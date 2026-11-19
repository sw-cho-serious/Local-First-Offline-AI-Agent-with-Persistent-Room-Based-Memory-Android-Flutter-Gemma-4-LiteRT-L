// Ghost Wheel concept inspired by/adapted from https://github.com/vNeeL-code/GHOST (MIT License).
// See THIRD_PARTY_NOTICES.md at the repository root.
package com.hako.kodari

import android.Manifest
import android.annotation.SuppressLint
import android.content.ClipData
import android.content.ClipboardManager
import android.content.ContentUris
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.graphics.Bitmap
import android.graphics.Color
import android.graphics.Paint
import android.graphics.drawable.GradientDrawable
import android.location.Location
import android.location.LocationManager
import android.os.Build
import android.os.CancellationSignal
import android.os.Handler
import android.os.Looper
import android.provider.AlarmClock
import android.provider.MediaStore
import android.text.TextUtils
import android.util.Size
import android.util.TypedValue
import android.view.Gravity
import android.view.View
import android.widget.FrameLayout
import android.widget.LinearLayout
import android.widget.ScrollView
import android.widget.TextView
import androidx.core.content.ContextCompat
import org.json.JSONObject
import java.io.File
import java.io.FileOutputStream
import java.net.HttpURLConnection
import java.net.URL
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale
import java.util.concurrent.Executors
import kotlin.math.abs
import kotlin.math.roundToInt

/**
 * Executes all zero-app-launch in-place desktop actions and builds lightweight
 * dark-gold WindowManager card overlays directly inside `GhostOverlayService`.
 */
class GhostInPlaceExecutors(private val service: GhostOverlayService) {

    private val ioPool = Executors.newSingleThreadExecutor()
    private val mainHandler = Handler(Looper.getMainLooper())

    fun dp(value: Int): Int = (value * service.resources.displayMetrics.density).toInt()
    fun dpF(value: Float): Float = value * service.resources.displayMetrics.density

    // -------------------------------------------------------------------------
    // 1. 📍 Location Share -> Clipboard + SQLite Main Todo + HUD
    // -------------------------------------------------------------------------

    @SuppressLint("MissingPermission")
    fun executeLocationShare() {
        val fineGranted = ContextCompat.checkSelfPermission(
            service,
            Manifest.permission.ACCESS_FINE_LOCATION
        ) == PackageManager.PERMISSION_GRANTED
        val coarseGranted = ContextCompat.checkSelfPermission(
            service,
            Manifest.permission.ACCESS_COARSE_LOCATION
        ) == PackageManager.PERMISSION_GRANTED

        if (!fineGranted && !coarseGranted) {
            service.showHudBanner("⚠️", "尚未授予手機定位權限", "請在系統設定允許 KODARI 存取位置")
            return
        }

        val lm = service.getSystemService(Context.LOCATION_SERVICE) as? LocationManager
        if (lm == null) {
            service.showHudBanner("⚠️", "無法取得系統定位服務", "")
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
            finalizeLocationShare(bestLast!!)
            return
        }

        val activeProvider = when {
            lm.isProviderEnabled(LocationManager.GPS_PROVIDER) -> LocationManager.GPS_PROVIDER
            lm.isProviderEnabled(LocationManager.NETWORK_PROVIDER) -> LocationManager.NETWORK_PROVIDER
            else -> null
        }

        if (activeProvider == null) {
            if (bestLast != null) {
                finalizeLocationShare(bestLast!!)
            } else {
                service.showHudBanner("⚠️", "手機定位（GPS）未開啟", "請下拉通知列打開位置服務後再試")
            }
            return
        }

        service.showHudBanner("🛰️", "正在抓取現場 GPS 座標…", "請稍候 1～3 秒", durationMs = 5500L)
        val cancelSignal = CancellationSignal()
        var replied = false

        val timeoutRunnable = Runnable {
            if (!replied) {
                replied = true
                cancelSignal.cancel()
                val fallback = bestLast
                if (fallback != null) {
                    finalizeLocationShare(fallback)
                } else {
                    service.showHudBanner("⚠️", "衛星定位逾時", "室內可移至窗邊或確認定位開關")
                }
            }
        }
        mainHandler.postDelayed(timeoutRunnable, 5500L)

        try {
            lm.getCurrentLocation(
                activeProvider,
                cancelSignal,
                ContextCompat.getMainExecutor(service)
            ) { loc ->
                mainHandler.removeCallbacks(timeoutRunnable)
                if (replied) return@getCurrentLocation
                replied = true
                when {
                    loc != null -> finalizeLocationShare(loc)
                    bestLast != null -> finalizeLocationShare(bestLast!!)
                    else -> service.showHudBanner("⚠️", "無法取得當前 GPS 座標", "")
                }
            }
        } catch (_: Exception) {
            mainHandler.removeCallbacks(timeoutRunnable)
            if (!replied) {
                replied = true
                if (bestLast != null) {
                    finalizeLocationShare(bestLast!!)
                } else {
                    service.showHudBanner("⚠️", "定位啟動失敗", "")
                }
            }
        }
    }

    private fun finalizeLocationShare(loc: Location) {
        val coords = String.format(Locale.US, "%.6f, %.6f", loc.latitude, loc.longitude)
        val urlCoords = String.format(Locale.US, "%.6f,%.6f", loc.latitude, loc.longitude)
        val url = "https://maps.google.com/?q=$urlCoords"
        val acc = loc.accuracy.roundToInt().coerceAtLeast(1)
        val clipText = "📍 現場座標\n座標：$coords (±${acc}m)\n地圖：$url"

        try {
            val cm = service.getSystemService(Context.CLIPBOARD_SERVICE) as? ClipboardManager
            cm?.setPrimaryClip(ClipData.newPlainText("HAKO_LOC", clipText))
        } catch (_: Exception) {}

        val hhmm = SimpleDateFormat("M/d HH:mm", Locale.US).format(Date())
        val todoLine = "📍 [桌面報位] $coords ($hhmm ±${acc}m) $url"
        ioPool.execute {
            GhostLocalStore.appendMainTodo(service, todoLine)
        }

        service.vibrateShort(22L)
        service.showHudBanner(
            "📍",
            "現場座標已複製到剪貼簿",
            "可直接貼上 LINE（誤差 ±${acc}m）• 已同步存進待辦",
            durationMs = 3600L
        )
    }

    // -------------------------------------------------------------------------
    // 2. 📋 Clipboard Memo -> SQLite Main Todo (text captured BEFORE overlay dismiss)
    // -------------------------------------------------------------------------

    fun executeClipboardMemo(capturedClipText: String?) {
        val raw = capturedClipText?.trim() ?: ""
        if (raw.isEmpty()) {
            service.showHudBanner("📋", "剪貼簿目前沒有文字", "請先在 LINE 或網頁複製一段文字再按")
            return
        }
        ioPool.execute {
            val res = GhostLocalStore.appendMainTodo(service, raw)
            mainHandler.post {
                if (!res.ok) {
                    service.showHudBanner("⚠️", "存入備忘失敗", res.error ?: "")
                } else {
                    val preview = if (res.cleanedText.length > 52) {
                        res.cleanedText.take(52) + "…"
                    } else {
                        res.cleanedText
                    }
                    if (res.duplicate) {
                        service.showHudBanner("📋", "此條備忘已在待辦清單中", preview)
                    } else {
                        service.vibrateShort(20L)
                        service.showHudBanner("📋", "已存入大廳待辦", preview, durationMs = 3200L)
                    }
                }
            }
        }
    }

    // -------------------------------------------------------------------------
    // 3. 📷 Latest Photo -> Persistent App Files + Starred Message + Thumb HUD
    // -------------------------------------------------------------------------

    fun executeLatestPhoto() {
        val perm = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            Manifest.permission.READ_MEDIA_IMAGES
        } else {
            Manifest.permission.READ_EXTERNAL_STORAGE
        }
        if (ContextCompat.checkSelfPermission(service, perm) != PackageManager.PERMISSION_GRANTED) {
            service.showHudBanner("⚠️", "尚未授予相簿讀取權限", "請於系統設定允許 KODARI 讀取照片")
            return
        }

        ioPool.execute {
            try {
                val projection = arrayOf(
                    MediaStore.Images.Media._ID,
                    MediaStore.Images.Media.DISPLAY_NAME,
                    MediaStore.Images.Media.DATE_TAKEN,
                    MediaStore.Images.Media.DATE_ADDED
                )
                val sortOrder = "${MediaStore.Images.Media.DATE_ADDED} DESC"
                var photoId: Long? = null
                var displayName = "photo.jpg"
                var tsMs = System.currentTimeMillis()

                service.contentResolver.query(
                    MediaStore.Images.Media.EXTERNAL_CONTENT_URI,
                    projection,
                    null,
                    null,
                    sortOrder
                )?.use { cursor ->
                    if (cursor.moveToFirst()) {
                        photoId = cursor.getLong(cursor.getColumnIndexOrThrow(MediaStore.Images.Media._ID))
                        displayName = cursor.getString(
                            cursor.getColumnIndexOrThrow(MediaStore.Images.Media.DISPLAY_NAME)
                        ) ?: "photo_$photoId.jpg"
                        val taken = cursor.getLong(cursor.getColumnIndexOrThrow(MediaStore.Images.Media.DATE_TAKEN))
                        val added = cursor.getLong(cursor.getColumnIndexOrThrow(MediaStore.Images.Media.DATE_ADDED))
                        tsMs = if (taken > 0L) taken else added * 1000L
                    }
                }

                val id = photoId
                if (id == null) {
                    mainHandler.post {
                        service.showHudBanner("📷", "相簿目前找不到照片", "先用原生相機拍一張再按即可")
                    }
                    return@execute
                }

                val prefs = service.getSharedPreferences(GhostOverlayService.PREFS_NAME, Context.MODE_PRIVATE)
                val lastArchived = prefs.getLong("last_archived_media_id", -1L)
                if (lastArchived == id) {
                    mainHandler.post {
                        service.showHudBanner(
                            "📷",
                            "最新這張照片剛才已收錄過",
                            "拍新照片再按即可自動歸檔（$displayName）"
                        )
                    }
                    return@execute
                }

                val uri = ContentUris.withAppendedId(MediaStore.Images.Media.EXTERNAL_CONTENT_URI, id)
                val photoDir = File(service.filesDir, "ghost_photos").apply {
                    if (!exists()) mkdirs()
                }
                val targetFile = File(photoDir, "site_${id}_${System.currentTimeMillis()}.jpg")
                var copied = false
                service.contentResolver.openInputStream(uri)?.use { input ->
                    FileOutputStream(targetFile).use { out ->
                        input.copyTo(out)
                        copied = true
                    }
                }
                if (!copied || !targetFile.exists() || targetFile.length() == 0L) {
                    mainHandler.post {
                        service.showHudBanner("⚠️", "讀取最新照片失敗", displayName)
                    }
                    return@execute
                }

                val thumb: Bitmap? = try {
                    service.contentResolver.loadThumbnail(uri, Size(160, 160), null)
                } catch (_: Exception) {
                    null
                }

                val coordSuffix = readQuickLastKnownCoordSuffix()
                val timeText = SimpleDateFormat("M/d HH:mm", Locale.US).format(Date(tsMs))
                val caption = "📷 現場快收照：$displayName ($timeText)$coordSuffix"
                val insertedId = GhostLocalStore.insertStarredPhotoMemo(
                    service,
                    targetFile.absolutePath,
                    caption
                )
                if (insertedId < 0L) {
                    targetFile.delete()
                    thumb?.recycle()
                    mainHandler.post {
                        service.showHudBanner("⚠️", "寫入資料庫失敗", "請先開啟一次 KODARI 完成初始化")
                    }
                    return@execute
                }

                prefs.edit().putLong("last_archived_media_id", id).apply()
                mainHandler.post {
                    service.vibrateShort(22L)
                    service.showHudBanner(
                        "📷",
                        "最新現場照已收錄（⭐標星）",
                        "$displayName • $timeText$coordSuffix",
                        thumb = thumb,
                        durationMs = 3800L
                    )
                }
            } catch (e: Exception) {
                mainHandler.post {
                    service.showHudBanner("⚠️", "收錄照片發生錯誤", e.message ?: "")
                }
            }
        }
    }

    @SuppressLint("MissingPermission")
    private fun readQuickLastKnownCoordSuffix(): String {
        val fine = ContextCompat.checkSelfPermission(
            service,
            Manifest.permission.ACCESS_FINE_LOCATION
        ) == PackageManager.PERMISSION_GRANTED
        val coarse = ContextCompat.checkSelfPermission(
            service,
            Manifest.permission.ACCESS_COARSE_LOCATION
        ) == PackageManager.PERMISSION_GRANTED
        if (!fine && !coarse) return ""

        return try {
            val lm = service.getSystemService(Context.LOCATION_SERVICE) as? LocationManager ?: return ""
            var best: Location? = null
            for (p in listOf(LocationManager.GPS_PROVIDER, LocationManager.NETWORK_PROVIDER)) {
                val loc = lm.getLastKnownLocation(p) ?: continue
                if (best == null || loc.time > best!!.time) best = loc
            }
            val recent = best ?: return ""
            if (System.currentTimeMillis() - recent.time > 30 * 60_000L) return ""
            val c = String.format(Locale.US, "%.4f,%.4f", recent.latitude, recent.longitude)
            " • 📍$c"
        } catch (_: Exception) {
            ""
        }
    }

    // -------------------------------------------------------------------------
    // 4. 📌 In-Place Pending Todo Peek Card (with direct 1-tap toggle in SQLite)
    // -------------------------------------------------------------------------

    fun showTodoPeekCard() {
        ioPool.execute {
            val snapshot = GhostLocalStore.loadPendingTodos(service, maxItems = 10)
            mainHandler.post {
                mountTodoPeekCard(snapshot)
            }
        }
    }

    private fun mountTodoPeekCard(snapshot: GhostLocalStore.PendingTodoSnapshot) {
        val card = buildBaseCardContainer(dp(332))

        val headerRow = LinearLayout(service).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER_VERTICAL
        }
        val titleView = TextView(service).apply {
            text = "📌 今日未完成待辦"
            setTextSize(TypedValue.COMPLEX_UNIT_SP, 15f)
            setTextColor(Color.parseColor("#FCD34D"))
            paint.isFakeBoldText = true
            layoutParams = LinearLayout.LayoutParams(0, LinearLayout.LayoutParams.WRAP_CONTENT, 1f)
        }
        val badgeView = TextView(service).apply {
            text = if (snapshot.ok) {
                "待辦 ${snapshot.totalPending} • ⭐ ${snapshot.starredCount}"
            } else {
                "異常"
            }
            setTextSize(TypedValue.COMPLEX_UNIT_SP, 11f)
            setTextColor(Color.parseColor("#FDE68A"))
            setPadding(dp(8), dp(3), dp(8), dp(3))
            background = GradientDrawable().apply {
                shape = GradientDrawable.RECTANGLE
                cornerRadius = dpF(99f)
                setColor(Color.parseColor("#33F59E0B"))
            }
        }
        headerRow.addView(titleView)
        headerRow.addView(badgeView)
        card.addView(headerRow)

        val maxScrollH = (service.resources.displayMetrics.heightPixels * 0.44f).toInt()
            .coerceIn(dp(180), dp(360))
        val listWrap = LinearLayout(service).apply {
            orientation = LinearLayout.VERTICAL
        }

        if (!snapshot.ok) {
            listWrap.addView(buildEmptyInfoText(snapshot.error ?: "讀取失敗"))
        } else if (snapshot.entries.isEmpty()) {
            listWrap.addView(buildEmptyInfoText("🎉 所有工作房間待辦都已清空！\n⭐ 標星暫存區：${snapshot.starredCount} 筆"))
        } else {
            for (entry in snapshot.entries) {
                var isChecked = false
                val row = LinearLayout(service).apply {
                    orientation = LinearLayout.HORIZONTAL
                    gravity = Gravity.CENTER_VERTICAL
                    setPadding(dp(10), dp(9), dp(10), dp(9))
                    background = GradientDrawable().apply {
                        shape = GradientDrawable.RECTANGLE
                        cornerRadius = dpF(12f)
                        setColor(Color.parseColor("#FF10131A"))
                        setStroke(dp(1), Color.parseColor("#29FFFFFF"))
                    }
                }

                val checkText = TextView(service).apply {
                    text = "⬜"
                    setTextSize(TypedValue.COMPLEX_UNIT_SP, 15f)
                    setPadding(0, 0, dp(8), 0)
                }
                val textCol = LinearLayout(service).apply {
                    orientation = LinearLayout.VERTICAL
                    layoutParams = LinearLayout.LayoutParams(0, LinearLayout.LayoutParams.WRAP_CONTENT, 1f)
                }
                val roomTag = TextView(service).apply {
                    text = entry.roomTitle
                    setTextSize(TypedValue.COMPLEX_UNIT_SP, 10.5f)
                    setTextColor(Color.parseColor("#FBBF24"))
                    maxLines = 1
                    ellipsize = TextUtils.TruncateAt.END
                }
                val bodyText = TextView(service).apply {
                    text = entry.text
                    setTextSize(TypedValue.COMPLEX_UNIT_SP, 13f)
                    setTextColor(Color.parseColor("#F3F4F6"))
                    maxLines = 2
                    ellipsize = TextUtils.TruncateAt.END
                }
                textCol.addView(roomTag)
                textCol.addView(bodyText)

                row.addView(checkText)
                row.addView(textCol)
                row.setOnClickListener {
                    service.vibrateShort(16L)
                    isChecked = !isChecked
                    checkText.text = if (isChecked) "✅" else "⬜"
                    bodyText.paintFlags = if (isChecked) {
                        bodyText.paintFlags or Paint.STRIKE_THRU_TEXT_FLAG
                    } else {
                        bodyText.paintFlags and Paint.STRIKE_THRU_TEXT_FLAG.inv()
                    }
                    row.alpha = if (isChecked) 0.52f else 1.0f
                    ioPool.execute {
                        GhostLocalStore.toggleTodoLine(service, entry.roomId, entry.lineIndex)
                    }
                }

                val lp = LinearLayout.LayoutParams(
                    LinearLayout.LayoutParams.MATCH_PARENT,
                    LinearLayout.LayoutParams.WRAP_CONTENT
                ).apply { topMargin = dp(8) }
                listWrap.addView(row, lp)
            }
        }

        val scroll = ScrollView(service).apply {
            addView(listWrap)
        }
        val scrollLp = LinearLayout.LayoutParams(
            LinearLayout.LayoutParams.MATCH_PARENT,
            LinearLayout.LayoutParams.WRAP_CONTENT
        ).apply {
            topMargin = dp(10)
        }
        val boundedBox = FrameLayout(service).apply {
            addView(scroll, FrameLayout.LayoutParams(
                FrameLayout.LayoutParams.MATCH_PARENT,
                FrameLayout.LayoutParams.WRAP_CONTENT
            ))
        }
        if (snapshot.entries.size >= 5) {
            scrollLp.height = maxScrollH
        }
        card.addView(boundedBox, scrollLp)

        card.addView(
            buildFooterActionRow(
                leftText = "關閉",
                onLeft = { service.dismissActiveCard() },
                rightText = "開 App 總覽",
                onRight = {
                    service.dismissActiveCard(restoreNub = false)
                    service.launchMainWithAction(GhostOverlayService.INTENT_ACTION_OPEN_TODOS)
                }
            ),
            LinearLayout.LayoutParams(
                LinearLayout.LayoutParams.MATCH_PARENT,
                LinearLayout.LayoutParams.WRAP_CONTENT
            ).apply { topMargin = dp(12) }
        )

        service.presentCardOverlay(card)
    }

    // -------------------------------------------------------------------------
    // 5. 🕒 In-Place Next Routine Peek Card
    // -------------------------------------------------------------------------

    fun showRoutinePeekCard() {
        ioPool.execute {
            val (ok, list) = GhostLocalStore.loadUpcomingRoutines(service, maxItems = 5)
            mainHandler.post {
                mountRoutinePeekCard(ok, list)
            }
        }
    }

    private fun mountRoutinePeekCard(
        ok: Boolean,
        items: List<GhostLocalStore.RoutinePreviewItem>
    ) {
        val card = buildBaseCardContainer(dp(332))

        val titleView = TextView(service).apply {
            text = "🕒 下一個日常排程"
            setTextSize(TypedValue.COMPLEX_UNIT_SP, 15f)
            setTextColor(Color.parseColor("#FCD34D"))
            paint.isFakeBoldText = true
        }
        card.addView(titleView)

        val listWrap = LinearLayout(service).apply {
            orientation = LinearLayout.VERTICAL
        }

        if (!ok) {
            listWrap.addView(buildEmptyInfoText("請先開啟 KODARI 初始化排程表"))
        } else if (items.isEmpty()) {
            listWrap.addView(buildEmptyInfoText("目前尚無日常排程\n點右下方「排程管理」即可新增每日/每週提醒"))
        } else {
            for (item in items) {
                val row = LinearLayout(service).apply {
                    orientation = LinearLayout.VERTICAL
                    setPadding(dp(11), dp(9), dp(11), dp(9))
                    background = GradientDrawable().apply {
                        shape = GradientDrawable.RECTANGLE
                        cornerRadius = dpF(12f)
                        setColor(Color.parseColor("#FF10131A"))
                        setStroke(
                            dp(1),
                            if (item.enabled) Color.parseColor("#59F59E0B") else Color.parseColor("#26FFFFFF")
                        )
                    }
                }

                val topLine = TextView(service).apply {
                    text = "${if (item.enabled) "🟢" else "⚪"} ${item.title}"
                    setTextSize(TypedValue.COMPLEX_UNIT_SP, 13f)
                    setTextColor(if (item.enabled) Color.WHITE else Color.parseColor("#9CA3AF"))
                    paint.isFakeBoldText = true
                    maxLines = 1
                    ellipsize = TextUtils.TruncateAt.END
                }
                val timeLine = TextView(service).apply {
                    text = "${item.formattedTime} • ${item.countdownText}"
                    setTextSize(TypedValue.COMPLEX_UNIT_SP, 11.5f)
                    setTextColor(if (item.enabled) Color.parseColor("#FDE68A") else Color.parseColor("#6B7280"))
                }
                val btnRow = LinearLayout(service).apply {
                    orientation = LinearLayout.HORIZONTAL
                    gravity = Gravity.END
                }

                val snoozeBtn = buildCompactCardChip("⏱️ +30分", "#1F2937", "#38BDF8") {
                    launchSystemTimer(30, "排程提醒：${item.title}")
                    service.dismissActiveCard()
                }
                val toggleBtn = buildCompactCardChip(
                    if (item.enabled) "暫停" else "啟用",
                    "#1F2937",
                    if (item.enabled) "#FB7185" else "#34D399"
                ) {
                    service.vibrateShort(18L)
                    ioPool.execute {
                        GhostLocalStore.toggleRoutineEnabled(service, item.id, !item.enabled)
                        val (reloadOk, reloaded) = GhostLocalStore.loadUpcomingRoutines(service, 5)
                        mainHandler.post {
                            mountRoutinePeekCard(reloadOk, reloaded)
                        }
                    }
                }

                btnRow.addView(
                    snoozeBtn,
                    LinearLayout.LayoutParams(
                        LinearLayout.LayoutParams.WRAP_CONTENT,
                        LinearLayout.LayoutParams.WRAP_CONTENT
                    ).apply { rightMargin = dp(8) }
                )
                btnRow.addView(toggleBtn)

                row.addView(topLine)
                row.addView(timeLine, LinearLayout.LayoutParams(
                    LinearLayout.LayoutParams.WRAP_CONTENT,
                    LinearLayout.LayoutParams.WRAP_CONTENT
                ).apply { topMargin = dp(2) })
                row.addView(btnRow, LinearLayout.LayoutParams(
                    LinearLayout.LayoutParams.MATCH_PARENT,
                    LinearLayout.LayoutParams.WRAP_CONTENT
                ).apply { topMargin = dp(7) })

                listWrap.addView(row, LinearLayout.LayoutParams(
                    LinearLayout.LayoutParams.MATCH_PARENT,
                    LinearLayout.LayoutParams.WRAP_CONTENT
                ).apply { topMargin = dp(8) })
            }
        }

        val scroll = ScrollView(service).apply { addView(listWrap) }
        val scrollLp = LinearLayout.LayoutParams(
            LinearLayout.LayoutParams.MATCH_PARENT,
            LinearLayout.LayoutParams.WRAP_CONTENT
        ).apply {
            topMargin = dp(8)
            if (items.size >= 4) {
                height = (service.resources.displayMetrics.heightPixels * 0.44f).toInt().coerceIn(dp(200), dp(360))
            }
        }
        card.addView(scroll, scrollLp)

        card.addView(
            buildFooterActionRow(
                leftText = "關閉",
                onLeft = { service.dismissActiveCard() },
                rightText = "排程管理",
                onRight = {
                    service.dismissActiveCard(restoreNub = false)
                    service.launchMainWithAction(GhostOverlayService.INTENT_ACTION_OPEN_ROUTINES)
                }
            ),
            LinearLayout.LayoutParams(
                LinearLayout.LayoutParams.MATCH_PARENT,
                LinearLayout.LayoutParams.WRAP_CONTENT
            ).apply { topMargin = dp(12) }
        )

        service.presentCardOverlay(card)
    }

    // -------------------------------------------------------------------------
    // 6. 🌦️ In-Place Weather & Wind Speed (Open-Meteo keyless HTTPS -> HUD)
    // -------------------------------------------------------------------------

    @SuppressLint("MissingPermission")
    fun executeWeatherDouliu() {
        service.showHudBanner("🌦️", "正在讀取現地天氣與風速…", "連線氣象資料中", durationMs = 4500L)

        ioPool.execute {
            var lat: Double? = null
            var lng: Double? = null
            val placeLabel = "現地位置"

            val fine = ContextCompat.checkSelfPermission(
                service,
                Manifest.permission.ACCESS_FINE_LOCATION
            ) == PackageManager.PERMISSION_GRANTED
            val coarse = ContextCompat.checkSelfPermission(
                service,
                Manifest.permission.ACCESS_COARSE_LOCATION
            ) == PackageManager.PERMISSION_GRANTED
            if (fine || coarse) {
                try {
                    val lm = service.getSystemService(Context.LOCATION_SERVICE) as? LocationManager
                    var best: Location? = null
                    if (lm != null) {
                        for (p in listOf(LocationManager.GPS_PROVIDER, LocationManager.NETWORK_PROVIDER)) {
                            val loc = lm.getLastKnownLocation(p) ?: continue
                            if (best == null || loc.time > best!!.time) best = loc
                        }
                    }
                    if (best != null && System.currentTimeMillis() - best!!.time <= 30 * 60_000L) {
                        lat = best!!.latitude
                        lng = best!!.longitude
                    }
                } catch (_: Exception) {}
            }

            if (lat == null || lng == null) {
                mainHandler.post {
                    service.showHudBanner("📍", "無法取得目前位置", "請開啟定位權限後再試", durationMs = 4000L)
                }
                return@execute
            }

            var conn: HttpURLConnection? = null
            try {
                val urlStr = String.format(
                    Locale.US,
                    "https://api.open-meteo.com/v1/forecast?latitude=%.4f&longitude=%.4f" +
                        "&current=temperature_2m,apparent_temperature,weather_code,wind_speed_10m,wind_direction_10m" +
                        "&hourly=precipitation_probability&daily=sunset&timezone=auto&forecast_days=1",
                    lat,
                    lng
                )
                conn = (URL(urlStr).openConnection() as HttpURLConnection).apply {
                    requestMethod = "GET"
                    connectTimeout = 5000
                    readTimeout = 6000
                    setRequestProperty("Accept", "application/json")
                }
                val code = conn.responseCode
                if (code != HttpURLConnection.HTTP_OK) {
                    throw RuntimeException("HTTP $code")
                }
                val raw = conn.inputStream.bufferedReader().use { it.readText() }
                val root = JSONObject(raw)
                val cur = root.getJSONObject("current")
                val temp = cur.optDouble("temperature_2m", 0.0).roundToInt()
                val apparent = cur.optDouble("apparent_temperature", 0.0).roundToInt()
                val wmo = cur.optInt("weather_code", 0)
                val windKmh = cur.optDouble("wind_speed_10m", 0.0)
                val windDeg = cur.optDouble("wind_direction_10m", 0.0)

                val currentTimeIso = cur.optString("time", "") // e.g. 2026-11-19T11:15
                val curHourPrefix = if (currentTimeIso.length >= 13) currentTimeIso.substring(0, 13) else ""
                var rainProb = 0
                val hourly = root.optJSONObject("hourly")
                if (hourly != null) {
                    val times = hourly.optJSONArray("time")
                    val probs = hourly.optJSONArray("precipitation_probability")
                    if (times != null && probs != null && probs.length() > 0) {
                        var matched = 0
                        for (i in 0 until minOf(times.length(), probs.length())) {
                            if (curHourPrefix.isNotEmpty() && times.optString(i).startsWith(curHourPrefix)) {
                                matched = probs.optInt(i, 0)
                                break
                            }
                        }
                        if (curHourPrefix.isEmpty()) matched = probs.optInt(0, 0)
                        rainProb = matched
                    }
                }

                var sunsetHHMM = "--:--"
                val daily = root.optJSONObject("daily")
                val sunsets = daily?.optJSONArray("sunset")
                if (sunsets != null && sunsets.length() > 0) {
                    val rawSun = sunsets.optString(0, "")
                    val tIdx = rawSun.indexOf('T')
                    if (tIdx != -1 && rawSun.length >= tIdx + 6) {
                        sunsetHHMM = rawSun.substring(tIdx + 1, tIdx + 6)
                    }
                }

                val (wEmoji, wDesc) = describeWmoCode(wmo)
                val beaufort = kmhToBeaufort(windKmh)
                val windDir = degToCompassZh(windDeg)
                val windKmhStr = String.format(Locale.US, "%.1f", windKmh)

                mainHandler.post {
                    service.vibrateShort(18L)
                    service.showHudBanner(
                        wEmoji,
                        "$placeLabel ${temp}°C（體感 ${apparent}° • $wDesc）",
                        "降雨 ${rainProb}%｜${windDir}風 ${beaufort}級 (${windKmhStr} km/h)｜🌅日落 $sunsetHHMM",
                        durationMs = 5200L
                    )
                }
            } catch (_: Exception) {
                mainHandler.post {
                    service.showHudBanner("⚠️", "無法取得即時天氣", "請確認手機網路連線狀態後再試")
                }
            } finally {
                try {
                    conn?.disconnect()
                } catch (_: Exception) {}
            }
        }
    }

    private fun describeWmoCode(code: Int): Pair<String, String> = when (code) {
        0 -> "☀️" to "晴朗"
        1, 2 -> "🌤️" to "多雲時晴"
        3 -> "☁️" to "陰天"
        45, 48 -> "🌫️" to "有霧"
        51, 53, 55 -> "🌦️" to "毛毛雨"
        61, 63, 65 -> "🌧️" to "下雨"
        80, 81, 82 -> "⛈️" to "陣雨"
        95, 96, 99 -> "⚡" to "雷雨"
        else -> "🌤️" to "多雲"
    }

    private fun kmhToBeaufort(kmh: Double): Int = when {
        kmh < 1.0 -> 0
        kmh < 6.0 -> 1
        kmh < 12.0 -> 2
        kmh < 20.0 -> 3
        kmh < 29.0 -> 4
        kmh < 39.0 -> 5
        kmh < 50.0 -> 6
        kmh < 62.0 -> 7
        kmh < 75.0 -> 8
        kmh < 89.0 -> 9
        kmh < 103.0 -> 10
        kmh < 118.0 -> 11
        else -> 12
    }

    private fun degToCompassZh(deg: Double): String {
        val dirs = arrayOf("北", "東北", "東", "東南", "南", "西南", "西", "西北")
        val normalized = ((deg % 360.0) + 360.0) % 360.0
        val idx = ((normalized + 22.5) / 45.0).toInt() % 8
        return dirs[idx]
    }

    // -------------------------------------------------------------------------
    // 7. ⏱️ Quick Timer Overlay Card
    // -------------------------------------------------------------------------

    fun showQuickTimerCard() {
        val card = buildBaseCardContainer(dp(304))

        card.addView(TextView(service).apply {
            text = "⏱️ 現場快速倒數計時"
            setTextSize(TypedValue.COMPLEX_UNIT_SP, 15f)
            setTextColor(Color.parseColor("#FCD34D"))
            paint.isFakeBoldText = true
        })
        card.addView(TextView(service).apply {
            text = "點擊即設定系統時鐘倒數（烤漆／放樣／等料）"
            setTextSize(TypedValue.COMPLEX_UNIT_SP, 11.5f)
            setTextColor(Color.parseColor("#9CA3AF"))
        }, LinearLayout.LayoutParams(
            LinearLayout.LayoutParams.WRAP_CONTENT,
            LinearLayout.LayoutParams.WRAP_CONTENT
        ).apply { topMargin = dp(3) })

        val presets = listOf(10, 15, 30, 60)
        for (rowIdx in 0..1) {
            val row = LinearLayout(service).apply {
                orientation = LinearLayout.HORIZONTAL
            }
            for (colIdx in 0..1) {
                val mins = presets[rowIdx * 2 + colIdx]
                val btn = TextView(service).apply {
                    text = if (mins == 60) "1 小時" else "$mins 分鐘"
                    setTextSize(TypedValue.COMPLEX_UNIT_SP, 14f)
                    setTextColor(Color.WHITE)
                    paint.isFakeBoldText = true
                    gravity = Gravity.CENTER
                    setPadding(dp(8), dp(14), dp(8), dp(14))
                    background = GradientDrawable().apply {
                        shape = GradientDrawable.RECTANGLE
                        cornerRadius = dpF(14f)
                        setColor(Color.parseColor("#FF10131A"))
                        setStroke(dp(1), Color.parseColor("#8CF59E0B"))
                    }
                    setOnClickListener {
                        service.vibrateShort(22L)
                        launchSystemTimer(mins, "KODARI 現場計時 (${mins}分)")
                        service.dismissActiveCard()
                    }
                }
                row.addView(btn, LinearLayout.LayoutParams(0, LinearLayout.LayoutParams.WRAP_CONTENT, 1f).apply {
                    if (colIdx == 0) rightMargin = dp(8)
                })
            }
            card.addView(row, LinearLayout.LayoutParams(
                LinearLayout.LayoutParams.MATCH_PARENT,
                LinearLayout.LayoutParams.WRAP_CONTENT
            ).apply { topMargin = dp(10) })
        }

        val closeBtn = buildCompactCardChip("關閉", "#1F2937", "#9CA3AF") {
            service.dismissActiveCard()
        }
        card.addView(closeBtn, LinearLayout.LayoutParams(
            LinearLayout.LayoutParams.WRAP_CONTENT,
            LinearLayout.LayoutParams.WRAP_CONTENT
        ).apply {
            gravity = Gravity.END
            topMargin = dp(12)
        })

        service.presentCardOverlay(card)
    }

    private fun launchSystemTimer(minutes: Int, message: String) {
        try {
            val intent = Intent(AlarmClock.ACTION_SET_TIMER).apply {
                putExtra(AlarmClock.EXTRA_LENGTH, minutes * 60)
                putExtra(AlarmClock.EXTRA_MESSAGE, message)
                putExtra(AlarmClock.EXTRA_SKIP_UI, false)
                flags = Intent.FLAG_ACTIVITY_NEW_TASK
            }
            service.startActivity(intent)
            service.showHudBanner("⏱️", "已啟動 ${minutes} 分鐘倒數計時", message)
        } catch (_: Exception) {
            service.showHudBanner("⚠️", "無法喚起系統時鐘", "請確認手機內建時鐘 App 可用")
        }
    }

    // -------------------------------------------------------------------------
    // 8. 🧮 Floating Mini Calculator (with mm ↔ 台尺 live readout)
    // -------------------------------------------------------------------------

    fun showMiniCalculatorCard() {
        val card = buildBaseCardContainer(dp(298))

        var currentText = "0"
        var accumulator: Double? = null
        var pendingOp: Char? = null
        var resetOnNextDigit = false
        var tailScaleMode = false // false: mm -> 台尺; true: 台尺 -> mm

        val exprLabel = TextView(service).apply {
            text = ""
            setTextSize(TypedValue.COMPLEX_UNIT_SP, 11.5f)
            setTextColor(Color.parseColor("#9CA3AF"))
            gravity = Gravity.END
            maxLines = 1
        }
        val mainDisplay = TextView(service).apply {
            text = "0"
            setTextSize(TypedValue.COMPLEX_UNIT_SP, 26f)
            setTextColor(Color.WHITE)
            paint.isFakeBoldText = true
            gravity = Gravity.END
            maxLines = 1
            ellipsize = TextUtils.TruncateAt.START
        }
        val unitRow = LinearLayout(service).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER_VERTICAL
        }
        val convertReadout = TextView(service).apply {
            text = "≈ 0.00 台尺 (1台尺=303.03mm)"
            setTextSize(TypedValue.COMPLEX_UNIT_SP, 11f)
            setTextColor(Color.parseColor("#FDE68A"))
            layoutParams = LinearLayout.LayoutParams(0, LinearLayout.LayoutParams.WRAP_CONTENT, 1f)
        }
        val modeBtn = TextView(service).apply {
            text = "mm⇄尺"
            setTextSize(TypedValue.COMPLEX_UNIT_SP, 10.5f)
            setTextColor(Color.parseColor("#FCD34D"))
            setPadding(dp(8), dp(3), dp(8), dp(3))
            background = GradientDrawable().apply {
                shape = GradientDrawable.RECTANGLE
                cornerRadius = dpF(99f)
                setColor(Color.parseColor("#33F59E0B"))
            }
        }
        unitRow.addView(convertReadout)
        unitRow.addView(modeBtn)

        val displayBox = LinearLayout(service).apply {
            orientation = LinearLayout.VERTICAL
            setPadding(dp(12), dp(10), dp(12), dp(8))
            background = GradientDrawable().apply {
                shape = GradientDrawable.RECTANGLE
                cornerRadius = dpF(14f)
                setColor(Color.parseColor("#FF0E1117"))
                setStroke(dp(1), Color.parseColor("#4DFFFFFF"))
            }
            addView(exprLabel)
            addView(mainDisplay)
            addView(unitRow, LinearLayout.LayoutParams(
                LinearLayout.LayoutParams.MATCH_PARENT,
                LinearLayout.LayoutParams.WRAP_CONTENT
            ).apply { topMargin = dp(4) })
        }
        card.addView(displayBox)

        fun formatNum(v: Double): String {
            if (v.isNaN() || v.isInfinite()) return "錯誤"
            val roundedLong = v.toLong()
            return if (abs(v - roundedLong) < 1e-9 && abs(v) < 1e13) {
                roundedLong.toString()
            } else {
                String.format(Locale.US, "%.4f", v).trimEnd('0').trimEnd('.')
            }
        }

        fun refreshDisplay() {
            mainDisplay.text = currentText
            exprLabel.text = if (accumulator != null && pendingOp != null) {
                "${formatNum(accumulator!!)} $pendingOp"
            } else {
                ""
            }
            val num = currentText.toDoubleOrNull() ?: 0.0
            convertReadout.text = if (!tailScaleMode) {
                val chi = num / 303.030303
                String.format(Locale.US, "%.2f mm ≈ %.2f 台尺", num, chi)
            } else {
                val mm = num * 303.030303
                String.format(Locale.US, "%.2f 台尺 ≈ %.1f mm", num, mm)
            }
        }

        modeBtn.setOnClickListener {
            tailScaleMode = !tailScaleMode
            refreshDisplay()
        }

        fun applyOp(a: Double, b: Double, op: Char): Double = when (op) {
            '+' -> a + b
            '-' -> a - b
            '×' -> a * b
            '÷' -> if (b == 0.0) Double.NaN else a / b
            else -> b
        }

        fun pressKey(key: String) {
            service.vibrateShort(10L)
            when (key) {
                "C" -> {
                    currentText = "0"
                    accumulator = null
                    pendingOp = null
                    resetOnNextDigit = false
                }
                "⌫" -> {
                    currentText = if (resetOnNextDigit || currentText.length <= 1) {
                        "0"
                    } else {
                        currentText.dropLast(1)
                    }
                    resetOnNextDigit = false
                }
                "+", "-", "×", "÷" -> {
                    val curVal = currentText.toDoubleOrNull() ?: 0.0
                    if (accumulator != null && pendingOp != null && !resetOnNextDigit) {
                        val res = applyOp(accumulator!!, curVal, pendingOp!!)
                        accumulator = res
                        currentText = formatNum(res)
                    } else {
                        accumulator = curVal
                    }
                    pendingOp = key[0]
                    resetOnNextDigit = true
                }
                "=" -> {
                    val curVal = currentText.toDoubleOrNull() ?: 0.0
                    if (accumulator != null && pendingOp != null) {
                        val res = applyOp(accumulator!!, curVal, pendingOp!!)
                        currentText = formatNum(res)
                        accumulator = null
                        pendingOp = null
                        resetOnNextDigit = true
                    }
                }
                "." -> {
                    if (resetOnNextDigit) {
                        currentText = "0."
                        resetOnNextDigit = false
                    } else if (!currentText.contains('.')) {
                        currentText += "."
                    }
                }
                else -> {
                    currentText = if (resetOnNextDigit || currentText == "0") {
                        resetOnNextDigit = false
                        key
                    } else {
                        (currentText + key).take(14)
                    }
                }
            }
            refreshDisplay()
        }

        val rows = listOf(
            listOf("C", "⌫", "÷", "×"),
            listOf("7", "8", "9", "-"),
            listOf("4", "5", "6", "+"),
            listOf("1", "2", "3", "="),
            listOf("0", ".", "複製", "關閉")
        )
        for (r in rows) {
            val rowLayout = LinearLayout(service).apply {
                orientation = LinearLayout.HORIZONTAL
            }
            r.forEachIndexed { idx, key ->
                val isOp = key in setOf("÷", "×", "-", "+", "=")
                val isCtrl = key in setOf("C", "⌫", "複製", "關閉")
                val btn = TextView(service).apply {
                    text = key
                    setTextSize(TypedValue.COMPLEX_UNIT_SP, if (key.length >= 2) 13f else 17f)
                    setTextColor(
                        when {
                            key == "=" -> Color.parseColor("#111317")
                            isOp -> Color.parseColor("#FCD34D")
                            key == "複製" -> Color.parseColor("#34D399")
                            key == "關閉" -> Color.parseColor("#FB7185")
                            else -> Color.WHITE
                        }
                    )
                    paint.isFakeBoldText = true
                    gravity = Gravity.CENTER
                    setPadding(0, dp(11), 0, dp(11))
                    background = GradientDrawable().apply {
                        shape = GradientDrawable.RECTANGLE
                        cornerRadius = dpF(11f)
                        setColor(
                            when {
                                key == "=" -> Color.parseColor("#FFF59E0B")
                                isOp || isCtrl -> Color.parseColor("#FF1F2430")
                                else -> Color.parseColor("#FF12151E")
                            }
                        )
                        setStroke(dp(1), Color.parseColor("#22FFFFFF"))
                    }
                    setOnClickListener {
                        when (key) {
                            "複製" -> {
                                try {
                                    val cm = service.getSystemService(Context.CLIPBOARD_SERVICE) as? ClipboardManager
                                    cm?.setPrimaryClip(ClipData.newPlainText("HAKO_CALC", currentText))
                                } catch (_: Exception) {}
                                service.vibrateShort(20L)
                                service.dismissActiveCard()
                                service.showHudBanner("🧮", "已複製計算結果", currentText)
                            }
                            "關閉" -> service.dismissActiveCard()
                            else -> pressKey(key)
                        }
                    }
                }
                rowLayout.addView(btn, LinearLayout.LayoutParams(0, LinearLayout.LayoutParams.WRAP_CONTENT, 1f).apply {
                    if (idx < r.lastIndex) rightMargin = dp(6)
                })
            }
            card.addView(rowLayout, LinearLayout.LayoutParams(
                LinearLayout.LayoutParams.MATCH_PARENT,
                LinearLayout.LayoutParams.WRAP_CONTENT
            ).apply { topMargin = dp(7) })
        }

        service.presentCardOverlay(card)
    }

    // -------------------------------------------------------------------------
    // 9. 📡 Refresh Office Dual Battle Boards (GAS / Peer HTTP)
    // -------------------------------------------------------------------------

    fun executeRefreshBoards() {
        service.showHudBanner("📡", "正在呼叫辦公室戰情板…", "發送 REFRESH_ALL_BOARDS", durationMs = 4500L)

        ioPool.execute {
            val flutterPrefs = service.getSharedPreferences(
                "FlutterSharedPreferences",
                Context.MODE_PRIVATE
            )
            val peerUrl = (flutterPrefs.getString("flutter.hako_peer_endpoint_url", "") ?: "").trim()
            val gasUrl = (flutterPrefs.getString("flutter.hako_gas_webapp_url", "") ?: "").trim()
            val token = (flutterPrefs.getString("flutter.hako_gas_sync_token", "") ?: "").trim()
            val targetUrl = peerUrl.ifEmpty { gasUrl }

            if (targetUrl.isEmpty()) {
                mainHandler.post {
                    service.showHudBanner(
                        "⚠️",
                        "尚未綁定雲端/Peer 網址",
                        "請先在 KODARI ☁️ 同步或設定頁填入 GAS / Peer 閘道網址",
                        durationMs = 3800L
                    )
                }
                return@execute
            }

            try {
                val payload = JSONObject().apply {
                    put("action", "refresh_all_boards")
                    put("target", "ALL")
                    put("source", "HAKO_GHOST")
                    put("token", token)
                    put("timestamp", System.currentTimeMillis())
                }.toString()

                val rawResp = postJsonWithGasRedirect(targetUrl, payload)
                val decoded = JSONObject(rawResp)
                val ok = decoded.optBoolean("ok", true)
                val msg = decoded.optString("reply", "").ifBlank {
                    decoded.optString("message", "")
                }
                val err = decoded.optString("error", "")

                mainHandler.post {
                    if (ok) {
                        service.vibrateShort(22L)
                        service.showHudBanner(
                            "🟢",
                            "雙戰情板刷新指令已送達",
                            msg.ifBlank { "BATTLE_BOARD 與 DISPATCH_BOARD 已觸發重整" },
                            durationMs = 3800L
                        )
                    } else {
                        service.showHudBanner(
                            "⚠️",
                            "戰情板刷新回傳異常",
                            err.ifBlank { msg.ifBlank { "伺服器拒絕指令" } }
                        )
                    }
                }
            } catch (e: Exception) {
                mainHandler.post {
                    service.showHudBanner("⚠️", "無法連線辦公室閘道", e.message ?: "連線逾時")
                }
            }
        }
    }

    private fun postJsonWithGasRedirect(targetUrl: String, jsonBody: String): String {
        var conn: HttpURLConnection? = null
        try {
            conn = (URL(targetUrl).openConnection() as HttpURLConnection).apply {
                instanceFollowRedirects = false
                requestMethod = "POST"
                doOutput = true
                connectTimeout = 6000
                readTimeout = 8000
                setRequestProperty("Content-Type", "application/json; charset=UTF-8")
                setRequestProperty("Accept", "application/json")
            }
            conn.outputStream.use { it.write(jsonBody.toByteArray(Charsets.UTF_8)) }

            val code = conn.responseCode
            if (code in setOf(301, 302, 303, 307, 308)) {
                val location = conn.getHeaderField("Location") ?: ""
                conn.disconnect()
                conn = null
                if (location.isNotEmpty()) {
                    val getConn = (URL(location).openConnection() as HttpURLConnection).apply {
                        requestMethod = "GET"
                        connectTimeout = 6000
                        readTimeout = 8000
                        setRequestProperty("Accept", "application/json")
                    }
                    try {
                        return getConn.inputStream.bufferedReader().use { it.readText() }
                    } finally {
                        getConn.disconnect()
                    }
                }
            }

            val stream = if (code >= 400) conn?.errorStream else conn?.inputStream
            return stream?.bufferedReader()?.use { it.readText() } ?: "{}"
        } finally {
            try {
                conn?.disconnect()
            } catch (_: Exception) {}
        }
    }

    // -------------------------------------------------------------------------
    // Shared Dark-Gold Card UI Builders
    // -------------------------------------------------------------------------

    private fun buildBaseCardContainer(widthPx: Int): LinearLayout {
        return LinearLayout(service).apply {
            orientation = LinearLayout.VERTICAL
            setPadding(dp(16), dp(15), dp(16), dp(14))
            layoutParams = FrameLayout.LayoutParams(widthPx, FrameLayout.LayoutParams.WRAP_CONTENT)
            background = GradientDrawable().apply {
                shape = GradientDrawable.RECTANGLE
                cornerRadius = dpF(20f)
                setColor(Color.parseColor("#F5171A23"))
                setStroke(dpF(1.5f).toInt().coerceAtLeast(1), Color.parseColor("#B3F59E0B"))
            }
            elevation = dpF(12f)
            setOnClickListener { /* absorb tap inside card */ }
        }
    }

    private fun buildEmptyInfoText(msg: String): TextView {
        return TextView(service).apply {
            text = msg
            setTextSize(TypedValue.COMPLEX_UNIT_SP, 12.5f)
            setTextColor(Color.parseColor("#9CA3AF"))
            setPadding(0, dp(14), 0, dp(10))
            setLineSpacing(dpF(4f), 1.0f)
        }
    }

    private fun buildCompactCardChip(
        label: String,
        bgHex: String,
        strokeHex: String,
        onClick: () -> Unit
    ): TextView {
        return TextView(service).apply {
            text = label
            setTextSize(TypedValue.COMPLEX_UNIT_SP, 11.5f)
            setTextColor(Color.WHITE)
            paint.isFakeBoldText = true
            setPadding(dp(12), dp(6), dp(12), dp(6))
            background = GradientDrawable().apply {
                shape = GradientDrawable.RECTANGLE
                cornerRadius = dpF(99f)
                setColor(Color.parseColor(bgHex))
                setStroke(dp(1), Color.parseColor(strokeHex))
            }
            setOnClickListener { onClick() }
        }
    }

    private fun buildFooterActionRow(
        leftText: String,
        onLeft: () -> Unit,
        rightText: String,
        onRight: () -> Unit
    ): LinearLayout {
        return LinearLayout(service).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.END
            addView(
                buildCompactCardChip(leftText, "#1F2937", "#6B7280", onLeft),
                LinearLayout.LayoutParams(
                    LinearLayout.LayoutParams.WRAP_CONTENT,
                    LinearLayout.LayoutParams.WRAP_CONTENT
                ).apply { rightMargin = dp(8) }
            )
            addView(buildCompactCardChip(rightText, "#2A2010", "#F59E0B", onRight))
        }
    }
}
