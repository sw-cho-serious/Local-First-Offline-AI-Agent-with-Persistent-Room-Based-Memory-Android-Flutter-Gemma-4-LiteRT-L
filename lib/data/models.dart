import 'dart:convert';

enum SpiritState {
  idle('idle', '待命'),
  thinking('thinking', '思考中'),
  working('working', '工作中'),
  waiting('waiting', '等待中'),
  done('done', '已完成'),
  stuck('stuck', '卡住了');

  const SpiritState(this.code, this.label);
  final String code;
  final String label;

  static SpiritState fromCode(String? code) {
    for (final value in SpiritState.values) {
      if (value.code == code) return value;
    }
    return SpiritState.idle;
  }
}

class TodoItem {
  const TodoItem({
    required this.lineIndex,
    required this.text,
    required this.done,
  });

  final int lineIndex;
  final String text;
  final bool done;

  TodoItem copyWith({bool? done, String? text}) {
    return TodoItem(
      lineIndex: lineIndex,
      text: text ?? this.text,
      done: done ?? this.done,
    );
  }
}

class RoomRecord {
  const RoomRecord({
    required this.roomId,
    required this.title,
    required this.subtitle,
    required this.colorHex,
    required this.accessory,
    required this.avatarState,
    required this.rollingSummary,
    required this.summarizedUntilMsgId,
    required this.updatedAt,
  });

  final String roomId;
  final String title;
  final String subtitle;
  final String colorHex;
  final String accessory;
  final SpiritState avatarState;
  final String rollingSummary;
  final int summarizedUntilMsgId;
  final int updatedAt;

  bool get isMain => roomId == 'main';
  bool get isArchived => roomId.startsWith('para:archives:') || avatarState == SpiritState.done;

  factory RoomRecord.fromMap(Map<String, Object?> map) {
    return RoomRecord(
      roomId: map['room_id'] as String,
      title: map['title'] as String,
      subtitle: map['subtitle'] as String? ?? '',
      colorHex: map['color_hex'] as String? ?? '#F59E0B',
      accessory: map['accessory'] as String? ?? 'helmet',
      avatarState: SpiritState.fromCode(map['avatar_state'] as String?),
      rollingSummary: map['rolling_summary'] as String? ?? '',
      summarizedUntilMsgId: map['summarized_until_msg_id'] as int? ?? 0,
      updatedAt: map['updated_at'] as int? ?? 0,
    );
  }
}

class ActionCardData {
  const ActionCardData({
    required this.type,
    required this.badge,
    required this.title,
    required this.rows,
    required this.buttonLabel,
    required this.payload,
  });

  /// Types: 'calendar', 'profile', 'tuning', 'notification', 'create_room'
  final String type;
  final String badge;
  final String title;
  final List<String> rows;
  final String buttonLabel;
  final Map<String, dynamic> payload;

  String toJsonString() => jsonEncode({
        'type': type,
        'badge': badge,
        'title': title,
        'rows': rows,
        'buttonLabel': buttonLabel,
        'payload': payload,
      });

  static ActionCardData? tryParse(String? raw) {
    if (raw == null || raw.isEmpty) return null;
    try {
      final decoded = jsonDecode(raw) as Map<String, dynamic>;
      return ActionCardData(
        type: decoded['type'] as String? ?? 'info',
        badge: decoded['badge'] as String? ?? '',
        title: decoded['title'] as String? ?? '',
        rows: (decoded['rows'] as List<dynamic>? ?? const [])
            .map((e) => e.toString())
            .toList(),
        buttonLabel: decoded['buttonLabel'] as String? ?? '',
        payload: (decoded['payload'] as Map<String, dynamic>? ?? const {}),
      );
    } catch (_) {
      return null;
    }
  }
}

class ChatMessageRecord {
  const ChatMessageRecord({
    required this.id,
    required this.roomId,
    required this.role,
    required this.content,
    this.imagePath,
    this.toolPill,
    this.cardJson,
    this.isStarred = false,
    this.archivedColorHex,
    this.archivedTitle,
    required this.createdAt,
  });

  final int id;
  final String roomId;

  /// 'user' | 'model' | 'divider'
  final String role;
  final String content;
  final String? imagePath;
  final String? toolPill;
  final String? cardJson;
  final bool isStarred;
  final String? archivedColorHex;
  final String? archivedTitle;
  final int createdAt;

  ActionCardData? get card => ActionCardData.tryParse(cardJson);

  factory ChatMessageRecord.fromMap(Map<String, Object?> map) {
    return ChatMessageRecord(
      id: map['id'] as int,
      roomId: map['room_id'] as String,
      role: map['role'] as String,
      content: map['content'] as String,
      imagePath: map['image_path'] as String?,
      toolPill: map['tool_pill'] as String?,
      cardJson: map['card_json'] as String?,
      isStarred: (map['is_starred'] as int? ?? 0) == 1,
      archivedColorHex: map['archived_color_hex'] as String?,
      archivedTitle: map['archived_title'] as String?,
      createdAt: map['created_at'] as int? ?? 0,
    );
  }
}

class ProfileRecord {
  const ProfileRecord({
    required this.code,
    required this.weightPerM,
    required this.stockRule,
    required this.extrudable,
    required this.note,
  });

  final String code;
  final double weightPerM;
  final String stockRule;
  final bool extrudable;
  final String note;

  factory ProfileRecord.fromMap(Map<String, Object?> map) {
    return ProfileRecord(
      code: map['code'] as String,
      weightPerM: (map['weight_per_m'] as num).toDouble(),
      stockRule: map['stock_rule'] as String? ?? '6000mm',
      extrudable: (map['extrudable'] as int? ?? 0) == 1,
      note: map['note'] as String? ?? '',
    );
  }
}

class MachineTuningRecord {
  const MachineTuningRecord({
    required this.id,
    required this.keywords,
    required this.title,
    required this.formula,
    required this.note,
  });

  final String id;
  final String keywords;
  final String title;
  final String formula;
  final String note;

  factory MachineTuningRecord.fromMap(Map<String, Object?> map) {
    return MachineTuningRecord(
      id: map['id'] as String,
      keywords: map['keywords'] as String? ?? '',
      title: map['title'] as String? ?? '',
      formula: map['formula'] as String? ?? '',
      note: map['note'] as String? ?? '',
    );
  }
}

class RoomTodoGroup {
  const RoomTodoGroup({
    required this.room,
    required this.todos,
  });

  final RoomRecord room;
  final List<TodoItem> todos;
}

class GlobalPendingMemo {
  const GlobalPendingMemo({
    required this.starredMessages,
    required this.pendingTodoGroups,
  });

  final List<({ChatMessageRecord message, RoomRecord? room})> starredMessages;
  final List<RoomTodoGroup> pendingTodoGroups;

  int get totalCount {
    var todoTotal = 0;
    for (final g in pendingTodoGroups) {
      todoTotal += g.todos.length;
    }
    return starredMessages.length + todoTotal;
  }
}
