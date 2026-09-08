import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:sautiflow/sautiflow.dart';
import '../services/app_theme_service.dart';

/// A sleek, real-time frequency response visualization graph for Parametric EQ.
///
/// Samples 150 logarithmic frequency points across [20Hz, 20kHz] and computes
/// exact biquad filter transfer functions H(z) for each band type (Peak, Low Shelf,
/// High Shelf, Bandpass, Notch) to render both individual band curves and the master
/// combined acoustic output curve.
class ParametricEqGraph extends StatelessWidget {
  final List<EqBandConfig> bands;
  final bool isEnabled;
  final double height;
  final Color? primaryColor;

  const ParametricEqGraph({
    super.key,
    required this.bands,
    this.isEnabled = true,
    this.height = 100.0,
    this.primaryColor,
  });

  @override
  Widget build(BuildContext context) {
    final effectivePrimary = primaryColor ?? AppThemeService.instance.currentData.primary;
    final cardBg = AppThemeService.instance.currentData.cardDark;

    return Container(
      height: height,
      margin: const EdgeInsets.symmetric(vertical: 8.0),
      decoration: BoxDecoration(
        color: cardBg,
        borderRadius: BorderRadius.circular(12.0),
        border: Border.all(color: Colors.white.withValues(alpha: 0.1), width: 1.0),
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
          painter: _ParametricEqPainter(
            bands: bands,
            isEnabled: isEnabled,
            primaryColor: effectivePrimary,
          ),
        ),
      ),
    );
  }
}

class _ParametricEqPainter extends CustomPainter {
  final List<EqBandConfig> bands;
  final bool isEnabled;
  final Color primaryColor;

  _ParametricEqPainter({
    required this.bands,
    required this.isEnabled,
    required this.primaryColor,
  });

  static const double minFreq = 20.0;
  static const double maxFreq = 20000.0;
  static const double minDb = -18.0;
  static const double maxDb = 18.0;
  static const int numPoints = 150;
  static const double sampleRate = 48000.0;

  static const List<Color> _bandColors = [
    Color(0xFF00E5FF), // Cyan
    Color(0xFFFF9100), // Amber / Orange
    Color(0xFFE040FB), // Purple / Pink
    Color(0xFF00E676), // Neon Green
    Color(0xFFFF5252), // Coral Red
    Color(0xFFFFEA00), // Yellow
    Color(0xFF7C4DFF), // Deep Purple
    Color(0xFF1DE9B6), // Teal
  ];

  @override
  void paint(Canvas canvas, Size size) {
    final paddingLeft = 32.0;
    final paddingRight = 16.0;
    final paddingTop = 12.0;
    final paddingBottom = 18.0;

    final graphWidth = size.width - paddingLeft - paddingRight;
    final graphHeight = size.height - paddingTop - paddingBottom;
    if (graphWidth <= 0 || graphHeight <= 0) return;

    // 1. Draw Grid & Axes Labels
    _drawGridAndLabels(
      canvas,
      size,
      paddingLeft,
      paddingTop,
      graphWidth,
      graphHeight,
    );

    // If disabled or no bands, return early after drawing grid
    if (!isEnabled || bands.isEmpty) return;

    // 2. Pre-calculate logarithmic frequency array & X coordinates
    final freqs = List<double>.generate(numPoints, (i) {
      return minFreq * math.pow(maxFreq / minFreq, i / (numPoints - 1));
    });

    final xCoords = List<double>.generate(numPoints, (i) {
      final logRatio = math.log(freqs[i] / minFreq) / math.log(maxFreq / minFreq);
      return paddingLeft + logRatio * graphWidth;
    });

    // 3. Compute per-band dB curves & total master dB curve
    final bandDbCurves = List.generate(bands.length, (_) => List<double>.filled(numPoints, 0.0));
    final totalDbCurve = List<double>.filled(numPoints, 0.0);

    for (int b = 0; b < bands.length; b++) {
      final band = bands[b];
      if (!band.enabled) continue;

      if (band.type == EqBandType.tilt) {
        final halfGain = band.gainDb * 0.5;
        final lowBand = EqBandConfig(
          type: EqBandType.lowshelf,
          frequencyHz: band.frequencyHz,
          gainDb: -halfGain,
          slope: band.slope,
        );
        final highBand = EqBandConfig(
          type: EqBandType.highshelf,
          frequencyHz: band.frequencyHz,
          gainDb: halfGain,
          slope: band.slope,
        );
        final lowCoeffs = _computeBiquadCoeffs(lowBand, sampleRate);
        final highCoeffs = _computeBiquadCoeffs(highBand, sampleRate);
        for (int i = 0; i < numPoints; i++) {
          final db = _evalBiquadGainDb(lowCoeffs, freqs[i], sampleRate) +
              _evalBiquadGainDb(highCoeffs, freqs[i], sampleRate);
          bandDbCurves[b][i] = db;
          totalDbCurve[i] += db;
        }
      } else {
        final coeffs = _computeBiquadCoeffs(band, sampleRate);
        for (int i = 0; i < numPoints; i++) {
          final db = _evalBiquadGainDb(coeffs, freqs[i], sampleRate);
          bandDbCurves[b][i] = db;
          totalDbCurve[i] += db;
        }
      }
    }

    // Helper to map dB value to Y canvas coordinate
    double dbToY(double db) {
      final clampedDb = db.clamp(minDb, maxDb);
      final norm = (clampedDb - minDb) / (maxDb - minDb);
      return paddingTop + (1.0 - norm) * graphHeight;
    }

    final zeroY = dbToY(0.0);

    // 4. Draw Individual Band Filled Curves & Lines
    for (int b = 0; b < bands.length; b++) {
      final band = bands[b];
      if (!band.enabled) continue;

      final color = _bandColors[b % _bandColors.length];
      final bandPath = Path();
      bandPath.moveTo(xCoords[0], dbToY(bandDbCurves[b][0]));

      for (int i = 1; i < numPoints; i++) {
        bandPath.lineTo(xCoords[i], dbToY(bandDbCurves[b][i]));
      }

      // Draw subtle stroke for individual band
      final strokePaint = Paint()
        ..color = color.withValues(alpha: 0.45)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.2
        ..strokeCap = StrokeCap.round;
      canvas.drawPath(bandPath, strokePaint);

      // Draw semi-transparent gradient fill to zero-line for band
      final fillPath = Path.from(bandPath);
      fillPath.lineTo(xCoords.last, zeroY);
      fillPath.lineTo(xCoords.first, zeroY);
      fillPath.close();

      final fillPaint = Paint()
        ..shader = LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [
            color.withValues(alpha: 0.18),
            color.withValues(alpha: 0.02),
          ],
        ).createShader(Rect.fromLTWH(paddingLeft, paddingTop, graphWidth, graphHeight))
        ..style = PaintingStyle.fill;
      canvas.drawPath(fillPath, fillPaint);
    }

    // 5. Draw Master Combined Composite Curve
    final masterPath = Path();
    masterPath.moveTo(xCoords[0], dbToY(totalDbCurve[0]));
    for (int i = 1; i < numPoints; i++) {
      masterPath.lineTo(xCoords[i], dbToY(totalDbCurve[i]));
    }

    // Glowing stroke shadow
    final glowPaint = Paint()
      ..color = primaryColor.withValues(alpha: 0.35)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 5.0
      ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 4.0);
    canvas.drawPath(masterPath, glowPaint);

    // Master bright line
    final masterStrokePaint = Paint()
      ..color = primaryColor
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2.5
      ..strokeCap = StrokeCap.round;
    canvas.drawPath(masterPath, masterStrokePaint);

    // Master subtle fill under composite curve
    final masterFillPath = Path.from(masterPath);
    masterFillPath.lineTo(xCoords.last, zeroY);
    masterFillPath.lineTo(xCoords.first, zeroY);
    masterFillPath.close();

    final masterFillPaint = Paint()
      ..shader = LinearGradient(
        begin: Alignment.topCenter,
        end: Alignment.bottomCenter,
        colors: [
          primaryColor.withValues(alpha: 0.25),
          primaryColor.withValues(alpha: 0.0),
        ],
      ).createShader(Rect.fromLTWH(paddingLeft, paddingTop, graphWidth, graphHeight))
      ..style = PaintingStyle.fill;
    canvas.drawPath(masterFillPath, masterFillPaint);

    // 6. Draw Band Center Handles / Badges
    for (int b = 0; b < bands.length; b++) {
      final band = bands[b];
      if (!band.enabled) continue;

      final color = _bandColors[b % _bandColors.length];
      final freq = band.frequencyHz.clamp(minFreq, maxFreq);

      // Compute position on canvas
      final logRatio = math.log(freq / minFreq) / math.log(maxFreq / minFreq);
      final handleX = paddingLeft + logRatio * graphWidth;

      // Evaluate the actual net gain at center frequency for placing the handle
      final double bandNetDb;
      if (band.type == EqBandType.tilt) {
        bandNetDb = 0.0;
      } else {
        final coeffs = _computeBiquadCoeffs(band, sampleRate);
        bandNetDb = _evalBiquadGainDb(coeffs, freq, sampleRate);
      }
      final handleY = dbToY(bandNetDb);

      // Outer glowing ring
      canvas.drawCircle(
        Offset(handleX, handleY),
        10.0,
        Paint()..color = color.withValues(alpha: 0.25),
      );

      // Inner solid circle
      canvas.drawCircle(
        Offset(handleX, handleY),
        7.0,
        Paint()..color = color,
      );

      // Border circle
      canvas.drawCircle(
        Offset(handleX, handleY),
        7.0,
        Paint()
          ..color = Colors.white
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.2,
      );

      // Band Number Label inside dot
      final textSpan = TextSpan(
        text: '${b + 1}',
        style: const TextStyle(
          color: Colors.black,
          fontSize: 9,
          fontWeight: FontWeight.bold,
        ),
      );
      final textPainter = TextPainter(
        text: textSpan,
        textDirection: TextDirection.ltr,
      )..layout();
      textPainter.paint(
        canvas,
        Offset(handleX - textPainter.width / 2, handleY - textPainter.height / 2),
      );
    }
  }

  void _drawGridAndLabels(
    Canvas canvas,
    Size size,
    double paddingLeft,
    double paddingTop,
    double graphWidth,
    double graphHeight,
  ) {
    final gridLinePaint = Paint()
      ..color = Colors.white.withValues(alpha: 0.06)
      ..strokeWidth = 1.0;

    final zeroLinePaint = Paint()
      ..color = Colors.white.withValues(alpha: 0.2)
      ..strokeWidth = 1.0;

    final textStyle = TextStyle(
      color: Colors.white.withValues(alpha: 0.45),
      fontSize: 9,
      fontFamily: 'monospace',
    );

    // Horizontal dB lines (-18dB, -12dB, -6dB, 0dB, +6dB, +12dB, +18dB)
    final dbSteps = [-18.0, -12.0, -6.0, 0.0, 6.0, 12.0, 18.0];
    for (final db in dbSteps) {
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

    // Vertical Logarithmic Frequency lines & labels (20Hz, 100Hz, 1kHz, 10kHz, 20kHz)
    final freqTicks = [
      {'f': 20.0, 'l': '20'},
      {'f': 100.0, 'l': '100'},
      {'f': 1000.0, 'l': '1k'},
      {'f': 10000.0, 'l': '10k'},
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
      tp.paint(
        canvas,
        Offset(x - tp.width / 2, paddingTop + graphHeight + 4),
      );
    }
  }

  // --- Biquad Coefficients Math ---

  List<double> _computeBiquadCoeffs(EqBandConfig band, double fs) {
    final f0 = band.frequencyHz.clamp(20.0, fs / 2.1);
    final w0 = 2.0 * math.pi * f0 / fs;
    final sinW0 = math.sin(w0);
    final cosW0 = math.cos(w0);
    final gainDb = band.gainDb;
    final A = math.pow(10.0, gainDb / 40.0).toDouble();

    double b0 = 1.0, b1 = 0.0, b2 = 0.0;
    double a0 = 1.0, a1 = 0.0, a2 = 0.0;

    switch (band.type) {
      case EqBandType.peak:
      case EqBandType.bell:
        final q = band.q > 0 ? band.q : 1.0;
        final alpha = sinW0 / (2.0 * q);
        b0 = 1.0 + alpha * A;
        b1 = -2.0 * cosW0;
        b2 = 1.0 - alpha * A;
        a0 = 1.0 + alpha / A;
        a1 = -2.0 * cosW0;
        a2 = 1.0 - alpha / A;
        break;

      case EqBandType.lowshelf:
        final slope = band.slope > 0 ? band.slope : 1.0;
        final beta = math.sqrt(A) / slope;
        final alpha = (sinW0 / 2.0) * beta;
        b0 = A * ((A + 1.0) - (A - 1.0) * cosW0 + 2.0 * math.sqrt(A) * alpha);
        b1 = 2.0 * A * ((A - 1.0) - (A + 1.0) * cosW0);
        b2 = A * ((A + 1.0) - (A - 1.0) * cosW0 - 2.0 * math.sqrt(A) * alpha);
        a0 = (A + 1.0) + (A - 1.0) * cosW0 + 2.0 * math.sqrt(A) * alpha;
        a1 = -2.0 * ((A - 1.0) + (A + 1.0) * cosW0);
        a2 = (A + 1.0) + (A - 1.0) * cosW0 - 2.0 * math.sqrt(A) * alpha;
        break;

      case EqBandType.highshelf:
        final slope = band.slope > 0 ? band.slope : 1.0;
        final beta = math.sqrt(A) / slope;
        final alpha = (sinW0 / 2.0) * beta;
        b0 = A * ((A + 1.0) + (A - 1.0) * cosW0 + 2.0 * math.sqrt(A) * alpha);
        b1 = -2.0 * A * ((A - 1.0) + (A + 1.0) * cosW0);
        b2 = A * ((A + 1.0) + (A - 1.0) * cosW0 - 2.0 * math.sqrt(A) * alpha);
        a0 = (A + 1.0) - (A - 1.0) * cosW0 + 2.0 * math.sqrt(A) * alpha;
        a1 = 2.0 * ((A - 1.0) - (A + 1.0) * cosW0);
        a2 = (A + 1.0) - (A - 1.0) * cosW0 - 2.0 * math.sqrt(A) * alpha;
        break;

      case EqBandType.bandpass:
        final q = band.q > 0 ? band.q : 1.0;
        final alpha = sinW0 / (2.0 * q);
        b0 = alpha;
        b1 = 0.0;
        b2 = -alpha;
        a0 = 1.0 + alpha;
        a1 = -2.0 * cosW0;
        a2 = 1.0 - alpha;
        break;

      case EqBandType.notch:
        final q = band.q > 0 ? band.q : 1.0;
        final alpha = sinW0 / (2.0 * q);
        b0 = 1.0;
        b1 = -2.0 * cosW0;
        b2 = 1.0;
        a0 = 1.0 + alpha;
        a1 = -2.0 * cosW0;
        a2 = 1.0 - alpha;
        break;

      case EqBandType.lowpass:
        final q = band.q > 0 ? band.q : 1.0;
        final alpha = sinW0 / (2.0 * q);
        b0 = (1.0 - cosW0) / 2.0;
        b1 = 1.0 - cosW0;
        b2 = (1.0 - cosW0) / 2.0;
        a0 = 1.0 + alpha;
        a1 = -2.0 * cosW0;
        a2 = 1.0 - alpha;
        break;

      case EqBandType.highpass:
        final q = band.q > 0 ? band.q : 1.0;
        final alpha = sinW0 / (2.0 * q);
        b0 = (1.0 + cosW0) / 2.0;
        b1 = -(1.0 + cosW0);
        b2 = (1.0 + cosW0) / 2.0;
        a0 = 1.0 + alpha;
        a1 = -2.0 * cosW0;
        a2 = 1.0 - alpha;
        break;

      case EqBandType.tilt:
        // Handled via cascaded low-shelf + high-shelf in paint()
        b0 = 1.0;
        b1 = 0.0;
        b2 = 0.0;
        a0 = 1.0;
        a1 = 0.0;
        a2 = 0.0;
        break;
    }

    return [b0, b1, b2, a0, a1, a2];
  }

  double _evalBiquadGainDb(List<double> coeffs, double f, double fs) {
    final a0 = coeffs[3];
    if (a0 == 0.0) return 0.0;

    final b0n = coeffs[0] / a0;
    final b1n = coeffs[1] / a0;
    final b2n = coeffs[2] / a0;
    final a1n = coeffs[4] / a0;
    final a2n = coeffs[5] / a0;

    final w = 2.0 * math.pi * f / fs;
    final cos1 = math.cos(w);
    final cos2 = math.cos(2.0 * w);
    final sin1 = math.sin(w);
    final sin2 = math.sin(2.0 * w);

    final numR = b0n + b1n * cos1 + b2n * cos2;
    final numI = -b1n * sin1 - b2n * sin2;
    final denR = 1.0 + a1n * cos1 + a2n * cos2;
    final denI = -a1n * sin1 - a2n * sin2;

    final numSq = numR * numR + numI * numI;
    final denSq = denR * denR + denI * denI;

    if (denSq < 1e-12) return 0.0;
    final magSq = numSq / denSq;
    if (magSq <= 1e-12) return -60.0; // Floor at -60dB

    return 10.0 * (math.log(magSq) / math.ln10);
  }

  @override
  bool shouldRepaint(covariant _ParametricEqPainter oldDelegate) {
    return true;
  }
}
