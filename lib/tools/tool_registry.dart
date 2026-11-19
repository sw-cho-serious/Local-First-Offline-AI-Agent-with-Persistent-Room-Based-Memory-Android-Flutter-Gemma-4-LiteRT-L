import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_edge_ai/flutter_edge_ai.dart';

import '../data/database_helper.dart';
import '../data/models.dart';
import 'native_actions.dart';
import 'routine_scheduler.dart';
import 'web_search_service.dart';

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

  /// Default estimation parameters for [_runLookupProfile]; adjust to your own shop rules.
  static const double defaultLossFactor = 1.09;
  static const double defaultKerfMm = 3.5;
  static const double defaultBulkThresholdKg = 300.0;

  static const List<AtToolOption> atOptions = [
    AtToolOption(
      atLabel: '@查材料',
      toolName: 'lookup_profile',
      subtitle: '材料規格/單重/自訂料表',
      colorHex: '#F59E0B',
    ),
    AtToolOption(
      atLabel: '@查公式',
      toolName: 'lookup_machine_tuning',
      subtitle: '加工參數/自訂公式',
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
    AtToolOption(
      atLabel: '@量測標註',
      toolName: 'photo_annotate',
      subtitle: '照片畫線寫尺寸 • 合成存入本房',
      colorHex: '#F472B6',
    ),
    AtToolOption(
      atLabel: '@掃相簿',
      toolName: 'album_scan',
      subtitle: '快篩今日/近期相簿歸檔案場',
      colorHex: '#22D3EE',
    ),
    AtToolOption(
      atLabel: '@報位置',
      toolName: 'location_tool',
      subtitle: '離線衛星 GPS 座標打卡記錄',
      colorHex: '#34D399',
    ),
    AtToolOption(
      atLabel: '@轉LINE',
      toolName: 'share_line',
      subtitle: '打包本房進度 ＋ 現場照傳到 LINE',
      colorHex: '#4ADE80',
    ),
    AtToolOption(
      atLabel: '@技能',
      toolName: 'load_skill',
      subtitle: '按需載入／管理 SKILL.md 知識包',
      colorHex: '#C084FC',
    ),
    AtToolOption(
      atLabel: '@動作',
      toolName: 'device_action',
      subtitle: '手電筒 / 撥號 / 導航 / 倒數 / 設定',
      colorHex: '#FB923C',
    ),
    AtToolOption(
      atLabel: '@知識',
      toolName: 'load_skill',
      subtitle: '按需載入／管理 Skill 知識包',
      colorHex: '#F472B6',
    ),
    AtToolOption(
      atLabel: '@查網',
      toolName: 'web_search',
      subtitle: '免Key聯網搜尋 • 附來源驗證連結',
      colorHex: '#38BDF8',
    ),
    AtToolOption(
      atLabel: '@找支援',
      toolName: 'consult_peer',
      subtitle: 'HTTP直連呼叫雲端參謀 Spark',
      colorHex: '#A78BFA',
    ),
    AtToolOption(
      atLabel: '@排程',
      toolName: 'routine_tool',
      subtitle: '零算力日常/Cron排程 • 預覽未來3次',
      colorHex: '#F59E0B',
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
      '查材料': '@查材料',
      '查公式': '@查公式',
      '查鋁料': '@查材料',
      '查調機': '@查公式',
      '記待辦': '@記待辦',
      '寫待辦': '@記待辦',
      '新增待辦': '@記待辦',
      '剪貼簿': '@剪貼簿',
      '量測標註': '@量測標註',
      '照片標註': '@量測標註',
      '標註尺寸': '@量測標註',
      '量尺寸': '@量測標註',
      '掃相簿': '@掃相簿',
      '掃描相簿': '@掃相簿',
      '整理相簿': '@掃相簿',
      '報位置': '@報位置',
      '報地址': '@報位置',
      '記位置': '@報位置',
      '記座標': '@報位置',
      '抓座標': '@報位置',
      '轉LINE': '@轉LINE',
      '傳LINE': '@轉LINE',
      '轉line': '@轉LINE',
      '傳line': '@轉LINE',
      '分享到LINE': '@轉LINE',
      '跑技能': '@技能',
      '用技能': '@技能',
      '查技能': '@技能',
      '註冊技能': '@技能 註冊',
      '開手電筒': '@開燈',
      '關手電筒': '@關燈',
      '手電筒': '@手電筒',
      '開燈': '@開燈',
      '關燈': '@關燈',
      '打電話': '@撥號',
      '撥號': '@撥號',
      '導航去': '@導航',
      '導航': '@導航',
      '設倒數': '@倒數',
      '倒數計時': '@倒數',
      '計時器': '@倒數',
      '系統設定': '@系統設定',
      '查知識': '@知識',
      '開知識': '@知識',
      '載入技能': '@知識',
      '查網': '@查網',
      '聯網查': '@查網',
      '上網查': '@查網',
      '搜尋網路': '@查網',
      '找支援': '@找支援',
      '問參謀': '@找支援',
      '呼叫參謀': '@找支援',
      '叫支援': '@找支援',
      '日常排程': '@排程',
      '定時排程': '@排程',
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
      '@查材料': 0,
      '@查公式': 1,
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
      '@量測標註': 7,
      '@量尺寸': 7,
      '@標註': 7,
      '@掃相簿': 8,
      '@相簿': 8,
      '@報位置': 9,
      '@報地址': 9,
      '@記座標': 9,
      '@轉LINE': 10,
      '@轉line': 10,
      '@傳LINE': 10,
      '@傳line': 10,
      '@分享': 10,
      '@技能': 11,
      '@Skill': 11,
      '@skill': 11,
      '@動作': 12,
      '@手電筒': 12,
      '@開燈': 12,
      '@關燈': 12,
      '@撥號': 12,
      '@導航': 12,
      '@倒數': 12,
      '@計時': 12,
      '@系統設定': 12,
      '@知識': 13,
      '@查網': 14,
      '@聯網': 14,
      '@搜尋': 14,
      '@上網': 14,
      '@找支援': 15,
      '@問參謀': 15,
      '@參謀': 15,
      '@同伴': 15,
      '@排程': 16,
      '@定時': 16,
      '@cron': 16,
    };

    const actionAliasPrefixes = <String, String>{
      '@手電筒': 'flashlight',
      '@開燈': 'flashlight on',
      '@關燈': 'flashlight off',
      '@撥號': 'dial',
      '@導航': 'map',
      '@倒數': 'timer',
      '@計時': 'timer',
      '@系統設定': 'settings',
    };

    for (final entry in aliases.entries) {
      final tag = entry.key;
      if (trimmed.startsWith(tag)) {
        final afterTag = trimmed.substring(tag.length);
        if (afterTag.isEmpty || RegExp(r'^[\s:：,，]').hasMatch(afterTag)) {
          final clean = afterTag.replaceFirst(RegExp(r'^[\s:：,，]+'), '').trim();
          final prefix = actionAliasPrefixes[tag];
          final effectiveClean = prefix == null
              ? clean
              : (clean.isEmpty ? (prefix == 'flashlight' ? 'flashlight on' : prefix) : '$prefix $clean');
          return (option: atOptions[entry.value], cleanText: effectiveClean);
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
      case 'photo_annotate':
        return const Tool(
          name: 'photo_annotate',
          description: '開啟現場照片尺寸標註畫布，於圖片畫線填寫毫米尺寸並存入工作房間。',
          parameters: {
            'type': 'object',
            'properties': {
              'note': {'type': 'string', 'description': '備註說明'},
            },
          },
        );
      case 'album_scan':
        return const Tool(
          name: 'album_scan',
          description: '掃描手機近期拍攝照片並挑選歸檔到指定工作房間。',
          parameters: {
            'type': 'object',
            'properties': {
              'range': {'type': 'string', 'description': 'today 或 recent'},
            },
          },
        );
      case 'location_tool':
        return const Tool(
          name: 'location_tool',
          description: '離線抓取手機 GPS 衛星經緯度存成標點與 Google Maps 連結。',
          parameters: {
            'type': 'object',
            'properties': {
              'label': {'type': 'string', 'description': '標點名稱或備註'},
            },
          },
        );
      case 'share_line':
        return const Tool(
          name: 'share_line',
          description: '整理當前工作房間待辦進度與最新現場照，喚起分享面板傳到 LINE。',
          parameters: {
            'type': 'object',
            'properties': {
              'extra_note': {'type': 'string', 'description': '附帶傳給對方的補充文字'},
            },
          },
        );
      case 'device_action':
        return const Tool(
          name: 'device_action',
          description: '呼叫 Android 原生硬體與系統 Intent：手電筒、填號撥號、震動、系統時鐘倒數/鬧鐘、Google Maps 導航、系統設定頁。',
          parameters: {
            'type': 'object',
            'properties': {
              'action': {
                'type': 'string',
                'enum': [
                  'setFlashlight',
                  'dialPhone',
                  'vibrate',
                  'setTimerOrAlarm',
                  'openMap',
                  'openSettings',
                ],
                'description': '原生動作名稱',
              },
              'value': {
                'type': 'string',
                'description': '參數內容（手電筒: on/off；撥號: 電話號碼；倒數/鬧鐘: 例如 15分鐘 或 07:30；地圖: 地址/座標；設定: wifi/bluetooth/hotspot/location）',
              },
              'message': {
                'type': 'string',
                'description': '選填：倒數計時或鬧鐘提示標題',
              },
            },
            'required': ['action'],
          },
        );
      case 'load_skill':
        return const Tool(
          name: 'load_skill',
          description: '按需從本地 SQLite 知識庫翻查指定 Skill 的詳細流程與規則（保護 Context 不預載全文）。',
          parameters: {
            'type': 'object',
            'properties': {
              'name': {'type': 'string', 'description': 'Skill 名稱或關鍵字，填 list 可查看所有可用 Skill'},
            },
            'required': ['name'],
          },
        );
      case 'web_search':
        return const Tool(
          name: 'web_search',
          description: '免 API Key 聯網查詢即時規格、材料價格、廠商營業資訊或現場查證。失敗時自動 Fallback 呼叫雲端同伴。',
          parameters: {
            'type': 'object',
            'properties': {
              'query': {'type': 'string', 'description': '要聯網搜尋的關鍵字或問題'},
            },
            'required': ['query'],
          },
        );
      case 'consult_peer':
        return const Tool(
          name: 'consult_peer',
          description: '當本地 4B 模型無法處理複雜計算、超長上下文或需雲端參謀 Spark 支援時，透過 HTTP 直連呼叫雲端／本地同伴。',
          parameters: {
            'type': 'object',
            'properties': {
              'query': {'type': 'string', 'description': '請同伴協助解決的具體問題'},
              'context': {'type': 'string', 'description': '選填：當前案場背景或數據'},
            },
            'required': ['query'],
          },
        );
      case 'routine_tool':
        return const Tool(
          name: 'routine_tool',
          description: '管理不喚醒 4B 模型的零算力本地日常排程（每日、每週、Cron、未來 3 次預覽）。',
          parameters: {
            'type': 'object',
            'properties': {
              'query': {'type': 'string', 'description': '例如：每天 07:30 追金代交期 或 list 查看現有排程'},
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
      case 'photo_annotate':
        return _runPhotoAnnotatePrompt(args);
      case 'album_scan':
        return _runAlbumScanPrompt(args);
      case 'location_tool':
        return _runLocationTool(args, roomId);
      case 'share_line':
        return _runShareLineTool(args, roomId);
      case 'device_action':
        return _runDeviceAction(args);
      case 'load_skill':
        return _runLoadSkill(args);
      case 'web_search':
        return _runWebSearch(args, roomId);
      case 'consult_peer':
        return _runConsultPeer(args, roomId);
      case 'routine_tool':
        return _runRoutineTool(args);
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
      case 'photo_annotate':
        return _runPhotoAnnotatePrompt({'note': clean});
      case 'album_scan':
        return _runAlbumScanPrompt({'range': clean});
      case 'location_tool':
        return _runLocationTool({'label': clean}, roomId);
      case 'share_line':
        return _runShareLineTool({'extra_note': clean}, roomId);
      case 'device_action':
        return _runDeviceAction({'query': clean});
      case 'load_skill':
        return _runLoadSkill({'name': clean});
      case 'web_search':
        return _runWebSearch({'query': clean}, roomId);
      case 'consult_peer':
        return _runConsultPeer({'query': clean}, roomId);
      case 'routine_tool':
        return _runRoutineTool({'query': clean});
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
        directReply: 'SQLite 料表裡找不到「$code」，我不亂猜，請再確認一下料號。',
      );
    }

    final first = hits.first;
    final lengthMm = (args['length_mm'] as num?)?.toDouble();
    final qty = (args['qty'] as num?)?.toInt();

    final rows = <String>[
      '單米重：${first.weightPerM.toStringAsFixed(2)} kg/m',
      '定尺規則：${first.stockRule}（鋸路 ${defaultKerfMm}mm）',
      '特殊排抽：${first.extrudable ? '可排抽料型（累計 >=${defaultBulkThresholdKg.toStringAsFixed(0)}kg 走排抽）' : '固定走一般定尺開料'}',
    ];

    if (lengthMm != null && qty != null && lengthMm > 0 && qty > 0) {
      final totalKg = (lengthMm / 1000.0) * qty * first.weightPerM;
      final prepKg = totalKg * defaultLossFactor;
      rows.add(
        '試算重量：$qty 支 × ${lengthMm.toStringAsFixed(0)}mm = ${totalKg.toStringAsFixed(2)} kg（$defaultLossFactor 備料 ${prepKg.toStringAsFixed(2)} kg）',
      );
      if (first.extrudable && totalKg >= defaultBulkThresholdKg) {
        rows.add('🔴 達 ${defaultBulkThresholdKg.toStringAsFixed(0)}kg 大量門檻，建議訂製特殊定尺！');
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
        directReply: '「$query」在已驗證公式庫裡查無參數，不亂編，實測完再補進來。',
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
      badge: '🔧 已驗證加工／公式參數',
      title: first.title,
      rows: rows,
      buttonLabel: '📋 複製公式',
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

  Future<ToolExecutionOutcome> _runPhotoAnnotatePrompt(Map<String, dynamic> args) async {
    final note = (args['note'] ?? '').toString().trim();
    final card = ActionCardData(
      type: 'photo_annotate',
      badge: '📏 工地量測尺寸標註畫布',
      title: note.isEmpty ? '拍照／選圖畫尺寸標註' : note,
      rows: const [
        '開啟相片畫線填寫毫米數字，合成高對比標註照直接存入本工作房。',
      ],
      buttonLabel: '📏 挑選／拍攝照片開始標註',
      payload: {'note': note},
    );
    return ToolExecutionOutcome(
      toolResponse: {'ready': true, 'note': note},
      toolPill: '📏 photo_annotate：量測畫布就緒',
      card: card,
      directReply: '點下面按鈕挑一張工地照或現場拍一張，用手指畫線就能寫尺寸存檔：',
    );
  }

  Future<ToolExecutionOutcome> _runAlbumScanPrompt(Map<String, dynamic> args) async {
    final card = ActionCardData(
      type: 'album_scan',
      badge: '🖼️ 手機相簿快篩歸檔',
      title: '掃描今日／近期拍攝照片',
      rows: const [
        '自動讀取縮圖並支援多選批次壓縮，快速歸檔到指定案場工作房間。',
      ],
      buttonLabel: '🖼️ 開啟相簿快篩歸檔面板',
      payload: {'range': (args['range'] ?? '').toString()},
    );
    return ToolExecutionOutcome(
      toolResponse: {'ready': true},
      toolPill: '🖼️ album_scan：相簿快篩就緒',
      card: card,
      directReply: '點開下面相簿掃描面板，直接勾選今天拍的照片就能批次收進案場房間：',
    );
  }

  Future<ToolExecutionOutcome> _runLocationTool(
    Map<String, dynamic> args,
    String roomId,
  ) async {
    final label = (args['label'] ?? '').toString().trim();
    final loc = await NativeActions.getCurrentLocation();
    if (!loc.ok || loc.lat == null || loc.lng == null) {
      return ToolExecutionOutcome(
        toolResponse: {'ok': false, 'reason': loc.reason ?? '定位失敗'},
        toolPill: '⚠️ location：${loc.reason ?? '定位失敗'}',
        directReply: '目前抓不到 GPS 座標（${loc.reason ?? '請檢查定位權限與開關'}）。',
      );
    }

    final room = await _db.getRoom(roomId);
    final tag = label.isNotEmpty ? label : (room?.title ?? '現場標點');
    final now = DateTime.now();
    final hhmm = '${now.month}/${now.day} ${now.hour.toString().padLeft(2, '0')}:${now.minute.toString().padLeft(2, '0')}';
    final accText = loc.accuracy != null ? '±${loc.accuracy!.round()}m' : '';
    final todoText = '📍 [$tag] ${loc.coordsText} ($hhmm ${loc.provider ?? 'gps'} $accText) ${loc.googleMapsUrl}';
    await _db.upsertTodoItem(roomId: roomId, itemText: todoText);

    final copyText = '📍 $tag\n座標：${loc.coordsText}\n地圖：${loc.googleMapsUrl}';
    final card = ActionCardData(
      type: 'location',
      badge: loc.stale ? '🛰️ 最近一次衛星座標（離線存檔）' : '🛰️ 即時 GPS 標點（已存入本房）',
      title: '$tag • ${loc.coordsText}',
      rows: [
        '精準度：${loc.accuracy != null ? '±${loc.accuracy!.round()} 公尺' : '未知'} (${loc.provider ?? 'gps'})',
        if (loc.altitude != null && loc.altitude != 0) '海拔：${loc.altitude!.toStringAsFixed(1)} m',
        '連結：${loc.googleMapsUrl}',
      ],
      buttonLabel: '🗺️ 開啟 Google Maps 導航',
      payload: {
        'lat': loc.lat,
        'lng': loc.lng,
        'label': tag,
        'copyText': copyText,
      },
    );

    return ToolExecutionOutcome(
      toolResponse: {
        'ok': true,
        'lat': loc.lat,
        'lng': loc.lng,
        'maps_url': loc.googleMapsUrl,
      },
      toolPill: '📍 location：${loc.coordsText}',
      card: card,
      directReply: '座標「${loc.coordsText}」幫你存進「${room?.title ?? roomId}」待辦了，下次點下面就能直接導航：',
    );
  }

  Future<ToolExecutionOutcome> _runShareLineTool(
    Map<String, dynamic> args,
    String roomId,
  ) async {
    final extra = (args['extra_note'] ?? '').toString().trim();
    final room = await _db.getRoom(roomId);
    final todos = await _db.getRoomTodos(roomId);
    final msgs = await _db.getMessages(roomId);

    String? latestImagePath;
    for (var i = msgs.length - 1; i >= 0; i--) {
      final path = msgs[i].imagePath;
      if (path != null && path.isNotEmpty && File(path).existsSync()) {
        latestImagePath = path;
        break;
      }
    }

    final pct = todos.isEmpty ? 0 : (DatabaseHelper.calculateProgress(todos) * 100).round();
    final buf = StringBuffer()
      ..writeln('【${room?.title ?? roomId}】(${todos.isEmpty ? '無待辦' : '進度 $pct%'})');
    if (extra.isNotEmpty) {
      buf.writeln('💬 $extra');
    }
    if (todos.isNotEmpty) {
      for (final t in todos.take(12)) {
        buf.writeln('${t.done ? '☑' : '☐'} ${t.text}');
      }
      if (todos.length > 12) {
        buf.writeln('…另有 ${todos.length - 12} 項');
      }
    } else if (msgs.isNotEmpty) {
      final recentTexts = msgs
          .where((m) => m.role != 'divider' && m.content.trim().isNotEmpty)
          .toList();
      for (final m in recentTexts.reversed.take(3).toList().reversed) {
        final short = m.content.length > 80 ? '${m.content.substring(0, 80)}...' : m.content;
        buf.writeln('• $short');
      }
    }

    final shareText = buf.toString().trim();
    final shareRes = await NativeActions.shareToLine(
      text: shareText,
      imagePath: latestImagePath,
    );

    final card = ActionCardData(
      type: 'share_line',
      badge: shareRes.withImage ? '📤 打包進度與最新現場照' : '📤 打包工作房摘要',
      title: room?.title ?? roomId,
      rows: [
        if (shareRes.withImage) '🖼️ 已附帶本房最新標註圖／現場照',
        '📋 含 ${todos.length} 條待辦紀錄（若系統無圖可再點按鈕分享）',
      ],
      buttonLabel: '📤 再分享一次到 LINE',
      payload: {
        'text': shareText,
        'imagePath': ?latestImagePath,
        'copyText': shareText,
      },
    );

    return ToolExecutionOutcome(
      toolResponse: {
        'ok': shareRes.ok,
        'with_image': shareRes.withImage,
        'todo_count': todos.length,
      },
      toolPill: shareRes.ok
          ? (shareRes.withImage ? '📤 share_line：已帶圖喚起分享' : '📤 share_line：已喚起分享')
          : '⚠️ share_line：${shareRes.error ?? '無法分享'}',
      card: card,
      directReply: shareRes.ok
          ? (shareRes.withImage
              ? '已經把本房進度跟最新現場照打包叫出分享選單了，選 LINE 群組直接丟出去就行。'
              : '已經把「${room?.title ?? roomId}」的清單打包叫出分享選單了，選 LINE 就能貼過去。')
          : '這次分享沒跳起來（${shareRes.error ?? ''}），先幫你產出卡片，點下面重試或複製文字：',
    );
  }

  Future<ToolExecutionOutcome> _runDeviceAction(Map<String, dynamic> args) async {
    var action = (args['action'] ?? '').toString().trim();
    var value = (args['value'] ?? '').toString().trim();
    var message = (args['message'] ?? '').toString().trim();
    final rawQuery = (args['query'] ?? '').toString().trim();

    if (action.isEmpty && rawQuery.isNotEmpty) {
      final lower = rawQuery.toLowerCase();
      if (lower.startsWith('flashlight') ||
          rawQuery.contains('手電筒') ||
          rawQuery.contains('開燈') ||
          rawQuery.contains('關燈')) {
        action = 'setFlashlight';
        value = (lower.contains('off') || rawQuery.contains('關')) ? 'off' : 'on';
      } else if (lower.startsWith('dial') ||
          rawQuery.contains('撥號') ||
          rawQuery.contains('打給') ||
          RegExp(r'^0\d{7,9}$').hasMatch(rawQuery.replaceAll('-', ''))) {
        action = 'dialPhone';
        value = rawQuery
            .replaceFirst(RegExp(r'^(dial|撥號|打給|打電話給?)\s*'), '')
            .trim();
      } else if (lower.startsWith('map') ||
          rawQuery.contains('導航') ||
          rawQuery.contains('地圖')) {
        action = 'openMap';
        value = rawQuery
            .replaceFirst(RegExp(r'^(map|導航去?|地圖找?)\s*'), '')
            .trim();
      } else if (lower.startsWith('timer') ||
          rawQuery.contains('倒數') ||
          rawQuery.contains('計時') ||
          rawQuery.contains('鬧鐘')) {
        action = 'setTimerOrAlarm';
        value = rawQuery
            .replaceFirst(RegExp(r'^(timer|倒數|計時器?|設定?鬧鐘)\s*'), '')
            .trim();
      } else if (lower.startsWith('settings') ||
          rawQuery.contains('設定') ||
          lower.contains('wifi') ||
          rawQuery.contains('藍牙') ||
          rawQuery.contains('熱點')) {
        action = 'openSettings';
        value = rawQuery.replaceFirst(RegExp(r'^(settings|系統設定|設定)\s*'), '').trim();
      } else if (lower.startsWith('vibrate') || rawQuery.contains('震動')) {
        action = 'vibrate';
        value = '250';
      }
    }

    switch (action) {
      case 'setFlashlight':
        final turnOn = !value.toLowerCase().contains('off') &&
            value != '0' &&
            !value.contains('關');
        final res = await NativeActions.setFlashlight(turnOn);
        final ok = res['ok'] == true;
        return ToolExecutionOutcome(
          toolResponse: {'action': 'setFlashlight', 'on': turnOn, ...res},
          toolPill: ok
              ? (turnOn ? '🔦 手電筒已開啟' : '🔦 手電筒已關閉')
              : '⚠️ 手電筒：${res['reason'] ?? '無法切換'}',
          card: ActionCardData(
            type: 'device_action',
            badge: '🔦 原生手電筒控制',
            title: turnOn ? '切換手電筒（目前：開）' : '切換手電筒（目前：關）',
            rows: [
              ok ? '硬體閃光燈已切換為${turnOn ? '開啟' : '關閉'}。' : '原因：${res['reason'] ?? '裝置不支援'}',
            ],
            buttonLabel: turnOn ? '🔦 關閉手電筒' : '🔦 開啟手電筒',
            payload: {
              'action': 'setFlashlight',
              'params': {'on': !turnOn},
            },
          ),
          directReply: ok
              ? (turnOn ? '手電筒幫你打開了，照清楚再量！' : '手電筒關掉了。')
              : '手電筒這次沒切過去（${res['reason'] ?? '請於實機操作'}）。',
        );

      case 'dialPhone':
        final phone = value.replaceAll(RegExp(r'[^\d+*#\-]'), '').trim();
        if (phone.isEmpty) {
          return const ToolExecutionOutcome(
            toolResponse: {'ok': false, 'reason': '缺少電話號碼'},
            toolPill: '📞 dialPhone：未提供號碼',
            directReply: '要打給誰？告訴我號碼，我幫你帶進撥號畫面（不會偷打出去）。',
          );
        }
        final res = await NativeActions.dialPhone(phone);
        final ok = res['ok'] == true;
        return ToolExecutionOutcome(
          toolResponse: {'action': 'dialPhone', 'phone': phone, ...res},
          toolPill: ok ? '📞 已帶入撥號：$phone' : '⚠️ dialPhone：${res['reason'] ?? '失敗'}',
          card: ActionCardData(
            type: 'device_action',
            badge: '📞 系統撥號盤預填（安全防誤撥）',
            title: phone,
            rows: const ['已預填號碼並跳轉系統撥號鍵盤，按下通話鍵即可撥出。'],
            buttonLabel: '📞 重新開啟撥號畫面',
            payload: {
              'action': 'dialPhone',
              'params': {'phone': phone},
            },
          ),
          directReply: ok
              ? '號碼「$phone」已經幫你填好打開撥號盤了，看清楚按綠色通話鍵就行。'
              : '無法開啟撥號畫面（${res['reason'] ?? ''}），號碼先留這張卡片給你：',
        );

      case 'vibrate':
        final ms = int.tryParse(value.replaceAll(RegExp(r'\D'), '')) ?? 250;
        final res = await NativeActions.vibrate(durationMs: ms);
        return ToolExecutionOutcome(
          toolResponse: {'action': 'vibrate', 'durationMs': ms, ...res},
          toolPill: res['ok'] == true ? '📳 震動觸發 (${ms}ms)' : '⚠️ vibrate：${res['reason'] ?? ''}',
          directReply: res['ok'] == true ? '震動過了 📳' : '目前無法觸發震動（${res['reason'] ?? ''}）。',
        );

      case 'setTimerOrAlarm':
        final combined = '$value $message'.trim();
        final secMatch = RegExp(r'(\d+)\s*秒').firstMatch(combined);
        final minMatch = RegExp(r'(\d+)\s*分(?:鐘)?').firstMatch(combined);
        final clockMatch = RegExp(r'(\d{1,2})\s*[:：點時]\s*(\d{1,2})?').firstMatch(combined);
        final cleanTitle = message.isNotEmpty
            ? message
            : _extractCleanEventTitle(value, 'KODARI 現場計時');

        if (clockMatch != null && minMatch == null && secMatch == null) {
          final h = (int.tryParse(clockMatch.group(1)!) ?? 8).clamp(0, 23);
          final m = (int.tryParse(clockMatch.group(2) ?? '0') ?? 0).clamp(0, 59);
          final res = await NativeActions.setTimerOrAlarm(
            mode: 'alarm',
            hour: h,
            minute: m,
            message: cleanTitle,
          );
          final hh = h.toString().padLeft(2, '0');
          final mm = m.toString().padLeft(2, '0');
          return ToolExecutionOutcome(
            toolResponse: {'action': 'setTimerOrAlarm', 'mode': 'alarm', 'hour': h, 'minute': m, ...res},
            toolPill: '⏰ 系統時鐘鬧鐘：$hh:$mm',
            card: ActionCardData(
              type: 'device_action',
              badge: '⏰ 喚起系統原生「時鐘」鬧鐘',
              title: '$hh:$mm • $cleanTitle',
              rows: const ['直接由手機原生時鐘負責響鈴，就算 App 被系統清掉也照樣準時叫你。'],
              buttonLabel: '⏰ 再開系統時鐘確認',
              payload: {
                'action': 'setTimerOrAlarm',
                'params': {'mode': 'alarm', 'hour': h, 'minute': m, 'message': cleanTitle},
              },
            ),
            directReply: '已幫你喚起系統「時鐘」設定 $hh:$mm 的鬧鐘（$cleanTitle）。',
          );
        }

        final minutes = int.tryParse(minMatch?.group(1) ?? '');
        final seconds = int.tryParse(secMatch?.group(1) ?? '');
        final bareNum = (minutes == null && seconds == null)
            ? int.tryParse(value.replaceAll(RegExp(r'\D'), ''))
            : null;
        final effMin = minutes ?? (seconds == null ? (bareNum ?? 5) : null);
        final res = await NativeActions.setTimerOrAlarm(
          mode: 'timer',
          minutes: effMin,
          seconds: seconds,
          message: cleanTitle,
        );
        final durLabel = seconds != null
            ? '$seconds秒'
            : '${effMin ?? 5}分鐘';
        return ToolExecutionOutcome(
          toolResponse: {'action': 'setTimerOrAlarm', 'mode': 'timer', 'label': durLabel, ...res},
          toolPill: '⏱️ 系統時鐘倒數：$durLabel',
          card: ActionCardData(
            type: 'device_action',
            badge: '⏱️ 原生系統倒數計時器',
            title: '倒數 $durLabel • $cleanTitle',
            rows: const ['已交給 Android 原生時鐘倒數計時。'],
            buttonLabel: '⏱️ 重新喚起倒數計時',
            payload: {
              'action': 'setTimerOrAlarm',
              'params': {
                'mode': 'timer',
                'minutes': ?effMin,
                'seconds': ?seconds,
                'message': cleanTitle,
              },
            },
          ),
          directReply: '好，幫你開好系統時鐘倒數 $durLabel（$cleanTitle）。',
        );

      case 'openMap':
        final query = value.trim();
        if (query.isEmpty) {
          return const ToolExecutionOutcome(
            toolResponse: {'ok': false, 'reason': '缺少導航目的地'},
            toolPill: '🗺️ openMap：缺少地點',
            directReply: '要去哪裡？說出路名、案場地址或座標，我馬上開 Google Maps 幫你導航。',
          );
        }
        final res = await NativeActions.openMapQuery(query);
        final ok = res['ok'] == true;
        return ToolExecutionOutcome(
          toolResponse: {'action': 'openMap', 'query': query, ...res},
          toolPill: ok ? '🗺️ 已導航：$query' : '⚠️ openMap：${res['reason'] ?? ''}',
          card: ActionCardData(
            type: 'device_action',
            badge: '🗺️ 一鍵 Google Maps 導航',
            title: query,
            rows: const ['已喚起系統地圖搜尋位置並準備導航路線。'],
            buttonLabel: '🗺️ 再開一次 Google Maps',
            payload: {
              'action': 'openMap',
              'params': {'query': query},
            },
          ),
          directReply: ok
              ? 'Google Maps 幫你拉起來導航「$query」了！'
              : '地圖沒有順利彈出（${res['reason'] ?? ''}），點卡片再試一次：',
        );

      case 'openSettings':
        final panel = value.isEmpty ? 'main' : value;
        final res = await NativeActions.openSystemSettings(panel);
        final label = panel.contains('wifi')
            ? 'Wi-Fi 設定'
            : panel.contains('blue') || panel.contains('藍牙')
                ? '藍牙配對'
                : panel.contains('hotspot') || panel.contains('熱點')
                    ? '熱點／網路共用'
                    : panel.contains('gps') || panel.contains('定位')
                        ? '定位設定'
                        : '系統設定';
        return ToolExecutionOutcome(
          toolResponse: {'action': 'openSettings', 'panel': panel, ...res},
          toolPill: '⚙️ 跳轉 $label',
          card: ActionCardData(
            type: 'device_action',
            badge: '⚙️ 系統設定快速通道',
            title: label,
            rows: const ['免自己滑選單，一點即達該系統面板。'],
            buttonLabel: '⚙️ 開啟 $label',
            payload: {
              'action': 'openSettings',
              'params': {'panel': panel},
            },
          ),
          directReply: '幫你直接跳到「$label」頁面了。',
        );

      default:
        return ToolExecutionOutcome(
          toolResponse: {'ok': false, 'reason': '請指定動作或直接用 @手電筒 / @撥號 / @導航 / @倒數 / @系統設定'},
          toolPill: '📱 原生動作就緒',
          card: const ActionCardData(
            type: 'device_action',
            badge: '🛠️ 可用原生手腳一覽',
            title: '直接打指令或對我說話就行',
            rows: [
              '• @手電筒 開 / 關（@開燈 / @關燈）',
              '• @撥號 0912345678（安全預填撥號盤）',
              '• @導航 中山路一段（喚起 Google Maps）',
              '• @倒數 15分鐘 看烤漆（原生系統時鐘）',
              '• @系統設定 wifi / 藍牙 / 熱點',
            ],
            buttonLabel: '',
            payload: {},
          ),
          directReply: '隨時可以叫我開手電筒、填號撥電話、開 Google Maps 導航、設倒數計時或跳系統設定！',
        );
    }
  }

  Future<ToolExecutionOutcome> _runLoadSkill(Map<String, dynamic> args) async {
    final query = (args['name'] ?? args['query'] ?? '').toString().trim();
    if (query.isEmpty || query == 'list' || query == '列表') {
      final skills = await _db.getSkills();
      final card = ActionCardData(
        type: 'skill',
        badge: '📜 按需 Skill 知識包庫（共 ${skills.length} 份）',
        title: skills.isEmpty ? '目前尚無 Skill 知識包' : '僅在命中關鍵字或點名時動態注入，不佔 KV-Cache',
        rows: [
          for (final s in skills.take(6))
            '${s.enabled ? '🟢' : '⚪'} ${s.name}（觸發：${s.triggerKeywords.take(3).join('/')}）— ${s.description}',
        ],
        buttonLabel: '📜 開啟 Skill 知識包管理',
        payload: {
          'copyText': skills.map((s) => '${s.name}: ${s.description}').join('\n'),
        },
      );
      return ToolExecutionOutcome(
        toolResponse: {
          'count': skills.length,
          'skills': skills.map((s) => {'id': s.id, 'name': s.name, 'enabled': s.enabled}).toList(),
        },
        toolPill: '📜 load_skill：共 ${skills.length} 份知識包',
        card: card,
        directReply: '目前手機裡有 ${skills.length} 份熱插拔 Skill，平常只放超輕量索引不佔記憶體，點下面可以新增或匯入 .md 檔：',
      );
    }

    final skill = await _db.getSkillByNameOrId(query);
    if (skill == null) {
      return ToolExecutionOutcome(
        toolResponse: {'found': false, 'query': query},
        toolPill: '⚠️ load_skill：查無「$query」',
        card: const ActionCardData(
          type: 'skill',
          badge: '📜 查無指定 Skill',
          title: '要自行新增或匯入 .md 知識包嗎？',
          rows: ['打 `@知識` 查看清單，或直接點下面按鈕在手機貼上 Markdown。'],
          buttonLabel: '📜 開啟 Skill 知識包管理',
          payload: {},
        ),
        directReply: '知識庫裡沒找到「$query」，點卡片進 Skill 管理器貼一段 Markdown 我馬上就學會！',
      );
    }

    final previewLines = skill.contentMd
        .split('\n')
        .map((l) => l.trim())
        .where((l) => l.isNotEmpty)
        .take(5)
        .toList();

    return ToolExecutionOutcome(
      toolResponse: {
        'found': true,
        'id': skill.id,
        'name': skill.name,
        'description': skill.description,
        'content_md': skill.contentMd,
      },
      toolPill: '📜 已動態載入 Skill：${skill.name}',
      card: ActionCardData(
        type: 'skill',
        badge: '📜 Skill 知識包詳情',
        title: skill.name,
        rows: [
          '關鍵字：${skill.triggerKeywordsCsv}',
          ...previewLines,
        ],
        buttonLabel: '📜 在管理器編輯／開關',
        payload: {'skillId': skill.id, 'copyText': skill.contentMd},
      ),
      directReply: '已調出「${skill.name}」的現場規範，內容細節在上面卡片：',
    );
  }

  Future<ToolExecutionOutcome> _runWebSearch(
    Map<String, dynamic> args,
    String roomId,
  ) async {
    final query = (args['query'] ?? args['q'] ?? '').toString().trim();
    if (query.isEmpty) {
      return const ToolExecutionOutcome(
        toolResponse: {'ok': false, 'error': '缺少搜尋關鍵字'},
        toolPill: '🌐 web_search：未輸入關鍵字',
        directReply: '要查什麼？直接跟我說關鍵字，例如「@查網 五金行」或「上網查 304白鐵比重」。',
      );
    }

    final roomTodos = await _db.getRoomTodos(roomId);
    final ctxSummary = roomTodos.take(6).map((t) => t.text).join('；');
    final outcome = await WebSearchService.searchWithFallback(
      query: query,
      contextText: ctxSummary,
      roomId: roomId,
    );

    return _outcomeFromWebOrPeer(
      outcome: outcome,
      isDirectPeer: false,
    );
  }

  Future<ToolExecutionOutcome> _runConsultPeer(
    Map<String, dynamic> args,
    String roomId,
  ) async {
    final query = (args['query'] ?? args['prompt'] ?? '').toString().trim();
    final extraContext = (args['context'] ?? '').toString().trim();
    if (query.isEmpty) {
      return const ToolExecutionOutcome(
        toolResponse: {'ok': false, 'error': '缺少提問內容'},
        toolPill: '🛸 consult_peer：請輸入要問同伴的問題',
        directReply: '要呼叫 Spark 參謀或後台支援嗎？把問題貼給我，我直接 HTTP 直連打過去幫你問。',
      );
    }

    final room = await _db.getRoom(roomId);
    final roomTodos = await _db.getRoomTodos(roomId);
    final todoPreview = roomTodos.take(8).map((t) => '${t.done ? "[x]" : "[ ]"} ${t.text}').join('\n');
    final combinedContext = [
      if (room != null) '房間：${room.title}',
      if (room?.rollingSummary.isNotEmpty == true) '摘要：${room!.rollingSummary}',
      if (todoPreview.isNotEmpty) '待辦：\n$todoPreview',
      if (extraContext.isNotEmpty) extraContext,
    ].join('\n');

    final outcome = await WebSearchService.consultPeer(
      query: query,
      contextText: combinedContext,
      roomId: roomId,
    );

    return _outcomeFromWebOrPeer(
      outcome: outcome,
      isDirectPeer: true,
    );
  }

  ToolExecutionOutcome _outcomeFromWebOrPeer({
    required WebSearchOutcome outcome,
    required bool isDirectPeer,
  }) {
    final sourcesList = outcome.sources.map((s) => s.toMap()).toList();
    final primaryUrl = outcome.sources.isNotEmpty ? outcome.sources.first.url : '';
    final usedPeer = outcome.usedPeerFallback || isDirectPeer;
    final peerLabel = outcome.peerName ?? 'Spark 參謀';

    final rawLines = outcome.summaryText
        .split('\n')
        .map((l) => l.trim())
        .where((l) => l.isNotEmpty)
        .take(8)
        .toList();

    final badge = usedPeer
        ? (isDirectPeer ? '🛸 直連同伴支援（$peerLabel）' : '🌐 聯網自動轉接同伴（$peerLabel）')
        : '🔍 已聯網搜尋：${outcome.query}';

    final pill = usedPeer
        ? (outcome.ok ? '🛸 已獲 $peerLabel 回援' : '⚠️ 同伴連線未完成')
        : (outcome.ok ? '🔍 已聯網搜尋：${outcome.query}' : '⚠️ 聯網搜尋異常');

    final card = ActionCardData(
      type: usedPeer ? 'consult_peer' : 'web_search',
      badge: badge,
      title: outcome.query,
      rows: rawLines.isEmpty ? [outcome.summaryText] : rawLines,
      buttonLabel: primaryUrl.isNotEmpty ? '🌐 開啟第一筆驗證網頁' : '📋 一鍵複製整理結果',
      payload: {
        'query': outcome.query,
        'primaryUrl': primaryUrl,
        'copyText': '${outcome.query}\n\n${outcome.summaryText}',
        'sources': sourcesList,
      },
    );

    final replyText = outcome.ok
        ? (usedPeer
            ? '$peerLabel 支援回覆回來了：\n\n${outcome.summaryText}'
            : '剛幫你聯網查了「${outcome.query}」，下面卡片附上可點擊的來源連結給你驗證：')
        : outcome.summaryText;

    return ToolExecutionOutcome(
      toolResponse: {
        'ok': outcome.ok,
        'query': outcome.query,
        'used_peer_fallback': outcome.usedPeerFallback,
        'peer': outcome.peerName,
        'summary': outcome.summaryText,
        'sources': sourcesList,
      },
      toolPill: pill,
      card: card,
      directReply: replyText,
    );
  }

  Future<ToolExecutionOutcome> _runRoutineTool(Map<String, dynamic> args) async {
    final query = (args['query'] ?? '').toString().trim();

    // Quick creation: e.g. "每天 07:30 追金代交期" or "08:15 檢查烤漆"
    final timeMatch = RegExp(r'(\d{1,2})\s*[:：點時]\s*(\d{1,2})?').firstMatch(query);
    if (query.isNotEmpty &&
        query.toLowerCase() != 'list' &&
        query != '列表' &&
        timeMatch != null) {
      final hh = (int.tryParse(timeMatch.group(1)!) ?? 8).clamp(0, 23).toString().padLeft(2, '0');
      final mm = (int.tryParse(timeMatch.group(2) ?? '0') ?? 0).clamp(0, 59).toString().padLeft(2, '0');
      final mode = query.contains('單次') ? 'once' : 'daily';
      var title = query
          .replaceFirst(timeMatch.group(0)!, '')
          .replaceAll(RegExp(r'^(?:每天|每日|單次|今天|明天)\s*'), '')
          .replaceAll(RegExp(r'\s+'), ' ')
          .trim();
      if (title.isEmpty) title = 'KODARI 零算力提醒';

      final saved = await _db.upsertRoutine(
        title: title,
        body: '零算力排程：$title',
        mode: mode,
        timeSpec: '$hh:$mm',
        enabled: true,
      );
      await RoutineScheduler.syncEnabledRoutinesToSystem(_db);
      final next3 = RoutineScheduler.formatNextOccurrencesPreview(saved);

      return ToolExecutionOutcome(
        toolResponse: {'created': true, 'id': saved.id, 'next3': next3},
        toolPill: '⏰ 已設零算力排程：${saved.title}',
        card: ActionCardData(
          type: 'routine',
          badge: '⏰ 零算力日常排程已啟用（0 Token）',
          title: '${saved.modeLabel} $hh:$mm • ${saved.title}',
          rows: [
            '未來 3 次執行預覽：',
            for (final ts in next3) '• $ts',
          ],
          buttonLabel: '⏰ 開啟零算力排程管理器',
          payload: {'routineId': saved.id},
        ),
        directReply: '設好了！${saved.modeLabel} $hh:$mm「${saved.title}」（完全不叫醒 4B，純系統定時叫你）。',
      );
    }

    final routines = await _db.getRoutines();
    final enabledCount = routines.where((r) => r.enabled).length;
    final rows = <String>[];
    for (final r in routines.take(4)) {
      final next3 = RoutineScheduler.formatNextOccurrencesPreview(r);
      rows.add('${r.enabled ? '🟢' : '⚪'} [${r.modeLabel} ${r.timeSpec}] ${r.title}');
      rows.add('   預覽：${next3.take(2).join('、')}');
    }
    if (rows.isEmpty) {
      rows.add('目前尚無日常排程，點下面按鈕或輸入 `@排程 每天 07:30 追料` 即可建立。');
    }

    return ToolExecutionOutcome(
      toolResponse: {'count': routines.length, 'enabled': enabledCount},
      toolPill: '⏰ 日常排程（啟用 $enabledCount / 共 ${routines.length} 筆）',
      card: ActionCardData(
        type: 'routine',
        badge: '⏰ 零算力日常排程總覽',
        title: '啟用中 $enabledCount 筆 • 未來執行時間預覽',
        rows: rows,
        buttonLabel: '⏰ 開啟排程管理器（新增 / Cron / 預覽）',
        payload: {},
      ),
      directReply: '這是目前的零算力日常排程清單（不消耗任何 AI 算力）：',
    );
  }
}
