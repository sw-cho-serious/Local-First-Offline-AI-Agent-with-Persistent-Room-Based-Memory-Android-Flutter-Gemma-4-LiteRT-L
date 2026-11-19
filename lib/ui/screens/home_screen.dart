import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:image_picker/image_picker.dart';

import '../../core/image_compressor.dart';
import '../../core/token_estimator.dart';
import '../../data/database_helper.dart';
import '../../data/models.dart';
import '../../engine/llm_engine.dart';
import '../../sync/cloud_sync_service.dart';
import '../../tools/native_actions.dart';
import '../../tools/tool_registry.dart';
import '../../tools/tts_service.dart';
import '../widgets/action_card_widget.dart';
import '../widgets/album_scanner_sheet.dart';
import '../widgets/kodari_floating_nub.dart';
import '../widgets/modals.dart';
import '../widgets/photo_annotator_dialog.dart';
import '../widgets/spirit_avatar.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({
    super.key,
    required this.db,
    required this.engine,
    required this.syncService,
  });

  final DatabaseHelper db;
  final LlmEngine engine;
  final CloudSyncService syncService;

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> with WidgetsBindingObserver {
  final GlobalKey<ScaffoldState> _scaffoldKey = GlobalKey<ScaffoldState>();
  final TextEditingController _inputController = TextEditingController();
  final FocusNode _inputFocusNode = FocusNode();
  final ScrollController _scrollController = ScrollController();
  final ImagePicker _picker = ImagePicker();
  final KodariFloatingNubController _nubController = KodariFloatingNubController();

  List<RoomRecord> _rooms = [];
  String _currentRoomId = 'main';
  List<TodoItem> _currentTodos = [];
  List<ChatMessageRecord> _messages = [];
  Set<int> _flaggedMessageIds = {};
  int _pendingMemoCount = 0;
  int _contextTokens = 0;

  bool _taskDrawerExpanded = false;
  bool _atMenuVisible = false;
  bool _isGenerating = false;
  bool _sendingLock = false;
  bool _isListeningVoice = false;
  String _voicePartialText = '';
  double _voiceRmsLevel = 0.0;
  bool _inAppNubEnabled = false;
  bool _flashlightOn = false;
  List<String> _wheelSlots = WheelActionRegistry.defaultSlots;
  int? _expandedPinMessageId;
  String _streamingText = '';
  String? _streamingPill;
  ActionCardData? _streamingCard;
  SpiritState _liveSpiritState = SpiritState.idle;

  AtToolOption? _mountedTool;
  bool _isToolPinned = false;
  CompressedImageResult? _pendingImage;

  Timer? _idleTimer;
  Timer? _topToastTimer;
  String? _topToastMsg;
  StreamSubscription<EngineStreamEvent>? _streamSub;
  int _lastSeenSyncAtMs = 0;

  RoomRecord? get _currentRoom {
    for (final r in _rooms) {
      if (r.roomId == _currentRoomId) return r;
    }
    return _rooms.isNotEmpty ? _rooms.first : null;
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _lastSeenSyncAtMs = widget.syncService.lastSyncAtMs;
    widget.syncService.addListener(_onSyncServiceChanged);
    _loadAllData();
    unawaited(_recoverLostCameraImage());
    unawaited(TtsService.instance.initialize());
    unawaited(_initFloatingAndNativeHooks());
  }

  Future<void> _initFloatingAndNativeHooks() async {
    final inApp = await FloatingOverlayPreferences.getInAppNubEnabled();
    final ghost = await FloatingOverlayPreferences.getGhostOverlayEnabled();
    final shake = await FloatingOverlayPreferences.getShakeToWakeEnabled();
    final slots = await FloatingOverlayPreferences.getWheelSlots();
    if (mounted) {
      setState(() {
        _inAppNubEnabled = inApp;
        _wheelSlots = slots;
      });
    }
    unawaited(NativeActions.setGhostWheelSlots(slots));
    NativeActions.setSpeechUiCallbacks(
      onPartial: (partial) {
        if (!mounted || !_isListeningVoice) return;
        setState(() => _voicePartialText = partial);
      },
      onRms: (rms) {
        if (!mounted || !_isListeningVoice) return;
        setState(() => _voiceRmsLevel = rms);
      },
    );
    NativeActions.setOnGhostActionCallback(_handleGhostLaunchAction);
    NativeActions.setOnShakeWakeCallback(() async {
      if (!mounted || _isGenerating || _isListeningVoice) return;
      _showToast('🫨 搖晃喚醒語音指令');
      await _startVoiceInput();
    });
    unawaited(NativeActions.setShakeToWakeEnabled(shake));
    if (ghost) {
      unawaited(NativeActions.setGhostOverlayEnabled(true));
    }
    final pendingAction = await NativeActions.consumePendingLaunchAction();
    if (pendingAction != null && pendingAction.isNotEmpty) {
      unawaited(_handleGhostLaunchAction(pendingAction));
    }
  }

  Future<void> _reloadFloatingPrefs() async {
    final inApp = await FloatingOverlayPreferences.getInAppNubEnabled();
    final slots = await FloatingOverlayPreferences.getWheelSlots();
    if (!mounted) return;
    setState(() {
      _inAppNubEnabled = inApp;
      _wheelSlots = slots;
    });
  }

  Future<void> _handleGhostLaunchAction(String action) async {
    if (!mounted) return;
    if (_rooms.isEmpty) {
      await _loadAllData();
      if (!mounted) return;
    }
    if (action == 'com.weilong.xiaoliu.ACTION_OPEN_WHEEL') {
      _nubController.openWheel();
    } else if (action == 'com.weilong.xiaoliu.ACTION_VOICE_DIRECT') {
      if (!_isGenerating && !_isListeningVoice) {
        await _startVoiceInput();
      }
    } else if (action == 'com.weilong.xiaoliu.ACTION_OPEN_ROOMS') {
      _openRoomsFromNub();
    } else if (action == 'com.weilong.xiaoliu.ACTION_OPEN_TODOS') {
      _openTodosFromNub();
    } else if (action == 'com.weilong.xiaoliu.ACTION_OPEN_CAMERA') {
      _showPhotoPickerSheet();
    } else if (action == 'com.weilong.xiaoliu.ACTION_OPEN_NAV') {
      await _showNavigationQuickSheet();
    } else if (action == 'com.weilong.xiaoliu.ACTION_OPEN_CUTTING') {
      await showOfflineLookupModal(
        context: context,
        db: widget.db,
        onToast: _showToast,
      );
    } else if (action == 'com.weilong.xiaoliu.ACTION_OPEN_TEXT') {
      _inputFocusNode.requestFocus();
    } else if (action == 'com.weilong.xiaoliu.ACTION_OPEN_ROUTINES') {
      await showRoutineSchedulerModal(
        context: context,
        db: widget.db,
        onToast: _showToast,
      );
    } else if (action.startsWith('com.weilong.xiaoliu.ACTION_SPOKEN_TEXT::')) {
      final spoken = action
          .substring('com.weilong.xiaoliu.ACTION_SPOKEN_TEXT::'.length)
          .trim();
      if (spoken.isEmpty) return;
      final normalized = ToolRegistry.normalizeSpokenCommand(spoken);
      _inputController.text = normalized;
      _inputController.selection = TextSelection.fromPosition(
        TextPosition(offset: normalized.length),
      );
      await _sendMessage();
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Run deferred 🚩 flagged self-reflection when screen turns off / app goes to background
    if (state == AppLifecycleState.paused) {
      unawaited(widget.engine.runIdleFlaggedReflection(forceManual: false));
    } else if (state == AppLifecycleState.resumed) {
      unawaited(_refreshAfterBackgroundResume());
    }
  }

  Future<void> _refreshAfterBackgroundResume() async {
    if (!mounted) return;
    await _loadRoomContent(_currentRoomId);
    unawaited(widget.syncService.refreshPendingCount());
  }

  Future<void> _recoverLostCameraImage() async {
    try {
      final response = await _picker.retrieveLostData();
      if (response.isEmpty || response.file == null) return;
      final compressed = await ImageCompressor.compressAndSave(response.file!.path);
      if (!mounted) return;
      setState(() => _pendingImage = compressed);
      _showToast('📷 已救回剛才拍攝的照片 (${compressed.width}×${compressed.height})');
    } catch (_) {
      // Ignore on unsupported platforms or when no lost data exists.
    }
  }

  void _onSyncServiceChanged() {
    final latest = widget.syncService.lastSyncAtMs;
    if (latest > _lastSeenSyncAtMs) {
      _lastSeenSyncAtMs = latest;
      if (mounted) {
        unawaited(_loadRoomContent(_currentRoomId));
      }
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    widget.syncService.removeListener(_onSyncServiceChanged);
    NativeActions.setOnGhostActionCallback(null);
    NativeActions.setOnShakeWakeCallback(null);
    NativeActions.setSpeechUiCallbacks();
    _idleTimer?.cancel();
    _topToastTimer?.cancel();
    _streamSub?.cancel();
    _inputController.dispose();
    _inputFocusNode.dispose();
    _scrollController.dispose();
    _nubController.dispose();
    super.dispose();
  }

  Future<void> _loadAllData() async {
    final rooms = await widget.db.getRooms();
    if (rooms.isEmpty) return;
    if (!rooms.any((r) => r.roomId == _currentRoomId)) {
      _currentRoomId = rooms.first.roomId;
    }
    await _loadRoomContent(_currentRoomId, roomsOverride: rooms);
  }

  Future<void> _loadRoomContent(
    String roomId, {
    List<RoomRecord>? roomsOverride,
  }) async {
    final rooms = roomsOverride ?? await widget.db.getRooms();
    if (rooms.isEmpty) return;
    final room = rooms.firstWhere(
      (r) => r.roomId == roomId,
      orElse: () => rooms.first,
    );
    final todos = await widget.db.getRoomTodos(room.roomId);
    final msgs = await widget.db.getMessages(room.roomId);
    final flaggedIds = await widget.db.getRoomFlaggedMessageIds(room.roomId);
    final memo = await widget.db.getGlobalPendingMemo();
    final traits = await widget.db.getAllTraits();

    // Estimate active context tokens (Traits + notes + summary + replay after divider/cursor)
    final minId = room.summarizedUntilMsgId;
    var activeMsgs = msgs.where((m) => m.id > minId).toList();
    final lastDivIdx = activeMsgs.lastIndexWhere((m) => m.role == 'divider');
    if (lastDivIdx != -1) {
      activeMsgs = activeMsgs.sublist(lastDivIdx + 1);
    }
    if (activeMsgs.length > 8) {
      activeMsgs = activeMsgs.sublist(activeMsgs.length - 8);
    }
    final estimatedTokens = TokenEstimator.estimateContextTokens(
      traitTexts: traits.values,
      roomNotes: todos.map((t) => t.text).join('\n'),
      rollingSummary: room.rollingSummary,
      activeMessages: activeMsgs.map(
        (m) => (
          content: m.content,
          hasImage: (m.imagePath ?? '').trim().isNotEmpty,
        ),
      ),
    );

    if (!mounted) return;

    setState(() {
      _rooms = rooms;
      _currentRoomId = room.roomId;
      _currentTodos = todos;
      _messages = msgs;
      _flaggedMessageIds = flaggedIds;
      _pendingMemoCount = memo.totalCount;
      _contextTokens = estimatedTokens;
      _liveSpiritState = _isGenerating ? _liveSpiritState : room.avatarState;
    });
    _scrollToBottom();
  }

  Future<void> _uploadPhotoInBackground({
    required String roomId,
    required Uint8List bytes,
    String note = '',
    bool createTodo = false,
  }) async {
    if (!widget.syncService.isConfigured || bytes.isEmpty) return;
    final roomTitle = _rooms
        .firstWhere((r) => r.roomId == roomId, orElse: () => _rooms.first)
        .title;
    final res = await widget.syncService.uploadPhotoNonBlocking(
      roomId: roomId,
      roomTitle: roomTitle,
      jpegBytes: bytes,
      note: note,
      createTodo: createTodo,
    );
    if (!mounted) return;
    if (res.ok) {
      if (createTodo && _currentRoomId == roomId) {
        await _loadRoomContent(roomId);
      }
      _showToast(createTodo ? '☁️ 標註照已存入 Drive 並回填待辦' : '☁️ 照片已背景備份 Drive');
    }
  }

  void _scrollToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scrollController.hasClients) {
        _scrollController.animateTo(
          _scrollController.position.maxScrollExtent,
          duration: const Duration(milliseconds: 220),
          curve: Curves.easeOut,
        );
      }
    });
  }

  void _resetIdleTimer() {
    _idleTimer?.cancel();
    final roomId = _currentRoomId;
    _idleTimer = Timer(const Duration(seconds: 30), () {
      if (!_isGenerating) {
        unawaited(widget.engine.compactRoomIfNeeded(roomId));
      }
    });
  }

  Future<void> _switchRoom(String nextRoomId) async {
    if (_isGenerating) {
      _showToast('KODARI 還在處理這一輪，請稍等或按停止');
      return;
    }
    final previousRoomId = _currentRoomId;
    if (previousRoomId != nextRoomId) {
      unawaited(widget.engine.compactRoomIfNeeded(previousRoomId));
    }
    _taskDrawerExpanded = false;
    await _loadRoomContent(nextRoomId);
    _resetIdleTimer();
  }

  Future<void> _confirmDeleteRoom(RoomRecord room) async {
    if (room.isMain) {
      _showToast('主房間不可刪除');
      return;
    }
    if (_isGenerating) {
      _showToast('KODARI 還在處理這一輪，請稍等或按停止');
      return;
    }

    final confirmed = await showDialog<bool>(
      context: context,
      barrierColor: Colors.black.withValues(alpha: 0.72),
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF1A1E26),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(18),
          side: BorderSide(color: Colors.white.withValues(alpha: 0.14)),
        ),
        title: Text(
          '🗑️ 刪除「${room.title}」？',
          style: const TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.bold),
        ),
        content: const Text(
          '將移除此工作房間及其專屬待辦與對話紀錄（P2 雲端同步亦會保留刪除標記，避免另一支手機復活）。\n此動作無法從列表直接還原。',
          style: TextStyle(color: Color(0xFFD1D5DB), fontSize: 13, height: 1.45),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('取消', style: TextStyle(color: Color(0xFF9CA3AF))),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(
              backgroundColor: const Color(0xFFE11D48),
              foregroundColor: Colors.white,
            ),
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('確定刪除'),
          ),
        ],
      ),
    );

    if (confirmed != true) return;
    await widget.db.deleteRoom(room.roomId);
    widget.syncService.scheduleDebouncedPush();
    if (!mounted) return;

    if (_currentRoomId == room.roomId) {
      await _switchRoom('main');
    } else {
      await _loadRoomContent(_currentRoomId);
    }
    _showToast('🗑️ 已刪除房間「${room.title}」');
  }

  void _showRoomLongPressSheet(RoomRecord room) {
    if (room.isMain) return;
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: const Color(0xFF1C2029),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 14, 16, 18),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '房間操作：${room.title}',
                style: const TextStyle(color: Color(0xFF9CA3AF), fontSize: 12.5),
              ),
              const SizedBox(height: 12),
              if (!room.isArchived) ...[
                ListTile(
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                  tileColor: Colors.white.withValues(alpha: 0.05),
                  leading: const Text('😴', style: TextStyle(fontSize: 18)),
                  title: const Text('封存結案本房（變白睡覺）', style: TextStyle(color: Colors.white, fontSize: 14)),
                  onTap: () async {
                    Navigator.of(ctx).pop();
                    await widget.db.archiveRoom(room.roomId);
                    widget.syncService.scheduleDebouncedPush();
                    await _loadRoomContent(_currentRoomId);
                    _showToast('😴「${room.title}」已結案封存');
                  },
                ),
                const SizedBox(height: 8),
              ],
              ListTile(
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                tileColor: const Color(0xFFE11D48).withValues(alpha: 0.14),
                leading: const Text('🗑️', style: TextStyle(fontSize: 18)),
                title: const Text('刪除此工作房間', style: TextStyle(color: Color(0xFFFB7185), fontSize: 14, fontWeight: FontWeight.w600)),
                onTap: () {
                  Navigator.of(ctx).pop();
                  unawaited(_confirmDeleteRoom(room));
                },
              ),
            ],
          ),
        ),
      ),
    );
  }

  void _prewarmOnInteraction() {
    if (!_isGenerating) {
      unawaited(widget.engine.prewarmRoomSession(_currentRoomId));
    }
  }

  Future<void> _pickPhoto(ImageSource source) async {
    _prewarmOnInteraction();
    try {
      if (source == ImageSource.camera) {
        final granted = await NativeActions.ensureCameraPermission();
        if (!granted) {
          _showToast('📷 請允許相機權限後再拍照');
          return;
        }
      }
      final file = await _picker.pickImage(
        source: source,
        maxWidth: 1568,
        maxHeight: 1568,
        imageQuality: 85,
      );
      if (file == null) return;
      final compressed = await ImageCompressor.compressAndSave(file.path);
      if (!mounted) return;
      setState(() {
        _pendingImage = compressed;
      });
      _showToast('📷 已壓縮至 ${compressed.width}×${compressed.height} (~${compressed.estimatedTokens} tok)');
    } catch (e) {
      _showToast('選取圖片失敗：$e');
    }
  }

  void _showPhotoPickerSheet() {
    _prewarmOnInteraction();
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: const Color(0xFF1C2029),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) {
        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                ListTile(
                  leading: const Icon(Icons.camera_alt, color: Color(0xFFF59E0B)),
                  title: const Text('相機快拍（自動壓縮 <=896px）', style: TextStyle(color: Colors.white)),
                  onTap: () {
                    Navigator.of(ctx).pop();
                    _pickPhoto(ImageSource.camera);
                  },
                ),
                ListTile(
                  leading: const Icon(Icons.photo_library, color: Color(0xFF38BDF8)),
                  title: const Text('相簿選圖', style: TextStyle(color: Colors.white)),
                  onTap: () {
                    Navigator.of(ctx).pop();
                    _pickPhoto(ImageSource.gallery);
                  },
                ),
                const Divider(color: Color(0x1AFFFFFF)),
                ListTile(
                  leading: const Text('📏', style: TextStyle(fontSize: 20)),
                  title: const Text('拍照並直接畫線標尺寸', style: TextStyle(color: Color(0xFFFCD34D))),
                  onTap: () {
                    Navigator.of(ctx).pop();
                    unawaited(_annotatePhoto(source: ImageSource.camera));
                  },
                ),
                ListTile(
                  leading: const Text('📐', style: TextStyle(fontSize: 20)),
                  title: const Text('選圖畫線標尺寸', style: TextStyle(color: Color(0xFFF472B6))),
                  onTap: () {
                    Navigator.of(ctx).pop();
                    unawaited(_annotatePhoto(source: ImageSource.gallery));
                  },
                ),
                ListTile(
                  leading: const Text('🖼️', style: TextStyle(fontSize: 20)),
                  title: const Text('掃描近期相簿（多張快篩歸檔）', style: TextStyle(color: Color(0xFF22D3EE))),
                  onTap: () {
                    Navigator.of(ctx).pop();
                    unawaited(_openAlbumScanner());
                  },
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  Future<void> _saveAnnotatedPhotoResult(
    AnnotatedPhotoResult result,
    String targetRoomId,
  ) async {
    final labelsStr = result.labels.isNotEmpty ? result.labels.join('、') : '已畫線標註';
    final contentBuf = StringBuffer('📏 量測標註：$labelsStr');
    if (result.note.isNotEmpty) {
      contentBuf.write('\n備註：${result.note}');
    }
    final summaryLine = '📏 [$labelsStr]${result.note.isNotEmpty ? ' ${result.note}' : ''}';

    await widget.db.insertMessage(
      roomId: targetRoomId,
      role: 'user',
      content: contentBuf.toString(),
      imagePath: result.savedPath,
      toolPill: '📏 量測標註 (${result.width}×${result.height})',
    );
    await widget.db.upsertTodoItem(roomId: targetRoomId, itemText: summaryLine);
    widget.syncService.scheduleDebouncedPush();
    try {
      final bytes = await File(result.savedPath).readAsBytes();
      unawaited(_uploadPhotoInBackground(
        roomId: targetRoomId,
        bytes: bytes,
        note: summaryLine,
      ));
    } catch (_) {}
    await _loadRoomContent(_currentRoomId);
    _showToast('📏 標註照片已合成存入「${_rooms.firstWhere((r) => r.roomId == targetRoomId, orElse: () => _rooms.first).title}」');
  }

  Future<void> _annotatePhoto({
    String? existingPath,
    ImageSource? source,
    String initialNote = '',
  }) async {
    String? sourcePath = existingPath;
    if (sourcePath == null) {
      var chosenSource = source;
      if (chosenSource == null && mounted) {
        chosenSource = await showDialog<ImageSource>(
          context: context,
          builder: (ctx) => AlertDialog(
            backgroundColor: const Color(0xFF1A1E26),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(18),
              side: BorderSide(color: Colors.white.withValues(alpha: 0.14)),
            ),
            title: const Text('📏 選擇要標註尺寸的照片來源', style: TextStyle(color: Colors.white, fontSize: 15)),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                ListTile(
                  leading: const Icon(Icons.camera_alt, color: Color(0xFFF59E0B)),
                  title: const Text('現場拍照並標註', style: TextStyle(color: Colors.white)),
                  onTap: () => Navigator.of(ctx).pop(ImageSource.camera),
                ),
                ListTile(
                  leading: const Icon(Icons.photo_library, color: Color(0xFF38BDF8)),
                  title: const Text('從相簿選圖標註', style: TextStyle(color: Colors.white)),
                  onTap: () => Navigator.of(ctx).pop(ImageSource.gallery),
                ),
              ],
            ),
          ),
        );
      }
      if (chosenSource == null) return;
      if (chosenSource == ImageSource.camera) {
        final granted = await NativeActions.ensureCameraPermission();
        if (!granted) {
          _showToast('📷 請允許相機權限後再拍照');
          return;
        }
      }
      final picked = await _picker.pickImage(
        source: chosenSource,
        maxWidth: 1568,
        maxHeight: 1568,
        imageQuality: 90,
      );
      if (picked == null) return;
      sourcePath = picked.path;
    }

    if (!mounted) return;
    final result = await showPhotoAnnotatorDialog(
      context: context,
      imagePath: sourcePath,
      initialNote: initialNote,
    );
    if (result == null || !mounted) return;
    await _saveAnnotatedPhotoResult(result, _currentRoomId);
  }

  Future<void> _openAlbumScanner() async {
    await showAlbumScannerSheet(
      context: context,
      db: widget.db,
      currentRoomId: _currentRoomId,
      onToast: _showToast,
      onAnnotatedArchive: _saveAnnotatedPhotoResult,
      onBatchArchive: ({required targetRoomId, required items}) async {
        for (final item in items) {
          await widget.db.insertMessage(
            roomId: targetRoomId,
            role: 'user',
            content: item.caption,
            imagePath: item.compressed.savedPath,
            toolPill: '🖼️ 相簿批次歸檔',
          );
          unawaited(_uploadPhotoInBackground(
            roomId: targetRoomId,
            bytes: item.compressed.bytes,
            note: item.caption,
          ));
        }
        await widget.db.upsertTodoItem(
          roomId: targetRoomId,
          itemText: items.first.caption,
        );
        widget.syncService.scheduleDebouncedPush();
        await _loadRoomContent(_currentRoomId);
        final targetTitle = _rooms
            .firstWhere((r) => r.roomId == targetRoomId, orElse: () => _rooms.first)
            .title;
        _showToast('🖼️ 已將 ${items.length} 張相簿照片壓縮歸檔至「$targetTitle」');
      },
    );
  }

  Future<void> _startVoiceInput() async {
    if (_isGenerating || _isListeningVoice) return;
    final granted = await NativeActions.ensureMicrophonePermission();
    if (!mounted) return;
    if (!granted) {
      _showToast('🎙️ 請先允許麥克風權限以使用無彈窗語音');
      return;
    }
    _prewarmOnInteraction();
    setState(() {
      _voicePartialText = '';
      _voiceRmsLevel = 0.0;
      _isListeningVoice = true;
    });
    try {
      final spoken = await NativeActions.listenSpeech();
      if (!mounted) return;
      if (spoken == null || spoken.trim().isEmpty) {
        _showToast('🎙️ 沒有收到語音內容');
        return;
      }
      final normalized = ToolRegistry.normalizeSpokenCommand(spoken);
      _inputController.text = normalized;
      _inputController.selection = TextSelection.fromPosition(
        TextPosition(offset: normalized.length),
      );
      await _sendMessage();
    } finally {
      if (mounted) {
        setState(() {
          _isListeningVoice = false;
          _voicePartialText = '';
          _voiceRmsLevel = 0.0;
        });
      }
    }
  }

  Future<void> _runCompactCommand() async {
    _showToast('✂️ 正在壓縮本房對話並刷新 KV-Cache...');
    final res = await widget.engine.forceCompactRoom(_currentRoomId);
    await widget.db.insertMessage(
      roomId: _currentRoomId,
      role: 'model',
      content: res.compacted
          ? '✂️ 已手動執行對話濃縮壓縮（Token 佔用：${res.beforeTokens} → ${res.afterTokens}），KV-Cache 已重新保持清爽！'
          : '✂️ 本房目前已經是最新精簡狀態（${res.beforeTokens} tok），已順手清空過期 KV-Cache。',
      toolPill: '✂️ /compact 壓縮完成',
    );
    widget.syncService.scheduleDebouncedPush();
    await _loadRoomContent(_currentRoomId);
  }

  Future<void> _handleInAppWheelAction(String actionId) async {
    switch (actionId) {
      case 'torch':
        await _toggleFlashlightQuick();
        return;
      case 'location_share':
        _showToast('🛰️ 正在抓取現場 GPS 座標…');
        final loc = await NativeActions.getCurrentLocation();
        if (!mounted) return;
        if (!loc.ok || loc.lat == null || loc.lng == null) {
          _showToast('⚠️ 無法取得 GPS：${loc.reason ?? ''}');
          return;
        }
        final copyText = '📍 現場座標\n座標：${loc.coordsText}\n地圖：${loc.googleMapsUrl}';
        await Clipboard.setData(ClipboardData(text: copyText));
        await widget.db.upsertTodoItem(
          roomId: _currentRoomId,
          itemText: '📍 [報位] ${loc.coordsText} ${loc.googleMapsUrl}',
        );
        widget.syncService.scheduleDebouncedPush();
        await _loadRoomContent(_currentRoomId);
        _showToast('📍 座標已複製到剪貼簿並記進待辦');
        return;
      case 'clipboard_memo':
        final clipData = await Clipboard.getData(Clipboard.kTextPlain);
        final raw = clipData?.text?.trim() ?? '';
        if (!mounted) return;
        if (raw.isEmpty) {
          _showToast('📋 剪貼簿目前沒有文字');
          return;
        }
        await widget.db.upsertTodoItem(
          roomId: _currentRoomId,
          itemText: raw.replaceAll('\n', ' / '),
        );
        widget.syncService.scheduleDebouncedPush();
        await _loadRoomContent(_currentRoomId);
        _showToast('📋 已從剪貼簿存入待辦');
        return;
      case 'voice_memo':
        if (!_isGenerating && !_isListeningVoice) {
          await _startVoiceInput();
        }
        return;
      case 'latest_photo':
        _showPhotoPickerSheet();
        return;
      case 'todo_peek':
        _openTodosFromNub();
        return;
      case 'next_routine':
        await showRoutineSchedulerModal(
          context: context,
          db: widget.db,
          onToast: _showToast,
        );
        return;
      case 'quick_timer':
        await _showQuickTimerPickerDialog();
        return;
      case 'weather_douliu':
        _inputController.text = '@查網 我目前所在地今日天氣風速';
        await _sendMessage();
        return;
      case 'refresh_boards':
        _inputController.text = '@找支援 REFRESH_ALL_BOARDS 刷新雙戰情板';
        await _sendMessage();
        return;
      case 'open_cutting':
      case 'calculator':
        await showOfflineLookupModal(
          context: context,
          db: widget.db,
          onToast: _showToast,
        );
        return;
      case 'open_rooms':
        _openRoomsFromNub();
        return;
      case 'open_text':
        _inputFocusNode.requestFocus();
        return;
    }
  }

  Future<void> _showQuickTimerPickerDialog() async {
    await showDialog<void>(
      context: context,
      barrierColor: Colors.black.withValues(alpha: 0.72),
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF1A1E26),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(18),
          side: BorderSide(color: const Color(0xFFF59E0B).withValues(alpha: 0.45)),
        ),
        title: const Text('⏱️ 快速現場倒數計時', style: TextStyle(color: Color(0xFFFCD34D), fontSize: 15)),
        content: Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            for (final mins in const [10, 15, 30, 60])
              OutlinedButton(
                style: OutlinedButton.styleFrom(
                  foregroundColor: Colors.white,
                  side: BorderSide(color: const Color(0xFFF59E0B).withValues(alpha: 0.55)),
                ),
                onPressed: () async {
                  Navigator.of(ctx).pop();
                  await NativeActions.setTimerOrAlarm(
                    mode: 'timer',
                    minutes: mins,
                    message: 'KODARI 現場計時 ($mins分)',
                  );
                  _showToast('⏱️ 已設定 $mins 分鐘倒數計時');
                },
                child: Text(mins == 60 ? '1 小時' : '$mins 分鐘'),
              ),
          ],
        ),
      ),
    );
  }

  Future<void> _toggleFlashlightQuick() async {
    final nextOn = !_flashlightOn;
    final res = await NativeActions.setFlashlight(nextOn);
    if (!mounted) return;
    if (res['ok'] == true) {
      setState(() => _flashlightOn = nextOn);
      _showToast(nextOn ? '🔦 手電筒已開啟' : '🔦 手電筒已關閉');
    } else {
      _showToast('⚠️ 手電筒切換失敗：${res['reason'] ?? ''}');
    }
  }

  void _openRoomsFromNub() {
    if (_scaffoldKey.currentState?.hasDrawer ?? false) {
      _scaffoldKey.currentState?.openDrawer();
      return;
    }
    setState(() => _taskDrawerExpanded = !_taskDrawerExpanded);
    _showToast('📂 左側即為工作房間總覽');
  }

  void _openTodosFromNub() {
    showPendingMemoInboxModal(
      context: context,
      db: widget.db,
      onJumpToRoom: _switchRoom,
      onDataChanged: () {
        widget.syncService.scheduleDebouncedPush();
        _loadRoomContent(_currentRoomId);
      },
      onToast: _showToast,
    );
  }

  Future<void> _showNavigationQuickSheet() async {
    final destCtrl = TextEditingController();
    await showDialog<void>(
      context: context,
      barrierColor: Colors.black.withValues(alpha: 0.72),
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF1A1E26),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(18),
          side: BorderSide(color: const Color(0xFFF59E0B).withValues(alpha: 0.45)),
        ),
        title: const Text('🧭 導航與現場 GPS 標點', style: TextStyle(color: Colors.white, fontSize: 15)),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            SizedBox(
              width: double.infinity,
              child: OutlinedButton.icon(
                style: OutlinedButton.styleFrom(
                  foregroundColor: const Color(0xFF6EE7B7),
                  side: BorderSide(color: const Color(0xFF10B981).withValues(alpha: 0.5)),
                  padding: const EdgeInsets.symmetric(vertical: 10),
                ),
                icon: const Icon(Icons.my_location, size: 18),
                label: const Text('📍 抓取目前 GPS 座標存入本房'),
                onPressed: () async {
                  Navigator.of(ctx).pop();
                  _showToast('📡 正在定位衛星 GPS 座標...');
                  final loc = await NativeActions.getCurrentLocation();
                  if (!mounted) return;
                  if (!loc.ok || loc.lat == null || loc.lng == null) {
                    _showToast('⚠️ 無法取得 GPS：${loc.reason ?? ''}');
                    return;
                  }
                  final line = '📍 現場定位：${loc.coordsText} ${loc.googleMapsUrl}';
                  await widget.db.upsertTodoItem(roomId: _currentRoomId, itemText: line);
                  await widget.db.insertMessage(
                    roomId: _currentRoomId,
                    role: 'model',
                    content: '已記下目前衛星座標（誤差約 ${loc.accuracy?.round() ?? '-'}m）：\n$line',
                    toolPill: '📍 GPS 標點完成',
                    cardJson: ActionCardData(
                      type: 'location',
                      badge: '📍 離線衛星定位',
                      title: loc.coordsText,
                      rows: ['誤差：${loc.accuracy?.round() ?? '-'} 公尺 • 已寫入本房待辦'],
                      buttonLabel: '🗺️ 在 Google Maps 查看',
                      payload: {'lat': loc.lat, 'lng': loc.lng, 'label': _currentRoom?.title ?? '現場'},
                    ).toJsonString(),
                  );
                  widget.syncService.scheduleDebouncedPush();
                  await _loadRoomContent(_currentRoomId);
                  _showToast('📍 GPS 座標已存進本房');
                },
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: destCtrl,
              autofocus: true,
              style: const TextStyle(color: Colors.white, fontSize: 13.5),
              decoration: InputDecoration(
                hintText: '輸入目的地或案場（如 台北車站）',
                hintStyle: const TextStyle(color: Color(0xFF6B7280), fontSize: 12.5),
                filled: true,
                fillColor: const Color(0xFF0E1014),
                border: OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
              ),
              onSubmitted: (v) async {
                final q = v.trim();
                if (q.isEmpty) return;
                Navigator.of(ctx).pop();
                await NativeActions.openMapQuery(q);
              },
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('取消', style: TextStyle(color: Color(0xFF9CA3AF))),
          ),
          ElevatedButton.icon(
            style: ElevatedButton.styleFrom(
              backgroundColor: const Color(0xFFF59E0B),
              foregroundColor: const Color(0xFF111317),
            ),
            icon: const Icon(Icons.directions, size: 17),
            label: const Text('Google Maps 導航'),
            onPressed: () async {
              final q = destCtrl.text.trim();
              if (q.isEmpty) {
                _showToast('請輸入目的地名稱或路名');
                return;
              }
              Navigator.of(ctx).pop();
              await NativeActions.openMapQuery(q);
            },
          ),
        ],
      ),
    );
    destCtrl.dispose();
  }

  Future<void> _sendMessage() async {
    if (_isGenerating) {
      await widget.engine.stopGeneration();
      return;
    }
    if (_sendingLock) return;

    var text = _inputController.text.trim();
    final image = _pendingImage;
    final usedTool = _mountedTool;
    if (text.isEmpty && image == null && usedTool == null) return;

    // V2 Batch 2 slash self-rescue commands: /compact & /reflect
    if (usedTool == null && image == null) {
      final lower = text.toLowerCase();
      if (lower == '/compact' || text == '@壓縮') {
        _inputController.clear();
        await _runCompactCommand();
        return;
      }
      if (lower == '/reflect' || text == '@自省') {
        _inputController.clear();
        final res = await widget.engine.runIdleFlaggedReflection(forceManual: true);
        if (res.reviewedCount > 0) {
          await widget.db.insertMessage(
            roomId: _currentRoomId,
            role: 'model',
            content: '🚩 已手動自省檢討 ${res.reviewedCount} 筆現場插旗糾錯，並將準則永久沉澱進 MEMORY.md：\n${res.lesson}',
            toolPill: '🚩 自省寫入 MEMORY.md',
          );
          widget.syncService.scheduleDebouncedPush();
          await _loadRoomContent(_currentRoomId);
          _showToast('🚩 已寫入 MEMORY.md（共檢討 ${res.reviewedCount} 筆）');
        } else {
          _showToast('🚩 目前沒有尚未反省的插旗紀錄');
        }
        return;
      }
    }

    // Intercept interactive P3 tools so tapping Send launches native UI right away.
    final leadingMatch =
        usedTool == null ? ToolRegistry.matchLeadingAtTool(text) : null;
    final activeOpt = usedTool ?? leadingMatch?.option;
    final cleanArg = leadingMatch?.cleanText ?? text;
    if (activeOpt != null) {
      if (activeOpt.toolName == 'photo_annotate') {
        _inputController.clear();
        final imgPath = image?.savedPath;
        setState(() {
          _pendingImage = null;
          _atMenuVisible = false;
          if (!_isToolPinned) _mountedTool = null;
        });
        await _annotatePhoto(existingPath: imgPath, initialNote: cleanArg);
        return;
      }
      if (activeOpt.toolName == 'album_scan') {
        _inputController.clear();
        setState(() {
          _atMenuVisible = false;
          if (!_isToolPinned) _mountedTool = null;
        });
        await _openAlbumScanner();
        return;
      }
    }

    if (text.isEmpty && image == null) return;
    _sendingLock = true;
    try {
      if (text.isEmpty && image != null) {
        text = '辨識這張現場照片中的料號、尺寸、數量或異常重點';
      }

      _inputController.clear();
      _idleTimer?.cancel();

      final displayText = usedTool != null ? '${usedTool.atLabel} $text' : text;

      // Persist user message immediately
      await widget.db.insertMessage(
        roomId: _currentRoomId,
        role: 'user',
        content: displayText,
        imagePath: image?.savedPath,
      );
      widget.syncService.scheduleDebouncedPush();

      final roomIdForTurn = _currentRoomId;
      final Uint8List? imgBytes = image?.bytes;
      if (imgBytes != null && imgBytes.isNotEmpty) {
        unawaited(_uploadPhotoInBackground(
          roomId: roomIdForTurn,
          bytes: imgBytes,
          note: text,
        ));
      }

      setState(() {
        _pendingImage = null;
        _atMenuVisible = false;
        if (!_isToolPinned) {
          _mountedTool = null;
        }
        _isGenerating = true;
        _streamingText = '';
        _streamingPill = null;
        _streamingCard = null;
        _liveSpiritState = SpiritState.thinking;
      });
      await _loadRoomContent(roomIdForTurn);

      final replyBuf = StringBuffer();
      String? capturedPill;
      ActionCardData? capturedCard;
      String? suggestedRoomName;
      var finalState = SpiritState.idle;

      try {
        await for (final event in widget.engine.sendMessageStream(
          roomId: roomIdForTurn,
          userText: text,
          compressedImageBytes: imgBytes,
          mountedTool: usedTool,
        )) {
          if (!mounted) break;
          switch (event) {
            case EngineTextChunk(:final token):
              replyBuf.write(token);
              setState(() {
                _streamingText = replyBuf.toString();
              });
              _scrollToBottom();
            case EngineToolExecuted(:final toolPill, :final card):
              if (toolPill != null) capturedPill = toolPill;
              if (card != null) capturedCard = card;
              setState(() {
                _streamingPill = capturedPill;
                _streamingCard = capturedCard;
              });
            case EngineStateHint(:final state):
              finalState = state;
              setState(() {
                _liveSpiritState = state;
              });
            case EngineSuggestedRoom(:final suggestedName):
              suggestedRoomName = suggestedName;
          }
        }
      } catch (e) {
        replyBuf.write('\n[錯誤：$e]');
        finalState = SpiritState.stuck;
      }

      final finalReply = replyBuf.toString().trim().isEmpty
          ? '（無輸出內容）'
          : replyBuf.toString().trim();

      if (suggestedRoomName != null && capturedCard == null) {
        capturedCard = ActionCardData(
          type: 'create_room',
          badge: '🏗️ 建議開設新工作房間',
          title: suggestedRoomName,
          rows: ['確認建立後將自動為「$suggestedRoomName」配置獨立上下文與專屬小精靈。'],
          buttonLabel: '➕ 建立「$suggestedRoomName」工作房間',
          payload: {'roomName': suggestedRoomName},
        );
      }

      await widget.db.insertMessage(
        roomId: roomIdForTurn,
        role: 'model',
        content: finalReply,
        toolPill: capturedPill,
        cardJson: capturedCard?.toJsonString(),
      );
      await widget.db.updateRoomAvatarState(roomIdForTurn, finalState);
      widget.syncService.scheduleDebouncedPush();

      if (!mounted) return;
      setState(() {
        _isGenerating = false;
        _streamingText = '';
        _streamingPill = null;
        _streamingCard = null;
        _liveSpiritState = finalState;
      });
      await _loadRoomContent(roomIdForTurn);
      _resetIdleTimer();
      if (TtsService.instance.autoRead && finalReply != '（無輸出內容）') {
        unawaited(TtsService.instance.speak(finalReply));
      }
    } finally {
      _sendingLock = false;
    }
  }

  Future<void> _insertNewTopicDivider() async {
    await widget.db.insertMessage(
      roomId: _currentRoomId,
      role: 'divider',
      content: '新話題（前文不帶入推論）',
    );
    widget.syncService.scheduleDebouncedPush();
    await _loadRoomContent(_currentRoomId);
    _showToast('✂️ 已開啟新話題，SQLite 歷史完整保留');
  }

  void _showMessageActionSheet(ChatMessageRecord msg) {
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: const Color(0xFF1C2029),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) {
        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 14, 16, 18),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  msg.content.length > 32
                      ? '${msg.content.substring(0, 32)}...'
                      : msg.content,
                  style: const TextStyle(fontSize: 12, color: Color(0xFF9CA3AF)),
                ),
                const SizedBox(height: 12),
                ListTile(
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                  tileColor: Colors.white.withValues(alpha: 0.05),
                  leading: const Text('📌', style: TextStyle(fontSize: 18)),
                  title: const Text('收入本房待辦清單', style: TextStyle(color: Colors.white, fontSize: 14)),
                  onTap: () async {
                    Navigator.of(ctx).pop();
                    final short = msg.content.length > 60
                        ? '${msg.content.substring(0, 60)}...'
                        : msg.content;
                    await widget.db.upsertTodoItem(roomId: _currentRoomId, itemText: short);
                    widget.syncService.scheduleDebouncedPush();
                    await _loadRoomContent(_currentRoomId);
                    _showToast('📌 已追加至本房待辦清單');
                  },
                ),
                const SizedBox(height: 8),
                ListTile(
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                  tileColor: Colors.white.withValues(alpha: 0.05),
                  leading: const Text('⭐', style: TextStyle(fontSize: 18)),
                  title: Text(
                    msg.isStarred ? '取消標星暫存' : '標星暫存（鬼畫符／待確認照片）',
                    style: const TextStyle(color: Colors.white, fontSize: 14),
                  ),
                  onTap: () async {
                    Navigator.of(ctx).pop();
                    await widget.db.setMessageStarred(msg.id, !msg.isStarred);
                    widget.syncService.scheduleDebouncedPush();
                    await _loadRoomContent(_currentRoomId);
                    _showToast(!msg.isStarred ? '⭐ 已標星暫存，可於右上角 📋 查看' : '已取消星號');
                  },
                ),
                if (msg.role == 'user') ...[
                  const SizedBox(height: 8),
                  ListTile(
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                    tileColor: const Color(0xFFF59E0B).withValues(alpha: 0.12),
                    leading: const Text('📂', style: TextStyle(fontSize: 18)),
                    title: const Text('歸檔到指定房間…', style: TextStyle(color: Color(0xFFFDE68A), fontSize: 14)),
                    trailing: const Icon(Icons.chevron_right, color: Color(0xFFF59E0B)),
                    onTap: () {
                      Navigator.of(ctx).pop();
                      _showArchiveRoomPicker(msg);
                    },
                  ),
                ],
                  if (msg.imagePath != null &&
                      msg.imagePath!.isNotEmpty &&
                      File(msg.imagePath!).existsSync()) ...[
                    const SizedBox(height: 8),
                    ListTile(
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                      tileColor: const Color(0xFFF472B6).withValues(alpha: 0.12),
                      leading: const Text('📏', style: TextStyle(fontSize: 18)),
                      title: const Text('在此照片上畫線標尺寸', style: TextStyle(color: Color(0xFFF9A8D4), fontSize: 14)),
                      onTap: () {
                        Navigator.of(ctx).pop();
                        unawaited(_annotatePhoto(existingPath: msg.imagePath!));
                      },
                    ),
                  ],
                  const SizedBox(height: 8),
                  ListTile(
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                    tileColor: const Color(0xFF10B981).withValues(alpha: 0.12),
                    leading: const Text('📤', style: TextStyle(fontSize: 18)),
                    title: const Text('轉傳到 LINE／系統分享（含圖片）', style: TextStyle(color: Color(0xFF6EE7B7), fontSize: 14)),
                    onTap: () async {
                      Navigator.of(ctx).pop();
                      final res = await NativeActions.shareToLine(
                        text: msg.content,
                        imagePath: msg.imagePath,
                      );
                      if (!res.ok) {
                        _showToast('⚠️ 無法開啟系統分享：${res.error ?? ''}');
                      }
                    },
                  ),
                const SizedBox(height: 8),
                ListTile(
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                  tileColor: Colors.white.withValues(alpha: 0.05),
                  leading: const Icon(Icons.copy, color: Color(0xFF9CA3AF), size: 20),
                  title: const Text('複製文字', style: TextStyle(color: Colors.white, fontSize: 14)),
                  onTap: () async {
                    Navigator.of(ctx).pop();
                    await Clipboard.setData(ClipboardData(text: msg.content));
                    _showToast('📋 已複製訊息文字');
                  },
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  void _showArchiveRoomPicker(ChatMessageRecord msg) {
    final targetRooms = _rooms.where((r) => r.roomId != _currentRoomId).toList();
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: const Color(0xFF1C2029),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) {
        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  '📂 選擇目標房間（將轉存並自動染上該房代表色）',
                  style: TextStyle(color: Color(0xFFFCD34D), fontSize: 13, fontWeight: FontWeight.w600),
                ),
                const SizedBox(height: 12),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    for (final r in targetRooms)
                      ActionChip(
                        backgroundColor: const Color(0xFF111317),
                        side: BorderSide(color: parseHexColor(r.colorHex).withValues(alpha: 0.6)),
                        avatar: CircleAvatar(backgroundColor: parseHexColor(r.colorHex), radius: 6),
                        label: Text(r.title, style: const TextStyle(color: Colors.white, fontSize: 12.5)),
                        onPressed: () async {
                          Navigator.of(ctx).pop();
                          await widget.db.archiveUserMessageToRoom(
                            messageId: msg.id,
                            targetRoomId: r.roomId,
                            addAsTodo: true,
                          );
                          widget.syncService.scheduleDebouncedPush();
                          await _loadRoomContent(_currentRoomId);
                          _showToast('📂 已染上「${r.title}」顏色並轉存');
                        },
                      ),
                    ActionChip(
                      backgroundColor: const Color(0xFFF59E0B).withValues(alpha: 0.15),
                      side: BorderSide(color: const Color(0xFFF59E0B).withValues(alpha: 0.5)),
                      label: const Text('＋ 新建房間', style: TextStyle(color: Color(0xFFFCD34D), fontSize: 12.5)),
                      onPressed: () async {
                        Navigator.of(ctx).pop();
                        final created = await showCreateRoomDialog(context: context, db: widget.db);
                        if (created != null) {
                          await widget.db.archiveUserMessageToRoom(
                            messageId: msg.id,
                            targetRoomId: created.roomId,
                            addAsTodo: true,
                          );
                          widget.syncService.scheduleDebouncedPush();
                          await _loadRoomContent(_currentRoomId);
                          _showToast('📂 已建房並轉存至「${created.title}」');
                        }
                      },
                    ),
                  ],
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  void _showToast(String message) {
    if (!mounted) return;
    _topToastTimer?.cancel();
    setState(() => _topToastMsg = message);
    _topToastTimer = Timer(const Duration(milliseconds: 2200), () {
      if (mounted) {
        setState(() => _topToastMsg = null);
      }
    });
  }

  void _openFullImage(String path) {
    showDialog<void>(
      context: context,
      barrierColor: Colors.black.withValues(alpha: 0.9),
      builder: (ctx) => Dialog(
        backgroundColor: Colors.transparent,
        insetPadding: const EdgeInsets.all(12),
        child: Stack(
          children: [
            InteractiveViewer(
              child: ClipRRect(
                borderRadius: BorderRadius.circular(12),
                child: Image.file(File(path), fit: BoxFit.contain),
              ),
            ),
            Positioned(
              left: 8,
              top: 8,
              child: Row(
                children: [
                  ElevatedButton.icon(
                    style: ElevatedButton.styleFrom(
                      backgroundColor: Colors.black87,
                      foregroundColor: const Color(0xFFFCD34D),
                    ),
                    icon: const Icon(Icons.straighten, size: 17),
                    label: const Text('標註尺寸', style: TextStyle(fontSize: 12.5)),
                    onPressed: () {
                      Navigator.of(ctx).pop();
                      unawaited(_annotatePhoto(existingPath: path));
                    },
                  ),
                  const SizedBox(width: 8),
                  ElevatedButton.icon(
                    style: ElevatedButton.styleFrom(
                      backgroundColor: Colors.black87,
                      foregroundColor: const Color(0xFF6EE7B7),
                    ),
                    icon: const Icon(Icons.share, size: 17),
                    label: const Text('傳LINE', style: TextStyle(fontSize: 12.5)),
                    onPressed: () {
                      Navigator.of(ctx).pop();
                      unawaited(NativeActions.shareToLine(text: '', imagePath: path));
                    },
                  ),
                ],
              ),
            ),
            Positioned(
              right: 8,
              top: 8,
              child: IconButton(
                style: IconButton.styleFrom(backgroundColor: Colors.black54),
                icon: const Icon(Icons.close, color: Colors.white),
                onPressed: () => Navigator.of(ctx).pop(),
              ),
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final room = _currentRoom;
    if (room == null) {
      return const Scaffold(
        backgroundColor: Color(0xFF111317),
        body: Center(child: CircularProgressIndicator(color: Color(0xFFF59E0B))),
      );
    }

    return LayoutBuilder(
      builder: (context, constraints) {
        final isWideFold = constraints.maxWidth >= 600;
        return Scaffold(
          key: _scaffoldKey,
          backgroundColor: const Color(0xFF111317),
          drawer: isWideFold ? null : Drawer(
            width: 288,
            backgroundColor: const Color(0xFF15181E),
            child: _buildSidebarPanel(closeDrawerOnTap: true),
          ),
          body: SafeArea(
            child: Stack(
              children: [
                Row(
                  children: [
                    if (isWideFold)
                      Container(
                        width: 268,
                        decoration: BoxDecoration(
                          color: const Color(0xFF15181E),
                          border: Border(
                            right: BorderSide(color: Colors.white.withValues(alpha: 0.1)),
                          ),
                        ),
                        child: _buildSidebarPanel(closeDrawerOnTap: false),
                      ),
                    Expanded(
                      child: Column(
                        children: [
                          _buildTopBar(room, showMenuBtn: !isWideFold),
                          if (_currentTodos.isNotEmpty) _buildTaskSummaryStrip(),
                          Expanded(child: _buildChatFeed(room)),
                          if (_atMenuVisible) _buildAtPopover(),
                          _buildInputBar(),
                        ],
                      ),
                    ),
                  ],
                ),
                if (_inAppNubEnabled || _isListeningVoice || _nubController.wheelOpen)
                  Positioned.fill(
                    child: KodariFloatingNub(
                      controller: _nubController,
                      isListeningVoice: _isListeningVoice,
                      isGenerating: _isGenerating,
                      flashlightOn: _flashlightOn,
                      wheelSlots: _wheelSlots,
                      onExecuteAction: (id) => unawaited(_handleInAppWheelAction(id)),
                      onStartVoiceInput: _startVoiceInput,
                      onOpenCamera: _showPhotoPickerSheet,
                      onOpenTodos: _openTodosFromNub,
                      onOpenRooms: _openRoomsFromNub,
                      onOpenNavigation: _showNavigationQuickSheet,
                      onOpenCuttingHelper: () => showOfflineLookupModal(
                        context: context,
                        db: widget.db,
                        onToast: _showToast,
                      ),
                      onToggleFlashlight: _toggleFlashlightQuick,
                      onOpenTextInput: () => _inputFocusNode.requestFocus(),
                      voicePartialText: _voicePartialText,
                      voiceRmsLevel: _voiceRmsLevel,
                      onCancelVoice: () => unawaited(NativeActions.cancelSpeechListening()),
                      onFinishVoice: () => unawaited(NativeActions.stopSpeechListening()),
                    ),
                  ),
                if (_topToastMsg != null)
                  Positioned(
                    top: 10,
                    left: 14,
                    right: 14,
                    child: Center(
                      child: GestureDetector(
                        onTap: () => setState(() => _topToastMsg = null),
                        child: Container(
                          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
                          decoration: BoxDecoration(
                            color: const Color(0xFFF3F4F6),
                            borderRadius: BorderRadius.circular(12),
                            border: Border.all(color: const Color(0xFFF59E0B), width: 1.5),
                            boxShadow: const [
                              BoxShadow(
                                color: Colors.black54,
                                blurRadius: 10,
                                offset: Offset(0, 4),
                              ),
                            ],
                          ),
                          child: Text(
                            _topToastMsg!,
                            textAlign: TextAlign.center,
                            style: const TextStyle(
                              fontSize: 12.5,
                              fontWeight: FontWeight.w700,
                              color: Color(0xFF111317),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _buildSidebarPanel({required bool closeDrawerOnTap}) {
    final activeRooms = _rooms.where((r) => !r.isArchived).toList();
    final archivedRooms = _rooms.where((r) => r.isArchived).toList();

    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'HAKO 工作房間',
              style: TextStyle(fontSize: 15, fontWeight: FontWeight.bold, color: Colors.white),
            ),
            const SizedBox(height: 2),
            const Text(
              '一隻 KODARI，顧一間案場',
              style: TextStyle(fontSize: 12, color: Color(0xFF9CA3AF)),
            ),
            const Divider(color: Color(0x1AFFFFFF), height: 20),
            Expanded(
              child: ListView(
                children: [
                  for (final r in activeRooms)
                    _buildRoomTile(r, closeDrawerOnTap: closeDrawerOnTap),
                  if (archivedRooms.isNotEmpty) ...[
                    const Padding(
                      padding: EdgeInsets.only(top: 10, bottom: 6, left: 4),
                      child: Text(
                        '已封存案場（睡覺收工）',
                        style: TextStyle(fontSize: 11.5, color: Color(0xFF6B7280)),
                      ),
                    ),
                    for (final r in archivedRooms)
                      _buildRoomTile(r, closeDrawerOnTap: closeDrawerOnTap),
                  ],
                ],
              ),
            ),
            const SizedBox(height: 8),
            SizedBox(
              width: double.infinity,
              child: OutlinedButton(
                style: OutlinedButton.styleFrom(
                  backgroundColor: const Color(0xFFF59E0B).withValues(alpha: 0.12),
                  side: BorderSide(color: const Color(0xFFF59E0B).withValues(alpha: 0.4)),
                  foregroundColor: const Color(0xFFFCD34D),
                  padding: const EdgeInsets.symmetric(vertical: 11),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                ),
                onPressed: () async {
                  if (closeDrawerOnTap) Navigator.of(context).pop();
                  final created = await showCreateRoomDialog(context: context, db: widget.db);
                  if (created != null) {
                    widget.syncService.scheduleDebouncedPush();
                    await _switchRoom(created.roomId);
                  }
                },
                child: const Text('＋ 建立新工作房間', style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600)),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildRoomTile(RoomRecord r, {required bool closeDrawerOnTap}) {
    final isActive = r.roomId == _currentRoomId;
    return FutureBuilder<List<TodoItem>>(
      future: widget.db.getRoomTodos(r.roomId),
      builder: (context, snap) {
        final todos = snap.data ?? const [];
        final pct = todos.isEmpty ? null : (DatabaseHelper.calculateProgress(todos) * 100).round();
        return GestureDetector(
          onTap: () async {
            if (closeDrawerOnTap) Navigator.of(context).pop();
            await _switchRoom(r.roomId);
          },
          onLongPress: r.isMain
              ? null
              : () {
                  if (closeDrawerOnTap) Navigator.of(context).pop();
                  _showRoomLongPressSheet(r);
                },
          child: Container(
            margin: const EdgeInsets.only(bottom: 8),
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: isActive
                  ? const Color(0xFFF59E0B).withValues(alpha: 0.12)
                  : const Color(0xFF1B1F27),
              borderRadius: BorderRadius.circular(14),
              border: Border.all(
                color: isActive
                    ? const Color(0xFFFBBF24).withValues(alpha: 0.55)
                    : Colors.white.withValues(alpha: 0.07),
              ),
            ),
            child: Row(
              children: [
                SpiritAvatar(
                  colorHex: r.colorHex,
                  state: isActive ? _liveSpiritState : r.avatarState,
                  size: 36,
                  isMain: r.isMain,
                  accessory: r.accessory,
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        r.title,
                        style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: Colors.white),
                        overflow: TextOverflow.ellipsis,
                      ),
                      Text(
                        r.subtitle,
                        style: const TextStyle(fontSize: 11, color: Color(0xFF9CA3AF)),
                        overflow: TextOverflow.ellipsis,
                      ),
                      if (pct != null) ...[
                        const SizedBox(height: 5),
                        Row(
                          children: [
                            Expanded(
                              child: ClipRRect(
                                borderRadius: BorderRadius.circular(99),
                                child: LinearProgressIndicator(
                                  value: pct / 100.0,
                                  minHeight: 4,
                                  backgroundColor: const Color(0xFF374151),
                                  color: const Color(0xFFF59E0B),
                                ),
                              ),
                            ),
                            const SizedBox(width: 8),
                            Text(
                              '$pct%',
                              style: const TextStyle(fontSize: 11, color: Color(0xFF9CA3AF), fontFamily: 'monospace'),
                            ),
                          ],
                        ),
                      ],
                    ],
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _buildTopBar(RoomRecord room, {required bool showMenuBtn}) {
    final badgeColor = switch (_liveSpiritState) {
      SpiritState.idle => const Color(0xFF10B981),
      SpiritState.thinking => const Color(0xFF38BDF8),
      SpiritState.working => const Color(0xFFF59E0B),
      SpiritState.waiting => const Color(0xFF9CA3AF),
      SpiritState.done => const Color(0xFF10B981),
      SpiritState.stuck => const Color(0xFFFB7185),
    };

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      decoration: BoxDecoration(
        color: const Color(0xFF16191F),
        border: Border(bottom: BorderSide(color: Colors.white.withValues(alpha: 0.1))),
      ),
      child: Row(
        children: [
          if (showMenuBtn)
            IconButton(
              icon: const Icon(Icons.menu, color: Color(0xFFD1D5DB)),
              onPressed: () => _scaffoldKey.currentState?.openDrawer(),
            ),
          GestureDetector(
            onTap: showMenuBtn ? () => _scaffoldKey.currentState?.openDrawer() : null,
            child: SpiritAvatar(
              colorHex: room.colorHex,
              state: _liveSpiritState,
              size: 40,
              isMain: room.isMain,
              accessory: room.accessory,
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: GestureDetector(
              onTap: () => showModelSettingsModal(
                context: context,
                engine: widget.engine,
                onStateChanged: () {
                  setState(() {});
                  unawaited(_reloadFloatingPrefs());
                },
                onToast: _showToast,
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Flexible(
                        child: Text(
                          room.title,
                          style: const TextStyle(fontSize: 14, fontWeight: FontWeight.bold, color: Colors.white),
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      const SizedBox(width: 6),
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                        decoration: BoxDecoration(
                          color: badgeColor.withValues(alpha: 0.18),
                          borderRadius: BorderRadius.circular(6),
                        ),
                        child: Text(
                          _liveSpiritState.label,
                          style: TextStyle(fontSize: 11, color: badgeColor, fontWeight: FontWeight.w600),
                        ),
                      ),
                    ],
                  ),
                  InkWell(
                    borderRadius: BorderRadius.circular(4),
                    onTap: () {
                      unawaited(_runCompactCommand());
                    },
                    child: Builder(
                      builder: (_) {
                        final maxCap = widget.engine.effectiveMaxContextTokens;
                      final ratio = _contextTokens / maxCap;
                      final Color meterColor;
                      if (ratio > 0.85) {
                        meterColor = const Color(0xFFFB7185);
                      } else if (ratio >= 0.70) {
                        meterColor = const Color(0xFFF59E0B);
                      } else {
                        meterColor = const Color(0xFF9CA3AF);
                      }
                      final compact = TokenEstimator.formatCompact(_contextTokens);
                      final maxCompact = TokenEstimator.formatCompact(maxCap);
                      final shortEngine = widget.engine.activeBackendLabel
                          .replaceFirst('Gemma-4-', '')
                          .replaceAll(' ', '');
                      return Text.rich(
                        TextSpan(
                          children: [
                            TextSpan(
                              text: '$shortEngine • ',
                              style: const TextStyle(fontSize: 11, color: Color(0xFF9CA3AF)),
                            ),
                            TextSpan(
                              text: '$compact/$maxCompact${ratio > 0.85 ? ' ✂️' : ''}',
                              style: TextStyle(
                                fontSize: 11,
                                color: meterColor,
                                fontWeight: ratio >= 0.70 ? FontWeight.w600 : FontWeight.normal,
                              ),
                            ),
                          ],
                        ),
                        overflow: TextOverflow.ellipsis,
                      );
                    },
                  ),
                ),
              ],
              ),
            ),
          ),
          // 🔊 Built-in TTS auto-read toggle / stop button
          ListenableBuilder(
            listenable: TtsService.instance,
            builder: (context, _) {
              final tts = TtsService.instance;
              final active = tts.autoRead || tts.isSpeaking;
              return Padding(
                padding: const EdgeInsets.only(right: 4),
                child: GestureDetector(
                  onLongPress: () => showTtsSettingsModal(
                    context: context,
                    onToast: _showToast,
                  ),
                  child: IconButton(
                    tooltip: tts.isSpeaking
                        ? '停止朗讀（長按調音色語速）'
                        : (tts.autoRead ? '關閉自動朗讀（長按調音色語速）' : '開啟自動朗讀（長按調音色語速）'),
                    style: IconButton.styleFrom(
                      backgroundColor: active
                          ? const Color(0xFFF59E0B).withValues(alpha: 0.16)
                          : Colors.white.withValues(alpha: 0.06),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(11),
                      ),
                    ),
                    icon: Icon(
                      tts.isSpeaking
                          ? Icons.stop_circle_outlined
                          : (tts.autoRead
                              ? Icons.volume_up_rounded
                              : Icons.volume_off_outlined),
                      color: active ? const Color(0xFFFCD34D) : const Color(0xFF9CA3AF),
                      size: 20,
                    ),
                    onPressed: () {
                      if (tts.isSpeaking) {
                        unawaited(tts.stop());
                        _showToast('🔇 已停止朗讀');
                      } else {
                        tts.toggleAutoRead();
                        _showToast(tts.autoRead ? '🔊 已開啟自動朗讀（長按可調音色）' : '🔇 已關閉自動朗讀');
                      }
                    },
                  ),
                ),
              );
            },
          ),
          // ☁️ P2 Cloud Handoff & Sync button
          ListenableBuilder(
            listenable: widget.syncService,
            builder: (context, _) {
              final pending = widget.syncService.pendingCount;
              final syncing = widget.syncService.isSyncing;
              final configured = widget.syncService.isConfigured;
              return Stack(
                clipBehavior: Clip.none,
                children: [
                  IconButton(
                    tooltip: 'P2 雙機雲端交班',
                    style: IconButton.styleFrom(
                      backgroundColor: configured
                          ? const Color(0xFF10B981).withValues(alpha: 0.14)
                          : Colors.white.withValues(alpha: 0.06),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(11)),
                    ),
                    icon: syncing
                        ? const SizedBox(
                            width: 18,
                            height: 18,
                            child: CircularProgressIndicator(
                              strokeWidth: 2,
                              color: Color(0xFF34D399),
                            ),
                          )
                        : Icon(
                            configured ? Icons.cloud_done_outlined : Icons.cloud_upload_outlined,
                            color: configured ? const Color(0xFF34D399) : const Color(0xFF9CA3AF),
                            size: 20,
                          ),
                    onPressed: () => showCloudSyncModal(
                      context: context,
                      syncService: widget.syncService,
                      onDataMerged: () => _loadRoomContent(_currentRoomId),
                      onToast: _showToast,
                    ),
                  ),
                  if (pending > 0 && !syncing)
                    Positioned(
                      right: 3,
                      top: 3,
                      child: Container(
                        width: 8,
                        height: 8,
                        decoration: const BoxDecoration(
                          color: Color(0xFFF59E0B),
                          shape: BoxShape.circle,
                        ),
                      ),
                    ),
                ],
              );
            },
          ),
          const SizedBox(width: 4),
          // 📋 Global Pending Memo Inbox button
          Stack(
            clipBehavior: Clip.none,
            children: [
              IconButton(
                tooltip: '待我處理的備忘錄',
                style: IconButton.styleFrom(
                  backgroundColor: const Color(0xFFF59E0B).withValues(alpha: 0.14),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(11)),
                ),
                icon: const Icon(Icons.assignment_turned_in_outlined, color: Color(0xFFFCD34D), size: 20),
                onPressed: () => showPendingMemoInboxModal(
                  context: context,
                  db: widget.db,
                  onJumpToRoom: _switchRoom,
                  onDataChanged: () {
                    widget.syncService.scheduleDebouncedPush();
                    _loadRoomContent(_currentRoomId);
                  },
                  onToast: _showToast,
                ),
              ),
              if (_pendingMemoCount > 0)
                Positioned(
                  right: 2,
                  top: 2,
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
                    decoration: BoxDecoration(
                      color: const Color(0xFFF43F5E),
                      borderRadius: BorderRadius.circular(99),
                    ),
                    child: Text(
                      '$_pendingMemoCount',
                      style: const TextStyle(fontSize: 10, fontWeight: FontWeight.bold, color: Colors.white),
                    ),
                  ),
                ),
            ],
          ),
          PopupMenuButton<String>(
            color: const Color(0xFF1E222B),
            icon: const Icon(Icons.more_vert, color: Color(0xFF9CA3AF)),
            onSelected: (val) async {
              switch (val) {
                case 'lookup':
                  await showOfflineLookupModal(
                    context: context,
                    db: widget.db,
                    onToast: _showToast,
                  );
                  break;
                case 'new_topic':
                  await _insertNewTopicDivider();
                  break;
                case 'new_room':
                  final created = await showCreateRoomDialog(context: context, db: widget.db);
                  if (created != null) {
                    widget.syncService.scheduleDebouncedPush();
                    await _switchRoom(created.roomId);
                  }
                  break;
                case 'archive_room':
                  await widget.db.archiveRoom(_currentRoomId);
                  widget.syncService.scheduleDebouncedPush();
                  await _loadRoomContent(_currentRoomId);
                  _showToast('😴 本房已結案封存，KODARI 進入睡覺狀態');
                  break;
                case 'delete_room':
                  await _confirmDeleteRoom(room);
                  break;
                case 'traits':
                  await showTraitsEditorModal(
                    context: context,
                    db: widget.db,
                    engine: widget.engine,
                    roomId: _currentRoomId,
                    onDataChanged: () => unawaited(_loadRoomContent(_currentRoomId)),
                    onToast: _showToast,
                  );
                  await widget.engine.invalidateSession();
                  widget.syncService.scheduleDebouncedPush();
                  await _loadRoomContent(_currentRoomId);
                  break;
                case 'routines':
                  await showRoutineSchedulerModal(
                    context: context,
                    db: widget.db,
                    onToast: _showToast,
                  );
                  widget.syncService.scheduleDebouncedPush();
                  break;
                case 'tts_settings':
                  await showTtsSettingsModal(
                    context: context,
                    onToast: _showToast,
                  );
                  break;
                case 'skills':
                  await showSkillManagerModal(
                    context: context,
                    db: widget.db,
                    onChanged: () {
                      unawaited(widget.engine.invalidateSession());
                      widget.syncService.scheduleDebouncedPush();
                    },
                    onToast: _showToast,
                  );
                  break;
                case 'settings':
                  await showModelSettingsModal(
                    context: context,
                    engine: widget.engine,
                    onStateChanged: () {
                  setState(() {});
                  unawaited(_reloadFloatingPrefs());
                },
                    onToast: _showToast,
                  );
                  break;
              }
            },
            itemBuilder: (ctx) => [
              const PopupMenuItem(value: 'lookup', child: Text('🔍 離線快查（鋁料／調機）', style: TextStyle(color: Color(0xFFFCD34D), fontSize: 13))),
              const PopupMenuItem(value: 'routines', child: Text('⏰ 零算力日常排程', style: TextStyle(color: Color(0xFFF59E0B), fontSize: 13))),
              const PopupMenuItem(value: 'skills', child: Text('📜 Skill 知識包管理', style: TextStyle(color: Color(0xFFF472B6), fontSize: 13))),
              const PopupMenuItem(value: 'new_topic', child: Text('✂️ 開始新話題（不刪歷史）', style: TextStyle(color: Colors.white, fontSize: 13))),
              const PopupMenuItem(value: 'new_room', child: Text('➕ 建立新工作房間', style: TextStyle(color: Colors.white, fontSize: 13))),
              if (!room.isMain && !room.isArchived)
                const PopupMenuItem(value: 'archive_room', child: Text('😴 封存結案本房（變白睡覺）', style: TextStyle(color: Color(0xFFD1D5DB), fontSize: 13))),
              if (!room.isMain)
                const PopupMenuItem(value: 'delete_room', child: Text('🗑️ 刪除此工作房間', style: TextStyle(color: Color(0xFFFB7185), fontSize: 13))),
              const PopupMenuItem(value: 'traits', child: Text('🧠 檢視／編輯 KODARI 靈魂', style: TextStyle(color: Colors.white, fontSize: 13))),
              const PopupMenuItem(value: 'tts_settings', child: Text('🔊 語音語速與音色設定', style: TextStyle(color: Colors.white, fontSize: 13))),
              const PopupMenuItem(value: 'settings', child: Text('⚙️ 模型與 GPU/CPU 設定', style: TextStyle(color: Colors.white, fontSize: 13))),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildTaskSummaryStrip() {
    final pct = (DatabaseHelper.calculateProgress(_currentTodos) * 100).round();
    final pendingTodos = _currentTodos.where((t) => !t.done).toList();
    final completedCount = _currentTodos.length - pendingTodos.length;
    final stripTitle = pendingTodos.isNotEmpty
        ? pendingTodos.first.text
        : '🎉 已完成 ${_currentTodos.length} 項待辦（點此展開或清除）';

    return Container(
      decoration: BoxDecoration(
        color: const Color(0xFF1A1E26),
        border: Border(bottom: BorderSide(color: Colors.white.withValues(alpha: 0.1))),
      ),
      child: Column(
        children: [
          InkWell(
            onTap: () => setState(() => _taskDrawerExpanded = !_taskDrawerExpanded),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
              child: Row(
                children: [
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                    decoration: BoxDecoration(
                      color: const Color(0xFFF59E0B).withValues(alpha: 0.2),
                      borderRadius: BorderRadius.circular(6),
                    ),
                    child: Text(
                      '$pct%',
                      style: const TextStyle(
                        fontSize: 11.5,
                        fontFamily: 'monospace',
                        color: Color(0xFFFCD34D),
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  SizedBox(
                    width: 64,
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(99),
                      child: LinearProgressIndicator(
                        value: pct / 100.0,
                        minHeight: 5,
                        backgroundColor: const Color(0xFF374151),
                        color: const Color(0xFFF59E0B),
                      ),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      stripTitle,
                      style: TextStyle(
                        fontSize: 12.5,
                        color: pendingTodos.isNotEmpty
                            ? const Color(0xFFD1D5DB)
                            : const Color(0xFF6EE7B7),
                      ),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  if (completedCount > 0)
                    InkWell(
                      borderRadius: BorderRadius.circular(8),
                      onTap: () async {
                        final removed = await widget.db.clearCompletedTodos(_currentRoomId);
                        if (removed > 0) {
                          widget.syncService.scheduleDebouncedPush();
                          await _loadRoomContent(_currentRoomId);
                          _showToast('🧹 已清除 $removed 項已完成待辦');
                        }
                      },
                      child: Container(
                        margin: const EdgeInsets.only(right: 6),
                        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                        decoration: BoxDecoration(
                          color: Colors.white.withValues(alpha: 0.08),
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: Text(
                          '🧹 清除($completedCount)',
                          style: const TextStyle(fontSize: 11, color: Color(0xFFD1D5DB)),
                        ),
                      ),
                    ),
                  Icon(
                    _taskDrawerExpanded ? Icons.keyboard_arrow_up : Icons.keyboard_arrow_down,
                    color: const Color(0xFF9CA3AF),
                    size: 20,
                  ),
                ],
              ),
            ),
          ),
          if (_taskDrawerExpanded)
            Container(
              constraints: const BoxConstraints(maxHeight: 190),
              decoration: BoxDecoration(
                border: Border(top: BorderSide(color: Colors.white.withValues(alpha: 0.06))),
              ),
              child: ListView.builder(
                shrinkWrap: true,
                itemCount: _currentTodos.length,
                itemBuilder: (ctx, i) {
                  final todo = _currentTodos[i];
                  return CheckboxListTile(
                    dense: true,
                    controlAffinity: ListTileControlAffinity.leading,
                    activeColor: const Color(0xFFF59E0B),
                    value: todo.done,
                    title: Text(
                      todo.text,
                      style: TextStyle(
                        fontSize: 12.5,
                        color: todo.done ? const Color(0xFF6B7280) : const Color(0xFFE5E7EB),
                        decoration: todo.done ? TextDecoration.lineThrough : null,
                      ),
                    ),
                    secondary: IconButton(
                      icon: const Icon(Icons.close, size: 16, color: Color(0xFF6B7280)),
                      tooltip: '刪除此待辦',
                      onPressed: () async {
                        await widget.db.deleteTodoAtIndex(_currentRoomId, todo.lineIndex);
                        widget.syncService.scheduleDebouncedPush();
                        await _loadRoomContent(_currentRoomId);
                        _showToast('🗑️ 已刪除待辦項目');
                      },
                    ),
                    onChanged: (_) async {
                      await widget.db.toggleTodoAtIndex(_currentRoomId, todo.lineIndex);
                      widget.syncService.scheduleDebouncedPush();
                      await _loadRoomContent(_currentRoomId);
                    },
                  );
                },
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildChatFeed(RoomRecord room) {
    final totalCount = _messages.length + (_isGenerating ? 1 : 0);
    return GestureDetector(
      behavior: HitTestBehavior.translucent,
      onTap: () {
        if (_expandedPinMessageId != null) {
          setState(() => _expandedPinMessageId = null);
        }
      },
      child: NotificationListener<ScrollStartNotification>(
        onNotification: (_) {
          if (_expandedPinMessageId != null) {
            setState(() => _expandedPinMessageId = null);
          }
          return false;
        },
        child: ListView.builder(
          controller: _scrollController,
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 14),
          itemCount: totalCount,
          itemBuilder: (context, index) {
            if (_isGenerating && index == _messages.length) {
              return _buildModelBubble(
                room: room,
                text: _streamingText.isEmpty ? '正在想…' : _streamingText,
                pill: _streamingPill,
                card: _streamingCard,
                msgRecord: null,
              );
            }

            final msg = _messages[index];
            if (msg.role == 'divider') {
              return Padding(
                padding: const EdgeInsets.symmetric(vertical: 10),
                child: Row(
                  children: [
                    Expanded(child: Divider(color: Colors.white.withValues(alpha: 0.12))),
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 10),
                      child: Text(
                        msg.content,
                        style: const TextStyle(fontSize: 11.5, color: Color(0xFF6B7280)),
                      ),
                    ),
                    Expanded(child: Divider(color: Colors.white.withValues(alpha: 0.12))),
                  ],
                ),
              );
            }

            if (msg.role == 'user') {
              return _buildUserBubble(msg);
            }
            return _buildModelBubble(
              room: room,
              text: msg.content,
              pill: msg.toolPill,
              card: msg.card,
              msgRecord: msg,
            );
          },
        ),
      ),
    );
  }

  Widget _buildUserBubble(ChatMessageRecord msg) {
    final archivedColor = msg.archivedColorHex != null
        ? parseHexColor(msg.archivedColorHex!)
        : null;
    final bgColor = archivedColor != null
        ? archivedColor.withValues(alpha: 0.14)
        : const Color(0xFF2B2438);
    final borderColor = archivedColor != null
        ? archivedColor.withValues(alpha: 0.65)
        : const Color(0xFFA855F7).withValues(alpha: 0.28);

    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.end,
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          SizedBox(
            width: 38,
            height: 38,
            child: IconButton(
              padding: EdgeInsets.zero,
              icon: const Icon(Icons.more_vert, size: 18, color: Color(0xFF9CA3AF)),
              onPressed: () => _showMessageActionSheet(msg),
            ),
          ),
          Flexible(
            child: GestureDetector(
              onLongPress: () => _showMessageActionSheet(msg),
              child: ConstrainedBox(
                constraints: BoxConstraints(maxWidth: MediaQuery.of(context).size.width * 0.76),
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                  decoration: BoxDecoration(
                    color: bgColor,
                    borderRadius: const BorderRadius.only(
                      topLeft: Radius.circular(18),
                      topRight: Radius.circular(18),
                      bottomLeft: Radius.circular(18),
                      bottomRight: Radius.circular(4),
                    ),
                    border: Border.all(color: borderColor),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      if (msg.imagePath != null && msg.imagePath!.isNotEmpty)
                        GestureDetector(
                          onTap: () => _openFullImage(msg.imagePath!),
                          child: Container(
                            margin: const EdgeInsets.only(bottom: 8),
                            child: Stack(
                              children: [
                                ClipRRect(
                                  borderRadius: BorderRadius.circular(10),
                                  child: File(msg.imagePath!).existsSync()
                                      ? Image.file(
                                          File(msg.imagePath!),
                                          height: 140,
                                          width: double.infinity,
                                          fit: BoxFit.cover,
                                        )
                                      : Container(
                                          height: 80,
                                          color: const Color(0xFF374151),
                                          alignment: Alignment.center,
                                          child: const Text('📷 現場照片', style: TextStyle(color: Colors.white70)),
                                        ),
                                ),
                                if (msg.isStarred)
                                  Positioned(
                                    top: 6,
                                    right: 6,
                                    child: Container(
                                      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
                                      decoration: BoxDecoration(
                                        color: const Color(0xFFF59E0B),
                                        borderRadius: BorderRadius.circular(6),
                                      ),
                                      child: const Text(
                                        '⭐ 待確認',
                                        style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold, color: Color(0xFF111317)),
                                      ),
                                    ),
                                  ),
                              ],
                            ),
                          ),
                        ),
                      Text(
                        msg.content,
                        style: const TextStyle(fontSize: 14, color: Color(0xFFF3F4F6), height: 1.4),
                      ),
                      if (msg.isStarred && (msg.imagePath == null || msg.imagePath!.isEmpty))
                        Padding(
                          padding: const EdgeInsets.only(top: 4),
                          child: Text(
                            '⭐ 已標星暫存',
                            style: TextStyle(fontSize: 11.5, color: const Color(0xFFFCD34D).withValues(alpha: 0.9)),
                          ),
                        ),
                      if (msg.archivedTitle != null && msg.archivedTitle!.isNotEmpty) ...[
                        const SizedBox(height: 6),
                        Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Container(
                              width: 7,
                              height: 7,
                              decoration: BoxDecoration(
                                color: archivedColor ?? const Color(0xFFF59E0B),
                                shape: BoxShape.circle,
                              ),
                            ),
                            const SizedBox(width: 5),
                            Flexible(
                              child: Text(
                                '已歸檔至 ${msg.archivedTitle}',
                                style: TextStyle(
                                  fontSize: 11.5,
                                  color: archivedColor ?? const Color(0xFFFCD34D),
                                  fontWeight: FontWeight.w500,
                                ),
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                          ],
                        ),
                      ],
                    ],
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildModelBubble({
    required RoomRecord room,
    required String text,
    String? pill,
    ActionCardData? card,
    ChatMessageRecord? msgRecord,
  }) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 14),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(top: 2),
            child: SpiritAvatar(
              colorHex: room.colorHex,
              state: msgRecord == null ? _liveSpiritState : room.avatarState,
              size: 28,
              isMain: room.isMain,
              accessory: room.accessory,
            ),
          ),
          const SizedBox(width: 8),
          Flexible(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (pill != null && pill.isNotEmpty)
                  Container(
                    margin: const EdgeInsets.only(bottom: 6),
                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                    decoration: BoxDecoration(
                      color: const Color(0xFF10B981).withValues(alpha: 0.14),
                      borderRadius: BorderRadius.circular(99),
                      border: Border.all(color: const Color(0xFF10B981).withValues(alpha: 0.35)),
                    ),
                    child: Text(
                      pill,
                      style: const TextStyle(fontSize: 11.5, color: Color(0xFF6EE7B7)),
                    ),
                  ),
                Row(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    Flexible(
                      child: GestureDetector(
                        onLongPress: msgRecord != null ? () => _showMessageActionSheet(msgRecord) : null,
                        child: Container(
                          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                          decoration: BoxDecoration(
                            color: const Color(0xFF1C2028),
                            borderRadius: const BorderRadius.only(
                              topLeft: Radius.circular(4),
                              topRight: Radius.circular(18),
                              bottomLeft: Radius.circular(18),
                              bottomRight: Radius.circular(18),
                            ),
                            border: Border.all(color: Colors.white.withValues(alpha: 0.1)),
                          ),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                text,
                                style: const TextStyle(fontSize: 14, color: Color(0xFFF3F4F6), height: 1.45),
                              ),
                              if (card != null)
                                ActionCardWidget(
                                  card: card,
                                  onToast: _showToast,
                                  onJumpToRoom: _switchRoom,
                                  onOpenAnnotator: (note) => _annotatePhoto(initialNote: note),
                                  onOpenAlbumScanner: _openAlbumScanner,
                                  onOpenSkillManager: () => showSkillManagerModal(
                                    context: context,
                                    db: widget.db,
                                    onChanged: () {
                                      unawaited(widget.engine.invalidateSession());
                                      widget.syncService.scheduleDebouncedPush();
                                    },
                                    onToast: _showToast,
                                  ),
                                  onOpenRoutineManager: () => showRoutineSchedulerModal(
                                    context: context,
                                    db: widget.db,
                                    onToast: _showToast,
                                  ),
                                  onCreateRoom: (name) async {
                                    final created = await showCreateRoomDialog(
                                      context: context,
                                      db: widget.db,
                                      initialTitle: name,
                                    );
                                    if (created != null) {
                                      widget.syncService.scheduleDebouncedPush();
                                      await _switchRoom(created.roomId);
                                    }
                                  },
                                ),
                            ],
                          ),
                        ),
                      ),
                    ),
                    if (msgRecord != null)
                      ListenableBuilder(
                        listenable: TtsService.instance,
                        builder: (context, _) {
                          final tts = TtsService.instance;
                          final isThisPlaying =
                              tts.isSpeaking && tts.speakingMessageId == msgRecord.id;
                          final isFlagged = _flaggedMessageIds.contains(msgRecord.id);
                          final Widget pinIcon;
                          if (isThisPlaying) {
                            pinIcon = const Icon(
                              Icons.stop_circle_outlined,
                              size: 18,
                              color: Color(0xFFFCD34D),
                            );
                          } else if (msgRecord.isStarred) {
                            pinIcon = const Text('⭐', style: TextStyle(fontSize: 15));
                          } else if (isFlagged) {
                            pinIcon = const Icon(
                              Icons.flag,
                              size: 16,
                              color: Color(0xFFF43F5E),
                            );
                          } else {
                            pinIcon = const Opacity(
                              opacity: 0.65,
                              child: Text('📌', style: TextStyle(fontSize: 14.5)),
                            );
                          }
                          return Tooltip(
                            message: '單擊釘選／標星 • 長按展開操作膠囊',
                            child: GestureDetector(
                              behavior: HitTestBehavior.opaque,
                              onTap: () async {
                                if (isThisPlaying) {
                                  HapticFeedback.lightImpact();
                                  unawaited(tts.stop());
                                  if (_expandedPinMessageId == msgRecord.id) {
                                    setState(() => _expandedPinMessageId = null);
                                  }
                                  _showToast('🔇 已停止朗讀');
                                  return;
                                }
                                HapticFeedback.lightImpact();
                                final nextStar = !msgRecord.isStarred;
                                await widget.db.setMessageStarred(msgRecord.id, nextStar);
                                if (nextStar) {
                                  final short = msgRecord.content.length > 60
                                      ? '${msgRecord.content.substring(0, 60)}...'
                                      : msgRecord.content;
                                  await widget.db.upsertTodoItem(
                                    roomId: _currentRoomId,
                                    itemText: short,
                                  );
                                }
                                widget.syncService.scheduleDebouncedPush();
                                if (_expandedPinMessageId == msgRecord.id) {
                                  _expandedPinMessageId = null;
                                }
                                await _loadRoomContent(_currentRoomId);
                                _showToast(nextStar ? '⭐📌 已標星並釘入本房待辦' : '已取消標星釘選');
                              },
                              onLongPress: () {
                                HapticFeedback.mediumImpact();
                                setState(() {
                                  _expandedPinMessageId =
                                      _expandedPinMessageId == msgRecord.id ? null : msgRecord.id;
                                });
                              },
                              child: SizedBox(
                                width: 32,
                                height: 36,
                                child: Center(child: pinIcon),
                              ),
                            ),
                          );
                        },
                      ),
                  ],
                ),
                if (msgRecord != null && _expandedPinMessageId == msgRecord.id)
                  _buildModelBubbleMiniCapsule(msgRecord, text),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildModelBubbleMiniCapsule(ChatMessageRecord msgRecord, String text) {
    final tts = TtsService.instance;
    final isThisPlaying = tts.isSpeaking && tts.speakingMessageId == msgRecord.id;
    final isFlagged = _flaggedMessageIds.contains(msgRecord.id);

    return Align(
      alignment: Alignment.centerRight,
      child: Padding(
        padding: const EdgeInsets.only(top: 6),
        child: Material(
          color: Colors.transparent,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
            decoration: BoxDecoration(
              color: const Color(0xFF14171F),
              borderRadius: BorderRadius.circular(99),
              border: Border.all(
                color: const Color(0xFFF59E0B).withValues(alpha: 0.72),
                width: 1.1,
              ),
              boxShadow: const [
                BoxShadow(
                  color: Colors.black54,
                  blurRadius: 10,
                  offset: Offset(0, 3),
                ),
              ],
            ),
            child: Wrap(
              spacing: 2,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                _buildMiniCapsuleBtn(
                  label: isThisPlaying ? '⏹️ 停止' : '🔊 朗讀',
                  color: isThisPlaying ? const Color(0xFFFCD34D) : const Color(0xFFE5E7EB),
                  onTap: () {
                    setState(() => _expandedPinMessageId = null);
                    if (isThisPlaying) {
                      unawaited(tts.stop());
                    } else {
                      unawaited(tts.speak(text, messageId: msgRecord.id));
                    }
                  },
                ),
                _buildMiniCapsuleBtn(
                  label: isFlagged ? '🚩 已插旗' : '🚩 糾錯',
                  color: isFlagged ? const Color(0xFFFB7185) : const Color(0xFFE5E7EB),
                  onTap: () async {
                    setState(() => _expandedPinMessageId = null);
                    final changed = await showFlagMessageDialog(
                      context: context,
                      db: widget.db,
                      msg: msgRecord,
                      alreadyFlagged: isFlagged,
                      onToast: _showToast,
                    );
                    if (changed) {
                      await _loadRoomContent(_currentRoomId);
                    }
                  },
                ),
                _buildMiniCapsuleBtn(
                  label: '📋 複製',
                  color: const Color(0xFFE5E7EB),
                  onTap: () async {
                    setState(() => _expandedPinMessageId = null);
                    await Clipboard.setData(ClipboardData(text: text));
                    _showToast('📋 已複製訊息文字');
                  },
                ),
                _buildMiniCapsuleBtn(
                  label: '⋯ 更多',
                  color: const Color(0xFFFCD34D),
                  onTap: () {
                    setState(() => _expandedPinMessageId = null);
                    _showMessageActionSheet(msgRecord);
                  },
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildMiniCapsuleBtn({
    required String label,
    required Color color,
    required VoidCallback onTap,
  }) {
    return InkWell(
      borderRadius: BorderRadius.circular(99),
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 5),
        child: Text(
          label,
          style: TextStyle(fontSize: 11.5, fontWeight: FontWeight.w600, color: color),
        ),
      ),
    );
  }

  Widget _buildAtPopover() {
    return Container(
      margin: const EdgeInsets.fromLTRB(12, 0, 12, 6),
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: const Color(0xFF1C2029),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: const Color(0xFFF59E0B).withValues(alpha: 0.35)),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              const Expanded(
                child: Text(
                  '⚡ 點選單輪掛載（長按可釘選連用）',
                  style: TextStyle(fontSize: 11.5, color: Color(0xFF9CA3AF)),
                ),
              ),
              InkWell(
                onTap: () => setState(() => _atMenuVisible = false),
                child: const Padding(
                  padding: EdgeInsets.all(4),
                  child: Icon(Icons.close, size: 16, color: Color(0xFF9CA3AF)),
                ),
              ),
            ],
          ),
          const SizedBox(height: 4),
          ConstrainedBox(
            constraints: const BoxConstraints(maxHeight: 270),
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  for (final opt in ToolRegistry.optionsForRoom(_currentRoomId))
                    InkWell(
                      borderRadius: BorderRadius.circular(10),
                      onTap: () => _selectAtTool(opt, pin: false),
                      onLongPress: () => _selectAtTool(opt, pin: true),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                        child: Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [
                            Text(
                              opt.atLabel,
                              style: TextStyle(
                                fontSize: 13.5,
                                fontWeight: FontWeight.w600,
                                color: parseHexColor(opt.colorHex),
                              ),
                            ),
                            const SizedBox(width: 8),
                            Flexible(
                              child: Text(
                                opt.subtitle,
                                textAlign: TextAlign.right,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(fontSize: 12, color: Color(0xFF9CA3AF)),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  void _selectAtTool(AtToolOption opt, {required bool pin}) {
    final text = _inputController.text;
    if (text.endsWith('@')) {
      _inputController.text = text.substring(0, text.length - 1);
      _inputController.selection = TextSelection.fromPosition(
        TextPosition(offset: _inputController.text.length),
      );
    }
    setState(() {
      _mountedTool = opt;
      _isToolPinned = pin;
      _atMenuVisible = false;
    });
    if (pin) {
      _showToast('📌 已釘選 ${opt.atLabel}，連續送出免重複選取');
    }
  }

  Widget _buildInputBar() {
    final hasPending = _mountedTool != null || _pendingImage != null;

    return Container(
      padding: const EdgeInsets.fromLTRB(10, 8, 10, 10),
      decoration: BoxDecoration(
        color: const Color(0xFF16191F),
        border: Border(top: BorderSide(color: Colors.white.withValues(alpha: 0.1))),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (hasPending)
            Padding(
              padding: const EdgeInsets.only(bottom: 8, left: 2),
              child: Wrap(
                spacing: 8,
                runSpacing: 6,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  if (_mountedTool != null)
                    GestureDetector(
                      onLongPress: () {
                        setState(() => _isToolPinned = !_isToolPinned);
                        _showToast(_isToolPinned ? '📌 已釘選工具（連續掛載）' : '⚡ 已改為單輪用完即卸');
                      },
                      child: Container(
                        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                        decoration: BoxDecoration(
                          color: const Color(0xFFF59E0B).withValues(alpha: _isToolPinned ? 0.28 : 0.16),
                          borderRadius: BorderRadius.circular(99),
                          border: Border.all(
                            color: const Color(0xFFFBBF24).withValues(alpha: _isToolPinned ? 0.8 : 0.4),
                          ),
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text(
                              '${_isToolPinned ? '📌' : '⚡'} ${_mountedTool!.atLabel}',
                              style: const TextStyle(fontSize: 12, color: Color(0xFFFDE68A), fontWeight: FontWeight.w600),
                            ),
                            const SizedBox(width: 6),
                            InkWell(
                              onTap: () => setState(() => _isToolPinned = !_isToolPinned),
                              child: Icon(
                                _isToolPinned ? Icons.push_pin : Icons.push_pin_outlined,
                                size: 15,
                                color: _isToolPinned ? const Color(0xFFF59E0B) : const Color(0xFF9CA3AF),
                              ),
                            ),
                            const SizedBox(width: 6),
                            InkWell(
                              onTap: () => setState(() {
                                _mountedTool = null;
                                _isToolPinned = false;
                              }),
                              child: const Icon(Icons.close, size: 15, color: Color(0xFFE5E7EB)),
                            ),
                          ],
                        ),
                      ),
                    ),
                  if (_pendingImage != null)
                    Container(
                      padding: const EdgeInsets.fromLTRB(6, 5, 8, 5),
                      decoration: BoxDecoration(
                        color: const Color(0xFF232833),
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(color: Colors.white.withValues(alpha: 0.14)),
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          ClipRRect(
                            borderRadius: BorderRadius.circular(6),
                            child: Image.memory(
                              _pendingImage!.bytes,
                              width: 36,
                              height: 36,
                              fit: BoxFit.cover,
                            ),
                          ),
                          const SizedBox(width: 8),
                          Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                '${_pendingImage!.width}×${_pendingImage!.height}',
                                style: const TextStyle(fontSize: 11.5, color: Colors.white, fontWeight: FontWeight.w600),
                              ),
                              Text(
                                '~${_pendingImage!.estimatedTokens} tok',
                                style: const TextStyle(fontSize: 11, color: Color(0xFF9CA3AF)),
                              ),
                            ],
                          ),
                          const SizedBox(width: 8),
                          InkWell(
                            onTap: () => setState(() => _pendingImage = null),
                            child: const Icon(Icons.close, size: 16, color: Color(0xFFD1D5DB)),
                          ),
                        ],
                      ),
                    ),
                ],
              ),
            ),
          Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              SizedBox(
                width: 40,
                height: 40,
                child: IconButton(
                  padding: EdgeInsets.zero,
                  style: IconButton.styleFrom(
                    backgroundColor: Colors.white.withValues(alpha: 0.06),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(11)),
                  ),
                  icon: const Icon(Icons.camera_alt_outlined, color: Color(0xFFD1D5DB), size: 20),
                  onPressed: _isGenerating ? null : _showPhotoPickerSheet,
                ),
              ),
              const SizedBox(width: 6),
              SizedBox(
                width: 40,
                height: 40,
                child: TextButton(
                  style: TextButton.styleFrom(
                    padding: EdgeInsets.zero,
                    backgroundColor: Colors.white.withValues(alpha: 0.06),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(11)),
                  ),
                  onPressed: _isGenerating
                      ? null
                      : () {
                          _prewarmOnInteraction();
                          setState(() => _atMenuVisible = !_atMenuVisible);
                        },
                  child: const Text(
                    '@',
                    style: TextStyle(fontSize: 17, fontWeight: FontWeight.bold, color: Color(0xFFFCD34D)),
                  ),
                ),
              ),
              const SizedBox(width: 6),
              SizedBox(
                width: 40,
                height: 40,
                child: IconButton(
                  padding: EdgeInsets.zero,
                  tooltip: '語音對 KODARI 說話',
                  style: IconButton.styleFrom(
                    backgroundColor: _isListeningVoice
                        ? const Color(0xFF10B981).withValues(alpha: 0.28)
                        : Colors.white.withValues(alpha: 0.06),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(11)),
                  ),
                  icon: Icon(
                    _isListeningVoice ? Icons.graphic_eq : Icons.mic_none_rounded,
                    color: _isListeningVoice ? const Color(0xFF34D399) : const Color(0xFF38BDF8),
                    size: 20,
                  ),
                  onPressed: _isGenerating ? null : _startVoiceInput,
                ),
              ),
              const SizedBox(width: 6),
              Expanded(
                child: TextField(
                  controller: _inputController,
                  focusNode: _inputFocusNode,
                  minLines: 1,
                  maxLines: 4,
                  style: const TextStyle(color: Colors.white, fontSize: 14),
                  onTap: _prewarmOnInteraction,
                  onChanged: (val) {
                    if (val.endsWith('@') && !_atMenuVisible) {
                      setState(() => _atMenuVisible = true);
                    }
                  },
                  onSubmitted: (_) => _sendMessage(),
                  decoration: InputDecoration(
                    hintText: '說點什麼，或按 @ 掛工具…',
                    hintMaxLines: 1,
                    hintStyle: const TextStyle(color: Color(0xFF6B7280), fontSize: 13),
                    filled: true,
                    fillColor: const Color(0xFF0E1014),
                    contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(12),
                      borderSide: BorderSide(color: Colors.white.withValues(alpha: 0.1)),
                    ),
                    enabledBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(12),
                      borderSide: BorderSide(color: Colors.white.withValues(alpha: 0.1)),
                    ),
                    focusedBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(12),
                      borderSide: BorderSide(color: const Color(0xFFF59E0B).withValues(alpha: 0.65)),
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 6),
              SizedBox(
                width: 42,
                height: 42,
                child: IconButton(
                  style: IconButton.styleFrom(
                    backgroundColor: _isGenerating ? const Color(0xFFF43F5E) : const Color(0xFFF59E0B),
                    foregroundColor: _isGenerating ? Colors.white : const Color(0xFF111317),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                  ),
                  icon: Icon(_isGenerating ? Icons.stop : Icons.arrow_forward, size: 20),
                  onPressed: _sendMessage,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
