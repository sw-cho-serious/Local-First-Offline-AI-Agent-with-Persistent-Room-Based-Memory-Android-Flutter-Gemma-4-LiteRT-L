import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Metadata for a customizable 6-track wheel shortcut action.
class WheelActionSpec {
  const WheelActionSpec({
    required this.id,
    required this.emoji,
    required this.label,
    required this.description,
    required this.icon,
    required this.isInPlace,
  });

  final String id;
  final String emoji;
  final String label;
  final String description;
  final IconData icon;
  final bool isInPlace;
}

/// Canonical 14-action pool & 6-slot hexagon configuration synced with Kotlin `GhostActionRegistry`.
class WheelActionRegistry {
  static const int slotCount = 6;

  static const List<String> defaultSlots = [
    'torch',
    'location_share',
    'clipboard_memo',
    'voice_memo',
    'latest_photo',
    'todo_peek',
  ];

  static const List<String> clockLabels = [
    '🕛 12點',
    '🕑 2點',
    '🕓 4點',
    '🕕 6點',
    '🕗 8點',
    '🕙 10點',
  ];

  static const List<WheelActionSpec> allActions = [
    WheelActionSpec(
      id: 'torch',
      emoji: '🔦',
      label: '手電筒',
      description: '硬體閃光燈直切（車斗/暗處看標籤）',
      icon: Icons.flashlight_on_rounded,
      isInPlace: true,
    ),
    WheelActionSpec(
      id: 'location_share',
      emoji: '📍',
      label: '報位置',
      description: 'GPS 秒抓連結進剪貼簿（LINE 一貼就送）',
      icon: Icons.location_on_rounded,
      isInPlace: true,
    ),
    WheelActionSpec(
      id: 'clipboard_memo',
      emoji: '📋',
      label: '貼入備忘',
      description: '剪貼簿文字直接存大廳待辦（不跳出 LINE）',
      icon: Icons.content_paste_go_rounded,
      isInPlace: true,
    ),
    WheelActionSpec(
      id: 'voice_memo',
      emoji: '🎙️',
      label: '語音速記',
      description: '講一句話自動轉文字寫進待辦（不開畫面）',
      icon: Icons.mic_rounded,
      isInPlace: true,
    ),
    WheelActionSpec(
      id: 'latest_photo',
      emoji: '📷',
      label: '存最新照',
      description: '一鍵撈相簿最新現場照進 ⭐ 標星暫存區',
      icon: Icons.add_a_photo_rounded,
      isInPlace: true,
    ),
    WheelActionSpec(
      id: 'todo_peek',
      emoji: '📌',
      label: '今日待辦',
      description: '原地懸浮便簽瞄急件・可直接在卡片打勾',
      icon: Icons.checklist_rounded,
      isInPlace: true,
    ),
    WheelActionSpec(
      id: 'next_routine',
      emoji: '🕒',
      label: '下個排程',
      description: '懸浮速覽最近排程倒數・+30分／暫停啟用',
      icon: Icons.schedule_rounded,
      isInPlace: true,
    ),
    WheelActionSpec(
      id: 'weather_douliu',
      emoji: '🌦️',
      label: '現地天氣',
      description: '斗六/現地溫度・降雨機率・風速幾級・日落',
      icon: Icons.wb_sunny_rounded,
      isInPlace: true,
    ),
    WheelActionSpec(
      id: 'quick_timer',
      emoji: '⏱️',
      label: '快速計時',
      description: '10/15/30/60 分鐘快速啟動系統倒數鬧鐘',
      icon: Icons.timer_rounded,
      isInPlace: true,
    ),
    WheelActionSpec(
      id: 'refresh_boards',
      emoji: '📡',
      label: '刷新戰情',
      description: '遠端敲鐘叫辦公室 Anti 工兵重刷雙戰情板',
      icon: Icons.radar_rounded,
      isInPlace: true,
    ),
    WheelActionSpec(
      id: 'calculator',
      emoji: '🧮',
      label: '計算機',
      description: '懸浮黑金小鍵盤・即時 mm ⇄ 台尺換算',
      icon: Icons.calculate_rounded,
      isInPlace: true,
    ),
    WheelActionSpec(
      id: 'open_cutting',
      emoji: '🛠️',
      label: '鋁料切料',
      description: '開啟 App 離線鋁料規範／調機公式查詢',
      icon: Icons.build_rounded,
      isInPlace: false,
    ),
    WheelActionSpec(
      id: 'open_rooms',
      emoji: '📂',
      label: '案場工單',
      description: '開啟 App 切換案場房間或看全案待辦',
      icon: Icons.folder_open_rounded,
      isInPlace: false,
    ),
    WheelActionSpec(
      id: 'open_text',
      emoji: '⌨️',
      label: '開啟對話',
      description: '開啟 App 並對準文字輸入框',
      icon: Icons.keyboard_rounded,
      isInPlace: false,
    ),
  ];

  static final Map<String, WheelActionSpec> _actionMap = {
    for (final a in allActions) a.id: a,
  };

  static WheelActionSpec? byId(String id) => _actionMap[id];

  static List<String> sanitizeSlots(List<String>? raw) {
    final result = <String>[];
    final seen = <String>{};
    if (raw != null) {
      for (final rawId in raw) {
        final id = rawId.trim();
        if (_actionMap.containsKey(id) && seen.add(id)) {
          if (result.length < slotCount) {
            result.add(id);
          }
        }
      }
    }
    for (final defId in defaultSlots) {
      if (result.length >= slotCount) break;
      if (seen.add(defId)) {
        result.add(defId);
      }
    }
    for (final meta in allActions) {
      if (result.length >= slotCount) break;
      if (seen.add(meta.id)) {
        result.add(meta.id);
      }
    }
    return result.take(slotCount).toList(growable: false);
  }

  /// Assigns [newActionId] into [slotIndex]; if already equipped in another slot, swaps the two positions.
  static List<String> swapOrAssignSlot(
    List<String> current,
    int slotIndex,
    String newActionId,
  ) {
    final sanitized = List<String>.from(sanitizeSlots(current));
    if (slotIndex < 0 || slotIndex >= slotCount) return sanitized;
    if (!_actionMap.containsKey(newActionId)) return sanitized;
    final existingIdx = sanitized.indexOf(newActionId);
    if (existingIdx == slotIndex) return sanitized;
    if (existingIdx >= 0) {
      final oldHere = sanitized[slotIndex];
      sanitized[slotIndex] = newActionId;
      sanitized[existingIdx] = oldHere;
    } else {
      sanitized[slotIndex] = newActionId;
    }
    return sanitizeSlots(sanitized);
  }
}

/// Persisted preferences for KODARI floating assistant & gesture behavior.
class FloatingOverlayPreferences {
  static const String keyInAppNub = 'hako_in_app_nub_enabled';
  static const String keyGhostOverlay = 'hako_ghost_overlay_enabled';
  static const String keyShakeWake = 'hako_shake_wake_enabled';
  static const String keyWheelSlots = 'hako_wheel_slots';
  static const String keyNubDockedRight = 'hako_nub_docked_right';
  static const String keyNubYFraction = 'hako_nub_y_fraction';
  static const String keyNubSkin = 'hako_nub_skin';

  static Future<bool> getInAppNubEnabled() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(keyInAppNub) ?? false;
  }

  static Future<void> setInAppNubEnabled(bool value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(keyInAppNub, value);
  }

  static Future<bool> getGhostOverlayEnabled() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(keyGhostOverlay) ?? false;
  }

  static Future<void> setGhostOverlayEnabled(bool value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(keyGhostOverlay, value);
  }

  /// Strictly defaults to OFF to prevent false triggers while driving trucks or moving around factory floors.
  static Future<bool> getShakeToWakeEnabled() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(keyShakeWake) ?? false;
  }

  static Future<void> setShakeToWakeEnabled(bool value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(keyShakeWake, value);
  }

  static Future<List<String>> getWheelSlots() async {
    final prefs = await SharedPreferences.getInstance();
    final saved = prefs.getStringList(keyWheelSlots);
    return WheelActionRegistry.sanitizeSlots(saved);
  }

  static Future<List<String>> setWheelSlots(List<String> slots) async {
    final sanitized = WheelActionRegistry.sanitizeSlots(slots);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList(keyWheelSlots, sanitized);
    return sanitized;
  }
}

/// Controller allowing external callers (e.g., Android Intent actions) to trigger the 7-track wheel.
class KodariFloatingNubController extends ChangeNotifier {
  bool _wheelOpen = false;
  int _wakeNonce = 0;

  bool get wheelOpen => _wheelOpen;
  int get wakeNonce => _wakeNonce;

  void openWheel() {
    if (_wheelOpen) return;
    _wheelOpen = true;
    _wakeNonce++;
    notifyListeners();
  }

  void closeWheel() {
    if (!_wheelOpen) return;
    _wheelOpen = false;
    notifyListeners();
  }

  void wakeAnimation() {
    _wakeNonce++;
    notifyListeners();
  }
}

/// KODARI Floating Assistant Nub:
/// - 6-frame squash-and-stretch breathing sprite (`assets/sprites/kodari_frame_0..5.png`)
/// - Auto edge-docking with semi-transparent 0%-CPU idle standby after 4 seconds
/// - Tap: expands the 6-puck symmetrical radial quick-action wheel with KODARI amber-gold aura
/// - Long press: haptic feedback + amber soundwave aura + invokes zero-permission system SpeechRecognizer
/// - Drag: free reposition with magnetic left/right edge snapping
class KodariFloatingNub extends StatefulWidget {
  const KodariFloatingNub({
    super.key,
    required this.controller,
    required this.isListeningVoice,
    required this.isGenerating,
    required this.flashlightOn,
    required this.onStartVoiceInput,
    required this.onOpenCamera,
    required this.onOpenTodos,
    required this.onOpenRooms,
    required this.onOpenNavigation,
    required this.onOpenCuttingHelper,
    required this.onToggleFlashlight,
    required this.onOpenTextInput,
    this.wheelSlots = WheelActionRegistry.defaultSlots,
    this.onExecuteAction,
    this.skin = 'kodari',
    this.voicePartialText = '',
    this.voiceRmsLevel = 0.0,
    this.onCancelVoice,
    this.onFinishVoice,
  });

  final KodariFloatingNubController controller;
  final bool isListeningVoice;
  final bool isGenerating;
  final bool flashlightOn;
  final Future<void> Function() onStartVoiceInput;
  final VoidCallback onOpenCamera;
  final VoidCallback onOpenTodos;
  final VoidCallback onOpenRooms;
  final VoidCallback onOpenNavigation;
  final VoidCallback onOpenCuttingHelper;
  final Future<void> Function() onToggleFlashlight;
  final VoidCallback onOpenTextInput;
  final List<String> wheelSlots;
  final void Function(String actionId)? onExecuteAction;

  /// Reserved skin slot ('kodari' default; expandable to 'xiaolan').
  final String skin;
  final String voicePartialText;
  final double voiceRmsLevel;
  final VoidCallback? onCancelVoice;
  final VoidCallback? onFinishVoice;

  @override
  State<KodariFloatingNub> createState() => _KodariFloatingNubState();
}

class _KodariFloatingNubState extends State<KodariFloatingNub>
    with TickerProviderStateMixin {
  static const List<String> _kodariFrames = [
    'assets/sprites/kodari_frame_0.png',
    'assets/sprites/kodari_frame_1.png',
    'assets/sprites/kodari_frame_2.png',
    'assets/sprites/kodari_frame_3.png',
    'assets/sprites/kodari_frame_4.png',
    'assets/sprites/kodari_frame_5.png',
  ];

  // KODARI amber/orange theme colors
  static const Color _kodariAmber = Color(0xFFF59E0B);
  static const Color _kodariOrange = Color(0xFFFB923C);
  static const Color _kodariGold = Color(0xFFFCD34D);

  Timer? _spriteTimer;
  Timer? _idleSleepTimer;
  int _frameIndex = 0;
  bool _isIdleDocked = false;
  bool _isDragging = false;
  bool _dockedRight = true;
  double _yFraction = 0.68;
  Offset? _dragOffset;

  late final AnimationController _wheelAnimController;
  late final AnimationController _waveAnimController;

  @override
  void initState() {
    super.initState();
    _wheelAnimController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 220),
    );
    _waveAnimController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 900),
    );
    widget.controller.addListener(_onControllerChanged);
    unawaited(_loadPosition());
    _wakeForBurst(const Duration(seconds: 4));
  }

  @override
  void didUpdateWidget(covariant KodariFloatingNub oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.controller != oldWidget.controller) {
      oldWidget.controller.removeListener(_onControllerChanged);
      widget.controller.addListener(_onControllerChanged);
    }
    if (widget.isListeningVoice != oldWidget.isListeningVoice) {
      if (widget.isListeningVoice) {
        _waveAnimController.repeat();
        _startSpriteLoop();
      } else {
        _waveAnimController.stop();
        _wakeForBurst(const Duration(seconds: 3));
      }
    }
    if (widget.isGenerating && !oldWidget.isGenerating) {
      _wakeForBurst(const Duration(seconds: 5));
    }
  }

  @override
  void dispose() {
    widget.controller.removeListener(_onControllerChanged);
    _spriteTimer?.cancel();
    _idleSleepTimer?.cancel();
    _wheelAnimController.dispose();
    _waveAnimController.dispose();
    super.dispose();
  }

  void _onControllerChanged() {
    if (!mounted) return;
    if (widget.controller.wheelOpen) {
      _wheelAnimController.forward(from: 0);
      _startSpriteLoop();
    } else {
      _wheelAnimController.reverse();
      _wakeForBurst(const Duration(seconds: 3));
    }
    setState(() {});
  }

  Future<void> _loadPosition() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final right = prefs.getBool(FloatingOverlayPreferences.keyNubDockedRight) ?? true;
      final yf = prefs.getDouble(FloatingOverlayPreferences.keyNubYFraction) ?? 0.68;
      if (!mounted) return;
      setState(() {
        _dockedRight = right;
        _yFraction = yf.clamp(0.12, 0.82);
      });
    } catch (_) {}
  }

  Future<void> _savePosition() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(FloatingOverlayPreferences.keyNubDockedRight, _dockedRight);
      await prefs.setDouble(FloatingOverlayPreferences.keyNubYFraction, _yFraction);
    } catch (_) {}
  }

  void _startSpriteLoop() {
    _isIdleDocked = false;
    _idleSleepTimer?.cancel();
    _spriteTimer ??= Timer.periodic(const Duration(milliseconds: 115), (_) {
      if (!mounted) return;
      setState(() {
        _frameIndex = (_frameIndex + 1) % _kodariFrames.length;
      });
    });
  }

  void _wakeForBurst(Duration activeWindow) {
    _startSpriteLoop();
    _idleSleepTimer?.cancel();
    _idleSleepTimer = Timer(activeWindow, () {
      if (!mounted) return;
      if (widget.controller.wheelOpen || widget.isListeningVoice || _isDragging) {
        return;
      }
      _spriteTimer?.cancel();
      _spriteTimer = null;
      setState(() {
        _frameIndex = 0;
        _isIdleDocked = true;
      });
    });
  }

  Widget _buildSpriteImage(double size, {int? fixedFrame}) {
    final idx = (fixedFrame ?? _frameIndex).clamp(0, _kodariFrames.length - 1);
    return Image.asset(
      _kodariFrames[idx],
      width: size,
      height: size,
      fit: BoxFit.contain,
      gaplessPlayback: true,
    );
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final maxW = constraints.maxWidth;
        final maxH = constraints.maxHeight;
        const nubBoxSize = 58.0;

        final defaultX = _dockedRight ? (maxW - nubBoxSize - 4) : 4.0;
        final defaultY = (_yFraction * maxH)
            .clamp(72.0, math.max<double>(72.0, maxH - 138.0))
            .toDouble();
        final pos = _dragOffset ?? Offset(defaultX, defaultY);

        return Stack(
          clipBehavior: Clip.none,
          children: [
            // 1. Voice listening soundwave overlay (Long-press mode)
            if (widget.isListeningVoice)
              Positioned.fill(
                child: _buildVoiceListeningOverlay(),
              ),

            // 2. 7-Puck radial wheel overlay (Tap mode)
            if (widget.controller.wheelOpen && !widget.isListeningVoice)
              Positioned.fill(
                child: _buildRadialWheelOverlay(),
              ),

            // 3. Edge-docked draggable KODARI floating nub
            if (!widget.controller.wheelOpen && !widget.isListeningVoice)
              AnimatedPositioned(
                duration: _isDragging
                    ? Duration.zero
                    : const Duration(milliseconds: 220),
                curve: Curves.easeOutCubic,
                left: pos.dx.clamp(0.0, math.max<double>(0.0, maxW - nubBoxSize)),
                top: pos.dy.clamp(60.0, math.max<double>(60.0, maxH - 126.0)),
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: () {
                    HapticFeedback.lightImpact();
                    widget.controller.openWheel();
                  },
                  onLongPress: () {
                    HapticFeedback.heavyImpact();
                    _wakeForBurst(const Duration(seconds: 5));
                    unawaited(widget.onStartVoiceInput());
                  },
                  onPanStart: (_) {
                    HapticFeedback.selectionClick();
                    _startSpriteLoop();
                    setState(() {
                      _isDragging = true;
                      _dragOffset = Offset(defaultX, defaultY);
                    });
                  },
                  onPanUpdate: (details) {
                    setState(() {
                      final cur = _dragOffset ?? Offset(defaultX, defaultY);
                      _dragOffset = Offset(
                        (cur.dx + details.delta.dx)
                            .clamp(0.0, math.max<double>(0.0, maxW - nubBoxSize))
                            .toDouble(),
                        (cur.dy + details.delta.dy)
                            .clamp(60.0, math.max<double>(60.0, maxH - 126.0))
                            .toDouble(),
                      );
                    });
                  },
                  onPanEnd: (_) {
                    final cur = _dragOffset ?? Offset(defaultX, defaultY);
                    final centerX = cur.dx + nubBoxSize / 2;
                    final dockRight = centerX >= maxW / 2;
                    final nextFrac = (cur.dy / math.max(1.0, maxH)).clamp(0.12, 0.82);
                    setState(() {
                      _isDragging = false;
                      _dockedRight = dockRight;
                      _yFraction = nextFrac;
                      _dragOffset = null;
                    });
                    unawaited(_savePosition());
                    _wakeForBurst(const Duration(seconds: 4));
                  },
                  child: AnimatedOpacity(
                    duration: const Duration(milliseconds: 260),
                    opacity: _isIdleDocked ? 0.56 : 1.0,
                    child: AnimatedContainer(
                      duration: const Duration(milliseconds: 220),
                      curve: Curves.easeOut,
                      width: nubBoxSize,
                      height: nubBoxSize,
                      transform: Matrix4.translationValues(
                        _isIdleDocked ? (_dockedRight ? 10.0 : -10.0) : 0.0,
                        0.0,
                        0.0,
                      ),
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        boxShadow: _isIdleDocked
                            ? const []
                            : [
                                BoxShadow(
                                  color: _kodariAmber.withValues(alpha: 0.36),
                                  blurRadius: 14,
                                  spreadRadius: 1,
                                ),
                              ],
                      ),
                      child: Center(
                        child: _buildSpriteImage(50),
                      ),
                    ),
                  ),
                ),
              ),
          ],
        );
      },
    );
  }

  VoidCallback _fallbackCallbackForAction(String actionId) {
    switch (actionId) {
      case 'torch':
        return () => unawaited(widget.onToggleFlashlight());
      case 'location_share':
        return widget.onOpenNavigation;
      case 'voice_memo':
        return () => unawaited(widget.onStartVoiceInput());
      case 'latest_photo':
        return widget.onOpenCamera;
      case 'todo_peek':
        return widget.onOpenTodos;
      case 'open_cutting':
        return widget.onOpenCuttingHelper;
      case 'open_rooms':
        return widget.onOpenRooms;
      case 'open_text':
      default:
        return widget.onOpenTextInput;
    }
  }

  Widget _buildRadialWheelOverlay() {
    final slotIds = WheelActionRegistry.sanitizeSlots(widget.wheelSlots);
    final tracks = slotIds.map((id) {
      final spec = WheelActionRegistry.byId(id) ?? WheelActionRegistry.allActions.first;
      final isTorch = spec.id == 'torch';
      return (
        icon: isTorch
            ? (widget.flashlightOn
                ? Icons.flashlight_on_rounded
                : Icons.flashlight_off_rounded)
            : spec.icon,
        emoji: spec.emoji,
        label: isTorch ? (widget.flashlightOn ? '手電筒 ON' : '手電筒') : spec.label,
        active: isTorch && widget.flashlightOn,
        onTap: widget.onExecuteAction != null
            ? () => widget.onExecuteAction!(spec.id)
            : _fallbackCallbackForAction(spec.id),
      );
    }).toList(growable: false);

    const wheelBoxSize = 316.0;
    const radius = 114.0;
    const puckWidth = 74.0;
    const puckHeight = 62.0;

    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () => widget.controller.closeWheel(),
      child: Container(
        color: Colors.black.withValues(alpha: 0.64),
        child: Center(
          child: ScaleTransition(
            scale: CurvedAnimation(
              parent: _wheelAnimController,
              curve: Curves.easeOutBack,
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                GestureDetector(
                  onTap: () {}, // Absorb taps inside wheel frame
                  child: SizedBox(
                    width: wheelBoxSize,
                    height: wheelBoxSize,
                    child: Stack(
                      alignment: Alignment.center,
                      children: [
                        // Outer amber tech glow ring (KODARI theme color)
                        Container(
                          width: 268,
                          height: 268,
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            color: const Color(0xFF151821).withValues(alpha: 0.72),
                            border: Border.all(
                              color: _kodariAmber.withValues(alpha: 0.45),
                              width: 1.5,
                            ),
                            boxShadow: [
                              BoxShadow(
                                color: _kodariAmber.withValues(alpha: 0.28),
                                blurRadius: 28,
                                spreadRadius: 2,
                              ),
                            ],
                          ),
                        ),
                        // Inner orbital accent ring
                        Container(
                          width: 122,
                          height: 122,
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            gradient: RadialGradient(
                              colors: [
                                _kodariAmber.withValues(alpha: 0.25),
                                _kodariOrange.withValues(alpha: 0.08),
                                Colors.transparent,
                              ],
                            ),
                            border: Border.all(
                              color: _kodariGold.withValues(alpha: 0.55),
                              width: 1.5,
                            ),
                          ),
                        ),
                        // 6 symmetrical orbital shortcut pucks
                        for (var i = 0; i < tracks.length; i++)
                          _buildWheelPuck(
                            track: tracks[i],
                            angleRad: -math.pi / 2 + (2 * math.pi * i / tracks.length),
                            radius: radius,
                            wheelBoxSize: wheelBoxSize,
                            puckWidth: puckWidth,
                            puckHeight: puckHeight,
                          ),
                        // Center KODARI hero medallion (Long press directly for voice too)
                        GestureDetector(
                          onTap: () => widget.controller.closeWheel(),
                          onLongPress: () {
                            HapticFeedback.heavyImpact();
                            widget.controller.closeWheel();
                            unawaited(widget.onStartVoiceInput());
                          },
                          child: Container(
                            width: 92,
                            height: 92,
                            decoration: BoxDecoration(
                              shape: BoxShape.circle,
                              color: const Color(0xFF171A23),
                              border: Border.all(
                                color: _kodariGold.withValues(alpha: 0.8),
                                width: 2,
                              ),
                              boxShadow: [
                                BoxShadow(
                                  color: _kodariAmber.withValues(alpha: 0.48),
                                  blurRadius: 18,
                                ),
                              ],
                            ),
                            child: Center(
                              child: _buildSpriteImage(68),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 14),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 7),
                  decoration: BoxDecoration(
                    color: const Color(0xFF161922).withValues(alpha: 0.94),
                    borderRadius: BorderRadius.circular(99),
                    border: Border.all(color: _kodariAmber.withValues(alpha: 0.55)),
                  ),
                  child: const Text(
                    '六軌可自訂捷徑 • 長按中央可達直接語音',
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                      color: Color(0xFFFDE68A),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildWheelPuck({
    required ({
      IconData icon,
      String emoji,
      String label,
      bool active,
      VoidCallback onTap,
    }) track,
    required double angleRad,
    required double radius,
    required double wheelBoxSize,
    required double puckWidth,
    required double puckHeight,
  }) {
    final cx = wheelBoxSize / 2 + radius * math.cos(angleRad);
    final cy = wheelBoxSize / 2 + radius * math.sin(angleRad);

    return Positioned(
      left: cx - puckWidth / 2,
      top: cy - puckHeight / 2,
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          borderRadius: BorderRadius.circular(16),
          onTap: () {
            HapticFeedback.selectionClick();
            widget.controller.closeWheel();
            track.onTap();
          },
          child: Container(
            width: puckWidth,
            height: puckHeight,
            decoration: BoxDecoration(
              color: track.active
                  ? _kodariAmber.withValues(alpha: 0.28)
                  : const Color(0xFF1B1F2A).withValues(alpha: 0.94),
              borderRadius: BorderRadius.circular(16),
              border: Border.all(
                color: track.active
                    ? _kodariGold
                    : _kodariAmber.withValues(alpha: 0.42),
                width: track.active ? 1.6 : 1.1,
              ),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withValues(alpha: 0.45),
                  blurRadius: 8,
                  offset: const Offset(0, 3),
                ),
              ],
            ),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(
                  track.icon,
                  size: 20,
                  color: track.active ? _kodariGold : const Color(0xFFFDE68A),
                ),
                const SizedBox(height: 4),
                Text(
                  track.label,
                  style: TextStyle(
                    fontSize: 10.5,
                    fontWeight: FontWeight.w600,
                    color: track.active ? Colors.white : const Color(0xFFE5E7EB),
                  ),
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildVoiceListeningOverlay() {
    final partial = widget.voicePartialText.trim();
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: widget.onCancelVoice,
      child: Container(
        color: Colors.black.withValues(alpha: 0.68),
        child: Center(
          child: GestureDetector(
            onTap: () {},
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                // Speech bubble header (live partial transcript)
                ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 300),
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
                    decoration: BoxDecoration(
                      color: const Color(0xFF171A23).withValues(alpha: 0.95),
                      borderRadius: BorderRadius.circular(20),
                      border: Border.all(color: _kodariAmber.withValues(alpha: 0.75), width: 1.5),
                      boxShadow: [
                        BoxShadow(
                          color: _kodariAmber.withValues(alpha: 0.35),
                          blurRadius: 20,
                        ),
                      ],
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Icon(Icons.mic_rounded, color: _kodariGold, size: 22),
                        const SizedBox(width: 8),
                        Flexible(
                          child: Text(
                            partial.isNotEmpty ? partial : '我在聽…\n請說指令',
                            style: const TextStyle(
                              fontSize: 15,
                              fontWeight: FontWeight.bold,
                              color: Colors.white,
                              height: 1.25,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 18),
                // Animated KODARI amber neon soundwave bars flanking the sprite
                SizedBox(
                  width: 300,
                  height: 120,
                  child: Stack(
                    alignment: Alignment.center,
                    children: [
                      AnimatedBuilder(
                        animation: _waveAnimController,
                        builder: (context, _) => CustomPaint(
                          size: const Size(300, 90),
                          painter: _AmberSoundwavePainter(
                            phase: _waveAnimController.value,
                            rmsLevel: widget.voiceRmsLevel,
                            amber: _kodariAmber,
                            orange: _kodariOrange,
                            gold: _kodariGold,
                          ),
                        ),
                      ),
                      Container(
                        width: 96,
                        height: 96,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          color: const Color(0xFF151821),
                          border: Border.all(color: _kodariGold, width: 2),
                          boxShadow: [
                            BoxShadow(
                              color: _kodariAmber.withValues(alpha: 0.55),
                              blurRadius: 24,
                              spreadRadius: 3,
                            ),
                          ],
                        ),
                        child: Center(child: _buildSpriteImage(72)),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 16),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 7),
                  decoration: BoxDecoration(
                    color: const Color(0xFF161922).withValues(alpha: 0.94),
                    borderRadius: BorderRadius.circular(99),
                    border: Border.all(color: _kodariAmber.withValues(alpha: 0.5)),
                  ),
                  child: const Text(
                    '語音聆聽中（系統原生辨識 • 零算力秒轉）',
                    style: TextStyle(fontSize: 12, color: Color(0xFFFDE68A), fontWeight: FontWeight.w600),
                  ),
                ),
                const SizedBox(height: 16),
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Material(
                      color: Colors.transparent,
                      child: InkWell(
                        borderRadius: BorderRadius.circular(99),
                        onTap: () {
                          HapticFeedback.selectionClick();
                          widget.onFinishVoice?.call();
                        },
                        child: Container(
                          padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 8),
                          decoration: BoxDecoration(
                            color: const Color(0xFF1F2937),
                            borderRadius: BorderRadius.circular(99),
                            border: Border.all(color: const Color(0xFF34D399), width: 1.2),
                          ),
                          child: const Text(
                            '✅ 說完了',
                            style: TextStyle(color: Colors.white, fontSize: 12.5, fontWeight: FontWeight.w600),
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Material(
                      color: Colors.transparent,
                      child: InkWell(
                        borderRadius: BorderRadius.circular(99),
                        onTap: () {
                          HapticFeedback.lightImpact();
                          widget.onCancelVoice?.call();
                        },
                        child: Container(
                          padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 8),
                          decoration: BoxDecoration(
                            color: const Color(0xFF1F2937),
                            borderRadius: BorderRadius.circular(99),
                            border: Border.all(color: const Color(0xFFFB7185), width: 1.2),
                          ),
                          child: const Text(
                            '✕ 取消',
                            style: TextStyle(color: Colors.white, fontSize: 12.5, fontWeight: FontWeight.w600),
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _AmberSoundwavePainter extends CustomPainter {
  _AmberSoundwavePainter({
    required this.phase,
    required this.rmsLevel,
    required this.amber,
    required this.orange,
    required this.gold,
  });

  final double phase;
  final double rmsLevel;
  final Color amber;
  final Color orange;
  final Color gold;

  @override
  void paint(Canvas canvas, Size size) {
    final cy = size.height / 2;
    const barCountSide = 10;
    const barWidth = 4.0;
    const spacing = 8.5;
    final ampBoost = 0.42 + rmsLevel.clamp(0.0, 1.0) * 0.95;

    for (var side in [-1, 1]) {
      for (var i = 0; i < barCountSide; i++) {
        final distFromCenter = 56.0 + i * spacing;
        final cx = size.width / 2 + side * distFromCenter;
        final wave = math.sin((phase * 2 * math.pi) - i * 0.55);
        final taper = 1.0 - (i / (barCountSide + 1));
        final h = (10.0 + 30.0 * ((wave + 1.0) * 0.5) * taper * ampBoost).clamp(8.0, 56.0);

        final color = Color.lerp(gold, orange, i / barCountSide)!
            .withValues(alpha: 0.35 + 0.6 * taper);
        final paint = Paint()
          ..color = color
          ..style = PaintingStyle.fill;

        final rect = RRect.fromRectAndRadius(
          Rect.fromCenter(center: Offset(cx, cy), width: barWidth, height: h),
          const Radius.circular(99),
        );
        canvas.drawRRect(rect, paint);
      }
    }
  }

  @override
  bool shouldRepaint(covariant _AmberSoundwavePainter oldDelegate) =>
      oldDelegate.phase != phase || oldDelegate.rmsLevel != rmsLevel;
}
