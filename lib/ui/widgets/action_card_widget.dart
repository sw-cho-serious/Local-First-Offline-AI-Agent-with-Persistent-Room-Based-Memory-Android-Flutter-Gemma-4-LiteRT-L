import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../data/models.dart';
import '../../tools/native_actions.dart';

class ActionCardWidget extends StatelessWidget {
  const ActionCardWidget({
    super.key,
    required this.card,
    required this.onCreateRoom,
    required this.onToast,
  });

  final ActionCardData card;
  final Future<void> Function(String title) onCreateRoom;
  final void Function(String message) onToast;

  @override
  Widget build(BuildContext context) {
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
          if (card.buttonLabel.isNotEmpty) ...[
            const SizedBox(height: 8),
            SizedBox(
              width: double.infinity,
              child: OutlinedButton(
                style: OutlinedButton.styleFrom(
                  backgroundColor: const Color(0xFFF59E0B).withValues(alpha: 0.15),
                  side: BorderSide(color: const Color(0xFFFBBF24).withValues(alpha: 0.4)),
                  foregroundColor: const Color(0xFFFDE68A),
                  padding: const EdgeInsets.symmetric(vertical: 10),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(9),
                  ),
                ),
                onPressed: () => _handleAction(context),
                child: Text(
                  card.buttonLabel,
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
    switch (card.type) {
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
        onToast('📅 已喚起 Android 日曆新增畫面');
        break;
      case 'profile':
      case 'tuning':
        final copyText = (card.payload['copyText'] ?? card.title).toString();
        await Clipboard.setData(ClipboardData(text: copyText));
        onToast('📋 已複製至剪貼簿');
        break;
      case 'create_room':
        final name = (card.payload['roomName'] ?? card.title).toString();
        await onCreateRoom(name);
        break;
      case 'notification':
        onToast('⏰ 系統通知已於 ${card.payload['time'] ?? ''} 排程');
        break;
    }
  }
}
