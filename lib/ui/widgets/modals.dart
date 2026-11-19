import 'dart:async';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/token_estimator.dart';
import '../../data/database_helper.dart';
import '../../data/models.dart';
import '../../engine/llm_engine.dart';
import '../../sync/cloud_sync_service.dart';
import '../../tools/native_actions.dart';
import '../../tools/routine_scheduler.dart';
import '../../tools/tts_service.dart';
import '../../tools/web_search_service.dart';
import 'kodari_floating_nub.dart';
import 'spirit_avatar.dart';

/// 📋 Global Pending Memo Inbox Modal (Starred photos/messages + Cross-room pending todos)
Future<void> showPendingMemoInboxModal({
  required BuildContext context,
  required DatabaseHelper db,
  required void Function(String roomId) onJumpToRoom,
  required VoidCallback onDataChanged,
  required void Function(String msg) onToast,
}) async {
  await showDialog<void>(
    context: context,
    barrierColor: Colors.black.withValues(alpha: 0.72),
    builder: (ctx) {
      return StatefulBuilder(
        builder: (ctx, setModalState) {
          return Dialog(
            backgroundColor: const Color(0xFF1A1E26),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(20),
              side: BorderSide(color: Colors.white.withValues(alpha: 0.14)),
            ),
            insetPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 32),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 480, maxHeight: 620),
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        const Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                '📋 待我處理的備忘錄',
                                style: TextStyle(
                                  fontSize: 15,
                                  fontWeight: FontWeight.bold,
                                  color: Color(0xFFFCD34D),
                                ),
                              ),
                              SizedBox(height: 2),
                              Text(
                                '⭐ 標星暫存 ＋ 跨房未完成待辦總覽',
                                style: TextStyle(fontSize: 12, color: Color(0xFF9CA3AF)),
                              ),
                            ],
                          ),
                        ),
                        IconButton(
                          icon: const Icon(Icons.close, color: Color(0xFF9CA3AF)),
                          onPressed: () => Navigator.of(ctx).pop(),
                        ),
                      ],
                    ),
                    const SizedBox(height: 10),
                    Expanded(
                      child: FutureBuilder<GlobalPendingMemo>(
                        future: db.getGlobalPendingMemo(),
                        builder: (context, snap) {
                          if (!snap.hasData) {
                            return const Center(
                              child: CircularProgressIndicator(color: Color(0xFFF59E0B)),
                            );
                          }
                          final memo = snap.data!;
                          if (memo.totalCount == 0) {
                            return const Center(
                              child: Text(
                                '🎉 全部處理完畢，目前沒有待辦或標星照片！',
                                style: TextStyle(color: Color(0xFF9CA3AF), fontSize: 13),
                              ),
                            );
                          }
                          return ListView(
                            children: [
                              if (memo.starredMessages.isNotEmpty) ...[
                                Padding(
                                  padding: const EdgeInsets.only(bottom: 8),
                                  child: Text(
                                    '⭐ 標星暫存區（${memo.starredMessages.length}）',
                                    style: const TextStyle(
                                      fontSize: 12.5,
                                      fontWeight: FontWeight.w600,
                                      color: Color(0xFFFCD34D),
                                    ),
                                  ),
                                ),
                                for (final item in memo.starredMessages)
                                  Container(
                                    margin: const EdgeInsets.only(bottom: 8),
                                    padding: const EdgeInsets.all(10),
                                    decoration: BoxDecoration(
                                      color: const Color(0xFF111317),
                                      borderRadius: BorderRadius.circular(12),
                                      border: Border.all(
                                        color: const Color(0xFFF59E0B).withValues(alpha: 0.35),
                                      ),
                                    ),
                                    child: Row(
                                      children: [
                                        Expanded(
                                          child: Column(
                                            crossAxisAlignment: CrossAxisAlignment.start,
                                            children: [
                                              Text(
                                                '${item.message.imagePath != null ? '📷 ' : ''}${item.room?.title ?? item.message.roomId}',
                                                style: const TextStyle(
                                                  fontSize: 12.5,
                                                  fontWeight: FontWeight.w600,
                                                  color: Color(0xFFFDE68A),
                                                ),
                                                overflow: TextOverflow.ellipsis,
                                              ),
                                              const SizedBox(height: 2),
                                              Text(
                                                item.message.content,
                                                style: const TextStyle(
                                                  fontSize: 12,
                                                  color: Color(0xFF9CA3AF),
                                                ),
                                                maxLines: 2,
                                                overflow: TextOverflow.ellipsis,
                                              ),
                                            ],
                                          ),
                                        ),
                                        const SizedBox(width: 6),
                                        Column(
                                          children: [
                                            TextButton(
                                              style: TextButton.styleFrom(
                                                backgroundColor: const Color(0xFFF59E0B).withValues(alpha: 0.2),
                                                foregroundColor: const Color(0xFFFCD34D),
                                                minimumSize: const Size(74, 32),
                                                padding: const EdgeInsets.symmetric(horizontal: 8),
                                              ),
                                              onPressed: () {
                                                Navigator.of(ctx).pop();
                                                onJumpToRoom(item.message.roomId);
                                              },
                                              child: const Text('跳去該房', style: TextStyle(fontSize: 11.5)),
                                            ),
                                            const SizedBox(height: 4),
                                            TextButton(
                                              style: TextButton.styleFrom(
                                                backgroundColor: Colors.white.withValues(alpha: 0.06),
                                                foregroundColor: const Color(0xFFD1D5DB),
                                                minimumSize: const Size(74, 32),
                                                padding: const EdgeInsets.symmetric(horizontal: 8),
                                              ),
                                              onPressed: () async {
                                                await db.setMessageStarred(item.message.id, false);
                                                onDataChanged();
                                                setModalState(() {});
                                                onToast('⭐ 已消星結案');
                                              },
                                              child: const Text('消星結案', style: TextStyle(fontSize: 11.5)),
                                            ),
                                          ],
                                        ),
                                      ],
                                    ),
                                  ),
                              ],
                              if (memo.pendingTodoGroups.isNotEmpty) ...[
                                const SizedBox(height: 6),
                                const Padding(
                                  padding: EdgeInsets.only(bottom: 8),
                                  child: Text(
                                    '⬜ 跨房未完成待辦總表',
                                    style: TextStyle(
                                      fontSize: 12.5,
                                      fontWeight: FontWeight.w600,
                                      color: Color(0xFF34D399),
                                    ),
                                  ),
                                ),
                                for (final group in memo.pendingTodoGroups) ...[
                                  Padding(
                                    padding: const EdgeInsets.only(bottom: 4, top: 4),
                                    child: Row(
                                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                                      children: [
                                        Text(
                                          '${group.room.title} (${group.todos.length})',
                                          style: const TextStyle(
                                            fontSize: 12,
                                            fontWeight: FontWeight.w600,
                                            color: Color(0xFFD1D5DB),
                                          ),
                                        ),
                                        InkWell(
                                          onTap: () {
                                            Navigator.of(ctx).pop();
                                            onJumpToRoom(group.room.roomId);
                                          },
                                          child: const Text(
                                            '進房 →',
                                            style: TextStyle(fontSize: 11.5, color: Color(0xFFF59E0B)),
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                                  for (final todo in group.todos)
                                    Container(
                                      margin: const EdgeInsets.only(bottom: 6),
                                      decoration: BoxDecoration(
                                        color: const Color(0xFF111317),
                                        borderRadius: BorderRadius.circular(10),
                                        border: Border.all(color: Colors.white.withValues(alpha: 0.09)),
                                      ),
                                      child: CheckboxListTile(
                                        dense: true,
                                        controlAffinity: ListTileControlAffinity.leading,
                                        activeColor: const Color(0xFFF59E0B),
                                        value: false,
                                        title: Text(
                                          todo.text,
                                          style: const TextStyle(fontSize: 12.5, color: Color(0xFFE5E7EB)),
                                        ),
                                        onChanged: (_) async {
                                          await db.toggleTodoAtIndex(group.room.roomId, todo.lineIndex);
                                          onDataChanged();
                                          setModalState(() {});
                                          onToast('✅ 已打勾結案');
                                        },
                                      ),
                                    ),
                                ],
                              ],
                            ],
                          );
                        },
                      ),
                    ),
                  ],
                ),
              ),
            ),
          );
        },
      );
    },
  );
}

/// 🔍 Pure Local SQLite Offline Lookup Modal (Zero AI wait)
Future<void> showOfflineLookupModal({
  required BuildContext context,
  required DatabaseHelper db,
  required void Function(String msg) onToast,
}) async {
  final controller = TextEditingController();
  await showDialog<void>(
    context: context,
    barrierColor: Colors.black.withValues(alpha: 0.72),
    builder: (ctx) {
      return StatefulBuilder(
        builder: (ctx, setModalState) {
          final query = controller.text.trim();
          return Dialog(
            backgroundColor: const Color(0xFF1A1E26),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(20),
              side: BorderSide(color: Colors.white.withValues(alpha: 0.14)),
            ),
            insetPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 32),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 480, maxHeight: 580),
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        const Text(
                          '🔍 離線極速查表（免等 AI）',
                          style: TextStyle(
                            fontSize: 15,
                            fontWeight: FontWeight.bold,
                            color: Color(0xFFFCD34D),
                          ),
                        ),
                        IconButton(
                          icon: const Icon(Icons.close, color: Color(0xFF9CA3AF)),
                          onPressed: () => Navigator.of(ctx).pop(),
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    TextField(
                      controller: controller,
                      autofocus: true,
                      style: const TextStyle(color: Colors.white, fontSize: 13.5),
                      decoration: InputDecoration(
                        hintText: '輸入料號或關鍵字（如 094、098M、WL2045、3060X）',
                        hintStyle: const TextStyle(color: Color(0xFF6B7280), fontSize: 12.5),
                        filled: true,
                        fillColor: const Color(0xFF0E1014),
                        contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(12),
                          borderSide: BorderSide(color: Colors.white.withValues(alpha: 0.15)),
                        ),
                        enabledBorder: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(12),
                          borderSide: BorderSide(color: Colors.white.withValues(alpha: 0.15)),
                        ),
                        focusedBorder: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(12),
                          borderSide: const BorderSide(color: Color(0xFFF59E0B)),
                        ),
                      ),
                      onChanged: (_) => setModalState(() {}),
                    ),
                    const SizedBox(height: 12),
                    Expanded(
                      child: FutureBuilder<(List<ProfileRecord>, List<MachineTuningRecord>)>(
                        future: () async {
                          final p = await db.lookupProfiles(query);
                          final t = await db.lookupMachineTuning(query);
                          return (p, t);
                        }(),
                        builder: (context, snap) {
                          if (!snap.hasData) {
                            return const Center(child: CircularProgressIndicator());
                          }
                          final (profiles, tunings) = snap.data!;
                          if (profiles.isEmpty && tunings.isEmpty) {
                            return const Center(
                              child: Text(
                                '查無參數（嚴禁模型推論）',
                                style: TextStyle(color: Color(0xFF9CA3AF), fontSize: 13),
                              ),
                            );
                          }
                          return ListView(
                            children: [
                              if (tunings.isNotEmpty) ...[
                                const Text(
                                  '🔧 調機與加工公式',
                                  style: TextStyle(fontSize: 12, color: Color(0xFF38BDF8), fontWeight: FontWeight.w600),
                                ),
                                const SizedBox(height: 6),
                                for (final t in tunings)
                                  Container(
                                    margin: const EdgeInsets.only(bottom: 8),
                                    padding: const EdgeInsets.all(10),
                                    decoration: BoxDecoration(
                                      color: const Color(0xFF111317),
                                      borderRadius: BorderRadius.circular(10),
                                      border: Border.all(color: Colors.white.withValues(alpha: 0.1)),
                                    ),
                                    child: Column(
                                      crossAxisAlignment: CrossAxisAlignment.start,
                                      children: [
                                        Row(
                                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                                          children: [
                                            Expanded(
                                              child: Text(
                                                t.title,
                                                style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 13, color: Color(0xFF7DD3FC)),
                                              ),
                                            ),
                                            IconButton(
                                              icon: const Icon(Icons.copy, size: 16, color: Color(0xFF9CA3AF)),
                                              constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
                                              padding: EdgeInsets.zero,
                                              onPressed: () async {
                                                await Clipboard.setData(ClipboardData(text: '${t.title}: ${t.formula}'));
                                                onToast('📋 已複製調機公式');
                                              },
                                            ),
                                          ],
                                        ),
                                        Text(t.formula, style: const TextStyle(fontSize: 12.5, color: Color(0xFFE5E7EB))),
                                        if (t.note.isNotEmpty)
                                          Padding(
                                            padding: const EdgeInsets.only(top: 4),
                                            child: Text(t.note, style: const TextStyle(fontSize: 11.5, color: Color(0xFF9CA3AF))),
                                          ),
                                      ],
                                    ),
                                  ),
                              ],
                              if (profiles.isNotEmpty) ...[
                                const SizedBox(height: 4),
                                Text(
                                  '🔩 鋁料規格與單重（顯示 ${profiles.length} 筆）',
                                  style: const TextStyle(fontSize: 12, color: Color(0xFFFCD34D), fontWeight: FontWeight.w600),
                                ),
                                const SizedBox(height: 6),
                                for (final p in profiles)
                                  Container(
                                    margin: const EdgeInsets.only(bottom: 8),
                                    padding: const EdgeInsets.all(10),
                                    decoration: BoxDecoration(
                                      color: const Color(0xFF111317),
                                      borderRadius: BorderRadius.circular(10),
                                      border: Border.all(color: Colors.white.withValues(alpha: 0.1)),
                                    ),
                                    child: Column(
                                      crossAxisAlignment: CrossAxisAlignment.start,
                                      children: [
                                        Row(
                                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                                          children: [
                                            Text(
                                              '${p.code}  •  ${p.weightPerM.toStringAsFixed(2)} kg/m',
                                              style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 13, color: Color(0xFFFCD34D)),
                                            ),
                                            if (p.extrudable)
                                              Container(
                                                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                                                decoration: BoxDecoration(
                                                  color: const Color(0xFF10B981).withValues(alpha: 0.18),
                                                  borderRadius: BorderRadius.circular(6),
                                                ),
                                                child: const Text('可排抽 >=300kg', style: TextStyle(fontSize: 10.5, color: Color(0xFF34D399))),
                                              ),
                                          ],
                                        ),
                                        const SizedBox(height: 3),
                                        Text('${p.stockRule}  |  ${p.note}', style: const TextStyle(fontSize: 12, color: Color(0xFFD1D5DB))),
                                      ],
                                    ),
                                  ),
                              ],
                            ],
                          );
                        },
                      ),
                    ),
                  ],
                ),
              ),
            ),
          );
        },
      );
    },
  );
}

/// ➕ Create New Room Dialog with fixed color palette & accessory picker
Future<RoomRecord?> showCreateRoomDialog({
  required BuildContext context,
  required DatabaseHelper db,
  String? initialTitle,
}) async {
  final controller = TextEditingController(text: initialTitle ?? '');
  final colors = [
    ('#F59E0B', '琥珀急單'),
    ('#3B82F6', '科技藍'),
    ('#10B981', '出車綠'),
    ('#A16207', '廠務棕'),
    ('#EC4899', '生活粉'),
    ('#8B5CF6', '其他紫'),
    ('#06B6D4', '霓虹青'),
    ('#94A3B8', '鐵灰銀'),
    ('#F97316', '暖橘紅'),
    ('#34D399', '薄荷綠'),
  ];
  final accessories = [
    ('helmet', '⛑️ 工安帽'),
    ('wrench', '🔧 銀板手'),
    ('box', '📦 HAKO箱'),
    ('bulb', '💡 靈感燈'),
    ('glasses', '🕶️ 酷墨鏡'),
    ('fish', '🐟 釣魚佬'),
    ('home', '🏠 小屋頂'),
    ('none', '✨ 純淨版'),
  ];
  var selectedColor = colors.first.$1;
  var selectedAccessory = 'helmet';

  return showDialog<RoomRecord>(
    context: context,
    barrierColor: Colors.black.withValues(alpha: 0.72),
    builder: (ctx) {
      return StatefulBuilder(
        builder: (ctx, setState) {
          return AlertDialog(
            backgroundColor: const Color(0xFF1A1E26),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(20),
              side: BorderSide(color: Colors.white.withValues(alpha: 0.14)),
            ),
            title: const Text('➕ 建立新工作房間', style: TextStyle(color: Colors.white, fontSize: 16)),
            content: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Center(
                    child: Container(
                      padding: const EdgeInsets.all(10),
                      decoration: BoxDecoration(
                        color: const Color(0xFF0E1014),
                        borderRadius: BorderRadius.circular(18),
                        border: Border.all(
                          color: parseHexColor(selectedColor).withValues(alpha: 0.38),
                        ),
                      ),
                      child: SpiritAvatar(
                        colorHex: selectedColor,
                        state: SpiritState.idle,
                        size: 68,
                        accessory: selectedAccessory,
                      ),
                    ),
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: controller,
                    autofocus: true,
                    style: const TextStyle(color: Colors.white, fontSize: 14),
                    decoration: InputDecoration(
                      hintText: '案場或領域名稱（例：勵宏 莿桐案）',
                      hintStyle: const TextStyle(color: Color(0xFF6B7280), fontSize: 13),
                      filled: true,
                      fillColor: const Color(0xFF0E1014),
                      border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
                    ),
                  ),
                  const SizedBox(height: 14),
                  const Text('小精靈代表色', style: TextStyle(color: Color(0xFF9CA3AF), fontSize: 12)),
                  const SizedBox(height: 8),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      for (final (hex, label) in colors)
                        ChoiceChip(
                          label: Text(label, style: const TextStyle(fontSize: 11.5)),
                          selected: selectedColor == hex,
                          selectedColor: parseHexColor(hex).withValues(alpha: 0.35),
                          backgroundColor: const Color(0xFF111317),
                          labelStyle: const TextStyle(color: Colors.white),
                          avatar: CircleAvatar(backgroundColor: parseHexColor(hex), radius: 7),
                          onSelected: (_) => setState(() => selectedColor = hex),
                        ),
                    ],
                  ),
                  const SizedBox(height: 14),
                  const Text('專屬配件類型（自由混搭）', style: TextStyle(color: Color(0xFF9CA3AF), fontSize: 12)),
                  const SizedBox(height: 8),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      for (final (accKey, accLabel) in accessories)
                        ChoiceChip(
                          label: Text(accLabel, style: const TextStyle(fontSize: 11.5)),
                          selected: selectedAccessory == accKey,
                          selectedColor: parseHexColor(selectedColor).withValues(alpha: 0.35),
                          backgroundColor: const Color(0xFF111317),
                          labelStyle: const TextStyle(color: Colors.white),
                          onSelected: (_) => setState(() => selectedAccessory = accKey),
                        ),
                    ],
                  ),
                ],
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(ctx).pop(),
                child: const Text('取消', style: TextStyle(color: Color(0xFF9CA3AF))),
              ),
              ElevatedButton(
                style: ElevatedButton.styleFrom(
                  backgroundColor: const Color(0xFFF59E0B),
                  foregroundColor: const Color(0xFF111317),
                ),
                onPressed: () async {
                  final title = controller.text.trim();
                  if (title.isEmpty) return;
                  final created = await db.createRoom(
                    title: title,
                    colorHex: selectedColor,
                    accessory: selectedAccessory,
                  );
                  if (ctx.mounted) Navigator.of(ctx).pop(created);
                },
                child: const Text('建立房間', style: TextStyle(fontWeight: FontWeight.bold)),
              ),
            ],
          );
        },
      );
    },
  );
}

/// 🧠 Traits Viewer / Editor + Prompt Budget & Self-Rescue Modal
Future<void> showTraitsEditorModal({
  required BuildContext context,
  required DatabaseHelper db,
  required void Function(String msg) onToast,
  LlmEngine? engine,
  String? roomId,
  VoidCallback? onDataChanged,
}) async {
  final traits = await db.getAllTraits();
  final activeRoomId = roomId ?? 'main';
  var room = await db.getRoom(activeRoomId);
  var todos = await db.getRoomTodos(activeRoomId);
  var msgs = await db.getMessages(activeRoomId);
  var pendingFlags = await db.getOperatorFlags(onlyUnreviewed: true);

  if (!context.mounted) return;
  final keys = ['SOUL.md', 'VOICE.md', 'USER.md', 'relationship.md', 'mood.md', 'MEMORY.md'];
  var activeKey = keys.first;
  final editor = TextEditingController(text: traits[activeKey] ?? '');
  var busyAction = false;

  await showDialog<void>(
    context: context,
    barrierColor: Colors.black.withValues(alpha: 0.72),
    builder: (ctx) {
      return StatefulBuilder(
        builder: (ctx, setState) {
          final maxCap = engine?.effectiveMaxContextTokens ?? TokenEstimator.maxContextTokens;
          var traitTokens = 0;
          for (final k in keys) {
            final txt = k == activeKey ? editor.text : (traits[k] ?? '');
            traitTokens += TokenEstimator.estimateTextTokens(txt);
          }
          final summaryAndTodoTokens = TokenEstimator.estimateTextTokens(
            '${room?.rollingSummary ?? ''}\n${todos.map((t) => t.text).join('\n')}',
          );
          final minId = room?.summarizedUntilMsgId ?? 0;
          var activeMsgs = msgs.where((m) => m.id > minId).toList();
          final lastDiv = activeMsgs.lastIndexWhere((m) => m.role == 'divider');
          if (lastDiv != -1) activeMsgs = activeMsgs.sublist(lastDiv + 1);
          if (activeMsgs.length > 8) activeMsgs = activeMsgs.sublist(activeMsgs.length - 8);
          var chatTokens = 0;
          for (final m in activeMsgs) {
            chatTokens += TokenEstimator.estimateTextTokens(m.content);
            if ((m.imagePath ?? '').trim().isNotEmpty) chatTokens += 384;
          }
          final totalBudgetTokens = traitTokens + summaryAndTodoTokens + chatTokens;
          final ratio = (totalBudgetTokens / maxCap).clamp(0.0, 1.0);
          final over = traitTokens >= 800;

          return Dialog(
            backgroundColor: const Color(0xFF1A1E26),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(20),
              side: BorderSide(color: Colors.white.withValues(alpha: 0.14)),
            ),
            insetPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 28),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 490, maxHeight: 580),
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        const Text('🧠 靈魂記憶與 Prompt 空間預算', style: TextStyle(color: Colors.white, fontSize: 15, fontWeight: FontWeight.bold)),
                        IconButton(
                          icon: const Icon(Icons.close, color: Color(0xFF9CA3AF)),
                          onPressed: () => Navigator.of(ctx).pop(),
                        ),
                      ],
                    ),
                    // Prompt Budget Breakdown Meter
                    Container(
                      width: double.infinity,
                      margin: const EdgeInsets.only(bottom: 8),
                      padding: const EdgeInsets.all(10),
                      decoration: BoxDecoration(
                        color: const Color(0xFF12151B),
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(color: Colors.white.withValues(alpha: 0.08)),
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            mainAxisAlignment: MainAxisAlignment.spaceBetween,
                            children: [
                              Text(
                                'Prompt 空間佔比：${TokenEstimator.formatCompact(totalBudgetTokens)} / ${TokenEstimator.formatCompact(maxCap)} (${(ratio * 100).round()}%)',
                                style: TextStyle(
                                  fontSize: 11.5,
                                  fontWeight: FontWeight.w600,
                                  color: ratio > 0.85
                                      ? const Color(0xFFFB7185)
                                      : (ratio >= 0.70 ? const Color(0xFFFCD34D) : const Color(0xFF93C5FD)),
                                ),
                              ),
                              Text(
                                '人設 $traitTokens · 摘要/待辦 $summaryAndTodoTokens · 對話 $chatTokens',
                                style: const TextStyle(fontSize: 10, color: Color(0xFF9CA3AF)),
                              ),
                            ],
                          ),
                          const SizedBox(height: 6),
                          ClipRRect(
                            borderRadius: BorderRadius.circular(99),
                            child: LinearProgressIndicator(
                              value: ratio,
                              minHeight: 6,
                              backgroundColor: const Color(0xFF262A34),
                              color: ratio > 0.85
                                  ? const Color(0xFFFB7185)
                                  : (ratio >= 0.70 ? const Color(0xFFF59E0B) : const Color(0xFF38BDF8)),
                            ),
                          ),
                          if (engine != null) ...[
                            const SizedBox(height: 8),
                            Row(
                              children: [
                                Expanded(
                                  child: OutlinedButton(
                                    style: OutlinedButton.styleFrom(
                                      padding: const EdgeInsets.symmetric(vertical: 6),
                                      side: BorderSide(color: const Color(0xFF38BDF8).withValues(alpha: 0.4)),
                                      foregroundColor: const Color(0xFF7DD3FC),
                                    ),
                                    onPressed: busyAction
                                        ? null
                                        : () async {
                                            setState(() => busyAction = true);
                                            try {
                                              final res = await engine.forceCompactRoom(activeRoomId);
                                              room = await db.getRoom(activeRoomId);
                                              msgs = await db.getMessages(activeRoomId);
                                              onDataChanged?.call();
                                              onToast(res.compacted
                                                  ? '✂️ 已強制壓縮：${res.beforeTokens} → ${res.afterTokens} tok'
                                                  : '✂️ 已清空當前 KV-Cache 並維持精簡');
                                            } finally {
                                              if (ctx.mounted) setState(() => busyAction = false);
                                            }
                                          },
                                    child: const Text('✂️ 立即壓縮 (/compact)', style: TextStyle(fontSize: 11.5)),
                                  ),
                                ),
                                const SizedBox(width: 8),
                                Expanded(
                                  child: OutlinedButton(
                                    style: OutlinedButton.styleFrom(
                                      padding: const EdgeInsets.symmetric(vertical: 6),
                                      side: BorderSide(color: const Color(0xFFF43F5E).withValues(alpha: 0.45)),
                                      foregroundColor: const Color(0xFFFDA4AF),
                                    ),
                                    onPressed: busyAction
                                        ? null
                                        : () async {
                                            if (pendingFlags.isEmpty) {
                                              onToast('🚩 目前沒有尚未反省的插旗紀錄');
                                              return;
                                            }
                                            setState(() => busyAction = true);
                                            try {
                                              final res = await engine.runIdleFlaggedReflection(forceManual: true);
                                              final refreshed = await db.getAllTraits();
                                              traits['MEMORY.md'] = refreshed['MEMORY.md'] ?? '';
                                              pendingFlags = await db.getOperatorFlags(onlyUnreviewed: true);
                                              if (activeKey == 'MEMORY.md') {
                                                editor.text = traits['MEMORY.md'] ?? '';
                                              }
                                              onDataChanged?.call();
                                              onToast('🚩 已檢討 ${res.reviewedCount} 筆插旗，寫入 MEMORY.md！');
                                            } finally {
                                              if (ctx.mounted) setState(() => busyAction = false);
                                            }
                                          },
                                    child: Text('🚩 自省糾錯 (${pendingFlags.length})', style: const TextStyle(fontSize: 11.5)),
                                  ),
                                ),
                              ],
                            ),
                          ],
                        ],
                      ),
                    ),
                    SingleChildScrollView(
                      scrollDirection: Axis.horizontal,
                      child: Row(
                        children: [
                          for (final k in keys)
                            Padding(
                              padding: const EdgeInsets.only(right: 6),
                              child: ChoiceChip(
                                label: Text(k, style: const TextStyle(fontSize: 11.5)),
                                selected: activeKey == k,
                                onSelected: (_) {
                                  traits[activeKey] = editor.text;
                                  setState(() {
                                    activeKey = k;
                                    editor.text = traits[k] ?? '';
                                  });
                                },
                              ),
                            ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 8),
                    Expanded(
                      child: TextField(
                        controller: editor,
                        maxLines: null,
                        expands: true,
                        textAlignVertical: TextAlignVertical.top,
                        style: const TextStyle(color: Color(0xFFE5E7EB), fontSize: 13),
                        onChanged: (_) => setState(() {}),
                        decoration: InputDecoration(
                          filled: true,
                          fillColor: const Color(0xFF0E1014),
                          border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
                        ),
                      ),
                    ),
                    const SizedBox(height: 6),
                    Text(
                      '目前人設共佔約 $traitTokens tokens（建議 < 800）',
                      style: TextStyle(
                        fontSize: 11.5,
                        color: over ? const Color(0xFFF59E0B) : const Color(0xFF9CA3AF),
                        fontWeight: over ? FontWeight.w600 : FontWeight.normal,
                      ),
                    ),
                    const SizedBox(height: 8),
                    SizedBox(
                      width: double.infinity,
                      child: ElevatedButton(
                        style: ElevatedButton.styleFrom(
                          backgroundColor: const Color(0xFFF59E0B),
                          foregroundColor: const Color(0xFF111317),
                        ),
                        onPressed: () async {
                          await db.upsertTrait(activeKey, editor.text);
                          onToast('🧠 已儲存 $activeKey（下輪對話生效）');
                          if (ctx.mounted) Navigator.of(ctx).pop();
                        },
                        child: const Text('儲存修改', style: TextStyle(fontWeight: FontWeight.bold)),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          );
        },
      );
    },
  );
}

/// ⚙️ Model & Dual-Channel (LiteRT / Termux-Y700 GGUF) Settings Modal
Future<void> showModelSettingsModal({
  required BuildContext context,
  required LlmEngine engine,
  required VoidCallback onStateChanged,
  required void Function(String msg) onToast,
}) async {
  var busy = false;
  var progress = 0;
  final peerCtrl = TextEditingController(
    text: await WebSearchService.getConfiguredPeerUrl(),
  );
  var inAppNub = await FloatingOverlayPreferences.getInAppNubEnabled();
  var ghostOverlay = await FloatingOverlayPreferences.getGhostOverlayEnabled();
  var shakeWake = await FloatingOverlayPreferences.getShakeToWakeEnabled();
  var wheelSlots = await FloatingOverlayPreferences.getWheelSlots();
  var hasOverlayPerm = await NativeActions.checkOverlayPermission();
  List<File> detectedModels = [];
  try {
    detectedModels = await engine.scanAvailableModelFiles();
  } catch (_) {}

  if (!context.mounted) return;

  await showDialog<void>(
    context: context,
    barrierColor: Colors.black.withValues(alpha: 0.72),
    builder: (ctx) {
      return StatefulBuilder(
        builder: (ctx, setState) {
          return AlertDialog(
            backgroundColor: const Color(0xFF1A1E26),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(20),
              side: BorderSide(color: Colors.white.withValues(alpha: 0.14)),
            ),
            title: const Text('⚙️ 模型與引擎設定', style: TextStyle(color: Colors.white, fontSize: 16)),
            content: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '目前引擎：${engine.activeBackendLabel}',
                    style: const TextStyle(color: Color(0xFFFCD34D), fontSize: 13, fontWeight: FontWeight.w600),
                  ),
                  const SizedBox(height: 10),
                  Text(
                    engine.installedModelPath ?? '尚未綁定 .litertlm 檔案（目前為離線查表預覽）',
                    style: const TextStyle(color: Color(0xFF9CA3AF), fontSize: 11.5),
                  ),
                    const SizedBox(height: 10),
                    SwitchListTile(
                      contentPadding: EdgeInsets.zero,
                      title: const Text('優先使用 GPU 加速', style: TextStyle(color: Colors.white, fontSize: 13.5)),
                      subtitle: const Text('若遇數字/日期亂碼可切換為純 CPU', style: TextStyle(color: Color(0xFF9CA3AF), fontSize: 11.5)),
                      activeThumbColor: const Color(0xFFF59E0B),
                      value: engine.useGpu,
                      onChanged: busy
                          ? null
                          : (v) async {
                              setState(() => busy = true);
                              try {
                                await engine.setUseGpu(v);
                                onStateChanged();
                                onToast(v ? '⚡ 已切換 GPU 模式' : '🛡️ 已切換 CPU 模式');
                              } catch (e) {
                                onToast('切換失敗：$e');
                              } finally {
                                if (ctx.mounted) setState(() => busy = false);
                              }
                            },
                    ),
                    const SizedBox(height: 8),
                    if (detectedModels.isNotEmpty) ...[
                      const Divider(color: Color(0x1FFFFFFF), height: 18),
                      const Text(
                        '⚡ 本機已探測模型（點擊一鍵換腦）：',
                        style: TextStyle(color: Color(0xFF6EE7B7), fontSize: 12, fontWeight: FontWeight.w600),
                      ),
                      const SizedBox(height: 6),
                      ...detectedModels.map((file) {
                        final fileName = file.path.split(Platform.pathSeparator).last;
                        final isCurrent = engine.installedModelPath == file.path;
                        int sizeBytes = 0;
                        try {
                          sizeBytes = file.lengthSync();
                        } catch (_) {}
                        final sizeStr = sizeBytes > 0
                            ? '${(sizeBytes / (1024 * 1024 * 1024)).toStringAsFixed(2)} GB'
                            : '';
                        return Container(
                          margin: const EdgeInsets.only(bottom: 6),
                          decoration: BoxDecoration(
                            color: isCurrent ? const Color(0xFF1E3A2F) : const Color(0xFF12151B),
                            borderRadius: BorderRadius.circular(10),
                            border: Border.all(
                              color: isCurrent ? const Color(0xFF10B981) : Colors.white.withValues(alpha: 0.1),
                              width: isCurrent ? 1.5 : 1,
                            ),
                          ),
                          child: ListTile(
                            dense: true,
                            contentPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 2),
                            leading: Icon(
                              isCurrent ? Icons.check_circle : Icons.model_training,
                              color: isCurrent ? const Color(0xFF34D399) : const Color(0xFF9CA3AF),
                              size: 20,
                            ),
                            title: Text(
                              fileName,
                              style: TextStyle(
                                color: isCurrent ? Colors.white : const Color(0xFFE5E7EB),
                                fontSize: 12,
                                fontWeight: isCurrent ? FontWeight.bold : FontWeight.normal,
                              ),
                            ),
                            subtitle: sizeStr.isNotEmpty
                                ? Text(sizeStr, style: const TextStyle(color: Color(0xFF6B7280), fontSize: 10.5))
                                : null,
                            trailing: isCurrent
                                ? const Text('運行中', style: TextStyle(color: Color(0xFF34D399), fontSize: 11, fontWeight: FontWeight.bold))
                                : TextButton(
                                    onPressed: busy
                                        ? null
                                        : () async {
                                            setState(() => busy = true);
                                            try {
                                              await engine.configureEngineChannel(channel: 'litert');
                                              await engine.installFromFilePath(file.path);
                                              onStateChanged();
                                              onToast('✅ 已一鍵切換至 $fileName');
                                              if (ctx.mounted) Navigator.of(ctx).pop();
                                            } catch (e) {
                                              onToast('切換失敗：$e');
                                            } finally {
                                              if (ctx.mounted) setState(() => busy = false);
                                            }
                                          },
                                    child: const Text('切換', style: TextStyle(color: Color(0xFF60A5FA), fontSize: 12)),
                                  ),
                          ),
                        );
                      }),
                      const SizedBox(height: 6),
                    ],
                    if (busy) ...[
                      LinearProgressIndicator(
                        value: progress > 0 ? progress / 100.0 : null,
                        color: const Color(0xFFF59E0B),
                        backgroundColor: const Color(0xFF262930),
                      ),
                      const SizedBox(height: 6),
                      Text(
                        progress > 0 ? '下載／載入中 $progress%...' : '正在載入 3.7GB 模型至記憶體，請稍候...',
                        style: const TextStyle(color: Color(0xFF9CA3AF), fontSize: 12),
                      ),
                      const SizedBox(height: 8),
                    ],
                    SizedBox(
                      width: double.infinity,
                      child: OutlinedButton.icon(
                        icon: const Icon(Icons.folder_open, size: 18),
                        label: const Text('選取本機 .litertlm 模型檔'),
                        onPressed: busy
                            ? null
                            : () async {
                                final picked = await FilePicker.pickFile(
                                  dialogTitle: '選取 gemma-4-E4B-it.litertlm',
                                  type: FileType.any,
                                );
                                final path = picked?.path;
                                if (path == null) return;
                                setState(() => busy = true);
                                try {
                                  await engine.configureEngineChannel(channel: 'litert');
                                  await engine.installFromFilePath(path);
                                  onStateChanged();
                                  onToast('✅ Gemma 4 E4B 載入成功！');
                                  if (ctx.mounted) Navigator.of(ctx).pop();
                                } catch (e) {
                                  onToast('載入失敗：$e');
                                } finally {
                                  if (ctx.mounted) setState(() => busy = false);
                                }
                              },
                      ),
                    ),
                    const SizedBox(height: 8),
                    SizedBox(
                      width: double.infinity,
                      child: OutlinedButton.icon(
                        icon: const Icon(Icons.cloud_download_outlined, size: 18),
                        label: const Text('線上安裝 Gemma-4-E4B-it (3.7GB)'),
                        onPressed: busy
                            ? null
                            : () async {
                                setState(() {
                                  busy = true;
                                  progress = 0;
                                });
                                try {
                                  await engine.configureEngineChannel(channel: 'litert');
                                  await engine.installFromCatalog(
                                    onProgress: (p) {
                                      if (ctx.mounted) setState(() => progress = p);
                                    },
                                  );
                                  onStateChanged();
                                  onToast('✅ 模型下載並載入成功！');
                                  if (ctx.mounted) Navigator.of(ctx).pop();
                                } catch (e) {
                                  onToast('下載失敗：$e');
                                } finally {
                                  if (ctx.mounted) setState(() => busy = false);
                                }
                              },
                      ),
                    ),
                  const Divider(color: Color(0x1FFFFFFF), height: 22),
                  const Text(
                    '🛸 consult_peer 支援閘道（選填，預設沿用 GAS 網址）：',
                    style: TextStyle(color: Color(0xFFA78BFA), fontSize: 11.5, fontWeight: FontWeight.w600),
                  ),
                  const SizedBox(height: 6),
                  Row(
                    children: [
                      Expanded(
                        child: TextField(
                          controller: peerCtrl,
                          style: const TextStyle(color: Colors.white, fontSize: 11.5),
                          decoration: InputDecoration(
                            hintText: 'GAS URL 或 Tailscale HTTP Endpoint',
                            hintStyle: const TextStyle(color: Color(0xFF6B7280), fontSize: 11),
                            filled: true,
                            fillColor: const Color(0xFF12151B),
                            border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
                            contentPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                          ),
                        ),
                      ),
                      const SizedBox(width: 6),
                      OutlinedButton(
                        onPressed: () async {
                          await WebSearchService.savePeerEndpointUrl(peerCtrl.text);
                          onToast('🛸 已儲存 Peer 支援閘道網址');
                        },
                        child: const Text('存', style: TextStyle(fontSize: 12)),
                      ),
                    ],
                  ),
                  const Divider(color: Color(0x1FFFFFFF), height: 22),
                  const Text(
                    '👻 KODARI 懸浮球與單手操控設定',
                    style: TextStyle(color: Color(0xFFFCD34D), fontSize: 12.5, fontWeight: FontWeight.w600),
                  ),
                  const SizedBox(height: 4),
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    dense: true,
                    activeThumbColor: const Color(0xFFF59E0B),
                    title: const Text('App 內貼邊懸浮球', style: TextStyle(color: Colors.white, fontSize: 13)),
                    subtitle: const Text('點按開 6 軌輪盤 • 長按直接語音 • 4 秒無操作半透明待機', style: TextStyle(color: Color(0xFF9CA3AF), fontSize: 11)),
                    value: inAppNub,
                    onChanged: busy
                        ? null
                        : (v) async {
                            await FloatingOverlayPreferences.setInAppNubEnabled(v);
                            setState(() => inAppNub = v);
                            onStateChanged();
                            onToast(v ? '✨ 已開啟 App 內 KODARI 懸浮球' : '已隱藏 App 內懸浮球');
                          },
                  ),
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    dense: true,
                    activeThumbColor: const Color(0xFFF59E0B),
                    title: const Text('桌面全域常駐懸浮球 (GHOST 冰涼模式)', style: TextStyle(color: Colors.white, fontSize: 13)),
                    subtitle: Text(
                      hasOverlayPerm
                          ? '像 iPhone 小白點般貼邊常駐 • 點擊原地開金色輪盤 (0% CPU 不噴電)'
                          : '尚未授予「顯示於其他應用程式上層」權限（開啟即引導設定）',
                      style: TextStyle(
                        color: hasOverlayPerm ? const Color(0xFF9CA3AF) : const Color(0xFFFBBF24),
                        fontSize: 11,
                      ),
                    ),
                    value: ghostOverlay,
                    onChanged: busy
                        ? null
                        : (v) async {
                            if (v) {
                              final perm = await NativeActions.checkOverlayPermission();
                              hasOverlayPerm = perm;
                              if (!perm) {
                                await NativeActions.requestOverlayPermission();
                                setState(() {
                                  hasOverlayPerm = false;
                                  ghostOverlay = false;
                                });
                                onToast('請在系統頁開啟「允許顯示於其他應用程式上層」，再回來打開此開關');
                                return;
                              }
                            }
                            final res = await NativeActions.setGhostOverlayEnabled(v);
                            if (res['ok'] == true) {
                              await FloatingOverlayPreferences.setGhostOverlayEnabled(v);
                              setState(() => ghostOverlay = v);
                              onStateChanged();
                              onToast(v ? '👻 桌面常駐模式已待命，跳回桌面立即現身' : '已停用桌面全域懸浮球');
                            } else if (res['needsPermission'] == true) {
                              await NativeActions.requestOverlayPermission();
                              onToast('請先授予懸浮窗顯示權限');
                            } else {
                              onToast('⚠️ 切換失敗：${res['reason'] ?? ''}');
                            }
                          },
                  ),
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    dense: true,
                    activeThumbColor: const Color(0xFFF59E0B),
                    title: const Text('搖一搖喚醒語音（預設關閉）', style: TextStyle(color: Colors.white, fontSize: 13)),
                    subtitle: const Text('開貨車／現場移動晃動大建議維持 OFF，避免誤觸語音', style: TextStyle(color: Color(0xFF9CA3AF), fontSize: 11)),
                    value: shakeWake,
                    onChanged: busy
                        ? null
                        : (v) async {
                            await FloatingOverlayPreferences.setShakeToWakeEnabled(v);
                            await NativeActions.setShakeToWakeEnabled(v);
                            setState(() => shakeWake = v);
                            onStateChanged();
                            onToast(v ? '🫨 已開啟前景搖一搖喚醒語音' : '🛡️ 已關閉搖一搖（防貨車誤觸）');
                          },
                  ),
                  const SizedBox(height: 6),
                  InkWell(
                    borderRadius: BorderRadius.circular(12),
                    onTap: busy
                        ? null
                        : () async {
                            await showWheelSlotCustomizerModal(
                              context: ctx,
                              initialSlots: wheelSlots,
                              onSaved: (updated) {
                                setState(() => wheelSlots = updated);
                                onStateChanged();
                              },
                              onToast: onToast,
                            );
                          },
                    child: Container(
                      width: double.infinity,
                      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                      decoration: BoxDecoration(
                        color: const Color(0xFF111317),
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(
                          color: const Color(0xFFF59E0B).withValues(alpha: 0.45),
                        ),
                      ),
                      child: Row(
                        children: [
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                const Text(
                                  '🎡 自訂輪盤 6 軌捷徑（免開 App 動作池）',
                                  style: TextStyle(
                                    color: Color(0xFFFCD34D),
                                    fontSize: 12.5,
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                                const SizedBox(height: 3),
                                Text(
                                  wheelSlots
                                      .map((id) {
                                        final spec = WheelActionRegistry.byId(id);
                                        return spec == null ? id : '${spec.emoji}${spec.label}';
                                      })
                                      .join('  '),
                                  style: const TextStyle(color: Color(0xFFD1D5DB), fontSize: 11),
                                  maxLines: 2,
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ],
                            ),
                          ),
                          const SizedBox(width: 6),
                          const Icon(Icons.tune_rounded, color: Color(0xFFF59E0B), size: 18),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ),
            actions: [
              TextButton(
                onPressed: busy ? null : () => Navigator.of(ctx).pop(),
                child: const Text('關閉', style: TextStyle(color: Color(0xFF9CA3AF))),
              ),
            ],
          );
        },
      );
    },
  );
  peerCtrl.dispose();
}

String _formatSyncTimestamp(int ms) {
  if (ms <= 0) return '尚未同步';
  final dt = DateTime.fromMillisecondsSinceEpoch(ms).toLocal();
  final y = dt.year;
  final m = dt.month.toString().padLeft(2, '0');
  final d = dt.day.toString().padLeft(2, '0');
  final hh = dt.hour.toString().padLeft(2, '0');
  final mm = dt.minute.toString().padLeft(2, '0');
  return '$y/$m/$d $hh:$mm';
}

/// ☁️ Phase 2 Cloud Handoff & Sync Modal (GAS Gateway + Clipboard Snapshot)
Future<void> showCloudSyncModal({
  required BuildContext context,
  required CloudSyncService syncService,
  required VoidCallback onDataMerged,
  required void Function(String msg) onToast,
}) async {
  await syncService.refreshPendingCount();
  if (!context.mounted) return;

  await showDialog<void>(
    context: context,
    barrierColor: Colors.black.withValues(alpha: 0.72),
    builder: (ctx) => _CloudSyncDialog(
      syncService: syncService,
      onDataMerged: onDataMerged,
      onToast: onToast,
    ),
  );
}

class _CloudSyncDialog extends StatefulWidget {
  const _CloudSyncDialog({
    required this.syncService,
    required this.onDataMerged,
    required this.onToast,
  });

  final CloudSyncService syncService;
  final VoidCallback onDataMerged;
  final void Function(String msg) onToast;

  @override
  State<_CloudSyncDialog> createState() => _CloudSyncDialogState();
}

class _CloudSyncDialogState extends State<_CloudSyncDialog> {
  late final TextEditingController _urlCtrl;
  late final TextEditingController _tokenCtrl;

  @override
  void initState() {
    super.initState();
    _urlCtrl = TextEditingController(text: widget.syncService.gasUrl);
    _tokenCtrl = TextEditingController(text: widget.syncService.syncToken);
  }

  @override
  void dispose() {
    _urlCtrl.dispose();
    _tokenCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: widget.syncService,
      builder: (ctx, _) {
        final syncService = widget.syncService;
        final isSyncing = syncService.isSyncing;
        return Dialog(
          backgroundColor: const Color(0xFF1A1E26),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(20),
            side: BorderSide(color: Colors.white.withValues(alpha: 0.14)),
          ),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 500),
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(18),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      const Expanded(
                        child: Text(
                          '☁️ HAKO 雙機雲端交班 (P2)',
                          style: TextStyle(
                            color: Colors.white,
                            fontSize: 16,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ),
                      IconButton(
                        icon: const Icon(Icons.close, color: Color(0xFF9CA3AF), size: 20),
                        onPressed: () => Navigator.of(ctx).pop(),
                      ),
                    ],
                  ),
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: const Color(0xFF0E1014),
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(color: Colors.white.withValues(alpha: 0.08)),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          '狀態：${syncService.lastStatusMessage}',
                          style: const TextStyle(color: Color(0xFFE5E7EB), fontSize: 12.5),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          '上次同步：${_formatSyncTimestamp(syncService.lastSyncAtMs)}  •  待推異動：${syncService.pendingCount} 筆',
                          style: const TextStyle(color: Color(0xFF9CA3AF), fontSize: 12),
                        ),
                        const SizedBox(height: 4),
                        const Text(
                          '物理隔離：僅連接獨立 HAKO 交班試算表，絕不碰工廠庫存／毛料資產表。',
                          style: TextStyle(color: Color(0xFF34D399), fontSize: 11.5),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 14),
                  const Text(
                    'Google Apps Script Web App URL',
                    style: TextStyle(color: Color(0xFFD1D5DB), fontSize: 12, fontWeight: FontWeight.w600),
                  ),
                  const SizedBox(height: 6),
                  TextField(
                    controller: _urlCtrl,
                    style: const TextStyle(color: Colors.white, fontSize: 12.5),
                    decoration: InputDecoration(
                      hintText: 'https://script.google.com/macros/s/.../exec',
                      hintStyle: const TextStyle(color: Color(0xFF6B7280), fontSize: 12),
                      filled: true,
                      fillColor: const Color(0xFF0E1014),
                      contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                      border: OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
                    ),
                  ),
                  const SizedBox(height: 10),
                  const Text(
                    '同步密鑰 Token（選填，對應 GAS SYNC_TOKEN）',
                    style: TextStyle(color: Color(0xFFD1D5DB), fontSize: 12, fontWeight: FontWeight.w600),
                  ),
                  const SizedBox(height: 6),
                  TextField(
                    controller: _tokenCtrl,
                    obscureText: true,
                    style: const TextStyle(color: Colors.white, fontSize: 12.5),
                    decoration: InputDecoration(
                      hintText: '未設定可留空',
                      hintStyle: const TextStyle(color: Color(0xFF6B7280), fontSize: 12),
                      filled: true,
                      fillColor: const Color(0xFF0E1014),
                      contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                      border: OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
                    ),
                  ),
                  const SizedBox(height: 12),
                  Row(
                    children: [
                      Expanded(
                        child: OutlinedButton(
                          onPressed: isSyncing
                              ? null
                              : () async {
                                  await syncService.saveConfig(
                                    url: _urlCtrl.text,
                                    token: _tokenCtrl.text,
                                  );
                                  widget.onToast('💾 已儲存 HAKO 雲端閘道設定');
                                },
                          child: const Text('儲存設定'),
                        ),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        flex: 2,
                        child: ElevatedButton.icon(
                          style: ElevatedButton.styleFrom(
                            backgroundColor: const Color(0xFFF59E0B),
                            foregroundColor: const Color(0xFF111317),
                          ),
                          icon: isSyncing
                              ? const SizedBox(
                                  width: 15,
                                  height: 15,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                    color: Color(0xFF111317),
                                  ),
                                )
                              : const Icon(Icons.cloud_sync_outlined, size: 18),
                          label: Text(
                            isSyncing ? '同步中…' : '立即雙向同步',
                            style: const TextStyle(fontWeight: FontWeight.bold),
                          ),
                          onPressed: isSyncing
                              ? null
                              : () async {
                                  await syncService.saveConfig(
                                    url: _urlCtrl.text,
                                    token: _tokenCtrl.text,
                                  );
                                  final res = await syncService.syncNow();
                                  if (res.ok) {
                                    widget.onDataMerged();
                                  }
                                  widget.onToast(res.message);
                                },
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 16),
                  const Divider(color: Color(0xFF2D333F)),
                  const SizedBox(height: 10),
                  const Text(
                    '📦 免網路／無 GAS 快速交班包（Sony ⇄ Fold 6）',
                    style: TextStyle(color: Color(0xFFD1D5DB), fontSize: 12, fontWeight: FontWeight.w600),
                  ),
                  const SizedBox(height: 8),
                  Row(
                    children: [
                      Expanded(
                        child: OutlinedButton.icon(
                          icon: const Icon(Icons.upload_file_outlined, size: 17),
                          label: const Text('複製完整交班', style: TextStyle(fontSize: 12.5)),
                          onPressed: isSyncing
                              ? null
                              : () async {
                                  final jsonStr = await syncService.exportFullSnapshotJson();
                                  await Clipboard.setData(ClipboardData(text: jsonStr));
                                  widget.onToast('📤 已複製 HAKO 完整交班包到剪貼簿');
                                },
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: OutlinedButton.icon(
                          icon: const Icon(Icons.download_for_offline_outlined, size: 17),
                          label: const Text('貼上匯入交班', style: TextStyle(fontSize: 12.5)),
                          onPressed: isSyncing
                              ? null
                              : () async {
                                  final clip = await Clipboard.getData(Clipboard.kTextPlain);
                                  if (!ctx.mounted) return;
                                  final pastedJson = await showDialog<String>(
                                    context: ctx,
                                    builder: (_) => _ImportSnapshotDialog(
                                      initialText: clip?.text ?? '',
                                    ),
                                  );
                                  if (pastedJson == null || pastedJson.trim().isEmpty) return;
                                  try {
                                    final merged = await syncService.importSnapshotJson(pastedJson);
                                    widget.onDataMerged();
                                    widget.onToast('✅ 已合併 ${merged.upserted} 筆、套用刪除 ${merged.deleted} 筆');
                                  } catch (e) {
                                    widget.onToast('匯入失敗：請確認是 HAKO 交班 JSON（$e）');
                                  }
                                },
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}

class _ImportSnapshotDialog extends StatefulWidget {
  const _ImportSnapshotDialog({required this.initialText});

  final String initialText;

  @override
  State<_ImportSnapshotDialog> createState() => _ImportSnapshotDialogState();
}

class _ImportSnapshotDialogState extends State<_ImportSnapshotDialog> {
  late final TextEditingController _pasteCtrl;

  @override
  void initState() {
    super.initState();
    _pasteCtrl = TextEditingController(text: widget.initialText);
  }

  @override
  void dispose() {
    _pasteCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      backgroundColor: const Color(0xFF1A1E26),
      title: const Text(
        '📥 匯入交班 JSON',
        style: TextStyle(color: Colors.white, fontSize: 15),
      ),
      content: SizedBox(
        width: 420,
        child: TextField(
          controller: _pasteCtrl,
          maxLines: 7,
          style: const TextStyle(color: Color(0xFFE5E7EB), fontSize: 12),
          decoration: InputDecoration(
            hintText: '在此貼上另一支手機複製的交班 JSON…',
            hintStyle: const TextStyle(color: Color(0xFF6B7280)),
            filled: true,
            fillColor: const Color(0xFF0E1014),
            border: OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('取消'),
        ),
        ElevatedButton(
          style: ElevatedButton.styleFrom(
            backgroundColor: const Color(0xFFF59E0B),
            foregroundColor: const Color(0xFF111317),
          ),
          onPressed: () => Navigator.of(context).pop(_pasteCtrl.text),
          child: const Text('合併匯入'),
        ),
      ],
    );
  }
}

/// 🔊 Built-in TTS Rate, Pitch & Voice Selector Modal
Future<void> showTtsSettingsModal({
  required BuildContext context,
  required void Function(String msg) onToast,
}) async {
  final tts = TtsService.instance;
  final voices = await tts.getAvailableChineseVoices();
  if (!context.mounted) return;

  var rate = tts.speechRate;
  var pitch = tts.pitch;
  var selectedVoiceName = tts.voiceName ?? '';

  await showDialog<void>(
    context: context,
    barrierColor: Colors.black.withValues(alpha: 0.72),
    builder: (ctx) {
      return StatefulBuilder(
        builder: (ctx, setState) {
          return AlertDialog(
            backgroundColor: const Color(0xFF1A1E26),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(20),
              side: BorderSide(color: Colors.white.withValues(alpha: 0.14)),
            ),
            title: const Text(
              '🔊 語音語速與音色設定',
              style: TextStyle(color: Colors.white, fontSize: 16),
            ),
            content: SizedBox(
              width: 400,
              child: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        const Text('語速（預設 0.55）', style: TextStyle(color: Color(0xFFD1D5DB), fontSize: 13)),
                        Text(rate.toStringAsFixed(2), style: const TextStyle(color: Color(0xFFFCD34D), fontSize: 13, fontWeight: FontWeight.bold)),
                      ],
                    ),
                    Slider(
                      value: rate,
                      min: 0.30,
                      max: 0.95,
                      divisions: 13,
                      activeColor: const Color(0xFFF59E0B),
                      onChanged: (v) async {
                        setState(() => rate = v);
                        await tts.updateSettings(rate: v);
                      },
                    ),
                    const SizedBox(height: 6),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        const Text('音調（預設 1.00）', style: TextStyle(color: Color(0xFFD1D5DB), fontSize: 13)),
                        Text(pitch.toStringAsFixed(2), style: const TextStyle(color: Color(0xFFFCD34D), fontSize: 13, fontWeight: FontWeight.bold)),
                      ],
                    ),
                    Slider(
                      value: pitch,
                      min: 0.65,
                      max: 1.40,
                      divisions: 15,
                      activeColor: const Color(0xFF38BDF8),
                      onChanged: (v) async {
                        setState(() => pitch = v);
                        await tts.updateSettings(pitch: v);
                      },
                    ),
                    const SizedBox(height: 10),
                    Text(
                      '系統中文聲線（共 ${voices.length} 組）',
                      style: const TextStyle(color: Color(0xFF9CA3AF), fontSize: 12),
                    ),
                    const SizedBox(height: 8),
                    if (voices.isEmpty)
                      const Text(
                        '目前引擎未回傳多組聲線，仍可透過上方「語速 / 音調」微調。',
                        style: TextStyle(color: Color(0xFF6B7280), fontSize: 12),
                      )
                    else
                      Wrap(
                        spacing: 6,
                        runSpacing: 6,
                        children: [
                          ChoiceChip(
                            label: const Text('系統預設', style: TextStyle(fontSize: 11.5)),
                            selected: selectedVoiceName.isEmpty,
                            onSelected: (_) async {
                              setState(() => selectedVoiceName = '');
                              await tts.updateSettings(clearVoice: true);
                            },
                          ),
                          for (var i = 0; i < voices.length; i++)
                            ChoiceChip(
                              label: Text(
                                '聲線 ${i + 1} (${voices[i].name.replaceAll('cmn-tw-x-', '').replaceAll('-local', '').replaceAll('-network', '☁')})',
                                style: const TextStyle(fontSize: 11),
                              ),
                              selected: selectedVoiceName == voices[i].name,
                              onSelected: (_) async {
                                setState(() => selectedVoiceName = voices[i].name);
                                await tts.updateSettings(voice: voices[i]);
                              },
                            ),
                        ],
                      ),
                    const SizedBox(height: 14),
                    SizedBox(
                      width: double.infinity,
                      child: OutlinedButton.icon(
                        style: OutlinedButton.styleFrom(
                          foregroundColor: const Color(0xFFFDE68A),
                          side: BorderSide(color: const Color(0xFFF59E0B).withValues(alpha: 0.45)),
                        ),
                        icon: const Icon(Icons.play_arrow_rounded, size: 18),
                        label: const Text('試聽目前聲音效果'),
                        onPressed: () {
                          tts.speak('嗨，我是你的現場助理 KODARI，這個語速和音調聽起來順耳嗎？');
                        },
                      ),
                    ),
                  ],
                ),
              ),
            ),
            actions: [
              TextButton(
                onPressed: () {
                  tts.stop();
                  Navigator.of(ctx).pop();
                  onToast('🔊 語音設定已儲存');
                },
                child: const Text('完成', style: TextStyle(color: Color(0xFFF59E0B), fontWeight: FontWeight.bold)),
              ),
            ],
          );
        },
      );
    },
  );
}

/// 🧩 Self-Expanding JS/Formula Hook Manager Modal (view, test, add, delete)
Future<void> showHookManagerModal({
  required BuildContext context,
  required DatabaseHelper db,
  required VoidCallback onChanged,
  required void Function(String msg) onToast,
}) async {
  await showDialog<void>(
    context: context,
    barrierColor: Colors.black.withValues(alpha: 0.72),
    builder: (ctx) {
      var selectedHookName = '';
      final argsCtrl = TextEditingController();
      var testResultText = '';

      return StatefulBuilder(
        builder: (ctx, setState) {
          return Dialog(
            backgroundColor: const Color(0xFF1A1E26),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(20),
              side: BorderSide(color: Colors.white.withValues(alpha: 0.14)),
            ),
            insetPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 24),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 500, maxHeight: 650),
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        const Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                '🧩 自我擴充技能 Hook 管理',
                                style: TextStyle(
                                  fontSize: 15.5,
                                  fontWeight: FontWeight.bold,
                                  color: Color(0xFFFCD34D),
                                ),
                              ),
                              SizedBox(height: 2),
                              Text(
                                '免重編 APK 新增公式技能（支援 P2 雙機同步）',
                                style: TextStyle(fontSize: 11.5, color: Color(0xFF9CA3AF)),
                              ),
                            ],
                          ),
                        ),
                        IconButton(
                          icon: const Icon(Icons.add_circle_outline, color: Color(0xFF34D399)),
                          tooltip: '新增自訂技能',
                          onPressed: () async {
                            await _showCreateHookDialog(
                              context: ctx,
                              db: db,
                              onToast: onToast,
                            );
                            onChanged();
                            setState(() {});
                          },
                        ),
                        IconButton(
                          icon: const Icon(Icons.close, color: Color(0xFF9CA3AF)),
                          onPressed: () => Navigator.of(ctx).pop(),
                        ),
                      ],
                    ),
                    const SizedBox(height: 10),
                    Expanded(
                      child: FutureBuilder<List<HookRecord>>(
                        future: db.getHooks(),
                        builder: (context, snap) {
                          if (!snap.hasData) {
                            return const Center(
                              child: CircularProgressIndicator(color: Color(0xFFF59E0B)),
                            );
                          }
                          final hooks = snap.data!;
                          if (hooks.isEmpty) {
                            return const Center(
                              child: Text(
                                '目前尚無技能，點右上角 ＋ 新增公式技能！',
                                style: TextStyle(color: Color(0xFF9CA3AF), fontSize: 13),
                              ),
                            );
                          }
                          final active = hooks.any((h) => h.name == selectedHookName)
                              ? hooks.firstWhere((h) => h.name == selectedHookName)
                              : hooks.first;

                          return ListView(
                            children: [
                              Wrap(
                                spacing: 6,
                                runSpacing: 6,
                                children: [
                                  for (final h in hooks)
                                    ChoiceChip(
                                      label: Text(h.name, style: const TextStyle(fontSize: 12)),
                                      selected: active.name == h.name,
                                      onSelected: (_) {
                                        setState(() {
                                          selectedHookName = h.name;
                                          testResultText = '';
                                          argsCtrl.clear();
                                        });
                                      },
                                    ),
                                ],
                              ),
                              const SizedBox(height: 12),
                              Container(
                                padding: const EdgeInsets.all(12),
                                decoration: BoxDecoration(
                                  color: const Color(0xFF111317),
                                  borderRadius: BorderRadius.circular(12),
                                  border: Border.all(color: Colors.white.withValues(alpha: 0.1)),
                                ),
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Row(
                                      children: [
                                        Expanded(
                                          child: Text(
                                            active.name,
                                            style: const TextStyle(
                                              color: Color(0xFFFCD34D),
                                              fontSize: 14,
                                              fontWeight: FontWeight.bold,
                                            ),
                                          ),
                                        ),
                                        IconButton(
                                          icon: const Icon(Icons.delete_outline, color: Color(0xFFFB7185), size: 18),
                                          tooltip: '刪除技能',
                                          onPressed: () async {
                                            await db.deleteHook(active.name);
                                            onChanged();
                                            setState(() {
                                              selectedHookName = '';
                                              testResultText = '';
                                            });
                                            onToast('🗑️ 已刪除技能「${active.name}」');
                                          },
                                        ),
                                      ],
                                    ),
                                    if (active.description.isNotEmpty)
                                      Text(
                                        active.description,
                                        style: const TextStyle(color: Color(0xFFD1D5DB), fontSize: 12),
                                      ),
                                    const SizedBox(height: 6),
                                    Text(
                                      '參數：${active.params.isEmpty ? '（無參數）' : active.paramsCsv}',
                                      style: const TextStyle(color: Color(0xFF38BDF8), fontSize: 11.5),
                                    ),
                                    const SizedBox(height: 8),
                                    Container(
                                      width: double.infinity,
                                      padding: const EdgeInsets.all(8),
                                      decoration: BoxDecoration(
                                        color: const Color(0xFF0A0C0F),
                                        borderRadius: BorderRadius.circular(8),
                                      ),
                                      child: Text(
                                        active.body,
                                        style: const TextStyle(
                                          fontFamily: 'monospace',
                                          fontSize: 11.5,
                                          color: Color(0xFF9CA3AF),
                                        ),
                                      ),
                                    ),
                                    const SizedBox(height: 10),
                                    Row(
                                      children: [
                                        Expanded(
                                          child: TextField(
                                            controller: argsCtrl,
                                            style: const TextStyle(color: Colors.white, fontSize: 12.5),
                                            decoration: InputDecoration(
                                              hintText: active.params.isEmpty
                                                  ? '免填參數可直接執行'
                                                  : '依序填：${active.params.join(' ')}',
                                              hintStyle: const TextStyle(color: Color(0xFF6B7280), fontSize: 11.5),
                                              filled: true,
                                              fillColor: const Color(0xFF1A1E26),
                                              isDense: true,
                                              border: OutlineInputBorder(
                                                borderRadius: BorderRadius.circular(8),
                                                borderSide: BorderSide(color: Colors.white.withValues(alpha: 0.14)),
                                              ),
                                            ),
                                          ),
                                        ),
                                        const SizedBox(width: 8),
                                        ElevatedButton(
                                          style: ElevatedButton.styleFrom(
                                            backgroundColor: const Color(0xFF10B981),
                                            foregroundColor: const Color(0xFF111317),
                                          ),
                                          onPressed: () {
                                            setState(() {
                                              testResultText = 'ℹ️ JS Hook 已退役，請至 Skill 知識包建立 SKILL.md 技能';
                                            });
                                          },
                                          child: const Text('試跑', style: TextStyle(fontWeight: FontWeight.bold)),
                                        ),
                                      ],
                                    ),
                                    if (testResultText.isNotEmpty) ...[
                                      const SizedBox(height: 8),
                                      Text(
                                        testResultText,
                                        style: TextStyle(
                                          color: testResultText.startsWith('✅')
                                              ? const Color(0xFF6EE7B7)
                                              : const Color(0xFFFCA5A5),
                                          fontSize: 12.5,
                                          fontWeight: FontWeight.w600,
                                        ),
                                      ),
                                    ],
                                  ],
                                ),
                              ),
                              const SizedBox(height: 8),
                              const Text(
                                '💡 對話框也能直接打「@技能 估重109 0.45 3200 10」或「@技能 註冊 名稱 | 說明 | a,b | a*b*1.09」',
                                style: TextStyle(color: Color(0xFF6B7280), fontSize: 11.5),
                              ),
                            ],
                          );
                        },
                      ),
                    ),
                  ],
                ),
              ),
            ),
          );
        },
      );
    },
  );
}

Future<void> _showCreateHookDialog({
  required BuildContext context,
  required DatabaseHelper db,
  required void Function(String msg) onToast,
}) async {
  final nameCtrl = TextEditingController();
  final descCtrl = TextEditingController();
  final paramsCtrl = TextEditingController();
  final bodyCtrl = TextEditingController();

  await showDialog<void>(
    context: context,
    builder: (ctx) => AlertDialog(
      backgroundColor: const Color(0xFF1A1E26),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(18),
        side: BorderSide(color: Colors.white.withValues(alpha: 0.14)),
      ),
      title: const Text('➕ 註冊新 JS/公式技能', style: TextStyle(color: Colors.white, fontSize: 15.5)),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: nameCtrl,
              style: const TextStyle(color: Colors.white, fontSize: 13),
              decoration: const InputDecoration(
                labelText: '技能名稱（例：雙折料重）',
                labelStyle: TextStyle(color: Color(0xFF9CA3AF)),
              ),
            ),
            TextField(
              controller: descCtrl,
              style: const TextStyle(color: Colors.white, fontSize: 13),
              decoration: const InputDecoration(
                labelText: '用途說明（選填）',
                labelStyle: TextStyle(color: Color(0xFF9CA3AF)),
              ),
            ),
            TextField(
              controller: paramsCtrl,
              style: const TextStyle(color: Colors.white, fontSize: 13),
              decoration: const InputDecoration(
                labelText: '參數名稱（逗號分隔，例：w,len,qty）',
                labelStyle: TextStyle(color: Color(0xFF9CA3AF)),
              ),
            ),
            const SizedBox(height: 8),
            TextField(
              controller: bodyCtrl,
              maxLines: 4,
              style: const TextStyle(color: Color(0xFFFDE68A), fontFamily: 'monospace', fontSize: 12),
              decoration: const InputDecoration(
                labelText: 'JS 公式主體（可用 const/Math/callNative/return）',
                hintText: 'return (w * len / 1000 * qty * 1.09).toFixed(2) + " kg";',
                hintStyle: TextStyle(color: Color(0xFF4B5563), fontSize: 11),
                labelStyle: TextStyle(color: Color(0xFF9CA3AF)),
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(ctx).pop(),
          child: const Text('取消', style: TextStyle(color: Color(0xFF9CA3AF))),
        ),
        ElevatedButton(
          style: ElevatedButton.styleFrom(
            backgroundColor: const Color(0xFFF59E0B),
            foregroundColor: const Color(0xFF111317),
          ),
          onPressed: () async {
            final name = nameCtrl.text.trim();
            final rawBody = bodyCtrl.text.trim();
            if (name.isEmpty || rawBody.isEmpty) {
              onToast('⚠️ 請填寫技能名稱與公式');
              return;
            }
            final params = paramsCtrl.text
                .split(RegExp(r'[,，\s]+'))
                .map((e) => e.trim())
                .where((e) => e.isNotEmpty)
                .toList();
            final body = (!rawBody.contains('return ') && !rawBody.contains(';'))
                ? 'return ($rawBody);'
                : rawBody;
            await db.upsertHook(
              name: name,
              description: descCtrl.text.trim(),
              params: params,
              body: body,
            );
            if (ctx.mounted) Navigator.of(ctx).pop();
            onToast('🧩 已註冊技能「$name」');
          },
          child: const Text('儲存技能', style: TextStyle(fontWeight: FontWeight.bold)),
        ),
      ],
    ),
  );
}

/// 📜 On-Demand JIT Skill Knowledge Pack Manager Modal (view, toggle, edit, import .md, delete)
Future<void> showSkillManagerModal({
  required BuildContext context,
  required DatabaseHelper db,
  required VoidCallback onChanged,
  required void Function(String msg) onToast,
}) async {
  await showDialog<void>(
    context: context,
    barrierColor: Colors.black.withValues(alpha: 0.72),
    builder: (ctx) {
      var selectedSkillId = '';

      return StatefulBuilder(
        builder: (ctx, setState) {
          return Dialog(
            backgroundColor: const Color(0xFF1A1E26),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(20),
              side: BorderSide(color: Colors.white.withValues(alpha: 0.14)),
            ),
            insetPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 24),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 520, maxHeight: 680),
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        const Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                '📜 按需 Skill 知識包管理',
                                style: TextStyle(
                                  fontSize: 15.5,
                                  fontWeight: FontWeight.bold,
                                  color: Color(0xFFF472B6),
                                ),
                              ),
                              SizedBox(height: 2),
                              Text(
                                '免重編 APK！命中關鍵字或 @點名 才注入當輪（保溫 KV-Cache）',
                                style: TextStyle(fontSize: 11.5, color: Color(0xFF9CA3AF)),
                              ),
                            ],
                          ),
                        ),
                        IconButton(
                          icon: const Icon(Icons.file_open_outlined, color: Color(0xFF38BDF8)),
                          tooltip: '匯入 .md 知識檔',
                          onPressed: () async {
                            try {
                              final picked = await FilePicker.pickFile(
                                dialogTitle: '選取 Skill Markdown (.md / .txt)',
                                type: FileType.any,
                              );
                              final path = picked?.path;
                              if (path == null) return;
                              final raw = await File(path).readAsString();
                              final baseName = Uri.file(path)
                                  .pathSegments
                                  .last
                                  .replaceFirst(RegExp(r'\.[^.]+$'), '');
                              final parsed = SkillRecord.parseFromMarkdown(
                                raw,
                                fallbackName: baseName,
                              );
                              if (!ctx.mounted) return;
                              final saved = await _showUpsertSkillDialog(
                                context: ctx,
                                db: db,
                                initial: parsed,
                                isNew: true,
                                onToast: onToast,
                              );
                              if (saved != null) {
                                selectedSkillId = saved.id;
                                onChanged();
                                setState(() {});
                              }
                            } catch (e) {
                              onToast('匯入失敗：$e');
                            }
                          },
                        ),
                        IconButton(
                          icon: const Icon(Icons.add_circle_outline, color: Color(0xFF34D399)),
                          tooltip: '貼上新增 Skill',
                          onPressed: () async {
                            final saved = await _showUpsertSkillDialog(
                              context: ctx,
                              db: db,
                              isNew: true,
                              onToast: onToast,
                            );
                            if (saved != null) {
                              selectedSkillId = saved.id;
                              onChanged();
                              setState(() {});
                            }
                          },
                        ),
                        IconButton(
                          icon: const Icon(Icons.close, color: Color(0xFF9CA3AF)),
                          onPressed: () => Navigator.of(ctx).pop(),
                        ),
                      ],
                    ),
                    const SizedBox(height: 10),
                    Expanded(
                      child: FutureBuilder<List<SkillRecord>>(
                        future: db.getSkills(),
                        builder: (context, snap) {
                          if (!snap.hasData) {
                            return const Center(
                              child: CircularProgressIndicator(color: Color(0xFFF472B6)),
                            );
                          }
                          final skills = snap.data!;
                          if (skills.isEmpty) {
                            return const Center(
                              child: Text(
                                '目前尚無 Skill，點右上角 ＋ 新增或匯入 .md 檔！',
                                style: TextStyle(color: Color(0xFF9CA3AF), fontSize: 13),
                              ),
                            );
                          }
                          final active = skills.any((s) => s.id == selectedSkillId)
                              ? skills.firstWhere((s) => s.id == selectedSkillId)
                              : skills.first;

                          return ListView(
                            children: [
                              Wrap(
                                spacing: 6,
                                runSpacing: 6,
                                children: [
                                  for (final s in skills)
                                    ChoiceChip(
                                      label: Text(
                                        '${s.enabled ? '🟢 ' : '⚪ '}${s.name}',
                                        style: const TextStyle(fontSize: 12),
                                      ),
                                      selected: active.id == s.id,
                                      onSelected: (_) {
                                        setState(() {
                                          selectedSkillId = s.id;
                                        });
                                      },
                                    ),
                                ],
                              ),
                              const SizedBox(height: 12),
                              Container(
                                padding: const EdgeInsets.all(12),
                                decoration: BoxDecoration(
                                  color: const Color(0xFF111317),
                                  borderRadius: BorderRadius.circular(12),
                                  border: Border.all(color: Colors.white.withValues(alpha: 0.1)),
                                ),
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Row(
                                      children: [
                                        Expanded(
                                          child: Text(
                                            active.name,
                                            style: const TextStyle(
                                              color: Color(0xFFF472B6),
                                              fontSize: 14,
                                              fontWeight: FontWeight.bold,
                                            ),
                                          ),
                                        ),
                                        Switch(
                                          value: active.enabled,
                                          activeThumbColor: const Color(0xFF34D399),
                                          onChanged: (v) async {
                                            await db.toggleSkillEnabled(active.id, v);
                                            onChanged();
                                            setState(() {});
                                            onToast(v ? '🟢 已啟用「${active.name}」' : '⚪ 已暫停「${active.name}」');
                                          },
                                        ),
                                        IconButton(
                                          icon: const Icon(Icons.edit_outlined, color: Color(0xFF38BDF8), size: 18),
                                          tooltip: '編輯 Markdown',
                                          onPressed: () async {
                                            final saved = await _showUpsertSkillDialog(
                                              context: ctx,
                                              db: db,
                                              initial: active,
                                              isNew: false,
                                              onToast: onToast,
                                            );
                                            if (saved != null) {
                                              onChanged();
                                              setState(() {});
                                            }
                                          },
                                        ),
                                        IconButton(
                                          icon: const Icon(Icons.delete_outline, color: Color(0xFFFB7185), size: 18),
                                          tooltip: '刪除 Skill',
                                          onPressed: () async {
                                            await db.deleteSkill(active.id);
                                            onChanged();
                                            setState(() {
                                              selectedSkillId = '';
                                            });
                                            onToast('🗑️ 已刪除 Skill「${active.name}」');
                                          },
                                        ),
                                      ],
                                    ),
                                    if (active.description.isNotEmpty)
                                      Text(
                                        active.description,
                                        style: const TextStyle(color: Color(0xFFD1D5DB), fontSize: 12),
                                      ),
                                    const SizedBox(height: 6),
                                    Text(
                                      '觸發關鍵字：${active.triggerKeywords.isEmpty ? '（僅限 @${active.name}）' : active.triggerKeywords.join('、')}',
                                      style: const TextStyle(color: Color(0xFF38BDF8), fontSize: 11.5),
                                    ),
                                    const SizedBox(height: 8),
                                    Container(
                                      width: double.infinity,
                                      constraints: const BoxConstraints(maxHeight: 230),
                                      padding: const EdgeInsets.all(10),
                                      decoration: BoxDecoration(
                                        color: const Color(0xFF0A0C0F),
                                        borderRadius: BorderRadius.circular(8),
                                      ),
                                      child: SingleChildScrollView(
                                        child: Text(
                                          active.contentMd,
                                          style: const TextStyle(
                                            fontFamily: 'monospace',
                                            fontSize: 11.5,
                                            color: Color(0xFFE5E7EB),
                                            height: 1.45,
                                          ),
                                        ),
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                              const SizedBox(height: 8),
                              Text(
                                '💡 在對話說出觸發詞或打「@${active.name}」，本輪才會動態注入規範（不佔平時 Context）。',
                                style: const TextStyle(color: Color(0xFF6B7280), fontSize: 11.5),
                              ),
                            ],
                          );
                        },
                      ),
                    ),
                  ],
                ),
              ),
            ),
          );
        },
      );
    },
  );
}

Future<SkillRecord?> _showUpsertSkillDialog({
  required BuildContext context,
  required DatabaseHelper db,
  SkillRecord? initial,
  required bool isNew,
  required void Function(String msg) onToast,
}) async {
  final nameCtrl = TextEditingController(text: initial?.name ?? '');
  final keywordsCtrl = TextEditingController(text: initial?.triggerKeywords.join(', ') ?? '');
  final descCtrl = TextEditingController(text: initial?.description ?? '');
  final contentCtrl = TextEditingController(text: initial?.contentMd ?? '');

  final saved = await showDialog<SkillRecord>(
    context: context,
    builder: (ctx) => AlertDialog(
      backgroundColor: const Color(0xFF1A1E26),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(18),
        side: BorderSide(color: Colors.white.withValues(alpha: 0.14)),
      ),
      title: Text(
        isNew ? '📜 新增／匯入 Skill 知識包' : '✏️ 編輯 Skill「${initial?.name ?? ''}」',
        style: const TextStyle(color: Colors.white, fontSize: 15.5),
      ),
      content: SizedBox(
        width: 460,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: nameCtrl,
                style: const TextStyle(color: Colors.white, fontSize: 13),
                decoration: const InputDecoration(
                  labelText: 'Skill 名稱（可用 @名稱 強制點名）',
                  labelStyle: TextStyle(color: Color(0xFF9CA3AF)),
                ),
              ),
              TextField(
                controller: keywordsCtrl,
                style: const TextStyle(color: Colors.white, fontSize: 13),
                decoration: const InputDecoration(
                  labelText: '觸發關鍵字（逗號分隔，例：欄杆,玻璃,立柱）',
                  labelStyle: TextStyle(color: Color(0xFF9CA3AF)),
                ),
              ),
              TextField(
                controller: descCtrl,
                style: const TextStyle(color: Colors.white, fontSize: 13),
                decoration: const InputDecoration(
                  labelText: '一句話索引摘要（僅列於常駐索引，極省 Token）',
                  labelStyle: TextStyle(color: Color(0xFF9CA3AF)),
                ),
              ),
              const SizedBox(height: 8),
              TextField(
                controller: contentCtrl,
                maxLines: 8,
                style: const TextStyle(
                  color: Color(0xFFFDE68A),
                  fontFamily: 'monospace',
                  fontSize: 12,
                ),
                decoration: const InputDecoration(
                  labelText: '完整 Skill Markdown 規範內容',
                  hintText: '貼上流程、防呆規則、標準對話指令或搭配 callNative 的步驟…',
                  hintStyle: TextStyle(color: Color(0xFF4B5563), fontSize: 11),
                  labelStyle: TextStyle(color: Color(0xFF9CA3AF)),
                  border: OutlineInputBorder(),
                ),
              ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(ctx).pop(),
          child: const Text('取消', style: TextStyle(color: Color(0xFF9CA3AF))),
        ),
        ElevatedButton(
          style: ElevatedButton.styleFrom(
            backgroundColor: const Color(0xFFF472B6),
            foregroundColor: const Color(0xFF111317),
          ),
          onPressed: () async {
            final name = nameCtrl.text.trim();
            final content = contentCtrl.text.trim();
            if (name.isEmpty || content.isEmpty) {
              onToast('⚠️ 請填寫 Skill 名稱與 Markdown 內容');
              return;
            }
            final kws = SkillRecord.parseKeywords(keywordsCtrl.text);
            final desc = descCtrl.text.trim().isEmpty
                ? '$name 現場流程知識包'
                : descCtrl.text.trim();
            final record = await db.upsertSkill(
              id: isNew ? initial?.id : initial?.id,
              name: name,
              triggerKeywords: kws.isEmpty ? [name] : kws,
              description: desc,
              contentMd: content,
              enabled: initial?.enabled ?? true,
            );
            if (ctx.mounted) Navigator.of(ctx).pop(record);
            onToast('📜 已儲存 Skill「$name」');
          },
          child: const Text('儲存 Skill', style: TextStyle(fontWeight: FontWeight.bold)),
        ),
      ],
    ),
  );

  nameCtrl.dispose();
  keywordsCtrl.dispose();
  descCtrl.dispose();
  contentCtrl.dispose();
  return saved;
}

/// 🚩 Operator Flag Message Dialog (Saved for idle/screen-off self-reflection)
Future<bool> showFlagMessageDialog({
  required BuildContext context,
  required DatabaseHelper db,
  required ChatMessageRecord msg,
  required bool alreadyFlagged,
  required void Function(String msg) onToast,
}) async {
  if (alreadyFlagged) {
    final unflag = await showDialog<bool>(
      context: context,
      barrierColor: Colors.black.withValues(alpha: 0.7),
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF1A1E26),
        title: const Text('🚩 取消此則插旗？', style: TextStyle(color: Colors.white, fontSize: 15)),
        content: const Text(
          '這則對話目前已被標記待待機自省修正，要撤銷插旗嗎？',
          style: TextStyle(color: Color(0xFFD1D5DB), fontSize: 13),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.of(ctx).pop(false), child: const Text('保留插旗')),
          ElevatedButton(
            style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFFE11D48)),
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('撤銷插旗', style: TextStyle(color: Colors.white)),
          ),
        ],
      ),
    );
    if (unflag == true) {
      await db.unflagMessage(msg.id);
      onToast('🚩 已撤銷該則插旗');
      return true;
    }
    return false;
  }

  const reasons = ['算料/鋸路錯', '答非所問', '語氣太官腔', '記錯案場規格'];
  var selectedReason = reasons.first;
  final noteCtrl = TextEditingController();

  final submitted = await showDialog<bool>(
    context: context,
    barrierColor: Colors.black.withValues(alpha: 0.72),
    builder: (ctx) => StatefulBuilder(
      builder: (ctx, setState) => AlertDialog(
        backgroundColor: const Color(0xFF1A1E26),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(18),
          side: BorderSide(color: const Color(0xFFF43F5E).withValues(alpha: 0.45)),
        ),
        title: const Text('🚩 插旗糾錯（關螢幕待機自省）', style: TextStyle(color: Colors.white, fontSize: 15)),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                msg.content.length > 72 ? '${msg.content.substring(0, 72)}…' : msg.content,
                style: const TextStyle(color: Color(0xFF9CA3AF), fontSize: 12),
              ),
              const SizedBox(height: 12),
              Wrap(
                spacing: 6,
                runSpacing: 6,
                children: [
                  for (final r in reasons)
                    ChoiceChip(
                      label: Text(r, style: const TextStyle(fontSize: 11.5)),
                      selected: selectedReason == r,
                      selectedColor: const Color(0xFFF43F5E).withValues(alpha: 0.28),
                      onSelected: (_) => setState(() => selectedReason = r),
                    ),
                ],
              ),
              const SizedBox(height: 10),
              TextField(
                controller: noteCtrl,
                maxLines: 2,
                style: const TextStyle(color: Colors.white, fontSize: 13),
                decoration: InputDecoration(
                  hintText: '補充現場正確作法（例如：093Z 要抓 6.4m 才對）',
                  hintStyle: const TextStyle(color: Color(0xFF6B7280), fontSize: 12),
                  filled: true,
                  fillColor: const Color(0xFF0E1014),
                  border: OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
                ),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('取消', style: TextStyle(color: Color(0xFF9CA3AF))),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(
              backgroundColor: const Color(0xFFF43F5E),
              foregroundColor: Colors.white,
            ),
            onPressed: () async {
              await db.flagMessage(
                messageId: msg.id,
                roomId: msg.roomId,
                reason: selectedReason,
                userNote: noteCtrl.text,
                flaggedContent: msg.content,
              );
              if (ctx.mounted) Navigator.of(ctx).pop(true);
            },
            child: const Text('插旗記錄'),
          ),
        ],
      ),
    ),
  );
  noteCtrl.dispose();
  if (submitted == true) {
    onToast('🚩 已插旗！退到後台／關螢幕待機時會自動反省進 MEMORY.md');
    return true;
  }
  return false;
}

/// ⏰ Zero-Compute Local Routine Scheduler Modal (with Next-3 Trigger Preview)
Future<void> showRoutineSchedulerModal({
  required BuildContext context,
  required DatabaseHelper db,
  required void Function(String msg) onToast,
}) async {
  var routines = await db.getRoutines();
  if (!context.mounted) return;

  await showDialog<void>(
    context: context,
    barrierColor: Colors.black.withValues(alpha: 0.72),
    builder: (ctx) => StatefulBuilder(
      builder: (ctx, setState) {
        Future<void> reload() async {
          routines = await db.getRoutines();
          if (ctx.mounted) setState(() {});
        }

        return Dialog(
          backgroundColor: const Color(0xFF1A1E26),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(20),
            side: BorderSide(color: Colors.white.withValues(alpha: 0.14)),
          ),
          insetPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 24),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 500, maxHeight: 590),
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      const Text(
                        '⏰ 零算力日常排程 (Cron / 重複)',
                        style: TextStyle(color: Colors.white, fontSize: 15, fontWeight: FontWeight.bold),
                      ),
                      IconButton(
                        icon: const Icon(Icons.close, color: Color(0xFF9CA3AF)),
                        onPressed: () => Navigator.of(ctx).pop(),
                      ),
                    ],
                  ),
                  const Text(
                    '全程由 Android 系統定時廣播喚醒通知，絕對不喚醒 4B GPU，不耗電不卡頓。',
                    style: TextStyle(color: Color(0xFF9CA3AF), fontSize: 11.5),
                  ),
                  const SizedBox(height: 10),
                  Expanded(
                    child: routines.isEmpty
                        ? const Center(
                            child: Text(
                              '目前沒有排程，按下方新增一組！',
                              style: TextStyle(color: Color(0xFF6B7280)),
                            ),
                          )
                        : ListView.separated(
                            itemCount: routines.length,
                            separatorBuilder: (_, _) => const SizedBox(height: 8),
                            itemBuilder: (_, i) {
                              final r = routines[i];
                              final next3 = RoutineScheduler.formatNextOccurrencesPreview(r);
                              return Container(
                                padding: const EdgeInsets.all(10),
                                decoration: BoxDecoration(
                                  color: const Color(0xFF12151B),
                                  borderRadius: BorderRadius.circular(12),
                                  border: Border.all(
                                    color: r.enabled
                                        ? const Color(0xFFF59E0B).withValues(alpha: 0.45)
                                        : Colors.white.withValues(alpha: 0.08),
                                  ),
                                ),
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Row(
                                      children: [
                                        Container(
                                          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                                          decoration: BoxDecoration(
                                            color: const Color(0xFFF59E0B).withValues(alpha: 0.16),
                                            borderRadius: BorderRadius.circular(6),
                                          ),
                                          child: Text(
                                            '${r.modeLabel} ${r.timeSpec}',
                                            style: const TextStyle(fontSize: 10.5, color: Color(0xFFFCD34D), fontWeight: FontWeight.w600),
                                          ),
                                        ),
                                        const SizedBox(width: 8),
                                        Expanded(
                                          child: Text(
                                            r.title,
                                            style: const TextStyle(color: Colors.white, fontSize: 13.5, fontWeight: FontWeight.bold),
                                            overflow: TextOverflow.ellipsis,
                                          ),
                                        ),
                                        Switch(
                                          value: r.enabled,
                                          activeThumbColor: const Color(0xFFF59E0B),
                                          onChanged: (v) async {
                                            await db.toggleRoutineEnabled(r.id, v);
                                            await RoutineScheduler.syncEnabledRoutinesToSystem(db);
                                            await reload();
                                            onToast(v ? '⏰ 已啟用「${r.title}」' : '⏸️ 已暫停「${r.title}」');
                                          },
                                        ),
                                        IconButton(
                                          icon: const Icon(Icons.delete_outline, size: 18, color: Color(0xFF9CA3AF)),
                                          onPressed: () async {
                                            await db.deleteRoutine(r.id);
                                            await reload();
                                            onToast('🗑️ 已移除排程「${r.title}」');
                                          },
                                        ),
                                      ],
                                    ),
                                    if (r.body.isNotEmpty)
                                      Padding(
                                        padding: const EdgeInsets.only(bottom: 4),
                                        child: Text(
                                          r.body,
                                          style: const TextStyle(color: Color(0xFFD1D5DB), fontSize: 11.5),
                                        ),
                                      ),
                                    Text(
                                      '📅 未來 3 次：${next3.join(' / ')}',
                                      style: const TextStyle(color: Color(0xFF93C5FD), fontSize: 11),
                                    ),
                                  ],
                                ),
                              );
                            },
                          ),
                  ),
                  const SizedBox(height: 10),
                  SizedBox(
                    width: double.infinity,
                    child: ElevatedButton.icon(
                      icon: const Icon(Icons.add_alarm, size: 18),
                      label: const Text('新增零算力排程（單次 / 重複 / Cron）'),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: const Color(0xFFF59E0B),
                        foregroundColor: const Color(0xFF111317),
                      ),
                      onPressed: () async {
                        final added = await _showRoutineEditorDialog(
                          context: ctx,
                          db: db,
                          onToast: onToast,
                        );
                        if (added) {
                          await RoutineScheduler.syncEnabledRoutinesToSystem(db);
                          await reload();
                        }
                      },
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    ),
  );
}

Future<bool> _showRoutineEditorDialog({
  required BuildContext context,
  required DatabaseHelper db,
  required void Function(String msg) onToast,
}) async {
  final titleCtrl = TextEditingController();
  final bodyCtrl = TextEditingController();
  final timeCtrl = TextEditingController(text: '07:30');
  var mode = 'daily';
  final selectedDays = <int>{1, 2, 3, 4, 5, 6};

  final saved = await showDialog<bool>(
    context: context,
    barrierColor: Colors.black.withValues(alpha: 0.72),
    builder: (ctx) => StatefulBuilder(
      builder: (ctx, setState) {
        final previewRecord = RoutineRecord(
          id: 'preview',
          title: titleCtrl.text.isEmpty ? '預覽' : titleCtrl.text,
          body: bodyCtrl.text,
          mode: mode,
          timeSpec: timeCtrl.text,
          weekdaysCsv: (selectedDays.toList()..sort()).join(','),
          enabled: true,
          updatedAt: 0,
        );
        final next3 = RoutineScheduler.formatNextOccurrencesPreview(previewRecord);

        return AlertDialog(
          backgroundColor: const Color(0xFF1A1E26),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
          title: const Text('⏰ 建立零算力排程', style: TextStyle(color: Colors.white, fontSize: 15)),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                TextField(
                  controller: titleCtrl,
                  onChanged: (_) => setState(() {}),
                  style: const TextStyle(color: Colors.white, fontSize: 13),
                  decoration: const InputDecoration(labelText: '提醒標題（例：追金代交期）'),
                ),
                const SizedBox(height: 8),
                Wrap(
                  spacing: 6,
                  children: [
                    for (final entry in const [
                      ('daily', '每日'),
                      ('weekly', '每週'),
                      ('once', '單次'),
                      ('cron', 'Cron'),
                    ])
                      ChoiceChip(
                        label: Text(entry.$2, style: const TextStyle(fontSize: 11.5)),
                        selected: mode == entry.$1,
                        onSelected: (_) {
                          setState(() {
                            mode = entry.$1;
                            if (mode == 'cron' && !timeCtrl.text.contains(' ')) {
                              timeCtrl.text = '30 7 * * 1-6';
                            } else if (mode != 'cron' && timeCtrl.text.contains('*')) {
                              timeCtrl.text = '07:30';
                            }
                          });
                        },
                      ),
                  ],
                ),
                const SizedBox(height: 8),
                TextField(
                  controller: timeCtrl,
                  onChanged: (_) => setState(() {}),
                  style: const TextStyle(color: Colors.white, fontSize: 13),
                  decoration: InputDecoration(
                    labelText: mode == 'cron'
                        ? '5 欄 Cron（分 時 日 月 週，如 30 7 * * 1-6）'
                        : (mode == 'once' ? '日期時間（如 2026-11-19 08:30 或 17:00）' : '時間（HH:mm，如 07:30）'),
                  ),
                ),
                if (mode == 'weekly') ...[
                  const SizedBox(height: 8),
                  Wrap(
                    spacing: 4,
                    children: [
                      for (var d = 1; d <= 7; d++)
                        FilterChip(
                          label: Text(['一', '二', '三', '四', '五', '六', '日'][d - 1], style: const TextStyle(fontSize: 11)),
                          selected: selectedDays.contains(d),
                          onSelected: (sel) {
                            setState(() {
                              if (sel) {
                                selectedDays.add(d);
                              } else if (selectedDays.length > 1) {
                                selectedDays.remove(d);
                              }
                            });
                          },
                        ),
                    ],
                  ),
                ],
                const SizedBox(height: 8),
                TextField(
                  controller: bodyCtrl,
                  style: const TextStyle(color: Colors.white, fontSize: 12.5),
                  decoration: const InputDecoration(labelText: '補充內容（選填）'),
                ),
                const SizedBox(height: 10),
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(8),
                  decoration: BoxDecoration(
                    color: const Color(0xFF12151B),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Text(
                    '📅 未來 3 次執行預覽：\n${next3.join('\n')}',
                    style: const TextStyle(color: Color(0xFF93C5FD), fontSize: 11.5, height: 1.4),
                  ),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.of(ctx).pop(false), child: const Text('取消')),
            ElevatedButton(
              onPressed: () async {
                final title = titleCtrl.text.trim();
                if (title.isEmpty) {
                  onToast('⚠️ 請輸入提醒標題');
                  return;
                }
                await db.upsertRoutine(
                  title: title,
                  body: bodyCtrl.text.trim(),
                  mode: mode,
                  timeSpec: timeCtrl.text.trim(),
                  weekdaysCsv: (selectedDays.toList()..sort()).join(','),
                  enabled: true,
                );
                if (ctx.mounted) Navigator.of(ctx).pop(true);
              },
              child: const Text('儲存並排程'),
            ),
          ],
        );
      },
    ),
  );
  titleCtrl.dispose();
  bodyCtrl.dispose();
  timeCtrl.dispose();
  if (saved == true) {
    onToast('⏰ 已新增零算力日常排程');
    return true;
  }
  return false;
}

/// 🎡 6-Slot Symmetrical Hexagon Wheel Customizer Modal
Future<void> showWheelSlotCustomizerModal({
  required BuildContext context,
  required List<String> initialSlots,
  required void Function(List<String> updatedSlots) onSaved,
  required void Function(String msg) onToast,
}) async {
  var currentSlots = WheelActionRegistry.sanitizeSlots(initialSlots);

  Future<void> persist(List<String> next) async {
    final saved = await FloatingOverlayPreferences.setWheelSlots(next);
    await NativeActions.setGhostWheelSlots(saved);
    currentSlots = saved;
    onSaved(saved);
  }

  Future<void> pickActionForSlot(
    BuildContext parentCtx,
    int slotIndex,
    void Function(VoidCallback) setModalState,
  ) async {
    final clockLabel = WheelActionRegistry.clockLabels[slotIndex];
    final currentId = currentSlots[slotIndex];
    final inPlaceActions = WheelActionRegistry.allActions.where((a) => a.isInPlace).toList();
    final appActions = WheelActionRegistry.allActions.where((a) => !a.isInPlace).toList();

    final picked = await showDialog<String>(
      context: parentCtx,
      barrierColor: Colors.black.withValues(alpha: 0.72),
      builder: (pickerCtx) {
        Widget buildOptionTile(WheelActionSpec spec) {
          final equippedIdx = currentSlots.indexOf(spec.id);
          final isHere = spec.id == currentId;
          final badgeText = isHere
              ? '目前配置'
              : (equippedIdx >= 0 ? '已在 ${WheelActionRegistry.clockLabels[equippedIdx]} (點選互換)' : null);
          return InkWell(
            borderRadius: BorderRadius.circular(10),
            onTap: () => Navigator.of(pickerCtx).pop(spec.id),
            child: Container(
              margin: const EdgeInsets.only(bottom: 6),
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
              decoration: BoxDecoration(
                color: isHere ? const Color(0xFF2B2110) : const Color(0xFF111317),
                borderRadius: BorderRadius.circular(10),
                border: Border.all(
                  color: isHere
                      ? const Color(0xFFFCD34D)
                      : Colors.white.withValues(alpha: 0.12),
                ),
              ),
              child: Row(
                children: [
                  Text(spec.emoji, style: const TextStyle(fontSize: 18)),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Text(
                              spec.label,
                              style: const TextStyle(
                                color: Colors.white,
                                fontSize: 13,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                            if (badgeText != null) ...[
                              const SizedBox(width: 6),
                              Container(
                                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
                                decoration: BoxDecoration(
                                  color: isHere
                                      ? const Color(0xFFF59E0B).withValues(alpha: 0.25)
                                      : Colors.white.withValues(alpha: 0.08),
                                  borderRadius: BorderRadius.circular(99),
                                ),
                                child: Text(
                                  badgeText,
                                  style: TextStyle(
                                    color: isHere ? const Color(0xFFFCD34D) : const Color(0xFF9CA3AF),
                                    fontSize: 10,
                                  ),
                                ),
                              ),
                            ],
                          ],
                        ),
                        const SizedBox(height: 2),
                        Text(
                          spec.description,
                          style: const TextStyle(color: Color(0xFF9CA3AF), fontSize: 11),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          );
        }

        return AlertDialog(
          backgroundColor: const Color(0xFF1A1E26),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(18),
            side: BorderSide(color: const Color(0xFFF59E0B).withValues(alpha: 0.45)),
          ),
          title: Text(
            '替換 $clockLabel 捷徑',
            style: const TextStyle(color: Color(0xFFFCD34D), fontSize: 15, fontWeight: FontWeight.bold),
          ),
          content: SizedBox(
            width: 340,
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    '🟢 免開 App（原地秒執行）',
                    style: TextStyle(color: Color(0xFF34D399), fontSize: 11.5, fontWeight: FontWeight.w600),
                  ),
                  const SizedBox(height: 6),
                  for (final spec in inPlaceActions) buildOptionTile(spec),
                  const SizedBox(height: 8),
                  const Text(
                    '🔵 直達 App 頁面',
                    style: TextStyle(color: Color(0xFF60A5FA), fontSize: 11.5, fontWeight: FontWeight.w600),
                  ),
                  const SizedBox(height: 6),
                  for (final spec in appActions) buildOptionTile(spec),
                ],
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(pickerCtx).pop(),
              child: const Text('取消', style: TextStyle(color: Color(0xFF9CA3AF))),
            ),
          ],
        );
      },
    );

    if (picked == null || picked == currentId) return;
    final next = WheelActionRegistry.swapOrAssignSlot(currentSlots, slotIndex, picked);
    await persist(next);
    setModalState(() {});
    final meta = WheelActionRegistry.byId(picked);
    onToast('🎡 $clockLabel 已更新為 ${meta?.emoji ?? ''} ${meta?.label ?? picked}');
  }

  await showDialog<void>(
    context: context,
    barrierColor: Colors.black.withValues(alpha: 0.72),
    builder: (ctx) {
      return StatefulBuilder(
        builder: (ctx, setModalState) {
          return AlertDialog(
            backgroundColor: const Color(0xFF1A1E26),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(18),
              side: BorderSide(color: Colors.white.withValues(alpha: 0.14)),
            ),
            title: const Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '🎡 自訂 6 軌現場輪盤',
                  style: TextStyle(color: Color(0xFFFCD34D), fontSize: 16, fontWeight: FontWeight.bold),
                ),
                SizedBox(height: 2),
                Text(
                  '正六芒星 60° 對稱佈局 • 點擊任意方位即可自由換裝',
                  style: TextStyle(color: Color(0xFF9CA3AF), fontSize: 11.5),
                ),
              ],
            ),
            content: SizedBox(
              width: 340,
              child: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    for (var i = 0; i < WheelActionRegistry.slotCount; i++)
                      Builder(
                        builder: (_) {
                          final actionId = currentSlots[i];
                          final spec = WheelActionRegistry.byId(actionId) ??
                              WheelActionRegistry.allActions.first;
                          return InkWell(
                            borderRadius: BorderRadius.circular(12),
                            onTap: () => pickActionForSlot(ctx, i, setModalState),
                            child: Container(
                              margin: const EdgeInsets.only(bottom: 8),
                              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                              decoration: BoxDecoration(
                                color: const Color(0xFF111317),
                                borderRadius: BorderRadius.circular(12),
                                border: Border.all(
                                  color: const Color(0xFFF59E0B).withValues(alpha: 0.32),
                                ),
                              ),
                              child: Row(
                                children: [
                                  Container(
                                    padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
                                    decoration: BoxDecoration(
                                      color: const Color(0xFFF59E0B).withValues(alpha: 0.16),
                                      borderRadius: BorderRadius.circular(8),
                                    ),
                                    child: Text(
                                      WheelActionRegistry.clockLabels[i],
                                      style: const TextStyle(
                                        color: Color(0xFFFCD34D),
                                        fontSize: 11,
                                        fontWeight: FontWeight.w600,
                                      ),
                                    ),
                                  ),
                                  const SizedBox(width: 10),
                                  Text(spec.emoji, style: const TextStyle(fontSize: 18)),
                                  const SizedBox(width: 8),
                                  Expanded(
                                    child: Column(
                                      crossAxisAlignment: CrossAxisAlignment.start,
                                      children: [
                                        Row(
                                          children: [
                                            Text(
                                              spec.label,
                                              style: const TextStyle(
                                                color: Colors.white,
                                                fontSize: 13,
                                                fontWeight: FontWeight.w600,
                                              ),
                                            ),
                                            const SizedBox(width: 6),
                                            Text(
                                              spec.isInPlace ? '🟢免開App' : '🔵開App',
                                              style: TextStyle(
                                                color: spec.isInPlace
                                                    ? const Color(0xFF34D399)
                                                    : const Color(0xFF60A5FA),
                                                fontSize: 10,
                                              ),
                                            ),
                                          ],
                                        ),
                                        Text(
                                          spec.description,
                                          style: const TextStyle(color: Color(0xFF9CA3AF), fontSize: 10.5),
                                          maxLines: 1,
                                          overflow: TextOverflow.ellipsis,
                                        ),
                                      ],
                                    ),
                                  ),
                                  const Icon(Icons.chevron_right_rounded, color: Color(0xFF6B7280), size: 18),
                                ],
                              ),
                            ),
                          );
                        },
                      ),
                  ],
                ),
              ),
            ),
            actions: [
              TextButton(
                onPressed: () async {
                  await persist(WheelActionRegistry.defaultSlots);
                  setModalState(() {});
                  onToast('↺ 已恢復預設六芒星免開輪盤');
                },
                child: const Text('↺ 恢復預設六芒星', style: TextStyle(color: Color(0xFFFBBF24))),
              ),
              TextButton(
                onPressed: () => Navigator.of(ctx).pop(),
                child: const Text('完成', style: TextStyle(color: Colors.white)),
              ),
            ],
          );
        },
      );
    },
  );
}

