import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

/// Supported visual themes for the fluid area spectrum visualizer.
enum FluidAreaTheme {
  neon('Neon Wave', Icons.auto_awesome_rounded),
  fire('Fire Glow', Icons.local_fire_department_rounded),
  aurora('Aurora Borealis', Icons.waves_rounded),
  ocean('Ocean Deep', Icons.water_rounded),
  minimal('Minimal', Icons.horizontal_rule_rounded);

  final String displayName;
  final IconData icon;
  const FluidAreaTheme(this.displayName, this.icon);

  static FluidAreaTheme fromString(String? val) {
    if (val == null) return FluidAreaTheme.minimal;
    final lower = val.toLowerCase().trim();
    for (final theme in FluidAreaTheme.values) {
      if (theme.name == lower || theme.displayName.toLowerCase() == lower) {
        return theme;
      }
    }
    return FluidAreaTheme.minimal;
  }
}

/// Internal state tracking physics metrics for an individual frequency point.
class _AreaPointPhysicsState {
  double target = 0.0;
  double level = 0.0;
  double velocity = 0.0;
  double peak = 0.0;
  double peakVelocity = 0.0;
  double peakHoldTimer = 0.0;
}

/// A high-performance, 60/120 FPS custom-painted audio spectrum visualizer
/// rendering an organic, liquid-smooth fluid wave area curve with physical
/// surface tension, luminous neon crest lines, and a floating peak retention drape.
class FluidAreaVisualizer extends StatefulWidget {
  /// Latest normalized frequency amplitudes (0.0 to 1.0).
  final List<double> values;

  /// Primary color used for base accents and theming.
  final Color primaryColor;

  /// Height of the visualizer graph area.
  final double height;

  /// Spectrum visual theme: 'neon', 'fire', 'aurora', 'ocean', 'minimal'.
  final String themeName;

  /// Whether to display logarithmic reference grid lines.
  final bool showGrids;

  /// Whether values represent logarithmic scale or linear.
  final bool logScale;

  /// Whether to apply dynamic auto-headroom scaling.
  final bool autoFit;

  /// Highest audible frequency in Hz (typically sampleRate / 2, capped at 24000).
  final int maxFreq;

  /// Optional callback invoked when the user taps the visualizer to cycle themes.
  final ValueChanged<String>? onThemeChanged;

  const FluidAreaVisualizer({
    super.key,
    required this.values,
    required this.primaryColor,
    this.height = 160.0,
    this.themeName = 'minimal',
    this.showGrids = true,
    this.logScale = true,
    this.autoFit = false,
    this.maxFreq = 24000,
    this.onThemeChanged,
  });

  @override
  State<FluidAreaVisualizer> createState() => _FluidAreaVisualizerState();
}

class _FluidAreaVisualizerState extends State<FluidAreaVisualizer>
    with SingleTickerProviderStateMixin {
  static const int _numPoints = 52;

  // Physics tuning constants for liquid/spring simulation
  static const double _gravityWave = 3.8; // Gravity pulling the wave surface down
  static const double _gravityPeak = 2.2; // Gravity pulling the floating peak drape down
  static const double _peakHoldDuration = 0.18; // 180ms apex hold time
  static const double _surfaceTension = 0.08; // Cross-band coupling for fluid ripple

  late final List<_AreaPointPhysicsState> _points;
  late final Ticker _ticker;
  DateTime? _lastTickTime;
  late FluidAreaTheme _activeTheme;

  @override
  void initState() {
    super.initState();
    _activeTheme = FluidAreaTheme.fromString(widget.themeName);
    _points = List.generate(_numPoints, (_) => _AreaPointPhysicsState());
    _syncTargetAmplitudes();

    _ticker = createTicker(_onTick);
    _ticker.start();
  }

  @override
  void didUpdateWidget(covariant FluidAreaVisualizer oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.themeName != widget.themeName) {
      _activeTheme = FluidAreaTheme.fromString(widget.themeName);
    }
    _syncTargetAmplitudes();

    if (!_ticker.isActive && widget.values.isNotEmpty) {
      _lastTickTime = DateTime.now();
      _ticker.start();
    }
  }

  @override
  void dispose() {
    _ticker.dispose();
    super.dispose();
  }

  void _syncTargetAmplitudes() {
    if (widget.values.isEmpty) {
      for (final pt in _points) {
        pt.target = 0.0;
      }
      return;
    }

    final inputLen = widget.values.length;
    final step = inputLen / _numPoints;

    double maxSample = 0.0;
    if (widget.autoFit) {
      for (final val in widget.values) {
        if (val > maxSample) maxSample = val;
      }
    }
    final scaleFactor = (widget.autoFit && maxSample > 0.05)
        ? (1.0 / (maxSample * 1.15)).clamp(1.0, 4.0)
        : 1.0;

    for (int i = 0; i < _numPoints; i++) {
      final sampleIdx = (i * step).floor().clamp(0, inputLen - 1);
      double val = widget.values[sampleIdx] * scaleFactor;
      if (!widget.logScale) {
        val = val * val;
      }
      _points[i].target = val.clamp(0.0, 1.0);
    }
  }

  void _onTick(Duration elapsed) {
    final now = DateTime.now();
    if (_lastTickTime == null) {
      _lastTickTime = now;
      return;
    }

    final dt = (now.difference(_lastTickTime!).inMicroseconds / 1000000.0)
        .clamp(0.001, 0.05);
    _lastTickTime = now;

    bool hasActivity = false;

    // 1. Primary physics integration (Attack, Gravity, Peak Drape)
    for (int i = 0; i < _numPoints; i++) {
      final pt = _points[i];
      final target = pt.target;

      // Transient attack vs gravitational falloff
      if (target > pt.level) {
        // Fast responsive fluid attack
        pt.level = target;
        pt.velocity = 0.0;
      } else {
        // Accelerated gravity falloff with momentum damping
        pt.velocity += _gravityWave * dt;
        pt.level -= pt.velocity * dt;
        if (pt.level < target) {
          pt.level = target;
          pt.velocity = 0.0;
        }
      }

      // Peak drape physics
      if (pt.level >= pt.peak) {
        pt.peak = pt.level;
        pt.peakVelocity = 0.0;
        pt.peakHoldTimer = _peakHoldDuration;
      } else {
        if (pt.peakHoldTimer > 0) {
          pt.peakHoldTimer -= dt;
        } else {
          pt.peakVelocity += _gravityPeak * dt;
          pt.peak -= pt.peakVelocity * dt;
          if (pt.peak < pt.level) {
            pt.peak = pt.level;
            pt.peakVelocity = 0.0;
          }
        }
      }

      pt.level = pt.level.clamp(0.0, 1.0);
      pt.peak = pt.peak.clamp(0.0, 1.0);

      if (pt.level > 0.001 || pt.peak > 0.001 || target > 0.001) {
        hasActivity = true;
      }
    }

    // 2. Surface tension pass: smooth dispersion between adjacent frequency neighbors
    for (int i = 1; i < _numPoints - 1; i++) {
      final prev = _points[i - 1].level;
      final next = _points[i + 1].level;
      final avg = (prev + next) * 0.5;
      _points[i].level = _points[i].level * (1.0 - _surfaceTension) + avg * _surfaceTension;
    }

    if (mounted) {
      setState(() {});
    }

    // Sleep when completely idle
    if (!hasActivity && widget.values.isEmpty) {
      _ticker.stop();
      _lastTickTime = null;
    }
  }

  void _cycleTheme() {
    final values = FluidAreaTheme.values;
    final nextIndex = (_activeTheme.index + 1) % values.length;
    final nextTheme = values[nextIndex];
    setState(() {
      _activeTheme = nextTheme;
    });
    widget.onThemeChanged?.call(nextTheme.name);
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: _cycleTheme,
      behavior: HitTestBehavior.opaque,
      child: CustomPaint(
        size: Size(double.infinity, widget.height),
        painter: _FluidAreaPainter(
          points: _points,
          primaryColor: widget.primaryColor,
          theme: _activeTheme,
          showGrids: widget.showGrids,
          logScale: widget.logScale,
          maxFreq: widget.maxFreq,
        ),
      ),
    );
  }
}

/// Custom painter rendering the fluid spline wave, glassmorphic fill, neon crest, and peak drape.
class _FluidAreaPainter extends CustomPainter {
  final List<_AreaPointPhysicsState> points;
  final Color primaryColor;
  final FluidAreaTheme theme;
  final bool showGrids;
  final bool logScale;
  final int maxFreq;

  _FluidAreaPainter({
    required this.points,
    required this.primaryColor,
    required this.theme,
    required this.showGrids,
    required this.logScale,
    required this.maxFreq,
  });

  static const double _paddingLeft = 28.0;
  static const double _paddingRight = 6.0;
  static const double _paddingTop = 8.0;
  static const double _paddingBottom = 22.0;

  @override
  void paint(Canvas canvas, Size size) {
    final graphWidth = size.width - _paddingLeft - _paddingRight;
    final graphHeight = size.height - _paddingTop - _paddingBottom;
    if (graphWidth <= 0 || graphHeight <= 0) return;

    final n = points.length;
    if (n < 2) return;

    // 1. Draw Grid Lines & Axis Markings
    _drawAxesAndGrids(
      canvas,
      _paddingLeft,
      _paddingTop,
      graphWidth,
      graphHeight,
    );

    // 2. Compute Screen Coordinates for Main Fluid Wave and Peak Drape
    final waveCoords = <Offset>[];
    final peakCoords = <Offset>[];

    final stepX = graphWidth / (n - 1);
    for (int i = 0; i < n; i++) {
      final x = _paddingLeft + (i * stepX);
      final yWave = _paddingTop + graphHeight * (1.0 - points[i].level);
      final yPeak = _paddingTop + graphHeight * (1.0 - points[i].peak);

      waveCoords.add(Offset(x, yWave));
      peakCoords.add(Offset(x, yPeak));
    }

    // 3. Construct Smooth Spline Paths
    final waveSplinePath = _buildCatmullRomSpline(waveCoords);
    final peakSplinePath = _buildCatmullRomSpline(peakCoords);

    // 4. Construct Closed Area Path for Glassmorphic Gradient Fill
    final areaPath = Path.from(waveSplinePath)
      ..lineTo(_paddingLeft + graphWidth, _paddingTop + graphHeight)
      ..lineTo(_paddingLeft, _paddingTop + graphHeight)
      ..close();

    // 5. Draw Layer 1: Ambient Background Glow Fill
    final colors = _getThemeGradients();
    final fillRect = Rect.fromLTWH(
      _paddingLeft,
      _paddingTop,
      graphWidth,
      graphHeight,
    );

    final bgGlowPaint = Paint()
      ..style = PaintingStyle.fill
      ..shader = LinearGradient(
        colors: [
          colors.crest.withValues(alpha: 0.28),
          colors.mid.withValues(alpha: 0.12),
          colors.bottom.withValues(alpha: 0.0),
        ],
        stops: const [0.0, 0.45, 1.0],
        begin: Alignment.topCenter,
        end: Alignment.bottomCenter,
      ).createShader(fillRect);
    canvas.drawPath(areaPath, bgGlowPaint);

    // 6. Draw Layer 2: Core Glassmorphic Area Fill
    final coreFillPaint = Paint()
      ..style = PaintingStyle.fill
      ..shader = LinearGradient(
        colors: [
          colors.crest.withValues(alpha: 0.45),
          colors.mid.withValues(alpha: 0.20),
          colors.bottom.withValues(alpha: 0.02),
        ],
        stops: const [0.0, 0.50, 1.0],
        begin: Alignment.topCenter,
        end: Alignment.bottomCenter,
      ).createShader(fillRect);
    canvas.drawPath(areaPath, coreFillPaint);

    // 7. Draw Layer 3: Floating Peak Retention Drape Contour
    final peakDrapePaint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.2
      ..color = colors.peakDrape.withValues(alpha: 0.55);
    canvas.drawPath(peakSplinePath, peakDrapePaint);

    // Highlight resonant peak pips on crest peaks
    final pipPaint = Paint()
      ..style = PaintingStyle.fill
      ..color = colors.peakDrape;
    for (int i = 2; i < n - 2; i += 3) {
      if (points[i].peak > 0.08) {
        canvas.drawCircle(peakCoords[i], 1.8, pipPaint);
      }
    }

    // 8. Draw Layer 4: Neon Crest Bloom Glow Pass
    final glowCrestPaint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 4.5
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round
      ..color = colors.crest.withValues(alpha: 0.45)
      ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 2.5);
    canvas.drawPath(waveSplinePath, glowCrestPaint);

    // 9. Draw Layer 5: Sharp High-Definition Fluid Surface Crest Line
    final sharpCrestPaint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2.2
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round
      ..shader = LinearGradient(
        colors: [
          colors.crestStart,
          colors.crest,
          colors.crestEnd,
        ],
        stops: const [0.0, 0.5, 1.0],
      ).createShader(fillRect);
    canvas.drawPath(waveSplinePath, sharpCrestPaint);
  }

  /// Builds a smooth Catmull-Rom spline path through discrete points.
  Path _buildCatmullRomSpline(List<Offset> pts) {
    final path = Path();
    if (pts.isEmpty) return path;
    if (pts.length < 3) {
      path.moveTo(pts.first.dx, pts.first.dy);
      for (int i = 1; i < pts.length; i++) {
        path.lineTo(pts[i].dx, pts[i].dy);
      }
      return path;
    }

    path.moveTo(pts[0].dx, pts[0].dy);

    for (int i = 0; i < pts.length - 1; i++) {
      final p0 = i > 0 ? pts[i - 1] : pts[i];
      final p1 = pts[i];
      final p2 = pts[i + 1];
      final p3 = (i < pts.length - 2) ? pts[i + 2] : p2;

      // Catmull-Rom to Cubic Bezier control points
      final cp1x = p1.dx + (p2.dx - p0.dx) / 6.0;
      final cp1y = p1.dy + (p2.dy - p0.dy) / 6.0;
      final cp2x = p2.dx - (p3.dx - p1.dx) / 6.0;
      final cp2y = p2.dy - (p3.dy - p1.dy) / 6.0;

      path.cubicTo(cp1x, cp1y, cp2x, cp2y, p2.dx, p2.dy);
    }

    return path;
  }

  _ThemeColors _getThemeGradients() {
    switch (theme) {
      case FluidAreaTheme.neon:
        return const _ThemeColors(
          crestStart: Color(0xFF00E5FF), // Electric Cyan
          crest: Color(0xFF7C4DFF), // Vivid Purple
          crestEnd: Color(0xFFFF1744), // Hot Neon Pink
          mid: Color(0xFF3D5AFE),
          bottom: Color(0xFF0D47A1),
          peakDrape: Color(0xFFE0F7FA),
        );

      case FluidAreaTheme.fire:
        return const _ThemeColors(
          crestStart: Color(0xFFD50000), // Crimson
          crest: Color(0xFFFF6D00), // Fiery Orange
          crestEnd: Color(0xFFFFD600), // Golden Amber
          mid: Color(0xFFFF3D00),
          bottom: Color(0xFF3E2723),
          peakDrape: Color(0xFFFFFF8D),
        );

      case FluidAreaTheme.aurora:
        return const _ThemeColors(
          crestStart: Color(0xFF00E676), // Arctic Mint
          crest: Color(0xFF1DE9B6), // Teal
          crestEnd: Color(0xFF651FFF), // Aurora Violet
          mid: Color(0xFF00B0FF),
          bottom: Color(0xFF004D40),
          peakDrape: Color(0xFFB9F6CA),
        );

      case FluidAreaTheme.ocean:
        return const _ThemeColors(
          crestStart: Color(0xFF2979FF), // Azure
          crest: Color(0xFF00E5FF), // Aqua
          crestEnd: Color(0xFF18FFFF), // Bright Cyan
          mid: Color(0xFF0288D1),
          bottom: Color(0xFF01579B),
          peakDrape: Color(0xFFE1F5FE),
        );

      case FluidAreaTheme.minimal:
        return _ThemeColors(
          crestStart: primaryColor.withValues(alpha: 0.7),
          crest: primaryColor,
          crestEnd: Colors.white,
          mid: primaryColor.withValues(alpha: 0.4),
          bottom: primaryColor.withValues(alpha: 0.05),
          peakDrape: Colors.white70,
        );
    }
  }

  void _drawAxesAndGrids(
    Canvas canvas,
    double x0,
    double y0,
    double w,
    double h,
  ) {
    final gridLinePaint = Paint()
      ..color = Colors.white.withValues(alpha: 0.08)
      ..strokeWidth = 1.0;

    final axisBorderPaint = Paint()
      ..color = Colors.white.withValues(alpha: 0.20)
      ..strokeWidth = 1.0;

    const labelStyle = TextStyle(
      color: Colors.white54,
      fontSize: 8.5,
      fontWeight: FontWeight.w400,
    );

    // Left dB / % Axis Labels & Horizontal Grid Lines
    final levels = [0.25, 0.50, 0.75, 1.0];
    for (final level in levels) {
      final y = y0 + h * (1.0 - level);

      if (showGrids) {
        canvas.drawLine(Offset(x0, y), Offset(x0 + w, y), gridLinePaint);
      }

      final label = '${(level * 100).toInt()}%';
      final tp = TextPainter(
        text: TextSpan(text: label, style: labelStyle),
        textAlign: TextAlign.right,
        textDirection: TextDirection.ltr,
      )..layout();

      tp.paint(canvas, Offset(x0 - tp.width - 5, y - (tp.height / 2)));
    }

    // Left & Bottom Axis Lines
    canvas.drawLine(Offset(x0, y0), Offset(x0, y0 + h), axisBorderPaint);
    canvas.drawLine(Offset(x0, y0 + h), Offset(x0 + w, y0 + h), axisBorderPaint);

    // Bottom Frequency Labels (20, 100, 500, 1k, 5k, 10k, 20k)
    final freqTicks = [
      {'f': 20.0, 'l': '20'},
      {'f': 100.0, 'l': '100'},
      {'f': 500.0, 'l': '500'},
      {'f': 1000.0, 'l': '1k'},
      {'f': 5000.0, 'l': '5k'},
      {'f': 10000.0, 'l': '10k'},
      {'f': 20000.0, 'l': '20k'},
    ];

    const double minFreq = 20.0;
    final double effectiveMaxFreq = math.min(24000.0, maxFreq.toDouble());

    for (final tick in freqTicks) {
      final f = tick['f'] as double;
      if (f > effectiveMaxFreq) continue;
      final label = tick['l'] as String;

      final logRatio = math.log(f / minFreq) / math.log(effectiveMaxFreq / minFreq);
      final x = x0 + (logRatio * w).clamp(0.0, w);

      if (showGrids) {
        canvas.drawLine(Offset(x, y0), Offset(x, y0 + h), gridLinePaint);
      }

      final tp = TextPainter(
        text: TextSpan(text: label, style: labelStyle),
        textDirection: TextDirection.ltr,
      )..layout();

      tp.paint(canvas, Offset(x - (tp.width / 2), y0 + h + 5));
    }
  }

  @override
  bool shouldRepaint(covariant _FluidAreaPainter oldDelegate) {
    return true;
  }
}

class _ThemeColors {
  final Color crestStart;
  final Color crest;
  final Color crestEnd;
  final Color mid;
  final Color bottom;
  final Color peakDrape;

  const _ThemeColors({
    required this.crestStart,
    required this.crest,
    required this.crestEnd,
    required this.mid,
    required this.bottom,
    required this.peakDrape,
  });
}
