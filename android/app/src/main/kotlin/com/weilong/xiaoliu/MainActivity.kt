package com.weilong.xiaoliu

import android.content.ContentValues
import android.provider.CalendarContract
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.util.TimeZone

class MainActivity : FlutterActivity() {
    companion object {
        private const val CALENDAR_CHANNEL = "com.weilong.hako/calendar"
    }

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
}
