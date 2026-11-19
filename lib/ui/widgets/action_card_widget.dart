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
    this.onOpenAnnotator,
    this.onOpenAlbumScanner,
    this.onOpenGpxImport,
    this.onOpenHookManager,
    this.onOpenSkillManager,
    this.onOpenRoutineManager,
  });

  final ActionCardData card;
  final Future<void> Function(String title) onCreateRoom;
  final void Function(String message) onToast;
  final Future<void> Function(String roomId)? onJumpToRoom;
  final Future<void> Function(String note)? onOpenAnnotator;
  final Future<void> Function()? onOpenAlbumScanner;
  final Future<void> Function()? onOpenGpxImport;
  final Future<void> Function()? onOpenHookManager;
  final Future<void> Function()? onOpenSkillManager;
  final Future<void> Function()? onOpenRoutineManager;

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
          if (card.payload['sources'] is List &&
              (card.payload['sources'] as List).isNotEmpty) ...[
            const SizedBox(height: 8),
            const Text(
              '🔗 點擊驗證來源連結：',
              style: TextStyle(fontSize: 11.5, color: Color(0xFF93C5FD), fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 5),
            Wrap(
              spacing: 6,
              runSpacing: 6,
              children: [
                for (final raw in (card.payload['sources'] as List))
                  if (raw is Map && (raw['url'] ?? '').toString().trim().isNotEmpty)
                    Builder(
                      builder: (_) {
                        final srcUrl = (raw['url'] ?? '').toString().trim();
                        final srcDomain = (raw['domain'] ?? '').toString().trim();
                        final srcTitle = (raw['title'] ?? '來源網頁').toString().trim();
                        final shortTitle = srcTitle.length > 18
                            ? '${srcTitle.substring(0, 18)}…'
                            : srcTitle;
                        final label = srcDomain.isNotEmpty
                            ? '$shortTitle ($srcDomain)'
                            : shortTitle;
                        return InkWell(
                          borderRadius: BorderRadius.circular(8),
                          onTap: () async {
                            final res = await NativeActions.openExternalUrl(srcUrl);
                            if (res['ok'] == true) {
                              widget.onToast(
                                res['copied'] == true
                                    ? '📋 已複製來源網址：$srcDomain'
                                    : '🌐 開啟來源：${srcDomain.isNotEmpty ? srcDomain : srcUrl}',
                              );
                            } else {
                              widget.onToast('⚠️ 無法開啟連結：${res['reason'] ?? ''}');
                            }
                          },
                          child: Container(
                            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
                            decoration: BoxDecoration(
                              color: const Color(0xFF1E293B),
                              borderRadius: BorderRadius.circular(8),
                              border: Border.all(
                                color: const Color(0xFF38BDF8).withValues(alpha: 0.4),
                              ),
                            ),
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                const Icon(Icons.open_in_new, size: 12, color: Color(0xFF7DD3FC)),
                                const SizedBox(width: 4),
                                Text(
                                  '🌐 $label',
                                  style: const TextStyle(
                                    fontSize: 11,
                                    color: Color(0xFFBAE6FD),
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        );
                      },
                    ),
              ],
            ),
          ],
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
      case 'location':
        final lat = (card.payload['lat'] as num?)?.toDouble();
        final lng = (card.payload['lng'] as num?)?.toDouble();
        final label = (card.payload['label'] ?? card.title).toString();
        if (lat != null && lng != null) {
          await NativeActions.openMapLocation(lat, lng, label: label);
          widget.onToast('🗺️ 已開啟地圖定位：$label');
        } else {
          final copyText = (card.payload['copyText'] ?? card.title).toString();
          await Clipboard.setData(ClipboardData(text: copyText));
          widget.onToast('📋 已複製位置座標');
        }
        break;
      case 'gpx_import':
        if (widget.onOpenGpxImport != null) {
          await widget.onOpenGpxImport!();
        }
        break;
      case 'share_line':
        final text = (card.payload['text'] ?? card.payload['copyText'] ?? card.title).toString();
        final imagePath = card.payload['imagePath']?.toString();
        final res = await NativeActions.shareToLine(text: text, imagePath: imagePath);
        if (!res.ok) {
          await Clipboard.setData(ClipboardData(text: text));
          widget.onToast('📋 系統分享未開啟，已複製文字至剪貼簿');
        }
        break;
      case 'photo_annotate':
        if (widget.onOpenAnnotator != null) {
          final note = (card.payload['note'] ?? '').toString();
          await widget.onOpenAnnotator!(note);
        }
        break;
      case 'album_scan':
        if (widget.onOpenAlbumScanner != null) {
          await widget.onOpenAlbumScanner!();
        }
        break;
      case 'hook':
      case 'skill':
        if (widget.onOpenSkillManager != null) {
          await widget.onOpenSkillManager!();
        } else {
          final copyText = (card.payload['copyText'] ?? card.title).toString();
          await Clipboard.setData(ClipboardData(text: copyText));
          widget.onToast('📋 已複製技能資訊');
        }
        break;
      case 'device_action':
        final action = (card.payload['action'] ?? '').toString();
        final rawParams = card.payload['params'];
        final params = rawParams is Map
            ? Map<String, dynamic>.from(rawParams)
            : <String, dynamic>{};
        if (action.isNotEmpty) {
          final res = await NativeActions.callNativeAction(action, params);
          if (res['ok'] == true) {
            widget.onToast('✅ 已喚起原生動作：$action');
          } else {
            widget.onToast('⚠️ ${res['reason'] ?? '原生動作執行未完成'}');
          }
        }
        break;
      case 'web_search':
      case 'consult_peer':
        final primaryUrl = (card.payload['primaryUrl'] ?? '').toString().trim();
        if (primaryUrl.isNotEmpty) {
          final res = await NativeActions.openExternalUrl(primaryUrl);
          widget.onToast(
            res['ok'] == true ? '🌐 已開啟查證網頁' : '⚠️ ${res['reason'] ?? '無法開啟'}',
          );
        } else {
          final copyText = (card.payload['copyText'] ?? card.title).toString();
          await Clipboard.setData(ClipboardData(text: copyText));
          widget.onToast('📋 已複製聯網／參謀整理結果');
        }
        break;
      case 'routine':
        if (widget.onOpenRoutineManager != null) {
          await widget.onOpenRoutineManager!();
        }
        break;
    }
  }
}
