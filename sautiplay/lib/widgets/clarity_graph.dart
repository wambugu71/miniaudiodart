import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:sautiflow/sautiflow.dart';
import '../services/app_theme_service.dart';

/// A real-time acoustic frequency response graph for the Audio Clarity DSP suite.
///
/// Computes the exact transfer function curve for the 4 Clarity profiles:
/// 1. [AudioClarityProfile.transientCrisp]: Differential rate-of-change pre-emphasis + 18 kHz smoothing filter.
/// 2. [AudioClarityProfile.airShelf]: 12 kHz ultra-high shelf biquad (+0 dB to +8 dB).
/// 3. [AudioClarityProfile.presenceExciter]: 3-way crossover (Low <120Hz, Mid 120-1200Hz, High >1200Hz).
/// 4. [AudioClarityProfile.harmonicBrilliance]: 3.5 kHz HPF sidechain with oversampled harmonic synthesis.
class ClarityGraph extends StatefulWidget {
  final AudioClarityProfile profile;
  final double intensity; // 0.0 - 1.0
  final bool isEnabled;
  final double height;
  final Color? primaryColor;

  const ClarityGraph({
    super.key,
    required this.profile,
    required this.intensity,
    this.isEnabled = true,
    this.height = 125.0,
    this.primaryColor,
  });

  @override
  State<ClarityGraph> createState() => _ClarityGraphState();
}

class _ClarityGraphState extends State<ClarityGraph> {
  double? _touchFreq;
  double? _touchDb;

  @override
  Widget build(BuildContext context) {
    final effectivePrimary =
        widget.primaryColor ?? AppThemeService.instance.currentData.primary;
    final cardBg = AppThemeService.instance.currentData.cardDark;

    return Container(
      height: widget.height,
      margin: const EdgeInsets.symmetric(vertical: 8.0),
      decoration: BoxDecoration(
        color: cardBg,
        borderRadius: BorderRadius.circular(12.0),
        border: Border.all(
          color: Colors.white.withValues(alpha: 0.1),
          width: 1.0,
        ),
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
        child: GestureDetector(
          onHorizontalDragDown: (details) =>
              _handleTouch(details.localPosition),
          onHorizontalDragUpdate: (details) =>
              _handleTouch(details.localPosition),
          onHorizontalDragEnd: (_) => _clearTouch(),
          onHorizontalDragCancel: () => _clearTouch(),
          onTapDown: (details) => _handleTouch(details.localPosition),
          onTapUp: (_) => _clearTouch(),
          onTapCancel: () => _clearTouch(),
          child: CustomPaint(
            size: Size.infinite,
            painter: _ClarityPainter(
              profile: widget.profile,
              intensity: widget.intensity,
              isEnabled: widget.isEnabled,
              primaryColor: effectivePrimary,
              touchFreq: _touchFreq,
              touchDb: _touchDb,
            ),
          ),
        ),
      ),
    );
  }

  void _handleTouch(Offset localPos) {
    final width = context.size?.width ?? 300.0;
    const paddingLeft = 34.0;
    const paddingRight = 16.0;
    final graphWidth = width - paddingLeft - paddingRight;
    if (graphWidth <= 0) return;

    final x = (localPos.dx - paddingLeft).clamp(0.0, graphWidth);
    final norm = x / graphWidth;
    final freq = 20.0 * math.pow(20000.0 / 20.0, norm).toDouble();
    final db = widget.isEnabled
        ? _ClarityPainter.computeGainDb(widget.profile, widget.intensity, freq)
        : 0.0;

    setState(() {
      _touchFreq = freq;
      _touchDb = db;
    });
  }

  void _clearTouch() {
    if (_touchFreq != null) {
      setState(() {
        _touchFreq = null;
        _touchDb = null;
      });
    }
  }
}

class _ClarityPainter extends CustomPainter {
  final AudioClarityProfile profile;
  final double intensity;
  final bool isEnabled;
  final Color primaryColor;
  final double? touchFreq;
  final double? touchDb;

  _ClarityPainter({
    required this.profile,
    required this.intensity,
    required this.isEnabled,
    required this.primaryColor,
    this.touchFreq,
    this.touchDb,
  });

  static const double minFreq = 20.0;
  static const double maxFreq = 20000.0;
  static const double minDb = -2.0;
  static const double maxDb = 10.0;
  static const int numPoints = 130;
  static const double sampleRate = 48000.0;

  @override
  void paint(Canvas canvas, Size size) {
    const paddingLeft = 34.0;
    const paddingRight = 16.0;
    const paddingTop = 14.0;
    const paddingBottom = 18.0;

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

    // 1. Grid & Axes
    _drawGrid(canvas, size, paddingLeft, paddingRight, paddingTop,
        paddingBottom, graphWidth, graphHeight, freqToX, dbToY);

    // 2. Profile acoustic feature annotations (e.g. 12k shelf, 3.5k exciter, vocal presence)
    if (isEnabled && intensity > 0.02) {
      _drawProfileAnnotations(
          canvas, size, freqToX, dbToY, graphHeight, paddingTop);
    }

    // 3. Response Curve & Fill
    _drawResponseCurve(canvas, size, graphWidth, graphHeight, freqToX, dbToY);

    // 4. Header Badge / Legend
    _drawHeaderLegend(canvas, size);

    // 5. Interactive Touch Marker
    if (touchFreq != null && touchDb != null) {
      _drawTouchMarker(canvas, freqToX, dbToY);
    }
  }

  void _drawGrid(
    Canvas canvas,
    Size size,
    double paddingLeft,
    double paddingRight,
    double paddingTop,
    double paddingBottom,
    double graphWidth,
    double graphHeight,
    double Function(double) freqToX,
    double Function(double) dbToY,
  ) {
    final gridPaint = Paint()
      ..color = Colors.white.withValues(alpha: 0.05)
      ..strokeWidth = 1.0;

    final basePaint = Paint()
      ..color = Colors.white.withValues(alpha: 0.18)
      ..strokeWidth = 1.0;

    final textStyle = TextStyle(
      color: Colors.white.withValues(alpha: 0.35),
      fontSize: 9.0,
      fontFamily: 'monospace',
      fontWeight: FontWeight.w500,
    );

    // Horizontal dB lines: 0dB, +3dB, +6dB, +9dB
    final dbLevels = [0.0, 3.0, 6.0, 9.0];
    for (final db in dbLevels) {
      final y = dbToY(db);
      final isZero = db == 0.0;
      canvas.drawLine(
        Offset(paddingLeft, y),
        Offset(size.width - paddingRight, y),
        isZero ? basePaint : gridPaint,
      );

      final label = isZero ? '0dB' : '+${db.toInt()}';
      final tp = TextPainter(
        text: TextSpan(
          text: label,
          style: isZero
              ? textStyle.copyWith(color: Colors.white.withValues(alpha: 0.6))
              : textStyle,
        ),
        textDirection: TextDirection.ltr,
      )..layout();
      tp.paint(canvas, Offset(paddingLeft - tp.width - 4, y - tp.height / 2));
    }

    // Vertical Frequency lines
    final freqMarkers = [
      (100.0, '100'),
      (500.0, '500'),
      (1000.0, '1k'),
      (5000.0, '5k'),
      (10000.0, '10k'),
      (20000.0, '20k'),
    ];

    for (final marker in freqMarkers) {
      final x = freqToX(marker.$1);
      canvas.drawLine(
        Offset(x, paddingTop),
        Offset(x, size.height - paddingBottom),
        gridPaint,
      );

      final tp = TextPainter(
        text: TextSpan(text: marker.$2, style: textStyle),
        textDirection: TextDirection.ltr,
      )..layout();
      tp.paint(
        canvas,
        Offset(x - tp.width / 2, size.height - paddingBottom + 3),
      );
    }
  }

  void _drawProfileAnnotations(
    Canvas canvas,
    Size size,
    double Function(double) freqToX,
    double Function(double) dbToY,
    double graphHeight,
    double paddingTop,
  ) {
    switch (profile) {
      case AudioClarityProfile.airShelf:
        // 12 kHz ultra-high shelf anchor
        final x12k = freqToX(12000.0);
        final y12k = dbToY(computeGainDb(profile, intensity, 12000.0));

        final markerPaint = Paint()
          ..color = primaryColor.withValues(alpha: 0.3)
          ..strokeWidth = 1.0
          ..style = PaintingStyle.stroke;
        canvas.drawLine(Offset(x12k, paddingTop),
            Offset(x12k, paddingTop + graphHeight), markerPaint);

        // Marker dot at 12 kHz
        canvas.drawCircle(
          Offset(x12k, y12k),
          3.5,
          Paint()..color = primaryColor,
        );
        canvas.drawCircle(
          Offset(x12k, y12k),
          7.0,
          Paint()..color = primaryColor.withValues(alpha: 0.25),
        );
        break;

      case AudioClarityProfile.presenceExciter:
        // Vocal presence band: 1.2 kHz - 8 kHz highlight
        final xStart = freqToX(1200.0);
        final xEnd = freqToX(8000.0);
        final bandRect =
            Rect.fromLTRB(xStart, paddingTop, xEnd, paddingTop + graphHeight);

        final bandPaint = Paint()
          ..shader = LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [
              primaryColor.withValues(alpha: 0.12),
              primaryColor.withValues(alpha: 0.02),
            ],
          ).createShader(bandRect);
        canvas.drawRect(bandRect, bandPaint);
        break;

      case AudioClarityProfile.harmonicBrilliance:
        // 3.5 kHz HPF cutoff line
        final xCutoff = freqToX(3500.0);
        final cutoffPaint = Paint()
          ..color = primaryColor.withValues(alpha: 0.35)
          ..strokeWidth = 1.0;
        canvas.drawLine(
          Offset(xCutoff, paddingTop),
          Offset(xCutoff, paddingTop + graphHeight),
          cutoffPaint,
        );

        // Synthesized harmonic markers at 7kHz and 14kHz
        for (final harmFreq in [7000.0, 14000.0]) {
          final xHarm = freqToX(harmFreq);
          canvas.drawLine(
            Offset(xHarm, paddingTop + 6),
            Offset(xHarm, paddingTop + graphHeight - 4),
            Paint()
              ..color = primaryColor.withValues(alpha: 0.15)
              ..strokeWidth = 1.0,
          );
        }
        break;

      case AudioClarityProfile.transientCrisp:
        // Attack band 2k - 16k
        final xStart = freqToX(2000.0);
        final xEnd = freqToX(16000.0);
        final bandRect =
            Rect.fromLTRB(xStart, paddingTop, xEnd, paddingTop + graphHeight);
        canvas.drawRect(
          bandRect,
          Paint()..color = primaryColor.withValues(alpha: 0.05),
        );
        break;
    }
  }

  void _drawResponseCurve(
    Canvas canvas,
    Size size,
    double graphWidth,
    double graphHeight,
    double Function(double) freqToX,
    double Function(double) dbToY,
  ) {
    final curveColor =
        isEnabled ? primaryColor : Colors.white.withValues(alpha: 0.3);
    final yZero = dbToY(0.0);

    final path = Path();
    final fillPath = Path();

    double startX = freqToX(minFreq);
    double startY =
        isEnabled ? dbToY(computeGainDb(profile, intensity, minFreq)) : yZero;

    path.moveTo(startX, startY);
    fillPath.moveTo(startX, yZero);
    fillPath.lineTo(startX, startY);

    for (int i = 1; i <= numPoints; i++) {
      final t = i / numPoints;
      final freq = minFreq * math.pow(maxFreq / minFreq, t);
      final db = isEnabled ? computeGainDb(profile, intensity, freq) : 0.0;
      final x = freqToX(freq);
      final y = dbToY(db);

      path.lineTo(x, y);
      fillPath.lineTo(x, y);
    }

    final endX = freqToX(maxFreq);
    fillPath.lineTo(endX, yZero);
    fillPath.close();

    // Fill under curve
    if (isEnabled && intensity > 0.01) {
      final fillPaint = Paint()
        ..shader = LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [
            curveColor.withValues(alpha: 0.35),
            curveColor.withValues(alpha: 0.03),
          ],
        ).createShader(Rect.fromLTRB(0, 0, size.width, size.height))
        ..style = PaintingStyle.fill;
      canvas.drawPath(fillPath, fillPaint);
    }

    // Outer glow
    if (isEnabled) {
      final glowPaint = Paint()
        ..color = curveColor.withValues(alpha: 0.25)
        ..strokeWidth = 4.0
        ..style = PaintingStyle.stroke
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round;
      canvas.drawPath(path, glowPaint);
    }

    // Main curve stroke
    final strokePaint = Paint()
      ..color = curveColor
      ..strokeWidth = isEnabled ? 2.2 : 1.2
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;
    canvas.drawPath(path, strokePaint);
  }

  void _drawHeaderLegend(Canvas canvas, Size size) {
    final profileName = _getProfileTitle(profile);
    final intensityPct = (intensity * 100).round();

    final badgeText = isEnabled
        ? '$profileName  •  $intensityPct%'
        : '$profileName  •  BYPASSED';

    final textSpan = TextSpan(
      text: badgeText,
      style: TextStyle(
        color: isEnabled
            ? Colors.white.withValues(alpha: 0.9)
            : Colors.white.withValues(alpha: 0.4),
        fontSize: 10.0,
        fontWeight: FontWeight.w700,
        letterSpacing: 0.5,
      ),
    );

    final tp = TextPainter(
      text: textSpan,
      textDirection: TextDirection.ltr,
    )..layout();

    const padding = EdgeInsets.symmetric(horizontal: 6.0, vertical: 2.0);
    final badgeRect = Rect.fromLTWH(
      size.width - tp.width - 24,
      8.0,
      tp.width + padding.horizontal,
      tp.height + padding.vertical,
    );

    final bgPaint = Paint()
      ..color = isEnabled
          ? primaryColor.withValues(alpha: 0.15)
          : Colors.white.withValues(alpha: 0.05)
      ..style = PaintingStyle.fill;
    final borderPaint = Paint()
      ..color = isEnabled
          ? primaryColor.withValues(alpha: 0.4)
          : Colors.white.withValues(alpha: 0.1)
      ..strokeWidth = 0.8
      ..style = PaintingStyle.stroke;

    final rrect =
        RRect.fromRectAndRadius(badgeRect, const Radius.circular(4.0));
    canvas.drawRRect(rrect, bgPaint);
    canvas.drawRRect(rrect, borderPaint);

    tp.paint(canvas,
        Offset(badgeRect.left + padding.left, badgeRect.top + padding.top));
  }

  void _drawTouchMarker(
    Canvas canvas,
    double Function(double) freqToX,
    double Function(double) dbToY,
  ) {
    final x = freqToX(touchFreq!);
    final y = dbToY(touchDb!);

    // Vertical indicator line
    final linePaint = Paint()
      ..color = Colors.white.withValues(alpha: 0.35)
      ..strokeWidth = 1.0;
    canvas.drawLine(Offset(x, 14.0), Offset(x, y), linePaint);

    // Indicator Dot
    canvas.drawCircle(Offset(x, y), 4.5, Paint()..color = Colors.white);
    canvas.drawCircle(Offset(x, y), 2.5, Paint()..color = primaryColor);

    // Tooltip label
    final freqStr = touchFreq! >= 1000
        ? '${(touchFreq! / 1000).toStringAsFixed(1)}kHz'
        : '${touchFreq!.toInt()}Hz';
    final dbStr = '${touchDb! >= 0 ? '+' : ''}${touchDb!.toStringAsFixed(1)}dB';
    final tooltipText = '$freqStr: $dbStr';

    final tp = TextPainter(
      text: TextSpan(
        text: tooltipText,
        style: const TextStyle(
          color: Colors.white,
          fontSize: 9.5,
          fontWeight: FontWeight.bold,
          fontFamily: 'monospace',
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout();

    final tooltipRect = Rect.fromCenter(
      center: Offset(x.clamp(35.0 + tp.width / 2, 280.0), y - 14.0),
      width: tp.width + 10.0,
      height: tp.height + 6.0,
    );

    canvas.drawRRect(
      RRect.fromRectAndRadius(tooltipRect, const Radius.circular(4.0)),
      Paint()..color = Colors.black.withValues(alpha: 0.85),
    );
    canvas.drawRRect(
      RRect.fromRectAndRadius(tooltipRect, const Radius.circular(4.0)),
      Paint()
        ..color = primaryColor.withValues(alpha: 0.6)
        ..strokeWidth = 0.8
        ..style = PaintingStyle.stroke,
    );

    tp.paint(
      canvas,
      Offset(tooltipRect.left + 5.0, tooltipRect.top + 3.0),
    );
  }

  String _getProfileTitle(AudioClarityProfile p) {
    switch (p) {
      case AudioClarityProfile.transientCrisp:
        return 'CRISP TRANSIENT';
      case AudioClarityProfile.airShelf:
        return 'AIR SHELF (12kHz)';
      case AudioClarityProfile.presenceExciter:
        return 'VOCAL PRESENCE';
      case AudioClarityProfile.harmonicBrilliance:
        return 'HARMONIC EXCITER';
    }
  }

  /// Calculates the exact DSP frequency response gain in dB at [freq] for [profile] and [intensity].
  static double computeGainDb(
    AudioClarityProfile profile,
    double intensity,
    double freq,
  ) {
    if (intensity <= 0.0001) return 0.0;

    switch (profile) {
      case AudioClarityProfile.transientCrisp:
        return _computeTransientCrispGainDb(intensity, freq);
      case AudioClarityProfile.airShelf:
        return _computeAirShelfGainDb(intensity, freq);
      case AudioClarityProfile.presenceExciter:
        return _computePresenceExciterGainDb(intensity, freq);
      case AudioClarityProfile.harmonicBrilliance:
        return _computeHarmonicBrillianceGainDb(intensity, freq);
    }
  }

  /// 1. Transient Crisp: Differential pre-emphasis + 18 kHz smoothing low-pass.
  static double _computeTransientCrispGainDb(double intensity, double freq) {
    final w = 2.0 * math.pi * freq / sampleRate;
    final diffScale = intensity * 1.5;

    // Differentiator H1(e^jw) = 1 + diffScale * (1 - e^-jw)
    final cosW = math.cos(w);
    final sinW = math.sin(w);
    final r1 = 1.0 + diffScale * (1.0 - cosW);
    final i1 = diffScale * sinW;
    final mag1Sq = r1 * r1 + i1 * i1;

    // Smoothing Low-Pass 18 kHz:
    final fc = math.min(18000.0, sampleRate * 0.45);
    final w0 = 2.0 * math.pi * fc / sampleRate;
    final gamma = math.cos(w0) / (1.0 + math.sin(w0));
    final smoothA1 = -gamma;
    final smoothB0 = (1.0 - gamma) * 0.5;
    final smoothB1 = (1.0 - gamma) * 0.5;

    final nr = smoothB0 + smoothB1 * cosW;
    final ni = -smoothB1 * sinW;
    final dr = 1.0 + smoothA1 * cosW;
    final di = -smoothA1 * sinW;
    final mag2Sq = (nr * nr + ni * ni) / (dr * dr + di * di);

    final totalMag = math.sqrt(mag1Sq * mag2Sq);
    if (totalMag <= 1e-6) return -60.0;
    return 20.0 * (math.log(totalMag) / math.ln10);
  }

  /// 2. Air Shelf: 12 kHz High-Shelf Biquad (+0 dB to +8 dB).
  static double _computeAirShelfGainDb(double intensity, double freq) {
    final shelfGainDb = intensity * 8.0;
    if (shelfGainDb.abs() < 0.01) return 0.0;

    final A = math.pow(10.0, shelfGainDb / 40.0).toDouble();
    double w0 = 2.0 * math.pi * 12000.0 / sampleRate;
    if (w0 > math.pi * 0.95) w0 = math.pi * 0.95;

    final cosW0 = math.cos(w0);
    final sinW0 = math.sin(w0);
    final alpha =
        sinW0 / 2.0 * math.sqrt((A + 1.0 / A) * (1.0 / 0.7071 - 1.0) + 2.0);
    final sqrtA = 2.0 * math.sqrt(A) * alpha;

    final a0 = (A + 1.0) - (A - 1.0) * cosW0 + sqrtA;
    final b0 = (A * ((A + 1.0) + (A - 1.0) * cosW0 + sqrtA)) / a0;
    final b1 = (-2.0 * A * ((A - 1.0) + (A + 1.0) * cosW0)) / a0;
    final b2 = (A * ((A + 1.0) + (A - 1.0) * cosW0 - sqrtA)) / a0;
    final a1 = (2.0 * ((A - 1.0) - (A + 1.0) * cosW0)) / a0;
    final a2 = ((A + 1.0) - (A - 1.0) * cosW0 - sqrtA) / a0;

    return _evaluateBiquadGainDb(b0, b1, b2, a1, a2, freq);
  }

  /// 3. Presence Exciter: 3-way crossover (Low <120Hz, Mid 120-1200Hz, High >1200Hz).
  static double _computePresenceExciterGainDb(double intensity, double freq) {
    final midGain = 1.0 + intensity * 0.4;
    final highGain = 1.0 + intensity * 0.8;

    // Lowpass 120 Hz
    final (lB0, lB1, lB2, lA1, lA2) = _calcLowpass(120.0, 0.7071);
    final lowC = _evaluateBiquadComplex(lB0, lB1, lB2, lA1, lA2, freq);

    // Highpass 1200 Hz
    final (hB0, hB1, hB2, hA1, hA2) = _calcHighpass(1200.0, 0.7071);
    final highC = _evaluateBiquadComplex(hB0, hB1, hB2, hA1, hA2, freq);

    // Mid is derived: mid = 1 - low - high
    final midReal = 1.0 - lowC.$1 - highC.$1;
    final midImag = -lowC.$2 - highC.$2;

    // Total = low + mid * midGain + high * highGain
    final totalReal = lowC.$1 + midReal * midGain + highC.$1 * highGain;
    final totalImag = lowC.$2 + midImag * midGain + highC.$2 * highGain;

    final magSq = totalReal * totalReal + totalImag * totalImag;
    if (magSq <= 1e-12) return -60.0;
    return 10.0 * (math.log(magSq) / math.ln10);
  }

  /// 4. Harmonic Brilliance: 3.5 kHz HPF Sidechain with Oversampled Harmonic Synthesis.
  static double _computeHarmonicBrillianceGainDb(
      double intensity, double freq) {
    final mix = intensity * 0.45;
    final (b0, b1, b2, a1, a2) = _calcHighpass(3500.0, 0.7071);
    final hpC = _evaluateBiquadComplex(b0, b1, b2, a1, a2, freq);

    // Sidechain generates odd and even harmonics from the highpassed signal
    // Effective spectral excitation magnitude:
    final hpMag = math.sqrt(hpC.$1 * hpC.$1 + hpC.$2 * hpC.$2);
    final harmonicBoost = 1.0 + mix * hpMag * 1.6;

    if (harmonicBoost <= 1e-6) return -60.0;
    return 20.0 * (math.log(harmonicBoost) / math.ln10);
  }

  // --- Biquad Helpers ---
  static double _evaluateBiquadGainDb(
    double b0,
    double b1,
    double b2,
    double a1,
    double a2,
    double freq,
  ) {
    final c = _evaluateBiquadComplex(b0, b1, b2, a1, a2, freq);
    final magSq = c.$1 * c.$1 + c.$2 * c.$2;
    if (magSq <= 1e-12) return -60.0;
    return 10.0 * (math.log(magSq) / math.ln10);
  }

  static (double, double) _evaluateBiquadComplex(
    double b0,
    double b1,
    double b2,
    double a1,
    double a2,
    double freq,
  ) {
    final w = 2.0 * math.pi * freq / sampleRate;
    final cosW = math.cos(w);
    final sinW = math.sin(w);
    final cos2W = math.cos(2.0 * w);
    final sin2W = math.sin(2.0 * w);

    final numR = b0 + b1 * cosW + b2 * cos2W;
    final numI = -(b1 * sinW + b2 * sin2W);

    final denR = 1.0 + a1 * cosW + a2 * cos2W;
    final denI = -(a1 * sinW + a2 * sin2W);

    final denMagSq = denR * denR + denI * denI;
    if (denMagSq <= 1e-12) return (0.0, 0.0);

    final real = (numR * denR + numI * denI) / denMagSq;
    final imag = (numI * denR - numR * denI) / denMagSq;
    return (real, imag);
  }

  static (double, double, double, double, double) _calcLowpass(
    double freq,
    double q,
  ) {
    double w0 = 2.0 * math.pi * freq / sampleRate;
    if (w0 > math.pi * 0.95) w0 = math.pi * 0.95;
    final cosW0 = math.cos(w0);
    final sinW0 = math.sin(w0);
    final alpha = sinW0 / (2.0 * q);

    final a0 = 1.0 + alpha;
    final b0 = ((1.0 - cosW0) / 2.0) / a0;
    final b1 = (1.0 - cosW0) / a0;
    final b2 = ((1.0 - cosW0) / 2.0) / a0;
    final a1 = (-2.0 * cosW0) / a0;
    final a2 = (1.0 - alpha) / a0;
    return (b0, b1, b2, a1, a2);
  }

  static (double, double, double, double, double) _calcHighpass(
    double freq,
    double q,
  ) {
    double w0 = 2.0 * math.pi * freq / sampleRate;
    if (w0 > math.pi * 0.95) w0 = math.pi * 0.95;
    final cosW0 = math.cos(w0);
    final sinW0 = math.sin(w0);
    final alpha = sinW0 / (2.0 * q);

    final a0 = 1.0 + alpha;
    final b0 = ((1.0 + cosW0) / 2.0) / a0;
    final b1 = (-(1.0 + cosW0)) / a0;
    final b2 = ((1.0 + cosW0) / 2.0) / a0;
    final a1 = (-2.0 * cosW0) / a0;
    final a2 = (1.0 - alpha) / a0;
    return (b0, b1, b2, a1, a2);
  }

  @override
  bool shouldRepaint(covariant _ClarityPainter oldDelegate) {
    return oldDelegate.profile != profile ||
        oldDelegate.intensity != intensity ||
        oldDelegate.isEnabled != isEnabled ||
        oldDelegate.primaryColor != primaryColor ||
        oldDelegate.touchFreq != touchFreq ||
        oldDelegate.touchDb != touchDb;
  }
}
