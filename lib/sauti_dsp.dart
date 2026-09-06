import 'dart:ffi' as ffi;
import 'dart:typed_data';
import 'package:ffi/ffi.dart';
import 'audio_engine_ffi.dart';

/// Audio Clarity DSP profiles.
enum AudioClarityProfile {
  transientCrisp(0),
  airShelf(1),
  presenceExciter(2),
  harmonicBrilliance(3);

  final int value;
  const AudioClarityProfile(this.value);
}

/// Dynamic Bass & Subwoofer DSP profiles.
enum HarmonicBassProfile {
  naturalBass(0),
  pureBass(1),
  subwoofer(2),
  harmonicExciter(3),
  pultecDeep(4),
  dynamicMultiPole(5);

  // Backward-compatible aliases
  static const HarmonicBassProfile subBassResonant = naturalBass;
  static const HarmonicBassProfile punchyBass = pureBass;

  final int value;
  const HarmonicBassProfile(this.value);
}

/// 19 Pre-tuned hardware & acoustic Dynamic Bass presets.
enum DynamicBassPreset {
  smoothNaturalSub(0, 'Smooth Natural Sub'),
  punchyInEar(1, 'Punchy In-Ear'),
  warmOverEar(2, 'Warm Over-Ear'),
  deepAcoustic(3, 'Deep Acoustic'),
  wideDynamic(4, 'Wide Dynamic'),
  subBassBoom(5, 'Sub-Bass Boom'),
  tightSub(6, 'Tight Sub'),
  solidImpact(7, 'Solid Impact'),
  cleanKick(8, 'Clean Kick'),
  richLowEnd(9, 'Rich Low-End'),
  clubPaPunch(10, 'Club PA Punch'),
  bassheadHeavy(11, 'Basshead Heavy'),
  resonantRumble(12, 'Resonant Rumble'),
  cinemaSub(13, 'Cinema Sub'),
  carAudioSlam(14, 'Car Audio Slam'),
  audiophileReference(15, 'Audiophile Reference'),
  studioMonitorLows(16, 'Studio Monitor Lows'),
  deepSubExtension(17, 'Deep Sub Extension'),
  ultimateSubwoofer(18, 'Ultimate Subwoofer');

  final int value;
  final String label;
  const DynamicBassPreset(this.value, this.label);
}

/// Dynamic Transducer profiles.
enum TransducerProfile {
  earphone(0, 'Earbuds'), // friendly naming
  headphone(1, 'Headphones'),
  highEndReference(2, 'Reference'),
  speakerMonitor(3, 'Speakers'),
  extremeSubwoofer(4, 'Subwoofer'),
  pureDynamic(5, 'Pure'),
  audiophileReference(6, 'Audiophile'),
  studioMonitorLows(7, 'Monitors'),
  cinemaSubSlam(8, 'Cinema'),
  carAudioBass(9, 'Car'),
  deepAcousticWarmth(10, 'Acoustic'),
  cleanKickDrum(11, 'Kick'),
  resonantRumble(12, 'Resonant'),
  subBassBoom(13, 'Sub-Bass'),
  solidImpact(14, 'Solid'),
  richLowEnd(15, 'Rich'),
  clubPAPunch(16, 'Club'),
  deepSubExtension(17, 'Deep'),
  ultimateSubwoofer(18, 'Ultimate');

  final int value;
  final String label;
  const TransducerProfile(this.value, [this.label = '']);
}

/// Analog Warmth profiles.
enum AnalogWarmthProfile {
  triode12AX7(0),
  magneticTape(1),
  vintagePreamp(2);

  final int value;
  const AnalogWarmthProfile(this.value);
}

/// Dialogue Booster & Enhancer profiles (reconstructed from Dolby DAP).
enum DialogEnhancerProfile {
  cinema(0, 'Cinema'),
  music(1, 'Music'),
  voice(2, 'Voice'),
  night(3, 'Night'),
  custom(4, 'Custom');

  final int value;
  final String label;
  const DialogEnhancerProfile(this.value, [this.label = '']);
}

/// De-Esser operating modes.
enum DeEsserMode {
  splitBand(0),
  wideBand(1);

  final int value;
  const DeEsserMode(this.value);
}

/// De-Esser presets.
enum DeEsserPreset {
  gentleVocal(0),
  aggressiveSibilance(1),
  vintageWideband(2),
  podcastSpeech(3),
  custom(4);

  final int value;
  const DeEsserPreset(this.value);
}

/// Downward Expander & Noise Floor Reducer presets.
enum DownwardExpanderPreset {
  vinylClean(0),
  tapeHiss(1),
  gentleExpansion(2),
  dynamicGate(3),
  custom(4);

  final int value;
  const DownwardExpanderPreset(this.value);
}

/// Spatial Surround suite modes.
enum SurroundMode {
  off(0),
  matrixSurround(1), // Cinema Matrix 5.1 (Pro Logic II cleanroom)
  binauralVirtualizer(2), // Reconstructed from Dolby analysis_dlby2
  acousticStage(3); // Reconstructed from AM3D Zirene re_workspace

  final int value;
  const SurroundMode(this.value);

  // Backward-compatibility aliases
  static const SurroundMode matrix51Hrtf = SurroundMode.matrixSurround;
  static const SurroundMode fieldExpander = SurroundMode.acousticStage;
  static const SurroundMode differentialHaas = SurroundMode.acousticStage;
  static const SurroundMode viperHeadphone = SurroundMode.binauralVirtualizer;
}

// Native FFI Typedefs
typedef _DspSetEnabledNative = ffi.Void Function(
    ffi.Pointer<ffi.Void>, ffi.Int32);
typedef _DspSetEnabledDart = void Function(ffi.Pointer<ffi.Void>, int);

typedef _DspSetSurroundModeNative = ffi.Void Function(
    ffi.Pointer<ffi.Void>, ffi.Int32);
typedef _DspSetSurroundModeDart = void Function(ffi.Pointer<ffi.Void>, int);

typedef _DspSetClarityParamsNative = ffi.Void Function(
    ffi.Pointer<ffi.Void>, ffi.Int32, ffi.Float);
typedef _DspSetClarityParamsDart = void Function(
    ffi.Pointer<ffi.Void>, int, double);

typedef _DspSetBassParamsNative = ffi.Void Function(
    ffi.Pointer<ffi.Void>, ffi.Int32, ffi.Float, ffi.Float);
typedef _DspSetBassParamsDart = void Function(
    ffi.Pointer<ffi.Void>, int, double, double);

typedef _DspSetDynamicBassParamsNative = ffi.Void Function(
    ffi.Pointer<ffi.Void>, ffi.Int32, ffi.Float);
typedef _DspSetDynamicBassParamsDart = void Function(
    ffi.Pointer<ffi.Void>, int, double);

typedef _DspSetDynamicSystemParamsNative = ffi.Void Function(
    ffi.Pointer<ffi.Void>, ffi.Int32, ffi.Float);
typedef _DspSetDynamicSystemParamsDart = void Function(
    ffi.Pointer<ffi.Void>, int, double);

typedef _DspSetDynamicSystemCustomParamsNative = ffi.Void Function(
    ffi.Pointer<ffi.Void>,
    ffi.Float,
    ffi.Float,
    ffi.Float,
    ffi.Float,
    ffi.Float,
    ffi.Float,
    ffi.Float);
typedef _DspSetDynamicSystemCustomParamsDart = void Function(
    ffi.Pointer<ffi.Void>,
    double,
    double,
    double,
    double,
    double,
    double,
    double);

typedef _DspSetAnalogWarmthParamsNative = ffi.Void Function(
    ffi.Pointer<ffi.Void>, ffi.Int32, ffi.Float);
typedef _DspSetAnalogWarmthParamsDart = void Function(
    ffi.Pointer<ffi.Void>, int, double);

typedef _DspSetDialogEnhancerParamsNative = ffi.Void Function(
    ffi.Pointer<ffi.Void>,
    ffi.Int32,
    ffi.Float,
    ffi.Float,
    ffi.Float,
    ffi.Float);
typedef _DspSetDialogEnhancerParamsDart = void Function(
    ffi.Pointer<ffi.Void>, int, double, double, double, double);

typedef _DspGetDialogEnhancerGainReductionDbNative = ffi.Float Function(
    ffi.Pointer<ffi.Void>);
typedef _DspGetDialogEnhancerGainReductionDbDart = double Function(
    ffi.Pointer<ffi.Void>);

typedef _DspSetDeEsserPresetNative = ffi.Void Function(
    ffi.Pointer<ffi.Void>, ffi.Int32);
typedef _DspSetDeEsserPresetDart = void Function(ffi.Pointer<ffi.Void>, int);

typedef _DspSetDeEsserParamsNative = ffi.Void Function(
    ffi.Pointer<ffi.Void>, ffi.Int32, ffi.Float);
typedef _DspSetDeEsserParamsDart = void Function(
    ffi.Pointer<ffi.Void>, int, double);

typedef _DspSetDeEsserParamsExNative = ffi.Void Function(
    ffi.Pointer<ffi.Void>,
    ffi.Int32,
    ffi.Float,
    ffi.Float,
    ffi.Float,
    ffi.Float,
    ffi.Float,
    ffi.Float);
typedef _DspSetDeEsserParamsExDart = void Function(
    ffi.Pointer<ffi.Void>, int, double, double, double, double, double, double);

typedef _DspGetDeEsserGainReductionDbNative = ffi.Float Function(
    ffi.Pointer<ffi.Void>);
typedef _DspGetDeEsserGainReductionDbDart = double Function(
    ffi.Pointer<ffi.Void>);

typedef _DspSetExpanderPresetNative = ffi.Void Function(
    ffi.Pointer<ffi.Void>, ffi.Int32);
typedef _DspSetExpanderPresetDart = void Function(ffi.Pointer<ffi.Void>, int);

typedef _DspSetExpanderParamsNative = ffi.Void Function(ffi.Pointer<ffi.Void>,
    ffi.Float, ffi.Float, ffi.Float, ffi.Float, ffi.Float);
typedef _DspSetExpanderParamsDart = void Function(
    ffi.Pointer<ffi.Void>, double, double, double, double, double);

typedef _DspSetExpanderParamsExNative = ffi.Void Function(
    ffi.Pointer<ffi.Void>,
    ffi.Float,
    ffi.Float,
    ffi.Float,
    ffi.Float,
    ffi.Float,
    ffi.Float,
    ffi.Float);
typedef _DspSetExpanderParamsExDart = void Function(ffi.Pointer<ffi.Void>,
    double, double, double, double, double, double, double);

typedef _DspGetExpanderGainReductionDbNative = ffi.Float Function(
    ffi.Pointer<ffi.Void>);
typedef _DspGetExpanderGainReductionDbDart = double Function(
    ffi.Pointer<ffi.Void>);

typedef _DspLoadConvolverIrNative = ffi.Int32 Function(
    ffi.Pointer<ffi.Void>, ffi.Pointer<ffi.Float>, ffi.Int32, ffi.Int32);
typedef _DspLoadConvolverIrDart = int Function(
    ffi.Pointer<ffi.Void>, ffi.Pointer<ffi.Float>, int, int);

typedef _DspClearConvolverIrNative = ffi.Void Function(ffi.Pointer<ffi.Void>);
typedef _DspClearConvolverIrDart = void Function(ffi.Pointer<ffi.Void>);

typedef _DspSetConvolverMixNative = ffi.Void Function(
    ffi.Pointer<ffi.Void>, ffi.Float, ffi.Float);
typedef _DspSetConvolverMixDart = void Function(
    ffi.Pointer<ffi.Void>, double, double);

typedef _DspSetMasterLimiterParamsNative = ffi.Void Function(
    ffi.Pointer<ffi.Void>, ffi.Float, ffi.Float, ffi.Float);
typedef _DspSetMasterLimiterParamsDart = void Function(
    ffi.Pointer<ffi.Void>, double, double, double);

typedef _DspResetNative = ffi.Void Function(ffi.Pointer<ffi.Void>);
typedef _DspResetDart = void Function(ffi.Pointer<ffi.Void>);

typedef _DspHasConvolverIrNative = ffi.Int32 Function(ffi.Pointer<ffi.Void>);
typedef _DspHasConvolverIrDart = int Function(ffi.Pointer<ffi.Void>);

typedef _DspGetConvolverKernelLengthNative = ffi.Int32 Function(
    ffi.Pointer<ffi.Void>);
typedef _DspGetConvolverKernelLengthDart = int Function(ffi.Pointer<ffi.Void>);

typedef _DspGetLimiterGainReductionDbNative = ffi.Float Function(
    ffi.Pointer<ffi.Void>);
typedef _DspGetLimiterGainReductionDbDart = double Function(
    ffi.Pointer<ffi.Void>);

typedef _DspSetSurroundParamsNative = ffi.Void Function(
    ffi.Pointer<ffi.Void>, ffi.Float, ffi.Float, ffi.Float, ffi.Float);
typedef _DspSetSurroundParamsDart = void Function(
    ffi.Pointer<ffi.Void>, double, double, double, double);

typedef _DspSetSurroundMatrixParamsNative = ffi.Void Function(
    ffi.Pointer<ffi.Void>, ffi.Float, ffi.Float, ffi.Float, ffi.Float);
typedef _DspSetSurroundMatrixParamsDart = void Function(
    ffi.Pointer<ffi.Void>, double, double, double, double);

typedef _DspSetSurroundBinauralParamsNative = ffi.Void Function(
    ffi.Pointer<ffi.Void>,
    ffi.Int32,
    ffi.Float,
    ffi.Int32,
    ffi.Float,
    ffi.Int32,
    ffi.Float);
typedef _DspSetSurroundBinauralParamsDart = void Function(
    ffi.Pointer<ffi.Void>, int, double, int, double, int, double);

typedef _DspSetSurroundStageParamsNative = ffi.Void Function(
    ffi.Pointer<ffi.Void>,
    ffi.Int32,
    ffi.Int32,
    ffi.Float,
    ffi.Float,
    ffi.Float,
    ffi.Float,
    ffi.Float);
typedef _DspSetSurroundStageParamsDart = void Function(
    ffi.Pointer<ffi.Void>, int, int, double, double, double, double, double);

typedef _DspSetSurroundParamsExNative = ffi.Void Function(
    ffi.Pointer<ffi.Void>,
    ffi.Float,
    ffi.Float,
    ffi.Float,
    ffi.Float, // field: width, crossover, diffuser, bass anchor
    ffi.Float,
    ffi.Float,
    ffi.Float, // haas: delay, depth, damping
    ffi.Int32,
    ffi.Float,
    ffi.Float, // vhs: preset, reflection gain, damping
    ffi.Float,
    ffi.Float,
    ffi.Float,
    ffi.Float // matrix: center focus, boost, rear delay, head radius
    );
typedef _DspSetSurroundParamsExDart = void Function(
    ffi.Pointer<ffi.Void>,
    double,
    double,
    double,
    double,
    double,
    double,
    double,
    int,
    double,
    double,
    double,
    double,
    double,
    double);

/// Clean-room high-fidelity DSP suite for SautiFlow.
class SautiDsp {
  final ffi.DynamicLibrary _lib;
  final ffi.Pointer<ffi.Void> _enginePtr;

  late final _DspResetDart _reset;

  late final _DspSetEnabledDart _setClarityEnabled;
  late final _DspSetClarityParamsDart _setClarityParams;

  late final _DspSetEnabledDart _setBassEnabled;
  late final _DspSetBassParamsDart _setBassParams;

  late final _DspSetEnabledDart _setDynamicBassEnabled;
  late final _DspSetDynamicBassParamsDart _setDynamicBassParams;

  late final _DspSetEnabledDart _setDynamicSystemEnabled;
  late final _DspSetDynamicSystemParamsDart _setDynamicSystemParams;
  late final _DspSetDynamicSystemCustomParamsDart _setDynamicSystemCustomParams;

  late final _DspSetEnabledDart _setAnalogWarmthEnabled;
  late final _DspSetAnalogWarmthParamsDart _setAnalogWarmthParams;

  late final _DspSetEnabledDart _setDialogEnhancerEnabled;
  late final _DspSetDialogEnhancerParamsDart _setDialogEnhancerParams;
  late final _DspGetDialogEnhancerGainReductionDbDart
      _getDialogEnhancerGainReductionDb;

  late final _DspSetEnabledDart _setDeEsserEnabled;
  late final _DspSetDeEsserPresetDart _setDeEsserPreset;
  late final _DspSetDeEsserParamsDart _setDeEsserParams;
  late final _DspSetDeEsserParamsExDart _setDeEsserParamsEx;
  late final _DspGetDeEsserGainReductionDbDart _getDeEsserGainReductionDb;

  late final _DspSetEnabledDart _setExpanderEnabled;
  late final _DspSetExpanderPresetDart _setExpanderPreset;
  late final _DspSetExpanderParamsDart _setExpanderParams;
  late final _DspSetExpanderParamsExDart _setExpanderParamsEx;
  late final _DspGetExpanderGainReductionDbDart _getExpanderGainReductionDb;

  late final _DspSetEnabledDart _setConvolverEnabled;
  late final _DspLoadConvolverIrDart _loadConvolverIr;
  late final _DspClearConvolverIrDart _clearConvolverIr;
  late final _DspSetConvolverMixDart _setConvolverMix;
  late final _DspHasConvolverIrDart _hasConvolverIr;
  late final _DspGetConvolverKernelLengthDart _getConvolverKernelLength;

  late final _DspSetEnabledDart _setMasterLimiterEnabled;
  late final _DspSetMasterLimiterParamsDart _setMasterLimiterParams;
  late final _DspGetLimiterGainReductionDbDart _getLimiterGainReductionDb;

  late final _DspSetEnabledDart _setSurroundEnabled;
  late final _DspSetSurroundModeDart _setSurroundMode;
  late final _DspSetSurroundParamsDart _setSurroundParams;
  late final _DspSetSurroundMatrixParamsDart _setSurroundMatrixParams;
  late final _DspSetSurroundBinauralParamsDart _setSurroundBinauralParams;
  late final _DspSetSurroundStageParamsDart _setSurroundStageParams;
  late final _DspSetSurroundParamsExDart _setSurroundParamsEx;

  SautiDsp(this._lib, this._enginePtr) {
    _initFunctions();
  }

  SautiDsp.fromEngine(AudioEngineFFI engine)
      : _lib = engine.library,
        _enginePtr = engine.enginePointer {
    _initFunctions();
  }

  void _initFunctions() {
    _reset =
        _lib.lookupFunction<_DspResetNative, _DspResetDart>('ae_dsp_reset');

    _setClarityEnabled =
        _lib.lookupFunction<_DspSetEnabledNative, _DspSetEnabledDart>(
            'ae_dsp_set_clarity_enabled');
    _setClarityParams = _lib.lookupFunction<_DspSetClarityParamsNative,
        _DspSetClarityParamsDart>('ae_dsp_set_clarity_params');

    _setBassEnabled =
        _lib.lookupFunction<_DspSetEnabledNative, _DspSetEnabledDart>(
            'ae_dsp_set_bass_enabled');
    _setBassParams =
        _lib.lookupFunction<_DspSetBassParamsNative, _DspSetBassParamsDart>(
            'ae_dsp_set_bass_params');

    _setDynamicBassEnabled =
        _lib.lookupFunction<_DspSetEnabledNative, _DspSetEnabledDart>(
            'ae_set_dynamic_bass_enabled');
    _setDynamicBassParams = _lib.lookupFunction<_DspSetDynamicBassParamsNative,
        _DspSetDynamicBassParamsDart>('ae_set_dynamic_bass_params');

    _setDynamicSystemEnabled =
        _lib.lookupFunction<_DspSetEnabledNative, _DspSetEnabledDart>(
            'ae_dsp_set_dynamic_system_enabled');
    _setDynamicSystemParams = _lib.lookupFunction<
        _DspSetDynamicSystemParamsNative,
        _DspSetDynamicSystemParamsDart>('ae_dsp_set_dynamic_system_params');
    _setDynamicSystemCustomParams = _lib.lookupFunction<
            _DspSetDynamicSystemCustomParamsNative,
            _DspSetDynamicSystemCustomParamsDart>(
        'ae_dsp_set_dynamic_system_custom_params');

    _setAnalogWarmthEnabled =
        _lib.lookupFunction<_DspSetEnabledNative, _DspSetEnabledDart>(
            'ae_dsp_set_analog_warmth_enabled');
    _setAnalogWarmthParams = _lib.lookupFunction<
        _DspSetAnalogWarmthParamsNative,
        _DspSetAnalogWarmthParamsDart>('ae_dsp_set_analog_warmth_params');

    _setDialogEnhancerEnabled =
        _lib.lookupFunction<_DspSetEnabledNative, _DspSetEnabledDart>(
            'ae_dsp_set_dialog_enhancer_enabled');
    _setDialogEnhancerParams = _lib.lookupFunction<
        _DspSetDialogEnhancerParamsNative,
        _DspSetDialogEnhancerParamsDart>('ae_dsp_set_dialog_enhancer_params');
    _getDialogEnhancerGainReductionDb = _lib.lookupFunction<
            _DspGetDialogEnhancerGainReductionDbNative,
            _DspGetDialogEnhancerGainReductionDbDart>(
        'ae_dsp_get_dialog_enhancer_gain_reduction_db');

    _setDeEsserEnabled =
        _lib.lookupFunction<_DspSetEnabledNative, _DspSetEnabledDart>(
            'ae_dsp_set_de_esser_enabled');
    _setDeEsserPreset = _lib.lookupFunction<_DspSetDeEsserPresetNative,
        _DspSetDeEsserPresetDart>('ae_dsp_set_de_esser_preset');
    _setDeEsserParams = _lib.lookupFunction<_DspSetDeEsserParamsNative,
        _DspSetDeEsserParamsDart>('ae_dsp_set_de_esser_params');
    _setDeEsserParamsEx = _lib.lookupFunction<_DspSetDeEsserParamsExNative,
        _DspSetDeEsserParamsExDart>('ae_dsp_set_de_esser_params_ex');
    _getDeEsserGainReductionDb = _lib.lookupFunction<
            _DspGetDeEsserGainReductionDbNative,
            _DspGetDeEsserGainReductionDbDart>(
        'ae_dsp_get_de_esser_gain_reduction_db');

    _setExpanderEnabled =
        _lib.lookupFunction<_DspSetEnabledNative, _DspSetEnabledDart>(
            'ae_dsp_set_expander_enabled');
    _setExpanderPreset = _lib.lookupFunction<_DspSetExpanderPresetNative,
        _DspSetExpanderPresetDart>('ae_dsp_set_expander_preset');
    _setExpanderParams = _lib.lookupFunction<_DspSetExpanderParamsNative,
        _DspSetExpanderParamsDart>('ae_dsp_set_expander_params');
    _setExpanderParamsEx = _lib.lookupFunction<_DspSetExpanderParamsExNative,
        _DspSetExpanderParamsExDart>('ae_dsp_set_expander_params_ex');
    _getExpanderGainReductionDb = _lib.lookupFunction<
            _DspGetExpanderGainReductionDbNative,
            _DspGetExpanderGainReductionDbDart>(
        'ae_dsp_get_expander_gain_reduction_db');

    _setConvolverEnabled =
        _lib.lookupFunction<_DspSetEnabledNative, _DspSetEnabledDart>(
            'ae_dsp_set_convolver_enabled');
    _loadConvolverIr =
        _lib.lookupFunction<_DspLoadConvolverIrNative, _DspLoadConvolverIrDart>(
            'ae_dsp_load_convolver_ir');
    _clearConvolverIr = _lib.lookupFunction<_DspClearConvolverIrNative,
        _DspClearConvolverIrDart>('ae_dsp_clear_convolver_ir');
    _setConvolverMix =
        _lib.lookupFunction<_DspSetConvolverMixNative, _DspSetConvolverMixDart>(
            'ae_dsp_set_convolver_mix');
    _hasConvolverIr =
        _lib.lookupFunction<_DspHasConvolverIrNative, _DspHasConvolverIrDart>(
            'ae_dsp_has_convolver_ir');
    _getConvolverKernelLength = _lib.lookupFunction<
        _DspGetConvolverKernelLengthNative,
        _DspGetConvolverKernelLengthDart>('ae_dsp_get_convolver_kernel_length');

    _setMasterLimiterEnabled =
        _lib.lookupFunction<_DspSetEnabledNative, _DspSetEnabledDart>(
            'ae_dsp_set_master_limiter_enabled');
    _setMasterLimiterParams = _lib.lookupFunction<
        _DspSetMasterLimiterParamsNative,
        _DspSetMasterLimiterParamsDart>('ae_dsp_set_master_limiter_params');
    _getLimiterGainReductionDb = _lib.lookupFunction<
            _DspGetLimiterGainReductionDbNative,
            _DspGetLimiterGainReductionDbDart>(
        'ae_dsp_get_limiter_gain_reduction_db');

    _setSurroundEnabled =
        _lib.lookupFunction<_DspSetEnabledNative, _DspSetEnabledDart>(
            'ae_dsp_set_surround_enabled');
    _setSurroundMode =
        _lib.lookupFunction<_DspSetSurroundModeNative, _DspSetSurroundModeDart>(
            'ae_dsp_set_surround_mode');
    _setSurroundParams = _lib.lookupFunction<_DspSetSurroundParamsNative,
        _DspSetSurroundParamsDart>('ae_dsp_set_surround_params');
    _setSurroundMatrixParams = _lib.lookupFunction<
        _DspSetSurroundMatrixParamsNative,
        _DspSetSurroundMatrixParamsDart>('ae_dsp_set_surround_matrix_params');
    _setSurroundBinauralParams = _lib.lookupFunction<
            _DspSetSurroundBinauralParamsNative,
            _DspSetSurroundBinauralParamsDart>(
        'ae_dsp_set_surround_binaural_params');
    _setSurroundStageParams = _lib.lookupFunction<
        _DspSetSurroundStageParamsNative,
        _DspSetSurroundStageParamsDart>('ae_dsp_set_surround_stage_params');
    _setSurroundParamsEx = _lib.lookupFunction<_DspSetSurroundParamsExNative,
        _DspSetSurroundParamsExDart>('ae_dsp_set_surround_params_ex');
  }

  /// Reset all internal DSP buffers and history states.
  void reset() {
    if (_enginePtr == ffi.nullptr) return;
    _reset(_enginePtr);
  }

  /// Audio Clarity Engine.
  void setClarity(
      {required bool enabled,
      AudioClarityProfile profile = AudioClarityProfile.transientCrisp,
      double intensity = 0.5}) {
    if (_enginePtr == ffi.nullptr) return;
    _setClarityEnabled(_enginePtr, enabled ? 1 : 0);
    _setClarityParams(_enginePtr, profile.value, intensity);
  }

  /// Harmonic Bass Engine.
  void setHarmonicBass(
      {required bool enabled,
      HarmonicBassProfile profile = HarmonicBassProfile.subBassResonant,
      double cutoffHz = 60.0,
      double boost = 1.0}) {
    if (_enginePtr == ffi.nullptr) return;
    _setBassEnabled(_enginePtr, enabled ? 1 : 0);
    _setBassParams(_enginePtr, profile.value, cutoffHz, boost);
  }

  /// Dynamic Multi-Pole Resonant Bass with 19 pre-tuned hardware & acoustic presets.
  void setDynamicBass({
    required bool enabled,
    DynamicBassPreset preset = DynamicBassPreset.ultimateSubwoofer,
    double gainDb = 15.0,
  }) {
    if (_enginePtr == ffi.nullptr) return;
    _setDynamicBassEnabled(_enginePtr, enabled ? 1 : 0);
    _setDynamicBassParams(_enginePtr, preset.value, gainDb);
  }

  /// Dynamic Transducer Correction.
  void setDynamicSystem(
      {required bool enabled,
      TransducerProfile profile = TransducerProfile.earphone,
      double strength = 0.5}) {
    if (_enginePtr == ffi.nullptr) return;
    _setDynamicSystemEnabled(_enginePtr, enabled ? 1 : 0);
    _setDynamicSystemParams(_enginePtr, profile.value, strength);
  }

  /// Dynamic Transducer Custom Multi-Band Parameters.
  void setDynamicSystemCustom({
    required bool enabled,
    required double xLow,
    required double xHigh,
    required double yLow,
    required double yHigh,
    required double sideGainLow,
    required double sideGainHigh,
    required double bassGain,
  }) {
    if (_enginePtr == ffi.nullptr) return;
    _setDynamicSystemEnabled(_enginePtr, enabled ? 1 : 0);
    _setDynamicSystemCustomParams(
      _enginePtr,
      xLow,
      xHigh,
      yLow,
      yHigh,
      sideGainLow,
      sideGainHigh,
      bassGain,
    );
  }

  /// Analog Warmth (Triode Tube & Magnetic Tape saturation).
  void setAnalogWarmth(
      {required bool enabled,
      AnalogWarmthProfile profile = AnalogWarmthProfile.triode12AX7,
      double drive = 0.5}) {
    if (_enginePtr == ffi.nullptr) return;
    _setAnalogWarmthEnabled(_enginePtr, enabled ? 1 : 0);
    _setAnalogWarmthParams(_enginePtr, profile.value, drive);
  }

  /// Dialogue Booster & Background Noise Ducking Engine (reconstructed from Dolby DAP).
  void setDialogEnhancer({
    required bool enabled,
    DialogEnhancerProfile profile = DialogEnhancerProfile.cinema,
    double amount = 0.65,
    double ducking = 0.55,
    double clarity = 0.60,
    double centerFocus = 0.70,
  }) {
    if (_enginePtr == ffi.nullptr) return;
    _setDialogEnhancerEnabled(_enginePtr, enabled ? 1 : 0);
    _setDialogEnhancerParams(
        _enginePtr, profile.value, amount, ducking, clarity, centerFocus);
  }

  /// Returns current dynamic background ducking attenuation in dB (negative value or 0.0).
  double getDialogEnhancerGainReductionDb() {
    if (_enginePtr == ffi.nullptr) return 0.0;
    return _getDialogEnhancerGainReductionDb(_enginePtr);
  }

  /// Split-Band / Wideband De-Esser.
  void setDeEsser({
    required bool enabled,
    DeEsserMode mode = DeEsserMode.splitBand,
    double intensity = 0.5,
  }) {
    if (_enginePtr == ffi.nullptr) return;
    _setDeEsserEnabled(_enginePtr, enabled ? 1 : 0);
    _setDeEsserParams(_enginePtr, mode.value, intensity);
  }

  /// Sets De-Esser preset.
  void setDeEsserPreset(DeEsserPreset preset) {
    if (_enginePtr == ffi.nullptr) return;
    _setDeEsserPreset(_enginePtr, preset.value);
  }

  /// Full manual parameter tuning for De-Esser.
  void setDeEsserEx({
    required bool enabled,
    DeEsserMode mode = DeEsserMode.splitBand,
    double frequencyHz = 5500.0,
    double thresholdDb = -22.0,
    double ratio = 4.0,
    double maxReductionDb = 12.0,
    double attackMs = 1.0,
    double releaseMs = 35.0,
  }) {
    if (_enginePtr == ffi.nullptr) return;
    _setDeEsserEnabled(_enginePtr, enabled ? 1 : 0);
    _setDeEsserParamsEx(
      _enginePtr,
      mode.value,
      frequencyHz,
      thresholdDb,
      ratio,
      maxReductionDb,
      attackMs,
      releaseMs,
    );
  }

  /// Current real-time gain reduction of De-Esser in dB.
  double get deEsserGainReductionDb {
    if (_enginePtr == ffi.nullptr) return 0.0;
    return _getDeEsserGainReductionDb(_enginePtr);
  }

  /// Downward Expander & Adaptive Noise Floor Reducer (ideal for vinyl/tape rips).
  void setDownwardExpander({
    required bool enabled,
    DownwardExpanderPreset preset = DownwardExpanderPreset.vinylClean,
    double? thresholdDb,
    double? ratio,
    double? rangeDb,
    double? attackMs,
    double? releaseMs,
    double? kneeDb,
    double? sidechainHpfHz,
  }) {
    if (_enginePtr == ffi.nullptr) return;
    _setExpanderEnabled(_enginePtr, enabled ? 1 : 0);
    _setExpanderPreset(_enginePtr, preset.value);
    if (preset == DownwardExpanderPreset.custom ||
        thresholdDb != null ||
        ratio != null ||
        rangeDb != null ||
        attackMs != null ||
        releaseMs != null ||
        kneeDb != null ||
        sidechainHpfHz != null) {
      _setExpanderParamsEx(
        _enginePtr,
        thresholdDb ?? -52.0,
        ratio ?? 1.8,
        rangeDb ?? -16.0,
        attackMs ?? 12.0,
        releaseMs ?? 280.0,
        kneeDb ?? 6.0,
        sidechainHpfHz ?? 50.0,
      );
    }
  }

  /// Full manual parameter tuning for Downward Expander.
  void setDownwardExpanderEx({
    required bool enabled,
    double thresholdDb = -52.0,
    double ratio = 1.8,
    double rangeDb = -16.0,
    double attackMs = 12.0,
    double releaseMs = 280.0,
    double kneeDb = 6.0,
    double sidechainHpfHz = 50.0,
  }) {
    if (_enginePtr == ffi.nullptr) return;
    _setExpanderEnabled(_enginePtr, enabled ? 1 : 0);
    _setExpanderParamsEx(
      _enginePtr,
      thresholdDb,
      ratio,
      rangeDb,
      attackMs,
      releaseMs,
      kneeDb,
      sidechainHpfHz,
    );
  }

  /// Compact parameter setter for Downward Expander.
  void setDownwardExpanderParams({
    required bool enabled,
    double thresholdDb = -52.0,
    double ratio = 1.8,
    double rangeDb = -16.0,
    double attackMs = 12.0,
    double releaseMs = 280.0,
  }) {
    if (_enginePtr == ffi.nullptr) return;
    _setExpanderEnabled(_enginePtr, enabled ? 1 : 0);
    _setExpanderParams(
        _enginePtr, thresholdDb, ratio, rangeDb, attackMs, releaseMs);
  }

  /// Current real-time gain reduction of Downward Expander in dB.
  double get downwardExpanderGainReductionDb {
    if (_enginePtr == ffi.nullptr) return 0.0;
    return _getExpanderGainReductionDb(_enginePtr);
  }

  /// Partitioned FFT Impulse Response Convolver.
  bool loadImpulseResponse(Float32List samples, int channels) {
    if (_enginePtr == ffi.nullptr || samples.isEmpty) return false;
    final frameCount = samples.length ~/ channels;
    final ptr = calloc<ffi.Float>(samples.length);
    final typedList = ptr.asTypedList(samples.length);
    typedList.setAll(0, samples);
    try {
      final res = _loadConvolverIr(_enginePtr, ptr, frameCount, channels);
      return res == 1;
    } finally {
      calloc.free(ptr);
    }
  }

  void setConvolverEnabled(bool enabled) {
    if (_enginePtr == ffi.nullptr) return;
    _setConvolverEnabled(_enginePtr, enabled ? 1 : 0);
  }

  void clearImpulseResponse() {
    if (_enginePtr == ffi.nullptr) return;
    _clearConvolverIr(_enginePtr);
  }

  void setConvolverMix({double wet = 1.0, double dry = 0.0}) {
    if (_enginePtr == ffi.nullptr) return;
    _setConvolverMix(_enginePtr, wet, dry);
  }

  bool get hasImpulseResponse {
    if (_enginePtr == ffi.nullptr) return false;
    return _hasConvolverIr(_enginePtr) == 1;
  }

  int get convolverKernelLength {
    if (_enginePtr == ffi.nullptr) return 0;
    return _getConvolverKernelLength(_enginePtr);
  }

  /// Master Peak Limiter.
  void setMasterLimiter(
      {required bool enabled,
      double ceilingDb = -0.1,
      double outputGainDb = 0.0,
      double releaseMs = 60.0}) {
    if (_enginePtr == ffi.nullptr) return;
    _setMasterLimiterEnabled(_enginePtr, enabled ? 1 : 0);
    _setMasterLimiterParams(_enginePtr, ceilingDb, outputGainDb, releaseMs);
  }

  /// Sets master headroom trim in dB applied before the DSP processing chain.
  /// A negative value (e.g. -3.0 dB to -6.0 dB) provides clean headroom to prevent
  /// harmonic saturation or clipping when multiple DSP modules are active.
  void setMasterHeadroomTrimDb(double trimDb) {
    if (_enginePtr == ffi.nullptr) return;
    setMasterLimiter(enabled: true, ceilingDb: -0.1, outputGainDb: trimDb);
  }

  /// Get current limiter gain reduction in dB (for real-time meter display).
  double get limiterGainReductionDb {
    if (_enginePtr == ffi.nullptr) return 0.0;
    return _getLimiterGainReductionDb(_enginePtr);
  }

  /// Spatial Surround Suite.
  ///
  /// [mode] selects the algorithm:
  ///  - [SurroundMode.matrixSurround]: Cinema Matrix 5.1 (Pro Logic II cleanroom)
  ///  - [SurroundMode.binauralVirtualizer]: Dolby Headphone HRTF & Speaker Virtualizer
  ///  - [SurroundMode.acousticStage]: AM3D Zirene 3D Virtual Surround & M/S Expander
  void setSurround({
    required bool enabled,
    SurroundMode mode = SurroundMode.off,
    double fieldWidth = 1.4,
    int roomLevel = 2,
    double delayMs = 5.5,
    double centerFocus = 0.6,
  }) {
    if (_enginePtr == ffi.nullptr) return;
    _setSurroundEnabled(_enginePtr, enabled ? 1 : 0);
    _setSurroundMode(_enginePtr, mode.value);
    _setSurroundParams(
        _enginePtr, fieldWidth, roomLevel.toDouble(), delayMs, centerFocus);
  }

  /// Cinema Matrix 5.1 (Cleanroom Pro Logic II Dematrix -> Spherical HRTF).
  void setSurroundMatrix({
    required bool enabled,
    double centerFocus = 0.6,
    double surroundBoost = 1.2,
    double surroundDelayMs = 15.0,
    double headRadiusCm = 8.75,
  }) {
    if (_enginePtr == ffi.nullptr) return;
    _setSurroundEnabled(_enginePtr, enabled ? 1 : 0);
    _setSurroundMode(_enginePtr, SurroundMode.matrixSurround.value);
    _setSurroundMatrixParams(
      _enginePtr,
      centerFocus,
      surroundBoost,
      surroundDelayMs,
      headRadiusCm,
    );
  }

  /// Binaural HRTF Virtualizer (Reconstructed from Dolby analysis_dlby2).
  ///
  /// [mode]: 0 for Headphone HRTF, 1 for Speaker Field.
  /// [roomPreset]: 1 for Studio, 2 for Cinema, 3 for Concert Hall.
  /// [speakerAngle]: 0 for Narrow (10 deg), 1 for Standard (30 deg), 2 for Wide (45 deg).
  void setSurroundBinaural({
    required bool enabled,
    int mode = 0,
    double boost = 0.65,
    int roomPreset = 2,
    double roomMix = 0.35,
    int speakerAngle = 1,
    double shadowCutoffHz = 3500.0,
  }) {
    if (_enginePtr == ffi.nullptr) return;
    _setSurroundEnabled(_enginePtr, enabled ? 1 : 0);
    _setSurroundMode(_enginePtr, SurroundMode.binauralVirtualizer.value);
    _setSurroundBinauralParams(
      _enginePtr,
      mode,
      boost,
      roomPreset,
      roomMix,
      speakerAngle,
      shadowCutoffHz,
    );
  }

  /// 3D Acoustic Stage (Reconstructed from AM3D Zirene re_workspace).
  ///
  /// [profile]: 0 for Headset, 1 for Speaker.
  /// [mode]: 0 for Studio (Normal), 1 for Panoramic (Wide).
  void setSurroundStage({
    required bool enabled,
    int profile = 0,
    int mode = 0,
    double width = 1.2,
    double depth = 0.5,
    double cancellation = 0.60,
    double airPresence = 0.40,
    double bassAnchorHz = 60.0,
  }) {
    if (_enginePtr == ffi.nullptr) return;
    _setSurroundEnabled(_enginePtr, enabled ? 1 : 0);
    _setSurroundMode(_enginePtr, SurroundMode.acousticStage.value);
    _setSurroundStageParams(
      _enginePtr,
      profile,
      mode,
      width,
      depth,
      cancellation,
      airPresence,
      bassAnchorHz,
    );
  }

  /// Full per-algorithm surround tuning.
  void setSurroundEx({
    required bool enabled,
    required SurroundMode mode,
    double fieldWidth = 1.4,
    double fieldCrossoverHz = 160.0,
    double fieldDiffuserMix = 0.5,
    double bassAnchor = 0.9,
    double haasDelayMs = 5.5,
    double haasDepth = 0.4,
    double haasDampingHz = 5000.0,
    int vhsRoomPreset = 2,
    double vhsReflectionGain = 0.45,
    double vhsDamping = 0.25,
    double centerFocus = 0.6,
    double surroundBoost = 1.2,
    double surroundDelayMs = 15.0,
    double headRadiusCm = 8.75,
  }) {
    if (_enginePtr == ffi.nullptr) return;
    _setSurroundEnabled(_enginePtr, enabled ? 1 : 0);
    _setSurroundMode(_enginePtr, mode.value);
    _setSurroundParamsEx(
      _enginePtr,
      fieldWidth,
      fieldCrossoverHz,
      fieldDiffuserMix,
      bassAnchor,
      haasDelayMs,
      haasDepth,
      haasDampingHz,
      vhsRoomPreset.clamp(1, 5),
      vhsReflectionGain,
      vhsDamping,
      centerFocus,
      surroundBoost,
      surroundDelayMs,
      headRadiusCm,
    );
  }
}
