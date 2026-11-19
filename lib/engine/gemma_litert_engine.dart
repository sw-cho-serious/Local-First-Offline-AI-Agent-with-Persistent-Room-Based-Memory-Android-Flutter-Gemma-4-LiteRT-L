import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_edge_ai/flutter_edge_ai.dart';
import 'package:flutter_edge_ai_litertlm/flutter_edge_ai_litertlm.dart';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../core/async_mutex.dart';
import '../core/token_estimator.dart';
import '../data/database_helper.dart';
import '../data/models.dart';
import '../tools/fast_path_router.dart';
import '../tools/native_actions.dart';
import '../tools/routine_scheduler.dart';
import '../tools/tool_registry.dart';
import 'llm_engine.dart';

class GemmaLiteRtEngine implements LlmEngine {
  GemmaLiteRtEngine({
    required this.db,
    required this.toolRegistry,
  });

  static const int maxContextTokens = 8192;
  static const int maxOutputTokens = 512;
  static const String _prefEngineChannelKey = 'hako_engine_channel';
  static const String _prefLocalHttpUrlKey = 'hako_local_http_url';
  static const String _prefLocalHttpModelKey = 'hako_local_http_model';

  final DatabaseHelper db;
  final ToolRegistry toolRegistry;
  final AsyncMutex _mutex = AsyncMutex();

  bool _sdkInitialized = false;
  InferenceModel? _model;
  InferenceChat? _activeChat;
  String? _activeRoomId;
  String? _activeToolKey;
  String? _activeSessionDate;
  bool _useGpu = true;
  bool _isFallbackMode = false;
  String? _installedPath;
  bool _cancelRequested = false;

  String _engineChannel = 'litert';
  String _localHttpUrl = 'http://127.0.0.1:8080/v1';
  String _localHttpModel = 'gemma-4-e4b-heretic';
  http.Client? _activeHttpClient;
  int _effectiveMaxContextTokens = maxContextTokens;
  bool _isInferencing = false;

  static String _dateKey(DateTime dt) =>
      '${dt.year}-${dt.month.toString().padLeft(2, '0')}-${dt.day.toString().padLeft(2, '0')}';

  static String _formatNowStamp(DateTime dt) {
    const weekdays = ['一', '二', '三', '四', '五', '六', '日'];
    final hh = dt.hour.toString().padLeft(2, '0');
    final mm = dt.minute.toString().padLeft(2, '0');
    return '${_dateKey(dt)} $hh:$mm (週${weekdays[dt.weekday - 1]})';
  }

  Future<void>? _prewarmFuture;
  String? _prewarmRoomId;

  @override
  bool get isModelReady =>
      (_engineChannel == 'local_http' && _localHttpUrl.trim().isNotEmpty) ||
      _model != null;

  @override
  bool get isFallbackMode => _isFallbackMode;

  @override
  bool get useGpu => _useGpu;

  @override
  String? get installedModelPath => _installedPath;

  @override
  String get engineChannel => _engineChannel;

  @override
  String get localHttpUrl => _localHttpUrl;

  @override
  String get localHttpModel => _localHttpModel;

  @override
  int get effectiveMaxContextTokens => _effectiveMaxContextTokens;

  /// V2 Batch 2: Detects small-model repetition/jumping-needle loops (e.g. "對對對..."
  /// or repeated phrases) and cleanly trims the tail so KV-Cache can be flushed.
  static ({bool hasLoop, String cleanedText}) detectAndTrimRepetitionLoop(String text) {
    if (text.length < 18) return (hasLoop: false, cleanedText: text);

    // Case A: Single or 2-char non-numeric unit repeated >= 12 times consecutively at tail
    final shortLoop = RegExp(r'([^\d\s\-=*_.#`]{1,2}?)\1{11,}$').firstMatch(text);
    if (shortLoop != null) {
      final cutAt = shortLoop.start + shortLoop.group(1)!.length;
      return (hasLoop: true, cleanedText: text.substring(0, cutAt).trimRight());
    }

    // Case B: Phrase of 4..48 chars repeated >= 4 times consecutively at tail
    final phraseLoop = RegExp(r'(.{4,48}?)\1{3,}$', dotAll: true).firstMatch(text);
    if (phraseLoop != null) {
      final unit = phraseLoop.group(1) ?? '';
      final stripped = unit.replaceAll(RegExp(r'[\s\-=*_.#`>]'), '');
      if (stripped.isNotEmpty) {
        final cutAt = phraseLoop.start + unit.length;
        return (hasLoop: true, cleanedText: text.substring(0, cutAt).trimRight());
      }
    }

    return (hasLoop: false, cleanedText: text);
  }

  @override
  String get activeBackendLabel {
    if (_engineChannel == 'local_http' && _localHttpUrl.trim().isNotEmpty) {
      return 'GGUF • ${formatShortEndpoint(_localHttpUrl)}';
    }
    if (_model != null) {
      final b = _model!.activeBackend;
      if (b == PreferredBackend.gpu) return 'Gemma-4-E4B • GPU';
      if (b == PreferredBackend.npu) return 'Gemma-4-E4B • NPU';
      return 'Gemma-4-E4B • CPU';
    }
    if (_isFallbackMode) return '離線規則／查表模式';
    return '未載入模型';
  }

  static String formatShortEndpoint(String rawUrl) {
    final trimmed = rawUrl.trim();
    if (trimmed.isEmpty) return '未設定';
    final normalized = (trimmed.startsWith('http://') || trimmed.startsWith('https://'))
        ? trimmed
        : 'http://$trimmed';
    try {
      final uri = Uri.parse(normalized);
      if (uri.host.isNotEmpty) {
        return uri.hasPort ? '${uri.host}:${uri.port}' : uri.host;
      }
    } catch (_) {}
    return trimmed;
  }

  static String normalizeChatCompletionsUrl(String rawUrl) {
    var s = rawUrl.trim();
    if (s.isEmpty) return '';
    if (!s.startsWith('http://') && !s.startsWith('https://')) {
      s = 'http://$s';
    }
    s = s.replaceAll(RegExp(r'/+$'), '');
    if (s.endsWith('/chat/completions')) return s;
    if (s.endsWith('/v1')) return '$s/chat/completions';
    return '$s/v1/chat/completions';
  }

  static String normalizeModelsUrl(String rawUrl) {
    var s = rawUrl.trim();
    if (s.isEmpty) return '';
    if (!s.startsWith('http://') && !s.startsWith('https://')) {
      s = 'http://$s';
    }
    s = s.replaceAll(RegExp(r'/+$'), '');
    if (s.endsWith('/chat/completions')) {
      return '${s.substring(0, s.length - '/chat/completions'.length)}/models';
    }
    if (s.endsWith('/models')) return s;
    if (s.endsWith('/v1')) return '$s/models';
    return '$s/v1/models';
  }

  Future<void> _loadSavedChannelConfig() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final ch = prefs.getString(_prefEngineChannelKey);
      if (ch == 'local_http' || ch == 'litert') {
        _engineChannel = ch!;
      }
      final url = prefs.getString(_prefLocalHttpUrlKey);
      if (url != null && url.trim().isNotEmpty) {
        _localHttpUrl = url.trim();
      }
      final model = prefs.getString(_prefLocalHttpModelKey);
      if (model != null && model.trim().isNotEmpty) {
        _localHttpModel = model.trim();
      }
    } catch (_) {}
  }

  @override
  Future<void> configureEngineChannel({
    required String channel,
    String? httpUrl,
    String? httpModel,
  }) async {
    _engineChannel = channel == 'local_http' ? 'local_http' : 'litert';
    if (httpUrl != null && httpUrl.trim().isNotEmpty) {
      _localHttpUrl = httpUrl.trim();
    }
    if (httpModel != null && httpModel.trim().isNotEmpty) {
      _localHttpModel = httpModel.trim();
    }
    if (_engineChannel == 'local_http') {
      _isFallbackMode = false;
    }
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_prefEngineChannelKey, _engineChannel);
      await prefs.setString(_prefLocalHttpUrlKey, _localHttpUrl);
      await prefs.setString(_prefLocalHttpModelKey, _localHttpModel);
    } catch (_) {}

    if (_engineChannel == 'litert' && _model == null) {
      await _tryAutoLoadLiteRtModel();
    }
  }

  @override
  Future<({bool ok, String message, List<String> models})> testLocalHttpConnection([
    String? urlOverride,
  ]) async {
    final base = (urlOverride ?? _localHttpUrl).trim();
    if (base.isEmpty) {
      return (ok: false, message: '請先輸入 API 網址', models: const <String>[]);
    }
    final modelsUrl = normalizeModelsUrl(base);
    final client = http.Client();
    try {
      final res = await client.get(Uri.parse(modelsUrl)).timeout(const Duration(seconds: 5));
      if (res.statusCode >= 200 && res.statusCode < 300) {
        final models = <String>[];
        try {
          final decoded = jsonDecode(utf8.decode(res.bodyBytes));
          if (decoded is Map && decoded['data'] is List) {
            for (final item in decoded['data'] as List) {
              if (item is Map && item['id'] != null) {
                models.add(item['id'].toString());
              }
            }
          }
        } catch (_) {}
        return (
          ok: true,
          message: models.isEmpty
              ? '連線成功！($modelsUrl)'
              : '連線成功！偵測到模型：${models.join(', ')}',
          models: models,
        );
      }
      // Fallback check `/health` on llama.cpp servers
      final uri = Uri.parse(modelsUrl);
      final healthUri = uri.replace(path: '/health');
      final healthRes = await client.get(healthUri).timeout(const Duration(seconds: 4));
      if (healthRes.statusCode >= 200 && healthRes.statusCode < 300) {
        return (ok: true, message: 'llama-server 健康就緒 (${healthUri.host}:${healthUri.port})', models: const <String>[]);
      }
      return (ok: false, message: '伺服器回傳 HTTP ${res.statusCode}', models: const <String>[]);
    } catch (e) {
      return (ok: false, message: '無法連上伺服器：$e', models: const <String>[]);
    } finally {
      client.close();
    }
  }

  Future<void> _ensureSdkInitialized() async {
    if (_sdkInitialized) return;
    await FlutterEdgeAi.initialize(
      inferenceEngines: const [LiteRtLmEngine()],
    );
    _sdkInitialized = true;
  }

  @override
  Future<void> initializeEngine() async {
    NativeActions.setOnMemoryCriticalCallback(handleCriticalMemoryPressure);
    final hwStatus = await NativeActions.getDeviceRuntimeStatus();
    if (hwStatus.ok) {
      _effectiveMaxContextTokens = hwStatus.recommendedMaxContextTokens;
    }
    unawaited(RoutineScheduler.syncEnabledRoutinesToSystem(db));

    await _loadSavedChannelConfig();
    if (_engineChannel == 'local_http' && _localHttpUrl.trim().isNotEmpty) {
      // Channel B active: ready immediately without forcing 3.7GB LiteRT load at startup.
      _isFallbackMode = false;
      return;
    }
    await _tryAutoLoadLiteRtModel();
  }

  @override
  Future<void> handleCriticalMemoryPressure() async {
    if (_isInferencing || _model == null) return;
    await _mutex.synchronized(() async {
      if (_isInferencing || _model == null) return;
      await _closeActiveChatOnly();
      await _model?.close();
      _model = null;
      debugPrint('[GemmaLiteRtEngine] Released model on TRIM_MEMORY_RUNNING_CRITICAL');
    });
  }

  Future<void> _tryAutoLoadLiteRtModel() async {
    try {
      await _ensureSdkInitialized();

      // 1. Check if flutter_edge_ai already has an active model recorded.
      if (FlutterEdgeAi.hasActiveModel()) {
        final spec = FlutterEdgeAi.activeModelSpec;
        if (spec != null && spec.files.isNotEmpty) {
          final path = await FlutterEdgeAi.getModelPath(spec.files.first.filename);
          if (await File(path).exists()) {
            _installedPath = path;
            await _loadSingletonModel();
            return;
          }
        }
      }

      // 2. Silent check standard fixed paths for gemma-4-E4B-it.litertlm.
      await NativeActions.ensureStoragePermission();
      final candidatePath = await _findExistingModelFile();
      if (candidatePath != null) {
        await installFromFilePath(candidatePath);
        return;
      }

      // No model file found yet -> stays unready so SetupGate / Fallback handles it.
      _isFallbackMode = false;
    } catch (e) {
      debugPrint('[GemmaLiteRtEngine] _tryAutoLoadLiteRtModel error: $e');
    }
  }

  Future<String?> _findExistingModelFile() async {
    final candidates = <String>[
      '/storage/emulated/0/Download/gemma-4-E4B-it-abliterated.litertlm',
      '/sdcard/Download/gemma-4-E4B-it-abliterated.litertlm',
      '/storage/emulated/0/Download/gemma-4-E4B-it.litertlm',
      '/sdcard/Download/gemma-4-E4B-it.litertlm',
      '/storage/emulated/0/Download/Gemma-4-E4B-it.litertlm',
      '/storage/emulated/0/Download/gemma-4-e4b-it.litertlm',
    ];

    try {
      final extDir = await getExternalStorageDirectory();
      if (extDir != null) {
        candidates.add(p.join(extDir.path, 'gemma-4-E4B-it-abliterated.litertlm'));
        candidates.add(p.join(extDir.path, 'gemma-4-E4B-it.litertlm'));
      }
      final docDir = await getApplicationDocumentsDirectory();
      candidates.add(p.join(docDir.path, 'gemma-4-E4B-it-abliterated.litertlm'));
      candidates.add(p.join(docDir.path, 'gemma-4-E4B-it.litertlm'));
    } catch (_) {}

    for (final path in candidates) {
      try {
        if (await File(path).exists()) return path;
      } catch (_) {}
    }
    return null;
  }

  @override
  Future<List<File>> scanAvailableModelFiles() async {
    final found = <String, File>{};
    final searchDirs = <String>[
      '/storage/emulated/0/Download',
      '/sdcard/Download',
    ];
    try {
      final extDir = await getExternalStorageDirectory();
      if (extDir != null) searchDirs.add(extDir.path);
      final docDir = await getApplicationDocumentsDirectory();
      searchDirs.add(docDir.path);
    } catch (_) {}

    for (final dirPath in searchDirs) {
      try {
        final d = Directory(dirPath);
        if (await d.exists()) {
          final entries = d.listSync();
          for (final entry in entries) {
            if (entry is File && (entry.path.endsWith('.litertlm') || entry.path.endsWith('.bin'))) {
              found[entry.path] = entry;
            }
          }
        }
      } catch (_) {}
    }
    if (_installedPath != null) {
      final f = File(_installedPath!);
      if (f.existsSync()) {
        found[f.path] = f;
      }
    }
    return found.values.toList();
  }

  void enableFallbackMode() {
    _isFallbackMode = true;
  }

  @override
  Future<void> installFromFilePath(String path) async {
    await _ensureSdkInitialized();
    await _mutex.synchronized(() async {
      await _closeActiveChatOnly();
      await _model?.close();
      _model = null;

      await FlutterEdgeAi.installModel(
        modelType: ModelType.gemma4,
        fileType: ModelFileType.litertlm,
      ).fromFile(path).install();

      _installedPath = path;
      _isFallbackMode = false;
      await _loadSingletonModelInternal();
    });
  }

  @override
  Future<void> installFromCatalog({
    required void Function(int percent) onProgress,
  }) async {
    await _ensureSdkInitialized();
    await _mutex.synchronized(() async {
      await _closeActiveChatOnly();
      await _model?.close();
      _model = null;

      final variant = LiteRtLmModels.gemma4E4bIt.generic;
      await FlutterEdgeAi.installModelFromCatalog(variant)
          .withProgress(onProgress)
          .install();

      _installedPath = await FlutterEdgeAi.getModelPath(variant.file.path);
      _isFallbackMode = false;
      await _loadSingletonModelInternal();
    });
  }

  @override
  Future<void> setUseGpu(bool gpu) async {
    if (_useGpu == gpu) return;
    _useGpu = gpu;
    if (_model == null && !_isFallbackMode && FlutterEdgeAi.hasActiveModel()) {
      await _loadSingletonModel();
      return;
    }
    if (_model != null) {
      await _loadSingletonModel();
    }
  }

  Future<void> _loadSingletonModel() {
    return _mutex.synchronized(() => _loadSingletonModelInternal());
  }

  Future<void> _loadSingletonModelInternal() async {
    await _closeActiveChatOnly();
    await _model?.close();
    _model = null;

    _model = await FlutterEdgeAi.getActiveModel(
      maxTokens: _effectiveMaxContextTokens,
      preferredBackend: _useGpu ? PreferredBackend.gpu : PreferredBackend.cpu,
      supportImage: true,
      maxNumImages: 1,
      activationDataType: _useGpu ? ActivationDataType.float32 : null,
      maxConcurrentSessions: 2,
    );
  }

  List<String> _ambientToolsForRoom(String roomId) {
    if (roomId == 'main') {
      return const [
        'search_memory',
        'schedule_notification',
        'create_calendar_event',
        'device_action',
        'load_skill',
        'web_search',
        'consult_peer',
      ];
    }
    if (roomId.startsWith('para:archives:')) {
      return const [];
    }
    return const [
      'data_write',
      'schedule_notification',
      'create_calendar_event',
      'device_action',
      'load_skill',
      'web_search',
      'consult_peer',
    ];
  }

  @override
  Future<void> prewarmRoomSession(String roomId) {
    if (_model == null) return Future<void>.value();
    final ambientTools = _ambientToolsForRoom(roomId);
    final ambientKey = ambientTools.join(',');
    if (_activeRoomId == roomId && _activeChat != null && _activeToolKey == ambientKey) {
      return Future<void>.value();
    }
    if (_prewarmFuture != null && _prewarmRoomId == roomId) {
      return _prewarmFuture!;
    }

    _prewarmRoomId = roomId;
    final future = _mutex.synchronized(() async {
      if (_model == null) return;
      if (_activeRoomId == roomId && _activeChat != null && _activeToolKey == ambientKey) {
        return;
      }
      await _buildChatSessionInternal(roomId: roomId, toolNames: ambientTools);
    });
    _prewarmFuture = future.whenComplete(() {
      if (identical(_prewarmFuture, future)) {
        _prewarmFuture = null;
      }
    });
    return _prewarmFuture!;
  }

  Future<void> _closeActiveChatOnly() async {
    final chat = _activeChat;
    _activeChat = null;
    _activeRoomId = null;
    _activeToolKey = null;
    _activeSessionDate = null;
    if (chat != null) {
      try {
        await chat.close();
      } catch (_) {}
    }
  }

  @override
  Future<void> invalidateSession() async {
    await _mutex.synchronized(() async {
      await _closeActiveChatOnly();
    });
  }

  Future<String> _assembleSystemPrompt(String roomId) async {
    final traits = await db.getAllTraits();
    final room = await db.getRoom(roomId);
    final rooms = await db.getRooms();
    final todos = await db.getRoomTodos(roomId);
    final enabledSkills = await db.getSkills(onlyEnabled: true);

    final soul = traits['SOUL.md'] ?? '';
    final voice = traits['VOICE.md'] ?? '';
    final user = traits['USER.md'] ?? '';
    final relationship = traits['relationship.md'] ?? '';
    final mood = traits['mood.md'] ?? '';
    final memory = traits['MEMORY.md'] ?? '';

    final activeRoomNames = rooms
        .where((r) => !r.isMain && !r.isArchived)
        .take(15)
        .map((r) => '${r.title} (${r.roomId})')
        .join('、');

    final notesText = todos.isEmpty
        ? '（本房目前尚無待辦項目）'
        : todos.map((t) => '${t.done ? '- [x]' : '- [ ]'} ${t.text}').join('\n');

    final buf = StringBuffer()
      ..writeln('【最高語氣鐵律】')
      ..writeln(voice)
      ..writeln()
      ..writeln('【你是誰】')
      ..writeln(soul)
      ..writeln()
      ..writeln('【對象與工廠基準】')
      ..writeln(user);

    if (relationship.trim().isNotEmpty) {
      buf
        ..writeln()
        ..writeln('【默契筆記】')
        ..writeln(relationship.trim());
    }
    if (mood.trim().isNotEmpty) {
      buf
        ..writeln()
        ..writeln('【近期狀態】')
        ..writeln(mood.trim());
    }
    if (memory.contains('- ')) {
      buf
        ..writeln()
        ..writeln('【長期自主蒸餾記憶 (MEMORY.md)】')
        ..writeln(memory.trim());
    }

    if (activeRoomNames.isNotEmpty) {
      buf
        ..writeln()
        ..writeln('【現有活躍工作房間（嚴禁私自重複亂開同名房間）】')
        ..writeln(activeRoomNames);
    }

    if (enabledSkills.isNotEmpty) {
      // Keep only a compact index here so content_md never inflates the 3072 KV-cache prefix.
      buf
        ..writeln()
        ..writeln('【可用按需 Skill 知識包索引（需要詳細 SOP 可呼出 load_skill）】');
      for (final s in enabledSkills.take(12)) {
        buf.writeln('- ${s.name}：${s.description}');
      }
    }

    final now = DateTime.now();
    const weekdays = ['一', '二', '三', '四', '五', '六', '日'];
    final nowStr =
        '${now.year}-${now.month.toString().padLeft(2, '0')}-${now.day.toString().padLeft(2, '0')} '
        '${now.hour.toString().padLeft(2, '0')}:${now.minute.toString().padLeft(2, '0')} '
        '(週${weekdays[now.weekday - 1]})';

    buf
      ..writeln()
      ..writeln('【當前手機系統時間】$nowStr（排程、提醒與「今天／明天」一律以此為基準）')
      ..writeln('【當前房間】${room?.title ?? 'KODARI 主房間'} (${room?.roomId ?? roomId})');

    if (room != null && room.rollingSummary.trim().isNotEmpty) {
      buf
        ..writeln('【前期對話壓縮摘要】')
        ..writeln(room.rollingSummary.trim());
    }

    buf
      ..writeln('【本房目前待辦與筆記】')
      ..writeln(notesText)
      ..writeln()
      ..writeln('【雙軌格式與防呆鐵律】')
      ..writeln('1. 對使用者回話一律維持自然短句口語，禁稱「您」、禁列 1. 2. 3. 報告體。')
      ..writeln('2. 【房間待辦唯一鎖定】：你目前身在【當前房間】。使用者交代的任何待辦、工項追加、現場交代，一律且只能呼叫 data_write 寫入【當前房間】！你「沒有」任何跨房間寫入的權限或工具，絕對嚴禁自作聰明聲稱幫使用者寫到其他房間（例如「工廠雜記」）！')
      ..writeln('3. 【嚴禁口頭假裝】：當使用者交代記待辦或確認「加吧」時，必須實際調用 data_write 工具（item_text 精簡具體）。嚴禁沒調用工具就在對話中用文字打出【房間名】* 待辦項目 (pending) 假裝已寫入！')
      ..writeln('4. 若使用者約定提醒或日曆時間，直接呼出 schedule_notification 或 create_calendar_event（系統會自動彈出確認卡讓使用者點選），不可在沒呼出工具的情況下口頭假裝已設好。')
      ..writeln('5. 若使用者要求建立新工作房間，請引導點擊下方「建立工作房間」卡片或左側選單按鈕，不可口頭假裝已建立完成。');

    return buf.toString();
  }

  /// Fetches the last 4 complete turns starting cleanly at a user message.
  Future<List<({bool isUser, String text})>> _loadReplayEntries(String roomId) async {
    final all = await db.getMessages(roomId);
    final room = await db.getRoom(roomId);
    final minId = room?.summarizedUntilMsgId ?? 0;

    // Respect the latest "── 新話題 ──" divider so old topics don't pollute context.
    var startIdx = 0;
    for (var i = all.length - 1; i >= 0; i--) {
      if (all[i].role == 'divider') {
        startIdx = i + 1;
        break;
      }
    }

    final candidates = all
        .sublist(startIdx)
        .where((m) => m.id > minId && (m.role == 'user' || m.role == 'model'))
        .toList();

    // Keep up to last 8 messages (4 rounds), aligned to start on a 'user' message.
    var sliceStart = candidates.length > 8 ? candidates.length - 8 : 0;
    while (sliceStart < candidates.length && candidates[sliceStart].role != 'user') {
      sliceStart++;
    }
    final sliced = candidates.sublist(sliceStart);

    // Never replay images into history to stay well within the 3072-token KV budget.
    return sliced
        .map((m) => (
              isUser: m.role == 'user',
              text: m.imagePath != null && m.imagePath!.isNotEmpty
                  ? '[曾附上一張現場照片] ${m.content}'
                  : m.content,
            ))
        .toList();
  }

  Future<List<Message>> _loadReplayMessages(String roomId) async {
    final entries = await _loadReplayEntries(roomId);
    return entries
        .map((e) => Message.text(text: e.text, isUser: e.isUser))
        .toList();
  }

  Future<void> _buildChatSessionInternal({
    required String roomId,
    required List<String> toolNames,
  }) async {
    final model = _model;
    if (model == null) return;

    await _closeActiveChatOnly();

    final systemPrompt = await _assembleSystemPrompt(roomId);
    final replay = await _loadReplayMessages(roomId);
    final tools = toolNames.map(ToolRegistry.buildSchema).toList();

    final chat = await model.openChat(
      supportImage: true,
      tools: tools,
      supportsFunctionCalls: tools.isNotEmpty,
      enableThinking: false,
      modelType: ModelType.gemma4,
      toolChoice: ToolChoice.auto,
      systemInstruction: systemPrompt,
      maxOutputTokens: maxOutputTokens,
    );

    if (replay.isNotEmpty) {
      await chat.clearHistory(replayHistory: replay);
    }

    _activeChat = chat;
    _activeRoomId = roomId;
    _activeToolKey = toolNames.join(',');
    _activeSessionDate = _dateKey(DateTime.now());
  }

  static String buildTurnUserPrompt({
    required String userText,
    required String nowStamp,
    AtToolOption? mountedTool,
    List<SkillRecord> triggeredSkills = const [],
    String? intentHint,
  }) {
    final hintPrefix = (intentHint != null && intentHint.trim().isNotEmpty)
        ? '${intentHint.trim()}\n'
        : '';
    if (mountedTool != null) {
      return '[現在時間 $nowStamp][已手動掛載工具 ${mountedTool.toolName}，請直接調用該工具處理後用 KODARI 口吻簡短回覆] $userText';
    }
    if (triggeredSkills.isEmpty) {
      return '$hintPrefix[現在時間 $nowStamp] $userText';
    }
    final skillBlock = triggeredSkills
        .map((s) => '## ${s.name}\n${s.contentMd.trim()}')
        .join('\n\n');
    return '[系統本輪按需載入 Skill 指引（用完即卸，無需重複復誦）]\n'
        '$skillBlock\n'
        '[/系統本輪按需載入 Skill 指引]\n\n'
        '$hintPrefix[現在時間 $nowStamp] $userText';
  }

  @override
  Stream<EngineStreamEvent> sendMessageStream({
    required String roomId,
    required String userText,
    Uint8List? compressedImageBytes,
    AtToolOption? mountedTool,
  }) async* {
    _cancelRequested = false;

    // 1. Await in-flight prewarm first (never spawn a duplicate session build).
    final inflight = _prewarmFuture;
    if (inflight != null && _prewarmRoomId == roomId) {
      try {
        await inflight;
      } catch (_) {}
    }

    // 2. Deterministic @ tool path: whenever user mounted or typed a leading @ tool
    // (without attaching an image for Vision OCR), execute immediately in Dart with zero LLM latency.
    final leadingMatch =
        mountedTool == null ? ToolRegistry.matchLeadingAtTool(userText) : null;
    final effectiveTool = mountedTool ?? leadingMatch?.option;
    final effectiveUserText = leadingMatch?.cleanText ?? userText;
    if (effectiveTool != null && compressedImageBytes == null) {
      yield const EngineStateHint(SpiritState.working);
      final outcome = await toolRegistry.executeFallbackFromAtOption(
        option: effectiveTool,
        userText: effectiveUserText,
        roomId: roomId,
      );
      yield EngineToolExecuted(toolPill: outcome.toolPill, card: outcome.card);
      yield EngineTextChunk(outcome.directReply ?? '處理好了。');
      yield const EngineStateHint(SpiritState.idle);
      return;
    }

    // 2.5 <2ms FastPathRouter (Mode A): spoken natural-language hardware/search/peer commands
    // execute directly without waking GPU or consuming any model tokens.
    if (mountedTool == null && compressedImageBytes == null) {
      final fastHit = FastPathRouter.matchFastPath(userText);
      if (fastHit != null) {
        yield const EngineStateHint(SpiritState.working);
        final outcome = await toolRegistry.executeTool(
          toolName: fastHit.toolName,
          args: fastHit.args,
          roomId: roomId,
        );
        yield EngineToolExecuted(
          toolPill: outcome.toolPill ?? '⚡ ${fastHit.label}',
          card: outcome.card,
        );
        yield EngineTextChunk(outcome.directReply ?? '處理好了。');
        yield const EngineStateHint(SpiritState.idle);
        return;
      }
    }

    // Check Track-1 zero-LLM keyword / @SkillName JIT triggers & Mode B IntentBagger hints.
    final triggeredSkills = mountedTool == null
        ? await db.matchTriggeredSkills(userText)
        : const <SkillRecord>[];
    final intentHint = mountedTool == null
        ? FastPathRouter.bagIntentHints(userText)
        : null;

    // 3. Dual-channel routing: Channel B (Termux / Y700 GGUF Local HTTP Server)
    if (_engineChannel == 'local_http' && _localHttpUrl.trim().isNotEmpty) {
      yield* _streamViaLocalHttp(
        roomId: roomId,
        userText: userText,
        compressedImageBytes: compressedImageBytes,
        mountedTool: mountedTool,
        triggeredSkills: triggeredSkills,
        intentHint: intentHint,
      );
      return;
    }

    // 4. Fallback when 3.7GB model is not loaded yet (images / free chat).
    if (_model == null) {
      yield const EngineStateHint(SpiritState.working);

      if (triggeredSkills.isNotEmpty) {
        yield EngineToolExecuted(
          toolPill: '📜 已按需載入 Skill：${triggeredSkills.map((s) => s.name).join('、')}',
        );
      }

      if (compressedImageBytes != null) {
        yield const EngineStateHint(SpiritState.stuck);
        yield const EngineTextChunk(
          '目前還沒載入 Gemma-4-E4B 模型本體（離線預覽模式）。照片我先幫你留在這間房，點氣泡可打 ⭐ 暫存，等模型匯入後就能看圖辨識。',
        );
        return;
      }

      final suggested = detectSuggestedRoom(userText);
      if (suggested != null) {
        yield EngineSuggestedRoom(suggested);
      }
      final skillNote = triggeredSkills.isEmpty
          ? ''
          : '\n📜 本輪已動態載入「${triggeredSkills.map((s) => s.name).join('、')}」，正式載入 Gemma 4 後會直接依循該 Skill 規範回答！';
      yield EngineTextChunk(
        '收到「$userText」。目前處於離線預覽模式（還沒載入 Gemma 4 權重），但上面可以點 @ 工具卡直接查鋁料／調機／排日曆／硬體動作，或長按氣泡歸檔。$skillNote',
      );
      yield const EngineStateHint(SpiritState.idle);
      return;
    }

    // 3. Real Gemma 4 LiteRT-LM inference serialized by AsyncMutex.
    final controller = StreamController<EngineStreamEvent>();
    unawaited(_mutex.synchronized(() async {
      _isInferencing = true;
      try {
        controller.add(const EngineStateHint(SpiritState.thinking));

        if (triggeredSkills.isNotEmpty) {
          controller.add(EngineToolExecuted(
            toolPill: '📜 已按需載入 Skill：${triggeredSkills.map((s) => s.name).join('、')}',
          ));
        }

        final now = DateTime.now();
        final todayKey = _dateKey(now);
        final desiredTools =
            mountedTool != null ? <String>[mountedTool.toolName] : _ambientToolsForRoom(roomId);
        final desiredKey = desiredTools.join(',');
        if (_activeChat == null ||
            _activeRoomId != roomId ||
            _activeToolKey != desiredKey ||
            _activeSessionDate != todayKey) {
          await _buildChatSessionInternal(roomId: roomId, toolNames: desiredTools);
        }

        final chat = _activeChat!;
        final nowStamp = _formatNowStamp(now);
        // Inject matched Skill markdown ONLY into this turn's user message so System Instruction
        // stays identical and the 3072 KV-cache prefix stays 100% hot!
        final promptText = buildTurnUserPrompt(
          userText: userText,
          nowStamp: nowStamp,
          mountedTool: mountedTool,
          triggeredSkills: triggeredSkills,
          intentHint: intentHint,
        );

        final message = compressedImageBytes != null
            ? Message.withImage(
                text: promptText,
                imageBytes: compressedImageBytes,
                isUser: true,
              )
            : Message.text(text: promptText, isUser: true);

        await chat.addQueryChunk(message);

        final replyBuffer = StringBuffer();
        var usedTool = false;
        var loopFlushed = false;

        await for (final resp in chat.generateChatResponseWithTools(
          maxToolTurns: 3,
          isCancelled: () => _cancelRequested,
          onToolCall: (call) async {
            usedTool = true;
            controller.add(const EngineStateHint(SpiritState.working));
            final outcome = await toolRegistry.executeTool(
              toolName: call.name,
              args: call.args,
              roomId: roomId,
              requireConfirm: mountedTool == null,
            );
            controller.add(EngineToolExecuted(
              toolPill: outcome.toolPill,
              card: outcome.card,
            ));
            return outcome.toolResponse;
          },
        )) {
          if (resp is TextResponse) {
            replyBuffer.write(resp.token);
            controller.add(EngineTextChunk(resp.token));

            final curStr = replyBuffer.toString();
            if (curStr.length >= 40) {
              final loopCheck = detectAndTrimRepetitionLoop(curStr);
              if (loopCheck.hasLoop) {
                loopFlushed = true;
                _cancelRequested = true;
                try {
                  await _activeChat?.stopGeneration();
                } catch (_) {}
                await _closeActiveChatOnly();
                controller.add(const EngineToolExecuted(
                  toolPill: '⚡ 已偵測跳針並清洗 KV-Cache',
                ));
                controller.add(const EngineTextChunk(
                  '\n\n⚡ [偵測到模型重複跳針，已自動中斷並清洗 KV-Cache 脫困]',
                ));
                break;
              }
            }
          }
        }
        if (loopFlushed) {
          await _closeActiveChatOnly();
        }

        // If user explicitly mounted @查鋁料 or @查調機 and Gemma forgot to emit a tool call,
        // execute the deterministic SQLite lookup so the user still gets the exact card.
        if (!usedTool &&
            mountedTool != null &&
            !_cancelRequested &&
            (mountedTool.toolName == 'lookup_profile' ||
                mountedTool.toolName == 'lookup_machine_tuning')) {
          final outcome = await toolRegistry.executeFallbackFromAtOption(
            option: mountedTool,
            userText: userText,
            roomId: roomId,
          );
          controller.add(EngineToolExecuted(
            toolPill: outcome.toolPill,
            card: outcome.card,
          ));
        }

        // If user requested an @ tool and Gemma returned empty text after tool card,
        // emit a short natural fallback line so the bubble is never blank.
        if (replyBuffer.isEmpty && usedTool) {
          controller.add(const EngineTextChunk('搞定了，看上面的卡片確認一下。'));
        }

        final suggested = detectSuggestedRoom(userText);
        if (suggested != null) {
          controller.add(EngineSuggestedRoom(suggested));
        }

        final fullReply = replyBuffer.toString();
        if (fullReply.contains('看不清') || fullReply.contains('認不出')) {
          controller.add(const EngineStateHint(SpiritState.stuck));
        } else {
          controller.add(const EngineStateHint(SpiritState.idle));
        }
      } catch (e, st) {
        debugPrint('[GemmaLiteRtEngine] inference error: $e\n$st');
        controller.add(const EngineStateHint(SpiritState.stuck));
        controller.add(EngineTextChunk('\n[推論異常：$e]'));
        // Reset session safely on next turn after an error.
        await _closeActiveChatOnly();
      } finally {
        _isInferencing = false;
        await controller.close();
      }
    }));

    yield* controller.stream;
  }

  Stream<EngineStreamEvent> _streamViaLocalHttp({
    required String roomId,
    required String userText,
    Uint8List? compressedImageBytes,
    AtToolOption? mountedTool,
    List<SkillRecord> triggeredSkills = const [],
    String? intentHint,
  }) async* {
    yield const EngineStateHint(SpiritState.thinking);

    if (triggeredSkills.isNotEmpty) {
      yield EngineToolExecuted(
        toolPill: '📜 已按需載入 Skill：${triggeredSkills.map((s) => s.name).join('、')}',
      );
    }

    final client = http.Client();
    _activeHttpClient = client;
    _isInferencing = true;

    try {
      final endpoint = normalizeChatCompletionsUrl(_localHttpUrl);
      final systemPrompt = await _assembleSystemPrompt(roomId);
      final replay = await _loadReplayEntries(roomId);
      final nowStamp = _formatNowStamp(DateTime.now());
      final promptText = buildTurnUserPrompt(
        userText: userText,
        nowStamp: nowStamp,
        mountedTool: mountedTool,
        triggeredSkills: triggeredSkills,
        intentHint: intentHint,
      );

      final messages = <Map<String, dynamic>>[
        {'role': 'system', 'content': systemPrompt},
        for (final entry in replay)
          {'role': entry.isUser ? 'user' : 'assistant', 'content': entry.text},
        if (compressedImageBytes != null)
          {
            'role': 'user',
            'content': [
              {'type': 'text', 'text': promptText},
              {
                'type': 'image_url',
                'image_url': {
                  'url': 'data:image/jpeg;base64,${base64Encode(compressedImageBytes)}',
                },
              },
            ],
          }
        else
          {'role': 'user', 'content': promptText},
      ];

      final req = http.Request('POST', Uri.parse(endpoint))
        ..headers['Content-Type'] = 'application/json'
        ..body = jsonEncode({
          'model': _localHttpModel.trim().isEmpty
              ? 'gemma-4-e4b-heretic'
              : _localHttpModel.trim(),
          'messages': messages,
          'stream': true,
          'max_tokens': maxOutputTokens,
          'temperature': 0.7,
        });

      final streamedRes = await client.send(req).timeout(const Duration(seconds: 25));
      if (streamedRes.statusCode < 200 || streamedRes.statusCode >= 300) {
        final errBody = await streamedRes.stream.bytesToString();
        yield const EngineStateHint(SpiritState.stuck);
        yield EngineTextChunk(
          '⚠️ GGUF 通道回傳 HTTP ${streamedRes.statusCode}（$endpoint）：${errBody.trim()}',
        );
        return;
      }

      final replyBuffer = StringBuffer();
      final rawFallbackBuf = StringBuffer();

      await for (final line in streamedRes.stream
          .transform(utf8.decoder)
          .transform(const LineSplitter())) {
        if (_cancelRequested) break;
        final trimmed = line.trim();
        if (trimmed.isEmpty) continue;
        if (trimmed.startsWith('data:')) {
          final payload = trimmed.substring(5).trim();
          if (payload == '[DONE]') break;
          final token = _extractDeltaTextFromSseJson(payload);
          if (token.isNotEmpty) {
            replyBuffer.write(token);
            yield EngineTextChunk(token);
            final curStr = replyBuffer.toString();
            if (curStr.length >= 40) {
              final loopCheck = detectAndTrimRepetitionLoop(curStr);
              if (loopCheck.hasLoop) {
                _cancelRequested = true;
                yield const EngineToolExecuted(
                  toolPill: '⚡ 已偵測跳針並清洗 KV-Cache',
                );
                yield const EngineTextChunk(
                  '\n\n⚡ [偵測到重複跳針，已自動中斷並清洗上下文快取]',
                );
                break;
              }
            }
          }
        } else {
          rawFallbackBuf.writeln(trimmed);
        }
      }

      if (replyBuffer.isEmpty && rawFallbackBuf.isNotEmpty) {
        final nonStreamText = _extractDeltaTextFromSseJson(rawFallbackBuf.toString());
        if (nonStreamText.isNotEmpty) {
          replyBuffer.write(nonStreamText);
          yield EngineTextChunk(nonStreamText);
        }
      }

      if (mountedTool != null &&
          !_cancelRequested &&
          (mountedTool.toolName == 'lookup_profile' ||
              mountedTool.toolName == 'lookup_machine_tuning')) {
        final outcome = await toolRegistry.executeFallbackFromAtOption(
          option: mountedTool,
          userText: userText,
          roomId: roomId,
        );
        yield EngineToolExecuted(toolPill: outcome.toolPill, card: outcome.card);
      }

      final suggested = detectSuggestedRoom(userText);
      if (suggested != null) {
        yield EngineSuggestedRoom(suggested);
      }

      final full = replyBuffer.toString();
      if (full.contains('看不清') || full.contains('認不出')) {
        yield const EngineStateHint(SpiritState.stuck);
      } else {
        yield const EngineStateHint(SpiritState.idle);
      }
    } catch (e) {
      if (!_cancelRequested) {
        yield const EngineStateHint(SpiritState.stuck);
        yield EngineTextChunk(
          '\n[GGUF 通道連線失敗：$e]\n確認 Y700 / Termux 的 llama-server 已啟動且網址正確（$_localHttpUrl），或點頂部標題切換回通道 A (LiteRT)。',
        );
      } else {
        yield const EngineStateHint(SpiritState.idle);
      }
    } finally {
      _isInferencing = false;
      if (identical(_activeHttpClient, client)) {
        _activeHttpClient = null;
      }
      client.close();
    }
  }

  static String _extractDeltaTextFromSseJson(String rawJson) {
    try {
      final decoded = jsonDecode(rawJson);
      if (decoded is! Map) return '';
      final choices = decoded['choices'];
      if (choices is List && choices.isNotEmpty) {
        final first = choices.first;
        if (first is Map) {
          final delta = first['delta'];
          if (delta is Map && delta['content'] != null) {
            return delta['content'].toString();
          }
          final msg = first['message'];
          if (msg is Map && msg['content'] != null) {
            return msg['content'].toString();
          }
          if (first['text'] != null) {
            return first['text'].toString();
          }
        }
      }
    } catch (_) {}
    return '';
  }

  static String? detectSuggestedRoom(String text) {
    final afterVerbRoom = RegExp(
      r'(?:開|建|建立|新增|創)(?:一個|一間|設|立)?新?(?:工作)?房間(?:\s*(?:叫做|叫名為|叫作|名為|叫|是|為|：|:))*\s*([^\s，。！!？?]{2,16})',
    ).firstMatch(text);
    if (afterVerbRoom != null) return afterVerbRoom.group(1);

    final beforeRoom = RegExp(
      r'(?:幫我)?(?:開|建立|新增|創)(?:一個|一間)?\s*([^\s，。！!？?]{2,16}?)(?:的)?(?:新)?(?:工作)?房間',
    ).firstMatch(text);
    if (beforeRoom != null) {
      final candidate = beforeRoom.group(1)?.trim() ?? '';
      if (candidate.isNotEmpty &&
          !const {'一個', '一間', '新', '新的', '工作'}.contains(candidate)) {
        return candidate;
      }
    }
    return null;
  }

  @override
  Future<void> stopGeneration() async {
    _cancelRequested = true;
    _activeHttpClient?.close();
    _activeHttpClient = null;
    try {
      await _activeChat?.stopGeneration();
    } catch (_) {}
  }

  @override
  Future<void> compactRoomIfNeeded(String roomId) async {
    if (_model == null) return;

    await _mutex.synchronized(() async {
      final model = _model;
      if (model == null) return;

      final room = await db.getRoom(roomId);
      if (room == null) return;
      final messages = await db.getMessages(roomId);
      final unsummarized = messages
          .where((m) => m.id > room.summarizedUntilMsgId && (m.role == 'user' || m.role == 'model'))
          .toList();

      if (unsummarized.length < 10) return;

      // Preserve the last 4 turns (8 messages) starting on a user message.
      var keepFrom = unsummarized.length > 8 ? unsummarized.length - 8 : 0;
      while (keepFrom < unsummarized.length && unsummarized[keepFrom].role != 'user') {
        keepFrom++;
      }
      if (keepFrom <= 2) return;

      final toCompress = unsummarized.sublist(0, keepFrom);
      final newCursor = toCompress.last.id;

      final transcript = toCompress
          .map((m) => '${m.role == 'user' ? '文' : 'KODARI'}: ${m.content}')
          .join('\n');

      final prompt = '''
請將以下對話精簡濃縮為 150 字以內的重點備忘（繁體中文）。
鐵律：所有料號、數字、尺寸、日期、人名必須完全保留原貌，嚴禁四捨五入或腦補。
既有摘要：${room.rollingSummary.isEmpty ? '（無）' : room.rollingSummary}

待壓縮對話：
$transcript
''';

      InferenceChat? compactorChat;
      try {
        compactorChat = await model.openChat(
          supportImage: false,
          supportsFunctionCalls: false,
          enableThinking: false,
          modelType: ModelType.gemma4,
          maxOutputTokens: 256,
        );
        await compactorChat.addQueryChunk(Message.text(text: prompt, isUser: true));
        final buf = StringBuffer();
        await for (final r in compactorChat.generateChatResponseAsync()) {
          if (r is TextResponse) buf.write(r.token);
        }
        final summary = buf.toString().trim();
        if (summary.isNotEmpty) {
          await db.updateRoomSummary(
            roomId: roomId,
            summary: summary,
            untilMsgId: newCursor,
          );
          if (_activeRoomId == roomId) {
            await _closeActiveChatOnly();
          }
        }

        // Autonomous MEMORY.md distillation (1 new user fact if any, else NONE)
        await compactorChat.close();
        compactorChat = null;
        final traits = await db.getAllTraits();
        final existingMem = traits['MEMORY.md'] ?? '';
        final memPrompt = '''
從以下對話中，只抽「1 條」關於使用者的新長期事實、偏好、習慣或固定規則（30字以內，開頭用 - ）。
鐵律：不要重複既有記憶；沒有值得長期記住的新資訊就只回覆 NONE。
既有記憶：
$existingMem
對話：
$transcript
''';
        compactorChat = await model.openChat(
          supportImage: false,
          supportsFunctionCalls: false,
          enableThinking: false,
          modelType: ModelType.gemma4,
          maxOutputTokens: 80,
        );
        await compactorChat.addQueryChunk(Message.text(text: memPrompt, isUser: true));
        final memBuf = StringBuffer();
        await for (final r in compactorChat.generateChatResponseAsync()) {
          if (r is TextResponse) memBuf.write(r.token);
        }
        final distilled = memBuf.toString().trim();
        if (distilled.isNotEmpty && !distilled.toUpperCase().contains('NONE')) {
          await db.appendDistilledMemory(distilled);
        }
      } catch (e) {
        debugPrint('[Compactor] skip error: $e');
      } finally {
        await compactorChat?.close();
      }
    });
  }

  Future<String?> _runShortSinglePrompt(String prompt, {int maxTokens = 220}) async {
    if (_engineChannel == 'local_http' && _localHttpUrl.trim().isNotEmpty) {
      final client = http.Client();
      try {
        final endpoint = normalizeChatCompletionsUrl(_localHttpUrl);
        final res = await client
            .post(
              Uri.parse(endpoint),
              headers: const {'Content-Type': 'application/json'},
              body: jsonEncode({
                'model': _localHttpModel.trim().isEmpty
                    ? 'gemma-4-e4b-heretic'
                    : _localHttpModel.trim(),
                'messages': [
                  {'role': 'user', 'content': prompt},
                ],
                'stream': false,
                'max_tokens': maxTokens,
                'temperature': 0.3,
              }),
            )
            .timeout(const Duration(seconds: 20));
        if (res.statusCode >= 200 && res.statusCode < 300) {
          final txt = _extractDeltaTextFromSseJson(utf8.decode(res.bodyBytes)).trim();
          if (txt.isNotEmpty) return txt;
        }
      } catch (_) {
      } finally {
        client.close();
      }
      return null;
    }

    final model = _model;
    if (model == null) return null;
    InferenceChat? chat;
    try {
      chat = await model.openChat(
        supportImage: false,
        supportsFunctionCalls: false,
        enableThinking: false,
        modelType: ModelType.gemma4,
        maxOutputTokens: maxTokens,
      );
      await chat.addQueryChunk(Message.text(text: prompt, isUser: true));
      final buf = StringBuffer();
      await for (final r in chat.generateChatResponseAsync()) {
        if (r is TextResponse) buf.write(r.token);
      }
      final out = buf.toString().trim();
      return out.isEmpty ? null : out;
    } catch (_) {
      return null;
    } finally {
      await chat?.close();
    }
  }

  Future<int> _estimateRoomTokens(String roomId) async {
    final traits = await db.getAllTraits();
    final room = await db.getRoom(roomId);
    final todos = await db.getRoomTodos(roomId);
    final msgs = await db.getMessages(roomId);
    final minId = room?.summarizedUntilMsgId ?? 0;
    var active = msgs.where((m) => m.id > minId).toList();
    final lastDiv = active.lastIndexWhere((m) => m.role == 'divider');
    if (lastDiv != -1) active = active.sublist(lastDiv + 1);
    if (active.length > 8) active = active.sublist(active.length - 8);
    return TokenEstimator.estimateContextTokens(
      traitTexts: traits.values,
      roomNotes: todos.map((t) => t.text).join('\n'),
      rollingSummary: room?.rollingSummary ?? '',
      activeMessages: active.map(
        (m) => (content: m.content, hasImage: (m.imagePath ?? '').trim().isNotEmpty),
      ),
    );
  }

  @override
  Future<({bool compacted, String summary, int beforeTokens, int afterTokens})> forceCompactRoom(
    String roomId,
  ) async {
    return _mutex.synchronized(() async {
      final beforeTokens = await _estimateRoomTokens(roomId);
      final room = await db.getRoom(roomId);
      if (room == null) {
        return (compacted: false, summary: '', beforeTokens: beforeTokens, afterTokens: beforeTokens);
      }

      final messages = await db.getMessages(roomId);
      final unsummarized = messages
          .where((m) => m.id > room.summarizedUntilMsgId && (m.role == 'user' || m.role == 'model'))
          .toList();

      if (unsummarized.length < 2) {
        await _closeActiveChatOnly();
        final after = await _estimateRoomTokens(roomId);
        return (
          compacted: false,
          summary: room.rollingSummary,
          beforeTokens: beforeTokens,
          afterTokens: after,
        );
      }

      // Keep at most last 2 messages (latest round), compress everything older cleanly.
      final cutIndex = unsummarized.length > 2 ? unsummarized.length - 2 : unsummarized.length;
      final toCompress = unsummarized.sublist(0, cutIndex);
      final newCursor = toCompress.last.id;
      final transcript = toCompress
          .map((m) => '${m.role == 'user' ? '文' : 'KODARI'}: ${m.content}')
          .join('\n');

      String? summary = await _runShortSinglePrompt('''
請將以下對話精簡濃縮為 150 字以內的重點備忘（繁體中文）。
鐵律：所有料號、數字、尺寸、日期、人名必須完全保留原貌，嚴禁四捨五入或腦補。
既有摘要：${room.rollingSummary.isEmpty ? '（無）' : room.rollingSummary}

待壓縮對話：
$transcript
''');

      if (summary == null || summary.trim().isEmpty) {
        final bulletLines = toCompress
            .map((m) => m.content.replaceAll(RegExp(r'\s+'), ' ').trim())
            .where((t) => t.isNotEmpty)
            .map((t) => '• ${t.length > 42 ? '${t.substring(0, 42)}…' : t}')
            .take(5)
            .toList();
        final prefix = room.rollingSummary.trim().isEmpty ? '' : '${room.rollingSummary.trim()}\n';
        summary = '$prefix${bulletLines.join('\n')}'.trim();
        if (summary.length > 240) {
          summary = summary.substring(summary.length - 240);
        }
      }

      await db.updateRoomSummary(
        roomId: roomId,
        summary: summary,
        untilMsgId: newCursor,
      );
      await _closeActiveChatOnly();
      final afterTokens = await _estimateRoomTokens(roomId);
      return (
        compacted: true,
        summary: summary,
        beforeTokens: beforeTokens,
        afterTokens: afterTokens,
      );
    });
  }

  @override
  Future<({int reviewedCount, String lesson})> runIdleFlaggedReflection({
    bool forceManual = false,
  }) async {
    final pendingFlags = await db.getOperatorFlags(onlyUnreviewed: true);
    if (pendingFlags.isEmpty) {
      return (reviewedCount: 0, lesson: '');
    }

    if (!forceManual && _isInferencing) {
      return (reviewedCount: 0, lesson: '');
    }

    return _mutex.synchronized(() async {
      if (!forceManual && _isInferencing) {
        return (reviewedCount: 0, lesson: '');
      }
      final flags = await db.getOperatorFlags(onlyUnreviewed: true);
      if (flags.isEmpty) return (reviewedCount: 0, lesson: '');

      final reportItems = flags.take(6).map((f) {
        final note = f.userNote.isEmpty ? '' : '（備註：${f.userNote}）';
        final snippet = f.flaggedContent.replaceAll(RegExp(r'\s+'), ' ').trim();
        final shortSnippet = snippet.length > 70 ? '${snippet.substring(0, 70)}…' : snippet;
        return '- [${f.reason}]$note 原句：「$shortSnippet」';
      }).join('\n');

      final prompt = '''
## Operator Feedback Reports to Review (🚩)
以下是使用者在現場針對你回答表現不滿意並插旗糾錯的紀錄：
$reportItems

請簡短反省並萃取出「1 條」具體、可直接執行的工程/對話修正準則（32字以內，開頭必須用 `- [🚩自省] `，例如：`- [🚩自省] 算料前務必先扣除 3.5mm 鋸路再加 1.09 損耗`）。
''';

      var lesson = (await _runShortSinglePrompt(prompt, maxTokens: 96))?.trim() ?? '';
      if (lesson.isEmpty || lesson.contains('NONE')) {
        final first = flags.first;
        final extra = first.userNote.isNotEmpty ? '：${first.userNote}' : '';
        lesson = '- [🚩自省] ${first.reason}$extra（已自現場糾錯紀錄修正）';
      } else {
        lesson = lesson.split('\n').first.trim();
        if (!lesson.startsWith('-')) {
          lesson = '- [🚩自省] $lesson';
        }
      }

      await db.appendDistilledMemory(lesson);
      await db.markFlagsReviewed(
        ids: flags.map((f) => f.id).toList(),
        lesson: lesson,
      );
      await _closeActiveChatOnly();
      return (reviewedCount: flags.length, lesson: lesson);
    });
  }

  @override
  Future<void> dispose() async {
    await _closeActiveChatOnly();
    await _model?.close();
    _model = null;
  }
}
