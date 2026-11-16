import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_tts/flutter_tts.dart';
import 'package:shared_preferences/shared_preferences.dart';

class TtsVoiceOption {
  const TtsVoiceOption({required this.name, required this.locale});

  final String name;
  final String locale;
}

class TtsService extends ChangeNotifier {
  TtsService._();

  static final TtsService instance = TtsService._();

  static const _prefRateKey = 'hako_tts_rate';
  static const _prefPitchKey = 'hako_tts_pitch';
  static const _prefVoiceNameKey = 'hako_tts_voice_name';
  static const _prefVoiceLocaleKey = 'hako_tts_voice_locale';

  final FlutterTts _tts = FlutterTts();
  bool _initialized = false;
  bool _autoRead = false;
  bool _isSpeaking = false;
  int? _speakingMessageId;

  double _speechRate = 0.55;
  double _pitch = 1.0;
  String? _voiceName;
  String? _voiceLocale;

  bool get autoRead => _autoRead;
  bool get isSpeaking => _isSpeaking;
  int? get speakingMessageId => _speakingMessageId;
  double get speechRate => _speechRate;
  double get pitch => _pitch;
  String? get voiceName => _voiceName;
  String? get voiceLocale => _voiceLocale;

  Future<void> initialize() async {
    if (_initialized) return;
    _initialized = true;
    try {
      final prefs = await SharedPreferences.getInstance();
      _speechRate = prefs.getDouble(_prefRateKey) ?? 0.55;
      _pitch = prefs.getDouble(_prefPitchKey) ?? 1.0;
      _voiceName = prefs.getString(_prefVoiceNameKey);
      _voiceLocale = prefs.getString(_prefVoiceLocaleKey);

      await _tts.setLanguage('zh-TW');
      await _tts.setSpeechRate(_speechRate);
      await _tts.setVolume(1.0);
      await _tts.setPitch(_pitch);
      if (_voiceName != null &&
          _voiceName!.isNotEmpty &&
          _voiceLocale != null &&
          _voiceLocale!.isNotEmpty) {
        await _tts.setVoice({'name': _voiceName!, 'locale': _voiceLocale!});
      }

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

  Future<List<TtsVoiceOption>> getAvailableChineseVoices() async {
    await initialize();
    try {
      final raw = await _tts.getVoices;
      if (raw is! List) return const [];
      final all = <TtsVoiceOption>[];
      for (final item in raw) {
        if (item is Map) {
          final name = (item['name'] ?? '').toString().trim();
          final locale = (item['locale'] ?? '').toString().trim();
          if (name.isEmpty || locale.isEmpty) continue;
          final lower = locale.toLowerCase();
          if (lower.contains('zh') || lower.contains('cmn')) {
            all.add(TtsVoiceOption(name: name, locale: locale));
          }
        }
      }
      final tw = all
          .where((v) => v.locale.toLowerCase().contains('tw'))
          .toList();
      final result = tw.isNotEmpty ? tw : all;
      result.sort((a, b) => a.name.compareTo(b.name));
      return result;
    } catch (e) {
      debugPrint('[TTS] getVoices error: $e');
      return const [];
    }
  }

  Future<void> updateSettings({
    double? rate,
    double? pitch,
    TtsVoiceOption? voice,
    bool clearVoice = false,
  }) async {
    await initialize();
    final prefs = await SharedPreferences.getInstance();
    if (rate != null) {
      _speechRate = rate.clamp(0.25, 1.0);
      await prefs.setDouble(_prefRateKey, _speechRate);
      await _tts.setSpeechRate(_speechRate);
    }
    if (pitch != null) {
      _pitch = pitch.clamp(0.6, 1.5);
      await prefs.setDouble(_prefPitchKey, _pitch);
      await _tts.setPitch(_pitch);
    }
    if (clearVoice) {
      _voiceName = null;
      _voiceLocale = null;
      await prefs.remove(_prefVoiceNameKey);
      await prefs.remove(_prefVoiceLocaleKey);
      await _tts.setLanguage('zh-TW');
    } else if (voice != null) {
      _voiceName = voice.name;
      _voiceLocale = voice.locale;
      await prefs.setString(_prefVoiceNameKey, voice.name);
      await prefs.setString(_prefVoiceLocaleKey, voice.locale);
      await _tts.setVoice({'name': voice.name, 'locale': voice.locale});
    }
    notifyListeners();
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
    s = s.replaceAll(RegExp(r'https?://\S+'), '');
    s = s.replaceAll(RegExp(r'\*\*|\*|__|`|#{1,6}\s*'), '');
    s = s.replaceAll(RegExp(r'^\s*-\s*\[[xX\s]\]\s*', multiLine: true), '');
    s = s.replaceAll(RegExp(r'\s+'), ' ').trim();
    return s;
  }
}
