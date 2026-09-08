import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:sautiflow/sautiflow.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../eq_screen.dart';
import '../isolate_player.dart';
import '../models/audio_profile.dart';
import 'app_state_service.dart';

/// Manages Audio Profiles: loading, saving, importing, exporting, and applying.
class AudioProfileService {
  static final AudioProfileService _instance = AudioProfileService._internal();
  static AudioProfileService get instance => _instance;

  AudioProfileService._internal();

  static const String _kCustomProfilesKey = 'custom_audio_profiles';
  static const String _kActiveProfileIdKey = 'active_audio_profile_id';

  final StreamController<AudioProfile?> _activeProfileController =
      StreamController<AudioProfile?>.broadcast();
  Stream<AudioProfile?> get activeProfileStream =>
      _activeProfileController.stream;

  /// Resets all DSP effects on the audio engine and storage to a clean baseline.
  Future<void> resetAllEffects(IsolateAudioPlayer player) async {
    // 1. Reset all built-in effects directly in the engine isolate
    player.setReverbEnabled(false);
    player.setDelay(enabled: false);
    player.setDynamicBass(enabled: false, preset: 18, gain: 0.0);
    player.setCrystalizer(enabled: false);
    player.setCrossfeed(enabled: false, preset: 1);
    player.setStereoWiden(enabled: false, width: 1.5, delayMs: 15.0);
    player.setStereoEnhancement(enabled: false, mix: 0.5);
    player.setEqEnabled(false);
    player.setEq(low: 0.0, mid: 0.0, high: 0.0);
    player.setSpatializationEnabled(false);
    player.setCustomLpf1(enabled: false, cutoffHz: 500.0);
    player.setCustomHpf1(enabled: false, cutoffHz: 120.0);
    player.setLimiterEnabled(false);
    player.setCompressorEnabled(false);

    // Reset & disable all Sauti DSP Suite modules directly in engine
    player.resetDsp();
    player.setClarity(enabled: false);
    player.setDialogEnhancer(enabled: false);
    player.setHarmonicBass(enabled: false);
    player.setDynamicSystem(enabled: false);
    player.setAnalogWarmth(enabled: false);
    player.setDeEsser(enabled: false);
    player.setDownwardExpander(enabled: false);
    player.setConvolverEnabled(false);
    player.setMasterLimiter(enabled: false);
    await AppStateService.instance.saveSautiDspState(
        {'dspMasterEnabled': false, 'surroundEnabled': false});
    await EqScreen.applySavedStateToEngine(player);

    // 2. Persist baseline disabled state to storage in parallel
    await Future.wait([
      AppStateService.instance.saveSpatialAudio(
          enabled: false, reverbMix: 0.25, roomSize: 0.3, echo: 0.15),
      AppStateService.instance
          .saveDelay(enabled: false, mix: 0.3, feedback: 0.4, time: 0.25),
      AppStateService.instance
          .saveDynamicBass(enabled: false, preset: 18, gain: 15.0),
      AppStateService.instance.saveCrystalizer(
          enabled: false,
          intensity: 0.5,
          highShelfEnabled: true,
          highShelfGainDb: 2.0),
      AppStateService.instance.saveCrossfeed(enabled: false, preset: 1),
      AppStateService.instance
          .saveStereoWiden(enabled: false, width: 1.5, delayMs: 15.0),
      AppStateService.instance.saveStereoEnhancement(enabled: false, mix: 0.5),
      AppStateService.instance
          .saveAudioTuning(enabled: false, low: 0.0, mid: 0.0, high: 0.0),
      AppStateService.instance
          .saveTrue3d(enabled: false, x: 0.0, y: 0.0, z: 0.0),
      AppStateService.instance.saveCustomLpf(enabled: false, cutoff: 500.0),
      AppStateService.instance.saveCustomHpf(enabled: false, cutoff: 120.0),
      AppStateService.instance.saveLimiter(
          enabled: false, threshold: 0.95, attackMs: 2.0, releaseMs: 50.0),
      AppStateService.instance.saveCompressor(
        enabled: false,
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
    ]);
  }

  /// Applies a full AudioProfile to the audio engine and updates AppStateService.
  Future<void> applyProfile(
      IsolateAudioPlayer player, AudioProfile profile) async {
    // Step 0: Clean baseline reset of all DSP effects to prevent leftover effects
    await resetAllEffects(player);

    // 1. Apply Graphic & Parametric EQ
    final eq = profile.eqState;
    if (eq.isNotEmpty) {
      final bool enabled = eq['enabled'] ?? true;
      final String presetName = profile.name;
      final List<double> gains =
          (eq['gains'] as List?)?.map((e) => (e as num).toDouble()).toList() ??
              [];
      final List<double> freqs =
          (eq['freqs'] as List?)?.map((e) => (e as num).toDouble()).toList() ??
              [];
      final double preampDb = (eq['preampDb'] as num?)?.toDouble() ?? 0.0;

      player.setMultibandEqEnabled(enabled);
      if (freqs.isNotEmpty) {
        player.initMultibandEq(freqs);
        for (int i = 0; i < gains.length; i++) {
          player.setMultibandEqBandGain(i, gains[i]);
        }
      }

      final gainLinear = math.pow(10, preampDb / 20.0).toDouble();
      player.setGain(gainLinear);

      await AppStateService.instance.saveEqBands(
        enabled: enabled,
        preset: presetName,
        gains: gains,
        preampDb: preampDb,
        bandCount: freqs.isNotEmpty ? freqs.length : 10,
      );

      // Apply and save Parametric EQ if present in profile
      final bool parametricEnabled = eq['parametricEnabled'] as bool? ?? false;
      final List rawParametric = eq['parametricBands'] as List? ?? [];
      final List<EqBandConfig> pBands = [];
      final List<Map<String, dynamic>> pBandMaps = [];

      for (final m in rawParametric) {
        if (m is Map) {
          final typeIdx = (m['type'] as num?)?.toInt() ?? 0;
          final rawType = (typeIdx >= 0 && typeIdx < EqBandType.values.length)
              ? EqBandType.values[typeIdx]
              : EqBandType.peak;
          final type =
              (rawType == EqBandType.bell) ? EqBandType.peak : rawType;
          final freq = (m['frequency'] as num?)?.toDouble() ?? 1000.0;
          final gain = (m['gainDb'] as num?)?.toDouble() ?? 0.0;
          final q = (m['q'] as num?)?.toDouble() ?? 1.2;
          final slope = (m['slope'] as num?)?.toDouble() ?? 1.0;
          final isBandEnabled = m['enabled'] as bool? ?? true;

          pBands.add(EqBandConfig(
            type: type,
            frequencyHz: freq,
            gainDb: gain,
            q: q,
            slope: slope,
            enabled: isBandEnabled,
          ));
          pBandMaps.add({
            'type': typeIdx,
            'frequency': freq,
            'gainDb': gain,
            'q': q,
            'slope': slope,
            'enabled': isBandEnabled,
          });
        }
      }

      if (pBands.isNotEmpty) {
        player.initMultibandFx(pBands, enabled: parametricEnabled);
      }
      player.setMultibandFxEnabled(parametricEnabled);
      await AppStateService.instance.saveParametricEq(
        enabled: parametricEnabled,
        bands: pBandMaps,
      );

      final parametricPreset = eq['parametricPreset'] as String?;
      if (parametricPreset != null && parametricPreset.isNotEmpty) {
        final prefs = await SharedPreferences.getInstance();
        await prefs.setString('sp_active_parametric_preset', parametricPreset);
      }
    } else {
      player.setMultibandFxEnabled(false);
      await AppStateService.instance.saveParametricEq(
        enabled: false,
        bands: [],
      );
    }

    // 2. Apply Built-in DSP Effects
    final dsp = profile.dspEffectsState;

    if (dsp.containsKey('spatial')) {
      final s = dsp['spatial'] as Map;
      final enabled = s['enabled'] ?? false;
      final reverbMix = (s['reverbMix'] as num?)?.toDouble() ?? 0.25;
      final roomSize = (s['roomSize'] as num?)?.toDouble() ?? 0.3;
      final echo = (s['echo'] as num?)?.toDouble() ?? 0.15;
      player.setReverbEnabled(enabled);
      await AppStateService.instance.saveSpatialAudio(
        enabled: enabled,
        reverbMix: reverbMix,
        roomSize: roomSize,
        echo: echo,
      );
    } else {
      player.setReverbEnabled(false);
      await AppStateService.instance.saveSpatialAudio(
        enabled: false,
        reverbMix: 0.25,
        roomSize: 0.3,
        echo: 0.15,
      );
    }

    if (dsp.containsKey('delay')) {
      final d = dsp['delay'] as Map;
      final enabled = d['enabled'] ?? false;
      final mix = (d['mix'] as num?)?.toDouble() ?? 0.3;
      final feedback = (d['feedback'] as num?)?.toDouble() ?? 0.4;
      final time = (d['time'] as num?)?.toDouble() ?? 0.25;
      player.setDelay(
          enabled: enabled,
          mix: mix,
          feedback: feedback,
          delayMs: time * 1000.0);
      await AppStateService.instance.saveDelay(
        enabled: enabled,
        mix: mix,
        feedback: feedback,
        time: time,
      );
    } else {
      player.setDelay(enabled: false);
      await AppStateService.instance.saveDelay(
        enabled: false,
        mix: 0.3,
        feedback: 0.4,
        time: 0.25,
      );
    }

    if (dsp.containsKey('dynamicBass')) {
      final db = dsp['dynamicBass'] as Map;
      final enabled = db['enabled'] ?? false;
      final preset = (db['preset'] as num?)?.toInt() ?? 18;
      final gain = (db['gain'] as num?)?.toDouble() ?? 15.0;
      player.setDynamicBass(enabled: enabled, preset: preset, gain: gain);
      await AppStateService.instance.saveDynamicBass(
        enabled: enabled,
        preset: preset,
        gain: gain,
      );
    } else {
      player.setDynamicBass(enabled: false, preset: 18, gain: 0.0);
      await AppStateService.instance.saveDynamicBass(
        enabled: false,
        preset: 18,
        gain: 0.0,
      );
    }

    if (dsp.containsKey('crystalizer')) {
      final c = dsp['crystalizer'] as Map;
      final enabled = c['enabled'] ?? false;
      final intensity = (c['intensity'] as num?)?.toDouble() ?? 0.5;
      final highShelf = c['highShelfEnabled'] ?? true;
      final shelfGain = (c['highShelfGainDb'] as num?)?.toDouble() ?? 2.0;
      player.setCrystalizer(enabled: enabled);
      await AppStateService.instance.saveCrystalizer(
        enabled: enabled,
        intensity: intensity,
        highShelfEnabled: highShelf,
        highShelfGainDb: shelfGain,
      );
    } else {
      player.setCrystalizer(enabled: false);
      await AppStateService.instance.saveCrystalizer(
        enabled: false,
        intensity: 0.5,
        highShelfEnabled: true,
        highShelfGainDb: 2.0,
      );
    }

    if (dsp.containsKey('crossfeed')) {
      final cf = dsp['crossfeed'] as Map;
      final enabled = cf['enabled'] ?? false;
      final preset = (cf['preset'] as num?)?.toInt() ?? 1;
      player.setCrossfeed(enabled: enabled, preset: preset);
      await AppStateService.instance
          .saveCrossfeed(enabled: enabled, preset: preset);
    } else {
      player.setCrossfeed(enabled: false, preset: 1);
      await AppStateService.instance.saveCrossfeed(enabled: false, preset: 1);
    }

    if (dsp.containsKey('stereoWiden')) {
      final sw = dsp['stereoWiden'] as Map;
      final enabled = sw['enabled'] ?? false;
      final width = (sw['width'] as num?)?.toDouble() ?? 1.5;
      final delayMs = (sw['delayMs'] as num?)?.toDouble() ?? 15.0;
      await AppStateService.instance.saveStereoWiden(
        enabled: enabled,
        width: width,
        delayMs: delayMs,
      );
    } else {
      await AppStateService.instance.saveStereoWiden(
        enabled: false,
        width: 1.5,
        delayMs: 15.0,
      );
    }

    if (dsp.containsKey('stereoEnhancement')) {
      final se = dsp['stereoEnhancement'] as Map;
      final enabled = se['enabled'] ?? false;
      final mix = (se['mix'] as num?)?.toDouble() ?? 0.5;
      player.setStereoEnhancement(enabled: enabled, mix: mix);
      await AppStateService.instance
          .saveStereoEnhancement(enabled: enabled, mix: mix);
    } else {
      player.setStereoEnhancement(enabled: false);
      await AppStateService.instance.saveStereoEnhancement(
        enabled: false,
        mix: 0.5,
      );
    }

    if (dsp.containsKey('audioTuning')) {
      final at = dsp['audioTuning'] as Map;
      final enabled = at['enabled'] ?? false;
      final low = (at['low'] as num?)?.toDouble() ?? 0.0;
      final mid = (at['mid'] as num?)?.toDouble() ?? 0.0;
      final high = (at['high'] as num?)?.toDouble() ?? 0.0;
      player.setEqEnabled(enabled);
      player.setEq(low: low, mid: mid, high: high);
      await AppStateService.instance.saveAudioTuning(
        enabled: enabled,
        low: low,
        mid: mid,
        high: high,
      );
    } else {
      player.setEqEnabled(false);
      await AppStateService.instance.saveAudioTuning(
        enabled: false,
        low: 0.0,
        mid: 0.0,
        high: 0.0,
      );
    }

    if (dsp.containsKey('true3d')) {
      final t3d = dsp['true3d'] as Map;
      final enabled = t3d['enabled'] ?? false;
      final x = (t3d['x'] as num?)?.toDouble() ?? 0.0;
      final y = (t3d['y'] as num?)?.toDouble() ?? 0.0;
      final z = (t3d['z'] as num?)?.toDouble() ?? 0.0;
      player.setSpatializationEnabled(enabled);
      await AppStateService.instance
          .saveTrue3d(enabled: enabled, x: x, y: y, z: z);
    } else {
      player.setSpatializationEnabled(false);
      await AppStateService.instance.saveTrue3d(
        enabled: false,
        x: 0.0,
        y: 0.0,
        z: 0.0,
      );
    }

    if (dsp.containsKey('limiter')) {
      final l = dsp['limiter'] as Map;
      final enabled = l['enabled'] ?? false;
      final threshold = (l['threshold'] as num?)?.toDouble() ?? 0.95;
      final attack = (l['attackMs'] as num?)?.toDouble() ?? 2.0;
      final release = (l['releaseMs'] as num?)?.toDouble() ?? 50.0;
      player.setLimiterEnabled(enabled);
      await AppStateService.instance.saveLimiter(
        enabled: enabled,
        threshold: threshold,
        attackMs: attack,
        releaseMs: release,
      );
    } else {
      player.setLimiterEnabled(false);
      await AppStateService.instance.saveLimiter(
        enabled: false,
        threshold: 0.95,
        attackMs: 2.0,
        releaseMs: 50.0,
      );
    }

    if (dsp.containsKey('compressor')) {
      final c = dsp['compressor'] as Map;
      final enabled = c['enabled'] ?? false;
      final thresholdDb = (c['thresholdDb'] as num?)?.toDouble() ?? -20.0;
      final ratio = (c['ratio'] as num?)?.toDouble() ?? 4.0;
      final kneeDb = (c['kneeDb'] as num?)?.toDouble() ?? 6.0;
      final attackMs = (c['attackMs'] as num?)?.toDouble() ?? 10.0;
      final releaseMs = (c['releaseMs'] as num?)?.toDouble() ?? 100.0;
      final makeupGainDb = (c['makeupGainDb'] as num?)?.toDouble() ?? 0.0;
      final detector = (c['detector'] as num?)?.toInt() ?? 0;
      final stereoLink = c['stereoLink'] != false;
      final autoMakeup = c['autoMakeup'] == true;
      final mix = (c['mix'] as num?)?.toDouble() ?? 1.0;
      player.setCompressorEnabled(enabled);
      if (enabled) {
        player.setCompressorParams(
          thresholdDb: thresholdDb,
          ratio: ratio,
          kneeDb: kneeDb,
          attackMs: attackMs,
          releaseMs: releaseMs,
          makeupGainDb: makeupGainDb,
          detector: detector,
          stereoLink: stereoLink,
          autoMakeup: autoMakeup,
          mix: mix,
        );
      }
      await AppStateService.instance.saveCompressor(
        enabled: enabled,
        thresholdDb: thresholdDb,
        ratio: ratio,
        kneeDb: kneeDb,
        attackMs: attackMs,
        releaseMs: releaseMs,
        makeupGainDb: makeupGainDb,
        detector: detector,
        stereoLink: stereoLink,
        autoMakeup: autoMakeup,
        mix: mix,
      );
    } else {
      player.setCompressorEnabled(false);
      await AppStateService.instance.saveCompressor(
        enabled: false,
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
      );
    }

    // 3. Apply Sauti DSP Suite State
    final cleanDspState = <String, dynamic>{
      'dspMasterEnabled': profile.sautiDspState['dspMasterEnabled'] ?? false,
      'clarityEnabled': false,
      'dialogEnhancerEnabled': false,
      'bassEnabled': false,
      'dynamicSystemEnabled': false,
      'analogWarmthEnabled': false,
      'deEsserEnabled': false,
      'expanderEnabled': false,
      'convolverEnabled': false,
      'limiterEnabled': false,
      'surroundEnabled': false,
      ...profile.sautiDspState,
    };
    await AppStateService.instance.saveSautiDspState(cleanDspState);
    await EqScreen.applySavedStateToEngine(player);

    // 4. Save active profile ID & notify listeners
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_kActiveProfileIdKey, profile.id);
    _activeProfileController.add(profile);
    AppStateService.instance.eqSettingsChanged.add(null);
  }

  /// Exports an AudioProfile to a file on disk.
  Future<void> exportProfile(AudioProfile profile, String targetPath) async {
    final file = File(targetPath);
    await file.writeAsString(jsonEncode(profile.toJson()));
  }

  /// Imports an AudioProfile from a JSON file.
  Future<AudioProfile?> importProfile(String filePath) async {
    try {
      final file = File(filePath);
      if (!await file.exists()) return null;
      final content = await file.readAsString();
      final json = jsonDecode(content) as Map<String, dynamic>;
      final profile = AudioProfile.fromJson(json);
      // Give it a fresh ID and flag as custom
      final importedProfile = profile.copyWith(
        id: 'custom_${DateTime.now().millisecondsSinceEpoch}',
        isBuiltIn: false,
        createdAt: DateTime.now(),
        updatedAt: DateTime.now(),
      );
      await saveProfile(importedProfile);
      return importedProfile;
    } catch (e) {
      debugPrint('Error importing profile: $e');
      return null;
    }
  }

  /// Retrieves all profiles (built-in + saved custom ones).
  Future<List<AudioProfile>> getProfiles() async {
    final builtIn = _getBuiltInProfiles();
    final custom = await _getCustomProfiles();
    return [...builtIn, ...custom];
  }

  /// Saves or updates a custom AudioProfile.
  Future<void> saveProfile(AudioProfile profile) async {
    final prefs = await SharedPreferences.getInstance();
    final customProfiles = await _getCustomProfiles();
    final index = customProfiles.indexWhere((p) => p.id == profile.id);

    if (index >= 0) {
      customProfiles[index] = profile.copyWith(updatedAt: DateTime.now());
    } else {
      customProfiles.add(profile);
    }

    final rawJson = jsonEncode(customProfiles.map((p) => p.toJson()).toList());
    await prefs.setString(_kCustomProfilesKey, rawJson);
  }

  /// Deletes a custom profile by ID. Built-in profiles cannot be deleted.
  Future<bool> deleteProfile(String profileId) async {
    if (profileId.startsWith('builtin_')) return false;

    final prefs = await SharedPreferences.getInstance();
    final customProfiles = await _getCustomProfiles();
    final initialLength = customProfiles.length;
    customProfiles.removeWhere((p) => p.id == profileId);

    if (customProfiles.length != initialLength) {
      final rawJson =
          jsonEncode(customProfiles.map((p) => p.toJson()).toList());
      await prefs.setString(_kCustomProfilesKey, rawJson);
      return true;
    }
    return false;
  }

  Future<List<AudioProfile>> _getCustomProfiles() async {
    final prefs = await SharedPreferences.getInstance();
    final rawJson = prefs.getString(_kCustomProfilesKey);
    if (rawJson == null || rawJson.isEmpty) return [];

    try {
      final list = jsonDecode(rawJson) as List;
      return list
          .map((item) => AudioProfile.fromJson(item as Map<String, dynamic>))
          .toList();
    } catch (e) {
      debugPrint('Error loading custom profiles: $e');
      return [];
    }
  }

  /// Gets a specific profile by ID.
  Future<AudioProfile?> getProfileById(String id) async {
    final profiles = await getProfiles();
    try {
      return profiles.firstWhere((p) => p.id == id);
    } catch (_) {
      return null;
    }
  }

  /// Gets the currently active profile ID, defaulting to 'builtin_flat'.
  Future<String> getActiveProfileId() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(_kActiveProfileIdKey) ?? 'builtin_flat';
  }

  /// Gets the currently active AudioProfile.
  Future<AudioProfile> getActiveProfile() async {
    final id = await getActiveProfileId();
    final profile = await getProfileById(id);
    return profile ?? _getBuiltInProfiles().first;
  }

  /// Factory built-in profiles defined with precise, audiophile-grade contours.
  List<AudioProfile> _getBuiltInProfiles() {
    final defaultFrequencies = [
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

    return [
      AudioProfile(
        id: 'builtin_flat',
        name: 'Flat',
        category: 'Reference',
        description: 'Neutral frequency',
        isBuiltIn: true,
        createdAt: DateTime(2026, 1, 1),
        updatedAt: DateTime(2026, 1, 1),
        eqState: {
          'enabled': true,
          'preampDb': 0.0,
          'freqs': defaultFrequencies,
          'gains': List<double>.filled(10, 0.0),
          'parametricEnabled': false,
          'parametricPreset': 'Default (3-Band)',
          'parametricBands': [
            {
              'type': EqBandType.lowshelf.index,
              'frequency': 120.0,
              'gainDb': 0.0,
              'q': 1.0,
              'slope': 1.0,
              'enabled': true,
            },
            {
              'type': EqBandType.peak.index,
              'frequency': 1000.0,
              'gainDb': 0.0,
              'q': 1.2,
              'slope': 1.0,
              'enabled': true,
            },
            {
              'type': EqBandType.highshelf.index,
              'frequency': 9000.0,
              'gainDb': 0.0,
              'q': 1.0,
              'slope': 1.0,
              'enabled': true,
            },
          ],
        },
        dspEffectsState: {},
        sautiDspState: {'dspMasterEnabled': false},
      ),
      AudioProfile(
        id: 'builtin_basshead',
        name: 'Bass Extreme',
        category: 'Headphones',
        description: 'Sifted sub-bass slam',
        isBuiltIn: true,
        createdAt: DateTime(2026, 1, 1),
        updatedAt: DateTime(2026, 1, 1),
        eqState: {
          'enabled': false,
          'preampDb': -3.0,
          'freqs': defaultFrequencies,
          'gains': [0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0],
          'parametricEnabled': true,
          'parametricPreset': 'Bass & Sub Punch',
          'parametricBands': [
            {
              'type': EqBandType.highpass.index,
              'frequency': 28.0,
              'gainDb': 0.0,
              'q': 0.7,
              'slope': 1.0,
              'enabled': true,
            },
            {
              'type': EqBandType.lowshelf.index,
              'frequency': 60.0,
              'gainDb': 5.0,
              'q': 1.0,
              'slope': 1.2,
              'enabled': true,
            },
            {
              'type': EqBandType.peak.index,
              'frequency': 180.0,
              'gainDb': -2.8,
              'q': 1.6,
              'slope': 1.0,
              'enabled': true,
            },
            {
              'type': EqBandType.peak.index,
              'frequency': 2500.0,
              'gainDb': 1.0,
              'q': 1.2,
              'slope': 1.0,
              'enabled': true,
            },
            {
              'type': EqBandType.highshelf.index,
              'frequency': 10000.0,
              'gainDb': 2.0,
              'q': 1.0,
              'slope': 1.0,
              'enabled': true,
            },
          ],
        },
        dspEffectsState: {
          'dynamicBass': {
            'enabled': false,
            'preset': DynamicBassPreset.clubPaPunch.value,
            'gain': 10.0,
          },
          'limiter': {
            'enabled': true,
            'threshold': 0.95,
            'attackMs': 2.0,
            'releaseMs': 50.0,
          },
        },
        sautiDspState: {
          'dspMasterEnabled': false,
          'dynamicSystemEnabled': true,
          'dynamicSystemProfile': TransducerProfile.clubPAPunch.value,
          'dynamicSystemStrength': 0.80,
          'bassEnabled': false,
          'bassProfile': HarmonicBassProfile.subwoofer.value,
          'bassCutoffHz': 58.0,
          'bassBoost': 0.45,
          'analogWarmthEnabled': false,
          'analogWarmthProfile': AnalogWarmthProfile.triode12AX7.value,
          'analogWarmthDrive': 0.25,
          'clarityEnabled': true,
          'clarityProfile': AudioClarityProfile.transientCrisp.value,
          'clarityIntensity': 0.25,
          'limiterEnabled': true,
          'limiterCeilingDb': -0.2,
          'limiterReleaseMs': 50.0,
        },
      ),
      AudioProfile(
        id: 'builtin_vocal',
        name: 'Vocal',
        category: 'Genre',
        description: 'Crystal-clear speech',
        isBuiltIn: true,
        createdAt: DateTime(2026, 1, 1),
        updatedAt: DateTime(2026, 1, 1),
        eqState: {
          'enabled': true,
          'preampDb': -1.0,
          'freqs': defaultFrequencies,
          'gains': [-2.0, -1.5, -0.5, -1.0, 0.5, 1.5, 2.5, 2.0, 1.0, 0.0],
          'parametricEnabled': true,
          'parametricPreset': 'Vocal Clarity & Air',
          'parametricBands': [
            {
              'type': EqBandType.highpass.index,
              'frequency': 80.0,
              'gainDb': 0.0,
              'q': 0.7,
              'slope': 1.0,
              'enabled': true,
            },
            {
              'type': EqBandType.lowshelf.index,
              'frequency': 200.0,
              'gainDb': -2.0,
              'q': 1.0,
              'slope': 1.0,
              'enabled': true,
            },
            {
              'type': EqBandType.peak.index,
              'frequency': 1000.0,
              'gainDb': 1.0,
              'q': 1.0,
              'slope': 1.0,
              'enabled': true,
            },
            {
              'type': EqBandType.peak.index,
              'frequency': 3500.0,
              'gainDb': 3.5,
              'q': 1.4,
              'slope': 1.0,
              'enabled': true,
            },
            {
              'type': EqBandType.highshelf.index,
              'frequency': 12000.0,
              'gainDb': 2.5,
              'q': 1.0,
              'slope': 1.0,
              'enabled': true,
            },
          ],
        },
        dspEffectsState: {},
        sautiDspState: {
          'dspMasterEnabled': true,
          'clarityEnabled': true,
          'clarityProfile': AudioClarityProfile.presenceExciter.value,
          'clarityIntensity': 0.45,
          'dialogEnhancerEnabled': true,
          'dialogEnhancerProfile': DialogEnhancerProfile.voice.value,
          'dialogEnhancerAmount': 0.55,
          'dialogEnhancerDucking': 0.35,
          'dialogEnhancerClarity': 0.50,
          'dialogEnhancerCenterFocus': 0.70,
        },
      ),
      AudioProfile(
        id: 'builtin_rock',
        name: 'Rock',
        category: 'Genre',
        description: 'Punchy kick drums, crunchy electric guitars',
        isBuiltIn: true,
        createdAt: DateTime(2026, 1, 1),
        updatedAt: DateTime(2026, 1, 1),
        eqState: {
          'enabled': true,
          'preampDb': -2.0,
          'freqs': defaultFrequencies,
          'gains': [2.0, 3.0, 1.0, -1.5, -1.5, 0.0, 1.5, 2.5, 2.0, 1.5],
          'parametricEnabled': true,
          'parametricPreset': 'Rock & Metal Punch',
          'parametricBands': [
            {
              'type': EqBandType.lowshelf.index,
              'frequency': 85.0,
              'gainDb': 3.5,
              'q': 1.0,
              'slope': 1.2,
              'enabled': true,
            },
            {
              'type': EqBandType.peak.index,
              'frequency': 450.0,
              'gainDb': -2.5,
              'q': 1.6,
              'slope': 1.0,
              'enabled': true,
            },
            {
              'type': EqBandType.peak.index,
              'frequency': 2600.0,
              'gainDb': 3.0,
              'q': 1.8,
              'slope': 1.0,
              'enabled': true,
            },
            {
              'type': EqBandType.highshelf.index,
              'frequency': 8500.0,
              'gainDb': 2.5,
              'q': 1.0,
              'slope': 1.0,
              'enabled': true,
            },
          ],
        },
        dspEffectsState: {},
        sautiDspState: {
          'dspMasterEnabled': true,
          'analogWarmthEnabled': true,
          'analogWarmthProfile': AnalogWarmthProfile.triode12AX7.value,
          'analogWarmthDrive': 0.35,
          'clarityEnabled': true,
          'clarityProfile': AudioClarityProfile.transientCrisp.value,
          'clarityIntensity': 0.30,
        },
      ),
      AudioProfile(
        id: 'builtin_audiophile',
        name: 'Audiophile',
        category: 'Headphones',
        description: 'Natural binaural crossfeed ',
        isBuiltIn: true,
        createdAt: DateTime(2026, 1, 1),
        updatedAt: DateTime(2026, 1, 1),
        eqState: {
          'enabled': true,
          'preampDb': 0.0,
          'freqs': defaultFrequencies,
          'gains': [0.5, 0.5, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.5, 1.0],
          'parametricEnabled': true,
          'parametricPreset': 'Acoustic Guitar Natural',
          'parametricBands': [
            {
              'type': EqBandType.lowshelf.index,
              'frequency': 75.0,
              'gainDb': 1.5,
              'q': 1.0,
              'slope': 1.0,
              'enabled': true,
            },
            {
              'type': EqBandType.peak.index,
              'frequency': 3200.0,
              'gainDb': -1.0,
              'q': 2.0,
              'slope': 1.0,
              'enabled': true,
            },
            {
              'type': EqBandType.highshelf.index,
              'frequency': 11000.0,
              'gainDb': 2.0,
              'q': 1.0,
              'slope': 1.0,
              'enabled': true,
            },
          ],
        },
        dspEffectsState: {
          'crossfeed': {'enabled': true, 'preset': 4},
        },
        sautiDspState: {
          'dspMasterEnabled': true,
          'analogWarmthEnabled': true,
          'analogWarmthProfile': AnalogWarmthProfile.vintagePreamp.value,
          'analogWarmthDrive': 0.20,
          'clarityEnabled': true,
          'clarityProfile': AudioClarityProfile.airShelf.value,
          'clarityIntensity': 0.25,
          'dynamicSystemEnabled': true,
          'dynamicSystemProfile': TransducerProfile.audiophileReference.value,
          'dynamicSystemStrength': 0.30,
        },
      ),
      AudioProfile(
        id: 'builtin_cinema_3d',
        name: 'Spatial',
        category: 'Speakers',
        description: 'Binaural hrtf spatializer',
        isBuiltIn: true,
        createdAt: DateTime(2026, 1, 1),
        updatedAt: DateTime(2026, 1, 1),
        eqState: {
          'enabled': true,
          'preampDb': -1.5,
          'freqs': defaultFrequencies,
          'gains': [3.0, 2.5, 0.0, -0.5, 0.0, 0.5, 1.5, 1.5, 2.0, 2.5],
          'parametricEnabled': true,
          'parametricPreset': 'Smiley Loudness',
          'parametricBands': [
            {
              'type': EqBandType.highpass.index,
              'frequency': 25.0,
              'gainDb': 0.0,
              'q': 0.7,
              'slope': 1.0,
              'enabled': true,
            },
            {
              'type': EqBandType.lowshelf.index,
              'frequency': 70.0,
              'gainDb': 3.5,
              'q': 1.0,
              'slope': 1.2,
              'enabled': true,
            },
            {
              'type': EqBandType.peak.index,
              'frequency': 250.0,
              'gainDb': -1.5,
              'q': 1.4,
              'slope': 1.0,
              'enabled': true,
            },
            {
              'type': EqBandType.peak.index,
              'frequency': 3000.0,
              'gainDb': 1.5,
              'q': 1.2,
              'slope': 1.0,
              'enabled': true,
            },
            {
              'type': EqBandType.highshelf.index,
              'frequency': 9000.0,
              'gainDb': 2.5,
              'q': 1.0,
              'slope': 1.0,
              'enabled': true,
            },
          ],
        },
        dspEffectsState: {
          'spatial': {
            'enabled': false,
            'reverbMix': 0.10,
            'roomSize': 0.25,
            'echo': 0.05,
          },
        },
        sautiDspState: {
          'dspMasterEnabled': true,
          'surroundEnabled': true,
          'surroundMode': SurroundMode.acousticStage.value,
          'surroundStageProfile': 0,
          'surroundStageMode': 0,
          'surroundStageWidth': 1.25,
          'surroundStageDepth': 0.55,
          'surroundStageCancellation': 0.60,
          'surroundStageAirPresence': 0.40,
          'surroundStageBassAnchorHz': 60.0,
          'dynamicSystemEnabled': true,
          'dynamicSystemProfile': TransducerProfile.cinemaSubSlam.value,
          'dynamicSystemStrength': 0.45,
          'bassEnabled': true,
          'bassProfile': HarmonicBassProfile.subwoofer.value,
          'bassCutoffHz': 62.0,
          'bassBoost': 0.35,
          'dialogEnhancerEnabled': true,
          'dialogEnhancerProfile': DialogEnhancerProfile.cinema.value,
          'dialogEnhancerAmount': 0.45,
          'dialogEnhancerCenterFocus': 0.70,
        },
      ),
      AudioProfile(
        id: 'builtin_vintage',
        name: 'Vintage Vinyl',
        category: 'Genre',
        description: 'Analog roll-off for warm nostalgia.',
        isBuiltIn: true,
        createdAt: DateTime(2026, 1, 1),
        updatedAt: DateTime(2026, 1, 1),
        eqState: {
          'enabled': true,
          'preampDb': -1.0,
          'freqs': defaultFrequencies,
          'gains': [1.5, 2.0, 1.0, 0.8, 0.5, 0.0, -0.5, -1.0, -1.5, -2.5],
          'parametricEnabled': true,
          'parametricPreset': 'Warm Vintage Tube',
          'parametricBands': [
            {
              'type': EqBandType.lowshelf.index,
              'frequency': 100.0,
              'gainDb': 2.0,
              'q': 1.0,
              'slope': 1.0,
              'enabled': true,
            },
            {
              'type': EqBandType.peak.index,
              'frequency': 600.0,
              'gainDb': 1.0,
              'q': 0.8,
              'slope': 1.0,
              'enabled': true,
            },
            {
              'type': EqBandType.peak.index,
              'frequency': 3200.0,
              'gainDb': -1.5,
              'q': 1.5,
              'slope': 1.0,
              'enabled': true,
            },
            {
              'type': EqBandType.lowpass.index,
              'frequency': 16000.0,
              'gainDb': 0.0,
              'q': 0.7,
              'slope': 1.0,
              'enabled': true,
            },
          ],
        },
        dspEffectsState: {},
        sautiDspState: {
          'dspMasterEnabled': true,
          'analogWarmthEnabled': true,
          'analogWarmthProfile': AnalogWarmthProfile.magneticTape.value,
          'analogWarmthDrive': 0.38,
          'dynamicSystemEnabled': true,
          'dynamicSystemProfile': TransducerProfile.deepAcousticWarmth.value,
          'dynamicSystemStrength': 0.35,
        },
      ),
    ];
  }
}
