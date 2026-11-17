import 'dart:io';

import 'package:flutter/material.dart';

import '../../core/image_compressor.dart';
import '../../data/database_helper.dart';
import '../../data/models.dart';
import '../../tools/native_actions.dart';
import 'photo_annotator_dialog.dart';

Future<void> showAlbumScannerSheet({
  required BuildContext context,
  required DatabaseHelper db,
  required String currentRoomId,
  required void Function(String msg) onToast,
  required Future<void> Function({
    required String targetRoomId,
    required List<({CompressedImageResult compressed, String caption})> items,
  }) onBatchArchive,
  required Future<void> Function(AnnotatedPhotoResult annotated, String targetRoomId) onAnnotatedArchive,
}) async {
  await showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    backgroundColor: const Color(0xFF16191F),
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(22)),
    ),
    builder: (ctx) => _AlbumScannerSheetBody(
      db: db,
      currentRoomId: currentRoomId,
      onToast: onToast,
      onBatchArchive: onBatchArchive,
      onAnnotatedArchive: onAnnotatedArchive,
    ),
  );
}

class _AlbumScannerSheetBody extends StatefulWidget {
  const _AlbumScannerSheetBody({
    required this.db,
    required this.currentRoomId,
    required this.onToast,
    required this.onBatchArchive,
    required this.onAnnotatedArchive,
  });

  final DatabaseHelper db;
  final String currentRoomId;
  final void Function(String msg) onToast;
  final Future<void> Function({
    required String targetRoomId,
    required List<({CompressedImageResult compressed, String caption})> items,
  }) onBatchArchive;
  final Future<void> Function(AnnotatedPhotoResult annotated, String targetRoomId) onAnnotatedArchive;

  @override
  State<_AlbumScannerSheetBody> createState() => _AlbumScannerSheetBodyState();
}

class _AlbumScannerSheetBodyState extends State<_AlbumScannerSheetBody> {
  // 0: today, 1: 3 days, 2: recent 40
  int _rangeMode = 0;
  bool _loading = true;
  bool _archiving = false;
  List<AlbumPhotoItem> _photos = const [];
  final Set<int> _selectedIds = {};
  List<RoomRecord> _rooms = const [];
  String _targetRoomId = 'main';
  final TextEditingController _noteController = TextEditingController();

  @override
  void initState() {
    super.initState();
    _initLoad();
  }

  @override
  void dispose() {
    _noteController.dispose();
    super.dispose();
  }

  Future<void> _initLoad() async {
    final rooms = await widget.db.getRooms();
    final active = rooms.where((r) => !r.isArchived).toList();
    var initialTarget = widget.currentRoomId;
    if (initialTarget == 'main' && active.any((r) => !r.isMain)) {
      initialTarget = active.firstWhere((r) => !r.isMain).roomId;
    }
    if (!mounted) return;
    setState(() {
      _rooms = active;
      _targetRoomId = initialTarget;
    });
    await _scanPhotos();
  }

  Future<void> _scanPhotos() async {
    setState(() => _loading = true);
    final now = DateTime.now();
    var sinceMs = 0;
    if (_rangeMode == 0) {
      sinceMs = DateTime(now.year, now.month, now.day).millisecondsSinceEpoch;
    } else if (_rangeMode == 1) {
      sinceMs = now.subtract(const Duration(days: 3)).millisecondsSinceEpoch;
    }

    final items = await NativeActions.scanRecentAlbumPhotos(
      limit: _rangeMode == 2 ? 40 : 30,
      sinceMs: sinceMs,
    );
    if (!mounted) return;
    setState(() {
      _photos = items;
      _selectedIds.removeWhere((id) => !items.any((p) => p.id == id));
      _loading = false;
    });
  }

  Future<void> _annotateSingle(AlbumPhotoItem item) async {
    final tempPath = await NativeActions.copyAlbumPhotoToTemp(item.id);
    if (tempPath == null || !mounted) {
      widget.onToast('❌ 無法讀取相簿原圖');
      return;
    }
    final result = await showPhotoAnnotatorDialog(
      context: context,
      imagePath: tempPath,
      initialNote: _noteController.text.trim(),
    );
    if (result == null || !mounted) return;
    await widget.onAnnotatedArchive(result, _targetRoomId);
    if (mounted) Navigator.of(context).pop();
  }

  Future<void> _archiveSelected() async {
    if (_selectedIds.isEmpty || _archiving) return;
    setState(() => _archiving = true);

    try {
      final selectedItems = _photos.where((p) => _selectedIds.contains(p.id)).toList();
      final note = _noteController.text.trim();
      final results = <({CompressedImageResult compressed, String caption})>[];

      for (final item in selectedItems) {
        final rawPath = await NativeActions.copyAlbumPhotoToTemp(item.id);
        if (rawPath == null) continue;
        final compressed = await ImageCompressor.compressAndSave(rawPath);
        final dt = DateTime.fromMillisecondsSinceEpoch(item.dateTakenMs);
        final timeStr = '${dt.month}/${dt.day} ${dt.hour.toString().padLeft(2, '0')}:${dt.minute.toString().padLeft(2, '0')}';
        final caption = note.isNotEmpty
            ? '🖼️ 相簿歸檔 ($timeStr · ${item.bucketName})：$note'
            : '🖼️ 相簿歸檔 ($timeStr · ${item.bucketName} · ${item.displayName})';
        results.add((compressed: compressed, caption: caption));
      }

      if (results.isEmpty) {
        if (mounted) {
          setState(() => _archiving = false);
          widget.onToast('❌ 找不到可歸檔的圖片檔案');
        }
        return;
      }

      await widget.onBatchArchive(targetRoomId: _targetRoomId, items: results);
      if (mounted) Navigator.of(context).pop();
    } catch (e) {
      if (mounted) {
        setState(() => _archiving = false);
        widget.onToast('❌ 相簿歸檔失敗：$e');
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final maxH = MediaQuery.of(context).size.height * 0.85;
    return SizedBox(
      height: maxH,
      child: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(14, 12, 14, 14),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  const Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          '🖼️ 手機相簿快篩歸檔',
                          style: TextStyle(color: Colors.white, fontSize: 15.5, fontWeight: FontWeight.bold),
                        ),
                        Text(
                          '零算力掃描縮圖，點選多張直接壓縮收進案場工作房（右上角 📏 可單張量測標註）',
                          style: TextStyle(color: Color(0xFF9CA3AF), fontSize: 11.5),
                        ),
                      ],
                    ),
                  ),
                  IconButton(
                    icon: const Icon(Icons.close, color: Color(0xFF9CA3AF)),
                    onPressed: () => Navigator.of(context).pop(),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              Wrap(
                spacing: 8,
                children: [
                  ChoiceChip(
                    label: const Text('今天拍的', style: TextStyle(fontSize: 12)),
                    selected: _rangeMode == 0,
                    onSelected: (_) {
                      setState(() => _rangeMode = 0);
                      _scanPhotos();
                    },
                  ),
                  ChoiceChip(
                    label: const Text('最近 3 天', style: TextStyle(fontSize: 12)),
                    selected: _rangeMode == 1,
                    onSelected: (_) {
                      setState(() => _rangeMode = 1);
                      _scanPhotos();
                    },
                  ),
                  ChoiceChip(
                    label: const Text('最近 40 張', style: TextStyle(fontSize: 12)),
                    selected: _rangeMode == 2,
                    onSelected: (_) {
                      setState(() => _rangeMode = 2);
                      _scanPhotos();
                    },
                  ),
                ],
              ),
              const SizedBox(height: 10),
              Expanded(
                child: _loading
                    ? const Center(child: CircularProgressIndicator(color: Color(0xFFF59E0B)))
                    : (_photos.isEmpty
                        ? const Center(
                            child: Text(
                              '這段時間內沒有掃描到照片，可切到「最近 40 張」試試',
                              style: TextStyle(color: Color(0xFF9CA3AF), fontSize: 13),
                            ),
                          )
                        : GridView.builder(
                            gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                              crossAxisCount: 3,
                              crossAxisSpacing: 6,
                              mainAxisSpacing: 6,
                            ),
                            itemCount: _photos.length,
                            itemBuilder: (ctx, i) {
                              final item = _photos[i];
                              final selected = _selectedIds.contains(item.id);
                              final dt = DateTime.fromMillisecondsSinceEpoch(item.dateTakenMs);
                              final hhmm = '${dt.month}/${dt.day} ${dt.hour.toString().padLeft(2, '0')}:${dt.minute.toString().padLeft(2, '0')}';

                              return GestureDetector(
                                onTap: () {
                                  setState(() {
                                    if (selected) {
                                      _selectedIds.remove(item.id);
                                    } else {
                                      _selectedIds.add(item.id);
                                    }
                                  });
                                },
                                child: Stack(
                                  fit: StackFit.expand,
                                  children: [
                                    ClipRRect(
                                      borderRadius: BorderRadius.circular(10),
                                      child: Image.file(
                                        File(item.thumbPath),
                                        fit: BoxFit.cover,
                                      ),
                                    ),
                                    if (selected)
                                      Container(
                                        decoration: BoxDecoration(
                                          borderRadius: BorderRadius.circular(10),
                                          border: Border.all(color: const Color(0xFFF59E0B), width: 3),
                                          color: const Color(0xFFF59E0B).withValues(alpha: 0.22),
                                        ),
                                      ),
                                    Positioned(
                                      left: 4,
                                      top: 4,
                                      child: Container(
                                        width: 22,
                                        height: 22,
                                        decoration: BoxDecoration(
                                          color: selected ? const Color(0xFFF59E0B) : Colors.black54,
                                          shape: BoxShape.circle,
                                          border: Border.all(color: Colors.white70, width: 1.5),
                                        ),
                                        child: selected
                                            ? const Icon(Icons.check, size: 14, color: Color(0xFF111317))
                                            : null,
                                      ),
                                    ),
                                    Positioned(
                                      right: 4,
                                      top: 4,
                                      child: GestureDetector(
                                        onTap: () => _annotateSingle(item),
                                        child: Container(
                                          padding: const EdgeInsets.all(4),
                                          decoration: BoxDecoration(
                                            color: Colors.black.withValues(alpha: 0.65),
                                            borderRadius: BorderRadius.circular(6),
                                          ),
                                          child: const Text('📏', style: TextStyle(fontSize: 12)),
                                        ),
                                      ),
                                    ),
                                    Positioned(
                                      left: 0,
                                      right: 0,
                                      bottom: 0,
                                      child: Container(
                                        padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 2),
                                        decoration: const BoxDecoration(
                                          color: Colors.black54,
                                          borderRadius: BorderRadius.vertical(bottom: Radius.circular(10)),
                                        ),
                                        child: Text(
                                          hhmm,
                                          style: const TextStyle(color: Colors.white, fontSize: 10),
                                          overflow: TextOverflow.ellipsis,
                                        ),
                                      ),
                                    ),
                                  ],
                                ),
                              );
                            },
                          )),
              ),
              const SizedBox(height: 10),
              Row(
                children: [
                  const Text('歸檔到：', style: TextStyle(color: Color(0xFFD1D5DB), fontSize: 12.5)),
                  const SizedBox(width: 8),
                  Expanded(
                    child: DropdownButtonFormField<String>(
                      initialValue: _rooms.any((r) => r.roomId == _targetRoomId)
                          ? _targetRoomId
                          : (_rooms.isNotEmpty ? _rooms.first.roomId : null),
                      dropdownColor: const Color(0xFF1E222B),
                      style: const TextStyle(color: Colors.white, fontSize: 13),
                      decoration: InputDecoration(
                        isDense: true,
                        filled: true,
                        fillColor: const Color(0xFF111317),
                        contentPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(10),
                          borderSide: BorderSide(color: Colors.white.withValues(alpha: 0.14)),
                        ),
                      ),
                      items: [
                        for (final r in _rooms)
                          DropdownMenuItem(
                            value: r.roomId,
                            child: Text(r.title, overflow: TextOverflow.ellipsis),
                          ),
                      ],
                      onChanged: (val) {
                        if (val != null) setState(() => _targetRoomId = val);
                      },
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _noteController,
                      style: const TextStyle(color: Colors.white, fontSize: 13),
                      decoration: InputDecoration(
                        hintText: '統一備註（選填，例：今天現勘門洞照）',
                        hintStyle: const TextStyle(color: Color(0xFF6B7280), fontSize: 12),
                        filled: true,
                        fillColor: const Color(0xFF111317),
                        isDense: true,
                        contentPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(10),
                          borderSide: BorderSide(color: Colors.white.withValues(alpha: 0.14)),
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  ElevatedButton(
                    style: ElevatedButton.styleFrom(
                      backgroundColor: const Color(0xFFF59E0B),
                      foregroundColor: const Color(0xFF111317),
                      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                    ),
                    onPressed: (_selectedIds.isEmpty || _archiving) ? null : _archiveSelected,
                    child: _archiving
                        ? const SizedBox(
                            width: 16,
                            height: 16,
                            child: CircularProgressIndicator(strokeWidth: 2, color: Color(0xFF111317)),
                          )
                        : Text(
                            '📥 歸檔 (${_selectedIds.length})',
                            style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 13),
                          ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}
