import 'dart:math' as math;
import 'package:flutter/material.dart';
import '../services/app_theme_service.dart';

/// An interactive, real-time spline curve and touch-and-drag node controller for Graphic EQ.
///
/// Features:
/// - Smooth Catmull-Rom cubic spline interpolation passing through every band node.
/// - Touch & Drag: Drag individual nodes vertically or swipe horizontally across multiple bands.
/// - Translucent shaded area between curve and 0 dB baseline matching studio EQ displays.
/// - Double-tap any node to snap it back to 0.0 dB.
/// - Long-press any node to open exact numerical input dialog.
/// - Live floating tooltip badge indicating active frequency and gain while dragging.
class GraphicEqGraph extends StatefulWidget {
  final List<double> frequencies;
  final List<double> gains;
  final double preampDb;
  final bool isEnabled;
  final double height;
  final Color? primaryColor;
  final void Function(int index, double gainDb)? onBandChanged;
  final VoidCallback? onBandChangeEnd;
  final void Function(int index)? onBandLongPress;

  const GraphicEqGraph({
    super.key,
    required this.frequencies,
    required this.gains,
    this.preampDb = 0.0,
    this.isEnabled = true,
    this.height = 210.0,
    this.primaryColor,
    this.onBandChanged,
    this.onBandChangeEnd,
    this.onBandLongPress,
  });

  @override
  State<GraphicEqGraph> createState() => _GraphicEqGraphState();
}

class _GraphicEqGraphState extends State<GraphicEqGraph> {
  int? _activeBandIndex;
  double? _activeGainDb;

  static const double minDb = -12.0;
  static const double maxDb = 12.0;

  // Layout padding constants
  static const double paddingLeft = 20.0;
  static const double paddingRight = 38.0; // Space for dB labels on the right
  static const double paddingTop = 22.0;
  static const double paddingBottom = 26.0; // Space for frequency labels

  int _findClosestBand(double localX, double graphWidth, int count) {
    if (count <= 1) return 0;
    final step = graphWidth / (count - 1);
    final relativeX = localX - paddingLeft;
    final index = (relativeX / step).round();
    return index.clamp(0, count - 1);
  }

  double _yToDb(double localY, double graphHeight) {
    final norm = 1.0 - ((localY - paddingTop) / graphHeight).clamp(0.0, 1.0);
    double db = minDb + norm * (maxDb - minDb);
    // Subtle zero-snap within ±0.35 dB for easy centering
    if (db.abs() < 0.35) {
      db = 0.0;
    }
    return db;
  }

  void _handleTouch(Offset localPos, Size size) {
    if (!widget.isEnabled || widget.frequencies.isEmpty) return;

    final graphWidth = size.width - paddingLeft - paddingRight;
    final graphHeight = size.height - paddingTop - paddingBottom;
    if (graphWidth <= 0 || graphHeight <= 0) return;

    final count = math.min(widget.frequencies.length, widget.gains.length);
    final bandIndex = _findClosestBand(localPos.dx, graphWidth, count);
    final gain = _yToDb(localPos.dy, graphHeight);

    setState(() {
      _activeBandIndex = bandIndex;
      _activeGainDb = gain;
    });

    widget.onBandChanged?.call(bandIndex, gain);
  }

  @override
  Widget build(BuildContext context) {
    final effectivePrimary =
        widget.primaryColor ?? AppThemeService.instance.currentData.primary;
    final cardBg = AppThemeService.instance.currentData.cardDark;

    return LayoutBuilder(
      builder: (context, constraints) {
        final totalWidth = constraints.maxWidth;
        final totalHeight = widget.height;
        final size = Size(totalWidth, totalHeight);

        return Container(
          height: totalHeight,
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
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onPanDown: (details) => _handleTouch(details.localPosition, size),
              onPanStart: (details) => _handleTouch(details.localPosition, size),
              onPanUpdate: (details) =>
                  _handleTouch(details.localPosition, size),
              onPanEnd: (_) {
                setState(() {
                  _activeBandIndex = null;
                  _activeGainDb = null;
                });
                widget.onBandChangeEnd?.call();
              },
              onPanCancel: () {
                setState(() {
                  _activeBandIndex = null;
                  _activeGainDb = null;
                });
                widget.onBandChangeEnd?.call();
              },
              onDoubleTapDown: (details) {
                if (!widget.isEnabled || widget.frequencies.isEmpty) return;
                final graphWidth = totalWidth - paddingLeft - paddingRight;
                final count = math.min(
                    widget.frequencies.length, widget.gains.length);
                final bandIndex = _findClosestBand(
                    details.localPosition.dx, graphWidth, count);
                widget.onBandChanged?.call(bandIndex, 0.0);
                widget.onBandChangeEnd?.call();
              },
              onLongPressStart: (details) {
                if (!widget.isEnabled || widget.frequencies.isEmpty) return;
                final graphWidth = totalWidth - paddingLeft - paddingRight;
                final count = math.min(
                    widget.frequencies.length, widget.gains.length);
                final bandIndex = _findClosestBand(
                    details.localPosition.dx, graphWidth, count);
                widget.onBandLongPress?.call(bandIndex);
              },
              child: CustomPaint(
                size: Size.infinite,
                painter: _InteractiveGraphicEqPainter(
                  frequencies: widget.frequencies,
                  gains: widget.gains,
                  preampDb: widget.preampDb,
                  isEnabled: widget.isEnabled,
                  primaryColor: effectivePrimary,
                  activeBandIndex: _activeBandIndex,
                  activeGainDb: _activeGainDb,
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}

class _InteractiveGraphicEqPainter extends CustomPainter {
  final List<double> frequencies;
  final List<double> gains;
  final double preampDb;
  final bool isEnabled;
  final Color primaryColor;
  final int? activeBandIndex;
  final double? activeGainDb;

  _InteractiveGraphicEqPainter({
    required this.frequencies,
    required this.gains,
    required this.preampDb,
    required this.isEnabled,
    required this.primaryColor,
    this.activeBandIndex,
    this.activeGainDb,
  });

  static const double minDb = -12.0;
  static const double maxDb = 12.0;

  static const double paddingLeft = _GraphicEqGraphState.paddingLeft;
  static const double paddingRight = _GraphicEqGraphState.paddingRight;
  static const double paddingTop = _GraphicEqGraphState.paddingTop;
  static const double paddingBottom = _GraphicEqGraphState.paddingBottom;

  @override
  void paint(Canvas canvas, Size size) {
    final graphWidth = size.width - paddingLeft - paddingRight;
    final graphHeight = size.height - paddingTop - paddingBottom;
    if (graphWidth <= 0 || graphHeight <= 0) return;

    // Helper: Map dB to Y canvas coordinate
    double dbToY(double db) {
      final norm = (db.clamp(minDb, maxDb) - minDb) / (maxDb - minDb);
      return paddingTop + (1.0 - norm) * graphHeight;
    }

    final zeroY = dbToY(0.0);

    // 1. Draw Grid Lines and Labels
    _drawGrid(canvas, paddingLeft, paddingTop, graphWidth, graphHeight);

    final bandCount = math.min(frequencies.length, gains.length);
    if (bandCount == 0) return;

    // 2. Compute Node Coordinates (x_i, y_i)
    final points = <Offset>[];
    for (int i = 0; i < bandCount; i++) {
      final x = bandCount == 1
          ? paddingLeft + graphWidth / 2.0
          : paddingLeft + i * (graphWidth / (bandCount - 1));
      final gain = (i == activeBandIndex && activeGainDb != null)
          ? activeGainDb!
          : gains[i];
      final y = dbToY(gain);
      points.add(Offset(x, y));
    }

    // 3. Construct Smooth Catmull-Rom Cubic Spline Path
    final splinePath = _buildCatmullRomSpline(points);

    // 4. Draw Shaded Fill between Spline Curve and 0 dB Baseline
    final fillPath = Path.from(splinePath);
    fillPath.lineTo(points.last.dx, zeroY);
    fillPath.lineTo(points.first.dx, zeroY);
    fillPath.close();

    final fillPaint = Paint()
      ..shader = LinearGradient(
        begin: Alignment.topCenter,
        end: Alignment.bottomCenter,
        colors: [
          primaryColor.withValues(alpha: isEnabled ? 0.38 : 0.12),
          primaryColor.withValues(alpha: isEnabled ? 0.08 : 0.02),
        ],
      ).createShader(
          Rect.fromLTWH(paddingLeft, paddingTop, graphWidth, graphHeight))
      ..style = PaintingStyle.fill;
    canvas.drawPath(fillPath, fillPaint);

    // 5. Draw Glowing Spline Stroke
    final glowPaint = Paint()
      ..color = primaryColor.withValues(alpha: isEnabled ? 0.45 : 0.15)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 5.0
      ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 3.5);
    canvas.drawPath(splinePath, glowPaint);

    final strokePaint = Paint()
      ..color = isEnabled ? primaryColor : Colors.white30
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2.4
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;
    canvas.drawPath(splinePath, strokePaint);

    // 6. Draw Nodes along the curve
    for (int i = 0; i < bandCount; i++) {
      final pt = points[i];
      final isActive = i == activeBandIndex;

      // Outer glow for active node
      if (isActive) {
        canvas.drawCircle(
          pt,
          11.0,
          Paint()..color = primaryColor.withValues(alpha: 0.35),
        );
      }

      // Node border / halo
      canvas.drawCircle(
        pt,
        isActive ? 6.5 : 5.0,
        Paint()
          ..color = isEnabled ? primaryColor : Colors.white38
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2.0,
      );

      // Inner solid dot (white)
      canvas.drawCircle(
        pt,
        isActive ? 4.5 : 3.2,
        Paint()..color = isEnabled ? Colors.white : Colors.white54,
      );
    }

    // 7. Draw Active Floating Tooltip Badge if user is touching/dragging
    if (activeBandIndex != null && activeBandIndex! < bandCount) {
      final activePt = points[activeBandIndex!];
      final f = frequencies[activeBandIndex!];
      final g = (activeGainDb ?? gains[activeBandIndex!]);

      String freqStr = f >= 1000
          ? '${(f / 1000).toStringAsFixed(f % 1000 == 0 ? 0 : 1)}k'
          : '${f.toInt()}';
      final tooltipText = '$freqStr: ${g >= 0 ? '+' : ''}${g.toStringAsFixed(1)} dB';

      final tp = TextPainter(
        text: TextSpan(
          text: tooltipText,
          style: const TextStyle(
            color: Colors.black,
            fontSize: 10.5,
            fontWeight: FontWeight.bold,
            fontFamily: 'monospace',
          ),
        ),
        textDirection: TextDirection.ltr,
      )..layout();

      final badgeWidth = tp.width + 14.0;
      final badgeHeight = tp.height + 6.0;

      // Position badge above node (or below if too close to top)
      double badgeY = activePt.dy - badgeHeight - 12.0;
      if (badgeY < 4.0) {
        badgeY = activePt.dy + 12.0;
      }
      final badgeX =
          (activePt.dx - badgeWidth / 2.0).clamp(4.0, size.width - badgeWidth - 4.0);

      final rrect = RRect.fromRectAndRadius(
        Rect.fromLTWH(badgeX, badgeY, badgeWidth, badgeHeight),
        const Radius.circular(8.0),
      );

      // Badge shadow
      canvas.drawRRect(
        rrect.shift(const Offset(0, 2)),
        Paint()
          ..color = Colors.black.withValues(alpha: 0.4)
          ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 4.0),
      );

      // Badge background (primary color pill)
      canvas.drawRRect(
        rrect,
        Paint()..color = primaryColor,
      );

      tp.paint(canvas, Offset(badgeX + 7.0, badgeY + 3.0));
    }

    // 8. Draw Frequency Labels at the Bottom
    _drawFrequencyLabels(
        canvas, size, points, bandCount, graphWidth, graphHeight);
  }

  void _drawGrid(Canvas canvas, double paddingLeft, double paddingTop,
      double graphWidth, double graphHeight) {
    final gridLinePaint = Paint()
      ..color = Colors.white.withValues(alpha: 0.08)
      ..strokeWidth = 1.0;

    final zeroLinePaint = Paint()
      ..color = Colors.white.withValues(alpha: 0.28)
      ..strokeWidth = 1.2;

    final textStyle = TextStyle(
      color: Colors.white.withValues(alpha: 0.5),
      fontSize: 9.5,
      fontWeight: FontWeight.w500,
      fontFamily: 'monospace',
    );

    // Horizontal dB lines: +12, +6, 0, -6, -12
    final dbSteps = [12.0, 6.0, 0.0, -6.0, -12.0];
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

      // Draw label on the right side matching user screenshot
      tp.paint(canvas, Offset(paddingLeft + graphWidth + 6, y - tp.height / 2));
    }
  }

  void _drawFrequencyLabels(Canvas canvas, Size size, List<Offset> points,
      int bandCount, double graphWidth, double graphHeight) {
    if (bandCount == 0) return;

    // 1. Dynamically determine label decimation step based on band count & width
    int step = 1;
    if (bandCount > 16) {
      // 32 bands: show every 4th band on mobile (~8-9 labels), every 2nd on wide displays
      step = graphWidth < 600 ? 4 : 2;
    } else if (bandCount > 10) {
      // 16 bands: show every 2nd band on mobile (~8 labels), every 1st on wide displays
      step = graphWidth < 500 ? 2 : 1;
    } else {
      // 10 bands: show all bands unless screen is extremely narrow
      step = graphWidth < 260 ? 2 : 1;
    }

    // 2. Build candidate indices ensuring first and last boundaries are represented
    final candidateIndices = <int>[];
    for (int i = 0; i < bandCount; i += step) {
      candidateIndices.add(i);
    }
    if (bandCount > 1 && !candidateIndices.contains(bandCount - 1)) {
      final lastIdx = bandCount - 1;
      final prevIdx = candidateIndices.last;
      if (lastIdx - prevIdx <= 1) {
        // If last band is only 1 band away from the previous candidate, substitute it
        candidateIndices[candidateIndices.length - 1] = lastIdx;
      } else {
        candidateIndices.add(lastIdx);
      }
    }

    final candidateSet = candidateIndices.toSet();
    final yAxis = paddingTop + graphHeight;

    // 3. Draw subtle hardware-style ticks along the baseline for every band
    final majorTickPaint = Paint()
      ..color = Colors.white.withValues(alpha: 0.28)
      ..strokeWidth = 1.0;
    final minorTickPaint = Paint()
      ..color = Colors.white.withValues(alpha: 0.10)
      ..strokeWidth = 1.0;

    for (int i = 0; i < bandCount; i++) {
      final x = points[i].dx;
      if (candidateSet.contains(i)) {
        canvas.drawLine(
            Offset(x, yAxis), Offset(x, yAxis + 3.0), majorTickPaint);
      } else {
        canvas.drawLine(
            Offset(x, yAxis), Offset(x, yAxis + 1.5), minorTickPaint);
      }
    }

    // 4. Helper for clean frequency formatting
    String formatFreq(double f) {
      if (f >= 1000) {
        final khz = f / 1000;
        return khz % 1 == 0
            ? '${khz.toInt()}k'
            : '${khz.toStringAsFixed(khz >= 10 ? 0 : 1)}k';
      } else {
        return f % 1 == 0 ? '${f.toInt()}' : f.toStringAsFixed(1);
      }
    }

    // 5. Paint labels with collision guard and active band highlighting
    double lastRightEdge = -double.infinity;
    final yText = yAxis + 5.5;

    for (final i in candidateIndices) {
      final f = frequencies[i];
      final label = formatFreq(f);
      final isActive = i == activeBandIndex;

      final tp = TextPainter(
        text: TextSpan(
          text: label,
          style: TextStyle(
            color: isActive
                ? primaryColor
                : Colors.white.withValues(alpha: isEnabled ? 0.6 : 0.25),
            fontSize: 9.0,
            fontWeight: isActive ? FontWeight.bold : FontWeight.w500,
            fontFamily: 'monospace',
          ),
        ),
        textDirection: TextDirection.ltr,
      )..layout();

      final x = points[i].dx - tp.width / 2.0;
      final clampedX = x.clamp(2.0, size.width - tp.width - 2.0);

      // Overlap protection: ensure at least 6px clearance
      if (clampedX < lastRightEdge + 6.0) {
        continue;
      }

      tp.paint(canvas, Offset(clampedX, yText));
      lastRightEdge = clampedX + tp.width;
    }
  }

  // Constructs a smooth Catmull-Rom cubic spline connecting points
  Path _buildCatmullRomSpline(List<Offset> pts) {
    final path = Path();
    if (pts.isEmpty) return path;
    if (pts.length == 1) {
      path.moveTo(pts[0].dx, pts[0].dy);
      return path;
    }

    path.moveTo(pts[0].dx, pts[0].dy);

    if (pts.length == 2) {
      path.lineTo(pts[1].dx, pts[1].dy);
      return path;
    }

    for (int i = 0; i < pts.length - 1; i++) {
      final p0 = i > 0 ? pts[i - 1] : pts[i];
      final p1 = pts[i];
      final p2 = pts[i + 1];
      final p3 = (i < pts.length - 2) ? pts[i + 2] : p2;

      // Catmull-Rom to Cubic Bezier control points
      final c1x = p1.dx + (p2.dx - p0.dx) / 6.0;
      final c1y = p1.dy + (p2.dy - p0.dy) / 6.0;
      final c2x = p2.dx - (p3.dx - p1.dx) / 6.0;
      final c2y = p2.dy - (p3.dy - p1.dy) / 6.0;

      path.cubicTo(c1x, c1y, c2x, c2y, p2.dx, p2.dy);
    }

    return path;
  }

  @override
  bool shouldRepaint(covariant _InteractiveGraphicEqPainter oldDelegate) {
    return oldDelegate.frequencies != frequencies ||
        oldDelegate.gains != gains ||
        oldDelegate.preampDb != preampDb ||
        oldDelegate.isEnabled != isEnabled ||
        oldDelegate.primaryColor != primaryColor ||
        oldDelegate.activeBandIndex != activeBandIndex ||
        oldDelegate.activeGainDb != activeGainDb;
  }
}
