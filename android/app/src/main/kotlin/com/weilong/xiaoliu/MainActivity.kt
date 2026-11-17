package com.weilong.xiaoliu

import android.Manifest
import android.annotation.SuppressLint
import android.app.Activity
import android.content.ActivityNotFoundException
import android.content.ClipData
import android.content.ContentUris
import android.content.ContentValues
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.graphics.Bitmap
import android.location.Location
import android.location.LocationManager
import android.os.CancellationSignal
import android.os.Handler
import android.os.Looper
import android.provider.CalendarContract
import android.provider.MediaStore
import android.speech.RecognizerIntent
import android.util.Size
import android.webkit.WebSettings
import android.webkit.WebView
import androidx.core.content.ContextCompat
import androidx.core.content.FileProvider
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import org.json.JSONObject
import org.json.JSONTokener
import java.io.File
import java.io.FileOutputStream
import java.util.TimeZone
import java.util.function.Consumer

class MainActivity : FlutterActivity() {
    companion object {
        private const val CALENDAR_CHANNEL = "com.weilong.hako/calendar"
        private const val SPEECH_CHANNEL = "com.weilong.hako/speech"
        private const val DEVICE_CHANNEL = "com.weilong.hako/device"
        private const val REQ_SPEECH = 9001
    }

    private var pendingSpeechResult: MethodChannel.Result? = null
    private var sandboxWebView: WebView? = null

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

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, SPEECH_CHANNEL)
            .setMethodCallHandler { call, result ->
                if (call.method == "startListening") {
                    if (pendingSpeechResult != null) {
                        result.error("BUSY", "語音辨識正在進行中", null)
                        return@setMethodCallHandler
                    }
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
                } else {
                    result.notImplemented()
                }
            }

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, DEVICE_CHANNEL)
            .setMethodCallHandler { call, result ->
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
                    else -> result.notImplemented()
                }
            }
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
                    val uri = FileProvider.getUriForFile(
                        this@MainActivity,
                        "${applicationContext.packageName}.fileprovider",
                        file
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
                    sandboxWebView = wv
                }

                val safeArgs = if (argsJson.isBlank()) "{}" else argsJson
                val quotedCode = JSONObject.quote(code)
                val wrapper = """
                    (function() {
                      try {
                        var args = $safeArgs;
                        var body = $quotedCode;
                        var fn = new Function('args', 'with(args){ ' + body + ' }');
                        var out = fn(args);
                        return JSON.stringify({ok: true, result: out === undefined ? '' : String(out)});
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
}
