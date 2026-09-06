import 'dart:math' as math;
import 'package:flutter/material.dart';
import '../services/app_theme_service.dart';

/// A sleek, real-time dynamic transfer curve and gain reduction graph for the Compressor.
///
/// Graphs the exact input dB vs. output dB transfer characteristics across [-60dB, 0dB]
/// with soft-knee curvature, ratio slope, makeup gain shift, unity gain reference,
/// and a real-time animated operating point tracking live gain reduction.
class CompressorTransferGraph extends StatelessWidget {
  final double thresholdDb;
  final double ratio;
  final double kneeDb;
  final double makeupGainDb;
  final double gainReductionDb;
  final bool isEnabled;
  final double height;
  final Color? primaryColor;

  const CompressorTransferGraph({
    super.key,
    required this.thresholdDb,
    required this.ratio,
    required this.kneeDb,
    this.makeupGainDb = 0.0,
    this.gainReductionDb = 0.0,
    this.isEnabled = true,
    this.height = 135.0,
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
          painter: _CompressorPainter(
            thresholdDb: thresholdDb,
            ratio: ratio,
            kneeDb: kneeDb,
            makeupGainDb: makeupGainDb,
            gainReductionDb: gainReductionDb,
            isEnabled: isEnabled,
            primaryColor: effectivePrimary,
          ),
        ),
      ),
    );
  }
}

class _CompressorPainter extends CustomPainter {
  final double thresholdDb;
  final double ratio;
  final double kneeDb;
  final double makeupGainDb;
  final double gainReductionDb;
  final bool isEnabled;
  final Color primaryColor;

  _CompressorPainter({
    required this.thresholdDb,
    required this.ratio,
    required this.kneeDb,
    required this.makeupGainDb,
    required this.gainReductionDb,
    required this.isEnabled,
    required this.primaryColor,
  });

  static const double minDb = -60.0;
  static const double maxDb = 0.0;
  static const int numPoints = 120;

  @override
  void paint(Canvas canvas, Size size) {
    final paddingLeft = 34.0;
    final paddingRight = 16.0;
    final paddingTop = 12.0;
    final paddingBottom = 22.0;

    final graphWidth = size.width - paddingLeft - paddingRight;
    final graphHeight = size.height - paddingTop - paddingBottom;
    if (graphWidth <= 0 || graphHeight <= 0) return;

    // Coordinate conversion helpers
    double inToX(double inDb) {
      final norm = (inDb.clamp(minDb, maxDb) - minDb) / (maxDb - minDb);
      return paddingLeft + norm * graphWidth;
    }

    double outToY(double outDb) {
      final norm = (outDb.clamp(minDb, maxDb) - minDb) / (maxDb - minDb);
      return paddingTop + (1.0 - norm) * graphHeight;
    }

    // 1. Draw Grid Lines & Scale Labels
    _drawGrid(canvas, paddingLeft, paddingTop, graphWidth, graphHeight);

    // 2. Draw Unity Gain Diagonal Line (1:1 dashed)
    final unityPath = Path()
      ..moveTo(inToX(minDb), outToY(minDb))
      ..lineTo(inToX(maxDb), outToY(maxDb));
    final unityPaint = Paint()
      ..color = Colors.white.withValues(alpha: 0.15)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.2;
    canvas.drawPath(unityPath, unityPaint);

    if (!isEnabled) {
      // If disabled, just draw flat 1:1 line in dimmed style
      final disabledPaint = Paint()
        ..color = Colors.white24
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.5;
      canvas.drawPath(unityPath, disabledPaint);
      return;
    }

    // 3. Compute Transfer Curve Points
    final T = thresholdDb.clamp(minDb, maxDb);
    final R = math.max(1.0, ratio);
    final W = kneeDb.clamp(0.0, 24.0);
    final M = makeupGainDb;

    double computeOutput(double x) {
      double y;
      if (W <= 0.1) {
        // Hard Knee
        if (x <= T) {
          y = x;
        } else {
          y = T + (x - T) / R;
        }
      } else {
        // Soft Knee (Continuous Quadratic Spline)
        final halfW = W / 2.0;
        if (x < T - halfW) {
          y = x;
        } else if (x > T + halfW) {
          y = T + (x - T) / R;
        } else {
          final delta = x - T + halfW;
          y = x + ((1.0 / R) - 1.0) * (delta * delta) / (2.0 * W);
        }
      }
      return y + M;
    }

    final inDbs = List<double>.generate(numPoints, (i) {
      return minDb + (maxDb - minDb) * (i / (numPoints - 1));
    });

    final curvePath = Path();
    curvePath.moveTo(inToX(inDbs[0]), outToY(computeOutput(inDbs[0])));
    for (int i = 1; i < numPoints; i++) {
      curvePath.lineTo(inToX(inDbs[i]), outToY(computeOutput(inDbs[i])));
    }

    // 4. Draw Shaded Gain Reduction Area (between Unity line and transfer curve)
    final grFillPath = Path();
    grFillPath.moveTo(inToX(inDbs[0]), outToY(inDbs[0]));
    for (int i = 1; i < numPoints; i++) {
      grFillPath.lineTo(inToX(inDbs[i]), outToY(inDbs[i]));
    }
    for (int i = numPoints - 1; i >= 0; i--) {
      grFillPath.lineTo(inToX(inDbs[i]), outToY(computeOutput(inDbs[i])));
    }
    grFillPath.close();

    final grFillPaint = Paint()
      ..shader = LinearGradient(
        begin: Alignment.topCenter,
        end: Alignment.bottomCenter,
        colors: [
          const Color(0xFFFF9100).withValues(alpha: 0.25),
          primaryColor.withValues(alpha: 0.05),
        ],
      ).createShader(
          Rect.fromLTWH(paddingLeft, paddingTop, graphWidth, graphHeight))
      ..style = PaintingStyle.fill;
    canvas.drawPath(grFillPath, grFillPaint);

    // 5. Draw Glowing Compression Curve
    final glowPaint = Paint()
      ..color = primaryColor.withValues(alpha: 0.35)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 4.5
      ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 3.0);
    canvas.drawPath(curvePath, glowPaint);

    final curvePaint = Paint()
      ..color = primaryColor
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2.2
      ..strokeCap = StrokeCap.round;
    canvas.drawPath(curvePath, curvePaint);

    // 6. Draw Threshold Knee Markers
    final thresholdX = inToX(T);
    final thresholdY = outToY(computeOutput(T));

    // Vertical dashed marker to threshold
    final dashPaint = Paint()
      ..color = primaryColor.withValues(alpha: 0.25)
      ..strokeWidth = 1.0;
    double sy = thresholdY;
    while (sy < paddingTop + graphHeight) {
      canvas.drawLine(
        Offset(thresholdX, sy),
        Offset(thresholdX, math.min(sy + 3, paddingTop + graphHeight)),
        dashPaint,
      );
      sy += 6;
    }

    // Threshold Handle Dot
    canvas.drawCircle(
      Offset(thresholdX, thresholdY),
      6.0,
      Paint()..color = primaryColor.withValues(alpha: 0.3),
    );
    canvas.drawCircle(
      Offset(thresholdX, thresholdY),
      3.5,
      Paint()..color = Colors.white,
    );

    // 7. Live Operating Point Dot (animated with gain reduction)
    final currentGr = gainReductionDb.abs();
    double operatingInDb = T;
    if (currentGr > 0.1 && R > 1.05) {
      // Estimate active input based on GR: GR = (x - T)*(1 - 1/R) => x = T + GR / (1 - 1/R)
      operatingInDb = (T + (currentGr / (1.0 - 1.0 / R))).clamp(minDb, maxDb);
    }
    final opX = inToX(operatingInDb);
    final opY = outToY(computeOutput(operatingInDb));

    if (currentGr > 0.1) {
      // Pulsing amber operating dot
      canvas.drawCircle(
        Offset(opX, opY),
        8.0,
        Paint()..color = const Color(0xFFFF9100).withValues(alpha: 0.35),
      );
      canvas.drawCircle(
        Offset(opX, opY),
        4.5,
        Paint()..color = const Color(0xFFFF9100),
      );
    }

    // 8. Text Legend & Readout
    final infoSpan = TextSpan(
      text:
          'Thresh: ${T.toInt()}dB  Ratio: ${R.toStringAsFixed(1)}:1  Knee: ${W.toInt()}dB',
      style: TextStyle(
        color: Colors.white.withValues(alpha: 0.6),
        fontSize: 9.0,
        fontFamily: 'monospace',
      ),
    );
    final tp = TextPainter(text: infoSpan, textDirection: TextDirection.ltr)
      ..layout();
    tp.paint(canvas, Offset(paddingLeft + 6, paddingTop + 4));
  }

  void _drawGrid(Canvas canvas, double paddingLeft, double paddingTop,
      double graphWidth, double graphHeight) {
    final gridLinePaint = Paint()
      ..color = Colors.white.withValues(alpha: 0.06)
      ..strokeWidth = 1.0;

    final textStyle = TextStyle(
      color: Colors.white.withValues(alpha: 0.4),
      fontSize: 8.5,
      fontFamily: 'monospace',
    );

    // dB ticks: -60, -48, -36, -24, -12, 0
    final dbTicks = [-60.0, -48.0, -36.0, -24.0, -12.0, 0.0];

    for (final db in dbTicks) {
      final norm = (db - minDb) / (maxDb - minDb);
      final x = paddingLeft + norm * graphWidth;
      final y = paddingTop + (1.0 - norm) * graphHeight;

      // Vertical grid line (Input level)
      canvas.drawLine(
        Offset(x, paddingTop),
        Offset(x, paddingTop + graphHeight),
        gridLinePaint,
      );

      // Horizontal grid line (Output level)
      canvas.drawLine(
        Offset(paddingLeft, y),
        Offset(paddingLeft + graphWidth, y),
        gridLinePaint,
      );

      // Y-axis label (Output)
      final tpY = TextPainter(
        text: TextSpan(text: '${db.toInt()}', style: textStyle),
        textDirection: TextDirection.ltr,
      )..layout();
      tpY.paint(canvas, Offset(paddingLeft - tpY.width - 4, y - tpY.height / 2));

      // X-axis label (Input)
      final tpX = TextPainter(
        text: TextSpan(text: '${db.toInt()}', style: textStyle),
        textDirection: TextDirection.ltr,
      )..layout();
      tpX.paint(canvas, Offset(x - tpX.width / 2, paddingTop + graphHeight + 4));
    }
  }

  @override
  bool shouldRepaint(covariant _CompressorPainter oldDelegate) {
    return oldDelegate.thresholdDb != thresholdDb ||
        oldDelegate.ratio != ratio ||
        oldDelegate.kneeDb != kneeDb ||
        oldDelegate.makeupGainDb != makeupGainDb ||
        (oldDelegate.gainReductionDb - gainReductionDb).abs() > 0.05 ||
        oldDelegate.isEnabled != isEnabled ||
        oldDelegate.primaryColor != primaryColor;
  }
}
