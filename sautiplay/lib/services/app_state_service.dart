import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../streaming_service.dart';

/// Centralized service for persisting and restoring all app state across
/// restarts: playback queue, EQ settings, and user preferences/settings.

enum ReplayGainMode {
  none,
  track,
  album
}
class AppStateService {
  AppStateService._() {
    loadUseWavySlider();
  }
  static final AppStateService instance = AppStateService._();

  // Stream to notify listeners of EQ changes
  final StreamController<void> eqSettingsChanged =
      StreamController<void>.broadcast();

  // Stream to notify listeners of ReplayGain changes
  final StreamController<void> replayGainChanged =
      StreamController<void>.broadcast();

  // Stream to notify listeners of Audio & Processing engine setting changes
  final StreamController<void> audioProcessingSettingsChanged =
      StreamController<void>.broadcast();

  // Stream to notify listeners of Waveform Seek Bar setting changes
  final StreamController<bool> useWaveformSeekBarChanged =
      StreamController<bool>.broadcast();

  // ValueNotifier to synchronously notify listeners of Wavy / Linear Seek Bar slider setting changes
  final ValueNotifier<bool> useWavySliderNotifier = ValueNotifier<bool>(true);

  // Stream to notify listeners of Wavy / Linear Seek Bar slider setting changes
  final StreamController<bool> useWavySliderChanged =
      StreamController<bool>.broadcast();

  // ─── Playback ───────────────────────────────────────────────────────────────
  static const _kQueueJson = 'sp_queue_json';
  static const _kQueueIndex = 'sp_queue_index';
  static const _kQueuePositionMs = 'sp_queue_position_ms';

  Future<void> saveQueue({
    required List<Map<String, dynamic>> tracks,
    required int index,
    required int positionMs,
  }) async {
    final prefs = await SharedPreferences.getInstance();
    final encoded = tracks.map((t) => jsonEncode(t)).toList();
    await prefs.setStringList(_kQueueJson, encoded);
    await prefs.setInt(_kQueueIndex, index);
    await prefs.setInt(_kQueuePositionMs, positionMs);
  }

  Future<({List<Map<String, dynamic>> tracks, int index, int positionMs})>
      loadQueue() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getStringList(_kQueueJson) ?? [];
    final tracks = raw
        .map<Map<String, dynamic>>((s) {
          try {
            return Map<String, dynamic>.from(jsonDecode(s) as Map);
          } catch (_) {
            return {};
          }
        })
        .where((m) => m.isNotEmpty)
        .toList();
    final index = prefs.getInt(_kQueueIndex) ?? 0;
    final positionMs = prefs.getInt(_kQueuePositionMs) ?? 0;
    return (tracks: tracks, index: index, positionMs: positionMs);
  }

  Future<void> clearQueue() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_kQueueJson);
    await prefs.remove(_kQueueIndex);
    await prefs.remove(_kQueuePositionMs);
  }

  // ─── EQ – Graphic EQ + Preamp ─────────────────────────────────────────────────
  static const _kEqEnabled = 'sp_eq_enabled';
  static const _kEqPreset = 'sp_eq_preset';
  static const _kEqGains = 'sp_eq_gains';
  static const _kPreampDb = 'sp_preamp_db';
  static const _kEqBandCount = 'sp_eq_band_count';

  Future<void> saveEqBands({
    required bool enabled,
    required String preset,
    required List<double> gains,
    required double preampDb,
    required int bandCount,
  }) async {
    final prefs = await SharedPreferences.getInstance();
    final prevBandCount = prefs.getInt(_kEqBandCount);

    await prefs.setBool(_kEqEnabled, enabled);
    await prefs.setString(_kEqPreset, preset);
    await prefs.setStringList(
        _kEqGains, gains.map((g) => g.toString()).toList());
    await prefs.setDouble(_kPreampDb, preampDb);
    await prefs.setInt(_kEqBandCount, bandCount);

    if (prevBandCount != null && prevBandCount != bandCount) {
      eqSettingsChanged.add(null);
    }
  }

  Future<
      ({
        bool enabled,
        String preset,
        List<double> gains,
        double preampDb,
        int bandCount
      })> loadEqBands() async {
    final prefs = await SharedPreferences.getInstance();
    final enabled = prefs.getBool(_kEqEnabled) ?? true;
    final preset = prefs.getString(_kEqPreset) ?? 'Flat';
    final bandCount = prefs.getInt(_kEqBandCount) ?? 10;

    final rawGains = prefs.getStringList(_kEqGains);
    final gains = rawGains != null
        ? rawGains.map((s) => double.tryParse(s) ?? 0.0).toList()
        : List<double>.filled(bandCount, 0.0);

    final preampDb = prefs.getDouble(_kPreampDb) ?? 0.0;

    return (
      enabled: enabled,
      preset: preset,
      gains: gains,
      preampDb: preampDb,
      bandCount: bandCount
    );
  }

  // ─── EQ – Spatial Audio / Reverb ──────────────────────────────────────────
  static const _kSpatialEnabled = 'sp_spatial_enabled';
  static const _kReverbMix = 'sp_reverb_mix';
  static const _kRoomSize = 'sp_room_size';
  static const _kEcho = 'sp_echo';

  Future<void> saveSpatialAudio({
    required bool enabled,
    required double reverbMix,
    required double roomSize,
    required double echo,
  }) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_kSpatialEnabled, enabled);
    await prefs.setDouble(_kReverbMix, reverbMix);
    await prefs.setDouble(_kRoomSize, roomSize);
    await prefs.setDouble(_kEcho, echo);
  }

  Future<({bool enabled, double reverbMix, double roomSize, double echo})>
      loadSpatialAudio() async {
    final prefs = await SharedPreferences.getInstance();
    return (
      enabled: prefs.getBool(_kSpatialEnabled) ?? false,
      reverbMix: prefs.getDouble(_kReverbMix) ?? 0.25,
      roomSize: prefs.getDouble(_kRoomSize) ?? 0.3,
      echo: prefs.getDouble(_kEcho) ?? 0.15,
    );
  }

  // ─── EQ – Delay / Echo ────────────────────────────────────────────────────
  static const _kDelayEnabled = 'sp_delay_enabled';
  static const _kDelayMix = 'sp_delay_mix';
  static const _kDelayFeedback = 'sp_delay_feedback';
  static const _kDelayTime = 'sp_delay_time';

  // ─── EQ – Stereo Widen ────────────────────────────────────────────────────
  static const _kStereoWidenEnabled = 'sp_stereo_widen_enabled';
  static const _kStereoWidenWidth = 'sp_stereo_widen_width';
  static const _kStereoWidenDelayMs = 'sp_stereo_widen_delay_ms';

  static const _kCrossfeedEnabled = 'sp_crossfeed_enabled';
  static const _kCrossfeedPreset = 'sp_crossfeed_preset';

  static const _kDynamicBassEnabled = 'sp_dynamic_bass_enabled';
  static const _kDynamicBassPreset = 'sp_dynamic_bass_preset';
  static const _kDynamicBassGain = 'sp_dynamic_bass_gain';

  Future<void> saveDelay({
    required bool enabled,
    required double mix,
    required double feedback,
    required double time,
  }) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_kDelayEnabled, enabled);
    await prefs.setDouble(_kDelayMix, mix);
    await prefs.setDouble(_kDelayFeedback, feedback);
    await prefs.setDouble(_kDelayTime, time);
  }

  Future<({bool enabled, double mix, double feedback, double time})>
      loadDelay() async {
    final prefs = await SharedPreferences.getInstance();
    return (
      enabled: prefs.getBool(_kDelayEnabled) ?? false,
      mix: prefs.getDouble(_kDelayMix) ?? 0.3,
      feedback: prefs.getDouble(_kDelayFeedback) ?? 0.4,
      time: prefs.getDouble(_kDelayTime) ?? 0.25,
    );
  }

  Future<void> saveStereoWiden({
    required bool enabled,
    required double width,
    required double delayMs,
  }) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_kStereoWidenEnabled, enabled);
    await prefs.setDouble(_kStereoWidenWidth, width);
    await prefs.setDouble(_kStereoWidenDelayMs, delayMs);
  }

  Future<({bool enabled, double width, double delayMs})>
      loadStereoWiden() async {
    final prefs = await SharedPreferences.getInstance();
    return (
      enabled: prefs.getBool(_kStereoWidenEnabled) ?? false,
      width: prefs.getDouble(_kStereoWidenWidth) ?? 1.5,
      delayMs: prefs.getDouble(_kStereoWidenDelayMs) ?? 15.0,
    );
  }

  // ─── EQ – JamesDSP Stereo Enhancement ──────────────────────────────────────────
  static const _kStereoEnhancementEnabled = 'sp_stereo_enhancement_enabled';
  static const _kStereoEnhancementMix = 'sp_stereo_enhancement_mix';

  Future<void> saveStereoEnhancement({
    required bool enabled,
    required double mix,
  }) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_kStereoEnhancementEnabled, enabled);
    await prefs.setDouble(_kStereoEnhancementMix, mix);
  }

  Future<({bool enabled, double mix})> loadStereoEnhancement() async {
    final prefs = await SharedPreferences.getInstance();
    return (
      enabled: prefs.getBool(_kStereoEnhancementEnabled) ?? false,
      mix: prefs.getDouble(_kStereoEnhancementMix) ?? 0.5,
    );
  }

  // ─── EQ – Reverb (Freeverb FDN) ───────────────────────────────────────────
  static const _kReverbExEnabled = 'sp_reverb_ex_enabled';
  static const _kReverbExPreset = 'sp_reverb_ex_preset';
  static const _kReverbExWet = 'sp_reverb_ex_wet';
  static const _kReverbExDry = 'sp_reverb_ex_dry';
  static const _kReverbExRoomSize = 'sp_reverb_ex_room_size';
  static const _kReverbExDamping = 'sp_reverb_ex_damping';
  static const _kReverbExPreDelayMs = 'sp_reverb_ex_pre_delay_ms';
  static const _kReverbExWidth = 'sp_reverb_ex_width';

  Future<void> saveReverb({
    required bool enabled,
    required String preset,
    required double wet,
    required double dry,
    required double roomSize,
    required double damping,
    required double preDelayMs,
    required double width,
  }) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_kReverbExEnabled, enabled);
    await prefs.setString(_kReverbExPreset, preset);
    await prefs.setDouble(_kReverbExWet, wet);
    await prefs.setDouble(_kReverbExDry, dry);
    await prefs.setDouble(_kReverbExRoomSize, roomSize);
    await prefs.setDouble(_kReverbExDamping, damping);
    await prefs.setDouble(_kReverbExPreDelayMs, preDelayMs);
    await prefs.setDouble(_kReverbExWidth, width);
  }

  Future<
      ({
        bool enabled,
        String preset,
        double wet,
        double dry,
        double roomSize,
        double damping,
        double preDelayMs,
        double width
      })> loadReverb() async {
    final prefs = await SharedPreferences.getInstance();
    return (
      enabled: prefs.getBool(_kReverbExEnabled) ?? false,
      preset: prefs.getString(_kReverbExPreset) ?? 'Custom',
      wet: prefs.getDouble(_kReverbExWet) ?? 0.18,
      dry: prefs.getDouble(_kReverbExDry) ?? 0.95,
      roomSize: prefs.getDouble(_kReverbExRoomSize) ?? 0.50,
      damping: prefs.getDouble(_kReverbExDamping) ?? 0.40,
      preDelayMs: prefs.getDouble(_kReverbExPreDelayMs) ?? 10.0,
      width: prefs.getDouble(_kReverbExWidth) ?? 1.0,
    );
  }

  static const _kRaceDelayMs = 'sp_race_delay_ms';
  static const _kRaceAlpha = 'sp_race_alpha';
  static const _kRaceLpfHz = 'sp_race_lpf_hz';

  static const _kCrossfeedAlgo = 'sp_crossfeed_algo';
  static const _kCrossfeedMix = 'sp_crossfeed_mix';
  static const _kCrossfeedDelay = 'sp_crossfeed_delay_ms';
  static const _kCrossfeedCutoff = 'sp_crossfeed_cutoff_hz';
  static const _kCrossfeedComp = 'sp_crossfeed_comp';

  Future<void> saveCrossfeed({
    required bool enabled,
    required int preset,
    int algoIndex = 2,
    double mix = 0.5,
    double delayMs = 0.40,
    double cutoffHz = 700.0,
    bool outputCompensation = true,
  }) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_kCrossfeedEnabled, enabled);
    await prefs.setInt(_kCrossfeedPreset, preset);
    await prefs.setInt(_kCrossfeedAlgo, algoIndex);
    await prefs.setDouble(_kCrossfeedMix, mix);
    await prefs.setDouble(_kCrossfeedDelay, delayMs);
    await prefs.setDouble(_kCrossfeedCutoff, cutoffHz);
    await prefs.setBool(_kCrossfeedComp, outputCompensation);
  }

  Future<
      ({
        bool enabled,
        int preset,
        int algoIndex,
        double mix,
        double delayMs,
        double cutoffHz,
        bool outputCompensation
      })> loadCrossfeed() async {
    final prefs = await SharedPreferences.getInstance();
    return (
      enabled: prefs.getBool(_kCrossfeedEnabled) ?? false,
      preset: prefs.getInt(_kCrossfeedPreset) ?? 1,
      algoIndex: prefs.getInt(_kCrossfeedAlgo) ?? 2,
      mix: prefs.getDouble(_kCrossfeedMix) ?? 0.5,
      delayMs: prefs.getDouble(_kCrossfeedDelay) ?? 0.40,
      cutoffHz: prefs.getDouble(_kCrossfeedCutoff) ?? 700.0,
      outputCompensation: prefs.getBool(_kCrossfeedComp) ?? true,
    );
  }

  Future<void> saveRaceParams({
    required double delayMs,
    required double alpha,
    required double lpfHz,
  }) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setDouble(_kRaceDelayMs, delayMs);
    await prefs.setDouble(_kRaceAlpha, alpha);
    await prefs.setDouble(_kRaceLpfHz, lpfHz);
  }

  Future<({double delayMs, double alpha, double lpfHz})> loadRaceParams() async {
    final prefs = await SharedPreferences.getInstance();
    return (
      delayMs: prefs.getDouble(_kRaceDelayMs) ?? 0.166,
      alpha: prefs.getDouble(_kRaceAlpha) ?? 0.55,
      lpfHz: prefs.getDouble(_kRaceLpfHz) ?? 2500.0,
    );
  }

  Future<void> saveDynamicBass({
    required bool enabled,
    required int preset,
    required double gain,
  }) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_kDynamicBassEnabled, enabled);
    await prefs.setInt(_kDynamicBassPreset, preset);
    await prefs.setDouble(_kDynamicBassGain, gain);
  }

  Future<({bool enabled, int preset, double gain})> loadDynamicBass() async {
    final prefs = await SharedPreferences.getInstance();
    return (
      enabled: prefs.getBool(_kDynamicBassEnabled) ?? false,
      preset: prefs.getInt(_kDynamicBassPreset) ?? 18,
      gain: prefs.getDouble(_kDynamicBassGain) ?? 15.0,
    );
  }

  // ─── EQ – Crystalizer ─────────────────────────────────────────────────────
  static const _kCrystalizerEnabled = 'sp_crystalizer_enabled';
  static const _kCrystalizerIntensity = 'sp_crystalizer_intensity';
  static const _kCrystalizerHighShelf = 'sp_crystalizer_high_shelf';
  static const _kCrystalizerShelfGain = 'sp_crystalizer_shelf_gain';

  Future<void> saveCrystalizer({
    required bool enabled,
    required double intensity,
    required bool highShelfEnabled,
    required double highShelfGainDb,
  }) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_kCrystalizerEnabled, enabled);
    await prefs.setDouble(_kCrystalizerIntensity, intensity);
    await prefs.setBool(_kCrystalizerHighShelf, highShelfEnabled);
    await prefs.setDouble(_kCrystalizerShelfGain, highShelfGainDb);
  }

  Future<
      ({
        bool enabled,
        double intensity,
        bool highShelfEnabled,
        double highShelfGainDb
      })> loadCrystalizer() async {
    final prefs = await SharedPreferences.getInstance();
    return (
      enabled: prefs.getBool(_kCrystalizerEnabled) ?? false,
      intensity: prefs.getDouble(_kCrystalizerIntensity) ?? 0.5,
      highShelfEnabled: prefs.getBool(_kCrystalizerHighShelf) ?? true,
      highShelfGainDb: prefs.getDouble(_kCrystalizerShelfGain) ?? 2.0,
    );
  }

  // ─── EQ – Audio Tuning (3-band) ───────────────────────────────────────────
  static const _kAudioTuningEnabled = 'sp_audio_tuning_enabled';
  static const _kTuneLow = 'sp_tune_low';
  static const _kTuneMid = 'sp_tune_mid';
  static const _kTuneHigh = 'sp_tune_high';

  Future<void> saveAudioTuning({
    required bool enabled,
    required double low,
    required double mid,
    required double high,
  }) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_kAudioTuningEnabled, enabled);
    await prefs.setDouble(_kTuneLow, low);
    await prefs.setDouble(_kTuneMid, mid);
    await prefs.setDouble(_kTuneHigh, high);
  }

  Future<({bool enabled, double low, double mid, double high})>
      loadAudioTuning() async {
    final prefs = await SharedPreferences.getInstance();
    return (
      enabled: prefs.getBool(_kAudioTuningEnabled) ?? false,
      low: prefs.getDouble(_kTuneLow) ?? 1.0,
      mid: prefs.getDouble(_kTuneMid) ?? 1.0,
      high: prefs.getDouble(_kTuneHigh) ?? 1.0,
    );
  }

  // ─── EQ – True 3D Spatialization ──────────────────────────────────────────
  static const _kTrue3dEnabled = 'sp_true3d_enabled';
  static const _kSpatX = 'sp_spat_x';
  static const _kSpatY = 'sp_spat_y';
  static const _kSpatZ = 'sp_spat_z';

  Future<void> saveTrue3d({
    required bool enabled,
    required double x,
    required double y,
    required double z,
  }) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_kTrue3dEnabled, enabled);
    await prefs.setDouble(_kSpatX, x);
    await prefs.setDouble(_kSpatY, y);
    await prefs.setDouble(_kSpatZ, z);
  }

  Future<({bool enabled, double x, double y, double z})> loadTrue3d() async {
    final prefs = await SharedPreferences.getInstance();
    return (
      enabled: prefs.getBool(_kTrue3dEnabled) ?? false,
      x: prefs.getDouble(_kSpatX) ?? 0.0,
      y: prefs.getDouble(_kSpatY) ?? 0.0,
      z: prefs.getDouble(_kSpatZ) ?? 0.0,
    );
  }

  // ─── EQ – Custom LPF ──────────────────────────────────────────────────────
  static const _kLpfEnabled = 'sp_custom_lpf_enabled';
  static const _kLpfCutoff = 'sp_custom_lpf_cutoff';

  Future<void> saveCustomLpf({
    required bool enabled,
    required double cutoff,
  }) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_kLpfEnabled, enabled);
    await prefs.setDouble(_kLpfCutoff, cutoff);
  }

  Future<({bool enabled, double cutoff})> loadCustomLpf() async {
    final prefs = await SharedPreferences.getInstance();
    return (
      enabled: prefs.getBool(_kLpfEnabled) ?? false,
      cutoff: prefs.getDouble(_kLpfCutoff) ?? 500.0,
    );
  }

  // ─── EQ – Custom HPF ──────────────────────────────────────────────────────
  static const _kHpfEnabled = 'sp_custom_hpf_enabled';
  static const _kHpfCutoff = 'sp_custom_hpf_cutoff';

  Future<void> saveCustomHpf({
    required bool enabled,
    required double cutoff,
  }) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_kHpfEnabled, enabled);
    await prefs.setDouble(_kHpfCutoff, cutoff);
  }

  Future<({bool enabled, double cutoff})> loadCustomHpf() async {
    final prefs = await SharedPreferences.getInstance();
    return (
      enabled: prefs.getBool(_kHpfEnabled) ?? false,
      cutoff: prefs.getDouble(_kHpfCutoff) ?? 120.0,
    );
  }

  // ─── EQ – Limiter ─────────────────────────────────────────────────────────
  static const _kLimiterEnabled = 'sp_limiter_enabled';
  static const _kLimiterThreshold = 'sp_limiter_threshold';
  static const _kLimiterAttack = 'sp_limiter_attack_ms';
  static const _kLimiterRelease = 'sp_limiter_release_ms';

  Future<void> saveLimiter({
    required bool enabled,
    required double threshold,
    required double attackMs,
    required double releaseMs,
  }) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_kLimiterEnabled, enabled);
    await prefs.setDouble(_kLimiterThreshold, threshold);
    await prefs.setDouble(_kLimiterAttack, attackMs);
    await prefs.setDouble(_kLimiterRelease, releaseMs);
  }

  Future<({bool enabled, double threshold, double attackMs, double releaseMs})>
      loadLimiter() async {
    final prefs = await SharedPreferences.getInstance();
    return (
      enabled: prefs.getBool(_kLimiterEnabled) ?? false,
      threshold: prefs.getDouble(_kLimiterThreshold) ?? 0.95,
      attackMs: prefs.getDouble(_kLimiterAttack) ?? 2.0,
      releaseMs: prefs.getDouble(_kLimiterRelease) ?? 50.0,
    );
  }

  // ─── EQ – Dynamic Range Compressor ─────────────────────────────────────────
  static const _kCompressorEnabled = 'sp_compressor_enabled';
  static const _kCompressorThreshold = 'sp_compressor_threshold_db';
  static const _kCompressorRatio = 'sp_compressor_ratio';
  static const _kCompressorKnee = 'sp_compressor_knee_db';
  static const _kCompressorAttack = 'sp_compressor_attack_ms';
  static const _kCompressorRelease = 'sp_compressor_release_ms';
  static const _kCompressorMakeup = 'sp_compressor_makeup_db';
  static const _kCompressorDetector = 'sp_compressor_detector';
  static const _kCompressorStereoLink = 'sp_compressor_stereo_link';
  static const _kCompressorAutoMakeup = 'sp_compressor_auto_makeup';
  static const _kCompressorMix = 'sp_compressor_mix';

  Future<void> saveCompressor({
    required bool enabled,
    required double thresholdDb,
    required double ratio,
    required double kneeDb,
    required double attackMs,
    required double releaseMs,
    required double makeupGainDb,
    required int detector,
    required bool stereoLink,
    required bool autoMakeup,
    required double mix,
  }) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_kCompressorEnabled, enabled);
    await prefs.setDouble(_kCompressorThreshold, thresholdDb);
    await prefs.setDouble(_kCompressorRatio, ratio);
    await prefs.setDouble(_kCompressorKnee, kneeDb);
    await prefs.setDouble(_kCompressorAttack, attackMs);
    await prefs.setDouble(_kCompressorRelease, releaseMs);
    await prefs.setDouble(_kCompressorMakeup, makeupGainDb);
    await prefs.setInt(_kCompressorDetector, detector);
    await prefs.setBool(_kCompressorStereoLink, stereoLink);
    await prefs.setBool(_kCompressorAutoMakeup, autoMakeup);
    await prefs.setDouble(_kCompressorMix, mix);
  }

  Future<
      ({
        bool enabled,
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
      })> loadCompressor() async {
    final prefs = await SharedPreferences.getInstance();
    return (
      enabled: prefs.getBool(_kCompressorEnabled) ?? false,
      thresholdDb: prefs.getDouble(_kCompressorThreshold) ?? -20.0,
      ratio: prefs.getDouble(_kCompressorRatio) ?? 4.0,
      kneeDb: prefs.getDouble(_kCompressorKnee) ?? 6.0,
      attackMs: prefs.getDouble(_kCompressorAttack) ?? 10.0,
      releaseMs: prefs.getDouble(_kCompressorRelease) ?? 100.0,
      makeupGainDb: prefs.getDouble(_kCompressorMakeup) ?? 0.0,
      detector: prefs.getInt(_kCompressorDetector) ?? 0,
      stereoLink: prefs.getBool(_kCompressorStereoLink) ?? true,
      autoMakeup: prefs.getBool(_kCompressorAutoMakeup) ?? false,
      mix: prefs.getDouble(_kCompressorMix) ?? 1.0,
    );
  }

  // ─── EQ – Parametric EQ ───────────────────────────────────────────────────
  static const _kParametricEqEnabled = 'sp_parametric_eq_enabled';
  static const _kParametricEqBands = 'sp_parametric_eq_bands'; // JSON list

  /// Each band is stored as a JSON object:
  /// {type, frequency, q, gainDb, slope, enabled}
  Future<void> saveParametricEq({
    required bool enabled,
    required List<Map<String, dynamic>> bands,
  }) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_kParametricEqEnabled, enabled);
    await prefs.setStringList(
      _kParametricEqBands,
      bands.map(jsonEncode).toList(),
    );
  }

  Future<({bool enabled, List<Map<String, dynamic>> bands})>
      loadParametricEq() async {
    final prefs = await SharedPreferences.getInstance();
    final enabled = prefs.getBool(_kParametricEqEnabled) ?? false;
    final raw = prefs.getStringList(_kParametricEqBands);
    final bands = raw != null
        ? raw
            .map<Map<String, dynamic>>((s) {
              try {
                return Map<String, dynamic>.from(jsonDecode(s) as Map);
              } catch (_) {
                return {};
              }
            })
            .where((m) => m.isNotEmpty)
            .toList()
        : <Map<String, dynamic>>[];
    return (enabled: enabled, bands: bands);
  }

  // ─── EQ – Custom Biquad ───────────────────────────────────────────────────
  static const _kBiquadEnabled = 'sp_biquad_enabled';
  static const _kBiquadB0 = 'sp_biquad_b0';
  static const _kBiquadB1 = 'sp_biquad_b1';
  static const _kBiquadB2 = 'sp_biquad_b2';
  static const _kBiquadA0 = 'sp_biquad_a0';
  static const _kBiquadA1 = 'sp_biquad_a1';
  static const _kBiquadA2 = 'sp_biquad_a2';

  Future<void> saveCustomBiquad({
    required bool enabled,
    required double b0,
    required double b1,
    required double b2,
    required double a0,
    required double a1,
    required double a2,
  }) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_kBiquadEnabled, enabled);
    await prefs.setDouble(_kBiquadB0, b0);
    await prefs.setDouble(_kBiquadB1, b1);
    await prefs.setDouble(_kBiquadB2, b2);
    await prefs.setDouble(_kBiquadA0, a0);
    await prefs.setDouble(_kBiquadA1, a1);
    await prefs.setDouble(_kBiquadA2, a2);
  }

  Future<
      ({
        bool enabled,
        double b0,
        double b1,
        double b2,
        double a0,
        double a1,
        double a2
      })> loadCustomBiquad() async {
    final prefs = await SharedPreferences.getInstance();
    return (
      enabled: prefs.getBool(_kBiquadEnabled) ?? false,
      b0: prefs.getDouble(_kBiquadB0) ?? 1.0,
      b1: prefs.getDouble(_kBiquadB1) ?? 0.0,
      b2: prefs.getDouble(_kBiquadB2) ?? 0.0,
      a0: prefs.getDouble(_kBiquadA0) ?? 1.0,
      a1: prefs.getDouble(_kBiquadA1) ?? 0.0,
      a2: prefs.getDouble(_kBiquadA2) ?? 0.0,
    );
  }

  // ─── Settings – Output / Engine ──────────────────────────────────────────
  static const _kOutputFormat = 'sp_output_format';
  static const _kSampleRate = 'sp_sample_rate';
  static const _kChannels = 'sp_channels';
  static const _kCrossfadeEnabled = 'sp_crossfade_enabled';
  static const _kCrossfadeMs = 'sp_crossfade_ms';
  static const _kLoudnessCrossfadeEnabled = 'sp_loudness_crossfade_enabled';
  static const _kAnalyzerEnabled = 'sp_analyzer_enabled';
  static const _kAnalyzerType = 'sp_analyzer_type';
  static const _kAnalyzerSampleSize = 'sp_analyzer_sample_size';
  static const _kAnalyzerWindowType = 'sp_analyzer_window_type';
  static const _kAllowInvalidTls = 'sp_allow_invalid_tls';
  static const _kExclusiveMode = 'sp_exclusive_mode';
  static const _kAnalyzerAutoFit = 'sp_analyzer_auto_fit';
  static const _kAnalyzerShowGrids = 'sp_analyzer_show_grids';
  static const _kAnalyzerLogScale = 'sp_analyzer_log_scale';
  static const _kSpectrumStyle = 'sp_spectrum_style';

  Future<void> saveEngineSettings({
    required int outputFormatIndex,
    required int sampleRate,
    required int channels,
    required bool crossfadeEnabled,
    required int crossfadeMs,
    bool loudnessCrossfadeEnabled = true,
    required bool analyzerEnabled,
    required String analyzerType,
    required int analyzerSampleSize,
    String analyzerWindowType = 'hann',
    required bool allowInvalidTls,
    required bool exclusiveMode,
    required bool analyzerAutoFit,
    required bool analyzerShowGrids,
    required bool analyzerLogScale,
    required String spectrumStyle,
  }) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(_kOutputFormat, outputFormatIndex);
    await prefs.setInt(_kSampleRate, sampleRate);
    await prefs.setInt(_kChannels, channels);
    await prefs.setBool(_kCrossfadeEnabled, crossfadeEnabled);
    await prefs.setInt(_kCrossfadeMs, crossfadeMs);
    await prefs.setBool(_kLoudnessCrossfadeEnabled, loudnessCrossfadeEnabled);
    await prefs.setBool(_kAnalyzerEnabled, analyzerEnabled);
    await prefs.setString(_kAnalyzerType, analyzerType);
    await prefs.setInt(_kAnalyzerSampleSize, analyzerSampleSize);
    await prefs.setString(_kAnalyzerWindowType, analyzerWindowType);
    await prefs.setBool(_kAllowInvalidTls, allowInvalidTls);
    await prefs.setBool(_kExclusiveMode, exclusiveMode);
    await prefs.setBool(_kAnalyzerAutoFit, analyzerAutoFit);
    await prefs.setBool(_kAnalyzerShowGrids, analyzerShowGrids);
    await prefs.setBool(_kAnalyzerLogScale, analyzerLogScale);
    await prefs.setString(_kSpectrumStyle, spectrumStyle);
    audioProcessingSettingsChanged.add(null);
  }

  /// Saves only the loudness-aware crossfade flag without touching other engine
  /// settings. Used by the Settings UI toggle which doesn't own the full state.
  Future<void> saveLoudnessCrossfadeEnabled(bool enabled) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_kLoudnessCrossfadeEnabled, enabled);
    audioProcessingSettingsChanged.add(null);
  }

  Future<
      ({
        int outputFormatIndex,
        int sampleRate,
        int channels,
        bool crossfadeEnabled,
        int crossfadeMs,
        bool loudnessCrossfadeEnabled,
        bool analyzerEnabled,
        String analyzerType,
        int analyzerSampleSize,
        String analyzerWindowType,
        bool allowInvalidTls,
        bool exclusiveMode,
        bool analyzerAutoFit,
        bool analyzerShowGrids,
        bool analyzerLogScale,
        String spectrumStyle
      })> loadEngineSettings() async {
    final prefs = await SharedPreferences.getInstance();
    return (
      outputFormatIndex: prefs.getInt(_kOutputFormat) ?? 0, // 0 = f32
      sampleRate: prefs.getInt(_kSampleRate) ?? 0,
      channels: prefs.getInt(_kChannels) ?? 2,
      crossfadeEnabled: prefs.getBool(_kCrossfadeEnabled) ?? false,
      crossfadeMs: prefs.getInt(_kCrossfadeMs) ?? 250,
      loudnessCrossfadeEnabled: prefs.getBool(_kLoudnessCrossfadeEnabled) ?? true,
      analyzerEnabled: prefs.getBool(_kAnalyzerEnabled) ?? true,
      analyzerType: prefs.getString(_kAnalyzerType) ?? 'bar',
      analyzerSampleSize: prefs.getInt(_kAnalyzerSampleSize) ?? 1024,
      analyzerWindowType: prefs.getString(_kAnalyzerWindowType) ?? 'hann',
      allowInvalidTls: prefs.getBool(_kAllowInvalidTls) ?? false,
      exclusiveMode: prefs.getBool(_kExclusiveMode) ?? false,
      analyzerAutoFit: prefs.getBool(_kAnalyzerAutoFit) ?? true,
      analyzerShowGrids: prefs.getBool(_kAnalyzerShowGrids) ?? true,
      analyzerLogScale: prefs.getBool(_kAnalyzerLogScale) ?? true,
      spectrumStyle: prefs.getString(_kSpectrumStyle) ?? 'minimal',
    );
  }

  // ─── Settings – UI / Streaming preferences ───────────────────────────────
  static const _kStreamingQuality = 'sp_streaming_quality';
  static const _kGaplessPlayback = 'sp_gapless_playback';
  static const _kNormalizeVolume = 'sp_normalize_volume';
  static const _kStreamOverWifi = 'sp_stream_over_wifi';
  static const _kResampleAlgorithm = 'sp_resample_algorithm';
  static const _kDitherMode = 'sp_dither_mode';

  Future<void> saveUiSettings({
    required String streamingQuality,
    required bool gaplessPlayback,
    required bool normalizeVolume,
    required bool streamOverWifi,
    required int resampleAlgorithm,
    required int ditherMode,
  }) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_kStreamingQuality, streamingQuality);
    await prefs.setBool(_kGaplessPlayback, gaplessPlayback);
    await prefs.setBool(_kNormalizeVolume, normalizeVolume);
    await prefs.setBool(_kStreamOverWifi, streamOverWifi);
    await prefs.setInt(_kResampleAlgorithm, resampleAlgorithm);
    await prefs.setInt(_kDitherMode, ditherMode);
    audioProcessingSettingsChanged.add(null);
  }

  Future<
      ({
        String streamingQuality,
        bool gaplessPlayback,
        bool normalizeVolume,
        bool streamOverWifi,
        int resampleAlgorithm,
        int ditherMode,
      })> loadUiSettings() async {
    final prefs = await SharedPreferences.getInstance();
    return (
      streamingQuality: prefs.getString(_kStreamingQuality) ?? 'High Fidelity',
      gaplessPlayback: prefs.getBool(_kGaplessPlayback) ?? true,
      normalizeVolume: prefs.getBool(_kNormalizeVolume) ?? false,
      streamOverWifi: prefs.getBool(_kStreamOverWifi) ?? true,
      resampleAlgorithm: prefs.getInt(_kResampleAlgorithm) ?? 0,
      ditherMode: prefs.getInt(_kDitherMode) ?? 0,
    );
  }

  // ─── Waveform & Slider Preferences ───────────────────────────────────────
  static const _kUseWaveformSeekBar = 'sp_use_waveform_seek_bar';
  static const _kUseWavySlider = 'sp_use_wavy_slider';

  Future<void> saveUseWaveformSeekBar(bool enabled) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_kUseWaveformSeekBar, enabled);
    useWaveformSeekBarChanged.add(enabled);
  }

  Future<bool> loadUseWaveformSeekBar() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(_kUseWaveformSeekBar) ?? false;
  }

  Future<void> saveUseWavySlider(bool enabled) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_kUseWavySlider, enabled);
    useWavySliderNotifier.value = enabled;
    useWavySliderChanged.add(enabled);
  }

  Future<bool> loadUseWavySlider() async {
    final prefs = await SharedPreferences.getInstance();
    final val = prefs.getBool(_kUseWavySlider) ?? true;
    useWavySliderNotifier.value = val;
    return val;
  }

  // ─── Sauti DSP Suite Settings ─────────────────────────────────────────────
  static const _kSautiDspState = 'sp_sauti_dsp_state';
  static const _kViperFxState = 'sp_viper_fx_state'; // Legacy fallback key

  Future<void> saveSautiDspState(Map<String, dynamic> state) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_kSautiDspState, jsonEncode(state));
  }

  Future<Map<String, dynamic>> loadSautiDspState() async {
    final prefs = await SharedPreferences.getInstance();
    final str = prefs.getString(_kSautiDspState) ?? prefs.getString(_kViperFxState);
    if (str != null && str.isNotEmpty) {
      try {
        return jsonDecode(str) as Map<String, dynamic>;
      } catch (_) {}
    }
    return {};
  }

  // ─── DSP Oversampling Settings ───────────────────────────────────────────
  static const _kDspOversampling = 'sp_dsp_oversampling';

  Future<void> saveDspOversampling(int factor) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(_kDspOversampling, factor);
    audioProcessingSettingsChanged.add(null);
  }

  Future<int> loadDspOversampling() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getInt(_kDspOversampling) ?? 1;
  }

  // ─── ReplayGain Settings ──────────────────────────────────────────────────
  static const _kReplayGainMode = 'sp_replay_gain_mode';
  static const _kReplayGainPreamp = 'sp_replay_gain_preamp';

  Future<void> saveReplayGainSettings({
    required ReplayGainMode mode,
    required double preamp,
  }) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(_kReplayGainMode, mode.index);
    await prefs.setDouble(_kReplayGainPreamp, preamp);
    replayGainChanged.add(null);
  }

  Future<({ReplayGainMode mode, double preamp})> loadReplayGainSettings() async {
    final prefs = await SharedPreferences.getInstance();
    final modeIndex = prefs.getInt(_kReplayGainMode) ?? 0;
    final mode = ReplayGainMode.values.elementAtOrNull(modeIndex) ?? ReplayGainMode.none;
    final preamp = prefs.getDouble(_kReplayGainPreamp) ?? 0.0;
    return (mode: mode, preamp: preamp);
  }

  // ─── Playback Speed & Pitch Settings ──────────────────────────────────────
  static const _kPlaybackRate = 'sp_playback_rate';
  static const _kPlaybackPitch = 'sp_playback_pitch';
  static const _kPitchCorrection = 'sp_pitch_correction';

  Future<void> savePlaybackRate(double rate) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setDouble(_kPlaybackRate, rate);
  }

  Future<double> loadPlaybackRate() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getDouble(_kPlaybackRate) ?? 1.0;
  }

  Future<void> savePlaybackPitch(double pitch) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setDouble(_kPlaybackPitch, pitch);
  }

  Future<double> loadPlaybackPitch() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getDouble(_kPlaybackPitch) ?? 1.0;
  }

  Future<void> savePitchCorrection(bool enabled) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_kPitchCorrection, enabled);
  }

  Future<bool> loadPitchCorrection() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(_kPitchCorrection) ?? true;
  }

  Future<void> savePlaybackSpeed(double rate) async {
    await savePlaybackRate(rate);
  }

  Future<double> loadPlaybackSpeed() async {
    return loadPlaybackRate();
  }

  // ─── Speaker & Hardware Protection Settings ──────────────────────────────
  static const _kSpeakerProtectionEnabled = 'sp_speaker_protection_enabled';
  static const _kSubsonicCutoff = 'sp_subsonic_cutoff_hz';
  static const _kUltrasonicCutoff = 'sp_ultrasonic_cutoff_hz';
  static const _kSpeakerLimiterThreshold = 'sp_speaker_limiter_threshold';
  static const _kSafetyAttenuation = 'sp_speaker_safety_attenuation_db';

  Future<void> saveSpeakerProtection({
    required bool enabled,
    required double subsonicCutoffHz,
    required double ultrasonicCutoffHz,
    required double limiterThreshold,
    required double safetyAttenuationDb,
  }) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_kSpeakerProtectionEnabled, enabled);
    await prefs.setDouble(_kSubsonicCutoff, subsonicCutoffHz);
    await prefs.setDouble(_kUltrasonicCutoff, ultrasonicCutoffHz);
    await prefs.setDouble(_kSpeakerLimiterThreshold, limiterThreshold);
    await prefs.setDouble(_kSafetyAttenuation, safetyAttenuationDb);
    audioProcessingSettingsChanged.add(null);
  }

  Future<({
    bool enabled,
    double subsonicCutoffHz,
    double ultrasonicCutoffHz,
    double limiterThreshold,
    double safetyAttenuationDb,
  })> loadSpeakerProtection() async {
    final prefs = await SharedPreferences.getInstance();
    return (
      enabled: prefs.getBool(_kSpeakerProtectionEnabled) ?? true,
      subsonicCutoffHz: prefs.getDouble(_kSubsonicCutoff) ?? 25.0,
      ultrasonicCutoffHz: prefs.getDouble(_kUltrasonicCutoff) ?? 20000.0,
      limiterThreshold: prefs.getDouble(_kSpeakerLimiterThreshold) ?? 0.95,
      safetyAttenuationDb: prefs.getDouble(_kSafetyAttenuation) ?? -1.0,
    );
  }

  // ─── Phase Inversion Settings ─────────────────────────────────────────────
  static const _kPhaseInvertLeft = 'sp_phase_invert_left';
  static const _kPhaseInvertRight = 'sp_phase_invert_right';

  Future<void> savePhaseInversion({
    required bool invertLeft,
    required bool invertRight,
  }) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_kPhaseInvertLeft, invertLeft);
    await prefs.setBool(_kPhaseInvertRight, invertRight);
    audioProcessingSettingsChanged.add(null);
  }

  Future<({bool invertLeft, bool invertRight})> loadPhaseInversion() async {
    final prefs = await SharedPreferences.getInstance();
    return (
      invertLeft: prefs.getBool(_kPhaseInvertLeft) ?? false,
      invertRight: prefs.getBool(_kPhaseInvertRight) ?? false,
    );
  }

  // ─── L/R Swap & Per-Channel Gain ──────────────────────────────────────────
  static const _kLrSwapEnabled = 'sp_lr_swap_enabled';
  static const _kChannelGainLeftDb = 'sp_channel_gain_left_db';
  static const _kChannelGainRightDb = 'sp_channel_gain_right_db';

  Future<void> saveLrSwap(bool enabled) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_kLrSwapEnabled, enabled);
    audioProcessingSettingsChanged.add(null);
  }

  Future<bool> loadLrSwap() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(_kLrSwapEnabled) ?? false;
  }

  Future<void> saveChannelGains({
    required double leftDb,
    required double rightDb,
  }) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setDouble(_kChannelGainLeftDb, leftDb);
    await prefs.setDouble(_kChannelGainRightDb, rightDb);
    audioProcessingSettingsChanged.add(null);
  }

  Future<({double leftDb, double rightDb})> loadChannelGains() async {
    final prefs = await SharedPreferences.getInstance();
    return (
      leftDb: prefs.getDouble(_kChannelGainLeftDb) ?? 0.0,
      rightDb: prefs.getDouble(_kChannelGainRightDb) ?? 0.0,
    );
  }

  // ─── Neutron HiFi Audio Engine Settings ────────────────────────────────────
  static const _k64BitProcessingEnabled = 'sp_64bit_processing_enabled';
  static const _kAutoBitPerfectEnabled = 'sp_auto_bit_perfect_enabled';

  Future<void> save64BitProcessingEnabled(bool enabled) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_k64BitProcessingEnabled, enabled);
    audioProcessingSettingsChanged.add(null);
  }

  Future<bool> load64BitProcessingEnabled() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(_k64BitProcessingEnabled) ?? false;
  }

  Future<void> saveAutoBitPerfectEnabled(bool enabled) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_kAutoBitPerfectEnabled, enabled);
    audioProcessingSettingsChanged.add(null);
  }

  Future<bool> loadAutoBitPerfectEnabled() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(_kAutoBitPerfectEnabled) ?? true;
  }

  // ─── Hardware Buffer Size & Latency Settings ──────────────────────────────
  static const _kOutputBufferFrames = 'sp_output_buffer_frames';
  static const _kOutputBufferPeriods = 'sp_output_buffer_periods';

  Future<void> saveOutputBuffer({
    required int periodFrames,
    required int periodCount,
  }) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(_kOutputBufferFrames, periodFrames);
    await prefs.setInt(_kOutputBufferPeriods, periodCount);
    audioProcessingSettingsChanged.add(null);
  }

  Future<({int periodFrames, int periodCount})> loadOutputBuffer() async {
    final prefs = await SharedPreferences.getInstance();
    return (
      periodFrames: prefs.getInt(_kOutputBufferFrames) ?? 0,
      periodCount: prefs.getInt(_kOutputBufferPeriods) ?? 0,
    );
  }

  // ── Release 1 Quality Foundation Settings ──────────────────────────────────
  static const _kLoudnessNormalizerEnabled = 'sp_loudness_normalizer_enabled';
  static const _kLoudnessNormalizerTarget = 'sp_loudness_normalizer_target';
  static const _kLookaheadLimiterEnabled = 'sp_lookahead_limiter_enabled';
  static const _kLookaheadLimiterCeiling = 'sp_lookahead_limiter_ceiling';

  Future<void> saveLoudnessNormalizer({
    required bool enabled,
    required double targetLUFS,
  }) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_kLoudnessNormalizerEnabled, enabled);
    await prefs.setDouble(_kLoudnessNormalizerTarget, targetLUFS);
    audioProcessingSettingsChanged.add(null);
  }

  Future<({bool enabled, double targetLUFS})> loadLoudnessNormalizer() async {
    final prefs = await SharedPreferences.getInstance();
    return (
      enabled: prefs.getBool(_kLoudnessNormalizerEnabled) ?? true,
      targetLUFS: prefs.getDouble(_kLoudnessNormalizerTarget) ?? -14.0,
    );
  }

  Future<void> saveLookaheadLimiter({
    required bool enabled,
    required double ceilingDBTP,
  }) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_kLookaheadLimiterEnabled, enabled);
    await prefs.setDouble(_kLookaheadLimiterCeiling, ceilingDBTP);
    audioProcessingSettingsChanged.add(null);
  }

  Future<({bool enabled, double ceilingDBTP})> loadLookaheadLimiter() async {
    final prefs = await SharedPreferences.getInstance();
    return (
      enabled: prefs.getBool(_kLookaheadLimiterEnabled) ?? true,
      ceilingDBTP: prefs.getDouble(_kLookaheadLimiterCeiling) ?? -1.0,
    );
  }

  // ─── Online Streaming & Bandwidth Settings ─────────────────────────────────
  static const _kStreamingQualityPreset = 'sp_streaming_quality_preset_v2';
  static const _kPreferNativeAac = 'sp_prefer_native_aac';
  static const _kEnableHostedFallback = 'sp_enable_hosted_fallback';

  final StreamController<void> streamingSettingsChanged =
      StreamController<void>.broadcast();

  Future<void> saveStreamingQualityPreset(AudioQualityPreset quality) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_kStreamingQualityPreset, quality.name);
    streamingSettingsChanged.add(null);
  }

  Future<AudioQualityPreset> loadStreamingQualityPreset() async {
    final prefs = await SharedPreferences.getInstance();
    final name = prefs.getString(_kStreamingQualityPreset);
    if (name == null) return AudioQualityPreset.audiophile;
    return AudioQualityPreset.values.firstWhere(
      (e) => e.name == name,
      orElse: () => AudioQualityPreset.audiophile,
    );
  }

  Future<void> savePreferNativeAac(bool prefer) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_kPreferNativeAac, prefer);
    streamingSettingsChanged.add(null);
  }

  Future<bool> loadPreferNativeAac() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(_kPreferNativeAac) ?? false;
  }

  Future<void> saveEnableHostedFallback(bool enable) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_kEnableHostedFallback, enable);
    streamingSettingsChanged.add(null);
  }

  Future<bool> loadEnableHostedFallback() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(_kEnableHostedFallback) ?? true;
  }
}



