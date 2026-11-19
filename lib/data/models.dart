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

  /// Types: 'calendar', 'profile', 'tuning', 'notification', 'create_room', 'skill', 'device_action'
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

class HookRecord {
  const HookRecord({
    required this.name,
    required this.description,
    required this.params,
    required this.body,
    required this.updatedAt,
  });

  final String name;
  final String description;
  final List<String> params;
  final String body;
  final int updatedAt;

  String get paramsCsv => params.join(', ');

  factory HookRecord.fromMap(Map<String, Object?> map) {
    final rawParams = (map['params_json'] as String? ?? '[]').trim();
    var parsed = <String>[];
    if (rawParams.isNotEmpty) {
      try {
        final decoded = jsonDecode(rawParams);
        if (decoded is List) {
          parsed = decoded
              .map((e) => e.toString().trim())
              .where((e) => e.isNotEmpty)
              .toList();
        }
      } catch (_) {}
    }
    return HookRecord(
      name: (map['name'] as String? ?? '').trim(),
      description: map['description'] as String? ?? '',
      params: parsed,
      body: map['body'] as String? ?? '',
      updatedAt: map['updated_at'] as int? ?? 0,
    );
  }
}

class SkillRecord {
  const SkillRecord({
    required this.id,
    required this.name,
    required this.triggerKeywords,
    required this.description,
    required this.contentMd,
    required this.enabled,
    required this.updatedAt,
  });

  final String id;
  final String name;
  final List<String> triggerKeywords;
  final String description;
  final String contentMd;
  final bool enabled;
  final int updatedAt;

  String get triggerKeywordsCsv => triggerKeywords.join(',');

  bool matchesInput(String userText) {
    if (!enabled) return false;
    final lower = userText.toLowerCase().trim();
    if (lower.isEmpty) return false;
    if (name.trim().isNotEmpty && lower.contains('@${name.trim().toLowerCase()}')) {
      return true;
    }
    for (final rawKw in triggerKeywords) {
      final kw = rawKw.trim().toLowerCase();
      if (kw.isNotEmpty && lower.contains(kw)) {
        return true;
      }
    }
    return false;
  }

  static List<String> parseKeywords(String raw) {
    return raw
        .split(RegExp(r'[,，、\s]+'))
        .map((e) => e.trim())
        .where((e) => e.isNotEmpty)
        .toList();
  }

  static SkillRecord parseFromMarkdown(
    String rawMd, {
    String? id,
    String? fallbackName,
  }) {
    final normalized = rawMd.replaceAll('\r\n', '\n').trim();
    var name = (fallbackName ?? '').trim();
    var desc = '';
    var keywords = <String>[];
    var enabled = true;
    var body = normalized;

    final fmMatch = RegExp(r'^---\s*\n([\s\S]*?)\n---\s*\n?([\s\S]*)$').firstMatch(normalized);
    if (fmMatch != null) {
      final header = fmMatch.group(1) ?? '';
      body = (fmMatch.group(2) ?? '').trim();
      for (final line in header.split('\n')) {
        final idx = line.indexOf(':');
        if (idx <= 0) continue;
        final key = line.substring(0, idx).trim().toLowerCase();
        var val = line.substring(idx + 1).trim();
        if ((val.startsWith('"') && val.endsWith('"')) ||
            (val.startsWith("'") && val.endsWith("'"))) {
          if (val.length >= 2) val = val.substring(1, val.length - 1);
        }
        switch (key) {
          case 'name':
          case 'title':
            if (val.isNotEmpty) name = val;
            break;
          case 'description':
          case 'desc':
            if (val.isNotEmpty) desc = val;
            break;
          case 'trigger_keywords':
          case 'keywords':
          case 'triggers':
            keywords = parseKeywords(val.replaceAll(RegExp(r'[\[\]]'), ''));
            break;
          case 'enabled':
            enabled = val.toLowerCase() != 'false' && val != '0';
            break;
        }
      }
    }

    if (name.isEmpty) {
      final h1Match = RegExp(r'^#\s+(.+)$', multiLine: true).firstMatch(body);
      if (h1Match != null) {
        name = h1Match.group(1)!.trim();
      }
    }
    if (name.isEmpty) {
      name = '自訂技能_${DateTime.now().millisecondsSinceEpoch % 10000}';
    }
    if (desc.isEmpty) {
      for (final line in body.split('\n')) {
        final t = line.trim();
        if (t.isEmpty || t.startsWith('#')) continue;
        desc = t.length > 60 ? '${t.substring(0, 60)}...' : t;
        break;
      }
    }
    if (desc.isEmpty) {
      desc = '$name 現場技能指引';
    }
    if (keywords.isEmpty) {
      keywords = [name];
    }

    final cleanId = (id != null && id.trim().isNotEmpty)
        ? id.trim()
        : 'skill_${name.replaceAll(RegExp(r'\s+'), '_')}';

    return SkillRecord(
      id: cleanId,
      name: name,
      triggerKeywords: keywords,
      description: desc,
      contentMd: body.isEmpty ? normalized : body,
      enabled: enabled,
      updatedAt: DateTime.now().millisecondsSinceEpoch,
    );
  }

  factory SkillRecord.fromMap(Map<String, Object?> map) {
    final enabledRaw = map['enabled'];
    final isEnabled = enabledRaw is bool
        ? enabledRaw
        : ((enabledRaw as num?)?.toInt() ?? 1) != 0;
    return SkillRecord(
      id: (map['id'] as String? ?? '').trim(),
      name: (map['name'] as String? ?? '').trim(),
      triggerKeywords: parseKeywords((map['trigger_keywords'] ?? '').toString()),
      description: (map['description'] ?? '').toString(),
      contentMd: (map['content_md'] ?? '').toString(),
      enabled: isEnabled,
      updatedAt: (map['updated_at'] as num?)?.toInt() ?? 0,
    );
  }
}

class OperatorFlagRecord {
  const OperatorFlagRecord({
    required this.id,
    required this.messageId,
    required this.roomId,
    required this.reason,
    required this.userNote,
    required this.flaggedContent,
    required this.reviewed,
    required this.lesson,
    required this.createdAt,
    required this.updatedAt,
  });

  final String id;
  final int messageId;
  final String roomId;
  final String reason;
  final String userNote;
  final String flaggedContent;
  final bool reviewed;
  final String lesson;
  final int createdAt;
  final int updatedAt;

  Map<String, Object?> toMap() => {
        'id': id,
        'message_id': messageId,
        'room_id': roomId,
        'reason': reason,
        'user_note': userNote,
        'flagged_content': flaggedContent,
        'reviewed': reviewed ? 1 : 0,
        'lesson': lesson,
        'created_at': createdAt,
        'updated_at': updatedAt,
      };

  factory OperatorFlagRecord.fromMap(Map<String, Object?> map) {
    return OperatorFlagRecord(
      id: (map['id'] ?? '').toString(),
      messageId: (map['message_id'] as num?)?.toInt() ?? 0,
      roomId: (map['room_id'] ?? 'main').toString(),
      reason: (map['reason'] ?? '').toString(),
      userNote: (map['user_note'] ?? '').toString(),
      flaggedContent: (map['flagged_content'] ?? '').toString(),
      reviewed: ((map['reviewed'] as num?)?.toInt() ?? 0) != 0,
      lesson: (map['lesson'] ?? '').toString(),
      createdAt: (map['created_at'] as num?)?.toInt() ?? 0,
      updatedAt: (map['updated_at'] as num?)?.toInt() ?? 0,
    );
  }
}

class RoutineRecord {
  const RoutineRecord({
    required this.id,
    required this.title,
    required this.body,
    required this.mode,
    required this.timeSpec,
    required this.weekdaysCsv,
    required this.enabled,
    required this.updatedAt,
  });

  final String id;
  final String title;
  final String body;

  /// `'once'` | `'daily'` | `'weekly'` | `'cron'`
  final String mode;
  final String timeSpec;
  final String weekdaysCsv;
  final bool enabled;
  final int updatedAt;

  List<int> get weekdays {
    final parsed = weekdaysCsv
        .split(RegExp(r'[,，\s]+'))
        .map((s) => int.tryParse(s.trim()))
        .whereType<int>()
        .where((d) => d >= 1 && d <= 7)
        .toList();
    return parsed.isEmpty ? const [1, 2, 3, 4, 5, 6] : parsed;
  }

  String get modeLabel {
    switch (mode) {
      case 'once':
        return '單次';
      case 'weekly':
        return '每週';
      case 'cron':
        return 'Cron';
      case 'daily':
      default:
        return '每日';
    }
  }

  Map<String, Object?> toMap() => {
        'id': id,
        'title': title,
        'body': body,
        'mode': mode,
        'time_spec': timeSpec,
        'weekdays_csv': weekdaysCsv,
        'enabled': enabled ? 1 : 0,
        'updated_at': updatedAt,
      };

  factory RoutineRecord.fromMap(Map<String, Object?> map) {
    final enabledRaw = map['enabled'];
    final isEnabled = enabledRaw is bool
        ? enabledRaw
        : ((enabledRaw as num?)?.toInt() ?? 1) != 0;
    return RoutineRecord(
      id: (map['id'] ?? '').toString(),
      title: (map['title'] ?? '').toString(),
      body: (map['body'] ?? '').toString(),
      mode: (map['mode'] ?? 'daily').toString(),
      timeSpec: (map['time_spec'] ?? '08:00').toString(),
      weekdaysCsv: (map['weekdays_csv'] ?? '1,2,3,4,5,6').toString(),
      enabled: isEnabled,
      updatedAt: (map['updated_at'] as num?)?.toInt() ?? 0,
    );
  }
}
