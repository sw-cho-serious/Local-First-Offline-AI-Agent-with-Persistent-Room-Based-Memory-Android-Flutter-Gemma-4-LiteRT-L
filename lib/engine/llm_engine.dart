import 'dart:io';
import 'dart:typed_data';

import '../data/models.dart';
import '../tools/tool_registry.dart';

sealed class EngineStreamEvent {
  const EngineStreamEvent();
}

class EngineTextChunk extends EngineStreamEvent {
  const EngineTextChunk(this.token);
  final String token;
}

class EngineToolExecuted extends EngineStreamEvent {
  const EngineToolExecuted({
    this.toolPill,
    this.card,
  });

  final String? toolPill;
  final ActionCardData? card;
}

class EngineStateHint extends EngineStreamEvent {
  const EngineStateHint(this.state);
  final SpiritState state;
}

class EngineSuggestedRoom extends EngineStreamEvent {
  const EngineSuggestedRoom(this.suggestedName);
  final String suggestedName;
}

/// Abstract LLM Engine contract (Layer 1 isolation for future model/framework swaps).
abstract class LlmEngine {
  bool get isModelReady;
  bool get isFallbackMode;
  bool get useGpu;
  String get activeBackendLabel;
  String? get installedModelPath;
  Future<List<File>> scanAvailableModelFiles() async => const [];

  /// Dual-channel engine routing: `'litert'` (on-device .litertlm) vs `'local_http'` (Termux / Y700 GGUF).
  String get engineChannel;
  String get localHttpUrl;
  String get localHttpModel;
  int get effectiveMaxContextTokens;

  Future<void> configureEngineChannel({
    required String channel,
    String? httpUrl,
    String? httpModel,
  });

  Future<({bool ok, String message, List<String> models})> testLocalHttpConnection([
    String? urlOverride,
  ]);

  /// V2 Batch 2: Manual /compact compressor, 🚩 idle reflection, and critical RAM release.
  Future<({bool compacted, String summary, int beforeTokens, int afterTokens})> forceCompactRoom(
    String roomId,
  );

  Future<({int reviewedCount, String lesson})> runIdleFlaggedReflection({
    bool forceManual = false,
  });

  Future<void> handleCriticalMemoryPressure();

  Future<void> initializeEngine();

  /// Attempts to install from a local `.litertlm` file path and activate the model.
  Future<void> installFromFilePath(String path);

  /// Downloads the official Gemma 4 E4B `.litertlm` bundle from catalog.
  Future<void> installFromCatalog({required void Function(int percent) onProgress});

  /// Toggles GPU vs CPU backend and reloads the singleton model if loaded.
  Future<void> setUseGpu(bool gpu);

  /// Prewarms a lightweight ChatSession for [roomId] on input focus / camera tap.
  Future<void> prewarmRoomSession(String roomId);

  /// Sends a user message (with optional compressed JPEG image and optional @ tool).
  Stream<EngineStreamEvent> sendMessageStream({
    required String roomId,
    required String userText,
    Uint8List? compressedImageBytes,
    AtToolOption? mountedTool,
  });

  Future<void> stopGeneration();

  /// Background context compactor (runs only on room leave or 30s idle).
  Future<void> compactRoomIfNeeded(String roomId);

  /// Clears cached chat session so updated traits/skills take effect next turn.
  Future<void> invalidateSession();

  Future<void> dispose();
}
