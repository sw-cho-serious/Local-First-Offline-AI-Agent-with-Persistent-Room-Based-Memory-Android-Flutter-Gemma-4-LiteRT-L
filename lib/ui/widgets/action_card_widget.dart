import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../data/models.dart';
import '../../tools/native_actions.dart';

class ActionCardWidget extends StatefulWidget {
  const ActionCardWidget({
    super.key,
    required this.card,
    required this.onCreateRoom,
    required this.onToast,
    this.onJumpToRoom,
  });

  final ActionCardData card;
  final Future<void> Function(String title) onCreateRoom;
  final void Function(String message) onToast;
  final Future<void> Function(String roomId)? onJumpToRoom;

  @override
  State<ActionCardWidget> createState() => _ActionCardWidgetState();
}

class _ActionCardWidgetState extends State<ActionCardWidget> {
  bool _confirmed = false;

  @override
  Widget build(BuildContext context) {
    final card = widget.card;
    final isConfirmType =
        card.type == 'confirm_calendar' || card.type == 'confirm_notification';
    final effectiveLabel = (_confirmed && isConfirmType)
        ? '✅ 已確認寫入'
        : card.buttonLabel;

    return Container(
      margin: const EdgeInsets.only(top: 8),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: const Color(0xFF12151B),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.white.withValues(alpha: 0.14)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Expanded(
                child: Text(
                  card.badge,
                  style: const TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                    color: Color(0xFFFCD34D),
                  ),
                ),
              ),
              const Text(
                '零算力渲染',
                style: TextStyle(fontSize: 11, color: Color(0xFF6B7280)),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Text(
            card.title,
            style: const TextStyle(
              fontSize: 14,
              fontWeight: FontWeight.bold,
              color: Colors.white,
            ),
          ),
          const SizedBox(height: 6),
          for (final row in card.rows)
            Padding(
              padding: const EdgeInsets.only(bottom: 3),
              child: Text(
                row,
                style: const TextStyle(fontSize: 12.5, color: Color(0xFFD1D5DB)),
              ),
            ),
          if (effectiveLabel.isNotEmpty) ...[
            const SizedBox(height: 8),
            SizedBox(
              width: double.infinity,
              child: OutlinedButton(
                style: OutlinedButton.styleFrom(
                  backgroundColor: (_confirmed && isConfirmType)
                      ? const Color(0xFF10B981).withValues(alpha: 0.15)
                      : const Color(0xFFF59E0B).withValues(alpha: 0.15),
                  side: BorderSide(
                    color: (_confirmed && isConfirmType)
                        ? const Color(0xFF10B981).withValues(alpha: 0.45)
                        : const Color(0xFFFBBF24).withValues(alpha: 0.4),
                  ),
                  foregroundColor: (_confirmed && isConfirmType)
                      ? const Color(0xFF6EE7B7)
                      : const Color(0xFFFDE68A),
                  padding: const EdgeInsets.symmetric(vertical: 10),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(9),
                  ),
                ),
                onPressed: (_confirmed && isConfirmType)
                    ? null
                    : () => _handleAction(context),
                child: Text(
                  effectiveLabel,
                  style: const TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600),
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }

  Future<void> _handleAction(BuildContext context) async {
    final card = widget.card;
    switch (card.type) {
      case 'confirm_calendar':
        final title = (card.payload['title'] ?? card.title).toString();
        final startIso = (card.payload['startIso'] ?? '').toString();
        final desc = (card.payload['description'] ?? '').toString();
        final display = (card.payload['displayTime'] ?? '').toString();
        final start = DateTime.tryParse(startIso) ??
            DateTime.now().add(const Duration(hours: 1));
        final direct = await NativeActions.insertCalendarEventDirect(
          title: title,
          startTime: start,
          description: desc,
        );
        if (direct.inserted) {
          if (mounted) setState(() => _confirmed = true);
          widget.onToast('📅 已寫入日曆（${direct.calendarName}）：$display');
        } else {
          await NativeActions.openCalendarDraft(
            title: title,
            startTime: start,
            description: desc,
          );
          if (mounted) setState(() => _confirmed = true);
          widget.onToast('📅 已開啟系統日曆確認畫面');
        }
        break;
      case 'confirm_notification':
        final title = (card.payload['title'] ?? card.title).toString();
        final body = (card.payload['body'] ?? title).toString();
        final triggerIso = (card.payload['triggerIso'] ?? '').toString();
        final triggerTime = DateTime.tryParse(triggerIso) ??
            DateTime.now().add(const Duration(minutes: 10));
        final res = await NativeActions.scheduleReminder(
          title: title,
          body: body,
          triggerTime: triggerTime,
        );
        if (mounted) setState(() => _confirmed = true);
        widget.onToast('⏰ 已排程提醒：${res.displayTime}');
        break;
      case 'calendar':
        final title = (card.payload['title'] ?? card.title).toString();
        final startIso = (card.payload['startIso'] ?? '').toString();
        final desc = (card.payload['description'] ?? '').toString();
        final start = DateTime.tryParse(startIso) ??
            DateTime.now().add(const Duration(hours: 1));
        await NativeActions.openCalendarDraft(
          title: title,
          startTime: start,
          description: desc,
        );
        widget.onToast('📅 已喚起 Android 日曆新增畫面');
        break;
      case 'profile':
      case 'tuning':
      case 'clipboard':
        final copyText = (card.payload['copyText'] ?? card.title).toString();
        await Clipboard.setData(ClipboardData(text: copyText));
        widget.onToast('📋 已複製至剪貼簿');
        break;
      case 'memory_hit':
        final targetRoomId = (card.payload['targetRoomId'] ?? '').toString();
        if (targetRoomId.isNotEmpty &&
            targetRoomId != 'main' &&
            widget.onJumpToRoom != null) {
          await widget.onJumpToRoom!(targetRoomId);
        } else {
          final copyText = (card.payload['copyText'] ?? card.title).toString();
          await Clipboard.setData(ClipboardData(text: copyText));
          widget.onToast('📋 已複製搜尋結果');
        }
        break;
      case 'create_room':
        final name = (card.payload['roomName'] ?? card.title).toString();
        await widget.onCreateRoom(name);
        break;
      case 'notification':
        final hour = (card.payload['hour'] as num?)?.toInt();
        final minute = (card.payload['minute'] as num?)?.toInt();
        final title = (card.payload['title'] ?? card.title).toString();
        if (hour != null && minute != null) {
          await NativeActions.setSystemAlarmClock(
            hour: hour,
            minute: minute,
            message: title,
            skipUi: false,
          );
          widget.onToast('⏰ 已開啟系統「時鐘」設定真鬧鐘');
        } else {
          widget.onToast('⏰ 系統通知已於 ${card.payload['time'] ?? ''} 排程');
        }
        break;
    }
  }
}
