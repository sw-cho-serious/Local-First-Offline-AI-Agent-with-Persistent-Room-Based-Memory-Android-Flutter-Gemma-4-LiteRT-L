import 'dart:math' as math;
import 'package:flutter/material.dart';

import '../../data/models.dart';

Color parseHexColor(String hex, {Color fallback = const Color(0xFFF59E0B)}) {
  var cleaned = hex.replaceAll('#', '').trim();
  if (cleaned.length == 6) cleaned = 'FF$cleaned';
  final value = int.tryParse(cleaned, radix: 16);
  if (value == null) return fallback;
  return Color(value);
}

class SpiritAvatar extends StatefulWidget {
  const SpiritAvatar({
    super.key,
    required this.colorHex,
    required this.state,
    this.size = 40,
    this.isMain = false,
    this.accessory = 'helmet',
  });

  final String colorHex;
  final SpiritState state;
  final double size;
  final bool isMain;
  final String accessory;

  @override
  State<SpiritAvatar> createState() => _SpiritAvatarState();
}

class _SpiritAvatarState extends State<SpiritAvatar>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 2800),
    )..repeat();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: widget.size,
      height: widget.size,
      child: AnimatedBuilder(
        animation: _controller,
        builder: (context, _) {
          return CustomPaint(
            painter: _SpiritPainter(
              progress: _controller.value,
              bodyColor: parseHexColor(widget.colorHex),
              state: widget.state,
              isMain: widget.isMain,
              accessory: widget.accessory,
            ),
          );
        },
      ),
    );
  }
}

class _SpiritPainter extends CustomPainter {
  _SpiritPainter({
    required this.progress,
    required this.bodyColor,
    required this.state,
    required this.isMain,
    required this.accessory,
  });

  final double progress;
  final Color bodyColor;
  final SpiritState state;
  final bool isMain;
  final String accessory;

  @override
  void paint(Canvas canvas, Size size) {
    final scale = size.width / 54.0;
    canvas.save();
    canvas.scale(scale, scale);

    // Subtle vertical bobbing / bounce depending on state
    double dy = 0;
    double rot = 0;
    if (state == SpiritState.idle) {
      dy = -2.2 * math.sin(progress * math.pi * 2);
    } else if (state == SpiritState.working) {
      final cycle = progress * 4.0;
      dy = -3.2 * math.sin(cycle * math.pi * 2).abs();
      rot = 0.06 * math.sin(cycle * math.pi * 2);
    } else if (state == SpiritState.thinking) {
      dy = -1.5 * math.sin(progress * math.pi * 4);
    }

    // Soft ground shadow
    final shadowPaint = Paint()..color = Colors.black.withValues(alpha: 0.4);
    canvas.drawOval(
      const Rect.fromLTWH(12.5, 41, 28, 6),
      shadowPaint,
    );

    canvas.translate(26.5, 28 + dy);
    canvas.rotate(rot);
    canvas.translate(-26.5, -28);

    // Fixed geometric droplet silhouette
    final bodyPath = Path()
      ..moveTo(26.5, 10)
      ..cubicTo(37, 10, 44, 22, 43, 33)
      ..cubicTo(42.5, 39, 36, 42, 26.5, 42)
      ..cubicTo(17, 42, 10.5, 39, 10, 33)
      ..cubicTo(9, 22, 16, 10, 26.5, 10)
      ..close();

    canvas.drawPath(bodyPath, Paint()..color = bodyColor);

    final isLightBody = bodyColor.computeLuminance() > 0.55;
    final strokePaint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = isMain ? 2.1 : 1.5
      ..color = isMain
          ? const Color(0xFFF59E0B)
          : (isLightBody
              ? const Color(0xFF9CA3AF)
              : Colors.white.withValues(alpha: 0.28));
    canvas.drawPath(bodyPath, strokePaint);

    // Eyes
    final eyeColor = isLightBody ? const Color(0xFF1F2937) : Colors.white;
    final eyePaint = Paint()..color = eyeColor;

    if (state == SpiritState.done) {
      final archPaint = Paint()
        ..color = eyeColor
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2.4
        ..strokeCap = StrokeCap.round;
      final leftEye = Path()
        ..moveTo(18, 27)
        ..quadraticBezierTo(21, 24, 24, 27);
      final rightEye = Path()
        ..moveTo(29, 27)
        ..quadraticBezierTo(32, 24, 35, 27);
      canvas.drawPath(leftEye, archPaint);
      canvas.drawPath(rightEye, archPaint);
    } else if (state == SpiritState.stuck) {
      canvas.drawRRect(
        RRect.fromRectAndRadius(const Rect.fromLTWH(19, 23, 4, 7), const Radius.circular(2)),
        eyePaint,
      );
      canvas.drawRRect(
        RRect.fromRectAndRadius(const Rect.fromLTWH(30, 25, 4, 4), const Radius.circular(2)),
        eyePaint,
      );
    } else if (state == SpiritState.thinking) {
      final glanceX = 1.5 * math.sin(progress * math.pi * 4);
      canvas.drawRRect(
        RRect.fromRectAndRadius(Rect.fromLTWH(20 + glanceX, 22, 4, 7), const Radius.circular(2)),
        eyePaint,
      );
      canvas.drawRRect(
        RRect.fromRectAndRadius(Rect.fromLTWH(30 + glanceX, 22, 4, 7), const Radius.circular(2)),
        eyePaint,
      );
    } else if (state == SpiritState.waiting) {
      // Half-lidded chill look
      canvas.drawRRect(
        RRect.fromRectAndRadius(const Rect.fromLTWH(19, 25, 4.2, 4), const Radius.circular(2)),
        eyePaint,
      );
      canvas.drawRRect(
        RRect.fromRectAndRadius(const Rect.fromLTWH(30, 25, 4.2, 4), const Radius.circular(2)),
        eyePaint,
      );
    } else {
      // Natural blink every ~3s
      final blinkPhase = (progress * 1.0) % 1.0;
      final isBlinking = blinkPhase > 0.93 && blinkPhase < 0.98;
      final eyeH = isBlinking ? 1.5 : 7.5;
      final eyeY = isBlinking ? 26.0 : 23.0;
      canvas.drawRRect(
        RRect.fromRectAndRadius(Rect.fromLTWH(19, eyeY, 4, eyeH), const Radius.circular(2)),
        eyePaint,
      );
      canvas.drawRRect(
        RRect.fromRectAndRadius(Rect.fromLTWH(30, eyeY, 4, eyeH), const Radius.circular(2)),
        eyePaint,
      );
    }

    // Accessories & state indicators
    if (state == SpiritState.working) {
      // Yellow safety helmet
      final dome = Path()
        ..moveTo(14, 18)
        ..cubicTo(14, 8.5, 39, 8.5, 39, 18)
        ..close();
      canvas.drawPath(dome, Paint()..color = const Color(0xFFFBBF24));
      canvas.drawPath(
        dome,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.2
          ..color = const Color(0xFF92400E),
      );
      canvas.drawRRect(
        RRect.fromRectAndRadius(const Rect.fromLTWH(11, 17, 31, 3.5), const Radius.circular(1.7)),
        Paint()..color = const Color(0xFFF59E0B),
      );
      canvas.drawRRect(
        RRect.fromRectAndRadius(const Rect.fromLTWH(24, 10, 5, 6), const Radius.circular(1.5)),
        Paint()..color = const Color(0xFFFDE68A),
      );
    } else if (state == SpiritState.thinking) {
      final a1 = 0.4 + 0.6 * math.sin(progress * math.pi * 4).abs();
      final a2 = 0.4 + 0.6 * math.cos(progress * math.pi * 4).abs();
      canvas.drawCircle(
        const Offset(42, 11),
        2.3,
        Paint()..color = const Color(0xFF38BDF8).withValues(alpha: a1),
      );
      canvas.drawCircle(
        const Offset(47, 7),
        2.7,
        Paint()..color = const Color(0xFF38BDF8).withValues(alpha: a2),
      );
    } else if (state == SpiritState.done) {
      canvas.drawCircle(const Offset(42, 11), 6, Paint()..color = const Color(0xFF10B981));
      final check = Path()
        ..moveTo(39, 11)
        ..lineTo(41.2, 13.2)
        ..lineTo(45.5, 8.8);
      canvas.drawPath(
        check,
        Paint()
          ..color = Colors.white
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.8
          ..strokeCap = StrokeCap.round
          ..strokeJoin = StrokeJoin.round,
      );
    } else if (state == SpiritState.stuck) {
      final tp = TextPainter(
        text: const TextSpan(
          text: '?',
          style: TextStyle(
            color: Color(0xFFFB7185),
            fontSize: 14,
            fontWeight: FontWeight.bold,
          ),
        ),
        textDirection: TextDirection.ltr,
      )..layout();
      tp.paint(canvas, const Offset(40, 2));
    } else if (accessory == 'wrench') {
      // Subtle amber dot badge for factory tuning rooms
      canvas.drawCircle(const Offset(41, 13), 3.5, Paint()..color = const Color(0xFFF59E0B));
    }

    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant _SpiritPainter oldDelegate) {
    return oldDelegate.progress != progress ||
        oldDelegate.bodyColor != bodyColor ||
        oldDelegate.state != state ||
        oldDelegate.isMain != isMain ||
        oldDelegate.accessory != accessory;
  }
}
