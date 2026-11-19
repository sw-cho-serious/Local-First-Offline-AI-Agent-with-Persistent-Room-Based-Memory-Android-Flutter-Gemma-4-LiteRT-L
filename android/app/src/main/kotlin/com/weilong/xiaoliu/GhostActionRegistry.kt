// Ghost Wheel concept inspired by/adapted from https://github.com/vNeeL-code/GHOST (MIT License).
// See THIRD_PARTY_NOTICES.md at the repository root.
package com.weilong.xiaoliu

import android.content.SharedPreferences

/**
 * Canonical 14-action pool and 6-slot symmetrical hexagon configuration
 * shared in exact ID parity with Flutter `WheelActionRegistry`.
 */
data class GhostActionMeta(
    val id: String,
    val emoji: String,
    val label: String,
    val inPlace: Boolean
)

object GhostActionRegistry {
    const val SLOT_COUNT = 6

    const val ID_TORCH = "torch"
    const val ID_LOCATION_SHARE = "location_share"
    const val ID_CLIPBOARD_MEMO = "clipboard_memo"
    const val ID_VOICE_MEMO = "voice_memo"
    const val ID_LATEST_PHOTO = "latest_photo"
    const val ID_TODO_PEEK = "todo_peek"
    const val ID_NEXT_ROUTINE = "next_routine"
    const val ID_WEATHER_DOULIU = "weather_douliu"
    const val ID_QUICK_TIMER = "quick_timer"
    const val ID_REFRESH_BOARDS = "refresh_boards"
    const val ID_CALCULATOR = "calculator"
    const val ID_OPEN_CUTTING = "open_cutting"
    const val ID_OPEN_ROOMS = "open_rooms"
    const val ID_OPEN_TEXT = "open_text"

    val DEFAULT_SLOTS: List<String> = listOf(
        ID_TORCH,
        ID_LOCATION_SHARE,
        ID_CLIPBOARD_MEMO,
        ID_VOICE_MEMO,
        ID_LATEST_PHOTO,
        ID_TODO_PEEK
    )

    val ALL_ACTIONS: List<GhostActionMeta> = listOf(
        GhostActionMeta(ID_TORCH, "🔦", "手電筒", inPlace = true),
        GhostActionMeta(ID_LOCATION_SHARE, "📍", "報位置", inPlace = true),
        GhostActionMeta(ID_CLIPBOARD_MEMO, "📋", "貼入備忘", inPlace = true),
        GhostActionMeta(ID_VOICE_MEMO, "🎙️", "語音速記", inPlace = true),
        GhostActionMeta(ID_LATEST_PHOTO, "📷", "存最新照", inPlace = true),
        GhostActionMeta(ID_TODO_PEEK, "📌", "今日待辦", inPlace = true),
        GhostActionMeta(ID_NEXT_ROUTINE, "🕒", "下個排程", inPlace = true),
        GhostActionMeta(ID_WEATHER_DOULIU, "🌦️", "現地天氣", inPlace = true),
        GhostActionMeta(ID_QUICK_TIMER, "⏱️", "快速計時", inPlace = true),
        GhostActionMeta(ID_REFRESH_BOARDS, "📡", "刷新戰情", inPlace = true),
        GhostActionMeta(ID_CALCULATOR, "🧮", "計算機", inPlace = true),
        GhostActionMeta(ID_OPEN_CUTTING, "🛠️", "離線查表", inPlace = false),
        GhostActionMeta(ID_OPEN_ROOMS, "📂", "案場工單", inPlace = false),
        GhostActionMeta(ID_OPEN_TEXT, "⌨️", "開啟對話", inPlace = false)
    )

    private val ACTION_MAP: Map<String, GhostActionMeta> = ALL_ACTIONS.associateBy { it.id }

    fun byId(id: String): GhostActionMeta? = ACTION_MAP[id]

    fun sanitizeSlots(raw: List<String>?): List<String> {
        val result = ArrayList<String>(SLOT_COUNT)
        val seen = HashSet<String>()
        raw?.forEach { rawId ->
            val id = rawId.trim()
            if (ACTION_MAP.containsKey(id) && seen.add(id)) {
                if (result.size < SLOT_COUNT) {
                    result.add(id)
                }
            }
        }
        for (defId in DEFAULT_SLOTS) {
            if (result.size >= SLOT_COUNT) break
            if (seen.add(defId)) {
                result.add(defId)
            }
        }
        for (meta in ALL_ACTIONS) {
            if (result.size >= SLOT_COUNT) break
            if (seen.add(meta.id)) {
                result.add(meta.id)
            }
        }
        return result.take(SLOT_COUNT)
    }

    fun loadSlots(prefs: SharedPreferences): List<String> {
        val csv = prefs.getString(GhostOverlayService.KEY_WHEEL_SLOTS, null) ?: return DEFAULT_SLOTS
        val parts = csv.split(',').map { it.trim() }.filter { it.isNotEmpty() }
        return sanitizeSlots(parts)
    }

    fun saveSlots(prefs: SharedPreferences, slots: List<String>): List<String> {
        val sanitized = sanitizeSlots(slots)
        prefs.edit()
            .putString(GhostOverlayService.KEY_WHEEL_SLOTS, sanitized.joinToString(","))
            .apply()
        return sanitized
    }
}
