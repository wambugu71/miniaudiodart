import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

/// Supported visual themes for the fine dots spectrum visualizer.
enum PhysicsDotsTheme {
  neon('Neon', Icons.auto_awesome_rounded),
  fire('Fire', Icons.local_fire_department_rounded),
  matrix('Studio LED', Icons.equalizer_rounded),
  pill('Pill Capsules', Icons.lens_blur_rounded),
  minimal('Minimal', Icons.horizontal_rule_rounded);

  final String displayName;
  final IconData icon;
  const PhysicsDotsTheme(this.displayName, this.icon);

  static PhysicsDotsTheme fromString(String? val) {
    if (val == null) return PhysicsDotsTheme.minimal;
    final lower = val.toLowerCase().trim();
    for (final theme in PhysicsDotsTheme.values) {
      if (theme.name == lower || theme.displayName.toLowerCase() == lower) {
        return theme;
      }
    }
    return PhysicsDotsTheme.minimal;
  }
}

/// Internal state tracking physics metrics for an individual frequency band.
class _BandPhysicsState {
  double target = 0.0;
  double level = 0.0;
  double velocity = 0.0;
  double peak = 0.0;
  double peakVelocity = 0.0;
  double peakHoldTimer = 0.0;
}

/// A high-performance, custom-painted audio spectrum visualizer where frequency
/// bars are rendered as fine segmented dots/micro-blocks (like ▓▓▓▓▓▓▓▓▓▓▓),
/// adhering to realistic physical laws of motion:
///
/// - **Attack / Bump**: Transients bump the bar upward instantaneously.
/// - **Bar Decay**: Natural falloff under gravitational acceleration and momentum damping.
/// - **Apex Peak Hold**: The peak dot hovers momentarily at the crest before accelerating
///   downward under gravity until the next audio transient catches it.
/// - **Ghost Matrix Grid**: Displays faint unlit dot positions for an authentic studio rack
///   hardware (LED / VFD) aesthetic.
class PhysicsDotsVisualizer extends StatefulWidget {
  /// Latest normalized frequency amplitudes (0.0 to 1.0).
  final List<double> values;

  /// Primary color used for base accents and theming.
  final Color primaryColor;

  /// Height of the visualizer graph area.
  final double height;

  /// Spectrum visual theme: 'neon', 'fire', 'matrix', 'pill', 'minimal'.
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

  const PhysicsDotsVisualizer({
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
  State<PhysicsDotsVisualizer> createState() => _PhysicsDotsVisualizerState();
}

class _PhysicsDotsVisualizerState extends State<PhysicsDotsVisualizer>
    with SingleTickerProviderStateMixin {
  static const int _numBands = 50;
  static const int _numDotsPerColumn = 28;

  // Physics tuning constants
  static const double _gravityBar = 4.2; // Gravity pulling the bar down
  static const double _gravityPeak = 2.5; // Gravity pulling the peak dot down
  static const double _peakHoldDuration = 0.16; // 160ms apex hold time

  late final List<_BandPhysicsState> _bands;
  late final Ticker _ticker;
  DateTime? _lastTickTime;
  late PhysicsDotsTheme _activeTheme;

  @override
  void initState() {
    super.initState();
    _activeTheme = PhysicsDotsTheme.fromString(widget.themeName);
    _bands = List.generate(_numBands, (_) => _BandPhysicsState());
    _syncTargetAmplitudes();

    _ticker = createTicker(_onTick);
    _ticker.start();
  }

  @override
  void didUpdateWidget(covariant PhysicsDotsVisualizer oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.themeName != widget.themeName) {
      _activeTheme = PhysicsDotsTheme.fromString(widget.themeName);
    }
    _syncTargetAmplitudes();

    // Ensure ticker is running if new non-empty values arrive
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
      for (final band in _bands) {
        band.target = 0.0;
      }
      return;
    }

    final inputLen = widget.values.length;
    final step = inputLen / _numBands;

    // Headroom calculation if autoFit is active
    double maxSample = 0.0;
    if (widget.autoFit) {
      for (final val in widget.values) {
        if (val > maxSample) maxSample = val;
      }
    }
    final scaleFactor = (widget.autoFit && maxSample > 0.05)
        ? (1.0 / (maxSample * 1.15)).clamp(1.0, 4.0)
        : 1.0;

    for (int i = 0; i < _numBands; i++) {
      final sampleIdx = (i * step).floor().clamp(0, inputLen - 1);
      final double val = widget.values[sampleIdx] * scaleFactor;
      _bands[i].target = val.clamp(0.0, 1.0);
    }
  }

  void _onTick(Duration elapsed) {
    final now = DateTime.now();
    if (_lastTickTime == null) {
      _lastTickTime = now;
      return;
    }

    // Clamp delta time to avoid jumps after app backgrounding
    final dt = (now.difference(_lastTickTime!).inMicroseconds / 1000000.0)
        .clamp(0.001, 0.05);
    _lastTickTime = now;

    bool hasActivity = false;

    for (int i = 0; i < _numBands; i++) {
      final band = _bands[i];
      final target = band.target;

      // 1. BAR PHYSICS
      if (target > band.level) {
        // Immediate punchy transient attack
        band.level = target;
        band.velocity = 0.0;
      } else {
        // Natural gravitational falloff with velocity acceleration
        band.velocity += _gravityBar * dt;
        band.level -= band.velocity * dt;
        if (band.level < target) {
          band.level = target;
          band.velocity = 0.0;
        }
      }

      // 2. PEAK DOT PHYSICS
      if (band.level >= band.peak) {
        // Bar bumps peak dot upward!
        band.peak = band.level;
        band.peakVelocity = 0.0;
        band.peakHoldTimer = _peakHoldDuration;
      } else {
        if (band.peakHoldTimer > 0) {
          // Hover at apex
          band.peakHoldTimer -= dt;
        } else {
          // Gravity accelerates the peak downward
          band.peakVelocity += _gravityPeak * dt;
          band.peak -= band.peakVelocity * dt;
          if (band.peak < band.level) {
            band.peak = band.level;
            band.peakVelocity = 0.0;
          }
        }
      }

      // Clamp limits
      band.level = band.level.clamp(0.0, 1.0);
      band.peak = band.peak.clamp(0.0, 1.0);

      if (band.level > 0.001 || band.peak > 0.001 || target > 0.001) {
        hasActivity = true;
      }
    }

    // Repaint frame
    if (mounted) {
      setState(() {});
    }

    // Battery optimization: if all bands are completely silent, pause ticker
    if (!hasActivity && widget.values.isEmpty) {
      _ticker.stop();
      _lastTickTime = null;
    }
  }

  void _cycleTheme() {
    final values = PhysicsDotsTheme.values;
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
        painter: _PhysicsDotsPainter(
          bands: _bands,
          primaryColor: widget.primaryColor,
          theme: _activeTheme,
          showGrids: widget.showGrids,
          logScale: widget.logScale,
          maxFreq: widget.maxFreq,
          numDotsPerColumn: _numDotsPerColumn,
        ),
      ),
    );
  }
}

/// Custom painter rendering the fine dot-matrix grid and gravity peak dots.
class _PhysicsDotsPainter extends CustomPainter {
  final List<_BandPhysicsState> bands;
  final Color primaryColor;
  final PhysicsDotsTheme theme;
  final bool showGrids;
  final bool logScale;
  final int maxFreq;
  final int numDotsPerColumn;

  _PhysicsDotsPainter({
    required this.bands,
    required this.primaryColor,
    required this.theme,
    required this.showGrids,
    required this.logScale,
    required this.maxFreq,
    required this.numDotsPerColumn,
  });

  // Layout bounds
  static const double _paddingLeft = 28.0; // Reserved for dB / % axis labels
  static const double _paddingRight = 6.0;
  static const double _paddingTop = 6.0; // Headroom for apex peak dots
  static const double _paddingBottom = 22.0; // Reserved for Hz axis labels

  @override
  void paint(Canvas canvas, Size size) {
    final gridWidth = size.width - _paddingLeft - _paddingRight;
    final gridHeight = size.height - _paddingTop - _paddingBottom;
    if (gridWidth <= 0 || gridHeight <= 0) return;

    final numBands = bands.length;
    final bandSlotWidth = gridWidth / numBands;
    final dotWidth = math.max(2.4, bandSlotWidth - 1.8);
    final dotSlotHeight = gridHeight / numDotsPerColumn;
    final dotHeight = math.max(1.8, dotSlotHeight - 1.3);
    final dotRadius = theme == PhysicsDotsTheme.pill
        ? Radius.circular(dotHeight / 2)
        : const Radius.circular(1.1);

    // 1. Draw Grid Lines & Axis Markings
    _drawAxesAndGrids(
      canvas,
      _paddingLeft,
      _paddingTop,
      gridWidth,
      gridHeight,
    );

    // 2. Draw Fine Dot-Matrix Bars & Physics Peak Dots
    final bgDotPaint = Paint()
      ..style = PaintingStyle.fill
      ..color = Colors.white.withValues(alpha: 0.06);

    final litDotPaint = Paint()..style = PaintingStyle.fill;
    final peakDotPaint = Paint()..style = PaintingStyle.fill;
    final peakGlowPaint = Paint()
      ..style = PaintingStyle.fill
      ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 2.5);

    for (int b = 0; b < numBands; b++) {
      final band = bands[b];
      final colLeft = _paddingLeft + (b * bandSlotWidth) + ((bandSlotWidth - dotWidth) / 2);
      final currentLevel = band.level;
      final peakLevel = band.peak;

      final int activeDotCount = (currentLevel * numDotsPerColumn).round().clamp(0, numDotsPerColumn);
      final int peakDotIndex = ((peakLevel * numDotsPerColumn) - 0.5)
          .round()
          .clamp(0, numDotsPerColumn - 1);

      // Render vertical stack of dots from bottom (d = 0) to top (d = numDots - 1)
      for (int d = 0; d < numDotsPerColumn; d++) {
        final dotTop = _paddingTop + gridHeight - ((d + 1) * dotSlotHeight) + ((dotSlotHeight - dotHeight) / 2);
        final dotRect = RRect.fromRectAndRadius(
          Rect.fromLTWH(colLeft, dotTop, dotWidth, dotHeight),
          dotRadius,
        );

        final normHeight = (d + 0.5) / numDotsPerColumn;

        if (d < activeDotCount) {
          // LIT DOT: Render vibrant thematic color
          final dotColor = _getDotColor(normHeight);
          litDotPaint.color = dotColor;
          canvas.drawRRect(dotRect, litDotPaint);
        } else {
          // UNLIT GHOST DOT: Displays matrix hardware grid
          canvas.drawRRect(dotRect, bgDotPaint);
        }

        // PEAK DOT: Floating apex indicator
        if (d == peakDotIndex && peakLevel > 0.02) {
          final peakColor = _getPeakColor(normHeight);

          // Subtle bloom glow halo
          peakGlowPaint.color = peakColor.withValues(alpha: 0.45);
          final glowRect = RRect.fromRectAndRadius(
            Rect.fromLTWH(colLeft - 0.5, dotTop - 0.5, dotWidth + 1.0, dotHeight + 1.0),
            dotRadius,
          );
          canvas.drawRRect(glowRect, peakGlowPaint);

          // Core brilliant peak dot
          peakDotPaint.color = peakColor;
          canvas.drawRRect(dotRect, peakDotPaint);
        }
      }
    }
  }

  /// Evaluates the thematic dot color at [normHeight] (0.0 bottom to 1.0 top).
  Color _getDotColor(double normHeight) {
    switch (theme) {
      case PhysicsDotsTheme.neon:
        // Electric Cyan -> Vivid Purple -> Hot Neon Pink
        if (normHeight < 0.45) {
          final t = normHeight / 0.45;
          return Color.lerp(const Color(0xFF00E5FF), const Color(0xFF7C4DFF), t)!;
        } else {
          final t = (normHeight - 0.45) / 0.55;
          return Color.lerp(const Color(0xFF7C4DFF), const Color(0xFFFF1744), t)!;
        }

      case PhysicsDotsTheme.fire:
        // Deep Crimson -> Blazing Orange -> Hot Amber / Yellow
        if (normHeight < 0.45) {
          final t = normHeight / 0.45;
          return Color.lerp(const Color(0xFFD50000), const Color(0xFFFF6D00), t)!;
        } else {
          final t = (normHeight - 0.45) / 0.55;
          return Color.lerp(const Color(0xFFFF6D00), const Color(0xFFFFD600), t)!;
        }

      case PhysicsDotsTheme.matrix:
        // Classic Studio Console RTA: Green (0-60%) -> Amber (60-85%) -> Red (85-100%)
        if (normHeight < 0.60) {
          return const Color(0xFF00E676);
        } else if (normHeight < 0.85) {
          return const Color(0xFFFFD600);
        } else {
          return const Color(0xFFFF1744);
        }

      case PhysicsDotsTheme.pill:
        // Emerald Green to Bright Cyan
        return Color.lerp(const Color(0xFF00E676), const Color(0xFF18FFFF), normHeight)!;

      case PhysicsDotsTheme.minimal:
        // Subtle monochrome / theme primary gradient
        return Color.lerp(
          primaryColor.withValues(alpha: 0.70),
          Colors.white,
          normHeight * 0.75,
        )!;
    }
  }

  /// Evaluates peak dot highlight color.
  Color _getPeakColor(double normHeight) {
    switch (theme) {
      case PhysicsDotsTheme.neon:
        return const Color(0xFFE0F7FA); // Brilliant icy white-cyan
      case PhysicsDotsTheme.fire:
        return const Color(0xFFFFFF8D); // White-hot gold
      case PhysicsDotsTheme.matrix:
        return normHeight > 0.85 ? const Color(0xFFFF5252) : const Color(0xFFFFFFFF);
      case PhysicsDotsTheme.pill:
        return const Color(0xFFFFFFFF);
      case PhysicsDotsTheme.minimal:
        return const Color(0xFFFFFFFF);
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

      final label = logScale
          ? (level == 1.0
              ? '0dB'
              : level == 0.75
                  ? '-12'
                  : level == 0.50
                      ? '-24'
                      : '-36')
          : '${(level * 100).toInt()}%';
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

    // Bottom Frequency Labels & Vertical Grids based on sample rate & scale mode
    final double effectiveMaxFreq =
        maxFreq > 0 ? maxFreq.toDouble() : 24000.0;

    String formatFreqLabel(double f) {
      if (f >= 1000) {
        if (f % 1000 == 0) {
          return '${(f / 1000).toInt()}k';
        } else if ((f * 10) % 1000 == 0) {
          return '${(f / 1000).toStringAsFixed(1)}k';
        } else {
          return '${(f / 1000).toStringAsFixed(f >= 10000 ? 0 : 1)}k';
        }
      }
      return '${f.toInt()}';
    }

    final List<({double f, String label, double x})> computedTicks = [];

    if (logScale) {
      // Logarithmic Frequency Axis (20 Hz to effectiveMaxFreq)
      const double minFreq = 20.0;
      final double safeMaxFreq = math.max(minFreq * 1.5, effectiveMaxFreq);
      final logRange = math.log(safeMaxFreq / minFreq);

      final candidates = <double>[
        20.0,
        50.0,
        100.0,
        250.0,
        500.0,
        1000.0,
        2000.0,
        5000.0,
        10000.0,
        20000.0,
        40000.0,
        80000.0,
        safeMaxFreq,
      ];

      for (final f in candidates) {
        if (f < minFreq || f > safeMaxFreq) continue;
        final ratio = (math.log(f / minFreq) / logRange).clamp(0.0, 1.0);
        final x = x0 + ratio * w;
        computedTicks.add((f: f, label: formatFreqLabel(f), x: x));
      }
    } else {
      // Linear Frequency Axis (0 Hz to effectiveMaxFreq)
      double step;
      if (effectiveMaxFreq <= 12000) {
        step = 2000.0;
      } else if (effectiveMaxFreq <= 25000) {
        step = 4000.0;
      } else if (effectiveMaxFreq <= 50000) {
        step = 8000.0;
      } else if (effectiveMaxFreq <= 100000) {
        step = 16000.0;
      } else {
        step = 24000.0;
      }

      for (double f = 0.0; f <= effectiveMaxFreq; f += step) {
        final x = x0 + (f / effectiveMaxFreq) * w;
        computedTicks.add((f: f, label: formatFreqLabel(f), x: x));
      }

      // Add Nyquist edge tick if not already present near right border
      if (computedTicks.isNotEmpty &&
          (w - (computedTicks.last.x - x0)) > 26.0) {
        computedTicks.add((
          f: effectiveMaxFreq,
          label: formatFreqLabel(effectiveMaxFreq),
          x: x0 + w,
        ));
      }
    }

    // Render grid lines and non-overlapping labels
    double lastLabelX = -999.0;
    for (final tick in computedTicks) {
      if (showGrids) {
        canvas.drawLine(
          Offset(tick.x, y0),
          Offset(tick.x, y0 + h),
          gridLinePaint,
        );
      }

      // Ensure tick labels have at least 26px clearance to prevent overlap
      if ((tick.x - lastLabelX).abs() >= 26.0 &&
          tick.x >= x0 - 2 &&
          tick.x <= x0 + w + 10) {
        final tp = TextPainter(
          text: TextSpan(text: tick.label, style: labelStyle),
          textDirection: TextDirection.ltr,
        )..layout();

        final labelX =
            (tick.x - (tp.width / 2)).clamp(x0, x0 + w - tp.width);
        tp.paint(canvas, Offset(labelX, y0 + h + 5));
        lastLabelX = tick.x;
      }
    }
  }

  @override
  bool shouldRepaint(covariant _PhysicsDotsPainter oldDelegate) {
    return true; // Continuously repaints driven by the physics ticker loop
  }
}
