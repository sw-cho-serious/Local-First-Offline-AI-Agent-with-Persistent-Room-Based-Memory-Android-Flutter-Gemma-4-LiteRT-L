package com.weilong.xiaoliu

import android.Manifest
import android.animation.Animator
import android.animation.AnimatorListenerAdapter
import android.animation.ValueAnimator
import android.annotation.SuppressLint
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.ClipboardManager
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.content.pm.ServiceInfo
import android.content.res.Configuration
import android.graphics.Bitmap
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.Outline
import android.graphics.Paint
import android.graphics.PixelFormat
import android.graphics.Rect
import android.graphics.RectF
import android.graphics.drawable.AnimationDrawable
import android.graphics.drawable.GradientDrawable
import android.hardware.camera2.CameraCharacteristics
import android.hardware.camera2.CameraManager
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import android.os.VibrationEffect
import android.os.Vibrator
import android.os.VibratorManager
import android.provider.Settings
import android.speech.RecognitionListener
import android.speech.RecognizerIntent
import android.speech.SpeechRecognizer
import android.text.TextUtils
import android.util.TypedValue
import android.view.Choreographer
import android.view.Gravity
import android.view.KeyEvent
import android.view.MotionEvent
import android.view.View
import android.view.ViewConfiguration
import android.view.ViewOutlineProvider
import android.view.WindowManager
import android.view.animation.LinearInterpolator
import android.view.animation.OvershootInterpolator
import android.widget.FrameLayout
import android.widget.ImageView
import android.widget.LinearLayout
import android.widget.TextView
import android.widget.Toast
import androidx.core.content.ContextCompat
import kotlin.math.abs
import kotlin.math.cos
import kotlin.math.sin

/**
 * 0%-CPU idle desktop floating KODARI assistant overlay (inspired by GHOST / AssistiveTouch).
 * - Rests cleanly as a semi-transparent edge-docked ImageView with zero background polling.
 * - Uses Choreographer VSync throttling, FLAG_HARDWARE_ACCELERATED, and Q+ gesture exclusion
 *   for 120Hz butter-smooth dragging and gentle magnetic edge docking.
 * - Tap opens the 6-track symmetrical amber radial wheel IN PLACE over any app without launching MainActivity.
 * - Long-press or center Kodari tap opens an in-place SpeechRecognizer HUD with amber soundwaves.
 */
class GhostOverlayService : Service() {

    companion object {
        const val PREFS_NAME = "hako_ghost_prefs"
        const val KEY_OVERLAY_ENABLED = "overlay_enabled"
        const val KEY_SHAKE_ENABLED = "shake_enabled"
        const val KEY_DOCK_RIGHT = "dock_right"
        const val KEY_Y_POS = "y_pos"
        const val KEY_WHEEL_SLOTS = "wheel_slots"

        const val ACTION_START = "com.weilong.xiaoliu.ghost.START"
        const val ACTION_STOP = "com.weilong.xiaoliu.ghost.STOP"
        const val ACTION_APP_FOREGROUND = "com.weilong.xiaoliu.ghost.APP_FOREGROUND"
        const val ACTION_APP_BACKGROUND = "com.weilong.xiaoliu.ghost.APP_BACKGROUND"

        const val INTENT_ACTION_OPEN_WHEEL = "com.weilong.xiaoliu.ACTION_OPEN_WHEEL"
        const val INTENT_ACTION_VOICE_DIRECT = "com.weilong.xiaoliu.ACTION_VOICE_DIRECT"
        const val INTENT_ACTION_OPEN_ROOMS = "com.weilong.xiaoliu.ACTION_OPEN_ROOMS"
        const val INTENT_ACTION_OPEN_TODOS = "com.weilong.xiaoliu.ACTION_OPEN_TODOS"
        const val INTENT_ACTION_OPEN_CAMERA = "com.weilong.xiaoliu.ACTION_OPEN_CAMERA"
        const val INTENT_ACTION_OPEN_NAV = "com.weilong.xiaoliu.ACTION_OPEN_NAV"
        const val INTENT_ACTION_OPEN_CUTTING = "com.weilong.xiaoliu.ACTION_OPEN_CUTTING"
        const val INTENT_ACTION_OPEN_TEXT = "com.weilong.xiaoliu.ACTION_OPEN_TEXT"
        const val INTENT_ACTION_OPEN_ROUTINES = "com.weilong.xiaoliu.ACTION_OPEN_ROUTINES"
        const val INTENT_ACTION_SPOKEN_TEXT = "com.weilong.xiaoliu.ACTION_SPOKEN_TEXT"
        const val EXTRA_SPOKEN_TEXT = "spoken_text"

        private const val CHANNEL_ID = "hako_ghost_overlay"
        private const val NOTIF_ID = 7701
        private const val IDLE_ALPHA = 0.60f
        private const val ACTIVE_ALPHA = 1.0f

        @Volatile
        var isRunning: Boolean = false
            private set
    }

    private var windowManager: WindowManager? = null
    private var overlayContainer: FrameLayout? = null
    private var overlayParams: WindowManager.LayoutParams? = null
    private var spriteImage: ImageView? = null
    private var isAppForeground = false
    private var dockAnimator: ValueAnimator? = null

    // Choreographer VSync drag throttling state
    private var cachedScreenW = 0
    private var cachedScreenH = 0
    private var pendingDragX = 0
    private var pendingDragY = 0
    private var dragFramePending = false
    private var isActivelyDragging = false

    private val dragFrameCallback = Choreographer.FrameCallback {
        dragFramePending = false
        if (!isActivelyDragging) return@FrameCallback
        val container = overlayContainer ?: return@FrameCallback
        val p = overlayParams ?: return@FrameCallback
        if (p.x != pendingDragX || p.y != pendingDragY) {
            p.x = pendingDragX
            p.y = pendingDragY
            try {
                windowManager?.updateViewLayout(container, p)
            } catch (_: Exception) {}
        }
    }

    // Native torch state
    private var cameraManager: CameraManager? = null
    private var torchCameraId: String? = null
    private var isTorchOn = false
    private val torchCallback = object : CameraManager.TorchCallback() {
        override fun onTorchModeChanged(cameraId: String, enabled: Boolean) {
            if (torchCameraId == null || cameraId == torchCameraId) {
                isTorchOn = enabled
                wheelTorchLabel?.text = if (enabled) "手電筒 ON" else "手電筒"
            }
        }
    }

    // In-place radial wheel overlay
    private var wheelOverlay: FrameLayout? = null
    private var wheelSpriteAnim: AnimationDrawable? = null
    private var wheelTorchLabel: TextView? = null

    // In-place desktop voice HUD overlay
    private var voiceOverlay: FrameLayout? = null
    private var voiceSpriteAnim: AnimationDrawable? = null
    private var voiceBubbleText: TextView? = null
    private var soundwaveView: AmberSoundwaveView? = null
    private var desktopSpeechRecognizer: SpeechRecognizer? = null
    private var lastVoicePartial: String = ""
    private var voiceHandlingResult = false
    private var voiceMemoMode = false
    private var voiceWatchdogRunnable: Runnable? = null
    private var voiceDismissRunnable: Runnable? = null

    // In-place card overlay & dark-gold HUD banner
    private var activeCardOverlay: FrameLayout? = null
    private var hudBannerOverlay: FrameLayout? = null
    private var hudDismissRunnable: Runnable? = null
    private var hudThumbBitmap: Bitmap? = null

    private val mainHandler = Handler(Looper.getMainLooper())
    private val executors by lazy { GhostInPlaceExecutors(this) }

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onCreate() {
        super.onCreate()
        isRunning = true
        windowManager = getSystemService(Context.WINDOW_SERVICE) as? WindowManager
        cameraManager = getSystemService(Context.CAMERA_SERVICE) as? CameraManager
        torchCameraId = resolveTorchCameraId()
        try {
            cameraManager?.registerTorchCallback(torchCallback, mainHandler)
        } catch (_: Exception) {}
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        ensureForegroundNotification()
        when (intent?.action) {
            ACTION_STOP -> {
                dismissWheelOverlay(restoreNub = false)
                dismissVoiceOverlay(restoreNub = false)
                dismissActiveCard(restoreNub = false)
                dismissHudBanner()
                removeOverlayView()
                stopForegroundCompat()
                stopSelf()
                return START_NOT_STICKY
            }
            ACTION_APP_FOREGROUND -> {
                isAppForeground = true
                dismissWheelOverlay(restoreNub = false)
                dismissVoiceOverlay(restoreNub = false)
                dismissActiveCard(restoreNub = false)
                dismissHudBanner()
                overlayContainer?.visibility = View.GONE
            }
            ACTION_APP_BACKGROUND -> {
                isAppForeground = false
                if (Settings.canDrawOverlays(this)) {
                    ensureOverlayView()
                    if (wheelOverlay == null && voiceOverlay == null && activeCardOverlay == null) {
                        overlayContainer?.visibility = View.VISIBLE
                    }
                }
            }
            ACTION_START, null -> {
                if (!Settings.canDrawOverlays(this)) {
                    stopForegroundCompat()
                    stopSelf()
                    return START_NOT_STICKY
                }
                ensureOverlayView()
                overlayContainer?.visibility =
                    if (isAppForeground || wheelOverlay != null || voiceOverlay != null || activeCardOverlay != null) {
                        View.GONE
                    } else {
                        View.VISIBLE
                    }
            }
        }
        return START_STICKY
    }

    override fun onConfigurationChanged(newConfig: Configuration) {
        super.onConfigurationChanged(newConfig)
        val container = overlayContainer ?: return
        val params = overlayParams ?: return
        val wm = windowManager ?: return

        val screenW = resources.displayMetrics.widthPixels
        val screenH = resources.displayMetrics.heightPixels
        cachedScreenW = screenW
        cachedScreenH = screenH

        val iconSize = dp(52)
        val pad = dp(10)
        val windowSize = iconSize + pad * 2
        val peekOffset = dp(8)
        val prefs = getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
        val dockRight = prefs.getBoolean(KEY_DOCK_RIGHT, true)
        val minY = dp(56)
        val maxY = (screenH - windowSize - dp(86)).coerceAtLeast(minY)
        params.x = if (dockRight) (screenW - iconSize - pad + peekOffset) else (-pad - peekOffset)
        params.y = params.y.coerceIn(minY, maxY)
        try {
            wm.updateViewLayout(container, params)
            prefs.edit().putInt(KEY_Y_POS, params.y).apply()
        } catch (_: Exception) {}
    }

    override fun onDestroy() {
        isRunning = false
        Choreographer.getInstance().removeFrameCallback(dragFrameCallback)
        dragFramePending = false
        isActivelyDragging = false
        dockAnimator?.cancel()
        dockAnimator = null
        dismissWheelOverlay(restoreNub = false)
        dismissVoiceOverlay(restoreNub = false)
        dismissActiveCard(restoreNub = false)
        dismissHudBanner()
        mainHandler.removeCallbacksAndMessages(null)
        try {
            cameraManager?.unregisterTorchCallback(torchCallback)
        } catch (_: Exception) {}
        removeOverlayView()
        super.onDestroy()
    }

    private fun ensureForegroundNotification() {
        val nm = getSystemService(Context.NOTIFICATION_SERVICE) as? NotificationManager
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O && nm != null) {
            val channel = NotificationChannel(
                CHANNEL_ID,
                "KODARI 桌面懸浮球",
                NotificationManager.IMPORTANCE_MIN
            ).apply {
                description = "待機 0% CPU 全域快捷懸浮圖釘，關閉設定可停用"
                setShowBadge(false)
            }
            nm.createNotificationChannel(channel)
        }

        val launchIntent = Intent(this, MainActivity::class.java).apply {
            action = INTENT_ACTION_OPEN_WHEEL
            flags = Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP
        }
        val pi = PendingIntent.getActivity(
            this,
            0,
            launchIntent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )

        val builder = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            Notification.Builder(this, CHANNEL_ID)
        } else {
            @Suppress("DEPRECATION")
            Notification.Builder(this)
        }
        val notification = builder
            .setContentTitle("KODARI 小白點待命中")
            .setContentText("點擊桌面球原地開金色輪盤 • 長按直接語音")
            .setSmallIcon(R.drawable.ic_stat_hako)
            .setContentIntent(pi)
            .setOngoing(true)
            .build()

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
            val hasMic = ContextCompat.checkSelfPermission(
                this,
                Manifest.permission.RECORD_AUDIO
            ) == PackageManager.PERMISSION_GRANTED
            val hasLoc = ContextCompat.checkSelfPermission(
                this,
                Manifest.permission.ACCESS_FINE_LOCATION
            ) == PackageManager.PERMISSION_GRANTED || ContextCompat.checkSelfPermission(
                this,
                Manifest.permission.ACCESS_COARSE_LOCATION
            ) == PackageManager.PERMISSION_GRANTED

            var preferredType = ServiceInfo.FOREGROUND_SERVICE_TYPE_SPECIAL_USE
            if (hasMic) {
                preferredType = preferredType or ServiceInfo.FOREGROUND_SERVICE_TYPE_MICROPHONE
            }
            if (hasLoc) {
                preferredType = preferredType or ServiceInfo.FOREGROUND_SERVICE_TYPE_LOCATION
            }
            try {
                startForeground(NOTIF_ID, notification, preferredType)
            } catch (_: SecurityException) {
                startForeground(
                    NOTIF_ID,
                    notification,
                    ServiceInfo.FOREGROUND_SERVICE_TYPE_SPECIAL_USE
                )
            }
        } else {
            startForeground(NOTIF_ID, notification)
        }
    }

    private fun stopForegroundCompat() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) {
            stopForeground(STOP_FOREGROUND_REMOVE)
        } else {
            @Suppress("DEPRECATION")
            stopForeground(true)
        }
    }

    private fun dp(value: Int): Int {
        return (value * resources.displayMetrics.density).toInt()
    }

    private fun dpF(value: Float): Float {
        return value * resources.displayMetrics.density
    }

    @SuppressLint("ClickableViewAccessibility")
    private fun ensureOverlayView() {
        if (overlayContainer != null || windowManager == null) return

        val iconSize = dp(52)
        val pad = dp(10)
        val windowSize = iconSize + pad * 2
        val screenWidth = resources.displayMetrics.widthPixels
        val screenHeight = resources.displayMetrics.heightPixels

        val prefs = getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
        val dockRight = prefs.getBoolean(KEY_DOCK_RIGHT, true)
        val minY = dp(56)
        val maxY = (screenHeight - windowSize - dp(86)).coerceAtLeast(minY)
        val savedY = prefs.getInt(KEY_Y_POS, (screenHeight * 0.62f).toInt())
            .coerceIn(minY, maxY)

        val peekOffset = dp(8)
        val startX = if (dockRight) (screenWidth - iconSize - pad + peekOffset) else (-pad - peekOffset)

        val params = WindowManager.LayoutParams(
            windowSize,
            windowSize,
            WindowManager.LayoutParams.TYPE_APPLICATION_OVERLAY,
            WindowManager.LayoutParams.FLAG_NOT_FOCUSABLE or
                WindowManager.LayoutParams.FLAG_LAYOUT_NO_LIMITS or
                WindowManager.LayoutParams.FLAG_HARDWARE_ACCELERATED,
            PixelFormat.TRANSLUCENT
        ).apply {
            gravity = Gravity.TOP or Gravity.START
            x = startX
            y = savedY
        }

        val container = FrameLayout(this).apply {
            clipChildren = false
            clipToPadding = false
        }
        val img = ImageView(this).apply {
            setImageResource(R.drawable.kodari_nub_0)
            scaleType = ImageView.ScaleType.FIT_CENTER
            alpha = IDLE_ALPHA
        }
        container.addView(
            img,
            FrameLayout.LayoutParams(iconSize, iconSize, Gravity.CENTER)
        )

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            container.addOnLayoutChangeListener { v, _, _, _, _, _, _, _, _ ->
                if (v.width > 0 && v.height > 0) {
                    v.systemGestureExclusionRects = listOf(Rect(0, 0, v.width, v.height))
                }
            }
        }

        val touchSlop = ViewConfiguration.get(this).scaledTouchSlop
        var initialX = 0
        var initialY = 0
        var downRawX = 0f
        var downRawY = 0f
        var isDragging = false
        var longPressTriggered = false

        val longPressRunnable = Runnable {
            longPressTriggered = true
            isActivelyDragging = false
            Choreographer.getInstance().removeFrameCallback(dragFrameCallback)
            dragFramePending = false
            img.animate()
                .scaleX(1.0f)
                .scaleY(1.0f)
                .alpha(IDLE_ALPHA)
                .setDuration(120L)
                .start()
            vibrateShort(55L)
            showVoiceOverlay()
        }

        container.setOnTouchListener { _, event ->
            val p = overlayParams ?: return@setOnTouchListener false
            when (event.actionMasked) {
                MotionEvent.ACTION_DOWN -> {
                    dockAnimator?.cancel()
                    Choreographer.getInstance().removeFrameCallback(dragFrameCallback)
                    dragFramePending = false
                    isActivelyDragging = false
                    cachedScreenW = resources.displayMetrics.widthPixels
                    cachedScreenH = resources.displayMetrics.heightPixels
                    initialX = p.x
                    initialY = p.y
                    downRawX = event.rawX
                    downRawY = event.rawY
                    isDragging = false
                    longPressTriggered = false
                    vibrateShort(12L)
                    img.animate()
                        .scaleX(1.15f)
                        .scaleY(1.15f)
                        .alpha(ACTIVE_ALPHA)
                        .setDuration(110L)
                        .start()
                    mainHandler.postDelayed(longPressRunnable, 460L)
                    true
                }
                MotionEvent.ACTION_MOVE -> {
                    val dx = event.rawX - downRawX
                    val dy = event.rawY - downRawY
                    if (!isDragging && (abs(dx) > touchSlop || abs(dy) > touchSlop)) {
                        isDragging = true
                        isActivelyDragging = true
                        mainHandler.removeCallbacks(longPressRunnable)
                    }
                    if (isDragging && !longPressTriggered) {
                        val minX = -pad - dp(12)
                        val maxX = (cachedScreenW - iconSize - pad + dp(12)).coerceAtLeast(minX)
                        val curMinY = dp(56)
                        val curMaxY = (cachedScreenH - windowSize - dp(80)).coerceAtLeast(curMinY)
                        pendingDragX = (initialX + dx.toInt()).coerceIn(minX, maxX)
                        pendingDragY = (initialY + dy.toInt()).coerceIn(curMinY, curMaxY)
                        if (!dragFramePending) {
                            dragFramePending = true
                            Choreographer.getInstance().postFrameCallback(dragFrameCallback)
                        }
                    }
                    true
                }
                MotionEvent.ACTION_UP, MotionEvent.ACTION_CANCEL -> {
                    mainHandler.removeCallbacks(longPressRunnable)
                    Choreographer.getInstance().removeFrameCallback(dragFrameCallback)
                    dragFramePending = false
                    val wasDragging = isDragging
                    isActivelyDragging = false

                    if (wasDragging && !longPressTriggered) {
                        val curW = if (cachedScreenW > 0) cachedScreenW else resources.displayMetrics.widthPixels
                        val curH = if (cachedScreenH > 0) cachedScreenH else resources.displayMetrics.heightPixels
                        val minX = -pad - dp(12)
                        val maxX = (curW - iconSize - pad + dp(12)).coerceAtLeast(minX)
                        val curMinY = dp(56)
                        val curMaxY = (curH - windowSize - dp(86)).coerceAtLeast(curMinY)

                        val startX = pendingDragX.coerceIn(minX, maxX)
                        val targetY = pendingDragY.coerceIn(curMinY, curMaxY)
                        p.x = startX
                        p.y = targetY

                        val centerX = startX + windowSize / 2
                        val snapRight = centerX >= curW / 2
                        val targetX = if (snapRight) (curW - iconSize - pad + peekOffset) else (-pad - peekOffset)

                        dockAnimator?.cancel()
                        var lastAppliedX = Int.MIN_VALUE
                        dockAnimator = ValueAnimator.ofInt(startX, targetX).apply {
                            duration = 220L
                            interpolator = OvershootInterpolator(0.85f)
                            addUpdateListener { va ->
                                val currP = overlayParams ?: return@addUpdateListener
                                val nextX = va.animatedValue as Int
                                if (nextX == lastAppliedX) return@addUpdateListener
                                lastAppliedX = nextX
                                currP.x = nextX
                                currP.y = targetY
                                try {
                                    windowManager?.updateViewLayout(container, currP)
                                } catch (_: Exception) {}
                            }
                            addListener(object : AnimatorListenerAdapter() {
                                override fun onAnimationEnd(animation: Animator) {
                                    img.animate()
                                        .scaleX(1.0f)
                                        .scaleY(1.0f)
                                        .alpha(IDLE_ALPHA)
                                        .setDuration(150L)
                                        .start()
                                    prefs.edit()
                                        .putBoolean(KEY_DOCK_RIGHT, snapRight)
                                        .putInt(KEY_Y_POS, targetY)
                                        .apply()
                                }
                            })
                            start()
                        }
                    } else {
                        img.animate()
                            .scaleX(1.0f)
                            .scaleY(1.0f)
                            .alpha(IDLE_ALPHA)
                            .setDuration(140L)
                            .start()
                        if (!longPressTriggered && event.actionMasked == MotionEvent.ACTION_UP) {
                            vibrateShort(20L)
                            showWheelOverlay()
                        }
                    }
                    true
                }
                else -> false
            }
        }

        try {
            windowManager?.addView(container, params)
            overlayContainer = container
            overlayParams = params
            spriteImage = img
        } catch (_: Exception) {
            overlayContainer = null
            overlayParams = null
            spriteImage = null
        }
    }

    private fun removeOverlayView() {
        Choreographer.getInstance().removeFrameCallback(dragFrameCallback)
        dragFramePending = false
        isActivelyDragging = false
        dockAnimator?.cancel()
        dockAnimator = null
        val view = overlayContainer ?: return
        try {
            windowManager?.removeView(view)
        } catch (_: Exception) {}
        overlayContainer = null
        overlayParams = null
        spriteImage = null
    }

    // -------------------------------------------------------------------------
    // Torch control (zero-app-launch native flashlight)
    // -------------------------------------------------------------------------

    private fun resolveTorchCameraId(): String? {
        val cm = cameraManager ?: return null
        return try {
            var fallback: String? = null
            for (id in cm.cameraIdList) {
                val chars = cm.getCameraCharacteristics(id)
                val hasFlash = chars.get(CameraCharacteristics.FLASH_INFO_AVAILABLE) == true
                val back = chars.get(CameraCharacteristics.LENS_FACING) == CameraCharacteristics.LENS_FACING_BACK
                if (hasFlash && back) return id
                if (hasFlash && fallback == null) fallback = id
            }
            fallback
        } catch (_: Exception) {
            null
        }
    }

    private fun setTorchNative(enable: Boolean): Boolean {
        val cm = cameraManager ?: return false
        val id = torchCameraId ?: resolveTorchCameraId()?.also { torchCameraId = it } ?: return false
        return try {
            cm.setTorchMode(id, enable)
            isTorchOn = enable
            true
        } catch (_: Exception) {
            false
        }
    }

    private fun toggleTorchNative(): Boolean {
        return setTorchNative(!isTorchOn)
    }

    // -------------------------------------------------------------------------
    // In-Place 6-Track Symmetrical Amber Radial Wheel Overlay (AssistiveTouch / GHOST)
    // -------------------------------------------------------------------------

    private fun readClipboardTextSafely(): String? {
        return try {
            val cm = getSystemService(Context.CLIPBOARD_SERVICE) as? ClipboardManager
            val clip = cm?.primaryClip
            if (clip == null || clip.itemCount == 0) null
            else clip.getItemAt(0)?.coerceToText(this)?.toString()
        } catch (_: Exception) {
            null
        }
    }

    private fun buildWheelTrack(actionId: String): WheelTrack {
        return when (actionId) {
            GhostActionRegistry.ID_TORCH -> WheelTrack(
                emoji = "🔦",
                label = if (isTorchOn) "手電筒 ON" else "手電筒",
                active = isTorchOn,
                isTorch = true
            ) {
                vibrateShort(25L)
                val ok = toggleTorchNative()
                val title = if (ok) {
                    if (isTorchOn) "手電筒已開啟" else "手電筒已關閉"
                } else {
                    "無法切換手電筒"
                }
                dismissWheelOverlay()
                showHudBanner(if (ok) "🔦" else "⚠️", title, durationMs = 2000L)
            }
            GhostActionRegistry.ID_LOCATION_SHARE -> WheelTrack("📍", "報位置", false) {
                dismissWheelOverlay()
                executors.executeLocationShare()
            }
            GhostActionRegistry.ID_CLIPBOARD_MEMO -> WheelTrack("📋", "貼入備忘", false) {
                // Capture clipboard BEFORE dismissing wheel so focused window can still read it on Android 10+.
                val clip = readClipboardTextSafely()
                dismissWheelOverlay()
                executors.executeClipboardMemo(clip)
            }
            GhostActionRegistry.ID_VOICE_MEMO -> WheelTrack("🎙️", "語音速記", false) {
                showVoiceOverlay(memoMode = true)
            }
            GhostActionRegistry.ID_LATEST_PHOTO -> WheelTrack("📷", "存最新照", false) {
                dismissWheelOverlay()
                executors.executeLatestPhoto()
            }
            GhostActionRegistry.ID_TODO_PEEK -> WheelTrack("📌", "今日待辦", false) {
                dismissWheelOverlay(restoreNub = false)
                executors.showTodoPeekCard()
            }
            GhostActionRegistry.ID_NEXT_ROUTINE -> WheelTrack("🕒", "下個排程", false) {
                dismissWheelOverlay(restoreNub = false)
                executors.showRoutinePeekCard()
            }
            GhostActionRegistry.ID_WEATHER_DOULIU -> WheelTrack("🌦️", "現地天氣", false) {
                dismissWheelOverlay()
                executors.executeWeatherDouliu()
            }
            GhostActionRegistry.ID_QUICK_TIMER -> WheelTrack("⏱️", "快速計時", false) {
                dismissWheelOverlay(restoreNub = false)
                executors.showQuickTimerCard()
            }
            GhostActionRegistry.ID_REFRESH_BOARDS -> WheelTrack("📡", "刷新戰情", false) {
                dismissWheelOverlay()
                executors.executeRefreshBoards()
            }
            GhostActionRegistry.ID_CALCULATOR -> WheelTrack("🧮", "計算機", false) {
                dismissWheelOverlay(restoreNub = false)
                executors.showMiniCalculatorCard()
            }
            GhostActionRegistry.ID_OPEN_CUTTING -> WheelTrack("🛠️", "鋁料切料", false) {
                dismissWheelOverlay()
                launchMainWithAction(INTENT_ACTION_OPEN_CUTTING)
            }
            GhostActionRegistry.ID_OPEN_ROOMS -> WheelTrack("📂", "案場工單", false) {
                dismissWheelOverlay()
                launchMainWithAction(INTENT_ACTION_OPEN_ROOMS)
            }
            GhostActionRegistry.ID_OPEN_TEXT -> WheelTrack("⌨️", "開啟對話", false) {
                dismissWheelOverlay()
                launchMainWithAction(INTENT_ACTION_OPEN_TEXT)
            }
            else -> WheelTrack("📌", "今日待辦", false) {
                dismissWheelOverlay(restoreNub = false)
                executors.showTodoPeekCard()
            }
        }
    }

    private fun showWheelOverlay() {
        val wm = windowManager ?: return
        if (!Settings.canDrawOverlays(this)) return

        dismissVoiceOverlay(restoreNub = false)
        dismissActiveCard(restoreNub = false)
        dismissWheelOverlay(restoreNub = false)
        overlayContainer?.visibility = View.GONE

        val root = object : FrameLayout(this) {
            override fun dispatchKeyEvent(event: KeyEvent): Boolean {
                if (event.keyCode == KeyEvent.KEYCODE_BACK && event.action == KeyEvent.ACTION_UP) {
                    dismissWheelOverlay()
                    return true
                }
                return super.dispatchKeyEvent(event)
            }
        }.apply {
            setBackgroundColor(Color.argb(163, 0, 0, 0))
            isFocusable = true
            isFocusableInTouchMode = true
            setOnClickListener { dismissWheelOverlay() }
        }

        val contentColumn = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            gravity = Gravity.CENTER_HORIZONTAL
            clipChildren = false
            clipToPadding = false
            setOnClickListener { /* absorb tap inside wheel area */ }
        }

        val wheelSizePx = dp(316)
        val wheelBox = FrameLayout(this).apply {
            clipChildren = false
            clipToPadding = false
        }

        // Outer amber glow ring (268dp)
        val outerRing = View(this).apply {
            background = GradientDrawable().apply {
                shape = GradientDrawable.OVAL
                setColor(Color.parseColor("#BF151821"))
                setStroke(dpF(1.5f).toInt().coerceAtLeast(1), Color.parseColor("#73F59E0B"))
            }
        }
        wheelBox.addView(outerRing, FrameLayout.LayoutParams(dp(268), dp(268), Gravity.CENTER))

        // Inner orbital ring (122dp)
        val innerRing = View(this).apply {
            background = GradientDrawable().apply {
                shape = GradientDrawable.OVAL
                setColor(Color.parseColor("#28F59E0B"))
                setStroke(dpF(1.5f).toInt().coerceAtLeast(1), Color.parseColor("#8CFCD34D"))
            }
        }
        wheelBox.addView(innerRing, FrameLayout.LayoutParams(dp(122), dp(122), Gravity.CENTER))

        // 6 customizable symmetrical orbital action pucks (60° exact hexagon)
        val radiusPx = dp(114)
        val puckW = dp(74)
        val puckH = dp(60)
        val prefs = getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
        val tracks = GhostActionRegistry.loadSlots(prefs).map { buildWheelTrack(it) }

        wheelTorchLabel = null
        tracks.forEachIndexed { i, track ->
            val angle = -Math.PI / 2.0 + (2.0 * Math.PI * i / tracks.size)
            val cx = wheelSizePx / 2.0 + radiusPx * cos(angle)
            val cy = wheelSizePx / 2.0 + radiusPx * sin(angle)

            val puck = LinearLayout(this).apply {
                orientation = LinearLayout.VERTICAL
                gravity = Gravity.CENTER
                background = GradientDrawable().apply {
                    shape = GradientDrawable.RECTANGLE
                    cornerRadius = dpF(16f)
                    setColor(
                        if (track.active) Color.parseColor("#45F59E0B")
                        else Color.parseColor("#F01B1F2A")
                    )
                    setStroke(
                        dpF(if (track.active) 1.6f else 1.1f).toInt().coerceAtLeast(1),
                        if (track.active) Color.parseColor("#FCD34D")
                        else Color.parseColor("#6BF59E0B")
                    )
                }
                elevation = dpF(6f)
                setOnClickListener {
                    vibrateShort(16L)
                    track.onTap()
                }
            }

            val emojiView = TextView(this).apply {
                text = track.emoji
                setTextSize(TypedValue.COMPLEX_UNIT_SP, 18f)
                gravity = Gravity.CENTER
            }
            val labelView = TextView(this).apply {
                text = track.label
                setTextSize(TypedValue.COMPLEX_UNIT_SP, 10.5f)
                setTextColor(if (track.active) Color.WHITE else Color.parseColor("#E5E7EB"))
                paint.isFakeBoldText = true
                gravity = Gravity.CENTER
                maxLines = 1
                ellipsize = TextUtils.TruncateAt.END
            }
            if (track.isTorch) {
                wheelTorchLabel = labelView
            }

            puck.addView(emojiView)
            puck.addView(labelView)

            val lp = FrameLayout.LayoutParams(puckW, puckH, Gravity.TOP or Gravity.START).apply {
                leftMargin = (cx - puckW / 2.0).toInt()
                topMargin = (cy - puckH / 2.0).toInt()
            }
            wheelBox.addView(puck, lp)
        }

        // Center Kodari medallion (Tap -> directly enter in-place voice HUD)
        val centerFrame = FrameLayout(this).apply {
            background = GradientDrawable().apply {
                shape = GradientDrawable.OVAL
                setColor(Color.parseColor("#FF171A23"))
                setStroke(dp(2), Color.parseColor("#CCFCD34D"))
            }
            elevation = dpF(10f)
            setOnClickListener {
                vibrateShort(35L)
                showVoiceOverlay()
            }
        }

        val centerAnimDrawable = buildKodariAnimationDrawable()
        wheelSpriteAnim = centerAnimDrawable
        val centerImg = ImageView(this).apply {
            setImageDrawable(centerAnimDrawable)
            scaleType = ImageView.ScaleType.FIT_CENTER
        }
        centerFrame.addView(centerImg, FrameLayout.LayoutParams(dp(68), dp(68), Gravity.CENTER))
        wheelBox.addView(centerFrame, FrameLayout.LayoutParams(dp(92), dp(92), Gravity.CENTER))

        contentColumn.addView(wheelBox, LinearLayout.LayoutParams(wheelSizePx, wheelSizePx))

        val hintBadge = TextView(this).apply {
            text = "六軌免開捷徑 • 點中央可達直接說話"
            setTextSize(TypedValue.COMPLEX_UNIT_SP, 12f)
            setTextColor(Color.parseColor("#FDE68A"))
            paint.isFakeBoldText = true
            setPadding(dp(16), dp(7), dp(16), dp(7))
            background = GradientDrawable().apply {
                shape = GradientDrawable.RECTANGLE
                cornerRadius = dpF(99f)
                setColor(Color.parseColor("#F0161922"))
                setStroke(dp(1), Color.parseColor("#8CF59E0B"))
            }
        }
        val hintLp = LinearLayout.LayoutParams(
            LinearLayout.LayoutParams.WRAP_CONTENT,
            LinearLayout.LayoutParams.WRAP_CONTENT
        ).apply {
            topMargin = dp(14)
        }
        contentColumn.addView(hintBadge, hintLp)

        root.addView(
            contentColumn,
            FrameLayout.LayoutParams(
                FrameLayout.LayoutParams.WRAP_CONTENT,
                FrameLayout.LayoutParams.WRAP_CONTENT,
                Gravity.CENTER
            )
        )

        contentColumn.scaleX = 0.78f
        contentColumn.scaleY = 0.78f
        contentColumn.alpha = 0f

        val params = WindowManager.LayoutParams(
            WindowManager.LayoutParams.MATCH_PARENT,
            WindowManager.LayoutParams.MATCH_PARENT,
            WindowManager.LayoutParams.TYPE_APPLICATION_OVERLAY,
            WindowManager.LayoutParams.FLAG_HARDWARE_ACCELERATED or
                WindowManager.LayoutParams.FLAG_LAYOUT_IN_SCREEN,
            PixelFormat.TRANSLUCENT
        ).apply {
            gravity = Gravity.TOP or Gravity.START
        }

        try {
            wm.addView(root, params)
            wheelOverlay = root
            root.requestFocus()
            root.post {
                centerAnimDrawable.start()
                contentColumn.animate()
                    .scaleX(1.0f)
                    .scaleY(1.0f)
                    .alpha(1.0f)
                    .setDuration(190L)
                    .setInterpolator(OvershootInterpolator(1.1f))
                    .start()
            }
        } catch (_: Exception) {
            wheelSpriteAnim = null
            wheelTorchLabel = null
            wheelOverlay = null
            if (!isAppForeground) {
                overlayContainer?.visibility = View.VISIBLE
            }
        }
    }

    private fun dismissWheelOverlay(restoreNub: Boolean = true) {
        wheelSpriteAnim?.stop()
        wheelSpriteAnim = null
        wheelTorchLabel = null
        val view = wheelOverlay ?: run {
            if (restoreNub && !isAppForeground && voiceOverlay == null && activeCardOverlay == null) {
                overlayContainer?.visibility = View.VISIBLE
            }
            return
        }
        wheelOverlay = null
        try {
            windowManager?.removeView(view)
        } catch (_: Exception) {}
        if (restoreNub && !isAppForeground && voiceOverlay == null && activeCardOverlay == null) {
            overlayContainer?.visibility = View.VISIBLE
        }
    }

    // -------------------------------------------------------------------------
    // In-Place Card Overlays & Dark-Gold Floating HUD Banner
    // -------------------------------------------------------------------------

    internal fun presentCardOverlay(cardContent: View) {
        val wm = windowManager ?: return
        if (!Settings.canDrawOverlays(this)) return

        dismissWheelOverlay(restoreNub = false)
        dismissVoiceOverlay(restoreNub = false)
        dismissActiveCard(restoreNub = false)
        overlayContainer?.visibility = View.GONE

        val root = object : FrameLayout(this) {
            override fun dispatchKeyEvent(event: KeyEvent): Boolean {
                if (event.keyCode == KeyEvent.KEYCODE_BACK && event.action == KeyEvent.ACTION_UP) {
                    dismissActiveCard()
                    return true
                }
                return super.dispatchKeyEvent(event)
            }
        }.apply {
            setBackgroundColor(Color.argb(165, 0, 0, 0))
            isFocusable = true
            isFocusableInTouchMode = true
            setOnClickListener { dismissActiveCard() }
        }

        val cardLp = FrameLayout.LayoutParams(
            cardContent.layoutParams?.width ?: FrameLayout.LayoutParams.WRAP_CONTENT,
            FrameLayout.LayoutParams.WRAP_CONTENT,
            Gravity.CENTER
        )
        root.addView(cardContent, cardLp)
        cardContent.scaleX = 0.88f
        cardContent.scaleY = 0.88f
        cardContent.alpha = 0f

        val params = WindowManager.LayoutParams(
            WindowManager.LayoutParams.MATCH_PARENT,
            WindowManager.LayoutParams.MATCH_PARENT,
            WindowManager.LayoutParams.TYPE_APPLICATION_OVERLAY,
            WindowManager.LayoutParams.FLAG_HARDWARE_ACCELERATED or
                WindowManager.LayoutParams.FLAG_LAYOUT_IN_SCREEN,
            PixelFormat.TRANSLUCENT
        ).apply {
            gravity = Gravity.TOP or Gravity.START
        }

        try {
            wm.addView(root, params)
            activeCardOverlay = root
            root.requestFocus()
            root.post {
                cardContent.animate()
                    .scaleX(1.0f)
                    .scaleY(1.0f)
                    .alpha(1.0f)
                    .setDuration(170L)
                    .setInterpolator(OvershootInterpolator(1.05f))
                    .start()
            }
        } catch (_: Exception) {
            activeCardOverlay = null
            if (!isAppForeground) {
                overlayContainer?.visibility = View.VISIBLE
            }
        }
    }

    internal fun dismissActiveCard(restoreNub: Boolean = true) {
        val view = activeCardOverlay ?: run {
            if (restoreNub && !isAppForeground && wheelOverlay == null && voiceOverlay == null) {
                overlayContainer?.visibility = View.VISIBLE
            }
            return
        }
        activeCardOverlay = null
        try {
            windowManager?.removeView(view)
        } catch (_: Exception) {}
        if (restoreNub && !isAppForeground && wheelOverlay == null && voiceOverlay == null) {
            overlayContainer?.visibility = View.VISIBLE
        }
    }

    internal fun showHudBanner(
        emoji: String,
        title: String,
        subtitle: String = "",
        thumb: Bitmap? = null,
        durationMs: Long = 3200L
    ) {
        val wm = windowManager ?: run {
            thumb?.recycle()
            return
        }
        if (!Settings.canDrawOverlays(this)) {
            thumb?.recycle()
            return
        }

        dismissHudBanner()

        val root = FrameLayout(this).apply {
            setPadding(dp(12), dp(8), dp(12), dp(8))
        }

        val pill = LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER_VERTICAL
            setPadding(dp(14), dp(10), dp(14), dp(10))
            background = GradientDrawable().apply {
                shape = GradientDrawable.RECTANGLE
                cornerRadius = dpF(18f)
                setColor(Color.parseColor("#F5171A23"))
                setStroke(dpF(1.4f).toInt().coerceAtLeast(1), Color.parseColor("#B3F59E0B"))
            }
            elevation = dpF(10f)
            setOnClickListener { dismissHudBanner() }
        }

        if (thumb != null && !thumb.isRecycled) {
            hudThumbBitmap = thumb
            val thumbView = ImageView(this).apply {
                setImageBitmap(thumb)
                scaleType = ImageView.ScaleType.CENTER_CROP
                clipToOutline = true
                outlineProvider = object : ViewOutlineProvider() {
                    override fun getOutline(view: View, outline: Outline) {
                        outline.setRoundRect(0, 0, view.width, view.height, dpF(10f))
                    }
                }
            }
            pill.addView(thumbView, LinearLayout.LayoutParams(dp(50), dp(50)).apply {
                rightMargin = dp(11)
            })
        } else {
            val emojiTv = TextView(this).apply {
                text = emoji
                setTextSize(TypedValue.COMPLEX_UNIT_SP, 20f)
            }
            pill.addView(emojiTv, LinearLayout.LayoutParams(
                LinearLayout.LayoutParams.WRAP_CONTENT,
                LinearLayout.LayoutParams.WRAP_CONTENT
            ).apply { rightMargin = dp(10) })
        }

        val textCol = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
        }
        val titleTv = TextView(this).apply {
            text = title
            setTextSize(TypedValue.COMPLEX_UNIT_SP, 13.5f)
            setTextColor(Color.parseColor("#FCD34D"))
            paint.isFakeBoldText = true
            maxLines = 2
            ellipsize = TextUtils.TruncateAt.END
        }
        textCol.addView(titleTv)
        if (subtitle.isNotBlank()) {
            val subTv = TextView(this).apply {
                text = subtitle
                setTextSize(TypedValue.COMPLEX_UNIT_SP, 11.5f)
                setTextColor(Color.parseColor("#E5E7EB"))
                maxLines = 3
                ellipsize = TextUtils.TruncateAt.END
            }
            textCol.addView(subTv, LinearLayout.LayoutParams(
                LinearLayout.LayoutParams.WRAP_CONTENT,
                LinearLayout.LayoutParams.WRAP_CONTENT
            ).apply { topMargin = dp(2) })
        }
        pill.addView(textCol, LinearLayout.LayoutParams(
            LinearLayout.LayoutParams.WRAP_CONTENT,
            LinearLayout.LayoutParams.WRAP_CONTENT
        ))

        val maxW = (resources.displayMetrics.widthPixels - dp(28)).coerceAtMost(dp(360))
        root.addView(pill, FrameLayout.LayoutParams(maxW, FrameLayout.LayoutParams.WRAP_CONTENT))

        val params = WindowManager.LayoutParams(
            WindowManager.LayoutParams.WRAP_CONTENT,
            WindowManager.LayoutParams.WRAP_CONTENT,
            WindowManager.LayoutParams.TYPE_APPLICATION_OVERLAY,
            WindowManager.LayoutParams.FLAG_NOT_FOCUSABLE or
                WindowManager.LayoutParams.FLAG_HARDWARE_ACCELERATED,
            PixelFormat.TRANSLUCENT
        ).apply {
            gravity = Gravity.TOP or Gravity.CENTER_HORIZONTAL
            y = dp(46)
        }

        pill.translationY = -dpF(14f)
        pill.alpha = 0f

        try {
            wm.addView(root, params)
            hudBannerOverlay = root
            pill.animate()
                .translationY(0f)
                .alpha(1.0f)
                .setDuration(180L)
                .start()
            val dismissTask = Runnable { dismissHudBanner() }
            hudDismissRunnable = dismissTask
            mainHandler.postDelayed(dismissTask, durationMs)
        } catch (_: Exception) {
            hudThumbBitmap?.recycle()
            hudThumbBitmap = null
            hudBannerOverlay = null
        }
    }

    private fun dismissHudBanner() {
        hudDismissRunnable?.let { mainHandler.removeCallbacks(it) }
        hudDismissRunnable = null
        val view = hudBannerOverlay
        hudBannerOverlay = null
        if (view != null) {
            try {
                windowManager?.removeView(view)
            } catch (_: Exception) {}
        }
        val bmp = hudThumbBitmap
        hudThumbBitmap = null
        if (bmp != null && !bmp.isRecycled) {
            bmp.recycle()
        }
    }

    // -------------------------------------------------------------------------
    // In-Place Desktop Voice HUD + Native SpeechRecognizer
    // -------------------------------------------------------------------------

    private fun showVoiceOverlay(memoMode: Boolean = false) {
        val hasMic = ContextCompat.checkSelfPermission(
            this,
            Manifest.permission.RECORD_AUDIO
        ) == PackageManager.PERMISSION_GRANTED
        if (!hasMic || !SpeechRecognizer.isRecognitionAvailable(this)) {
            dismissWheelOverlay(restoreNub = false)
            dismissVoiceOverlay(restoreNub = true)
            launchMainWithAction(INTENT_ACTION_VOICE_DIRECT)
            return
        }

        val wm = windowManager ?: return
        if (!Settings.canDrawOverlays(this)) return

        dismissWheelOverlay(restoreNub = false)
        dismissActiveCard(restoreNub = false)
        dismissVoiceOverlay(restoreNub = false)
        overlayContainer?.visibility = View.GONE

        voiceMemoMode = memoMode
        lastVoicePartial = ""
        voiceHandlingResult = false

        val root = object : FrameLayout(this) {
            override fun dispatchKeyEvent(event: KeyEvent): Boolean {
                if (event.keyCode == KeyEvent.KEYCODE_BACK && event.action == KeyEvent.ACTION_UP) {
                    dismissVoiceOverlay()
                    return true
                }
                return super.dispatchKeyEvent(event)
            }
        }.apply {
            setBackgroundColor(Color.argb(175, 0, 0, 0))
            isFocusable = true
            isFocusableInTouchMode = true
            setOnClickListener { dismissVoiceOverlay() }
        }

        val column = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            gravity = Gravity.CENTER_HORIZONTAL
            clipChildren = false
            clipToPadding = false
            setOnClickListener { /* absorb tap inside HUD */ }
        }

        val bubble = TextView(this).apply {
            text = if (voiceMemoMode) "🎙️ 語音速記…\n請說要記下的內容" else "🎙️ 我在聽…\n請說指令"
            setTextSize(TypedValue.COMPLEX_UNIT_SP, 15f)
            setTextColor(Color.WHITE)
            paint.isFakeBoldText = true
            gravity = Gravity.CENTER
            setLineSpacing(dpF(3f), 1.0f)
            setPadding(dp(20), dp(12), dp(20), dp(12))
            maxWidth = dp(300)
            background = GradientDrawable().apply {
                shape = GradientDrawable.RECTANGLE
                cornerRadius = dpF(20f)
                setColor(Color.parseColor("#F2171A23"))
                setStroke(dpF(1.5f).toInt().coerceAtLeast(1), Color.parseColor("#BFF59E0B"))
            }
        }
        voiceBubbleText = bubble
        column.addView(bubble)

        val waveStage = FrameLayout(this).apply {
            clipChildren = false
            clipToPadding = false
        }
        val waveView = AmberSoundwaveView(this)
        soundwaveView = waveView
        waveStage.addView(waveView, FrameLayout.LayoutParams(dp(300), dp(90), Gravity.CENTER))

        val centerMedallion = FrameLayout(this).apply {
            background = GradientDrawable().apply {
                shape = GradientDrawable.OVAL
                setColor(Color.parseColor("#FF151821"))
                setStroke(dp(2), Color.parseColor("#FFFCD34D"))
            }
            elevation = dpF(10f)
        }
        val spriteAnim = buildKodariAnimationDrawable()
        voiceSpriteAnim = spriteAnim
        val spriteView = ImageView(this).apply {
            setImageDrawable(spriteAnim)
            scaleType = ImageView.ScaleType.FIT_CENTER
        }
        centerMedallion.addView(spriteView, FrameLayout.LayoutParams(dp(72), dp(72), Gravity.CENTER))
        waveStage.addView(centerMedallion, FrameLayout.LayoutParams(dp(96), dp(96), Gravity.CENTER))

        val stageLp = LinearLayout.LayoutParams(dp(300), dp(120)).apply {
            topMargin = dp(18)
        }
        column.addView(waveStage, stageLp)

        val statusPill = TextView(this).apply {
            text = if (voiceMemoMode) {
                "原地語音速記 • 說完自動存待辦（不開 App）"
            } else {
                "語音聆聽中（系統原生辨識 • 原地執行）"
            }
            setTextSize(TypedValue.COMPLEX_UNIT_SP, 11.5f)
            setTextColor(Color.parseColor("#FDE68A"))
            paint.isFakeBoldText = true
            setPadding(dp(14), dp(6), dp(14), dp(6))
            background = GradientDrawable().apply {
                shape = GradientDrawable.RECTANGLE
                cornerRadius = dpF(99f)
                setColor(Color.parseColor("#F0161922"))
                setStroke(dp(1), Color.parseColor("#80F59E0B"))
            }
        }
        val statusLp = LinearLayout.LayoutParams(
            LinearLayout.LayoutParams.WRAP_CONTENT,
            LinearLayout.LayoutParams.WRAP_CONTENT
        ).apply {
            topMargin = dp(14)
        }
        column.addView(statusPill, statusLp)

        val actionRow = LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER
        }
        val finishBtn = buildVoiceActionPill("✅ 說完了", "#1F2937", "#34D399") {
            vibrateShort(20L)
            desktopSpeechRecognizer?.stopListening()
        }
        val cancelBtn = buildVoiceActionPill("✕ 取消", "#1F2937", "#FB7185") {
            vibrateShort(15L)
            dismissVoiceOverlay()
        }
        actionRow.addView(finishBtn, LinearLayout.LayoutParams(
            LinearLayout.LayoutParams.WRAP_CONTENT,
            LinearLayout.LayoutParams.WRAP_CONTENT
        ).apply { rightMargin = dp(12) })
        actionRow.addView(cancelBtn)

        column.addView(actionRow, LinearLayout.LayoutParams(
            LinearLayout.LayoutParams.WRAP_CONTENT,
            LinearLayout.LayoutParams.WRAP_CONTENT
        ).apply { topMargin = dp(16) })

        root.addView(
            column,
            FrameLayout.LayoutParams(
                FrameLayout.LayoutParams.WRAP_CONTENT,
                FrameLayout.LayoutParams.WRAP_CONTENT,
                Gravity.CENTER
            )
        )

        val params = WindowManager.LayoutParams(
            WindowManager.LayoutParams.MATCH_PARENT,
            WindowManager.LayoutParams.MATCH_PARENT,
            WindowManager.LayoutParams.TYPE_APPLICATION_OVERLAY,
            WindowManager.LayoutParams.FLAG_HARDWARE_ACCELERATED or
                WindowManager.LayoutParams.FLAG_LAYOUT_IN_SCREEN,
            PixelFormat.TRANSLUCENT
        ).apply {
            gravity = Gravity.TOP or Gravity.START
        }

        try {
            wm.addView(root, params)
            voiceOverlay = root
            root.requestFocus()
            root.post {
                spriteAnim.start()
                waveView.startWave()
                startDesktopSpeechRecognizer()
            }
        } catch (_: Exception) {
            dismissVoiceOverlay()
            launchMainWithAction(INTENT_ACTION_VOICE_DIRECT)
        }
    }

    private fun buildVoiceActionPill(
        label: String,
        bgHex: String,
        strokeHex: String,
        onClick: () -> Unit
    ): TextView {
        return TextView(this).apply {
            text = label
            setTextSize(TypedValue.COMPLEX_UNIT_SP, 12.5f)
            setTextColor(Color.WHITE)
            paint.isFakeBoldText = true
            setPadding(dp(18), dp(8), dp(18), dp(8))
            background = GradientDrawable().apply {
                shape = GradientDrawable.RECTANGLE
                cornerRadius = dpF(99f)
                setColor(Color.parseColor(bgHex))
                setStroke(dp(1), Color.parseColor(strokeHex))
            }
            setOnClickListener { onClick() }
        }
    }

    private fun startDesktopSpeechRecognizer() {
        try {
            desktopSpeechRecognizer?.destroy()
        } catch (_: Exception) {}
        desktopSpeechRecognizer = null

        val sr = try {
            SpeechRecognizer.createSpeechRecognizer(this)
        } catch (_: Exception) {
            null
        }
        if (sr == null) {
            dismissVoiceOverlay()
            launchMainWithAction(INTENT_ACTION_VOICE_DIRECT)
            return
        }
        desktopSpeechRecognizer = sr

        val watchdog = Runnable {
            if (voiceOverlay == null || voiceHandlingResult) return@Runnable
            val fallbackText = lastVoicePartial.trim()
            if (fallbackText.isNotEmpty()) {
                handleDesktopVoiceResult(fallbackText)
            } else {
                dismissVoiceOverlay()
            }
        }
        voiceWatchdogRunnable = watchdog
        mainHandler.postDelayed(watchdog, 15_000L)

        sr.setRecognitionListener(object : RecognitionListener {
            override fun onReadyForSpeech(params: Bundle?) {}
            override fun onBeginningOfSpeech() {}
            override fun onRmsChanged(rmsdB: Float) {
                val normalized = ((rmsdB + 2f) / 12f).coerceIn(0f, 1f)
                soundwaveView?.setRmsLevel(normalized)
            }

            override fun onBufferReceived(buffer: ByteArray?) {}
            override fun onEndOfSpeech() {
                soundwaveView?.setRmsLevel(0.15f)
            }

            override fun onError(error: Int) {
                cancelVoiceWatchdog()
                if (voiceOverlay == null || voiceHandlingResult) return
                if (error == SpeechRecognizer.ERROR_INSUFFICIENT_PERMISSIONS ||
                    error == SpeechRecognizer.ERROR_CLIENT
                ) {
                    dismissVoiceOverlay()
                    launchMainWithAction(INTENT_ACTION_VOICE_DIRECT)
                    return
                }
                val partial = lastVoicePartial.trim()
                if ((error == SpeechRecognizer.ERROR_NO_MATCH ||
                        error == SpeechRecognizer.ERROR_SPEECH_TIMEOUT) &&
                    partial.isNotEmpty()
                ) {
                    handleDesktopVoiceResult(partial)
                    return
                }
                voiceBubbleText?.text = "🎙️ 沒有聽清楚\n請再試一次"
                scheduleDelayedVoiceDismiss(800L)
            }

            override fun onResults(results: Bundle?) {
                cancelVoiceWatchdog()
                if (voiceOverlay == null || voiceHandlingResult) return
                val list = results?.getStringArrayList(SpeechRecognizer.RESULTS_RECOGNITION)
                val finalText = (list?.firstOrNull() ?: "").trim().ifEmpty { lastVoicePartial.trim() }
                if (finalText.isEmpty()) {
                    voiceBubbleText?.text = "🎙️ 沒有聽清楚\n請再試一次"
                    scheduleDelayedVoiceDismiss(750L)
                } else {
                    handleDesktopVoiceResult(finalText)
                }
            }

            override fun onPartialResults(partialResults: Bundle?) {
                val list = partialResults?.getStringArrayList(SpeechRecognizer.RESULTS_RECOGNITION)
                val text = (list?.firstOrNull() ?: "").trim()
                if (text.isNotEmpty()) {
                    lastVoicePartial = text
                    voiceBubbleText?.text = text
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
            cancelVoiceWatchdog()
            dismissVoiceOverlay()
            launchMainWithAction(INTENT_ACTION_VOICE_DIRECT)
        }
    }

    private fun cancelVoiceWatchdog() {
        voiceWatchdogRunnable?.let { mainHandler.removeCallbacks(it) }
        voiceWatchdogRunnable = null
    }

    private fun scheduleDelayedVoiceDismiss(delayMs: Long) {
        voiceDismissRunnable?.let { mainHandler.removeCallbacks(it) }
        val r = Runnable { dismissVoiceOverlay() }
        voiceDismissRunnable = r
        mainHandler.postDelayed(r, delayMs)
    }

    private fun handleDesktopVoiceResult(rawText: String) {
        val text = rawText.trim()
        if (text.isEmpty()) {
            dismissVoiceOverlay()
            return
        }
        voiceHandlingResult = true
        if (voiceMemoMode) {
            saveVoiceMemoInPlace(text)
            return
        }
        if (tryHandleDesktopVoiceFastPath(text)) {
            return
        }
        dismissVoiceOverlay(restoreNub = false)
        launchMainWithAction(INTENT_ACTION_SPOKEN_TEXT, spokenText = text)
    }

    private fun saveVoiceMemoInPlace(text: String) {
        voiceBubbleText?.text = "⏳ 寫入大廳待辦…"
        Thread {
            val res = GhostLocalStore.appendMainTodo(this, text)
            mainHandler.post {
                if (res.ok) {
                    vibrateShort(24L)
                    voiceBubbleText?.text = if (res.duplicate) {
                        "📋 已存在待辦：\n${res.cleanedText}"
                    } else {
                        "✅ 已存待辦：\n${res.cleanedText}"
                    }
                } else {
                    voiceBubbleText?.text = "⚠️ 存入失敗：${res.error ?: ""}"
                }
                scheduleDelayedVoiceDismiss(1150L)
            }
        }.start()
    }

    private fun tryHandleDesktopVoiceFastPath(text: String): Boolean {
        val lower = text.lowercase()
        val memoMatch = Regex("""^(?:記一下|記待辦|寫待辦|備忘)\s*[:：]?\s*(.+)$""").find(text)
        if (memoMatch != null) {
            val item = memoMatch.groupValues[1].trim()
            if (item.isNotEmpty()) {
                saveVoiceMemoInPlace(item)
                return true
            }
        }
        if (lower.contains("報位置") || lower.contains("報座標") || lower == "我在哪") {
            dismissVoiceOverlay()
            executors.executeLocationShare()
            return true
        }
        if (lower.contains("天氣") || lower.contains("風速")) {
            dismissVoiceOverlay()
            executors.executeWeatherDouliu()
            return true
        }
        if (lower.contains("關手電筒") || lower.contains("關掉手電筒") ||
            lower.contains("關閉手電筒") || lower == "關燈" || lower.contains("幫我關燈")
        ) {
            val ok = setTorchNative(false)
            vibrateShort(25L)
            voiceBubbleText?.text = if (ok) "🔦 手電筒已關閉" else "⚠️ 無法關閉手電筒"
            scheduleDelayedVoiceDismiss(850L)
            return true
        }
        if (lower.contains("開手電筒") || lower.contains("打開手電筒") ||
            lower.contains("開啟手電筒") || lower == "手電筒" ||
            lower == "開燈" || lower.contains("幫我開燈")
        ) {
            val ok = setTorchNative(true)
            vibrateShort(25L)
            voiceBubbleText?.text = if (ok) "🔦 手電筒已開啟" else "⚠️ 無法開啟手電筒"
            scheduleDelayedVoiceDismiss(850L)
            return true
        }

        val navMatch = Regex("""^(?:導航到|導航去|帶我去)\s*(.+)$""").find(text)
        if (navMatch != null) {
            val dest = navMatch.groupValues[1].trim()
            if (dest.isNotEmpty()) {
                vibrateShort(25L)
                dismissVoiceOverlay()
                try {
                    val mapIntent = Intent(
                        Intent.ACTION_VIEW,
                        Uri.parse("geo:0,0?q=${Uri.encode(dest)}")
                    ).apply {
                        flags = Intent.FLAG_ACTIVITY_NEW_TASK
                    }
                    startActivity(mapIntent)
                } catch (_: Exception) {
                    Toast.makeText(this, "無法開啟 Google Maps", Toast.LENGTH_SHORT).show()
                }
                return true
            }
        }

        if (text.contains("撥打") || text.contains("打電話給")) {
            val digits = text.replace(Regex("""[^\d+*#]"""), "")
            if (digits.length >= 7) {
                vibrateShort(25L)
                dismissVoiceOverlay()
                try {
                    val dialIntent = Intent(Intent.ACTION_DIAL, Uri.parse("tel:$digits")).apply {
                        flags = Intent.FLAG_ACTIVITY_NEW_TASK
                    }
                    startActivity(dialIntent)
                } catch (_: Exception) {
                    Toast.makeText(this, "無法開啟撥號畫面", Toast.LENGTH_SHORT).show()
                }
                return true
            }
        }
        return false
    }

    private fun dismissVoiceOverlay(restoreNub: Boolean = true) {
        cancelVoiceWatchdog()
        voiceDismissRunnable?.let { mainHandler.removeCallbacks(it) }
        voiceDismissRunnable = null
        soundwaveView?.stopWave()
        soundwaveView = null
        voiceSpriteAnim?.stop()
        voiceSpriteAnim = null
        voiceBubbleText = null
        lastVoicePartial = ""
        voiceHandlingResult = false
        voiceMemoMode = false

        try {
            desktopSpeechRecognizer?.cancel()
            desktopSpeechRecognizer?.destroy()
        } catch (_: Exception) {}
        desktopSpeechRecognizer = null

        val view = voiceOverlay ?: run {
            if (restoreNub && !isAppForeground && wheelOverlay == null && activeCardOverlay == null) {
                overlayContainer?.visibility = View.VISIBLE
            }
            return
        }
        voiceOverlay = null
        try {
            windowManager?.removeView(view)
        } catch (_: Exception) {}
        if (restoreNub && !isAppForeground && wheelOverlay == null && activeCardOverlay == null) {
            overlayContainer?.visibility = View.VISIBLE
        }
    }

    private fun buildKodariAnimationDrawable(): AnimationDrawable {
        return AnimationDrawable().apply {
            isOneShot = false
            ContextCompat.getDrawable(this@GhostOverlayService, R.drawable.kodari_nub_0)?.let {
                addFrame(it, 150)
            }
            ContextCompat.getDrawable(this@GhostOverlayService, R.drawable.kodari_nub_1)?.let {
                addFrame(it, 150)
            }
            ContextCompat.getDrawable(this@GhostOverlayService, R.drawable.kodari_nub_4)?.let {
                addFrame(it, 150)
            }
            ContextCompat.getDrawable(this@GhostOverlayService, R.drawable.kodari_nub_1)?.let {
                addFrame(it, 150)
            }
        }
    }

    internal fun launchMainWithAction(actionName: String, spokenText: String? = null) {
        try {
            val intent = Intent(this, MainActivity::class.java).apply {
                action = actionName
                if (spokenText != null) {
                    putExtra(EXTRA_SPOKEN_TEXT, spokenText)
                }
                flags = Intent.FLAG_ACTIVITY_NEW_TASK or
                    Intent.FLAG_ACTIVITY_SINGLE_TOP or
                    Intent.FLAG_ACTIVITY_REORDER_TO_FRONT
            }
            startActivity(intent)
        } catch (_: Exception) {}
    }

    internal fun vibrateShort(ms: Long) {
        try {
            val vibrator: Vibrator? = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
                val vm = getSystemService(Context.VIBRATOR_MANAGER_SERVICE) as? VibratorManager
                vm?.defaultVibrator
            } else {
                @Suppress("DEPRECATION")
                getSystemService(Context.VIBRATOR_SERVICE) as? Vibrator
            }
            if (vibrator != null && vibrator.hasVibrator()) {
                vibrator.vibrate(VibrationEffect.createOneShot(ms, VibrationEffect.DEFAULT_AMPLITUDE))
            }
        } catch (_: Exception) {}
    }

    private data class WheelTrack(
        val emoji: String,
        val label: String,
        val active: Boolean,
        val isTorch: Boolean = false,
        val onTap: () -> Unit
    )

    /**
     * Native amber neon equalizer bars mirroring Flutter `_AmberSoundwavePainter`,
     * driven by ValueAnimator phase + live SpeechRecognizer RMS amplitude.
     */
    private class AmberSoundwaveView(context: Context) : View(context) {
        private val paint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
            style = Paint.Style.FILL
        }
        private val barRect = RectF()
        private var phase = 0f
        private var rmsLevel = 0.2f
        private var animator: ValueAnimator? = null

        private val density = context.resources.displayMetrics.density
        private val barWidth = 4f * density
        private val spacing = 8.5f * density
        private val centerOffset = 56f * density
        private val cornerRadius = 4f * density

        fun startWave() {
            if (animator != null) return
            animator = ValueAnimator.ofFloat(0f, 1f).apply {
                duration = 900L
                repeatCount = ValueAnimator.INFINITE
                interpolator = LinearInterpolator()
                addUpdateListener { va ->
                    phase = va.animatedValue as Float
                    invalidate()
                }
                start()
            }
        }

        fun stopWave() {
            animator?.cancel()
            animator = null
        }

        fun setRmsLevel(level: Float) {
            val target = level.coerceIn(0.08f, 1.0f)
            rmsLevel = rmsLevel * 0.55f + target * 0.45f
            invalidate()
        }

        override fun onDraw(canvas: Canvas) {
            super.onDraw(canvas)
            val cy = height / 2f
            val cxBase = width / 2f
            val barCountSide = 10
            val minH = 8f * density
            val maxH = 56f * density

            for (side in intArrayOf(-1, 1)) {
                for (i in 0 until barCountSide) {
                    val distFromCenter = centerOffset + i * spacing
                    val cx = cxBase + side * distFromCenter
                    val wave = sin((phase * 2.0 * Math.PI) - i * 0.55).toFloat()
                    val taper = 1f - (i.toFloat() / (barCountSide + 1))
                    val ampBoost = 0.42f + rmsLevel * 0.95f
                    val h = ((10f * density) + (30f * density) * ((wave + 1f) * 0.5f) * taper * ampBoost)
                        .coerceIn(minH, maxH)

                    val fraction = i.toFloat() / barCountSide
                    paint.color = lerpAmberGold(fraction, (0.35f + 0.6f * taper))
                    barRect.set(
                        cx - barWidth / 2f,
                        cy - h / 2f,
                        cx + barWidth / 2f,
                        cy + h / 2f
                    )
                    canvas.drawRoundRect(barRect, cornerRadius, cornerRadius, paint)
                }
            }
        }

        private fun lerpAmberGold(t: Float, alphaRatio: Float): Int {
            // Gold #FCD34D (252,211,77) -> Orange #FB923C (251,146,60)
            val r = (252f + (251f - 252f) * t).toInt().coerceIn(0, 255)
            val g = (211f + (146f - 211f) * t).toInt().coerceIn(0, 255)
            val b = (77f + (60f - 77f) * t).toInt().coerceIn(0, 255)
            val a = (alphaRatio * 255f).toInt().coerceIn(0, 255)
            return Color.argb(a, r, g, b)
        }
    }
}
