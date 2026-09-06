import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_m3shapes_extended/flutter_m3shapes_extended.dart';
import 'package:material_3_expressive/material_3_expressive.dart';
import 'package:path/path.dart' as p;
import 'package:sautiflow/sautiflow.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'isolate_player.dart';
import 'services/app_state_service.dart';
import 'widgets/app_showcase.dart';
import 'widgets/clarity_graph.dart';
import 'widgets/compressor_graph.dart';
import 'widgets/de_esser_graph.dart';
import 'widgets/crossfeed_graph.dart';
import 'widgets/dynamic_bass_graph.dart';
import 'widgets/dynamic_system_graph.dart';
import 'widgets/graphic_eq_graph.dart';
import 'widgets/parametric_eq_graph.dart';
import 'widgets/playback_speed_modal.dart';
import 'widgets/race_visualizer.dart';
import 'widgets/stereo_vectorscope_graph.dart';

import 'services/app_theme_service.dart';

class EqScreen extends StatefulWidget {
  final IsolateAudioPlayer player;
  final bool analyzerEnabled;
  final String analyzerType;
  final GlobalKey? effectsKnobKey;

  const EqScreen({
    super.key,
    required this.player,
    required this.analyzerEnabled,
    required this.analyzerType,
    this.effectsKnobKey,
  });

  /// Applies persisted Sauti DSP suite settings directly to the audio engine.
  static Future<void> applySavedStateToEngine(IsolateAudioPlayer player) async {
    final state = await AppStateService.instance.loadSautiDspState();
    if (state.isEmpty) return;

    final masterEnabled = state['dspMasterEnabled'] ?? true;
    final clarityEnabled = masterEnabled && (state['clarityEnabled'] ?? false);
    final clarityProfile = AudioClarityProfile.values.firstWhere(
      (e) => e.value == (state['clarityProfile'] ?? 0),
      orElse: () => AudioClarityProfile.transientCrisp,
    );
    final clarityIntensity =
        (state['clarityIntensity'] as num?)?.toDouble() ?? 0.5;

    final bassEnabled = masterEnabled && (state['bassEnabled'] ?? false);
    final bassProfile = HarmonicBassProfile.values.firstWhere(
      (e) => e.value == (state['bassProfile'] ?? 5),
      orElse: () => HarmonicBassProfile.dynamicMultiPole,
    );
    final bassCutoffHz = (state['bassCutoffHz'] as num?)?.toDouble() ?? 60.0;
    final bassBoost = (state['bassBoost'] as num?)?.toDouble() ?? 0.5;
    final bassPreset = (state['bassPreset'] as num?)?.toInt() ?? 18;
    final bassGainDb = (state['bassGainDb'] as num?)?.toDouble() ?? 15.0;

    final dynamicSystemEnabled =
        masterEnabled && (state['dynamicSystemEnabled'] ?? false);
    final dynamicSystemProfile = TransducerProfile.values.firstWhere(
      (e) => e.value == (state['dynamicSystemProfile'] ?? 0),
      orElse: () => TransducerProfile.earphone,
    );
    final dynamicSystemStrength =
        (state['dynamicSystemStrength'] as num?)?.toDouble() ?? 0.5;

    final analogWarmthEnabled =
        masterEnabled && (state['analogWarmthEnabled'] ?? false);
    final analogWarmthProfile = AnalogWarmthProfile.values.firstWhere(
      (e) => e.value == (state['analogWarmthProfile'] ?? 0),
      orElse: () => AnalogWarmthProfile.triode12AX7,
    );
    final analogWarmthDrive =
        (state['analogWarmthDrive'] as num?)?.toDouble() ?? 0.5;

    final convolverEnabled =
        masterEnabled && (state['convolverEnabled'] ?? false);
    final convolverIrPath = state['convolverIrPath'] as String?;
    final convolverWet = (state['convolverWet'] as num?)?.toDouble() ?? 1.0;
    final convolverDry = (state['convolverDry'] as num?)?.toDouble() ?? 0.0;

    final limiterEnabled = masterEnabled && (state['limiterEnabled'] ?? false);
    final limiterCeilingDb =
        (state['limiterCeilingDb'] as num?)?.toDouble() ?? -0.1;
    final limiterOutputGainDb =
        (state['limiterOutputGainDb'] as num?)?.toDouble() ?? 0.0;
    final limiterReleaseMs =
        (state['limiterReleaseMs'] as num?)?.toDouble() ?? 60.0;

    player.setClarity(
      enabled: clarityEnabled,
      profile: clarityProfile,
      intensity: clarityIntensity,
    );

    if (bassProfile == HarmonicBassProfile.dynamicMultiPole) {
      player.setDynamicBass(
        enabled: bassEnabled,
        preset: bassPreset,
        gain: bassGainDb,
      );
    } else {
      player.setHarmonicBass(
        enabled: bassEnabled,
        profile: bassProfile,
        cutoffHz: bassCutoffHz,
        boost: bassBoost,
      );
    }

    player.setDynamicSystem(
      enabled: dynamicSystemEnabled,
      profile: dynamicSystemProfile,
      strength: dynamicSystemStrength,
    );

    player.setAnalogWarmth(
      enabled: analogWarmthEnabled,
      profile: analogWarmthProfile,
      drive: analogWarmthDrive,
    );

    final dialogEnhancerEnabled =
        masterEnabled && (state['dialogEnhancerEnabled'] ?? false);
    final dialogEnhancerProfile = DialogEnhancerProfile.values.firstWhere(
      (e) => e.value == (state['dialogEnhancerProfile'] ?? 0),
      orElse: () => DialogEnhancerProfile.cinema,
    );
    final dialogEnhancerAmount =
        (state['dialogEnhancerAmount'] as num?)?.toDouble() ?? 0.65;
    final dialogEnhancerDucking =
        (state['dialogEnhancerDucking'] as num?)?.toDouble() ?? 0.55;
    final dialogEnhancerClarity =
        (state['dialogEnhancerClarity'] as num?)?.toDouble() ?? 0.60;
    final dialogEnhancerCenterFocus =
        (state['dialogEnhancerCenterFocus'] as num?)?.toDouble() ?? 0.70;

    player.setDialogEnhancer(
      enabled: dialogEnhancerEnabled,
      profile: dialogEnhancerProfile,
      amount: dialogEnhancerAmount,
      ducking: dialogEnhancerDucking,
      clarity: dialogEnhancerClarity,
      centerFocus: dialogEnhancerCenterFocus,
    );

    final deEsserEnabled =
        masterEnabled && (state['deEsserEnabled'] ?? false);
    final deEsserMode = DeEsserMode.values.firstWhere(
      (e) => e.value == (state['deEsserMode'] ?? 0),
      orElse: () => DeEsserMode.splitBand,
    );
    final deEsserFrequencyHz =
        (state['deEsserFrequencyHz'] as num?)?.toDouble() ?? 5500.0;
    final deEsserThresholdDb =
        (state['deEsserThresholdDb'] as num?)?.toDouble() ?? -22.0;
    final deEsserRatio = (state['deEsserRatio'] as num?)?.toDouble() ?? 4.0;
    final deEsserMaxReductionDb =
        (state['deEsserMaxReductionDb'] as num?)?.toDouble() ?? 12.0;
    final deEsserAttackMs =
        (state['deEsserAttackMs'] as num?)?.toDouble() ?? 1.0;
    final deEsserReleaseMs =
        (state['deEsserReleaseMs'] as num?)?.toDouble() ?? 35.0;

    player.setDeEsserEx(
      enabled: deEsserEnabled,
      mode: deEsserMode,
      frequencyHz: deEsserFrequencyHz,
      thresholdDb: deEsserThresholdDb,
      ratio: deEsserRatio,
      maxReductionDb: deEsserMaxReductionDb,
      attackMs: deEsserAttackMs,
      releaseMs: deEsserReleaseMs,
    );

    final expanderEnabled =
        masterEnabled && (state['expanderEnabled'] ?? false);
    final expanderPreset = DownwardExpanderPreset.values.firstWhere(
      (e) => e.value == (state['expanderPreset'] ?? 0),
      orElse: () => DownwardExpanderPreset.vinylClean,
    );
    final expanderThresholdDb =
        (state['expanderThresholdDb'] as num?)?.toDouble() ?? -52.0;
    final expanderRatio = (state['expanderRatio'] as num?)?.toDouble() ?? 1.8;
    final expanderRangeDb =
        (state['expanderRangeDb'] as num?)?.toDouble() ?? -16.0;
    final expanderAttackMs =
        (state['expanderAttackMs'] as num?)?.toDouble() ?? 12.0;
    final expanderReleaseMs =
        (state['expanderReleaseMs'] as num?)?.toDouble() ?? 280.0;
    final expanderKneeDb = (state['expanderKneeDb'] as num?)?.toDouble() ?? 6.0;
    final expanderHpfHz = (state['expanderHpfHz'] as num?)?.toDouble() ?? 50.0;

    player.setDownwardExpander(
      enabled: expanderEnabled,
      preset: expanderPreset,
      thresholdDb: expanderThresholdDb,
      ratio: expanderRatio,
      rangeDb: expanderRangeDb,
      attackMs: expanderAttackMs,
      releaseMs: expanderReleaseMs,
      kneeDb: expanderKneeDb,
      sidechainHpfHz: expanderHpfHz,
    );

    player.setConvolverEnabled(convolverEnabled);
    player.setConvolverMix(wet: convolverWet, dry: convolverDry);
    if (convolverEnabled &&
        convolverIrPath != null &&
        convolverIrPath.isNotEmpty) {
      player.loadConvolverIr(convolverIrPath);
    }

    final surroundEnabled =
        masterEnabled && (state['surroundEnabled'] ?? false);
    final surroundMode = SurroundMode.values.firstWhere(
      (e) => e.value == (state['surroundMode'] ?? 0),
      orElse: () => SurroundMode.off,
    );
    player.setSurround(
      enabled: surroundEnabled,
      mode: surroundMode,
      centerFocus: (state['surroundCenterFocus'] as num?)?.toDouble() ?? 0.6,
      surroundBoost:
          (state['surroundSurroundBoost'] as num?)?.toDouble() ?? 1.2,
      surroundDelayMs:
          (state['surroundRearDelayMs'] as num?)?.toDouble() ?? 15.0,
      headRadiusCm: (state['surroundHeadRadiusCm'] as num?)?.toDouble() ?? 8.75,
      binauralMode: (state['surroundBinauralMode'] as num?)?.toInt() ?? 0,
      binauralBoost:
          (state['surroundBinauralBoost'] as num?)?.toDouble() ?? 0.65,
      binauralRoomPreset:
          (state['surroundBinauralRoomPreset'] as num?)?.toInt() ??
              (state['surroundRoomPreset'] as num?)?.toInt() ??
              2,
      binauralRoomMix:
          (state['surroundBinauralRoomMix'] as num?)?.toDouble() ?? 0.35,
      binauralSpeakerAngle:
          (state['surroundBinauralSpeakerAngle'] as num?)?.toInt() ?? 1,
      binauralShadowCutoff:
          (state['surroundBinauralShadowCutoff'] as num?)?.toDouble() ?? 3500.0,
      stageProfile: (state['surroundStageProfile'] as num?)?.toInt() ?? 0,
      stageMode: (state['surroundStageMode'] as num?)?.toInt() ?? 0,
      stageWidth: (state['surroundStageWidth'] as num?)?.toDouble() ??
          (state['surroundFieldWidth'] as num?)?.toDouble() ??
          1.2,
      stageDepth: (state['surroundStageDepth'] as num?)?.toDouble() ?? 0.5,
      stageCancellation:
          (state['surroundStageCancellation'] as num?)?.toDouble() ?? 0.60,
      stageAirPresence:
          (state['surroundStageAirPresence'] as num?)?.toDouble() ?? 0.40,
      stageBassAnchorHz:
          (state['surroundStageBassAnchorHz'] as num?)?.toDouble() ?? 60.0,
    );

    player.setMasterLimiter(
      enabled: limiterEnabled,
      ceilingDb: limiterCeilingDb,
      outputGainDb: limiterOutputGainDb,
      releaseMs: limiterReleaseMs,
    );

    final compressor = await AppStateService.instance.loadCompressor();
    player.setCompressorEnabled(compressor.enabled);
    if (compressor.enabled) {
      player.setCompressorParams(
        thresholdDb: compressor.thresholdDb,
        ratio: compressor.ratio,
        kneeDb: compressor.kneeDb,
        attackMs: compressor.attackMs,
        releaseMs: compressor.releaseMs,
        makeupGainDb: compressor.makeupGainDb,
        detector: compressor.detector,
        stereoLink: compressor.stereoLink,
        autoMakeup: compressor.autoMakeup,
        mix: compressor.mix,
      );
    }

    final parametricEq = await AppStateService.instance.loadParametricEq();
    if (parametricEq.bands.isNotEmpty) {
      final pBands = parametricEq.bands.map((m) {
        final typeIdx = (m['type'] as num?)?.toInt() ?? 0;
        final type = (typeIdx >= 0 && typeIdx < EqBandType.values.length)
            ? EqBandType.values[typeIdx]
            : EqBandType.peak;
        return EqBandConfig(
          type: type,
          frequencyHz: (m['frequency'] as num?)?.toDouble() ?? 1000.0,
          gainDb: (m['gainDb'] as num?)?.toDouble() ?? 0.0,
          q: (m['q'] as num?)?.toDouble() ?? 1.2,
          slope: (m['slope'] as num?)?.toDouble() ?? 1.0,
          enabled: m['enabled'] as bool? ?? true,
        );
      }).toList();
      player.initMultibandFx(pBands,
          enabled: masterEnabled && parametricEq.enabled);
    }
  }

  @override
  State<EqScreen> createState() => _EqScreenState();
}

class _EqScreenState extends State<EqScreen>
    with AutomaticKeepAliveClientMixin {
  @override
  bool get wantKeepAlive => true;

  // Reactive theme colors from BuildContext
  Color get primaryColor => context.primaryColor;
  Color get bgDarkColor => context.bgDark;
  Color get surfaceDarkColor => context.cardDark;
  Color get surfaceDarkerColor => context.cardDark.withValues(alpha: 0.8);

  // Preferences
  bool _showWarningBanner = true;

  // Master EQ
  bool _masterEqEnabled = true;

  // Graphic EQ Frequencies
  List<double> _eqFrequencies = [
    32.0,
    60.0,
    125.0,
    250.0,
    500.0,
    1000.0,
    2000.0,
    4000.0,
    8000.0,
    16000.0
  ];
  List<double> _eqGains = List.filled(10, 0.0);

  void _setupFrequencies(int bands) {
    if (bands == 10) {
      _eqFrequencies = [
        32.0,
        60.0,
        125.0,
        250.0,
        500.0,
        1000.0,
        2000.0,
        4000.0,
        8000.0,
        16000.0
      ];
    } else if (bands == 16) {
      _eqFrequencies = [
        25.0,
        40.0,
        63.0,
        100.0,
        160.0,
        250.0,
        400.0,
        630.0,
        1000.0,
        1600.0,
        2500.0,
        4000.0,
        6300.0,
        10000.0,
        16000.0,
        20000.0
      ];
    } else if (bands == 32) {
      _eqFrequencies = [
        16.0,
        20.0,
        25.0,
        31.5,
        40.0,
        50.0,
        63.0,
        80.0,
        100.0,
        125.0,
        160.0,
        200.0,
        250.0,
        315.0,
        400.0,
        500.0,
        630.0,
        800.0,
        1000.0,
        1250.0,
        1600.0,
        2000.0,
        2500.0,
        3150.0,
        4000.0,
        5000.0,
        6300.0,
        8000.0,
        10000.0,
        12500.0,
        16000.0,
        20000.0
      ];
    } else {
      _eqFrequencies = [];
      for (int i = 0; i < bands; i++) {
        _eqFrequencies
            .add((20.0 * math.pow(1000.0, i / (bands - 1))).roundToDouble());
      }
    }
    if (_eqGains.length != bands) {
      _eqGains = List.filled(bands, 0.0);
    }
  }

  String _activePreset = 'Flat';

  // Parametric EQ state & presets
  String _parametricPreset = 'Default (3-Band)';
  final Map<String, List<EqBandConfig>> _userParametricProfiles = {};
  static const String _kUserParametricProfilesKey =
      'sp_user_parametric_profiles';
  static const String _kActiveParametricPresetKey =
      'sp_active_parametric_preset';

  static const Map<String, List<EqBandConfig>> _builtInParametricPresets = {
    'Default (3-Band)': [
      EqBandConfig(
          type: EqBandType.lowshelf, frequencyHz: 120, gainDb: 0.0, slope: 1.0),
      EqBandConfig(
          type: EqBandType.peak, frequencyHz: 1000, gainDb: 0.0, q: 1.2),
      EqBandConfig(
          type: EqBandType.highshelf,
          frequencyHz: 9000,
          gainDb: 0.0,
          slope: 1.0),
    ],
    'Bass': [
      EqBandConfig(
          type: EqBandType.lowshelf, frequencyHz: 80, gainDb: 5.5, slope: 1.2),
      EqBandConfig(
          type: EqBandType.peak, frequencyHz: 160, gainDb: -2.0, q: 1.8),
      EqBandConfig(
          type: EqBandType.highshelf,
          frequencyHz: 10000,
          gainDb: 1.5,
          slope: 1.0),
    ],
    'Vocal': [
      EqBandConfig(
          type: EqBandType.highpass, frequencyHz: 80, gainDb: 0.0, q: 0.7),
      EqBandConfig(
          type: EqBandType.lowshelf,
          frequencyHz: 200,
          gainDb: -2.0,
          slope: 1.0),
      EqBandConfig(
          type: EqBandType.peak, frequencyHz: 1000, gainDb: 1.0, q: 1.0),
      EqBandConfig(
          type: EqBandType.peak, frequencyHz: 3500, gainDb: 3.5, q: 1.4),
      EqBandConfig(
          type: EqBandType.highshelf,
          frequencyHz: 12000,
          gainDb: 3.0,
          slope: 1.0),
    ],
    'Treble': [
      EqBandConfig(
          type: EqBandType.lowshelf, frequencyHz: 100, gainDb: 0.0, slope: 1.0),
      EqBandConfig(
          type: EqBandType.peak, frequencyHz: 4000, gainDb: 2.0, q: 1.0),
      EqBandConfig(
          type: EqBandType.highshelf,
          frequencyHz: 9000,
          gainDb: 5.0,
          slope: 1.2),
      EqBandConfig(
          type: EqBandType.peak, frequencyHz: 14000, gainDb: 2.0, q: 0.8),
    ],
    'Vintage Tube': [
      EqBandConfig(
          type: EqBandType.lowshelf, frequencyHz: 100, gainDb: 3.0, slope: 1.0),
      EqBandConfig(
          type: EqBandType.peak, frequencyHz: 600, gainDb: 1.0, q: 0.8),
      EqBandConfig(
          type: EqBandType.peak, frequencyHz: 3200, gainDb: -1.5, q: 1.5),
      EqBandConfig(
          type: EqBandType.lowpass, frequencyHz: 16000, gainDb: 0.0, q: 0.7),
    ],
    'Rock': [
      EqBandConfig(
          type: EqBandType.lowshelf, frequencyHz: 90, gainDb: 4.5, slope: 1.2),
      EqBandConfig(
          type: EqBandType.peak, frequencyHz: 450, gainDb: -3.0, q: 1.6),
      EqBandConfig(
          type: EqBandType.peak, frequencyHz: 2600, gainDb: 3.5, q: 1.8),
      EqBandConfig(
          type: EqBandType.highshelf,
          frequencyHz: 8500,
          gainDb: 3.0,
          slope: 1.0),
    ],
    'Electronic': [
      EqBandConfig(
          type: EqBandType.highpass, frequencyHz: 28, gainDb: 0.0, q: 0.7),
      EqBandConfig(type: EqBandType.peak, frequencyHz: 55, gainDb: 5.5, q: 2.0),
      EqBandConfig(
          type: EqBandType.peak, frequencyHz: 300, gainDb: -2.5, q: 1.4),
      EqBandConfig(
          type: EqBandType.peak, frequencyHz: 4000, gainDb: 2.0, q: 1.2),
      EqBandConfig(
          type: EqBandType.highshelf,
          frequencyHz: 10000,
          gainDb: 3.5,
          slope: 1.0),
    ],
    'Acoustic Guitar': [
      EqBandConfig(
          type: EqBandType.highpass, frequencyHz: 50, gainDb: 0.0, q: 0.7),
      EqBandConfig(
          type: EqBandType.notch, frequencyHz: 200, gainDb: 0.0, q: 6.0),
      EqBandConfig(
          type: EqBandType.peak, frequencyHz: 3000, gainDb: 2.0, q: 1.4),
      EqBandConfig(
          type: EqBandType.highshelf,
          frequencyHz: 11000,
          gainDb: 2.5,
          slope: 1.0),
    ],
    'Speaker protection': [
      EqBandConfig(
          type: EqBandType.highpass, frequencyHz: 40, gainDb: 0.0, q: 0.7),
      EqBandConfig(
          type: EqBandType.notch, frequencyHz: 60, gainDb: 0.0, q: 10.0),
      EqBandConfig(
          type: EqBandType.notch, frequencyHz: 120, gainDb: 0.0, q: 8.0),
    ],
    'Voc': [
      EqBandConfig(
          type: EqBandType.highpass, frequencyHz: 400, gainDb: 0.0, q: 0.7),
      EqBandConfig(
          type: EqBandType.peak, frequencyHz: 1800, gainDb: 3.0, q: 1.2),
      EqBandConfig(
          type: EqBandType.lowpass, frequencyHz: 3500, gainDb: 0.0, q: 0.7),
    ],
    'Loudness': [
      EqBandConfig(
          type: EqBandType.lowshelf, frequencyHz: 65, gainDb: 6.0, slope: 1.2),
      EqBandConfig(
          type: EqBandType.peak, frequencyHz: 1000, gainDb: -2.5, q: 1.0),
      EqBandConfig(
          type: EqBandType.highshelf,
          frequencyHz: 8500,
          gainDb: 4.5,
          slope: 1.2),
    ],
    'Octave Series (30-60-120...)': [
      EqBandConfig(type: EqBandType.peak, frequencyHz: 30, gainDb: 0.0, q: 1.4),
      EqBandConfig(type: EqBandType.peak, frequencyHz: 60, gainDb: 0.0, q: 1.4),
      EqBandConfig(
          type: EqBandType.peak, frequencyHz: 120, gainDb: 0.0, q: 1.4),
      EqBandConfig(
          type: EqBandType.peak, frequencyHz: 240, gainDb: 0.0, q: 1.4),
      EqBandConfig(
          type: EqBandType.peak, frequencyHz: 480, gainDb: 0.0, q: 1.4),
      EqBandConfig(
          type: EqBandType.peak, frequencyHz: 960, gainDb: 0.0, q: 1.4),
      EqBandConfig(
          type: EqBandType.peak, frequencyHz: 1920, gainDb: 0.0, q: 1.4),
      EqBandConfig(
          type: EqBandType.peak, frequencyHz: 3840, gainDb: 0.0, q: 1.4),
      EqBandConfig(
          type: EqBandType.peak, frequencyHz: 7680, gainDb: 0.0, q: 1.4),
      EqBandConfig(
          type: EqBandType.peak, frequencyHz: 15360, gainDb: 0.0, q: 1.4),
    ],
    'Linear +30Hz (60-90-120...)': [
      EqBandConfig(type: EqBandType.peak, frequencyHz: 60, gainDb: 0.0, q: 1.4),
      EqBandConfig(type: EqBandType.peak, frequencyHz: 90, gainDb: 0.0, q: 1.4),
      EqBandConfig(
          type: EqBandType.peak, frequencyHz: 120, gainDb: 0.0, q: 1.4),
      EqBandConfig(
          type: EqBandType.peak, frequencyHz: 150, gainDb: 0.0, q: 1.4),
      EqBandConfig(
          type: EqBandType.peak, frequencyHz: 180, gainDb: 0.0, q: 1.4),
      EqBandConfig(
          type: EqBandType.peak, frequencyHz: 210, gainDb: 0.0, q: 1.4),
      EqBandConfig(
          type: EqBandType.peak, frequencyHz: 240, gainDb: 0.0, q: 1.4),
      EqBandConfig(
          type: EqBandType.peak, frequencyHz: 270, gainDb: 0.0, q: 1.4),
    ],
    'Linear +45Hz (45-90-135...)': [
      EqBandConfig(type: EqBandType.peak, frequencyHz: 45, gainDb: 0.0, q: 1.4),
      EqBandConfig(type: EqBandType.peak, frequencyHz: 90, gainDb: 0.0, q: 1.4),
      EqBandConfig(
          type: EqBandType.peak, frequencyHz: 135, gainDb: 0.0, q: 1.4),
      EqBandConfig(
          type: EqBandType.peak, frequencyHz: 180, gainDb: 0.0, q: 1.4),
      EqBandConfig(
          type: EqBandType.peak, frequencyHz: 225, gainDb: 0.0, q: 1.4),
      EqBandConfig(
          type: EqBandType.peak, frequencyHz: 270, gainDb: 0.0, q: 1.4),
      EqBandConfig(
          type: EqBandType.peak, frequencyHz: 315, gainDb: 0.0, q: 1.4),
      EqBandConfig(
          type: EqBandType.peak, frequencyHz: 360, gainDb: 0.0, q: 1.4),
    ],
  };

  final List<EqBandConfig> _parametricBands = [
    const EqBandConfig(
        type: EqBandType.lowshelf, frequencyHz: 120, gainDb: 0.0, slope: 1.0),
    const EqBandConfig(
        type: EqBandType.peak, frequencyHz: 1000, gainDb: 0.0, q: 1.2),
    const EqBandConfig(
        type: EqBandType.highshelf, frequencyHz: 9000, gainDb: 0.0, slope: 1.0),
  ];
  bool _parametricEqEnabled = false;

  // Crystalizer
  bool _crystalizerEnabled = false;
  double _crystalizerIntensity = 0.5;
  bool _crystalizerHighShelf = true;
  double _crystalizerShelfGain = 2.0;

  // Audiophile Crossfeed
  int _crossfeedPreset = 1;
  int _crossfeedAlgorithmIndex =
      2; // 1=Simple, 2=BS2B, 3=Meier, 4=Natural, 5=RACE
  bool _crossfeedEnabled = false;
  double _crossfeedMix = 0.5;
  double _crossfeedDelayMs = 0.40;
  double _crossfeedCutoffHz = 700.0;
  bool _crossfeedCompensation = true;
  double _raceDelayMs = 0.166;
  double _raceAlpha = 0.55;
  double _raceLpfHz = 2500.0;

  // Stereo Widen
  bool _stereoWidenEnabled = false;
  double _stereoWidenWidth = 1.5;
  double _stereoWidenDelayMs = 0.15; // Maps to 15ms

  // DSP Stereo Enhancer
  bool _stereoEnhancementEnabled = false;
  double _stereoEnhancementMix = 0.5;

  // Reverb (Freeverb FDN)
  static const List<
      ({
        String name,
        double wet,
        double dry,
        double roomSize,
        double damping,
        double preDelayMs,
        double width
      })> _reverbPresets = [
    (
      name: 'Custom',
      wet: 0.25,
      dry: 0.75,
      roomSize: 0.6,
      damping: 0.4,
      preDelayMs: 20.0,
      width: 1.0
    ),
    (
      name: 'Small Room',
      wet: 0.22,
      dry: 1.0,
      roomSize: 0.25,
      damping: 0.55,
      preDelayMs: 8.0,
      width: 0.9
    ),
    (
      name: 'Live Club',
      wet: 0.28,
      dry: 0.95,
      roomSize: 0.42,
      damping: 0.45,
      preDelayMs: 12.0,
      width: 1.0
    ),
    (
      name: 'Concert Hall',
      wet: 0.35,
      dry: 0.90,
      roomSize: 0.72,
      damping: 0.35,
      preDelayMs: 25.0,
      width: 1.0
    ),
    (
      name: 'Cathedral',
      wet: 0.45,
      dry: 0.85,
      roomSize: 0.95,
      damping: 0.20,
      preDelayMs: 60.0,
      width: 1.0
    ),
    (
      name: 'Studio Plate',
      wet: 0.32,
      dry: 1.0,
      roomSize: 0.50,
      damping: 0.05,
      preDelayMs: 4.0,
      width: 1.0
    ),
    (
      name: 'Ambient Drift',
      wet: 0.55,
      dry: 0.70,
      roomSize: 0.85,
      damping: 0.10,
      preDelayMs: 45.0,
      width: 1.0
    ),
  ];

  String _reverbPreset = 'Custom';
  bool _reverbEnabled = false;
  double _reverbWet = 0.25;
  double _reverbDry = 0.75;
  double _reverbRoomSize = 0.6;
  double _reverbDamping = 0.4;
  double _reverbPreDelayMs = 20.0;
  double _reverbWidth = 1.0;

  // Audio Tuning (3-band EQ)
  bool _audioTuningEnabled = false;
  double _tuneLow = 0.0;
  double _tuneMid = 0.0;
  double _tuneHigh = 0.0;

  // Preamp
  double _preampDb = 0.0; // Simulated gain offset
  // Subscriptions
  StreamSubscription<void>? _eqSettingsSub;

  // Soft Limiter
  bool _limiterEnabled = false;
  double _limiterThreshold = 0.95; // 0.1 – 1.0
  double _limiterAttackMs = 2.0; // 0.1 – 100 ms
  double _limiterReleaseMs = 50.0; // 10 – 1000 ms

  // Dynamic Range Compressor
  static const List<
      ({
        String name,
        double thresholdDb,
        double ratio,
        double kneeDb,
        double attackMs,
        double releaseMs,
        double makeupGainDb,
        int detector,
        bool stereoLink,
        bool autoMakeup,
        double mix,
      })> _compressorPresets = [
    (
      name: 'Custom',
      thresholdDb: -20.0,
      ratio: 4.0,
      kneeDb: 6.0,
      attackMs: 10.0,
      releaseMs: 100.0,
      makeupGainDb: 0.0,
      detector: 0,
      stereoLink: true,
      autoMakeup: false,
      mix: 1.0,
    ),
    (
      name: 'Vocal Punch',
      thresholdDb: -18.0,
      ratio: 3.5,
      kneeDb: 4.0,
      attackMs: 15.0,
      releaseMs: 80.0,
      makeupGainDb: 2.0,
      detector: 1,
      stereoLink: true,
      autoMakeup: false,
      mix: 1.0,
    ),
    (
      name: 'Master Glue',
      thresholdDb: -12.0,
      ratio: 2.0,
      kneeDb: 6.0,
      attackMs: 30.0,
      releaseMs: 120.0,
      makeupGainDb: 1.0,
      detector: 1,
      stereoLink: true,
      autoMakeup: false,
      mix: 1.0,
    ),
    (
      name: 'Drum Tamer',
      thresholdDb: -16.0,
      ratio: 6.0,
      kneeDb: 2.0,
      attackMs: 5.0,
      releaseMs: 50.0,
      makeupGainDb: 3.0,
      detector: 0,
      stereoLink: true,
      autoMakeup: false,
      mix: 1.0,
    ),
    (
      name: 'Gentle Leveler',
      thresholdDb: -24.0,
      ratio: 2.5,
      kneeDb: 8.0,
      attackMs: 40.0,
      releaseMs: 250.0,
      makeupGainDb: 3.5,
      detector: 1,
      stereoLink: true,
      autoMakeup: false,
      mix: 1.0,
    ),
    (
      name: 'Bass Control',
      thresholdDb: -20.0,
      ratio: 4.0,
      kneeDb: 5.0,
      attackMs: 20.0,
      releaseMs: 150.0,
      makeupGainDb: 2.5,
      detector: 1,
      stereoLink: true,
      autoMakeup: false,
      mix: 1.0,
    ),
    (
      name: 'Hard Slam',
      thresholdDb: -28.0,
      ratio: 12.0,
      kneeDb: 1.0,
      attackMs: 1.0,
      releaseMs: 40.0,
      makeupGainDb: 6.0,
      detector: 0,
      stereoLink: true,
      autoMakeup: false,
      mix: 1.0,
    ),
  ];

  String _compressorPreset = 'Custom';
  bool _compressorEnabled = false;
  double _compressorThresholdDb = -20.0;
  double _compressorRatio = 4.0;
  double _compressorKneeDb = 6.0;
  double _compressorAttackMs = 10.0;
  double _compressorReleaseMs = 100.0;
  double _compressorMakeupGainDb = 0.0;
  int _compressorDetector = 0; // 0=Peak, 1=RMS
  bool _compressorStereoLink = true;
  bool _compressorAutoMakeup = false;
  double _compressorMix = 1.0;
  double _compressorGainReductionDb = 0.0;
  Timer? _compressorMeterTimer;

  // ── Sauti DSP Suite States ──
  // 1. Audio Clarity
  bool _clarityEnabled = false;
  AudioClarityProfile _clarityProfile = AudioClarityProfile.transientCrisp;
  double _clarityIntensity = 0.5;

  // 1b. Dialogue Booster & Enhancer (reconstructed from Dolby DAP)
  bool _dialogEnhancerEnabled = false;
  DialogEnhancerProfile _dialogEnhancerProfile = DialogEnhancerProfile.cinema;
  double _dialogEnhancerAmount = 0.65;
  double _dialogEnhancerDucking = 0.55;
  double _dialogEnhancerClarity = 0.60;
  double _dialogEnhancerCenterFocus = 0.70;

  // 2. Harmonic / Dynamic Multi-Pole Bass
  bool _bassEnabled = false;
  HarmonicBassProfile _bassProfile = HarmonicBassProfile.dynamicMultiPole;
  double _bassCutoffHz = 60.0;
  double _bassBoost = 0.5;
  int _bassPreset = 18;
  double _bassGainDb = 15.0;

  // 3. Dynamic Transducer System
  bool _dynamicSystemEnabled = false;
  TransducerProfile _dynamicSystemProfile = TransducerProfile.earphone;
  double _dynamicSystemStrength = 0.5;

  // 4. Analog Warmth
  bool _analogWarmthEnabled = false;
  AnalogWarmthProfile _analogWarmthProfile = AnalogWarmthProfile.triode12AX7;
  double _analogWarmthDrive = 0.5;

  // 4a. De-Esser (Sibilance Reducer)
  bool _deEsserEnabled = false;
  DeEsserMode _deEsserMode = DeEsserMode.splitBand;
  DeEsserPreset _deEsserPreset = DeEsserPreset.gentleVocal;
  double _deEsserFrequencyHz = 5500.0;
  double _deEsserThresholdDb = -22.0;
  double _deEsserRatio = 4.0;
  double _deEsserMaxReductionDb = 12.0;
  double _deEsserAttackMs = 1.0;
  double _deEsserReleaseMs = 35.0;
  double _deEsserGainReductionDb = 0.0;

  // 4b. Downward Expander (Vinyl & Tape Noise Floor Reducer)
  bool _expanderEnabled = false;
  DownwardExpanderPreset _expanderPreset = DownwardExpanderPreset.vinylClean;
  double _expanderThresholdDb = -52.0;
  double _expanderRatio = 1.8;
  double _expanderRangeDb = -16.0;
  double _expanderAttackMs = 12.0;
  double _expanderReleaseMs = 280.0;
  double _expanderKneeDb = 6.0;
  double _expanderHpfCutoffHz = 50.0;

  // 5. FFT Convolver
  bool _convolverEnabled = false;
  String? _convolverIrPath;
  String? _convolverIrFileName;
  double _convolverWet = 1.0;
  double _convolverDry = 0.0;

  /// Built-in HRIR (head-related impulse response) presets bundled as assets.
  static const List<({String label, String asset})> _builtinHrirs = [
    (label: 'Dolby Atmos', asset: 'assets/hrirs/atmos.wav'),
    (label: 'DH+', asset: 'assets/hrirs/dh+.wav'),
    (label: 'DH++', asset: 'assets/hrirs/dh++.wav'),
    (label: 'DS3D', asset: 'assets/hrirs/ds3d.wav'),
    (label: 'DS3D+', asset: 'assets/hrirs/ds3d+.wav'),
    (label: 'DS3D++', asset: 'assets/hrirs/ds3d++.wav'),
    (label: 'DS3D+++', asset: 'assets/hrirs/ds3d+++.wav'),
    (label: 'DTS:X', asset: 'assets/hrirs/dtshx.wav'),
    (label: 'DTS:X Lite', asset: 'assets/hrirs/dtshx-.wav'),
    (label: 'GSX', asset: 'assets/hrirs/gsx.wav'),
    (label: 'Sonic', asset: 'assets/hrirs/sonic.wav'),
    (label: 'Sonic+', asset: 'assets/hrirs/sonic+.wav'),
  ];

  final List<M3EDropdownItem<String>> _hrirItems = [
    for (final h in _builtinHrirs)
      M3EDropdownItem(label: h.label, value: h.asset),
  ];

  // 5b. Spatial Surround Suite
  bool _surroundEnabled = false;
  SurroundMode _surroundMode = SurroundMode.off;

  // Mode 1: Cinema Matrix 5.1 (Cleanroom Pro Logic II)
  double _surroundCenterFocus = 0.6;
  double _surroundSurroundBoost = 1.2;
  double _surroundRearDelayMs = 15.0;
  double _surroundHeadRadiusCm = 8.75;

  // Mode 2: Binaural HRTF Virtualizer (Reconstructed from Dolby analysis_dlby2)
  int _surroundBinauralMode = 0; // 0=Headphone HRTF, 1=Speaker Field
  double _surroundBinauralBoost = 0.65;
  int _surroundBinauralRoomPreset = 2; // 1=Studio, 2=Cinema, 3=Concert Hall
  double _surroundBinauralRoomMix = 0.35;
  int _surroundBinauralSpeakerAngle =
      1; // 0=Narrow (10°), 1=Standard (30°), 2=Wide (45°)
  double _surroundBinauralShadowCutoff = 3500.0;

  // Mode 3: 3D Acoustic Stage (Reconstructed from AM3D Zirene re_workspace)
  int _surroundStageProfile = 0; // 0=Headset, 1=Speaker
  int _surroundStageMode = 0; // 0=Studio (Normal), 1=Panoramic (Wide)
  double _surroundStageWidth = 1.2;
  double _surroundStageDepth = 0.5;
  double _surroundStageCancellation = 0.60;
  double _surroundStageAirPresence = 0.40;
  double _surroundStageBassAnchorHz = 60.0;

  // 6. Master Peak Limiter
  bool _masterLimiterEnabled = false;
  double _masterLimiterCeilingDb = -0.1;
  double _masterLimiterOutputGainDb = 0.0;
  double _masterLimiterReleaseMs = 60.0;

  // Playback Speed, Pitch & Status
  double _playbackRate = 1.0;
  double _playbackPitch = 1.0;
  bool _playbackPitchCorrection = true;
  bool _isPlaying = false;
  StreamSubscription<PlayerStatus>? _statusSub;

  StateSetter? _subScreenSetState;

  late final M3EDropdownController<String> _hrirDropdownController =
      M3EDropdownController<String>();

  @override
  void setState(VoidCallback fn) {
    super.setState(fn);
    _subScreenSetState?.call(() {});
  }

  @override
  void initState() {
    super.initState();
    _loadPreferences();
    _initEq();
    widget.player.setAnalyzerEnabled(true);
    widget.player.configureAnalyzer(frameSize: 512);

    _statusSub = widget.player.statusStream.listen((status) {
      if (mounted && _isPlaying != status.isPlaying) {
        setState(() {
          _isPlaying = status.isPlaying;
        });
      }
    });

    _compressorMeterTimer =
        Timer.periodic(const Duration(milliseconds: 60), (_) async {
      if (!mounted) return;
      if (_compressorEnabled && _isPlaying) {
        final gr = await widget.player.getCompressorGainReductionDB();
        if (mounted && (_compressorGainReductionDb - gr).abs() > 0.05) {
          setState(() {
            _compressorGainReductionDb = gr;
          });
        }
      } else if (_compressorGainReductionDb != 0.0) {
        if (mounted) {
          setState(() {
            _compressorGainReductionDb = 0.0;
          });
        }
      }

      if (_deEsserEnabled && _isPlaying) {
        final deGr = await widget.player.getDeEsserGainReductionDB();
        if (mounted && (_deEsserGainReductionDb - deGr).abs() > 0.05) {
          setState(() {
            _deEsserGainReductionDb = deGr;
          });
        }
      } else if (_deEsserGainReductionDb != 0.0) {
        if (mounted) {
          setState(() {
            _deEsserGainReductionDb = 0.0;
          });
        }
      }
    });

    _eqSettingsSub =
        AppStateService.instance.eqSettingsChanged.stream.listen((_) {
      if (mounted) _loadPreferences();
    });
  }

  @override
  void dispose() {
    _compressorMeterTimer?.cancel();
    _statusSub?.cancel();
    _eqSettingsSub?.cancel();
    _hrirDropdownController.dispose();
    widget.player.setAnalyzerEnabled(false);
    super.dispose();
  }

  Future<void> _loadPreferences() async {
    final prefs = await SharedPreferences.getInstance();
    final hideBanner = prefs.getBool('hide_eq_warning') ?? false;

    // Load all persisted EQ state
    final rate = await AppStateService.instance.loadPlaybackRate();
    final pitch = await AppStateService.instance.loadPlaybackPitch();
    final pitchCorrection =
        await AppStateService.instance.loadPitchCorrection();
    final eqBands = await AppStateService.instance.loadEqBands();
    final crystalizer = await AppStateService.instance.loadCrystalizer();
    final stereoWiden = await AppStateService.instance.loadStereoWiden();
    final stereoEnhancement =
        await AppStateService.instance.loadStereoEnhancement();
    final reverb = await AppStateService.instance.loadReverb();
    final crossfeed = await AppStateService.instance.loadCrossfeed();
    final raceParams = await AppStateService.instance.loadRaceParams();
    final tuning = await AppStateService.instance.loadAudioTuning();
    final limiter = await AppStateService.instance.loadLimiter();
    final compressor = await AppStateService.instance.loadCompressor();

    setState(() {
      _showWarningBanner = !hideBanner;
      _playbackRate = rate;
      _playbackPitch = pitch;
      _playbackPitchCorrection = pitchCorrection;

      // EQ bands
      _masterEqEnabled = eqBands.enabled;
      _activePreset = eqBands.preset;
      _setupFrequencies(eqBands.bandCount);
      if (eqBands.gains.length == _eqGains.length) {
        for (int i = 0; i < _eqGains.length; i++) {
          _eqGains[i] = eqBands.gains[i];
        }
      }
      _preampDb = eqBands.preampDb;

      // Crystalizer
      _crystalizerEnabled = crystalizer.enabled;
      _crystalizerIntensity = crystalizer.intensity;
      _crystalizerHighShelf = crystalizer.highShelfEnabled;
      _crystalizerShelfGain = crystalizer.highShelfGainDb;

      // Crossfeed
      _crossfeedEnabled = crossfeed.enabled;
      _crossfeedPreset = crossfeed.preset > 0 ? crossfeed.preset : 1;
      _crossfeedAlgorithmIndex = crossfeed.algoIndex;
      _crossfeedMix = crossfeed.mix;
      _crossfeedDelayMs = crossfeed.delayMs;
      _crossfeedCutoffHz = crossfeed.cutoffHz;
      _crossfeedCompensation = crossfeed.outputCompensation;
      _raceDelayMs = raceParams.delayMs;
      _raceAlpha = raceParams.alpha;
      _raceLpfHz = raceParams.lpfHz;

      // Stereo Widen
      _stereoWidenEnabled = stereoWiden.enabled;
      _stereoWidenWidth = stereoWiden.width;
      _stereoWidenDelayMs = stereoWiden.delayMs;

      // DSP Stereo Enhancer
      _stereoEnhancementEnabled = stereoEnhancement.enabled;
      _stereoEnhancementMix = stereoEnhancement.mix;

      // Reverb (Freeverb FDN)
      _reverbEnabled = reverb.enabled;
      _reverbPreset = reverb.preset;
      _reverbWet = reverb.wet;
      _reverbDry = reverb.dry;
      _reverbRoomSize = reverb.roomSize;
      _reverbDamping = reverb.damping;
      _reverbPreDelayMs = reverb.preDelayMs;
      _reverbWidth = reverb.width;

      // Audio Tuning
      _audioTuningEnabled = tuning.enabled;
      _tuneLow = tuning.low;
      _tuneMid = tuning.mid;
      _tuneHigh = tuning.high;

      // Limiter
      _limiterEnabled = limiter.enabled;
      _limiterThreshold = limiter.threshold;
      _limiterAttackMs = limiter.attackMs;
      _limiterReleaseMs = limiter.releaseMs;

      // Compressor
      _compressorEnabled = compressor.enabled;
      _compressorThresholdDb = compressor.thresholdDb;
      _compressorRatio = compressor.ratio;
      _compressorKneeDb = compressor.kneeDb;
      _compressorAttackMs = compressor.attackMs;
      _compressorReleaseMs = compressor.releaseMs;
      _compressorMakeupGainDb = compressor.makeupGainDb;
      _compressorDetector = compressor.detector;
      _compressorStereoLink = compressor.stereoLink;
      _compressorAutoMakeup = compressor.autoMakeup;
      _compressorMix = compressor.mix;
    });

    // Load Sauti DSP Suite state
    final dspMap = await AppStateService.instance.loadSautiDspState();
    if (dspMap.isNotEmpty && mounted) {
      setState(() {
        _clarityEnabled = dspMap['clarityEnabled'] ?? false;
        _clarityProfile = AudioClarityProfile.values.firstWhere(
          (e) => e.value == (dspMap['clarityProfile'] ?? 0),
          orElse: () => AudioClarityProfile.transientCrisp,
        );
        _clarityIntensity =
            (dspMap['clarityIntensity'] as num?)?.toDouble() ?? 0.5;

        _dialogEnhancerEnabled = dspMap['dialogEnhancerEnabled'] ?? false;
        _dialogEnhancerProfile = DialogEnhancerProfile.values.firstWhere(
          (e) => e.value == (dspMap['dialogEnhancerProfile'] ?? 0),
          orElse: () => DialogEnhancerProfile.cinema,
        );
        _dialogEnhancerAmount =
            (dspMap['dialogEnhancerAmount'] as num?)?.toDouble() ?? 0.65;
        _dialogEnhancerDucking =
            (dspMap['dialogEnhancerDucking'] as num?)?.toDouble() ?? 0.55;
        _dialogEnhancerClarity =
            (dspMap['dialogEnhancerClarity'] as num?)?.toDouble() ?? 0.60;
        _dialogEnhancerCenterFocus =
            (dspMap['dialogEnhancerCenterFocus'] as num?)?.toDouble() ?? 0.70;

        _bassEnabled = dspMap['bassEnabled'] ?? false;
        _bassProfile = HarmonicBassProfile.values.firstWhere(
          (e) => e.value == (dspMap['bassProfile'] ?? 5),
          orElse: () => HarmonicBassProfile.dynamicMultiPole,
        );
        _bassCutoffHz = (dspMap['bassCutoffHz'] as num?)?.toDouble() ?? 60.0;
        _bassBoost = (dspMap['bassBoost'] as num?)?.toDouble() ?? 0.5;
        _bassPreset = (dspMap['bassPreset'] as num?)?.toInt() ?? 18;
        _bassGainDb = (dspMap['bassGainDb'] as num?)?.toDouble() ?? 15.0;

        _dynamicSystemEnabled = dspMap['dynamicSystemEnabled'] ?? false;
        _dynamicSystemProfile = TransducerProfile.values.firstWhere(
          (e) => e.value == (dspMap['dynamicSystemProfile'] ?? 0),
          orElse: () => TransducerProfile.earphone,
        );
        _dynamicSystemStrength =
            (dspMap['dynamicSystemStrength'] as num?)?.toDouble() ?? 0.5;

        _analogWarmthEnabled = dspMap['analogWarmthEnabled'] ?? false;
        _analogWarmthProfile = AnalogWarmthProfile.values.firstWhere(
          (e) => e.value == (dspMap['analogWarmthProfile'] ?? 0),
          orElse: () => AnalogWarmthProfile.triode12AX7,
        );
        _analogWarmthDrive =
            (dspMap['analogWarmthDrive'] as num?)?.toDouble() ?? 0.5;

        _deEsserEnabled = dspMap['deEsserEnabled'] ?? false;
        _deEsserMode = DeEsserMode.values.firstWhere(
          (e) => e.value == (dspMap['deEsserMode'] ?? 0),
          orElse: () => DeEsserMode.splitBand,
        );
        _deEsserPreset = DeEsserPreset.values.firstWhere(
          (e) => e.value == (dspMap['deEsserPreset'] ?? 0),
          orElse: () => DeEsserPreset.gentleVocal,
        );
        _deEsserFrequencyHz =
            (dspMap['deEsserFrequencyHz'] as num?)?.toDouble() ?? 5500.0;
        _deEsserThresholdDb =
            (dspMap['deEsserThresholdDb'] as num?)?.toDouble() ?? -22.0;
        _deEsserRatio =
            (dspMap['deEsserRatio'] as num?)?.toDouble() ?? 4.0;
        _deEsserMaxReductionDb =
            (dspMap['deEsserMaxReductionDb'] as num?)?.toDouble() ?? 12.0;
        _deEsserAttackMs =
            (dspMap['deEsserAttackMs'] as num?)?.toDouble() ?? 1.0;
        _deEsserReleaseMs =
            (dspMap['deEsserReleaseMs'] as num?)?.toDouble() ?? 35.0;

        _expanderEnabled = dspMap['expanderEnabled'] ?? false;
        _expanderPreset = DownwardExpanderPreset.values.firstWhere(
          (e) => e.value == (dspMap['expanderPreset'] ?? 0),
          orElse: () => DownwardExpanderPreset.vinylClean,
        );
        _expanderThresholdDb =
            (dspMap['expanderThresholdDb'] as num?)?.toDouble() ?? -52.0;
        _expanderRatio = (dspMap['expanderRatio'] as num?)?.toDouble() ?? 1.8;
        _expanderRangeDb =
            (dspMap['expanderRangeDb'] as num?)?.toDouble() ?? -16.0;
        _expanderAttackMs =
            (dspMap['expanderAttackMs'] as num?)?.toDouble() ?? 12.0;
        _expanderReleaseMs =
            (dspMap['expanderReleaseMs'] as num?)?.toDouble() ?? 280.0;
        _expanderKneeDb = (dspMap['expanderKneeDb'] as num?)?.toDouble() ?? 6.0;
        _expanderHpfCutoffHz =
            (dspMap['expanderHpfHz'] as num?)?.toDouble() ?? 50.0;

        _convolverEnabled = dspMap['convolverEnabled'] ?? false;
        _convolverIrPath = dspMap['convolverIrPath'] as String?;
        if (_convolverIrPath != null && _convolverIrPath!.isNotEmpty) {
          _convolverIrFileName = p.basename(_convolverIrPath!);
        }
        _convolverWet = (dspMap['convolverWet'] as num?)?.toDouble() ?? 1.0;
        _convolverDry = (dspMap['convolverDry'] as num?)?.toDouble() ?? 0.0;

        _surroundEnabled = dspMap['surroundEnabled'] ?? false;
        _surroundMode = SurroundMode.values.firstWhere(
          (e) => e.value == (dspMap['surroundMode'] ?? 0),
          orElse: () => SurroundMode.off,
        );
        _surroundCenterFocus =
            (dspMap['surroundCenterFocus'] as num?)?.toDouble() ?? 0.6;
        _surroundSurroundBoost =
            (dspMap['surroundSurroundBoost'] as num?)?.toDouble() ?? 1.2;
        _surroundRearDelayMs =
            (dspMap['surroundRearDelayMs'] as num?)?.toDouble() ?? 15.0;
        _surroundHeadRadiusCm =
            (dspMap['surroundHeadRadiusCm'] as num?)?.toDouble() ?? 8.75;

        _surroundBinauralMode =
            (dspMap['surroundBinauralMode'] as num?)?.toInt() ?? 0;
        _surroundBinauralBoost =
            (dspMap['surroundBinauralBoost'] as num?)?.toDouble() ?? 0.65;
        _surroundBinauralRoomPreset =
            (dspMap['surroundBinauralRoomPreset'] as num?)?.toInt() ??
                (dspMap['surroundRoomPreset'] as num?)?.toInt() ??
                2;
        _surroundBinauralRoomMix =
            (dspMap['surroundBinauralRoomMix'] as num?)?.toDouble() ?? 0.35;
        _surroundBinauralSpeakerAngle =
            (dspMap['surroundBinauralSpeakerAngle'] as num?)?.toInt() ?? 1;
        _surroundBinauralShadowCutoff =
            (dspMap['surroundBinauralShadowCutoff'] as num?)?.toDouble() ??
                3500.0;

        _surroundStageProfile =
            (dspMap['surroundStageProfile'] as num?)?.toInt() ?? 0;
        _surroundStageMode =
            (dspMap['surroundStageMode'] as num?)?.toInt() ?? 0;
        _surroundStageWidth =
            (dspMap['surroundStageWidth'] as num?)?.toDouble() ??
                (dspMap['surroundFieldWidth'] as num?)?.toDouble() ??
                1.2;
        _surroundStageDepth =
            (dspMap['surroundStageDepth'] as num?)?.toDouble() ?? 0.5;
        _surroundStageCancellation =
            (dspMap['surroundStageCancellation'] as num?)?.toDouble() ?? 0.60;
        _surroundStageAirPresence =
            (dspMap['surroundStageAirPresence'] as num?)?.toDouble() ?? 0.40;
        _surroundStageBassAnchorHz =
            (dspMap['surroundStageBassAnchorHz'] as num?)?.toDouble() ?? 60.0;

        _masterLimiterEnabled = dspMap['limiterEnabled'] ?? false;
        _masterLimiterCeilingDb =
            (dspMap['limiterCeilingDb'] as num?)?.toDouble() ?? -0.1;
        _masterLimiterOutputGainDb =
            (dspMap['limiterOutputGainDb'] as num?)?.toDouble() ?? 0.0;
        _masterLimiterReleaseMs =
            (dspMap['limiterReleaseMs'] as num?)?.toDouble() ?? 60.0;
      });
    }

    // Sync built-in HRIR dropdown selection with a restored asset IR
    if (mounted && _isBuiltinHrir(_convolverIrPath)) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        _hrirDropdownController
          ..clearAll()
          ..selectWhere((item) => item.value == _convolverIrPath);
      });
    }

    // Apply loaded state to the audio engine
    widget.player.setMultibandEqEnabled(_masterEqEnabled);
    widget.player.initMultibandEq(_eqFrequencies);
    _applyEqGains();
    _applyStoredPreamp();

    if (_crystalizerEnabled) {
      _updateCrystalizer();
    }
    if (_crossfeedEnabled) {
      _updateCrossfeed();
    }
    if (_stereoWidenEnabled) {
      _updateStereoWiden();
    }
    if (_stereoEnhancementEnabled) {
      _updateStereoEnhancement();
    }
    if (_reverbEnabled) {
      _updateReverb();
    }
    if (_audioTuningEnabled) {
      widget.player.setEqEnabled(true);
      widget.player.setEq(low: _tuneLow, mid: _tuneMid, high: _tuneHigh);
    }
    if (_limiterEnabled) {
      _applyLimiter();
    }
    if (_compressorEnabled) {
      _updateCompressor();
    }

    // Apply Sauti DSP suite
    _updateClarity();
    _updateDialogEnhancer();
    _updateHarmonicBass();
    _updateDynamicSystem();
    _updateAnalogWarmth();
    _updateConvolver();
    _updateSurround();
    _updateMasterLimiter();

    // Load user parametric profiles and saved parametric EQ
    await _loadUserParametricProfiles();
    final parametricEq = await AppStateService.instance.loadParametricEq();
    if (mounted) {
      setState(() {
        _parametricEqEnabled = parametricEq.enabled;
        _parametricBands.clear();
        for (final m in parametricEq.bands) {
          final typeIdx = (m['type'] as num?)?.toInt() ?? 0;
          final type = (typeIdx >= 0 && typeIdx < EqBandType.values.length)
              ? EqBandType.values[typeIdx]
              : EqBandType.peak;
          _parametricBands.add(EqBandConfig(
            type: type,
            frequencyHz: (m['frequency'] as num?)?.toDouble() ?? 1000.0,
            gainDb: (m['gainDb'] as num?)?.toDouble() ?? 0.0,
            q: (m['q'] as num?)?.toDouble() ?? 1.2,
            slope: (m['slope'] as num?)?.toDouble() ?? 1.0,
            enabled: m['enabled'] as bool? ?? true,
          ));
        }
      });
      if (_parametricBands.isNotEmpty) {
        widget.player
            .initMultibandFx(_parametricBands, enabled: _parametricEqEnabled);
      }
      widget.player.setMultibandFxEnabled(_parametricEqEnabled);
      _subScreenSetState?.call(() {});
    }
  }

  void _updateClarity() {
    widget.player.setClarity(
      enabled: _clarityEnabled,
      profile: _clarityProfile,
      intensity: _clarityIntensity,
    );
  }

  void _updateDialogEnhancer() {
    widget.player.setDialogEnhancer(
      enabled: _dialogEnhancerEnabled,
      profile: _dialogEnhancerProfile,
      amount: _dialogEnhancerAmount,
      ducking: _dialogEnhancerDucking,
      clarity: _dialogEnhancerClarity,
      centerFocus: _dialogEnhancerCenterFocus,
    );
  }

  void _updateHarmonicBass() {
    if (_bassProfile == HarmonicBassProfile.dynamicMultiPole) {
      widget.player.setDynamicBass(
        enabled: _bassEnabled,
        preset: _bassPreset,
        gain: _bassGainDb,
      );
    } else {
      widget.player.setHarmonicBass(
        enabled: _bassEnabled,
        profile: _bassProfile,
        cutoffHz: _bassCutoffHz,
        boost: _bassBoost,
      );
    }
  }

  void _updateDynamicSystem() {
    widget.player.setDynamicSystem(
      enabled: _dynamicSystemEnabled,
      profile: _dynamicSystemProfile,
      strength: _dynamicSystemStrength,
    );
  }

  void _updateAnalogWarmth() {
    widget.player.setAnalogWarmth(
      enabled: _analogWarmthEnabled,
      profile: _analogWarmthProfile,
      drive: _analogWarmthDrive,
    );
  }

  void _updateDeEsser() {
    widget.player.setDeEsserEx(
      enabled: _deEsserEnabled,
      mode: _deEsserMode,
      frequencyHz: _deEsserFrequencyHz,
      thresholdDb: _deEsserThresholdDb,
      ratio: _deEsserRatio,
      maxReductionDb: _deEsserMaxReductionDb,
      attackMs: _deEsserAttackMs,
      releaseMs: _deEsserReleaseMs,
    );
  }

  void _applyDeEsserPreset(DeEsserPreset preset) {
    setState(() {
      _deEsserPreset = preset;
      switch (preset) {
        case DeEsserPreset.gentleVocal:
          _deEsserMode = DeEsserMode.splitBand;
          _deEsserFrequencyHz = 5500.0;
          _deEsserThresholdDb = -24.0;
          _deEsserRatio = 3.5;
          _deEsserMaxReductionDb = 8.0;
          _deEsserAttackMs = 1.5;
          _deEsserReleaseMs = 40.0;
          break;
        case DeEsserPreset.aggressiveSibilance:
          _deEsserMode = DeEsserMode.splitBand;
          _deEsserFrequencyHz = 6000.0;
          _deEsserThresholdDb = -30.0;
          _deEsserRatio = 6.0;
          _deEsserMaxReductionDb = 16.0;
          _deEsserAttackMs = 0.8;
          _deEsserReleaseMs = 30.0;
          break;
        case DeEsserPreset.vintageWideband:
          _deEsserMode = DeEsserMode.wideBand;
          _deEsserFrequencyHz = 5000.0;
          _deEsserThresholdDb = -22.0;
          _deEsserRatio = 4.0;
          _deEsserMaxReductionDb = 10.0;
          _deEsserAttackMs = 2.0;
          _deEsserReleaseMs = 50.0;
          break;
        case DeEsserPreset.podcastSpeech:
          _deEsserMode = DeEsserMode.splitBand;
          _deEsserFrequencyHz = 4500.0;
          _deEsserThresholdDb = -26.0;
          _deEsserRatio = 5.0;
          _deEsserMaxReductionDb = 14.0;
          _deEsserAttackMs = 1.0;
          _deEsserReleaseMs = 35.0;
          break;
        case DeEsserPreset.custom:
          break;
      }
    });
    if (_deEsserEnabled) _updateDeEsser();
    _saveEqState();
  }

  String _getDeEsserPresetName(DeEsserPreset p) {
    switch (p) {
      case DeEsserPreset.gentleVocal:
        return 'Gentle';
      case DeEsserPreset.aggressiveSibilance:
        return 'Aggressive';
      case DeEsserPreset.vintageWideband:
        return 'Wideband';
      case DeEsserPreset.podcastSpeech:
        return 'Podcast';
      case DeEsserPreset.custom:
        return 'Custom';
    }
  }

  void _updateDownwardExpander() {
    widget.player.setDownwardExpander(
      enabled: _expanderEnabled,
      preset: _expanderPreset,
      thresholdDb: _expanderThresholdDb,
      ratio: _expanderRatio,
      rangeDb: _expanderRangeDb,
      attackMs: _expanderAttackMs,
      releaseMs: _expanderReleaseMs,
      kneeDb: _expanderKneeDb,
      sidechainHpfHz: _expanderHpfCutoffHz,
    );
  }

  void _applyExpanderPreset(DownwardExpanderPreset preset) {
    setState(() {
      _expanderPreset = preset;
      switch (preset) {
        case DownwardExpanderPreset.vinylClean:
          _expanderThresholdDb = -52.0;
          _expanderRatio = 1.8;
          _expanderRangeDb = -16.0;
          _expanderAttackMs = 12.0;
          _expanderReleaseMs = 280.0;
          _expanderKneeDb = 6.0;
          _expanderHpfCutoffHz = 50.0;
          break;
        case DownwardExpanderPreset.tapeHiss:
          _expanderThresholdDb = -50.0;
          _expanderRatio = 2.0;
          _expanderRangeDb = -18.0;
          _expanderAttackMs = 10.0;
          _expanderReleaseMs = 220.0;
          _expanderKneeDb = 6.0;
          _expanderHpfCutoffHz = 40.0;
          break;
        case DownwardExpanderPreset.gentleExpansion:
          _expanderThresholdDb = -46.0;
          _expanderRatio = 1.4;
          _expanderRangeDb = -12.0;
          _expanderAttackMs = 20.0;
          _expanderReleaseMs = 400.0;
          _expanderKneeDb = 8.0;
          _expanderHpfCutoffHz = 30.0;
          break;
        case DownwardExpanderPreset.dynamicGate:
          _expanderThresholdDb = -38.0;
          _expanderRatio = 6.0;
          _expanderRangeDb = -36.0;
          _expanderAttackMs = 2.0;
          _expanderReleaseMs = 100.0;
          _expanderKneeDb = 3.0;
          _expanderHpfCutoffHz = 60.0;
          break;
        case DownwardExpanderPreset.custom:
          break;
      }
    });
    if (_expanderEnabled) _updateDownwardExpander();
    _saveEqState();
  }

  String _getExpanderPresetName(DownwardExpanderPreset preset) {
    return switch (preset) {
      DownwardExpanderPreset.vinylClean => 'Vinyl Clean',
      DownwardExpanderPreset.tapeHiss => 'Tape Hiss',
      DownwardExpanderPreset.gentleExpansion => 'Gentle Clean',
      DownwardExpanderPreset.dynamicGate => 'Dynamic Gate',
      DownwardExpanderPreset.custom => 'Custom',
    };
  }

  bool _isBuiltinHrir(String? path) =>
      path != null && _builtinHrirs.any((h) => h.asset == path);

  void _onHrirPresetSelected(List<M3EDropdownItem<String>> selected) {
    if (selected.isEmpty) return;
    final item = selected.first;
    if (item.value == _convolverIrPath) return;
    setState(() {
      _convolverIrPath = item.value;
      _convolverIrFileName = item.label;
      _convolverEnabled = true;
    });
    _updateConvolver();
    _saveEqState();
  }

  void _updateConvolver() {
    widget.player.setConvolverEnabled(_convolverEnabled);
    widget.player.setConvolverMix(wet: _convolverWet, dry: _convolverDry);
    if (_convolverEnabled &&
        _convolverIrPath != null &&
        _convolverIrPath!.isNotEmpty) {
      widget.player.loadConvolverIr(_convolverIrPath!);
    }
  }

  void _updateSurround() {
    widget.player.setSurround(
      enabled: _surroundEnabled,
      mode: _surroundMode,
      // Mode 1: Cinema Matrix 5.1
      centerFocus: _surroundCenterFocus,
      surroundBoost: _surroundSurroundBoost,
      surroundDelayMs: _surroundRearDelayMs,
      headRadiusCm: _surroundHeadRadiusCm,
      // Mode 2: Binaural Virtualizer
      binauralMode: _surroundBinauralMode,
      binauralBoost: _surroundBinauralBoost,
      binauralRoomPreset: _surroundBinauralRoomPreset,
      binauralRoomMix: _surroundBinauralRoomMix,
      binauralSpeakerAngle: _surroundBinauralSpeakerAngle,
      binauralShadowCutoff: _surroundBinauralShadowCutoff,
      // Mode 3: 3D Acoustic Stage
      stageProfile: _surroundStageProfile,
      stageMode: _surroundStageMode,
      stageWidth: _surroundStageWidth,
      stageDepth: _surroundStageDepth,
      stageCancellation: _surroundStageCancellation,
      stageAirPresence: _surroundStageAirPresence,
      stageBassAnchorHz: _surroundStageBassAnchorHz,
      // Fallback aliases
      fieldWidth: _surroundStageWidth,
      vhsRoomPreset: _surroundBinauralRoomPreset,
      haasDelayMs: _surroundRearDelayMs,
    );
  }

  void _updateMasterLimiter() {
    widget.player.setMasterLimiter(
      enabled: _masterLimiterEnabled,
      ceilingDb: _masterLimiterCeilingDb,
      outputGainDb: _masterLimiterOutputGainDb,
      releaseMs: _masterLimiterReleaseMs,
    );
  }

  Future<void> _pickImpulseResponse() async {
    try {
      final result = await FilePicker.pickFiles(
        type: FileType.custom,
        allowedExtensions: ['wav', 'irs'],
      );
      if (result != null && result.files.single.path != null) {
        final path = result.files.single.path!;
        _hrirDropdownController.clearAll();
        setState(() {
          _convolverIrPath = path;
          _convolverIrFileName = p.basename(path);
          _convolverEnabled = true;
        });
        _updateConvolver();
        _saveEqState();
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Failed to load acoustic file: $e')),
        );
      }
    }
  }

  void _updateStereoEnhancement() {
    widget.player.setStereoEnhancement(
      enabled: _stereoEnhancementEnabled,
      mix: _stereoEnhancementMix,
    );
  }

  void _updateReverb() {
    widget.player.setReverbEx(
      enabled: _reverbEnabled,
      wet: _reverbWet,
      dry: _reverbDry,
      roomSize: _reverbRoomSize,
      damping: _reverbDamping,
      preDelayMs: _reverbPreDelayMs,
      width: _reverbWidth,
    );
  }

  /// Applies the loaded preamp value to the audio engine.
  void _applyStoredPreamp() {
    final gain = math.pow(10, _preampDb / 20).toDouble();
    widget.player.setGain(gain);
  }

  /// Saves all current EQ and Sauti DSP state to persistent storage.
  void _saveEqState() {
    AppStateService.instance.saveEqBands(
      enabled: _masterEqEnabled,
      preset: _activePreset,
      gains: List<double>.from(_eqGains),
      preampDb: _preampDb,
      bandCount: _eqFrequencies.length,
    );
    AppStateService.instance.saveCrystalizer(
      enabled: _crystalizerEnabled,
      intensity: _crystalizerIntensity,
      highShelfEnabled: _crystalizerHighShelf,
      highShelfGainDb: _crystalizerShelfGain,
    );
    AppStateService.instance.saveCrossfeed(
      enabled: _crossfeedEnabled,
      preset: _crossfeedPreset,
      algoIndex: _crossfeedAlgorithmIndex,
      mix: _crossfeedMix,
      delayMs: _crossfeedDelayMs,
      cutoffHz: _crossfeedCutoffHz,
      outputCompensation: _crossfeedCompensation,
    );
    AppStateService.instance.saveRaceParams(
      delayMs: _raceDelayMs,
      alpha: _raceAlpha,
      lpfHz: _raceLpfHz,
    );
    AppStateService.instance.saveStereoWiden(
      enabled: _stereoWidenEnabled,
      width: _stereoWidenWidth,
      delayMs: _stereoWidenDelayMs,
    );
    AppStateService.instance.saveStereoEnhancement(
      enabled: _stereoEnhancementEnabled,
      mix: _stereoEnhancementMix,
    );
    AppStateService.instance.saveReverb(
      enabled: _reverbEnabled,
      preset: _reverbPreset,
      wet: _reverbWet,
      dry: _reverbDry,
      roomSize: _reverbRoomSize,
      damping: _reverbDamping,
      preDelayMs: _reverbPreDelayMs,
      width: _reverbWidth,
    );
    AppStateService.instance.saveAudioTuning(
      enabled: _audioTuningEnabled,
      low: _tuneLow,
      mid: _tuneMid,
      high: _tuneHigh,
    );
    AppStateService.instance.saveLimiter(
      enabled: _limiterEnabled,
      threshold: _limiterThreshold,
      attackMs: _limiterAttackMs,
      releaseMs: _limiterReleaseMs,
    );
    AppStateService.instance.saveCompressor(
      enabled: _compressorEnabled,
      thresholdDb: _compressorThresholdDb,
      ratio: _compressorRatio,
      kneeDb: _compressorKneeDb,
      attackMs: _compressorAttackMs,
      releaseMs: _compressorReleaseMs,
      makeupGainDb: _compressorMakeupGainDb,
      detector: _compressorDetector,
      stereoLink: _compressorStereoLink,
      autoMakeup: _compressorAutoMakeup,
      mix: _compressorMix,
    );

    // Save Sauti DSP Suite state
    AppStateService.instance.saveSautiDspState({
      'dspMasterEnabled': _masterEqEnabled,
      'clarityEnabled': _clarityEnabled,
      'clarityProfile': _clarityProfile.value,
      'clarityIntensity': _clarityIntensity,
      'dialogEnhancerEnabled': _dialogEnhancerEnabled,
      'dialogEnhancerProfile': _dialogEnhancerProfile.value,
      'dialogEnhancerAmount': _dialogEnhancerAmount,
      'dialogEnhancerDucking': _dialogEnhancerDucking,
      'dialogEnhancerClarity': _dialogEnhancerClarity,
      'dialogEnhancerCenterFocus': _dialogEnhancerCenterFocus,
      'bassEnabled': _bassEnabled,
      'bassProfile': _bassProfile.value,
      'bassCutoffHz': _bassCutoffHz,
      'bassBoost': _bassBoost,
      'bassPreset': _bassPreset,
      'bassGainDb': _bassGainDb,
      'dynamicSystemEnabled': _dynamicSystemEnabled,
      'dynamicSystemProfile': _dynamicSystemProfile.value,
      'dynamicSystemStrength': _dynamicSystemStrength,
      'analogWarmthEnabled': _analogWarmthEnabled,
      'analogWarmthProfile': _analogWarmthProfile.value,
      'analogWarmthDrive': _analogWarmthDrive,
      'deEsserEnabled': _deEsserEnabled,
      'deEsserMode': _deEsserMode.value,
      'deEsserPreset': _deEsserPreset.value,
      'deEsserFrequencyHz': _deEsserFrequencyHz,
      'deEsserThresholdDb': _deEsserThresholdDb,
      'deEsserRatio': _deEsserRatio,
      'deEsserMaxReductionDb': _deEsserMaxReductionDb,
      'deEsserAttackMs': _deEsserAttackMs,
      'deEsserReleaseMs': _deEsserReleaseMs,
      'expanderEnabled': _expanderEnabled,
      'expanderPreset': _expanderPreset.value,
      'expanderThresholdDb': _expanderThresholdDb,
      'expanderRatio': _expanderRatio,
      'expanderRangeDb': _expanderRangeDb,
      'expanderAttackMs': _expanderAttackMs,
      'expanderReleaseMs': _expanderReleaseMs,
      'expanderKneeDb': _expanderKneeDb,
      'expanderHpfHz': _expanderHpfCutoffHz,
      'convolverEnabled': _convolverEnabled,
      'convolverIrPath': _convolverIrPath,
      'convolverWet': _convolverWet,
      'convolverDry': _convolverDry,
      'surroundEnabled': _surroundEnabled,
      'surroundMode': _surroundMode.value,
      'surroundCenterFocus': _surroundCenterFocus,
      'surroundSurroundBoost': _surroundSurroundBoost,
      'surroundRearDelayMs': _surroundRearDelayMs,
      'surroundHeadRadiusCm': _surroundHeadRadiusCm,
      'surroundBinauralMode': _surroundBinauralMode,
      'surroundBinauralBoost': _surroundBinauralBoost,
      'surroundBinauralRoomPreset': _surroundBinauralRoomPreset,
      'surroundBinauralRoomMix': _surroundBinauralRoomMix,
      'surroundBinauralSpeakerAngle': _surroundBinauralSpeakerAngle,
      'surroundBinauralShadowCutoff': _surroundBinauralShadowCutoff,
      'surroundStageProfile': _surroundStageProfile,
      'surroundStageMode': _surroundStageMode,
      'surroundStageWidth': _surroundStageWidth,
      'surroundStageDepth': _surroundStageDepth,
      'surroundStageCancellation': _surroundStageCancellation,
      'surroundStageAirPresence': _surroundStageAirPresence,
      'surroundStageBassAnchorHz': _surroundStageBassAnchorHz,
      'surroundFieldWidth': _surroundStageWidth,
      'surroundRoomPreset': _surroundBinauralRoomPreset,
      'surroundHaasDelayMs': _surroundRearDelayMs,
      'limiterEnabled': _masterLimiterEnabled,
      'limiterCeilingDb': _masterLimiterCeilingDb,
      'limiterOutputGainDb': _masterLimiterOutputGainDb,
      'limiterReleaseMs': _masterLimiterReleaseMs,
    });
    AppStateService.instance.saveParametricEq(
      enabled: _parametricEqEnabled,
      bands: _parametricBands
          .map((b) => {
                'type': b.type.index,
                'frequency': b.frequencyHz,
                'q': b.q,
                'gainDb': b.gainDb,
                'slope': b.slope,
                'enabled': b.enabled,
              })
          .toList(),
    );
    SharedPreferences.getInstance().then((prefs) {
      prefs.setString(_kActiveParametricPresetKey, _parametricPreset);
    });
  }

  void _dismissWarningBanner() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('hide_eq_warning', true);
    setState(() {
      _showWarningBanner = false;
    });
  }

  void _initEq() {
    widget.player.setMultibandEqEnabled(_masterEqEnabled);
    widget.player.initMultibandEq(_eqFrequencies);
    _applyPreset('Flat');
  }

  void _applyEqGains() {
    for (int i = 0; i < _eqGains.length; i++) {
      widget.player.setMultibandEqBandGain(i, _eqGains[i]);
    }
  }

  void _applyPreset(String preset) {
    setState(() {
      _activePreset = preset;
      if (preset == 'Flat') {
        _eqGains.fillRange(0, _eqGains.length, 0.0);
      } else {
        List<double> baseGains = List.filled(10, 0.0);
        switch (preset) {
          case 'Bass Boost':
            baseGains = [6.0, 5.0, 3.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0];
            break;
          case 'Vocal':
            baseGains = [-2.0, -2.0, -2.0, 1.0, 3.0, 4.0, 3.0, 1.0, -1.0, -1.0];
            break;
          case 'Treble':
            baseGains = [0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 2.0, 4.0, 5.0, 6.0];
            break;
          case 'Rock':
            baseGains = [5.0, 4.0, 2.0, -1.0, -2.0, -1.0, 1.0, 3.0, 4.0, 5.0];
            break;
          case 'Jazz':
            baseGains = [4.0, 3.0, 1.0, 2.0, -2.0, -2.0, 0.0, 1.0, 3.0, 4.0];
            break;
        }

        for (int i = 0; i < _eqGains.length; i++) {
          double position = i / (_eqGains.length - 1);
          double index10 = position * 9.0;
          int lower = index10.floor();
          int upper = index10.ceil();
          double fraction = index10 - lower;
          if (upper > 9) upper = 9;
          _eqGains[i] =
              baseGains[lower] * (1.0 - fraction) + baseGains[upper] * fraction;
        }
      }
      _applyEqGains();
    });
    // Persist the new preset
    _saveEqState();
  }

  void _resetAll() {
    M3EDialog.show<void>(
      context,
      dialog: M3EDialog(
        title: 'Reset All Effects?',
        content: const Material(
          color: Colors.transparent,
          child: Text(
            'This will reset the Equalizer and all audio DSP effects to defaults.',
            style: TextStyle(color: Colors.white70, fontSize: 13.5),
          ),
        ),
        topDivider: true,
        bottomDivider: true,
        actions: [
          M3EButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          M3EButton(
            onPressed: () {
              Navigator.pop(context);
              _performResetAll();
            },
            child: const Text('Reset'),
          ),
        ],
      ),
    );
  }

  void _performResetAll() {
    _applyPreset('Flat');
    setState(() {
      _masterEqEnabled = true;
      widget.player.setMultibandEqEnabled(true);

      _crystalizerEnabled = false;
      _crystalizerIntensity = 0.5;
      _crystalizerHighShelf = true;
      _crystalizerShelfGain = 2.0;
      widget.player.setCrystalizer(enabled: false);

      _crossfeedEnabled = false;
      _crossfeedPreset = 1;
      _crossfeedAlgorithmIndex = 2;
      widget.player.setCrossfeed(enabled: false, preset: 0);
      widget.player.setCrossfeedAlgorithm(CrossfeedAlgorithm.off);

      _stereoWidenEnabled = false;
      _stereoWidenWidth = 1.5;
      widget.player.setStereoWiden(enabled: false, width: 1.5, delayMs: 15.0);

      _stereoEnhancementEnabled = false;
      _stereoEnhancementMix = 0.5;
      widget.player.setStereoEnhancement(enabled: false, mix: 0.5);

      _reverbEnabled = false;
      _reverbPreset = 'Custom';
      _reverbWet = 0.25;
      _reverbDry = 0.75;
      _reverbRoomSize = 0.6;
      _reverbDamping = 0.4;
      _reverbPreDelayMs = 20.0;
      _reverbWidth = 1.0;
      widget.player.setReverbEx(
        enabled: false,
        wet: _reverbWet,
        dry: _reverbDry,
        roomSize: _reverbRoomSize,
        damping: _reverbDamping,
        preDelayMs: _reverbPreDelayMs,
        width: _reverbWidth,
      );

      _audioTuningEnabled = false;
      widget.player.setEqEnabled(false);
      _tuneLow = 0.0;
      _tuneMid = 0.0;
      _tuneHigh = 0.0;
      widget.player.setEq(low: _tuneLow, mid: _tuneMid, high: _tuneHigh);

      _preampDb = 0.0;
      widget.player.setGain(1.0); // 1.0 is 0dB
      _playbackRate = 1.0;
      _playbackPitch = 1.0;
      _playbackPitchCorrection = true;
      widget.player.setRate(1.0);
      widget.player.setPitch(1.0);
      widget.player.setPitchCorrection(true);
      AppStateService.instance.savePlaybackRate(1.0);
      AppStateService.instance.savePlaybackPitch(1.0);
      AppStateService.instance.savePitchCorrection(true);

      _parametricEqEnabled = false;
      _parametricBands.clear();
      widget.player.setMultibandFxEnabled(false);
      widget.player.clearMultibandFx();

      _limiterEnabled = false;
      _limiterThreshold = 0.95;
      _limiterAttackMs = 2.0;
      _limiterReleaseMs = 50.0;
      widget.player.setLimiterEnabled(false);
      widget.player.setClippingDetectionEnabled(false);

      // Sauti DSP Suite Resets
      _clarityEnabled = false;
      _clarityProfile = AudioClarityProfile.transientCrisp;
      _clarityIntensity = 0.5;
      widget.player.setClarity(enabled: false);

      _dialogEnhancerEnabled = false;
      _dialogEnhancerProfile = DialogEnhancerProfile.cinema;
      _dialogEnhancerAmount = 0.65;
      _dialogEnhancerDucking = 0.55;
      _dialogEnhancerClarity = 0.60;
      _dialogEnhancerCenterFocus = 0.70;
      widget.player.setDialogEnhancer(enabled: false);

      _bassEnabled = false;
      _bassProfile = HarmonicBassProfile.dynamicMultiPole;
      _bassCutoffHz = 60.0;
      _bassBoost = 0.5;
      _bassPreset = 18;
      _bassGainDb = 15.0;
      widget.player.setDynamicBass(enabled: false, preset: 18, gain: 15.0);
      widget.player.setHarmonicBass(enabled: false);

      _dynamicSystemEnabled = false;
      _dynamicSystemProfile = TransducerProfile.earphone;
      _dynamicSystemStrength = 0.5;
      widget.player.setDynamicSystem(enabled: false);

      _analogWarmthEnabled = false;
      _analogWarmthProfile = AnalogWarmthProfile.triode12AX7;
      _analogWarmthDrive = 0.5;
      widget.player.setAnalogWarmth(enabled: false);

      _deEsserEnabled = false;
      _deEsserMode = DeEsserMode.splitBand;
      _deEsserPreset = DeEsserPreset.gentleVocal;
      _deEsserFrequencyHz = 5500.0;
      _deEsserThresholdDb = -22.0;
      _deEsserRatio = 4.0;
      _deEsserMaxReductionDb = 12.0;
      _deEsserAttackMs = 1.0;
      _deEsserReleaseMs = 35.0;
      _deEsserGainReductionDb = 0.0;
      widget.player.setDeEsser(enabled: false);

      _expanderEnabled = false;
      _expanderPreset = DownwardExpanderPreset.vinylClean;
      _expanderThresholdDb = -52.0;
      _expanderRatio = 1.8;
      _expanderRangeDb = -16.0;
      _expanderAttackMs = 12.0;
      _expanderReleaseMs = 280.0;
      _expanderKneeDb = 6.0;
      _expanderHpfCutoffHz = 50.0;
      widget.player.setDownwardExpander(enabled: false);

      _convolverEnabled = false;
      _convolverIrPath = null;
      _convolverIrFileName = null;
      _convolverWet = 1.0;
      _convolverDry = 0.0;
      _hrirDropdownController.clearAll();
      widget.player.setConvolverEnabled(false);
      widget.player.clearConvolverIr();

      _surroundEnabled = false;
      _surroundMode = SurroundMode.off;
      _surroundCenterFocus = 0.6;
      _surroundSurroundBoost = 1.2;
      _surroundRearDelayMs = 15.0;
      _surroundHeadRadiusCm = 8.75;
      _surroundBinauralMode = 0;
      _surroundBinauralBoost = 0.65;
      _surroundBinauralRoomPreset = 2;
      _surroundBinauralRoomMix = 0.35;
      _surroundBinauralSpeakerAngle = 1;
      _surroundBinauralShadowCutoff = 3500.0;
      _surroundStageProfile = 0;
      _surroundStageMode = 0;
      _surroundStageWidth = 1.2;
      _surroundStageDepth = 0.5;
      _surroundStageCancellation = 0.60;
      _surroundStageAirPresence = 0.40;
      _surroundStageBassAnchorHz = 60.0;
      widget.player.setSurround(enabled: false, mode: SurroundMode.off);

      _masterLimiterEnabled = false;
      _masterLimiterCeilingDb = -0.1;
      _masterLimiterOutputGainDb = 0.0;
      _masterLimiterReleaseMs = 60.0;
      widget.player.setMasterLimiter(enabled: false);
    });
    // Persist the reset state
    _saveEqState();
  }

  Widget _buildSectionHeader(String title, {IconData? icon}) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 20, 20, 8),
      child: Row(
        children: [
          if (icon != null) ...[
            Icon(icon, color: primaryColor, size: 14),
            const SizedBox(width: 6),
          ],
          Text(
            title.toUpperCase(),
            style: TextStyle(
              color: primaryColor,
              fontSize: 11.5,
              fontWeight: FontWeight.w800,
              letterSpacing: 1.2,
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Container(
              height: 1,
              color: primaryColor.withValues(alpha: 0.15),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildEffectTileCard({
    required IconData icon,
    required String title,
    required String subtitle,
    required bool isEnabled,
    Shapes shape = Shapes.c4SidedCookie,
    ValueChanged<bool>? onToggle,
    required VoidCallback onTapDetail,
  }) {
    return M3EListItem(
      headline: title,
      supportingText: subtitle,
      leading: /*M3EContainer(
        shape,
        width: 44,
        height: 44,
        color: isEnabled
            ? primaryColor.withValues(alpha: 0.18)
            : Colors.white.withValues(alpha: 0.05),
        border: BorderSide(
          color: isEnabled
              ? primaryColor.withValues(alpha: 0.45)
              : Colors.white.withValues(alpha: 0.1),
          width: 1.2,
        ),
        child: */
          Center(
        child: Icon(
          icon,
          color: isEnabled ? primaryColor : Colors.white60,
          size: 22,
        ),
        //  ),
      ),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (onToggle != null) ...[
            M3ESwitch(
              selectedIcon: Icon(Icons.check, color: primaryColor),
              value: isEnabled,
              onChanged: onToggle,
            ),
            const SizedBox(width: 6),
          ],
          const Icon(
            Icons.chevron_right_rounded,
            color: Colors.white38,
            size: 22,
          ),
        ],
      ),
      onTap: onTapDetail,
    );
  }

  void _openDetailScreen(
      String title, IconData icon, WidgetBuilder contentBuilder,
      {Shapes shape = Shapes.c4SidedCookie}) {
    Navigator.push(
      context,
      PageRouteBuilder(
        transitionDuration: const Duration(milliseconds: 320),
        reverseTransitionDuration: const Duration(milliseconds: 260),
        pageBuilder: (context, animation, secondaryAnimation) {
          return StatefulBuilder(
            builder: (context, setSubState) {
              _subScreenSetState = setSubState;
              return Scaffold(
                backgroundColor: bgDarkColor,
                appBar: AppBar(
                  backgroundColor: surfaceDarkerColor,
                  elevation: 0,
                  scrolledUnderElevation: 0,
                  leading: M3EIconButton(
                    icon: const Icon(Icons.keyboard_arrow_down,
                        color: Colors.white, size: 20),
                    variant: M3EIconButtonVariant.standard,
                    onPressed: () {
                      _subScreenSetState = null;
                      Navigator.pop(context);
                    },
                  ),
                  title: Row(
                    children: [
                      /* M3EContainer(
                        shape,
                        width: 32,
                        height: 32,
                        color: primaryColor.withValues(alpha: 0.18),
                        border: BorderSide(
                          color: primaryColor.withValues(alpha: 0.4),
                          width: 1.0,
                        ),
                        child: */
                      Center(
                        child: Icon(icon, color: primaryColor, size: 16),
                      ),
                      // ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Text(
                          title,
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 17,
                            fontWeight: FontWeight.bold,
                            letterSpacing: -0.2,
                          ),
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    ],
                  ),
                ),
                body: RepaintBoundary(
                  child: Align(
                    alignment: Alignment.topCenter,
                    child: ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 1000.0),
                      child: SingleChildScrollView(
                        padding: const EdgeInsets.all(16),
                        physics: const BouncingScrollPhysics(),
                        child: contentBuilder(context),
                      ),
                    ),
                  ),
                ),
              );
            },
          );
        },
        transitionsBuilder: (context, animation, secondaryAnimation, child) {
          final curveAnimation = CurvedAnimation(
            parent: animation,
            curve: Curves.easeOutCubic,
            reverseCurve: Curves.easeInCubic,
          );

          final slideAnimation = Tween<Offset>(
            begin: const Offset(0.06, 0.0),
            end: Offset.zero,
          ).animate(curveAnimation);

          final fadeAnimation = Tween<double>(
            begin: 0.0,
            end: 1.0,
          ).animate(curveAnimation);

          return SlideTransition(
            position: slideAnimation,
            child: FadeTransition(
              opacity: fadeAnimation,
              child: child,
            ),
          );
        },
      ),
    ).then((_) {
      _subScreenSetState = null;
    });
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    return Align(
      alignment: Alignment.topCenter,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 1000.0),
        child: CustomScrollView(
          key: const PageStorageKey<String>('eq_screen_scroll'),
          slivers: [
            // Top Master Control Bar
            /*  SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.only(
                    left: 16.0, right: 16.0, top: 12.0, bottom: 6.0),
                child: Container(
                  padding: const EdgeInsets.symmetric(
                      horizontal: 14.0, vertical: 8.0),
                  decoration: BoxDecoration(
                    color: surfaceDarkColor,
                    borderRadius: BorderRadius.circular(16),
                    border: Border.all(
                      color: _masterEqEnabled
                          ? primaryColor.withValues(alpha: 0.35)
                          : Colors.white.withValues(alpha: 0.08),
                    ),
                  ),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Row(
                        children: [
                          Center(
                            child: Icon(
                              Icons.equalizer_rounded,
                              color: _masterEqEnabled
                                  ? primaryColor
                                  : Colors.white60,
                              size: 18,
                            ),
                          ),
                          const SizedBox(width: 8),
                          Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              const Text(
                                'Master EQ & DSP',
                                style: TextStyle(
                                  color: Colors.white,
                                  fontSize: 16,
                                  fontWeight: FontWeight.bold,
                                  letterSpacing: -0.2,
                                ),
                              ),
                              Text(
                                _masterEqEnabled
                                    ? 'Audio engine active'
                                    : 'DSP bypassed',
                                style: TextStyle(
                                  color: _masterEqEnabled
                                      ? primaryColor.withValues(alpha: 0.9)
                                      : Colors.white38,
                                  fontSize: 11.5,
                                ),
                              ),
                            ],
                          ),
                        ],
                      ),
                      Row(
                        children: [
                          const SizedBox(width: 6),
                          M3EIconButton(
                            icon: const Icon(Icons.refresh_rounded, size: 19),
                            variant: M3EIconButtonVariant.tonal,
                            tooltip: 'Reset All',
                            onPressed: _resetAll,
                          ),
                          const SizedBox(width: 6),
                          M3ESwitch(
                            selectedIcon:
                                Icon(Icons.check, color: primaryColor),
                            value: _masterEqEnabled,
                            onChanged: (val) {
                              setState(() => _masterEqEnabled = val);
                              widget.player.setMultibandEqEnabled(val);
                              _saveEqState();
                            },
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
            ),
*/
            // Warning Banner (Dismissible)
            if (_showWarningBanner)
              SliverToBoxAdapter(
                child: Padding(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
                  child: M3ECard(
                    variant: M3ECardVariant.filled,
                    child: Padding(
                      padding: const EdgeInsets.all(12),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          M3EContainer(
                            Shapes.triangle,
                            width: 32,
                            height: 32,
                            color: Colors.amber.withValues(alpha: 0.15),
                            border: BorderSide(
                              color: Colors.amber.withValues(alpha: 0.35),
                              width: 1.0,
                            ),
                            child: const Center(
                              child: Icon(Icons.warning_amber_rounded,
                                  color: Colors.amberAccent, size: 18),
                            ),
                          ),
                          const SizedBox(width: 10),
                          const Expanded(
                            child: Text(
                              'Extreme equalizer or filter boosts can cause clipping. Use limiter or preamp reduction if needed.',
                              style: TextStyle(
                                  color: Colors.white70,
                                  fontSize: 11.5,
                                  height: 1.3),
                            ),
                          ),
                          M3EIconButton(
                            onPressed: _dismissWarningBanner,
                            icon: const Icon(Icons.close_rounded, size: 16),
                            variant: M3EIconButtonVariant.standard,
                            tooltip: 'Dismiss',
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),

            // Section 1: Equalization & Tuning
            SliverToBoxAdapter(
              child: _buildSectionHeader('Equalization & Tuning',
                  icon: Icons.equalizer_rounded),
            ),
            SliverToBoxAdapter(
              child: Padding(
                padding:
                    const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
                child: M3ECardList(
                  itemCount: 4,
                  onTap: (index) {
                    switch (index) {
                      case 0:
                        _openDetailScreen(
                          '${_eqFrequencies.length}-Band Graphic EQ',
                          Icons.equalizer_rounded,
                          (_) => _buildGraphicEqSection(),
                          shape: Shapes.c4SidedCookie,
                        );
                        break;
                      case 1:
                        _openDetailScreen(
                          'Playback Speed & Pitch',
                          Icons.speed_rounded,
                          (_) => _buildPlaybackSpeedSection(),
                          shape: Shapes.sunny,
                        );
                        break;
                      case 2:
                        _openDetailScreen(
                          '3-Band Audio Tuning',
                          Icons.tune_rounded,
                          (_) => _buildAudioTuningSection(),
                          shape: Shapes.pill,
                        );
                        break;
                      case 3:
                        _openDetailScreen(
                          'Parametric EQ',
                          Icons.show_chart_rounded,
                          (_) => _buildParametricEqSection(),
                          shape: Shapes.gem,
                        );
                        break;
                    }
                  },
                  itemBuilder: (context, index) {
                    if (index == 0) {
                      return AppShowcase(
                        showcaseKey: widget.effectsKnobKey ?? GlobalKey(),
                        title: 'Knob Controls',
                        description:
                            'Drag knobs to adjust EQ. Tip: Long-press any knob to edit values directly with your keyboard!',
                        currentStep: 4,
                        totalSteps: 5,
                        child: _buildEffectTileCard(
                          icon: Icons.equalizer_rounded,
                          shape: Shapes.c4SidedCookie,
                          title: '${_eqFrequencies.length}-Band Graphic EQ',
                          subtitle: _masterEqEnabled
                              ? '${_eqFrequencies.length}-Band ($_activePreset)'
                              : 'Disabled',
                          isEnabled: _masterEqEnabled,
                          onToggle: (v) {
                            setState(() => _masterEqEnabled = v);
                            widget.player.setMultibandEqEnabled(v);
                            _saveEqState();
                          },
                          onTapDetail: () => _openDetailScreen(
                            '${_eqFrequencies.length}-Band Graphic EQ',
                            Icons.equalizer_rounded,
                            (_) => _buildGraphicEqSection(),
                            shape: Shapes.c4SidedCookie,
                          ),
                        ),
                      );
                    }
                    if (index == 1) {
                      final hasCustomRate = (_playbackRate - 1.0).abs() >= 0.01;
                      final hasCustomPitch =
                          (_playbackPitch - 1.0).abs() >= 0.01;
                      final isActive = hasCustomRate || hasCustomPitch;
                      String subtitle;
                      if (hasCustomRate && hasCustomPitch) {
                        subtitle =
                            '${_playbackRate.toStringAsFixed(2)}x Speed • ${_playbackPitch.toStringAsFixed(2)}x Pitch';
                      } else if (hasCustomRate) {
                        subtitle =
                            '${_playbackRate.toStringAsFixed(2)}x Speed${_playbackPitchCorrection ? ' (Scaletempo)' : ''}';
                      } else if (hasCustomPitch) {
                        subtitle =
                            '${_playbackPitch.toStringAsFixed(2)}x Pitch';
                      } else {
                        subtitle = 'Normal Speed (1.0x)';
                      }

                      return _buildEffectTileCard(
                        icon: Icons.speed_rounded,
                        shape: Shapes.sunny,
                        title: 'Playback Speed & Pitch',
                        subtitle: subtitle,
                        isEnabled: isActive,
                        onToggle: (v) {
                          final newRate = v ? 1.25 : 1.0;
                          final newPitch = 1.0;
                          setState(() {
                            _playbackRate = newRate;
                            _playbackPitch = newPitch;
                          });
                          widget.player.setRate(newRate);
                          widget.player.setPitch(newPitch);
                          AppStateService.instance.savePlaybackRate(newRate);
                          AppStateService.instance.savePlaybackPitch(newPitch);
                        },
                        onTapDetail: () => _openDetailScreen(
                          'Playback Speed & Pitch',
                          Icons.speed_rounded,
                          (_) => _buildPlaybackSpeedSection(),
                          shape: Shapes.sunny,
                        ),
                      );
                    }
                    if (index == 2) {
                      return _buildEffectTileCard(
                        icon: Icons.tune_rounded,
                        shape: Shapes.pill,
                        title: '3-Band Audio Tuning',
                        subtitle: _audioTuningEnabled
                            ? 'Low: ${_tuneLow.toInt()}dB | Mid: ${_tuneMid.toInt()}dB | High: ${_tuneHigh.toInt()}dB'
                            : 'Disabled',
                        isEnabled: _audioTuningEnabled,
                        onToggle: (v) {
                          setState(() => _audioTuningEnabled = v);
                          widget.player.setEqEnabled(v);
                          _saveEqState();
                        },
                        onTapDetail: () => _openDetailScreen(
                          '3-Band Audio Tuning',
                          Icons.tune_rounded,
                          (_) => _buildAudioTuningSection(),
                          shape: Shapes.pill,
                        ),
                      );
                    }
                    return _buildEffectTileCard(
                      icon: Icons.show_chart_rounded,
                      shape: Shapes.gem,
                      title: 'Parametric EQ',
                      subtitle: _parametricEqEnabled
                          ? '${_parametricBands.length} Bands ($_parametricPreset)'
                          : 'Disabled',
                      isEnabled: _parametricEqEnabled,
                      onToggle: (v) {
                        setState(() => _parametricEqEnabled = v);
                        widget.player.setMultibandFxEnabled(v);
                        _saveEqState();
                      },
                      onTapDetail: () => _openDetailScreen(
                        'Parametric EQ',
                        Icons.show_chart_rounded,
                        (_) => _buildParametricEqSection(),
                        shape: Shapes.gem,
                      ),
                    );
                  },
                ),
              ),
            ),

            // Section 2: Bass & Subwoofer Engine
            SliverToBoxAdapter(
              child: _buildSectionHeader('Bass Engine',
                  icon: Icons.speaker_group_rounded),
            ),
            SliverToBoxAdapter(
              child: Padding(
                padding:
                    const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
                child: M3ECardList(
                  itemCount: 2,
                  onTap: (index) {
                    switch (index) {
                      case 0:
                        _openDetailScreen(
                          'Dynamic Bass',
                          Icons.speaker_group_rounded,
                          (_) => _buildHarmonicBassSection(),
                          shape: Shapes.boom,
                        );
                        break;
                      case 1:
                        _openDetailScreen(
                          'Dynamic System',
                          Icons.headphones_rounded,
                          (_) => _buildDynamicSystemSection(),
                          shape: Shapes.burst,
                        );
                        break;
                    }
                  },
                  itemBuilder: (context, index) {
                    if (index == 0) {
                      return _buildEffectTileCard(
                        icon: Icons.speaker_group_rounded,
                        shape: Shapes.boom,
                        title: 'Dynamic Bass',
                        subtitle: _bassEnabled
                            ? (_bassProfile ==
                                    HarmonicBassProfile.dynamicMultiPole
                                ? '${_getDynamicBassPresetName(_bassPreset)} (+${_bassGainDb.toStringAsFixed(1)} dB)'
                                : '${_getHarmonicBassProfileName(_bassProfile)} | ${_bassCutoffHz.toInt()}Hz (${(_bassBoost * 100).toInt()}%)')
                            : 'Disabled',
                        isEnabled: _bassEnabled,
                        onToggle: (v) {
                          setState(() => _bassEnabled = v);
                          _updateHarmonicBass();
                          _saveEqState();
                        },
                        onTapDetail: () => _openDetailScreen(
                          'Dynamic Bass',
                          Icons.speaker_group_rounded,
                          (_) => _buildHarmonicBassSection(),
                          shape: Shapes.boom,
                        ),
                      );
                    }
                    return _buildEffectTileCard(
                      icon: Icons.headphones_rounded,
                      shape: Shapes.burst,
                      title: 'Dynamic system',
                      subtitle: _dynamicSystemEnabled
                          ? '${_getTransducerProfileName(_dynamicSystemProfile)} (${(_dynamicSystemStrength * 100).toInt()}%)'
                          : 'Disabled',
                      isEnabled: _dynamicSystemEnabled,
                      onToggle: (v) {
                        setState(() => _dynamicSystemEnabled = v);
                        _updateDynamicSystem();
                        _saveEqState();
                      },
                      onTapDetail: () => _openDetailScreen(
                        'Dynamic System',
                        Icons.headphones_rounded,
                        (_) => _buildDynamicSystemSection(),
                        shape: Shapes.burst,
                      ),
                    );
                  },
                ),
              ),
            ),

            // Section 3: Clarity & Dynamics
            SliverToBoxAdapter(
              child: _buildSectionHeader('Clarity & Dynamics',
                  icon: Icons.auto_awesome),
            ),
            SliverToBoxAdapter(
              child: Padding(
                padding:
                    const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
                child: M3ECardList(
                  itemCount: 5,
                  onTap: (index) {
                    switch (index) {
                      case 0:
                        _openDetailScreen(
                          'Audio Clarity',
                          Icons.graphic_eq_rounded,
                          (_) => _buildClaritySection(),
                          shape: Shapes.gem,
                        );
                        break;
                      case 1:
                        _openDetailScreen(
                          'Dialogue Enhancer',
                          Icons.record_voice_over_rounded,
                          (_) => _buildDialogEnhancerSection(),
                          shape: Shapes.pill,
                        );
                        break;
                      case 2:
                        _openDetailScreen(
                          'De-Esser',
                          Icons.record_voice_over_rounded,
                          (_) => _buildDeEsserSection(),
                          shape: Shapes.pill,
                        );
                        break;
                      case 3:
                        _openDetailScreen(
                          'Crystalizer',
                          Icons.auto_fix_high_rounded,
                          (_) => _buildCrystalizerSection(),
                          shape: Shapes.burst,
                        );
                        break;
                      case 4:
                        _openDetailScreen(
                          'Downward Expander',
                          Icons.cleaning_services_rounded,
                          (_) => _buildDownwardExpanderSection(),
                          shape: Shapes.flower,
                        );
                        break;
                    }
                  },
                  itemBuilder: (context, index) {
                    if (index == 0) {
                      return _buildEffectTileCard(
                        icon: Icons.graphic_eq_rounded,
                        shape: Shapes.gem,
                        title: 'Audio Clarity',
                        subtitle: _clarityEnabled
                            ? '${_getClarityProfileName(_clarityProfile)} (${(_clarityIntensity * 100).toInt()}%)'
                            : 'Disabled',
                        isEnabled: _clarityEnabled,
                        onToggle: (v) {
                          setState(() => _clarityEnabled = v);
                          _updateClarity();
                          _saveEqState();
                        },
                        onTapDetail: () => _openDetailScreen(
                          'Audio Clarity',
                          Icons.graphic_eq_rounded,
                          (_) => _buildClaritySection(),
                          shape: Shapes.gem,
                        ),
                      );
                    }
                    if (index == 1) {
                      return _buildEffectTileCard(
                        icon: Icons.record_voice_over_rounded,
                        shape: Shapes.pill,
                        title: 'Dialogue Enhancer',
                        subtitle: _dialogEnhancerEnabled
                            ? '${_getDialogEnhancerProfileName(_dialogEnhancerProfile)} (+${(_dialogEnhancerAmount * 11.0).toStringAsFixed(1)} dB)'
                            : 'Disabled',
                        isEnabled: _dialogEnhancerEnabled,
                        onToggle: (v) {
                          setState(() => _dialogEnhancerEnabled = v);
                          _updateDialogEnhancer();
                          _saveEqState();
                        },
                        onTapDetail: () => _openDetailScreen(
                          'Dialogue Enhancer',
                          Icons.record_voice_over_rounded,
                          (_) => _buildDialogEnhancerSection(),
                          shape: Shapes.pill,
                        ),
                      );
                    }
                    if (index == 2) {
                      return _buildEffectTileCard(
                        icon: Icons.record_voice_over_rounded,
                        shape: Shapes.pill,
                        title: 'De-Esser',
                        subtitle: _deEsserEnabled
                            ? '${_getDeEsserPresetName(_deEsserPreset)} (${(_deEsserFrequencyHz / 1000.0).toStringAsFixed(1)} kHz / ${_deEsserThresholdDb.toInt()} dB)'
                            : 'Disabled',
                        isEnabled: _deEsserEnabled,
                        onToggle: (v) {
                          setState(() => _deEsserEnabled = v);
                          _updateDeEsser();
                          _saveEqState();
                        },
                        onTapDetail: () => _openDetailScreen(
                          'De-Esser',
                          Icons.record_voice_over_rounded,
                          (_) => _buildDeEsserSection(),
                          shape: Shapes.pill,
                        ),
                      );
                    }
                    if (index == 3) {
                      return _buildEffectTileCard(
                        icon: Icons.auto_fix_high_rounded,
                        shape: Shapes.burst,
                        title: 'Crystalizer',
                        subtitle: _crystalizerEnabled
                            ? 'Intensity: ${(_crystalizerIntensity * 100).toInt()}%'
                            : 'Disabled',
                        isEnabled: _crystalizerEnabled,
                        onToggle: (v) {
                          setState(() => _crystalizerEnabled = v);
                          _updateCrystalizer();
                          _saveEqState();
                        },
                        onTapDetail: () => _openDetailScreen(
                          'Crystalizer',
                          Icons.auto_fix_high_rounded,
                          (_) => _buildCrystalizerSection(),
                          shape: Shapes.burst,
                        ),
                      );
                    }
                    return _buildEffectTileCard(
                      icon: Icons.cleaning_services_rounded,
                      shape: Shapes.flower,
                      title: 'Downward Expander',
                      subtitle: _expanderEnabled
                          ? '${_getExpanderPresetName(_expanderPreset)} (${_expanderThresholdDb.toInt()} dB / ${_expanderRatio.toStringAsFixed(1)}:1)'
                          : 'Disabled',
                      isEnabled: _expanderEnabled,
                      onToggle: (v) {
                        setState(() => _expanderEnabled = v);
                        _updateDownwardExpander();
                        _saveEqState();
                      },
                      onTapDetail: () => _openDetailScreen(
                        'Downward Expander',
                        Icons.cleaning_services_rounded,
                        (_) => _buildDownwardExpanderSection(),
                        shape: Shapes.flower,
                      ),
                    );
                  },
                ),
              ),
            ),

            // Section 4: Spatial & Analog Warmth
            SliverToBoxAdapter(
              child: _buildSectionHeader('Spatial & Analog Warmth',
                  icon: Icons.headphones_rounded),
            ),
            SliverToBoxAdapter(
              child: Padding(
                padding:
                    const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
                child: M3ECardList(
                  itemCount: 4,
                  onTap: (index) {
                    switch (index) {
                      case 0:
                        _openDetailScreen(
                          'Crossfeed',
                          Icons.headphones_rounded,
                          (_) => _buildCrossfeedSection(),
                          shape: Shapes.arch,
                        );
                        break;
                      case 1:
                        _openDetailScreen(
                          'Stereo Widener',
                          Icons.swap_horiz_rounded,
                          (_) => _buildStereoWidenSection(),
                          shape: Shapes.slanted,
                        );
                        break;
                      case 2:
                        _openDetailScreen(
                          'Stereo Enhancer',
                          Icons.surround_sound_rounded,
                          (_) => _buildStereoEnhancementSection(),
                          shape: Shapes.puffyDiamond,
                        );
                        break;
                      case 3:
                        _openDetailScreen(
                          'Analog Warmth',
                          Icons.album_rounded,
                          (_) => _buildAnalogWarmthSection(),
                          shape: Shapes.sunny,
                        );
                        break;
                    }
                  },
                  itemBuilder: (context, index) {
                    if (index == 0) {
                      return _buildEffectTileCard(
                        icon: Icons.headphones_rounded,
                        shape: Shapes.arch,
                        title: 'Crossfeed',
                        subtitle: _crossfeedEnabled
                            ? (_crossfeedAlgorithmIndex == 1
                                ? 'Simple Reference'
                                : _crossfeedAlgorithmIndex == 2
                                    ? 'Bauer BS2B'
                                    : _crossfeedAlgorithmIndex == 3
                                        ? 'Jan Meier'
                                        : _crossfeedAlgorithmIndex == 4
                                            ? 'Custom Natural'
                                            : 'Ambiophonics RACE (Speakers / Dipole XTC)')
                            : 'Disabled',
                        isEnabled: _crossfeedEnabled,
                        onToggle: (v) {
                          setState(() => _crossfeedEnabled = v);
                          if (v) {
                            _updateCrossfeed();
                          } else {
                            widget.player.setCrossfeed(
                                enabled: false, preset: _crossfeedPreset);
                          }
                          _saveEqState();
                        },
                        onTapDetail: () => _openDetailScreen(
                          'Crossfeed',
                          Icons.headphones_rounded,
                          (_) => _buildCrossfeedSection(),
                          shape: Shapes.arch,
                        ),
                      );
                    }
                    if (index == 1) {
                      return _buildEffectTileCard(
                        icon: Icons.swap_horiz_rounded,
                        shape: Shapes.slanted,
                        title: 'Stereo Widener',
                        subtitle: _stereoWidenEnabled
                            ? 'Width: ${_stereoWidenWidth.toStringAsFixed(1)}x'
                            : 'Disabled',
                        isEnabled: _stereoWidenEnabled,
                        onToggle: (v) {
                          setState(() => _stereoWidenEnabled = v);
                          if (v) {
                            _updateStereoWiden();
                          } else {
                            widget.player.setStereoWiden(
                                enabled: false,
                                width: _stereoWidenWidth,
                                delayMs: _stereoWidenDelayMs * 100.0);
                          }
                          _saveEqState();
                        },
                        onTapDetail: () => _openDetailScreen(
                          'Stereo Widener',
                          Icons.swap_horiz_rounded,
                          (_) => _buildStereoWidenSection(),
                          shape: Shapes.slanted,
                        ),
                      );
                    }
                    if (index == 2) {
                      return _buildEffectTileCard(
                        icon: Icons.surround_sound_rounded,
                        shape: Shapes.puffyDiamond,
                        title: 'Stereo Enhancer',
                        subtitle: _stereoEnhancementEnabled
                            ? 'Mix: ${(_stereoEnhancementMix * 100).toInt()}%'
                            : 'Disabled',
                        isEnabled: _stereoEnhancementEnabled,
                        onToggle: (v) {
                          setState(() => _stereoEnhancementEnabled = v);
                          _updateStereoEnhancement();
                          _saveEqState();
                        },
                        onTapDetail: () => _openDetailScreen(
                          'Stereo Enhancer',
                          Icons.surround_sound_rounded,
                          (_) => _buildStereoEnhancementSection(),
                          shape: Shapes.puffyDiamond,
                        ),
                      );
                    }
                    return _buildEffectTileCard(
                      icon: Icons.album_rounded,
                      shape: Shapes.sunny,
                      title: 'Analog Warmth',
                      subtitle: _analogWarmthEnabled
                          ? '${_getAnalogWarmthProfileName(_analogWarmthProfile)} (${(_analogWarmthDrive * 100).toInt()}%)'
                          : 'Disabled',
                      isEnabled: _analogWarmthEnabled,
                      onToggle: (v) {
                        setState(() => _analogWarmthEnabled = v);
                        _updateAnalogWarmth();
                        _saveEqState();
                      },
                      onTapDetail: () => _openDetailScreen(
                        'Analog Warmth',
                        Icons.album_rounded,
                        (_) => _buildAnalogWarmthSection(),
                        shape: Shapes.sunny,
                      ),
                    );
                  },
                ),
              ),
            ),

            // Section 5: Acoustic Space, Convolver & Surround
            SliverToBoxAdapter(
              child: _buildSectionHeader('Convolver & Surround',
                  icon: Icons.waves_rounded),
            ),
            SliverToBoxAdapter(
              child: Padding(
                padding:
                    const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
                child: M3ECardList(
                  itemCount: 2,
                  onTap: (index) {
                    switch (index) {
                      case 0:
                        _openDetailScreen(
                          'Convolver',
                          Icons.waves_rounded,
                          (_) => _buildConvolverSection(),
                          shape: Shapes.c4SidedCookie,
                        );
                        break;
                      case 1:
                        _openDetailScreen(
                          'Spatial Surround',
                          Icons.surround_sound_rounded,
                          (_) => _buildSurroundSection(),
                          shape: Shapes.puffyDiamond,
                        );
                        break;
                    }
                  },
                  itemBuilder: (context, index) {
                    if (index == 0) {
                      return _buildEffectTileCard(
                        icon: Icons.waves_rounded,
                        shape: Shapes.c4SidedCookie,
                        title: 'Convolver',
                        subtitle: _convolverEnabled
                            ? (_convolverIrFileName ?? 'Acoustic IR Active')
                            : 'Disabled',
                        isEnabled: _convolverEnabled,
                        onToggle: (v) {
                          setState(() => _convolverEnabled = v);
                          _updateConvolver();
                          _saveEqState();
                        },
                        onTapDetail: () => _openDetailScreen(
                          'Convolver',
                          Icons.waves_rounded,
                          (_) => _buildConvolverSection(),
                          shape: Shapes.c4SidedCookie,
                        ),
                      );
                    }
                    return _buildEffectTileCard(
                      icon: Icons.surround_sound_rounded,
                      shape: Shapes.puffyDiamond,
                      title: 'Spatial Surround',
                      subtitle: _surroundEnabled
                          ? _getSurroundModeSubtitle()
                          : 'Disabled',
                      isEnabled: _surroundEnabled,
                      onToggle: (v) {
                        setState(() {
                          _surroundEnabled = v;
                          if (v && _surroundMode == SurroundMode.off) {
                            _surroundMode = SurroundMode.matrixSurround;
                          }
                        });
                        _updateSurround();
                        _saveEqState();
                      },
                      onTapDetail: () => _openDetailScreen(
                        'Spatial Surround',
                        Icons.surround_sound_rounded,
                        (_) => _buildSurroundSection(),
                        shape: Shapes.puffyDiamond,
                      ),
                    );
                  },
                ),
              ),
            ),

            // Section 6: Reverb
            SliverToBoxAdapter(
              child: _buildSectionHeader('Reverb',
                  icon: Icons.wb_twilight_rounded),
            ),
            SliverToBoxAdapter(
              child: Padding(
                padding:
                    const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
                child: M3ECardList(
                  itemCount: 1,
                  onTap: (index) {
                    _openDetailScreen(
                      'Reverb',
                      Icons.wb_twilight_rounded,
                      (_) => _buildReverbSection(),
                      shape: Shapes.flower,
                    );
                  },
                  itemBuilder: (context, index) {
                    return _buildEffectTileCard(
                      icon: Icons.wb_twilight_rounded,
                      shape: Shapes.flower,
                      title: 'Reverb',
                      subtitle: _reverbEnabled
                          ? '$_reverbPreset · Wet ${(_reverbWet * 100).toInt()}% / Dry ${(_reverbDry * 100).toInt()}%'
                          : 'Disabled',
                      isEnabled: _reverbEnabled,
                      onToggle: (v) {
                        setState(() => _reverbEnabled = v);
                        _updateReverb();
                        _saveEqState();
                      },
                      onTapDetail: () => _openDetailScreen(
                        'Reverb',
                        Icons.wb_twilight_rounded,
                        (_) => _buildReverbSection(),
                        shape: Shapes.flower,
                      ),
                    );
                  },
                ),
              ),
            ),

            // Section 7: Master Dynamics & Protection
            SliverToBoxAdapter(
              child: _buildSectionHeader('Master Dynamics & Protection',
                  icon: Icons.shield_rounded),
            ),
            SliverToBoxAdapter(
              child: Padding(
                padding:
                    const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
                child: M3ECardList(
                  itemCount: 3,
                  onTap: (index) {
                    switch (index) {
                      case 0:
                        _openDetailScreen(
                          'Compressor',
                          Icons.tune_rounded,
                          (_) => _buildCompressorSection(),
                          shape: Shapes.burst,
                        );
                        break;
                      case 1:
                        _openDetailScreen(
                          'Master Peak Limiter',
                          Icons.shield_rounded,
                          (_) => _buildMasterLimiterSection(),
                          shape: Shapes.square,
                        );
                        break;
                      case 2:
                        _openDetailScreen(
                          'Soft Anti-Clipping Limiter',
                          Icons.compress_rounded,
                          (_) => _buildLimiterSection(),
                          shape: Shapes.diamond,
                        );
                        break;
                    }
                  },
                  itemBuilder: (context, index) {
                    if (index == 0) {
                      return _buildEffectTileCard(
                        icon: Icons.tune_rounded,
                        shape: Shapes.burst,
                        title: 'Compressor',
                        subtitle: _compressorEnabled
                            ? '$_compressorPreset · ${_compressorThresholdDb.toInt()} dB / ${_compressorRatio.toStringAsFixed(1)}:1'
                            : 'Disabled',
                        isEnabled: _compressorEnabled,
                        onToggle: (v) {
                          setState(() => _compressorEnabled = v);
                          _updateCompressor();
                          _saveEqState();
                        },
                        onTapDetail: () => _openDetailScreen(
                          'Compressor',
                          Icons.tune_rounded,
                          (_) => _buildCompressorSection(),
                          shape: Shapes.burst,
                        ),
                      );
                    }
                    if (index == 1) {
                      return _buildEffectTileCard(
                        icon: Icons.shield_rounded,
                        shape: Shapes.square,
                        title: 'Master Peak Limiter',
                        subtitle: _masterLimiterEnabled
                            ? 'Ceiling: ${_masterLimiterCeilingDb.toStringAsFixed(1)} dBFS'
                            : 'Disabled',
                        isEnabled: _masterLimiterEnabled,
                        onToggle: (v) {
                          setState(() => _masterLimiterEnabled = v);
                          _updateMasterLimiter();
                          _saveEqState();
                        },
                        onTapDetail: () => _openDetailScreen(
                          'Master Peak Limiter',
                          Icons.shield_rounded,
                          (_) => _buildMasterLimiterSection(),
                          shape: Shapes.square,
                        ),
                      );
                    }
                    return _buildEffectTileCard(
                      icon: Icons.compress_rounded,
                      shape: Shapes.diamond,
                      title: 'Soft Anti-Clipping Limiter',
                      subtitle: _limiterEnabled
                          ? 'Threshold: ${_limiterThreshold.toInt()}dB'
                          : 'Disabled',
                      isEnabled: _limiterEnabled,
                      onToggle: (v) {
                        setState(() => _limiterEnabled = v);
                        if (v) {
                          _applyLimiter();
                        } else {
                          widget.player.setLimiterEnabled(false);
                        }
                        _saveEqState();
                      },
                      onTapDetail: () => _openDetailScreen(
                        'Soft Anti-Clipping Limiter',
                        Icons.compress_rounded,
                        (_) => _buildLimiterSection(),
                        shape: Shapes.diamond,
                      ),
                    );
                  },
                ),
              ),
            ),

            // Bottom Spacing for floating player / nav
            const SliverToBoxAdapter(
              child: SizedBox(height: 120),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildPresetChip(String label) {
    final isSelected = _activePreset == label;
    return M3EChip(
      label: label,
      type: M3EChipType.filter,
      selected: isSelected,
      onPressed: () => _applyPreset(label),
    );
  }

  Future<void> _promptForValue({
    required String title,
    required double currentValue,
    required double min,
    required double max,
    required ValueChanged<double> onChanged,
  }) async {
    final controller =
        TextEditingController(text: currentValue.toStringAsFixed(2));
    await M3EDialog.show<void>(
      context,
      dialog: M3EDialog(
        title: 'Enter $title',
        topDivider: true,
        bottomDivider: true,
        content: Material(
          color: Colors.transparent,
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 8.0),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Allowed range: $min to $max',
                  style: TextStyle(
                    color: Colors.white.withValues(alpha: 0.6),
                    fontSize: 12,
                  ),
                ),
                const SizedBox(height: 12),
                M3ETextField(
                  controller: controller,
                  label: 'Value',
                ),
              ],
            ),
          ),
        ),
        actions: [
          M3EButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          M3EButton(
            onPressed: () {
              final val = double.tryParse(controller.text);
              if (val != null) {
                onChanged(val.clamp(min, max));
              }
              Navigator.pop(context);
            },
            child: const Text('OK'),
          ),
        ],
      ),
    );
  }

  Widget _buildPlaybackSpeedSection() {
    final hasCustomRate = (_playbackRate - 1.0).abs() >= 0.01;
    final hasCustomPitch = (_playbackPitch - 1.0).abs() >= 0.01;
    final isCustom = hasCustomRate || hasCustomPitch;

    String subtitleText;
    if (hasCustomRate && hasCustomPitch) {
      subtitleText =
          '${_playbackRate.toStringAsFixed(2)}x Speed • ${_playbackPitch.toStringAsFixed(2)}x Pitch';
    } else if (hasCustomRate) {
      subtitleText =
          '${_playbackRate.toStringAsFixed(2)}x Speed${_playbackPitchCorrection ? ' (Scaletempo)' : ''}';
    } else if (hasCustomPitch) {
      subtitleText = '${_playbackPitch.toStringAsFixed(2)}x Pitch';
    } else {
      subtitleText = 'Normal Speed (1.0x)';
    }

    return _CollapsibleSection(
      icon: Center(
        child: Icon(Icons.speed_rounded, color: primaryColor, size: 20),
      ),
      title: 'Speed & Pitch',
      subtitle: subtitleText,
      isEnabled: isCustom,
      onToggle: (v) {
        final newRate = v ? 1.25 : 1.0;
        final newPitch = 1.0;
        setState(() {
          _playbackRate = newRate;
          _playbackPitch = newPitch;
        });
        widget.player.setRate(newRate);
        widget.player.setPitch(newPitch);
        AppStateService.instance.savePlaybackRate(newRate);
        AppStateService.instance.savePlaybackPitch(newPitch);
      },
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 8.0, horizontal: 4.0),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Speed: ${_playbackRate.toStringAsFixed(2)}x',
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 14.5,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    'Pitch: ${_playbackPitch.toStringAsFixed(2)}x • ${_playbackPitchCorrection ? "Scaletempo ON" : "Resample Mode"}',
                    style: TextStyle(
                      color: Colors.white.withValues(alpha: 0.6),
                      fontSize: 12,
                    ),
                  ),
                ],
              ),
              M3EButton.icon(
                icon: Icon(Icons.tune_rounded, size: 16, color: primaryColor),
                label:
                    Text('Adjust Speed', style: TextStyle(color: primaryColor)),
                onPressed: () async {
                  await showPlaybackSpeedModal(
                    context,
                    widget.player,
                    currentRate: _playbackRate,
                    currentPitch: _playbackPitch,
                    currentPitchCorrection: _playbackPitchCorrection,
                    onRateChanged: (r) => setState(() => _playbackRate = r),
                    onPitchChanged: (p) => setState(() => _playbackPitch = p),
                    onPitchCorrectionChanged: (pc) =>
                        setState(() => _playbackPitchCorrection = pc),
                  );
                },
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildGraphicEqSection() {
    return _CollapsibleSection(
      icon: /*M3EContainer(
        Shapes.clampShell,
        width: 40,
        height: 40,
        color: primaryColor.withValues(alpha: 0.18),
        border: BorderSide(
          color: primaryColor.withValues(alpha: 0.4),
          width: 1.0,
        ),
        child: */
          Center(
        child: Icon(Icons.equalizer_rounded, color: primaryColor, size: 20),
        //  ),
      ),
      title: 'Graphic Equalizer',
      subtitle: '${_eqFrequencies.length}-Band Frequency',
      isEnabled: _masterEqEnabled,
      onToggle: (v) {
        setState(() => _masterEqEnabled = v);
        widget.player.setMultibandEqEnabled(v);
        _saveEqState();
      },
      children: [
        // 1. Sleek Preamp Control Strip
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
          decoration: BoxDecoration(
            color: surfaceDarkerColor,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(
              color: Colors.white.withValues(alpha: 0.08),
            ),
          ),
          child: Row(
            children: [
              Icon(
                Icons.volume_up_rounded,
                size: 18,
                color:
                    _preampDb != 0.0 ? Colors.deepOrangeAccent : Colors.white60,
              ),
              const SizedBox(width: 8),
              Text(
                'PREAMP',
                style: TextStyle(
                  color: Colors.white.withValues(alpha: 0.8),
                  fontSize: 11.5,
                  fontWeight: FontWeight.bold,
                  letterSpacing: 0.5,
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: M3ESlider.centered(
                  value: _preampDb.clamp(-12.0, 12.0),
                  min: -12.0,
                  max: 12.0,
                  trackThickness: 8.0,
                  cornerRadius: 6.0,
                  onChanged: (v) {
                    setState(() {
                      _preampDb = v;
                      double gain = math.pow(10, v / 20).toDouble();
                      widget.player.setGain(gain);
                    });
                  },
                  onChangeEnd: (_) => _saveEqState(),
                ),
              ),
              const SizedBox(width: 8),
              GestureDetector(
                onTap: () {
                  setState(() {
                    _preampDb = 0.0;
                    widget.player.setGain(1.0);
                  });
                  _saveEqState();
                },
                onLongPress: () => _promptForValue(
                  title: 'PREAMP',
                  currentValue: _preampDb,
                  min: -12.0,
                  max: 12.0,
                  onChanged: (v) {
                    setState(() {
                      _preampDb = v;
                      double gain = math.pow(10, v / 20).toDouble();
                      widget.player.setGain(gain);
                    });
                    _saveEqState();
                  },
                ),
                child: Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                  decoration: BoxDecoration(
                    color: Colors.deepOrangeAccent.withValues(alpha: 0.15),
                    borderRadius: BorderRadius.circular(6),
                    border: Border.all(
                      color: Colors.deepOrangeAccent.withValues(alpha: 0.3),
                    ),
                  ),
                  child: Text(
                    '${_preampDb > 0 ? '+' : ''}${_preampDb.toStringAsFixed(1)} dB',
                    style: const TextStyle(
                      color: Colors.deepOrangeAccent,
                      fontSize: 11,
                      fontWeight: FontWeight.bold,
                      fontFamily: 'monospace',
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 10),

        // 2. Interactive Spline Curve & Touch Node Controller
        RepaintBoundary(
          child: GraphicEqGraph(
            frequencies: _eqFrequencies,
            gains: _eqGains,
            preampDb: _preampDb,
            isEnabled: _masterEqEnabled,
            height: 215.0,
            primaryColor: primaryColor,
            onBandChanged: (index, gain) {
              if (!_masterEqEnabled) return;
              setState(() {
                _eqGains[index] = gain;
                _activePreset = 'Custom';
                widget.player.setMultibandEqBandGain(index, gain);
              });
            },
            onBandChangeEnd: () {
              if (_masterEqEnabled) _saveEqState();
            },
            onBandLongPress: (index) {
              if (!_masterEqEnabled) return;
              final freq = _eqFrequencies[index];
              final label = freq >= 1000
                  ? '${(freq / 1000).toStringAsFixed(freq % 1000 == 0 ? 0 : 1)}k'
                  : '${freq.toInt()}Hz';
              _promptForValue(
                title: 'Band Gain ($label)',
                currentValue: _eqGains[index],
                min: -12.0,
                max: 12.0,
                onChanged: (v) {
                  setState(() {
                    _eqGains[index] = v;
                    _activePreset = 'Custom';
                    widget.player.setMultibandEqBandGain(index, v);
                  });
                  _saveEqState();
                },
              );
            },
          ),
        ),
        const SizedBox(height: 10),

        // 3. Band Count Segmented Selector
        Padding(
          padding: const EdgeInsets.only(bottom: 12),
          child: M3ESegmentedButton<int>(
            segments: const [
              M3ESegment(value: 10, label: '10 Bands'),
              M3ESegment(value: 16, label: '16 Bands'),
              M3ESegment(value: 32, label: '32 Bands'),
            ],
            selected: {
              _eqFrequencies.length == 10 ||
                      _eqFrequencies.length == 16 ||
                      _eqFrequencies.length == 32
                  ? _eqFrequencies.length
                  : 10
            },
            onSelectionChanged: (Set<int> val) {
              if (val.isNotEmpty) {
                final bands = val.first;
                setState(() {
                  _setupFrequencies(bands);
                  widget.player.initMultibandEq(_eqFrequencies);
                  _applyPreset(_activePreset);
                });
                _saveEqState();
              }
            },
          ),
        ),

        // 4. Preset Chips Row
        SizedBox(
          height: 38,
          child: ListView(
            scrollDirection: Axis.horizontal,
            physics: const BouncingScrollPhysics(),
            children: [
              for (final preset in [
                'Flat',
                'Bass Boost',
                'Vocal',
                'Treble',
                'Rock',
                'Jazz',
              ]) ...[
                _buildPresetChip(preset),
                const SizedBox(width: 8),
              ],
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildCrystalizerSection() {
    const crystalColor = Color(0xFF00C9B1);
    return _CollapsibleSection(
      icon: /* M3EContainer(
        Shapes.burst,
        width: 40,
        height: 40,
        color: const Color(0x2600C9B1),
        border: const BorderSide(
          color: Color(0x6600C9B1),
          width: 1.0,
        ),
        child: */
          const Center(
        child: Icon(Icons.auto_fix_high_rounded, color: crystalColor, size: 20),
        // ),
      ),
      title: 'Crystalizer',
      subtitle: 'Transient reconstruction',
      isEnabled: _crystalizerEnabled,
      onToggle: (v) {
        setState(() => _crystalizerEnabled = v);
        _updateCrystalizer();
        _saveEqState();
      },
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceEvenly,
          children: [
            ModernAudioKnob(
              label: 'INTENSITY',
              value: _crystalizerIntensity,
              min: 0.0,
              max: 1.0,
              flatValue: 0.5,
              activeColor: _crystalizerEnabled ? crystalColor : Colors.white,
              isPercentage: true,
              valueFormatter: (v) => '${(v * 100).toInt()}%',
              onChanged: (v) {
                setState(() => _crystalizerIntensity = v);
                if (_crystalizerEnabled) _updateCrystalizer();
                _saveEqState();
              },
            ),
            ModernAudioKnob(
              label: 'AIR SHELF',
              value: _crystalizerShelfGain,
              min: 0.0,
              max: 6.0,
              flatValue: 2.0,
              activeColor: _crystalizerHighShelf && _crystalizerEnabled
                  ? crystalColor
                  : Colors.white38,
              valueFormatter: (v) =>
                  '${v > 0 ? '+' : ''}${v.toStringAsFixed(1)} dB',
              onChanged: (v) {
                if (!_crystalizerHighShelf) return;
                setState(() => _crystalizerShelfGain = v);
                if (_crystalizerEnabled) _updateCrystalizer();
                _saveEqState();
              },
            ),
          ],
        ),
        const SizedBox(height: 16),
        // High-shelf toggle
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Text(
              'High-shelf Air boost',
              style: TextStyle(
                color: Colors.white.withValues(alpha: 0.75),
                fontSize: 13,
                fontWeight: FontWeight.w500,
              ),
            ),
            const SizedBox(width: 12),
            M3ESwitch(
              selectedIcon: Icon(Icons.check, color: primaryColor),
              value: _crystalizerHighShelf,
              onChanged: (v) {
                setState(() => _crystalizerHighShelf = v);
                if (_crystalizerEnabled) _updateCrystalizer();
                _saveEqState();
              },
            ),
          ],
        ),
        const SizedBox(height: 8),
        Center(
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
            decoration: BoxDecoration(
              color: const Color(0x1A00C9B1),
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: const Color(0x4000C9B1)),
            ),
            child: Text(
              'Recovers transient detail & "air" lost in compressed audio',
              style: TextStyle(
                color: Colors.white.withValues(alpha: 0.6),
                fontSize: 11,
              ),
              textAlign: TextAlign.center,
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildCrossfeedSection() {
    return _CollapsibleSection(
      icon: /* M3EContainer(
        Shapes.arch,
        width: 40,
        height: 40,
        color: primaryColor.withValues(alpha: 0.18),
        border: BorderSide(
          color: primaryColor.withValues(alpha: 0.4),
          width: 1.0,
        ),
        child:*/
          Center(
        child: Icon(Icons.headphones_rounded, color: primaryColor, size: 20),
        //  ),
      ),
      title: 'Crossfeed',
      subtitle: 'Simulate natural acoustic speaker listening',
      isEnabled: _crossfeedEnabled,
      onToggle: (v) {
        setState(() => _crossfeedEnabled = v);
        _updateCrossfeed();
        _saveEqState();
      },
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text('Algorithm',
                style: TextStyle(
                    color: Colors.white.withValues(alpha: 0.85),
                    fontSize: 13.5,
                    fontWeight: FontWeight.w600)),
            /* M3EContainer(
              Shapes.pill,
              color: surfaceDarkColor,
              border: BorderSide(color: primaryColor.withValues(alpha: 0.35)),
              child:*/
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 2),
              child: DropdownButtonHideUnderline(
                child: DropdownButton<int>(
                  value: _crossfeedAlgorithmIndex,
                  dropdownColor: surfaceDarkerColor,
                  icon:
                      Icon(Icons.arrow_drop_down_rounded, color: primaryColor),
                  style: const TextStyle(
                      color: Colors.white,
                      fontSize: 13,
                      fontWeight: FontWeight.w600),
                  items: const [
                    DropdownMenuItem(
                        value: 1, child: Text('Simple Reference (Headphones)')),
                    DropdownMenuItem(
                        value: 2, child: Text('Bauer BS2B (Headphones)')),
                    DropdownMenuItem(
                        value: 3, child: Text('Jan Meier (Headphones)')),
                    DropdownMenuItem(
                        value: 4, child: Text('Custom Natural (Headphones)')),
                    DropdownMenuItem(
                        value: 5,
                        child:
                            Text('Ambiophonics RACE (Speakers / Dipole XTC)')),
                  ],
                  onChanged: (val) {
                    if (val != null) {
                      setState(() {
                        _crossfeedAlgorithmIndex = val;
                        _crossfeedEnabled = true;
                      });
                      _updateCrossfeed();
                      _saveEqState();
                    }
                  },
                  // ),
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 16),
        if (_crossfeedAlgorithmIndex >= 1 && _crossfeedAlgorithmIndex <= 4) ...[
          RepaintBoundary(
            child: CrossfeedGraph(
              algorithmIndex: _crossfeedAlgorithmIndex,
              mix: _crossfeedMix,
              cutoffHz: _crossfeedCutoffHz,
              delayMs: _crossfeedDelayMs,
              compensation: _crossfeedCompensation,
              isEnabled: _crossfeedEnabled,
              height: 120.0,
              primaryColor: primaryColor,
            ),
          ),
          const SizedBox(height: 12),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceEvenly,
            children: [
              ModernAudioKnob(
                label: 'CROSSFEED MIX',
                value: _crossfeedMix,
                min: 0.0,
                max: 1.0,
                flatValue: 0.5,
                activeColor: _crossfeedEnabled ? primaryColor : Colors.white,
                isPercentage: true,
                valueFormatter: (v) => '${(v * 100).toInt()}%',
                onChanged: (v) {
                  setState(() => _crossfeedMix = v);
                  if (_crossfeedEnabled) _updateCrossfeed();
                  _saveEqState();
                },
              ),
              ModernAudioKnob(
                label: 'ITD DELAY',
                value: (_crossfeedDelayMs - 0.05) / 1.95,
                min: 0.0,
                max: 1.0,
                flatValue: (0.40 - 0.05) / 1.95,
                activeColor: _crossfeedEnabled ? primaryColor : Colors.white,
                valueFormatter: (_) =>
                    '${(_crossfeedDelayMs * 1000).round()}µs',
                onChanged: (v) {
                  setState(() => _crossfeedDelayMs = 0.05 + v * 1.95);
                  if (_crossfeedEnabled) _updateCrossfeed();
                  _saveEqState();
                },
              ),
              ModernAudioKnob(
                label: 'CUTOFF FREQ',
                value: (_crossfeedCutoffHz - 200.0) / 2800.0,
                min: 0.0,
                max: 1.0,
                flatValue: (700.0 - 200.0) / 2800.0,
                activeColor: _crossfeedEnabled ? primaryColor : Colors.white,
                valueFormatter: (_) => '${_crossfeedCutoffHz.toInt()}Hz',
                onChanged: (v) {
                  setState(() => _crossfeedCutoffHz = 200.0 + v * 2800.0);
                  if (_crossfeedEnabled) _updateCrossfeed();
                  _saveEqState();
                },
              ),
            ],
          ),
          const SizedBox(height: 14),
          InkWell(
            onTap: () {
              setState(() => _crossfeedCompensation = !_crossfeedCompensation);
              if (_crossfeedEnabled) _updateCrossfeed();
              _saveEqState();
            },
            borderRadius: BorderRadius.circular(12),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              decoration: BoxDecoration(
                color: surfaceDarkColor.withValues(alpha: 0.6),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(
                  color: _crossfeedCompensation
                      ? primaryColor.withValues(alpha: 0.4)
                      : Colors.white10,
                ),
              ),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Row(
                    children: [
                      Icon(
                        Icons.equalizer_rounded,
                        size: 18,
                        color: _crossfeedCompensation
                            ? primaryColor
                            : Colors.white54,
                      ),
                      const SizedBox(width: 8),
                      const Text(
                        'Output Loudness Compensation',
                        style: TextStyle(color: Colors.white, fontSize: 13),
                      ),
                    ],
                  ),
                  M3ESwitch(
                    selectedIcon: Icon(Icons.check, color: primaryColor),
                    value: _crossfeedCompensation,
                    onChanged: (v) {
                      setState(() => _crossfeedCompensation = v);
                      if (_crossfeedEnabled) _updateCrossfeed();
                      _saveEqState();
                    },
                  ),
                ],
              ),
            ),
          ),
        ] else if (_crossfeedAlgorithmIndex == 5) ...[
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            decoration: BoxDecoration(
              color: primaryColor.withValues(alpha: 0.08),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: primaryColor.withValues(alpha: 0.2)),
            ),
            child: Row(
              children: [
                Icon(Icons.speaker_group_outlined,
                    size: 18, color: primaryColor),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    'Loudspeaker Crosstalk Elimination.',
                    style: TextStyle(
                      color: Colors.white.withValues(alpha: 0.75),
                      fontSize: 11.5,
                      fontWeight: FontWeight.w400,
                    ),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 10),
          RepaintBoundary(
            child: RaceSoundstageVisualizer(
              delayMs: _raceDelayMs,
              alpha: _raceAlpha,
              lpfHz: _raceLpfHz,
              isEnabled: _crossfeedEnabled,
              primaryColor: primaryColor,
            ),
          ),
          const SizedBox(height: 12),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceEvenly,
            children: [
              ModernAudioKnob(
                label: 'ITD DELAY',
                value: (_raceDelayMs - 0.05) / 0.35,
                min: 0.0,
                max: 1.0,
                flatValue: (0.166 - 0.05) / 0.35,
                activeColor: _crossfeedEnabled ? primaryColor : Colors.white,
                valueFormatter: (_) => '${(_raceDelayMs * 1000).round()}µs',
                onChanged: (v) {
                  setState(() => _raceDelayMs = 0.05 + v * 0.35);
                  if (_crossfeedEnabled) _updateCrossfeed();
                  _saveEqState();
                },
              ),
              ModernAudioKnob(
                label: 'ATTENUATION',
                value: (_raceAlpha - 0.10) / 0.80,
                min: 0.0,
                max: 1.0,
                flatValue: (0.55 - 0.10) / 0.80,
                activeColor: _crossfeedEnabled ? primaryColor : Colors.white,
                isPercentage: true,
                valueFormatter: (_) => '${(_raceAlpha * 100).toInt()}%',
                onChanged: (v) {
                  setState(() => _raceAlpha = 0.10 + v * 0.80);
                  if (_crossfeedEnabled) _updateCrossfeed();
                  _saveEqState();
                },
              ),
              ModernAudioKnob(
                label: 'HEAD LPF',
                value: (_raceLpfHz - 500.0) / 7500.0,
                min: 0.0,
                max: 1.0,
                flatValue: (2500.0 - 500.0) / 7500.0,
                activeColor: _crossfeedEnabled ? primaryColor : Colors.white,
                valueFormatter: (_) => '${_raceLpfHz.toInt()}Hz',
                onChanged: (v) {
                  setState(() => _raceLpfHz = 500.0 + v * 7500.0);
                  if (_crossfeedEnabled) _updateCrossfeed();
                  _saveEqState();
                },
              ),
            ],
          ),
        ],
      ],
    );
  }

  Widget _buildStereoWidenSection() {
    return _CollapsibleSection(
      icon: /* M3EContainer(
        Shapes.slanted,
        width: 40,
        height: 40,
        color: primaryColor.withValues(alpha: 0.18),
        border: BorderSide(
          color: primaryColor.withValues(alpha: 0.4),
          width: 1.0,
        ),
        child: */
          Center(
        child: Icon(Icons.swap_horiz_rounded, color: primaryColor, size: 20),
        // ),
      ),
      title: 'Stereo Widener',
      subtitle: 'Mid/Side matrix & Haas effect width expansion',
      isEnabled: _stereoWidenEnabled,
      onToggle: (v) {
        setState(() => _stereoWidenEnabled = v);
        if (v) {
          _updateStereoWiden();
        } else {
          widget.player.setStereoWiden(
              enabled: false,
              width: _stereoWidenWidth,
              delayMs: _stereoWidenDelayMs * 100.0);
        }
        _saveEqState();
      },
      children: [
        RepaintBoundary(
          child: StereoVectorscopeGraph(
            width: _stereoWidenWidth,
            delayMs: _stereoWidenDelayMs,
            isEnabled: _stereoWidenEnabled,
            height: 195.0,
            primaryColor: primaryColor,
          ),
        ),
        const SizedBox(height: 12),
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceEvenly,
          children: [
            ModernAudioKnob(
              label: 'WIDTH',
              value: (_stereoWidenWidth / 5.0).clamp(0.0, 1.0),
              min: 0.0,
              max: 1.0,
              flatValue: 0.2, // Maps to 1.0
              activeColor: _stereoWidenEnabled ? primaryColor : Colors.white,
              displayMultiplier: 5.0,
              valueFormatter: (v) => '${(v * 5.0).toStringAsFixed(1)}x',
              onChanged: (v) {
                setState(() => _stereoWidenWidth = v * 5.0);
                if (_stereoWidenEnabled) _updateStereoWiden();
                _saveEqState();
              },
            ),
            ModernAudioKnob(
              label: 'HAAS DELAY',
              value: _stereoWidenDelayMs,
              min: 0.0,
              max: 1.0,
              flatValue: 0.15,
              activeColor: _stereoWidenEnabled ? primaryColor : Colors.white,
              isPercentage: true,
              valueFormatter: (v) => '${(v * 100).toInt()}ms',
              onChanged: (v) {
                setState(() => _stereoWidenDelayMs = v);
                if (_stereoWidenEnabled) _updateStereoWiden();
                _saveEqState();
              },
            ),
          ],
        ),
      ],
    );
  }

  Widget _buildStereoEnhancementSection() {
    return _CollapsibleSection(
      icon: /* M3EContainer(
        Shapes.puffyDiamond,
        width: 40,
        height: 40,
        color: primaryColor.withValues(alpha: 0.18),
        border: BorderSide(
          color: primaryColor.withValues(alpha: 0.4),
          width: 1.0,
        ),
        child:*/
          Center(
        child:
            Icon(Icons.surround_sound_rounded, color: primaryColor, size: 20),
        //),
      ),
      title: 'Stereo Enhancer',
      subtitle: 'Warped PFB M/S Widening',
      isEnabled: _stereoEnhancementEnabled,
      onToggle: (v) {
        setState(() => _stereoEnhancementEnabled = v);
        _updateStereoEnhancement();
        _saveEqState();
      },
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceEvenly,
          children: [
            ModernAudioKnob(
              label: 'STEREO MIX',
              value: _stereoEnhancementMix,
              min: 0.0,
              max: 1.0,
              flatValue: 0.5,
              activeColor:
                  _stereoEnhancementEnabled ? primaryColor : Colors.white,
              isPercentage: true,
              valueFormatter: (v) => '${(v * 100).toInt()}%',
              onChanged: (v) {
                setState(() => _stereoEnhancementMix = v);
                if (_stereoEnhancementEnabled) _updateStereoEnhancement();
                _saveEqState();
              },
            ),
          ],
        ),
        const SizedBox(height: 10),
        Center(
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
            decoration: BoxDecoration(
              color: primaryColor.withValues(alpha: 0.1),
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: primaryColor.withValues(alpha: 0.25)),
            ),
            child: Text(
              _stereoEnhancementMix == 0.5
                  ? 'Pass-through (Original Stereo)'
                  : (_stereoEnhancementMix > 0.5
                      ? 'Stereo Widening (Center Subtraction)'
                      : 'Mono Center Extraction'),
              style: TextStyle(
                color: Colors.white.withValues(alpha: 0.65),
                fontSize: 11,
              ),
              textAlign: TextAlign.center,
            ),
          ),
        ),
      ],
    );
  }

  void _updateCrystalizer() {
    widget.player.setCrystalizer(
      enabled: _crystalizerEnabled,
      intensity: _crystalizerIntensity,
      highShelfEnabled: _crystalizerHighShelf,
      highShelfGainDb: _crystalizerShelfGain,
    );
  }

  void _updateCrossfeed() {
    if (!_crossfeedEnabled) {
      widget.player.setCrossfeed(enabled: false, preset: 0);
      widget.player.setCrossfeedAlgorithm(CrossfeedAlgorithm.off);
      return;
    }

    if (_crossfeedAlgorithmIndex == 5) {
      widget.player.setCrossfeed(enabled: true, preset: 4);
      widget.player.setCrossfeedAlgorithm(CrossfeedAlgorithm.race);
      widget.player.setRaceParams(
        delayMs: _raceDelayMs,
        alpha: _raceAlpha,
        lpfHz: _raceLpfHz,
      );
    } else {
      CrossfeedAlgorithm algo = CrossfeedAlgorithm.off;
      if (_crossfeedAlgorithmIndex == 1) {
        algo = CrossfeedAlgorithm.simple;
      } else if (_crossfeedAlgorithmIndex == 2) {
        algo = CrossfeedAlgorithm.bs2b;
      } else if (_crossfeedAlgorithmIndex == 3) {
        algo = CrossfeedAlgorithm.meier;
      } else if (_crossfeedAlgorithmIndex == 4) {
        algo = CrossfeedAlgorithm.natural;
      }
      widget.player.setCrossfeedAlgorithm(algo);
      widget.player.setCrossfeedParams(
        mix: _crossfeedMix,
        delayMs: _crossfeedDelayMs,
        cutoffHz: _crossfeedCutoffHz,
        outputCompensation: _crossfeedCompensation,
      );
    }
  }

  void _updateStereoWiden() {
    double delayMsMapping = _stereoWidenDelayMs * 100.0;
    widget.player.setStereoWiden(
      enabled: _stereoWidenEnabled,
      width: _stereoWidenWidth,
      delayMs: delayMsMapping,
    );
  }

  Widget _buildAudioTuningSection() {
    return _CollapsibleSection(
      icon: /* M3EContainer(
        Shapes.pill,
        width: 40,
        height: 40,
        color: primaryColor.withValues(alpha: 0.18),
        border: BorderSide(
          color: primaryColor.withValues(alpha: 0.4),
          width: 1.0,
        ),
        child: */
          Center(
        child: Icon(Icons.tune_rounded, color: primaryColor, size: 20),
      ),
      //),
      title: '3-Band Audio Tuning',
      subtitle: 'Bass, midrange & treble tone control',
      isEnabled: _audioTuningEnabled,
      onToggle: (v) {
        setState(() => _audioTuningEnabled = v);
        widget.player.setEqEnabled(v);
        if (v) {
          widget.player.setEq(low: _tuneLow, mid: _tuneMid, high: _tuneHigh);
        }
        _saveEqState();
      },
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceEvenly,
          children: [
            ModernAudioKnob(
              label: 'BASS',
              value: _tuneLow,
              min: -24.0,
              max: 12.0,
              flatValue: 0.0,
              activeColor: _audioTuningEnabled ? primaryColor : Colors.white,
              valueFormatter: (v) =>
                  '${v > 0 ? '+' : ''}${v.toStringAsFixed(1)} dB',
              onChanged: (v) {
                setState(() => _tuneLow = v);
                if (_audioTuningEnabled) {
                  widget.player
                      .setEq(low: _tuneLow, mid: _tuneMid, high: _tuneHigh);
                }
                _saveEqState();
              },
            ),
            ModernAudioKnob(
              label: 'MID',
              value: _tuneMid,
              min: -24.0,
              max: 12.0,
              flatValue: 0.0,
              activeColor: _audioTuningEnabled ? primaryColor : Colors.white,
              valueFormatter: (v) =>
                  '${v > 0 ? '+' : ''}${v.toStringAsFixed(1)} dB',
              onChanged: (v) {
                setState(() => _tuneMid = v);
                if (_audioTuningEnabled) {
                  widget.player
                      .setEq(low: _tuneLow, mid: _tuneMid, high: _tuneHigh);
                }
                _saveEqState();
              },
            ),
            ModernAudioKnob(
              label: 'TREBLE',
              value: _tuneHigh,
              min: -24.0,
              max: 12.0,
              flatValue: 0.0,
              activeColor: _audioTuningEnabled ? primaryColor : Colors.white,
              valueFormatter: (v) =>
                  '${v > 0 ? '+' : ''}${v.toStringAsFixed(1)} dB',
              onChanged: (v) {
                setState(() => _tuneHigh = v);
                if (_audioTuningEnabled) {
                  widget.player
                      .setEq(low: _tuneLow, mid: _tuneMid, high: _tuneHigh);
                }
                _saveEqState();
              },
            ),
          ],
        ),
      ],
    );
  }

  void _applyParametricBands() {
    widget.player.setMultibandFxBands(_parametricBands);
  }

  /// Dynamically computes the next band frequency based on user patterns:
  /// - Empty: starts at 60 Hz.
  /// - 1 band (e.g. 60 Hz): adds +30 Hz by default (90 Hz).
  /// - 2 bands:
  ///   - [30, 60] -> 120 Hz (octave doubling)
  ///   - [45, 90] -> 135 Hz (difference +45 Hz)
  ///   - [60, 90] -> 120 Hz (difference +30 Hz)
  ///   - General: uses difference (fLast - fPrev)
  /// - 3+ bands:
  ///   - Geometric doubling / ratio matching: multiplies by ratio (e.g. 30-60-120 -> 240 -> 480...)
  ///   - Arithmetic step / difference matching: adds difference (e.g. 45-90-135 -> 180 -> 225...)
  ///   - Fallback: adds last difference
  double _calculateNextBandFrequency() {
    if (_parametricBands.isEmpty) {
      return 60.0;
    }

    final sortedFreqs = _parametricBands.map((b) => b.frequencyHz).toList()
      ..sort();
    final count = sortedFreqs.length;

    if (count == 1) {
      final f0 = sortedFreqs.first;
      // "when i add bands from like 60 it adds +30 by default"
      if ((f0 - 60.0).abs() < 2.0) {
        return 90.0;
      } else if ((f0 - 45.0).abs() < 2.0) {
        return 90.0;
      } else if ((f0 - 30.0).abs() < 2.0) {
        return 60.0;
      } else if (f0 < 100.0) {
        return (f0 + 30.0).clamp(20.0, 20000.0);
      } else {
        return (f0 + 30.0).clamp(20.0, 20000.0);
      }
    }

    final fLast = sortedFreqs[count - 1];
    final fPrev = sortedFreqs[count - 2];
    final diff = fLast - fPrev;
    final ratio = fPrev > 0 ? fLast / fPrev : 2.0;

    // Check if we have 3 or more bands to detect arithmetic vs geometric pattern
    if (count >= 3) {
      final fPrev2 = sortedFreqs[count - 3];
      final prevDiff = fPrev - fPrev2;
      final prevRatio = fPrev2 > 0 ? fPrev / fPrev2 : 2.0;

      // 1. Geometric / Octave progression (e.g. 30 - 60 - 120 -> 240 -> 480...)
      final isGeometric = (ratio - prevRatio).abs() < 0.15 && ratio > 1.15;
      if (isGeometric) {
        final nextFreq = (fLast * ratio).roundToDouble();
        return nextFreq.clamp(20.0, 20000.0);
      }

      // 2. Arithmetic / Constant Difference (e.g. 45 - 90 - 135 -> 180 -> 225...)
      final isArithmetic = (diff - prevDiff).abs() < 6.0 && diff > 2.0;
      if (isArithmetic) {
        final nextFreq = (fLast + diff).roundToDouble();
        return nextFreq.clamp(20.0, 20000.0);
      }
    }

    // Special cases for 2 bands:
    // If [30, 60]: User highlighted "if 30-60-120 ...." -> 30, 60 doubles to 120!
    if ((fPrev - 30.0).abs() < 2.0 && (fLast - 60.0).abs() < 2.0) {
      return 120.0;
    }

    // If [45, 90]: User highlighted "45 hz - 90 hz -135 hz" -> difference is 45 -> 135!
    if ((fPrev - 45.0).abs() < 2.0 && (fLast - 90.0).abs() < 2.0) {
      return 135.0;
    }

    // If [60, 90]: User highlighted "from like 60 it adds +30 by default" -> 60, 90 -> diff is 30 -> 120!
    if ((fPrev - 60.0).abs() < 2.0 && (fLast - 90.0).abs() < 2.0) {
      return 120.0;
    }

    // General fallback for 2+ bands: "use the difference eg any difference"
    if (diff > 5.0) {
      final nextFreq = (fLast + diff).roundToDouble();
      if (nextFreq <= 20000.0) {
        return nextFreq;
      }
    }

    if (fLast < 10000.0) {
      return (fLast + 30.0).clamp(20.0, 20000.0);
    }

    return 20000.0;
  }

  Future<void> _loadUserParametricProfiles() async {
    final prefs = await SharedPreferences.getInstance();
    final rawJson = prefs.getString(_kUserParametricProfilesKey);
    if (rawJson != null && rawJson.isNotEmpty) {
      try {
        final decoded = jsonDecode(rawJson) as Map<String, dynamic>;
        _userParametricProfiles.clear();
        decoded.forEach((name, rawBands) {
          if (rawBands is List) {
            final bands = rawBands.map((m) {
              final map = Map<String, dynamic>.from(m as Map);
              final typeIdx = (map['type'] as num?)?.toInt() ?? 0;
              final type = (typeIdx >= 0 && typeIdx < EqBandType.values.length)
                  ? EqBandType.values[typeIdx]
                  : EqBandType.peak;
              return EqBandConfig(
                type: type,
                frequencyHz: (map['frequency'] as num?)?.toDouble() ?? 1000.0,
                gainDb: (map['gainDb'] as num?)?.toDouble() ?? 0.0,
                q: (map['q'] as num?)?.toDouble() ?? 1.2,
                slope: (map['slope'] as num?)?.toDouble() ?? 1.0,
                enabled: map['enabled'] as bool? ?? true,
              );
            }).toList();
            _userParametricProfiles[name] = bands;
          }
        });
      } catch (e) {
        debugPrint('Error loading user parametric profiles: $e');
      }
    }
    final savedPreset = prefs.getString(_kActiveParametricPresetKey);
    if (savedPreset != null && savedPreset.isNotEmpty) {
      _parametricPreset = savedPreset;
    }
  }

  Future<void> _saveUserParametricProfile(String name) async {
    final prefs = await SharedPreferences.getInstance();
    _userParametricProfiles[name] = List<EqBandConfig>.from(_parametricBands);
    final mapToSave = <String, dynamic>{};
    _userParametricProfiles.forEach((pName, bands) {
      mapToSave[pName] = bands
          .map((b) => {
                'type': b.type.index,
                'frequency': b.frequencyHz,
                'q': b.q,
                'gainDb': b.gainDb,
                'slope': b.slope,
                'enabled': b.enabled,
              })
          .toList();
    });
    await prefs.setString(_kUserParametricProfilesKey, jsonEncode(mapToSave));
    setState(() {
      _parametricPreset = name;
    });
    await prefs.setString(_kActiveParametricPresetKey, name);
    _saveEqState();
  }

  Future<void> _deleteUserParametricProfile(String name) async {
    final prefs = await SharedPreferences.getInstance();
    _userParametricProfiles.remove(name);
    final mapToSave = <String, dynamic>{};
    _userParametricProfiles.forEach((pName, bands) {
      mapToSave[pName] = bands
          .map((b) => {
                'type': b.type.index,
                'frequency': b.frequencyHz,
                'q': b.q,
                'gainDb': b.gainDb,
                'slope': b.slope,
                'enabled': b.enabled,
              })
          .toList();
    });
    await prefs.setString(_kUserParametricProfilesKey, jsonEncode(mapToSave));
    setState(() {
      _parametricPreset = 'Custom';
    });
    await prefs.setString(_kActiveParametricPresetKey, 'Custom');
    _saveEqState();
  }

  void _showSaveProfileDialog() {
    final controller = TextEditingController();
    showDialog<void>(
      context: context,
      builder: (dialogContext) {
        return AlertDialog(
          backgroundColor: surfaceDarkColor,
          shape:
              RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
          title: const Row(
            children: [
              Icon(Icons.bookmark_add_rounded, color: Colors.white, size: 22),
              SizedBox(width: 8),
              Text('Save Parametric Profile',
                  style: TextStyle(
                      color: Colors.white,
                      fontSize: 16,
                      fontWeight: FontWeight.bold)),
            ],
          ),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Save current ${_parametricBands.length} bands as a named custom profile.',
                style: TextStyle(
                    color: Colors.white.withValues(alpha: 0.7), fontSize: 13),
              ),
              const SizedBox(height: 14),
              TextField(
                controller: controller,
                autofocus: true,
                style: const TextStyle(color: Colors.white, fontSize: 14),
                decoration: InputDecoration(
                  hintText: 'e.g. My Studio Monitors',
                  hintStyle:
                      TextStyle(color: Colors.white.withValues(alpha: 0.4)),
                  filled: true,
                  fillColor: surfaceDarkerColor,
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(10),
                    borderSide:
                        BorderSide(color: Colors.white.withValues(alpha: 0.15)),
                  ),
                  focusedBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(10),
                    borderSide: BorderSide(color: primaryColor),
                  ),
                ),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(),
              child: Text('Cancel',
                  style: TextStyle(color: Colors.white.withValues(alpha: 0.6))),
            ),
            FilledButton(
              style: FilledButton.styleFrom(backgroundColor: primaryColor),
              onPressed: () {
                final name = controller.text.trim();
                if (name.isNotEmpty && !name.startsWith('__')) {
                  Navigator.of(dialogContext).pop();
                  _saveUserParametricProfile(name);
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(
                      content: Text('Profile "$name" saved!'),
                      duration: const Duration(seconds: 2),
                      backgroundColor: surfaceDarkColor,
                    ),
                  );
                }
              },
              child: const Text('Save Profile',
                  style: TextStyle(
                      color: Colors.black, fontWeight: FontWeight.bold)),
            ),
          ],
        );
      },
    );
  }

  void _applyParametricPreset(String presetName) {
    List<EqBandConfig>? sourceBands = _builtInParametricPresets[presetName];
    sourceBands ??= _userParametricProfiles[presetName];
    if (sourceBands == null) return;

    setState(() {
      _parametricPreset = presetName;
      _parametricBands.clear();
      _parametricBands.addAll(sourceBands!.map((b) => EqBandConfig(
            type: b.type,
            frequencyHz: b.frequencyHz,
            enabled: b.enabled,
            q: b.q,
            gainDb: b.gainDb,
            slope: b.slope,
          )));
      _applyParametricBands();
    });
    _saveEqState();
  }

  List<String> _getAllParametricPresetNames() {
    return [
      ..._builtInParametricPresets.keys,
      ..._userParametricProfiles.keys,
    ];
  }

  List<DropdownMenuItem<String>> _buildParametricDropdownItems() {
    final items = <DropdownMenuItem<String>>[];

    // Built-in presets header
    items.add(DropdownMenuItem<String>(
      enabled: false,
      value: '__header_builtin__',
      child: Text(
        '— PARAMETRIC PRESETS —',
        style: TextStyle(
          color: primaryColor,
          fontSize: 11,
          fontWeight: FontWeight.bold,
          letterSpacing: 0.8,
        ),
      ),
    ));

    for (final name in _builtInParametricPresets.keys) {
      if (name == 'Octave Series (30-60-120...)') {
        items.add(DropdownMenuItem<String>(
          enabled: false,
          value: '__header_series__',
          child: Text(
            '— FREQUENCY SERIES —',
            style: TextStyle(
              color: primaryColor,
              fontSize: 11,
              fontWeight: FontWeight.bold,
              letterSpacing: 0.8,
            ),
          ),
        ));
      }

      items.add(DropdownMenuItem<String>(
        value: name,
        child: Text(name, overflow: TextOverflow.ellipsis),
      ));
    }

    // User profiles header
    if (_userParametricProfiles.isNotEmpty) {
      items.add(DropdownMenuItem<String>(
        enabled: false,
        value: '__header_user__',
        child: Text(
          '— SAVED PROFILES —',
          style: TextStyle(
            color: primaryColor,
            fontSize: 11,
            fontWeight: FontWeight.bold,
            letterSpacing: 0.8,
          ),
        ),
      ));

      for (final name in _userParametricProfiles.keys) {
        items.add(DropdownMenuItem<String>(
          value: name,
          child: Text(name, overflow: TextOverflow.ellipsis),
        ));
      }
    }

    // Ensure currently selected value is present in dropdown
    final currentSelected =
        _getAllParametricPresetNames().contains(_parametricPreset)
            ? _parametricPreset
            : 'Custom';

    if (!items.any((item) => item.value == currentSelected)) {
      items.add(DropdownMenuItem<String>(
        value: currentSelected,
        child: Text(currentSelected == 'Custom' ? 'Custom' : currentSelected),
      ));
    }

    return items;
  }

  Widget _buildParametricEqSection() {
    return _CollapsibleSection(
      icon: Center(
        child: Icon(Icons.show_chart_rounded, color: primaryColor, size: 20),
      ),
      title: 'Parametric Equalizer',
      subtitle: 'Dynamic cascade filter nodes',
      isEnabled: _parametricEqEnabled,
      onToggle: (v) {
        setState(() {
          _parametricEqEnabled = v;
          if (v && _parametricBands.isEmpty) {
            final defBands =
                _builtInParametricPresets['Default (3-Band)'] ?? [];
            _parametricBands.addAll(defBands.map((b) => EqBandConfig(
                  type: b.type,
                  frequencyHz: b.frequencyHz,
                  gainDb: b.gainDb,
                  q: b.q,
                  slope: b.slope,
                )));
          }
          if (v) {
            widget.player.initMultibandFx(_parametricBands);
          }
          widget.player.setMultibandFxEnabled(v);
        });
        _saveEqState();
      },
      children: [
        RepaintBoundary(
          child: ParametricEqGraph(
            bands: _parametricBands,
            isEnabled: _parametricEqEnabled,
            height: 110.0,
            primaryColor: primaryColor,
          ),
        ),
        const SizedBox(height: 12),
        // Preset and Controls Bar
        Row(
          children: [
            // Dropdown in expanded container
            Expanded(
              child: Container(
                height: 40,
                padding: const EdgeInsets.symmetric(horizontal: 10),
                decoration: BoxDecoration(
                  color: surfaceDarkerColor,
                  borderRadius: BorderRadius.circular(10),
                  border:
                      Border.all(color: Colors.white.withValues(alpha: 0.12)),
                ),
                child: DropdownButtonHideUnderline(
                  child: DropdownButton<String>(
                    value: _getAllParametricPresetNames()
                            .contains(_parametricPreset)
                        ? _parametricPreset
                        : 'Custom',
                    isExpanded: true,
                    dropdownColor: surfaceDarkColor,
                    icon: Icon(Icons.arrow_drop_down_rounded,
                        color: primaryColor),
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 12.5,
                      fontWeight: FontWeight.w600,
                    ),
                    items: _buildParametricDropdownItems(),
                    onChanged: (v) {
                      if (v != null && v != 'Custom' && !v.startsWith('__')) {
                        _applyParametricPreset(v);
                      }
                    },
                  ),
                ),
              ),
            ),
            const SizedBox(width: 6),
            // Save Profile Button
            M3EIconButton(
              tooltip: 'Save Profile',
              icon: Icon(Icons.bookmark_add_rounded,
                  size: 18, color: primaryColor),
              variant: M3EIconButtonVariant.standard,
              onPressed: _showSaveProfileDialog,
            ),
            // Delete Custom Profile Button (if active preset is a user profile)
            /* if (_userParametricProfiles.containsKey(_parametricPreset)) ...[
              const SizedBox(width: 4),
              M3EIconButton(
                tooltip: 'Delete Profile',
                icon: const Icon(Icons.delete_outline_rounded,
                    size: 18, color: Colors.redAccent),
                variant: M3EIconButtonVariant.standard,
                onPressed: () =>
                    _deleteUserParametricProfile(_parametricPreset),
              ),
            ],
            // Sort Bands Button
             if (_parametricBands.length > 1) ...[
              const SizedBox(width: 4),
              M3EIconButton(
                tooltip: 'Sort by Frequency',
                icon: const Icon(Icons.sort_rounded,
                    size: 18, color: Colors.white70),
                variant: M3EIconButtonVariant.standard,
                onPressed: () {
                  setState(() {
                    _parametricBands
                        .sort((a, b) => a.frequencyHz.compareTo(b.frequencyHz));
                    _applyParametricBands();
                    _saveEqState();
                  });
                },
              ),
            ],
            // Clear All Button
            if (_parametricBands.isNotEmpty) ...[
              const SizedBox(width: 4),
              M3EIconButton(
                tooltip: 'Clear All Bands',
                icon: const Icon(Icons.delete_sweep_rounded,
                    size: 18, color: Colors.white70),
                variant: M3EIconButtonVariant.standard,
                onPressed: () {
                  setState(() {
                    _parametricBands.clear();
                    _parametricPreset = 'Custom';
                    _applyParametricBands();
                    _saveEqState();
                  });
                },
              ),
            ],*/
            const SizedBox(width: 6),
            // Add Band Button
            M3EIconButton(
              variant: M3EIconButtonVariant.tonal,
              tooltip: 'Add Band',
              icon:
                  const Icon(Icons.add_rounded, color: Colors.white, size: 18),
              onPressed: () {
                setState(() {
                  final nextFreq = _calculateNextBandFrequency();
                  _parametricBands.add(EqBandConfig(
                    type: EqBandType.peak,
                    frequencyHz: nextFreq,
                    gainDb: 0.0,
                    q: 1.4,
                    slope: 1.0,
                  ));
                  _parametricPreset = 'Custom';
                  _applyParametricBands();
                  _saveEqState();
                });
              },
            ),
          ],
        ),
        const SizedBox(height: 12),
        if (_parametricBands.isEmpty)
          Container(
            height: 120,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: surfaceDarkerColor.withValues(alpha: 0.5),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: Colors.white12),
            ),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(Icons.graphic_eq_rounded, color: Colors.white38, size: 28),
                const SizedBox(height: 8),
                const Text(
                  'No EQ Bands Active',
                  style: TextStyle(
                      color: Colors.white70,
                      fontSize: 13,
                      fontWeight: FontWeight.w600),
                ),
                const SizedBox(height: 4),
                Text(
                  'Choose a preset above or tap "Add Band"',
                  style: TextStyle(color: Colors.white38, fontSize: 12),
                ),
              ],
            ),
          )
        else
          SizedBox(
            height: 300,
            child: ListView.builder(
              scrollDirection: Axis.horizontal,
              physics: const BouncingScrollPhysics(),
              itemCount: _parametricBands.length,
              itemBuilder: (context, index) {
                final band = _parametricBands[index];
                return _buildParametricBandCard(index, band);
              },
            ),
          ),
      ],
    );
  }

  Widget _buildParametricBandCard(int index, EqBandConfig band) {
    return Container(
      width: 255,
      margin: const EdgeInsets.only(right: 14),
      child: M3ECard(
        variant: M3ECardVariant.filled,
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text('Band ${index + 1}',
                      style: const TextStyle(
                          color: Colors.white,
                          fontWeight: FontWeight.bold,
                          fontSize: 13.5)),
                  Row(
                    children: [
                      Text('${band.frequencyHz.toInt()}Hz',
                          style: TextStyle(
                              color: primaryColor,
                              fontFamily: 'monospace',
                              fontSize: 12,
                              fontWeight: FontWeight.bold)),
                      const SizedBox(width: 8),
                      M3EIconButton(
                        onPressed: () {
                          setState(() {
                            _parametricBands.removeAt(index);
                            _parametricPreset = 'Custom';
                            _applyParametricBands();
                            _saveEqState();
                          });
                        },
                        icon: const Icon(Icons.close_rounded, size: 16),
                        variant: M3EIconButtonVariant.standard,
                      ),
                    ],
                  ),
                ],
              ),
              const SizedBox(height: 8),
              // Type Selector
              DropdownButtonHideUnderline(
                child: DropdownButton<EqBandType>(
                  value: band.type,
                  isExpanded: true,
                  dropdownColor: surfaceDarkerColor,
                  icon: const Icon(Icons.arrow_drop_down_rounded,
                      color: Colors.white54),
                  style: const TextStyle(
                      color: Colors.white,
                      fontSize: 13,
                      fontWeight: FontWeight.w600),
                  items: EqBandType.values
                      .map((t) => DropdownMenuItem(
                            value: t,
                            child: Text(switch (t) {
                              EqBandType.peak => 'Peak EQ',
                              EqBandType.bandpass => 'Band-Pass',
                              EqBandType.notch => 'Notch',
                              EqBandType.lowshelf => 'Low Shelf',
                              EqBandType.highshelf => 'High Shelf',
                              EqBandType.lowpass => 'Low-Pass',
                              EqBandType.highpass => 'High-Pass',
                            }),
                          ))
                      .toList(),
                  onChanged: (v) {
                    if (v != null) {
                      setState(() {
                        _parametricBands[index] = EqBandConfig(
                          type: v,
                          frequencyHz: band.frequencyHz,
                          enabled: band.enabled,
                          q: band.q,
                          gainDb: band.gainDb,
                          slope: band.slope,
                        );
                        _parametricPreset = 'Custom';
                        _applyParametricBands();
                        _saveEqState();
                      });
                    }
                  },
                ),
              ),
              const SizedBox(height: 12),
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                children: [
                  // Frequency Knob
                  ModernAudioKnob(
                    size: 52,
                    label: 'FREQ',
                    value: band.frequencyHz.clamp(20.0, 20000.0),
                    min: 20.0,
                    max: 20000.0,
                    flatValue: 1000.0,
                    activeColor:
                        _parametricEqEnabled ? primaryColor : Colors.white,
                    valueFormatter: (v) => '${v.toInt()}Hz',
                    onChanged: (v) {
                      setState(() {
                        _parametricBands[index] = EqBandConfig(
                          type: band.type,
                          frequencyHz: v,
                          enabled: band.enabled,
                          q: band.q,
                          gainDb: band.gainDb,
                          slope: band.slope,
                        );
                        _parametricPreset = 'Custom';
                        _applyParametricBands();
                        _saveEqState();
                      });
                    },
                  ),

                  // Q Factor / Slope Knob
                  ModernAudioKnob(
                    size: 52,
                    label: band.type == EqBandType.lowshelf ||
                            band.type == EqBandType.highshelf
                        ? 'SLOPE'
                        : 'Q',
                    value: band.type == EqBandType.lowshelf ||
                            band.type == EqBandType.highshelf
                        ? band.slope
                        : band.q,
                    min: 0.1,
                    max: 18.0,
                    flatValue: 1.0,
                    activeColor:
                        _parametricEqEnabled ? primaryColor : Colors.white,
                    valueFormatter: (v) => v.toStringAsFixed(1),
                    onChanged: (v) {
                      setState(() {
                        if (band.type == EqBandType.lowshelf ||
                            band.type == EqBandType.highshelf) {
                          _parametricBands[index] = EqBandConfig(
                            type: band.type,
                            frequencyHz: band.frequencyHz,
                            enabled: band.enabled,
                            q: band.q,
                            gainDb: band.gainDb,
                            slope: v,
                          );
                        } else {
                          _parametricBands[index] = EqBandConfig(
                            type: band.type,
                            frequencyHz: band.frequencyHz,
                            enabled: band.enabled,
                            q: v,
                            gainDb: band.gainDb,
                            slope: band.slope,
                          );
                        }
                        _parametricPreset = 'Custom';
                        _applyParametricBands();
                        _saveEqState();
                      });
                    },
                  ),

                  // Gain Knob (for Peak, Low Shelf, High Shelf)
                  if (band.type == EqBandType.peak ||
                      band.type == EqBandType.lowshelf ||
                      band.type == EqBandType.highshelf)
                    ModernAudioKnob(
                      size: 52,
                      label: 'GAIN',
                      value: band.gainDb,
                      min: -24.0,
                      max: 24.0,
                      flatValue: 0.0,
                      activeColor:
                          _parametricEqEnabled ? primaryColor : Colors.white,
                      valueFormatter: (v) =>
                          '${v >= 0 ? '+' : ''}${v.toStringAsFixed(1)} dB',
                      onChanged: (v) {
                        setState(() {
                          _parametricBands[index] = EqBandConfig(
                            type: band.type,
                            frequencyHz: band.frequencyHz,
                            enabled: band.enabled,
                            q: band.q,
                            gainDb: v,
                            slope: band.slope,
                          );
                          _parametricPreset = 'Custom';
                          _applyParametricBands();
                          _saveEqState();
                        });
                      },
                    ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  static const List<
          ({int index, String name, String description, String bestFor})>
      _dynamicBassPresetDetails = [
    (
      index: 0,
      name: 'Natural',
      description: 'Natural bass',
      bestFor: 'Acoustic, Jazz'
    ),
    (
      index: 1,
      name: 'Punchy',
      description: 'Bass punch',
      bestFor: 'IEMs, Pop, EDM'
    ),
    (
      index: 2,
      name: 'Warm',
      description: 'Warmth in the lows',
      bestFor: 'Rock, R&B'
    ),
    (
      index: 3,
      name: 'Deep',
      description: 'Sub-harmonic',
      bestFor: 'Orchestral, Live'
    ),
    (
      index: 4,
      name: 'Wide',
      description: 'Broad low-end resonance',
      bestFor: 'Soundtracks, Ambient'
    ),
    (
      index: 5,
      name: 'Sub-Bass',
      description: 'Low-octave emphasis',
      bestFor: 'Hip-Hop, Trap, Dubstep'
    ),
    (
      index: 6,
      name: 'Tight',
      description: 'Fast impulse response ',
      bestFor: 'Techno, Electronic, Metal'
    ),
    (
      index: 7,
      name: 'Solid',
      description: 'Focused bass',
      bestFor: 'Rock, Funk, House'
    ),
    (
      index: 8,
      name: 'Kick',
      description: 'Snappy bass drum',
      bestFor: 'Drums, Pop/Rock'
    ),
    (
      index: 9,
      name: 'Rich',
      description: 'Harmonic',
      bestFor: 'Soul, Blues, Warm Vocals'
    ),
    (
      index: 10,
      name: 'Club',
      description: 'High-energy',
      bestFor: 'Dance, Club, EDM'
    ),
    (
      index: 11,
      name: 'Basshead',
      description: 'Maximum low-end',
      bestFor: 'Bassheads, Subwoofer Test'
    ),
    (
      index: 12,
      name: 'Resonant Rumble',
      description: 'Floor-shaking sub resonance',
      bestFor: 'Cinematic FX, Deep House'
    ),
    (
      index: 13,
      name: 'Cinema',
      description: 'Explosive theatrical impact',
      bestFor: 'Movies, Gaming, Atmos'
    ),
    (
      index: 14,
      name: 'Car Audio',
      description: 'Tuned to overcome car cabin road noise',
      bestFor: 'Car Bluetooth & Aux Audio'
    ),
    (
      index: 15,
      name: 'Audiophile',
      description: 'Linear phase',
      bestFor: 'Hi-Fi Audio, Lossless FLAC'
    ),
    (
      index: 16,
      name: 'Studio',
      description: 'Accurate monitor',
      bestFor: 'Critical Listening & Mixing'
    ),
    (
      index: 17,
      name: 'Deep',
      description: 'Ultra-low sub octaves ',
      bestFor: 'Organ, Synthesizer Sub'
    ),
    (
      index: 18,
      name: 'Ultimate',
      description: 'Maximum',
      bestFor: 'All-around Bass'
    ),
  ];

  String _getHarmonicBassProfileName(HarmonicBassProfile profile) {
    return switch (profile) {
      HarmonicBassProfile.dynamicMultiPole => 'Dynamic(19 Presets)',
      HarmonicBassProfile.naturalBass => 'Natural',
      HarmonicBassProfile.pureBass => 'Punchy Kick',
      HarmonicBassProfile.subwoofer => 'Subwoofer',
      HarmonicBassProfile.harmonicExciter => 'Harmonic Exciter',
      HarmonicBassProfile.pultecDeep => 'Pultec Deep',
    };
  }

  String _getDynamicBassPresetName(int preset) {
    if (preset >= 0 && preset < DynamicBassPreset.values.length) {
      return DynamicBassPreset.values[preset].label;
    }
    return 'Ultimate ';
  }

  String _getTransducerProfileName(TransducerProfile profile) {
    return profile.label.isNotEmpty ? profile.label : profile.name;
  }

  String _getClarityProfileName(AudioClarityProfile profile) {
    return switch (profile) {
      AudioClarityProfile.transientCrisp => 'Crisp',
      AudioClarityProfile.airShelf => 'Air',
      AudioClarityProfile.presenceExciter => 'Vocal',
      AudioClarityProfile.harmonicBrilliance => 'Brilliance',
    };
  }

  String _getDialogEnhancerProfileName(DialogEnhancerProfile profile) {
    return switch (profile) {
      DialogEnhancerProfile.cinema => 'Cinema',
      DialogEnhancerProfile.music => 'Music',
      DialogEnhancerProfile.voice => 'Voice',
      DialogEnhancerProfile.night => 'Night',
      DialogEnhancerProfile.custom => 'Custom',
    };
  }

  String _getAnalogWarmthProfileName(AnalogWarmthProfile profile) {
    return switch (profile) {
      AnalogWarmthProfile.triode12AX7 => 'Vacuum Tube',
      AnalogWarmthProfile.magneticTape => 'Magnetic Tape',
      AnalogWarmthProfile.vintagePreamp => 'Console Preamp',
    };
  }

  Widget _buildHarmonicBassSection() {
    final currentPresetDetail = _dynamicBassPresetDetails.firstWhere(
      (p) => p.index == _bassPreset,
      orElse: () => _dynamicBassPresetDetails.last,
    );

    return _CollapsibleSection(
      icon: Center(
        child: Icon(Icons.speaker_group_rounded, color: primaryColor, size: 20),
      ),
      title: 'Dynamic Bass',
      subtitle: '4-pole cascaded ladder resonance',
      isEnabled: _bassEnabled,
      onToggle: (v) {
        setState(() => _bassEnabled = v);
        _updateHarmonicBass();
        _saveEqState();
      },
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text(
              'Bass Profile',
              style: TextStyle(
                color: Colors.white.withValues(alpha: 0.85),
                fontSize: 13.5,
                fontWeight: FontWeight.w600,
              ),
            ),
            DropdownButtonHideUnderline(
              child: DropdownButton<HarmonicBassProfile>(
                value: _bassProfile,
                dropdownColor: surfaceDarkerColor,
                icon: Icon(Icons.arrow_drop_down_rounded, color: primaryColor),
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                ),
                items: const [
                  DropdownMenuItem(
                    value: HarmonicBassProfile.dynamicMultiPole,
                    child: Text('Dynamic(19 Presets)'),
                  ),
                  DropdownMenuItem(
                    value: HarmonicBassProfile.naturalBass,
                    child: Text('Natural'),
                  ),
                  DropdownMenuItem(
                    value: HarmonicBassProfile.pureBass,
                    child: Text('Pure'),
                  ),
                  DropdownMenuItem(
                    value: HarmonicBassProfile.subwoofer,
                    child: Text('Aggressive'),
                  ),
                  DropdownMenuItem(
                    value: HarmonicBassProfile.harmonicExciter,
                    child: Text('Harmonic'),
                  ),
                  DropdownMenuItem(
                    value: HarmonicBassProfile.pultecDeep,
                    child: Text('Pultec'),
                  ),
                ],
                onChanged: (val) {
                  if (val != null) {
                    setState(() => _bassProfile = val);
                    if (_bassEnabled) _updateHarmonicBass();
                    _saveEqState();
                  }
                },
              ),
            ),
          ],
        ),
        const SizedBox(height: 10),
        RepaintBoundary(
          child: DynamicBassGraph(
            profile: _bassProfile,
            preset: _bassPreset,
            cutoffHz: _bassCutoffHz,
            gainDb: _bassGainDb,
            boost: _bassBoost,
            isEnabled: _bassEnabled,
            height: 125.0,
            primaryColor: primaryColor,
          ),
        ),
        if (_bassProfile == HarmonicBassProfile.dynamicMultiPole) ...[
          const SizedBox(height: 12),
          // 19 Preset Selection Dropdown
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 4),
            decoration: BoxDecoration(
              color: surfaceDarkerColor,
              borderRadius: BorderRadius.circular(14),
              border: Border.all(color: primaryColor.withValues(alpha: 0.3)),
            ),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Row(
                  children: [
                    Icon(Icons.tune_rounded, size: 18, color: primaryColor),
                    const SizedBox(width: 8),
                    Text(
                      'Preset',
                      style: TextStyle(
                        color: Colors.white.withValues(alpha: 0.9),
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ],
                ),
                DropdownButtonHideUnderline(
                  child: DropdownButton<int>(
                    value: _bassPreset,
                    dropdownColor: surfaceDarkerColor,
                    icon: Icon(Icons.arrow_drop_down_rounded,
                        color: primaryColor),
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                    ),
                    items: DynamicBassPreset.values
                        .map((preset) => DropdownMenuItem<int>(
                              value: preset.value,
                              child: Text(
                                '${preset.value + 1}. ${preset.label}',
                                style: TextStyle(
                                  color: _bassPreset == preset.value
                                      ? primaryColor
                                      : Colors.white,
                                  fontWeight: _bassPreset == preset.value
                                      ? FontWeight.bold
                                      : FontWeight.normal,
                                ),
                              ),
                            ))
                        .toList(),
                    onChanged: (val) {
                      if (val != null) {
                        setState(() => _bassPreset = val);
                        if (_bassEnabled) _updateHarmonicBass();
                        _saveEqState();
                      }
                    },
                  ),
                ),
              ],
            ),
          ),

          const SizedBox(height: 10),

          // Preset Information & Best For Card
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: primaryColor.withValues(alpha: 0.08),
              borderRadius: BorderRadius.circular(14),
              border: Border.all(color: primaryColor.withValues(alpha: 0.2)),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 8, vertical: 2),
                      decoration: BoxDecoration(
                        color: primaryColor.withValues(alpha: 0.25),
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: Text(
                        '${_bassPreset + 1}',
                        style: TextStyle(
                          color: primaryColor,
                          fontSize: 10.5,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        currentPresetDetail.name,
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 13,
                          fontWeight: FontWeight.bold,
                        ),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 6),
                Text(
                  currentPresetDetail.description,
                  style: TextStyle(
                    color: Colors.white.withValues(alpha: 0.75),
                    fontSize: 11.5,
                    height: 1.3,
                  ),
                ),
                const SizedBox(height: 6),
                Row(
                  children: [
                    Icon(Icons.headphones_rounded,
                        size: 13, color: primaryColor.withValues(alpha: 0.8)),
                    const SizedBox(width: 4),
                    Expanded(
                      child: Text(
                        'Best for: ${currentPresetDetail.bestFor}',
                        style: TextStyle(
                          color: primaryColor.withValues(alpha: 0.9),
                          fontSize: 11,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),

          const SizedBox(height: 12),

          // Fast Preset Selector Chips (Popular choices)
          SizedBox(
            height: 34,
            child: ListView(
              scrollDirection: Axis.horizontal,
              physics: const BouncingScrollPhysics(),
              children: [
                for (final p in [18, 0, 1, 6, 10, 13, 14, 15]) ...[
                  Padding(
                    padding: const EdgeInsets.only(right: 6),
                    child: ChoiceChip(
                      label: Text(
                        DynamicBassPreset.values[p].label,
                        style: TextStyle(
                          fontSize: 11,
                          fontWeight: _bassPreset == p
                              ? FontWeight.bold
                              : FontWeight.normal,
                        ),
                      ),
                      selected: _bassPreset == p,
                      selectedColor: primaryColor.withValues(alpha: 0.3),
                      onSelected: (selected) {
                        if (selected) {
                          setState(() => _bassPreset = p);
                          if (_bassEnabled) _updateHarmonicBass();
                          _saveEqState();
                        }
                      },
                    ),
                  ),
                ],
              ],
            ),
          ),

          const SizedBox(height: 16),

          // Dynamic Bass Knobs Row
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceEvenly,
            children: [
              ModernAudioKnob(
                label: 'BASS GAIN',
                value: _bassGainDb,
                min: 0.0,
                max: 24.0,
                flatValue: 15.0,
                activeColor: _bassEnabled ? primaryColor : Colors.white,
                valueFormatter: (v) => '+${v.toStringAsFixed(1)} dB',
                onChanged: (v) {
                  setState(() => _bassGainDb = v);
                  if (_bassEnabled) _updateHarmonicBass();
                  _saveEqState();
                },
              ),
              ModernAudioKnob(
                label: 'FOCUS FREQ',
                value: _bassCutoffHz,
                min: 30.0,
                max: 160.0,
                flatValue: 60.0,
                activeColor: _bassEnabled ? primaryColor : Colors.white,
                valueFormatter: (v) => '${v.toInt()} Hz',
                onChanged: (v) {
                  setState(() => _bassCutoffHz = v);
                  if (_bassEnabled) _updateHarmonicBass();
                  _saveEqState();
                },
              ),
              ModernAudioKnob(
                label: 'RESONANCE',
                value: _bassBoost,
                min: 0.0,
                max: 1.0,
                flatValue: 0.5,
                activeColor: _bassEnabled ? primaryColor : Colors.white,
                isPercentage: true,
                valueFormatter: (v) => '${(v * 100).toInt()}%',
                onChanged: (v) {
                  setState(() => _bassBoost = v);
                  if (_bassEnabled) _updateHarmonicBass();
                  _saveEqState();
                },
              ),
            ],
          ),
        ] else ...[
          const SizedBox(height: 16),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceEvenly,
            children: [
              ModernAudioKnob(
                label: 'FOCUS FREQ',
                value: _bassCutoffHz,
                min: 30.0,
                max: 160.0,
                flatValue: 60.0,
                activeColor: _bassEnabled ? primaryColor : Colors.white,
                valueFormatter: (v) => '${v.toInt()} Hz',
                onChanged: (v) {
                  setState(() => _bassCutoffHz = v);
                  if (_bassEnabled) _updateHarmonicBass();
                  _saveEqState();
                },
              ),
              ModernAudioKnob(
                label: 'BASS POWER',
                value: _bassBoost,
                min: 0.0,
                max: 1.0,
                flatValue: 0.5,
                activeColor: _bassEnabled ? primaryColor : Colors.white,
                isPercentage: true,
                valueFormatter: (v) => '${(v * 100).toInt()}%',
                onChanged: (v) {
                  setState(() => _bassBoost = v);
                  if (_bassEnabled) _updateHarmonicBass();
                  _saveEqState();
                },
              ),
            ],
          ),
        ],
      ],
    );
  }

  Widget _buildDynamicSystemSection() {
    return _CollapsibleSection(
      icon: Center(
        child: Icon(Icons.headphones_rounded, color: primaryColor, size: 20),
      ),
      title: 'Dynamic System',
      subtitle: 'Multi-Band Acoustic Simulation',
      isEnabled: _dynamicSystemEnabled,
      onToggle: (v) {
        setState(() => _dynamicSystemEnabled = v);
        _updateDynamicSystem();
        _saveEqState();
      },
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text(
              'Profile',
              style: TextStyle(
                color: Colors.white.withValues(alpha: 0.85),
                fontSize: 13.5,
                fontWeight: FontWeight.w600,
              ),
            ),
            DropdownButtonHideUnderline(
              child: DropdownButton<TransducerProfile>(
                value: _dynamicSystemProfile,
                dropdownColor: surfaceDarkerColor,
                icon: Icon(Icons.arrow_drop_down_rounded, color: primaryColor),
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                ),
                items: TransducerProfile.values.map((profile) {
                  return DropdownMenuItem<TransducerProfile>(
                    value: profile,
                    child: Text(
                      profile.label.isNotEmpty ? profile.label : profile.name,
                      overflow: TextOverflow.ellipsis,
                    ),
                  );
                }).toList(),
                onChanged: (val) {
                  if (val != null) {
                    setState(() => _dynamicSystemProfile = val);
                    if (_dynamicSystemEnabled) _updateDynamicSystem();
                    _saveEqState();
                  }
                },
              ),
            ),
          ],
        ),
        const SizedBox(height: 10),
        RepaintBoundary(
          child: DynamicSystemGraph(
            profile: _dynamicSystemProfile,
            strength: _dynamicSystemStrength,
            isEnabled: _dynamicSystemEnabled,
            height: 120.0,
            primaryColor: primaryColor,
          ),
        ),
        const SizedBox(height: 14),
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceEvenly,
          children: [
            ModernAudioKnob(
              label: 'DYNAMIC DRIVE',
              value: _dynamicSystemStrength,
              min: 0.0,
              max: 1.0,
              flatValue: 0.5,
              activeColor: _dynamicSystemEnabled ? primaryColor : Colors.white,
              isPercentage: true,
              valueFormatter: (v) => '${(v * 100).toInt()}%',
              onChanged: (v) {
                setState(() => _dynamicSystemStrength = v);
                if (_dynamicSystemEnabled) _updateDynamicSystem();
                _saveEqState();
              },
            ),
          ],
        ),
      ],
    );
  }

  Widget _buildClaritySection() {
    return _CollapsibleSection(
      icon: Center(
        child: Icon(Icons.graphic_eq_rounded, color: primaryColor, size: 20),
      ),
      title: 'Clarity',
      subtitle: 'Crisp details, vocal presence',
      isEnabled: _clarityEnabled,
      onToggle: (v) {
        setState(() => _clarityEnabled = v);
        _updateClarity();
        _saveEqState();
      },
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text(
              'Profile',
              style: TextStyle(
                color: Colors.white.withValues(alpha: 0.85),
                fontSize: 13.5,
                fontWeight: FontWeight.w600,
              ),
            ),
            DropdownButtonHideUnderline(
              child: DropdownButton<AudioClarityProfile>(
                value: _clarityProfile,
                dropdownColor: surfaceDarkerColor,
                icon: Icon(Icons.arrow_drop_down_rounded, color: primaryColor),
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                ),
                items: const [
                  DropdownMenuItem(
                    value: AudioClarityProfile.transientCrisp,
                    child: Text('Crisp'),
                  ),
                  DropdownMenuItem(
                    value: AudioClarityProfile.airShelf,
                    child: Text('Air'),
                  ),
                  DropdownMenuItem(
                    value: AudioClarityProfile.presenceExciter,
                    child: Text('Vocal'),
                  ),
                  DropdownMenuItem(
                    value: AudioClarityProfile.harmonicBrilliance,
                    child: Text('Harmonic'),
                  ),
                ],
                onChanged: (val) {
                  if (val != null) {
                    setState(() => _clarityProfile = val);
                    if (_clarityEnabled) _updateClarity();
                    _saveEqState();
                  }
                },
              ),
            ),
          ],
        ),
        const SizedBox(height: 10),
        RepaintBoundary(
          child: ClarityGraph(
            profile: _clarityProfile,
            intensity: _clarityIntensity,
            isEnabled: _clarityEnabled,
            height: 125.0,
            primaryColor: primaryColor,
          ),
        ),
        const SizedBox(height: 16),
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceEvenly,
          children: [
            ModernAudioKnob(
              label: 'CLARITY',
              value: _clarityIntensity,
              min: 0.0,
              max: 1.0,
              flatValue: 0.5,
              activeColor: _clarityEnabled ? primaryColor : Colors.white,
              isPercentage: true,
              valueFormatter: (v) => '${(v * 100).toInt()}%',
              onChanged: (v) {
                setState(() => _clarityIntensity = v);
                if (_clarityEnabled) _updateClarity();
                _saveEqState();
              },
            ),
          ],
        ),
      ],
    );
  }

  Widget _buildDialogEnhancerSection() {
    final dialogColor = context.primaryColor;
    return _CollapsibleSection(
      icon: Center(
        child:
            Icon(Icons.record_voice_over_rounded, color: dialogColor, size: 20),
      ),
      title: 'Dialogues',
      subtitle: 'Speech intelligibility enhancement',
      isEnabled: _dialogEnhancerEnabled,
      onToggle: (v) {
        setState(() => _dialogEnhancerEnabled = v);
        _updateDialogEnhancer();
        _saveEqState();
      },
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text(
              'Profile',
              style: TextStyle(
                color: Colors.white.withValues(alpha: 0.85),
                fontSize: 13.5,
                fontWeight: FontWeight.w600,
              ),
            ),
            DropdownButtonHideUnderline(
              child: DropdownButton<DialogEnhancerProfile>(
                value: _dialogEnhancerProfile,
                dropdownColor: surfaceDarkerColor,
                icon: Icon(Icons.arrow_drop_down_rounded, color: dialogColor),
                style: TextStyle(
                  color: Colors.white,
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                ),
                items: DialogEnhancerProfile.values.map((profile) {
                  return DropdownMenuItem<DialogEnhancerProfile>(
                    value: profile,
                    child: Text(
                      profile.label.isNotEmpty ? profile.label : profile.name,
                      overflow: TextOverflow.ellipsis,
                    ),
                  );
                }).toList(),
                onChanged: (val) {
                  if (val != null) {
                    setState(() {
                      _dialogEnhancerProfile = val;
                      switch (val) {
                        case DialogEnhancerProfile.cinema:
                          _dialogEnhancerAmount = 0.70;
                          _dialogEnhancerDucking = 0.65;
                          _dialogEnhancerClarity = 0.60;
                          _dialogEnhancerCenterFocus = 0.75;
                          break;
                        case DialogEnhancerProfile.music:
                          _dialogEnhancerAmount = 0.45;
                          _dialogEnhancerDucking = 0.35;
                          _dialogEnhancerClarity = 0.50;
                          _dialogEnhancerCenterFocus = 0.40;
                          break;
                        case DialogEnhancerProfile.voice:
                          _dialogEnhancerAmount = 0.85;
                          _dialogEnhancerDucking = 0.75;
                          _dialogEnhancerClarity = 0.75;
                          _dialogEnhancerCenterFocus = 0.85;
                          break;
                        case DialogEnhancerProfile.night:
                          _dialogEnhancerAmount = 0.80;
                          _dialogEnhancerDucking = 0.85;
                          _dialogEnhancerClarity = 0.55;
                          _dialogEnhancerCenterFocus = 0.90;
                          break;
                        case DialogEnhancerProfile.custom:
                          break;
                      }
                    });
                    if (_dialogEnhancerEnabled) _updateDialogEnhancer();
                    _saveEqState();
                  }
                },
              ),
            ),
          ],
        ),
        const SizedBox(height: 16),
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceEvenly,
          children: [
            ModernAudioKnob(
              label: 'VOCAL BOOST',
              value: _dialogEnhancerAmount,
              min: 0.0,
              max: 1.0,
              flatValue: 0.0,
              activeColor: _dialogEnhancerEnabled ? dialogColor : Colors.white,
              isPercentage: true,
              valueFormatter: (v) => '+${(v * 11.0).toStringAsFixed(1)} dB',
              onChanged: (v) {
                setState(() {
                  _dialogEnhancerAmount = v;
                  _dialogEnhancerProfile = DialogEnhancerProfile.custom;
                });
                if (_dialogEnhancerEnabled) _updateDialogEnhancer();
                _saveEqState();
              },
            ),
            ModernAudioKnob(
              label: 'DUCKING',
              value: _dialogEnhancerDucking,
              min: 0.0,
              max: 1.0,
              flatValue: 0.0,
              activeColor: _dialogEnhancerEnabled ? dialogColor : Colors.white,
              isPercentage: true,
              valueFormatter: (v) => '${(v * 100).toInt()}%',
              onChanged: (v) {
                setState(() {
                  _dialogEnhancerDucking = v;
                  _dialogEnhancerProfile = DialogEnhancerProfile.custom;
                });
                if (_dialogEnhancerEnabled) _updateDialogEnhancer();
                _saveEqState();
              },
            ),
          ],
        ),
        const SizedBox(height: 16),
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceEvenly,
          children: [
            ModernAudioKnob(
              label: 'CLARITY',
              value: _dialogEnhancerClarity,
              min: 0.0,
              max: 1.0,
              flatValue: 0.0,
              activeColor: _dialogEnhancerEnabled ? dialogColor : Colors.white,
              isPercentage: true,
              valueFormatter: (v) => '+${(v * 6.0).toStringAsFixed(1)} dB',
              onChanged: (v) {
                setState(() {
                  _dialogEnhancerClarity = v;
                  _dialogEnhancerProfile = DialogEnhancerProfile.custom;
                });
                if (_dialogEnhancerEnabled) _updateDialogEnhancer();
                _saveEqState();
              },
            ),
            ModernAudioKnob(
              label: 'CENTER FOCUS',
              value: _dialogEnhancerCenterFocus,
              min: 0.0,
              max: 1.0,
              flatValue: 0.0,
              activeColor: _dialogEnhancerEnabled ? dialogColor : Colors.white,
              isPercentage: true,
              valueFormatter: (v) => '${(v * 100).toInt()}%',
              onChanged: (v) {
                setState(() {
                  _dialogEnhancerCenterFocus = v;
                  _dialogEnhancerProfile = DialogEnhancerProfile.custom;
                });
                if (_dialogEnhancerEnabled) _updateDialogEnhancer();
                _saveEqState();
              },
            ),
          ],
        ),
      ],
    );
  }

  Widget _buildDownwardExpanderSection() {
    const expanderColor = Color(0xFF26A69A);
    return _CollapsibleSection(
      icon: Center(
        child: Icon(Icons.cleaning_services_rounded,
            color: expanderColor, size: 20),
      ),
      title: 'Downward Expander',
      subtitle: 'Reduces noise floor smoothly',
      isEnabled: _expanderEnabled,
      onToggle: (v) {
        setState(() => _expanderEnabled = v);
        _updateDownwardExpander();
        _saveEqState();
      },
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text(
              'Profile',
              style: TextStyle(
                color: Colors.white.withValues(alpha: 0.85),
                fontSize: 13.5,
                fontWeight: FontWeight.w600,
              ),
            ),
            DropdownButtonHideUnderline(
              child: DropdownButton<DownwardExpanderPreset>(
                value: _expanderPreset,
                dropdownColor: surfaceDarkerColor,
                icon: Icon(Icons.arrow_drop_down_rounded, color: expanderColor),
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                ),
                items: const [
                  DropdownMenuItem(
                    value: DownwardExpanderPreset.vinylClean,
                    child: Text('Vinyl'),
                  ),
                  DropdownMenuItem(
                    value: DownwardExpanderPreset.tapeHiss,
                    child: Text('Tape'),
                  ),
                  DropdownMenuItem(
                    value: DownwardExpanderPreset.gentleExpansion,
                    child: Text('Gentle'),
                  ),
                  DropdownMenuItem(
                    value: DownwardExpanderPreset.dynamicGate,
                    child: Text('Dynamic'),
                  ),
                  DropdownMenuItem(
                    value: DownwardExpanderPreset.custom,
                    child: Text('Custom'),
                  ),
                ],
                onChanged: (val) {
                  if (val != null) {
                    _applyExpanderPreset(val);
                  }
                },
              ),
            ),
          ],
        ),
        const SizedBox(height: 16),
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceEvenly,
          children: [
            ModernAudioKnob(
              label: 'THRESHOLD',
              value: _expanderThresholdDb,
              min: -80.0,
              max: -10.0,
              flatValue: -52.0,
              activeColor: _expanderEnabled ? expanderColor : Colors.white,
              valueFormatter: (v) => '${v.toInt()} dB',
              onChanged: (v) {
                setState(() {
                  _expanderThresholdDb = v;
                  _expanderPreset = DownwardExpanderPreset.custom;
                });
                if (_expanderEnabled) _updateDownwardExpander();
                _saveEqState();
              },
            ),
            ModernAudioKnob(
              label: 'EXP RATIO',
              value: _expanderRatio,
              min: 1.0,
              max: 8.0,
              flatValue: 1.8,
              activeColor: _expanderEnabled ? expanderColor : Colors.white,
              valueFormatter: (v) => '${v.toStringAsFixed(1)}:1',
              onChanged: (v) {
                setState(() {
                  _expanderRatio = v;
                  _expanderPreset = DownwardExpanderPreset.custom;
                });
                if (_expanderEnabled) _updateDownwardExpander();
                _saveEqState();
              },
            ),
            ModernAudioKnob(
              label: 'MAX FLOOR',
              value: _expanderRangeDb,
              min: -40.0,
              max: -6.0,
              flatValue: -16.0,
              activeColor: _expanderEnabled ? expanderColor : Colors.white,
              valueFormatter: (v) => '${v.toInt()} dB',
              onChanged: (v) {
                setState(() {
                  _expanderRangeDb = v;
                  _expanderPreset = DownwardExpanderPreset.custom;
                });
                if (_expanderEnabled) _updateDownwardExpander();
                _saveEqState();
              },
            ),
          ],
        ),
        const SizedBox(height: 16),
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceEvenly,
          children: [
            ModernAudioKnob(
              label: 'ATTACK',
              value: _expanderAttackMs,
              min: 1.0,
              max: 50.0,
              flatValue: 12.0,
              activeColor: _expanderEnabled ? expanderColor : Colors.white,
              valueFormatter: (v) => '${v.toInt()} ms',
              onChanged: (v) {
                setState(() {
                  _expanderAttackMs = v;
                  _expanderPreset = DownwardExpanderPreset.custom;
                });
                if (_expanderEnabled) _updateDownwardExpander();
                _saveEqState();
              },
            ),
            ModernAudioKnob(
              label: 'RELEASE',
              value: _expanderReleaseMs,
              min: 20.0,
              max: 800.0,
              flatValue: 280.0,
              activeColor: _expanderEnabled ? expanderColor : Colors.white,
              valueFormatter: (v) => '${v.toInt()} ms',
              onChanged: (v) {
                setState(() {
                  _expanderReleaseMs = v;
                  _expanderPreset = DownwardExpanderPreset.custom;
                });
                if (_expanderEnabled) _updateDownwardExpander();
                _saveEqState();
              },
            ),
            ModernAudioKnob(
              label: 'RUMBLE HPF',
              value: _expanderHpfCutoffHz,
              min: 0.0,
              max: 100.0,
              flatValue: 50.0,
              activeColor: _expanderEnabled ? expanderColor : Colors.white,
              valueFormatter: (v) => v < 15.0 ? 'OFF' : '${v.toInt()} Hz',
              onChanged: (v) {
                setState(() {
                  _expanderHpfCutoffHz = v;
                  _expanderPreset = DownwardExpanderPreset.custom;
                });
                if (_expanderEnabled) _updateDownwardExpander();
                _saveEqState();
              },
            ),
          ],
        ),
      ],
    );
  }

  Widget _buildDeEsserSection() {
    final deEsserColor = context.primaryColor;
    return _CollapsibleSection(
      icon: Center(
        child: Icon(Icons.record_voice_over_rounded,
            color: deEsserColor, size: 20),
      ),
      title: 'De-Esser',
      subtitle: 'Attenuates harsh vocal sibilance',
      isEnabled: _deEsserEnabled,
      onToggle: (v) {
        setState(() => _deEsserEnabled = v);
        _updateDeEsser();
        _saveEqState();
      },
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text(
              'Profile',
              style: TextStyle(
                color: Colors.white.withValues(alpha: 0.85),
                fontSize: 13.5,
                fontWeight: FontWeight.w600,
              ),
            ),
            DropdownButtonHideUnderline(
              child: DropdownButton<DeEsserPreset>(
                value: _deEsserPreset,
                dropdownColor: surfaceDarkerColor,
                icon: Icon(Icons.arrow_drop_down_rounded, color: deEsserColor),
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                ),
                items: const [
                  DropdownMenuItem(
                    value: DeEsserPreset.gentleVocal,
                    child: Text('Gentle Vocal'),
                  ),
                  DropdownMenuItem(
                    value: DeEsserPreset.aggressiveSibilance,
                    child: Text('Aggressive'),
                  ),
                  DropdownMenuItem(
                    value: DeEsserPreset.vintageWideband,
                    child: Text('Vintage Wideband'),
                  ),
                  DropdownMenuItem(
                    value: DeEsserPreset.podcastSpeech,
                    child: Text('Podcast / Speech'),
                  ),
                  DropdownMenuItem(
                    value: DeEsserPreset.custom,
                    child: Text('Custom'),
                  ),
                ],
                onChanged: (val) {
                  if (val != null) {
                    _applyDeEsserPreset(val);
                  }
                },
              ),
            ),
          ],
        ),
        const SizedBox(height: 8),
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text(
              'Mode',
              style: TextStyle(
                color: Colors.white.withValues(alpha: 0.85),
                fontSize: 13.5,
                fontWeight: FontWeight.w600,
              ),
            ),
            SegmentedButton<DeEsserMode>(
              segments: const [
                ButtonSegment(
                  value: DeEsserMode.splitBand,
                  label: Text('Split-Band', style: TextStyle(fontSize: 12)),
                  icon: Icon(Icons.call_split_rounded, size: 16),
                ),
                ButtonSegment(
                  value: DeEsserMode.wideBand,
                  label: Text('Wideband', style: TextStyle(fontSize: 12)),
                  icon: Icon(Icons.compress_rounded, size: 16),
                ),
              ],
              selected: {_deEsserMode},
              onSelectionChanged: (modes) {
                if (modes.isNotEmpty) {
                  setState(() {
                    _deEsserMode = modes.first;
                    _deEsserPreset = DeEsserPreset.custom;
                  });
                  if (_deEsserEnabled) _updateDeEsser();
                  _saveEqState();
                }
              },
              style: ButtonStyle(
                visualDensity: VisualDensity.compact,
                padding: WidgetStateProperty.all(
                  const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 10),
        RepaintBoundary(
          child: DeEsserGraph(
            mode: _deEsserMode,
            frequencyHz: _deEsserFrequencyHz,
            thresholdDb: _deEsserThresholdDb,
            ratio: _deEsserRatio,
            maxReductionDb: _deEsserMaxReductionDb,
            gainReductionDb: _deEsserGainReductionDb,
            isEnabled: _deEsserEnabled,
            height: 130.0,
            primaryColor: deEsserColor,
          ),
        ),
        const SizedBox(height: 16),
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceEvenly,
          children: [
            ModernAudioKnob(
              label: 'FREQUENCY',
              value: _deEsserFrequencyHz,
              min: 2000.0,
              max: 12000.0,
              flatValue: 5500.0,
              activeColor: _deEsserEnabled ? deEsserColor : Colors.white,
              valueFormatter: (v) => v >= 1000.0
                  ? '${(v / 1000.0).toStringAsFixed(1)} kHz'
                  : '${v.toInt()} Hz',
              onChanged: (v) {
                setState(() {
                  _deEsserFrequencyHz = v;
                  _deEsserPreset = DeEsserPreset.custom;
                });
                if (_deEsserEnabled) _updateDeEsser();
                _saveEqState();
              },
            ),
            ModernAudioKnob(
              label: 'THRESHOLD',
              value: _deEsserThresholdDb,
              min: -60.0,
              max: 0.0,
              flatValue: -22.0,
              activeColor: _deEsserEnabled ? deEsserColor : Colors.white,
              valueFormatter: (v) => '${v.toInt()} dB',
              onChanged: (v) {
                setState(() {
                  _deEsserThresholdDb = v;
                  _deEsserPreset = DeEsserPreset.custom;
                });
                if (_deEsserEnabled) _updateDeEsser();
                _saveEqState();
              },
            ),
            ModernAudioKnob(
              label: 'RATIO',
              value: _deEsserRatio,
              min: 1.0,
              max: 10.0,
              flatValue: 4.0,
              activeColor: _deEsserEnabled ? deEsserColor : Colors.white,
              valueFormatter: (v) => '${v.toStringAsFixed(1)}:1',
              onChanged: (v) {
                setState(() {
                  _deEsserRatio = v;
                  _deEsserPreset = DeEsserPreset.custom;
                });
                if (_deEsserEnabled) _updateDeEsser();
                _saveEqState();
              },
            ),
          ],
        ),
        const SizedBox(height: 16),
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceEvenly,
          children: [
            ModernAudioKnob(
              label: 'MAX REDUCTION',
              value: _deEsserMaxReductionDb,
              min: 2.0,
              max: 24.0,
              flatValue: 12.0,
              activeColor: _deEsserEnabled ? deEsserColor : Colors.white,
              valueFormatter: (v) => '-${v.toInt()} dB',
              onChanged: (v) {
                setState(() {
                  _deEsserMaxReductionDb = v;
                  _deEsserPreset = DeEsserPreset.custom;
                });
                if (_deEsserEnabled) _updateDeEsser();
                _saveEqState();
              },
            ),
            ModernAudioKnob(
              label: 'ATTACK',
              value: _deEsserAttackMs,
              min: 0.1,
              max: 20.0,
              flatValue: 1.0,
              activeColor: _deEsserEnabled ? deEsserColor : Colors.white,
              valueFormatter: (v) => '${v.toStringAsFixed(1)} ms',
              onChanged: (v) {
                setState(() {
                  _deEsserAttackMs = v;
                  _deEsserPreset = DeEsserPreset.custom;
                });
                if (_deEsserEnabled) _updateDeEsser();
                _saveEqState();
              },
            ),
            ModernAudioKnob(
              label: 'RELEASE',
              value: _deEsserReleaseMs,
              min: 5.0,
              max: 200.0,
              flatValue: 35.0,
              activeColor: _deEsserEnabled ? deEsserColor : Colors.white,
              valueFormatter: (v) => '${v.toInt()} ms',
              onChanged: (v) {
                setState(() {
                  _deEsserReleaseMs = v;
                  _deEsserPreset = DeEsserPreset.custom;
                });
                if (_deEsserEnabled) _updateDeEsser();
                _saveEqState();
              },
            ),
          ],
        ),
      ],
    );
  }

  Widget _buildAnalogWarmthSection() {
    return _CollapsibleSection(
      icon: Center(
        child: Icon(Icons.album_rounded, color: primaryColor, size: 20),
      ),
      title: 'Analog Warmth',
      subtitle: 'Adds analog harmonics',
      isEnabled: _analogWarmthEnabled,
      onToggle: (v) {
        setState(() => _analogWarmthEnabled = v);
        _updateAnalogWarmth();
        _saveEqState();
      },
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text(
              'Presets',
              style: TextStyle(
                color: Colors.white.withValues(alpha: 0.85),
                fontSize: 13.5,
                fontWeight: FontWeight.w600,
              ),
            ),
            DropdownButtonHideUnderline(
              child: DropdownButton<AnalogWarmthProfile>(
                value: _analogWarmthProfile,
                dropdownColor: surfaceDarkerColor,
                icon: Icon(Icons.arrow_drop_down_rounded, color: primaryColor),
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                ),
                items: const [
                  DropdownMenuItem(
                    value: AnalogWarmthProfile.triode12AX7,
                    child: Text('Vacuum Tube'),
                  ),
                  DropdownMenuItem(
                    value: AnalogWarmthProfile.magneticTape,
                    child: Text('Vintage Tape'),
                  ),
                  DropdownMenuItem(
                    value: AnalogWarmthProfile.vintagePreamp,
                    child: Text('Console Preamp'),
                  ),
                ],
                onChanged: (val) {
                  if (val != null) {
                    setState(() => _analogWarmthProfile = val);
                    if (_analogWarmthEnabled) _updateAnalogWarmth();
                    _saveEqState();
                  }
                },
              ),
            ),
          ],
        ),
        const SizedBox(height: 16),
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceEvenly,
          children: [
            ModernAudioKnob(
              label: 'WARMTH DRIVE',
              value: _analogWarmthDrive,
              min: 0.0,
              max: 1.0,
              flatValue: 0.5,
              activeColor: _analogWarmthEnabled ? primaryColor : Colors.white,
              isPercentage: true,
              valueFormatter: (v) => '${(v * 100).toInt()}%',
              onChanged: (v) {
                setState(() => _analogWarmthDrive = v);
                if (_analogWarmthEnabled) _updateAnalogWarmth();
                _saveEqState();
              },
            ),
          ],
        ),
      ],
    );
  }

  Widget _buildConvolverSection() {
    return _CollapsibleSection(
      icon: Center(
        child: Icon(Icons.waves_rounded, color: primaryColor, size: 20),
      ),
      title: 'Acoustic Space & Convolver',
      subtitle: 'Simulate playing inside real halls, spaces',
      isEnabled: _convolverEnabled,
      onToggle: (v) {
        setState(() => _convolverEnabled = v);
        _updateConvolver();
        _saveEqState();
      },
      children: [
        Text(
          'HRIR Presets',
          style: const TextStyle(
            color: Colors.white54,
            fontSize: 11,
            fontWeight: FontWeight.w600,
            letterSpacing: 0.5,
          ),
        ),
        const SizedBox(height: 8),
        M3EDropdownMenu<String>(
          controller: _hrirDropdownController,
          items: _hrirItems,
          singleSelect: true,
          onSelectionChanged: _onHrirPresetSelected,
          fieldStyle: M3EDropdownFieldStyle(
            backgroundColor: surfaceDarkerColor,
            foregroundColor: Colors.white,
            border: const BorderSide(color: Colors.white12),
            focusedBorder: BorderSide(color: primaryColor),
          ),
          dropdownStyle: M3EDropdownPanelStyle(
            backgroundColor: surfaceDarkerColor,
          ),
          itemStyle: M3EDropdownItemStyle(
            textColor: Colors.white70,
            selectedTextColor: primaryColor,
          ),
        ),
        if (_isBuiltinHrir(_convolverIrPath)) ...[
          const SizedBox(height: 8),
          Row(
            children: [
              Icon(Icons.surround_sound_rounded, color: primaryColor, size: 16),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  'Built-in preset: $_convolverIrFileName',
                  style: TextStyle(color: Colors.white54, fontSize: 11),
                ),
              ),
              IconButton(
                icon: const Icon(Icons.clear_rounded,
                    color: Colors.white54, size: 18),
                tooltip: 'Clear Preset',
                onPressed: () {
                  _hrirDropdownController.clearAll();
                  setState(() {
                    _convolverIrPath = null;
                    _convolverIrFileName = null;
                    _convolverEnabled = false;
                  });
                  widget.player.clearConvolverIr();
                  _updateConvolver();
                  _saveEqState();
                },
              ),
            ],
          ),
        ],
        const SizedBox(height: 8),
        Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: surfaceDarkerColor,
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: Colors.white12),
          ),
          child: Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      _convolverIrFileName ?? 'No Impulse Response Loaded',
                      style: TextStyle(
                        color: _convolverIrFileName != null
                            ? Colors.white
                            : Colors.white54,
                        fontWeight: FontWeight.w600,
                        fontSize: 13,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    const SizedBox(height: 3),
                    Text(
                      _convolverIrPath != null
                          ? 'Active Acoustic Room Simulation'
                          : 'Load a .wav or .irs room impulse response file',
                      style:
                          const TextStyle(color: Colors.white38, fontSize: 11),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              if (_convolverIrPath != null)
                IconButton(
                  icon: const Icon(Icons.clear_rounded,
                      color: Colors.white54, size: 20),
                  tooltip: 'Clear File',
                  onPressed: () {
                    _hrirDropdownController.clearAll();
                    setState(() {
                      _convolverIrPath = null;
                      _convolverIrFileName = null;
                      _convolverEnabled = false;
                    });
                    widget.player.clearConvolverIr();
                    _updateConvolver();
                    _saveEqState();
                  },
                ),
              ElevatedButton.icon(
                icon: const Icon(Icons.folder_open_rounded, size: 16),
                label: const Text('Browse'),
                style: ElevatedButton.styleFrom(
                  backgroundColor: primaryColor.withValues(alpha: 0.25),
                  foregroundColor: primaryColor,
                  elevation: 0,
                  padding:
                      const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                ),
                onPressed: _pickImpulseResponse,
              ),
            ],
          ),
        ),
        const SizedBox(height: 16),
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceEvenly,
          children: [
            ModernAudioKnob(
              label: 'ROOM WET',
              value: _convolverWet,
              min: 0.0,
              max: 1.0,
              flatValue: 1.0,
              activeColor: _convolverEnabled ? primaryColor : Colors.white,
              isPercentage: true,
              valueFormatter: (v) => '${(v * 100).toInt()}%',
              onChanged: (v) {
                setState(() => _convolverWet = v);
                if (_convolverEnabled) _updateConvolver();
                _saveEqState();
              },
            ),
            ModernAudioKnob(
              label: 'AUDIO DRY',
              value: _convolverDry,
              min: 0.0,
              max: 1.0,
              flatValue: 0.0,
              activeColor: _convolverEnabled ? primaryColor : Colors.white,
              isPercentage: true,
              valueFormatter: (v) => '${(v * 100).toInt()}%',
              onChanged: (v) {
                setState(() => _convolverDry = v);
                if (_convolverEnabled) _updateConvolver();
                _saveEqState();
              },
            ),
          ],
        ),
      ],
    );
  }

  String _getSurroundModeName(SurroundMode mode) {
    switch (mode) {
      case SurroundMode.off:
        return 'Off';
      case SurroundMode.matrixSurround:
        return 'Matrix 5.1';
      case SurroundMode.binauralVirtualizer:
        return 'Binaural HRTF';
      case SurroundMode.acousticStage:
        return 'Acoustic Stage';
    }
  }

  String _getSurroundModeSubtitle() {
    switch (_surroundMode) {
      case SurroundMode.off:
        return 'Disabled';
      case SurroundMode.matrixSurround:
        return 'Matrix 5.1 | Focus ${(_surroundCenterFocus * 100).toInt()}%';
      case SurroundMode.binauralVirtualizer:
        final target = _surroundBinauralMode == 0 ? 'Headphone' : 'Speaker';
        return 'Binaural Virtualizer | $target (${(_surroundBinauralBoost * 100).toInt()}%)';
      case SurroundMode.acousticStage:
        final spread = _surroundStageMode == 0 ? 'Studio' : 'Panoramic';
        return 'Acoustic Stage | $spread (${_surroundStageWidth.toStringAsFixed(1)}x)';
    }
  }

  String _getSurroundModeDescription(SurroundMode mode) {
    switch (mode) {
      case SurroundMode.off:
        return 'Select a spatial surround engine';
      case SurroundMode.matrixSurround:
        return 'cleanroom 5.1 quadrature dematrixer';
      case SurroundMode.binauralVirtualizer:
        return 'Reconstructed binaural HRTF';
      case SurroundMode.acousticStage:
        return '3D soundstage with cross-talk cancellation';
    }
  }

  Widget _buildSurroundSection() {
    //use appwide theme primary color
    final primaryColor = context.primaryColor;
    return _CollapsibleSection(
      icon: Center(
        child:
            Icon(Icons.surround_sound_rounded, color: primaryColor, size: 20),
      ),
      title: 'Spatial Sound',
      subtitle: _getSurroundModeSubtitle(),
      isEnabled: _surroundEnabled,
      onToggle: (v) {
        setState(() {
          _surroundEnabled = v;
          if (v && _surroundMode == SurroundMode.off) {
            _surroundMode = SurroundMode.matrixSurround;
          }
        });
        _updateSurround();
        _saveEqState();
      },
      children: [
        // Algorithm selector
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
          decoration: BoxDecoration(
            color: surfaceDarkerColor,
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: Colors.white12),
          ),
          child: DropdownButtonHideUnderline(
            child: DropdownButton<SurroundMode>(
              value: _surroundMode == SurroundMode.off
                  ? SurroundMode.matrixSurround
                  : _surroundMode,
              dropdownColor: surfaceDarkerColor,
              isExpanded: true,
              icon: Icon(Icons.arrow_drop_down_rounded, color: primaryColor),
              style: const TextStyle(
                  color: Colors.white,
                  fontSize: 13.5,
                  fontWeight: FontWeight.w600),
              items: [
                for (final mode in [
                  SurroundMode.matrixSurround,
                  SurroundMode.binauralVirtualizer,
                  SurroundMode.acousticStage,
                ])
                  DropdownMenuItem(
                    value: mode,
                    child: Text(_getSurroundModeName(mode)),
                  ),
              ],
              onChanged: (mode) {
                if (mode == null) return;
                setState(() {
                  _surroundMode = mode;
                  _surroundEnabled = true;
                });
                _updateSurround();
                _saveEqState();
              },
            ),
          ),
        ),
        const SizedBox(height: 8),
        Center(
          child: Text(
            _getSurroundModeDescription(_surroundMode),
            textAlign: TextAlign.center,
            style: TextStyle(
              color: Colors.white.withValues(alpha: 0.55),
              fontSize: 11.5,
              height: 1.4,
            ),
          ),
        ),
        const SizedBox(height: 16),

        // Mode 1: Cinema Matrix 5.1 Controls
        if (_surroundMode == SurroundMode.matrixSurround)
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceEvenly,
            children: [
              ModernAudioKnob(
                label: 'CENTER FOCUS',
                value: _surroundCenterFocus,
                min: 0.0,
                max: 1.0,
                flatValue: 0.6,
                activeColor: _surroundEnabled ? primaryColor : Colors.white,
                isPercentage: true,
                valueFormatter: (v) => '${(v * 100).toInt()}%',
                onChanged: (v) {
                  setState(() => _surroundCenterFocus = v);
                  if (_surroundEnabled) _updateSurround();
                  _saveEqState();
                },
              ),
              ModernAudioKnob(
                label: 'SURROUND BOOST',
                value: (_surroundSurroundBoost - 0.5) / 1.5,
                min: 0.0,
                max: 1.0,
                flatValue: (1.2 - 0.5) / 1.5,
                activeColor: _surroundEnabled ? primaryColor : Colors.white,
                valueFormatter: (v) => '${(0.5 + v * 1.5).toStringAsFixed(1)}x',
                onChanged: (v) {
                  setState(() => _surroundSurroundBoost = 0.5 + v * 1.5);
                  if (_surroundEnabled) _updateSurround();
                  _saveEqState();
                },
              ),
              ModernAudioKnob(
                label: 'REAR DELAY',
                value: (_surroundRearDelayMs - 5.0) / 25.0,
                min: 0.0,
                max: 1.0,
                flatValue: (15.0 - 5.0) / 25.0,
                activeColor: _surroundEnabled ? primaryColor : Colors.white,
                valueFormatter: (v) =>
                    '${(5.0 + v * 25.0).toStringAsFixed(1)}ms',
                onChanged: (v) {
                  setState(() => _surroundRearDelayMs = 5.0 + v * 25.0);
                  if (_surroundEnabled) _updateSurround();
                  _saveEqState();
                },
              ),
            ],
          )

        // Mode 2: Binaural HRTF Virtualizer Controls
        else if (_surroundMode == SurroundMode.binauralVirtualizer)
          Column(
            children: [
              // Output Transducer Mode Switch
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  ChoiceChip(
                    label:
                        const Text('Headphone', style: TextStyle(fontSize: 12)),
                    selected: _surroundBinauralMode == 0,
                    selectedColor: primaryColor.withValues(alpha: 0.3),
                    onSelected: (selected) {
                      if (selected) {
                        setState(() => _surroundBinauralMode = 0);
                        if (_surroundEnabled) _updateSurround();
                        _saveEqState();
                      }
                    },
                  ),
                  const SizedBox(width: 8),
                  ChoiceChip(
                    label: const Text('Speaker Field',
                        style: TextStyle(fontSize: 12)),
                    selected: _surroundBinauralMode == 1,
                    selectedColor: primaryColor.withValues(alpha: 0.3),
                    onSelected: (selected) {
                      if (selected) {
                        setState(() => _surroundBinauralMode = 1);
                        if (_surroundEnabled) _updateSurround();
                        _saveEqState();
                      }
                    },
                  ),
                ],
              ),
              const SizedBox(height: 12),

              if (_surroundBinauralMode == 0) ...[
                // Headphone Mode: DH1/DH2/DH3 Room Presets
                SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  physics: const BouncingScrollPhysics(),
                  child: Row(
                    children: [
                      ChoiceChip(
                        label: const Text('Studio',
                            style: TextStyle(fontSize: 11)),
                        selected: _surroundBinauralRoomPreset == 1,
                        selectedColor: primaryColor.withValues(alpha: 0.25),
                        onSelected: (s) {
                          if (s) {
                            setState(() => _surroundBinauralRoomPreset = 1);
                            if (_surroundEnabled) _updateSurround();
                            _saveEqState();
                          }
                        },
                      ),
                      const SizedBox(width: 6),
                      ChoiceChip(
                        label: const Text('Cinema',
                            style: TextStyle(fontSize: 11)),
                        selected: _surroundBinauralRoomPreset == 2,
                        selectedColor: primaryColor.withValues(alpha: 0.25),
                        onSelected: (s) {
                          if (s) {
                            setState(() => _surroundBinauralRoomPreset = 2);
                            if (_surroundEnabled) _updateSurround();
                            _saveEqState();
                          }
                        },
                      ),
                      const SizedBox(width: 6),
                      ChoiceChip(
                        label: const Text('Concert Hall',
                            style: TextStyle(fontSize: 11)),
                        selected: _surroundBinauralRoomPreset == 3,
                        selectedColor: primaryColor.withValues(alpha: 0.25),
                        onSelected: (s) {
                          if (s) {
                            setState(() => _surroundBinauralRoomPreset = 3);
                            if (_surroundEnabled) _updateSurround();
                            _saveEqState();
                          }
                        },
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 12),
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                  children: [
                    ModernAudioKnob(
                      label: 'INTENSITY',
                      value: _surroundBinauralBoost,
                      min: 0.0,
                      max: 1.0,
                      flatValue: 0.65,
                      activeColor:
                          _surroundEnabled ? primaryColor : Colors.white,
                      isPercentage: true,
                      valueFormatter: (v) => '${(v * 100).toInt()}%',
                      onChanged: (v) {
                        setState(() => _surroundBinauralBoost = v);
                        if (_surroundEnabled) _updateSurround();
                        _saveEqState();
                      },
                    ),
                    ModernAudioKnob(
                      label: 'ROOM REVERB',
                      value: _surroundBinauralRoomMix,
                      min: 0.0,
                      max: 1.0,
                      flatValue: 0.35,
                      activeColor:
                          _surroundEnabled ? primaryColor : Colors.white,
                      isPercentage: true,
                      valueFormatter: (v) => '${(v * 100).toInt()}%',
                      onChanged: (v) {
                        setState(() => _surroundBinauralRoomMix = v);
                        if (_surroundEnabled) _updateSurround();
                        _saveEqState();
                      },
                    ),
                    ModernAudioKnob(
                      label: 'HEAD SHADOW',
                      value: (_surroundBinauralShadowCutoff - 2000.0) / 3000.0,
                      min: 0.0,
                      max: 1.0,
                      flatValue: (3500.0 - 2000.0) / 3000.0,
                      activeColor:
                          _surroundEnabled ? primaryColor : Colors.white,
                      valueFormatter: (v) =>
                          '${(2000.0 + v * 3000.0).toInt()}Hz',
                      onChanged: (v) {
                        setState(() => _surroundBinauralShadowCutoff =
                            2000.0 + v * 3000.0);
                        if (_surroundEnabled) _updateSurround();
                        _saveEqState();
                      },
                    ),
                  ],
                ),
              ] else ...[
                // Speaker Field Mode: Angle selection
                Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    ChoiceChip(
                      label: const Text('Narrow (10°)',
                          style: TextStyle(fontSize: 11)),
                      selected: _surroundBinauralSpeakerAngle == 0,
                      selectedColor: primaryColor.withValues(alpha: 0.25),
                      onSelected: (s) {
                        if (s) {
                          setState(() => _surroundBinauralSpeakerAngle = 0);
                          if (_surroundEnabled) _updateSurround();
                          _saveEqState();
                        }
                      },
                    ),
                    const SizedBox(width: 6),
                    ChoiceChip(
                      label: const Text('Standard (30°)',
                          style: TextStyle(fontSize: 11)),
                      selected: _surroundBinauralSpeakerAngle == 1,
                      selectedColor: primaryColor.withValues(alpha: 0.25),
                      onSelected: (s) {
                        if (s) {
                          setState(() => _surroundBinauralSpeakerAngle = 1);
                          if (_surroundEnabled) _updateSurround();
                          _saveEqState();
                        }
                      },
                    ),
                    const SizedBox(width: 6),
                    ChoiceChip(
                      label: const Text('Wide (45°)',
                          style: TextStyle(fontSize: 11)),
                      selected: _surroundBinauralSpeakerAngle == 2,
                      selectedColor: primaryColor.withValues(alpha: 0.25),
                      onSelected: (s) {
                        if (s) {
                          setState(() => _surroundBinauralSpeakerAngle = 2);
                          if (_surroundEnabled) _updateSurround();
                          _saveEqState();
                        }
                      },
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                  children: [
                    ModernAudioKnob(
                      label: 'INTENSITY',
                      value: _surroundBinauralBoost,
                      min: 0.0,
                      max: 1.0,
                      flatValue: 0.65,
                      activeColor:
                          _surroundEnabled ? primaryColor : Colors.white,
                      isPercentage: true,
                      valueFormatter: (v) => '${(v * 100).toInt()}%',
                      onChanged: (v) {
                        setState(() => _surroundBinauralBoost = v);
                        if (_surroundEnabled) _updateSurround();
                        _saveEqState();
                      },
                    ),
                    ModernAudioKnob(
                      label: 'SHADOW CUTOFF',
                      value: (_surroundBinauralShadowCutoff - 2000.0) / 3000.0,
                      min: 0.0,
                      max: 1.0,
                      flatValue: (3500.0 - 2000.0) / 3000.0,
                      activeColor:
                          _surroundEnabled ? primaryColor : Colors.white,
                      valueFormatter: (v) =>
                          '${(2000.0 + v * 3000.0).toInt()}Hz',
                      onChanged: (v) {
                        setState(() => _surroundBinauralShadowCutoff =
                            2000.0 + v * 3000.0);
                        if (_surroundEnabled) _updateSurround();
                        _saveEqState();
                      },
                    ),
                  ],
                ),
              ],
            ],
          )

        // Mode 3: 3D Acoustic Stage Controls
        else if (_surroundMode == SurroundMode.acousticStage)
          Column(
            children: [
              // Transducer and Spread Profile Chips
              SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                physics: const BouncingScrollPhysics(),
                child: Row(
                  children: [
                    ChoiceChip(
                      label:
                          const Text('Headset', style: TextStyle(fontSize: 11)),
                      selected: _surroundStageProfile == 0,
                      selectedColor: primaryColor.withValues(alpha: 0.25),
                      onSelected: (s) {
                        if (s) {
                          setState(() => _surroundStageProfile = 0);
                          if (_surroundEnabled) _updateSurround();
                          _saveEqState();
                        }
                      },
                    ),
                    const SizedBox(width: 6),
                    ChoiceChip(
                      label:
                          const Text('Speaker', style: TextStyle(fontSize: 11)),
                      selected: _surroundStageProfile == 1,
                      selectedColor: primaryColor.withValues(alpha: 0.25),
                      onSelected: (s) {
                        if (s) {
                          setState(() => _surroundStageProfile = 1);
                          if (_surroundEnabled) _updateSurround();
                          _saveEqState();
                        }
                      },
                    ),
                    const SizedBox(width: 12),
                    ChoiceChip(
                      label: const Text('Studio (D=25k)',
                          style: TextStyle(fontSize: 11)),
                      selected: _surroundStageMode == 0,
                      selectedColor: primaryColor.withValues(alpha: 0.25),
                      onSelected: (s) {
                        if (s) {
                          setState(() => _surroundStageMode = 0);
                          if (_surroundEnabled) _updateSurround();
                          _saveEqState();
                        }
                      },
                    ),
                    const SizedBox(width: 6),
                    ChoiceChip(
                      label: const Text('Panoramic (D=10k)',
                          style: TextStyle(fontSize: 11)),
                      selected: _surroundStageMode == 1,
                      selectedColor: primaryColor.withValues(alpha: 0.25),
                      onSelected: (s) {
                        if (s) {
                          setState(() => _surroundStageMode = 1);
                          if (_surroundEnabled) _updateSurround();
                          _saveEqState();
                        }
                      },
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 12),
              // Knobs Row 1: Width, Depth, Cancellation
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                children: [
                  ModernAudioKnob(
                    label: 'STAGE WIDTH',
                    value: (_surroundStageWidth - 0.5) / 1.5,
                    min: 0.0,
                    max: 1.0,
                    flatValue: (1.2 - 0.5) / 1.5,
                    activeColor: _surroundEnabled ? primaryColor : Colors.white,
                    valueFormatter: (v) =>
                        '${(0.5 + v * 1.5).toStringAsFixed(1)}x',
                    onChanged: (v) {
                      setState(() => _surroundStageWidth = 0.5 + v * 1.5);
                      if (_surroundEnabled) _updateSurround();
                      _saveEqState();
                    },
                  ),
                  ModernAudioKnob(
                    label: 'STAGE DEPTH',
                    value: _surroundStageDepth,
                    min: 0.0,
                    max: 1.0,
                    flatValue: 0.5,
                    activeColor: _surroundEnabled ? primaryColor : Colors.white,
                    isPercentage: true,
                    valueFormatter: (v) => '${(v * 100).toInt()}%',
                    onChanged: (v) {
                      setState(() => _surroundStageDepth = v);
                      if (_surroundEnabled) _updateSurround();
                      _saveEqState();
                    },
                  ),
                  ModernAudioKnob(
                    label: 'CROSSTALK CANCEL',
                    value: _surroundStageCancellation,
                    min: 0.0,
                    max: 1.0,
                    flatValue: 0.60,
                    activeColor: _surroundEnabled ? primaryColor : Colors.white,
                    isPercentage: true,
                    valueFormatter: (v) => '${(v * 100).toInt()}%',
                    onChanged: (v) {
                      setState(() => _surroundStageCancellation = v);
                      if (_surroundEnabled) _updateSurround();
                      _saveEqState();
                    },
                  ),
                ],
              ),
              const SizedBox(height: 10),
              // Knobs Row 2: Air Contour & Bass Anchor
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                children: [
                  ModernAudioKnob(
                    label: 'AIR CONTOUR',
                    value: _surroundStageAirPresence,
                    min: 0.0,
                    max: 1.0,
                    flatValue: 0.40,
                    activeColor: _surroundEnabled ? primaryColor : Colors.white,
                    isPercentage: true,
                    valueFormatter: (v) => '${(v * 100).toInt()}%',
                    onChanged: (v) {
                      setState(() => _surroundStageAirPresence = v);
                      if (_surroundEnabled) _updateSurround();
                      _saveEqState();
                    },
                  ),
                  ModernAudioKnob(
                    label: 'BASS ANCHOR',
                    value: (_surroundStageBassAnchorHz - 20.0) / 100.0,
                    min: 0.0,
                    max: 1.0,
                    flatValue: (60.0 - 20.0) / 100.0,
                    activeColor: _surroundEnabled ? primaryColor : Colors.white,
                    valueFormatter: (v) => '${(20.0 + v * 100.0).toInt()}Hz',
                    onChanged: (v) {
                      setState(
                          () => _surroundStageBassAnchorHz = 20.0 + v * 100.0);
                      if (_surroundEnabled) _updateSurround();
                      _saveEqState();
                    },
                  ),
                ],
              ),
            ],
          ),

        const SizedBox(height: 14),
        /* Center(
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
            decoration: BoxDecoration(
              color: primaryColor.withValues(alpha: 0.1),
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: primaryColor.withValues(alpha: 0.25)),
            ),
            child: Text(
              'Zero-latency binaural/surround processing | Stereo (headphone & speaker) output',
              style: TextStyle(
                color: Colors.white.withValues(alpha: 0.6),
                fontSize: 11,
              ),
              textAlign: TextAlign.center,
            ),
          ),
        ),*/
      ],
    );
  }

  void _applyReverbPreset(String name) {
    final preset = _reverbPresets.firstWhere(
      (p) => p.name == name,
      orElse: () => _reverbPresets.first,
    );
    setState(() {
      _reverbPreset = preset.name;
      _reverbWet = preset.wet;
      _reverbDry = preset.dry;
      _reverbRoomSize = preset.roomSize;
      _reverbDamping = preset.damping;
      _reverbPreDelayMs = preset.preDelayMs;
      _reverbWidth = preset.width;
    });
    if (_reverbEnabled) _updateReverb();
    _saveEqState();
  }

  Widget _buildReverbSection() {
    return _CollapsibleSection(
      icon: Center(
        child: Icon(Icons.wb_twilight_rounded, color: primaryColor, size: 20),
      ),
      title: 'Reverb',
      subtitle: 'Freeverb room simulation',
      isEnabled: _reverbEnabled,
      onToggle: (v) {
        setState(() => _reverbEnabled = v);
        _updateReverb();
        _saveEqState();
      },
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text(
              'Reverb Preset',
              style: TextStyle(
                color: Colors.white.withValues(alpha: 0.85),
                fontSize: 13.5,
                fontWeight: FontWeight.w600,
              ),
            ),
            DropdownButtonHideUnderline(
              child: DropdownButton<String>(
                value: _reverbPreset,
                dropdownColor: surfaceDarkerColor,
                icon: Icon(Icons.arrow_drop_down_rounded, color: primaryColor),
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                ),
                items: _reverbPresets
                    .map((p) => DropdownMenuItem(
                          value: p.name,
                          child: Text(p.name),
                        ))
                    .toList(),
                onChanged: (val) {
                  if (val != null) {
                    _applyReverbPreset(val);
                  }
                },
              ),
            ),
          ],
        ),
        const SizedBox(height: 8),
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceEvenly,
          children: [
            ModernAudioKnob(
              label: 'WET',
              value: _reverbWet,
              min: 0.0,
              max: 2.0,
              flatValue: 0.25,
              activeColor: _reverbEnabled ? primaryColor : Colors.white,
              isPercentage: true,
              valueFormatter: (v) => '${(v * 100).toInt()}%',
              onChanged: (v) {
                setState(() {
                  _reverbWet = v;
                  _reverbPreset = 'Custom';
                });
                if (_reverbEnabled) {
                  widget.player
                      .setReverbGains(wet: _reverbWet, dry: _reverbDry);
                }
                _saveEqState();
              },
            ),
            ModernAudioKnob(
              label: 'ROOM SIZE',
              value: _reverbRoomSize,
              min: 0.0,
              max: 1.0,
              flatValue: 0.6,
              activeColor: _reverbEnabled ? primaryColor : Colors.white,
              isPercentage: true,
              valueFormatter: (v) => '${(v * 100).toInt()}%',
              onChanged: (v) {
                setState(() {
                  _reverbRoomSize = v;
                  _reverbPreset = 'Custom';
                });
                if (_reverbEnabled) _updateReverb();
                _saveEqState();
              },
            ),
            ModernAudioKnob(
              label: 'DAMPING',
              value: _reverbDamping,
              min: 0.0,
              max: 1.0,
              flatValue: 0.4,
              activeColor: _reverbEnabled ? primaryColor : Colors.white,
              isPercentage: true,
              valueFormatter: (v) => '${(v * 100).toInt()}%',
              onChanged: (v) {
                setState(() {
                  _reverbDamping = v;
                  _reverbPreset = 'Custom';
                });
                if (_reverbEnabled) _updateReverb();
                _saveEqState();
              },
            ),
          ],
        ),
        const SizedBox(height: 16),
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceEvenly,
          children: [
            ModernAudioKnob(
              label: 'PRE-DELAY',
              value: _reverbPreDelayMs,
              min: 0.0,
              max: 250.0,
              flatValue: 20.0,
              activeColor: _reverbEnabled ? primaryColor : Colors.white,
              valueFormatter: (v) => '${v.toInt()} ms',
              onChanged: (v) {
                setState(() {
                  _reverbPreDelayMs = v;
                  _reverbPreset = 'Custom';
                });
                if (_reverbEnabled) _updateReverb();
                _saveEqState();
              },
            ),
            ModernAudioKnob(
              label: 'WIDTH',
              value: _reverbWidth,
              min: 0.0,
              max: 1.0,
              flatValue: 1.0,
              activeColor: _reverbEnabled ? primaryColor : Colors.white,
              isPercentage: true,
              valueFormatter: (v) => '${(v * 100).toInt()}%',
              onChanged: (v) {
                setState(() {
                  _reverbWidth = v;
                  _reverbPreset = 'Custom';
                });
                if (_reverbEnabled) _updateReverb();
                _saveEqState();
              },
            ),
            ModernAudioKnob(
              label: 'DRY',
              value: _reverbDry,
              min: 0.0,
              max: 2.0,
              flatValue: 0.75,
              activeColor: _reverbEnabled ? primaryColor : Colors.white,
              isPercentage: true,
              valueFormatter: (v) => '${(v * 100).toInt()}%',
              onChanged: (v) {
                setState(() {
                  _reverbDry = v;
                  _reverbPreset = 'Custom';
                });
                if (_reverbEnabled) {
                  widget.player
                      .setReverbGains(wet: _reverbWet, dry: _reverbDry);
                }
                _saveEqState();
              },
            ),
          ],
        ),
        const SizedBox(height: 12),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 4.0),
          child: Text(
            'Tip: higher room size & lower damping give long, bright halls; '
            'pre-delay keeps vocals clear of the tail.',
            style: TextStyle(
              color: Colors.white.withValues(alpha: 0.4),
              fontSize: 11.5,
              height: 1.3,
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildMasterLimiterSection() {
    return _CollapsibleSection(
      icon: Center(
        child: Icon(Icons.shield_rounded, color: primaryColor, size: 20),
      ),
      title: 'Master Peak Limiter',
      subtitle: 'Lookahead true-peak brickwall limiting & loudness booster',
      isEnabled: _masterLimiterEnabled,
      onToggle: (v) {
        setState(() => _masterLimiterEnabled = v);
        _updateMasterLimiter();
        _saveEqState();
      },
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceEvenly,
          children: [
            ModernAudioKnob(
              label: 'CEILING',
              value: _masterLimiterCeilingDb,
              min: -12.0,
              max: 0.0,
              flatValue: -0.1,
              activeColor: _masterLimiterEnabled ? primaryColor : Colors.white,
              valueFormatter: (v) => '${v.toStringAsFixed(1)} dB',
              onChanged: (v) {
                setState(() => _masterLimiterCeilingDb = v);
                if (_masterLimiterEnabled) _updateMasterLimiter();
                _saveEqState();
              },
            ),
            ModernAudioKnob(
              label: 'GAIN BOOST',
              value: _masterLimiterOutputGainDb,
              min: -6.0,
              max: 12.0,
              flatValue: 0.0,
              activeColor: _masterLimiterEnabled ? primaryColor : Colors.white,
              valueFormatter: (v) =>
                  '${v >= 0 ? '+' : ''}${v.toStringAsFixed(1)} dB',
              onChanged: (v) {
                setState(() => _masterLimiterOutputGainDb = v);
                if (_masterLimiterEnabled) _updateMasterLimiter();
                _saveEqState();
              },
            ),
            ModernAudioKnob(
              label: 'RELEASE',
              value: _masterLimiterReleaseMs,
              min: 10.0,
              max: 500.0,
              flatValue: 60.0,
              activeColor: _masterLimiterEnabled ? primaryColor : Colors.white,
              valueFormatter: (v) => '${v.toInt()} ms',
              onChanged: (v) {
                setState(() => _masterLimiterReleaseMs = v);
                if (_masterLimiterEnabled) _updateMasterLimiter();
                _saveEqState();
              },
            ),
          ],
        ),
      ],
    );
  }

  void _applyLimiter() {
    widget.player.setLimiterEnabled(_limiterEnabled);
    if (_limiterEnabled) {
      widget.player.setLimiterParams(
        threshold: _limiterThreshold,
        attackMs: _limiterAttackMs,
        releaseMs: _limiterReleaseMs,
      );
    }
  }

  Widget _buildLimiterSection() {
    return _CollapsibleSection(
      icon: /* M3EContainer(
        Shapes.square,
        width: 40,
        height: 40,
        color: primaryColor.withValues(alpha: 0.18),
        border: BorderSide(
          color: primaryColor.withValues(alpha: 0.4),
          width: 1.0,
        ),
        child:*/
          Center(
        child: Icon(Icons.compress_rounded, color: primaryColor, size: 20),
        //),
      ),
      title: 'Soft Limiter',
      subtitle: 'True-peak limiting & anti-clipping dynamics processor',
      isEnabled: _limiterEnabled,
      onToggle: (v) {
        setState(() => _limiterEnabled = v);
        _applyLimiter();
        _saveEqState();
      },
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceEvenly,
          children: [
            ModernAudioKnob(
              label: 'THRESHOLD',
              value: _limiterThreshold,
              min: 0.1,
              max: 1.0,
              flatValue: 0.95,
              activeColor: _limiterEnabled ? primaryColor : Colors.white,
              isPercentage: true,
              valueFormatter: (v) => '${(v * 100).toInt()}%',
              onChanged: _limiterEnabled
                  ? (v) {
                      setState(() => _limiterThreshold = v);
                      _applyLimiter();
                    }
                  : (_) {},
            ),
            ModernAudioKnob(
              label: 'ATTACK',
              value: _limiterAttackMs,
              min: 0.1,
              max: 100.0,
              flatValue: 2.0,
              activeColor: _limiterEnabled ? primaryColor : Colors.white,
              valueFormatter: (v) => '${v.toStringAsFixed(1)}ms',
              onChanged: _limiterEnabled
                  ? (v) {
                      setState(() => _limiterAttackMs = v);
                      _applyLimiter();
                    }
                  : (_) {},
            ),
            ModernAudioKnob(
              label: 'RELEASE',
              value: _limiterReleaseMs,
              min: 10.0,
              max: 1000.0,
              flatValue: 50.0,
              activeColor: _limiterEnabled ? primaryColor : Colors.white,
              valueFormatter: (v) => '${v.toStringAsFixed(0)}ms',
              onChanged: _limiterEnabled
                  ? (v) {
                      setState(() => _limiterReleaseMs = v);
                      _applyLimiter();
                    }
                  : (_) {},
            ),
          ],
        ),
      ],
    );
  }

  void _updateCompressor() {
    widget.player.setCompressorEnabled(_compressorEnabled);
    if (_compressorEnabled) {
      widget.player.setCompressorParams(
        thresholdDb: _compressorThresholdDb,
        ratio: _compressorRatio,
        kneeDb: _compressorKneeDb,
        attackMs: _compressorAttackMs,
        releaseMs: _compressorReleaseMs,
        makeupGainDb: _compressorMakeupGainDb,
        detector: _compressorDetector,
        stereoLink: _compressorStereoLink,
        autoMakeup: _compressorAutoMakeup,
        mix: _compressorMix,
      );
    }
  }

  void _applyCompressorPreset(String name) {
    final preset = _compressorPresets.firstWhere(
      (p) => p.name == name,
      orElse: () => _compressorPresets.first,
    );
    setState(() {
      _compressorPreset = preset.name;
      _compressorThresholdDb = preset.thresholdDb;
      _compressorRatio = preset.ratio;
      _compressorKneeDb = preset.kneeDb;
      _compressorAttackMs = preset.attackMs;
      _compressorReleaseMs = preset.releaseMs;
      _compressorMakeupGainDb = preset.makeupGainDb;
      _compressorDetector = preset.detector;
      _compressorStereoLink = preset.stereoLink;
      _compressorAutoMakeup = preset.autoMakeup;
      _compressorMix = preset.mix;
    });
    if (_compressorEnabled) _updateCompressor();
    _saveEqState();
  }

  Widget _buildCompressorSection() {
    final primaryColor = context.primaryColor;
    final grDb = _compressorGainReductionDb.abs();
    // Normalize GR to 0.0 .. 1.0 (range: 0 dB to 24 dB)
    final grFraction = (grDb / 24.0).clamp(0.0, 1.0);

    return _CollapsibleSection(
      icon: Center(
        child: Icon(Icons.tune_rounded, color: primaryColor, size: 20),
      ),
      title: 'Compressor',
      subtitle: 'Soft-knee dynamics, peak/RMS detector & gain reduction',
      isEnabled: _compressorEnabled,
      onToggle: (v) {
        setState(() => _compressorEnabled = v);
        _updateCompressor();
        _saveEqState();
      },
      children: [
        RepaintBoundary(
          child: CompressorTransferGraph(
            thresholdDb: _compressorThresholdDb,
            ratio: _compressorRatio,
            kneeDb: _compressorKneeDb,
            makeupGainDb: _compressorMakeupGainDb,
            gainReductionDb: _compressorGainReductionDb,
            isEnabled: _compressorEnabled,
            height: 135.0,
            primaryColor: primaryColor,
          ),
        ),
        const SizedBox(height: 10),
        // Live Gain Reduction Meter
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
          decoration: BoxDecoration(
            color: surfaceDarkerColor,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(
              color: primaryColor.withValues(
                  alpha: _compressorEnabled ? 0.35 : 0.1),
            ),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Row(
                    children: [
                      Container(
                        width: 8,
                        height: 8,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          color: _compressorEnabled && grDb > 0.1
                              ? primaryColor
                              : Colors.white24,
                          boxShadow: _compressorEnabled && grDb > 0.1
                              ? [
                                  BoxShadow(
                                    color: primaryColor.withValues(alpha: 0.6),
                                    blurRadius: 6,
                                  ),
                                ]
                              : null,
                        ),
                      ),
                      const SizedBox(width: 6),
                      const Text(
                        'GAIN REDUCTION',
                        style: TextStyle(
                          color: Colors.white70,
                          fontSize: 10.5,
                          fontWeight: FontWeight.bold,
                          letterSpacing: 0.8,
                        ),
                      ),
                    ],
                  ),
                  Text(
                    _compressorEnabled
                        ? (grDb > 0.05
                            ? '-${grDb.toStringAsFixed(1)} dB'
                            : '0.0 dB')
                        : 'OFF',
                    style: TextStyle(
                      color: _compressorEnabled && grDb > 0.1
                          ? primaryColor
                          : Colors.white38,
                      fontSize: 12,
                      fontWeight: FontWeight.bold,
                      fontFamily: 'monospace',
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              // Meter Bar
              Stack(
                children: [
                  // Track
                  Container(
                    height: 8,
                    decoration: BoxDecoration(
                      color: Colors.white10,
                      borderRadius: BorderRadius.circular(4),
                    ),
                  ),
                  // Active GR Fill
                  FractionallySizedBox(
                    widthFactor: _compressorEnabled ? grFraction : 0.0,
                    child: Container(
                      height: 8,
                      decoration: BoxDecoration(
                        gradient: LinearGradient(
                          colors: [
                            primaryColor.withValues(alpha: 0.5),
                            Color(0xFFFF9100),
                          ],
                        ),
                        borderRadius: BorderRadius.circular(4),
                        boxShadow: [
                          BoxShadow(
                            color: primaryColor.withValues(alpha: 0.5),
                            blurRadius: 4,
                          ),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 4),
              // Scale Ticks
              const Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text('0',
                      style: TextStyle(color: Colors.white30, fontSize: 8.5)),
                  Text('-3',
                      style: TextStyle(color: Colors.white30, fontSize: 8.5)),
                  Text('-6',
                      style: TextStyle(color: Colors.white30, fontSize: 8.5)),
                  Text('-12',
                      style: TextStyle(color: Colors.white30, fontSize: 8.5)),
                  Text('-18',
                      style: TextStyle(color: Colors.white30, fontSize: 8.5)),
                  Text('-24 dB',
                      style: TextStyle(color: Colors.white30, fontSize: 8.5)),
                ],
              ),
            ],
          ),
        ),

        const SizedBox(height: 14),

        // Preset Chips
        SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          physics: const BouncingScrollPhysics(),
          child: Row(
            children: _compressorPresets.map((preset) {
              final isSelected = _compressorPreset == preset.name;
              return Padding(
                padding: const EdgeInsets.only(right: 6.0),
                child: M3EChip(
                  label: preset.name,
                  type: M3EChipType.filter,
                  selected: isSelected,
                  onPressed: () => _applyCompressorPreset(preset.name),
                ),
              );
            }).toList(),
          ),
        ),

        const SizedBox(height: 14),

        // Knobs Row 1: Threshold, Ratio, Makeup Gain
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceEvenly,
          children: [
            ModernAudioKnob(
              label: 'THRESHOLD',
              value: _compressorThresholdDb,
              min: -60.0,
              max: 0.0,
              flatValue: -20.0,
              activeColor: _compressorEnabled ? primaryColor : Colors.white38,
              valueFormatter: (v) => '${v.toStringAsFixed(1)} dB',
              onChanged: (v) {
                setState(() {
                  _compressorThresholdDb = v;
                  _compressorPreset = 'Custom';
                });
                if (_compressorEnabled) _updateCompressor();
                _saveEqState();
              },
            ),
            ModernAudioKnob(
              label: 'RATIO',
              value: _compressorRatio,
              min: 1.0,
              max: 20.0,
              flatValue: 4.0,
              activeColor: _compressorEnabled ? primaryColor : Colors.white38,
              valueFormatter: (v) => '${v.toStringAsFixed(1)}:1',
              onChanged: (v) {
                setState(() {
                  _compressorRatio = v;
                  _compressorPreset = 'Custom';
                });
                if (_compressorEnabled) _updateCompressor();
                _saveEqState();
              },
            ),
            ModernAudioKnob(
              label: 'MAKEUP',
              value: _compressorMakeupGainDb,
              min: 0.0,
              max: 24.0,
              flatValue: 0.0,
              activeColor: _compressorEnabled && !_compressorAutoMakeup
                  ? primaryColor
                  : Colors.white38,
              valueFormatter: (v) => _compressorAutoMakeup
                  ? 'AUTO'
                  : '+${v.toStringAsFixed(1)} dB',
              onChanged: (v) {
                if (_compressorAutoMakeup) return;
                setState(() {
                  _compressorMakeupGainDb = v;
                  _compressorPreset = 'Custom';
                });
                if (_compressorEnabled) _updateCompressor();
                _saveEqState();
              },
            ),
          ],
        ),

        const SizedBox(height: 16),

        // Knobs Row 2: Knee, Attack, Release, Mix
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceEvenly,
          children: [
            ModernAudioKnob(
              label: 'KNEE',
              value: _compressorKneeDb,
              min: 0.0,
              max: 24.0,
              flatValue: 6.0,
              activeColor: _compressorEnabled ? primaryColor : Colors.white38,
              valueFormatter: (v) => '${v.toStringAsFixed(1)} dB',
              onChanged: (v) {
                setState(() {
                  _compressorKneeDb = v;
                  _compressorPreset = 'Custom';
                });
                if (_compressorEnabled) _updateCompressor();
                _saveEqState();
              },
            ),
            ModernAudioKnob(
              label: 'ATTACK',
              value: _compressorAttackMs,
              min: 0.1,
              max: 100.0,
              flatValue: 10.0,
              activeColor: _compressorEnabled ? primaryColor : Colors.white38,
              valueFormatter: (v) => '${v.toStringAsFixed(1)} ms',
              onChanged: (v) {
                setState(() {
                  _compressorAttackMs = v;
                  _compressorPreset = 'Custom';
                });
                if (_compressorEnabled) _updateCompressor();
                _saveEqState();
              },
            ),
            ModernAudioKnob(
              label: 'RELEASE',
              value: _compressorReleaseMs,
              min: 10.0,
              max: 1000.0,
              flatValue: 100.0,
              activeColor: _compressorEnabled ? primaryColor : Colors.white38,
              valueFormatter: (v) => '${v.toInt()} ms',
              onChanged: (v) {
                setState(() {
                  _compressorReleaseMs = v;
                  _compressorPreset = 'Custom';
                });
                if (_compressorEnabled) _updateCompressor();
                _saveEqState();
              },
            ),
            ModernAudioKnob(
              label: 'MIX',
              value: _compressorMix,
              min: 0.0,
              max: 1.0,
              flatValue: 1.0,
              isPercentage: true,
              activeColor: _compressorEnabled ? primaryColor : Colors.white38,
              valueFormatter: (v) => '${(v * 100).toInt()}%',
              onChanged: (v) {
                setState(() {
                  _compressorMix = v;
                  _compressorPreset = 'Custom';
                });
                if (_compressorEnabled) _updateCompressor();
                _saveEqState();
              },
            ),
          ],
        ),

        const SizedBox(height: 16),

        // Detector Mode Selector (Peak vs RMS) & Auto Makeup & Stereo Link
        Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: surfaceDarkerColor,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: Colors.white10),
          ),
          child: Column(
            children: [
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  const Text(
                    'Detector Mode',
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  Row(
                    children: [
                      ChoiceChip(
                        label:
                            const Text('Peak', style: TextStyle(fontSize: 12)),
                        selected: _compressorDetector == 0,
                        selectedColor: primaryColor.withValues(alpha: 0.3),
                        onSelected: (selected) {
                          if (selected) {
                            setState(() {
                              _compressorDetector = 0;
                              _compressorPreset = 'Custom';
                            });
                            if (_compressorEnabled) _updateCompressor();
                            _saveEqState();
                          }
                        },
                      ),
                      const SizedBox(width: 8),
                      ChoiceChip(
                        label:
                            const Text('RMS', style: TextStyle(fontSize: 12)),
                        selected: _compressorDetector == 1,
                        selectedColor: primaryColor.withValues(alpha: 0.3),
                        onSelected: (selected) {
                          if (selected) {
                            setState(() {
                              _compressorDetector = 1;
                              _compressorPreset = 'Custom';
                            });
                            if (_compressorEnabled) _updateCompressor();
                            _saveEqState();
                          }
                        },
                      ),
                    ],
                  ),
                ],
              ),
              const Divider(color: Colors.white10, height: 16),
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text(
                        'Auto Makeup Gain',
                        style: TextStyle(
                          color: Colors.white,
                          fontSize: 13,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      Text(
                        'Compensate volume',
                        style: TextStyle(
                          color: Colors.white.withValues(alpha: 0.5),
                          fontSize: 11,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    ],
                  ),
                  M3ESwitch(
                    selectedIcon: Icon(Icons.check, color: primaryColor),
                    value: _compressorAutoMakeup,
                    onChanged: (v) {
                      setState(() {
                        _compressorAutoMakeup = v;
                        _compressorPreset = 'Custom';
                      });
                      if (_compressorEnabled) _updateCompressor();
                      _saveEqState();
                    },
                  ),
                ],
              ),
              const Divider(color: Colors.white10, height: 16),
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text(
                        'Stereo Link',
                        style: TextStyle(
                          color: Colors.white,
                          fontSize: 13,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      Text(
                        'Link L/R channels',
                        style: TextStyle(
                          color: Colors.white.withValues(alpha: 0.5),
                          fontSize: 11,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    ],
                  ),
                  M3ESwitch(
                    selectedIcon: Icon(Icons.check, color: primaryColor),
                    value: _compressorStereoLink,
                    onChanged: (v) {
                      setState(() {
                        _compressorStereoLink = v;
                        _compressorPreset = 'Custom';
                      });
                      if (_compressorEnabled) _updateCompressor();
                      _saveEqState();
                    },
                  ),
                ],
              ),
            ],
          ),
        ),

        const SizedBox(height: 10),

        /*  Center(
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
            decoration: BoxDecoration(
              color: const Color(0x1A00E5FF),
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: const Color(0x4000E5FF)),
            ),
            child: Text(
              'RMS mode: smooth musical leveling · Peak mode: aggressive punch & transient capture',
              style: TextStyle(
                color: Colors.white.withValues(alpha: 0.65),
                fontSize: 11,
              ),
              textAlign: TextAlign.center,
            ),
          ),
        ),*/
      ],
    );
  }
}

class ModernAudioKnob extends StatefulWidget {
  final String label;
  final double value;
  final double min;
  final double max;
  final double flatValue;
  final ValueChanged<double> onChanged;
  final String Function(double)? valueFormatter;
  final Color? activeColor;
  final bool isPercentage;
  final double displayMultiplier;
  final double size;

  const ModernAudioKnob({
    super.key,
    required this.label,
    required this.value,
    this.min = 0.0,
    this.max = 3.0,
    this.flatValue = 1.0,
    required this.onChanged,
    this.valueFormatter,
    this.activeColor,
    this.isPercentage = false,
    this.displayMultiplier = 1.0,
    this.size = 60.0,
  });

  @override
  State<ModernAudioKnob> createState() => _ModernAudioKnobState();
}

class _ModernAudioKnobState extends State<ModernAudioKnob> {
  Color get primaryColor => context.primaryColor;

  void _onVerticalDragUpdate(DragUpdateDetails details) {
    // dragging up (negative dy) increases value
    double sensitivity = (widget.max - widget.min) / 150.0;
    double newValue = widget.value - (details.delta.dy * sensitivity);
    newValue = newValue.clamp(widget.min, widget.max);
    if ((newValue - widget.value).abs() > 0.001) {
      widget.onChanged(newValue);
    }
  }

  void _showValueDialog(BuildContext context, double dbValue) {
    String initialText = widget.value.toStringAsFixed(2);
    double effectiveMultiplier =
        widget.isPercentage ? 100.0 : widget.displayMultiplier;
    int decimals = widget.isPercentage ? 0 : 1;

    if (widget.isPercentage || widget.displayMultiplier != 1.0) {
      initialText =
          (widget.value * effectiveMultiplier).toStringAsFixed(decimals);
    } else if (widget.valueFormatter == null) {
      initialText = dbValue.toStringAsFixed(2);
    }

    final controller = TextEditingController(text: initialText);

    double displayMin = widget.min;
    double displayMax = widget.max;
    if (widget.isPercentage || widget.displayMultiplier != 1.0) {
      displayMin = widget.min * effectiveMultiplier;
      displayMax = widget.max * effectiveMultiplier;
    } else if (widget.valueFormatter == null) {
      displayMin = -24.0;
      displayMax = 24.0;
    }

    String displayMinStr = displayMin.toStringAsFixed(decimals);
    String displayMaxStr = displayMax.toStringAsFixed(decimals);
    if (widget.valueFormatter == null &&
        !widget.isPercentage &&
        widget.displayMultiplier == 1.0) {
      displayMinStr = displayMin.toStringAsFixed(1);
      displayMaxStr = displayMax.toStringAsFixed(1);
    }

    final accentColor = widget.activeColor ?? primaryColor;

    M3EDialog.show<void>(
      context,
      dialog: M3EDialog(
        title: 'Adjust ${widget.label}',
        topDivider: true,
        bottomDivider: true,
        content: Material(
          color: Colors.transparent,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Center(
                    child:
                        Icon(Icons.tune_rounded, size: 16, color: accentColor),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          widget.label,
                          style: const TextStyle(
                            color: Colors.white,
                            fontWeight: FontWeight.bold,
                            fontSize: 14,
                          ),
                        ),
                        Text(
                          'Allowed range: $displayMinStr to $displayMaxStr',
                          style: TextStyle(
                            color: Colors.white.withValues(alpha: 0.6),
                            fontSize: 11.5,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 16),
              M3ETextField(
                controller: controller,
                label: 'Target Value',
              ),
            ],
          ),
        ),
        actions: [
          M3EButton(
            onPressed: () {
              widget.onChanged(widget.flatValue);
              Navigator.pop(context);
            },
            child: const Text('Reset Flat'),
          ),
          M3EButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          M3EButton(
            onPressed: () {
              final val = double.tryParse(controller.text);
              if (val != null) {
                if (widget.isPercentage || widget.displayMultiplier != 1.0) {
                  widget.onChanged((val / effectiveMultiplier)
                      .clamp(widget.min, widget.max));
                } else if (widget.valueFormatter == null) {
                  double linear = math.pow(10, val / 20).toDouble();
                  widget.onChanged(linear.clamp(widget.min, widget.max));
                } else {
                  widget.onChanged(val.clamp(widget.min, widget.max));
                }
              }
              Navigator.pop(context);
            },
            child: const Text('Apply'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    double normalizedValue =
        (widget.value - widget.min) / (widget.max - widget.min);

    String displayValue;
    double dbValue = 0.0;
    if (widget.valueFormatter != null) {
      displayValue = widget.valueFormatter!(widget.value);
    } else {
      dbValue =
          20 * math.log(widget.value == 0 ? 0.0001 : widget.value) / math.ln10;
      dbValue = dbValue.clamp(-24.0, 24.0);
      displayValue =
          '${dbValue > 0 ? '+' : ''}${dbValue.toStringAsFixed(1)} dB';
    }

    final accentColor = widget.activeColor ?? primaryColor;

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        RepaintBoundary(
          child: GestureDetector(
            onVerticalDragUpdate: _onVerticalDragUpdate,
            onDoubleTap: () => widget.onChanged(widget.flatValue),
            onLongPress: () => _showValueDialog(context, dbValue),
            child: CustomPaint(
              size: Size(widget.size, widget.size),
              painter: _KnobPainter(
                normalizedValue: normalizedValue,
                activeColor: accentColor,
                inactiveColor: Colors.white.withValues(alpha: 0.1),
              ),
            ),
          ),
        ),
        const SizedBox(height: 8),
        Text(
          widget.label,
          style: TextStyle(
            color: Colors.white.withValues(alpha: 0.8),
            fontSize: 11,
            fontWeight: FontWeight.bold,
            letterSpacing: 0.5,
          ),
        ),
        const SizedBox(height: 4),
        GestureDetector(
          onTap: () => _showValueDialog(context, dbValue),
          child: Padding(
            padding: EdgeInsets.symmetric(
              horizontal: widget.size < 60 ? 5 : 8,
            ),
            child: Center(
              child: Text(
                displayValue,
                style: TextStyle(
                  color: accentColor,
                  fontSize: widget.size < 60 ? 9.5 : 10.5,
                  fontFamily: 'monospace',
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
          ),
          // ),
        ),
      ],
    );
  }
}

class _KnobPainter extends CustomPainter {
  final double normalizedValue;
  final Color activeColor;
  final Color inactiveColor;

  _KnobPainter({
    required this.normalizedValue,
    required this.activeColor,
    required this.inactiveColor,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    final radius = math.min(size.width, size.height) / 2;

    // 1. Ambient Drop Shadow underneath the knob
    final shadowRadius = radius - (size.width * 0.03);
    final shadowPaint = Paint()
      ..color = Colors.black.withValues(alpha: 0.5)
      ..maskFilter = MaskFilter.blur(BlurStyle.normal, size.width * 0.08);
    canvas.drawCircle(
      center + Offset(0, size.width * 0.04),
      shadowRadius,
      shadowPaint,
    );

    // 2. Beveled Outer Collar / Chassis
    final outerRadius = radius - 1.5;
    final innerRadius = outerRadius * 0.77;
    final outerRect = Rect.fromCircle(center: center, radius: outerRadius);

    // Slanted 3D metallic bevel gradient (top-right highlight to bottom-left shadow)
    final bevelPaint = Paint()
      ..shader = const LinearGradient(
        begin: Alignment(0.3, -1.0),
        end: Alignment(-0.3, 1.0),
        colors: [
          Color(0xFF5A5E66), // Top/top-right metallic highlight
          Color(0xFF45484F),
          Color(0xFF2E3035),
          Color(0xFF1E2023),
          Color(0xFF141517), // Deep bottom-left shadow
        ],
        stops: [0.0, 0.22, 0.50, 0.78, 1.0],
      ).createShader(outerRect);
    canvas.drawCircle(center, outerRadius, bevelPaint);

    // Outer rim stroke highlight/shadow
    final outerRimPaint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.0
      ..shader = const LinearGradient(
        begin: Alignment(0.2, -1.0),
        end: Alignment(-0.2, 1.0),
        colors: [
          Color(0xFF6C717A), // Top rim sheen
          Color(0xFF383A3F),
          Color(0xFF141517), // Bottom rim shadow
        ],
      ).createShader(outerRect);
    canvas.drawCircle(center, outerRadius, outerRimPaint);

    // 3. Recessed Inner Face / Dish
    final innerRect = Rect.fromCircle(center: center, radius: innerRadius);
    final dishPaint = Paint()
      ..shader = const LinearGradient(
        begin: Alignment(0.0, -1.0),
        end: Alignment(0.0, 1.0),
        colors: [
          Color(0xFF3A3C42), // Top illuminated gunmetal
          Color(0xFF2C2E33),
          Color(0xFF1E2023),
          Color(0xFF151618), // Deep matte charcoal bottom
        ],
        stops: [0.0, 0.32, 0.68, 1.0],
      ).createShader(innerRect);
    canvas.drawCircle(center, innerRadius - 0.5, dishPaint);

    // Inner shadow at the top of the recessed dish (shadow cast by collar)
    canvas.save();
    canvas.clipPath(
      Path()
        ..addOval(
          Rect.fromCircle(center: center, radius: innerRadius - 0.5),
        ),
    );
    final innerTopShadowPaint = Paint()
      ..shader = LinearGradient(
        begin: Alignment.topCenter,
        end: const Alignment(0.0, -0.15),
        colors: [
          Colors.black.withValues(alpha: 0.85),
          Colors.black.withValues(alpha: 0.0),
        ],
      ).createShader(innerRect);
    canvas.drawRect(innerRect, innerTopShadowPaint);
    canvas.restore();

    // 4. Inner Socket Crease and Bottom Reflection Ring
    final innerCreasePaint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.6
      ..color = const Color(0xFF090A0C);
    canvas.drawCircle(center, innerRadius, innerCreasePaint);

    final innerRimHighlightPaint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.0
      ..shader = LinearGradient(
        begin: Alignment.topCenter,
        end: Alignment.bottomCenter,
        colors: [
          Colors.transparent,
          Colors.white.withValues(alpha: 0.16),
        ],
      ).createShader(innerRect);
    canvas.drawArc(
      innerRect,
      0.0,
      math.pi,
      false,
      innerRimHighlightPaint,
    );

    // 5. Indicator Needle / Pointer
    final startAngle = math.pi * 0.75;
    final sweepAngle = math.pi * 1.5;
    final clampedNorm = normalizedValue.clamp(0.0, 1.0);
    final currentAngle = startAngle + (sweepAngle * clampedNorm);

    final outerTickR = innerRadius - (size.width * 0.02);
    final innerTickR = innerRadius * 0.50;

    final outerPt = Offset(
      center.dx + outerTickR * math.cos(currentAngle),
      center.dy + outerTickR * math.sin(currentAngle),
    );
    final innerPt = Offset(
      center.dx + innerTickR * math.cos(currentAngle),
      center.dy + innerTickR * math.sin(currentAngle),
    );

    final strokeWidth = math.max(2.4, size.width * 0.045);

    // Needle soft glow pass
    final glowPaint = Paint()
      ..color = activeColor.withValues(alpha: 0.45)
      ..strokeWidth = strokeWidth + 2.2
      ..strokeCap = StrokeCap.round
      ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 2.0);
    canvas.drawLine(innerPt, outerPt, glowPaint);

    // Needle sharp neon bar pass
    final needlePaint = Paint()
      ..color = activeColor
      ..strokeWidth = strokeWidth
      ..strokeCap = StrokeCap.round;
    canvas.drawLine(innerPt, outerPt, needlePaint);
  }

  @override
  bool shouldRepaint(covariant _KnobPainter oldDelegate) {
    return oldDelegate.normalizedValue != normalizedValue ||
        oldDelegate.activeColor != activeColor ||
        oldDelegate.inactiveColor != inactiveColor;
  }
}

class _CollapsibleSection extends StatelessWidget {
  final Widget icon;
  final String title;
  final String subtitle;
  final bool isEnabled;
  final ValueChanged<bool>? onToggle;
  final List<Widget> children;

  const _CollapsibleSection({
    required this.icon,
    required this.title,
    required this.subtitle,
    this.isEnabled = false,
    this.onToggle,
    required this.children,
  });

  @override
  Widget build(BuildContext context) {
    final primaryColor = context.primaryColor;
    final cardColor = context.cardDark;

    return Container(
      width: double.infinity,
      decoration: BoxDecoration(
        color: cardColor,
        borderRadius: BorderRadius.circular(16),
        /* border: Border.all(
          color: isEnabled
              ? primaryColor.withValues(alpha: 0.35)
              : Colors.white.withValues(alpha: 0.08),
        ),*/
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          // Header Bar
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
            child: Row(
              children: [
                icon,
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        title,
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 16,
                          fontWeight: FontWeight.bold,
                          letterSpacing: -0.2,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        subtitle,
                        style: TextStyle(
                          color: isEnabled
                              ? primaryColor.withValues(alpha: 0.9)
                              : Colors.white54,
                          fontSize: 12,
                        ),
                      ),
                    ],
                  ),
                ),
                if (onToggle != null) ...[
                  const SizedBox(width: 8),
                  M3ESwitch(
                    selectedIcon: Icon(Icons.check, color: primaryColor),
                    value: isEnabled,
                    onChanged: onToggle,
                  ),
                ],
              ],
            ),
          ),
          const Divider(color: Colors.white12, height: 1),
          // Directly display controls without any expander
          Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: children,
            ),
          ),
        ],
      ),
    );
  }
}
