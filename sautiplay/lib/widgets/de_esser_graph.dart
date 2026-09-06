import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:sautiflow/sautiflow.dart';
import '../services/app_theme_service.dart';

/// An interactive, real-time frequency response curve and dynamic Gain Reduction (GR)
/// meter for the De-Esser DSP suite.
///
/// Features:
/// - Logarithmic frequency response curve (20 Hz – 20 kHz) depicting high-shelf split-band attenuation or wideband ducking.
/// - Glowing sibilance detection passband overlay starting at [frequencyHz].
/// - Real-time animated Gain Reduction meter (0 to -18 dB) reacting dynamically during playback.
/// - Interactive touch scrubbing with frequency (Hz) and gain (dB) readout tooltip.
class DeEsserGraph extends StatefulWidget {
  final DeEsserMode mode;
  final double frequencyHz;
  final double thresholdDb;
  final double ratio;
  final double maxReductionDb;
  final double gainReductionDb;
  final bool isEnabled;
  final double height;
  final Color? primaryColor;

  const DeEsserGraph({
    super.key,
    required this.mode,
    required this.frequencyHz,
    required this.thresholdDb,
    required this.ratio,
    required this.maxReductionDb,
    this.gainReductionDb = 0.0,
    this.isEnabled = true,
    this.height = 135.0,
    this.primaryColor,
  });

  @override
  State<DeEsserGraph> createState() => _DeEsserGraphState();
}

class _DeEsserGraphState extends State<DeEsserGraph> {
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
          onPanDown: (d) => _updateTouch(d.localPosition),
          onPanUpdate: (d) => _updateTouch(d.localPosition),
          onPanEnd: (_) => setState(() {
            _touchFreq = null;
            _touchDb = null;
          }),
          onPanCancel: () => setState(() {
            _touchFreq = null;
            _touchDb = null;
          }),
          child: CustomPaint(
            size: Size.infinite,
            painter: _DeEsserPainter(
              mode: widget.mode,
              frequencyHz: widget.frequencyHz,
              thresholdDb: widget.thresholdDb,
              ratio: widget.ratio,
              maxReductionDb: widget.maxReductionDb,
              gainReductionDb: widget.gainReductionDb,
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

  void _updateTouch(Offset pos) {
    const minFreq = 20.0;
    const maxFreq = 20000.0;
    final w = context.size?.width ?? 300.0;
    if (w <= 0) return;

    final t = (pos.dx / w).clamp(0.0, 1.0);
    final logMin = math.log(minFreq);
    final logMax = math.log(maxFreq);
    final freq = math.exp(logMin + t * (logMax - logMin));

    final db = _DeEsserPainter.computeGainDb(
      widget.mode,
      widget.frequencyHz,
      widget.maxReductionDb,
      widget.gainReductionDb,
      widget.isEnabled,
      freq,
    );

    setState(() {
      _touchFreq = freq;
      _touchDb = db;
    });
  }
}

class _DeEsserPainter extends CustomPainter {
  final DeEsserMode mode;
  final double frequencyHz;
  final double thresholdDb;
  final double ratio;
  final double maxReductionDb;
  final double gainReductionDb;
  final bool isEnabled;
  final Color primaryColor;
  final double? touchFreq;
  final double? touchDb;

  static const double _minFreq = 20.0;
  static const double _maxFreq = 20000.0;
  static const double _minDb = -24.0;
  static const double _maxDb = 6.0;

  _DeEsserPainter({
    required this.mode,
    required this.frequencyHz,
    required this.thresholdDb,
    required this.ratio,
    required this.maxReductionDb,
    required this.gainReductionDb,
    required this.isEnabled,
    required this.primaryColor,
    this.touchFreq,
    this.touchDb,
  });

  static double computeGainDb(
    DeEsserMode mode,
    double fc,
    double maxReductionDb,
    double liveGrDb,
    bool enabled,
    double f,
  ) {
    if (!enabled) return 0.0;

    // Display live gain reduction if currently compressing, else preview max reduction depth
    final displayReduction = liveGrDb.abs() > 0.05
        ? liveGrDb.abs().clamp(0.0, maxReductionDb)
        : (maxReductionDb * 0.5).clamp(2.0, 18.0);

    if (mode == DeEsserMode.wideBand) {
      return -displayReduction;
    }

    // SplitBand: 2nd-order High-Shelf approximation
    final ratio = f / fc;
    if (ratio <= 0.5) return 0.0;

    // Smooth sigmoidal shelving transition centered around fc
    final t = 1.0 / (1.0 + math.pow(ratio, -3.0));
    return -displayReduction * t;
  }

  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width;
    final h = size.height;
    if (w <= 0 || h <= 0) return;

    final meterWidth = 38.0;
    final graphWidth = w - meterWidth;

    _drawGrid(canvas, graphWidth, h);
    _drawSibilanceZone(canvas, graphWidth, h);
    _drawResponseCurve(canvas, graphWidth, h);
    _drawGainReductionMeter(canvas, graphWidth, h, meterWidth);

    if (touchFreq != null && touchDb != null) {
      _drawTooltip(canvas, graphWidth, h, touchFreq!, touchDb!);
    }
  }

  void _drawGrid(Canvas canvas, double w, double h) {
    final linePaint = Paint()
      ..color = Colors.white.withValues(alpha: 0.06)
      ..strokeWidth = 1.0;

    final zeroLinePaint = Paint()
      ..color = Colors.white.withValues(alpha: 0.18)
      ..strokeWidth = 1.0;

    final textStyle = TextStyle(
      color: Colors.white.withValues(alpha: 0.35),
      fontSize: 9.0,
      fontWeight: FontWeight.w500,
    );

    // Horizontal dB lines: -18 dB, -12 dB, -6 dB, 0 dB
    final dbLines = [-18.0, -12.0, -6.0, 0.0];
    for (final db in dbLines) {
      final y = _dbToY(db, h);
      final isZero = db == 0.0;
      canvas.drawLine(
        Offset(0, y),
        Offset(w, y),
        isZero ? zeroLinePaint : linePaint,
      );

      final tp = TextPainter(
        text: TextSpan(text: '${db.toInt()} dB', style: textStyle),
        textDirection: TextDirection.ltr,
      )..layout();
      tp.paint(canvas, Offset(4, y - tp.height - 1));
    }

    // Vertical Frequency lines
    final freqs = [100.0, 500.0, 1000.0, 2000.0, 5000.0, 10000.0];
    for (final f in freqs) {
      final x = _freqToX(f, w);
      canvas.drawLine(Offset(x, 0), Offset(x, h), linePaint);

      final label = f >= 1000 ? '${(f / 1000).toInt()}k' : '${f.toInt()}';
      final tp = TextPainter(
        text: TextSpan(text: label, style: textStyle),
        textDirection: TextDirection.ltr,
      )..layout();
      tp.paint(canvas, Offset(x - tp.width / 2, h - tp.height - 2));
    }
  }

  void _drawSibilanceZone(Canvas canvas, double w, double h) {
    if (!isEnabled) return;

    final startX = _freqToX(frequencyHz, w);
    final endX = w;

    if (startX < endX) {
      final rect = Rect.fromLTRB(startX, 0, endX, h);
      final glowColor = primaryColor.withValues(alpha: 0.12);
      final gradient = LinearGradient(
        begin: Alignment.centerLeft,
        end: Alignment.centerRight,
        colors: [
          glowColor,
          primaryColor.withValues(alpha: 0.04),
        ],
      );

      final zonePaint = Paint()
        ..shader = gradient.createShader(rect)
        ..style = PaintingStyle.fill;
      canvas.drawRect(rect, zonePaint);

      // Dashed cutoff marker line at fc
      final markerPaint = Paint()
        ..color = primaryColor.withValues(alpha: 0.65)
        ..strokeWidth = 1.2;

      double curY = 0;
      while (curY < h) {
        canvas.drawLine(
          Offset(startX, curY),
          Offset(startX, math.min(curY + 4.0, h)),
          markerPaint,
        );
        curY += 8.0;
      }

      // Detection frequency label
      final tp = TextPainter(
        text: TextSpan(
          text: '${(frequencyHz / 1000.0).toStringAsFixed(1)} kHz',
          style: TextStyle(
            color: primaryColor.withValues(alpha: 0.85),
            fontSize: 9.0,
            fontWeight: FontWeight.bold,
          ),
        ),
        textDirection: TextDirection.ltr,
      )..layout();
      tp.paint(canvas, Offset(startX + 4, 4));
    }
  }

  void _drawResponseCurve(Canvas canvas, double w, double h) {
    final path = Path();
    final fillPath = Path();

    const steps = 140;
    for (int i = 0; i <= steps; i++) {
      final x = (i / steps) * w;
      final f = _xToFreq(x, w);
      final db = computeGainDb(
        mode,
        frequencyHz,
        maxReductionDb,
        gainReductionDb,
        isEnabled,
        f,
      );
      final y = _dbToY(db, h);

      if (i == 0) {
        path.moveTo(x, y);
        fillPath.moveTo(x, _dbToY(0.0, h));
        fillPath.lineTo(x, y);
      } else {
        path.lineTo(x, y);
        fillPath.lineTo(x, y);
      }
    }

    fillPath.lineTo(w, _dbToY(0.0, h));
    fillPath.close();

    final curveColor = isEnabled ? primaryColor : Colors.white.withValues(alpha: 0.4);

    // Shaded fill under attenuation curve
    if (isEnabled) {
      final fillPaint = Paint()
        ..shader = LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [
            curveColor.withValues(alpha: 0.22),
            curveColor.withValues(alpha: 0.02),
          ],
        ).createShader(Rect.fromLTRB(0, 0, w, h))
        ..style = PaintingStyle.fill;
      canvas.drawPath(fillPath, fillPaint);
    }

    // Neon response line
    final linePaint = Paint()
      ..color = curveColor
      ..strokeWidth = 2.2
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round;

    canvas.drawPath(path, linePaint);

    // Mode watermark
    final modeLabel = mode == DeEsserMode.splitBand ? 'SPLIT-BAND DYNAMIC SHELF' : 'WIDEBAND DUCK';
    final tp = TextPainter(
      text: TextSpan(
        text: modeLabel,
        style: TextStyle(
          color: Colors.white.withValues(alpha: isEnabled ? 0.35 : 0.15),
          fontSize: 9.5,
          fontWeight: FontWeight.w700,
          letterSpacing: 1.1,
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    tp.paint(canvas, Offset(8, h - tp.height - 18));
  }

  void _drawGainReductionMeter(Canvas canvas, double graphW, double h, double meterW) {
    final meterX = graphW + 6.0;
    final barW = meterW - 12.0;
    final topY = 16.0;
    final bottomY = h - 14.0;
    final meterH = bottomY - topY;

    // Meter divider line
    canvas.drawLine(
      Offset(graphW, 4),
      Offset(graphW, h - 4),
      Paint()
        ..color = Colors.white.withValues(alpha: 0.08)
        ..strokeWidth = 1.0,
    );

    // Meter Header
    final headerTp = TextPainter(
      text: TextSpan(
        text: 'GR',
        style: TextStyle(
          color: Colors.white.withValues(alpha: 0.5),
          fontSize: 8.5,
          fontWeight: FontWeight.bold,
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    headerTp.paint(canvas, Offset(meterX + (barW - headerTp.width) / 2, 3));

    // Meter track background
    final trackRect = RRect.fromRectAndRadius(
      Rect.fromLTWH(meterX, topY, barW, meterH),
      const Radius.circular(3.0),
    );
    canvas.drawRRect(
      trackRect,
      Paint()..color = Colors.white.withValues(alpha: 0.06),
    );

    // Meter fill (Gain reduction fills downward from 0 dB)
    final effectiveGrDb = isEnabled ? gainReductionDb.abs().clamp(0.0, 18.0) : 0.0;
    final grFraction = (effectiveGrDb / 18.0).clamp(0.0, 1.0);

    if (grFraction > 0.01) {
      final fillH = meterH * grFraction;
      final fillRect = RRect.fromRectAndRadius(
        Rect.fromLTWH(meterX, topY, barW, fillH),
        const Radius.circular(3.0),
      );

      final grGradient = LinearGradient(
        begin: Alignment.topCenter,
        end: Alignment.bottomCenter,
        colors: [
          primaryColor,
          Colors.orangeAccent,
          Colors.redAccent,
        ],
      );

      canvas.drawRRect(
        fillRect,
        Paint()
          ..shader = grGradient.createShader(Rect.fromLTWH(meterX, topY, barW, fillH))
          ..style = PaintingStyle.fill,
      );
    }

    // Numeric readout at the bottom
    final grText = isEnabled && effectiveGrDb > 0.1
        ? '-${effectiveGrDb.toStringAsFixed(1)}'
        : '0.0';
    final valTp = TextPainter(
      text: TextSpan(
        text: grText,
        style: TextStyle(
          color: effectiveGrDb > 0.1 ? primaryColor : Colors.white.withValues(alpha: 0.35),
          fontSize: 7.5,
          fontWeight: FontWeight.bold,
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    valTp.paint(canvas, Offset(meterX + (barW - valTp.width) / 2, bottomY + 2));
  }

  void _drawTooltip(Canvas canvas, double w, double h, double freq, double db) {
    final x = _freqToX(freq, w);
    final y = _dbToY(db, h);

    // Indicator dot
    canvas.drawCircle(
      Offset(x, y),
      4.0,
      Paint()..color = primaryColor,
    );
    canvas.drawCircle(
      Offset(x, y),
      6.5,
      Paint()
        ..color = primaryColor.withValues(alpha: 0.35)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.5,
    );

    final text = '${freq >= 1000 ? (freq / 1000).toStringAsFixed(1) : freq.toInt()} Hz\n${db.toStringAsFixed(1)} dB';
    final tp = TextPainter(
      text: TextSpan(
        text: text,
        style: const TextStyle(
          color: Colors.white,
          fontSize: 9.5,
          fontWeight: FontWeight.w600,
          height: 1.2,
        ),
      ),
      textDirection: TextDirection.ltr,
      textAlign: TextAlign.center,
    )..layout();

    final padding = const EdgeInsets.symmetric(horizontal: 6.0, vertical: 3.0);
    final bubbleW = tp.width + padding.horizontal;
    final bubbleH = tp.height + padding.vertical;

    double bubbleX = x - bubbleW / 2;
    if (bubbleX < 4) bubbleX = 4;
    if (bubbleX + bubbleW > w - 4) bubbleX = w - bubbleW - 4;

    double bubbleY = y - bubbleH - 8;
    if (bubbleY < 4) bubbleY = y + 8;

    final bubbleRRect = RRect.fromRectAndRadius(
      Rect.fromLTWH(bubbleX, bubbleY, bubbleW, bubbleH),
      const Radius.circular(5.0),
    );

    canvas.drawRRect(
      bubbleRRect,
      Paint()..color = const Color(0xE6141414),
    );
    canvas.drawRRect(
      bubbleRRect,
      Paint()
        ..color = primaryColor.withValues(alpha: 0.5)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.0,
    );

    tp.paint(canvas, Offset(bubbleX + padding.left, bubbleY + padding.top));
  }

  double _freqToX(double f, double w) {
    final logMin = math.log(_minFreq);
    final logMax = math.log(_maxFreq);
    final t = (math.log(f.clamp(_minFreq, _maxFreq)) - logMin) / (logMax - logMin);
    return t * w;
  }

  double _xToFreq(double x, double w) {
    final t = (x / w).clamp(0.0, 1.0);
    final logMin = math.log(_minFreq);
    final logMax = math.log(_maxFreq);
    return math.exp(logMin + t * (logMax - logMin));
  }

  double _dbToY(double db, double h) {
    final clamped = db.clamp(_minDb, _maxDb);
    final t = (clamped - _minDb) / (_maxDb - _minDb);
    return h * (1.0 - t);
  }

  @override
  bool shouldRepaint(covariant _DeEsserPainter old) {
    return old.mode != mode ||
        old.frequencyHz != frequencyHz ||
        old.thresholdDb != thresholdDb ||
        old.ratio != ratio ||
        old.maxReductionDb != maxReductionDb ||
        (old.gainReductionDb - gainReductionDb).abs() > 0.05 ||
        old.isEnabled != isEnabled ||
        old.primaryColor != primaryColor ||
        old.touchFreq != touchFreq ||
        old.touchDb != touchDb;
  }
}
