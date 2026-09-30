import 'dart:math' as math;

import 'package:flutter/material.dart';

/// A small looping "steaming coffee cup" animation shown while the app
/// waits on a network call (e.g. starting a payment), matching this
/// canteen app's coffee branding instead of a generic spinner.
class CoffeeLoadingAnimation extends StatefulWidget {
  final double size;
  final Color color;

  const CoffeeLoadingAnimation({super.key, this.size = 72, required this.color});

  @override
  State<CoffeeLoadingAnimation> createState() => _CoffeeLoadingAnimationState();
}

class _CoffeeLoadingAnimationState extends State<CoffeeLoadingAnimation> with SingleTickerProviderStateMixin {
  late final AnimationController _controller;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(vsync: this, duration: const Duration(seconds: 2))..repeat();
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
      height: widget.size * 1.15,
      child: AnimatedBuilder(
        animation: _controller,
        builder: (context, _) => CustomPaint(
          painter: _CoffeeCupPainter(progress: _controller.value, color: widget.color),
        ),
      ),
    );
  }
}

class _CoffeeCupPainter extends CustomPainter {
  final double progress; // loops 0..1
  final Color color;

  _CoffeeCupPainter({required this.progress, required this.color});

  @override
  void paint(Canvas canvas, Size size) {
    final fillPaint = Paint()..color = color;
    final outlinePaint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = size.width * 0.035
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;

    final cupTop = size.height * 0.52;
    final cupBottom = size.height * 0.88;
    final cupLeft = size.width * 0.18;
    final cupRight = size.width * 0.72;

    // Saucer
    canvas.drawOval(
      Rect.fromCenter(center: Offset(size.width * 0.45, cupBottom + size.height * 0.04), width: size.width * 0.78, height: size.height * 0.07),
      fillPaint,
    );

    // Cup body
    final cupPath = Path()
      ..moveTo(cupLeft, cupTop)
      ..lineTo(cupRight, cupTop)
      ..lineTo(cupRight - size.width * 0.05, cupBottom)
      ..lineTo(cupLeft + size.width * 0.05, cupBottom)
      ..close();
    canvas.drawPath(cupPath, outlinePaint);

    // Handle
    canvas.drawArc(
      Rect.fromCenter(center: Offset(cupRight + size.width * 0.05, (cupTop + cupBottom) / 2), width: size.width * 0.22, height: size.height * 0.22),
      -math.pi / 2.3,
      math.pi * 1.5,
      false,
      outlinePaint,
    );

    // Three wavy steam trails, staggered so they rise and fade on a loop
    for (int i = 0; i < 3; i++) {
      final phase = (progress + i / 3) % 1.0;
      final opacity = math.sin(phase * math.pi).clamp(0.0, 1.0);
      final steamPaint = Paint()
        ..color = color.withValues(alpha: 0.55 * opacity)
        ..style = PaintingStyle.stroke
        ..strokeWidth = size.width * 0.025
        ..strokeCap = StrokeCap.round;

      final baseX = cupLeft + size.width * (0.16 + i * 0.24);
      final riseHeight = size.height * 0.4;
      final yBottom = cupTop - size.height * 0.02;
      final yTop = yBottom - riseHeight * phase;

      final steamPath = Path()..moveTo(baseX, yBottom);
      const steps = 12;
      for (int s = 1; s <= steps; s++) {
        final t = s / steps;
        final y = yBottom + (yTop - yBottom) * t;
        final wave = math.sin(t * math.pi * 2 + phase * math.pi * 2) * size.width * 0.035;
        steamPath.lineTo(baseX + wave, y);
      }
      canvas.drawPath(steamPath, steamPaint);
    }
  }

  @override
  bool shouldRepaint(covariant _CoffeeCupPainter oldDelegate) => oldDelegate.progress != progress || oldDelegate.color != color;
}
