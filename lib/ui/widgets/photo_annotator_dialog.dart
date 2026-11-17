import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

class DimensionAnnotation {
  const DimensionAnnotation({
    required this.startNorm,
    required this.endNorm,
    required this.label,
    required this.color,
  });

  final Offset startNorm;
  final Offset endNorm;
  final String label;
  final Color color;
}

class AnnotatedPhotoResult {
  const AnnotatedPhotoResult({
    required this.savedPath,
    required this.bytes,
    required this.labels,
    required this.note,
    required this.width,
    required this.height,
  });

  final String savedPath;
  final Uint8List bytes;
  final List<String> labels;
  final String note;
  final int width;
  final int height;
}

Future<AnnotatedPhotoResult?> showPhotoAnnotatorDialog({
  required BuildContext context,
  required String imagePath,
  String initialNote = '',
}) async {
  return showDialog<AnnotatedPhotoResult>(
    context: context,
    barrierDismissible: false,
    barrierColor: Colors.black.withValues(alpha: 0.92),
    builder: (ctx) => _PhotoAnnotatorDialog(
      imagePath: imagePath,
      initialNote: initialNote,
    ),
  );
}

class _PhotoAnnotatorDialog extends StatefulWidget {
  const _PhotoAnnotatorDialog({
    required this.imagePath,
    required this.initialNote,
  });

  final String imagePath;
  final String initialNote;

  @override
  State<_PhotoAnnotatorDialog> createState() => _PhotoAnnotatorDialogState();
}

class _PhotoAnnotatorDialogState extends State<_PhotoAnnotatorDialog> {
  static const List<Color> _palette = [
    Color(0xFFEF4444), // 工安紅
    Color(0xFFF59E0B), // 琥珀黃
    Color(0xFF10B981), // 螢光綠
    Color(0xFF38BDF8), // 科技藍
    Colors.white,
  ];

  ui.Image? _uiImage;
  String? _loadError;
  final List<DimensionAnnotation> _annotations = [];
  Color _activeColor = _palette[0];
  Offset? _dragStartNorm;
  Offset? _dragCurrentNorm;
  late final TextEditingController _noteController;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _noteController = TextEditingController(text: widget.initialNote);
    _loadUiImage();
  }

  @override
  void dispose() {
    _noteController.dispose();
    _uiImage?.dispose();
    super.dispose();
  }

  Future<void> _loadUiImage() async {
    try {
      final bytes = await File(widget.imagePath).readAsBytes();
      final codec = await ui.instantiateImageCodec(bytes);
      final frame = await codec.getNextFrame();
      if (!mounted) {
        frame.image.dispose();
        return;
      }
      setState(() {
        _uiImage = frame.image;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _loadError = '圖片載入失敗：$e');
    }
  }

  Offset _toNorm(Offset local, Size boxSize) {
    return Offset(
      (local.dx / boxSize.width).clamp(0.0, 1.0),
      (local.dy / boxSize.height).clamp(0.0, 1.0),
    );
  }

  Future<String?> _promptDimensionLabel(BuildContext context) async {
    final ctrl = TextEditingController();
    const quickChips = ['mm', 'cm', ' × ', ' 支', 'H=', 'W='];
    return showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF1A1E26),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(18),
          side: BorderSide(color: Colors.white.withValues(alpha: 0.14)),
        ),
        title: const Text(
          '📏 輸入這條線的尺寸標註',
          style: TextStyle(color: Colors.white, fontSize: 15),
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            TextField(
              controller: ctrl,
              autofocus: true,
              style: const TextStyle(color: Colors.white, fontSize: 15),
              decoration: InputDecoration(
                hintText: '例：2450mm 或 W=1800×H=900',
                hintStyle: const TextStyle(color: Color(0xFF6B7280), fontSize: 13),
                filled: true,
                fillColor: const Color(0xFF111317),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(10),
                  borderSide: BorderSide(color: Colors.white.withValues(alpha: 0.14)),
                ),
              ),
              onSubmitted: (val) => Navigator.of(ctx).pop(val.trim()),
            ),
            const SizedBox(height: 10),
            Wrap(
              spacing: 6,
              runSpacing: 6,
              children: [
                for (final chip in quickChips)
                  ActionChip(
                    backgroundColor: const Color(0xFF111317),
                    side: BorderSide(color: Colors.white.withValues(alpha: 0.16)),
                    label: Text(
                      chip.trim(),
                      style: const TextStyle(color: Color(0xFFFCD34D), fontSize: 12),
                    ),
                    onPressed: () {
                      final next = '${ctrl.text}$chip';
                      ctrl.value = TextEditingValue(
                        text: next,
                        selection: TextSelection.collapsed(offset: next.length),
                      );
                    },
                  ),
              ],
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(null),
            child: const Text('取消這條', style: TextStyle(color: Color(0xFF9CA3AF))),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(
              backgroundColor: const Color(0xFFF59E0B),
              foregroundColor: const Color(0xFF111317),
            ),
            onPressed: () => Navigator.of(ctx).pop(ctrl.text.trim()),
            child: const Text('確定標註', style: TextStyle(fontWeight: FontWeight.bold)),
          ),
        ],
      ),
    );
  }

  Future<void> _saveComposite() async {
    final src = _uiImage;
    if (src == null || _saving) return;
    setState(() => _saving = true);

    try {
      final maxDim = math.max(src.width, src.height);
      final scale = maxDim > 1280 ? 1280.0 / maxDim : 1.0;
      final outW = (src.width * scale).round().clamp(1, 1280);
      final outH = (src.height * scale).round().clamp(1, 1280);

      final recorder = ui.PictureRecorder();
      final canvas = Canvas(
        recorder,
        Rect.fromLTWH(0, 0, outW.toDouble(), outH.toDouble()),
      );

      final paint = Paint()..filterQuality = FilterQuality.high;
      canvas.drawImageRect(
        src,
        Rect.fromLTWH(0, 0, src.width.toDouble(), src.height.toDouble()),
        Rect.fromLTWH(0, 0, outW.toDouble(), outH.toDouble()),
        paint,
      );

      _DimensionCanvasPainter.paintAnnotations(
        canvas: canvas,
        size: Size(outW.toDouble(), outH.toDouble()),
        annotations: _annotations,
        strokeScale: math.max(1.0, outW / 420.0),
      );

      final picture = recorder.endRecording();
      final composed = await picture.toImage(outW, outH);
      final byteData = await composed.toByteData(format: ui.ImageByteFormat.png);
      composed.dispose();
      picture.dispose();

      if (byteData == null) {
        throw StateError('無法產生合成圖檔');
      }
      final pngBytes = byteData.buffer.asUint8List();

      final appDir = await getApplicationDocumentsDirectory();
      final photosDir = Directory(p.join(appDir.path, 'xiaoliu_photos'));
      if (!await photosDir.exists()) {
        await photosDir.create(recursive: true);
      }
      final filePath = p.join(
        photosDir.path,
        'annotated_${DateTime.now().millisecondsSinceEpoch}.png',
      );
      await File(filePath).writeAsBytes(pngBytes, flush: true);

      if (!mounted) return;
      Navigator.of(context).pop(
        AnnotatedPhotoResult(
          savedPath: filePath,
          bytes: pngBytes,
          labels: _annotations.map((a) => a.label).where((l) => l.isNotEmpty).toList(),
          note: _noteController.text.trim(),
          width: outW,
          height: outH,
        ),
      );
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _saving = false;
        _loadError = '合成存檔失敗：$e';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final img = _uiImage;
    return Dialog.fullscreen(
      backgroundColor: const Color(0xFF0E1014),
      child: SafeArea(
        child: Column(
          children: [
            // Top bar
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
              decoration: BoxDecoration(
                color: const Color(0xFF16191F),
                border: Border(bottom: BorderSide(color: Colors.white.withValues(alpha: 0.1))),
              ),
              child: Row(
                children: [
                  IconButton(
                    icon: const Icon(Icons.close, color: Colors.white),
                    onPressed: _saving ? null : () => Navigator.of(context).pop(),
                  ),
                  const Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          '📏 工地量測尺寸標註',
                          style: TextStyle(color: Colors.white, fontSize: 15, fontWeight: FontWeight.bold),
                        ),
                        Text(
                          '手指在圖上拖曳畫出雙向尺寸線，放開即填數字',
                          style: TextStyle(color: Color(0xFF9CA3AF), fontSize: 11.5),
                        ),
                      ],
                    ),
                  ),
                  TextButton.icon(
                    onPressed: (_annotations.isEmpty || _saving)
                        ? null
                        : () => setState(() => _annotations.removeLast()),
                    icon: const Icon(Icons.undo, size: 18),
                    label: const Text('復原'),
                  ),
                  const SizedBox(width: 4),
                  ElevatedButton(
                    style: ElevatedButton.styleFrom(
                      backgroundColor: const Color(0xFFF59E0B),
                      foregroundColor: const Color(0xFF111317),
                    ),
                    onPressed: (_saving || img == null) ? null : _saveComposite,
                    child: _saving
                        ? const SizedBox(
                            width: 16,
                            height: 16,
                            child: CircularProgressIndicator(strokeWidth: 2, color: Color(0xFF111317)),
                          )
                        : const Text('💾 存入', style: TextStyle(fontWeight: FontWeight.bold)),
                  ),
                ],
              ),
            ),

            // Canvas workspace
            Expanded(
              child: Center(
                child: _loadError != null
                    ? Padding(
                        padding: const EdgeInsets.all(20),
                        child: Text(_loadError!, style: const TextStyle(color: Color(0xFFFCA5A5))),
                      )
                    : (img == null
                        ? const CircularProgressIndicator(color: Color(0xFFF59E0B))
                        : LayoutBuilder(
                            builder: (context, constraints) {
                              final aspect = img.width / img.height;
                              var drawW = constraints.maxWidth - 16;
                              var drawH = drawW / aspect;
                              if (drawH > constraints.maxHeight - 16) {
                                drawH = constraints.maxHeight - 16;
                                drawW = drawH * aspect;
                              }
                              final boxSize = Size(drawW, drawH);

                              return GestureDetector(
                                onPanStart: (details) {
                                  final norm = _toNorm(details.localPosition, boxSize);
                                  setState(() {
                                    _dragStartNorm = norm;
                                    _dragCurrentNorm = norm;
                                  });
                                },
                                onPanUpdate: (details) {
                                  final norm = _toNorm(details.localPosition, boxSize);
                                  setState(() => _dragCurrentNorm = norm);
                                },
                                onPanEnd: (_) async {
                                  final start = _dragStartNorm;
                                  final end = _dragCurrentNorm;
                                  setState(() {
                                    _dragStartNorm = null;
                                    _dragCurrentNorm = null;
                                  });
                                  if (start == null || end == null) return;
                                  final dx = (end.dx - start.dx) * boxSize.width;
                                  final dy = (end.dy - start.dy) * boxSize.height;
                                  if (math.sqrt(dx * dx + dy * dy) < 14) return;

                                  final label = await _promptDimensionLabel(context);
                                  if (label == null || !mounted) return;
                                  setState(() {
                                    _annotations.add(
                                      DimensionAnnotation(
                                        startNorm: start,
                                        endNorm: end,
                                        label: label,
                                        color: _activeColor,
                                      ),
                                    );
                                  });
                                },
                                child: SizedBox(
                                  width: drawW,
                                  height: drawH,
                                  child: Stack(
                                    fit: StackFit.expand,
                                    children: [
                                      RawImage(image: img, fit: BoxFit.fill),
                                      CustomPaint(
                                        painter: _DimensionCanvasPainter(
                                          annotations: _annotations,
                                          activeStart: _dragStartNorm,
                                          activeEnd: _dragCurrentNorm,
                                          activeColor: _activeColor,
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                              );
                            },
                          )),
              ),
            ),

            // Bottom toolbar: colors + note
            Container(
              padding: const EdgeInsets.fromLTRB(12, 10, 12, 12),
              decoration: BoxDecoration(
                color: const Color(0xFF16191F),
                border: Border(top: BorderSide(color: Colors.white.withValues(alpha: 0.1))),
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Row(
                    children: [
                      const Text('標線顏色：', style: TextStyle(color: Color(0xFF9CA3AF), fontSize: 12)),
                      for (final c in _palette)
                        GestureDetector(
                          onTap: () => setState(() => _activeColor = c),
                          child: Container(
                            margin: const EdgeInsets.symmetric(horizontal: 5),
                            width: 24,
                            height: 24,
                            decoration: BoxDecoration(
                              color: c,
                              shape: BoxShape.circle,
                              border: Border.all(
                                color: _activeColor == c ? const Color(0xFFF59E0B) : Colors.black54,
                                width: _activeColor == c ? 3 : 1,
                              ),
                            ),
                          ),
                        ),
                      const Spacer(),
                      if (_annotations.isNotEmpty)
                        TextButton(
                          onPressed: () => setState(() => _annotations.clear()),
                          child: const Text('清空標註', style: TextStyle(color: Color(0xFFFB7185), fontSize: 12)),
                        ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  TextField(
                    controller: _noteController,
                    style: const TextStyle(color: Colors.white, fontSize: 13),
                    decoration: InputDecoration(
                      hintText: '補充現場備註（例：一樓大門框洞口實測）',
                      hintStyle: const TextStyle(color: Color(0xFF6B7280), fontSize: 12),
                      filled: true,
                      fillColor: const Color(0xFF0E1014),
                      isDense: true,
                      contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(10),
                        borderSide: BorderSide(color: Colors.white.withValues(alpha: 0.12)),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _DimensionCanvasPainter extends CustomPainter {
  const _DimensionCanvasPainter({
    required this.annotations,
    this.activeStart,
    this.activeEnd,
    required this.activeColor,
  });

  final List<DimensionAnnotation> annotations;
  final Offset? activeStart;
  final Offset? activeEnd;
  final Color activeColor;

  @override
  void paint(Canvas canvas, Size size) {
    paintAnnotations(
      canvas: canvas,
      size: size,
      annotations: annotations,
      strokeScale: 1.0,
    );
    if (activeStart != null && activeEnd != null) {
      paintSingleAnnotation(
        canvas: canvas,
        size: size,
        ann: DimensionAnnotation(
          startNorm: activeStart!,
          endNorm: activeEnd!,
          label: '放開填尺寸',
          color: activeColor,
        ),
        strokeScale: 1.0,
      );
    }
  }

  static void paintAnnotations({
    required Canvas canvas,
    required Size size,
    required List<DimensionAnnotation> annotations,
    required double strokeScale,
  }) {
    for (final ann in annotations) {
      paintSingleAnnotation(
        canvas: canvas,
        size: size,
        ann: ann,
        strokeScale: strokeScale,
      );
    }
  }

  static void paintSingleAnnotation({
    required Canvas canvas,
    required Size size,
    required DimensionAnnotation ann,
    required double strokeScale,
  }) {
    final p1 = Offset(ann.startNorm.dx * size.width, ann.startNorm.dy * size.height);
    final p2 = Offset(ann.endNorm.dx * size.width, ann.endNorm.dy * size.height);
    final dx = p2.dx - p1.dx;
    final dy = p2.dy - p1.dy;
    final len = math.sqrt(dx * dx + dy * dy);
    if (len < 2) return;

    final ux = dx / len;
    final uy = dy / len;
    final nx = -uy;
    final ny = ux;

    // Dark outline behind colored line so white/yellow lines stay crisp on bright backgrounds.
    final haloPaint = Paint()
      ..color = Colors.black.withValues(alpha: 0.72)
      ..strokeWidth = 4.5 * strokeScale
      ..strokeCap = StrokeCap.round
      ..style = PaintingStyle.stroke;

    final linePaint = Paint()
      ..color = ann.color
      ..strokeWidth = 2.6 * strokeScale
      ..strokeCap = StrokeCap.round
      ..style = PaintingStyle.stroke;

    void drawVector(Offset a, Offset b) {
      canvas.drawLine(a, b, haloPaint);
      canvas.drawLine(a, b, linePaint);
    }

    // Main line
    drawVector(p1, p2);

    // End ticks (perpendicular stop bars)
    final tick = 8.0 * strokeScale;
    drawVector(
      Offset(p1.dx - nx * tick, p1.dy - ny * tick),
      Offset(p1.dx + nx * tick, p1.dy + ny * tick),
    );
    drawVector(
      Offset(p2.dx - nx * tick, p2.dy - ny * tick),
      Offset(p2.dx + nx * tick, p2.dy + ny * tick),
    );

    // Arrowheads at both ends
    final arrowLen = math.min(12.0 * strokeScale, len * 0.35);
    const arrowSpread = 0.45;
    final angle = math.atan2(dy, dx);
    drawVector(
      p1,
      Offset(
        p1.dx + arrowLen * math.cos(angle + arrowSpread),
        p1.dy + arrowLen * math.sin(angle + arrowSpread),
      ),
    );
    drawVector(
      p1,
      Offset(
        p1.dx + arrowLen * math.cos(angle - arrowSpread),
        p1.dy + arrowLen * math.sin(angle - arrowSpread),
      ),
    );
    drawVector(
      p2,
      Offset(
        p2.dx - arrowLen * math.cos(angle + arrowSpread),
        p2.dy - arrowLen * math.sin(angle + arrowSpread),
      ),
    );
    drawVector(
      p2,
      Offset(
        p2.dx - arrowLen * math.cos(angle - arrowSpread),
        p2.dy - arrowLen * math.sin(angle - arrowSpread),
      ),
    );

    if (ann.label.trim().isEmpty) return;

    final tp = TextPainter(
      text: TextSpan(
        text: ann.label.trim(),
        style: TextStyle(
          color: Colors.white,
          fontSize: 13.5 * strokeScale,
          fontWeight: FontWeight.bold,
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout();

    final mid = Offset((p1.dx + p2.dx) / 2, (p1.dy + p2.dy) / 2);
    final padX = 7.0 * strokeScale;
    final padY = 3.5 * strokeScale;
    final rect = Rect.fromCenter(
      center: mid,
      width: tp.width + padX * 2,
      height: tp.height + padY * 2,
    );
    final rrect = RRect.fromRectAndRadius(rect, Radius.circular(6 * strokeScale));

    canvas.drawRRect(
      rrect,
      Paint()..color = const Color(0xDD111317),
    );
    canvas.drawRRect(
      rrect,
      Paint()
        ..color = ann.color
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.6 * strokeScale,
    );

    tp.paint(canvas, Offset(rect.left + padX, rect.top + padY));
  }

  @override
  bool shouldRepaint(covariant _DimensionCanvasPainter oldDelegate) => true;
}
