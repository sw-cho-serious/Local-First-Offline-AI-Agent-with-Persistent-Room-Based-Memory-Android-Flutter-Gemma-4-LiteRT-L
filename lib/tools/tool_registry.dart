import 'package:flutter_edge_ai/flutter_edge_ai.dart';

import '../data/database_helper.dart';
import '../data/models.dart';
import 'native_actions.dart';

class AtToolOption {
  const AtToolOption({
    required this.atLabel,
    required this.toolName,
    required this.subtitle,
    required this.colorHex,
  });

  final String atLabel;
  final String toolName;
  final String subtitle;
  final String colorHex;
}

class ToolExecutionOutcome {
  const ToolExecutionOutcome({
    required this.toolResponse,
    this.toolPill,
    this.card,
    this.directReply,
  });

  final Map<String, dynamic> toolResponse;
  final String? toolPill;
  final ActionCardData? card;
  final String? directReply;
}

class ToolRegistry {
  ToolRegistry(this._db);

  final DatabaseHelper _db;

  static const List<AtToolOption> atOptions = [
    AtToolOption(
      atLabel: '@查鋁料',
      toolName: 'lookup_profile',
      subtitle: '77款規格/單重/排抽',
      colorHex: '#F59E0B',
    ),
    AtToolOption(
      atLabel: '@查調機',
      toolName: 'lookup_machine_tuning',
      subtitle: 'NC沖孔/跨距/鋸路公式',
      colorHex: '#38BDF8',
    ),
    AtToolOption(
      atLabel: '@記待辦',
      toolName: 'data_write',
      subtitle: '安全追加至本房清單',
      colorHex: '#10B981',
    ),
    AtToolOption(
      atLabel: '@設鬧鐘',
      toolName: 'schedule_notification',
      subtitle: '系統通知準時提醒',
      colorHex: '#A855F7',
    ),
    AtToolOption(
      atLabel: '@排日曆',
      toolName: 'create_calendar_event',
      subtitle: '直寫 Google / 系統日曆',
      colorHex: '#FB7185',
    ),
  ];

  /// Matches manual or mounted leading @ tool commands so execution is 100% deterministic.
  static ({AtToolOption option, String cleanText})? matchLeadingAtTool(String rawText) {
    final trimmed = rawText.trimLeft();
    if (!trimmed.startsWith('@')) return null;

    const aliases = <String, int>{
      '@查鋁料': 0,
      '@查調機': 1,
      '@記待辦': 2,
      '@寫待辦': 2,
      '@設鬧鐘': 3,
      '@設提醒': 3,
      '@排日曆': 4,
    };

    for (final entry in aliases.entries) {
      final tag = entry.key;
      if (trimmed.startsWith(tag)) {
        final afterTag = trimmed.substring(tag.length);
        if (afterTag.isEmpty || RegExp(r'^[\s:：,，]').hasMatch(afterTag)) {
          final clean = afterTag.replaceFirst(RegExp(r'^[\s:：,，]+'), '').trim();
          return (option: atOptions[entry.value], cleanText: clean);
        }
      }
    }
    return null;
  }

  static Tool buildSchema(String toolName) {
    switch (toolName) {
      case 'lookup_profile':
        return const Tool(
          name: 'lookup_profile',
          description: '查詢自訂材料單米重、定尺規格與門檻資格。若提供長度(mm)與支數，同時算出總重與含損耗備料。',
          parameters: {
            'type': 'object',
            'properties': {
              'code': {'type': 'string', 'description': '料號，例如 094, 093Z, 098M, WL2045'},
              'length_mm': {'type': 'number', 'description': '選填：單支長度(mm)'},
              'qty': {'type': 'integer', 'description': '選填：支數'},
            },
            'required': ['code'],
          },
        );
      case 'lookup_machine_tuning':
        return const Tool(
          name: 'lookup_machine_tuning',
          description: '精準查詢沖孔、彎管、跨距與機台加工公式。查無資料時不可猜測。',
          parameters: {
            'type': 'object',
            'properties': {
              'query': {'type': 'string', 'description': '關鍵字或料號，例如 WL2045, 3060X, 邊蓋, 鋸路'},
            },
            'required': ['query'],
          },
        );
      case 'data_write':
        return const Tool(
          name: 'data_write',
          description: '將工作項目追加寫入當前工作房間待辦清單（不覆寫舊項目），或將既有項目標為完成。',
          parameters: {
            'type': 'object',
            'properties': {
              'item_text': {'type': 'string', 'description': '單筆待辦內容'},
              'status': {'type': 'string', 'enum': ['pending', 'done'], 'description': 'pending 新增待辦，done 勾選完成'},
            },
            'required': ['item_text'],
          },
        );
      case 'schedule_notification':
        return const Tool(
          name: 'schedule_notification',
          description: '設定手機本地提醒通知鬧鐘。',
          parameters: {
            'type': 'object',
            'properties': {
              'title': {'type': 'string', 'description': '提醒標題'},
              'body': {'type': 'string', 'description': '提醒內容'},
              'trigger_iso': {'type': 'string', 'description': 'ISO8601 本地觸發時間，例如 2026-11-17T08:00:00'},
            },
            'required': ['title', 'trigger_iso'],
          },
        );
      case 'create_calendar_event':
        return const Tool(
          name: 'create_calendar_event',
          description: '建立系統日曆事件草稿卡片。',
          parameters: {
            'type': 'object',
            'properties': {
              'title': {'type': 'string', 'description': '事件標題'},
              'start_iso': {'type': 'string', 'description': 'ISO8601 開始時間，例如 2026-11-17T08:00:00'},
              'description': {'type': 'string', 'description': '補充說明'},
            },
            'required': ['title', 'start_iso'],
          },
        );
      default:
        throw ArgumentError('Unknown tool: $toolName');
    }
  }

  Future<ToolExecutionOutcome> executeTool({
    required String toolName,
    required Map<String, dynamic> args,
    required String roomId,
  }) async {
    switch (toolName) {
      case 'lookup_profile':
        return _runLookupProfile(args);
      case 'lookup_machine_tuning':
        return _runLookupTuning(args);
      case 'data_write':
        return _runDataWrite(args, roomId);
      case 'schedule_notification':
        return _runScheduleNotification(args);
      case 'create_calendar_event':
        return _runCreateCalendar(args);
      default:
        return ToolExecutionOutcome(
          toolResponse: {'error': '未知工具: $toolName'},
          toolPill: '⚠️ 未知工具 $toolName',
        );
    }
  }

  /// Deterministic fallback executor when the 3.7GB LLM weights are not yet
  /// installed on the device, so @ tools and interactive cards still work 100%.
  Future<ToolExecutionOutcome> executeFallbackFromAtOption({
    required AtToolOption option,
    required String userText,
    required String roomId,
  }) async {
    final clean = userText.trim();
    switch (option.toolName) {
      case 'lookup_profile':
        final match = RegExp(r'([A-Za-z0-9\-\(\)/]+)').firstMatch(clean);
        final code = match?.group(1) ?? clean;
        final lenMatch = RegExp(r'(\d+(?:\.\d+)?)\s*(?:mm|MM|毫米)').firstMatch(clean);
        final qtyMatch = RegExp(r'(\d+)\s*[支隻片條]').firstMatch(clean);
        return _runLookupProfile({
          'code': code,
          if (lenMatch != null) 'length_mm': double.tryParse(lenMatch.group(1)!),
          if (qtyMatch != null) 'qty': int.tryParse(qtyMatch.group(1)!),
        });
      case 'lookup_machine_tuning':
        return _runLookupTuning({'query': clean});
      case 'data_write':
        return _runDataWrite({'item_text': clean, 'status': 'pending'}, roomId);
      case 'schedule_notification':
        final dt = parseLooseDateTime(clean);
        final title = _extractCleanEventTitle(clean, 'KODARI 現場提醒');
        return _runScheduleNotification({
          'title': title,
          'body': clean.isEmpty ? title : clean,
          'trigger_iso': dt.toIso8601String(),
        });
      case 'create_calendar_event':
        final dt = parseLooseDateTime(clean);
        final title = _extractCleanEventTitle(clean, '工作排程事件');
        return _runCreateCalendar({
          'title': title,
          'start_iso': dt.toIso8601String(),
          'description': clean.isEmpty ? '由《HAKO • KODARI》建立' : clean,
        });
      default:
        return const ToolExecutionOutcome(toolResponse: {'status': 'noop'});
    }
  }

  Future<ToolExecutionOutcome> _runLookupProfile(Map<String, dynamic> args) async {
    final code = (args['code'] ?? '').toString().trim();
    final hits = await _db.lookupProfiles(code);
    if (hits.isEmpty) {
      return ToolExecutionOutcome(
        toolResponse: {'found': false, 'message': '查無料號 $code，嚴禁自行推測單重。'},
        toolPill: '🔍 lookup_profile：查無 $code',
        directReply: 'SQLite 料表裡找不到「$code」，照廠裡規矩我不亂猜，再確認一下料號。',
      );
    }

    final first = hits.first;
    final lengthMm = (args['length_mm'] as num?)?.toDouble();
    final qty = (args['qty'] as num?)?.toInt();

    final rows = <String>[
      '單米重：${first.weightPerM.toStringAsFixed(2)} kg/m',
      '定尺規則：${first.stockRule}（鋸路 3.5mm）',
      '特殊排抽：${first.extrudable ? '可排抽料型（累計 >=300kg 走排抽）' : '固定走一般定尺開料'}',
    ];

    if (lengthMm != null && qty != null && lengthMm > 0 && qty > 0) {
      final totalKg = (lengthMm / 1000.0) * qty * first.weightPerM;
      final prepKg = totalKg * 1.09;
      rows.add(
        '試算重量：$qty 支 × ${lengthMm.toStringAsFixed(0)}mm = ${totalKg.toStringAsFixed(2)} kg（1.09 備料 ${prepKg.toStringAsFixed(2)} kg）',
      );
      if (first.extrudable && totalKg >= 300.0) {
        rows.add('🔴 達 300kg 排抽門檻，建議訂製特殊定尺！');
      }
    }
    if (first.note.isNotEmpty) {
      rows.add('備註：${first.note}');
    }

    final card = ActionCardData(
      type: 'profile',
      badge: '🔩 材料規格表',
      title: '${first.code} 料型規格',
      rows: rows,
      buttonLabel: '📋 一鍵複製規格',
      payload: {'copyText': '${first.code}｜${rows.join(' / ')}'},
    );

    return ToolExecutionOutcome(
      toolResponse: {
        'found': true,
        'code': first.code,
        'weight_per_m': first.weightPerM,
        'stock_rule': first.stockRule,
        'extrudable': first.extrudable,
        'note': first.note,
      },
      toolPill: '🔩 lookup_profile：已撈出 ${first.code}',
      card: card,
      directReply: '${first.code} 規格從離線表調出來了：',
    );
  }

  Future<ToolExecutionOutcome> _runLookupTuning(Map<String, dynamic> args) async {
    final query = (args['query'] ?? '').toString().trim();
    final hits = await _db.lookupMachineTuning(query);
    if (hits.isEmpty) {
      return ToolExecutionOutcome(
        toolResponse: {'found': false, 'message': '查無參數，嚴禁模型推論。'},
        toolPill: '🔧 lookup_machine_tuning：查無參數',
        directReply: '「$query」在已驗證調機庫裡查無參數，不亂編，現場實測完再補進來。',
      );
    }

    final first = hits.first;
    final rows = <String>[first.formula];
    if (first.note.isNotEmpty) rows.add(first.note);
    if (hits.length > 1) {
      rows.add('另有 ${hits.length - 1} 筆相關條目（可於更多選單 🔍 檢視全部）');
    }

    final card = ActionCardData(
      type: 'tuning',
      badge: '🔧 已驗證加工／調機參數',
      title: first.title,
      rows: rows,
      buttonLabel: '📋 複製調機公式',
      payload: {'copyText': '${first.title}：${first.formula}'},
    );

    return ToolExecutionOutcome(
      toolResponse: {
        'found': true,
        'title': first.title,
        'formula': first.formula,
        'note': first.note,
      },
      toolPill: '🔧 lookup_machine_tuning：已查出參數',
      card: card,
      directReply: '${first.title} 的公式參數在這裡：',
    );
  }

  Future<ToolExecutionOutcome> _runDataWrite(
    Map<String, dynamic> args,
    String roomId,
  ) async {
    final text = (args['item_text'] ?? args['value'] ?? '').toString().trim();
    final status = (args['status'] ?? 'pending').toString().trim();
    if (text.isEmpty) {
      return const ToolExecutionOutcome(
        toolResponse: {'ok': false, 'error': 'item_text 為空'},
      );
    }
    final res = await _db.upsertTodoItem(
      roomId: roomId,
      itemText: text,
      status: status,
    );
    return ToolExecutionOutcome(
      toolResponse: {
        'ok': true,
        'key': res.key,
        'toggled': res.toggled,
        'done': res.done,
        'total': res.total,
      },
      toolPill: res.toggled ? '☑️ data_write：已更新完成狀態' : '✅ data_write：已追加至 ${res.key}',
      directReply: res.toggled
          ? '好，「$text」幫你打勾收掉了（目前進度 ${res.done}/${res.total}）。'
          : '收到，「$text」已經穩穩追加進這間房的清單了。',
    );
  }

  Future<ToolExecutionOutcome> _runScheduleNotification(Map<String, dynamic> args) async {
    final title = (args['title'] ?? 'KODARI 現場提醒').toString();
    final body = (args['body'] ?? title).toString();
    final rawTime = (args['trigger_iso'] ?? '').toString();
    final triggerTime = _resolveToolDateTime(rawTime, '$title $body');

    final res = await NativeActions.scheduleReminder(
      title: title,
      body: body,
      triggerTime: triggerTime,
    );

    final card = ActionCardData(
      type: 'notification',
      badge: '⏰ 本地提醒已排程',
      title: title,
      rows: [
        '提醒時間：${res.displayTime}',
        if (body != title) '備註：$body',
      ],
      buttonLabel: '⏰ 系統通知已設定',
      payload: {'time': res.displayTime},
    );

    return ToolExecutionOutcome(
      toolResponse: {'scheduled': res.scheduled, 'time': res.displayTime},
      toolPill: '⏰ 已設定提醒：${res.displayTime}',
      card: card,
      directReply: '好，${res.displayTime} 的提醒幫你釘好了。',
    );
  }

  Future<ToolExecutionOutcome> _runCreateCalendar(Map<String, dynamic> args) async {
    final title = (args['title'] ?? '工作排程事件').toString();
    final desc = (args['description'] ?? '由《HAKO • KODARI》建立').toString();
    final rawStart = (args['start_iso'] ?? '').toString();
    final startTime = _resolveToolDateTime(rawStart, '$title $desc');
    final h = startTime.hour.toString().padLeft(2, '0');
    final m = startTime.minute.toString().padLeft(2, '0');
    final display = '${startTime.year}/${startTime.month}/${startTime.day} $h:$m';

    final direct = await NativeActions.insertCalendarEventDirect(
      title: title,
      startTime: startTime,
      description: desc,
    );

    if (direct.inserted) {
      final card = ActionCardData(
        type: 'calendar',
        badge: '📅 已寫入系統日曆',
        title: title,
        rows: [
          '時間：$display',
          '日曆：${direct.calendarName}',
          '備註：$desc',
        ],
        buttonLabel: '',
        payload: {
          'title': title,
          'startIso': startTime.toIso8601String(),
          'description': desc,
          'inserted': true,
        },
      );

      return ToolExecutionOutcome(
        toolResponse: {
          'inserted': true,
          'calendar': direct.calendarName,
          'title': title,
          'start': display,
        },
        toolPill: '📅 已直接寫入日曆：$display',
        card: card,
        directReply: '好，$display 的「$title」已經直接幫你寫進日曆了。',
      );
    }

    final card = ActionCardData(
      type: 'calendar',
      badge: '📅 系統日曆草稿',
      title: title,
      rows: [
        '時間：$display',
        '備註：$desc',
      ],
      buttonLabel: '📅 寫入系統日曆',
      payload: {
        'title': title,
        'startIso': startTime.toIso8601String(),
        'description': desc,
      },
    );

    return ToolExecutionOutcome(
      toolResponse: {'draft_ready': true, 'title': title, 'start': display},
      toolPill: '📅 create_calendar_event：已組裝日曆草稿',
      card: card,
      directReply: '日曆卡片排好了，確認沒錯點一下直接寫進系統日曆：',
    );
  }

  /// Resolves an ISO timestamp from the LLM while guarding against stale model-cutoff years (e.g. 2025).
  static DateTime _resolveToolDateTime(String rawIso, String fallbackText) {
    final parsed = DateTime.tryParse(rawIso.trim())?.toLocal();
    final loose = parseLooseDateTime(fallbackText);
    if (parsed == null) return loose;

    final now = DateTime.now();
    // If model hallucinated a stale past date (> 7 days ago, e.g. training cutoff 2025),
    // keep the model's hour/minute if meaningful, and anchor the date to today/loose fallback.
    if (parsed.isBefore(now.subtract(const Duration(days: 7)))) {
      return DateTime(
        loose.year,
        loose.month,
        loose.day,
        parsed.hour,
        parsed.minute,
      );
    }
    return parsed;
  }

  /// Parses simple Chinese time hints ("1分鐘後", "測試 2分鐘", "明天 8點", "08:30") cleanly.
  static DateTime parseLooseDateTime(String text) {
    final now = DateTime.now();

    // 1. Relative time hints ("1分鐘後", "五分鐘之後", "測試 2分鐘", "2小時後", "半小時後", "30秒後")
    if (text.contains('半小時')) {
      return now.add(const Duration(minutes: 30));
    }
    final hasClockTime = RegExp(r'(\d{1,2})\s*[點時:]').hasMatch(text);
    final secMatch = RegExp(r'(\d+|[一二兩三四五六七八九十]+)\s*秒(?:鐘)?(?:\s*(?:之後|以後|之內|後))?').firstMatch(text);
    if (secMatch != null && !hasClockTime) {
      final secs = _parseZhOrInt(secMatch.group(1)!);
      if (secs > 0) return now.add(Duration(seconds: secs));
    }
    final minMatch = RegExp(r'(\d+|[一二兩三四五六七八九十]+)\s*分(?:鐘)?(?:\s*(?:之後|以後|之內|後))?').firstMatch(text);
    if (minMatch != null && !hasClockTime) {
      final mins = _parseZhOrInt(minMatch.group(1)!);
      if (mins > 0) return now.add(Duration(minutes: mins));
    }
    final hourMatch = RegExp(r'(\d+|[一二兩三四五六七八九十]+)\s*小?時(?:\s*(?:之後|以後|之內|後))?').firstMatch(text);
    if (hourMatch != null && !hasClockTime) {
      final hrs = _parseZhOrInt(hourMatch.group(1)!);
      if (hrs > 0) return now.add(Duration(hours: hrs));
    }

    var dayOffset = 0;
    if (text.contains('明天') || text.contains('明日')) {
      dayOffset = 1;
    } else if (text.contains('後天')) {
      dayOffset = 2;
    }

    var hour = 8;
    var minute = 0;
    final colonMatch = RegExp(r'(\d{1,2}):(\d{2})').firstMatch(text);
    final zhMatch = RegExp(r'(\d{1,2})\s*[點時](?:\s*(\d{1,2})\s*分?)?').firstMatch(text);
    if (colonMatch != null) {
      hour = int.tryParse(colonMatch.group(1)!) ?? 8;
      minute = int.tryParse(colonMatch.group(2)!) ?? 0;
    } else if (zhMatch != null) {
      hour = int.tryParse(zhMatch.group(1)!) ?? 8;
      if (text.contains('下午') || text.contains('晚上')) {
        if (hour < 12) hour += 12;
      }
      minute = int.tryParse(zhMatch.group(2) ?? '0') ?? 0;
    } else if (dayOffset == 0) {
      return now.add(const Duration(minutes: 10));
    }

    final target = DateTime(now.year, now.month, now.day + dayOffset, hour.clamp(0, 23), minute.clamp(0, 59));
    return target.isBefore(now) ? target.add(const Duration(days: 1)) : target;
  }

  static int _parseZhOrInt(String raw) {
    final direct = int.tryParse(raw);
    if (direct != null) return direct;
    const map = {
      '一': 1,
      '二': 2,
      '兩': 2,
      '三': 3,
      '四': 4,
      '五': 5,
      '六': 6,
      '七': 7,
      '八': 8,
      '九': 9,
      '十': 10,
    };
    return map[raw] ?? 0;
  }

  static String _extractCleanEventTitle(String raw, String defaultTitle) {
    var s = raw
        .replaceAll(RegExp(r'(\d+|[一二兩三四五六七八九十]+)\s*分(?:鐘)?(?:\s*(?:之後|以後|之內|後))?'), '')
        .replaceAll(RegExp(r'(\d+|[一二兩三四五六七八九十]+)\s*秒(?:鐘)?(?:\s*(?:之後|以後|之內|後))?'), '')
        .replaceAll(RegExp(r'(\d+|[一二兩三四五六七八九十]+)\s*小?時(?:\s*(?:之後|以後|之內|後))?'), '')
        .replaceAll(RegExp(r'半小時(?:之後|以後|後)?'), '')
        .replaceAll(RegExp(r'\d{1,2}:\d{2}'), '')
        .replaceAll(RegExp(r'\d{1,2}\s*[點時](?:\s*\d{1,2}\s*分?)?'), '')
        .replaceAll(RegExp(r'今天|今日|明天|明日|後天|早上|上午|中午|下午|晚上|提醒我|叫我'), '')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
    if (s.isEmpty) s = raw.trim();
    return s.isEmpty ? defaultTitle : s;
  }
}
