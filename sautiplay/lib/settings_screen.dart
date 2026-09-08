import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:sautiflow/sautiflow.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';

import 'package:flutter_m3shapes_extended/flutter_m3shapes_extended.dart';
import 'package:material_3_expressive/material_3_expressive.dart';

import 'eq_screen.dart';
import 'isolate_player.dart';
import 'widgets/app_m3e_widgets.dart';
import 'network_sources_screen.dart';
import 'services/app_state_service.dart';
import 'services/app_theme_service.dart';
import 'services/cached_stream_service.dart';
import 'services/lastfm_service.dart';
import 'streaming_service.dart';
import 'services/app_update_service.dart';
import 'widgets/app_update_dialog.dart';
import 'widgets/album_art_shape_selector.dart';
import 'widgets/audio_engine_diagnostic_panel.dart';

class SettingsScreen extends StatefulWidget {
  final IsolateAudioPlayer player;
  // Shared state from main.dart
  final bool analyzerEnabled;
  final ValueChanged<bool> onAnalyzerEnabledChanged;
  final String analyzerType;
  final ValueChanged<String> onAnalyzerTypeChanged;
  final bool analyzerAutoFit;
  final ValueChanged<bool> onAnalyzerAutoFitChanged;
  final bool analyzerShowGrids;
  final ValueChanged<bool> onAnalyzerShowGridsChanged;
  final bool analyzerLogScale;
  final ValueChanged<bool> onAnalyzerLogScaleChanged;
  final int analyzerSampleSize;
  final ValueChanged<int> onAnalyzerSampleSizeChanged;
  final String analyzerWindowType;
  final ValueChanged<String> onAnalyzerWindowTypeChanged;
  final AudioFormat outputFormat;
  final ValueChanged<AudioFormat> onOutputFormatChanged;
  final int outputSampleRate;
  final ValueChanged<int> onOutputSampleRateChanged;
  final int outputChannels;
  final ValueChanged<int> onOutputChannelsChanged;
  final bool crossfadeEnabled;
  final ValueChanged<bool> onCrossfadeEnabledChanged;
  final int crossfadeDurationMs;
  final ValueChanged<int> onCrossfadeDurationMsChanged;
  final bool exclusiveMode;
  final ValueChanged<bool> onExclusiveModeChanged;
  final String spectrumStyle;
  final ValueChanged<String> onSpectrumStyleChanged;

  final List<String> logs;
  final ValueNotifier<int> logUpdateNotifier;
  final bool allowInvalidTls;
  final ValueChanged<bool> onAllowInvalidTlsChanged;
  final VoidCallback onPollError;
  final VoidCallback onClearNativeError;
  final VoidCallback onClearLogs;
  final void Function(String filePath, String title, String artist)?
      onPlayNetworkFile;
  final void Function(List<dynamic> entries, dynamic config, int initialIndex)?
      onPlayFtpFolder;
  final VoidCallback? onTriggerShowcase;

  const SettingsScreen({
    super.key,
    required this.player,
    required this.analyzerEnabled,
    required this.onAnalyzerEnabledChanged,
    required this.onAnalyzerTypeChanged,
    required this.analyzerType,
    required this.analyzerAutoFit,
    required this.onAnalyzerAutoFitChanged,
    required this.analyzerShowGrids,
    required this.onAnalyzerShowGridsChanged,
    required this.analyzerLogScale,
    required this.onAnalyzerLogScaleChanged,
    required this.analyzerSampleSize,
    required this.onAnalyzerSampleSizeChanged,
    this.analyzerWindowType = 'hann',
    required this.onAnalyzerWindowTypeChanged,
    required this.outputFormat,
    required this.onOutputFormatChanged,
    required this.outputSampleRate,
    required this.onOutputSampleRateChanged,
    required this.outputChannels,
    required this.onOutputChannelsChanged,
    required this.crossfadeEnabled,
    required this.onCrossfadeEnabledChanged,
    required this.crossfadeDurationMs,
    required this.onCrossfadeDurationMsChanged,
    required this.exclusiveMode,
    required this.onExclusiveModeChanged,
    required this.spectrumStyle,
    required this.onSpectrumStyleChanged,
    required this.logs,
    required this.logUpdateNotifier,
    required this.allowInvalidTls,
    required this.onAllowInvalidTlsChanged,
    required this.onPollError,
    required this.onClearNativeError,
    required this.onClearLogs,
    this.onPlayNetworkFile,
    this.onPlayFtpFolder,
    this.onTriggerShowcase,
  });

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  // Dynamic theme colors from BuildContext (reactive)
  Color get _bgDark => context.bgDark;
  Color get _cardDark => context.cardDark;
  Color get _primary => context.primaryColor;
  Color get _textDark => context.textMuted;
  Color get _textPrimary => context.textPrimary;

  // Local UI settings
  String _streamingQuality = 'High Fidelity';
  AudioQualityPreset _streamingQualityPreset = AudioQualityPreset.audiophile;
  bool _preferNativeAac = false;
  bool _enableHostedFallback = true;
  bool _gaplessPlayback = true;
  bool _normalizeVolume = false;
  bool _streamOverWifi = true;

  // Engine Resampling & Dithering
  int _resampleAlgorithm = 0;
  int _ditherMode = 0;
  int _eqBandCount = 10;

  // DSP Oversampling
  int _dspOversampling = 1;

  // Speaker & Hardware Protection
  bool _speakerProtectionEnabled = true;
  double _subsonicCutoffHz = 25.0;
  double _ultrasonicCutoffHz = 20000.0;
  double _limiterThreshold = 0.95;
  double _safetyAttenuationDb = -1.0;

  // Phase Inversion
  bool _phaseInvertLeft = false;
  bool _phaseInvertRight = false;

  // L/R Swap & Per-Channel Gain
  bool _lrSwapEnabled = false;
  double _channelGainLeftDb = 0.0;
  double _channelGainRightDb = 0.0;

  // Fixed Output Buffer & Latency
  int _outputBufferFrames = 0;
  int _outputBufferPeriods = 0;

  // Android Audio Output Backend & Hardware
  AudioOutputBackend _selectedBackend = AudioOutputBackend.auto;
  String _detectedDspHardware = '';
  // String _detectedSocModel = '';

  // Neutron HiFi Engine Settings
  bool _use64BitProcessingEnabled = false;
  bool _autoBitPerfectEnabled = true;

  // Loudness-Aware Crossfade
  bool _loudnessCrossfadeEnabled = true;

  // Waveform & Slider Seek Bar UI Settings
  bool _useWaveformSeekBar = false;
  bool _useWavySlider = true;
  double _previewSliderValue = 42.0;

  // App version state
  String _appVersion = 'v0.6.20';
  bool _autoCheckUpdates = true;

  // Changelog loaded from assets/CHANGELOG.md
  List<Map<String, dynamic>> _changelog = [];

  // Active theme ID (always synced with AppThemeProvider)
  AppThemeId get _activeThemeId => context.appTheme.id;

  StreamSubscription<void>? _audioSettingsSub;
  StreamSubscription<PlayerStatus>? _playerStatusSub;
  StreamSubscription<String>? _lastFmAuthSub;
  bool _isPlaying = false;

  @override
  void initState() {
    super.initState();
    _loadUiSettings();
    _loadChangelog();
    _audioSettingsSub = AppStateService
        .instance.audioProcessingSettingsChanged.stream
        .listen((_) {
      if (mounted) {
        _loadUiSettings();
      }
    });
    _playerStatusSub = widget.player.statusStream.listen((status) {
      if (mounted && _isPlaying != status.isPlaying) {
        setState(() => _isPlaying = status.isPlaying);
      }
    });
    _lastFmAuthSub = LastFmService.instance.authSuccessStream.listen((username) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Connected to Last.fm as $username!'),
            backgroundColor: const Color(0xFFD51007),
          ),
        );
      }
    });
  }

  /// Parses assets/CHANGELOG.md into a list of version entries.
  Future<void> _loadChangelog() async {
    try {
      final raw = await rootBundle.loadString('assets/CHANGELOG.md');
      final entries = <Map<String, dynamic>>[];
      Map<String, dynamic>? current;
      for (final line in raw.split('\n')) {
        final trimmed = line.trim();
        if (trimmed.startsWith('## ')) {
          if (current != null) entries.add(current);
          // Parse "## vX.Y.Z — YYYY-MM-DD" or "## vX.Y.Z — YYYY-MM"
          final header = trimmed.substring(3).trim();
          final parts = header.split(RegExp(r'\s*[–—-]\s*'));
          current = {
            'version': parts.isNotEmpty ? parts[0].trim() : header,
            'date': parts.length > 1 ? parts[1].trim() : '',
            'changes': <String>[],
          };
        } else if (trimmed.startsWith('- ') && current != null) {
          (current['changes'] as List<String>).add(trimmed.substring(2).trim());
        }
      }
      if (current != null) entries.add(current);
      if (mounted) setState(() => _changelog = entries);
    } catch (_) {}
  }

  @override
  void dispose() {
    _audioSettingsSub?.cancel();
    _playerStatusSub?.cancel();
    _lastFmAuthSub?.cancel();
    super.dispose();
  }

  String _getAudioProcessingBadgeText() {
    if (widget.exclusiveMode) {
      return 'Bit-Perfect';
    }
    if (_autoBitPerfectEnabled) {
      return 'Auto-Rate • ${_formatAudioDepth(widget.outputFormat)}';
    }
    final depth = _formatAudioDepth(widget.outputFormat);
    final resamplerShort = _resampleAlgorithm == 7 || _resampleAlgorithm == 8
        ? 'SoX VHQ'
        : _resampleAlgorithm == 9
            ? 'SoX HQ'
            : _resampleAlgorithm == 11
                ? 'r8brain LP'
                : _resampleAlgorithm == 12
                    ? 'r8brain MP'
                    : _resampleAlgorithm == 1
                        ? 'Master HD'
                        : 'Linear';
    return '$depth • $resamplerShort';
  }

  String _getStreamingQualityBadgeText() {
    switch (_streamingQualityPreset) {
      case AudioQualityPreset.low:
        return 'Data Saver';
      case AudioQualityPreset.medium:
        return 'Balanced';
      case AudioQualityPreset.high:
        return 'High';
      case AudioQualityPreset.audiophile:
        return 'Max';
    }
  }

  Future<void> _loadUiSettings() async {
    final saved = await AppStateService.instance.loadUiSettings();
    final eqSaved = await AppStateService.instance.loadEqBands();
    final oversamplingSaved =
        await AppStateService.instance.loadDspOversampling();
    final spSaved = await AppStateService.instance.loadSpeakerProtection();
    final phaseSaved = await AppStateService.instance.loadPhaseInversion();
    final lrSwap = await AppStateService.instance.loadLrSwap();
    final channelGains = await AppStateService.instance.loadChannelGains();
    final bufferConfig = await AppStateService.instance.loadOutputBuffer();
    final is64Bit = await AppStateService.instance.load64BitProcessingEnabled();
    final autoBp = await AppStateService.instance.loadAutoBitPerfectEnabled();
    final waveformSaved =
        await AppStateService.instance.loadUseWaveformSeekBar();
    final wavySaved = await AppStateService.instance.loadUseWavySlider();
    final engineSettings = await AppStateService.instance.loadEngineSettings();
    final loudnessCf = engineSettings.loudnessCrossfadeEnabled;
    final streamingPreset =
        await AppStateService.instance.loadStreamingQualityPreset();
    final preferAac = await AppStateService.instance.loadPreferNativeAac();
    final fallback = await AppStateService.instance.loadEnableHostedFallback();

    String versionStr = 'v0.6.20';
    try {
      final info = await PackageInfo.fromPlatform();
      versionStr = 'v${info.version}';
    } catch (_) {}

    final prefs = await SharedPreferences.getInstance();
    final autoCheck = prefs.getBool('auto_check_updates') ?? true;

    if (!mounted) return;
    setState(() {
      _appVersion = versionStr;
      _autoCheckUpdates = autoCheck;
      _streamingQualityPreset = streamingPreset;
      _preferNativeAac = preferAac;
      _enableHostedFallback = fallback;
      _streamingQuality = saved.streamingQuality;
      _gaplessPlayback = saved.gaplessPlayback;
      _normalizeVolume = saved.normalizeVolume;
      _streamOverWifi = saved.streamOverWifi;
      _resampleAlgorithm = saved.resampleAlgorithm;
      _ditherMode = saved.ditherMode;
      _eqBandCount = eqSaved.bandCount;
      _dspOversampling = oversamplingSaved;
      _speakerProtectionEnabled = spSaved.enabled;
      _subsonicCutoffHz = spSaved.subsonicCutoffHz;
      _ultrasonicCutoffHz = spSaved.ultrasonicCutoffHz;
      _limiterThreshold = spSaved.limiterThreshold;
      _safetyAttenuationDb = spSaved.safetyAttenuationDb;
      _phaseInvertLeft = phaseSaved.invertLeft;
      _phaseInvertRight = phaseSaved.invertRight;
      _lrSwapEnabled = lrSwap;
      _channelGainLeftDb = channelGains.leftDb;
      _channelGainRightDb = channelGains.rightDb;
      _outputBufferFrames = bufferConfig.periodFrames;
      _outputBufferPeriods = bufferConfig.periodCount;
      _use64BitProcessingEnabled = is64Bit;
      _autoBitPerfectEnabled = autoBp;
      _loudnessCrossfadeEnabled = loudnessCf;
      _useWaveformSeekBar = waveformSaved;
      _useWavySlider = wavySaved;
    });

    final loudnessNorm =
        await AppStateService.instance.loadLoudnessNormalizer();
    final lookaheadLim = await AppStateService.instance.loadLookaheadLimiter();

    widget.player.set64BitProcessingEnabled(is64Bit);
    widget.player.setAutoSampleRateMatchEnabled(autoBp);
    widget.player.setLoudnessCrossfadeEnabled(loudnessCf);
    widget.player.setLoudnessNormalizerEnabled(loudnessNorm.enabled);
    widget.player.setLoudnessNormalizerTarget(loudnessNorm.targetLUFS);
    widget.player.setLookaheadLimiterEnabled(lookaheadLim.enabled);
    widget.player
        .setLookaheadLimiterParams(ceilingDBTP: lookaheadLim.ceilingDBTP);
    widget.player.setPhaseInversion(
      invertLeft: _phaseInvertLeft,
      invertRight: _phaseInvertRight,
    );
    widget.player.setLrSwap(_lrSwapEnabled);
    widget.player.setChannelGainsDb(
      leftDb: _channelGainLeftDb,
      rightDb: _channelGainRightDb,
    );
    widget.player.setOutputBuffer(
      periodFrames: _outputBufferFrames,
      periodCount: _outputBufferPeriods,
    );
    _applySpeakerProtectionSettings();

    if (Platform.isAndroid) {
      widget.player.getOutputBackend().then((bk) {
        if (mounted) setState(() => _selectedBackend = bk);
      });
      widget.player.getHardwareInfo().then((info) {
        if (mounted) {
          setState(() {
            _detectedDspHardware = info.dspHardware;
            //  _detectedSocModel = info.socName;
          });
        }
      });
    }
  }


  void _persistPhaseInversionSettings() {
    AppStateService.instance.savePhaseInversion(
      invertLeft: _phaseInvertLeft,
      invertRight: _phaseInvertRight,
    );
    widget.player.setPhaseInversion(
      invertLeft: _phaseInvertLeft,
      invertRight: _phaseInvertRight,
    );
  }

  void _persistChannelRoutingSettings() {
    AppStateService.instance.saveLrSwap(_lrSwapEnabled);
    AppStateService.instance.saveChannelGains(
      leftDb: _channelGainLeftDb,
      rightDb: _channelGainRightDb,
    );
    widget.player.setLrSwap(_lrSwapEnabled);
    widget.player.setChannelGainsDb(
      leftDb: _channelGainLeftDb,
      rightDb: _channelGainRightDb,
    );
  }

  void _persistSpeakerProtectionSettings() {
    AppStateService.instance.saveSpeakerProtection(
      enabled: _speakerProtectionEnabled,
      subsonicCutoffHz: _subsonicCutoffHz,
      ultrasonicCutoffHz: _ultrasonicCutoffHz,
      limiterThreshold: _limiterThreshold,
      safetyAttenuationDb: _safetyAttenuationDb,
    );
    _applySpeakerProtectionSettings();
  }

  void _applySpeakerProtectionSettings() {
    widget.player.setSpeakerProtectionParams(
      enabled: _speakerProtectionEnabled,
      subsonicCutoffHz: _subsonicCutoffHz,
      ultrasonicCutoffHz: _ultrasonicCutoffHz,
      limiterThreshold: _limiterThreshold,
      safetyAttenuationDb: _safetyAttenuationDb,
    );
  }


  void _persistUiSettings() {
    AppStateService.instance.saveUiSettings(
      streamingQuality: _streamingQuality,
      gaplessPlayback: _gaplessPlayback,
      normalizeVolume: _normalizeVolume,
      streamOverWifi: _streamOverWifi,
      resampleAlgorithm: _resampleAlgorithm,
      ditherMode: _ditherMode,
    );
  }

  String _formatAudioDepth(AudioFormat format) {
    switch (format) {
      case AudioFormat.f32:
        return '32 bit float';
      case AudioFormat.s32:
        return '32 bit';
      case AudioFormat.s24:
        return '24 bit';
      case AudioFormat.s16:
        return '16 bit';
      case AudioFormat.u8:
        return '8 bit';
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: _bgDark,
      body: LayoutBuilder(
        builder: (context, constraints) {
          final isDesktop = constraints.maxWidth >= 800;
          final isMobile = constraints.maxWidth < 600;
          return Align(
            alignment: Alignment.topCenter,
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 1000.0),
              child: CustomScrollView(
                slivers: [
                  SliverAppBar(
                    backgroundColor: _bgDark.withAlpha(230),
                    floating: true,
                    pinned: true,
                    title: const Text(
                      'Settings',
                      style:
                          TextStyle(fontWeight: FontWeight.bold, fontSize: 22),
                    ),
                    centerTitle: true,
                  ),
                  SliverPadding(
                    padding: EdgeInsets.symmetric(
                      horizontal: isDesktop ? 36.0 : (isMobile ? 12.0 : 16.0),
                      vertical: 12.0,
                    ),
                    sliver: SliverList(
                      delegate: SliverChildListDelegate([
                        //  _buildSettingsHeaderCard(),
                        const SizedBox(height: 20),
                        _buildSectionHeader('PREFERENCES'),
                        const SizedBox(height: 10),
                        M3ECardList(
                          itemCount: 9,
                          onTap: (index) {
                            switch (index) {
                              case 0:
                                _navigateToSubScreen(
                                    _buildLookAndFeelSubScreen());
                                break;
                              case 1:
                                _navigateToSubScreen(
                                    _buildAudioProcessingSubScreen());
                                break;
                              case 2:
                                _navigateToSubScreen(
                                    _buildEqualizerSubScreen());
                                break;
                              case 3:
                                _navigateToSubScreen(
                                    _buildVisualizationSubScreen());
                                break;
                              case 4:
                                _navigateToSubScreen(_buildPlaybackSubScreen());
                                break;
                              case 5:
                                _navigateToSubScreen(
                                    _buildDataAndStreamingSubScreen());
                                break;
                              case 6:
                                Navigator.push(
                                  context,
                                  MaterialPageRoute(
                                    builder: (context) => NetworkSourcesScreen(
                                      player: widget.player,
                                      onPlayNetworkFile:
                                          widget.onPlayNetworkFile,
                                      onPlayFtpFolder: widget.onPlayFtpFolder,
                                    ),
                                  ),
                                );
                                break;
                              case 7:
                                _navigateToSubScreen(_buildLastFmSubScreen());
                                break;
                              case 8:
                                _navigateToSubScreen(
                                    _buildMiscSystemSubScreen());
                                break;
                            }
                          },
                          itemBuilder: (context, index) {
                            switch (index) {
                              case 0:
                                return _buildCategoryCard(
                                  title: 'Look & Feel',
                                  subtitle: 'Theme, seek bar & UI appearance',
                                  icon: Icons.palette_outlined,
                                  accentColor: _primary,
                                  badgeText:
                                      AppThemeService.dataFor(_activeThemeId)
                                          .displayName,
                                  onTap: () => _navigateToSubScreen(
                                      _buildLookAndFeelSubScreen()),
                                );
                              case 1:
                                return _buildCategoryCard(
                                  title: 'Audio & Processing',
                                  subtitle:
                                      'Resampling, Bit depth & Hardware Safeguards',
                                  icon: Icons.graphic_eq_rounded,
                                  accentColor: _primary,
                                  badgeText: _getAudioProcessingBadgeText(),
                                  onTap: () => _navigateToSubScreen(
                                      _buildAudioProcessingSubScreen()),
                                );
                              case 2:
                                return _buildCategoryCard(
                                  title: 'Equalizer & DSP',
                                  subtitle:
                                      'Band configuration & Sauti DSP shortcuts',
                                  icon: Icons.tune_rounded,
                                  accentColor: _primary,
                                  badgeText: '$_eqBandCount-Band',
                                  onTap: () => _navigateToSubScreen(
                                      _buildEqualizerSubScreen()),
                                );
                              case 3:
                                return _buildCategoryCard(
                                  title: 'Visualization & RTA',
                                  subtitle:
                                      'Spectrum styles, FFT window & resolution, RTA monitoring',
                                  icon: Icons.bar_chart_rounded,
                                  accentColor: _primary,
                                  badgeText: widget.analyzerEnabled
                                      ? '${widget.spectrumStyle.toUpperCase()} • ${_getFftWindowDisplayName(widget.analyzerWindowType).toUpperCase()}'
                                      : 'Off',
                                  onTap: () => _navigateToSubScreen(
                                      _buildVisualizationSubScreen()),
                                );
                              case 4:
                                return _buildCategoryCard(
                                  title: 'Playback & Crossfade',
                                  subtitle:
                                      'Gapless mode, crossfade transitions & volume',
                                  icon: Icons.queue_music_rounded,
                                  accentColor: _primary,
                                  badgeText: widget.crossfadeEnabled
                                      ? '${(widget.crossfadeDurationMs / 1000).toStringAsFixed(1)}s'
                                      : 'Gapless',
                                  onTap: () => _navigateToSubScreen(
                                      _buildPlaybackSubScreen()),
                                );
                              case 5:
                                return _buildCategoryCard(
                                  title: 'Data & Streaming',
                                  subtitle:
                                      'Direct YouTube stream bitrates, AAC, backup fallback & cache',
                                  icon: Icons.stream_rounded,
                                  accentColor: _primary,
                                  badgeText: _getStreamingQualityBadgeText(),
                                  onTap: () => _navigateToSubScreen(
                                      _buildDataAndStreamingSubScreen()),
                                );
                              case 6:
                                return _buildCategoryCard(
                                  title: 'Network Sources (FTP & DLNA)',
                                  subtitle:
                                      'Browse FTP servers, DLNA NAS, and cast audio',
                                  icon: Icons.lan_rounded,
                                  accentColor: _primary,
                                  badgeText: 'FTP & DLNA',
                                  onTap: () {
                                    Navigator.push(
                                      context,
                                      MaterialPageRoute(
                                        builder: (context) =>
                                            NetworkSourcesScreen(
                                          player: widget.player,
                                          onPlayNetworkFile:
                                              widget.onPlayNetworkFile,
                                          onPlayFtpFolder:
                                              widget.onPlayFtpFolder,
                                        ),
                                      ),
                                    );
                                  },
                                );
                              case 7:
                                return AnimatedBuilder(
                                  animation: LastFmService.instance,
                                  builder: (context, _) {
                                    final lastFm = LastFmService.instance;
                                    return _buildCategoryCard(
                                      title: 'Last.fm Scrobbler',
                                      subtitle:
                                          'Now Playing updates & track scrobbling to Last.fm',
                                      icon: Icons.radio_rounded,
                                      accentColor: const Color(0xFFD51007),
                                      badgeText: lastFm.isLoggedIn
                                          ? (lastFm.username ?? 'Connected')
                                          : 'Not Connected',
                                      onTap: () => _navigateToSubScreen(
                                          _buildLastFmSubScreen()),
                                    );
                                  },
                                );
                              default:
                                return ListenableBuilder(
                                  listenable: AppUpdateService.instance,
                                  builder: (context, _) {
                                    final hasUpdate = AppUpdateService
                                                .instance.stage ==
                                            UpdateStage.available ||
                                        AppUpdateService.instance.stage ==
                                            UpdateStage.downloaded ||
                                        AppUpdateService.instance.stage ==
                                            UpdateStage.downloading;
                                    return _buildCategoryCard(
                                      title: 'Misc & System',
                                      subtitle:
                                          'Open source licenses, updates, TLS, diagnostic logs',
                                      icon: Icons.admin_panel_settings_outlined,
                                      accentColor:
                                          hasUpdate ? Colors.greenAccent : _primary,
                                      badgeText: hasUpdate
                                          ? 'UPDATE AVAILABLE'
                                          : _appVersion,
                                      onTap: () => _navigateToSubScreen(
                                          _buildMiscSystemSubScreen()),
                                    );
                                  },
                                );
                            }
                          },
                        ),
                        const SizedBox(height: 120),
                      ]),
                    ),
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  void _navigateToSubScreen(Widget subScreen) {
    Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => subScreen),
    );
  }

  Widget _buildSectionHeader(String title) {
    return AppSectionHeader(title);
  }

  Widget _buildCategoryCard({
    required String title,
    required String subtitle,
    required IconData icon,
    required Color accentColor,
    required String badgeText,
    required VoidCallback onTap,
  }) {
    return M3EListItem(
      headline: title,
      supportingText: subtitle,
      leading: /* M3EContainer(
        Shapes.pill,
        width: 44,
        height: 44,
        color: accentColor.withAlpha(30),
        border: BorderSide(color: accentColor.withAlpha(60), width: 1),
        child: 
        */
          Center(
        child: Icon(icon, color: accentColor, size: 22),
        //  ),
      ),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
            decoration: BoxDecoration(
              color: accentColor.withAlpha(25),
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: accentColor.withAlpha(60)),
            ),
            child: Text(
              badgeText,
              style: TextStyle(
                color: accentColor,
                fontSize: 12,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          const SizedBox(width: 8),
          Icon(Icons.chevron_right_rounded, color: _textDark, size: 22),
        ],
      ),
      onTap: onTap,
    );
  }

  // --- Sub-Screen Views ---

  Widget _buildSubScreenLayout({
    required String title,
    required List<Widget> children,
  }) {
    return AppSubScreenScaffold(
      title: title,
      children: children,
    );
  }

  Widget _buildCardContainer({required List<Widget> children}) {
    return AppCardContainer(children: children);
  }

  Widget _buildLeadingIcon(IconData icon, [Color? color]) {
    final c = color ?? _primary;
    return /* M3EContainer(
      Shapes.pill,
      width: 40,
      height: 40,
      color: c.withValues(alpha: 0.15),
      child: */
        Center(
      child: Icon(icon, color: c, size: 20),
      //   ),
    );
  }

  Widget _buildM3ESwitchTile({
    required String title,
    String? subtitle,
    Widget? secondary,
    required bool value,
    required ValueChanged<bool> onChanged,
  }) {
    return M3EListItem(
      headline: title,
      supportingText: subtitle,
      leading: secondary,
      trailing: M3ESwitch(
        value: value,
        onChanged: onChanged,
      ),
      onTap: () => onChanged(!value),
    );
  }

  // 1. Look & Feel Sub-Screen
  Widget _buildLookAndFeelSubScreen() {
    return StatefulBuilder(
      builder: (context, setSubState) {
        final appTheme = AppThemeProvider.of(context);
        final cardColor = appTheme.cardDark;
        final accent = appTheme.primary;
        final mutedText = appTheme.textDark;
        final isDarkTheme = appTheme.bgDark.computeLuminance() < 0.15;
        final textPrimaryColor =
            isDarkTheme ? Colors.white : const Color(0xFF1A1A2E);

        return _buildSubScreenLayout(
          title: 'Look & Feel',
          children: [
            // ── THEME SECTION ─────────────────────────────────────────────
            _buildSectionHeader('APP THEME'),
            const SizedBox(height: 12),
            Container(
              decoration: BoxDecoration(
                color: cardColor,
                borderRadius: BorderRadius.circular(20),
                border: Border.all(color: context.outlineColor),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Padding(
                    padding: const EdgeInsets.fromLTRB(20, 20, 20, 4),
                    child: Row(
                      children: [
                        Container(
                          padding: const EdgeInsets.all(10),
                          decoration: BoxDecoration(
                            color: accent.withAlpha(25),
                            shape: BoxShape.circle,
                          ),
                          child: Icon(Icons.palette_outlined,
                              color: accent, size: 20),
                        ),
                        const SizedBox(width: 14),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                'Color Theme',
                                style: TextStyle(
                                    color: textPrimaryColor,
                                    fontSize: 15,
                                    fontWeight: FontWeight.w600),
                              ),
                              const SizedBox(height: 2),
                              Text(
                                'Changes the theme colors',
                                style:
                                    TextStyle(color: mutedText, fontSize: 12),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 16),
                  SizedBox(
                    height: 130,
                    child: ListView.builder(
                      scrollDirection: Axis.horizontal,
                      padding: const EdgeInsets.symmetric(horizontal: 16),
                      itemCount: AppThemeService.themes.length,
                      itemBuilder: (context, index) {
                        final theme = AppThemeService.themes[index];
                        final isActive = _activeThemeId == theme.id;
                        final isItemDark =
                            theme.bgDark.computeLuminance() < 0.15;
                        return GestureDetector(
                          onTap: () {
                            AppThemeService.instance.saveTheme(theme.id);
                            setState(() {});
                            setSubState(() {});
                          },
                          child: AnimatedContainer(
                            duration: const Duration(milliseconds: 220),
                            curve: Curves.easeOutCubic,
                            width: 80,
                            margin:
                                const EdgeInsets.only(right: 12, bottom: 16),
                            decoration: BoxDecoration(
                              color: theme.bgDark,
                              borderRadius: BorderRadius.circular(16),
                              border: Border.all(
                                color: isActive
                                    ? theme.primary
                                    : (isItemDark
                                        ? Colors.white.withAlpha(18)
                                        : Colors.black.withAlpha(18)),
                                width: isActive ? 2.5 : 1.5,
                              ),
                              boxShadow: isActive
                                  ? [
                                      BoxShadow(
                                        color: theme.primary.withAlpha(80),
                                        blurRadius: 12,
                                        spreadRadius: 1,
                                      )
                                    ]
                                  : null,
                            ),
                            child: Column(
                              mainAxisAlignment: MainAxisAlignment.center,
                              children: [
                                // accent dot
                                Stack(
                                  alignment: Alignment.center,
                                  children: [
                                    Container(
                                      width: 40,
                                      height: 40,
                                      decoration: BoxDecoration(
                                        color: theme.cardDark,
                                        shape: BoxShape.circle,
                                        border: Border.all(
                                          color: theme.primary.withAlpha(80),
                                          width: 1.5,
                                        ),
                                      ),
                                      child: Center(
                                        child: Icon(
                                          theme.icon,
                                          color: theme.primary,
                                          size: 20,
                                        ),
                                      ),
                                    ),
                                    if (isActive)
                                      Positioned(
                                        right: 0,
                                        top: 0,
                                        child: Container(
                                          width: 16,
                                          height: 16,
                                          decoration: BoxDecoration(
                                            color: theme.primary,
                                            shape: BoxShape.circle,
                                            border: Border.all(
                                                color: theme.bgDark,
                                                width: 1.5),
                                          ),
                                          child: const Icon(
                                            Icons.check,
                                            color: Colors.white,
                                            size: 10,
                                          ),
                                        ),
                                      ),
                                  ],
                                ),
                                const SizedBox(height: 8),
                                Text(
                                  theme.displayName,
                                  style: TextStyle(
                                    color: isActive
                                        ? theme.primary
                                        : (isItemDark
                                            ? Colors.white70
                                            : Colors.black87),
                                    fontSize: 11,
                                    fontWeight: isActive
                                        ? FontWeight.w700
                                        : FontWeight.w400,
                                  ),
                                  textAlign: TextAlign.center,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ],
                            ),
                          ),
                        );
                      },
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 20),
            // ── NOW PLAYING ALBUM ART SHAPE SECTION ─────────────────────────
            _buildSectionHeader('NOW PLAYING ALBUM ART SHAPE'),
            const SizedBox(height: 12),
            AlbumArtShapeSelector(
              showLivePreview: true,
              onShapeSelected: (newShape) {
                setState(() {});
                setSubState(() {});
              },
            ),
            const SizedBox(height: 20),
            // ── SEEK BAR & SLIDER SECTION ─────────────────────────────────
            _buildSectionHeader('INTERFACE & SEEK BAR'),
            const SizedBox(height: 8),
            _buildCardContainer(
              children: [
                _buildM3ESwitchTile(
                  title: 'Waveform Seek Bar',
                  subtitle:
                      'Replaces classic time slider with interactive track amplitude waveform',
                  secondary: /*M3EContainer(
                    Shapes.pill,
                    width: 40,
                    height: 40,
                    color: _primary.withAlpha(25),
                    child: */
                      Center(
                    child: Icon(Icons.graphic_eq, color: _primary, size: 20),
                    //  ),
                  ),
                  value: _useWaveformSeekBar,
                  onChanged: (val) {
                    setState(() => _useWaveformSeekBar = val);
                    setSubState(() {});
                    AppStateService.instance.saveUseWaveformSeekBar(val);
                  },
                ),
                const Padding(
                  padding: EdgeInsets.symmetric(horizontal: 16.0),
                  child: M3EDivider(),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 14, 16, 16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          /* M3EContainer(
                            Shapes.pill,
                            width: 40,
                            height: 40,
                            color: _primary.withAlpha(25),
                            child: */
                          Center(
                            child: Icon(
                              _useWavySlider
                                  ? Icons.waves_rounded
                                  : Icons.linear_scale_rounded,
                              color: _primary,
                              size: 20,
                            ),
                            //  ),
                          ),
                          const SizedBox(width: 14),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  'Slider & Mini Player Style',
                                  style: TextStyle(
                                    color: textPrimaryColor,
                                    fontSize: 15,
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                                const SizedBox(height: 2),
                                Text(
                                  _useWavySlider
                                      ? 'M3E Linear Wavy travelling sine-wave (Now Playing & Mini Player)'
                                      : 'M3E Linear Regular straight track (Now Playing & Mini Player)',
                                  style: TextStyle(
                                    color: mutedText,
                                    fontSize: 12,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 14),
                      // Live interactive preview of the selected M3E Slider & Mini Player Progress
                      Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 14, vertical: 10),
                        decoration: BoxDecoration(
                          color: isDarkTheme
                              ? Colors.black.withAlpha(50)
                              : Colors.black.withAlpha(10),
                          borderRadius: BorderRadius.circular(14),
                          border: Border.all(
                            color: context.outlineColor.withAlpha(40),
                          ),
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            _useWavySlider
                                ? M3ESlider.wavy(
                                    value: _previewSliderValue,
                                    min: 0.0,
                                    max: 100.0,
                                    trackThickness: 8.0,
                                    cornerRadius: 8,
                                    thumbLength: 24.0,
                                    showValueIndicator: false,
                                    onChanged: (v) {
                                      setState(() => _previewSliderValue = v);
                                      setSubState(() {});
                                    },
                                  )
                                : M3ESlider(
                                    value: _previewSliderValue,
                                    min: 0.0,
                                    max: 100.0,
                                    trackThickness: 8.0,
                                    cornerRadius: 8,
                                    thumbLength: 24.0,
                                    showValueIndicator: false,
                                    onChanged: (v) {
                                      setState(() => _previewSliderValue = v);
                                      setSubState(() {});
                                    },
                                  ),
                            const SizedBox(height: 8),
                            ClipRRect(
                              borderRadius: BorderRadius.circular(4),
                              child: _useWavySlider
                                  ? M3EProgressIndicator.linearWavy(
                                      wavelength: 60,
                                      waveSpeed: 25,
                                      strokeWidth: 4,
                                      value: (_previewSliderValue / 100.0)
                                          .clamp(0.0, 1.0),
                                      linearSize: M3EProgressIndicatorSize.s,
                                      trackColor: Colors.white.withAlpha(20),
                                      color: _primary,
                                    )
                                  : M3EProgressIndicator.linear(
                                      value: (_previewSliderValue / 100.0)
                                          .clamp(0.0, 1.0),
                                      linearSize: M3EProgressIndicatorSize.s,
                                      trackColor: Colors.white.withAlpha(20),
                                      color: _primary,
                                    ),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(height: 14),
                      // M3E Segmented button selection
                      SizedBox(
                        width: double.infinity,
                        child: M3ESegmentedButton<bool>(
                          segments: const [
                            M3ESegment<bool>(
                              value: true,
                              label: 'Linear Wavy',
                              icon: Icon(Icons.waves_rounded, size: 18),
                            ),
                            M3ESegment<bool>(
                              value: false,
                              label: 'Linear Regular',
                              icon: Icon(Icons.linear_scale_rounded, size: 18),
                            ),
                          ],
                          selected: {_useWavySlider},
                          onSelectionChanged: (newSelection) {
                            if (newSelection.isNotEmpty) {
                              final isWavy = newSelection.first;
                              setState(() => _useWavySlider = isWavy);
                              setSubState(() {});
                              AppStateService.instance
                                  .saveUseWavySlider(isWavy);
                            }
                          },
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 20),
            _buildSectionHeader('ONBOARDING & FEATURE TOUR'),
            const SizedBox(height: 8),
            _buildCardContainer(
              children: [
                M3EListItem(
                  headline: 'Re-run Feature Tour',
                  supportingText:
                      'Re-start the interactive guided walkthrough for SautiPlay',
                  leading: /* M3EContainer(
                    Shapes.pill,
                    width: 40,
                    height: 40,
                    color: _primary.withAlpha(25),
                    child: */
                      Center(
                    child: Icon(Icons.tour_rounded, color: _primary, size: 20),
                    // ),
                  ),
                  trailing: Icon(Icons.play_arrow_rounded, color: _primary),
                  onTap: () {
                    Navigator.of(context).pop();
                    widget.onTriggerShowcase?.call();
                  },
                ),
              ],
            ),
          ],
        );
      },
    );
  }

  // 2. Audio & Processing Sub-Screen
  Widget _buildAudioProcessingSubScreen() {
    return StatefulBuilder(
      builder: (context, setSubState) {
        return _buildSubScreenLayout(
          title: 'Audio & Processing',
          children: [
            _buildSectionHeader('DIAGNOSTICS & TELEMETRY'),
            const SizedBox(height: 8),
            _buildCardContainer(
              children: [
                M3EListItem(
                  headline: 'Audio Engine Diagnostic Panel',
                  supportingText:
                      'Real-time telemetry, PDC latency & "Why is this track resampled?" explainer',
                  leading: _buildLeadingIcon(Icons.monitor_heart_outlined),
                  trailing: const Icon(Icons.chevron_right_rounded,
                      color: Colors.cyanAccent, size: 22),
                  onTap: () {
                    showAudioEngineDiagnosticPanel(context, widget.player);
                  },
                ),
              ],
            ),
            const SizedBox(height: 20),
            _buildSectionHeader('RESAMPLING & DITHERING'),
            const SizedBox(height: 8),
            _buildCardContainer(
              children: [
                M3EListItem(
                  headline: 'Resampler',
                  supportingText:
                      _getResampleAlgorithmSupportingText(_resampleAlgorithm),
                  leading: _buildLeadingIcon(Icons.memory),
                  trailing: SizedBox(
                    width: 170,
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.end,
                      children: [
                        Expanded(
                          child: Text(
                            _getResampleAlgorithmShortName(_resampleAlgorithm),
                            style: TextStyle(color: _textDark, fontSize: 13),
                            textAlign: TextAlign.right,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        const SizedBox(width: 8),
                        Icon(Icons.chevron_right, color: _textDark, size: 20),
                      ],
                    ),
                  ),
                  onTap: () => _showResampleAlgorithmDialog(
                      onDone: () => setSubState(() {})),
                ),
                const M3EDivider(),
                M3EListItem(
                  headline: 'Oversampler',
                  supportingText: 'Anti-aliasing for DSP',
                  leading: _buildLeadingIcon(Icons.blur_on),
                  trailing: SizedBox(
                    width: 150,
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.end,
                      children: [
                        Expanded(
                          child: Text(
                            _getOversamplingName(_dspOversampling),
                            style: TextStyle(color: _textDark, fontSize: 13),
                            textAlign: TextAlign.right,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        const SizedBox(width: 8),
                        Icon(Icons.chevron_right, color: _textDark, size: 20),
                      ],
                    ),
                  ),
                  onTap: () =>
                      _showOversamplingDialog(onDone: () => setSubState(() {})),
                ),
                const M3EDivider(),
                M3EListItem(
                  headline: 'Dither',
                  leading: _buildLeadingIcon(Icons.waves),
                  trailing: SizedBox(
                    width: 150,
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.end,
                      children: [
                        Expanded(
                          child: Text(
                            _getDitherModeName(_ditherMode),
                            style: TextStyle(color: _textDark, fontSize: 13),
                            textAlign: TextAlign.right,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        const SizedBox(width: 8),
                        Icon(Icons.chevron_right, color: _textDark, size: 20),
                      ],
                    ),
                  ),
                  onTap: () =>
                      _showDitherModeDialog(onDone: () => setSubState(() {})),
                ),
              ],
            ),
            const SizedBox(height: 20),
            _buildSectionHeader('HARDWARE OUTPUT'),
            const SizedBox(height: 8),
            _buildCardContainer(
              children: [
                M3EListItem(
                  headline: 'Output Bit Depth',
                  supportingText: 'Audio precision',
                  leading: _buildLeadingIcon(Icons.code),
                  trailing: SizedBox(
                    width: 150,
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.end,
                      children: [
                        Expanded(
                          child: Text(
                            _formatAudioDepth(widget.outputFormat),
                            style: TextStyle(color: _textDark, fontSize: 13),
                            textAlign: TextAlign.right,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        const SizedBox(width: 8),
                        Icon(Icons.chevron_right, color: _textDark, size: 20),
                      ],
                    ),
                  ),
                  onTap: () =>
                      _showOutputFormatDialog(onDone: () => setSubState(() {})),
                ),
                const M3EDivider(),
                IgnorePointer(
                  ignoring: _autoBitPerfectEnabled,
                  child: AnimatedOpacity(
                    opacity: _autoBitPerfectEnabled ? 0.38 : 1.0,
                    duration: const Duration(milliseconds: 200),
                    child: M3EListItem(
                      headline: 'Sample Rate',
                      supportingText:
                          _autoBitPerfectEnabled ? 'Auto Bit-Perfect' : null,
                      leading: _buildLeadingIcon(Icons.speed),
                      trailing: SizedBox(
                        width: 150,
                        child: Row(
                          mainAxisAlignment: MainAxisAlignment.end,
                          children: [
                            Expanded(
                              child: Text(
                                widget.outputSampleRate == 0
                                    ? 'Native'
                                    : '${widget.outputSampleRate} Hz',
                                style:
                                    TextStyle(color: _textDark, fontSize: 13),
                                textAlign: TextAlign.right,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                            const SizedBox(width: 8),
                            Icon(Icons.chevron_right,
                                color: _textDark, size: 20),
                          ],
                        ),
                      ),
                      onTap: () => _showSampleRateDialog(
                          onDone: () => setSubState(() {})),
                    ),
                  ),
                ),
                const M3EDivider(),
                M3EListItem(
                  headline: 'Output Channels',
                  leading: _buildLeadingIcon(Icons.speaker_group),
                  trailing: SizedBox(
                    width: 150,
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.end,
                      children: [
                        Expanded(
                          child: Text(
                            _formatChannelCount(widget.outputChannels),
                            style: TextStyle(color: _textDark, fontSize: 13),
                            textAlign: TextAlign.right,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        const SizedBox(width: 8),
                        Icon(Icons.chevron_right, color: _textDark, size: 20),
                      ],
                    ),
                  ),
                  onTap: () =>
                      _showChannelsDialog(onDone: () => setSubState(() {})),
                ),
                const M3EDivider(),
                M3EListItem(
                  headline: 'Output Buffer & Latency',
                  supportingText:
                      'Hardware period buffer frame size and periods',
                  leading: _buildLeadingIcon(Icons.av_timer_rounded),
                  trailing: SizedBox(
                    width: 160,
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.end,
                      children: [
                        Expanded(
                          child: Text(
                            _formatOutputBuffer(
                                _outputBufferFrames, _outputBufferPeriods),
                            style: TextStyle(color: _textDark, fontSize: 13),
                            textAlign: TextAlign.right,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        const SizedBox(width: 8),
                        Icon(Icons.chevron_right, color: _textDark, size: 20),
                      ],
                    ),
                  ),
                  onTap: () =>
                      _showOutputBufferDialog(onDone: () => setSubState(() {})),
                ),
                const M3EDivider(),
                Padding(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          _buildLeadingIcon(Icons.swap_calls),
                          const SizedBox(width: 16),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  'Phase Inversion (180°)',
                                  style: TextStyle(
                                      color: _textPrimary,
                                      fontWeight: FontWeight.w500),
                                ),
                                const SizedBox(height: 2),
                                Text(
                                  'Invert polarity',
                                  style:
                                      TextStyle(color: _textDark, fontSize: 12),
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 12),
                      Row(
                        children: [
                          Expanded(
                            child: _buildM3ESwitchTile(
                              title: 'Left Phase 180°',
                              value: _phaseInvertLeft,
                              onChanged: (val) {
                                setState(() => _phaseInvertLeft = val);
                                _persistPhaseInversionSettings();
                                setSubState(() {});
                              },
                            ),
                          ),
                          Expanded(
                            child: _buildM3ESwitchTile(
                              title: 'Right Phase 180°',
                              value: _phaseInvertRight,
                              onChanged: (val) {
                                setState(() => _phaseInvertRight = val);
                                _persistPhaseInversionSettings();
                                setSubState(() {});
                              },
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
                const M3EDivider(),
                _buildM3ESwitchTile(
                  title: 'Swap Channels', //swap horizon
                  subtitle: _lrSwapEnabled
                      ? 'Left and right outputs are swapped'
                      : 'Mirror left and right audio channels',
                  secondary: _buildLeadingIcon(
                    Icons.swap_horiz_rounded,
                    _lrSwapEnabled ? _primary : _textDark,
                  ),
                  value: _lrSwapEnabled,
                  onChanged: (val) {
                    setState(() => _lrSwapEnabled = val);
                    _persistChannelRoutingSettings();
                    setSubState(() {});
                  },
                ),
                const M3EDivider(),
                Padding(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          _buildLeadingIcon(Icons.tune_rounded),
                          const SizedBox(width: 16),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  'Per-Channel Gain',
                                  style: TextStyle(
                                      color: _textPrimary,
                                      fontWeight: FontWeight.w500),
                                ),
                                const SizedBox(height: 2),
                                Text(
                                  'Independent L/R trim (\u221212\u202fdB to +12\u202fdB)', //
                                  style:
                                      TextStyle(color: _textDark, fontSize: 12),
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 16),
                      // Left channel slider
                      Row(
                        children: [
                          SizedBox(
                            width: 28,
                            child: Text('L',
                                style: TextStyle(
                                    color: _primary,
                                    fontWeight: FontWeight.bold,
                                    fontSize: 13)),
                          ),
                          Expanded(
                            child: M3ESlider(
                              min: -12,
                              max: 12,
                              divisions: 48,
                              value: _channelGainLeftDb,
                              onChanged: (val) {
                                setState(() => _channelGainLeftDb =
                                    double.parse(val.toStringAsFixed(1)));
                              },
                              onChangeEnd: (_) {
                                _persistChannelRoutingSettings();
                                setSubState(() {});
                              },
                            ),
                          ),
                          SizedBox(
                            width: 52,
                            child: Text(
                              _channelGainLeftDb == 0.0
                                  ? '0\u202fdB'
                                  : '${_channelGainLeftDb > 0 ? '+' : ''}${_channelGainLeftDb.toStringAsFixed(1)}\u202fdB',
                              style: TextStyle(
                                  color: _channelGainLeftDb == 0.0
                                      ? _textDark
                                      : _primary,
                                  fontSize: 12,
                                  fontWeight: _channelGainLeftDb == 0.0
                                      ? FontWeight.normal
                                      : FontWeight.bold),
                              textAlign: TextAlign.right,
                            ),
                          ),
                        ],
                      ),
                      // Right channel slider
                      Row(
                        children: [
                          SizedBox(
                            width: 28,
                            child: Text('R',
                                style: TextStyle(
                                    color: Colors.deepOrangeAccent,
                                    fontWeight: FontWeight.bold,
                                    fontSize: 13)),
                          ),
                          Expanded(
                            child: M3ESlider(
                              min: -12,
                              max: 12,
                              divisions: 48,
                              value: _channelGainRightDb,
                              onChanged: (val) {
                                setState(() => _channelGainRightDb =
                                    double.parse(val.toStringAsFixed(1)));
                              },
                              onChangeEnd: (_) {
                                _persistChannelRoutingSettings();
                                setSubState(() {});
                              },
                            ),
                          ),
                          SizedBox(
                            width: 52,
                            child: Text(
                              _channelGainRightDb == 0.0
                                  ? '0\u202fdB'
                                  : '${_channelGainRightDb > 0 ? '+' : ''}${_channelGainRightDb.toStringAsFixed(1)}\u202fdB',
                              style: TextStyle(
                                  color: _channelGainRightDb == 0.0
                                      ? _textDark
                                      : Colors.deepOrangeAccent,
                                  fontSize: 12,
                                  fontWeight: _channelGainRightDb == 0.0
                                      ? FontWeight.normal
                                      : FontWeight.bold),
                              textAlign: TextAlign.right,
                            ),
                          ),
                        ],
                      ),
                      // Reset button
                      if (_channelGainLeftDb != 0.0 ||
                          _channelGainRightDb != 0.0)
                        Align(
                          alignment: Alignment.centerRight,
                          child: M3EButton.icon(
                            onPressed: () {
                              setState(() {
                                _channelGainLeftDb = 0.0;
                                _channelGainRightDb = 0.0;
                              });
                              _persistChannelRoutingSettings();
                              setSubState(() {});
                            },
                            icon: Icon(Icons.restart_alt_rounded,
                                color: _textDark, size: 16),
                            label: Text('Reset to 0\u202fdB',
                                style:
                                    TextStyle(color: _textDark, fontSize: 12)),
                          ),
                        ),
                    ],
                  ),
                ),
                const M3EDivider(),
                IgnorePointer(
                  ignoring: _autoBitPerfectEnabled,
                  child: AnimatedOpacity(
                    opacity: _autoBitPerfectEnabled ? 0.38 : 1.0,
                    duration: const Duration(milliseconds: 200),
                    child: _buildM3ESwitchTile(
                      title: 'Bit-Perfect Playback',
                      subtitle: _autoBitPerfectEnabled
                          ? 'Managed automatically (Auto Sample-Rate Match is on)'
                          : 'Bypasses OS Mixer',
                      secondary: _buildLeadingIcon(Icons.verified),
                      value: widget.exclusiveMode,
                      onChanged: (val) async {
                        widget.player.setExclusiveMode(val);
                        await Future.delayed(const Duration(milliseconds: 150));
                        final actual = await widget.player.getExclusiveMode();
                        widget.onExclusiveModeChanged(actual);
                        setSubState(() {});
                        if (!context.mounted) return;
                        ScaffoldMessenger.of(context).hideCurrentSnackBar();
                        if (val && actual) {
                          ScaffoldMessenger.of(context).showSnackBar(
                            SnackBar(
                              backgroundColor: _cardDark,
                              behavior: SnackBarBehavior.floating,
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(12),
                                side: BorderSide(
                                    color: Colors.greenAccent.withAlpha(120)),
                              ),
                              content: Row(
                                children: [
                                  const Icon(Icons.verified_rounded,
                                      color: Colors.greenAccent, size: 20),
                                  const SizedBox(width: 12),
                                  Expanded(
                                    child: Text(
                                      'Bit-Perfect Mode Accepted',
                                      style: TextStyle(
                                          color: _textPrimary, fontSize: 13),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          );
                        } else if (val && !actual) {
                          ScaffoldMessenger.of(context).showSnackBar(
                            SnackBar(
                              backgroundColor: _cardDark,
                              behavior: SnackBarBehavior.floating,
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(12),
                                side: BorderSide(
                                    color: Colors.amberAccent.withAlpha(120)),
                              ),
                              content: Row(
                                children: [
                                  const Icon(Icons.warning_amber_rounded,
                                      color: Colors.amberAccent, size: 20),
                                  const SizedBox(width: 12),
                                  Expanded(
                                    child: Text(
                                      'Hardware declined Exclusive Mode. Falling back to Shared Mixer!',
                                      style: TextStyle(
                                          color: _textPrimary, fontSize: 13),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          );
                        } else {
                          ScaffoldMessenger.of(context).showSnackBar(
                            SnackBar(
                              backgroundColor: _cardDark,
                              behavior: SnackBarBehavior.floating,
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(12),
                                side: BorderSide(color: context.outlineColor),
                              ),
                              content: Row(
                                children: [
                                  Icon(Icons.info_outline,
                                      color: _textDark, size: 20),
                                  const SizedBox(width: 12),
                                  Expanded(
                                    child: Text(
                                      'Bit-Perfect Exclusive Mode Disabled (Shared Mixer)',
                                      style: TextStyle(
                                          color: _textPrimary, fontSize: 13),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          );
                        }
                      },
                    ),
                  ),
                ),
                const M3EDivider(),
                _buildM3ESwitchTile(
                  title: '64-Bit Float DSP',
                  subtitle: 'Higher accuracy (more power consumption)',
                  secondary: _buildLeadingIcon(Icons.architecture),
                  value: _use64BitProcessingEnabled,
                  onChanged: (val) {
                    setState(() => _use64BitProcessingEnabled = val);
                    widget.player.set64BitProcessingEnabled(val);
                    AppStateService.instance.save64BitProcessingEnabled(val);
                    setSubState(() {});
                  },
                ),
                const M3EDivider(),
                _buildM3ESwitchTile(
                  title: 'Auto Sample-Rate',
                  subtitle: 'Sync audio to track rate (Recommended)',
                  secondary: _buildLeadingIcon(Icons.graphic_eq),
                  value: _autoBitPerfectEnabled,
                  onChanged: (val) {
                    setState(() => _autoBitPerfectEnabled = val);
                    widget.player.setAutoSampleRateMatchEnabled(val);
                    AppStateService.instance.saveAutoBitPerfectEnabled(val);
                    setSubState(() {});
                    if (!context.mounted) return;
                    ScaffoldMessenger.of(context).hideCurrentSnackBar();
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(
                        backgroundColor: _cardDark,
                        behavior: SnackBarBehavior.floating,
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12),
                          side: BorderSide(
                            color: val
                                ? Colors.greenAccent.withAlpha(120)
                                : context.outlineColor,
                          ),
                        ),
                        content: Row(
                          children: [
                            Icon(
                              val ? Icons.graphic_eq : Icons.info_outline,
                              color: val ? Colors.greenAccent : _textDark,
                              size: 20,
                            ),
                            const SizedBox(width: 12),
                            Expanded(
                              child: Text(
                                val
                                    ? 'Auto Sample-Rate Match Active'
                                    : 'Auto Sample-Rate Match Disabled',
                                style: TextStyle(
                                    color: _textPrimary, fontSize: 13),
                              ),
                            ),
                          ],
                        ),
                      ),
                    );
                  },
                ),
                if (Platform.isAndroid) ...[
                  const M3EDivider(),
                  M3EListItem(
                    headline: 'Android Output Backend',
                    supportingText: _selectedBackend.displayName,
                    leading: _buildLeadingIcon(Icons.developer_board_rounded),
                    trailing:
                        Icon(Icons.chevron_right_rounded, color: _textDark),
                    onTap: () =>
                        _showAndroidBackendPicker(context, setSubState),
                  ),
                  if (_detectedDspHardware.isNotEmpty) ...[
                    const M3EDivider(),
                    M3EListItem(
                      headline: 'Hardware Variant',
                      supportingText: [
                        if (_detectedDspHardware.isNotEmpty)
                          _detectedDspHardware,
                      ].join(' • '),
                      leading: _buildLeadingIcon(Icons.memory_rounded),
                    ),
                  ],
                ],
              ],
            ),
            const SizedBox(height: 20),
            _buildSectionHeader('HARDWARE PROTECTION'),
            const SizedBox(height: 8),
            _buildCardContainer(
              children: [
                _buildM3ESwitchTile(
                  title: 'Hardware Safeguards',
                  subtitle: _speakerProtectionEnabled
                      ? 'Peak ceiling & subsonic/ultrasonic guard active'
                      : 'Hardware protection disabled',
                  secondary: _buildLeadingIcon(
                    _speakerProtectionEnabled
                        ? Icons.health_and_safety
                        : Icons.warning_amber_rounded,
                    _speakerProtectionEnabled ? _primary : Colors.amberAccent,
                  ),
                  value: _speakerProtectionEnabled,
                  onChanged: (val) {
                    setState(() => _speakerProtectionEnabled = val);
                    setSubState(() {});
                    _persistSpeakerProtectionSettings();
                  },
                ),
                if (_speakerProtectionEnabled) ...[
                  const M3EDivider(),
                  M3EListItem(
                    headline: 'Subsonic Filter',
                    supportingText: 'Below woofer tuning',
                    leading: _buildLeadingIcon(Icons.arrow_upward),
                    trailing: SizedBox(
                      width: 130,
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.end,
                        children: [
                          Expanded(
                            child: Text(
                              _subsonicCutoffHz <= 0
                                  ? 'Off'
                                  : '${_subsonicCutoffHz.toInt()} Hz',
                              style: TextStyle(color: _textDark, fontSize: 13),
                              textAlign: TextAlign.right,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                          const SizedBox(width: 8),
                          Icon(Icons.chevron_right, color: _textDark, size: 20),
                        ],
                      ),
                    ),
                    onTap: () =>
                        _showSubsonicDialog(onDone: () => setSubState(() {})),
                  ),
                  const M3EDivider(),
                  M3EListItem(
                    headline: 'Ultrasonic Guard (Low-Pass)',
                    supportingText: 'Filters frequencies above 18-22kHz',
                    leading: _buildLeadingIcon(Icons.keyboard_arrow_down),
                    trailing: SizedBox(
                      width: 130,
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.end,
                        children: [
                          Expanded(
                            child: Text(
                              _ultrasonicCutoffHz >= 24000
                                  ? 'Off'
                                  : '${(_ultrasonicCutoffHz / 1000).toStringAsFixed(1)} kHz',
                              style: TextStyle(color: _textDark, fontSize: 13),
                              textAlign: TextAlign.right,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                          const SizedBox(width: 8),
                          Icon(Icons.chevron_right, color: _textDark, size: 20),
                        ],
                      ),
                    ),
                    onTap: () =>
                        _showUltrasonicDialog(onDone: () => setSubState(() {})),
                  ),
                  const M3EDivider(),
                  Padding(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 20, vertical: 16),
                    child: Row(
                      children: [
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text('Peak Ceiling',
                                  style: TextStyle(
                                      color: _textPrimary,
                                      fontWeight: FontWeight.w500)),
                              const SizedBox(height: 2),
                              Text(
                                'Max: ${(_limiterThreshold * 100).toInt()}% (${(20 * math.log(_limiterThreshold) / math.ln10).toStringAsFixed(2)} dBFS)',
                                style:
                                    TextStyle(color: _textDark, fontSize: 12),
                              ),
                            ],
                          ),
                        ),
                        SizedBox(
                          width: 90,
                          child: ModernAudioKnob(
                            label: 'CEILING',
                            value: _limiterThreshold,
                            min: 0.70,
                            max: 1.00,
                            activeColor: _primary,
                            valueFormatter: (v) => '${(v * 100).toInt()}%',
                            onChanged: (val) {
                              setState(() => _limiterThreshold = val);
                              setSubState(() {});
                              _persistSpeakerProtectionSettings();
                            },
                          ),
                        ),
                      ],
                    ),
                  ),
                  const M3EDivider(),
                  Padding(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 20, vertical: 16),
                    child: Row(
                      children: [
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text('Safety Headroom',
                                  style: TextStyle(
                                      color: _textPrimary,
                                      fontWeight: FontWeight.w500)),
                              const SizedBox(height: 2),
                              Text('Output level attenuation buffer',
                                  style: TextStyle(
                                      color: _textDark, fontSize: 12)),
                            ],
                          ),
                        ),
                        SizedBox(
                          width: 90,
                          child: ModernAudioKnob(
                            label: 'SAFETY',
                            value: _safetyAttenuationDb,
                            min: -6.0,
                            max: 0.0,
                            activeColor: _primary,
                            valueFormatter: (v) => '${v.toStringAsFixed(1)} dB',
                            onChanged: (val) {
                              setState(() => _safetyAttenuationDb = val);
                              setSubState(() {});
                              _persistSpeakerProtectionSettings();
                            },
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ],
            ),
          ],
        );
      },
    );
  }

  // 3. Equalizer Sub-Screen
  Widget _buildEqualizerSubScreen() {
    return StatefulBuilder(
      builder: (context, setSubState) {
        return _buildSubScreenLayout(
          title: 'Equalizer & DSP',
          children: [
            _buildSectionHeader('GRAPHIC EQUALIZER BANDS'),
            const SizedBox(height: 8),
            _buildCardContainer(
              children: [
                Padding(
                  padding: const EdgeInsets.all(20.0),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          _buildLeadingIcon(Icons.settings_input_composite),
                          const SizedBox(width: 16),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text('Frequency Precision',
                                    style: TextStyle(
                                        color: _textPrimary,
                                        fontSize: 16,
                                        fontWeight: FontWeight.w500)),
                                const SizedBox(height: 4),
                                Text('Choose total active EQ bands',
                                    style: TextStyle(
                                        color: _textDark, fontSize: 13)),
                              ],
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 20),
                      SizedBox(
                        width: double.infinity,
                        child: M3ESegmentedButton<int>(
                          segments: const [
                            M3ESegment<int>(
                              value: 10,
                              label: '10-Band',
                              icon: Icon(Icons.graphic_eq_rounded, size: 16),
                            ),
                            M3ESegment<int>(
                              value: 16,
                              label: '16-Band',
                              icon: Icon(Icons.equalizer_rounded, size: 16),
                            ),
                            M3ESegment<int>(
                              value: 32,
                              label: '32-Band',
                              icon: Icon(Icons.tune_rounded, size: 16),
                            ),
                          ],
                          selected: {_eqBandCount},
                          onSelectionChanged: (newSelection) async {
                            if (newSelection.isNotEmpty) {
                              final count = newSelection.first;
                              setState(() => _eqBandCount = count);
                              setSubState(() {});
                              final state =
                                  await AppStateService.instance.loadEqBands();
                              await AppStateService.instance.saveEqBands(
                                enabled: state.enabled,
                                preset: state.preset,
                                gains: List.filled(count, 0.0),
                                preampDb: state.preampDb,
                                bandCount: count,
                              );
                            }
                          },
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ],
        );
      },
    );
  }

  // 4. Visualization Sub-Screen
  Widget _buildVisualizationSubScreen() {
    return StatefulBuilder(
      builder: (context, setSubState) {
        final isArea = widget.analyzerType == 'area';
        final activeStyleName = widget.spectrumStyle.toLowerCase();

        return _buildSubScreenLayout(
          title: 'Visualization & RTA',
          children: [
            // ── TOP LIVE RTA & RMS LOUDNESS CARD ────────────────────────────
            _buildSectionHeader('REAL-TIME AUDIO & RMS LOUDNESS'),
            const SizedBox(height: 8),
            AppCardContainer(
              padding: const EdgeInsets.all(16.0),
              children: [
                Row(
                  children: [
                    AppShapeIcon(
                      Icons.speed_rounded,
                      shape: Shapes.pill,
                      color: widget.analyzerEnabled ? _primary : _textDark,
                      size: 38,
                      iconSize: 20,
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            'RTA RMS Loudness',
                            style: TextStyle(
                              color: _textPrimary,
                              fontSize: 15,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                          const SizedBox(height: 2),
                          Text(
                            widget.analyzerEnabled
                                ? (_isPlaying
                                    ? 'Real-Time RMS & Peak Level Monitoring'
                                    : 'Awaiting Audio Playback')
                                : 'Level Meter Bypassed',
                            style: TextStyle(
                              color: _textDark,
                              fontSize: 12,
                            ),
                          ),
                        ],
                      ),
                    ),
                    AppStatusBadge(
                      text: widget.analyzerEnabled
                          ? '${_isPlaying ? "ACTIVE" : "STANDBY"} • ${_getFftWindowDisplayName(widget.analyzerWindowType).toUpperCase()}'
                          : 'BYPASSED',
                      color: widget.analyzerEnabled ? _primary : _textDark,
                    ),
                  ],
                ),
                const SizedBox(height: 16),
                Container(
                  decoration: BoxDecoration(
                    color: context.bgDark.withValues(alpha: 0.6),
                    borderRadius: BorderRadius.circular(16),
                    border: Border.all(
                      color: widget.analyzerEnabled
                          ? _primary.withValues(alpha: 0.25)
                          : context.outlineColor,
                    ),
                  ),
                  clipBehavior: Clip.antiAlias,
                  padding: const EdgeInsets.symmetric(
                      horizontal: 12.0, vertical: 12.0),
                  child: widget.analyzerEnabled
                      ? RmsMeterWidget(
                          analyzerStream: widget.player.analyzerStream,
                          isPlaying: _isPlaying,
                        )
                      : Container(
                          height: 52,
                          alignment: Alignment.center,
                          child: Row(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              Icon(
                                Icons.graphic_eq_rounded,
                                color: _textDark.withValues(alpha: 0.4),
                                size: 22,
                              ),
                              const SizedBox(width: 8),
                              Text(
                                'Audio loudness meter is paused & bypassed',
                                style: TextStyle(
                                  color: _textDark,
                                  fontSize: 13,
                                ),
                              ),
                            ],
                          ),
                        ),
                ),
              ],
            ),

            const SizedBox(height: 20),

            // ── SPECTRUM ENGINE & RENDERING CARD ──────────────────────────
            _buildSectionHeader('SPECTRUM ENGINE & RENDERING'),
            const SizedBox(height: 8),
            _buildCardContainer(
              children: [
                _buildM3ESwitchTile(
                  title: 'Spectrum Analyzer Engine',
                  subtitle: 'Real-time native FFT frequency spectrum analyzer',
                  secondary: _buildLeadingIcon(Icons.bar_chart_rounded),
                  value: widget.analyzerEnabled,
                  onChanged: (v) {
                    widget.onAnalyzerEnabledChanged(v);
                    setSubState(() {});
                  },
                ),
                if (widget.analyzerEnabled) ...[
                  const M3EDivider(),
                  Padding(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 20.0, vertical: 16.0),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [
                            Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  'Rendering Mode',
                                  style: TextStyle(
                                    color: _textPrimary,
                                    fontSize: 15,
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                                const SizedBox(height: 2),
                                Text(
                                  'Discrete frequency bars or continuous area curve',
                                  style:
                                      TextStyle(color: _textDark, fontSize: 12),
                                ),
                              ],
                            ),
                          ],
                        ),
                        const SizedBox(height: 14),
                        SizedBox(
                          width: double.infinity,
                          child: M3ESegmentedButton<String>(
                            segments: const [
                              M3ESegment(
                                value: 'bar',
                                label: 'Bar Spectrum',
                                icon: Icon(Icons.bar_chart_rounded, size: 18),
                              ),
                              M3ESegment(
                                value: 'area',
                                label: 'Area Curve',
                                icon: Icon(Icons.show_chart_rounded, size: 18),
                              ),
                            ],
                            selected: {isArea ? 'area' : 'bar'},
                            onSelectionChanged: (val) {
                              if (val.isNotEmpty) {
                                widget.onAnalyzerTypeChanged(val.first);
                                setSubState(() {});
                              }
                            },
                          ),
                        ),
                      ],
                    ),
                  ),
                  const M3EDivider(),
                  Padding(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 20.0, vertical: 16.0),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Visual Theme',
                          style: TextStyle(
                            color: _textPrimary,
                            fontSize: 15,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          'Color gradient palette and bar styling preset',
                          style: TextStyle(color: _textDark, fontSize: 12),
                        ),
                        const SizedBox(height: 14),
                        SizedBox(
                          width: double.infinity,
                          child: M3ESegmentedButton<String>(
                            segments: const [
                              M3ESegment(
                                value: 'neon',
                                label: 'Neon',
                                icon:
                                    Icon(Icons.auto_awesome_rounded, size: 16),
                              ),
                              M3ESegment(
                                value: 'fire',
                                label: 'Fire',
                                icon: Icon(Icons.local_fire_department_rounded,
                                    size: 16),
                              ),
                              M3ESegment(
                                value: 'minimal',
                                label: 'Minimal',
                                icon: Icon(Icons.horizontal_rule_rounded,
                                    size: 16),
                              ),
                              M3ESegment(
                                value: 'pill',
                                label: 'Pill',
                                icon: Icon(Icons.lens_blur_rounded, size: 16),
                              ),
                            ],
                            selected: {
                              ['neon', 'fire', 'minimal', 'pill']
                                      .contains(activeStyleName)
                                  ? activeStyleName
                                  : 'minimal'
                            },
                            onSelectionChanged: (val) {
                              if (val.isNotEmpty) {
                                widget.onSpectrumStyleChanged(val.first);
                                setSubState(() {});
                              }
                            },
                          ),
                        ),
                      ],
                    ),
                  ),
                  const M3EDivider(),
                  Padding(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 20.0, vertical: 14.0),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              'Visualizer Presets',
                              style: TextStyle(
                                color: _textPrimary,
                                fontSize: 14,
                                fontWeight: FontWeight.w500,
                              ),
                            ),
                            const SizedBox(height: 2),
                            Text(
                              'Quick 1-tap curated configurations',
                              style: TextStyle(color: _textDark, fontSize: 12),
                            ),
                          ],
                        ),
                        M3EMenu(
                          anchorBuilder: (context, open) => M3EButton.icon(
                            onPressed: open,
                            icon: const Icon(Icons.auto_fix_high_rounded,
                                size: 16),
                            label: const Text('Presets'),
                          ),
                          children: [
                            M3EMenuGroup.entries(
                              entries: [
                                M3EMenuEntry(
                                  label: 'Balanced (Bar • Neon • 1024)',
                                  leading: const Icon(Icons.bar_chart_rounded,
                                      size: 18),
                                  onPressed: () => _applyVisualizerPreset(
                                      'balanced', setSubState),
                                ),
                                M3EMenuEntry(
                                  label: 'Smooth Curve (Area • Fire • 2048)',
                                  leading: const Icon(Icons.show_chart_rounded,
                                      size: 18),
                                  onPressed: () => _applyVisualizerPreset(
                                      'smooth_curve', setSubState),
                                ),
                                M3EMenuEntry(
                                  label: 'Audiophile (Bar • Pill • 4096)',
                                  leading: const Icon(Icons.lens_blur_rounded,
                                      size: 18),
                                  onPressed: () => _applyVisualizerPreset(
                                      'audiophile_precision', setSubState),
                                ),
                                M3EMenuEntry(
                                  label: 'Minimalist (Area • Minimal • 512)',
                                  leading: const Icon(
                                      Icons.horizontal_rule_rounded,
                                      size: 18),
                                  onPressed: () => _applyVisualizerPreset(
                                      'minimalist', setSubState),
                                ),
                              ],
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                ],
              ],
            ),

            const SizedBox(height: 20),

            // ── SCALING & GRID DYNAMICS CARD ──────────────────────────────
            if (widget.analyzerEnabled) ...[
              _buildSectionHeader('SCALING & GRID DYNAMICS'),
              const SizedBox(height: 8),
              _buildCardContainer(
                children: [
                  _buildM3ESwitchTile(
                    title: 'Auto Peak Headroom',
                    subtitle:
                        'Dynamically adapts Y-axis ceiling to track loudness',
                    secondary: _buildLeadingIcon(Icons.fit_screen_rounded),
                    value: widget.analyzerAutoFit,
                    onChanged: (v) {
                      widget.onAnalyzerAutoFitChanged(v);
                      setSubState(() {});
                    },
                  ),
                  const M3EDivider(),
                  _buildM3ESwitchTile(
                    title: 'Show Grids & Decibels',
                    subtitle:
                        'Display amplitude level grid and frequency axis ticks',
                    secondary: _buildLeadingIcon(Icons.grid_4x4_rounded),
                    value: widget.analyzerShowGrids,
                    onChanged: (v) {
                      widget.onAnalyzerShowGridsChanged(v);
                      setSubState(() {});
                    },
                  ),
                  const M3EDivider(),
                  Padding(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 20.0, vertical: 14.0),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            _buildLeadingIcon(Icons.tune_rounded),
                            const SizedBox(width: 14),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    'Visualizer Scale Mode',
                                    style: TextStyle(
                                      color: _textPrimary,
                                      fontSize: 15,
                                      fontWeight: FontWeight.w600,
                                    ),
                                  ),
                                  const SizedBox(height: 2),
                                  Text(
                                    widget.analyzerLogScale
                                        ? 'Logarithmic: Musical octaves & decibel perception'
                                        : 'Linear: Even frequency bandwidths & linear magnitude',
                                    style: TextStyle(
                                        color: _textDark, fontSize: 12),
                                  ),
                                ],
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 12),
                        SizedBox(
                          width: double.infinity,
                          child: M3ESegmentedButton<bool>(
                            segments: const [
                              M3ESegment(
                                value: true,
                                label: 'Logarithmic',
                                icon: Icon(Icons.tune_rounded, size: 16),
                              ),
                              M3ESegment(
                                value: false,
                                label: 'Linear',
                                icon: Icon(Icons.linear_scale_rounded, size: 16),
                              ),
                            ],
                            selected: {widget.analyzerLogScale},
                            onSelectionChanged: (val) {
                              if (val.isNotEmpty) {
                                widget.onAnalyzerLogScaleChanged(val.first);
                                setSubState(() {});
                              }
                            },
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 20),

              // ── FFT RESOLUTION & PERFORMANCE CARD ───────────────────────
              _buildSectionHeader('FFT RESOLUTION & PERFORMANCE'),
              const SizedBox(height: 8),
              _buildCardContainer(
                children: [
                  Padding(
                    padding: const EdgeInsets.fromLTRB(20, 16, 20, 8),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            _buildLeadingIcon(Icons.data_array_rounded),
                            const SizedBox(width: 14),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    'FFT Frame Size (Buffer)',
                                    style: TextStyle(
                                      color: _textPrimary,
                                      fontSize: 15,
                                      fontWeight: FontWeight.w600,
                                    ),
                                  ),
                                  const SizedBox(height: 2),
                                  Text(
                                    _getFftSampleSizeDescription(
                                        widget.analyzerSampleSize),
                                    style: TextStyle(
                                        color: _textDark, fontSize: 12),
                                  ),
                                ],
                              ),
                            ),
                            AppStatusBadge(
                              text: '${widget.analyzerSampleSize} pts',
                              onTap: () => _showAnalyzerSampleSizeDialog(
                                onDone: () => setSubState(() {}),
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 14),
                        SizedBox(
                          width: double.infinity,
                          child: M3ESegmentedButton<int>(
                            segments: const [
                              M3ESegment(value: 512, label: '512 (Fast)'),
                              M3ESegment(value: 1024, label: '1024 (Std)'),
                              M3ESegment(value: 2048, label: '2048 (Hi-Res)'),
                              M3ESegment(value: 4096, label: '4096 (Ultra)'),
                            ],
                            selected: {
                              [512, 1024, 2048, 4096]
                                      .contains(widget.analyzerSampleSize)
                                  ? widget.analyzerSampleSize
                                  : 1024
                            },
                            onSelectionChanged: (val) {
                              if (val.isNotEmpty) {
                                widget.onAnalyzerSampleSizeChanged(val.first);
                                widget.player.configureAnalyzer(
                                  frameSize: val.first,
                                  windowType: widget.analyzerWindowType,
                                );
                                setSubState(() {});
                              }
                            },
                          ),
                        ),
                      ],
                    ),
                  ),
                  const M3EDivider(),
                  M3EListItem(
                    headline: 'All Sample Sizes (256 - 8192)',
                    supportingText:
                        'Inspect full latency and resolution breakdown',
                    leading: _buildLeadingIcon(Icons.tune_rounded),
                    trailing: const Icon(Icons.chevron_right_rounded, size: 22),
                    onTap: () => _showAnalyzerSampleSizeDialog(
                      onDone: () => setSubState(() {}),
                    ),
                  ),
                  const M3EDivider(),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(20, 16, 20, 8),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            _buildLeadingIcon(Icons.waves_rounded),
                            const SizedBox(width: 14),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    'FFT Window Function',
                                    style: TextStyle(
                                      color: _textPrimary,
                                      fontSize: 15,
                                      fontWeight: FontWeight.w600,
                                    ),
                                  ),
                                  const SizedBox(height: 2),
                                  Text(
                                    _getFftWindowDescription(
                                        widget.analyzerWindowType),
                                    style: TextStyle(
                                        color: _textDark, fontSize: 12),
                                  ),
                                ],
                              ),
                            ),
                            AppStatusBadge(
                              text: _getFftWindowDisplayName(
                                  widget.analyzerWindowType),
                              onTap: () => _showAnalyzerWindowDialog(
                                onDone: () => setSubState(() {}),
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 14),
                        SizedBox(
                          width: double.infinity,
                          child: M3ESegmentedButton<String>(
                            segments: const [
                              M3ESegment(value: 'hann', label: 'Hann'),
                              M3ESegment(value: 'hamming', label: 'Hamming'),
                              M3ESegment(
                                  value: 'blackman_harris',
                                  label: 'Blackman-H'),
                              M3ESegment(value: 'flat_top', label: 'Flat-Top'),
                            ],
                            selected: {
                              ['hann', 'hamming', 'blackman_harris', 'flat_top']
                                      .contains(widget.analyzerWindowType)
                                  ? widget.analyzerWindowType
                                  : 'hann'
                            },
                            onSelectionChanged: (val) {
                              if (val.isNotEmpty) {
                                widget.onAnalyzerWindowTypeChanged(val.first);
                                widget.player.configureAnalyzer(
                                  frameSize: widget.analyzerSampleSize,
                                  windowType: val.first,
                                );
                                setSubState(() {});
                              }
                            },
                          ),
                        ),
                      ],
                    ),
                  ),
                  const M3EDivider(),
                  M3EListItem(
                    headline: 'Window Characteristics & Guide',
                    supportingText:
                        'Explore sidelobe suppression, bandwidth & RTA accuracy',
                    leading: _buildLeadingIcon(Icons.info_outline_rounded),
                    trailing: const Icon(Icons.chevron_right_rounded, size: 22),
                    onTap: () => _showAnalyzerWindowDialog(
                      onDone: () => setSubState(() {}),
                    ),
                  ),
                ],
              ),
            ],
          ],
        );
      },
    );
  }

  String _getFftWindowDisplayName(String type) {
    return FftWindowType.fromString(type).displayName;
  }

  String _getFftWindowDescription(String type) {
    switch (FftWindowType.fromString(type)) {
      case FftWindowType.hann:
        return 'Hann • Balanced all-rounder with smooth visual response (-31.5 dB sidelobes)';
      case FftWindowType.hamming:
        return 'Hamming • Narrow main lobe for sharp harmonic separation (-42.5 dB sidelobes)';
      case FftWindowType.blackmanHarris:
        return 'Blackman-Harris • 4-term ultra-low leakage (-92.0 dB sidelobes)';
      case FftWindowType.flatTop:
        return 'Flat-Top • Calibrated passband with < 0.01 dB scalloping loss';
    }
  }


  String _getFftSampleSizeDescription(int size) {
    switch (size) {
      case 256:
        return '256 samples • Ultra-fast, lowest latency';
      case 512:
        return '512 samples • Fast transient response';
      case 1024:
        return '1024 samples • Balanced standard';
      case 2048:
        return '2048 samples • High frequency resolution';
      case 4096:
        return '4096 samples • Studio precision FFT';
      case 8192:
        return '8192 samples • Ultra HD analytical resolution';
      default:
        return '$size samples window';
    }
  }

  void _applyVisualizerPreset(String preset, StateSetter setSubState) {
    switch (preset) {
      case 'balanced':
        widget.onAnalyzerEnabledChanged(true);
        widget.onAnalyzerTypeChanged('bar');
        widget.onSpectrumStyleChanged('neon');
        widget.onAnalyzerAutoFitChanged(true);
        widget.onAnalyzerShowGridsChanged(true);
        widget.onAnalyzerLogScaleChanged(true);
        widget.onAnalyzerSampleSizeChanged(1024);
        widget.onAnalyzerWindowTypeChanged('hann');
        widget.player.configureAnalyzer(frameSize: 1024, windowType: 'hann');
        break;
      case 'smooth_curve':
        widget.onAnalyzerEnabledChanged(true);
        widget.onAnalyzerTypeChanged('area');
        widget.onSpectrumStyleChanged('fire');
        widget.onAnalyzerAutoFitChanged(true);
        widget.onAnalyzerShowGridsChanged(true);
        widget.onAnalyzerLogScaleChanged(true);
        widget.onAnalyzerSampleSizeChanged(2048);
        widget.onAnalyzerWindowTypeChanged('hann');
        widget.player.configureAnalyzer(frameSize: 2048, windowType: 'hann');
        break;
      case 'audiophile_precision':
        widget.onAnalyzerEnabledChanged(true);
        widget.onAnalyzerTypeChanged('bar');
        widget.onSpectrumStyleChanged('pill');
        widget.onAnalyzerAutoFitChanged(false);
        widget.onAnalyzerShowGridsChanged(true);
        widget.onAnalyzerLogScaleChanged(true);
        widget.onAnalyzerSampleSizeChanged(4096);
        widget.onAnalyzerWindowTypeChanged('blackman_harris');
        widget.player.configureAnalyzer(frameSize: 4096, windowType: 'blackman_harris');
        break;
      case 'minimalist':
        widget.onAnalyzerEnabledChanged(true);
        widget.onAnalyzerTypeChanged('area');
        widget.onSpectrumStyleChanged('minimal');
        widget.onAnalyzerAutoFitChanged(true);
        widget.onAnalyzerShowGridsChanged(false);
        widget.onAnalyzerLogScaleChanged(false);
        widget.onAnalyzerSampleSizeChanged(512);
        widget.onAnalyzerWindowTypeChanged('hamming');
        widget.player.configureAnalyzer(frameSize: 512, windowType: 'hamming');
        break;
    }
    setSubState(() {});
    setState(() {});
  }

  // 5. Playback & Crossfade Sub-Screen
  Widget _buildPlaybackSubScreen() {
    return StatefulBuilder(
      builder: (context, setSubState) {
        return _buildSubScreenLayout(
          title: 'Playback & Crossfade',
          children: [
            _buildSectionHeader('TRANSITIONS & PLAYBACK'),
            const SizedBox(height: 8),
            _buildCardContainer(
              children: [
                _buildM3ESwitchTile(
                  title: 'Gapless Playback',
                  subtitle: 'Seamless transitions between track ends',
                  secondary: _buildLeadingIcon(Icons.queue_music),
                  value: _gaplessPlayback,
                  onChanged: (v) {
                    setState(() => _gaplessPlayback = v);
                    setSubState(() {});
                    _persistUiSettings();
                  },
                ),
                const M3EDivider(),
                Padding(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
                  child: Column(
                    children: [
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          Row(
                            children: [
                              _buildLeadingIcon(Icons.tune),
                              const SizedBox(width: 16),
                              Text('Crossfade Duration',
                                  style: TextStyle(
                                      color: _textPrimary,
                                      fontSize: 16,
                                      fontWeight: FontWeight.w500)),
                            ],
                          ),
                          M3ESwitch(
                            value: widget.crossfadeEnabled,
                            onChanged: (v) {
                              widget.onCrossfadeEnabledChanged(v);
                              widget.player.setCrossfadeEnabled(v);
                              setSubState(() {});
                            },
                          ),
                        ],
                      ),
                      const SizedBox(height: 16),
                      M3ESlider(
                        value: widget.crossfadeDurationMs / 1000.0,
                        min: 0,
                        max: 12,
                        divisions: 24,
                        onChanged: widget.crossfadeEnabled
                            ? (v) {
                                widget.onCrossfadeDurationMsChanged(
                                    (v * 1000).toInt());
                                setSubState(() {});
                              }
                            : null,
                        onChangeEnd: widget.crossfadeEnabled
                            ? (v) {
                                widget.player
                                    .setCrossfadeDurationMs((v * 1000).toInt());
                              }
                            : null,
                      ),
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          Text('Off',
                              style: TextStyle(color: _textDark, fontSize: 12)),
                          Text(
                            '${(widget.crossfadeDurationMs / 1000).toStringAsFixed(1)}s',
                            style: TextStyle(
                              color: widget.crossfadeEnabled
                                  ? _primary
                                  : _textDark,
                              fontSize: 12,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                          Text('12s',
                              style: TextStyle(color: _textDark, fontSize: 12)),
                        ],
                      )
                    ],
                  ),
                ),
                const M3EDivider(),
                if (widget.crossfadeEnabled) ...[
                  _buildM3ESwitchTile(
                    title: 'Loudness-Aware Crossfade',
                    subtitle: _loudnessCrossfadeEnabled
                        ? 'Per-track gain applied during blend — no volume jumps'
                        : 'Disabled — raw PCM blending',
                    secondary: _buildLeadingIcon(
                      Icons.volume_up_rounded,
                      _loudnessCrossfadeEnabled ? _primary : _textDark,
                    ),
                    value: _loudnessCrossfadeEnabled,
                    onChanged: (val) {
                      setState(() => _loudnessCrossfadeEnabled = val);
                      setSubState(() {});
                      widget.player.setLoudnessCrossfadeEnabled(val);
                      AppStateService.instance
                          .saveLoudnessCrossfadeEnabled(val);
                    },
                  ),
                  const M3EDivider(),
                ],
                _buildM3ESwitchTile(
                  title: 'Normalize Volume',
                  subtitle: 'Normalizes volume across tracks',
                  secondary: _buildLeadingIcon(Icons.bar_chart),
                  value: _normalizeVolume,
                  onChanged: (v) {
                    setState(() => _normalizeVolume = v);
                    setSubState(() {});
                    _persistUiSettings();
                  },
                ),
              ],
            ),
          ],
        );
      },
    );
  }

  // 6. Data & Streaming Sub-Screen
  Widget _buildDataAndStreamingSubScreen() {
    return StatefulBuilder(
      builder: (context, setSubState) {
        return _buildSubScreenLayout(
          title: 'Data & Streaming',
          children: [
            // ── AUDIO STREAMING QUALITY ──────────────────────────────────────
            _buildSectionHeader('STREAMING QUALITY'),
            const SizedBox(height: 8),
            _buildCardContainer(
              children: [
                _buildQualityOptionTile(
                  title: 'Max Quality',
                  subtitle: 'Highest bitrate, best dynamic range',
                  preset: AudioQualityPreset.audiophile,
                  badge: 'Max',
                  setSubState: setSubState,
                ),
                const M3EDivider(),
                _buildQualityOptionTile(
                  title: 'High Quality',
                  subtitle: 'Balanced quality with good hardware decoding',
                  preset: AudioQualityPreset.high,
                  badge: 'High',
                  setSubState: setSubState,
                ),
                const M3EDivider(),
                _buildQualityOptionTile(
                  title: 'Balanced',
                  subtitle: 'Good balance of quality and data usage',
                  preset: AudioQualityPreset.medium,
                  badge: 'Balanced',
                  setSubState: setSubState,
                ),
                const M3EDivider(),
                _buildQualityOptionTile(
                  title: 'Data Saver',
                  subtitle: 'Minimal bandwidth',
                  preset: AudioQualityPreset.low,
                  badge: 'Data Saver',
                  setSubState: setSubState,
                ),
              ],
            ),
            const SizedBox(height: 20),

            // ── HARDWARE & CONTAINER PREFERENCES ────────────────────────────
            _buildSectionHeader('HARDWARE & PLAYBACK OPTIMIZATION'),
            const SizedBox(height: 8),
            _buildCardContainer(
              children: [
                _buildM3ESwitchTile(
                  title: 'Prefer Native AAC',
                  subtitle: 'Prioritize Native M4A streams',
                  secondary: _buildLeadingIcon(Icons.memory_rounded),
                  value: _preferNativeAac,
                  onChanged: (val) {
                    setState(() => _preferNativeAac = val);
                    setSubState(() {});
                    AppStateService.instance.savePreferNativeAac(val);
                  },
                ),
                const M3EDivider(),
                _buildM3ESwitchTile(
                  title: 'Enable Backup Fallback',
                  subtitle: '(Recommended)',
                  secondary: _buildLeadingIcon(
                    Icons.cloud_sync_rounded,
                    _enableHostedFallback ? _primary : _textDark,
                  ),
                  value: _enableHostedFallback,
                  onChanged: (val) {
                    setState(() => _enableHostedFallback = val);
                    setSubState(() {});
                    AppStateService.instance.saveEnableHostedFallback(val);
                  },
                ),
                // const M3EDivider(),
              ],
            ),
            const SizedBox(height: 20),

            // ── CACHE & STORAGE ─────────────────────────────────────────────
            _buildSectionHeader('OFFLINE STREAM CACHE'),
            const SizedBox(height: 8),
            _buildCardContainer(
              children: [
                ValueListenableBuilder<int>(
                  valueListenable:
                      CachedStreamService.instance.totalSizeBytesNotifier,
                  builder: (context, totalBytes, _) {
                    return M3EListItem(
                      headline: 'Cached Stream Storage',
                      supportingText:
                          'Local cache of previously resolved tracks',
                      leading: _buildLeadingIcon(Icons.dns_rounded),
                      trailing: Text(
                        CachedStreamService.formatBytes(totalBytes),
                        style: TextStyle(
                          color: _primary,
                          fontWeight: FontWeight.bold,
                          fontSize: 14,
                        ),
                      ),
                    );
                  },
                ),
                const M3EDivider(),
                M3EListItem(
                  headline: 'Clear Stream Cache',
                  supportingText:
                      'Delete temporary audio files & purge cache index',
                  leading: _buildLeadingIcon(
                      Icons.cleaning_services_rounded, Colors.redAccent),
                  trailing: const Icon(Icons.chevron_right_rounded,
                      color: Colors.redAccent, size: 20),
                  onTap: () async {
                    await CachedStreamService.instance.clearAllCache();
                    StreamingService.clearCache();
                    if (context.mounted) {
                      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
                        content: const Text('Audio cache purged successfully'),
                        backgroundColor: _cardDark,
                      ));
                    }
                  },
                ),
              ],
            ),
            const SizedBox(height: 30),
          ],
        );
      },
    );
  }

  Widget _buildQualityOptionTile({
    required String title,
    required String subtitle,
    required AudioQualityPreset preset,
    required String badge,
    required StateSetter setSubState,
  }) {
    final isSelected = _streamingQualityPreset == preset;
    return InkWell(
      onTap: () {
        setState(() => _streamingQualityPreset = preset);
        setSubState(() {});
        AppStateService.instance.saveStreamingQualityPreset(preset);
      },
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        child: Row(
          children: [
            Icon(
              isSelected
                  ? Icons.radio_button_checked_rounded
                  : Icons.radio_button_off_rounded,
              color: isSelected ? _primary : _textDark,
              size: 22,
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Text(
                        title,
                        style: TextStyle(
                          color: isSelected ? _primary : _textPrimary,
                          fontWeight:
                              isSelected ? FontWeight.bold : FontWeight.w500,
                          fontSize: 15,
                        ),
                      ),
                      const SizedBox(width: 8),
                      Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 6, vertical: 2),
                        decoration: BoxDecoration(
                          color: isSelected
                              ? _primary.withValues(alpha: 0.15)
                              : _cardDark,
                          borderRadius: BorderRadius.circular(6),
                          border: Border.all(
                            color: isSelected
                                ? _primary.withValues(alpha: 0.3)
                                : Colors.white10,
                          ),
                        ),
                        child: Text(
                          badge,
                          style: TextStyle(
                            color: isSelected ? _primary : _textDark,
                            fontSize: 10,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 4),
                  Text(
                    subtitle,
                    style: TextStyle(color: _textDark, fontSize: 12),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  void _showChangelogBottomSheet() {
    M3EBottomSheet.show<void>(
      context,
      builder: (ctx) => _buildModalBottomSheetLayout(
        title: 'Release Notes & Changelog',
        subtitle: 'What\'s new and improved in SautiPlay',
        height: MediaQuery.of(context).size.height * 0.85,
        child: _buildChangelogView(),
      ),
    );
  }

  Widget _buildChangelogView() {
    if (_changelog.isEmpty) {
      return const Padding(
        padding: EdgeInsets.all(32),
        child: Center(child: CircularProgressIndicator()),
      );
    }
    return ListView.separated(
      padding: const EdgeInsets.fromLTRB(20, 8, 20, 24),
      itemCount: _changelog.length,
      separatorBuilder: (_, __) => const SizedBox(height: 14),
      itemBuilder: (context, index) {
        final entry = _changelog[index];
        final version = (entry['version'] as String?) ?? '';
        final date = (entry['date'] as String?) ?? '';
        final changes = (entry['changes'] as List<dynamic>?) ?? [];
        final isCurrentVersion = version
                .toLowerCase()
                .contains(_appVersion.toLowerCase().replaceAll('v', '')) ||
            _appVersion
                .toLowerCase()
                .contains(version.toLowerCase().replaceAll('v', ''));

        return Container(
          decoration: BoxDecoration(
            color: isCurrentVersion
                ? _primary.withValues(alpha: 0.08)
                : context.cardDark,
            borderRadius: BorderRadius.circular(16),
            border: Border.all(
              color: isCurrentVersion
                  ? _primary.withValues(alpha: 0.45)
                  : context.outlineColor,
              width: isCurrentVersion ? 1.5 : 1.0,
            ),
          ),
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                    decoration: BoxDecoration(
                      color: _primary.withValues(alpha: 0.15),
                      borderRadius: BorderRadius.circular(10),
                      border:
                          Border.all(color: _primary.withValues(alpha: 0.4)),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(Icons.new_releases_rounded,
                            size: 14, color: _primary),
                        const SizedBox(width: 6),
                        Text(
                          version,
                          style: TextStyle(
                            color: _primary,
                            fontWeight: FontWeight.bold,
                            fontSize: 13,
                          ),
                        ),
                      ],
                    ),
                  ),
                  if (isCurrentVersion) ...[
                    const SizedBox(width: 8),
                    Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 8, vertical: 4),
                      decoration: BoxDecoration(
                        color: Colors.green.withValues(alpha: 0.15),
                        borderRadius: BorderRadius.circular(8),
                        border: Border.all(
                            color: Colors.green.withValues(alpha: 0.4)),
                      ),
                      child: const Text(
                        'CURRENT',
                        style: TextStyle(
                          color: Colors.greenAccent,
                          fontWeight: FontWeight.bold,
                          fontSize: 10,
                        ),
                      ),
                    ),
                  ],
                  const Spacer(),
                  if (date.isNotEmpty)
                    Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(Icons.calendar_today_outlined,
                            size: 13, color: _textDark),
                        const SizedBox(width: 4),
                        Text(
                          date,
                          style: TextStyle(
                            color: _textDark,
                            fontSize: 12,
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                      ],
                    ),
                ],
              ),
              if (changes.isNotEmpty) ...[
                const SizedBox(height: 12),
                const M3EDivider(),
                const SizedBox(height: 10),
                ...changes.map((c) {
                  return Padding(
                    padding: const EdgeInsets.only(bottom: 8.0),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Container(
                          width: 6,
                          height: 6,
                          margin: const EdgeInsets.only(top: 7, right: 10),
                          decoration: BoxDecoration(
                            color: isCurrentVersion
                                ? _primary
                                : _textDark.withValues(alpha: 0.6),
                            shape: BoxShape.circle,
                          ),
                        ),
                        Expanded(
                          child: _buildFormattedMarkdownText(
                            c as String,
                            baseStyle: TextStyle(
                              color:
                                  isCurrentVersion ? _textPrimary : _textDark,
                              fontSize: 13,
                              height: 1.45,
                            ),
                          ),
                        ),
                      ],
                    ),
                  );
                }),
              ],
            ],
          ),
        );
      },
    );
  }

  Widget _buildFormattedMarkdownText(String text, {TextStyle? baseStyle}) {
    final style =
        baseStyle ?? TextStyle(color: _textDark, fontSize: 13, height: 1.45);
    final spans = <InlineSpan>[];
    final regex = RegExp(r'(`[^`]+`|\*\*[^*]+\*\*|\*[^*]+\*)');
    int lastMatchEnd = 0;

    for (final match in regex.allMatches(text)) {
      if (match.start > lastMatchEnd) {
        spans.add(TextSpan(
          text: text.substring(lastMatchEnd, match.start),
          style: style,
        ));
      }
      final matchedText = match.group(0)!;
      if (matchedText.startsWith('`') && matchedText.endsWith('`')) {
        final codeContent = matchedText.substring(1, matchedText.length - 1);
        spans.add(
          WidgetSpan(
            alignment: PlaceholderAlignment.middle,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1.5),
              margin: const EdgeInsets.symmetric(horizontal: 2),
              decoration: BoxDecoration(
                color: _primary.withValues(alpha: 0.15),
                borderRadius: BorderRadius.circular(4),
                border: Border.all(color: _primary.withValues(alpha: 0.3)),
              ),
              child: Text(
                codeContent,
                style: TextStyle(
                  fontFamily: 'monospace',
                  fontSize: (style.fontSize ?? 13) * 0.88,
                  fontWeight: FontWeight.w600,
                  color: _primary,
                ),
              ),
            ),
          ),
        );
      } else if (matchedText.startsWith('**') && matchedText.endsWith('**')) {
        final boldContent = matchedText.substring(2, matchedText.length - 2);
        spans.add(TextSpan(
          text: boldContent,
          style:
              style.copyWith(fontWeight: FontWeight.bold, color: _textPrimary),
        ));
      } else if (matchedText.startsWith('*') && matchedText.endsWith('*')) {
        final italicContent = matchedText.substring(1, matchedText.length - 1);
        spans.add(TextSpan(
          text: italicContent,
          style: style.copyWith(fontStyle: FontStyle.italic),
        ));
      }
      lastMatchEnd = match.end;
    }

    if (lastMatchEnd < text.length) {
      spans.add(TextSpan(
        text: text.substring(lastMatchEnd),
        style: style,
      ));
    }

    return Text.rich(TextSpan(children: spans));
  }

  // 7. Misc & System Sub-Screen
  Widget _buildMiscSystemSubScreen() {
    return StatefulBuilder(
      builder: (context, setSubState) {
        return _buildSubScreenLayout(
          title: 'Misc & System',
          children: [
            _buildSectionHeader('ABOUT & SYSTEM LICENSES'),
            const SizedBox(height: 8),
            _buildCardContainer(
              children: [
                M3EListItem(
                  headline: 'Version',
                  leading: _buildLeadingIcon(Icons.info_outline),
                  trailing: Text(_appVersion,
                      style: TextStyle(color: _textDark, fontSize: 14)),
                ),
                const M3EDivider(),
                ListenableBuilder(
                  listenable: AppUpdateService.instance,
                  builder: (context, _) {
                    final updateService = AppUpdateService.instance;
                    final isChecking =
                        updateService.stage == UpdateStage.checking;
                    final isAvailable =
                        updateService.stage == UpdateStage.available;
                    final isDownloaded =
                        updateService.stage == UpdateStage.downloaded;
                    final isDownloading =
                        updateService.stage == UpdateStage.downloading;

                    String subtitle = 'Check GitHub for new releases';
                    Widget? trailing;

                    if (isChecking) {
                      subtitle = 'Checking for updates...';
                      trailing = SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          valueColor: AlwaysStoppedAnimation<Color>(_primary),
                        ),
                      );
                    } else if (isDownloading) {
                      final pct =
                          (updateService.downloadProgress * 100).toInt();
                      subtitle = 'Downloading update ($pct%)...';
                      trailing = Text(
                        '$pct%',
                        style: TextStyle(
                          color: _primary,
                          fontWeight: FontWeight.bold,
                          fontSize: 13,
                        ),
                      );
                    } else if (isAvailable || isDownloaded) {
                      final release = updateService.release;
                      subtitle = isDownloaded
                          ? 'Downloaded ${release?.tagName ?? ""}. Ready to install!'
                          : 'New version ${release?.tagName ?? ""} available!';
                      trailing = Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 8, vertical: 4),
                        decoration: BoxDecoration(
                          color: Colors.green.withValues(alpha: 0.15),
                          borderRadius: BorderRadius.circular(8),
                          border: Border.all(
                              color: Colors.greenAccent
                                  .withValues(alpha: 0.5)),
                        ),
                        child: const Text(
                          'UPDATE',
                          style: TextStyle(
                            color: Colors.greenAccent,
                            fontSize: 11,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      );
                    } else if (updateService.stage == UpdateStage.error) {
                      subtitle = 'Update check failed. Tap to retry.';
                      trailing = const Icon(Icons.refresh_rounded,
                          color: Colors.orangeAccent, size: 20);
                    } else {
                      trailing = Icon(Icons.chevron_right_rounded,
                          color: _textDark, size: 20);
                    }

                    return M3EListItem(
                      headline: 'Check for Updates',
                      supportingText: subtitle,
                      leading: _buildLeadingIcon(
                        Icons.system_update_rounded,
                        (isAvailable || isDownloaded)
                            ? Colors.greenAccent
                            : _primary,
                      ),
                      trailing: trailing,
                      onTap: () async {
                        if (isDownloading || isAvailable || isDownloaded) {
                          AppUpdateDialog.show(context);
                        } else {
                          final hasUpdate = await updateService
                              .checkForUpdates(isManual: true);
                          if (context.mounted) {
                            if (hasUpdate) {
                              AppUpdateDialog.show(context);
                            } else if (updateService.stage !=
                                UpdateStage.error) {
                              ScaffoldMessenger.of(context).showSnackBar(
                                SnackBar(
                                  content: Text(
                                    'Sautiplay is up to date ($_appVersion)',
                                  ),
                                  duration: const Duration(seconds: 2),
                                ),
                              );
                            }
                          }
                        }
                      },
                    );
                  },
                ),
                const M3EDivider(),
                M3EListItem(
                  headline: 'Check Updates on Startup',
                  supportingText:
                      'Automatically check for updates when Sautiplay opens',
                  leading: _buildLeadingIcon(Icons.update_rounded),
                  trailing: M3ESwitch(
                    value: _autoCheckUpdates,
                    onChanged: (val) async {
                      final prefs = await SharedPreferences.getInstance();
                      await prefs.setBool('auto_check_updates', val);
                      setSubState(() => _autoCheckUpdates = val);
                      setState(() => _autoCheckUpdates = val);
                    },
                  ),
                ),
                const M3EDivider(),
                M3EListItem(
                  headline: 'Developer',
                  leading: _buildLeadingIcon(Icons.person_outline),
                  trailing: Text('Wambugu Kinyua',
                      style: TextStyle(color: _textDark, fontSize: 14)),
                ),
                const M3EDivider(),
                M3EListItem(
                  headline: 'Copyright',
                  leading: _buildLeadingIcon(Icons.copyright_outlined),
                  trailing: Text('© ${DateTime.now().year} Wambugu Kinyua',
                      style: TextStyle(color: _textDark, fontSize: 14)),
                ),
                const M3EDivider(),
                M3EListItem(
                  headline: 'Open Source Licenses',
                  leading: _buildLeadingIcon(Icons.policy_outlined),
                  trailing:
                      Icon(Icons.chevron_right, color: _textDark, size: 20),
                  onTap: () {
                    showLicensePage(
                      context: context,
                      applicationName: 'SautiPlay',
                      applicationVersion: _appVersion,
                    );
                  },
                ),
                const M3EDivider(),
                M3EListItem(
                  headline: 'Changelog',
                  supportingText: 'Release notes and version updates',
                  leading: _buildLeadingIcon(Icons.history_edu_outlined),
                  trailing: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 8, vertical: 4),
                        decoration: BoxDecoration(
                          color: _primary.withAlpha(25),
                          borderRadius: BorderRadius.circular(8),
                          border: Border.all(color: _primary.withAlpha(60)),
                        ),
                        child: Text(
                          _appVersion,
                          style: TextStyle(
                            color: _primary,
                            fontSize: 12,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                      const SizedBox(width: 6),
                      Icon(Icons.chevron_right_rounded,
                          color: _textDark, size: 20),
                    ],
                  ),
                  onTap: _showChangelogBottomSheet,
                ),
                const M3EDivider(),
                M3EListItem(
                  headline: 'Join Telegram Community',
                  supportingText:
                      'Discuss features, report issues & get early builds',
                  leading: _buildLeadingIcon(
                      Icons.send_rounded, const Color(0xFF229ED9)),
                  trailing: Icon(Icons.open_in_new_rounded,
                      color: _textDark, size: 20),
                  onTap: () async {
                    final uri = Uri.parse('https://t.me/+MilnrgkNkbFiYmY0');
                    try {
                      await launchUrl(uri,
                          mode: LaunchMode.externalApplication);
                    } catch (_) {
                      if (context.mounted) {
                        ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(
                              content: Text('Could not open Telegram link')),
                        );
                      }
                    }
                  },
                ),
              ],
            ),
            const SizedBox(height: 20),
            _buildSectionHeader('DEBUG & ERROR CONTROLS'),
            const SizedBox(height: 8),
            _buildCardContainer(
              children: [
                _buildM3ESwitchTile(
                  title: 'Allow invalid TLS certs',
                  subtitle: 'Testing & fallback media server mode',
                  secondary: _buildLeadingIcon(Icons.security),
                  value: widget.allowInvalidTls,
                  onChanged: (v) {
                    widget.onAllowInvalidTlsChanged(v);
                    setSubState(() {});
                  },
                ),
                const M3EDivider(),
                M3EListItem(
                  headline: 'Poll Native Error',
                  leading: _buildLeadingIcon(Icons.refresh),
                  trailing:
                      Icon(Icons.chevron_right, color: _textDark, size: 20),
                  onTap: widget.onPollError,
                ),
                const M3EDivider(),
                M3EListItem(
                  headline: 'Clear Native Error',
                  leading: _buildLeadingIcon(Icons.cleaning_services_outlined),
                  trailing:
                      Icon(Icons.chevron_right, color: _textDark, size: 20),
                  onTap: widget.onClearNativeError,
                ),
              ],
            ),
            const SizedBox(height: 20),
            _buildSectionHeader('ENGINE LOGS TERMINAL'),
            const SizedBox(height: 8),
            ValueListenableBuilder<int>(
              valueListenable: widget.logUpdateNotifier,
              builder: (context, _, __) {
                return M3EExpandableList(
                  style: M3EExpandableStyle(
                    color: context.cardDark,
                    gap: 8,
                    headerPadding: const EdgeInsets.symmetric(
                        horizontal: 16, vertical: 12),
                    bodyPadding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                  ),
                  data: [
                    M3EExpandableData(
                      title: 'App Engine Logs',
                      subtitle: '${widget.logs.length} logged entries',
                      leading: _buildLeadingIcon(Icons.article_outlined),
                      trailing: Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 8, vertical: 4),
                        decoration: BoxDecoration(
                          color: _primary.withAlpha(50),
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: Text('${widget.logs.length}',
                            style: TextStyle(
                                color: _primary,
                                fontSize: 12,
                                fontWeight: FontWeight.bold)),
                      ),
                      body: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          Row(
                            children: [
                              Expanded(
                                child: M3EButton.icon(
                                  onPressed: () async {
                                    if (widget.logs.isEmpty) {
                                      ScaffoldMessenger.of(context)
                                          .showSnackBar(const SnackBar(
                                              content:
                                                  Text('No logs to copy')));
                                      return;
                                    }
                                    final text =
                                        widget.logs.reversed.join('\n');
                                    await Clipboard.setData(
                                        ClipboardData(text: text));
                                    if (!context.mounted) return;
                                    ScaffoldMessenger.of(context).showSnackBar(
                                        SnackBar(
                                            content: Text(
                                                'Copied ${widget.logs.length} lines'),
                                            backgroundColor: _cardDark));
                                  },
                                  icon: const Icon(Icons.copy, size: 18),
                                  label: const Text('Copy'),
                                ),
                              ),
                              const SizedBox(width: 8),
                              Expanded(
                                child: M3EButton.icon(
                                  onPressed: widget.onClearLogs,
                                  icon:
                                      const Icon(Icons.delete_sweep, size: 18),
                                  label: const Text('Clear'),
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 12),
                          Container(
                            height: 250,
                            decoration: BoxDecoration(
                              color:
                                  context.outlineColor.withValues(alpha: 0.1),
                              borderRadius: BorderRadius.circular(12),
                              border: Border.all(color: context.outlineColor),
                            ),
                            child: widget.logs.isEmpty
                                ? Center(
                                    child: Text('No logs yet',
                                        style: TextStyle(color: _textDark)))
                                : ListView.builder(
                                    padding: const EdgeInsets.all(12),
                                    itemCount: widget.logs.length,
                                    itemBuilder: (context, index) {
                                      return Padding(
                                        padding:
                                            const EdgeInsets.only(bottom: 6.0),
                                        child: SelectableText(
                                          widget.logs[index],
                                          style: TextStyle(
                                              color: _textDark,
                                              fontSize: 12,
                                              fontFamily: 'monospace'),
                                        ),
                                      );
                                    },
                                  ),
                          ),
                        ],
                      ),
                    ),
                  ],
                );
              },
            ),
          ],
        );
      },
    );
  }

  // 8. Last.fm Scrobbler Sub-Screen
  Widget _buildLastFmSubScreen() {
    return AnimatedBuilder(
      animation: LastFmService.instance,
      builder: (context, _) {
        final lastFm = LastFmService.instance;
        const lastFmRed = Color(0xFFD51007);
        final isAuthenticating = lastFm.isAuthenticating;

        return StatefulBuilder(
          builder: (context, setSubState) {
            return _buildSubScreenLayout(
              title: 'Last.fm Scrobbler',
              children: [
                // ── ACCOUNT STATUS & PROFILE BANNER ────────────────────────
                _buildSectionHeader('ACCOUNT & CONNECTION'),
                const SizedBox(height: 8),
                _buildCardContainer(
                  children: [
                    Padding(
                      padding: const EdgeInsets.all(16.0),
                      child: Row(
                        children: [
                          Container(
                            width: 48,
                            height: 48,
                            decoration: BoxDecoration(
                              color: lastFmRed.withAlpha(30),
                              shape: BoxShape.circle,
                              border: Border.all(
                                  color: lastFmRed.withAlpha(80), width: 1.5),
                            ),
                            child: const Center(
                              child: Icon(Icons.radio_rounded,
                                  color: lastFmRed, size: 24),
                            ),
                          ),
                          const SizedBox(width: 16),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  lastFm.isLoggedIn
                                      ? (lastFm.username ?? 'Connected Account')
                                      : (isAuthenticating
                                          ? 'Awaiting Authorization...'
                                          : 'Not Connected'),
                                  style: TextStyle(
                                    color: _textPrimary,
                                    fontSize: 16,
                                    fontWeight: FontWeight.bold,
                                  ),
                                ),
                                const SizedBox(height: 2),
                                Text(
                                  lastFm.isLoggedIn
                                      ? 'Scrobbles sync automatically to your Last.fm profile'
                                      : (isAuthenticating
                                          ? 'Approve in browser; app connects automatically on return'
                                          : 'Connect your Last.fm account to track listening history'),
                                  style: TextStyle(
                                    color: _textDark,
                                    fontSize: 12,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                    ),
                    const M3EDivider(),
                    if (!lastFm.isLoggedIn) ...[
                      Padding(
                        padding: const EdgeInsets.all(16.0),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            if (!isAuthenticating) ...[
                              M3EButton.icon(
                                onPressed: () async {
                                  final token =
                                      await lastFm.fetchRequestToken();
                                  if (token != null) {
                                    await lastFm.launchAuthorizationUrl(token);
                                    if (context.mounted) {
                                      ScaffoldMessenger.of(context)
                                          .showSnackBar(
                                        const SnackBar(
                                          content: Text(
                                              'Authorize Sautiplay in your browser. Connection will complete automatically upon return!'),
                                        ),
                                      );
                                    }
                                  } else {
                                    if (context.mounted) {
                                      ScaffoldMessenger.of(context)
                                          .showSnackBar(
                                        const SnackBar(
                                          content: Text(
                                              'Failed to connect to Last.fm API. Check internet connection.'),
                                        ),
                                      );
                                    }
                                  }
                                },
                                icon: const Icon(Icons.login_rounded, size: 18),
                                label: const Text('Connect Last.fm Account'),
                              ),
                            ] else ...[
                              Container(
                                padding: const EdgeInsets.all(14),
                                decoration: BoxDecoration(
                                  color: _primary.withAlpha(20),
                                  borderRadius: BorderRadius.circular(12),
                                  border:
                                      Border.all(color: _primary.withAlpha(60)),
                                ),
                                child: Column(
                                  children: [
                                    Row(
                                      children: [
                                        SizedBox(
                                          width: 18,
                                          height: 18,
                                          child: CircularProgressIndicator(
                                            strokeWidth: 2.2,
                                            valueColor:
                                                AlwaysStoppedAnimation<Color>(
                                                    _primary),
                                          ),
                                        ),
                                        const SizedBox(width: 10),
                                        Expanded(
                                          child: Text(
                                            lastFm.isCheckingSession
                                                ? 'Verifying authorization...'
                                                : 'Waiting for browser authorization...',
                                            style: TextStyle(
                                              color: _textPrimary,
                                              fontSize: 13,
                                              fontWeight: FontWeight.w600,
                                            ),
                                          ),
                                        ),
                                      ],
                                    ),
                                    const SizedBox(height: 8),
                                    Text(
                                      'Approve Sautiplay in your browser, then return here. The app connects automatically.',
                                      style: TextStyle(
                                          color: _textDark, fontSize: 12),
                                    ),
                                    const SizedBox(height: 12),
                                    Row(
                                      children: [
                                        Expanded(
                                          child: M3EButton.outlined(
                                            onPressed: () async {
                                              await lastFm
                                                  .cancelAuthentication();
                                            },
                                            child: const Text('Cancel'),
                                          ),
                                        ),
                                        const SizedBox(width: 10),
                                        Expanded(
                                          child: M3EButton(
                                            onPressed: lastFm.isCheckingSession
                                                ? null
                                                : () async {
                                                    final success = await lastFm
                                                        .checkPendingAuthorization();
                                                    if (success) {
                                                      if (context.mounted) {
                                                        ScaffoldMessenger.of(
                                                                context)
                                                            .showSnackBar(
                                                          SnackBar(
                                                            content: Text(
                                                                'Connected to Last.fm as ${lastFm.username}!'),
                                                          ),
                                                        );
                                                      }
                                                    } else {
                                                      if (context.mounted) {
                                                        ScaffoldMessenger.of(
                                                                context)
                                                            .showSnackBar(
                                                          const SnackBar(
                                                            content: Text(
                                                                'Authorization not completed yet. Please approve on the Last.fm webpage.'),
                                                          ),
                                                        );
                                                      }
                                                    }
                                                  },
                                            child: Text(lastFm.isCheckingSession
                                                ? 'Verifying...'
                                                : 'Check Now'),
                                          ),
                                        ),
                                      ],
                                    ),
                                  ],
                                ),
                              ),
                            ],
                          ],
                        ),
                      ),
                    ] else ...[
                      M3EListItem(
                        headline: 'Disconnect Last.fm Account',
                        supportingText: 'Log out and stop scrobbling',
                        leading: _buildLeadingIcon(
                            Icons.logout_rounded, Colors.redAccent),
                        trailing: const Icon(Icons.chevron_right_rounded,
                            color: Colors.redAccent, size: 20),
                        onTap: () async {
                          await lastFm.logout();
                          setSubState(() {});
                        },
                      ),
                    ],
                  ],
                ),
                const SizedBox(height: 20),

                // ── SCROBBLING SETTINGS ──────────────────────────────────────
                _buildSectionHeader('SCROBBLING PREFERENCES'),
                const SizedBox(height: 8),
                _buildCardContainer(
                  children: [
                    _buildM3ESwitchTile(
                      title: 'Scrobble Tracks',
                      subtitle:
                          'Save played songs to your Last.fm listening history',
                      secondary:
                          _buildLeadingIcon(Icons.history_rounded, lastFmRed),
                      value: lastFm.isScrobbleEnabled,
                      onChanged: (val) async {
                        await lastFm.setScrobbleEnabled(val);
                        setSubState(() {});
                      },
                    ),
                    const M3EDivider(),
                    _buildM3ESwitchTile(
                      title: 'Update "Now Playing"',
                      subtitle: 'Broadcast currently active song in real-time',
                      secondary: _buildLeadingIcon(
                          Icons.graphic_eq_rounded, lastFmRed),
                      value: lastFm.isNowPlayingEnabled,
                      onChanged: (val) async {
                        await lastFm.setNowPlayingEnabled(val);
                        setSubState(() {});
                      },
                    ),
                  ],
                ),
                const SizedBox(height: 20),

                // ── RULES & DETAILS ─────────────────────────────────────────
                _buildSectionHeader('LAST.FM SCROBBLER RULES'),
                const SizedBox(height: 8),
                _buildCardContainer(
                  children: [
                    Padding(
                      padding: const EdgeInsets.all(16.0),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              Icon(Icons.info_outline_rounded,
                                  color: _primary, size: 18),
                              const SizedBox(width: 8),
                              Text(
                                'How scrobbling works',
                                style: TextStyle(
                                    color: _primary,
                                    fontWeight: FontWeight.bold,
                                    fontSize: 13),
                              ),
                            ],
                          ),
                          const SizedBox(height: 8),
                          Text(
                            '• Tracks shorter than 30 seconds are ignored as per Last.fm guidelines.\n'
                            '• A scrobble is sent after listening to 50% of the track or 4 minutes (whichever comes first).\n'
                            '• Real-time "Now Playing" updates appear instantly on your Last.fm profile when playback begins.',
                            style: TextStyle(
                                color: _textDark, fontSize: 12, height: 1.45),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ],
            );
          },
        );
      },
    );
  }

  // --- Modal Dialog Helpers ---

  String _getResampleAlgorithmName(int index) {
    switch (index) {
      case 0:
        return 'Linear Standard (Fast & Smooth)';
      case 1:
        return 'Sinc Master Ultra HD';
      case 2:
        return 'Sinc High Quality';
      case 3:
        return 'Sinc Good Quality';
      case 4:
        return 'Step / Hold (Lo-Fi)';
      case 5:
        return 'Linear Extended';
      case 7:
        return 'SoX VHQ Linear Phase (Audiophile)';
      case 8:
        return 'SoX VHQ Minimum Phase (Zero Pre-Ring)';
      case 9:
        return 'SoX High Quality';
      case 10:
        return 'SoX Fast Quality';
      case 11:
        return 'r8brain 24-bit Linear Phase (Mastering)';
      case 12:
        return 'r8brain 24-bit Minimum Phase (Zero Pre-Ring)';
      default:
        return 'Linear Standard (Fast & Smooth)';
    }
  }

  String _getResampleAlgorithmShortName(int index) {
    switch (index) {
      case 0:
        return 'Linear';
      case 1:
        return 'Master HD';
      case 2:
        return 'Sinc HQ';
      case 3:
        return 'Sinc Good';
      case 4:
        return 'Step / Hold';
      case 5:
        return 'Linear Ext';
      case 7:
        return 'SoX VHQ (LP)';
      case 8:
        return 'SoX VHQ (MP)';
      case 9:
        return 'SoX HQ';
      case 10:
        return 'SoX Fast';
      case 11:
        return 'r8brain (LP)';
      case 12:
        return 'r8brain (MP)';
      default:
        return 'Linear';
    }
  }

  String _getResampleAlgorithmSupportingText(int index) {
    switch (index) {
      case 0:
        return 'Linear standard interpolation';
      case 1:
        return 'Sinc master ultra HD (640 taps)';
      case 2:
        return 'Sinc high quality (libsamplerate)';
      case 3:
        return 'Sinc good quality (libsamplerate)';
      case 4:
        return 'Step / hold (lo-fi vintage)';
      case 5:
        return 'Linear extended interpolation';
      case 7:
        return 'SoX VHQ linear phase (175dB SNR)';
      case 8:
        return 'SoX VHQ minimum phase (zero pre-ring)';
      case 9:
        return 'SoX high quality (160dB SNR)';
      case 10:
        return 'SoX fast quality (120dB SNR)';
      case 11:
        return 'r8brain 24-bit linear phase (>160dB SNR)';
      case 12:
        return 'r8brain 24-bit min-phase (zero pre-ring)';
      default:
        return 'Audio sample rate conversion';
    }
  }

  String _getOversamplingName(int factor) {
    switch (factor) {
      case 2:
        return '2x (High Quality)';
      case 4:
        return '4x (Ultra HD)';
      default:
        return 'Off (1x)';
    }
  }

  Widget _buildModalBottomSheetLayout({
    required String title,
    String? subtitle,
    required Widget child,
    double? height,
  }) {
    return ConstrainedBox(
      constraints: BoxConstraints(
        maxHeight: height ?? MediaQuery.of(context).size.height * 0.75,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(24.0, 4.0, 24.0, 12.0),
            child: Column(
              children: [
                Text(
                  title,
                  style: TextStyle(
                    color: _textPrimary,
                    fontSize: 18,
                    fontWeight: FontWeight.bold,
                  ),
                  textAlign: TextAlign.center,
                ),
                if (subtitle != null) ...[
                  const SizedBox(height: 4),
                  Text(
                    subtitle,
                    style: TextStyle(color: _textDark, fontSize: 12),
                    textAlign: TextAlign.center,
                  ),
                ],
              ],
            ),
          ),
          const Padding(
            padding: EdgeInsets.symmetric(horizontal: 20.0),
            child: M3EDivider(),
          ),
          const SizedBox(height: 8),
          if (height != null)
            Expanded(child: child)
          else
            Flexible(child: child),
          const SizedBox(height: 8),
        ],
      ),
    );
  }

  void _showOversamplingDialog({VoidCallback? onDone}) {
    final options = [
      {'factor': 1, 'name': 'Off (1x)', 'subtitle': 'Native sample rate'},
      {
        'factor': 2,
        'name': '2x Oversampling',
        'subtitle': 'High Quality (Anti-aliasing saturation)'
      },
      {
        'factor': 4,
        'name': '4x Oversampling',
        'subtitle': 'Ultra HD (Maximum purity)'
      },
    ];

    M3EBottomSheet.show<void>(
      context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDlgState) => _buildModalBottomSheetLayout(
          title: 'DSP Anti-Aliasing Oversampling',
          subtitle: 'Anti-aliasing oversampling for DSP & limiters',
          child: M3ECardList(
            margin: const EdgeInsets.fromLTRB(20.0, 4.0, 20.0, 16.0),
            padding:
                const EdgeInsets.symmetric(horizontal: 16.0, vertical: 12.0),
            gap: 6.0,
            outerRadius: 20.0,
            innerRadius: 6.0,
            itemCount: options.length,
            onTap: (index) {
              final val = options[index]['factor'] as int;
              setDlgState(() {});
              setState(() => _dspOversampling = val);
              AppStateService.instance.saveDspOversampling(val);
              onDone?.call();
              Navigator.pop(ctx);
            },
            itemBuilder: (context, index) {
              final item = options[index];
              final val = item['factor'] as int;
              final isSelected = val == _dspOversampling;
              return M3EListItem(
                headline: item['name'] as String,
                supportingText: item['subtitle'] as String,
                selected: isSelected,
                trailing: M3ERadio<int>(
                  value: val,
                  groupValue: _dspOversampling,
                  onChanged: (v) {
                    setDlgState(() {});
                    setState(() => _dspOversampling = v);
                    AppStateService.instance.saveDspOversampling(v);
                    onDone?.call();
                    Navigator.pop(ctx);
                  },
                ),
              );
            },
          ),
        ),
      ),
    );
  }

  void _showResampleAlgorithmDialog({VoidCallback? onDone}) {
    final isMobile = defaultTargetPlatform == TargetPlatform.android ||
        defaultTargetPlatform == TargetPlatform.iOS;

    final options = [
      {
        'index': 0,
        'name': 'Linear Standard (Fast & Smooth)',
        'subtitle':
            'Default. Ultra-low CPU, zero latency. Recommended for Mobile.',
        'badge': 'Recommended',
        'isHeavy': false,
      },
      {
        'index': 5,
        'name': 'Linear Extended',
        'subtitle': 'Standard linear interpolation algorithm.',
        'badge': null,
        'isHeavy': false,
      },
      {
        'index': 4,
        'name': 'Step / Hold (Lo-Fi)',
        'subtitle': 'Zero-order hold interpolation for vintage stepped sound.',
        'badge': null,
        'isHeavy': false,
      },
      {
        'index': 9,
        'name': 'SoX High Quality',
        'subtitle':
            'High Quality SoX resampler (160dB SNR). Fast & pristine rate conversion.',
        'badge': 'SoX HQ',
        'isHeavy': false,
      },
      {
        'index': 10,
        'name': 'SoX Fast Quality',
        'subtitle':
            'Fast SoX resampler (120dB SNR). High efficiency resampling.',
        'badge': 'SoX Fast',
        'isHeavy': false,
      },
      {
        'index': 7,
        'name': 'SoX VHQ Linear Phase (Audiophile)',
        'subtitle':
            'Very High Quality linear phase filter (175dB SNR). Exceptional purity.',
        'badge': isMobile ? '⚠️ High CPU' : 'SoX VHQ',
        'isHeavy': true,
      },
      {
        'index': 8,
        'name': 'SoX VHQ Minimum Phase (Zero Pre-Ring)',
        'subtitle':
            'VHQ minimum phase filter. Eliminates pre-ringing on acoustic transients.',
        'badge': isMobile ? '⚠️ High CPU' : 'SoX Min-Phase',
        'isHeavy': true,
      },
      {
        'index': 11,
        'name': 'r8brain 24-bit Linear Phase (Mastering)',
        'subtitle':
            'Voxengo r8brain (>160dB SNR). Pristine mastering-grade linear phase conversion.',
        'badge': isMobile ? '⚠️ High CPU' : 'r8brain LP',
        'isHeavy': true,
      },
      {
        'index': 12,
        'name': 'r8brain 24-bit Minimum Phase (Zero Pre-Ring)',
        'subtitle':
            'Voxengo r8brain minimum phase filter. Eliminates pre-ringing with natural transient response.',
        'badge': isMobile ? '⚠️ High CPU' : 'r8brain MP',
        'isHeavy': true,
      },
      {
        'index': 3,
        'name': 'Sinc Good Quality (libsamplerate)',
        'subtitle': 'Band-limited sinc filter (97dB SNR). Efficient & clean.',
        'badge': null,
        'isHeavy': false,
      },
      {
        'index': 2,
        'name': 'Sinc High Quality (libsamplerate)',
        'subtitle': 'Band-limited sinc filter (121dB SNR). High CPU load.',
        'badge': isMobile ? '⚠️ High CPU' : 'Studio',
        'isHeavy': true,
      },
      {
        'index': 1,
        'name': 'Sinc Master Ultra HD (libsamplerate)',
        'subtitle': '640-tap sinc filter (144dB SNR). Desktop High-End CPUs.',
        'badge': isMobile ? '⚠️ Desktop Only' : 'Master HD',
        'isHeavy': true,
      },
    ];

    M3EBottomSheet.show<void>(
      context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDlgState) => _buildModalBottomSheetLayout(
          title: 'Resampling Quality Tier',
          subtitle: 'Select interpolation algorithm for rate conversion',
          height: MediaQuery.of(context).size.height * 0.78,
          child: M3ECardList.builder(
            margin: const EdgeInsets.fromLTRB(20.0, 4.0, 20.0, 16.0),
            listPadding: const EdgeInsets.symmetric(vertical: 4.0),
            padding:
                const EdgeInsets.symmetric(horizontal: 16.0, vertical: 12.0),
            gap: 6.0,
            outerRadius: 20.0,
            innerRadius: 6.0,
            itemCount: options.length,
            onTap: (index) {
              final item = options[index];
              final val = item['index'] as int;
              if (isMobile && (item['isHeavy'] as bool)) {
                Navigator.pop(ctx);
                _showMobileResamplerWarningDialog(val, onDone);
              } else {
                _applyResampleAlgorithm(val, onDone);
                Navigator.pop(ctx);
              }
            },
            itemBuilder: (context, index) {
              final item = options[index];
              final val = item['index'] as int;
              final isSelected = val == _resampleAlgorithm;
              return M3EListItem(
                headline: item['name'] as String,
                supportingText: item['subtitle'] as String,
                selected: isSelected,
                trailing: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (item['badge'] != null) ...[
                      Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 8, vertical: 3),
                        decoration: BoxDecoration(
                          color: (item['isHeavy'] as bool && isMobile)
                              ? Colors.amber.withAlpha(40)
                              : _primary.withAlpha(30),
                          borderRadius: BorderRadius.circular(8),
                          border: Border.all(
                            color: (item['isHeavy'] as bool && isMobile)
                                ? Colors.amber.withAlpha(120)
                                : _primary.withAlpha(80),
                          ),
                        ),
                        child: Text(
                          item['badge'] as String,
                          style: TextStyle(
                            color: (item['isHeavy'] as bool && isMobile)
                                ? Colors.amberAccent
                                : _primary,
                            fontSize: 10,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                    ],
                    M3ERadio<int>(
                      value: val,
                      groupValue: _resampleAlgorithm,
                      onChanged: (v) {
                        setDlgState(() {});
                        if (isMobile && (item['isHeavy'] as bool)) {
                          Navigator.pop(ctx);
                          _showMobileResamplerWarningDialog(v, onDone);
                        } else {
                          _applyResampleAlgorithm(v, onDone);
                          Navigator.pop(ctx);
                        }
                      },
                    ),
                  ],
                ),
              );
            },
          ),
        ),
      ),
    );
  }

  void _applyResampleAlgorithm(int index, VoidCallback? onDone) {
    setState(() => _resampleAlgorithm = index);
    widget.player.setEngineResampleAlgorithm(index);
    _persistUiSettings();
    onDone?.call();
  }

  void _showMobileResamplerWarningDialog(
      int requestedIndex, VoidCallback? onDone) {
    final name = _getResampleAlgorithmName(requestedIndex);
    final String techDetails;
    if (requestedIndex == 11 || requestedIndex == 12) {
      techDetails =
          '$name performs multi-stage convolution (>160dB SNR). On mobile devices, this may increase CPU usage.';
    } else if (requestedIndex == 1) {
      techDetails =
          '$name calculates 640 filter taps per sample. On mobile devices, this may cause stuttering or battery drain.';
    } else {
      techDetails =
          '$name uses high-precision DSP filtering. On mobile devices, this may cause battery drain.';
    }

    M3EDialog.show<void>(
      context,
      dialog: M3EDialog(
        contentPadding:
            const EdgeInsets.symmetric(vertical: 16.0, horizontal: 8.0),
        title: 'High CPU Resampler Warning',
        content: Text(
          '$techDetails\n\nDo you want to enable it anyway or stay with Linear Standard (Recommended)?',
          style: TextStyle(color: _textDark, fontSize: 13, height: 1.4),
        ),
        actions: [
          M3EButton.text(
            onPressed: () {
              _applyResampleAlgorithm(0, onDone);
              Navigator.pop(context);
            },
            child: const Text('Recommended'),
          ),
          M3EButton(
            onPressed: () {
              _applyResampleAlgorithm(requestedIndex, onDone);
              Navigator.pop(context);
            },
            child: const Text('Enable'),
          ),
        ],
      ),
    );
  }

  void _showAnalyzerSampleSizeDialog({VoidCallback? onDone}) {
    final sizes = [
      (256, '256 samples', 'Ultra-fast, lowest CPU (Lightweight FFT)'),
      (512, '512 samples', 'Fast transient response (Low Latency)'),
      (1024, '1024 samples', 'Balanced default (Standard Music Playback)'),
      (2048, '2048 samples', 'High frequency resolution (Crisp Bass/Treble)'),
      (4096, '4096 samples', 'Studio precision (Audiophile Inspection)'),
      (8192, '8192 samples', 'Ultra HD analytical FFT (Maximum Resolution)'),
    ];
    M3EBottomSheet.show<void>(
      context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDlgState) => _buildModalBottomSheetLayout(
          title: 'FFT Sample Window Size',
          subtitle: 'Frequency resolution vs time domain responsiveness',
          child: M3ECardList(
            margin: const EdgeInsets.fromLTRB(20.0, 4.0, 20.0, 16.0),
            padding:
                const EdgeInsets.symmetric(horizontal: 16.0, vertical: 12.0),
            gap: 6.0,
            outerRadius: 20.0,
            innerRadius: 6.0,
            itemCount: sizes.length,
            onTap: (index) {
              final size = sizes[index].$1;
              setDlgState(() {});
              widget.onAnalyzerSampleSizeChanged(size);
              widget.player.configureAnalyzer(frameSize: size);
              onDone?.call();
              Navigator.pop(ctx);
            },
            itemBuilder: (context, index) {
              final item = sizes[index];
              final size = item.$1;
              final isSelected = size == widget.analyzerSampleSize;
              return M3EListItem(
                headline: item.$2,
                supportingText: item.$3,
                selected: isSelected,
                trailing: M3ERadio<int>(
                  value: size,
                  groupValue: widget.analyzerSampleSize,
                  onChanged: (v) {
                    setDlgState(() {});
                    widget.onAnalyzerSampleSizeChanged(v);
                    widget.player.configureAnalyzer(frameSize: v);
                    onDone?.call();
                    Navigator.pop(ctx);
                  },
                ),
              );
            },
          ),
        ),
      ),
    );
  }

  void _showAnalyzerWindowDialog({VoidCallback? onDone}) {
    final windows = [
      (
        'hann',
        'Hann (Hanning)',
        'Balanced standard for music visualization and audio analysis (-31.5 dB sidelobes, 18 dB/oct rolloff). Smooth natural ballistics.',
      ),
      (
        'hamming',
        'Hamming',
        'Narrowest main lobe for resolving closely spaced pitches, vocal harmonics, and rapid transients (-42.5 dB sidelobes).',
      ),
      (
        'blackman_harris',
        'Blackman-Harris (4-Term)',
        'Ultra-low leakage with -92 dB sidelobe suppression. Eliminates bleed across adjacent RTA bands for pristine dynamic range.',
      ),
      (
        'flat_top',
        'Flat-Top (5-Term)',
        'Amplitude-calibrated reference with < 0.01 dB passband ripple. Eliminates scalloping loss for precise decibel and SPL metering.',
      ),
    ];
    M3EBottomSheet.show<void>(
      context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDlgState) => _buildModalBottomSheetLayout(
          title: 'FFT Window Functions',
          subtitle:
              'Spectral leakage suppression vs main lobe frequency resolution',
          child: M3ECardList(
            margin: const EdgeInsets.fromLTRB(20.0, 4.0, 20.0, 16.0),
            padding:
                const EdgeInsets.symmetric(horizontal: 16.0, vertical: 12.0),
            gap: 6.0,
            outerRadius: 20.0,
            innerRadius: 6.0,
            itemCount: windows.length,
            onTap: (index) {
              final winId = windows[index].$1;
              setDlgState(() {});
              widget.onAnalyzerWindowTypeChanged(winId);
              widget.player.configureAnalyzer(
                frameSize: widget.analyzerSampleSize,
                windowType: winId,
              );
              onDone?.call();
              Navigator.pop(ctx);
            },
            itemBuilder: (context, index) {
              final item = windows[index];
              final winId = item.$1;
              final isSelected = winId == widget.analyzerWindowType;
              return M3EListItem(
                headline: item.$2,
                supportingText: item.$3,
                selected: isSelected,
                trailing: M3ERadio<String>(
                  value: winId,
                  groupValue: widget.analyzerWindowType,
                  onChanged: (v) {
                    setDlgState(() {});
                    widget.onAnalyzerWindowTypeChanged(v);
                    widget.player.configureAnalyzer(
                      frameSize: widget.analyzerSampleSize,
                      windowType: v,
                    );
                    onDone?.call();
                    Navigator.pop(ctx);
                  },
                ),
              );
            },
          ),
        ),
      ),
    );
  }


  String _getDitherModeName(int mode) {
    switch (mode) {
      case 0:
        return 'None';
      case 1:
        return 'Rectangle (RPDF)';
      case 2:
        return 'Triangle (TPDF)';
      case 3:
        return 'Lipshitz';
      case 4:
        return 'F-Weighted';
      case 5:
        return 'Modified E-Weighted';
      case 6:
        return 'Shibata';
      case 7:
        return 'Low Shibata';
      case 8:
        return 'High Shibata';
      default:
        return 'None';
    }
  }

  Future<void> _showDitherModeDialog({VoidCallback? onDone}) async {
    final modes = [
      {'id': 0, 'name': 'None', 'subtitle': 'No dithering applied'},
      {'id': 1, 'name': 'Rectangle (RPDF)', 'subtitle': 'Simple flat dither'},
      {
        'id': 2,
        'name': 'Triangle (TPDF)',
        'subtitle': 'Standard flat dither (Recommended)'
      },
      {
        'id': 3,
        'name': 'Lipshitz',
        'subtitle': 'Classic 5th-order noise-shaped'
      },
      {
        'id': 4,
        'name': 'F-Weighted',
        'subtitle': 'Midrange cut noise-shaped (Acoustic/Vocal)'
      },
      {
        'id': 5,
        'name': 'Modified E-Weighted',
        'subtitle': 'Peak-safe noise-shaped (Pop/Rock)'
      },
      {
        'id': 6,
        'name': 'Shibata',
        'subtitle': 'Standard audiophile noise-shaped'
      },
      {
        'id': 7,
        'name': 'Low Shibata',
        'subtitle': 'Gentle audiophile noise-shaped (Safest)'
      },
      {
        'id': 8,
        'name': 'High Shibata',
        'subtitle': 'Steep audiophile noise-shaped'
      },
    ];

    M3EBottomSheet.show<void>(
      context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDlgState) => _buildModalBottomSheetLayout(
          title: 'Dither Mode',
          subtitle: 'Quantization noise shaping for bit-depth reduction',
          height: MediaQuery.of(context).size.height * 0.78,
          child: M3ECardList.builder(
            margin: const EdgeInsets.fromLTRB(20.0, 4.0, 20.0, 16.0),
            listPadding: const EdgeInsets.symmetric(vertical: 4.0),
            padding:
                const EdgeInsets.symmetric(horizontal: 16.0, vertical: 12.0),
            gap: 6.0,
            outerRadius: 20.0,
            innerRadius: 6.0,
            itemCount: modes.length,
            onTap: (i) {
              final item = modes[i];
              final id = item['id'] as int;
              setDlgState(() {});
              setState(() => _ditherMode = id);
              widget.player.setEngineDitherMode(id);
              _persistUiSettings();
              onDone?.call();
              Navigator.pop(ctx);
            },
            itemBuilder: (context, i) {
              final item = modes[i];
              final id = item['id'] as int;
              final name = item['name'] as String;
              final subtitle = item['subtitle'] as String;
              final isSelected = id == _ditherMode;
              return M3EListItem(
                headline: name,
                supportingText: subtitle,
                selected: isSelected,
                trailing: M3ERadio<int>(
                  value: id,
                  groupValue: _ditherMode,
                  onChanged: (val) {
                    setDlgState(() {});
                    setState(() => _ditherMode = val);
                    widget.player.setEngineDitherMode(val);
                    _persistUiSettings();
                    onDone?.call();
                    Navigator.pop(ctx);
                  },
                ),
              );
            },
          ),
        ),
      ),
    );
  }

  void _showOutputFormatDialog({VoidCallback? onDone}) {
    final formats = [
      (
        AudioFormat.f32,
        '32-Bit Floating Point (f32)',
        'Highest dynamic range IEEE float (Recommended)'
      ),
      (
        AudioFormat.s32,
        '32-Bit Signed Integer (s32)',
        '32-bit signed integer hardware PCM'
      ),
      (
        AudioFormat.s24,
        '24-Bit Signed Integer (s24)',
        '24-bit high-resolution studio standard'
      ),
      (
        AudioFormat.s16,
        '16-Bit Signed Integer (s16)',
        '16-bit standard CD quality PCM'
      ),
      (
        AudioFormat.u8,
        '8-Bit Unsigned Integer (u8)',
        '8-bit legacy PCM format'
      ),
    ];
    M3EBottomSheet.show<void>(
      context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDlgState) => _buildModalBottomSheetLayout(
          title: 'Engine Output Format',
          subtitle: 'Target PCM bit depth for audio hardware output',
          child: M3ECardList(
            margin: const EdgeInsets.fromLTRB(20.0, 4.0, 20.0, 16.0),
            padding:
                const EdgeInsets.symmetric(horizontal: 16.0, vertical: 12.0),
            gap: 6.0,
            outerRadius: 20.0,
            innerRadius: 6.0,
            itemCount: formats.length,
            onTap: (index) {
              final fmt = formats[index].$1;
              setDlgState(() {});
              widget.onOutputFormatChanged(fmt);
              widget.player.setOutputFormat(fmt);
              setState(() {});
              onDone?.call();
              Navigator.pop(ctx);
            },
            itemBuilder: (context, index) {
              final item = formats[index];
              final fmt = item.$1;
              final isSelected = fmt == widget.outputFormat;
              return M3EListItem(
                headline: item.$2,
                supportingText: item.$3,
                selected: isSelected,
                trailing: M3ERadio<AudioFormat>(
                  value: fmt,
                  groupValue: widget.outputFormat,
                  onChanged: (v) {
                    setDlgState(() {});
                    widget.onOutputFormatChanged(fmt);
                    widget.player.setOutputFormat(fmt);
                    setState(() {});
                    onDone?.call();
                    Navigator.pop(ctx);
                  },
                ),
              );
            },
          ),
        ),
      ),
    );
  }

  void _showSampleRateDialog({VoidCallback? onDone}) {
    final rates = [
      (0, 'Native', 'Match device hardware rate'),
      (44100, '44.1 kHz (44,100 Hz)', 'Standard rate'),
      (48000, '48.0 kHz (48,000 Hz)', 'Studio Audio rate'),
      (96000, '96.0 kHz (96,000 Hz)', 'High-Resolution rate'),
      (192000, '192.0 kHz (192,000 Hz)', 'Ultra HD Master rate'),
    ];
    M3EBottomSheet.show<void>(
      context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDlgState) => _buildModalBottomSheetLayout(
          title: 'Engine Sample Rate',
          subtitle: 'Target rate for audio output stream',
          child: M3ECardList(
            margin: const EdgeInsets.fromLTRB(20.0, 4.0, 20.0, 16.0),
            padding:
                const EdgeInsets.symmetric(horizontal: 16.0, vertical: 12.0),
            gap: 6.0,
            outerRadius: 20.0,
            innerRadius: 6.0,
            itemCount: rates.length,
            onTap: (index) {
              final r = rates[index].$1;
              setDlgState(() {});
              widget.onOutputSampleRateChanged(r);
              widget.player.setOutputSampleRate(r);
              setState(() {});
              onDone?.call();
              Navigator.pop(ctx);
            },
            itemBuilder: (context, index) {
              final item = rates[index];
              final r = item.$1;
              final isSelected = r == widget.outputSampleRate;
              return M3EListItem(
                headline: item.$2,
                supportingText: item.$3,
                selected: isSelected,
                trailing: M3ERadio<int>(
                  value: r,
                  groupValue: widget.outputSampleRate,
                  onChanged: (v) {
                    setDlgState(() {});
                    widget.onOutputSampleRateChanged(r);
                    widget.player.setOutputSampleRate(r);
                    setState(() {});
                    onDone?.call();
                    Navigator.pop(ctx);
                  },
                ),
              );
            },
          ),
        ),
      ),
    );
  }

  void _showAndroidBackendPicker(
      BuildContext context, StateSetter setSubState) {
    final backends = [
      (
        AudioOutputBackend.auto,
        'Auto (System Optimal)',
        'Automatically chooses the lowest latency',
        Icons.auto_awesome_rounded,
      ),
      (
        AudioOutputBackend.aaudio,
        'AAudio (Low-Latency MMAP)',
        'High-performance (Android 8.0+) (Recommended)',
        Icons.speed_rounded,
      ),
      (
        AudioOutputBackend.openSl,
        'OpenSL ES (Legacy)',
        'Standard Android audio interface',
        Icons.history_toggle_off_rounded,
      ),
      (
        AudioOutputBackend.audioTrack,
        'AudioTrack (Framework)',
        'Standard Android audio ',
        Icons.layers_rounded,
      ),
      (
        AudioOutputBackend.directHiRes,
        'Direct Hi-Res (limited)',
        'Direct Hi-Res DSPs (on supported hardware only)',
        Icons.verified_rounded,
      ),
    ];

    M3EBottomSheet.show<void>(
      context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDlgState) => _buildModalBottomSheetLayout(
          title: 'Android Output Backend',
          subtitle: 'Select audio output driver',
          child: M3ECardList(
            margin: const EdgeInsets.fromLTRB(20.0, 4.0, 20.0, 16.0),
            padding:
                const EdgeInsets.symmetric(horizontal: 16.0, vertical: 12.0),
            gap: 6.0,
            outerRadius: 20.0,
            innerRadius: 6.0,
            itemCount: backends.length,
            onTap: (index) {
              final selected = backends[index].$1;
              widget.player.setOutputBackend(selected);
              setState(() {
                _selectedBackend = selected;
              });
              setSubState(() {});
              Navigator.pop(ctx);
            },
            itemBuilder: (context, index) {
              final item = backends[index];
              final bk = item.$1;
              final isSelected = bk == _selectedBackend;
              return M3EListItem(
                leading: Icon(item.$4,
                    color: isSelected ? _primary : _textDark, size: 22),
                headline: item.$2,
                supportingText: item.$3,
                selected: isSelected,
                trailing: M3ERadio<AudioOutputBackend>(
                  value: bk,
                  groupValue: _selectedBackend,
                  onChanged: (v) {
                    widget.player.setOutputBackend(v);
                    setState(() {
                      _selectedBackend = v;
                    });
                    setSubState(() {});
                    Navigator.pop(ctx);
                  },
                ),
              );
            },
          ),
        ),
      ),
    );
  }

  String _formatChannelCount(int count) {
    switch (count) {
      case 1:
        return 'Mono';
      case 2:
        return 'Stereo';
      case 3:
        return '2.1 Surround';
      case 4:
        return '4.0 Quadraphonic';
      case 5:
        return '5.0 Surround';
      case 6:
        return '5.1 Surround';
      case 7:
        return '7.0 Surround';
      case 8:
        return '7.1 Surround';
      default:
        return '$count CH';
    }
  }

  void _showChannelsDialog({VoidCallback? onDone}) {
    final options = [
      {'ch': 1, 'name': 'Mono', 'subtitle': 'Single channel mono output'},
      {
        'ch': 2,
        'name': 'Stereo',
        'subtitle': 'Standard 2-channel Left / Right stereo'
      },
      {
        'ch': 3,
        'name': '2.1 Surround',
        'subtitle': 'Left, Right, Center/Subwoofer'
      },
      {
        'ch': 4,
        'name': '4.0 Quadraphonic',
        'subtitle': 'FL, FR, Center, Back Center'
      },
      {'ch': 5, 'name': '5.0 Surround', 'subtitle': 'FL, FR, Center, Back L/R'},
      {
        'ch': 6,
        'name': '5.1 Surround',
        'subtitle': 'FL, FR, Center, LFE Sub, Side L/R'
      },
      {
        'ch': 7,
        'name': '7.0 Surround',
        'subtitle': 'FL, FR, Center, LFE, Back C, Side L/R'
      },
      {
        'ch': 8,
        'name': '7.1 Surround',
        'subtitle': 'FL, FR, Center, LFE, Back L/R, Side L/R'
      },
    ];

    M3EBottomSheet.show<void>(
      context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDlgState) => _buildModalBottomSheetLayout(
          title: 'Output Channels',
          subtitle: 'Select speaker channels layout',
          height: MediaQuery.of(context).size.height * 0.78,
          child: M3ECardList.builder(
            margin: const EdgeInsets.fromLTRB(20.0, 4.0, 20.0, 16.0),
            listPadding: const EdgeInsets.symmetric(vertical: 4.0),
            padding:
                const EdgeInsets.symmetric(horizontal: 16.0, vertical: 12.0),
            gap: 6.0,
            outerRadius: 20.0,
            innerRadius: 6.0,
            itemCount: options.length,
            onTap: (i) {
              final item = options[i];
              final ch = item['ch'] as int;
              setDlgState(() {});
              widget.onOutputChannelsChanged(ch);
              widget.player.setOutputChannels(ch);
              setState(() {});
              onDone?.call();
              Navigator.pop(ctx);
            },
            itemBuilder: (context, i) {
              final item = options[i];
              final ch = item['ch'] as int;
              final name = item['name'] as String;
              final subtitle = item['subtitle'] as String;
              final isSelected = ch == widget.outputChannels;
              return M3EListItem(
                headline: name,
                supportingText: subtitle,
                selected: isSelected,
                trailing: M3ERadio<int>(
                  value: ch,
                  groupValue: widget.outputChannels,
                  onChanged: (val) {
                    setDlgState(() {});
                    widget.onOutputChannelsChanged(val);
                    widget.player.setOutputChannels(val);
                    setState(() {});
                    onDone?.call();
                    Navigator.pop(ctx);
                  },
                ),
              );
            },
          ),
        ),
      ),
    );
  }

  String _formatOutputBuffer(int frames, int periods) {
    if (frames <= 0 || periods <= 0) {
      return 'Auto (Default)';
    }
    return '$frames f • ${periods}x';
  }

  void _showOutputBufferDialog({VoidCallback? onDone}) {
    final options = [
      {
        'frames': 0,
        'periods': 0,
        'name': 'Auto (Default)',
        'subtitle': 'System-negotiated period sizing (~10–25ms)',
        'badge': 'Recommended',
      },
      {
        'frames': 128,
        'periods': 2,
        'name': '128 frames • 2 periods (Ultra Low)',
        'subtitle': '~2.7ms at 48kHz — Minimum latency for live response',
        'badge': 'Ultra Low',
      },
      {
        'frames': 256,
        'periods': 2,
        'name': '256 frames • 2 periods (Low Latency)',
        'subtitle': '~5.3ms at 48kHz — Fast response',
        'badge': 'Low Latency',
      },
      {
        'frames': 512,
        'periods': 2,
        'name': '512 frames • 2 periods (Standard)',
        'subtitle': '~10.7ms at 48kHz — Good latency and stability',
        'badge': 'Standard',
      },
      {
        'frames': 1024,
        'periods': 3,
        'name': '1024 frames • 3 periods (High Stability)',
        'subtitle': '~21.3ms at 48kHz — Resilient',
        'badge': 'Safe',
      },
      {
        'frames': 2048,
        'periods': 4,
        'name': '2048 frames • 4 periods (Max Reliability)',
        'subtitle': '~42.6ms at 48kHz — Maximum underrun prevention',
        'badge': 'Max Safe',
      },
    ];

    M3EBottomSheet.show<void>(
      context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDlgState) => _buildModalBottomSheetLayout(
          title: 'Fixed Output Buffer & Latency',
          subtitle: 'Configure hardware period buffer size and periods',
          height: MediaQuery.of(context).size.height * 0.78,
          child: M3ECardList.builder(
            margin: const EdgeInsets.fromLTRB(20.0, 4.0, 20.0, 16.0),
            listPadding: const EdgeInsets.symmetric(vertical: 4.0),
            padding:
                const EdgeInsets.symmetric(horizontal: 16.0, vertical: 12.0),
            gap: 6.0,
            outerRadius: 20.0,
            innerRadius: 6.0,
            itemCount: options.length,
            onTap: (i) {
              final item = options[i];
              final f = item['frames'] as int;
              final p = item['periods'] as int;
              setDlgState(() {});
              setState(() {
                _outputBufferFrames = f;
                _outputBufferPeriods = p;
              });
              widget.player.setOutputBuffer(
                periodFrames: f,
                periodCount: p,
              );
              AppStateService.instance.saveOutputBuffer(
                periodFrames: f,
                periodCount: p,
              );
              onDone?.call();
              Navigator.pop(ctx);
            },
            itemBuilder: (context, i) {
              final item = options[i];
              final f = item['frames'] as int;
              final p = item['periods'] as int;
              final name = item['name'] as String;
              final subtitle = item['subtitle'] as String;
              final isSelected =
                  _outputBufferFrames == f && _outputBufferPeriods == p;
              return M3EListItem(
                headline: name,
                supportingText: subtitle,
                selected: isSelected,
                trailing: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (item['badge'] != null) ...[
                      Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 6, vertical: 2),
                        decoration: BoxDecoration(
                          color: _primary.withAlpha(40),
                          borderRadius: BorderRadius.circular(6),
                        ),
                        child: Text(
                          item['badge'] as String,
                          style: TextStyle(
                            color: _primary,
                            fontSize: 10,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                    ],
                    M3ERadio<bool>(
                      value: true,
                      groupValue: isSelected ? true : null,
                      onChanged: (_) {
                        setDlgState(() {});
                        setState(() {
                          _outputBufferFrames = f;
                          _outputBufferPeriods = p;
                        });
                        widget.player.setOutputBuffer(
                          periodFrames: f,
                          periodCount: p,
                        );
                        AppStateService.instance.saveOutputBuffer(
                          periodFrames: f,
                          periodCount: p,
                        );
                        onDone?.call();
                        Navigator.pop(ctx);
                      },
                    ),
                  ],
                ),
              );
            },
          ),
        ),
      ),
    );
  }

  void _showSubsonicDialog({VoidCallback? onDone}) {
    final options = [
      (0.0, 'Disabled', 'No sub-bass removal'),
      (15.0, 'Ultra Sub-bass', 'Preserves extreme low end'),
      (20.0, 'Standard Subwoofer', 'Reduces distortion'),
      (25.0, 'Small Woofers', 'Protects small drivers from damage'),
    ];

    M3EBottomSheet.show<void>(
      context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDlgState) => _buildModalBottomSheetLayout(
          title: 'Subsonic Filter',
          subtitle: 'Filter DC and inaudible sub-bass',
          child: M3ECardList(
            margin: const EdgeInsets.fromLTRB(20.0, 4.0, 20.0, 16.0),
            padding:
                const EdgeInsets.symmetric(horizontal: 16.0, vertical: 12.0),
            gap: 6.0,
            outerRadius: 20.0,
            innerRadius: 6.0,
            itemCount: options.length,
            onTap: (index) {
              final val = options[index].$1;
              setState(() => _subsonicCutoffHz = val);
              _persistSpeakerProtectionSettings();
              onDone?.call();
              Navigator.pop(context);
            },
            itemBuilder: (context, index) {
              final opt = options[index];
              final isSelected = opt.$1 == _subsonicCutoffHz;
              return M3EListItem(
                headline: opt.$2,
                supportingText: opt.$3,
                selected: isSelected,
                trailing: M3ERadio<double>(
                  value: opt.$1,
                  groupValue: _subsonicCutoffHz,
                  onChanged: (val) {
                    setState(() => _subsonicCutoffHz = val);
                    _persistSpeakerProtectionSettings();
                    onDone?.call();
                    Navigator.pop(context);
                  },
                ),
              );
            },
          ),
        ),
      ),
    );
  }

  void _showUltrasonicDialog({VoidCallback? onDone}) {
    final options = [
      (24000.0, 'Disabled', 'No filtering applied'),
      (22000.0, 'Hi-Res Limit', 'Protects DACs'),
      (
        20000.0,
        'Human Hearing Limit',
        'Filters frequencies above human hearing'
      ),
      (18000.0, 'Tweeter Guard', 'Protects tweeters from RF noise'),
    ];

    M3EBottomSheet.show<void>(
      context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDlgState) => _buildModalBottomSheetLayout(
          title: 'Ultrasonic Filter',
          subtitle: 'Filter out-of-band high frequencies',
          child: M3ECardList(
            margin: const EdgeInsets.fromLTRB(20.0, 4.0, 20.0, 16.0),
            padding:
                const EdgeInsets.symmetric(horizontal: 16.0, vertical: 12.0),
            gap: 6.0,
            outerRadius: 20.0,
            innerRadius: 6.0,
            itemCount: options.length,
            onTap: (index) {
              final val = options[index].$1;
              setState(() => _ultrasonicCutoffHz = val);
              _persistSpeakerProtectionSettings();
              onDone?.call();
              Navigator.pop(context);
            },
            itemBuilder: (context, index) {
              final opt = options[index];
              final isSelected = opt.$1 == _ultrasonicCutoffHz;
              return M3EListItem(
                headline: opt.$2,
                supportingText: opt.$3,
                selected: isSelected,
                trailing: M3ERadio<double>(
                  value: opt.$1,
                  groupValue: _ultrasonicCutoffHz,
                  onChanged: (val) {
                    setState(() => _ultrasonicCutoffHz = val);
                    _persistSpeakerProtectionSettings();
                    onDone?.call();
                    Navigator.pop(context);
                  },
                ),
              );
            },
          ),
        ),
      ),
    );
  }
}
