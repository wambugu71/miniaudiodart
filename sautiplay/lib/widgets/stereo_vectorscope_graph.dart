import 'dart:math' as math;
import 'package:flutter/material.dart';
import '../services/app_theme_service.dart';

class _ScopeParticle {
  final double baseMid;
  final double baseSide;
  final double phase;
  final double speed;
  final double driftAmp;
  final double size;
  final double alpha;

  const _ScopeParticle({
    required this.baseMid,
    required this.baseSide,
    required this.phase,
    required this.speed,
    required this.driftAmp,
    required this.size,
    required this.alpha,
  });
}

/// An interactive Polar Goniometer / Stereo Vectorscope particle cloud display.
///
/// Visualizes stereo field width, phase correlation, and spatial dispersion with
/// moving, shimmering particles that expand horizontally towards L/R as stereo widening
/// increases, and collapse into a vertical mono beam along the Mid (M) axis when width is 0.
class StereoVectorscopeGraph extends StatefulWidget {
  final double width; // 0.0 to 5.0 (1.0 = normal, 2.0+ = wide)
  final double delayMs; // Haas delay (0.0 to 1.0)
  final bool isEnabled;
  final double height;
  final Color? primaryColor;

  const StereoVectorscopeGraph({
    super.key,
    required this.width,
    this.delayMs = 0.15,
    this.isEnabled = true,
    this.height = 195.0,
    this.primaryColor,
  });

  @override
  State<StereoVectorscopeGraph> createState() => _StereoVectorscopeGraphState();
}

class _StereoVectorscopeGraphState extends State<StereoVectorscopeGraph>
    with SingleTickerProviderStateMixin {
  late AnimationController _animController;
  late List<_ScopeParticle> _particles;

  static const int particleCount = 280;

  @override
  void initState() {
    super.initState();
    _animController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 3200),
    )..repeat();

    final rng = math.Random(42);
    _particles = List.generate(particleCount, (i) {
      // Gaussian-like distribution for realistic audio energy
      final u1 = rng.nextDouble().clamp(1e-6, 1.0);
      final u2 = rng.nextDouble();
      final z0 = math.sqrt(-2.0 * math.log(u1)) * math.cos(2.0 * math.pi * u2);
      final z1 = math.sqrt(-2.0 * math.log(u1)) * math.sin(2.0 * math.pi * u2);

      // Mid has high vertical spread; side has natural initial stereo variance
      final baseMid = (z0 * 0.35).clamp(-0.85, 0.85);
      final baseSide = (z1 * 0.22).clamp(-0.85, 0.85);

      return _ScopeParticle(
        baseMid: baseMid,
        baseSide: baseSide,
        phase: rng.nextDouble() * 2.0 * math.pi,
        speed: 0.7 + rng.nextDouble() * 1.8,
        driftAmp: 0.02 + rng.nextDouble() * 0.04,
        size: 1.2 + rng.nextDouble() * 1.8,
        alpha: 0.35 + rng.nextDouble() * 0.60,
      );
    });
  }

  @override
  void dispose() {
    _animController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final effectivePrimary =
        widget.primaryColor ?? AppThemeService.instance.currentData.primary;
    final cardBg = AppThemeService.instance.currentData.cardDark;

    return AnimatedBuilder(
      animation: _animController,
      builder: (context, child) {
        return Container(
          height: widget.height,
          margin: const EdgeInsets.symmetric(vertical: 8.0),
          decoration: BoxDecoration(
            color: cardBg,
            borderRadius: BorderRadius.circular(14.0),
            border: Border.all(
              color: Colors.white.withValues(alpha: 0.1),
              width: 1.0,
            ),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.35),
                blurRadius: 12,
                offset: const Offset(0, 4),
              ),
            ],
          ),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(14.0),
            child: CustomPaint(
              size: Size.infinite,
              painter: _VectorscopePainter(
                width: widget.width,
                delayMs: widget.delayMs,
                isEnabled: widget.isEnabled,
                primaryColor: effectivePrimary,
                animProgress: _animController.value,
                particles: _particles,
              ),
            ),
          ),
        );
      },
    );
  }
}

class _VectorscopePainter extends CustomPainter {
  final double width;
  final double delayMs;
  final bool isEnabled;
  final Color primaryColor;
  final double animProgress;
  final List<_ScopeParticle> particles;

  _VectorscopePainter({
    required this.width,
    required this.delayMs,
    required this.isEnabled,
    required this.primaryColor,
    required this.animProgress,
    required this.particles,
  });

  @override
  void paint(Canvas canvas, Size size) {
    // Top portion for circular polar scope, bottom for phase correlation bar
    const barHeight = 28.0;
    final scopeHeight = size.height - barHeight;
    final scopeCenter = Offset(size.width / 2.0, scopeHeight / 2.0);
    final radius = math.min(size.width / 2.0, scopeHeight / 2.0) - 14.0;
    if (radius <= 0) return;

    // 1. Draw Polar Scope Grid (Concentric circles & crosshairs)
    _drawScopeGrid(canvas, scopeCenter, radius);

    // 2. Draw Dispersing, Moving Particle Cloud
    _drawParticles(canvas, scopeCenter, radius);

    // 3. Draw Phase Correlation Bar at bottom
    _drawPhaseCorrelationBar(canvas, size, scopeHeight);
  }

  void _drawScopeGrid(Canvas canvas, Offset center, double radius) {
    final circlePaint = Paint()
      ..color = Colors.white.withValues(alpha: 0.10)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.0;

    final innerCirclePaint = Paint()
      ..color = Colors.white.withValues(alpha: 0.05)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 0.8;

    final axisPaint = Paint()
      ..color = Colors.white.withValues(alpha: 0.08)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.0;

    final labelStyle = TextStyle(
      color: Colors.white.withValues(alpha: 0.45),
      fontSize: 10.5,
      fontWeight: FontWeight.bold,
      fontFamily: 'monospace',
    );

    // Outer boundary circle
    canvas.drawCircle(center, radius, circlePaint);

    // Inner concentric guide circles (33% and 66%)
    canvas.drawCircle(center, radius * 0.35, innerCirclePaint);
    canvas.drawCircle(center, radius * 0.68, innerCirclePaint);

    // Mid/Side Axes (Vertical = Mid, Horizontal = Side)
    canvas.drawLine(
      Offset(center.dx, center.dy - radius),
      Offset(center.dx, center.dy + radius),
      axisPaint,
    );
    canvas.drawLine(
      Offset(center.dx - radius, center.dy),
      Offset(center.dx + radius, center.dy),
      axisPaint,
    );

    // 45° Diagonal Lines for L and R
    final diag = radius * 0.7071; // cos(45°)
    canvas.drawLine(
      center,
      Offset(center.dx - diag, center.dy - diag),
      axisPaint,
    );
    canvas.drawLine(
      center,
      Offset(center.dx + diag, center.dy - diag),
      axisPaint,
    );

    // Labels: M (Mid), L (Left), R (Right)
    void drawText(String text, Offset pos) {
      final tp = TextPainter(
        text: TextSpan(text: text, style: labelStyle),
        textDirection: TextDirection.ltr,
      )..layout();
      tp.paint(canvas, Offset(pos.dx - tp.width / 2.0, pos.dy - tp.height / 2.0));
    }

    drawText('M', Offset(center.dx, center.dy - radius + 10.0));
    drawText('L', Offset(center.dx - diag + 10.0, center.dy - diag + 10.0));
    drawText('R', Offset(center.dx + diag - 10.0, center.dy - diag + 10.0));
  }

  void _drawParticles(Canvas canvas, Offset center, double radius) {
    final effectiveWidth = isEnabled ? width.clamp(0.0, 5.0) : 0.0;
    // Map width multiplier (1.0 = normal, 2.0+ = wide, 0 = mono)
    final widthFactor = effectiveWidth;
    final time = animProgress;

    final dotPaint = Paint()..style = PaintingStyle.fill;

    for (final p in particles) {
      // Shimmering Brownian drift
      final driftAngle = p.phase + 2.0 * math.pi * time * p.speed;
      final driftX = math.sin(driftAngle) * p.driftAmp * (0.4 + 0.6 * widthFactor);
      final driftY = math.cos(driftAngle) * p.driftAmp;

      // When width = 0 (mono), side component collapses to 0 (tight vertical beam)
      // When width > 1, side component disperses outward towards L and R
      final side = (p.baseSide * widthFactor * 0.75 + driftX);
      final mid = (p.baseMid + driftY);

      // Map to canvas position (Side = horizontal, Mid = vertical)
      final px = (center.dx + side * radius).clamp(center.dx - radius + 2, center.dx + radius - 2);
      final py = (center.dy - mid * radius).clamp(center.dy - radius + 2, center.dy + radius - 2);

      // Particle alpha modulation with breathing effect
      final shimmer = 0.8 + 0.2 * math.sin(driftAngle * 1.5);
      final currentAlpha = isEnabled
          ? (p.alpha * shimmer).clamp(0.15, 0.95)
          : 0.18;

      dotPaint.color = primaryColor.withValues(alpha: currentAlpha);

      canvas.drawCircle(Offset(px, py), isEnabled ? p.size : 1.2, dotPaint);
    }
  }

  void _drawPhaseCorrelationBar(Canvas canvas, Size size, double scopeHeight) {
    const barPaddingX = 36.0;
    final barTop = scopeHeight + 4.0;
    final barWidth = size.width - (barPaddingX * 2.0);
    const barH = 7.0;

    if (barWidth <= 0) return;

    // Track background
    final trackRect = RRect.fromRectAndRadius(
      Rect.fromLTWH(barPaddingX, barTop, barWidth, barH),
      const Radius.circular(3.5),
    );
    canvas.drawRRect(
      trackRect,
      Paint()..color = Colors.white.withValues(alpha: 0.08),
    );

    // Calculate phase correlation value from width:
    // Mono (w=0) => +1.00
    // Normal (w=1) => +0.75
    // Wide (w=2) => +0.50
    // Ultra-wide (w=5) => +0.10
    final effectiveWidth = isEnabled ? width.clamp(0.0, 5.0) : 1.0;
    double correlation = (1.0 - (effectiveWidth * 0.25) + 0.05).clamp(-1.0, 1.0);
    if (!isEnabled) correlation = 0.0;

    // Normalized to 0.0 (-1.0) .. 1.0 (+1.0)
    final norm = (correlation - (-1.0)) / (1.0 - (-1.0)); // 0.0 to 1.0
    final activeWidth = (barWidth * norm).clamp(4.0, barWidth);

    // Active correlation fill bar (cyan gradient)
    final activeRect = RRect.fromRectAndRadius(
      Rect.fromLTWH(barPaddingX, barTop, activeWidth, barH),
      const Radius.circular(3.5),
    );
    canvas.drawRRect(
      activeRect,
      Paint()
        ..shader = LinearGradient(
          colors: [
            primaryColor.withValues(alpha: 0.5),
            primaryColor,
          ],
        ).createShader(Rect.fromLTWH(barPaddingX, barTop, activeWidth, barH)),
    );

    // Labels: -1 (left), correlation value (center), +1 (right)
    final labelStyle = TextStyle(
      color: Colors.white.withValues(alpha: 0.4),
      fontSize: 8.5,
      fontFamily: 'monospace',
    );

    final leftTp = TextPainter(
      text: TextSpan(text: '-1', style: labelStyle),
      textDirection: TextDirection.ltr,
    )..layout();
    leftTp.paint(canvas, Offset(barPaddingX, barTop + barH + 3.0));

    final valText = isEnabled
        ? (correlation >= 0 ? '+${correlation.toStringAsFixed(2)}' : correlation.toStringAsFixed(2))
        : 'BYPASS';
    final valTp = TextPainter(
      text: TextSpan(
        text: valText,
        style: TextStyle(
          color: isEnabled ? primaryColor : Colors.white38,
          fontSize: 8.5,
          fontWeight: FontWeight.bold,
          fontFamily: 'monospace',
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    valTp.paint(canvas, Offset(size.width / 2.0 - valTp.width / 2.0, barTop + barH + 3.0));

    final rightTp = TextPainter(
      text: TextSpan(text: '+1', style: labelStyle),
      textDirection: TextDirection.ltr,
    )..layout();
    rightTp.paint(canvas, Offset(barPaddingX + barWidth - rightTp.width, barTop + barH + 3.0));
  }

  @override
  bool shouldRepaint(covariant _VectorscopePainter oldDelegate) {
    return oldDelegate.animProgress != animProgress ||
        oldDelegate.width != width ||
        oldDelegate.delayMs != delayMs ||
        oldDelegate.isEnabled != isEnabled ||
        oldDelegate.primaryColor != primaryColor;
  }
}
