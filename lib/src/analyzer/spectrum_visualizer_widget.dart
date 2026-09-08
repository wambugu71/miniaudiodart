import 'dart:async';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'audio_analysis_processor.dart';

/// Style presets for the RTA Spectrum Visualizer.
enum SpectrumVisualStyle {
  /// Modern gradient bars with glowing peak hold dots.
  neon,

  /// Warm audiophile fire gradient (amber to cyan).
  fire,

  /// Clean minimal solid bars.
  minimal,

  /// Round pill bars.
  pill,
}

/// A 60 FPS real-time RTA Frequency Spectrum Visualizer widget for Flutter.
class SpectrumVisualizerWidget extends StatefulWidget {
  /// Raw PCM float stream from `player.analyzerStream`.
  final Stream<Float32List> analyzerStream;

  /// Whether audio is currently playing.
  final bool isPlaying;

  /// Number of frequency bands (default: 32).
  final int bandCount;

  /// Visual style preset.
  final SpectrumVisualStyle style;

  /// Custom bar gradient (overrides preset if provided).
  final Gradient? gradient;

  /// Show peak hold dots on top of spectrum bars.
  final bool showPeakHold;

  /// Color of the peak hold dots.
  final Color? peakHoldColor;

  /// Corner radius of the bars.
  final double barRadius;

  /// Height of the visualizer.
  final double height;

  /// FFT Window function (Hann, Hamming, Blackman-Harris, Flat-Top).
  final FftWindowType windowType;

  const SpectrumVisualizerWidget({
    super.key,
    required this.analyzerStream,
    required this.isPlaying,
    this.bandCount = 32,
    this.style = SpectrumVisualStyle.neon,
    this.gradient,
    this.showPeakHold = true,
    this.peakHoldColor,
    this.barRadius = 3.0,
    this.height = 120.0,
    this.windowType = FftWindowType.hann,
  });

  @override
  State<SpectrumVisualizerWidget> createState() =>
      _SpectrumVisualizerWidgetState();
}

class _SpectrumVisualizerWidgetState extends State<SpectrumVisualizerWidget> {
  late AudioAnalysisProcessor _processor;
  late AudioAnalysisData _currentData;
  StreamSubscription<Float32List>? _sub;

  @override
  void initState() {
    super.initState();
    _processor = AudioAnalysisProcessor(
      numBands: widget.bandCount,
      windowType: widget.windowType,
    );
    _currentData = AudioAnalysisData.empty(widget.bandCount);
    _listenToStream();
  }

  @override
  void didUpdateWidget(SpectrumVisualizerWidget oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.bandCount != widget.bandCount) {
      _processor = AudioAnalysisProcessor(
        numBands: widget.bandCount,
        windowType: widget.windowType,
      );
      _currentData = AudioAnalysisData.empty(widget.bandCount);
    } else if (oldWidget.windowType != widget.windowType) {
      _processor.setWindowType(widget.windowType);
    }
    if (oldWidget.analyzerStream != widget.analyzerStream) {
      _sub?.cancel();
      _listenToStream();
    }
  }

  void _listenToStream() {
    _sub = widget.analyzerStream.listen((pcmFrame) {
      if (mounted) {
        final newData = _processor.processFrame(pcmFrame);
        setState(() {
          _currentData = newData;
        });
      }
    });
  }

  @override
  void dispose() {
    _sub?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: widget.height,
      child: CustomPaint(
        painter: _SpectrumPainter(
          data: _currentData,
          style: widget.style,
          gradient: widget.gradient,
          showPeakHold: widget.showPeakHold,
          peakHoldColor: widget.peakHoldColor ?? Colors.cyanAccent,
          barRadius: widget.barRadius,
        ),
        size: Size.infinite,
      ),
    );
  }
}

class _SpectrumPainter extends CustomPainter {
  final AudioAnalysisData data;
  final SpectrumVisualStyle style;
  final Gradient? gradient;
  final bool showPeakHold;
  final Color peakHoldColor;
  final double barRadius;

  _SpectrumPainter({
    required this.data,
    required this.style,
    this.gradient,
    required this.showPeakHold,
    required this.peakHoldColor,
    required this.barRadius,
  });

  @override
  void paint(Canvas canvas, Size size) {
    if (data.bands.isEmpty) return;

    final count = data.bands.length;
    final totalGapRatio = 0.35;
    final totalWidth = size.width;
    final barWidth = totalWidth / (count + (count - 1) * totalGapRatio);
    final gap = barWidth * totalGapRatio;

    final Gradient defaultGradient;
    switch (style) {
      case SpectrumVisualStyle.fire:
        defaultGradient = const LinearGradient(
          colors: [Colors.deepOrange, Colors.amber, Colors.cyanAccent],
          stops: [0.0, 0.6, 1.0],
          begin: Alignment.bottomCenter,
          end: Alignment.topCenter,
        );
        break;
      case SpectrumVisualStyle.minimal:
        defaultGradient = const LinearGradient(
          colors: [Colors.blueAccent, Colors.lightBlueAccent],
          begin: Alignment.bottomCenter,
          end: Alignment.topCenter,
        );
        break;
      case SpectrumVisualStyle.pill:
      case SpectrumVisualStyle.neon:
        defaultGradient = const LinearGradient(
          colors: [Colors.purpleAccent, Colors.cyanAccent],
          begin: Alignment.bottomCenter,
          end: Alignment.topCenter,
        );
        break;
    }

    final barPaint = Paint()
      ..shader = (gradient ?? defaultGradient).createShader(
        Rect.fromLTWH(0, 0, size.width, size.height),
      )
      ..style = PaintingStyle.fill;

    final peakPaint = Paint()
      ..color = peakHoldColor
      ..style = PaintingStyle.fill;

    for (int i = 0; i < count; i++) {
      final mag = data.bands[i];
      final minHeight = 2.0; // keep small baseline
      final barHeight = (mag * (size.height - 6.0)).clamp(minHeight, size.height);
      final x = i * (barWidth + gap);
      final y = size.height - barHeight;

      // Draw Main Spectrum Bar
      final RRect rrect;
      if (style == SpectrumVisualStyle.pill) {
        rrect = RRect.fromRectAndRadius(
          Rect.fromLTWH(x, y, barWidth, barHeight),
          Radius.circular(barWidth * 0.5),
        );
      } else {
        rrect = RRect.fromRectAndCorners(
          Rect.fromLTWH(x, y, barWidth, barHeight),
          topLeft: Radius.circular(barRadius),
          topRight: Radius.circular(barRadius),
          bottomLeft: Radius.circular(1.0),
          bottomRight: Radius.circular(1.0),
        );
      }

      canvas.drawRRect(rrect, barPaint);

      // Draw Peak Hold Dot/Line
      if (showPeakHold) {
        final peakMag = data.peakHoldBands[i];
        final peakY = (size.height - (peakMag * (size.height - 6.0))).clamp(2.0, size.height - 2.0);

        final peakRRect = RRect.fromRectAndRadius(
          Rect.fromLTWH(x, peakY - 2.0, barWidth, 2.0),
          const Radius.circular(1.0),
        );
        canvas.drawRRect(peakRRect, peakPaint);
      }
    }
  }

  @override
  bool shouldRepaint(covariant _SpectrumPainter oldDelegate) {
    return oldDelegate.data != data;
  }
}

/// A real-time RMS Level Meter Widget showing dBFS and peak warning indicator.
class RmsMeterWidget extends StatefulWidget {
  final Stream<Float32List> analyzerStream;
  final bool isPlaying;

  const RmsMeterWidget({
    super.key,
    required this.analyzerStream,
    required this.isPlaying,
  });

  @override
  State<RmsMeterWidget> createState() => _RmsMeterWidgetState();
}

class _RmsMeterWidgetState extends State<RmsMeterWidget> {
  final _processor = AudioAnalysisProcessor(numBands: 16);
  AudioAnalysisData _currentData = AudioAnalysisData.empty(16);
  StreamSubscription<Float32List>? _sub;

  @override
  void initState() {
    super.initState();
    _sub = widget.analyzerStream.listen((pcmFrame) {
      if (mounted) {
        setState(() {
          _currentData = _processor.processFrame(pcmFrame);
        });
      }
    });
  }

  @override
  void dispose() {
    _sub?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final normRms = ((_currentData.rmsDb + 60.0) / 60.0).clamp(0.0, 1.0);
    final normPeak = ((_currentData.peakDb + 60.0) / 60.0).clamp(0.0, 1.0);

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.4),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                'RMS Loudness',
                style: theme.textTheme.labelMedium?.copyWith(
                  fontWeight: FontWeight.bold,
                ),
              ),
              Row(
                children: [
                  Text(
                    '${_currentData.rmsDb.toStringAsFixed(1)} dBFS',
                    style: theme.textTheme.labelSmall?.copyWith(
                      fontFeatures: const [FontFeature.tabularFigures()],
                      color: _currentData.rmsDb > -3.0
                          ? Colors.redAccent
                          : theme.textTheme.labelSmall?.color,
                    ),
                  ),
                  const SizedBox(width: 6),
                  Container(
                    width: 8,
                    height: 8,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: _currentData.isClipped
                          ? Colors.red
                          : (_currentData.peakDb > -1.0
                              ? Colors.amber
                              : Colors.greenAccent),
                    ),
                  ),
                ],
              ),
            ],
          ),
          const SizedBox(height: 6),
          // Dual bar showing Peak and RMS
          ClipRRect(
            borderRadius: BorderRadius.circular(4),
            child: SizedBox(
              height: 10,
              child: Stack(
                children: [
                  // Background
                  Container(color: theme.colorScheme.surface),
                  // Peak Level Bar
                  FractionallySizedBox(
                    widthFactor: normPeak,
                    child: Container(
                      color: normPeak > 0.95
                          ? Colors.redAccent.withValues(alpha: 0.5)
                          : Colors.amber.withValues(alpha: 0.4),
                    ),
                  ),
                  // RMS Level Bar
                  FractionallySizedBox(
                    widthFactor: normRms,
                    child: Container(
                      decoration: const BoxDecoration(
                        gradient: LinearGradient(
                          colors: [Colors.tealAccent, Colors.cyan, Colors.blueAccent],
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
