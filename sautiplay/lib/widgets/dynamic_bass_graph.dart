import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:sautiflow/sautiflow.dart';
import '../services/app_theme_service.dart';

/// A real-time low-frequency resonance and harmonic excitation graph for Dynamic Bass.
///
/// Focuses on the sub-bass and mid-bass acoustic band [20Hz, 500Hz], computing the
/// 4-pole cascaded ladder resonance curve, Focus Frequency peak, Bass Gain amplitude,
/// and psychoacoustic harmonic overtone generation (2f0, 3f0).
class DynamicBassGraph extends StatelessWidget {
  final HarmonicBassProfile profile;
  final int preset;
  final double cutoffHz; // 30Hz - 160Hz Focus Frequency
  final double gainDb; // 0dB - 24dB Bass Gain
  final double boost; // 0.0 - 1.0 Resonance / Q
  final bool isEnabled;
  final double height;
  final Color? primaryColor;

  const DynamicBassGraph({
    super.key,
    required this.profile,
    this.preset = 18,
    required this.cutoffHz,
    required this.gainDb,
    required this.boost,
    this.isEnabled = true,
    this.height = 125.0,
    this.primaryColor,
  });

  @override
  Widget build(BuildContext context) {
    final effectivePrimary =
        primaryColor ?? AppThemeService.instance.currentData.primary;
    final cardBg = AppThemeService.instance.currentData.cardDark;

    return Container(
      height: height,
      margin: const EdgeInsets.symmetric(vertical: 8.0),
      decoration: BoxDecoration(
        color: cardBg,
        borderRadius: BorderRadius.circular(12.0),
        border:
            Border.all(color: Colors.white.withValues(alpha: 0.1), width: 1.0),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.3),
            blurRadius: 10,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(12.0),
        child: CustomPaint(
          size: Size.infinite,
          painter: _DynamicBassPainter(
            profile: profile,
            preset: preset,
            cutoffHz: cutoffHz,
            gainDb: gainDb,
            boost: boost,
            isEnabled: isEnabled,
            primaryColor: effectivePrimary,
          ),
        ),
      ),
    );
  }
}

class _DynamicBassPainter extends CustomPainter {
  final HarmonicBassProfile profile;
  final int preset;
  final double cutoffHz;
  final double gainDb;
  final double boost;
  final bool isEnabled;
  final Color primaryColor;

  _DynamicBassPainter({
    required this.profile,
    required this.preset,
    required this.cutoffHz,
    required this.gainDb,
    required this.boost,
    required this.isEnabled,
    required this.primaryColor,
  });

  static const double minFreq = 20.0;
  static const double maxFreq = 500.0; // Focused sub/mid-bass display
  static const double minDb = 0.0;
  static const double maxDb = 24.0;
  static const int numPoints = 120;

  @override
  void paint(Canvas canvas, Size size) {
    final paddingLeft = 32.0;
    final paddingRight = 16.0;
    final paddingTop = 14.0;
    final paddingBottom = 18.0;

    final graphWidth = size.width - paddingLeft - paddingRight;
    final graphHeight = size.height - paddingTop - paddingBottom;
    if (graphWidth <= 0 || graphHeight <= 0) return;

    double freqToX(double f) {
      final clamped = f.clamp(minFreq, maxFreq);
      final logRatio =
          math.log(clamped / minFreq) / math.log(maxFreq / minFreq);
      return paddingLeft + logRatio * graphWidth;
    }

    double dbToY(double db) {
      final clamped = db.clamp(minDb, maxDb);
      final norm = (clamped - minDb) / (maxDb - minDb);
      return paddingTop + (1.0 - norm) * graphHeight;
    }

    final baselineY = dbToY(0.0);

    // 1. Draw Grid
    _drawGrid(canvas, paddingLeft, paddingTop, graphWidth, graphHeight);

    if (!isEnabled || gainDb < 0.1) {
      // Flat baseline
      canvas.drawLine(
        Offset(paddingLeft, baselineY),
        Offset(paddingLeft + graphWidth, baselineY),
        Paint()
          ..color = primaryColor.withValues(alpha: 0.4)
          ..strokeWidth = 1.8,
      );
      return;
    }

    // 2. Pre-calculate logarithmic frequencies [20Hz, 500Hz]
    final freqs = List<double>.generate(numPoints, (i) {
      return minFreq * math.pow(maxFreq / minFreq, i / (numPoints - 1));
    });

    final fc = cutoffHz.clamp(30.0, 160.0);
    final k = boost.clamp(0.0, 1.0) * 3.6; // Ladder resonance feedback

    // 3. Compute 4-Pole Ladder Resonance Response Curve
    final curveDbs = <double>[];
    for (int i = 0; i < numPoints; i++) {
      final f = freqs[i];
      final w = f / fc;

      // 4-pole pole factor: (1 + jw)^4
      // (1 + jw)^2 = (1 - w^2) + j(2w)
      final r2 = 1.0 - w * w;
      final i2 = 2.0 * w;
      // (1 + jw)^4 = (r2^2 - i2^2) + j(2 * r2 * i2)
      final r4 = r2 * r2 - i2 * i2;
      final i4 = 2.0 * r2 * i2;

      // Feedback denominator: (1 + jw)^4 + k
      final denR = r4 + k;
      final denI = i4;
      final magSq = 1.0 / math.max(1e-6, denR * denR + denI * denI);
      final rawGain = math.sqrt(magSq);

      // Normalize peak to 1.0 at resonance and scale with gainDb
      final peakRaw = 1.0 / math.max(0.05, 1.0 - k * 0.25);
      final normalizedGain = (rawGain / peakRaw).clamp(0.0, 1.0);

      // Subsonic protection roll-off below 25Hz
      final subsonicAtt = f < 30.0 ? math.sin((f / 30.0) * math.pi / 2.0) : 1.0;

      final pointDb = (gainDb * normalizedGain * subsonicAtt).clamp(0.0, maxDb);
      curveDbs.add(pointDb);
    }

    // 4. Draw Gradient Fill Under Bass Curve
    final curvePath = Path();
    curvePath.moveTo(freqToX(freqs[0]), dbToY(curveDbs[0]));
    for (int i = 1; i < numPoints; i++) {
      curvePath.lineTo(freqToX(freqs[i]), dbToY(curveDbs[i]));
    }

    final fillPath = Path.from(curvePath);
    fillPath.lineTo(freqToX(freqs.last), baselineY);
    fillPath.lineTo(freqToX(freqs.first), baselineY);
    fillPath.close();

    final fillPaint = Paint()
      ..shader = LinearGradient(
        begin: Alignment.topCenter,
        end: Alignment.bottomCenter,
        colors: [
          primaryColor.withValues(alpha: 0.30),
          primaryColor.withValues(alpha: 0.02),
        ],
      ).createShader(
          Rect.fromLTWH(paddingLeft, paddingTop, graphWidth, graphHeight))
      ..style = PaintingStyle.fill;
    canvas.drawPath(fillPath, fillPaint);

    // 5. Draw Glowing Resonance Curve
    final glowPaint = Paint()
      ..color = primaryColor.withValues(alpha: 0.4)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 4.5
      ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 3.5);
    canvas.drawPath(curvePath, glowPaint);

    final strokePaint = Paint()
      ..color = primaryColor
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2.4
      ..strokeCap = StrokeCap.round;
    canvas.drawPath(curvePath, strokePaint);

    // 6. Draw Virtual Harmonic Excitation Bars (2f0, 3f0)
    final hasHarmonics = profile == HarmonicBassProfile.dynamicMultiPole ||
        profile == HarmonicBassProfile.harmonicExciter ||
        profile == HarmonicBassProfile.subwoofer ||
        profile == HarmonicBassProfile.pureBass;

    if (hasHarmonics) {
      final h2Freq = fc * 2.0;
      final h3Freq = fc * 3.0;

      void drawHarmonicBar(double freq, String label, double gainRatio) {
        if (freq <= maxFreq) {
          final barX = freqToX(freq);
          final barHeight = gainDb * gainRatio;
          final barTopY = dbToY(barHeight);

          // Glowing vertical beam
          canvas.drawLine(
            Offset(barX, baselineY),
            Offset(barX, barTopY),
            Paint()
              ..color = const Color(0xFF00E5FF).withValues(alpha: 0.7)
              ..strokeWidth = 2.0
              ..strokeCap = StrokeCap.round,
          );

          // Top dot
          canvas.drawCircle(
            Offset(barX, barTopY),
            3.5,
            Paint()..color = const Color(0xFF00E5FF),
          );

          // Harmonic Tag
          final tp = TextPainter(
            text: TextSpan(
              text: label,
              style: const TextStyle(
                color: Color(0xFF00E5FF),
                fontSize: 8.5,
                fontWeight: FontWeight.bold,
                fontFamily: 'monospace',
              ),
            ),
            textDirection: TextDirection.ltr,
          )..layout();
          tp.paint(canvas, Offset(barX - tp.width / 2, barTopY - 12));
        }
      }

      drawHarmonicBar(h2Freq, '2f', 0.55);
      drawHarmonicBar(h3Freq, '3f', 0.32);
    }

    // 7. Focus Frequency Peak Handle
    final peakX = freqToX(fc);
    final peakY = dbToY(gainDb);

    // Vertical dashed marker down to base
    final dashPaint = Paint()
      ..color = primaryColor.withValues(alpha: 0.3)
      ..strokeWidth = 1.0;
    double dy = peakY;
    while (dy < baselineY) {
      canvas.drawLine(
        Offset(peakX, dy),
        Offset(peakX, math.min(dy + 3, baselineY)),
        dashPaint,
      );
      dy += 6;
    }

    // Glowing Peak Center Dot
    canvas.drawCircle(
      Offset(peakX, peakY),
      6.5,
      Paint()..color = primaryColor.withValues(alpha: 0.3),
    );
    canvas.drawCircle(
      Offset(peakX, peakY),
      3.5,
      Paint()..color = Colors.white,
    );

    // 8. Info Banner
    final infoSpan = TextSpan(
      children: [
        TextSpan(
          text: 'Focus: ${fc.toInt()}Hz  ',
          style: const TextStyle(
            color: Colors.white,
            fontSize: 9.0,
            fontWeight: FontWeight.bold,
            fontFamily: 'monospace',
          ),
        ),
        TextSpan(
          text: '+${gainDb.toStringAsFixed(1)}dB  ',
          style: TextStyle(
            color: primaryColor,
            fontSize: 9.0,
            fontWeight: FontWeight.bold,
            fontFamily: 'monospace',
          ),
        ),
        TextSpan(
          text: 'Q: ${(boost * 100).toInt()}%',
          style: TextStyle(
            color: Colors.white.withValues(alpha: 0.6),
            fontSize: 8.5,
            fontFamily: 'monospace',
          ),
        ),
      ],
    );
    final tp = TextPainter(text: infoSpan, textDirection: TextDirection.ltr)
      ..layout();
    tp.paint(canvas, Offset(paddingLeft + 6, paddingTop + 2));
  }

  void _drawGrid(Canvas canvas, double paddingLeft, double paddingTop,
      double graphWidth, double graphHeight) {
    final gridLinePaint = Paint()
      ..color = Colors.white.withValues(alpha: 0.06)
      ..strokeWidth = 1.0;

    final baselinePaint = Paint()
      ..color = Colors.white.withValues(alpha: 0.2)
      ..strokeWidth = 1.0;

    final textStyle = TextStyle(
      color: Colors.white.withValues(alpha: 0.4),
      fontSize: 8.5,
      fontFamily: 'monospace',
    );

    // Gain ticks: 0dB, +6dB, +12dB, +18dB, +24dB
    final dbTicks = [0.0, 6.0, 12.0, 18.0, 24.0];
    for (final db in dbTicks) {
      final norm = (db - minDb) / (maxDb - minDb);
      final y = paddingTop + (1.0 - norm) * graphHeight;

      canvas.drawLine(
        Offset(paddingLeft, y),
        Offset(paddingLeft + graphWidth, y),
        db == 0.0 ? baselinePaint : gridLinePaint,
      );

      final label = '+${db.toInt()}';
      final tp = TextPainter(
        text: TextSpan(text: label, style: textStyle),
        textDirection: TextDirection.ltr,
      )..layout();
      tp.paint(canvas, Offset(paddingLeft - tp.width - 4, y - tp.height / 2));
    }

    // Frequency ticks: 20Hz, 40Hz, 80Hz, 150Hz, 300Hz, 500Hz
    final freqTicks = [
      {'f': 20.0, 'l': '20'},
      {'f': 40.0, 'l': '40'},
      {'f': 80.0, 'l': '80'},
      {'f': 150.0, 'l': '150'},
      {'f': 300.0, 'l': '300'},
      {'f': 500.0, 'l': '500Hz'},
    ];

    for (final tick in freqTicks) {
      final freq = tick['f'] as double;
      final label = tick['l'] as String;

      final logRatio = math.log(freq / minFreq) / math.log(maxFreq / minFreq);
      final x = paddingLeft + logRatio * graphWidth;

      canvas.drawLine(
        Offset(x, paddingTop),
        Offset(x, paddingTop + graphHeight),
        gridLinePaint,
      );

      final tp = TextPainter(
        text: TextSpan(text: label, style: textStyle),
        textDirection: TextDirection.ltr,
      )..layout();
      tp.paint(canvas, Offset(x - tp.width / 2, paddingTop + graphHeight + 3));
    }
  }

  @override
  bool shouldRepaint(covariant _DynamicBassPainter oldDelegate) {
    return oldDelegate.profile != profile ||
        oldDelegate.preset != preset ||
        oldDelegate.cutoffHz != cutoffHz ||
        oldDelegate.gainDb != gainDb ||
        oldDelegate.boost != boost ||
        oldDelegate.isEnabled != isEnabled ||
        oldDelegate.primaryColor != primaryColor;
  }
}
