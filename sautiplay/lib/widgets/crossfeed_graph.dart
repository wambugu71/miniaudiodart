import 'dart:math' as math;
import 'package:flutter/material.dart';
import '../services/app_theme_service.dart';

/// A real-time frequency response visualization graph for Crossfeed algorithms.
///
/// Displays:
/// 1. Direct Ear frequency response (primary/cyan)
/// 2. Contralateral Ear (Cross) frequency response (amber/orange) showing low-pass head shadow
/// 3. Interaural Level Difference (ILD) acoustic separation fill
/// 4. Dynamic Cutoff frequency line and ITD delay annotation badge.
class CrossfeedGraph extends StatelessWidget {
  final int algorithmIndex; // 1=Simple, 2=BS2B, 3=Meier, 4=Natural
  final double mix; // 0.0 to 1.0
  final double cutoffHz; // 200.0 to 3000.0 Hz
  final double delayMs; // 0.05 to 2.0 ms
  final bool compensation;
  final bool isEnabled;
  final double height;
  final Color? primaryColor;

  const CrossfeedGraph({
    super.key,
    required this.algorithmIndex,
    required this.mix,
    required this.cutoffHz,
    required this.delayMs,
    this.compensation = false,
    this.isEnabled = true,
    this.height = 120.0,
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
          painter: _CrossfeedPainter(
            algorithmIndex: algorithmIndex,
            mix: mix,
            cutoffHz: cutoffHz,
            delayMs: delayMs,
            compensation: compensation,
            isEnabled: isEnabled,
            primaryColor: effectivePrimary,
          ),
        ),
      ),
    );
  }
}

class _CrossfeedPainter extends CustomPainter {
  final int algorithmIndex;
  final double mix;
  final double cutoffHz;
  final double delayMs;
  final bool compensation;
  final bool isEnabled;
  final Color primaryColor;

  _CrossfeedPainter({
    required this.algorithmIndex,
    required this.mix,
    required this.cutoffHz,
    required this.delayMs,
    required this.compensation,
    required this.isEnabled,
    required this.primaryColor,
  });

  static const double minFreq = 20.0;
  static const double maxFreq = 20000.0;
  static const double minDb = -24.0;
  static const double maxDb = 6.0;
  static const int numPoints = 120;

  @override
  void paint(Canvas canvas, Size size) {
    final paddingLeft = 32.0;
    final paddingRight = 16.0;
    final paddingTop = 12.0;
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

    // 1. Draw Grid
    _drawGrid(canvas, paddingLeft, paddingTop, graphWidth, graphHeight);

    if (!isEnabled || mix < 0.001) {
      // Draw flat direct line
      final flatY = dbToY(0.0);
      canvas.drawLine(
        Offset(paddingLeft, flatY),
        Offset(paddingLeft + graphWidth, flatY),
        Paint()
          ..color = primaryColor.withValues(alpha: 0.5)
          ..strokeWidth = 1.8,
      );
      return;
    }

    // 2. Compute Frequencies
    final freqs = List<double>.generate(numPoints, (i) {
      return minFreq * math.pow(maxFreq / minFreq, i / (numPoints - 1));
    });

    // 3. Compute Direct and Cross Responses
    final directDbs = <double>[];
    final crossDbs = <double>[];

    final effectiveFc = cutoffHz.clamp(100.0, 10000.0);
    final crossGainLinear = (algorithmIndex == 3 ? 0.35 : 0.30) * mix;
    final directGainLinear = compensation
        ? 1.0 / math.sqrt(1.0 + crossGainLinear * crossGainLinear)
        : 1.0;

    for (int i = 0; i < numPoints; i++) {
      final f = freqs[i];
      double directGain = directGainLinear;
      double lpfAtt;

      if (algorithmIndex == 2) {
        // Bauer BS2B shelf
        final feed = mix * 6.5 + 3.0;
        final level = feed / 10.0;
        final gbLo = level * -5.0 / 6.0 - 3.0;
        final gLo = math.pow(10.0, gbLo / 20.0).toDouble();
        final ratio = f / effectiveFc;
        lpfAtt = gLo / math.sqrt(1.0 + ratio * ratio);
        directGain = 1.0;
      } else if (algorithmIndex == 3) {
        // Jan Meier: 1-pole + direct high boost
        final ratio = f / effectiveFc;
        lpfAtt = 1.0 / math.sqrt(1.0 + ratio * ratio);
        directGain = (1.0 + 0.15 * (1.0 - lpfAtt)) * directGainLinear;
      } else if (algorithmIndex == 4) {
        // Natural: 2-pole SVF
        final ratio = f / effectiveFc;
        lpfAtt = 1.0 / math.sqrt(1.0 + math.pow(ratio, 4));
      } else {
        // Simple: 1-pole lowpass
        final ratio = f / effectiveFc;
        lpfAtt = 1.0 / math.sqrt(1.0 + ratio * ratio);
      }

      final crossLinear = crossGainLinear * lpfAtt;
      final directDb = 20.0 * (math.log(math.max(1e-4, directGain)) / math.ln10);
      final crossDb = 20.0 * (math.log(math.max(1e-4, crossLinear)) / math.ln10);

      directDbs.add(directDb);
      crossDbs.add(crossDb);
    }

    // 4. Draw Interaural Separation Area (Fill between direct and cross)
    final separationPath = Path();
    separationPath.moveTo(freqToX(freqs[0]), dbToY(directDbs[0]));
    for (int i = 1; i < numPoints; i++) {
      separationPath.lineTo(freqToX(freqs[i]), dbToY(directDbs[i]));
    }
    for (int i = numPoints - 1; i >= 0; i--) {
      separationPath.lineTo(freqToX(freqs[i]), dbToY(crossDbs[i]));
    }
    separationPath.close();

    final separationPaint = Paint()
      ..shader = LinearGradient(
        begin: Alignment.topCenter,
        end: Alignment.bottomCenter,
        colors: [
          primaryColor.withValues(alpha: 0.15),
          const Color(0xFFFF9100).withValues(alpha: 0.05),
        ],
      ).createShader(
          Rect.fromLTWH(paddingLeft, paddingTop, graphWidth, graphHeight))
      ..style = PaintingStyle.fill;
    canvas.drawPath(separationPath, separationPaint);

    // 5. Draw Cross (Contralateral) Response Curve (Amber / Orange)
    final crossPath = Path();
    crossPath.moveTo(freqToX(freqs[0]), dbToY(crossDbs[0]));
    for (int i = 1; i < numPoints; i++) {
      crossPath.lineTo(freqToX(freqs[i]), dbToY(crossDbs[i]));
    }

    final crossPaint = Paint()
      ..color = const Color(0xFFFF9100)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2.0
      ..strokeCap = StrokeCap.round;
    canvas.drawPath(crossPath, crossPaint);

    // 6. Draw Direct Ear Response Curve (Primary Color)
    final directPath = Path();
    directPath.moveTo(freqToX(freqs[0]), dbToY(directDbs[0]));
    for (int i = 1; i < numPoints; i++) {
      directPath.lineTo(freqToX(freqs[i]), dbToY(directDbs[i]));
    }

    final directPaint = Paint()
      ..color = primaryColor
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2.2
      ..strokeCap = StrokeCap.round;
    canvas.drawPath(directPath, directPaint);

    // 7. Draw Cutoff Frequency Guideline & Handle
    final cutoffX = freqToX(effectiveFc);
    final cutoffCrossY = dbToY(crossDbs.firstWhere(
      (v) => true,
      orElse: () => -6.0,
    ));

    // Vertical dashed marker at cutoff
    final dashPaint = Paint()
      ..color = const Color(0xFFFF9100).withValues(alpha: 0.35)
      ..strokeWidth = 1.0;
    double dy = paddingTop;
    while (dy < paddingTop + graphHeight) {
      canvas.drawLine(
        Offset(cutoffX, dy),
        Offset(cutoffX, math.min(dy + 3, paddingTop + graphHeight)),
        dashPaint,
      );
      dy += 6;
    }

    // Cutoff dot on cross curve
    canvas.drawCircle(
      Offset(cutoffX, cutoffCrossY),
      4.0,
      Paint()..color = const Color(0xFFFF9100),
    );

    // 8. Legend / Readout
    final itdMicros = (delayMs * 1000).round();
    final legendSpan = TextSpan(
      children: [
        TextSpan(
          text: '— Direct Ear  ',
          style: TextStyle(
            color: primaryColor,
            fontSize: 9.0,
            fontWeight: FontWeight.bold,
          ),
        ),
        const TextSpan(
          text: '— Crossfeed Ear  ',
          style: TextStyle(
            color: Color(0xFFFF9100),
            fontSize: 9.0,
            fontWeight: FontWeight.bold,
          ),
        ),
        TextSpan(
          text: 'fc: ${effectiveFc.toInt()}Hz  ITD: ${itdMicros}µs',
          style: TextStyle(
            color: Colors.white.withValues(alpha: 0.6),
            fontSize: 8.5,
            fontFamily: 'monospace',
          ),
        ),
      ],
    );
    final tp = TextPainter(text: legendSpan, textDirection: TextDirection.ltr)
      ..layout();
    tp.paint(canvas, Offset(paddingLeft + 6, paddingTop + 4));
  }

  void _drawGrid(Canvas canvas, double paddingLeft, double paddingTop,
      double graphWidth, double graphHeight) {
    final gridLinePaint = Paint()
      ..color = Colors.white.withValues(alpha: 0.06)
      ..strokeWidth = 1.0;

    final zeroLinePaint = Paint()
      ..color = Colors.white.withValues(alpha: 0.2)
      ..strokeWidth = 1.0;

    final textStyle = TextStyle(
      color: Colors.white.withValues(alpha: 0.4),
      fontSize: 8.5,
      fontFamily: 'monospace',
    );

    // Horizontal dB lines: -24, -18, -12, -6, 0, +6
    final dbTicks = [-24.0, -18.0, -12.0, -6.0, 0.0, 6.0];
    for (final db in dbTicks) {
      final norm = (db - minDb) / (maxDb - minDb);
      final y = paddingTop + (1.0 - norm) * graphHeight;

      canvas.drawLine(
        Offset(paddingLeft, y),
        Offset(paddingLeft + graphWidth, y),
        db == 0.0 ? zeroLinePaint : gridLinePaint,
      );

      final label = '${db > 0 ? '+' : ''}${db.toInt()}';
      final tp = TextPainter(
        text: TextSpan(text: label, style: textStyle),
        textDirection: TextDirection.ltr,
      )..layout();
      tp.paint(canvas, Offset(paddingLeft - tp.width - 4, y - tp.height / 2));
    }

    // Vertical Frequency lines
    final freqTicks = [
      {'f': 50.0, 'l': '50'},
      {'f': 200.0, 'l': '200'},
      {'f': 1000.0, 'l': '1k'},
      {'f': 5000.0, 'l': '5k'},
      {'f': 20000.0, 'l': '20k'},
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
  bool shouldRepaint(covariant _CrossfeedPainter oldDelegate) {
    return oldDelegate.algorithmIndex != algorithmIndex ||
        oldDelegate.mix != mix ||
        oldDelegate.cutoffHz != cutoffHz ||
        oldDelegate.delayMs != delayMs ||
        oldDelegate.compensation != compensation ||
        oldDelegate.isEnabled != isEnabled ||
        oldDelegate.primaryColor != primaryColor;
  }
}
