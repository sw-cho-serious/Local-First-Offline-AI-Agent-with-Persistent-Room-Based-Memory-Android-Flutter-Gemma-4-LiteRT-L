import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_edge_ai/flutter_edge_ai.dart';
import 'package:flutter_edge_ai_litertlm/flutter_edge_ai_litertlm.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../core/async_mutex.dart';
import '../data/database_helper.dart';
import '../data/models.dart';
import '../tools/native_actions.dart';
import '../tools/tool_registry.dart';
import 'llm_engine.dart';

class GemmaLiteRtEngine implements LlmEngine {
  GemmaLiteRtEngine({
    required this.db,
    required this.toolRegistry,
  });

  static const int maxContextTokens = 3072;
  static const int maxOutputTokens = 512;

  final DatabaseHelper db;
  final ToolRegistry toolRegistry;
  final AsyncMutex _mutex = AsyncMutex();

  bool _sdkInitialized = false;
  InferenceModel? _model;
  InferenceChat? _activeChat;
  String? _activeRoomId;
  String? _activeToolKey;
  bool _useGpu = true;
  bool _isFallbackMode = false;
  String? _installedPath;
  bool _cancelRequested = false;

  Future<void>? _prewarmFuture;
  String? _prewarmRoomId;

  @override
  bool get isModelReady => _model != null;

  @override
  bool get isFallbackMode => _isFallbackMode;

  @override
  bool get useGpu => _useGpu;

  @override
  String? get installedModelPath => _installedPath;

  @override
  String get activeBackendLabel {
    if (_model != null) {
      final b = _model!.activeBackend;
      if (b == PreferredBackend.gpu) return 'Gemma-4-E4B • GPU';
      if (b == PreferredBackend.npu) return 'Gemma-4-E4B • NPU';
      return 'Gemma-4-E4B • CPU';
    }
    if (_isFallbackMode) return '離線規則／查表模式';
    return '未載入模型';
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
  }

  Future<String?> _findExistingModelFile() async {
    final candidates = <String>[
      '/storage/emulated/0/Download/gemma-4-E4B-it.litertlm',
      '/sdcard/Download/gemma-4-E4B-it.litertlm',
      '/storage/emulated/0/Download/Gemma-4-E4B-it.litertlm',
      '/storage/emulated/0/Download/gemma-4-e4b-it.litertlm',
    ];

    try {
      final extDir = await getExternalStorageDirectory();
      if (extDir != null) {
        candidates.add(p.join(extDir.path, 'gemma-4-E4B-it.litertlm'));
      }
      final docDir = await getApplicationDocumentsDirectory();
      candidates.add(p.join(docDir.path, 'gemma-4-E4B-it.litertlm'));
    } catch (_) {}

    for (final path in candidates) {
      try {
        if (await File(path).exists()) return path;
      } catch (_) {}
    }
    return null;
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
      maxTokens: maxContextTokens,
      preferredBackend: _useGpu ? PreferredBackend.gpu : PreferredBackend.cpu,
      supportImage: true,
      maxNumImages: 1,
      activationDataType: _useGpu ? ActivationDataType.float32 : null,
      maxConcurrentSessions: 2,
    );
  }

  @override
  Future<void> prewarmRoomSession(String roomId) {
    if (_model == null) return Future<void>.value();
    if (_activeRoomId == roomId && _activeChat != null && (_activeToolKey == null || _activeToolKey!.isEmpty)) {
      return Future<void>.value();
    }
    if (_prewarmFuture != null && _prewarmRoomId == roomId) {
      return _prewarmFuture!;
    }

    _prewarmRoomId = roomId;
    final future = _mutex.synchronized(() async {
      if (_model == null) return;
      if (_activeRoomId == roomId && _activeChat != null && (_activeToolKey == null || _activeToolKey!.isEmpty)) {
        return;
      }
      await _buildChatSessionInternal(roomId: roomId, toolName: null);
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
    if (chat != null) {
      try {
        await chat.close();
      } catch (_) {}
    }
  }

  Future<String> _assembleSystemPrompt(String roomId) async {
    final traits = await db.getAllTraits();
    final room = await db.getRoom(roomId);
    final rooms = await db.getRooms();
    final todos = await db.getRoomTodos(roomId);

    final soul = traits['SOUL.md'] ?? '';
    final voice = traits['VOICE.md'] ?? '';
    final user = traits['USER.md'] ?? '';
    final relationship = traits['relationship.md'] ?? '';
    final mood = traits['mood.md'] ?? '';

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

    if (activeRoomNames.isNotEmpty) {
      buf
        ..writeln()
        ..writeln('【現有活躍工作房間（嚴禁私自重複亂開同名房間）】')
        ..writeln(activeRoomNames);
    }

    buf
      ..writeln()
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
      ..writeln('【雙軌格式提醒】')
      ..writeln('1. 對使用者回話一律維持自然短句口語，禁稱「您」、禁列 1. 2. 3. 報告體。')
      ..writeln('2. 若呼出 data_write 工具，item_text 必須精簡具體；若查表查無參數，直接坦白說查無參數，絕對禁止編造尺寸或單重。');

    return buf.toString();
  }

  /// Fetches the last 4 complete turns starting cleanly at a user message.
  Future<List<Message>> _loadReplayMessages(String roomId) async {
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
        .map((m) => Message.text(
              text: m.imagePath != null && m.imagePath!.isNotEmpty
                  ? '[曾附上一張現場照片] ${m.content}'
                  : m.content,
              isUser: m.role == 'user',
            ))
        .toList();
  }

  Future<void> _buildChatSessionInternal({
    required String roomId,
    required String? toolName,
  }) async {
    final model = _model;
    if (model == null) return;

    await _closeActiveChatOnly();

    final systemPrompt = await _assembleSystemPrompt(roomId);
    final replay = await _loadReplayMessages(roomId);
    final tools = toolName != null ? <Tool>[ToolRegistry.buildSchema(toolName)] : const <Tool>[];

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
    _activeToolKey = toolName;
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

    // 2. Fallback deterministic path when 3.7GB model is not loaded yet.
    if (_model == null) {
      yield const EngineStateHint(SpiritState.working);
      if (mountedTool != null) {
        final outcome = await toolRegistry.executeFallbackFromAtOption(
          option: mountedTool,
          userText: userText,
          roomId: roomId,
        );
        yield EngineToolExecuted(toolPill: outcome.toolPill, card: outcome.card);
        yield EngineTextChunk(outcome.directReply ?? '處理好了。');
        yield const EngineStateHint(SpiritState.idle);
        return;
      }

      if (compressedImageBytes != null) {
        yield const EngineStateHint(SpiritState.stuck);
        yield const EngineTextChunk(
          '目前還沒載入 Gemma-4-E4B 模型本體（離線預覽模式）。照片我先幫你留在這間房，點氣泡可打 ⭐ 暫存，等模型匯入後就能看圖辨識。',
        );
        return;
      }

      final suggested = _detectSuggestedRoom(userText);
      if (suggested != null) {
        yield EngineSuggestedRoom(suggested);
      }
      yield EngineTextChunk(
        '收到「$userText」。目前處於離線預覽模式（還沒載入 Gemma 4 權重），但上面可以點 @ 工具卡直接查鋁料／調機／排日曆，或長按氣泡歸檔。',
      );
      yield const EngineStateHint(SpiritState.idle);
      return;
    }

    // 3. Real Gemma 4 LiteRT-LM inference serialized by AsyncMutex.
    final controller = StreamController<EngineStreamEvent>();
    unawaited(_mutex.synchronized(() async {
      try {
        controller.add(const EngineStateHint(SpiritState.thinking));

        final desiredTool = mountedTool?.toolName;
        if (_activeChat == null ||
            _activeRoomId != roomId ||
            _activeToolKey != desiredTool) {
          await _buildChatSessionInternal(roomId: roomId, toolName: desiredTool);
        }

        final chat = _activeChat!;
        final promptText = mountedTool != null
            ? '[已手動掛載工具 ${mountedTool.toolName}，請直接調用該工具處理後用 KODARI 口吻簡短回覆] $userText'
            : userText;

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
          }
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

        final suggested = _detectSuggestedRoom(userText);
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
        await controller.close();
      }
    }));

    yield* controller.stream;
  }

  String? _detectSuggestedRoom(String text) {
    final m = RegExp(r'開(?:一間|設|立)?新?(?:工作)?房間[叫名為：:\s]*([^\s，。！!？?]{2,16})').firstMatch(text);
    if (m != null) return m.group(1);
    return null;
  }

  @override
  Future<void> stopGeneration() async {
    _cancelRequested = true;
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
      } catch (e) {
        debugPrint('[Compactor] skip error: $e');
      } finally {
        await compactorChat?.close();
      }
    });
  }

  @override
  Future<void> dispose() async {
    await _closeActiveChatOnly();
    await _model?.close();
    _model = null;
  }
}
