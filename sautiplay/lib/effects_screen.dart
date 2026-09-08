import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:material_3_expressive/material_3_expressive.dart';
import 'package:sautiflow/sautiflow.dart';
import 'eq_screen.dart';
import 'isolate_player.dart';
import 'services/app_theme_service.dart';
import 'services/audio_hardware_inspector.dart';
import 'services/fft_processor.dart';
import 'widgets/fluid_area_visualizer.dart';
import 'widgets/glsl_audio_visualizer.dart';
import 'widgets/physics_dots_visualizer.dart';
import 'widgets/profile_selector.dart';

class EffectsScreen extends StatefulWidget {
  final IsolateAudioPlayer player;
  final bool analyzerEnabled;
  final String analyzerType;
  final bool analyzerAutoFit;
  final bool analyzerShowGrids;
  final bool analyzerLogScale;
  final int outputSampleRate;
  final String spectrumStyle;
  final GlobalKey? effectsKnobKey;

  const EffectsScreen({
    super.key,
    required this.player,
    required this.analyzerEnabled,
    this.analyzerType = 'bar',
    required this.analyzerAutoFit,
    required this.analyzerShowGrids,
    this.analyzerLogScale = true,
    required this.outputSampleRate,
    this.spectrumStyle = 'minimal',
    this.effectsKnobKey,
  });

  @override
  State<EffectsScreen> createState() => _EffectsScreenState();
}

class _EffectsScreenState extends State<EffectsScreen> {
  List<double> _analyzerValues = [];
  List<double> _peakValues = [];
  StreamSubscription? _analyzerSub;
  StreamSubscription<PlayerStatus>? _statusSub;
  StreamSubscription<AudioHardwareSpecs>? _hardwareSub;
  AudioHardwareSpecs? _hardwareSpecs;
  bool _isPlaying = false;
  FftProcessor? _fftProcessor;
  late String _currentAnalyzerType;
  late String _currentSpectrumStyle;

  /// Effective sample rate currently used by audio engine & DAC hardware.
  int get _currentlyUsedSampleRate {
    if (widget.outputSampleRate > 0) {
      return widget.outputSampleRate;
    }
    final hwRate = _hardwareSpecs?.sampleRate ??
        AudioHardwareInspector.currentSpecs?.sampleRate;
    if (hwRate != null && hwRate > 0) {
      return hwRate;
    }
    return 48000;
  }

  /// True Nyquist upper boundary (f_s / 2) for the currently used sample rate.
  int get _currentMaxFreq => _currentlyUsedSampleRate ~/ 2;

  String _formatRateString(int rateHz) {
    if (rateHz <= 0) return '48 kHz';
    final double kHz = rateHz / 1000.0;
    return rateHz % 1000 == 0
        ? '${rateHz ~/ 1000} kHz'
        : '${kHz.toStringAsFixed(1)} kHz';
  }

  @override
  void initState() {
    super.initState();
    _currentAnalyzerType = widget.analyzerType;
    _currentSpectrumStyle = widget.spectrumStyle;
    _isPlaying = widget.player.isPlaying;

    _hardwareSpecs = AudioHardwareInspector.currentSpecs;
    AudioHardwareInspector.inspectAsync(widget.player).then((specs) {
      if (mounted) {
        setState(() {
          _hardwareSpecs = specs;
          _updateAnalyzerConfig();
        });
      }
    });
    _hardwareSub =
        AudioHardwareInspector.hardwareStream(widget.player).listen((specs) {
      if (mounted) {
        setState(() {
          _hardwareSpecs = specs;
          _updateAnalyzerConfig();
        });
      }
    });

    _setupAnalyzer(widget.analyzerEnabled);
    _statusSub = widget.player.statusStream.listen((status) {
      if (mounted && _isPlaying != status.isPlaying) {
        setState(() {
          _isPlaying = status.isPlaying;
        });
      }
    });
  }

  @override
  void didUpdateWidget(covariant EffectsScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.analyzerType != widget.analyzerType) {
      _currentAnalyzerType = widget.analyzerType;
    }
    if (oldWidget.spectrumStyle != widget.spectrumStyle) {
      _currentSpectrumStyle = widget.spectrumStyle;
    }
    if (oldWidget.outputSampleRate != widget.outputSampleRate ||
        oldWidget.analyzerLogScale != widget.analyzerLogScale) {
      _updateAnalyzerConfig();
    }
    if (oldWidget.analyzerEnabled != widget.analyzerEnabled) {
      _setupAnalyzer(widget.analyzerEnabled);
    }
  }

  void _updateAnalyzerConfig() {
    _fftProcessor?.setSampleRate(_currentlyUsedSampleRate);
    _fftProcessor?.setLogScale(widget.analyzerLogScale);
  }

  @override
  void dispose() {
    _analyzerSub?.cancel();
    _statusSub?.cancel();
    _hardwareSub?.cancel();
    super.dispose();
  }

  void _setupAnalyzer(bool enabled) {
    if (enabled) {
      final sr = _currentlyUsedSampleRate;
      _fftProcessor ??= FftProcessor(
        sampleRate: sr,
        logScale: widget.analyzerLogScale,
      );
      _fftProcessor!.setSampleRate(sr);
      _fftProcessor!.setLogScale(widget.analyzerLogScale);
      widget.player.setAnalyzerEnabled(true);
      _analyzerSub ??= widget.player.analyzerStream.listen((frame) {
        if (frame.isEmpty) return;
        if (!_isPlaying) {
          _isPlaying = true;
        }
        const targetBins = 60;
        final bins = _fftProcessor!.processFrame(
          frame,
          targetBins: targetBins,
          logScale: widget.analyzerLogScale,
        );
        if (mounted) {
          setState(() {
            _analyzerValues = bins;
            if (_peakValues.length != targetBins) {
              _peakValues = List<double>.filled(targetBins, 0.0);
            }
            for (int i = 0; i < targetBins; i++) {
              if (bins[i] > _peakValues[i]) {
                _peakValues[i] = bins[i];
              } else {
                _peakValues[i] = math.max(0.0, _peakValues[i] - 0.02);
              }
            }
          });
        }
      });
    } else {
      _analyzerSub?.cancel();
      _analyzerSub = null;
      _fftProcessor?.reset();
      if (mounted) {
        setState(() {
          _analyzerValues = [];
          _peakValues = [];
        });
      }
    }
  }

  Widget _buildVisualizer(Color primaryColor,
      List<double> currentAnalyzerValues, List<double> peakValues) {
    final int maxFreq = _currentMaxFreq;

    for (final style in GlslShaderStyle.values) {
      if (_currentAnalyzerType == style.name ||
          _currentAnalyzerType == style.displayName) {
        return GlslAudioVisualizerWidget(
          analyzerStream: widget.player.analyzerStream,
          isPlaying: _isPlaying,
          style: style,
          primaryColor: primaryColor,
          height: 160.0,
        );
      }
    }

    if (_currentAnalyzerType == 'area') {
      return FluidAreaVisualizer(
        values: currentAnalyzerValues,
        primaryColor: primaryColor,
        height: 160.0,
        themeName: _currentSpectrumStyle,
        showGrids: widget.analyzerShowGrids,
        logScale: widget.analyzerLogScale,
        autoFit: widget.analyzerAutoFit,
        maxFreq: maxFreq,
        onThemeChanged: (newTheme) {
          setState(() {
            _currentSpectrumStyle = newTheme;
          });
        },
      );
    } else {
      return PhysicsDotsVisualizer(
        values: currentAnalyzerValues,
        primaryColor: primaryColor,
        height: 160.0,
        themeName: _currentSpectrumStyle,
        showGrids: widget.analyzerShowGrids,
        logScale: widget.analyzerLogScale,
        autoFit: widget.analyzerAutoFit,
        maxFreq: maxFreq,
        onThemeChanged: (newTheme) {
          setState(() {
            _currentSpectrumStyle = newTheme;
          });
        },
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final primaryColor = context.primaryColor;
    final bgColor = context.bgDark;
    final cardColor = context.cardDark;
    final headerColor = bgColor;

    // Calculate the dynamic expanded height based on what's visible
    final double analyzerChartHeight =
        (widget.analyzerEnabled && _analyzerValues.isNotEmpty)
            ? 194.0
            : 0.0; // 160 + 18 (specs) + 16 (padding)
    final double spectrumHeight = widget.analyzerEnabled
        ? 160.0
        : 0.0; // 85 (spectrum) + 8 (gap) + 45 (RMS meter) + 22 (padding)
    const double controlBarHeight = 44.0;
    const double titleBarHeight = 50.0;
    const double dragHandleHeight = 10.0;
    final topPadding = MediaQuery.of(context).padding.top;
    final double expandedHeight = topPadding +
        titleBarHeight +
        controlBarHeight +
        analyzerChartHeight +
        spectrumHeight +
        dragHandleHeight;
    final double collapsedHeight =
        topPadding + titleBarHeight + controlBarHeight + dragHandleHeight;

    // Helper to get active visualizer display label
    String activeVisualizerLabel =
        'Dot Matrix (${PhysicsDotsTheme.fromString(_currentSpectrumStyle).displayName})';
    if (_currentAnalyzerType == 'area') {
      activeVisualizerLabel =
          'Fluid Wave (${FluidAreaTheme.fromString(_currentSpectrumStyle).displayName})';
    } else if (_currentAnalyzerType != 'bar') {
      final glslMatch = GlslShaderStyle.values.firstWhere(
        (s) =>
            s.name == _currentAnalyzerType ||
            s.displayName == _currentAnalyzerType,
        orElse: () => GlslShaderStyle.cyberTunnel,
      );
      activeVisualizerLabel = glslMatch.displayName;
    }

    return Scaffold(
      backgroundColor: bgColor,
      body: NestedScrollView(
        headerSliverBuilder: (context, innerBoxIsScrolled) {
          return [
            SliverAppBar(
              backgroundColor: headerColor,
              pinned: true,
              floating: false,
              snap: false,
              expandedHeight: expandedHeight,
              collapsedHeight: collapsedHeight,
              toolbarHeight: 0, // We handle our own title in flexibleSpace
              automaticallyImplyLeading: false,
              flexibleSpace: LayoutBuilder(
                builder: (context, constraints) {
                  // How much space is available beyond the collapsed state
                  final double currentHeight = constraints.maxHeight;
                  final double expandableRange =
                      expandedHeight - collapsedHeight;
                  final double scrollFraction = expandableRange > 0
                      ? ((currentHeight - collapsedHeight) / expandableRange)
                          .clamp(0.0, 1.0)
                      : 0.0;

                  return Column(
                    children: [
                      // Safe area top padding
                      SizedBox(height: topPadding),

                      // Title Bar (Always visible)
                      SizedBox(
                        height: titleBarHeight,
                        child: Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 12.0),
                          child: Row(
                            children: [
                              if (Navigator.canPop(context))
                                const BackButton(color: Colors.white),
                              Icon(Icons.tune_rounded,
                                  color: primaryColor, size: 22),
                              const SizedBox(width: 8),
                              const Text(
                                'Audio Effects & DSP',
                                style: TextStyle(
                                  color: Colors.white,
                                  fontSize: 17,
                                  fontWeight: FontWeight.bold,
                                ),
                              ),
                              const Spacer(),
                              // Quick toggle analyzer visualizer
                              IconButton(
                                icon: Icon(
                                  widget.analyzerEnabled
                                      ? Icons.equalizer
                                      : Icons.equalizer_outlined,
                                  color: widget.analyzerEnabled
                                      ? primaryColor
                                      : Colors.white38,
                                  size: 22,
                                ),
                                tooltip: widget.analyzerEnabled
                                    ? 'Analyzer Active'
                                    : 'Analyzer Off',
                                onPressed: () {
                                  _setupAnalyzer(!widget.analyzerEnabled);
                                },
                              ),
                            ],
                          ),
                        ),
                      ),

                      // Secondary Pinned Control Bar (Mobile-Optimized for Selectors)
                      SizedBox(
                        height: controlBarHeight,
                        child: Padding(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 12.0, vertical: 2.0),
                          child: Row(
                            children: [
                              // Visualizer Selector Pill Menu
                              Expanded(
                                child: M3EMenu(
                                  anchorBuilder: (context, open) => InkWell(
                                    onTap: open,
                                    borderRadius: BorderRadius.circular(18),
                                    child: Container(
                                      decoration: BoxDecoration(
                                        borderRadius: BorderRadius.circular(14),
                                        color: cardColor,
                                        border: Border.all(
                                          color: primaryColor.withValues(
                                              alpha: 0.25),
                                        ),
                                      ),
                                      height: 34,
                                      child: Padding(
                                        padding: const EdgeInsets.symmetric(
                                            horizontal: 10),
                                        child: Row(
                                          children: [
                                            Icon(Icons.auto_awesome_mosaic,
                                                color: primaryColor, size: 14),
                                            const SizedBox(width: 6),
                                            Expanded(
                                              child: Text(
                                                activeVisualizerLabel,
                                                overflow: TextOverflow.ellipsis,
                                                style: const TextStyle(
                                                  color: Colors.white,
                                                  fontSize: 12,
                                                  fontWeight: FontWeight.w600,
                                                ),
                                              ),
                                            ),
                                            const Icon(Icons.arrow_drop_down,
                                                color: Colors.white70,
                                                size: 16),
                                          ],
                                        ),
                                      ),
                                    ),
                                  ),
                                  children: [
                                    M3EMenuGroup.entries(
                                      label: 'Standard Visualizers',
                                      entries: [
                                        M3EMenuEntry(
                                          label: 'Wave Area',
                                          leading: const Icon(
                                              Icons.show_chart_rounded,
                                              size: 18),
                                          onPressed: () {
                                            setState(() {
                                              _currentAnalyzerType = 'area';
                                            });
                                          },
                                        ),
                                        M3EMenuEntry(
                                          label: 'Matrix Spectrum',
                                          leading: const Icon(
                                              Icons.grain_rounded,
                                              size: 18),
                                          onPressed: () {
                                            setState(() {
                                              _currentAnalyzerType = 'bar';
                                            });
                                          },
                                        ),
                                      ],
                                    ),
                                    M3EMenuGroup.entries(
                                      label: _currentAnalyzerType == 'area'
                                          ? 'Wave Themes'
                                          : 'Matrix Themes',
                                      entries: (_currentAnalyzerType == 'area'
                                              ? FluidAreaTheme.values.map(
                                                  (theme) => M3EMenuEntry(
                                                    label: theme.displayName,
                                                    leading: Icon(
                                                      theme.icon,
                                                      size: 18,
                                                      color:
                                                          _currentSpectrumStyle ==
                                                                  theme.name
                                                              ? primaryColor
                                                              : null,
                                                    ),
                                                    onPressed: () {
                                                      setState(() {
                                                        _currentSpectrumStyle =
                                                            theme.name;
                                                      });
                                                    },
                                                  ),
                                                )
                                              : PhysicsDotsTheme.values.map(
                                                  (theme) => M3EMenuEntry(
                                                    label: theme.displayName,
                                                    leading: Icon(
                                                      theme.icon,
                                                      size: 18,
                                                      color:
                                                          _currentSpectrumStyle ==
                                                                  theme.name
                                                              ? primaryColor
                                                              : null,
                                                    ),
                                                    onPressed: () {
                                                      setState(() {
                                                        _currentSpectrumStyle =
                                                            theme.name;
                                                      });
                                                    },
                                                  ),
                                                ))
                                          .toList(),
                                    ),
                                    M3EMenuGroup.entries(
                                      label: 'GLSL Shaders',
                                      entries: GlslShaderStyle.values
                                          .map(
                                            (s) => M3EMenuEntry(
                                              label: s.displayName,
                                              leading: const Icon(
                                                  Icons.auto_awesome,
                                                  size: 18),
                                              onPressed: () {
                                                setState(() {
                                                  _currentAnalyzerType = s.name;
                                                });
                                              },
                                            ),
                                          )
                                          .toList(),
                                    ),
                                  ],
                                ),
                              ),

                              const SizedBox(width: 8),

                              // Audio Profile Selector
                              AudioProfileSelector(
                                player: widget.player,
                                isCompact: true,
                                onProfileChanged: () {
                                  setState(() {});
                                },
                              ),
                            ],
                          ),
                        ),
                      ),

                      // Collapsible analyzer section
                      if (expandableRange > 0)
                        Expanded(
                          child: ClipRect(
                            child: Opacity(
                              opacity: scrollFraction,
                              child: SingleChildScrollView(
                                physics: const NeverScrollableScrollPhysics(),
                                child: Column(
                                  children: [
                                    // Realtime Visualizer (BarChart / LineChart / GLSL Shaders)
                                    if (widget.analyzerEnabled)
                                      Padding(
                                        padding: const EdgeInsets.symmetric(
                                            horizontal: 16.0, vertical: 8.0),
                                        child: Column(
                                          mainAxisSize: MainAxisSize.min,
                                          children: [
                                            SizedBox(
                                              height: 160,
                                              child: _buildVisualizer(
                                                  primaryColor,
                                                  _analyzerValues,
                                                  _peakValues),
                                            ),
                                          ],
                                        ),
                                      ),

                                    // RMS Loudness Meter Slider
                                    if (widget.analyzerEnabled)
                                      Padding(
                                        padding: const EdgeInsets.symmetric(
                                            horizontal: 16.0, vertical: 6.0),
                                        child: RmsMeterWidget(
                                          analyzerStream:
                                              widget.player.analyzerStream,
                                          isPlaying: _isPlaying,
                                        ),
                                      ),
                                  ],
                                ),
                              ),
                            ),
                          ),
                        ),

                      // Drag Handle Affordance (Pill indicator for sliver expansion/collapse)
                      Padding(
                        padding: const EdgeInsets.only(top: 4, bottom: 2),
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Container(
                              width: 36,
                              height: 4,
                              decoration: BoxDecoration(
                                color: Colors.white.withValues(alpha: 0.35),
                                borderRadius: BorderRadius.circular(2),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  );
                },
              ),
            ),
          ];
        },
        body: EqScreen(
          effectsKnobKey: widget.effectsKnobKey,
          player: widget.player,
          analyzerEnabled: widget.analyzerEnabled,
          analyzerType: widget.analyzerType,
        ),
      ),
    );
  }
}
