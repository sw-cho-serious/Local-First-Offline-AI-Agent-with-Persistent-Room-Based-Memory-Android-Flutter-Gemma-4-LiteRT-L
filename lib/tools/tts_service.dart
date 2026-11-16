import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_tts/flutter_tts.dart';

class TtsService extends ChangeNotifier {
  TtsService._();

  static final TtsService instance = TtsService._();

  final FlutterTts _tts = FlutterTts();
  bool _initialized = false;
  bool _autoRead = false;
  bool _isSpeaking = false;
  int? _speakingMessageId;

  bool get autoRead => _autoRead;
  bool get isSpeaking => _isSpeaking;
  int? get speakingMessageId => _speakingMessageId;

  Future<void> initialize() async {
    if (_initialized) return;
    _initialized = true;
    try {
      await _tts.setLanguage('zh-TW');
      await _tts.setSpeechRate(0.5);
      await _tts.setVolume(1.0);
      await _tts.setPitch(1.0);
      _tts.setCompletionHandler(() {
        _isSpeaking = false;
        _speakingMessageId = null;
        notifyListeners();
      });
      _tts.setCancelHandler(() {
        _isSpeaking = false;
        _speakingMessageId = null;
        notifyListeners();
      });
      _tts.setErrorHandler((_) {
        _isSpeaking = false;
        _speakingMessageId = null;
        notifyListeners();
      });
    } catch (e) {
      debugPrint('[TTS] initialize error: $e');
    }
  }

  void toggleAutoRead() {
    _autoRead = !_autoRead;
    if (!_autoRead && _isSpeaking) {
      unawaited(stop());
    } else {
      notifyListeners();
    }
  }

  Future<void> speak(String rawText, {int? messageId}) async {
    await initialize();
    final cleaned = cleanTextForSpeech(rawText);
    if (cleaned.isEmpty) return;

    try {
      if (_isSpeaking) {
        final sameMessage = messageId != null && _speakingMessageId == messageId;
        await stop();
        if (sameMessage) return;
      }
      _isSpeaking = true;
      _speakingMessageId = messageId;
      notifyListeners();
      await _tts.speak(cleaned);
    } catch (e) {
      debugPrint('[TTS] speak error: $e');
      _isSpeaking = false;
      _speakingMessageId = null;
      notifyListeners();
    }
  }

  Future<void> stop() async {
    try {
      await _tts.stop();
    } catch (_) {}
    _isSpeaking = false;
    _speakingMessageId = null;
    notifyListeners();
  }

  static String cleanTextForSpeech(String raw) {
    var s = raw;
    // Remove URLs
    s = s.replaceAll(RegExp(r'https?://\S+'), '');
    // Remove markdown formatting tokens
    s = s.replaceAll(RegExp(r'\*\*|\*|__|`|#{1,6}\s*'), '');
    // Remove checklist prefixes
    s = s.replaceAll(RegExp(r'^\s*-\s*\[[xX\s]\]\s*', multiLine: true), '');
    // Collapse excessive whitespace
    s = s.replaceAll(RegExp(r'\s+'), ' ').trim();
    return s;
  }
}
