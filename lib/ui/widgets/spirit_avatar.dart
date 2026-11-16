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

    // Permanent room accessory layer (protected for main & sleep)
    if (!isMain && accessory != 'sleep') {
      final hasWorkingHelmet = state == SpiritState.working;
      switch (accessory) {
        case 'helmet':
          if (!hasWorkingHelmet) _drawSafetyHelmet(canvas);
          break;
        case 'bulb':
          if (!hasWorkingHelmet) _drawLightBulb(canvas, progress);
          break;
        case 'home':
          if (!hasWorkingHelmet) _drawHomeRoof(canvas);
          break;
        case 'wrench':
          _drawSilverWrench(canvas);
          break;
        case 'box':
          _drawCargoBox(canvas);
          break;
        case 'glasses':
          _drawSunglasses(canvas);
          break;
        case 'fish':
          _drawLittleFish(canvas);
          break;
      }
    }

    // Dynamic state indicators
    if (state == SpiritState.working) {
      _drawSafetyHelmet(canvas);
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
    }

    canvas.restore();
  }

  void _drawSafetyHelmet(Canvas canvas) {
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
      Paint()..color = const Color(0xFFFEF3C7),
    );
  }

  void _drawSilverWrench(Canvas canvas) {
    canvas.save();
    canvas.translate(43.5, 29.5);
    canvas.rotate(-0.45);
    // Wrench shaft
    canvas.drawRRect(
      RRect.fromRectAndRadius(const Rect.fromLTWH(-2.1, -6, 4.2, 16), const Radius.circular(2.1)),
      Paint()..color = const Color(0xFFCBD5E1),
    );
    canvas.drawRRect(
      RRect.fromRectAndRadius(const Rect.fromLTWH(-2.1, -6, 4.2, 16), const Radius.circular(2.1)),
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 0.9
        ..color = const Color(0xFF475569),
    );
    // Wrench C-head
    final head = Path()
      ..addOval(const Rect.fromLTWH(-4.6, -11, 9.2, 7.6));
    canvas.drawPath(head, Paint()..color = const Color(0xFFE2E8F0));
    canvas.drawPath(
      head,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 0.9
        ..color = const Color(0xFF475569),
    );
    // Notch in C-head
    canvas.drawRect(
      const Rect.fromLTWH(-1.7, -11.5, 3.4, 4.2),
      Paint()..color = const Color(0xFF111317),
    );
    canvas.restore();
  }

  void _drawCargoBox(Canvas canvas) {
    final boxRect = RRect.fromRectAndRadius(
      const Rect.fromLTWH(35.5, 24.5, 13.5, 12.5),
      const Radius.circular(2.2),
    );
    canvas.drawRRect(boxRect, Paint()..color = const Color(0xFFD97706));
    canvas.drawRRect(
      boxRect,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.1
        ..color = const Color(0xFF78350F),
    );
    // Top tape & center seam
    canvas.drawRect(
      const Rect.fromLTWH(35.8, 28.2, 12.9, 1.4),
      Paint()..color = const Color(0xFF92400E),
    );
    canvas.drawRect(
      const Rect.fromLTWH(40.7, 24.8, 3.1, 4.2),
      Paint()..color = const Color(0xFFFDE68A),
    );
  }

  void _drawLightBulb(Canvas canvas, double progress) {
    final glowAlpha = 0.55 + 0.45 * math.sin(progress * math.pi * 2).abs();
    // Soft glow halo
    canvas.drawCircle(
      const Offset(26.5, 6.2),
      6.5,
      Paint()..color = const Color(0xFFFDE047).withValues(alpha: 0.25 * glowAlpha),
    );
    // Bulb glass
    canvas.drawCircle(
      const Offset(26.5, 6.2),
      4.3,
      Paint()..color = const Color(0xFFFACC15),
    );
    // Screw base
    canvas.drawRRect(
      RRect.fromRectAndRadius(const Rect.fromLTWH(24.3, 9.8, 4.4, 2.8), const Radius.circular(1)),
      Paint()..color = const Color(0xFF94A3B8),
    );
    // Light rays
    final rayPaint = Paint()
      ..color = const Color(0xFFFEF08A).withValues(alpha: glowAlpha)
      ..strokeWidth = 1.2
      ..strokeCap = StrokeCap.round;
    canvas.drawLine(const Offset(26.5, 0.2), const Offset(26.5, 1.4), rayPaint);
    canvas.drawLine(const Offset(20.2, 2.4), const Offset(21.4, 3.4), rayPaint);
    canvas.drawLine(const Offset(32.8, 2.4), const Offset(31.6, 3.4), rayPaint);
  }

  void _drawSunglasses(Canvas canvas) {
    final lensPaint = Paint()..color = const Color(0xFF0F172A);
    final framePaint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.3
      ..color = const Color(0xFFE2E8F0);

    final leftLens = RRect.fromRectAndRadius(
      const Rect.fromLTWH(15.5, 22.2, 9.5, 6.5),
      const Radius.circular(2.2),
    );
    final rightLens = RRect.fromRectAndRadius(
      const Rect.fromLTWH(28.0, 22.2, 9.5, 6.5),
      const Radius.circular(2.2),
    );
    canvas.drawRRect(leftLens, lensPaint);
    canvas.drawRRect(rightLens, lensPaint);
    canvas.drawRRect(leftLens, framePaint);
    canvas.drawRRect(rightLens, framePaint);

    // Bridge & temples
    canvas.drawLine(const Offset(25.0, 24.4), const Offset(28.0, 24.4), framePaint);
    canvas.drawLine(const Offset(11.5, 23.6), const Offset(15.5, 24.0), framePaint);
    canvas.drawLine(const Offset(37.5, 24.0), const Offset(41.5, 23.6), framePaint);

    // Cool white diagonal glint
    final glint = Paint()
      ..color = Colors.white.withValues(alpha: 0.75)
      ..strokeWidth = 1.2
      ..strokeCap = StrokeCap.round;
    canvas.drawLine(const Offset(17.5, 26.8), const Offset(20.2, 23.8), glint);
    canvas.drawLine(const Offset(30.0, 26.8), const Offset(32.7, 23.8), glint);
  }

  void _drawLittleFish(Canvas canvas) {
    canvas.save();
    canvas.translate(42.5, 30.0);
    // Tail fin
    final tail = Path()
      ..moveTo(3.5, 0)
      ..lineTo(8.5, -3.8)
      ..lineTo(8.5, 3.8)
      ..close();
    canvas.drawPath(tail, Paint()..color = const Color(0xFF0284C7));
    // Fish body
    canvas.drawOval(
      const Rect.fromLTWH(-6.5, -3.8, 11.2, 7.6),
      Paint()..color = const Color(0xFF38BDF8),
    );
    canvas.drawOval(
      const Rect.fromLTWH(-6.5, -3.8, 11.2, 7.6),
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 0.9
        ..color = const Color(0xFF0369A1),
    );
    // Cute eye
    canvas.drawCircle(const Offset(-3.2, -0.8), 1.1, Paint()..color = Colors.white);
    canvas.drawCircle(const Offset(-3.4, -0.8), 0.55, Paint()..color = const Color(0xFF0F172A));
    canvas.restore();
  }

  void _drawHomeRoof(Canvas canvas) {
    // Chimney
    canvas.drawRect(
      const Rect.fromLTWH(32.5, 7.2, 3.2, 5.2),
      Paint()..color = const Color(0xFF94A3B8),
    );
    // Warm pitched roof
    final roof = Path()
      ..moveTo(13.0, 15.5)
      ..lineTo(26.5, 5.2)
      ..lineTo(40.0, 15.5);
    canvas.drawPath(
      roof,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 3.2
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round
        ..color = const Color(0xFFFB7185),
    );
    canvas.drawPath(
      roof,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.2
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round
        ..color = const Color(0xFFFFE4E6),
    );
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
