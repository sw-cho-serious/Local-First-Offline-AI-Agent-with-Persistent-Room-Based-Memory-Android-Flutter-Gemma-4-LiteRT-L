import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../data/database_helper.dart';
import '../../data/models.dart';
import '../../engine/llm_engine.dart';
import '../../sync/cloud_sync_service.dart';
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
                    child: SpiritAvatar(
                      colorHex: selectedColor,
                      state: SpiritState.idle,
                      size: 56,
                      accessory: selectedAccessory,
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
                  const SizedBox(height: 12),
                  const Text('專屬配件類型', style: TextStyle(color: Color(0xFF9CA3AF), fontSize: 12)),
                  const SizedBox(height: 6),
                  Row(
                    children: [
                      ChoiceChip(
                        label: const Text('⛑️ 案場工安'),
                        selected: selectedAccessory == 'helmet',
                        onSelected: (_) => setState(() => selectedAccessory = 'helmet'),
                      ),
                      const SizedBox(width: 8),
                      ChoiceChip(
                        label: const Text('🔧 廠務調機'),
                        selected: selectedAccessory == 'wrench',
                        onSelected: (_) => setState(() => selectedAccessory = 'wrench'),
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

/// 🧠 Traits Viewer / Editor Modal (Replaces LLM trait_* tools for safety)
Future<void> showTraitsEditorModal({
  required BuildContext context,
  required DatabaseHelper db,
  required void Function(String msg) onToast,
}) async {
  final traits = await db.getAllTraits();
  if (!context.mounted) return;
  final keys = ['SOUL.md', 'VOICE.md', 'USER.md', 'relationship.md', 'mood.md'];
  var activeKey = keys.first;
  final editor = TextEditingController(text: traits[activeKey] ?? '');

  await showDialog<void>(
    context: context,
    barrierColor: Colors.black.withValues(alpha: 0.72),
    builder: (ctx) {
      return StatefulBuilder(
        builder: (ctx, setState) {
          return Dialog(
            backgroundColor: const Color(0xFF1A1E26),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(20),
              side: BorderSide(color: Colors.white.withValues(alpha: 0.14)),
            ),
            insetPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 32),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 480, maxHeight: 540),
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        const Text('🧠 KODARI 靈魂與默契 (Traits)', style: TextStyle(color: Colors.white, fontSize: 15, fontWeight: FontWeight.bold)),
                        IconButton(
                          icon: const Icon(Icons.close, color: Color(0xFF9CA3AF)),
                          onPressed: () => Navigator.of(ctx).pop(),
                        ),
                      ],
                    ),
                    const SizedBox(height: 6),
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
                    const SizedBox(height: 10),
                    Expanded(
                      child: TextField(
                        controller: editor,
                        maxLines: null,
                        expands: true,
                        textAlignVertical: TextAlignVertical.top,
                        style: const TextStyle(color: Color(0xFFE5E7EB), fontSize: 13),
                        decoration: InputDecoration(
                          filled: true,
                          fillColor: const Color(0xFF0E1014),
                          border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
                        ),
                      ),
                    ),
                    const SizedBox(height: 10),
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

/// ⚙️ Model & GPU/CPU Settings Modal
Future<void> showModelSettingsModal({
  required BuildContext context,
  required LlmEngine engine,
  required VoidCallback onStateChanged,
  required void Function(String msg) onToast,
}) async {
  var busy = false;
  var progress = 0;

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
            title: const Text('⚙️ 模型與推論設定', style: TextStyle(color: Colors.white, fontSize: 16)),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '目前引擎：${engine.activeBackendLabel}',
                  style: const TextStyle(color: Color(0xFFFCD34D), fontSize: 13, fontWeight: FontWeight.w600),
                ),
                const SizedBox(height: 4),
                Text(
                  engine.installedModelPath ?? '尚未綁定 .litertlm 檔案（目前為離線查表預覽）',
                  style: const TextStyle(color: Color(0xFF9CA3AF), fontSize: 11.5),
                ),
                const SizedBox(height: 12),
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
                const SizedBox(height: 10),
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
                ],
                const SizedBox(height: 8),
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
              ],
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
