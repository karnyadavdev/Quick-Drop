import 'dart:math' as math;
import 'package:flutter/material.dart';

class RadarPainter extends CustomPainter {
  final double animationValue;
  final Color baseColor;

  RadarPainter({
    required this.animationValue,
    required this.baseColor,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    final maxRadius = math.min(size.width, size.height) / 2;

    const numRings = 4;
    for (int i = 0; i < numRings; i++) {
      final t = (animationValue + (i / numRings)) % 1.0;
      final radius = maxRadius * (0.18 + (t * 0.78));
      final opacity = math.sin(t * math.pi).clamp(0.0, 1.0) * 0.32;

      final pulsePaint = Paint()
        ..color = baseColor.withAlpha((opacity * 255).round())
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2.5 - (t * 0.9);

      canvas.drawCircle(center, radius, pulsePaint);
    }

    final blooms = [
      Offset(-maxRadius * 0.24, -maxRadius * 0.16),
      Offset(maxRadius * 0.28, maxRadius * 0.06),
      Offset(0, maxRadius * 0.30),
    ];

    for (var i = 0; i < blooms.length; i++) {
      final phase = (animationValue + i / blooms.length) * math.pi * 2;
      final strength = 0.55 + (math.sin(phase) * 0.20);
      final bloomCenter = center + blooms[i];
      final bloomRadius = maxRadius * (0.26 + (strength * 0.10));
      final bloomPaint = Paint()
        ..shader = RadialGradient(
          colors: [
            baseColor.withAlpha((48 * strength).round()),
            baseColor.withAlpha((18 * strength).round()),
            baseColor.withAlpha(0),
          ],
          stops: const [0.0, 0.48, 1.0],
        ).createShader(
          Rect.fromCircle(center: bloomCenter, radius: bloomRadius),
        );

      canvas.drawCircle(bloomCenter, bloomRadius, bloomPaint);
    }
  }

  @override
  bool shouldRepaint(covariant RadarPainter oldDelegate) {
    return oldDelegate.animationValue != animationValue ||
        oldDelegate.baseColor != baseColor;
  }
}
