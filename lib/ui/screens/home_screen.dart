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
import '../../tools/tool_registry.dart';
import '../widgets/action_card_widget.dart';
import '../widgets/modals.dart';
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

class _HomeScreenState extends State<HomeScreen> {
  final GlobalKey<ScaffoldState> _scaffoldKey = GlobalKey<ScaffoldState>();
  final TextEditingController _inputController = TextEditingController();
  final ScrollController _scrollController = ScrollController();
  final ImagePicker _picker = ImagePicker();

  List<RoomRecord> _rooms = [];
  String _currentRoomId = 'main';
  List<TodoItem> _currentTodos = [];
  List<ChatMessageRecord> _messages = [];
  int _pendingMemoCount = 0;
  int _contextTokens = 0;

  bool _taskDrawerExpanded = false;
  bool _atMenuVisible = false;
  bool _isGenerating = false;
  bool _sendingLock = false;
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
    _lastSeenSyncAtMs = widget.syncService.lastSyncAtMs;
    widget.syncService.addListener(_onSyncServiceChanged);
    _loadAllData();
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
    widget.syncService.removeListener(_onSyncServiceChanged);
    _idleTimer?.cancel();
    _topToastTimer?.cancel();
    _streamSub?.cancel();
    _inputController.dispose();
    _scrollController.dispose();
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
      _pendingMemoCount = memo.totalCount;
      _contextTokens = estimatedTokens;
      _liveSpiritState = _isGenerating ? _liveSpiritState : room.avatarState;
    });
    _scrollToBottom();
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
      final file = await _picker.pickImage(source: source);
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
              ],
            ),
          ),
        );
      },
    );
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
                onStateChanged: () => setState(() {}),
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
                  Builder(
                    builder: (_) {
                      final ratio = _contextTokens / TokenEstimator.maxContextTokens;
                      final Color meterColor;
                      if (ratio > 0.85) {
                        meterColor = const Color(0xFFFB7185);
                      } else if (ratio >= 0.70) {
                        meterColor = const Color(0xFFF59E0B);
                      } else {
                        meterColor = const Color(0xFF9CA3AF);
                      }
                      final compact = TokenEstimator.formatCompact(_contextTokens);
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
                              text: '$compact/3.0k${ratio > 0.85 ? ' ✂️' : ''}',
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
                ],
              ),
            ),
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
                    onToast: _showToast,
                  );
                  widget.syncService.scheduleDebouncedPush();
                  await _loadRoomContent(_currentRoomId);
                  break;
                case 'settings':
                  await showModelSettingsModal(
                    context: context,
                    engine: widget.engine,
                    onStateChanged: () => setState(() {}),
                    onToast: _showToast,
                  );
                  break;
              }
            },
            itemBuilder: (ctx) => [
              const PopupMenuItem(value: 'lookup', child: Text('🔍 離線快查（鋁料／調機）', style: TextStyle(color: Color(0xFFFCD34D), fontSize: 13))),
              const PopupMenuItem(value: 'new_topic', child: Text('✂️ 開始新話題（不刪歷史）', style: TextStyle(color: Colors.white, fontSize: 13))),
              const PopupMenuItem(value: 'new_room', child: Text('➕ 建立新工作房間', style: TextStyle(color: Colors.white, fontSize: 13))),
              if (!room.isMain && !room.isArchived)
                const PopupMenuItem(value: 'archive_room', child: Text('😴 封存結案本房（變白睡覺）', style: TextStyle(color: Color(0xFFD1D5DB), fontSize: 13))),
              if (!room.isMain)
                const PopupMenuItem(value: 'delete_room', child: Text('🗑️ 刪除此工作房間', style: TextStyle(color: Color(0xFFFB7185), fontSize: 13))),
              const PopupMenuItem(value: 'traits', child: Text('🧠 檢視／編輯 KODARI 靈魂', style: TextStyle(color: Colors.white, fontSize: 13))),
              const PopupMenuItem(value: 'settings', child: Text('⚙️ 模型與 GPU/CPU 設定', style: TextStyle(color: Colors.white, fontSize: 13))),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildTaskSummaryStrip() {
    final pct = (DatabaseHelper.calculateProgress(_currentTodos) * 100).round();
    final nextTodo = _currentTodos.firstWhere(
      (t) => !t.done,
      orElse: () => _currentTodos.last,
    );

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
                      nextTodo.text,
                      style: const TextStyle(fontSize: 12.5, color: Color(0xFFD1D5DB)),
                      overflow: TextOverflow.ellipsis,
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
    return ListView.builder(
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
                      SizedBox(
                        width: 38,
                        height: 38,
                        child: IconButton(
                          padding: EdgeInsets.zero,
                          tooltip: '操作訊息',
                          icon: Text(
                            msgRecord.isStarred ? '⭐' : '📌',
                            style: const TextStyle(fontSize: 15),
                          ),
                          onPressed: () => _showMessageActionSheet(msgRecord),
                        ),
                      ),
                  ],
                ),
              ],
            ),
          ),
        ],
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
          for (final opt in ToolRegistry.atOptions)
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
                    Text(
                      opt.subtitle,
                      style: const TextStyle(fontSize: 12, color: Color(0xFF9CA3AF)),
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
              Expanded(
                child: TextField(
                  controller: _inputController,
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
