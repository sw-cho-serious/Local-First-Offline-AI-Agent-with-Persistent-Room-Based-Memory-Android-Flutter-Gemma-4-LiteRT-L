// Ghost Wheel concept inspired by/adapted from https://github.com/vNeeL-code/GHOST (MIT License).
// See THIRD_PARTY_NOTICES.md at the repository root.
package com.hako.kodari

import android.content.ContentValues
import android.content.Context
import android.database.sqlite.SQLiteDatabase
import java.util.Calendar
import java.util.Locale
import java.util.TreeSet

/**
 * Direct native SQLite bridge to sqflite's `kodari.db` for zero-app-launch GHOST actions.
 * Strictly preserves existing `- [x]`, `- [O]`, `- [ ]` lines (Anti-Wipe) and marks
 * `sync_status = 'pending'` so cloud handoff picks up every desktop write.
 */
object GhostLocalStore {

    private const val DB_NAME = "kodari.db"
    private const val MAIN_DATA_KEY = "para:areas:大廳雜記"
    private const val MAIN_ROOM_ID = "main"

    private val STATUS_PREFIX_REGEX = Regex("""^-\s*\[[ xXoO]\]\s*""")
    private val DONE_PREFIX_REGEX = Regex("""^-\s*\[[xXO]\]""")
    private val PENDING_PREFIX_REGEX = Regex("""^-\s*\[\s\]\s*""")
    private val HM_REGEX = Regex("""(\d{1,2})\s*[:：點時]\s*(\d{1,2})?""")
    private val ONCE_DATE_REGEX = Regex("""(\d{4})[-/](\d{1,2})[-/](\d{1,2})\s+(\d{1,2}):(\d{1,2})""")

    data class TodoAppendResult(
        val ok: Boolean,
        val duplicate: Boolean = false,
        val cleanedText: String = "",
        val error: String? = null
    )

    data class PendingTodoEntry(
        val roomId: String,
        val roomTitle: String,
        val lineIndex: Int,
        val text: String
    )

    data class PendingTodoSnapshot(
        val ok: Boolean,
        val entries: List<PendingTodoEntry> = emptyList(),
        val totalPending: Int = 0,
        val starredCount: Int = 0,
        val error: String? = null
    )

    data class RoutinePreviewItem(
        val id: String,
        val title: String,
        val body: String,
        val mode: String,
        val timeSpec: String,
        val enabled: Boolean,
        val nextTriggerMs: Long?,
        val formattedTime: String,
        val countdownText: String
    )

    private fun openDbWritable(context: Context): SQLiteDatabase? {
        val dbFile = context.getDatabasePath(DB_NAME)
        if (!dbFile.exists() || !dbFile.isFile) return null
        val db = SQLiteDatabase.openDatabase(
            dbFile.absolutePath,
            null,
            SQLiteDatabase.OPEN_READWRITE
        )
        try {
            db.rawQuery("PRAGMA busy_timeout = 3000", null).use { }
        } catch (_: Exception) {}
        return db
    }

    private fun tableExists(db: SQLiteDatabase, tableName: String): Boolean {
        return try {
            db.rawQuery(
                "SELECT name FROM sqlite_master WHERE type='table' AND name=? LIMIT 1",
                arrayOf(tableName)
            ).use { it.moveToFirst() }
        } catch (_: Exception) {
            false
        }
    }

    fun appendMainTodo(context: Context, rawText: String): TodoAppendResult {
        val normalized = rawText
            .replace("\r\n", "\n")
            .split('\n')
            .map { it.trim() }
            .filter { it.isNotEmpty() }
            .joinToString(" / ")
            .replace(STATUS_PREFIX_REGEX, "")
            .trim()
        if (normalized.isEmpty()) {
            return TodoAppendResult(ok = false, error = "內容空白")
        }

        val db = try {
            openDbWritable(context)
        } catch (e: Exception) {
            return TodoAppendResult(ok = false, error = e.message ?: "資料庫開啟失敗")
        } ?: return TodoAppendResult(ok = false, error = "請先開啟 KODARI 初始化資料庫")

        try {
            if (!tableExists(db, "data")) {
                return TodoAppendResult(ok = false, error = "找不到 data 資料表")
            }

            var existing = ""
            db.rawQuery(
                "SELECT value FROM data WHERE key = ? AND is_deleted = 0 LIMIT 1",
                arrayOf(MAIN_DATA_KEY)
            ).use { c ->
                if (c.moveToFirst()) {
                    existing = c.getString(0) ?: ""
                }
            }

            val lines = if (existing.trim().isEmpty()) {
                ArrayList()
            } else {
                existing.split('\n')
                    .map { it.trimEnd() }
                    .filter { it.isNotEmpty() }
                    .toMutableList()
            }

            val duplicate = lines.any { line ->
                line.replace(STATUS_PREFIX_REGEX, "").trim() == normalized
            }
            if (duplicate) {
                return TodoAppendResult(ok = true, duplicate = true, cleanedText = normalized)
            }

            lines.add("- [ ] $normalized")
            val newValue = lines.joinToString("\n")
            val now = System.currentTimeMillis()
            val values = ContentValues().apply {
                put("key", MAIN_DATA_KEY)
                put("room_id", MAIN_ROOM_ID)
                put("value", newValue)
                put("updated_at", now)
                put("sync_status", "pending")
                put("is_deleted", 0)
            }
            db.insertWithOnConflict("data", null, values, SQLiteDatabase.CONFLICT_REPLACE)
            return TodoAppendResult(ok = true, duplicate = false, cleanedText = normalized)
        } catch (e: Exception) {
            return TodoAppendResult(ok = false, error = e.message ?: "寫入待辦失敗")
        } finally {
            try {
                db.close()
            } catch (_: Exception) {}
        }
    }

    fun insertStarredPhotoMemo(
        context: Context,
        imagePath: String,
        content: String
    ): Long {
        val db = try {
            openDbWritable(context)
        } catch (_: Exception) {
            null
        } ?: return -1L

        try {
            if (!tableExists(db, "messages")) return -1L
            val now = System.currentTimeMillis()
            val values = ContentValues().apply {
                put("room_id", MAIN_ROOM_ID)
                put("role", "user")
                put("content", content)
                put("image_path", imagePath)
                put("tool_pill", "📷 桌面快收現場照")
                put("is_starred", 1)
                put("created_at", now)
                put("sync_status", "pending")
                put("is_deleted", 0)
            }
            return db.insert("messages", null, values)
        } catch (_: Exception) {
            return -1L
        } finally {
            try {
                db.close()
            } catch (_: Exception) {}
        }
    }

    fun loadPendingTodos(context: Context, maxItems: Int = 10): PendingTodoSnapshot {
        val db = try {
            openDbWritable(context)
        } catch (e: Exception) {
            return PendingTodoSnapshot(ok = false, error = e.message ?: "資料庫開啟失敗")
        } ?: return PendingTodoSnapshot(ok = false, error = "請先開啟 KODARI 初始化資料庫")

        try {
            if (!tableExists(db, "rooms") || !tableExists(db, "data")) {
                return PendingTodoSnapshot(ok = false, error = "尚未初始化工作房間")
            }

            val rooms = ArrayList<Pair<String, String>>()
            db.rawQuery(
                """
                SELECT room_id, title FROM rooms
                WHERE is_deleted = 0
                ORDER BY CASE WHEN room_id = 'main' THEN 0 WHEN room_id LIKE 'para:archives:%' THEN 2 ELSE 1 END,
                         updated_at DESC
                """.trimIndent(),
                null
            ).use { c ->
                while (c.moveToNext()) {
                    val rid = c.getString(0) ?: continue
                    val title = (c.getString(1) ?: rid).ifBlank { rid }
                    rooms.add(rid to title)
                }
            }

            val entries = ArrayList<PendingTodoEntry>()
            var totalPending = 0

            for ((roomId, roomTitle) in rooms) {
                val dataKey = if (roomId == MAIN_ROOM_ID) MAIN_DATA_KEY else roomId
                var rawMd = ""
                db.rawQuery(
                    "SELECT value FROM data WHERE key = ? AND is_deleted = 0 LIMIT 1",
                    arrayOf(dataKey)
                ).use { c ->
                    if (c.moveToFirst()) {
                        rawMd = c.getString(0) ?: ""
                    }
                }
                if (rawMd.trim().isEmpty()) continue

                val lines = rawMd.split('\n')
                for (idx in lines.indices) {
                    val line = lines[idx].trim()
                    if (line.isEmpty()) continue
                    if (DONE_PREFIX_REGEX.containsMatchIn(line)) continue
                    val clean = if (line.startsWith("- [ ]")) {
                        line.replaceFirst(PENDING_PREFIX_REGEX, "").trim()
                    } else {
                        line
                    }
                    if (clean.isEmpty()) continue
                    totalPending++
                    if (entries.size < maxItems) {
                        entries.add(PendingTodoEntry(roomId, roomTitle, idx, clean))
                    }
                }
            }

            var starredCount = 0
            if (tableExists(db, "messages")) {
                db.rawQuery(
                    "SELECT COUNT(*) FROM messages WHERE is_starred = 1 AND is_deleted = 0",
                    null
                ).use { c ->
                    if (c.moveToFirst()) {
                        starredCount = c.getInt(0)
                    }
                }
            }

            return PendingTodoSnapshot(
                ok = true,
                entries = entries,
                totalPending = totalPending,
                starredCount = starredCount
            )
        } catch (e: Exception) {
            return PendingTodoSnapshot(ok = false, error = e.message ?: "讀取待辦失敗")
        } finally {
            try {
                db.close()
            } catch (_: Exception) {}
        }
    }

    fun toggleTodoLine(context: Context, roomId: String, lineIndex: Int): Boolean {
        val db = try {
            openDbWritable(context)
        } catch (_: Exception) {
            null
        } ?: return false

        try {
            if (!tableExists(db, "data")) return false
            val dataKey = if (roomId == MAIN_ROOM_ID) MAIN_DATA_KEY else roomId
            var rawMd = ""
            db.rawQuery(
                "SELECT value FROM data WHERE key = ? AND is_deleted = 0 LIMIT 1",
                arrayOf(dataKey)
            ).use { c ->
                if (c.moveToFirst()) {
                    rawMd = c.getString(0) ?: ""
                }
            }
            if (rawMd.trim().isEmpty()) return false

            val lines = rawMd.split('\n').toMutableList()
            if (lineIndex < 0 || lineIndex >= lines.size) return false

            val line = lines[lineIndex]
            lines[lineIndex] = when {
                line.startsWith("- [x]") || line.startsWith("- [X]") || line.startsWith("- [O]") ->
                    line.replaceFirst(DONE_PREFIX_REGEX, "- [ ]")
                line.startsWith("- [ ]") ->
                    line.replaceFirst("- [ ]", "- [x]")
                else -> "- [x] $line"
            }

            val values = ContentValues().apply {
                put("key", dataKey)
                put("room_id", roomId)
                put("value", lines.joinToString("\n"))
                put("updated_at", System.currentTimeMillis())
                put("sync_status", "pending")
                put("is_deleted", 0)
            }
            db.insertWithOnConflict("data", null, values, SQLiteDatabase.CONFLICT_REPLACE)
            return true
        } catch (_: Exception) {
            return false
        } finally {
            try {
                db.close()
            } catch (_: Exception) {}
        }
    }

    fun loadUpcomingRoutines(context: Context, maxItems: Int = 5): Pair<Boolean, List<RoutinePreviewItem>> {
        val db = try {
            openDbWritable(context)
        } catch (_: Exception) {
            return false to emptyList()
        } ?: return false to emptyList()

        try {
            if (!tableExists(db, "routines")) {
                return true to emptyList()
            }
            val nowMs = System.currentTimeMillis()
            val items = ArrayList<RoutinePreviewItem>()
            db.rawQuery(
                """
                SELECT id, title, body, mode, time_spec, weekdays_csv, enabled
                FROM routines
                WHERE is_deleted = 0
                ORDER BY updated_at DESC, title ASC
                """.trimIndent(),
                null
            ).use { c ->
                while (c.moveToNext()) {
                    val id = c.getString(0) ?: continue
                    val title = c.getString(1) ?: "未命名排程"
                    val body = c.getString(2) ?: ""
                    val mode = c.getString(3) ?: "daily"
                    val timeSpec = c.getString(4) ?: "08:00"
                    val weekdaysCsv = c.getString(5) ?: "1,2,3,4,5,6"
                    val enabled = c.getInt(6) == 1

                    val weekdays = weekdaysCsv.split(',')
                        .mapNotNull { it.trim().toIntOrNull() }
                        .filter { it in 1..7 }
                        .toSet()

                    val nextMs = computeNextOccurrenceMs(mode, timeSpec, weekdays, nowMs)
                    val formatted = if (nextMs != null) {
                        formatCompactDateTime(nextMs)
                    } else {
                        "已過期或無未來時間"
                    }
                    val countdown = when {
                        !enabled -> "已暫停"
                        nextMs == null -> "無排程"
                        else -> formatCountdown(nextMs - nowMs)
                    }
                    items.add(
                        RoutinePreviewItem(
                            id = id,
                            title = title,
                            body = body,
                            mode = mode,
                            timeSpec = timeSpec,
                            enabled = enabled,
                            nextTriggerMs = nextMs,
                            formattedTime = formatted,
                            countdownText = countdown
                        )
                    )
                }
            }

            items.sortWith(
                compareBy<RoutinePreviewItem> { !it.enabled }
                    .thenBy { it.nextTriggerMs ?: Long.MAX_VALUE }
            )
            return true to items.take(maxItems)
        } catch (_: Exception) {
            return false to emptyList()
        } finally {
            try {
                db.close()
            } catch (_: Exception) {}
        }
    }

    fun toggleRoutineEnabled(context: Context, routineId: String, enabled: Boolean): Boolean {
        val db = try {
            openDbWritable(context)
        } catch (_: Exception) {
            null
        } ?: return false

        try {
            if (!tableExists(db, "routines")) return false
            val values = ContentValues().apply {
                put("enabled", if (enabled) 1 else 0)
                put("updated_at", System.currentTimeMillis())
                put("sync_status", "pending")
            }
            val rows = db.update("routines", values, "id = ?", arrayOf(routineId))
            return rows > 0
        } catch (_: Exception) {
            return false
        } finally {
            try {
                db.close()
            } catch (_: Exception) {}
        }
    }

    // -------------------------------------------------------------------------
    // Routine time math (strict parity with Dart RoutineScheduler)
    // -------------------------------------------------------------------------

    private fun parseHourMinute(spec: String): Pair<Int, Int> {
        val m = HM_REGEX.find(spec.trim())
        if (m != null) {
            val h = (m.groupValues[1].toIntOrNull() ?: 8).coerceIn(0, 23)
            val min = (m.groupValues.getOrNull(2)?.takeIf { it.isNotEmpty() }?.toIntOrNull() ?: 0)
                .coerceIn(0, 59)
            return h to min
        }
        return 8 to 0
    }

    private fun isoWeekday(cal: Calendar): Int {
        val dow = cal.get(Calendar.DAY_OF_WEEK)
        return if (dow == Calendar.SUNDAY) 7 else dow - 1
    }

    private fun computeNextOccurrenceMs(
        mode: String,
        timeSpec: String,
        weekdays: Set<Int>,
        fromMs: Long
    ): Long? {
        return when (mode) {
            "once" -> {
                val mDate = ONCE_DATE_REGEX.find(timeSpec.trim())
                if (mDate != null) {
                    val cal = Calendar.getInstance().apply {
                        set(Calendar.YEAR, mDate.groupValues[1].toInt())
                        set(Calendar.MONTH, (mDate.groupValues[2].toInt() - 1).coerceIn(0, 11))
                        set(Calendar.DAY_OF_MONTH, mDate.groupValues[3].toInt())
                        set(Calendar.HOUR_OF_DAY, mDate.groupValues[4].toInt().coerceIn(0, 23))
                        set(Calendar.MINUTE, mDate.groupValues[5].toInt().coerceIn(0, 59))
                        set(Calendar.SECOND, 0)
                        set(Calendar.MILLISECOND, 0)
                    }
                    if (cal.timeInMillis > fromMs) cal.timeInMillis else null
                } else {
                    val (h, min) = parseHourMinute(timeSpec)
                    val cal = Calendar.getInstance().apply {
                        timeInMillis = fromMs
                        set(Calendar.HOUR_OF_DAY, h)
                        set(Calendar.MINUTE, min)
                        set(Calendar.SECOND, 0)
                        set(Calendar.MILLISECOND, 0)
                    }
                    if (cal.timeInMillis <= fromMs) {
                        cal.add(Calendar.DAY_OF_MONTH, 1)
                    }
                    cal.timeInMillis
                }
            }
            "daily" -> {
                val (h, min) = parseHourMinute(timeSpec)
                val cal = Calendar.getInstance().apply {
                    timeInMillis = fromMs
                    set(Calendar.HOUR_OF_DAY, h)
                    set(Calendar.MINUTE, min)
                    set(Calendar.SECOND, 0)
                    set(Calendar.MILLISECOND, 0)
                }
                if (cal.timeInMillis <= fromMs) {
                    cal.add(Calendar.DAY_OF_MONTH, 1)
                }
                cal.timeInMillis
            }
            "weekly" -> {
                if (weekdays.isEmpty()) return null
                val (h, min) = parseHourMinute(timeSpec)
                for (offset in 0 until 60) {
                    val cal = Calendar.getInstance().apply {
                        timeInMillis = fromMs
                        set(Calendar.HOUR_OF_DAY, h)
                        set(Calendar.MINUTE, min)
                        set(Calendar.SECOND, 0)
                        set(Calendar.MILLISECOND, 0)
                        add(Calendar.DAY_OF_MONTH, offset)
                    }
                    if (cal.timeInMillis > fromMs && weekdays.contains(isoWeekday(cal))) {
                        return cal.timeInMillis
                    }
                }
                null
            }
            "cron" -> computeCronNextMs(timeSpec, fromMs)
            else -> null
        }
    }

    private fun computeCronNextMs(expr: String, fromMs: Long): Long? {
        val parts = expr.trim().split(Regex("""\s+"""))
        if (parts.size < 5) return null
        val minutes = expandCronField(parts[0], 0, 59)
        val hours = expandCronField(parts[1], 0, 23)
        val days = expandCronField(parts[2], 1, 31)
        val months = expandCronField(parts[3], 1, 12)
        val rawDows = expandCronField(parts[4], 0, 7)
        if (minutes.isEmpty() || hours.isEmpty() || days.isEmpty() || months.isEmpty() || rawDows.isEmpty()) {
            return null
        }
        val dows = rawDows.map { if (it == 0) 7 else it }.toSet()
        val domWild = parts[2].trim() == "*"
        val dowWild = parts[4].trim() == "*"

        for (dayOffset in 0 until 366) {
            val dayCal = Calendar.getInstance().apply {
                timeInMillis = fromMs
                set(Calendar.HOUR_OF_DAY, 0)
                set(Calendar.MINUTE, 0)
                set(Calendar.SECOND, 0)
                set(Calendar.MILLISECOND, 0)
                add(Calendar.DAY_OF_MONTH, dayOffset)
            }
            val month = dayCal.get(Calendar.MONTH) + 1
            if (!months.contains(month)) continue

            val domMatch = days.contains(dayCal.get(Calendar.DAY_OF_MONTH))
            val dowMatch = dows.contains(isoWeekday(dayCal))
            val dayOk = (domWild && dowWild) ||
                (domWild && dowMatch) ||
                (dowWild && domMatch) ||
                (!domWild && !dowWild && (domMatch || dowMatch))
            if (!dayOk) continue

            for (h in hours) {
                for (m in minutes) {
                    val cand = Calendar.getInstance().apply {
                        timeInMillis = dayCal.timeInMillis
                        set(Calendar.HOUR_OF_DAY, h)
                        set(Calendar.MINUTE, m)
                        set(Calendar.SECOND, 0)
                        set(Calendar.MILLISECOND, 0)
                    }
                    if (cand.timeInMillis > fromMs) {
                        return cand.timeInMillis
                    }
                }
            }
        }
        return null
    }

    private fun expandCronField(field: String, minVal: Int, maxVal: Int): TreeSet<Int> {
        val result = TreeSet<Int>()
        val f = field.trim()
        if (f.isEmpty()) return result
        for (seg in f.split(',')) {
            val part = seg.trim()
            if (part.isEmpty()) continue
            var step = 1
            var rangeExpr = part
            if (part.contains('/')) {
                val slash = part.split('/')
                rangeExpr = slash[0]
                step = (slash.getOrNull(1)?.toIntOrNull() ?: 1).coerceIn(1, maxVal - minVal + 1)
            }
            when {
                rangeExpr == "*" -> {
                    var v = minVal
                    while (v <= maxVal) {
                        result.add(v)
                        v += step
                    }
                }
                rangeExpr.contains('-') -> {
                    val bounds = rangeExpr.split('-')
                    val start = (bounds[0].toIntOrNull() ?: minVal).coerceIn(minVal, maxVal)
                    val end = (bounds.getOrNull(1)?.toIntOrNull() ?: maxVal).coerceIn(minVal, maxVal)
                    var v = start
                    while (v <= end) {
                        result.add(v)
                        v += step
                    }
                }
                else -> {
                    val exact = rangeExpr.toIntOrNull()
                    if (exact != null && exact in minVal..maxVal) {
                        result.add(exact)
                    }
                }
            }
        }
        return result
    }

    private fun formatCompactDateTime(ms: Long): String {
        val weekdaysZh = arrayOf("一", "二", "三", "四", "五", "六", "日")
        val cal = Calendar.getInstance().apply { timeInMillis = ms }
        val month = cal.get(Calendar.MONTH) + 1
        val day = cal.get(Calendar.DAY_OF_MONTH)
        val hh = String.format(Locale.US, "%02d", cal.get(Calendar.HOUR_OF_DAY))
        val mm = String.format(Locale.US, "%02d", cal.get(Calendar.MINUTE))
        val w = weekdaysZh[(isoWeekday(cal) - 1).coerceIn(0, 6)]
        return "$month/$day ($w) $hh:$mm"
    }

    private fun formatCountdown(diffMs: Long): String {
        if (diffMs <= 60_000L) return "即將觸發"
        val totalMin = diffMs / 60_000L
        val days = totalMin / (24L * 60L)
        val hours = (totalMin % (24L * 60L)) / 60L
        val mins = totalMin % 60L
        return when {
            days > 0 -> "還有 ${days}天 ${hours}小時"
            hours > 0 -> "還有 ${hours}小時 ${mins}分"
            else -> "還有 ${mins} 分"
        }
    }
}
