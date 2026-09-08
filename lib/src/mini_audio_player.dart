import 'dart:async';
import 'dart:ffi' as ffi;
import 'dart:typed_data';

import 'package:ffi/ffi.dart';
import 'package:http/http.dart' as http;

import '../audio_engine_ffi.dart';
import '../sauti_dsp.dart';
import 'miniaudio_filters.dart';
import 'mobile_system_audio.dart';

class MiniAudioPlayer {
  MiniAudioPlayer({
    String? libraryPath,
    Duration statusPollInterval = const Duration(milliseconds: 200),
    Duration analyzerPollInterval = const Duration(milliseconds: 33),
  })  : _engine = AudioEngineFFI(libraryPath: libraryPath),
        _statusPollInterval = statusPollInterval,
        _analyzerPollInterval = analyzerPollInterval;

  final AudioEngineFFI _engine;
  late final SautiDsp _dsp = SautiDsp.fromEngine(_engine);
  Duration _statusPollInterval;
  Duration _analyzerPollInterval;

  Duration get statusPollInterval => _statusPollInterval;
  set statusPollInterval(Duration interval) {
    _statusPollInterval = interval;
    _startStatusPolling();
  }

  Duration get analyzerPollInterval => _analyzerPollInterval;
  set analyzerPollInterval(Duration interval) {
    _analyzerPollInterval = interval;
    _startAnalyzerPolling();
  }

  final _statusController = StreamController<PlayerStatus>.broadcast();
  final _logController = StreamController<String>.broadcast();
  final _analyzerController = StreamController<Float32List>.broadcast();
  final _telemetryController = StreamController<StreamTelemetry>.broadcast();
  final _bufferingController = StreamController<bool>.broadcast();
  late final MiniAudioSystemAudioController _systemAudio =
      MiniAudioSystemAudioController(
    statusStream: _statusController.stream,
    onPlay: () {
      play();
    },
    onPause: () {
      pause();
    },
    onStop: () {
      stop();
    },
    onNext: () {
      seekToNext();
    },
    onPrevious: () {
      seekToPrevious();
    },
    onSeek: (position) {
      seekTo(position);
    },
    onSetGain: (gain) {
      setGain(gain);
    },
    onGetGain: () => _engine.getGain(),
    telemetryStream: _telemetryController.stream,
  );
  Timer? _statusTimer;
  Timer? _analyzerTimer;
  String _lastLog = '';
  bool _analyzerEnabled = false;
  bool _lastBuffering = false;

  Stream<PlayerStatus> get statusStream => _statusController.stream;
  Stream<String> get logStream => _logController.stream;
  Stream<Float32List> get analyzerStream => _analyzerController.stream;
  Stream<StreamTelemetry> get streamTelemetryStream => _telemetryController.stream;
  Stream<bool> get bufferingStream => _bufferingController.stream;

  /// Provides direct access to all Sauti clean-room DSP features.
  SautiDsp get dsp => _dsp;

  bool init({
    int sampleRate = 48000,
    int channels = 2,
    bool enableSystemAudio = false,
    MiniAudioSystemAudioConfig? systemAudioConfig,
    bool enableSafetyLimiter = true,
    bool enableAutoSampleRateMatch = false,
  }) {
    final ok = _engine.create(sampleRate: sampleRate, channels: channels);
    if (ok) {
      if (enableSafetyLimiter) {
        _engine.setLookaheadLimiterEnabled(true);
        _engine.setLookaheadLimiterParams(
          ceilingDBTP: -1.0,
          attackMs: 2.0,
          releaseMs: 50.0,
        );
      }
      if (enableAutoSampleRateMatch) {
        _engine.setAutoSampleRateMatchEnabled(true);
      }
      _startStatusPolling();
      _startAnalyzerPolling();
      if (enableSystemAudio) {
        unawaited(
          _systemAudio.enable(
            config: systemAudioConfig ?? const MiniAudioSystemAudioConfig(),
          ),
        );
      }
    }
    return ok;
  }

  void dispose() {
    unawaited(_systemAudio.disable());
    _statusTimer?.cancel();
    _analyzerTimer?.cancel();
    _statusController.close();
    _logController.close();
    _analyzerController.close();
    _telemetryController.close();
    _bufferingController.close();
    _engine.dispose();
  }

  bool setAudioSources(
    List<AudioSource> sources, {
    int initialIndex = 0,
    Duration initialPosition = Duration.zero,
    bool useLazyPreparation = true,
    bool autoPlay = true,
    Object? shuffleOrder,
  }) {
    final supportsNetwork = isNetworkStreamingSupported();
    for (final source in sources) {
      if (source.isNetwork && !supportsNetwork) {
        throw ArgumentError(
          'Network URLs are not supported in this native build (found: ${source.uri}). Rebuild with network streaming enabled, or use local files/pushStream().',
        );
      }
    }
    return _engine.setAudioSources(
      sources,
      initialIndex: initialIndex,
      initialPosition: initialPosition,
      useLazyPreparation: useLazyPreparation,
      autoPlay: autoPlay,
      shuffleOrder: shuffleOrder,
    );
  }

  bool addAudioSource(AudioSource source) {
    if (source.isNetwork && !isNetworkStreamingSupported()) {
      throw ArgumentError(
        'Network URLs are not supported in this native build (found: ${source.uri}). Rebuild with network streaming enabled, or use local files/pushStream().',
      );
    }
    return _engine.addAudioSourceUri(source.uri);
  }

  bool insertAudioSource(int index, AudioSource source) =>
      _engine.insertAudioSource(
        index,
        source.uri.scheme == 'file'
            ? source.uri.toFilePath()
            : source.uri.toString(),
      );
  bool removeAudioSourceAt(int index) => _engine.removeAudioSourceAt(index);
  void clearAudioSources() => _engine.clearPlaylist();
  bool moveAudioSource(int fromIndex, int toIndex) =>
      _engine.moveAudioSource(fromIndex, toIndex);

  bool play() {
    final ok = _engine.play();
    if (ok) _pollStatusNow();
    return ok;
  }

  bool pause() {
    final ok = _engine.pause();
    if (ok) _pollStatusNow();
    return ok;
  }

  bool stop() {
    final ok = _engine.stop();
    if (ok) _pollStatusNow();
    return ok;
  }

  bool seek(Duration position, {int? index}) {
    final ok = _engine.seekTo(position, index: index);
    if (ok) _pollStatusNow();
    return ok;
  }

  bool seekTo(Duration position, {int? index}) {
    final ok = _engine.seekTo(position, index: index);
    if (ok) _pollStatusNow();
    return ok;
  }

  bool seekToNext() {
    final ok = _engine.seekToNext();
    if (ok) _pollStatusNow();
    return ok;
  }

  bool seekToPrevious() {
    final ok = _engine.seekToPrevious();
    if (ok) _pollStatusNow();
    return ok;
  }

  void setLoopMode(LoopMode mode) => _engine.setLoopMode(mode);
  void setShuffleModeEnabled(bool enabled) =>
      _engine.setShuffleModeEnabled(enabled);
  void reshuffle() => _engine.reshuffle();
  void setAbRepeat({
    required bool enabled,
    double startSeconds = 0.0,
    double endSeconds = 0.0,
  }) =>
      _engine.setAbRepeat(
        enabled: enabled,
        startSeconds: startSeconds,
        endSeconds: endSeconds,
      );
  ({bool enabled, double startSeconds, double endSeconds}) getAbRepeat() =>
      _engine.getAbRepeat();
  void setCrossfadeEnabled(bool enabled) =>
      _engine.setCrossfadeEnabled(enabled);
  bool getCrossfadeEnabled() => _engine.getCrossfadeEnabled();
  void setCrossfadeDurationMs(int durationMs) =>
      _engine.setCrossfadeDurationMs(durationMs);
  int getCrossfadeDurationMs() => _engine.getCrossfadeDurationMs();
  void setLoudnessCrossfadeEnabled(bool enabled) =>
      _engine.setLoudnessCrossfadeEnabled(enabled);
  bool getLoudnessCrossfadeEnabled() => _engine.getLoudnessCrossfadeEnabled();
  void setNextReplayGain(double gainDb) => _engine.setNextReplayGain(gainDb);

  PlayerStatus get status => _engine.getStatus();
  double get deviceLatencyMs => _engine.getDeviceLatencyMs();
  double get engineLatencySamples => _engine.getEngineLatencySamples();
  double get engineLatencyMs => _engine.getEngineLatencyMs();
  PipelineAudioState get pipelineState => _engine.getPipelineState();
  String getLastError() => _engine.getLastError();
  void clearLastError() => _engine.clearLastError();
  TrackNativeInfo? inspectFile(String path) => _engine.inspectFile(path);
  AEHardwareInfo getHardwareInfo() => _engine.getHardwareInfo();
  AEHardwareInfo get hardwareInfo => getHardwareInfo();

  /// Sets the preferred audio output backend.
  bool setOutputBackend(AudioOutputBackend backend) =>
      _engine.setOutputBackend(backend);

  /// Gets the currently active audio output backend.
  AudioOutputBackend getOutputBackend() => _engine.getOutputBackend();

  /// Checks if a specific backend is supported on the current platform/device.
  bool isBackendSupported(AudioOutputBackend backend) =>
      _engine.isBackendSupported(backend);
  ResampleAlgorithm getEngineResampleAlgorithm() =>
      ResampleAlgorithm.values[_engine.getEngineResampleAlgorithm().clamp(0, ResampleAlgorithm.values.length - 1)];
  bool isNetworkStreamingSupported() => _engine.isNetworkStreamingSupported();
  StreamTelemetry get streamTelemetry => _engine.getStreamTelemetry();
  StreamTelemetry getStreamTelemetry() => _engine.getStreamTelemetry();
  bool isCurrentStreamLive() => _engine.isCurrentStreamLive();
  bool get isBuffering => _engine.getStreamTelemetry().isBuffering;
  bool get isLive => _engine.isCurrentStreamLive();
  int getPushStreamBufferedBytes() => _engine.getPushStreamBufferedBytes();
  int getAnalyzerFrameSize() => _engine.getAnalyzerFrameSize();
  int getAnalyzerDroppedFrames() => _engine.getAnalyzerDroppedFrames();
  bool get supportsSystemMediaControls => _systemAudio.isSupported;
  bool get systemMediaControlsEnabled => _systemAudio.isEnabled;

  void configureAnalyzer({int frameSize = 512, FftWindowType? windowType}) =>
      _engine.configureAnalyzer(frameSize, windowType);

  void setAnalyzerWindowType(FftWindowType windowType) =>
      _engine.configureAnalyzerWindow(windowType);

  FftWindowType getAnalyzerWindowType() => _engine.getAnalyzerWindowType();
  FftWindowType get analyzerWindowType => _engine.getAnalyzerWindowType();

  void setAnalyzerEnabled(bool enabled) {
    _analyzerEnabled = enabled;
    _engine.setAnalyzerEnabled(enabled);
  }

  Float32List getLatestAnalyzerFrame({int? maxSamples}) =>
      _engine.pollAnalyzerFrame(maxSamples: maxSamples);

  Future<bool> enableSystemMediaControls({
    MiniAudioSystemAudioConfig config = const MiniAudioSystemAudioConfig(),
  }) =>
      _systemAudio.enable(config: config);

  Future<void> disableSystemMediaControls() => _systemAudio.disable();

  Future<void> updateNowPlaying({
    required String title,
    String? artist,
    String? album,
    String? id,
    Duration? duration,
    Uri? artUri,
  }) =>
      _systemAudio.updateNowPlaying(
        title: title,
        artist: artist,
        album: album,
        id: id,
        duration: duration,
        artUri: artUri,
      );

  void setReverbEnabled(bool enabled) => _engine.setReverbEnabled(enabled);

  void setReverbParams({
    double mix = 0.5,
    double feedback = 0.5,
    double delayMs = 50.0,
  }) {
    _engine.setReverbParams(mix: mix, feedback: feedback, delayMs: delayMs);
  }

  /// Extended reverb (Freeverb FDN): independent wet/dry gains, room size,
  /// damping, pre-delay and width.
  void setReverbEx({
    required bool enabled,
    double wet = 0.25,
    double dry = 0.75,
    double roomSize = 0.6,
    double damping = 0.4,
    double preDelayMs = 20.0,
    double width = 1.0,
  }) {
    _engine.setReverbEnabled(enabled);
    // setReverbParamsEx derives dry from mix, so apply the independent
    // gains last to get the final wet/dry balance.
    _engine.setReverbParamsEx(
      mix: wet,
      roomSize: roomSize,
      damping: damping,
      preDelayMs: preDelayMs,
      width: width,
    );
    _engine.setReverbGains(wet: wet, dry: dry);
  }

  /// Live wet/dry gain update without touching the other reverb params.
  void setReverbGains({required double wet, required double dry}) =>
      _engine.setReverbGains(wet: wet, dry: dry);

  ReverbParamsEx getReverbParams() => _engine.getReverbParamsEx();

  void setOldEqEnabled(bool enabled) => _engine.setEqEnabled(enabled);

  void setOldEqGains({
    double lowGain = 1.0,
    double midGain = 1.0,
    double highGain = 1.0,
  }) {
    _engine.setEqGains(low: lowGain, mid: midGain, high: highGain);
  }

  // --- Advanced Audio Controls ---

  /// Request True Bit-Perfect Output (Exclusive Mode).
  /// Bypasses the system mixer and locks the DAC to the exact requested format.
  /// If the hardware rejects the format natively, it safely falls back to Shared mode.
  /// This will momentarily restart the audio connection.
  void setExclusiveMode(bool enabled) => _engine.setExclusiveMode(enabled);

  /// Check if the engine is actually running in Exclusive Mode successfully.
  bool getExclusiveMode() => _engine.getExclusiveMode();

  /// Enable or disable 64-bit floating point DSP processing mode (-320dB headroom).
  void set64BitProcessingEnabled(bool enabled) =>
      _engine.set64BitProcessingEnabled(enabled);

  /// Check if 64-bit floating point DSP processing mode is active.
  bool get is64BitProcessingEnabled => _engine.get64BitProcessingEnabled();

  /// Set native DSP oversampling factor (1 = off, 2 = 2x polyphase half-band, 4 = 4x polyphase cascaded).
  void setDspOversampling(int factor) => _engine.setDspOversampling(factor);

  /// Get current native DSP oversampling factor (1, 2, or 4).
  int get dspOversampling => _engine.getDspOversampling();

  /// Enable or disable Auto Sample-Rate Match hardware sample-rate matching.
  void setAutoSampleRateMatchEnabled(bool enabled) =>
      _engine.setAutoSampleRateMatchEnabled(enabled);

  /// Check if Auto Sample-Rate Match hardware sample-rate matching is enabled.
  bool get isAutoSampleRateMatchEnabled => _engine.getAutoSampleRateMatchEnabled();

  /// Deprecated alias for [setAutoSampleRateMatchEnabled].
  void setAutoBitPerfectEnabled(bool enabled) => setAutoSampleRateMatchEnabled(enabled);

  /// Deprecated alias for [isAutoSampleRateMatchEnabled].
  bool get isAutoBitPerfectEnabled => isAutoSampleRateMatchEnabled;

  /// Poll for a deferred Auto Bit-Perfect sample-rate switch signalled by the
  /// native worker thread. Returns the new target sample rate (> 0) if one is
  /// pending, or 0 if nothing to do.
  ///
  /// When non-zero, call [setOutputSampleRate] with the returned value — this
  /// triggers [restart_and_apply_config] safely from the Dart/control thread.
  int consumePendingRateChange() => _engine.consumePendingRateChange();

  /// Set the desired output audio format (f32, s16, u8).
  /// This may cause the audio engine to restart.
  void setOutputFormat(AudioFormat format) => _engine.setOutputFormat(format);

  /// Get the current output audio format.
  AudioFormat getOutputFormat() => _engine.getOutputFormat();

  /// Set the desired output sample rate (e.g., 44100, 48000).
  /// Set to 0 to use the device's native sample rate.
  /// This may cause the audio engine to restart.
  void setOutputSampleRate(int rate) => _engine.setOutputSampleRate(rate);

  /// Get the current output sample rate (0 usually means native/auto).
  int getOutputSampleRate() => _engine.getOutputSampleRate();

  /// Set number of output channels.
  void setOutputChannels(int channels) => _engine.setOutputChannels(channels);

  /// Get output channel count.
  int getOutputChannels() => _engine.getOutputChannels();

  /// Set custom fixed output buffer size (period frames) and period count.
  /// Set [periodFrames] to 0 or [periodCount] to 0 to revert to auto/driver defaults.
  void setOutputBuffer({int periodFrames = 0, int periodCount = 0}) =>
      _engine.setOutputBuffer(periodFrames: periodFrames, periodCount: periodCount);

  /// Get configured fixed output buffer parameters (periodFrames, periodCount).
  ({int periodFrames, int periodCount}) getOutputBuffer() =>
      _engine.getOutputBuffer();

  /// Set Phase Inversion (180° polarity flip) for Left and Right channels.
  void setPhaseInversion({required bool invertLeft, required bool invertRight}) =>
      _engine.setPhaseInversion(invertLeft: invertLeft, invertRight: invertRight);

  /// Get current Phase Inversion status.
  ({bool left, bool right}) getPhaseInversion() => _engine.getPhaseInversion();

  /// Enable or disable Left/Right output channel swapping.
  void setLrSwap(bool enabled) => _engine.setLrSwap(enabled);

  /// Check if Left/Right channel swap is active.
  bool getLrSwap() => _engine.getLrSwap();

  /// Set linear channel gains for Left and Right channels.
  void setChannelGains({required double leftLinear, required double rightLinear}) =>
      _engine.setChannelGains(leftLinear: leftLinear, rightLinear: rightLinear);

  /// Set per-channel gains in dB for Left and Right channels (-12 dB to +12 dB).
  void setChannelGainsDb({required double leftDb, required double rightDb}) =>
      _engine.setChannelGainsDb(leftDb: leftDb, rightDb: rightDb);

  /// Get current per-channel gains as linear multipliers.
  ({double left, double right}) getChannelGains() => _engine.getChannelGains();

  /// Get current per-channel gains in dB.
  ({double left, double right}) getChannelGainsDb() => _engine.getChannelGainsDb();

  /// Initialize the multiband equalizer.
  /// provide a list of center frequencies (Hz) for the bands.
  /// Optional [qFactors] lists the Q factor for each band (defaults to 1.0).
  /// Example 10-band ISO: [31.25, 62.5, 125, 250, 500, 1000, 2000, 4000, 8000, 16000]
  void initMultibandEq(List<double> frequencies, {List<double>? qFactors}) =>
      _engine.initMultibandEq(
        frequencies.length,
        frequencies,
        qFactors: qFactors,
      );

  /// Enable or disable the multiband equalizer.
  void setMultibandEqEnabled(bool enabled) =>
      _engine.setMultibandEqEnabled(enabled);

  /// Set the gain (in dB) for a specific EQ band.
  void setMultibandEqBandGain(int bandIndex, double gainDb) =>
      _engine.setMultibandEqGain(bandIndex, gainDb);

  /// Get the current gain (in dB) for a specific EQ band.
  double getMultibandEqBandGain(int bandIndex) =>
      _engine.getMultibandEqGain(bandIndex);

  /// Configure a mixed multiband FX chain where each band can be a different
  /// filter type (peak, bandpass, notch, lowshelf, highshelf).
  void initMultibandFx(List<EqBandConfig> bands, {bool enabled = true}) {
    _engine.setMultibandFxBands(bands);
    _engine.setMultibandFxEnabled(enabled);
  }

  /// Replace all bands in the mixed multiband FX chain.
  void setMultibandFxBands(List<EqBandConfig> bands) =>
      _engine.setMultibandFxBands(bands);

  /// Enable or disable the mixed multiband FX chain.
  void setMultibandFxEnabled(bool enabled) =>
      _engine.setMultibandFxEnabled(enabled);

  /// Clears all mixed multiband FX bands and disables the chain.
  void clearMultibandFx() => _engine.clearMultibandFx();

  void setReverb({
    required double mix,
    required double feedback,
    required double delayMs,
  }) {
    _engine.setReverbParams(mix: mix, feedback: feedback, delayMs: delayMs);
  }

  void setEqEnabled(bool enabled) => _engine.setEqEnabled(enabled);
  void setEq({required double low, required double mid, required double high}) {
    _engine.setEqGains(low: low, mid: mid, high: high);
  }
  void setEqDb({
    required double lowDb,
    required double midDb,
    required double highDb,
  }) {
    _engine.setEqGainsDb(lowDb: lowDb, midDb: midDb, highDb: highDb);
  }

  void setGain(double gain) => _engine.setGain(gain);
  void setReplayGain(double gainDb) => _engine.setReplayGain(gainDb);
  
  /// Sets master volume using a perceptual cubic curve (0.0 to 1.0)
  /// mapping linear slider movement to natural human loudness perception.
  void setVolume(double volume) {
    final clamped = volume.clamp(0.0, 1.0);
    // Cubic perceptual volume curve
    final linear = clamped * clamped * clamped;
    _engine.setGain(linear);
  }

  /// Sets master volume in dB (e.g. 0.0 dB for full volume, -6.0 dB for ~50%, -60.0 dB for silence).
  void setVolumeDb(double gainDb) => _engine.setVolumeDb(gainDb);

  /// Returns the current master volume in dB.
  double getVolumeDb() => _engine.getVolumeDb();

  void setPan(double pan) => _engine.setPan(pan);

  /// Sets playback rate / speed (e.g. 1.0 = normal, 1.5 = 1.5x speed).
  Future<void> setRate(double rate) async => _engine.setRate(rate);

  /// Returns the current playback rate / speed.
  double get rate => _engine.getRate();

  /// Sets musical pitch factor (e.g. 1.0 = normal, 0.9 = lower pitch without affecting speed).
  Future<void> setPitch(double pitch) async => _engine.setPitch(pitch);

  /// Returns the current pitch factor.
  double get pitch => _engine.getPitch();

  /// Enables or disables pitch correction (scaletempo algorithm).
  /// When enabled (default), changing speed preserves original pitch.
  Future<void> setPitchCorrection(bool enabled) async =>
      _engine.setPitchCorrection(enabled);

  /// Returns whether pitch correction (scaletempo) is enabled.
  bool get pitchCorrectionEnabled => _engine.getPitchCorrection();

  // --- Spatialization ---
  void setSpatializationEnabled(bool enabled) =>
      _engine.setSpatializationEnabled(enabled);
  void setPosition({required double x, required double y, required double z}) =>
      _engine.setPosition(x: x, y: y, z: z);
  void setDirection(
          {required double x, required double y, required double z}) =>
      _engine.setDirection(x: x, y: y, z: z);
  void setVelocity({required double x, required double y, required double z}) =>
      _engine.setVelocity(x: x, y: y, z: z);
  void setSoundCone({
    required double innerAngleRad,
    required double outerAngleRad,
    required double outerGain,
  }) =>
      _engine.setSoundCone(
        innerAngleRad: innerAngleRad,
        outerAngleRad: outerAngleRad,
        outerGain: outerGain,
      );
  void setAttenuationModel(int model) => _engine.setAttenuationModel(model);
  void setRolloff(double rolloff) => _engine.setRolloff(rolloff);
  void setMinGain(double minGain) => _engine.setMinGain(minGain);
  void setMaxGain(double maxGain) => _engine.setMaxGain(maxGain);
  void setMinDistance(double minDistance) =>
      _engine.setMinDistance(minDistance);
  void setMaxDistance(double maxDistance) =>
      _engine.setMaxDistance(maxDistance);
  void setDopplerFactor(double dopplerFactor) =>
      _engine.setDopplerFactor(dopplerFactor);

  void setListenerPosition(
          {required double x, required double y, required double z}) =>
      _engine.setListenerPosition(x: x, y: y, z: z);
  void setListenerDirection(
          {required double x, required double y, required double z}) =>
      _engine.setListenerDirection(x: x, y: y, z: z);
  void setListenerVelocity(
          {required double x, required double y, required double z}) =>
      _engine.setListenerVelocity(x: x, y: y, z: z);
  void setListenerWorldUp(
          {required double x, required double y, required double z}) =>
      _engine.setListenerWorldUp(x: x, y: y, z: z);
  void setListenerCone({
    required double innerAngleRad,
    required double outerAngleRad,
    required double outerGain,
  }) =>
      _engine.setListenerCone(
        innerAngleRad: innerAngleRad,
        outerAngleRad: outerAngleRad,
        outerGain: outerGain,
      );

  // --- Fading & Scheduling ---
  void setFade(double startVol, double endVol, int durationMs) =>
      _engine.setFade(startVol, endVol, durationMs);
  void scheduleStartTimeInPcmFrames(int absoluteTime) =>
      _engine.scheduleStartTimeInPcmFrames(absoluteTime);
  void scheduleStopTimeInPcmFrames(int absoluteTime) =>
      _engine.scheduleStopTimeInPcmFrames(absoluteTime);
  int getEngineTimeInPcmFrames() => _engine.getEngineTimeInPcmFrames();
  void setEndCallback(
      ffi.Pointer<
              ffi.NativeFunction<
                  ffi.Void Function(
                      ffi.Pointer<ffi.Void>, ffi.Pointer<ffi.Void>)>>
          callback,
      ffi.Pointer<ffi.Void> userData) {
    _engine.setEndCallback(callback, userData);
  }

  void setLowpass({required bool enabled, required double cutoffHz}) {
    _engine.setLowpassEnabled(enabled);
    _engine.setLowpassCutoff(cutoffHz);
  }

  void setHighpass({required bool enabled, required double cutoffHz}) {
    _engine.setHighpassEnabled(enabled);
    _engine.setHighpassCutoff(cutoffHz);
  }

  void setDelay({
    required bool enabled,
    required double mix,
    required double feedback,
    required double delayMs,
  }) {
    _engine.setDelayEnabled(enabled);
    _engine.setDelayParams(mix: mix, feedback: feedback, delayMs: delayMs);
  }

  void setStereoWiden({
    required bool enabled,
    required double width,
    required double delayMs,
  }) {
    _engine.setStereoWiden(enabled: enabled, width: width, delayMs: delayMs);
  }

  void setStereoEnhancement({
    required bool enabled,
    double mix = 0.5,
  }) {
    _engine.setStereoEnhancementEnabled(enabled);
    _engine.setStereoEnhancementMix(mix);
  }

  void setCrossfeed({required bool enabled, required int preset}) {
    _engine.setCrossfeedEnabled(enabled);
    _engine.setCrossfeedPreset(preset);
  }

  void setCrossfeedAlgorithm(CrossfeedAlgorithm algorithm) =>
      _engine.setCrossfeedAlgorithm(algorithm);

  void setCrossfeedParams({
    required double mix,
    required double delayMs,
    required double cutoffHz,
    bool outputCompensation = true,
  }) =>
      _engine.setCrossfeedParams(
        mix: mix,
        delayMs: delayMs,
        cutoffHz: cutoffHz,
        outputCompensation: outputCompensation,
      );

  CrossfeedParams getCrossfeedParams() => _engine.getCrossfeedParams();

  void setRaceParams({
    double delayMs = 0.166,
    double alpha = 0.55,
    double lpfHz = 2500.0,
  }) {
    _engine.setRaceParams(delayMs: delayMs, alpha: alpha, lpfHz: lpfHz);
  }

  /// Enable or configure Dynamic Multi-Pole Resonant Bass with 19 hardware-tuned presets.
  ///
  /// [enabled] – main on/off switch.
  /// [preset]  – acoustic profile index (0..18, default: 18 - Ultimate Subwoofer):
  ///   * 0: Smooth Natural Sub (140Hz / 6.2kHz / 40Hz / 60Hz)
  ///   * 1: Punchy In-Ear (180Hz / 5.8kHz / 55Hz / 80Hz)
  ///   * 2: Warm Over-Ear (300Hz / 5.6kHz / 60Hz / 105Hz)
  ///   * 3: Deep Acoustic (600Hz / 5.4kHz / 60Hz / 105Hz)
  ///   * 4: Wide Dynamic (100Hz / 5.6kHz / 40Hz / 80Hz)
  ///   * 5: Sub-Bass Boom (1.2kHz / 6.2kHz / 40Hz / 80Hz)
  ///   * 6: Tight Sub (1.0kHz / 6.2kHz / 40Hz / 80Hz)
  ///   * 7: Solid Impact (800Hz / 6.2kHz / 40Hz / 80Hz)
  ///   * 8: Clean Kick (400Hz / 6.2kHz / 40Hz / 80Hz)
  ///   * 9: Rich Low-End (1.2kHz / 6.2kHz / 50Hz / 90Hz)
  ///   * 10: Club PA Punch (1.0kHz / 6.2kHz / 50Hz / 90Hz)
  ///   * 11: Basshead Heavy (1.1kHz / 6.2kHz / 60Hz / 100Hz)
  ///   * 12: Resonant Rumble (1.2kHz / 6.2kHz / 50Hz / 100Hz)
  ///   * 13: Cinema Sub (1.2kHz / 6.2kHz / 60Hz / 100Hz)
  ///   * 14: Car Audio Slam (1.2kHz / 6.2kHz / 40Hz / 80Hz)
  ///   * 15: Audiophile Reference (1.0kHz / 6.2kHz / 60Hz / 100Hz)
  ///   * 16: Studio Monitor Lows (1.0kHz / 6.2kHz / 60Hz / 120Hz)
  ///   * 17: Deep Sub Extension (1.0kHz / 6.2kHz / 80Hz / 140Hz)
  ///   * 18: Ultimate Subwoofer (800Hz / 6.2kHz / 80Hz / 140Hz)
  /// [gain]    – boost level in dB [0.0 – 24.0 dB] (default: 15.0 dB).
  void setDynamicBass({
    required bool enabled,
    int preset = 18,
    double gain = 15.0,
  }) {
    _engine.setDynamicBassEnabled(enabled);
    _engine.setDynamicBassParams(preset: preset, gain: gain);
  }

  /// Enable or disable the Crystalizer and set its parameters.
  ///
  /// [enabled]          – main on/off switch.
  /// [intensity]        – transient reconstruction strength [0.0 – 1.0].
  /// [highShelfEnabled] – add "air" high-shelf above 8 kHz.
  /// [highShelfGainDb]  – shelf boost in dB [0.0 – 6.0].
  void setCrystalizer({
    required bool enabled,
    double intensity = 0.5,
    bool highShelfEnabled = true,
    double highShelfGainDb = 2.0,
  }) {
    _engine.setCrystalizerEnabled(enabled);
    _engine.setCrystalizerParams(
      intensity: intensity,
      highShelfEnabled: highShelfEnabled,
      highShelfGainDb: highShelfGainDb,
    );
  }

  void setBandpass({
    required bool enabled,
    required double cutoffHz,
    double q = 0.707,
  }) {
    _engine.setBandpassEnabled(enabled);
    _engine.setBandpassParams(cutoffHz: cutoffHz, q: q);
  }

  void setPeakEq({
    required bool enabled,
    required double gainDb,
    required double q,
    required double frequencyHz,
  }) {
    _engine.setPeakEqEnabled(enabled);
    _engine.setPeakEqParams(gainDb: gainDb, q: q, frequencyHz: frequencyHz);
  }

  void setNotch({
    required bool enabled,
    required double q,
    required double frequencyHz,
  }) {
    _engine.setNotchEnabled(enabled);
    _engine.setNotchParams(q: q, frequencyHz: frequencyHz);
  }

  void setLowshelf({
    required bool enabled,
    required double gainDb,
    double slope = 1.0,
    required double frequencyHz,
  }) {
    _engine.setLowshelfEnabled(enabled);
    _engine.setLowshelfParams(
      gainDb: gainDb,
      slope: slope,
      frequencyHz: frequencyHz,
    );
  }

  void setHighshelf({
    required bool enabled,
    required double gainDb,
    double slope = 1.0,
    required double frequencyHz,
  }) {
    _engine.setHighshelfEnabled(enabled);
    _engine.setHighshelfParams(
      gainDb: gainDb,
      slope: slope,
      frequencyHz: frequencyHz,
    );
  }

  void setCustomLpf1({required bool enabled, required double cutoffHz}) {
    _engine.setCustomLpf1Params(enabled: enabled, cutoffHz: cutoffHz);
  }

  void setCustomHpf1({required bool enabled, required double cutoffHz}) {
    _engine.setCustomHpf1Params(enabled: enabled, cutoffHz: cutoffHz);
  }

  void setCustomBiquad({
    required bool enabled,
    required double b0,
    required double b1,
    required double b2,
    required double a0,
    required double a1,
    required double a2,
  }) {
    _engine.setCustomBiquadParams(
      enabled: enabled,
      b0: b0,
      b1: b1,
      b2: b2,
      a0: a0,
      a1: a1,
      a2: a2,
    );
  }

  void setEngineResampleAlgorithm(ResampleAlgorithm algorithm) {
    _engine.setEngineResampleAlgorithm(algorithm.index);
  }

  void setEngineDitherMode(int ditherMode) {
    _engine.setEngineDitherMode(ditherMode);
  }

  int getEngineDitherMode() => _engine.getEngineDitherMode();

  // --- Limiter & Clipping Detection ---

  /// Enable or disable the soft limiter.
  void setLimiterEnabled(bool enabled) => _engine.setLimiterEnabled(enabled);

  /// Configure limiter parameters.
  /// [threshold] linear amplitude ceiling (0.1–1.0, default 0.95).
  /// [attackMs]  attack time in ms (0.1–100, default 2).
  /// [releaseMs] release time in ms (10–1000, default 50).
  void setLimiterParams({
    double threshold = 0.95,
    double attackMs = 2.0,
    double releaseMs = 50.0,
  }) =>
      _engine.setLimiterParams(
        threshold: threshold,
        attackMs: attackMs,
        releaseMs: releaseMs,
      );

  /// Enable or disable clipping detection.
  void setClippingDetectionEnabled(bool enabled) =>
      _engine.setClippingDetectionEnabled(enabled);

  /// Total number of samples that exceeded ±1.0 since last reset.
  int getClippedSamplesCount() => _engine.getClippedSamplesCount();

  /// Reset the clipped-sample counter to zero.
  void resetClippedSamplesCount() => _engine.resetClippedSamplesCount();

  // --- Dynamic Range Compressor ---

  /// Enable or disable the compressor.
  void setCompressorEnabled(bool enabled) =>
      _engine.setCompressorEnabled(enabled);

  /// Configure compressor parameters.
  ///
  /// [thresholdDb]  – level where compression starts in dB (-60 – 0, default -20).
  /// [ratio]        – compression ratio 1:1 – 20:1 (default 4).
  /// [kneeDb]       – soft knee width in dB (0 – 24, default 6).
  /// [attackMs]     – attack time in ms (0.1 – 100, default 10).
  /// [releaseMs]    – release time in ms (10 – 1000, default 100).
  /// [makeupGainDb] – static make-up gain in dB (0 – 24, default 0).
  /// [detector]     – 0 = peak, 1 = RMS (default peak).
  /// [stereoLink]   – true = linked stereo gain, false = dual mono.
  /// [autoMakeup]   – derive make-up gain from threshold/ratio.
  /// [mix]          – dry/wet mix 0.0 – 1.0 (default 1.0 = fully compressed).
  void setCompressorParams({
    double thresholdDb = -20.0,
    double ratio = 4.0,
    double kneeDb = 6.0,
    double attackMs = 10.0,
    double releaseMs = 100.0,
    double makeupGainDb = 0.0,
    int detector = 0,
    bool stereoLink = true,
    bool autoMakeup = false,
    double mix = 1.0,
  }) =>
      _engine.setCompressorParams(
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

  /// Current gain reduction in dB applied by the compressor.
  double getCompressorGainReductionDB() =>
      _engine.getCompressorGainReductionDB();

  // ── Release 1 Quality Foundation API ────────────────────────────────────────

  /// Fetch live ITU-R BS.1770-4 / EBU R128 loudness metrics.
  AELoudnessMetrics getLoudnessMetrics() => _engine.getLoudnessMetrics();

  /// Reset accumulated loudness measurements.
  void resetLoudnessMeter() => _engine.resetLoudnessMeter();

  /// Enable or disable live ITU/EBU loudness normalizer.
  void setLoudnessNormalizerEnabled(bool enabled) =>
      _engine.setLoudnessNormalizerEnabled(enabled);

  /// Set the loudness normalizer target in LUFS (e.g. -14.0 LUFS).
  void setLoudnessNormalizerTarget(double targetLUFS) =>
      _engine.setLoudnessNormalizerTarget(targetLUFS);

  /// Fetch 4x oversampled True-Peak metrics in dBTP.
  AETruePeakMetrics getTruePeak() => _engine.getTruePeak();

  /// Whether the Look-Ahead True-Peak Limiter is currently enabled.
  bool get isLookaheadLimiterEnabled => _engine.isLookaheadLimiterEnabled;

  /// Enable or disable the Look-Ahead True-Peak Limiter.
  void setLookaheadLimiterEnabled(bool enabled) =>
      _engine.setLookaheadLimiterEnabled(enabled);

  /// Configure Look-Ahead Limiter parameters.
  void setLookaheadLimiterParams({
    double ceilingDBTP = -1.0,
    double attackMs = 2.0,
    double releaseMs = 50.0,
  }) =>
      _engine.setLookaheadLimiterParams(
        ceilingDBTP: ceilingDBTP,
        attackMs: attackMs,
        releaseMs: releaseMs,
      );

  /// Get current gain reduction in dB applied by the Look-Ahead Limiter.
  double getLookaheadLimiterGainReductionDB() =>
      _engine.getLookaheadLimiterGainReductionDB();

  /// Fetch unified quality telemetry snapshot.
  AEQualityTelemetry getQualityTelemetry() => _engine.getQualityTelemetry();

  /// Fetch resampling policy info snapshot (latency, passband ratio, linear phase status, bypass state).
  AEResamplingPolicyInfo getResamplingPolicyInfo() =>
      _engine.getResamplingPolicyInfo();

  /// Resampling policy info getter.
  AEResamplingPolicyInfo get resamplingPolicyInfo =>
      _engine.getResamplingPolicyInfo();

  /// Returns current linear output gain.
  double getGain() => _engine.getGain();

  /// Polls the latest PCM frame from the analyzer buffer.
  Float32List pollAnalyzerFrame({int? maxSamples, Float32List? targetBuffer}) =>
      _engine.pollAnalyzerFrame(
        maxSamples: maxSamples,
        targetBuffer: targetBuffer,
      );

  Future<void> pushStream({
    required String url,
    int bufferThreshold = 32 * 1024,
  }) async {
    _engine.initPushStream();

    final client = http.Client();
    ffi.Pointer<ffi.Uint8>? sharedBuf;
    int sharedBufCap = 0;
    try {
      final request = http.Request('GET', Uri.parse(url));
      final response = await client.send(request);

      int bytesReceived = 0;
      bool playbackStarted = false;

      await for (final chunk in response.stream) {
        final size = chunk.length;
        if (size == 0) continue;

        if (sharedBuf == null || sharedBufCap < size) {
          if (sharedBuf != null && sharedBuf != ffi.nullptr) {
            calloc.free(sharedBuf);
          }
          sharedBufCap = size < 65536 ? 65536 : size;
          sharedBuf = calloc<ffi.Uint8>(sharedBufCap);
        }

        final list = sharedBuf.asTypedList(size);
        list.setAll(0, chunk);

        _engine.pushStreamChunk(sharedBuf, size);

        bytesReceived += size;
        if (!playbackStarted && bytesReceived >= bufferThreshold) {
          play();
          playbackStarted = true;
        }
      }
    } catch (e) {
      rethrow;
    } finally {
      if (sharedBuf != null && sharedBuf != ffi.nullptr) {
        calloc.free(sharedBuf);
      }
      client.close();
      _engine.endPushStream();
    }
  }

  void _pollStatusNow() {
    if (_statusController.isClosed) return;
    _statusController.add(_engine.getStatus());

    if (!_telemetryController.isClosed) {
      final tel = _engine.getStreamTelemetry();
      _telemetryController.add(tel);
      if (tel.isBuffering != _lastBuffering && !_bufferingController.isClosed) {
        _lastBuffering = tel.isBuffering;
        _bufferingController.add(tel.isBuffering);
      }
    }
  }

  void _startStatusPolling() {
    _statusTimer?.cancel();
    _statusTimer = Timer.periodic(_statusPollInterval, (_) {
      if (_statusController.isClosed) return;
      _pollStatusNow();

      if (!_logController.isClosed) {
        final msg = _engine.getLastError();
        if (msg.isNotEmpty && msg != _lastLog) {
          _lastLog = msg;
          _logController.add(msg);
        }
      }

      // Auto Bit-Perfect: check if the native worker thread has signalled a
      // deferred sample-rate change. Apply it here — we are on the isolate
      // event-loop (the "control thread"), so restart_and_apply_config is safe
      // to call and will not race with the audio device callback.
      final pendingRate = _engine.consumePendingRateChange();
      if (pendingRate > 0) {
        _engine.setOutputSampleRate(pendingRate);
      }
    });
  }

  void _startAnalyzerPolling() {
    _analyzerTimer?.cancel();
    _analyzerTimer = Timer.periodic(analyzerPollInterval, (_) {
      if (_analyzerController.isClosed || !_analyzerEnabled) return;
      final frame = _engine.pollAnalyzerFrame();
      if (frame.isNotEmpty) {
        _analyzerController.add(frame);
      }
    });
  }
}
