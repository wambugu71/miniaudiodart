import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:sautiflow/sautiflow.dart';
import '../services/app_theme_service.dart';

class _DynamicSystemPresetParams {
  final String name;
  final double xLow;
  final double xHigh;
  final double yLow;
  final double yHigh;
  final double sideGainX;
  final double sideGainY;
  final double maxDrive;

  const _DynamicSystemPresetParams(
    this.name,
    this.xLow,
    this.xHigh,
    this.yLow,
    this.yHigh,
    this.sideGainX,
    this.sideGainY,
    this.maxDrive,
  );
}

const List<_DynamicSystemPresetParams> _kDynamicSystemPresets = [
  _DynamicSystemPresetParams('In-Ear Earbuds', 180.0, 5800.0, 55.0, 80.0, 0.10, 0.70, 3.4),
  _DynamicSystemPresetParams('Over-Ear Headphones', 300.0, 5600.0, 60.0, 105.0, 0.10, 0.50, 3.0),
  _DynamicSystemPresetParams('Studio Reference', 140.0, 6200.0, 40.0, 60.0, 0.10, 0.80, 2.2),
  _DynamicSystemPresetParams('Desktop Speakers', 400.0, 6200.0, 40.0, 80.0, 0.10, 0.00, 3.6),
  _DynamicSystemPresetParams('Club Subwoofer', 800.0, 6200.0, 80.0, 140.0, 0.00, 0.00, 4.6),
  _DynamicSystemPresetParams('Pure Dynamic', 1000.0, 6200.0, 50.0, 90.0, 0.30, 0.10, 3.8),
  _DynamicSystemPresetParams('Audiophile Open-Back', 1000.0, 6200.0, 60.0, 100.0, 0.00, 0.00, 2.5),
  _DynamicSystemPresetParams('Studio Monitor Lows', 1000.0, 6200.0, 60.0, 120.0, 0.00, 0.00, 2.8),
  _DynamicSystemPresetParams('Cinema Sub Slam', 1200.0, 6200.0, 60.0, 100.0, 0.00, 0.30, 4.2),
  _DynamicSystemPresetParams('Car Audio Bass', 1200.0, 6200.0, 40.0, 80.0, 0.00, 0.30, 4.0),
  _DynamicSystemPresetParams('Deep Acoustic Warmth', 600.0, 5400.0, 60.0, 105.0, 0.10, 0.20, 2.8),
  _DynamicSystemPresetParams('Clean Kick Drum', 400.0, 6200.0, 40.0, 80.0, 0.10, 0.00, 3.2),
  _DynamicSystemPresetParams('Resonant Rumble', 1200.0, 6200.0, 50.0, 100.0, 0.10, 0.50, 4.4),
  _DynamicSystemPresetParams('Sub-Bass Boom', 1200.0, 6200.0, 40.0, 80.0, 0.00, 0.20, 4.8),
  _DynamicSystemPresetParams('Solid Impact', 800.0, 6200.0, 40.0, 80.0, 0.10, 0.00, 3.5),
  _DynamicSystemPresetParams('Rich Low-End', 1200.0, 6200.0, 50.0, 90.0, 0.15, 0.10, 3.6),
  _DynamicSystemPresetParams('Club PA Punch', 1000.0, 6200.0, 50.0, 90.0, 0.30, 0.10, 4.0),
  _DynamicSystemPresetParams('Deep Sub Extension', 1000.0, 6200.0, 80.0, 140.0, 0.00, 0.00, 4.5),
  _DynamicSystemPresetParams('Ultimate Subwoofer', 800.0, 6200.0, 80.0, 140.0, 0.00, 0.00, 5.0),
];

/// A real-time acoustic transfer simulation graph for Dynamic System (Transducer Modeling).
///
/// Graphs the multi-band transducer acoustic contour across [20Hz, 20kHz] based on the
/// physical acoustic impedance characteristics of earbuds, headphones, planar drivers,
/// and loudspeakers scaled dynamically by the Dynamic Drive strength knob.
class DynamicSystemGraph extends StatelessWidget {
  final TransducerProfile profile;
  final double strength; // 0.0 to 1.0 (Dynamic Drive)
  final bool isEnabled;
  final double height;
  final Color? primaryColor;

  const DynamicSystemGraph({
    super.key,
    required this.profile,
    required this.strength,
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
          painter: _DynamicSystemPainter(
            profile: profile,
            strength: strength,
            isEnabled: isEnabled,
            primaryColor: effectivePrimary,
          ),
        ),
      ),
    );
  }
}

class _DynamicSystemPainter extends CustomPainter {
  final TransducerProfile profile;
  final double strength;
  final bool isEnabled;
  final Color primaryColor;

  _DynamicSystemPainter({
    required this.profile,
    required this.strength,
    required this.isEnabled,
    required this.primaryColor,
  });

  static const double minFreq = 20.0;
  static const double maxFreq = 20000.0;
  static const double minDb = -12.0;
  static const double maxDb = 12.0;
  static const int numPoints = 130;

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

    final zeroY = dbToY(0.0);

    // 1. Draw Grid
    _drawGrid(canvas, paddingLeft, paddingTop, graphWidth, graphHeight);

    if (!isEnabled || strength < 0.01) {
      // Draw flat baseline
      canvas.drawLine(
        Offset(paddingLeft, zeroY),
        Offset(paddingLeft + graphWidth, zeroY),
        Paint()
          ..color = primaryColor.withValues(alpha: 0.4)
          ..strokeWidth = 1.8,
      );
      return;
    }

    // 2. Lookup Preset Parameters
    final index = profile.value.clamp(0, _kDynamicSystemPresets.length - 1);
    final p = _kDynamicSystemPresets[index];

    // 3. Compute Transducer Acoustic Transfer Contour across [20Hz, 20kHz]
    final freqs = List<double>.generate(numPoints, (i) {
      return minFreq * math.pow(maxFreq / minFreq, i / (numPoints - 1));
    });

    final curveDbs = <double>[];
    final effectiveDrive = strength * p.maxDrive;
    final subGain = (p.sideGainY * 1.4 + 0.3) * effectiveDrive * 2.0;
    final midBassGain = (p.sideGainX * 1.2 + 0.1) * effectiveDrive * 1.5;

    for (int i = 0; i < numPoints; i++) {
      final f = freqs[i];

      // Stage 2: Sub-bass resonance bump around yLow
      final subRatio = f / p.yLow;
      final subBump = subGain / (1.0 + math.pow(math.log(math.max(1e-3, subRatio)), 2) * 3.5);

      // Mid-bass punch bump around yHigh
      final midRatio = f / p.yHigh;
      final midBump = midBassGain / (1.0 + math.pow(math.log(math.max(1e-3, midRatio)), 2) * 2.5);

      // Low crossover transition (attenuation below 30Hz for subsonic control)
      final subsonicAtt = f < 30.0 ? math.sin((f / 30.0) * math.pi / 2.0) : 1.0;

      // Stage 1: Upper-treble air presence lift above xHigh
      double trebleAir = 0.0;
      if (f > p.xHigh * 0.7) {
        final tRatio = (f - p.xHigh * 0.7) / (maxFreq - p.xHigh * 0.7);
        trebleAir = tRatio.clamp(0.0, 1.0) * 2.5 * strength;
      }

      final netDb = ((subBump + midBump) * subsonicAtt + trebleAir).clamp(minDb, maxDb);
      curveDbs.add(netDb);
    }

    // 4. Draw Gradient Fill Under Curve
    final curvePath = Path();
    curvePath.moveTo(freqToX(freqs[0]), dbToY(curveDbs[0]));
    for (int i = 1; i < numPoints; i++) {
      curvePath.lineTo(freqToX(freqs[i]), dbToY(curveDbs[i]));
    }

    final fillPath = Path.from(curvePath);
    fillPath.lineTo(freqToX(freqs.last), zeroY);
    fillPath.lineTo(freqToX(freqs.first), zeroY);
    fillPath.close();

    final fillPaint = Paint()
      ..shader = LinearGradient(
        begin: Alignment.topCenter,
        end: Alignment.bottomCenter,
        colors: [
          primaryColor.withValues(alpha: 0.25),
          primaryColor.withValues(alpha: 0.0),
        ],
      ).createShader(
          Rect.fromLTWH(paddingLeft, paddingTop, graphWidth, graphHeight))
      ..style = PaintingStyle.fill;
    canvas.drawPath(fillPath, fillPaint);

    // 5. Draw Glowing Acoustic Curve
    final glowPaint = Paint()
      ..color = primaryColor.withValues(alpha: 0.35)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 4.5
      ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 3.0);
    canvas.drawPath(curvePath, glowPaint);

    final strokePaint = Paint()
      ..color = primaryColor
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2.2
      ..strokeCap = StrokeCap.round;
    canvas.drawPath(curvePath, strokePaint);

    // 6. Draw Crossover Boundary Region Markers (xLow and xHigh)
    void drawCrossoverMarker(double f, String label) {
      final cx = freqToX(f);
      final markerPaint = Paint()
        ..color = Colors.white.withValues(alpha: 0.25)
        ..strokeWidth = 1.0;

      double my = paddingTop;
      while (my < paddingTop + graphHeight) {
        canvas.drawLine(
          Offset(cx, my),
          Offset(cx, math.min(my + 3, paddingTop + graphHeight)),
          markerPaint,
        );
        my += 6;
      }

      final tp = TextPainter(
        text: TextSpan(
          text: label,
          style: TextStyle(
            color: Colors.white.withValues(alpha: 0.5),
            fontSize: 8.0,
            fontFamily: 'monospace',
          ),
        ),
        textDirection: TextDirection.ltr,
      )..layout();
      tp.paint(canvas, Offset(cx - tp.width / 2, paddingTop + 2));
    }

    drawCrossoverMarker(p.xLow, 'xLow');
    drawCrossoverMarker(p.xHigh, 'xHigh');

    // 7. Info Readout
    final infoSpan = TextSpan(
      children: [
        TextSpan(
          text: '${p.name}  ',
          style: const TextStyle(
            color: Colors.white,
            fontSize: 9.0,
            fontWeight: FontWeight.bold,
            fontFamily: 'monospace',
          ),
        ),
        TextSpan(
          text: 'Drive: ${(strength * 100).toInt()}%  ',
          style: TextStyle(
            color: primaryColor,
            fontSize: 9.0,
            fontWeight: FontWeight.bold,
            fontFamily: 'monospace',
          ),
        ),
        TextSpan(
          text: 'Sub: ${p.yLow.toInt()}Hz Mid: ${p.yHigh.toInt()}Hz',
          style: TextStyle(
            color: Colors.white.withValues(alpha: 0.55),
            fontSize: 8.5,
            fontFamily: 'monospace',
          ),
        ),
      ],
    );
    final tp = TextPainter(text: infoSpan, textDirection: TextDirection.ltr)
      ..layout();
    tp.paint(canvas, Offset(paddingLeft + 6, paddingTop + graphHeight - 12));
  }

  void _drawGrid(Canvas canvas, double paddingLeft, double paddingTop,
      double graphWidth, double graphHeight) {
    final gridLinePaint = Paint()
      ..color = Colors.white.withValues(alpha: 0.06)
      ..strokeWidth = 1.0;

    final zeroLinePaint = Paint()
      ..color = Colors.white.withValues(alpha: 0.22)
      ..strokeWidth = 1.0;

    final textStyle = TextStyle(
      color: Colors.white.withValues(alpha: 0.4),
      fontSize: 8.5,
      fontFamily: 'monospace',
    );

    // dB lines: -12, -6, 0, +6, +12
    final dbTicks = [-12.0, -6.0, 0.0, 6.0, 12.0];
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

    // Frequency lines
    final freqTicks = [
      {'f': 50.0, 'l': '50'},
      {'f': 200.0, 'l': '200'},
      {'f': 1000.0, 'l': '1k'},
      {'f': 6000.0, 'l': '6k'},
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
  bool shouldRepaint(covariant _DynamicSystemPainter oldDelegate) {
    return oldDelegate.profile != profile ||
        oldDelegate.strength != strength ||
        oldDelegate.isEnabled != isEnabled ||
        oldDelegate.primaryColor != primaryColor;
  }
}
