import 'package:flutter/services.dart';
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
    this.mainOnly = false,
  });

  final String atLabel;
  final String toolName;
  final String subtitle;
  final String colorHex;
  final bool mainOnly;
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
    AtToolOption(
      atLabel: '@搜記憶',
      toolName: 'search_memory',
      subtitle: '主房專屬 • 跨房搜待辦／對話',
      colorHex: '#34D399',
      mainOnly: true,
    ),
    AtToolOption(
      atLabel: '@剪貼簿',
      toolName: 'clipboard_tool',
      subtitle: '剪貼簿匯入待辦／匯出本房',
      colorHex: '#60A5FA',
    ),
  ];

  static List<AtToolOption> optionsForRoom(String roomId) {
    return atOptions.where((o) => !o.mainOnly || roomId == 'main').toList();
  }

  /// Normalizes voice transcriptions (strips wake word & maps spoken commands to @ tools).
  static String normalizeSpokenCommand(String raw) {
    var s = raw.trim();
    if (s.isEmpty) return s;
    s = s.replaceFirst(
      RegExp(r'^(?:可達|KODARI|kodari|嘿可達|哈囉可達|可達呀|可達啊)[\s,，:：、]+'),
      '',
    ).trim();

    const voiceMap = <String, String>{
      '設定鬧鐘': '@設鬧鐘',
      '設鬧鐘': '@設鬧鐘',
      '設提醒': '@設鬧鐘',
      '提醒我': '@設鬧鐘',
      '排日曆': '@排日曆',
      '加日曆': '@排日曆',
      '新增日曆': '@排日曆',
      '搜記憶': '@搜記憶',
      '找記憶': '@搜記憶',
      '搜尋記憶': '@搜記憶',
      '查記憶': '@搜記憶',
      '查鋁料': '@查鋁料',
      '查調機': '@查調機',
      '記待辦': '@記待辦',
      '寫待辦': '@記待辦',
      '新增待辦': '@記待辦',
      '剪貼簿': '@剪貼簿',
    };
    for (final e in voiceMap.entries) {
      if (s.startsWith(e.key)) {
        final rest = s.substring(e.key.length).replaceFirst(RegExp(r'^[\s,，:：]+'), '');
        return rest.isEmpty ? e.value : '${e.value} $rest';
      }
    }
    return s;
  }

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
      '@搜記憶': 5,
      '@查記憶': 5,
      '@剪貼簿': 6,
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
      case 'search_memory':
        return const Tool(
          name: 'search_memory',
          description: '跨全部工作房間搜尋待辦清單與歷史對話紀錄。',
          parameters: {
            'type': 'object',
            'properties': {
              'query': {'type': 'string', 'description': '搜尋關鍵字，例如 343mm 或 案場名稱'},
            },
            'required': ['query'],
          },
        );
      case 'clipboard_tool':
        return const Tool(
          name: 'clipboard_tool',
          description: '讀取手機剪貼簿匯入待辦，或將本房待辦清單匯出複製。',
          parameters: {
            'type': 'object',
            'properties': {
              'mode': {'type': 'string', 'description': 'import 或 export'},
            },
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
    bool requireConfirm = false,
  }) async {
    switch (toolName) {
      case 'lookup_profile':
        return _runLookupProfile(args);
      case 'lookup_machine_tuning':
        return _runLookupTuning(args);
      case 'data_write':
        return _runDataWrite(args, roomId);
      case 'schedule_notification':
        return _runScheduleNotification(args, requireConfirm: requireConfirm);
      case 'create_calendar_event':
        return _runCreateCalendar(args, requireConfirm: requireConfirm);
      case 'search_memory':
        return _runSearchMemory(args);
      case 'clipboard_tool':
        return _runClipboardTool(args, roomId);
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
      case 'search_memory':
        return _runSearchMemory({'query': clean});
      case 'clipboard_tool':
        return _runClipboardTool({'query': clean}, roomId);
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

  Future<ToolExecutionOutcome> _runScheduleNotification(
    Map<String, dynamic> args, {
    bool requireConfirm = false,
  }) async {
    final title = (args['title'] ?? 'KODARI 現場提醒').toString();
    final body = (args['body'] ?? title).toString();
    final rawTime = (args['trigger_iso'] ?? '').toString();
    final triggerTime = _resolveToolDateTime(rawTime, '$title $body');
    final h = triggerTime.hour.toString().padLeft(2, '0');
    final m = triggerTime.minute.toString().padLeft(2, '0');
    final displayTime =
        '${triggerTime.year}/${triggerTime.month}/${triggerTime.day} $h:$m';

    if (requireConfirm) {
      final card = ActionCardData(
        type: 'confirm_notification',
        badge: '⏰ 請確認是否設定提醒',
        title: title,
        rows: [
          '預計時間：$displayTime',
          if (body != title && body.isNotEmpty) '備註：$body',
        ],
        buttonLabel: '✅ 確認設定提醒（$displayTime）',
        payload: {
          'title': title,
          'body': body,
          'triggerIso': triggerTime.toIso8601String(),
          'displayTime': displayTime,
          'hour': triggerTime.hour,
          'minute': triggerTime.minute,
        },
      );
      return ToolExecutionOutcome(
        toolResponse: {
          'status': 'pending_confirmation',
          'title': title,
          'time': displayTime,
        },
        toolPill: '⏰ 待你確認提醒：$displayTime',
        card: card,
      );
    }

    final res = await NativeActions.scheduleReminder(
      title: title,
      body: body,
      triggerTime: triggerTime,
    );

    final combined = '$title $body';
    final alsoRealAlarm = combined.contains('真鬧鐘') || combined.contains('系統鬧鐘');
    if (alsoRealAlarm) {
      await NativeActions.setSystemAlarmClock(
        hour: triggerTime.hour,
        minute: triggerTime.minute,
        message: title,
        skipUi: true,
      );
    }

    final card = ActionCardData(
      type: 'notification',
      badge: alsoRealAlarm ? '⏰ 通知 ＋ 系統真鬧鐘已排程' : '⏰ 本地提醒已排程',
      title: title,
      rows: [
        '提醒時間：${res.displayTime}',
        if (body != title) '備註：$body',
      ],
      buttonLabel: '⏰ 寫入系統「時鐘」真鬧鐘',
      payload: {
        'time': res.displayTime,
        'hour': triggerTime.hour,
        'minute': triggerTime.minute,
        'title': title,
      },
    );

    return ToolExecutionOutcome(
      toolResponse: {'scheduled': res.scheduled, 'time': res.displayTime},
      toolPill: alsoRealAlarm
          ? '⏰ 已設通知 ＋ 真鬧鐘：${res.displayTime}'
          : '⏰ 已設定提醒：${res.displayTime}',
      card: card,
      directReply: alsoRealAlarm
          ? '好，${res.displayTime} 的系統通知跟「時鐘」真鬧鐘都幫你設定好了。'
          : '好，${res.displayTime} 的提醒幫你釘好了（需要響到按掉可點卡片寫進系統鬧鐘）。',
    );
  }

  Future<ToolExecutionOutcome> _runSearchMemory(Map<String, dynamic> args) async {
    final query = (args['query'] ?? '').toString().trim();
    final hits = await _db.searchGlobalMemory(query);
    if (hits.isEmpty) {
      return ToolExecutionOutcome(
        toolResponse: {'found': 0, 'query': query},
        toolPill: '🧠 search_memory：跨房查無「$query」',
        directReply: '翻過所有工作房間的待辦和對話紀錄，沒找到「$query」相關內容。',
      );
    }

    final rows = <String>[
      for (final h in hits.take(5))
        '[${h.roomTitle} · ${h.source}] ${h.snippet.length > 55 ? '${h.snippet.substring(0, 55)}...' : h.snippet}',
    ];
    final jumpTarget = hits.firstWhere(
      (h) => h.roomId != 'main',
      orElse: () => hits.first,
    );
    final canJump = jumpTarget.roomId != 'main';

    final card = ActionCardData(
      type: 'memory_hit',
      badge: '🧠 跨房間記憶搜尋（共 ${hits.length} 筆）',
      title: query.isEmpty ? '各房間待辦記憶總覽' : '關鍵字：$query',
      rows: rows,
      buttonLabel: canJump ? '🚪 跳轉至「${jumpTarget.roomTitle}」' : '📋 複製搜尋結果',
      payload: {
        'targetRoomId': jumpTarget.roomId,
        'roomTitle': jumpTarget.roomTitle,
        'copyText': rows.join('\n'),
      },
    );

    return ToolExecutionOutcome(
      toolResponse: {'found': hits.length, 'top_room': jumpTarget.roomTitle},
      toolPill: '🧠 search_memory：找到 ${hits.length} 筆記憶',
      card: card,
      directReply: '跨房間幫你翻到 ${hits.length} 筆相關紀錄，最新一筆在「${hits.first.roomTitle}」：',
    );
  }

  Future<ToolExecutionOutcome> _runClipboardTool(
    Map<String, dynamic> args,
    String roomId,
  ) async {
    final query = (args['query'] ?? args['mode'] ?? '').toString().trim();
    final isExport = query.contains('匯出') ||
        query.contains('複製') ||
        query.contains('分享') ||
        query.toLowerCase() == 'export';

    if (isExport) {
      final room = await _db.getRoom(roomId);
      final todos = await _db.getRoomTodos(roomId);
      final lines = todos.isEmpty
          ? '（目前尚無待辦項目）'
          : todos.map((t) => '${t.done ? '[x]' : '[ ]'} ${t.text}').join('\n');
      final exportText = '【${room?.title ?? roomId}】\n$lines';
      await Clipboard.setData(ClipboardData(text: exportText));

      final card = ActionCardData(
        type: 'clipboard',
        badge: '📋 已複製本房清單到剪貼簿',
        title: room?.title ?? roomId,
        rows: [
          '共 ${todos.length} 條待辦已寫入剪貼簿，可直接去 LINE 貼上！',
        ],
        buttonLabel: '📋 再複製一次',
        payload: {'copyText': exportText},
      );
      return ToolExecutionOutcome(
        toolResponse: {'mode': 'export', 'count': todos.length},
        toolPill: '📋 clipboard：已匯出 ${todos.length} 條至剪貼簿',
        card: card,
        directReply: '已經把「${room?.title ?? roomId}」的 ${todos.length} 條清單複製到剪貼簿，直接切去 LINE 貼上就行。',
      );
    }

    final clip = await Clipboard.getData(Clipboard.kTextPlain);
    final rawClip = (clip?.text ?? '').trim();
    if (rawClip.isEmpty) {
      return const ToolExecutionOutcome(
        toolResponse: {'mode': 'import', 'empty': true},
        toolPill: '📋 clipboard：剪貼簿目前為空',
        directReply: '剪貼簿裡面目前沒有文字喔，先複製一段訊息再試（要匯出清單請打「@剪貼簿 匯出」）。',
      );
    }

    final lines = rawClip
        .split('\n')
        .map((l) => l.trim())
        .where((l) => l.isNotEmpty)
        .take(5)
        .toList();
    for (final line in lines) {
      final short = line.length > 80 ? '${line.substring(0, 80)}...' : line;
      await _db.upsertTodoItem(roomId: roomId, itemText: short);
    }

    final card = ActionCardData(
      type: 'clipboard',
      badge: '📥 已從剪貼簿匯入待辦',
      title: '匯入 ${lines.length} 條至本房清單',
      rows: lines,
      buttonLabel: '📋 複製原文內容',
      payload: {'copyText': rawClip},
    );

    return ToolExecutionOutcome(
      toolResponse: {'mode': 'import', 'imported': lines.length},
      toolPill: '📥 clipboard：已匯入 ${lines.length} 條待辦',
      card: card,
      directReply: '幫你把剪貼簿內容匯入這間房的待辦清單了（共 ${lines.length} 條）：',
    );
  }

  Future<ToolExecutionOutcome> _runCreateCalendar(
    Map<String, dynamic> args, {
    bool requireConfirm = false,
  }) async {
    final title = (args['title'] ?? '工作排程事件').toString();
    final desc = (args['description'] ?? '由《HAKO • KODARI》建立').toString();
    final rawStart = (args['start_iso'] ?? '').toString();
    final startTime = _resolveToolDateTime(rawStart, '$title $desc');
    final h = startTime.hour.toString().padLeft(2, '0');
    final m = startTime.minute.toString().padLeft(2, '0');
    final display = '${startTime.year}/${startTime.month}/${startTime.day} $h:$m';

    if (requireConfirm) {
      final card = ActionCardData(
        type: 'confirm_calendar',
        badge: '📅 請確認是否寫入日曆',
        title: title,
        rows: [
          '預計時間：$display',
          if (desc.isNotEmpty) '備註：$desc',
        ],
        buttonLabel: '✅ 確認寫入系統日曆（$display）',
        payload: {
          'title': title,
          'startIso': startTime.toIso8601String(),
          'description': desc,
          'displayTime': display,
        },
      );
      return ToolExecutionOutcome(
        toolResponse: {
          'status': 'pending_confirmation',
          'title': title,
          'start': display,
        },
        toolPill: '📅 待你確認寫入日曆：$display',
        card: card,
      );
    }

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
  static DateTime parseLooseDateTime(String rawText) {
    final text = rawText.replaceAll('：', ':');
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
    final colonMatch = RegExp(r'(\d{1,2})\s*:\s*(\d{2})').firstMatch(text);
    final zhMatch = RegExp(r'(\d{1,2})\s*[點時](?:\s*(\d{1,2})\s*分?)?').firstMatch(text);
    final militaryMatch = RegExp(r'(?<!\d)([01]\d|2[0-3])([0-5]\d)(?!\d|\s*(?:mm|MM|kg|KG|支|隻|片|條))').firstMatch(text);
    if (colonMatch != null) {
      hour = int.tryParse(colonMatch.group(1)!) ?? 8;
      minute = int.tryParse(colonMatch.group(2)!) ?? 0;
    } else if (zhMatch != null) {
      hour = int.tryParse(zhMatch.group(1)!) ?? 8;
      if (text.contains('下午') || text.contains('晚上')) {
        if (hour < 12) hour += 12;
      }
      minute = int.tryParse(zhMatch.group(2) ?? '0') ?? 0;
    } else if (militaryMatch != null) {
      hour = int.tryParse(militaryMatch.group(1)!) ?? 8;
      minute = int.tryParse(militaryMatch.group(2)!) ?? 0;
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
        .replaceAll(RegExp(r'(?<!\d)([01]\d|2[0-3])([0-5]\d)(?!\d|\s*(?:mm|MM|kg|KG|支|隻|片|條))'), '')
        .replaceAll(RegExp(r'今天|今日|明天|明日|後天|早上|上午|中午|下午|晚上|提醒我|叫我'), '')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
    if (s.isEmpty) s = raw.trim();
    return s.isEmpty ? defaultTitle : s;
  }
}
