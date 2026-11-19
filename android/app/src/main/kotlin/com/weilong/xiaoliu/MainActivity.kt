package com.weilong.xiaoliu

import android.Manifest
import android.annotation.SuppressLint
import android.app.Activity
import android.app.ActivityManager
import android.content.ActivityNotFoundException
import android.content.ClipData
import android.content.ClipboardManager
import android.content.ComponentCallbacks2
import android.content.ContentUris
import android.content.ContentValues
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.content.pm.PackageManager
import android.graphics.Bitmap
import android.hardware.Sensor
import android.hardware.SensorEvent
import android.hardware.SensorEventListener
import android.hardware.SensorManager
import android.hardware.camera2.CameraCharacteristics
import android.hardware.camera2.CameraManager
import android.location.Location
import android.location.LocationManager
import android.net.Uri
import android.os.BatteryManager
import android.os.Build
import android.os.Bundle
import android.os.CancellationSignal
import android.os.Handler
import android.os.Looper
import android.os.PowerManager
import android.os.VibrationEffect
import android.os.Vibrator
import android.os.VibratorManager
import android.provider.AlarmClock
import android.provider.CalendarContract
import android.provider.MediaStore
import android.provider.Settings
import android.speech.RecognitionListener
import android.speech.RecognizerIntent
import android.speech.SpeechRecognizer
import android.util.Size
import android.webkit.JavascriptInterface
import android.webkit.WebSettings
import android.webkit.WebView
import androidx.core.content.ContextCompat
import androidx.core.content.FileProvider
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import org.json.JSONObject
import org.json.JSONTokener
import java.io.File
import java.io.FileOutputStream
import java.util.TimeZone
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.function.Consumer
import kotlin.math.sqrt

class MainActivity : FlutterActivity(), SensorEventListener {
    companion object {
        private const val CALENDAR_CHANNEL = "com.weilong.hako/calendar"
        private const val SPEECH_CHANNEL = "com.weilong.hako/speech"
        private const val DEVICE_CHANNEL = "com.weilong.hako/device"
        private const val NATIVE_ACTIONS_CHANNEL = "com.weilong.xiaoliu/native_actions"
        private const val REQ_SPEECH = 9001
    }

    private var pendingSpeechResult: MethodChannel.Result? = null
    private var speechMethodChannel: MethodChannel? = null
    private var activeSpeechRecognizer: SpeechRecognizer? = null
    private var lastPartialSpeech: String = ""
    private var lastRmsPushMs: Long = 0L
    private var speechTimeoutRunnable: Runnable? = null
    private val uiHandler = Handler(Looper.getMainLooper())
    private var sandboxWebView: WebView? = null
    private var deviceMethodChannel: MethodChannel? = null
    private var sensorManager: SensorManager? = null
    private var accelerometer: Sensor? = null
    private var shakeRegistered = false
    private var lastShakeAtMs = 0L
    private var flutterHomeReady = false
    private var pendingLaunchAction: String? = null

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        sensorManager = getSystemService(Context.SENSOR_SERVICE) as? SensorManager
        accelerometer = sensorManager?.getDefaultSensor(Sensor.TYPE_ACCELEROMETER)
        captureGhostIntent(intent, dispatchIfReady = false)
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        captureGhostIntent(intent, dispatchIfReady = true)
    }

    override fun onResume() {
        super.onResume()
        if (isGhostOverlayPrefEnabled() && Settings.canDrawOverlays(this)) {
            sendGhostServiceAction(GhostOverlayService.ACTION_APP_FOREGROUND)
        }
        syncShakeSensorRegistration()
    }

    override fun onPause() {
        unregisterShakeSensor()
        if (activeSpeechRecognizer != null) {
            finishInlineSpeech(null)
        }
        if (pendingSpeechResult == null && isGhostOverlayPrefEnabled() && Settings.canDrawOverlays(this)) {
            sendGhostServiceAction(GhostOverlayService.ACTION_APP_BACKGROUND)
        }
        super.onPause()
    }

    override fun onDestroy() {
        finishInlineSpeech(null)
        super.onDestroy()
    }

    private fun captureGhostIntent(intent: Intent?, dispatchIfReady: Boolean) {
        val action = intent?.action ?: return
        val supported = when (action) {
            GhostOverlayService.INTENT_ACTION_OPEN_WHEEL,
            GhostOverlayService.INTENT_ACTION_VOICE_DIRECT,
            GhostOverlayService.INTENT_ACTION_OPEN_ROOMS,
            GhostOverlayService.INTENT_ACTION_OPEN_TODOS,
            GhostOverlayService.INTENT_ACTION_OPEN_CAMERA,
            GhostOverlayService.INTENT_ACTION_OPEN_NAV,
            GhostOverlayService.INTENT_ACTION_OPEN_CUTTING,
            GhostOverlayService.INTENT_ACTION_OPEN_TEXT,
            GhostOverlayService.INTENT_ACTION_OPEN_ROUTINES,
            GhostOverlayService.INTENT_ACTION_SPOKEN_TEXT -> true
            else -> false
        }
        if (!supported) return

        val payload = if (action == GhostOverlayService.INTENT_ACTION_SPOKEN_TEXT) {
            val spoken = intent.getStringExtra(GhostOverlayService.EXTRA_SPOKEN_TEXT) ?: ""
            "${GhostOverlayService.INTENT_ACTION_SPOKEN_TEXT}::$spoken"
        } else {
            action
        }

        if (dispatchIfReady && flutterHomeReady && deviceMethodChannel != null) {
            pendingLaunchAction = null
            uiHandler.post {
                try {
                    deviceMethodChannel?.invokeMethod("onGhostAction", payload)
                } catch (_: Exception) {}
            }
        } else {
            pendingLaunchAction = payload
        }
    }

    private fun ghostPrefs() =
        getSharedPreferences(GhostOverlayService.PREFS_NAME, Context.MODE_PRIVATE)

    private fun isGhostOverlayPrefEnabled(): Boolean =
        ghostPrefs().getBoolean(GhostOverlayService.KEY_OVERLAY_ENABLED, false)

    private fun isShakePrefEnabled(): Boolean =
        ghostPrefs().getBoolean(GhostOverlayService.KEY_SHAKE_ENABLED, false)

    private fun sendGhostServiceAction(action: String) {
        try {
            val svcIntent = Intent(this, GhostOverlayService::class.java).apply {
                this.action = action
            }
            if (action == GhostOverlayService.ACTION_STOP) {
                stopService(svcIntent)
            } else {
                ContextCompat.startForegroundService(this, svcIntent)
            }
        } catch (_: Exception) {}
    }

    private fun syncShakeSensorRegistration() {
        val wantShake = isShakePrefEnabled()
        if (wantShake && !shakeRegistered && accelerometer != null) {
            sensorManager?.registerListener(this, accelerometer, SensorManager.SENSOR_DELAY_UI)
            shakeRegistered = true
        } else if (!wantShake && shakeRegistered) {
            unregisterShakeSensor()
        }
    }

    private fun unregisterShakeSensor() {
        if (shakeRegistered) {
            sensorManager?.unregisterListener(this)
            shakeRegistered = false
        }
    }

    override fun onSensorChanged(event: SensorEvent?) {
        if (event?.sensor?.type != Sensor.TYPE_ACCELEROMETER) return
        val x = event.values[0]
        val y = event.values[1]
        val z = event.values[2]
        val gForce = sqrt((x * x + y * y + z * z).toDouble()) / SensorManager.GRAVITY_EARTH
        if (gForce > 2.65) {
            val now = System.currentTimeMillis()
            if (now - lastShakeAtMs > 2500L && pendingSpeechResult == null) {
                lastShakeAtMs = now
                deviceMethodChannel?.invokeMethod("onShakeWake", null)
            }
        }
    }

    override fun onAccuracyChanged(sensor: Sensor?, accuracy: Int) {}

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CALENDAR_CHANNEL)
            .setMethodCallHandler { call, result ->
                if (call.method == "insertEvent") {
                    val title = call.argument<String>("title") ?: "工作排程事件"
                    val description = call.argument<String>("description") ?: ""
                    val startMs = call.argument<Number>("startMs")?.toLong() ?: System.currentTimeMillis()
                    val endMs = call.argument<Number>("endMs")?.toLong() ?: (startMs + 3600_000L)
                    result.success(insertCalendarEvent(title, description, startMs, endMs))
                } else {
                    result.notImplemented()
                }
            }

        val speechChannel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, SPEECH_CHANNEL)
        speechMethodChannel = speechChannel
        speechChannel.setMethodCallHandler { call, result ->
            when (call.method) {
                "startListening" -> {
                    if (pendingSpeechResult != null) {
                        result.error("BUSY", "語音辨識正在進行中", null)
                        return@setMethodCallHandler
                    }
                    val hasMic = ContextCompat.checkSelfPermission(
                        this,
                        Manifest.permission.RECORD_AUDIO
                    ) == PackageManager.PERMISSION_GRANTED
                    if (!hasMic) {
                        result.error("NO_PERMISSION", "尚未授予麥克風權限", null)
                        return@setMethodCallHandler
                    }
                    if (SpeechRecognizer.isRecognitionAvailable(this)) {
                        startInlineSpeechRecognizer(result)
                    } else {
                        launchDialogSpeechFallback(result)
                    }
                }
                "stopListening" -> {
                    uiHandler.post {
                        try {
                            activeSpeechRecognizer?.stopListening()
                        } catch (_: Exception) {}
                    }
                    result.success(true)
                }
                "cancelListening" -> {
                    uiHandler.post { finishInlineSpeech(null) }
                    result.success(true)
                }
                else -> result.notImplemented()
            }
        }

        val unifiedDeviceHandler = MethodChannel.MethodCallHandler { call, result ->
            handleDeviceOrNativeCall(call, result)
        }
        val devChannel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, DEVICE_CHANNEL)
        devChannel.setMethodCallHandler(unifiedDeviceHandler)
        deviceMethodChannel = devChannel
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, NATIVE_ACTIONS_CHANNEL)
            .setMethodCallHandler(unifiedDeviceHandler)
    }

    override fun onTrimMemory(level: Int) {
        super.onTrimMemory(level)
        // Strictly ignore TRIM_MEMORY_UI_HIDDEN (20) etc.; only release on extreme critical pressure.
        if (level == ComponentCallbacks2.TRIM_MEMORY_RUNNING_CRITICAL ||
            level >= ComponentCallbacks2.TRIM_MEMORY_COMPLETE
        ) {
            Handler(Looper.getMainLooper()).post {
                try {
                    deviceMethodChannel?.invokeMethod("onMemoryCritical", mapOf("level" to level))
                } catch (_: Exception) {}
            }
        }
    }

    private fun handleDeviceOrNativeCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "getCurrentLocation" -> handleGetCurrentLocation(result)
            "shareContent" -> {
                val text = call.argument<String>("text") ?: ""
                val imagePath = call.argument<String>("imagePath")
                result.success(shareContent(text, imagePath))
            }
            "scanRecentPhotos" -> {
                val limit = call.argument<Number>("limit")?.toInt() ?: 30
                val sinceMs = call.argument<Number>("sinceMs")?.toLong() ?: 0L
                scanRecentPhotos(limit, sinceMs, result)
            }
            "copyAlbumPhoto" -> {
                val id = call.argument<Number>("id")?.toLong()
                if (id == null) {
                    result.success(null)
                } else {
                    copyAlbumPhoto(id, result)
                }
            }
            "evalJsHook" -> {
                val code = call.argument<String>("code") ?: ""
                val argsJson = call.argument<String>("argsJson") ?: "{}"
                evalJsHook(code, argsJson, result)
            }
            "callNative" -> {
                val action = call.argument<String>("action") ?: ""
                val params = call.argument<Map<String, Any?>>("params") ?: emptyMap()
                result.success(dispatchNativeAction(action, params))
            }
            "checkOverlayPermission" -> {
                result.success(Settings.canDrawOverlays(this))
            }
            "requestOverlayPermission" -> {
                try {
                    val intent = Intent(
                        Settings.ACTION_MANAGE_OVERLAY_PERMISSION,
                        Uri.parse("package:$packageName")
                    )
                    startActivity(intent)
                    result.success(true)
                } catch (_: Exception) {
                    result.success(false)
                }
            }
            "setGhostOverlayEnabled" -> {
                val enabled = call.argument<Boolean>("enabled") == true
                if (enabled && !Settings.canDrawOverlays(this)) {
                    ghostPrefs().edit().putBoolean(GhostOverlayService.KEY_OVERLAY_ENABLED, false).apply()
                    result.success(mapOf("ok" to false, "needsPermission" to true))
                } else {
                    ghostPrefs().edit().putBoolean(GhostOverlayService.KEY_OVERLAY_ENABLED, enabled).apply()
                    if (enabled) {
                        sendGhostServiceAction(GhostOverlayService.ACTION_START)
                        sendGhostServiceAction(GhostOverlayService.ACTION_APP_FOREGROUND)
                    } else {
                        sendGhostServiceAction(GhostOverlayService.ACTION_STOP)
                    }
                    result.success(mapOf("ok" to true, "enabled" to enabled))
                }
            }
            "setShakeToWakeEnabled" -> {
                val enabled = call.argument<Boolean>("enabled") == true
                ghostPrefs().edit().putBoolean(GhostOverlayService.KEY_SHAKE_ENABLED, enabled).apply()
                syncShakeSensorRegistration()
                result.success(mapOf("ok" to true, "enabled" to enabled))
            }
            "setGhostWheelSlots" -> {
                val rawSlots = (call.argument<List<*>>("slots"))?.mapNotNull { it?.toString() }
                val saved = GhostActionRegistry.saveSlots(ghostPrefs(), rawSlots ?: emptyList())
                result.success(mapOf("ok" to true, "slots" to saved))
            }
            "getGhostWheelSlots" -> {
                result.success(GhostActionRegistry.loadSlots(ghostPrefs()))
            }
            "consumePendingLaunchAction" -> {
                flutterHomeReady = true
                val act = pendingLaunchAction
                pendingLaunchAction = null
                result.success(act)
            }
            "setFlashlight", "dialPhone", "vibrate", "copyToClipboard",
            "setTimerOrAlarm", "openMap", "openSettings", "openUrl", "getDeviceRuntimeStatus" -> {
                val rawArgs = (call.arguments as? Map<*, *>)?.entries
                    ?.associate { it.key.toString() to it.value } ?: emptyMap()
                result.success(dispatchNativeAction(call.method, rawArgs))
            }
            else -> result.notImplemented()
        }
    }

    private fun launchDialogSpeechFallback(result: MethodChannel.Result) {
        val intent = Intent(RecognizerIntent.ACTION_RECOGNIZE_SPEECH).apply {
            putExtra(
                RecognizerIntent.EXTRA_LANGUAGE_MODEL,
                RecognizerIntent.LANGUAGE_MODEL_FREE_FORM
            )
            putExtra(RecognizerIntent.EXTRA_LANGUAGE, "zh-TW")
            putExtra(RecognizerIntent.EXTRA_PROMPT, "請對 KODARI（可達）說話…")
        }
        pendingSpeechResult = result
        try {
            @Suppress("DEPRECATION")
            startActivityForResult(intent, REQ_SPEECH)
        } catch (e: ActivityNotFoundException) {
            pendingSpeechResult = null
            result.error("NO_SPEECH", "此裝置不支援系統語音輸入", null)
        }
    }

    private fun startInlineSpeechRecognizer(result: MethodChannel.Result) {
        uiHandler.post {
            try {
                activeSpeechRecognizer?.cancel()
                activeSpeechRecognizer?.destroy()
            } catch (_: Exception) {}
            activeSpeechRecognizer = null

            val sr = try {
                SpeechRecognizer.createSpeechRecognizer(this)
            } catch (_: Exception) {
                null
            }
            if (sr == null) {
                launchDialogSpeechFallback(result)
                return@post
            }

            pendingSpeechResult = result
            lastPartialSpeech = ""
            lastRmsPushMs = 0L
            activeSpeechRecognizer = sr

            speechTimeoutRunnable?.let { uiHandler.removeCallbacks(it) }
            val timeout = Runnable {
                val partial = lastPartialSpeech.trim()
                finishInlineSpeech(partial.ifEmpty { null })
            }
            speechTimeoutRunnable = timeout
            uiHandler.postDelayed(timeout, 15_000L)

            sr.setRecognitionListener(object : RecognitionListener {
                override fun onReadyForSpeech(params: Bundle?) {}
                override fun onBeginningOfSpeech() {}
                override fun onRmsChanged(rmsdB: Float) {
                    val now = System.currentTimeMillis()
                    if (now - lastRmsPushMs < 45L) return
                    lastRmsPushMs = now
                    val level = ((rmsdB + 2f) / 12f).coerceIn(0f, 1f).toDouble()
                    try {
                        speechMethodChannel?.invokeMethod("onSpeechRms", level)
                    } catch (_: Exception) {}
                }

                override fun onBufferReceived(buffer: ByteArray?) {}
                override fun onEndOfSpeech() {
                    try {
                        speechMethodChannel?.invokeMethod("onSpeechRms", 0.1)
                    } catch (_: Exception) {}
                }

                override fun onError(error: Int) {
                    val fallback = if ((error == SpeechRecognizer.ERROR_NO_MATCH ||
                            error == SpeechRecognizer.ERROR_SPEECH_TIMEOUT) &&
                        lastPartialSpeech.isNotBlank()
                    ) {
                        lastPartialSpeech
                    } else {
                        null
                    }
                    finishInlineSpeech(fallback)
                }

                override fun onResults(results: Bundle?) {
                    val list = results?.getStringArrayList(SpeechRecognizer.RESULTS_RECOGNITION)
                    val finalText = (list?.firstOrNull() ?: "").trim().ifEmpty { lastPartialSpeech.trim() }
                    finishInlineSpeech(finalText.ifEmpty { null })
                }

                override fun onPartialResults(partialResults: Bundle?) {
                    val list = partialResults?.getStringArrayList(SpeechRecognizer.RESULTS_RECOGNITION)
                    val text = (list?.firstOrNull() ?: "").trim()
                    if (text.isNotEmpty()) {
                        lastPartialSpeech = text
                        try {
                            speechMethodChannel?.invokeMethod("onSpeechPartial", text)
                        } catch (_: Exception) {}
                    }
                }

                override fun onEvent(eventType: Int, params: Bundle?) {}
            })

            val intent = Intent(RecognizerIntent.ACTION_RECOGNIZE_SPEECH).apply {
                putExtra(RecognizerIntent.EXTRA_LANGUAGE_MODEL, RecognizerIntent.LANGUAGE_MODEL_FREE_FORM)
                putExtra(RecognizerIntent.EXTRA_LANGUAGE, "zh-TW")
                putExtra(RecognizerIntent.EXTRA_PARTIAL_RESULTS, true)
                putExtra(RecognizerIntent.EXTRA_MAX_RESULTS, 1)
            }
            try {
                sr.startListening(intent)
            } catch (_: Exception) {
                speechTimeoutRunnable?.let { uiHandler.removeCallbacks(it) }
                speechTimeoutRunnable = null
                try {
                    sr.destroy()
                } catch (_: Exception) {}
                activeSpeechRecognizer = null
                pendingSpeechResult = null
                launchDialogSpeechFallback(result)
            }
        }
    }

    private fun finishInlineSpeech(finalText: String?) {
        speechTimeoutRunnable?.let { uiHandler.removeCallbacks(it) }
        speechTimeoutRunnable = null
        val cb = pendingSpeechResult
        pendingSpeechResult = null
        lastPartialSpeech = ""
        lastRmsPushMs = 0L
        val sr = activeSpeechRecognizer
        activeSpeechRecognizer = null
        try {
            sr?.cancel()
            sr?.destroy()
        } catch (_: Exception) {}
        cb?.success(finalText?.trim()?.ifEmpty { null })
    }

    @Suppress("DEPRECATION")
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        if (requestCode == REQ_SPEECH) {
            val cb = pendingSpeechResult
            pendingSpeechResult = null
            if (resultCode == Activity.RESULT_OK && data != null) {
                val results = data.getStringArrayListExtra(RecognizerIntent.EXTRA_RESULTS)
                cb?.success(results?.firstOrNull())
            } else {
                cb?.success(null)
            }
            return
        }
        super.onActivityResult(requestCode, resultCode, data)
    }

    private fun insertCalendarEvent(
        title: String,
        description: String,
        startMs: Long,
        endMs: Long
    ): Map<String, Any?> {
        return try {
            val projection = arrayOf(
                CalendarContract.Calendars._ID,
                CalendarContract.Calendars.CALENDAR_DISPLAY_NAME,
                CalendarContract.Calendars.ACCOUNT_NAME,
                CalendarContract.Calendars.ACCOUNT_TYPE
            )
            val selection =
                "${CalendarContract.Calendars.VISIBLE} = 1 AND " +
                "${CalendarContract.Calendars.CALENDAR_ACCESS_LEVEL} >= ${CalendarContract.Calendars.CAL_ACCESS_CONTRIBUTOR}"
            val sortOrder =
                "CASE WHEN ${CalendarContract.Calendars.ACCOUNT_TYPE} = 'com.google' THEN 0 ELSE 1 END ASC, " +
                "${CalendarContract.Calendars.IS_PRIMARY} DESC, ${CalendarContract.Calendars._ID} ASC"

            var calendarId: Long? = null
            var calendarName = "系統日曆"

            contentResolver.query(
                CalendarContract.Calendars.CONTENT_URI,
                projection,
                selection,
                null,
                sortOrder
            )?.use { cursor ->
                if (cursor.moveToFirst()) {
                    calendarId = cursor.getLong(0)
                    val disp = cursor.getString(1) ?: "系統日曆"
                    val acct = cursor.getString(2) ?: ""
                    calendarName = if (acct.isNotEmpty() && acct != disp) "$disp ($acct)" else disp
                }
            }

            if (calendarId == null) {
                return mapOf("ok" to false, "reason" to "找不到可寫入的日曆帳戶")
            }

            val values = ContentValues().apply {
                put(CalendarContract.Events.DTSTART, startMs)
                put(CalendarContract.Events.DTEND, endMs)
                put(CalendarContract.Events.TITLE, title)
                put(CalendarContract.Events.DESCRIPTION, description)
                put(CalendarContract.Events.CALENDAR_ID, calendarId)
                put(CalendarContract.Events.EVENT_TIMEZONE, TimeZone.getDefault().id)
            }

            val uri = contentResolver.insert(CalendarContract.Events.CONTENT_URI, values)
            if (uri != null) {
                mapOf("ok" to true, "calendarName" to calendarName, "eventUri" to uri.toString())
            } else {
                mapOf("ok" to false, "reason" to "寫入日曆回傳空值")
            }
        } catch (e: SecurityException) {
            mapOf("ok" to false, "reason" to "缺少日曆寫入權限")
        } catch (e: Exception) {
            mapOf("ok" to false, "reason" to (e.message ?: "寫入失敗"))
        }
    }

    private fun locationToMap(loc: Location, stale: Boolean = false): Map<String, Any?> {
        return mapOf(
            "ok" to true,
            "lat" to loc.latitude,
            "lng" to loc.longitude,
            "altitude" to loc.altitude,
            "accuracy" to loc.accuracy.toDouble(),
            "provider" to (loc.provider ?: "gps"),
            "timestampMs" to loc.time,
            "stale" to stale
        )
    }

    @SuppressLint("MissingPermission")
    private fun handleGetCurrentLocation(result: MethodChannel.Result) {
        val fineGranted = ContextCompat.checkSelfPermission(
            this,
            Manifest.permission.ACCESS_FINE_LOCATION
        ) == PackageManager.PERMISSION_GRANTED
        val coarseGranted = ContextCompat.checkSelfPermission(
            this,
            Manifest.permission.ACCESS_COARSE_LOCATION
        ) == PackageManager.PERMISSION_GRANTED

        if (!fineGranted && !coarseGranted) {
            result.success(mapOf("ok" to false, "reason" to "缺少定位權限"))
            return
        }

        val lm = getSystemService(Context.LOCATION_SERVICE) as? LocationManager
        if (lm == null) {
            result.success(mapOf("ok" to false, "reason" to "無法取得系統定位服務"))
            return
        }

        val candidates = listOf(
            LocationManager.GPS_PROVIDER,
            LocationManager.NETWORK_PROVIDER,
            LocationManager.PASSIVE_PROVIDER
        )
        var bestLast: Location? = null
        for (p in candidates) {
            try {
                if (!lm.isProviderEnabled(p) && p != LocationManager.PASSIVE_PROVIDER) continue
                val loc = lm.getLastKnownLocation(p) ?: continue
                if (bestLast == null || loc.time > bestLast!!.time) {
                    bestLast = loc
                }
            } catch (_: Exception) {}
        }

        val now = System.currentTimeMillis()
        if (bestLast != null && (now - bestLast!!.time) <= 90_000L && bestLast!!.accuracy <= 60f) {
            result.success(locationToMap(bestLast!!, stale = false))
            return
        }

        val activeProvider = when {
            lm.isProviderEnabled(LocationManager.GPS_PROVIDER) -> LocationManager.GPS_PROVIDER
            lm.isProviderEnabled(LocationManager.NETWORK_PROVIDER) -> LocationManager.NETWORK_PROVIDER
            else -> null
        }

        if (activeProvider == null) {
            if (bestLast != null) {
                result.success(locationToMap(bestLast!!, stale = true))
            } else {
                result.success(mapOf("ok" to false, "reason" to "手機定位（GPS）未開啟"))
            }
            return
        }

        val cancelSignal = CancellationSignal()
        val handler = Handler(Looper.getMainLooper())
        var replied = false

        val timeoutRunnable = Runnable {
            if (!replied) {
                replied = true
                cancelSignal.cancel()
                if (bestLast != null) {
                    result.success(locationToMap(bestLast!!, stale = true))
                } else {
                    result.success(mapOf("ok" to false, "reason" to "衛星定位逾時（室內可移至窗邊再試）"))
                }
            }
        }
        handler.postDelayed(timeoutRunnable, 5500L)

        try {
            lm.getCurrentLocation(
                activeProvider,
                cancelSignal,
                mainExecutor,
                Consumer { loc ->
                    handler.removeCallbacks(timeoutRunnable)
                    if (replied) return@Consumer
                    replied = true
                    if (loc != null) {
                        result.success(locationToMap(loc, stale = false))
                    } else if (bestLast != null) {
                        result.success(locationToMap(bestLast!!, stale = true))
                    } else {
                        result.success(mapOf("ok" to false, "reason" to "無法取得當前 GPS 座標"))
                    }
                }
            )
        } catch (e: Exception) {
            handler.removeCallbacks(timeoutRunnable)
            if (!replied) {
                replied = true
                if (bestLast != null) {
                    result.success(locationToMap(bestLast!!, stale = true))
                } else {
                    result.success(mapOf("ok" to false, "reason" to (e.message ?: "定位失敗")))
                }
            }
        }
    }

    private fun shareContent(text: String, imagePath: String?): Map<String, Any?> {
        return try {
            val file = if (!imagePath.isNullOrBlank()) File(imagePath) else null
            val hasImage = file != null && file.exists() && file.length() > 0L

            val sendIntent = Intent(Intent.ACTION_SEND).apply {
                if (hasImage && file != null) {
                    val shareDir = File(cacheDir, "share_tmp").apply {
                        if (!exists()) mkdirs()
                    }
                    val cachedFile = File(shareDir, file.name)
                    file.copyTo(cachedFile, overwrite = true)
                    val uri = FileProvider.getUriForFile(
                        this@MainActivity,
                        "${applicationContext.packageName}.fileprovider",
                        cachedFile
                    )
                    type = "image/*"
                    putExtra(Intent.EXTRA_STREAM, uri)
                    if (text.isNotEmpty()) {
                        putExtra(Intent.EXTRA_TEXT, text)
                    }
                    clipData = ClipData.newRawUri("現場圖片", uri)
                    addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
                } else {
                    type = "text/plain"
                    putExtra(Intent.EXTRA_TEXT, text)
                }
            }

            val chooser = Intent.createChooser(sendIntent, "分享到 LINE／其他應用").apply {
                addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
            }
            startActivity(chooser)
            mapOf("ok" to true, "withImage" to hasImage)
        } catch (e: Exception) {
            mapOf("ok" to false, "reason" to (e.message ?: "無法開啟系統分享"))
        }
    }

    private fun scanRecentPhotos(limit: Int, sinceMs: Long, result: MethodChannel.Result) {
        val cappedLimit = limit.coerceIn(1, 60)
        Thread {
            try {
                val thumbDir = File(cacheDir, "album_thumbs").apply {
                    if (!exists()) mkdirs()
                }
                val projection = arrayOf(
                    MediaStore.Images.Media._ID,
                    MediaStore.Images.Media.DISPLAY_NAME,
                    MediaStore.Images.Media.DATE_TAKEN,
                    MediaStore.Images.Media.DATE_ADDED,
                    MediaStore.Images.Media.WIDTH,
                    MediaStore.Images.Media.HEIGHT,
                    MediaStore.Images.Media.BUCKET_DISPLAY_NAME
                )
                val selection = if (sinceMs > 0L) {
                    "${MediaStore.Images.Media.DATE_ADDED} >= ?"
                } else {
                    null
                }
                val selectionArgs = if (sinceMs > 0L) {
                    arrayOf((sinceMs / 1000L).toString())
                } else {
                    null
                }
                val sortOrder = "${MediaStore.Images.Media.DATE_ADDED} DESC"
                val items = ArrayList<Map<String, Any?>>()

                contentResolver.query(
                    MediaStore.Images.Media.EXTERNAL_CONTENT_URI,
                    projection,
                    selection,
                    selectionArgs,
                    sortOrder
                )?.use { cursor ->
                    val idxId = cursor.getColumnIndexOrThrow(MediaStore.Images.Media._ID)
                    val idxName = cursor.getColumnIndexOrThrow(MediaStore.Images.Media.DISPLAY_NAME)
                    val idxTaken = cursor.getColumnIndexOrThrow(MediaStore.Images.Media.DATE_TAKEN)
                    val idxAdded = cursor.getColumnIndexOrThrow(MediaStore.Images.Media.DATE_ADDED)
                    val idxW = cursor.getColumnIndexOrThrow(MediaStore.Images.Media.WIDTH)
                    val idxH = cursor.getColumnIndexOrThrow(MediaStore.Images.Media.HEIGHT)
                    val idxBucket = cursor.getColumnIndexOrThrow(MediaStore.Images.Media.BUCKET_DISPLAY_NAME)

                    while (cursor.moveToNext() && items.size < cappedLimit) {
                        val id = cursor.getLong(idxId)
                        val name = cursor.getString(idxName) ?: "photo_$id.jpg"
                        val takenRaw = cursor.getLong(idxTaken)
                        val addedSec = cursor.getLong(idxAdded)
                        val tsMs = if (takenRaw > 0L) takenRaw else addedSec * 1000L
                        val width = cursor.getInt(idxW)
                        val height = cursor.getInt(idxH)
                        val bucket = cursor.getString(idxBucket) ?: "相簿"

                        val thumbFile = File(thumbDir, "thumb_$id.jpg")
                        if (!thumbFile.exists() || thumbFile.length() == 0L) {
                            try {
                                val uri = ContentUris.withAppendedId(
                                    MediaStore.Images.Media.EXTERNAL_CONTENT_URI,
                                    id
                                )
                                val bmp = contentResolver.loadThumbnail(uri, Size(320, 320), null)
                                FileOutputStream(thumbFile).use { out ->
                                    bmp.compress(Bitmap.CompressFormat.JPEG, 78, out)
                                }
                                bmp.recycle()
                            } catch (_: Exception) {
                                continue
                            }
                        }

                        items.add(
                            mapOf(
                                "id" to id,
                                "displayName" to name,
                                "dateTakenMs" to tsMs,
                                "width" to width,
                                "height" to height,
                                "bucketName" to bucket,
                                "thumbPath" to thumbFile.absolutePath
                            )
                        )
                    }
                }

                runOnUiThread {
                    result.success(items)
                }
            } catch (e: Exception) {
                runOnUiThread {
                    result.error("ALBUM_SCAN_ERROR", e.message ?: "相簿掃描失敗", null)
                }
            }
        }.start()
    }

    private fun copyAlbumPhoto(id: Long, result: MethodChannel.Result) {
        Thread {
            try {
                val uri = ContentUris.withAppendedId(
                    MediaStore.Images.Media.EXTERNAL_CONTENT_URI,
                    id
                )
                val target = File(cacheDir, "album_import_${id}_${System.currentTimeMillis()}.jpg")
                contentResolver.openInputStream(uri)?.use { input ->
                    FileOutputStream(target).use { output ->
                        input.copyTo(output)
                    }
                } ?: run {
                    runOnUiThread { result.success(null) }
                    return@Thread
                }
                runOnUiThread {
                    result.success(target.absolutePath)
                }
            } catch (_: Exception) {
                runOnUiThread {
                    result.success(null)
                }
            }
        }.start()
    }

    @SuppressLint("SetJavaScriptEnabled")
    private fun evalJsHook(code: String, argsJson: String, result: MethodChannel.Result) {
        runOnUiThread {
            try {
                val webView = sandboxWebView ?: WebView(applicationContext).also { wv ->
                    wv.settings.javaScriptEnabled = true
                    wv.settings.allowFileAccess = false
                    wv.settings.allowContentAccess = false
                    wv.settings.blockNetworkLoads = true
                    wv.settings.cacheMode = WebSettings.LOAD_NO_CACHE
                    wv.addJavascriptInterface(HakoJsBridge(), "HakoNativeBridge")
                    sandboxWebView = wv
                }

                val safeArgs = if (argsJson.isBlank()) "{}" else argsJson
                val quotedCode = JSONObject.quote(code)
                val wrapper = """
                    (function() {
                      try {
                        var args = $safeArgs;
                        var body = $quotedCode;
                        var callNative = function(action, params) {
                          if (typeof HakoNativeBridge === 'undefined') {
                            return { ok: false, error: 'HakoNativeBridge unavailable' };
                          }
                          var raw = HakoNativeBridge.callNative(String(action || ''), JSON.stringify(params || {}));
                          try { return JSON.parse(raw); } catch (_) { return { ok: true, raw: raw }; }
                        };
                        var fn = new Function('args', 'callNative', 'with(args){ ' + body + ' }');
                        var out = fn(args, callNative);
                        return JSON.stringify({ok: true, result: out === undefined ? '' : (typeof out === 'object' ? JSON.stringify(out) : String(out))});
                      } catch (e) {
                        return JSON.stringify({ok: false, error: String(e)});
                      }
                    })();
                """.trimIndent()

                webView.evaluateJavascript(wrapper) { raw ->
                    try {
                        val unwrapped = JSONTokener(raw ?: "null").nextValue()?.toString() ?: "{}"
                        val obj = JSONObject(unwrapped)
                        result.success(
                            mapOf(
                                "ok" to obj.optBoolean("ok", false),
                                "result" to obj.optString("result", ""),
                                "error" to obj.optString("error", "")
                            )
                        )
                    } catch (e: Exception) {
                        result.success(mapOf("ok" to false, "error" to (e.message ?: "JS 回傳解析失敗")))
                    }
                }
            } catch (e: Exception) {
                result.success(mapOf("ok" to false, "error" to (e.message ?: "JS 沙盒啟動失敗")))
            }
        }
    }

    inner class HakoJsBridge {
        @JavascriptInterface
        fun callNative(action: String, paramsJson: String?): String {
            return try {
                val map = mutableMapOf<String, Any?>()
                if (!paramsJson.isNullOrBlank()) {
                    val obj = JSONObject(paramsJson)
                    val keys = obj.keys()
                    while (keys.hasNext()) {
                        val k = keys.next()
                        map[k] = obj.opt(k)
                    }
                }
                val res: Map<String, Any?> = if (Looper.myLooper() == Looper.getMainLooper()) {
                    dispatchNativeAction(action, map)
                } else {
                    var out: Map<String, Any?> = mapOf("ok" to false, "error" to "主執行緒逾時")
                    val latch = CountDownLatch(1)
                    Handler(Looper.getMainLooper()).post {
                        try {
                            out = dispatchNativeAction(action, map)
                        } finally {
                            latch.countDown()
                        }
                    }
                    latch.await(2, TimeUnit.SECONDS)
                    out
                }
                JSONObject(res).toString()
            } catch (e: Exception) {
                JSONObject(mapOf("ok" to false, "error" to (e.message ?: "原生橋接失敗"))).toString()
            }
        }
    }

    private fun dispatchNativeAction(action: String, args: Map<String, Any?>): Map<String, Any?> {
        return when (action.trim()) {
            "setFlashlight" -> {
                val on = when (val raw = args["on"]) {
                    is Boolean -> raw
                    is Number -> raw.toInt() != 0
                    is String -> raw.equals("true", ignoreCase = true) || raw == "1" || raw == "開"
                    else -> true
                }
                setFlashlight(on)
            }
            "dialPhone" -> {
                val phone = (args["phone"] ?: args["number"] ?: "").toString()
                dialPhone(phone)
            }
            "vibrate" -> {
                val ms = (args["durationMs"] as? Number)?.toLong()
                    ?: (args["ms"] as? Number)?.toLong()
                    ?: 220L
                vibrateDevice(ms)
            }
            "copyToClipboard" -> {
                val text = (args["text"] ?: args["content"] ?: "").toString()
                copyToClipboardNative(text)
            }
            "setTimerOrAlarm" -> {
                val mode = (args["mode"] ?: "timer").toString().lowercase()
                val minutes = (args["minutes"] as? Number)?.toInt()
                val seconds = (args["seconds"] as? Number)?.toInt()
                val hour = (args["hour"] as? Number)?.toInt()
                val minute = (args["minute"] as? Number)?.toInt()
                val message = (args["message"] ?: "KODARI 現場計時").toString()
                val skipUi = args["skipUi"] == true
                setTimerOrAlarm(mode, minutes, seconds, hour, minute, message, skipUi)
            }
            "openMap" -> {
                val query = (args["query"] ?: args["q"] ?: args["queryOrLatLng"] ?: "").toString()
                openMapIntent(query)
            }
            "openSettings" -> {
                val panel = (args["panel"] ?: args["target"] ?: "main").toString()
                openSettingsIntent(panel)
            }
            "openUrl" -> {
                val url = (args["url"] ?: args["href"] ?: "").toString()
                openExternalUrlIntent(url)
            }
            "getDeviceRuntimeStatus" -> getDeviceRuntimeStatusMap()
            else -> mapOf("ok" to false, "reason" to "不支援的原生動作：$action")
        }
    }

    private fun setFlashlight(on: Boolean): Map<String, Any?> {
        return try {
            val cm = getSystemService(Context.CAMERA_SERVICE) as? CameraManager
                ?: return mapOf("ok" to false, "reason" to "找不到相機硬體服務")
            var targetId: String? = null
            for (id in cm.cameraIdList) {
                val chars = cm.getCameraCharacteristics(id)
                val hasFlash = chars.get(CameraCharacteristics.FLASH_INFO_AVAILABLE) == true
                val facingBack = chars.get(CameraCharacteristics.LENS_FACING) == CameraCharacteristics.LENS_FACING_BACK
                if (hasFlash && facingBack) {
                    targetId = id
                    break
                }
                if (hasFlash && targetId == null) {
                    targetId = id
                }
            }
            if (targetId == null) {
                return mapOf("ok" to false, "reason" to "此裝置沒有可控制的閃光燈")
            }
            cm.setTorchMode(targetId, on)
            mapOf("ok" to true, "on" to on, "action" to "setFlashlight")
        } catch (e: Exception) {
            mapOf("ok" to false, "reason" to (e.message ?: "手電筒切換失敗"))
        }
    }

    private fun dialPhone(rawPhone: String): Map<String, Any?> {
        val cleaned = rawPhone.replace(Regex("""[^\d+*#\-]"""), "").trim()
        if (cleaned.isEmpty()) {
            return mapOf("ok" to false, "reason" to "請提供有效的電話號碼")
        }
        return try {
            val intent = Intent(Intent.ACTION_DIAL, Uri.parse("tel:$cleaned"))
            startActivity(intent)
            mapOf("ok" to true, "phone" to cleaned, "action" to "dialPhone")
        } catch (e: Exception) {
            mapOf("ok" to false, "reason" to (e.message ?: "無法開啟撥號畫面"))
        }
    }

    private fun vibrateDevice(durationMs: Long): Map<String, Any?> {
        val safeMs = durationMs.coerceIn(40L, 2000L)
        return try {
            val vibrator: Vibrator? = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
                val vm = getSystemService(Context.VIBRATOR_MANAGER_SERVICE) as? VibratorManager
                vm?.defaultVibrator
            } else {
                @Suppress("DEPRECATION")
                getSystemService(Context.VIBRATOR_SERVICE) as? Vibrator
            }
            if (vibrator == null || !vibrator.hasVibrator()) {
                return mapOf("ok" to false, "reason" to "裝置不支援震動馬達")
            }
            vibrator.vibrate(VibrationEffect.createOneShot(safeMs, VibrationEffect.DEFAULT_AMPLITUDE))
            mapOf("ok" to true, "durationMs" to safeMs, "action" to "vibrate")
        } catch (e: Exception) {
            mapOf("ok" to false, "reason" to (e.message ?: "震動失敗"))
        }
    }

    private fun copyToClipboardNative(text: String): Map<String, Any?> {
        return try {
            val cm = getSystemService(Context.CLIPBOARD_SERVICE) as? ClipboardManager
                ?: return mapOf("ok" to false, "reason" to "無法存取系統剪貼簿")
            cm.setPrimaryClip(ClipData.newPlainText("HAKO", text))
            mapOf("ok" to true, "length" to text.length, "action" to "copyToClipboard")
        } catch (e: Exception) {
            mapOf("ok" to false, "reason" to (e.message ?: "寫入剪貼簿失敗"))
        }
    }

    private fun setTimerOrAlarm(
        mode: String,
        minutes: Int?,
        seconds: Int?,
        hour: Int?,
        minute: Int?,
        message: String,
        skipUi: Boolean
    ): Map<String, Any?> {
        return try {
            val useAlarm = mode == "alarm" || (hour != null && minutes == null && seconds == null)
            if (useAlarm) {
                val h = (hour ?: 8).coerceIn(0, 23)
                val m = (minute ?: 0).coerceIn(0, 59)
                val intent = Intent(AlarmClock.ACTION_SET_ALARM).apply {
                    putExtra(AlarmClock.EXTRA_HOUR, h)
                    putExtra(AlarmClock.EXTRA_MINUTES, m)
                    putExtra(AlarmClock.EXTRA_MESSAGE, message)
                    putExtra(AlarmClock.EXTRA_SKIP_UI, skipUi)
                }
                startActivity(intent)
                mapOf("ok" to true, "mode" to "alarm", "hour" to h, "minute" to m, "message" to message)
            } else {
                val totalSec = ((seconds ?: 0) + (minutes ?: if (seconds == null) 5 else 0) * 60)
                    .coerceIn(5, 86400)
                val intent = Intent(AlarmClock.ACTION_SET_TIMER).apply {
                    putExtra(AlarmClock.EXTRA_LENGTH, totalSec)
                    putExtra(AlarmClock.EXTRA_MESSAGE, message)
                    putExtra(AlarmClock.EXTRA_SKIP_UI, skipUi)
                }
                startActivity(intent)
                mapOf("ok" to true, "mode" to "timer", "seconds" to totalSec, "message" to message)
            }
        } catch (e: Exception) {
            mapOf("ok" to false, "reason" to (e.message ?: "無法喚起系統時鐘（請檢查系統時鐘支援）"))
        }
    }

    private fun openMapIntent(rawQuery: String): Map<String, Any?> {
        val q = rawQuery.trim()
        if (q.isEmpty()) {
            return mapOf("ok" to false, "reason" to "請提供地點名稱或座標")
        }
        return try {
            val geoUri = Uri.parse("geo:0,0?q=${Uri.encode(q)}")
            val intent = Intent(Intent.ACTION_VIEW, geoUri)
            startActivity(intent)
            mapOf("ok" to true, "query" to q, "action" to "openMap")
        } catch (_: Exception) {
            try {
                val webIntent = Intent(
                    Intent.ACTION_VIEW,
                    Uri.parse("https://maps.google.com/?q=${Uri.encode(q)}")
                )
                startActivity(webIntent)
                mapOf("ok" to true, "query" to q, "action" to "openMap")
            } catch (e: Exception) {
                mapOf("ok" to false, "reason" to (e.message ?: "無法開啟地圖應用"))
            }
        }
    }

    private fun openSettingsIntent(panel: String): Map<String, Any?> {
        val p = panel.trim().lowercase()
        val action = when {
            p.contains("wifi") || p.contains("wi-fi") || p.contains("無線") -> Settings.ACTION_WIFI_SETTINGS
            p.contains("blue") || p.contains("藍牙") -> Settings.ACTION_BLUETOOTH_SETTINGS
            p.contains("hotspot") || p.contains("tether") || p.contains("熱點") || p.contains("分享") ->
                Settings.ACTION_WIRELESS_SETTINGS
            p.contains("loc") || p.contains("gps") || p.contains("定位") -> Settings.ACTION_LOCATION_SOURCE_SETTINGS
            else -> Settings.ACTION_SETTINGS
        }
        return try {
            startActivity(Intent(action))
            mapOf("ok" to true, "panel" to p, "intentAction" to action)
        } catch (e: Exception) {
            try {
                startActivity(Intent(Settings.ACTION_SETTINGS))
                mapOf("ok" to true, "panel" to "main", "intentAction" to Settings.ACTION_SETTINGS)
            } catch (e2: Exception) {
                mapOf("ok" to false, "reason" to (e2.message ?: "無法開啟系統設定"))
            }
        }
    }

    private fun openExternalUrlIntent(rawUrl: String): Map<String, Any?> {
        val trimmed = rawUrl.trim()
        if (trimmed.isEmpty()) {
            return mapOf("ok" to false, "reason" to "缺少目標網址")
        }
        val normalized = if (trimmed.startsWith("http://", ignoreCase = true) ||
            trimmed.startsWith("https://", ignoreCase = true)
        ) {
            trimmed
        } else {
            "https://$trimmed"
        }
        return try {
            val intent = Intent(Intent.ACTION_VIEW, Uri.parse(normalized))
            startActivity(intent)
            mapOf("ok" to true, "url" to normalized, "action" to "openUrl")
        } catch (e: Exception) {
            mapOf("ok" to false, "reason" to (e.message ?: "無法開啟瀏覽器"), "url" to normalized)
        }
    }

    private fun getDeviceRuntimeStatusMap(): Map<String, Any?> {
        return try {
            val am = getSystemService(Context.ACTIVITY_SERVICE) as? ActivityManager
            val memInfo = ActivityManager.MemoryInfo()
            am?.getMemoryInfo(memInfo)

            val totalRamMb = memInfo.totalMem / (1024L * 1024L)
            val availRamMb = memInfo.availMem / (1024L * 1024L)

            val pm = getSystemService(Context.POWER_SERVICE) as? PowerManager
            val isScreenInteractive = pm?.isInteractive ?: true

            val batteryStatus = registerReceiver(null, IntentFilter(Intent.ACTION_BATTERY_CHANGED))
            val statusInt = batteryStatus?.getIntExtra(BatteryManager.EXTRA_STATUS, -1) ?: -1
            val isCharging = statusInt == BatteryManager.BATTERY_STATUS_CHARGING ||
                statusInt == BatteryManager.BATTERY_STATUS_FULL
            val level = batteryStatus?.getIntExtra(BatteryManager.EXTRA_LEVEL, -1) ?: -1
            val scale = batteryStatus?.getIntExtra(BatteryManager.EXTRA_SCALE, 100) ?: 100
            val batteryPct = if (level >= 0 && scale > 0) ((level * 100f) / scale).toInt() else -1

            mapOf(
                "ok" to true,
                "totalRamMb" to totalRamMb,
                "availRamMb" to availRamMb,
                "lowMemory" to memInfo.lowMemory,
                "isScreenInteractive" to isScreenInteractive,
                "isCharging" to isCharging,
                "batteryPct" to batteryPct
            )
        } catch (e: Exception) {
            mapOf("ok" to false, "reason" to (e.message ?: "無法讀取硬體運行狀態"))
        }
    }
}
