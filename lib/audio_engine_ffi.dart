import 'dart:convert';
import 'dart:ffi' as ffi;
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:ffi/ffi.dart';
import 'package:http/http.dart' as http;
import 'src/m3u_parser.dart';

enum LoopMode { off, all, one }

enum AudioFormat { f32, s16, u8, s24, s32 }

enum EqBandType {
  peak,
  bandpass,
  notch,
  lowshelf,
  highshelf,
  lowpass,
  highpass
}

enum AttenuationModel { none, inverse, linear, exponential }

/// Mirrors CrossfeedAlgorithm in crossfeed_node.h — must stay in sync.
enum CrossfeedAlgorithm { off, simple, bs2b, meier, natural, race }

/// Immutable value-class returned by [MiniaudioPlayer.getCrossfeedParams].
class CrossfeedParams {
  const CrossfeedParams({
    required this.algorithm,
    required this.mix,
    required this.delayMs,
    required this.cutoffHz,
    required this.outputCompensation,
  });

  final CrossfeedAlgorithm algorithm;

  /// Wet/dry mix [0.0 – 1.0].
  final double mix;

  /// Inter-aural delay in milliseconds.
  final double delayMs;

  /// Low-pass cut-off frequency in Hz.
  final double cutoffHz;

  /// Whether the node applies output-level compensation.
  final bool outputCompensation;

  @override
  String toString() =>
      'CrossfeedParams(algo: $algorithm, mix: $mix, delayMs: $delayMs, '
      'cutoff: $cutoffHz Hz, compensation: $outputCompensation)';
}

/// Immutable value-class returned by [AudioEngine.getReverbParamsEx].
class ReverbParamsEx {
  const ReverbParamsEx({
    this.enabled = false,
    this.mix = 0.0,
    this.roomSize = 0.5,
    this.damping = 0.5,
    this.preDelayMs = 20.0,
    this.width = 1.0,
  });

  final bool enabled;

  /// Dry/wet blend [0.0 – 1.0].
  final double mix;

  /// Decay / room size [0.0 – 1.0].
  final double roomSize;

  /// High-frequency absorption [0.0 – 1.0].
  final double damping;

  /// Pre-delay in milliseconds [0 – 250].
  final double preDelayMs;

  /// Stereo width [0.0 – 1.0].
  final double width;

  @override
  String toString() =>
      'ReverbParamsEx(enabled: $enabled, mix: $mix, roomSize: $roomSize, '
      'damping: $damping, preDelayMs: $preDelayMs, width: $width)';
}

class EqBandConfig {
  const EqBandConfig({
    required this.type,
    required this.frequencyHz,
    this.enabled = true,
    this.q = 1.0,
    this.gainDb = 0.0,
    this.slope = 1.0,
  });

  final EqBandType type;
  final double frequencyHz;
  final bool enabled;
  final double q;
  final double gainDb;
  final double slope;
}

enum StreamPlaybackState {
  idle,
  connecting,
  buffering,
  ready,
  playing,
  ended,
  error,
}

class StreamTelemetry {
  final StreamPlaybackState state;
  final int errorCode;
  final Duration bufferedDuration;
  final Duration totalDuration;
  final double bufferPercent;
  final int bitrate;
  final String codecName;
  final String icyTitle;
  final String icyArtist;
  final bool isLive;
  final bool isSeekable;

  const StreamTelemetry({
    this.state = StreamPlaybackState.idle,
    this.errorCode = 0,
    this.bufferedDuration = Duration.zero,
    this.totalDuration = Duration.zero,
    this.bufferPercent = 0.0,
    this.bitrate = 0,
    this.codecName = '',
    this.icyTitle = '',
    this.icyArtist = '',
    this.isLive = false,
    this.isSeekable = true,
  });

  bool get isBuffering =>
      state == StreamPlaybackState.buffering ||
      state == StreamPlaybackState.connecting;
  bool get isPlaying => state == StreamPlaybackState.playing;
  bool get isEnded => state == StreamPlaybackState.ended;
  bool get hasError => state == StreamPlaybackState.error;

  @override
  String toString() =>
      'StreamTelemetry(state: $state, buffered: ${bufferedDuration.inSeconds}s, '
      'total: ${totalDuration.inSeconds}s, bufferPct: ${bufferPercent.toStringAsFixed(1)}%, '
      'bitrate: ${bitrate ~/ 1000}kbps, codec: $codecName, icy: "$icyArtist - $icyTitle", isLive: $isLive, isSeekable: $isSeekable)';
}

class AudioSource {
  final Uri uri;
  final String? title;
  final String? artist;
  final Duration? duration;

  const AudioSource.uri(
    this.uri, {
    this.title,
    this.artist,
    this.duration,
  });

  factory AudioSource.file(
    String path, {
    String? title,
    String? artist,
    Duration? duration,
  }) =>
      AudioSource.uri(
        Uri.file(path),
        title: title,
        artist: artist,
        duration: duration,
      );

  factory AudioSource.network(
    String url, {
    String? title,
    String? artist,
    Duration? duration,
  }) =>
      AudioSource.uri(
        Uri.parse(url),
        title: title,
        artist: artist,
        duration: duration,
      );

  bool get isNetwork => uri.scheme == 'http' || uri.scheme == 'https';

  /// Parses an M3U/M3U8 playlist string and expands it into a list of [AudioSource] instances.
  static List<AudioSource> fromM3uContent(
    String content, {
    String? baseDirectory,
  }) {
    final entries = M3uParser.parse(content, baseDirectory: baseDirectory);
    return entries.map((entry) {
      final dur = entry.durationSeconds >= 0
          ? Duration(seconds: entry.durationSeconds)
          : null;
      if (entry.isNetwork) {
        return AudioSource.network(
          entry.pathOrUrl,
          title: entry.title,
          artist: entry.artist,
          duration: dur,
        );
      } else {
        return AudioSource.file(
          entry.pathOrUrl,
          title: entry.title,
          artist: entry.artist,
          duration: dur,
        );
      }
    }).toList();
  }

  /// Asynchronously loads an M3U/M3U8 playlist from a local file path or remote HTTP/HTTPS URL
  /// and expands it into a [List<AudioSource>].
  static Future<List<AudioSource>> fromM3u(String pathOrUrl) async {
    final isUrl =
        pathOrUrl.startsWith('http://') || pathOrUrl.startsWith('https://');
    if (isUrl) {
      final response = await http.get(Uri.parse(pathOrUrl));
      if (response.statusCode == 200) {
        return fromM3uContent(response.body);
      } else {
        throw Exception(
          'Failed to fetch M3U playlist from network (Status ${response.statusCode})',
        );
      }
    } else {
      final file = File(pathOrUrl);
      if (!await file.exists()) {
        throw FileSystemException('M3U playlist file not found', pathOrUrl);
      }
      final content = await file.readAsString();
      return fromM3uContent(content, baseDirectory: file.parent.path);
    }
  }
}

typedef _MallocNative = ffi.Pointer<ffi.Void> Function(ffi.IntPtr);
typedef _MallocDart = ffi.Pointer<ffi.Void> Function(int);
typedef _FreeNative = ffi.Void Function(ffi.Pointer<ffi.Void>);
typedef _FreeDart = void Function(ffi.Pointer<ffi.Void>);

final class PlayerStatusNative extends ffi.Struct {
  @ffi.Double()
  external double position_seconds;

  @ffi.Double()
  external double duration_seconds;

  @ffi.Int32()
  external int is_playing;

  @ffi.Int32()
  external int current_index;

  @ffi.Int32()
  external int playlist_count;

  @ffi.Int32()
  external int shuffle_enabled;

  @ffi.Int32()
  external int loop_mode;
}

final class PipelineStateNative extends ffi.Struct {
  @ffi.Int32()
  external int input_format;
  @ffi.Int32()
  external int input_sample_rate;
  @ffi.Int32()
  external int input_channels;

  @ffi.Int32()
  external int processing_format;
  @ffi.Int32()
  external int processing_sample_rate;
  @ffi.Int32()
  external int processing_channels;

  @ffi.Int32()
  external int output_format;
  @ffi.Int32()
  external int output_sample_rate;
  @ffi.Int32()
  external int output_channels;

  @ffi.Int32()
  external int eq_enabled;
  @ffi.Int32()
  external int reverb_enabled;
  @ffi.Int32()
  external int limiter_enabled;
  @ffi.Int32()
  external int stereo_widen_enabled;
  @ffi.Int32()
  external int stereo_enhancement_enabled;
  @ffi.Int32()
  external int spatialization_enabled;
  @ffi.Int32()
  external int delay_enabled;

  @ffi.Float()
  external double gain;
  @ffi.Float()
  external double pan;
  @ffi.Float()
  external double pitch;
  @ffi.Float()
  external double rate;
  @ffi.Int32()
  external int pitch_correction_enabled;
}

final class AETrackInfoNative extends ffi.Struct {
  @ffi.Int32()
  external int sample_rate;

  @ffi.Int32()
  external int bit_depth;

  @ffi.Int32()
  external int channels;

  @ffi.Int32()
  external int bitrate_kbps;

  @ffi.Int32()
  external int is_float;

  @ffi.Double()
  external double duration_secs;

  @ffi.Int64()
  external int file_size_bytes;

  @ffi.Array(32)
  external ffi.Array<ffi.Uint8> format_name;
}

class TrackNativeInfo {
  final int sampleRate;
  final int bitDepth;
  final int channels;
  final int bitrateKbps;
  final bool isFloat;
  final double durationSecs;
  final int fileSizeBytes;
  final String formatName;

  const TrackNativeInfo({
    required this.sampleRate,
    required this.bitDepth,
    required this.channels,
    required this.bitrateKbps,
    required this.isFloat,
    required this.durationSecs,
    required this.fileSizeBytes,
    required this.formatName,
  });

  factory TrackNativeInfo.fromNative(AETrackInfoNative native) {
    final bytes = <int>[];
    for (int i = 0; i < 32; i++) {
      final b = native.format_name[i];
      if (b == 0) break;
      bytes.add(b);
    }
    final fmtStr = String.fromCharCodes(bytes).trim();
    return TrackNativeInfo(
      sampleRate: native.sample_rate,
      bitDepth: native.bit_depth,
      channels: native.channels,
      bitrateKbps: native.bitrate_kbps,
      isFloat: native.is_float != 0,
      durationSecs: native.duration_secs,
      fileSizeBytes: native.file_size_bytes,
      formatName: fmtStr.isNotEmpty ? fmtStr : 'AUDIO',
    );
  }

  Map<String, dynamic> toJson() => {
        'sampleRate': sampleRate,
        'bitDepth': bitDepth,
        'channels': channels,
        'bitrateKbps': bitrateKbps,
        'isFloat': isFloat,
        'durationSecs': durationSecs,
        'fileSizeBytes': fileSizeBytes,
        'formatName': formatName,
      };
}

final class AEHardwareInfoNative extends ffi.Struct {
  @ffi.Array(32)
  external ffi.Array<ffi.Uint8> backend_name;

  @ffi.Array(256)
  external ffi.Array<ffi.Uint8> device_name;

  @ffi.Array(128)
  external ffi.Array<ffi.Uint8> dsp_hardware;

  @ffi.Array(64)
  external ffi.Array<ffi.Uint8> soc_name;

  @ffi.Int32()
  external int output_format;

  @ffi.Int32()
  external int bit_depth;

  @ffi.Int32()
  external int is_float;

  @ffi.Int32()
  external int sample_rate;

  @ffi.Int32()
  external int channels;

  @ffi.Uint32()
  external int period_size_frames;

  @ffi.Uint32()
  external int period_count;

  @ffi.Double()
  external double latency_ms;

  @ffi.Int32()
  external int is_exclusive_mode;

  @ffi.Int32()
  external int is_direct_pcm;
}

/// Audio output backends supported by the engine.
enum AudioOutputBackend {
  auto(0, 'Auto (System Optimal)'),
  aaudio(1, 'AAudio (Android Low-Latency)'),
  openSl(2, 'OpenSL ES (Android Legacy Fallback)'),
  audioTrack(3, 'AudioTrack (Java Audio Subsystem)'),
  directHiRes(4, 'Direct Hi-Res (Bit-Perfect Direct HAL / DAC)');

  final int value;
  final String displayName;
  const AudioOutputBackend(this.value, this.displayName);

  static AudioOutputBackend fromInt(int value) {
    for (final b in AudioOutputBackend.values) {
      if (b.value == value) return b;
    }
    return AudioOutputBackend.auto;
  }
}

class AEHardwareInfo {
  final String backendName;
  final String deviceName;
  final AudioFormat outputFormat;
  final int bitDepth;
  final bool isFloat;
  final int sampleRate;
  final int channels;
  final int periodSizeFrames;
  final int periodCount;
  final double latencyMs;
  final bool isExclusiveMode;
  final String dspHardware;
  final String socName;
  final bool isDirectPcm;

  const AEHardwareInfo({
    required this.backendName,
    required this.deviceName,
    required this.outputFormat,
    required this.bitDepth,
    required this.isFloat,
    required this.sampleRate,
    required this.channels,
    required this.periodSizeFrames,
    required this.periodCount,
    required this.latencyMs,
    required this.isExclusiveMode,
    this.dspHardware = 'Host Native Audio',
    this.socName = 'Host Processor',
    this.isDirectPcm = false,
  });

  factory AEHardwareInfo.fromNative(AEHardwareInfoNative native) {
    final bBytes = <int>[];
    for (int i = 0; i < 32; i++) {
      final b = native.backend_name[i];
      if (b == 0) break;
      bBytes.add(b);
    }
    final dBytes = <int>[];
    for (int i = 0; i < 256; i++) {
      final b = native.device_name[i];
      if (b == 0) break;
      dBytes.add(b);
    }
    final dspBytes = <int>[];
    for (int i = 0; i < 128; i++) {
      final b = native.dsp_hardware[i];
      if (b == 0) break;
      dspBytes.add(b);
    }
    final socBytes = <int>[];
    for (int i = 0; i < 64; i++) {
      final b = native.soc_name[i];
      if (b == 0) break;
      socBytes.add(b);
    }

    AudioFormat fmt = AudioFormat.f32;
    if (native.output_format >= 0 &&
        native.output_format < AudioFormat.values.length) {
      fmt = AudioFormat.values[native.output_format];
    }

    return AEHardwareInfo(
      backendName: String.fromCharCodes(bBytes).trim(),
      deviceName: String.fromCharCodes(dBytes).trim(),
      outputFormat: fmt,
      bitDepth: native.bit_depth,
      isFloat: native.is_float != 0,
      sampleRate: native.sample_rate,
      channels: native.channels,
      periodSizeFrames: native.period_size_frames,
      periodCount: native.period_count,
      latencyMs: native.latency_ms,
      isExclusiveMode: native.is_exclusive_mode != 0,
      dspHardware: String.fromCharCodes(dspBytes).trim(),
      socName: String.fromCharCodes(socBytes).trim(),
      isDirectPcm: native.is_direct_pcm != 0,
    );
  }

  Map<String, dynamic> toJson() => {
        'backendName': backendName,
        'deviceName': deviceName,
        'outputFormat': outputFormat.name,
        'bitDepth': bitDepth,
        'isFloat': isFloat,
        'sampleRate': sampleRate,
        'channels': channels,
        'periodSizeFrames': periodSizeFrames,
        'periodCount': periodCount,
        'latencyMs': latencyMs,
        'isExclusiveMode': isExclusiveMode,
        'dspHardware': dspHardware,
        'socName': socName,
        'isDirectPcm': isDirectPcm,
      };
}

final class AELoudnessMetricsNative extends ffi.Struct {
  @ffi.Float()
  external double momentary_lufs;
  @ffi.Float()
  external double short_term_lufs;
  @ffi.Float()
  external double integrated_lufs;
  @ffi.Float()
  external double loudness_range_lra;
}

class AELoudnessMetrics {
  final double momentaryLUFS;
  final double shortTermLUFS;
  final double integratedLUFS;
  final double loudnessRangeLRA;

  const AELoudnessMetrics({
    required this.momentaryLUFS,
    required this.shortTermLUFS,
    required this.integratedLUFS,
    required this.loudnessRangeLRA,
  });

  factory AELoudnessMetrics.fromNative(AELoudnessMetricsNative native) {
    return AELoudnessMetrics(
      momentaryLUFS: native.momentary_lufs,
      shortTermLUFS: native.short_term_lufs,
      integratedLUFS: native.integrated_lufs,
      loudnessRangeLRA: native.loudness_range_lra,
    );
  }
}

final class AETruePeakMetricsNative extends ffi.Struct {
  @ffi.Float()
  external double left_dbtp;
  @ffi.Float()
  external double right_dbtp;
  @ffi.Float()
  external double max_dbtp;
}

class AETruePeakMetrics {
  final double leftDBTP;
  final double rightDBTP;
  final double maxDBTP;

  const AETruePeakMetrics({
    required this.leftDBTP,
    required this.rightDBTP,
    required this.maxDBTP,
  });

  factory AETruePeakMetrics.fromNative(AETruePeakMetricsNative native) {
    return AETruePeakMetrics(
      leftDBTP: native.left_dbtp,
      rightDBTP: native.right_dbtp,
      maxDBTP: native.max_dbtp,
    );
  }
}

final class AEQualityTelemetryNative extends ffi.Struct {
  @ffi.Float()
  external double sample_peak_db;
  @ffi.Float()
  external double true_peak_dbtp;
  @ffi.Float()
  external double momentary_lufs;
  @ffi.Float()
  external double short_term_lufs;
  @ffi.Float()
  external double integrated_lufs;
  @ffi.Float()
  external double loudness_range_lra;
  @ffi.Float()
  external double crest_factor_db;
  @ffi.Float()
  external double limiter_gain_reduction_db;
  @ffi.Double()
  external double resampler_latency_ms;
  @ffi.Double()
  external double total_engine_latency_ms;
  @ffi.Uint64()
  external int clipped_samples_count;
  @ffi.Uint64()
  external int underrun_count;
}

class AEQualityTelemetry {
  final double samplePeakDB;
  final double truePeakDBTP;
  final double momentaryLUFS;
  final double shortTermLUFS;
  final double integratedLUFS;
  final double loudnessRangeLRA;
  final double crestFactorDB;
  final double limiterGainReductionDB;
  final double resamplerLatencyMs;
  final double totalEngineLatencyMs;
  final int clippedSamplesCount;
  final int underrunCount;

  const AEQualityTelemetry({
    required this.samplePeakDB,
    required this.truePeakDBTP,
    required this.momentaryLUFS,
    required this.shortTermLUFS,
    required this.integratedLUFS,
    required this.loudnessRangeLRA,
    required this.crestFactorDB,
    required this.limiterGainReductionDB,
    required this.resamplerLatencyMs,
    required this.totalEngineLatencyMs,
    required this.clippedSamplesCount,
    required this.underrunCount,
  });

  factory AEQualityTelemetry.fromNative(AEQualityTelemetryNative native) {
    return AEQualityTelemetry(
      samplePeakDB: native.sample_peak_db,
      truePeakDBTP: native.true_peak_dbtp,
      momentaryLUFS: native.momentary_lufs,
      shortTermLUFS: native.short_term_lufs,
      integratedLUFS: native.integrated_lufs,
      loudnessRangeLRA: native.loudness_range_lra,
      crestFactorDB: native.crest_factor_db,
      limiterGainReductionDB: native.limiter_gain_reduction_db,
      resamplerLatencyMs: native.resampler_latency_ms,
      totalEngineLatencyMs: native.total_engine_latency_ms,
      clippedSamplesCount: native.clipped_samples_count,
      underrunCount: native.underrun_count,
    );
  }
}

typedef _CreateEngineNative = ffi.Pointer<ffi.Void> Function(
    ffi.Int32, ffi.Int32);
typedef _CreateEngineDart = ffi.Pointer<ffi.Void> Function(int, int);

typedef _DestroyEngineNative = ffi.Void Function(ffi.Pointer<ffi.Void>);
typedef _DestroyEngineDart = void Function(ffi.Pointer<ffi.Void>);

typedef _SetPlaylistNative = ffi.Uint8 Function(
  ffi.Pointer<ffi.Void>,
  ffi.Pointer<ffi.Pointer<ffi.Char>>,
  ffi.Int32,
);
typedef _SetPlaylistDart = int Function(
  ffi.Pointer<ffi.Void>,
  ffi.Pointer<ffi.Pointer<ffi.Char>>,
  int,
);

typedef _AddToPlaylistNative = ffi.Uint8 Function(
    ffi.Pointer<ffi.Void>, ffi.Pointer<ffi.Char>);
typedef _AddToPlaylistDart = int Function(
    ffi.Pointer<ffi.Void>, ffi.Pointer<ffi.Char>);

typedef _InsertToPlaylistNative = ffi.Uint8 Function(
    ffi.Pointer<ffi.Void>, ffi.Int32, ffi.Pointer<ffi.Char>);
typedef _InsertToPlaylistDart = int Function(
    ffi.Pointer<ffi.Void>, int, ffi.Pointer<ffi.Char>);

typedef _RemoveFromPlaylistNative = ffi.Uint8 Function(
    ffi.Pointer<ffi.Void>, ffi.Int32);
typedef _RemoveFromPlaylistDart = int Function(ffi.Pointer<ffi.Void>, int);

typedef _MovePlaylistItemNative = ffi.Uint8 Function(
    ffi.Pointer<ffi.Void>, ffi.Int32, ffi.Int32);
typedef _MovePlaylistItemDart = int Function(ffi.Pointer<ffi.Void>, int, int);

typedef _ClearPlaylistNative = ffi.Void Function(ffi.Pointer<ffi.Void>);
typedef _ClearPlaylistDart = void Function(ffi.Pointer<ffi.Void>);

typedef _BoolOpNative = ffi.Uint8 Function(ffi.Pointer<ffi.Void>);
typedef _BoolOpDart = int Function(ffi.Pointer<ffi.Void>);

typedef _SeekNative = ffi.Uint8 Function(ffi.Pointer<ffi.Void>, ffi.Double);
typedef _SeekDart = int Function(ffi.Pointer<ffi.Void>, double);

typedef _JumpNative = ffi.Uint8 Function(ffi.Pointer<ffi.Void>, ffi.Int32);
typedef _JumpDart = int Function(ffi.Pointer<ffi.Void>, int);

typedef _JumpWithPositionNative = ffi.Uint8 Function(
    ffi.Pointer<ffi.Void>, ffi.Int32, ffi.Double);
typedef _JumpWithPositionDart = int Function(
    ffi.Pointer<ffi.Void>, int, double);

typedef _SetIntNative = ffi.Void Function(ffi.Pointer<ffi.Void>, ffi.Int32);
typedef _SetIntDart = void Function(ffi.Pointer<ffi.Void>, int);
typedef _GetIntNative = ffi.Int32 Function(ffi.Pointer<ffi.Void>);
typedef _GetIntDart = int Function(ffi.Pointer<ffi.Void>);
typedef _GetFloatNative = ffi.Float Function(ffi.Pointer<ffi.Void>);
typedef _GetFloatDart = double Function(ffi.Pointer<ffi.Void>);

typedef _SetAbRepeatNative = ffi.Void Function(
    ffi.Pointer<ffi.Void>, ffi.Int32, ffi.Double, ffi.Double);
typedef _SetAbRepeatDart = void Function(
    ffi.Pointer<ffi.Void>, int, double, double);

typedef _GetAbRepeatNative = ffi.Void Function(ffi.Pointer<ffi.Void>,
    ffi.Pointer<ffi.Int32>, ffi.Pointer<ffi.Double>, ffi.Pointer<ffi.Double>);
typedef _GetAbRepeatDart = void Function(ffi.Pointer<ffi.Void>,
    ffi.Pointer<ffi.Int32>, ffi.Pointer<ffi.Double>, ffi.Pointer<ffi.Double>);

typedef _GetDeviceLatencyMsNative = ffi.Float Function(ffi.Pointer<ffi.Void>);
typedef _GetDeviceLatencyMsDart = double Function(ffi.Pointer<ffi.Void>);

typedef _GetEngineLatencySamplesNative = ffi.Double Function(
    ffi.Pointer<ffi.Void>);
typedef _GetEngineLatencySamplesDart = double Function(ffi.Pointer<ffi.Void>);

typedef _GetEngineLatencyMsNative = ffi.Double Function(ffi.Pointer<ffi.Void>);
typedef _GetEngineLatencyMsDart = double Function(ffi.Pointer<ffi.Void>);

typedef _GetStatusNative = PlayerStatusNative Function(ffi.Pointer<ffi.Void>);
typedef _GetStatusDart = PlayerStatusNative Function(ffi.Pointer<ffi.Void>);

typedef _GetPipelineStateNative = PipelineStateNative Function(
    ffi.Pointer<ffi.Void>);
typedef _GetPipelineStateDart = PipelineStateNative Function(
    ffi.Pointer<ffi.Void>);

typedef _GetLastErrorNative = ffi.Pointer<ffi.Char> Function(
  ffi.Pointer<ffi.Void>,
);
typedef _GetLastErrorDart = ffi.Pointer<ffi.Char> Function(
  ffi.Pointer<ffi.Void>,
);

typedef _ClearLastErrorNative = ffi.Void Function(ffi.Pointer<ffi.Void>);
typedef _ClearLastErrorDart = void Function(ffi.Pointer<ffi.Void>);

typedef _SetFxEnabledNative = ffi.Void Function(
    ffi.Pointer<ffi.Void>, ffi.Int32);
typedef _SetFxEnabledDart = void Function(ffi.Pointer<ffi.Void>, int);

typedef _SetReverbParamsNative = ffi.Void Function(
    ffi.Pointer<ffi.Void>, ffi.Float, ffi.Float, ffi.Float);
typedef _SetReverbParamsDart = void Function(
    ffi.Pointer<ffi.Void>, double, double, double);

// ae_set_reverb_params_ex(AudioEngineHandle*, mix, room_size, damping, pre_delay_ms, width)
typedef _SetReverbParamsExNative = ffi.Void Function(ffi.Pointer<ffi.Void>,
    ffi.Float, ffi.Float, ffi.Float, ffi.Float, ffi.Float);
typedef _SetReverbParamsExDart = void Function(ffi.Pointer<ffi.Void>, double,
    double, double, double, double);

// ae_get_reverb_params_ex(AudioEngineHandle*, int* enabled, float* mix,
//   float* room_size, float* damping, float* pre_delay_ms, float* width)
typedef _GetReverbParamsExNative = ffi.Void Function(
    ffi.Pointer<ffi.Void>,
    ffi.Pointer<ffi.Int32>,
    ffi.Pointer<ffi.Float>,
    ffi.Pointer<ffi.Float>,
    ffi.Pointer<ffi.Float>,
    ffi.Pointer<ffi.Float>,
    ffi.Pointer<ffi.Float>);
typedef _GetReverbParamsExDart = void Function(
    ffi.Pointer<ffi.Void>,
    ffi.Pointer<ffi.Int32>,
    ffi.Pointer<ffi.Float>,
    ffi.Pointer<ffi.Float>,
    ffi.Pointer<ffi.Float>,
    ffi.Pointer<ffi.Float>,
    ffi.Pointer<ffi.Float>);

// ae_set_reverb_gains(AudioEngineHandle*, wet, dry)
typedef _SetReverbGainsNative = ffi.Void Function(
    ffi.Pointer<ffi.Void>, ffi.Float, ffi.Float);
typedef _SetReverbGainsDart = void Function(
    ffi.Pointer<ffi.Void>, double, double);

// ae_get_reverb_gains(AudioEngineHandle*, float* wet, float* dry)
typedef _GetReverbGainsNative = ffi.Void Function(
    ffi.Pointer<ffi.Void>, ffi.Pointer<ffi.Float>, ffi.Pointer<ffi.Float>);
typedef _GetReverbGainsDart = void Function(ffi.Pointer<ffi.Void>,
    ffi.Pointer<ffi.Float>, ffi.Pointer<ffi.Float>);

typedef _SetEqGainsNative = ffi.Void Function(
    ffi.Pointer<ffi.Void>, ffi.Float, ffi.Float, ffi.Float);
typedef _SetEqGainsDart = void Function(
    ffi.Pointer<ffi.Void>, double, double, double);

// Custom Filter Typedefs
typedef _SetCustomLpf1ParamsNative = ffi.Void Function(
    ffi.Pointer<ffi.Void>, ffi.Int32, ffi.Double);
typedef _SetCustomLpf1ParamsDart = void Function(
    ffi.Pointer<ffi.Void>, int, double);

typedef _SetCustomBiquadParamsNative = ffi.Void Function(
    ffi.Pointer<ffi.Void>,
    ffi.Int32,
    ffi.Double,
    ffi.Double,
    ffi.Double,
    ffi.Double,
    ffi.Double,
    ffi.Double);
typedef _SetCustomBiquadParamsDart = void Function(
    ffi.Pointer<ffi.Void>, int, double, double, double, double, double, double);

typedef _SetSingleFloatNative = ffi.Void Function(
    ffi.Pointer<ffi.Void>, ffi.Float);
typedef _SetSingleFloatDart = void Function(ffi.Pointer<ffi.Void>, double);
typedef _SetTwoFloatsNative = ffi.Void Function(
    ffi.Pointer<ffi.Void>, ffi.Float, ffi.Float);
typedef _SetTwoFloatsDart = void Function(
    ffi.Pointer<ffi.Void>, double, double);

// Spatialization Typedefs
// ae_set_spatialization_enabled(AudioEngineHandle *engine, int enabled)
typedef _SetSpatializationEnabledNative = ffi.Void Function(
    ffi.Pointer<ffi.Void>, ffi.Int32);
typedef _SetSpatializationEnabledDart = void Function(
    ffi.Pointer<ffi.Void>, int);

// ae_set_position, ae_set_direction, ae_set_velocity (engine, x, y, z)
typedef _SetSpatializationVec3Native = ffi.Void Function(
    ffi.Pointer<ffi.Void>, ffi.Float, ffi.Float, ffi.Float);
typedef _SetSpatializationVec3Dart = void Function(
    ffi.Pointer<ffi.Void>, double, double, double);

// ae_set_sound_cone, ae_set_listener_cone (engine, inner_angle_rad, outer_angle_rad, outer_gain)
typedef _SetConeNative = ffi.Void Function(
    ffi.Pointer<ffi.Void>, ffi.Float, ffi.Float, ffi.Float);
typedef _SetConeDart = void Function(
    ffi.Pointer<ffi.Void>, double, double, double);

typedef _SetSingleIntNative = ffi.Void Function(
    ffi.Pointer<ffi.Void>, ffi.Int32);
typedef _SetSingleIntDart = void Function(ffi.Pointer<ffi.Void>, int);

// Fading & Scheduling
typedef _SetFadeInMillisecondsNative = ffi.Void Function(
    ffi.Pointer<ffi.Void>, ffi.Float, ffi.Float, ffi.Int32);
typedef _SetFadeInMillisecondsDart = void Function(
    ffi.Pointer<ffi.Void>, double, double, int);

typedef _SetStereoWidenNative = ffi.Void Function(
    ffi.Pointer<ffi.Void>, ffi.Int32, ffi.Float, ffi.Float);
typedef _SetStereoWidenDart = void Function(
    ffi.Pointer<ffi.Void>, int, double, double);

typedef _SetStereoEnhancementEnabledNative = ffi.Void Function(
    ffi.Pointer<ffi.Void>, ffi.Int32);
typedef _SetStereoEnhancementEnabledDart = void Function(
    ffi.Pointer<ffi.Void>, int);

typedef _GetStereoEnhancementEnabledNative = ffi.Int32 Function(
    ffi.Pointer<ffi.Void>);
typedef _GetStereoEnhancementEnabledDart = int Function(ffi.Pointer<ffi.Void>);

typedef _SetStereoEnhancementMixNative = ffi.Void Function(
    ffi.Pointer<ffi.Void>, ffi.Float);
typedef _SetStereoEnhancementMixDart = void Function(
    ffi.Pointer<ffi.Void>, double);

typedef _GetStereoEnhancementMixNative = ffi.Float Function(
    ffi.Pointer<ffi.Void>);
typedef _GetStereoEnhancementMixDart = double Function(ffi.Pointer<ffi.Void>);

typedef _SetDynamicBassParamsNative = ffi.Void Function(
    ffi.Pointer<ffi.Void>, ffi.Int32, ffi.Float);
typedef _SetDynamicBassParamsDart = void Function(
    ffi.Pointer<ffi.Void>, int, double);

typedef _SetRaceParamsNative = ffi.Void Function(
    ffi.Pointer<ffi.Void>, ffi.Float, ffi.Float, ffi.Float);
typedef _SetRaceParamsDart = void Function(
    ffi.Pointer<ffi.Void>, double, double, double);

// ─── CrossfeedNode new API ────────────────────────────────────────────────────
// ae_set_crossfeed_algorithm(AudioEngineHandle*, int)
typedef _SetCrossfeedAlgorithmNative = ffi.Void Function(
    ffi.Pointer<ffi.Void>, ffi.Int32);
typedef _SetCrossfeedAlgorithmDart = void Function(ffi.Pointer<ffi.Void>, int);

// ae_set_crossfeed_params(AudioEngineHandle*, float mix, float delay_ms, float cutoff_hz, int output_compensation)
typedef _SetCrossfeedParamsNative = ffi.Void Function(
    ffi.Pointer<ffi.Void>, ffi.Float, ffi.Float, ffi.Float, ffi.Int32);
typedef _SetCrossfeedParamsDart = void Function(
    ffi.Pointer<ffi.Void>, double, double, double, int);

// ae_get_crossfeed_params(AudioEngineHandle*, int* algo, float* mix, float* delay_ms, float* cutoff_hz, int* comp)
typedef _GetCrossfeedParamsNative = ffi.Void Function(
    ffi.Pointer<ffi.Void>,
    ffi.Pointer<ffi.Int32>,
    ffi.Pointer<ffi.Float>,
    ffi.Pointer<ffi.Float>,
    ffi.Pointer<ffi.Float>,
    ffi.Pointer<ffi.Int32>);
typedef _GetCrossfeedParamsDart = void Function(
    ffi.Pointer<ffi.Void>,
    ffi.Pointer<ffi.Int32>,
    ffi.Pointer<ffi.Float>,
    ffi.Pointer<ffi.Float>,
    ffi.Pointer<ffi.Float>,
    ffi.Pointer<ffi.Int32>);
// ─────────────────────────────────────────────────────────────────────────────

// Crystalizer typedefs
typedef _SetCrystalizerEnabledNative = ffi.Void Function(
    ffi.Pointer<ffi.Void>, ffi.Int32);
typedef _SetCrystalizerEnabledDart = void Function(ffi.Pointer<ffi.Void>, int);

typedef _SetCrystalizerParamsNative = ffi.Void Function(
    ffi.Pointer<ffi.Void>, ffi.Float, ffi.Int32, ffi.Float);
typedef _SetCrystalizerParamsDart = void Function(
    ffi.Pointer<ffi.Void>, double, int, double);

typedef _GetCrystalizerIntensityNative = ffi.Float Function(
    ffi.Pointer<ffi.Void>);
typedef _GetCrystalizerIntensityDart = double Function(ffi.Pointer<ffi.Void>);

typedef _SetTimeInPcmFramesNative = ffi.Void Function(
    ffi.Pointer<ffi.Void>, ffi.Uint64);
typedef _SetTimeInPcmFramesDart = void Function(ffi.Pointer<ffi.Void>, int);

typedef _GetEngineTimeInPcmFramesNative = ffi.Uint64 Function(
    ffi.Pointer<ffi.Void>);
typedef _GetEngineTimeInPcmFramesDart = int Function(ffi.Pointer<ffi.Void>);

// End Callback
typedef EndCallbackNative = ffi.Void Function(
    ffi.Pointer<ffi.Void>, ffi.Pointer<ffi.Void>);
typedef _SetEndCallbackNative = ffi.Void Function(ffi.Pointer<ffi.Void>,
    ffi.Pointer<ffi.NativeFunction<EndCallbackNative>>, ffi.Pointer<ffi.Void>);
typedef _SetEndCallbackDart = void Function(ffi.Pointer<ffi.Void>,
    ffi.Pointer<ffi.NativeFunction<EndCallbackNative>>, ffi.Pointer<ffi.Void>);

typedef _SetExclusiveModeNative = ffi.Void Function(
    ffi.Pointer<ffi.Void>, ffi.Int32);
typedef _SetExclusiveModeDart = void Function(ffi.Pointer<ffi.Void>, int);

typedef _GetExclusiveModeNative = ffi.Int32 Function(ffi.Pointer<ffi.Void>);
typedef _GetExclusiveModeDart = int Function(ffi.Pointer<ffi.Void>);

typedef _SetOutputBackendNative = ffi.Int32 Function(
    ffi.Pointer<ffi.Void>, ffi.Int32);
typedef _SetOutputBackendDart = int Function(ffi.Pointer<ffi.Void>, int);

typedef _GetOutputBackendNative = ffi.Int32 Function(ffi.Pointer<ffi.Void>);
typedef _GetOutputBackendDart = int Function(ffi.Pointer<ffi.Void>);

typedef _IsBackendSupportedNative = ffi.Int32 Function(
    ffi.Pointer<ffi.Void>, ffi.Int32);
typedef _IsBackendSupportedDart = int Function(ffi.Pointer<ffi.Void>, int);


typedef _SetOutputFormatNative = ffi.Void Function(
    ffi.Pointer<ffi.Void>, ffi.Int32);
typedef _SetOutputFormatDart = void Function(ffi.Pointer<ffi.Void>, int);

typedef _GetOutputFormatNative = ffi.Int32 Function(ffi.Pointer<ffi.Void>);
typedef _GetOutputFormatDart = int Function(ffi.Pointer<ffi.Void>);

typedef _SetOutputRateNative = ffi.Void Function(
    ffi.Pointer<ffi.Void>, ffi.Int32);
typedef _SetOutputRateDart = void Function(ffi.Pointer<ffi.Void>, int);

typedef _GetOutputRateNative = ffi.Int32 Function(ffi.Pointer<ffi.Void>);
typedef _GetOutputRateDart = int Function(ffi.Pointer<ffi.Void>);

typedef _SetOutputChannelsNative = ffi.Void Function(
    ffi.Pointer<ffi.Void>, ffi.Int32);
typedef _SetOutputChannelsDart = void Function(ffi.Pointer<ffi.Void>, int);

typedef _SetOutputBufferNative = ffi.Void Function(
    ffi.Pointer<ffi.Void>, ffi.Int32, ffi.Int32);
typedef _SetOutputBufferDart = void Function(
    ffi.Pointer<ffi.Void>, int, int);

typedef _GetOutputBufferNative = ffi.Void Function(
    ffi.Pointer<ffi.Void>, ffi.Pointer<ffi.Int32>, ffi.Pointer<ffi.Int32>);
typedef _GetOutputBufferDart = void Function(
    ffi.Pointer<ffi.Void>, ffi.Pointer<ffi.Int32>, ffi.Pointer<ffi.Int32>);

// Release 1 Quality Foundation Typedefs
typedef _GetLoudnessMetricsNative = AELoudnessMetricsNative Function(
    ffi.Pointer<ffi.Void>);
typedef _GetLoudnessMetricsDart = AELoudnessMetricsNative Function(
    ffi.Pointer<ffi.Void>);

typedef _ResetLoudnessMeterNative = ffi.Void Function(ffi.Pointer<ffi.Void>);
typedef _ResetLoudnessMeterDart = void Function(ffi.Pointer<ffi.Void>);

typedef _SetLoudnessNormalizerEnabledNative = ffi.Void Function(
    ffi.Pointer<ffi.Void>, ffi.Int32);
typedef _SetLoudnessNormalizerEnabledDart = void Function(
    ffi.Pointer<ffi.Void>, int);

typedef _SetLoudnessNormalizerTargetNative = ffi.Void Function(
    ffi.Pointer<ffi.Void>, ffi.Float);
typedef _SetLoudnessNormalizerTargetDart = void Function(
    ffi.Pointer<ffi.Void>, double);

typedef _GetLoudnessNormalizerEnabledNative = ffi.Int32 Function(
    ffi.Pointer<ffi.Void>);
typedef _GetLoudnessNormalizerEnabledDart = int Function(
    ffi.Pointer<ffi.Void>);

typedef _GetLoudnessNormalizerTargetNative = ffi.Float Function(
    ffi.Pointer<ffi.Void>);
typedef _GetLoudnessNormalizerTargetDart = double Function(
    ffi.Pointer<ffi.Void>);

typedef _GetLoudnessNormalizerGainDbNative = ffi.Float Function(
    ffi.Pointer<ffi.Void>);
typedef _GetLoudnessNormalizerGainDbDart = double Function(
    ffi.Pointer<ffi.Void>);

typedef _GetTruePeakNative = AETruePeakMetricsNative Function(
    ffi.Pointer<ffi.Void>);
typedef _GetTruePeakDart = AETruePeakMetricsNative Function(
    ffi.Pointer<ffi.Void>);

typedef _SetLookaheadLimiterEnabledNative = ffi.Void Function(
    ffi.Pointer<ffi.Void>, ffi.Int32);
typedef _SetLookaheadLimiterEnabledDart = void Function(
    ffi.Pointer<ffi.Void>, int);

typedef _SetLookaheadLimiterParamsNative = ffi.Void Function(
    ffi.Pointer<ffi.Void>, ffi.Float, ffi.Float, ffi.Float);
typedef _SetLookaheadLimiterParamsDart = void Function(
    ffi.Pointer<ffi.Void>, double, double, double);

typedef _GetLookaheadLimiterGainReductionDbNative = ffi.Float Function(
    ffi.Pointer<ffi.Void>);
typedef _GetLookaheadLimiterGainReductionDbDart = double Function(
    ffi.Pointer<ffi.Void>);

typedef _GetQualityTelemetryNative = AEQualityTelemetryNative Function(
    ffi.Pointer<ffi.Void>);
typedef _GetQualityTelemetryDart = AEQualityTelemetryNative Function(
    ffi.Pointer<ffi.Void>);

typedef _GetOutputChannelsNative = ffi.Int32 Function(ffi.Pointer<ffi.Void>);
typedef _GetOutputChannelsDart = int Function(ffi.Pointer<ffi.Void>);

typedef _SetEngineResampleAlgorithmNative = ffi.Void Function(
    ffi.Pointer<ffi.Void>, ffi.Int32);
typedef _SetEngineResampleAlgorithmDart = void Function(
    ffi.Pointer<ffi.Void>, int);

typedef _GetEngineResampleAlgorithmNative = ffi.Int32 Function(
    ffi.Pointer<ffi.Void>);
typedef _GetEngineResampleAlgorithmDart = int Function(ffi.Pointer<ffi.Void>);

typedef _SetEngineDitherModeNative = ffi.Void Function(
    ffi.Pointer<ffi.Void>, ffi.Int32);
typedef _SetEngineDitherModeDart = void Function(ffi.Pointer<ffi.Void>, int);

typedef _GetEngineDitherModeNative = ffi.Int32 Function(ffi.Pointer<ffi.Void>);
typedef _GetEngineDitherModeDart = int Function(ffi.Pointer<ffi.Void>);

typedef _SetPhaseInversionNative = ffi.Void Function(
    ffi.Pointer<ffi.Void>, ffi.Int32, ffi.Int32);
typedef _SetPhaseInversionDart = void Function(ffi.Pointer<ffi.Void>, int, int);

typedef _GetPhaseInversionNative = ffi.Void Function(
    ffi.Pointer<ffi.Void>, ffi.Pointer<ffi.Int32>, ffi.Pointer<ffi.Int32>);
typedef _GetPhaseInversionDart = void Function(
    ffi.Pointer<ffi.Void>, ffi.Pointer<ffi.Int32>, ffi.Pointer<ffi.Int32>);

// L/R Swap
typedef _SetLrSwapNative = ffi.Void Function(ffi.Pointer<ffi.Void>, ffi.Int32);
typedef _SetLrSwapDart = void Function(ffi.Pointer<ffi.Void>, int);
typedef _GetLrSwapNative = ffi.Int32 Function(ffi.Pointer<ffi.Void>);
typedef _GetLrSwapDart = int Function(ffi.Pointer<ffi.Void>);

// Per-Channel Gain
typedef _SetChannelGainsNative = ffi.Void Function(
    ffi.Pointer<ffi.Void>, ffi.Float, ffi.Float);
typedef _SetChannelGainsDart = void Function(
    ffi.Pointer<ffi.Void>, double, double);
typedef _GetChannelGainsNative = ffi.Void Function(
    ffi.Pointer<ffi.Void>, ffi.Pointer<ffi.Float>, ffi.Pointer<ffi.Float>);
typedef _GetChannelGainsDart = void Function(
    ffi.Pointer<ffi.Void>, ffi.Pointer<ffi.Float>, ffi.Pointer<ffi.Float>);

// Limiter & Clipping Detection
typedef _SetLimiterEnabledNative = ffi.Void Function(
    ffi.Pointer<ffi.Void>, ffi.Int32);
typedef _SetLimiterEnabledDart = void Function(ffi.Pointer<ffi.Void>, int);

typedef _SetLimiterParamsNative = ffi.Void Function(
    ffi.Pointer<ffi.Void>, ffi.Float, ffi.Float, ffi.Float);
typedef _SetLimiterParamsDart = void Function(
    ffi.Pointer<ffi.Void>, double, double, double);

// Dynamic Range Compressor
typedef _SetCompressorEnabledNative = ffi.Void Function(
    ffi.Pointer<ffi.Void>, ffi.Int32);
typedef _SetCompressorEnabledDart = void Function(ffi.Pointer<ffi.Void>, int);

typedef _SetCompressorParamsNative = ffi.Void Function(
    ffi.Pointer<ffi.Void>,
    ffi.Float,
    ffi.Float,
    ffi.Float,
    ffi.Float,
    ffi.Float,
    ffi.Float,
    ffi.Int32,
    ffi.Int32,
    ffi.Int32,
    ffi.Float);
typedef _SetCompressorParamsDart = void Function(
    ffi.Pointer<ffi.Void>,
    double,
    double,
    double,
    double,
    double,
    double,
    int,
    int,
    int,
    double);

typedef _GetCompressorGainReductionDbNative = ffi.Float Function(
    ffi.Pointer<ffi.Void>);
typedef _GetCompressorGainReductionDbDart = double Function(
    ffi.Pointer<ffi.Void>);

typedef _SetClippingDetectionEnabledNative = ffi.Void Function(
    ffi.Pointer<ffi.Void>, ffi.Int32);
typedef _SetClippingDetectionEnabledDart = void Function(
    ffi.Pointer<ffi.Void>, int);

typedef _GetClippedSamplesCountNative = ffi.Uint64 Function(
    ffi.Pointer<ffi.Void>);
typedef _GetClippedSamplesCountDart = int Function(ffi.Pointer<ffi.Void>);

typedef _ResetClippedSamplesCountNative = ffi.Void Function(
    ffi.Pointer<ffi.Void>);
typedef _ResetClippedSamplesCountDart = void Function(ffi.Pointer<ffi.Void>);

typedef _InitMultibandEqNative = ffi.Void Function(ffi.Pointer<ffi.Void>,
    ffi.Int32, ffi.Pointer<ffi.Float>, ffi.Pointer<ffi.Float>);
typedef _InitMultibandEqDart = void Function(
    ffi.Pointer<ffi.Void>, int, ffi.Pointer<ffi.Float>, ffi.Pointer<ffi.Float>);

typedef _SetMultibandEqEnabledNative = ffi.Void Function(
    ffi.Pointer<ffi.Void>, ffi.Int32);
typedef _SetMultibandEqEnabledDart = void Function(ffi.Pointer<ffi.Void>, int);

typedef _SetMultibandEqGainNative = ffi.Void Function(
    ffi.Pointer<ffi.Void>, ffi.Int32, ffi.Float);
typedef _SetMultibandEqGainDart = void Function(
    ffi.Pointer<ffi.Void>, int, double);

typedef _GetMultibandEqGainNative = ffi.Float Function(
    ffi.Pointer<ffi.Void>, ffi.Int32);
typedef _GetMultibandEqGainDart = double Function(ffi.Pointer<ffi.Void>, int);

typedef _SetMultibandFxEnabledNative = ffi.Void Function(
    ffi.Pointer<ffi.Void>, ffi.Int32);
typedef _SetMultibandFxEnabledDart = void Function(ffi.Pointer<ffi.Void>, int);

typedef _SetMultibandFxBandsNative = ffi.Void Function(
  ffi.Pointer<ffi.Void>,
  ffi.Int32,
  ffi.Pointer<ffi.Int32>,
  ffi.Pointer<ffi.Float>,
  ffi.Pointer<ffi.Float>,
  ffi.Pointer<ffi.Float>,
  ffi.Pointer<ffi.Float>,
  ffi.Pointer<ffi.Int32>,
);
typedef _SetMultibandFxBandsDart = void Function(
  ffi.Pointer<ffi.Void>,
  int,
  ffi.Pointer<ffi.Int32>,
  ffi.Pointer<ffi.Float>,
  ffi.Pointer<ffi.Float>,
  ffi.Pointer<ffi.Float>,
  ffi.Pointer<ffi.Float>,
  ffi.Pointer<ffi.Int32>,
);

typedef _InspectFileNative = AETrackInfoNative Function(ffi.Pointer<ffi.Char>);
typedef _InspectFileDart = AETrackInfoNative Function(ffi.Pointer<ffi.Char>);

typedef _GetHardwareInfoNative = AEHardwareInfoNative Function(
    ffi.Pointer<ffi.Void>);
typedef _GetHardwareInfoDart = AEHardwareInfoNative Function(
    ffi.Pointer<ffi.Void>);

typedef _RegisterAndroidJvmNative = ffi.Void Function(ffi.Pointer<ffi.Void>);
typedef _RegisterAndroidJvmDart = void Function(ffi.Pointer<ffi.Void>);

typedef _ClearMultibandFxNative = ffi.Void Function(ffi.Pointer<ffi.Void>);
typedef _ClearMultibandFxDart = void Function(ffi.Pointer<ffi.Void>);

typedef _InitPushStreamNative = ffi.Void Function(ffi.Pointer<ffi.Void>);
typedef _InitPushStreamDart = void Function(ffi.Pointer<ffi.Void>);

typedef _PushStreamChunkNative = ffi.Void Function(
    ffi.Pointer<ffi.Void>, ffi.Pointer<ffi.Uint8>, ffi.Size);
typedef _PushStreamChunkDart = void Function(
    ffi.Pointer<ffi.Void>, ffi.Pointer<ffi.Uint8>, int);

typedef _EndPushStreamNative = ffi.Void Function(ffi.Pointer<ffi.Void>);
typedef _EndPushStreamDart = void Function(ffi.Pointer<ffi.Void>);

typedef _GetPushStreamBufferedBytesNative = ffi.Int32 Function(
    ffi.Pointer<ffi.Void>);
typedef _GetPushStreamBufferedBytesDart = int Function(ffi.Pointer<ffi.Void>);

typedef _GetNetworkStreamingSupportNative = ffi.Int32 Function();
typedef _GetNetworkStreamingSupportDart = int Function();

typedef _GetStreamTelemetryNative = ffi.Int32 Function(
    ffi.Pointer<ffi.Void> engine,
    ffi.Pointer<ffi.Int32> outState,
    ffi.Pointer<ffi.Int32> outErrorCode,
    ffi.Pointer<ffi.Double> outBufferedDurationSec,
    ffi.Pointer<ffi.Double> outTotalDurationSec,
    ffi.Pointer<ffi.Double> outBufferPercent,
    ffi.Pointer<ffi.Int64> outBitrate,
    ffi.Pointer<ffi.Char> outCodecName,
    ffi.Int32 codecNameLen,
    ffi.Pointer<ffi.Char> outIcyTitle,
    ffi.Int32 icyTitleLen,
    ffi.Pointer<ffi.Char> outIcyArtist,
    ffi.Int32 icyArtistLen);

typedef _GetStreamTelemetryDart = int Function(
    ffi.Pointer<ffi.Void> engine,
    ffi.Pointer<ffi.Int32> outState,
    ffi.Pointer<ffi.Int32> outErrorCode,
    ffi.Pointer<ffi.Double> outBufferedDurationSec,
    ffi.Pointer<ffi.Double> outTotalDurationSec,
    ffi.Pointer<ffi.Double> outBufferPercent,
    ffi.Pointer<ffi.Int64> outBitrate,
    ffi.Pointer<ffi.Char> outCodecName,
    int codecNameLen,
    ffi.Pointer<ffi.Char> outIcyTitle,
    int icyTitleLen,
    ffi.Pointer<ffi.Char> outIcyArtist,
    int icyArtistLen);

typedef _IsStreamLiveNative = ffi.Int32 Function(ffi.Pointer<ffi.Void> engine);
typedef _IsStreamLiveDart = int Function(ffi.Pointer<ffi.Void> engine);

typedef _SetAnalyzerEnabledNative = ffi.Void Function(
    ffi.Pointer<ffi.Void>, ffi.Int32);
typedef _SetAnalyzerEnabledDart = void Function(ffi.Pointer<ffi.Void>, int);

typedef _ConfigureAnalyzerNative = ffi.Void Function(
    ffi.Pointer<ffi.Void>, ffi.Int32);
typedef _ConfigureAnalyzerDart = void Function(ffi.Pointer<ffi.Void>, int);

typedef _GetAnalyzerFrameSizeNative = ffi.Int32 Function(ffi.Pointer<ffi.Void>);
typedef _GetAnalyzerFrameSizeDart = int Function(ffi.Pointer<ffi.Void>);

typedef _PollAnalyzerFrameNative = ffi.Int32 Function(
    ffi.Pointer<ffi.Void>, ffi.Pointer<ffi.Float>, ffi.Int32);
typedef _PollAnalyzerFrameDart = int Function(
    ffi.Pointer<ffi.Void>, ffi.Pointer<ffi.Float>, int);

typedef _GetAnalyzerDroppedFramesNative = ffi.Uint64 Function(
    ffi.Pointer<ffi.Void>);
typedef _GetAnalyzerDroppedFramesDart = int Function(ffi.Pointer<ffi.Void>);

class PlayerStatus {
  final double positionSeconds;
  final double durationSeconds;
  final bool isPlaying;
  final int currentIndex;
  final int playlistCount;
  final bool shuffleEnabled;
  final LoopMode loopMode;

  const PlayerStatus({
    required this.positionSeconds,
    required this.durationSeconds,
    required this.isPlaying,
    required this.currentIndex,
    required this.playlistCount,
    required this.shuffleEnabled,
    required this.loopMode,
  });
}

class PipelineAudioState {
  final int inputFormat;
  final int inputSampleRate;
  final int inputChannels;
  final int processingFormat;
  final int processingSampleRate;
  final int processingChannels;
  final int outputFormat;
  final int outputSampleRate;
  final int outputChannels;

  final bool eqEnabled;
  final bool reverbEnabled;
  final bool limiterEnabled;
  final bool stereoWidenEnabled;
  final bool stereoEnhancementEnabled;
  final bool spatializationEnabled;
  final bool delayEnabled;

  final double gain;
  final double pan;
  final double pitch;
  final double rate;
  final bool pitchCorrectionEnabled;

  const PipelineAudioState({
    required this.inputFormat,
    required this.inputSampleRate,
    required this.inputChannels,
    required this.processingFormat,
    required this.processingSampleRate,
    required this.processingChannels,
    required this.outputFormat,
    required this.outputSampleRate,
    required this.outputChannels,
    required this.eqEnabled,
    required this.reverbEnabled,
    required this.limiterEnabled,
    required this.stereoWidenEnabled,
    required this.stereoEnhancementEnabled,
    required this.spatializationEnabled,
    required this.delayEnabled,
    required this.gain,
    required this.pan,
    required this.pitch,
    this.rate = 1.0,
    this.pitchCorrectionEnabled = true,
  });

  factory PipelineAudioState.fromNative(PipelineStateNative native) {
    return PipelineAudioState(
      inputFormat: native.input_format,
      inputSampleRate: native.input_sample_rate,
      inputChannels: native.input_channels,
      processingFormat: native.processing_format,
      processingSampleRate: native.processing_sample_rate,
      processingChannels: native.processing_channels,
      outputFormat: native.output_format,
      outputSampleRate: native.output_sample_rate,
      outputChannels: native.output_channels,
      eqEnabled: native.eq_enabled != 0,
      reverbEnabled: native.reverb_enabled != 0,
      limiterEnabled: native.limiter_enabled != 0,
      stereoWidenEnabled: native.stereo_widen_enabled != 0,
      stereoEnhancementEnabled: native.stereo_enhancement_enabled != 0,
      spatializationEnabled: native.spatialization_enabled != 0,
      delayEnabled: native.delay_enabled != 0,
      gain: native.gain,
      pan: native.pan,
      pitch: native.pitch,
      rate: native.rate,
      pitchCorrectionEnabled: native.pitch_correction_enabled != 0,
    );
  }

  factory PipelineAudioState.empty() {
    return const PipelineAudioState(
      inputFormat: 0,
      inputSampleRate: 0,
      inputChannels: 0,
      processingFormat: 0,
      processingSampleRate: 0,
      processingChannels: 0,
      outputFormat: 0,
      outputSampleRate: 0,
      outputChannels: 0,
      eqEnabled: false,
      reverbEnabled: false,
      limiterEnabled: false,
      stereoWidenEnabled: false,
      stereoEnhancementEnabled: false,
      spatializationEnabled: false,
      delayEnabled: false,
      gain: 0.0,
      pan: 0.0,
      pitch: 0.0,
      rate: 1.0,
      pitchCorrectionEnabled: true,
    );
  }

  String formatToString(int format) {
    switch (format) {
      case 1:
        return '8-bit Unsigned';
      case 2:
        return '16-bit Signed';
      case 3:
        return '24-bit Signed';
      case 4:
        return '32-bit Signed';
      case 5:
        return '32-bit Float';
      default:
        return 'Unknown ($format)';
    }
  }

  String get inputFormatString => formatToString(inputFormat);
  String get processingFormatString => formatToString(processingFormat);
  String get outputFormatString => formatToString(outputFormat);
}

class AudioEngineFFI {
  AudioEngineFFI({String? libraryPath})
      : _lib = openLibrary(libraryPath),
        _engine = ffi.nullptr {
    final allocLib = openAllocatorLibrary();
    _malloc = allocLib.lookupFunction<_MallocNative, _MallocDart>('malloc');
    _free = allocLib.lookupFunction<_FreeNative, _FreeDart>('free');

    _createEngine = _lib.lookupFunction<_CreateEngineNative, _CreateEngineDart>(
      'ae_create_engine',
    );
    _destroyEngine =
        _lib.lookupFunction<_DestroyEngineNative, _DestroyEngineDart>(
      'ae_destroy_engine',
    );
    _setPlaylist = _lib.lookupFunction<_SetPlaylistNative, _SetPlaylistDart>(
      'ae_set_playlist',
    );
    _addToPlaylist =
        _lib.lookupFunction<_AddToPlaylistNative, _AddToPlaylistDart>(
      'ae_add_to_playlist',
    );
    _insertToPlaylist =
        _lib.lookupFunction<_InsertToPlaylistNative, _InsertToPlaylistDart>(
      'ae_insert_to_playlist',
    );
    _removeFromPlaylist =
        _lib.lookupFunction<_RemoveFromPlaylistNative, _RemoveFromPlaylistDart>(
      'ae_remove_from_playlist',
    );
    _movePlaylistItem =
        _lib.lookupFunction<_MovePlaylistItemNative, _MovePlaylistItemDart>(
      'ae_move_playlist_item',
    );
    _clearPlaylist =
        _lib.lookupFunction<_ClearPlaylistNative, _ClearPlaylistDart>(
      'ae_clear_playlist',
    );

    _play = _lib.lookupFunction<_BoolOpNative, _BoolOpDart>('ae_play');
    _pause = _lib.lookupFunction<_BoolOpNative, _BoolOpDart>('ae_pause');
    _stop = _lib.lookupFunction<_BoolOpNative, _BoolOpDart>('ae_stop');
    _next = _lib.lookupFunction<_BoolOpNative, _BoolOpDart>('ae_next');
    _prev = _lib.lookupFunction<_BoolOpNative, _BoolOpDart>('ae_prev');

    _seek = _lib.lookupFunction<_SeekNative, _SeekDart>('ae_seek');
    _jumpTo = _lib.lookupFunction<_JumpNative, _JumpDart>('ae_jump_to');
    _jumpToWithPosition =
        _lib.lookupFunction<_JumpWithPositionNative, _JumpWithPositionDart>(
      'ae_jump_to_with_position',
    );
    _getDeviceLatencyMs =
        _lib.lookupFunction<_GetDeviceLatencyMsNative, _GetDeviceLatencyMsDart>(
            'ae_get_device_latency_ms');
    _getEngineLatencySamples = _lib.lookupFunction<
        _GetEngineLatencySamplesNative,
        _GetEngineLatencySamplesDart>('ae_get_engine_latency_samples');
    _getEngineLatencyMs =
        _lib.lookupFunction<_GetEngineLatencyMsNative, _GetEngineLatencyMsDart>(
            'ae_get_engine_latency_ms');
    _getStatus = _lib.lookupFunction<_GetStatusNative, _GetStatusDart>(
      'ae_get_status',
    );
    _getPipelineState =
        _lib.lookupFunction<_GetPipelineStateNative, _GetPipelineStateDart>(
      'ae_get_pipeline_state',
    );
    _getLastError = _lib.lookupFunction<_GetLastErrorNative, _GetLastErrorDart>(
      'ae_get_last_error',
    );
    _clearLastError =
        _lib.lookupFunction<_ClearLastErrorNative, _ClearLastErrorDart>(
      'ae_clear_last_error',
    );

    _setLoopMode = _lib.lookupFunction<_SetIntNative, _SetIntDart>(
      'ae_set_loop_mode',
    );
    _setShuffleEnabled = _lib.lookupFunction<_SetIntNative, _SetIntDart>(
      'ae_set_shuffle_enabled',
    );
    _reshuffle = _lib.lookupFunction<_ClearPlaylistNative, _ClearPlaylistDart>(
      'ae_reshuffle',
    );

    try {
      _setAbRepeat = _lib.lookupFunction<_SetAbRepeatNative, _SetAbRepeatDart>(
        'ae_set_ab_repeat',
      );
      _getAbRepeat = _lib.lookupFunction<_GetAbRepeatNative, _GetAbRepeatDart>(
        'ae_get_ab_repeat',
      );
    } catch (_) {
      _setAbRepeat = null;
      _getAbRepeat = null;
    }
    _setCrossfadeEnabled = _lib.lookupFunction<_SetIntNative, _SetIntDart>(
      'ae_set_crossfade_enabled',
    );
    _getCrossfadeEnabled = _lib.lookupFunction<_GetIntNative, _GetIntDart>(
      'ae_get_crossfade_enabled',
    );
    _setCrossfadeDurationMs = _lib.lookupFunction<_SetIntNative, _SetIntDart>(
      'ae_set_crossfade_duration_ms',
    );
    _getCrossfadeDurationMs = _lib.lookupFunction<_GetIntNative, _GetIntDart>(
      'ae_get_crossfade_duration_ms',
    );

    try {
      _setLoudnessCrossfadeEnabled =
          _lib.lookupFunction<_SetIntNative, _SetIntDart>(
        'ae_set_loudness_crossfade_enabled',
      );
      _getLoudnessCrossfadeEnabled =
          _lib.lookupFunction<_GetIntNative, _GetIntDart>(
        'ae_get_loudness_crossfade_enabled',
      );
      _setNextReplayGain =
          _lib.lookupFunction<_SetSingleFloatNative, _SetSingleFloatDart>(
        'ae_set_next_replay_gain',
      );
    } catch (_) {
      _setLoudnessCrossfadeEnabled = null;
      _getLoudnessCrossfadeEnabled = null;
      _setNextReplayGain = null;
    }

    _setReverbEnabled =
        _lib.lookupFunction<_SetFxEnabledNative, _SetFxEnabledDart>(
      'ae_set_reverb_enabled',
    );
    _setReverbParams =
        _lib.lookupFunction<_SetReverbParamsNative, _SetReverbParamsDart>(
      'ae_set_reverb_params',
    );
    _setReverbParamsEx =
        _lib.lookupFunction<_SetReverbParamsExNative, _SetReverbParamsExDart>(
      'ae_set_reverb_params_ex',
    );
    _getReverbParamsEx =
        _lib.lookupFunction<_GetReverbParamsExNative, _GetReverbParamsExDart>(
      'ae_get_reverb_params_ex',
    );
    _setReverbGains =
        _lib.lookupFunction<_SetReverbGainsNative, _SetReverbGainsDart>(
      'ae_set_reverb_gains',
    );
    _getReverbGains =
        _lib.lookupFunction<_GetReverbGainsNative, _GetReverbGainsDart>(
      'ae_get_reverb_gains',
    );
    _setEqEnabled = _lib.lookupFunction<_SetFxEnabledNative, _SetFxEnabledDart>(
      'ae_set_eq_enabled',
    );
    _setEqGains = _lib.lookupFunction<_SetEqGainsNative, _SetEqGainsDart>(
      'ae_set_eq_gains',
    );
    _setGain = _lib.lookupFunction<_SetSingleFloatNative, _SetSingleFloatDart>(
      'ae_set_gain',
    );
    try {
      _setReplayGain =
          _lib.lookupFunction<_SetSingleFloatNative, _SetSingleFloatDart>(
        'ae_set_replay_gain',
      );
    } catch (_) {
      _setReplayGain = null;
    }
    _setPan = _lib.lookupFunction<_SetSingleFloatNative, _SetSingleFloatDart>(
      'ae_set_pan',
    );
    _setRate = _lib.lookupFunction<_SetSingleFloatNative, _SetSingleFloatDart>(
      'ae_set_rate',
    );
    try {
      _getRate = _lib.lookupFunction<_GetFloatNative, _GetFloatDart>(
        'ae_get_rate',
      );
    } catch (_) {
      _getRate = null;
    }
    _setPitch = _lib.lookupFunction<_SetSingleFloatNative, _SetSingleFloatDart>(
      'ae_set_pitch',
    );
    try {
      _getPitch = _lib.lookupFunction<_GetFloatNative, _GetFloatDart>(
        'ae_get_pitch',
      );
    } catch (_) {
      _getPitch = null;
    }
    _setPitchCorrection =
        _lib.lookupFunction<_SetSingleIntNative, _SetSingleIntDart>(
      'ae_set_pitch_correction',
    );
    try {
      _getPitchCorrection =
          _lib.lookupFunction<_GetIntNative, _GetIntDart>(
        'ae_get_pitch_correction',
      );
    } catch (_) {
      _getPitchCorrection = null;
    }
    _setLowpassEnabled =
        _lib.lookupFunction<_SetFxEnabledNative, _SetFxEnabledDart>(
      'ae_set_lowpass_enabled',
    );
    _setLowpassCutoff =
        _lib.lookupFunction<_SetSingleFloatNative, _SetSingleFloatDart>(
      'ae_set_lowpass_cutoff',
    );
    _setHighpassEnabled =
        _lib.lookupFunction<_SetFxEnabledNative, _SetFxEnabledDart>(
      'ae_set_highpass_enabled',
    );
    _setHighpassCutoff =
        _lib.lookupFunction<_SetSingleFloatNative, _SetSingleFloatDart>(
      'ae_set_highpass_cutoff',
    );
    _setDelayEnabled =
        _lib.lookupFunction<_SetFxEnabledNative, _SetFxEnabledDart>(
      'ae_set_delay_enabled',
    );
    _setDelayParams =
        _lib.lookupFunction<_SetReverbParamsNative, _SetReverbParamsDart>(
      'ae_set_delay_params',
    );
    _setStereoWiden =
        _lib.lookupFunction<_SetStereoWidenNative, _SetStereoWidenDart>(
      'ae_set_stereo_widen',
    );
    _setStereoEnhancementEnabled = _lib.lookupFunction<
        _SetStereoEnhancementEnabledNative, _SetStereoEnhancementEnabledDart>(
      'ae_set_stereo_enhancement_enabled',
    );
    _getStereoEnhancementEnabled = _lib.lookupFunction<
        _GetStereoEnhancementEnabledNative, _GetStereoEnhancementEnabledDart>(
      'ae_get_stereo_enhancement_enabled',
    );
    _setStereoEnhancementMix = _lib.lookupFunction<
        _SetStereoEnhancementMixNative, _SetStereoEnhancementMixDart>(
      'ae_set_stereo_enhancement_mix',
    );
    _getStereoEnhancementMix = _lib.lookupFunction<
        _GetStereoEnhancementMixNative, _GetStereoEnhancementMixDart>(
      'ae_get_stereo_enhancement_mix',
    );
    _setCrossfeedEnabled =
        _lib.lookupFunction<_SetFxEnabledNative, _SetFxEnabledDart>(
      'ae_set_crossfeed_enabled',
    );
    _setCrossfeedPreset =
        _lib.lookupFunction<_SetSingleIntNative, _SetSingleIntDart>(
      'ae_set_crossfeed_preset',
    );
    _setRaceParams =
        _lib.lookupFunction<_SetRaceParamsNative, _SetRaceParamsDart>(
      'ae_set_race_params',
    );
    // CrossfeedNode extended API
    _setCrossfeedAlgorithm = _lib.lookupFunction<_SetCrossfeedAlgorithmNative,
        _SetCrossfeedAlgorithmDart>('ae_set_crossfeed_algorithm');
    _setCrossfeedParams =
        _lib.lookupFunction<_SetCrossfeedParamsNative, _SetCrossfeedParamsDart>(
            'ae_set_crossfeed_params');
    _getCrossfeedParams =
        _lib.lookupFunction<_GetCrossfeedParamsNative, _GetCrossfeedParamsDart>(
            'ae_get_crossfeed_params');
    _setDynamicBassEnabled =
        _lib.lookupFunction<_SetFxEnabledNative, _SetFxEnabledDart>(
      'ae_set_dynamic_bass_enabled',
    );
    _setDynamicBassParams = _lib
        .lookupFunction<_SetDynamicBassParamsNative, _SetDynamicBassParamsDart>(
      'ae_set_dynamic_bass_params',
    );
    // Crystalizer
    _setCrystalizerEnabled = _lib.lookupFunction<_SetCrystalizerEnabledNative,
        _SetCrystalizerEnabledDart>('ae_set_crystalizer_enabled');
    _setCrystalizerParams = _lib.lookupFunction<_SetCrystalizerParamsNative,
        _SetCrystalizerParamsDart>('ae_set_crystalizer_params');
    _getCrystalizerIntensity = _lib.lookupFunction<
        _GetCrystalizerIntensityNative,
        _GetCrystalizerIntensityDart>('ae_get_crystalizer_intensity');
    _setBandpassEnabled =
        _lib.lookupFunction<_SetFxEnabledNative, _SetFxEnabledDart>(
      'ae_set_bandpass_enabled',
    );
    _setBandpassParams =
        _lib.lookupFunction<_SetTwoFloatsNative, _SetTwoFloatsDart>(
      'ae_set_bandpass_params',
    );
    _setPeakEqEnabled =
        _lib.lookupFunction<_SetFxEnabledNative, _SetFxEnabledDart>(
      'ae_set_peak_eq_enabled',
    );
    _setPeakEqParams =
        _lib.lookupFunction<_SetReverbParamsNative, _SetReverbParamsDart>(
      'ae_set_peak_eq_params',
    );
    _setNotchEnabled =
        _lib.lookupFunction<_SetFxEnabledNative, _SetFxEnabledDart>(
      'ae_set_notch_enabled',
    );
    _setNotchParams =
        _lib.lookupFunction<_SetTwoFloatsNative, _SetTwoFloatsDart>(
      'ae_set_notch_params',
    );
    _setLowshelfEnabled =
        _lib.lookupFunction<_SetFxEnabledNative, _SetFxEnabledDart>(
      'ae_set_lowshelf_enabled',
    );
    _setLowshelfParams =
        _lib.lookupFunction<_SetReverbParamsNative, _SetReverbParamsDart>(
      'ae_set_lowshelf_params',
    );
    _setHighshelfEnabled =
        _lib.lookupFunction<_SetFxEnabledNative, _SetFxEnabledDart>(
      'ae_set_highshelf_enabled',
    );
    _setHighshelfParams =
        _lib.lookupFunction<_SetReverbParamsNative, _SetReverbParamsDart>(
      'ae_set_highshelf_params',
    );

    // Custom Filters
    _setCustomLpf1Params = _lib
        .lookupFunction<_SetCustomLpf1ParamsNative, _SetCustomLpf1ParamsDart>(
      'ae_set_custom_lpf1_params',
    );
    _setCustomHpf1Params = _lib
        .lookupFunction<_SetCustomLpf1ParamsNative, _SetCustomLpf1ParamsDart>(
      'ae_set_custom_hpf1_params',
    );
    _setCustomBiquadParams = _lib.lookupFunction<_SetCustomBiquadParamsNative,
        _SetCustomBiquadParamsDart>(
      'ae_set_custom_biquad_params',
    );

    // Spatialization
    _setSpatializationEnabled = _lib.lookupFunction<
        _SetSpatializationEnabledNative,
        _SetSpatializationEnabledDart>('ae_set_spatialization_enabled');
    _setPosition = _lib.lookupFunction<_SetSpatializationVec3Native,
        _SetSpatializationVec3Dart>('ae_set_position');
    _setDirection = _lib.lookupFunction<_SetSpatializationVec3Native,
        _SetSpatializationVec3Dart>('ae_set_direction');
    _setVelocity = _lib.lookupFunction<_SetSpatializationVec3Native,
        _SetSpatializationVec3Dart>('ae_set_velocity');
    _setSoundCone =
        _lib.lookupFunction<_SetConeNative, _SetConeDart>('ae_set_sound_cone');
    _setAttenuationModel = _lib
        .lookupFunction<_SetIntNative, _SetIntDart>('ae_set_attenuation_model');
    _setRolloff =
        _lib.lookupFunction<_SetSingleFloatNative, _SetSingleFloatDart>(
            'ae_set_rolloff');
    _setMinGain =
        _lib.lookupFunction<_SetSingleFloatNative, _SetSingleFloatDart>(
            'ae_set_min_gain');
    _setMaxGain =
        _lib.lookupFunction<_SetSingleFloatNative, _SetSingleFloatDart>(
            'ae_set_max_gain');
    _setMinDistance =
        _lib.lookupFunction<_SetSingleFloatNative, _SetSingleFloatDart>(
            'ae_set_min_distance');
    _setMaxDistance =
        _lib.lookupFunction<_SetSingleFloatNative, _SetSingleFloatDart>(
            'ae_set_max_distance');
    _setDopplerFactor =
        _lib.lookupFunction<_SetSingleFloatNative, _SetSingleFloatDart>(
            'ae_set_doppler_factor');

    // Listener 3D Spatialization
    _setListenerPosition = _lib.lookupFunction<_SetSpatializationVec3Native,
        _SetSpatializationVec3Dart>('ae_set_listener_position');
    _setListenerDirection = _lib.lookupFunction<_SetSpatializationVec3Native,
        _SetSpatializationVec3Dart>('ae_set_listener_direction');
    _setListenerVelocity = _lib.lookupFunction<_SetSpatializationVec3Native,
        _SetSpatializationVec3Dart>('ae_set_listener_velocity');
    _setListenerWorldUp = _lib.lookupFunction<_SetSpatializationVec3Native,
        _SetSpatializationVec3Dart>('ae_set_listener_world_up');
    _setListenerCone = _lib
        .lookupFunction<_SetConeNative, _SetConeDart>('ae_set_listener_cone');

    // Fading & Scheduling
    _setFadeInMilliseconds = _lib.lookupFunction<_SetFadeInMillisecondsNative,
        _SetFadeInMillisecondsDart>('ae_set_fade_in_milliseconds');
    _setStartTimeInPcmFrames =
        _lib.lookupFunction<_SetTimeInPcmFramesNative, _SetTimeInPcmFramesDart>(
            'ae_set_start_time_in_pcm_frames');
    _setStopTimeInPcmFrames =
        _lib.lookupFunction<_SetTimeInPcmFramesNative, _SetTimeInPcmFramesDart>(
            'ae_set_stop_time_in_pcm_frames');
    _getEngineTimeInPcmFrames = _lib.lookupFunction<
        _GetEngineTimeInPcmFramesNative,
        _GetEngineTimeInPcmFramesDart>('ae_get_engine_time_in_pcm_frames');
    _setEndCallback =
        _lib.lookupFunction<_SetEndCallbackNative, _SetEndCallbackDart>(
            'ae_set_end_callback');

    // Advanced Audio Features Bindings
    _setExclusiveMode =
        _lib.lookupFunction<_SetExclusiveModeNative, _SetExclusiveModeDart>(
      'ae_set_exclusive_mode',
    );
    _getExclusiveMode =
        _lib.lookupFunction<_GetExclusiveModeNative, _GetExclusiveModeDart>(
      'ae_get_exclusive_mode',
    );
    _setOutputBackend =
        _lib.lookupFunction<_SetOutputBackendNative, _SetOutputBackendDart>(
      'ae_set_output_backend',
    );
    _getOutputBackend =
        _lib.lookupFunction<_GetOutputBackendNative, _GetOutputBackendDart>(
      'ae_get_output_backend',
    );
    _isBackendSupported =
        _lib.lookupFunction<_IsBackendSupportedNative, _IsBackendSupportedDart>(
      'ae_is_backend_supported',
    );
    _setOutputFormat =
        _lib.lookupFunction<_SetOutputFormatNative, _SetOutputFormatDart>(
      'ae_set_output_format',
    );
    _getOutputFormat =
        _lib.lookupFunction<_GetOutputFormatNative, _GetOutputFormatDart>(
      'ae_get_output_format',
    );
    _setOutputSampleRate =
        _lib.lookupFunction<_SetOutputRateNative, _SetOutputRateDart>(
      'ae_set_output_sample_rate',
    );
    _getOutputSampleRate =
        _lib.lookupFunction<_GetOutputRateNative, _GetOutputRateDart>(
      'ae_get_output_sample_rate',
    );
    _setOutputChannels =
        _lib.lookupFunction<_SetOutputChannelsNative, _SetOutputChannelsDart>(
      'ae_set_output_channels',
    );
    _getOutputChannels =
        _lib.lookupFunction<_GetOutputChannelsNative, _GetOutputChannelsDart>(
      'ae_get_output_channels',
    );

    try {
      _setOutputBuffer = _lib.lookupFunction<_SetOutputBufferNative,
          _SetOutputBufferDart>('ae_set_output_buffer');
      _getOutputBuffer = _lib.lookupFunction<_GetOutputBufferNative,
          _GetOutputBufferDart>('ae_get_output_buffer');
    } catch (_) {
      _setOutputBuffer = null;
      _getOutputBuffer = null;
    }

    _setEngineResampleAlgorithm = _lib.lookupFunction<
        _SetEngineResampleAlgorithmNative,
        _SetEngineResampleAlgorithmDart>('ae_set_engine_resample_algorithm');
    _getEngineResampleAlgorithm = _lib.lookupFunction<
        _GetEngineResampleAlgorithmNative,
        _GetEngineResampleAlgorithmDart>('ae_get_engine_resample_algorithm');

    _setEngineDitherMode = _lib.lookupFunction<_SetEngineDitherModeNative,
        _SetEngineDitherModeDart>('ae_set_engine_dither_mode');
    _getEngineDitherMode = _lib.lookupFunction<_GetEngineDitherModeNative,
        _GetEngineDitherModeDart>('ae_get_engine_dither_mode');

    try {
      _set64BitProcessingEnabled =
          _lib.lookupFunction<_SetFxEnabledNative, _SetFxEnabledDart>(
              'ae_set_64bit_processing_enabled');
      _get64BitProcessingEnabled =
          _lib.lookupFunction<_GetIntNative, _GetIntDart>(
              'ae_get_64bit_processing_enabled');
    } catch (_) {
      _set64BitProcessingEnabled = null;
      _get64BitProcessingEnabled = null;
    }

    try {
      _setAutoSampleRateMatchEnabled =
          _lib.lookupFunction<_SetFxEnabledNative, _SetFxEnabledDart>(
              'ae_set_auto_sample_rate_match_enabled');
      _getAutoSampleRateMatchEnabled =
          _lib.lookupFunction<_GetIntNative, _GetIntDart>(
              'ae_get_auto_sample_rate_match_enabled');
      _consumePendingRateChange =
          _lib.lookupFunction<_GetIntNative, _GetIntDart>(
              'ae_consume_pending_rate_change');
    } catch (_) {
      try {
        _setAutoSampleRateMatchEnabled =
            _lib.lookupFunction<_SetFxEnabledNative, _SetFxEnabledDart>(
                'ae_set_auto_bit_perfect_enabled');
        _getAutoSampleRateMatchEnabled =
            _lib.lookupFunction<_GetIntNative, _GetIntDart>(
                'ae_get_auto_bit_perfect_enabled');
        _consumePendingRateChange =
            _lib.lookupFunction<_GetIntNative, _GetIntDart>(
                'ae_consume_pending_rate_change');
      } catch (_) {
        _setAutoSampleRateMatchEnabled = null;
        _getAutoSampleRateMatchEnabled = null;
        _consumePendingRateChange = null;
      }
    }

    try {
      _setPhaseInversion =
          _lib.lookupFunction<_SetPhaseInversionNative, _SetPhaseInversionDart>(
              'ae_set_phase_inversion');
      _getPhaseInversion =
          _lib.lookupFunction<_GetPhaseInversionNative, _GetPhaseInversionDart>(
              'ae_get_phase_inversion');
    } catch (_) {
      _setPhaseInversion = null;
      _getPhaseInversion = null;
    }

    try {
      _setLrSwap = _lib
          .lookupFunction<_SetLrSwapNative, _SetLrSwapDart>('ae_set_lr_swap');
      _getLrSwap = _lib
          .lookupFunction<_GetLrSwapNative, _GetLrSwapDart>('ae_get_lr_swap');
      _setChannelGains =
          _lib.lookupFunction<_SetChannelGainsNative, _SetChannelGainsDart>(
              'ae_set_channel_gains');
      _getChannelGains =
          _lib.lookupFunction<_GetChannelGainsNative, _GetChannelGainsDart>(
              'ae_get_channel_gains');
    } catch (_) {
      _setLrSwap = null;
      _getLrSwap = null;
      _setChannelGains = null;
      _getChannelGains = null;
    }

    // Limiter & Clipping Detection
    _setLimiterEnabled =
        _lib.lookupFunction<_SetLimiterEnabledNative, _SetLimiterEnabledDart>(
            'ae_set_limiter_enabled');
    _setLimiterParams =
        _lib.lookupFunction<_SetLimiterParamsNative, _SetLimiterParamsDart>(
            'ae_set_limiter_params');

    // Dynamic Range Compressor
    _setCompressorEnabled =
        _lib.lookupFunction<_SetCompressorEnabledNative, _SetCompressorEnabledDart>(
            'ae_set_compressor_enabled');
    _setCompressorParams =
        _lib.lookupFunction<_SetCompressorParamsNative, _SetCompressorParamsDart>(
            'ae_set_compressor_params');
    _getCompressorGainReductionDb = _lib.lookupFunction<
        _GetCompressorGainReductionDbNative,
        _GetCompressorGainReductionDbDart>('ae_get_compressor_gain_reduction_db');

    _setClippingDetectionEnabled = _lib.lookupFunction<
        _SetClippingDetectionEnabledNative,
        _SetClippingDetectionEnabledDart>('ae_set_clipping_detection_enabled');
    _getClippedSamplesCount = _lib.lookupFunction<_GetClippedSamplesCountNative,
        _GetClippedSamplesCountDart>('ae_get_clipped_samples_count');
    _resetClippedSamplesCount = _lib.lookupFunction<
        _ResetClippedSamplesCountNative,
        _ResetClippedSamplesCountDart>('ae_reset_clipped_samples_count');

    _initMultibandEq =
        _lib.lookupFunction<_InitMultibandEqNative, _InitMultibandEqDart>(
      'ae_init_multiband_eq',
    );
    _setMultibandEqEnabled = _lib.lookupFunction<_SetMultibandEqEnabledNative,
        _SetMultibandEqEnabledDart>('ae_set_multiband_eq_enabled');
    _setMultibandEqGain =
        _lib.lookupFunction<_SetMultibandEqGainNative, _SetMultibandEqGainDart>(
      'ae_set_multiband_eq_gain',
    );
    _getMultibandEqGain =
        _lib.lookupFunction<_GetMultibandEqGainNative, _GetMultibandEqGainDart>(
      'ae_get_multiband_eq_gain',
    );
    _setMultibandFxEnabled = _lib.lookupFunction<_SetMultibandFxEnabledNative,
        _SetMultibandFxEnabledDart>('ae_set_multiband_fx_enabled');
    _setMultibandFxBands = _lib
        .lookupFunction<_SetMultibandFxBandsNative, _SetMultibandFxBandsDart>(
      'ae_set_multiband_fx_bands',
    );
    _clearMultibandFx =
        _lib.lookupFunction<_ClearMultibandFxNative, _ClearMultibandFxDart>(
      'ae_clear_multiband_fx',
    );

    _initPushStream =
        _lib.lookupFunction<_InitPushStreamNative, _InitPushStreamDart>(
      'ae_init_push_stream',
    );
    _pushStreamChunk =
        _lib.lookupFunction<_PushStreamChunkNative, _PushStreamChunkDart>(
      'ae_push_stream_chunk',
    );
    _endPushStream =
        _lib.lookupFunction<_EndPushStreamNative, _EndPushStreamDart>(
      'ae_end_push_stream',
    );
    _getPushStreamBufferedBytes = _lib.lookupFunction<
        _GetPushStreamBufferedBytesNative, _GetPushStreamBufferedBytesDart>(
      'ae_get_push_stream_buffered_bytes',
    );

    _setAnalyzerEnabled =
        _lib.lookupFunction<_SetAnalyzerEnabledNative, _SetAnalyzerEnabledDart>(
      'ae_set_analyzer_enabled',
    );
    _configureAnalyzer =
        _lib.lookupFunction<_ConfigureAnalyzerNative, _ConfigureAnalyzerDart>(
      'ae_configure_analyzer',
    );
    _getAnalyzerFrameSize = _lib.lookupFunction<_GetAnalyzerFrameSizeNative,
        _GetAnalyzerFrameSizeDart>('ae_get_analyzer_frame_size');
    _pollAnalyzerFrame =
        _lib.lookupFunction<_PollAnalyzerFrameNative, _PollAnalyzerFrameDart>(
      'ae_poll_analyzer_frame',
    );

    try {
      _getLoudnessMetrics = _lib.lookupFunction<_GetLoudnessMetricsNative,
          _GetLoudnessMetricsDart>('ae_get_loudness_metrics');
      _resetLoudnessMeter = _lib.lookupFunction<_ResetLoudnessMeterNative,
          _ResetLoudnessMeterDart>('ae_reset_loudness_meter');
      _setLoudnessNormalizerEnabled = _lib.lookupFunction<
              _SetLoudnessNormalizerEnabledNative,
              _SetLoudnessNormalizerEnabledDart>(
          'ae_set_loudness_normalizer_enabled');
      _setLoudnessNormalizerTarget = _lib.lookupFunction<
              _SetLoudnessNormalizerTargetNative,
              _SetLoudnessNormalizerTargetDart>(
          'ae_set_loudness_normalizer_target');
      _getLoudnessNormalizerEnabled = _lib.lookupFunction<
              _GetLoudnessNormalizerEnabledNative,
              _GetLoudnessNormalizerEnabledDart>(
          'ae_get_loudness_normalizer_enabled');
      _getLoudnessNormalizerTarget = _lib.lookupFunction<
              _GetLoudnessNormalizerTargetNative,
              _GetLoudnessNormalizerTargetDart>(
          'ae_get_loudness_normalizer_target');
      _getLoudnessNormalizerGainDb = _lib.lookupFunction<
              _GetLoudnessNormalizerGainDbNative,
              _GetLoudnessNormalizerGainDbDart>(
          'ae_get_loudness_normalizer_gain_db');
      _getTruePeak = _lib.lookupFunction<_GetTruePeakNative, _GetTruePeakDart>(
          'ae_get_true_peak');
      _setLookaheadLimiterEnabled = _lib.lookupFunction<
          _SetLookaheadLimiterEnabledNative,
          _SetLookaheadLimiterEnabledDart>('ae_set_lookahead_limiter_enabled');
      _setLookaheadLimiterParams = _lib.lookupFunction<
          _SetLookaheadLimiterParamsNative,
          _SetLookaheadLimiterParamsDart>('ae_set_lookahead_limiter_params');
      _getLookaheadLimiterGainReductionDb = _lib.lookupFunction<
              _GetLookaheadLimiterGainReductionDbNative,
              _GetLookaheadLimiterGainReductionDbDart>(
          'ae_get_lookahead_limiter_gain_reduction_db');
      _getQualityTelemetry = _lib.lookupFunction<_GetQualityTelemetryNative,
          _GetQualityTelemetryDart>('ae_get_quality_telemetry');
    } catch (_) {
      _getLoudnessMetrics = null;
      _resetLoudnessMeter = null;
      _setLoudnessNormalizerEnabled = null;
      _setLoudnessNormalizerTarget = null;
      _getLoudnessNormalizerEnabled = null;
      _getLoudnessNormalizerTarget = null;
      _getLoudnessNormalizerGainDb = null;
      _getTruePeak = null;
      _setLookaheadLimiterEnabled = null;
      _setLookaheadLimiterParams = null;
      _getLookaheadLimiterGainReductionDb = null;
      _getQualityTelemetry = null;
    }
    _getAnalyzerDroppedFrames = _lib.lookupFunction<
        _GetAnalyzerDroppedFramesNative,
        _GetAnalyzerDroppedFramesDart>('ae_get_analyzer_dropped_frames');

    try {
      _getNetworkStreamingSupport = _lib.lookupFunction<
          _GetNetworkStreamingSupportNative,
          _GetNetworkStreamingSupportDart>('ae_is_network_streaming_supported');
    } catch (_) {
      _getNetworkStreamingSupport = null;
    }

    try {
      _getStreamTelemetry = _lib.lookupFunction<_GetStreamTelemetryNative,
          _GetStreamTelemetryDart>('ae_get_stream_telemetry');
    } catch (_) {
      _getStreamTelemetry = null;
    }

    try {
      _isStreamLive = _lib.lookupFunction<_IsStreamLiveNative,
          _IsStreamLiveDart>('ae_is_stream_live');
    } catch (_) {
      _isStreamLive = null;
    }

    try {
      _inspectFile = _lib.lookupFunction<_InspectFileNative, _InspectFileDart>(
        'ae_inspect_file',
      );
    } catch (_) {
      _inspectFile = null;
    }

    try {
      _getHardwareInfo =
          _lib.lookupFunction<_GetHardwareInfoNative, _GetHardwareInfoDart>(
        'ae_get_hardware_info',
      );
    } catch (_) {
      _getHardwareInfo = null;
    }

    try {
      _registerAndroidJvm = _lib
          .lookupFunction<_RegisterAndroidJvmNative, _RegisterAndroidJvmDart>(
        'ae_register_android_jvm',
      );
    } catch (_) {
      _registerAndroidJvm = null;
    }
  }

  final ffi.DynamicLibrary _lib;
  ffi.DynamicLibrary get library => _lib;
  late final _CreateEngineDart _createEngine;
  late final _DestroyEngineDart _destroyEngine;
  late final _SetPlaylistDart _setPlaylist;
  late final _AddToPlaylistDart _addToPlaylist;
  late final _InsertToPlaylistDart _insertToPlaylist;
  late final _RemoveFromPlaylistDart _removeFromPlaylist;
  late final _MovePlaylistItemDart _movePlaylistItem;
  late final _ClearPlaylistDart _clearPlaylist;
  late final _BoolOpDart _play;
  late final _BoolOpDart _pause;
  late final _BoolOpDart _stop;
  late final _BoolOpDart _next;
  late final _BoolOpDart _prev;
  late final _SeekDart _seek;
  late final _JumpDart _jumpTo;
  late final _JumpWithPositionDart _jumpToWithPosition;
  late final _GetDeviceLatencyMsDart _getDeviceLatencyMs;
  late final _GetEngineLatencySamplesDart _getEngineLatencySamples;
  late final _GetEngineLatencyMsDart _getEngineLatencyMs;
  late final _GetStatusDart _getStatus;
  late final _GetPipelineStateDart _getPipelineState;
  late final _GetLastErrorDart _getLastError;
  late final _ClearLastErrorDart _clearLastError;
  late final _SetIntDart _setLoopMode;
  late final _SetIntDart _setShuffleEnabled;
  late final _ClearPlaylistDart _reshuffle;
  _SetAbRepeatDart? _setAbRepeat;
  _GetAbRepeatDart? _getAbRepeat;
  late final _SetIntDart _setCrossfadeEnabled;
  late final _GetIntDart _getCrossfadeEnabled;
  late final _SetIntDart _setCrossfadeDurationMs;
  late final _GetIntDart _getCrossfadeDurationMs;
  _SetIntDart? _setLoudnessCrossfadeEnabled;
  _GetIntDart? _getLoudnessCrossfadeEnabled;
  _SetSingleFloatDart? _setNextReplayGain;
  late final _SetFxEnabledDart _setReverbEnabled;
  late final _SetReverbParamsDart _setReverbParams;
  late final _SetReverbParamsExDart _setReverbParamsEx;
  late final _GetReverbParamsExDart _getReverbParamsEx;
  late final _SetReverbGainsDart _setReverbGains;
  late final _GetReverbGainsDart _getReverbGains;
  late final _SetFxEnabledDart _setEqEnabled;
  late final _SetEqGainsDart _setEqGains;
  late final _SetSingleFloatDart _setGain;
  _SetSingleFloatDart? _setReplayGain;
  late final _SetSingleFloatDart _setPan;
  late final _SetSingleFloatDart _setRate;
  _GetFloatDart? _getRate;
  late final _SetSingleFloatDart _setPitch;
  _GetFloatDart? _getPitch;
  late final _SetSingleIntDart _setPitchCorrection;
  _GetIntDart? _getPitchCorrection;
  late final _SetFxEnabledDart _setLowpassEnabled;
  late final _SetSingleFloatDart _setLowpassCutoff;
  late final _SetFxEnabledDart _setHighpassEnabled;
  late final _SetSingleFloatDart _setHighpassCutoff;
  late final _SetFxEnabledDart _setDelayEnabled;
  late final _SetReverbParamsDart _setDelayParams;
  late final _SetStereoWidenDart _setStereoWiden;
  late final _SetStereoEnhancementEnabledDart _setStereoEnhancementEnabled;
  late final _GetStereoEnhancementEnabledDart _getStereoEnhancementEnabled;
  late final _SetStereoEnhancementMixDart _setStereoEnhancementMix;
  late final _GetStereoEnhancementMixDart _getStereoEnhancementMix;
  late final _SetFxEnabledDart _setCrossfeedEnabled;
  late final _SetSingleIntDart _setCrossfeedPreset;
  late final _SetRaceParamsDart _setRaceParams;
  // CrossfeedNode extended API
  late final _SetCrossfeedAlgorithmDart _setCrossfeedAlgorithm;
  late final _SetCrossfeedParamsDart _setCrossfeedParams;
  late final _GetCrossfeedParamsDart _getCrossfeedParams;
  late final _SetFxEnabledDart _setDynamicBassEnabled;
  late final _SetDynamicBassParamsDart _setDynamicBassParams;

  // Crystalizer
  late final _SetCrystalizerEnabledDart _setCrystalizerEnabled;
  late final _SetCrystalizerParamsDart _setCrystalizerParams;
  late final _GetCrystalizerIntensityDart _getCrystalizerIntensity;

  // Reusable native buffer for spectrum analyzer polling (prevents 60 FPS malloc churn)
  ffi.Pointer<ffi.Float>? _analyzerBufferPtr;
  int _analyzerBufferCapacity = 0;
  late final _SetFxEnabledDart _setBandpassEnabled;
  late final _SetTwoFloatsDart _setBandpassParams;
  late final _SetFxEnabledDart _setPeakEqEnabled;
  late final _SetReverbParamsDart _setPeakEqParams;
  late final _SetFxEnabledDart _setNotchEnabled;
  late final _SetTwoFloatsDart _setNotchParams;
  late final _SetFxEnabledDart _setLowshelfEnabled;
  late final _SetReverbParamsDart _setLowshelfParams;
  late final _SetFxEnabledDart _setHighshelfEnabled;
  late final _SetReverbParamsDart _setHighshelfParams;

  // Custom filters
  late final _SetCustomLpf1ParamsDart _setCustomLpf1Params;
  late final _SetCustomLpf1ParamsDart _setCustomHpf1Params;
  late final _SetCustomBiquadParamsDart _setCustomBiquadParams;

  // Spatialization
  late final _SetSpatializationEnabledDart _setSpatializationEnabled;
  late final _SetSpatializationVec3Dart _setPosition;
  late final _SetSpatializationVec3Dart _setDirection;
  late final _SetSpatializationVec3Dart _setVelocity;
  late final _SetConeDart _setSoundCone;
  late final _SetIntDart _setAttenuationModel;
  late final _SetSingleFloatDart _setRolloff;
  late final _SetSingleFloatDart _setMinGain;
  late final _SetSingleFloatDart _setMaxGain;
  late final _SetSingleFloatDart _setMinDistance;
  late final _SetSingleFloatDart _setMaxDistance;
  late final _SetSingleFloatDart _setDopplerFactor;

  // Listener 3D Spatialization
  late final _SetSpatializationVec3Dart _setListenerPosition;
  late final _SetSpatializationVec3Dart _setListenerDirection;
  late final _SetSpatializationVec3Dart _setListenerVelocity;
  late final _SetSpatializationVec3Dart _setListenerWorldUp;
  late final _SetConeDart _setListenerCone;

  // Fading & Scheduling
  late final _SetFadeInMillisecondsDart _setFadeInMilliseconds;
  late final _SetTimeInPcmFramesDart _setStartTimeInPcmFrames;
  late final _SetTimeInPcmFramesDart _setStopTimeInPcmFrames;
  late final _GetEngineTimeInPcmFramesDart _getEngineTimeInPcmFrames;
  late final _SetEndCallbackDart _setEndCallback;

  // Advanced Audio Features
  late final _SetExclusiveModeDart _setExclusiveMode;
  late final _GetExclusiveModeDart _getExclusiveMode;
  late final _SetOutputBackendDart _setOutputBackend;
  late final _GetOutputBackendDart _getOutputBackend;
  late final _IsBackendSupportedDart _isBackendSupported;
  late final _SetOutputFormatDart _setOutputFormat;
  late final _GetOutputFormatDart _getOutputFormat;
  late final _SetOutputRateDart _setOutputSampleRate;
  late final _GetOutputRateDart _getOutputSampleRate;
  late final _SetOutputChannelsDart _setOutputChannels;
  late final _GetOutputChannelsDart _getOutputChannels;
  _SetOutputBufferDart? _setOutputBuffer;
  _GetOutputBufferDart? _getOutputBuffer;

  late final _SetEngineResampleAlgorithmDart _setEngineResampleAlgorithm;
  late final _GetEngineResampleAlgorithmDart _getEngineResampleAlgorithm;
  late final _SetEngineDitherModeDart _setEngineDitherMode;
  late final _GetEngineDitherModeDart _getEngineDitherMode;
  late final _SetFxEnabledDart? _set64BitProcessingEnabled;
  late final _GetIntDart? _get64BitProcessingEnabled;
  late final _SetFxEnabledDart? _setAutoSampleRateMatchEnabled;
  late final _GetIntDart? _getAutoSampleRateMatchEnabled;
  _GetIntDart? _consumePendingRateChange;
  late final _SetPhaseInversionDart? _setPhaseInversion;
  late final _GetPhaseInversionDart? _getPhaseInversion;
  late final _SetLrSwapDart? _setLrSwap;
  late final _GetLrSwapDart? _getLrSwap;
  late final _SetChannelGainsDart? _setChannelGains;
  late final _GetChannelGainsDart? _getChannelGains;

  // Limiter & Clipping Detection
  late final _SetLimiterEnabledDart _setLimiterEnabled;
  late final _SetLimiterParamsDart _setLimiterParams;

  late final _SetCompressorEnabledDart _setCompressorEnabled;
  late final _SetCompressorParamsDart _setCompressorParams;
  late final _GetCompressorGainReductionDbDart _getCompressorGainReductionDb;
  late final _SetClippingDetectionEnabledDart _setClippingDetectionEnabled;
  late final _GetClippedSamplesCountDart _getClippedSamplesCount;
  late final _ResetClippedSamplesCountDart _resetClippedSamplesCount;

  late final _InitMultibandEqDart _initMultibandEq;
  late final _SetMultibandEqEnabledDart _setMultibandEqEnabled;
  late final _SetMultibandEqGainDart _setMultibandEqGain;
  late final _GetMultibandEqGainDart _getMultibandEqGain;
  late final _SetMultibandFxEnabledDart _setMultibandFxEnabled;
  late final _SetMultibandFxBandsDart _setMultibandFxBands;
  late final _ClearMultibandFxDart _clearMultibandFx;

  late final _InitPushStreamDart _initPushStream;
  late final _PushStreamChunkDart _pushStreamChunk;
  late final _EndPushStreamDart _endPushStream;
  late final _GetPushStreamBufferedBytesDart _getPushStreamBufferedBytes;

  late final _SetAnalyzerEnabledDart _setAnalyzerEnabled;
  late final _ConfigureAnalyzerDart _configureAnalyzer;
  late final _GetAnalyzerFrameSizeDart _getAnalyzerFrameSize;
  late final _PollAnalyzerFrameDart _pollAnalyzerFrame;
  late final _GetAnalyzerDroppedFramesDart _getAnalyzerDroppedFrames;

  late final _MallocDart _malloc;
  late final _FreeDart _free;
  _GetNetworkStreamingSupportDart? _getNetworkStreamingSupport;
  _GetStreamTelemetryDart? _getStreamTelemetry;
  _IsStreamLiveDart? _isStreamLive;
  _InspectFileDart? _inspectFile;
  _GetHardwareInfoDart? _getHardwareInfo;
  _RegisterAndroidJvmDart? _registerAndroidJvm;

  // Release 1 Quality Foundation Lookups
  _GetLoudnessMetricsDart? _getLoudnessMetrics;
  _ResetLoudnessMeterDart? _resetLoudnessMeter;
  _SetLoudnessNormalizerEnabledDart? _setLoudnessNormalizerEnabled;
  _SetLoudnessNormalizerTargetDart? _setLoudnessNormalizerTarget;
  _GetLoudnessNormalizerEnabledDart? _getLoudnessNormalizerEnabled;
  _GetLoudnessNormalizerTargetDart? _getLoudnessNormalizerTarget;
  _GetLoudnessNormalizerGainDbDart? _getLoudnessNormalizerGainDb;
  _GetTruePeakDart? _getTruePeak;
  _SetLookaheadLimiterEnabledDart? _setLookaheadLimiterEnabled;
  _SetLookaheadLimiterParamsDart? _setLookaheadLimiterParams;
  _GetLookaheadLimiterGainReductionDbDart? _getLookaheadLimiterGainReductionDb;
  _GetQualityTelemetryDart? _getQualityTelemetry;

  ffi.Pointer<ffi.Void> _engine;
  ffi.Pointer<ffi.Void> get enginePointer => _engine;

  ffi.Pointer<ffi.Char> _toNativeChar(String value) {
    final bytes = utf8.encode(value);
    final ptr = _malloc(bytes.length + 1).cast<ffi.Uint8>();
    final list = ptr.asTypedList(bytes.length + 1);
    list.setAll(0, bytes);
    list[bytes.length] = 0;
    return ptr.cast<ffi.Char>();
  }

  void _freePtr(ffi.Pointer<ffi.Void> ptr) {
    if (ptr != ffi.nullptr) {
      _free(ptr);
    }
  }

  String _fromNativeCharPtr(ffi.Pointer<ffi.Char> ptr) {
    if (ptr == ffi.nullptr) return '';
    final bytes = <int>[];
    var offset = 0;
    while (true) {
      final b = ptr.cast<ffi.Uint8>().elementAt(offset).value;
      if (b == 0) break;
      bytes.add(b);
      offset++;
    }
    if (bytes.isEmpty) return '';
    return utf8.decode(bytes, allowMalformed: true);
  }

  String _uriToEnginePath(Uri uri) {
    if (uri.scheme == 'file') {
      return uri.toFilePath();
    }
    return uri.toString();
  }

  static ffi.DynamicLibrary openLibrary(String? path) {
    if (path != null && path.isNotEmpty) {
      return ffi.DynamicLibrary.open(path);
    }
    if (Platform.isWindows) {
      try {
        return ffi.DynamicLibrary.open('sautiflow.dll');
      } catch (_) {
        return ffi.DynamicLibrary.open('audio_engine.dll');
      }
    }
    if (Platform.isIOS) return ffi.DynamicLibrary.process();
    if (Platform.isMacOS) {
      try {
        return ffi.DynamicLibrary.open('libsautiflow.dylib');
      } catch (_) {
        return ffi.DynamicLibrary.open('libaudio_engine.dylib');
      }
    }
    if (Platform.isAndroid) {
      try {
        return ffi.DynamicLibrary.open('libsautiflow.so');
      } catch (_) {
        return ffi.DynamicLibrary.open('libaudio_engine.so');
      }
    }
    try {
      return ffi.DynamicLibrary.open('libsautiflow.so');
    } catch (_) {
      return ffi.DynamicLibrary.open('libaudio_engine.so');
    }
  }

  static ffi.DynamicLibrary openAllocatorLibrary() {
    if (Platform.isWindows) return ffi.DynamicLibrary.open('msvcrt.dll');
    if (Platform.isMacOS || Platform.isIOS) return ffi.DynamicLibrary.process();
    if (Platform.isLinux || Platform.isAndroid) {
      try {
        return ffi.DynamicLibrary.open('libc.so.6');
      } catch (_) {
        return ffi.DynamicLibrary.process();
      }
    }
    return ffi.DynamicLibrary.process();
  }

  bool create({int sampleRate = 48000, int channels = 2}) {
    if (_engine != ffi.nullptr) return true;
    _engine = _createEngine(sampleRate, channels);
    return _engine != ffi.nullptr;
  }

  ffi.Pointer<ffi.Int32>? _telStatePtr;
  ffi.Pointer<ffi.Int32>? _telErrorCodePtr;
  ffi.Pointer<ffi.Double>? _telBufferedPtr;
  ffi.Pointer<ffi.Double>? _telTotalPtr;
  ffi.Pointer<ffi.Double>? _telBufferPctPtr;
  ffi.Pointer<ffi.Int64>? _telBitratePtr;
  ffi.Pointer<ffi.Char>? _telCodecPtr;
  ffi.Pointer<ffi.Char>? _telIcyTitlePtr;
  ffi.Pointer<ffi.Char>? _telIcyArtistPtr;
  ffi.Pointer<ffi.Int32>? _pAbEnabled;
  ffi.Pointer<ffi.Double>? _pAbStart;
  ffi.Pointer<ffi.Double>? _pAbEnd;
  double _masterGain = 1.0;

  void dispose() {
    if (_analyzerBufferPtr != null && _analyzerBufferPtr != ffi.nullptr) {
      _freePtr(_analyzerBufferPtr!.cast<ffi.Void>());
      _analyzerBufferPtr = null;
      _analyzerBufferCapacity = 0;
    }
    if (_pAbEnabled != null) {
      _freePtr(_pAbEnabled!.cast<ffi.Void>());
      _freePtr(_pAbStart!.cast<ffi.Void>());
      _freePtr(_pAbEnd!.cast<ffi.Void>());
      _pAbEnabled = null;
      _pAbStart = null;
      _pAbEnd = null;
    }
    if (_telStatePtr != null) {
      _freePtr(_telStatePtr!.cast<ffi.Void>());
      _freePtr(_telErrorCodePtr!.cast<ffi.Void>());
      _freePtr(_telBufferedPtr!.cast<ffi.Void>());
      _freePtr(_telTotalPtr!.cast<ffi.Void>());
      _freePtr(_telBufferPctPtr!.cast<ffi.Void>());
      _freePtr(_telBitratePtr!.cast<ffi.Void>());
      _freePtr(_telCodecPtr!.cast<ffi.Void>());
      _freePtr(_telIcyTitlePtr!.cast<ffi.Void>());
      _freePtr(_telIcyArtistPtr!.cast<ffi.Void>());
      _telStatePtr = null;
      _telErrorCodePtr = null;
      _telBufferedPtr = null;
      _telTotalPtr = null;
      _telBufferPctPtr = null;
      _telBitratePtr = null;
      _telCodecPtr = null;
      _telIcyTitlePtr = null;
      _telIcyArtistPtr = null;
    }
    if (_engine != ffi.nullptr) {
      _destroyEngine(_engine);
      _engine = ffi.nullptr;
    }
  }

  bool isNetworkStreamingSupported() {
    final getter = _getNetworkStreamingSupport;
    if (getter == null) return false;
    return getter() != 0;
  }

  StreamTelemetry getStreamTelemetry() {
    final getter = _getStreamTelemetry;
    if (getter == null || _engine == ffi.nullptr) {
      return const StreamTelemetry();
    }

    const codecLen = 32;
    const icyLen = 256;

    if (_telStatePtr == null) {
      _telStatePtr = _malloc(ffi.sizeOf<ffi.Int32>()).cast<ffi.Int32>();
      _telErrorCodePtr = _malloc(ffi.sizeOf<ffi.Int32>()).cast<ffi.Int32>();
      _telBufferedPtr = _malloc(ffi.sizeOf<ffi.Double>()).cast<ffi.Double>();
      _telTotalPtr = _malloc(ffi.sizeOf<ffi.Double>()).cast<ffi.Double>();
      _telBufferPctPtr = _malloc(ffi.sizeOf<ffi.Double>()).cast<ffi.Double>();
      _telBitratePtr = _malloc(ffi.sizeOf<ffi.Int64>()).cast<ffi.Int64>();
      _telCodecPtr = _malloc(codecLen).cast<ffi.Char>();
      _telIcyTitlePtr = _malloc(icyLen).cast<ffi.Char>();
      _telIcyArtistPtr = _malloc(icyLen).cast<ffi.Char>();
    }

    final outState = _telStatePtr!;
    final outErrorCode = _telErrorCodePtr!;
    final outBuffered = _telBufferedPtr!;
    final outTotal = _telTotalPtr!;
    final outBufferPct = _telBufferPctPtr!;
    final outBitrate = _telBitratePtr!;
    final outCodec = _telCodecPtr!;
    final outIcyTitle = _telIcyTitlePtr!;
    final outIcyArtist = _telIcyArtistPtr!;

    getter(
      _engine,
      outState,
      outErrorCode,
      outBuffered,
      outTotal,
      outBufferPct,
      outBitrate,
      outCodec,
      codecLen,
      outIcyTitle,
      icyLen,
      outIcyArtist,
      icyLen,
    );

    final stateIdx = outState.value;
    final state = (stateIdx >= 0 && stateIdx < StreamPlaybackState.values.length)
        ? StreamPlaybackState.values[stateIdx]
        : StreamPlaybackState.idle;

    final codecStr = outCodec.cast<Utf8>().toDartString();
    final icyTitleStr = outIcyTitle.cast<Utf8>().toDartString();
    final icyArtistStr = outIcyArtist.cast<Utf8>().toDartString();
    final isLive = isCurrentStreamLive();

    return StreamTelemetry(
      state: state,
      errorCode: outErrorCode.value,
      bufferedDuration: Duration(
        milliseconds: (outBuffered.value * 1000).round(),
      ),
      totalDuration: Duration(
        milliseconds: (outTotal.value * 1000).round(),
      ),
      bufferPercent: outBufferPct.value,
      bitrate: outBitrate.value,
      codecName: codecStr,
      icyTitle: icyTitleStr,
      icyArtist: icyArtistStr,
      isLive: isLive,
      isSeekable: !isLive && outTotal.value > 0,
    );
  }

  bool isCurrentStreamLive() {
    final getter = _isStreamLive;
    if (getter == null || _engine == ffi.nullptr) return false;
    return getter(_engine) != 0;
  }

  bool setPlaylist(List<String> paths) {
    if (_engine == ffi.nullptr || paths.isEmpty) return false;

    final ptrArray = _malloc(
      ffi.sizeOf<ffi.Pointer<ffi.Char>>() * paths.length,
    ).cast<ffi.Pointer<ffi.Char>>();
    final allocated = <ffi.Pointer<ffi.Char>>[];

    try {
      for (var i = 0; i < paths.length; i++) {
        final c = _toNativeChar(paths[i]);
        allocated.add(c);
        ptrArray[i] = c;
      }
      return _setPlaylist(_engine, ptrArray, paths.length) != 0;
    } finally {
      for (final p in allocated) {
        _freePtr(p.cast<ffi.Void>());
      }
      _freePtr(ptrArray.cast<ffi.Void>());
    }
  }

  bool addToPlaylist(String path) {
    if (_engine == ffi.nullptr) return false;
    final c = _toNativeChar(path);
    try {
      return _addToPlaylist(_engine, c) != 0;
    } finally {
      _freePtr(c.cast<ffi.Void>());
    }
  }

  bool insertAudioSource(int index, String path) {
    if (_engine == ffi.nullptr) return false;
    final c = _toNativeChar(path);
    try {
      return _insertToPlaylist(_engine, index, c) != 0;
    } finally {
      _freePtr(c.cast<ffi.Void>());
    }
  }

  bool removeAudioSourceAt(int index) {
    if (_engine == ffi.nullptr) return false;
    return _removeFromPlaylist(_engine, index) != 0;
  }

  bool moveAudioSource(int fromIndex, int toIndex) {
    if (_engine == ffi.nullptr) return false;
    return _movePlaylistItem(_engine, fromIndex, toIndex) != 0;
  }

  void clearPlaylist() {
    if (_engine == ffi.nullptr) return;
    _clearPlaylist(_engine);
  }

  bool play() => _engine != ffi.nullptr && _play(_engine) != 0;
  bool pause() => _engine != ffi.nullptr && _pause(_engine) != 0;
  bool stop() => _engine != ffi.nullptr && _stop(_engine) != 0;
  bool next() => _engine != ffi.nullptr && _next(_engine) != 0;
  bool prev() => _engine != ffi.nullptr && _prev(_engine) != 0;
  bool jumpTo(int index) =>
      _engine != ffi.nullptr && _jumpTo(_engine, index) != 0;

  bool jumpToWithPosition(int index, Duration position) =>
      _engine != ffi.nullptr &&
      _jumpToWithPosition(
            _engine,
            index,
            position.inMicroseconds / 1000000.0,
          ) !=
          0;

  bool seekToNext() => next();
  bool seekToPrevious() => prev();

  void setLoopMode(LoopMode mode) {
    if (_engine == ffi.nullptr) return;
    _setLoopMode(_engine, mode.index);
  }

  void setShuffleModeEnabled(bool enabled) {
    if (_engine == ffi.nullptr) return;
    _setShuffleEnabled(_engine, enabled ? 1 : 0);
  }

  void reshuffle() {
    if (_engine == ffi.nullptr) return;
    _reshuffle(_engine);
  }

  void setAbRepeat({
    required bool enabled,
    double startSeconds = 0.0,
    double endSeconds = 0.0,
  }) {
    if (_engine == ffi.nullptr || _setAbRepeat == null) return;
    _setAbRepeat!(_engine, enabled ? 1 : 0, startSeconds, endSeconds);
  }

  ({bool enabled, double startSeconds, double endSeconds}) getAbRepeat() {
    if (_engine == ffi.nullptr || _getAbRepeat == null) {
      return (enabled: false, startSeconds: 0.0, endSeconds: 0.0);
    }
    _pAbEnabled ??= _malloc(ffi.sizeOf<ffi.Int32>()).cast<ffi.Int32>();
    _pAbStart ??= _malloc(ffi.sizeOf<ffi.Double>()).cast<ffi.Double>();
    _pAbEnd ??= _malloc(ffi.sizeOf<ffi.Double>()).cast<ffi.Double>();

    _getAbRepeat!(_engine, _pAbEnabled!, _pAbStart!, _pAbEnd!);
    return (
      enabled: _pAbEnabled!.value != 0,
      startSeconds: _pAbStart!.value,
      endSeconds: _pAbEnd!.value,
    );
  }

  void setCrossfadeEnabled(bool enabled) {
    if (_engine == ffi.nullptr) return;
    _setCrossfadeEnabled(_engine, enabled ? 1 : 0);
  }

  bool getCrossfadeEnabled() {
    if (_engine == ffi.nullptr) return false;
    return _getCrossfadeEnabled(_engine) != 0;
  }

  void setCrossfadeDurationMs(int durationMs) {
    if (_engine == ffi.nullptr) return;
    _setCrossfadeDurationMs(_engine, durationMs);
  }

  int getCrossfadeDurationMs() {
    if (_engine == ffi.nullptr) return 0;
    return _getCrossfadeDurationMs(_engine);
  }

  void setLoudnessCrossfadeEnabled(bool enabled) {
    if (_engine == ffi.nullptr || _setLoudnessCrossfadeEnabled == null) return;
    _setLoudnessCrossfadeEnabled!(_engine, enabled ? 1 : 0);
  }

  bool getLoudnessCrossfadeEnabled() {
    if (_engine == ffi.nullptr || _getLoudnessCrossfadeEnabled == null) {
      return false;
    }
    return _getLoudnessCrossfadeEnabled!(_engine) != 0;
  }

  void setNextReplayGain(double gainDb) {
    if (_engine == ffi.nullptr || _setNextReplayGain == null) return;
    _setNextReplayGain!(_engine, gainDb);
  }

  TrackNativeInfo? inspectFile(String path) {
    if (_inspectFile == null) return null;
    final c = _toNativeChar(path);
    try {
      final native = _inspectFile!(c);
      return TrackNativeInfo.fromNative(native);
    } finally {
      _freePtr(c.cast<ffi.Void>());
    }
  }

  AEHardwareInfo getHardwareInfo() {
    if (_engine == ffi.nullptr || _getHardwareInfo == null) {
      return const AEHardwareInfo(
        backendName: 'Unknown',
        deviceName: 'Default Output Device',
        outputFormat: AudioFormat.f32,
        bitDepth: 32,
        isFloat: true,
        sampleRate: 48000,
        channels: 2,
        periodSizeFrames: 0,
        periodCount: 0,
        latencyMs: 0.0,
        isExclusiveMode: false,
        dspHardware: 'Host Native Audio',
        socName: 'Host Processor',
        isDirectPcm: false,
      );
    }
    final native = _getHardwareInfo!(_engine);
    return AEHardwareInfo.fromNative(native);
  }

  void registerAndroidJvm(ffi.Pointer<ffi.Void> vm) {
    if (_registerAndroidJvm != null && vm != ffi.nullptr) {
      _registerAndroidJvm!(vm);
    }
  }

  // Alias matching requested naming style.
  bool addAudioSource(String path) => addToPlaylist(path);
  bool addAudioSourceUri(Uri uri) => addToPlaylist(_uriToEnginePath(uri));

  bool setAudioSources(
    List<AudioSource> sources, {
    int initialIndex = 0,
    Duration initialPosition = Duration.zero,
    bool useLazyPreparation = true,
    bool autoPlay = true,
    Object? shuffleOrder,
  }) {
    final paths = sources.map((s) => _uriToEnginePath(s.uri)).toList();
    final ok = setPlaylist(paths);
    if (!ok) return false;

    if (sources.isEmpty) return false;
    final idx = initialIndex.clamp(0, sources.length - 1);
    final jumped = jumpToWithPosition(idx, initialPosition);

    // When autoPlay is false (e.g. queue restore), cancel the native engine's
    // pending auto-play so the track loads but stays paused.
    if (!autoPlay) {
      pause();
    }

    if (!useLazyPreparation) {
      // Force preload behavior by briefly touching next/prev ordering.
      reshuffle();
    }

    if (shuffleOrder != null) {
      // Placeholder to keep API compatibility with caller; shuffle policy remains engine-defined.
    }

    return jumped;
  }

  bool seekTo(Duration position, {int? index}) {
    if (index != null) {
      return jumpToWithPosition(index, position);
    }

    final s = getStatus();
    double durationSec = s.durationSeconds;
    if (durationSec <= 0) {
      final tel = getStreamTelemetry();
      if (tel.isSeekable && tel.totalDuration.inMilliseconds > 0) {
        durationSec = tel.totalDuration.inMicroseconds / 1000000.0;
      }
    }

    if (durationSec <= 0) return false;
    final percent = (position.inMicroseconds / 1000000.0) / durationSec;
    return seek(percent);
  }

  bool seek(double percent0to1) =>
      _engine != ffi.nullptr && _seek(_engine, percent0to1) != 0;

  PlayerStatus getStatus() {
    if (_engine == ffi.nullptr) {
      return const PlayerStatus(
        positionSeconds: 0,
        durationSeconds: 0,
        isPlaying: false,
        currentIndex: -1,
        playlistCount: 0,
        shuffleEnabled: false,
        loopMode: LoopMode.off,
      );
    }

    final s = _getStatus(_engine);
    return PlayerStatus(
      positionSeconds: s.position_seconds,
      durationSeconds: s.duration_seconds,
      isPlaying: s.is_playing != 0,
      currentIndex: s.current_index,
      playlistCount: s.playlist_count,
      shuffleEnabled: s.shuffle_enabled != 0,
      loopMode: LoopMode.values[s.loop_mode.clamp(0, 2)],
    );
  }

  double getDeviceLatencyMs() {
    if (_engine == ffi.nullptr) return 0.0;
    return _getDeviceLatencyMs(_engine);
  }

  double getEngineLatencySamples() {
    if (_engine == ffi.nullptr) return 0.0;
    return _getEngineLatencySamples(_engine);
  }

  double getEngineLatencyMs() {
    if (_engine == ffi.nullptr) return 0.0;
    return _getEngineLatencyMs(_engine);
  }

  PipelineAudioState getPipelineState() {
    if (_engine == ffi.nullptr) return PipelineAudioState.empty();
    return PipelineAudioState.fromNative(_getPipelineState(_engine));
  }

  String getLastError() {
    if (_engine == ffi.nullptr) return 'Engine is not initialized';
    return _fromNativeCharPtr(_getLastError(_engine));
  }

  void clearLastError() {
    if (_engine == ffi.nullptr) return;
    _clearLastError(_engine);
  }

  void setReverbEnabled(bool enabled) {
    if (_engine == ffi.nullptr) return;
    _setReverbEnabled(_engine, enabled ? 1 : 0);
  }

  void setReverbParams({
    required double mix,
    required double feedback,
    required double delayMs,
  }) {
    if (_engine == ffi.nullptr) return;
    _setReverbParams(_engine, mix, feedback, delayMs);
  }

  /// Extended reverb params (Freeverb FDN node).
  ///
  /// [mix] dry/wet blend 0..1, [roomSize] decay 0..1, [damping] high-frequency
  /// absorption 0..1, [preDelayMs] 0..250, [width] stereo width 0..1.
  void setReverbParamsEx({
    required double mix,
    required double roomSize,
    double damping = 0.5,
    double preDelayMs = 20.0,
    double width = 1.0,
  }) {
    if (_engine == ffi.nullptr) return;
    _setReverbParamsEx(_engine, mix, roomSize, damping, preDelayMs, width);
  }

  ReverbParamsEx getReverbParamsEx() {
    if (_engine == ffi.nullptr) {
      return const ReverbParamsEx();
    }
    final enabledPtr = calloc<ffi.Int32>();
    final mixPtr = calloc<ffi.Float>();
    final roomPtr = calloc<ffi.Float>();
    final dampPtr = calloc<ffi.Float>();
    final predelayPtr = calloc<ffi.Float>();
    final widthPtr = calloc<ffi.Float>();
    try {
      _getReverbParamsEx(
          _engine, enabledPtr, mixPtr, roomPtr, dampPtr, predelayPtr, widthPtr);
      return ReverbParamsEx(
        enabled: enabledPtr.value != 0,
        mix: mixPtr.value,
        roomSize: roomPtr.value,
        damping: dampPtr.value,
        preDelayMs: predelayPtr.value,
        width: widthPtr.value,
      );
    } finally {
      calloc
        ..free(enabledPtr)
        ..free(mixPtr)
        ..free(roomPtr)
        ..free(dampPtr)
        ..free(predelayPtr)
        ..free(widthPtr);
    }
  }

  /// Independent wet/dry output gains for the reverb (0.0 – 2.0 each,
  /// >1.0 boosts). Overrides the crossfade mix.
  void setReverbGains({required double wet, required double dry}) {
    if (_engine == ffi.nullptr) return;
    _setReverbGains(_engine, wet, dry);
  }

  ({double wet, double dry}) getReverbGains() {
    if (_engine == ffi.nullptr) {
      return (wet: 0.0, dry: 1.0);
    }
    final wetPtr = calloc<ffi.Float>();
    final dryPtr = calloc<ffi.Float>();
    try {
      _getReverbGains(_engine, wetPtr, dryPtr);
      return (wet: wetPtr.value, dry: dryPtr.value);
    } finally {
      calloc
        ..free(wetPtr)
        ..free(dryPtr);
    }
  }

  void setEqEnabled(bool enabled) {
    if (_engine == ffi.nullptr) return;
    _setEqEnabled(_engine, enabled ? 1 : 0);
  }

  /// Sets 3-band EQ gains using raw linear multipliers [0.0 – 4.0].
  /// Consider using [setEqGainsDb] instead for consistent dB-based control.
  void setEqGains({
    required double low,
    required double mid,
    required double high,
  }) {
    if (_engine == ffi.nullptr) return;
    _setEqGains(_engine, low, mid, high);
  }

  /// Sets 3-band EQ gains using dB values (e.g. -12.0 to +12.0 dB).
  /// 0.0 dB corresponds to unity gain (1.0).
  void setEqGainsDb({
    required double lowDb,
    required double midDb,
    required double highDb,
  }) {
    setEqGains(
      low: _dbToLinear(lowDb),
      mid: _dbToLinear(midDb),
      high: _dbToLinear(highDb),
    );
  }

  /// Sets master output gain as a raw linear scalar multiplier [0.0 – 8.0].
  void setGain(double gain) {
    _masterGain = gain;
    if (_engine == ffi.nullptr) return;
    _setGain(_engine, gain);
  }

  /// Returns the current master gain as a linear scalar multiplier.
  double getGain() => _masterGain;

  /// Sets master volume in dB (e.g. 0.0 dB for full volume, -6.0 dB for ~50%, -60.0 dB for silence).
  void setVolumeDb(double volumeDb) {
    setGain(_dbToLinear(volumeDb));
  }

  /// Returns the current master volume in dB.
  double getVolumeDb() {
    return _linearToDb(_masterGain);
  }

  void setReplayGain(double gainDb) {
    if (_engine == ffi.nullptr) return;
    _setReplayGain?.call(_engine, gainDb);
  }

  void setPan(double panMinus1ToPlus1) {
    if (_engine == ffi.nullptr) return;
    _setPan(_engine, panMinus1ToPlus1);
  }

  void setRate(double rate) {
    if (_engine == ffi.nullptr) return;
    _setRate(_engine, rate);
  }

  double getRate() {
    if (_engine == ffi.nullptr) return 1.0;
    return _getRate?.call(_engine) ?? 1.0;
  }

  void setPitch(double pitchMultiplier) {
    if (_engine == ffi.nullptr) return;
    _setPitch(_engine, pitchMultiplier);
  }

  double getPitch() {
    if (_engine == ffi.nullptr) return 1.0;
    return _getPitch?.call(_engine) ?? 1.0;
  }

  void setPitchCorrection(bool enabled) {
    if (_engine == ffi.nullptr) return;
    _setPitchCorrection(_engine, enabled ? 1 : 0);
  }

  bool getPitchCorrection() {
    if (_engine == ffi.nullptr) return true;
    return (_getPitchCorrection?.call(_engine) ?? 1) != 0;
  }

  void setLowpassEnabled(bool enabled) {
    if (_engine == ffi.nullptr) return;
    _setLowpassEnabled(_engine, enabled ? 1 : 0);
  }

  void setLowpassCutoff(double hz) {
    if (_engine == ffi.nullptr) return;
    _setLowpassCutoff(_engine, hz);
  }

  void setHighpassEnabled(bool enabled) {
    if (_engine == ffi.nullptr) return;
    _setHighpassEnabled(_engine, enabled ? 1 : 0);
  }

  void setHighpassCutoff(double hz) {
    if (_engine == ffi.nullptr) return;
    _setHighpassCutoff(_engine, hz);
  }

  void setDelayEnabled(bool enabled) {
    if (_engine == ffi.nullptr) return;
    _setDelayEnabled(_engine, enabled ? 1 : 0);
  }

  void setDelayParams({
    required double mix,
    required double feedback,
    required double delayMs,
  }) {
    if (_engine == ffi.nullptr) return;
    _setDelayParams(_engine, mix, feedback, delayMs);
  }

  void setStereoWiden({
    required bool enabled,
    required double width,
    required double delayMs,
  }) {
    if (_engine == ffi.nullptr) return;
    _setStereoWiden(_engine, enabled ? 1 : 0, width, delayMs);
  }

  void setStereoEnhancementEnabled(bool enabled) {
    if (_engine == ffi.nullptr) return;
    _setStereoEnhancementEnabled(_engine, enabled ? 1 : 0);
  }

  bool getStereoEnhancementEnabled() {
    if (_engine == ffi.nullptr) return false;
    return _getStereoEnhancementEnabled(_engine) != 0;
  }

  void setStereoEnhancementMix(double mix) {
    if (_engine == ffi.nullptr) return;
    _setStereoEnhancementMix(_engine, mix);
  }

  double getStereoEnhancementMix() {
    if (_engine == ffi.nullptr) return 0.5;
    return _getStereoEnhancementMix(_engine);
  }

  void setCrossfeedEnabled(bool enabled) {
    if (_engine == ffi.nullptr) return;
    _setCrossfeedEnabled(_engine, enabled ? 1 : 0);
  }

  void setCrossfeedPreset(int preset) {
    if (_engine == ffi.nullptr) return;
    _setCrossfeedPreset(_engine, preset);
  }

  void setCrossfeedAlgorithm(CrossfeedAlgorithm algorithm) {
    if (_engine == ffi.nullptr) return;
    _setCrossfeedAlgorithm(_engine, algorithm.index);
  }

  void setCrossfeedParams({
    required double mix,
    required double delayMs,
    required double cutoffHz,
    bool outputCompensation = true,
  }) {
    if (_engine == ffi.nullptr) return;
    _setCrossfeedParams(
      _engine,
      mix,
      delayMs,
      cutoffHz,
      outputCompensation ? 1 : 0,
    );
  }

  CrossfeedParams getCrossfeedParams() {
    if (_engine == ffi.nullptr) {
      return const CrossfeedParams(
        algorithm: CrossfeedAlgorithm.off,
        mix: 0.5,
        delayMs: 0.4,
        cutoffHz: 700.0,
        outputCompensation: true,
      );
    }
    final algoPtr = calloc<ffi.Int32>();
    final mixPtr = calloc<ffi.Float>();
    final delayPtr = calloc<ffi.Float>();
    final cutoffPtr = calloc<ffi.Float>();
    final compPtr = calloc<ffi.Int32>();
    try {
      _getCrossfeedParams(
          _engine, algoPtr, mixPtr, delayPtr, cutoffPtr, compPtr);
      final algoIdx =
          algoPtr.value.clamp(0, CrossfeedAlgorithm.values.length - 1);
      return CrossfeedParams(
        algorithm: CrossfeedAlgorithm.values[algoIdx],
        mix: mixPtr.value,
        delayMs: delayPtr.value,
        cutoffHz: cutoffPtr.value,
        outputCompensation: compPtr.value != 0,
      );
    } finally {
      calloc.free(algoPtr);
      calloc.free(mixPtr);
      calloc.free(delayPtr);
      calloc.free(cutoffPtr);
      calloc.free(compPtr);
    }
  }

  void setRaceParams({
    double delayMs = 0.166,
    double alpha = 0.55,
    double lpfHz = 2500.0,
  }) {
    if (_engine == ffi.nullptr) return;
    _setRaceParams(_engine, delayMs, alpha, lpfHz);
  }

  void setDynamicBassEnabled(bool enabled) {
    if (_engine == ffi.nullptr) return;
    _setDynamicBassEnabled(_engine, enabled ? 1 : 0);
  }

  void setDynamicBassParams({
    required int preset,
    required double gain,
  }) {
    if (_engine == ffi.nullptr) return;
    _setDynamicBassParams(_engine, preset, gain);
  }

  void setBandpassEnabled(bool enabled) {
    if (_engine == ffi.nullptr) return;
    _setBandpassEnabled(_engine, enabled ? 1 : 0);
  }

  void setBandpassParams({
    required double cutoffHz,
    required double q,
  }) {
    if (_engine == ffi.nullptr) return;
    _setBandpassParams(_engine, cutoffHz, q);
  }

  void setPeakEqEnabled(bool enabled) {
    if (_engine == ffi.nullptr) return;
    _setPeakEqEnabled(_engine, enabled ? 1 : 0);
  }

  void setPeakEqParams({
    required double gainDb,
    required double q,
    required double frequencyHz,
  }) {
    if (_engine == ffi.nullptr) return;
    _setPeakEqParams(_engine, gainDb, q, frequencyHz);
  }

  void setNotchEnabled(bool enabled) {
    if (_engine == ffi.nullptr) return;
    _setNotchEnabled(_engine, enabled ? 1 : 0);
  }

  void setNotchParams({
    required double q,
    required double frequencyHz,
  }) {
    if (_engine == ffi.nullptr) return;
    _setNotchParams(_engine, q, frequencyHz);
  }

  void setLowshelfEnabled(bool enabled) {
    if (_engine == ffi.nullptr) return;
    _setLowshelfEnabled(_engine, enabled ? 1 : 0);
  }

  void setLowshelfParams({
    required double gainDb,
    required double slope,
    required double frequencyHz,
  }) {
    if (_engine == ffi.nullptr) return;
    _setLowshelfParams(_engine, gainDb, slope, frequencyHz);
  }

  void setHighshelfEnabled(bool enabled) {
    if (_engine == ffi.nullptr) return;
    _setHighshelfEnabled(_engine, enabled ? 1 : 0);
  }

  void setHighshelfParams({
    required double gainDb,
    required double slope,
    required double frequencyHz,
  }) {
    if (_engine == ffi.nullptr) return;
    _setHighshelfParams(_engine, gainDb, slope, frequencyHz);
  }

  // Custom Filters

  void setCustomLpf1Params({required bool enabled, required double cutoffHz}) {
    if (_engine == ffi.nullptr) return;
    _setCustomLpf1Params(_engine, enabled ? 1 : 0, cutoffHz);
  }

  void setCustomHpf1Params({required bool enabled, required double cutoffHz}) {
    if (_engine == ffi.nullptr) return;
    _setCustomHpf1Params(_engine, enabled ? 1 : 0, cutoffHz);
  }

  void setCustomBiquadParams({
    required bool enabled,
    required double b0,
    required double b1,
    required double b2,
    required double a0,
    required double a1,
    required double a2,
  }) {
    if (_engine == ffi.nullptr) return;
    _setCustomBiquadParams(_engine, enabled ? 1 : 0, b0, b1, b2, a0, a1, a2);
  }

  // Spatialization

  void setSpatializationEnabled(bool enabled) {
    if (_engine == ffi.nullptr) return;
    _setSpatializationEnabled(_engine, enabled ? 1 : 0);
  }

  void setPosition({required double x, required double y, required double z}) {
    if (_engine == ffi.nullptr) return;
    _setPosition(_engine, x, y, z);
  }

  void setDirection({required double x, required double y, required double z}) {
    if (_engine == ffi.nullptr) return;
    _setDirection(_engine, x, y, z);
  }

  void setVelocity({required double x, required double y, required double z}) {
    if (_engine == ffi.nullptr) return;
    _setVelocity(_engine, x, y, z);
  }

  void setSoundCone({
    required double innerAngleRad,
    required double outerAngleRad,
    required double outerGain,
  }) {
    if (_engine == ffi.nullptr) return;
    _setSoundCone(_engine, innerAngleRad, outerAngleRad, outerGain);
  }

  /// 0 = None, 1 = Inverse, 2 = Linear, 3 = Exponential
  void setAttenuationModel(int model) {
    if (_engine == ffi.nullptr) return;
    _setAttenuationModel(_engine, model);
  }

  void setAttenuationModelEnum(AttenuationModel model) {
    setAttenuationModel(model.index);
  }

  void setRolloff(double rolloff) {
    if (_engine == ffi.nullptr) return;
    _setRolloff(_engine, rolloff);
  }

  void setMinGain(double minGain) {
    if (_engine == ffi.nullptr) return;
    _setMinGain(_engine, minGain);
  }

  void setMaxGain(double maxGain) {
    if (_engine == ffi.nullptr) return;
    _setMaxGain(_engine, maxGain);
  }

  void setMinDistance(double minDistance) {
    if (_engine == ffi.nullptr) return;
    _setMinDistance(_engine, minDistance);
  }

  void setMaxDistance(double maxDistance) {
    if (_engine == ffi.nullptr) return;
    _setMaxDistance(_engine, maxDistance);
  }

  void setDopplerFactor(double dopplerFactor) {
    if (_engine == ffi.nullptr) return;
    _setDopplerFactor(_engine, dopplerFactor);
  }

  // Listener 3D Spatialization

  void setListenerPosition({
    required double x,
    required double y,
    required double z,
  }) {
    if (_engine == ffi.nullptr) return;
    _setListenerPosition(_engine, x, y, z);
  }

  void setListenerDirection({
    required double x,
    required double y,
    required double z,
  }) {
    if (_engine == ffi.nullptr) return;
    _setListenerDirection(_engine, x, y, z);
  }

  void setListenerVelocity({
    required double x,
    required double y,
    required double z,
  }) {
    if (_engine == ffi.nullptr) return;
    _setListenerVelocity(_engine, x, y, z);
  }

  void setListenerWorldUp({
    required double x,
    required double y,
    required double z,
  }) {
    if (_engine == ffi.nullptr) return;
    _setListenerWorldUp(_engine, x, y, z);
  }

  void setListenerCone({
    required double innerAngleRad,
    required double outerAngleRad,
    required double outerGain,
  }) {
    if (_engine == ffi.nullptr) return;
    _setListenerCone(_engine, innerAngleRad, outerAngleRad, outerGain);
  }

  // Fading & Scheduling

  void setFade(double startVol, double endVol, int durationMs) {
    if (_engine == ffi.nullptr) return;
    _setFadeInMilliseconds(_engine, startVol, endVol, durationMs);
  }

  void scheduleStartTimeInPcmFrames(int absoluteTime) {
    if (_engine == ffi.nullptr) return;
    _setStartTimeInPcmFrames(_engine, absoluteTime);
  }

  void scheduleStopTimeInPcmFrames(int absoluteTime) {
    if (_engine == ffi.nullptr) return;
    _setStopTimeInPcmFrames(_engine, absoluteTime);
  }

  int getEngineTimeInPcmFrames() {
    if (_engine == ffi.nullptr) return 0;
    return _getEngineTimeInPcmFrames(_engine);
  }

  void setEndCallback(
      ffi.Pointer<ffi.NativeFunction<EndCallbackNative>> callback,
      ffi.Pointer<ffi.Void> userData) {
    if (_engine == ffi.nullptr) return;
    _setEndCallback(_engine, callback, userData);
  }

  // Advanced Audio Features Helpers

  void setExclusiveMode(bool enabled) {
    if (_engine == ffi.nullptr) return;
    _setExclusiveMode(_engine, enabled ? 1 : 0);
  }

  bool getExclusiveMode() {
    if (_engine == ffi.nullptr) return false;
    return _getExclusiveMode(_engine) != 0;
  }

  /// Sets the preferred audio output backend. Returns true if accepted.
  bool setOutputBackend(AudioOutputBackend backend) {
    if (_engine == ffi.nullptr) return false;
    return _setOutputBackend(_engine, backend.value) != 0;
  }

  /// Gets the currently active audio output backend.
  AudioOutputBackend getOutputBackend() {
    if (_engine == ffi.nullptr) return AudioOutputBackend.auto;
    final val = _getOutputBackend(_engine);
    return AudioOutputBackend.fromInt(val);
  }

  /// Checks if a specific backend is supported on the current platform/device.
  bool isBackendSupported(AudioOutputBackend backend) {
    if (_engine == ffi.nullptr) return false;
    return _isBackendSupported(_engine, backend.value) != 0;
  }

  void setOutputFormat(AudioFormat format) {
    if (_engine == ffi.nullptr) return;
    _setOutputFormat(_engine, format.index);
  }

  AudioFormat getOutputFormat() {
    if (_engine == ffi.nullptr) return AudioFormat.f32;
    final index = _getOutputFormat(_engine);
    return AudioFormat.values[index.clamp(0, AudioFormat.values.length - 1)];
  }

  void setOutputSampleRate(int rate) {
    if (_engine == ffi.nullptr) return;
    _setOutputSampleRate(_engine, rate);
  }

  int getOutputSampleRate() {
    if (_engine == ffi.nullptr) return 0;
    return _getOutputSampleRate(_engine);
  }

  void setOutputChannels(int channels) {
    if (_engine == ffi.nullptr) return;
    _setOutputChannels(_engine, channels);
  }

  int getOutputChannels() {
    if (_engine == ffi.nullptr) return 0;
    return _getOutputChannels(_engine);
  }

  /// Set custom fixed output buffer size (period frames) and period count.
  /// Set [periodFrames] to 0 or [periodCount] to 0 to auto-select defaults.
  void setOutputBuffer({int periodFrames = 0, int periodCount = 0}) {
    if (_engine == ffi.nullptr) return;
    _setOutputBuffer?.call(_engine, periodFrames, periodCount);
  }

  /// Get configured fixed output buffer parameters (periodFrames, periodCount).
  ({int periodFrames, int periodCount}) getOutputBuffer() {
    if (_engine == ffi.nullptr || _getOutputBuffer == null) {
      return (periodFrames: 0, periodCount: 0);
    }
    final pF = _malloc(ffi.sizeOf<ffi.Int32>()).cast<ffi.Int32>();
    final pC = _malloc(ffi.sizeOf<ffi.Int32>()).cast<ffi.Int32>();
    try {
      _getOutputBuffer!(_engine, pF, pC);
      return (periodFrames: pF.value, periodCount: pC.value);
    } finally {
      _free(pF.cast());
      _free(pC.cast());
    }
  }

  void setPhaseInversion(
      {required bool invertLeft, required bool invertRight}) {
    if (_engine == ffi.nullptr) return;
    _setPhaseInversion?.call(_engine, invertLeft ? 1 : 0, invertRight ? 1 : 0);
  }

  ({bool left, bool right}) getPhaseInversion() {
    if (_engine == ffi.nullptr || _getPhaseInversion == null) {
      return (left: false, right: false);
    }
    final pL = _malloc(ffi.sizeOf<ffi.Int32>()).cast<ffi.Int32>();
    final pR = _malloc(ffi.sizeOf<ffi.Int32>()).cast<ffi.Int32>();
    try {
      _getPhaseInversion(_engine, pL, pR);
      return (left: pL.value != 0, right: pR.value != 0);
    } finally {
      _freePtr(pL.cast<ffi.Void>());
      _freePtr(pR.cast<ffi.Void>());
    }
  }

  // ── L/R Swap ────────────────────────────────────────────────────────────────

  /// Swaps left and right output channels. Applied after polarity inversion.
  void setLrSwap(bool enabled) {
    if (_engine == ffi.nullptr) return;
    _setLrSwap?.call(_engine, enabled ? 1 : 0);
  }

  bool getLrSwap() {
    if (_engine == ffi.nullptr || _getLrSwap == null) return false;
    return _getLrSwap(_engine) != 0;
  }

  // ── Per-Channel Gain ─────────────────────────────────────────────────────────

  /// Sets independent gain for left and right channels.
  /// [leftLinear] and [rightLinear] are linear multipliers [0.0, 4.0].
  /// Use [dbToLinear] to convert from dB if needed.
  void setChannelGains(
      {required double leftLinear, required double rightLinear}) {
    if (_engine == ffi.nullptr) return;
    _setChannelGains?.call(_engine, leftLinear, rightLinear);
  }

  /// Sets per-channel gain using dB values. Convenience wrapper.
  /// [leftDb] and [rightDb] are in dB; 0.0 = unity, +12.0 = max.
  void setChannelGainsDb({required double leftDb, required double rightDb}) {
    setChannelGains(
      leftLinear: _dbToLinear(leftDb),
      rightLinear: _dbToLinear(rightDb),
    );
  }

  /// Returns the current per-channel gains as linear multipliers {left, right}.
  ({double left, double right}) getChannelGains() {
    if (_engine == ffi.nullptr || _getChannelGains == null) {
      return (left: 1.0, right: 1.0);
    }
    final pL = _malloc(ffi.sizeOf<ffi.Float>()).cast<ffi.Float>();
    final pR = _malloc(ffi.sizeOf<ffi.Float>()).cast<ffi.Float>();
    try {
      _getChannelGains(_engine, pL, pR);
      return (left: pL.value.toDouble(), right: pR.value.toDouble());
    } finally {
      _freePtr(pL.cast<ffi.Void>());
      _freePtr(pR.cast<ffi.Void>());
    }
  }

  /// Returns the current per-channel gains in dB {left, right}.
  ({double left, double right}) getChannelGainsDb() {
    final g = getChannelGains();
    return (left: _linearToDb(g.left), right: _linearToDb(g.right));
  }

  // Converts dB to linear gain. 0 dB => 1.0, -80 dB => ~0.0.
  static double _dbToLinear(double db) {
    if (db <= -80.0) return 0.0;
    return math.pow(10.0, db / 20.0).toDouble();
  }

  // Converts linear gain to dB. 1.0 => 0 dB, 0.0 => -80 dB floor.
  static double _linearToDb(double linear) {
    if (linear <= 0.0) return -80.0;
    return 20.0 * (math.log(linear) / math.ln10);
  }

  void setEngineResampleAlgorithm(int algorithm) {
    if (_engine == ffi.nullptr) return;
    _setEngineResampleAlgorithm(_engine, algorithm);
  }

  int getEngineResampleAlgorithm() {
    if (_engine == ffi.nullptr) return 0;
    return _getEngineResampleAlgorithm(_engine);
  }

  void setEngineDitherMode(int ditherMode) {
    if (_engine == ffi.nullptr) return;
    _setEngineDitherMode(_engine, ditherMode);
  }

  int getEngineDitherMode() {
    if (_engine == ffi.nullptr) return 0;
    return _getEngineDitherMode(_engine);
  }

  /// Enable or disable 64-bit float DSP processing mode (-320dB mathematical headroom).
  void set64BitProcessingEnabled(bool enabled) {
    if (_engine == ffi.nullptr || _set64BitProcessingEnabled == null) return;
    _set64BitProcessingEnabled(_engine, enabled ? 1 : 0);
  }

  /// Check whether 64-bit float DSP processing mode is active.
  bool get64BitProcessingEnabled() {
    if (_engine == ffi.nullptr || _get64BitProcessingEnabled == null) {
      return false;
    }
    return _get64BitProcessingEnabled(_engine) != 0;
  }

  /// Enable or disable Auto Sample-Rate Match hardware sample-rate matching.
  void setAutoSampleRateMatchEnabled(bool enabled) {
    if (_engine == ffi.nullptr || _setAutoSampleRateMatchEnabled == null) {
      return;
    }
    _setAutoSampleRateMatchEnabled(_engine, enabled ? 1 : 0);
  }

  /// Check whether Auto Sample-Rate Match hardware sample-rate matching is enabled.
  bool getAutoSampleRateMatchEnabled() {
    if (_engine == ffi.nullptr || _getAutoSampleRateMatchEnabled == null) {
      return false;
    }
    return _getAutoSampleRateMatchEnabled(_engine) != 0;
  }

  /// Deprecated alias for [setAutoSampleRateMatchEnabled].
  void setAutoBitPerfectEnabled(bool enabled) =>
      setAutoSampleRateMatchEnabled(enabled);

  /// Deprecated alias for [getAutoSampleRateMatchEnabled].
  bool getAutoBitPerfectEnabled() => getAutoSampleRateMatchEnabled();

  /// Poll for a deferred Auto Bit-Perfect sample-rate change requested by the
  /// native worker thread. Returns the new sample rate (> 0) if a change is
  /// pending, or 0 if nothing to do. Call this from your status-poll loop;
  /// when non-zero, apply it via [setOutputSampleRate].
  int consumePendingRateChange() {
    if (_engine == ffi.nullptr || _consumePendingRateChange == null) return 0;
    return _consumePendingRateChange!(_engine);
  }

  // ── Limiter & Clipping Detection ──────────────────────────────────────────

  /// Enable or disable the soft limiter in the audio chain.
  void setLimiterEnabled(bool enabled) {
    if (_engine == ffi.nullptr) return;
    _setLimiterEnabled(_engine, enabled ? 1 : 0);
  }

  /// Configure the limiter parameters.
  ///
  /// [threshold] – linear amplitude threshold (0.1 – 1.0, default 0.95).
  /// [attackMs]  – attack time in milliseconds (0.1 – 100 ms, default 2 ms).
  /// [releaseMs] – release time in milliseconds (10 – 1000 ms, default 50 ms).
  void setLimiterParams({
    double threshold = 0.95,
    double attackMs = 2.0,
    double releaseMs = 50.0,
  }) {
    if (_engine == ffi.nullptr) return;
    _setLimiterParams(_engine, threshold, attackMs, releaseMs);
  }

  // ── Dynamic Range Compressor ──────────────────────────────────────────────

  /// Enable or disable the compressor in the audio chain.
  void setCompressorEnabled(bool enabled) {
    if (_engine == ffi.nullptr) return;
    _setCompressorEnabled(_engine, enabled ? 1 : 0);
  }

  /// Configure the compressor parameters.
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
  }) {
    if (_engine == ffi.nullptr) return;
    _setCompressorParams(_engine, thresholdDb, ratio, kneeDb, attackMs,
        releaseMs, makeupGainDb, detector, stereoLink ? 1 : 0,
        autoMakeup ? 1 : 0, mix);
  }

  /// Current gain reduction applied by the compressor in dB.
  double getCompressorGainReductionDB() {
    if (_engine == ffi.nullptr) return 0.0;
    return _getCompressorGainReductionDb(_engine);
  }

  /// Enable or disable clipping detection.
  /// When enabled, samples exceeding ±1.0 are counted by the engine.
  void setClippingDetectionEnabled(bool enabled) {
    if (_engine == ffi.nullptr) return;
    _setClippingDetectionEnabled(_engine, enabled ? 1 : 0);
  }

  /// Returns the total number of clipped samples since the last reset.
  int getClippedSamplesCount() {
    if (_engine == ffi.nullptr) return 0;
    return _getClippedSamplesCount(_engine);
  }

  /// Resets the clipped-sample counter back to zero.
  void resetClippedSamplesCount() {
    if (_engine == ffi.nullptr) return;
    _resetClippedSamplesCount(_engine);
  }

  // ── Release 1 Quality Foundation API ────────────────────────────────────────

  /// Fetch live ITU-R BS.1770-4 / EBU R128 loudness metrics.
  AELoudnessMetrics getLoudnessMetrics() {
    if (_getLoudnessMetrics == null || _engine == ffi.nullptr) {
      return const AELoudnessMetrics(
        momentaryLUFS: -100.0,
        shortTermLUFS: -100.0,
        integratedLUFS: -100.0,
        loudnessRangeLRA: 0.0,
      );
    }
    final native = _getLoudnessMetrics!(_engine);
    return AELoudnessMetrics.fromNative(native);
  }

  /// Reset accumulated loudness measurements.
  void resetLoudnessMeter() {
    if (_resetLoudnessMeter != null && _engine != ffi.nullptr) {
      _resetLoudnessMeter!(_engine);
    }
  }

  /// Enable or disable live ITU/EBU loudness normalizer.
  void setLoudnessNormalizerEnabled(bool enabled) {
    if (_setLoudnessNormalizerEnabled != null && _engine != ffi.nullptr) {
      _setLoudnessNormalizerEnabled!(_engine, enabled ? 1 : 0);
    }
  }

  /// Set the loudness normalizer target in LUFS (e.g. -14.0 LUFS).
  void setLoudnessNormalizerTarget(double targetLUFS) {
    if (_setLoudnessNormalizerTarget != null && _engine != ffi.nullptr) {
      _setLoudnessNormalizerTarget!(_engine, targetLUFS);
    }
  }

  /// Returns true if the live loudness normalizer is currently enabled.
  bool getLoudnessNormalizerEnabled() {
    if (_getLoudnessNormalizerEnabled == null || _engine == ffi.nullptr) {
      return false;
    }
    return _getLoudnessNormalizerEnabled!(_engine) != 0;
  }

  /// Returns the loudness normalizer target in LUFS (default -14.0).
  double getLoudnessNormalizerTarget() {
    if (_getLoudnessNormalizerTarget == null || _engine == ffi.nullptr) {
      return -14.0;
    }
    return _getLoudnessNormalizerTarget!(_engine);
  }

  /// Returns the currently applied normalizer gain in dB
  /// (0 when disabled or bypassed during crossfades).
  double getLoudnessNormalizerGainDb() {
    if (_getLoudnessNormalizerGainDb == null || _engine == ffi.nullptr) {
      return 0.0;
    }
    return _getLoudnessNormalizerGainDb!(_engine);
  }

  /// Fetch 4x oversampled True-Peak metrics in dBTP.
  AETruePeakMetrics getTruePeak() {
    if (_getTruePeak == null || _engine == ffi.nullptr) {
      return const AETruePeakMetrics(
        leftDBTP: -100.0,
        rightDBTP: -100.0,
        maxDBTP: -100.0,
      );
    }
    final native = _getTruePeak!(_engine);
    return AETruePeakMetrics.fromNative(native);
  }

  bool _lookaheadLimiterEnabled = false;

  /// Returns whether the lookahead limiter is currently enabled.
  bool get isLookaheadLimiterEnabled => _lookaheadLimiterEnabled;

  /// Enable or disable the Look-Ahead True-Peak Limiter.
  void setLookaheadLimiterEnabled(bool enabled) {
    _lookaheadLimiterEnabled = enabled;
    if (_setLookaheadLimiterEnabled != null && _engine != ffi.nullptr) {
      _setLookaheadLimiterEnabled!(_engine, enabled ? 1 : 0);
    }
  }

  /// Configure Look-Ahead Limiter parameters.
  /// [ceilingDBTP] – maximum peak output in dBTP (default -1.0 dBTP).
  /// [attackMs] – look-ahead window time in ms (default 2.0 ms).
  /// [releaseMs] – release recovery time in ms (default 50.0 ms).
  void setLookaheadLimiterParams({
    double ceilingDBTP = -1.0,
    double attackMs = 2.0,
    double releaseMs = 50.0,
  }) {
    if (_setLookaheadLimiterParams != null && _engine != ffi.nullptr) {
      _setLookaheadLimiterParams!(_engine, ceilingDBTP, attackMs, releaseMs);
    }
  }

  /// Get current gain reduction in dB applied by the Look-Ahead Limiter.
  double getLookaheadLimiterGainReductionDB() {
    if (_getLookaheadLimiterGainReductionDb != null && _engine != ffi.nullptr) {
      return _getLookaheadLimiterGainReductionDb!(_engine);
    }
    return 0.0;
  }

  /// Fetch unified quality telemetry snapshot (True Peak, LUFS, LRA, Crest Factor, Limiter GR, Latencies).
  AEQualityTelemetry getQualityTelemetry() {
    if (_getQualityTelemetry == null || _engine == ffi.nullptr) {
      return const AEQualityTelemetry(
        samplePeakDB: -100.0,
        truePeakDBTP: -100.0,
        momentaryLUFS: -100.0,
        shortTermLUFS: -100.0,
        integratedLUFS: -100.0,
        loudnessRangeLRA: 0.0,
        crestFactorDB: 0.0,
        limiterGainReductionDB: 0.0,
        resamplerLatencyMs: 0.0,
        totalEngineLatencyMs: 0.0,
        clippedSamplesCount: 0,
        underrunCount: 0,
      );
    }
    final native = _getQualityTelemetry!(_engine);
    return AEQualityTelemetry.fromNative(native);
  }

  void initMultibandEq(
    int bands,
    List<double> frequencies, {
    List<double>? qFactors,
  }) {
    if (_engine == ffi.nullptr) return;
    if (frequencies.length != bands) return;
    if (qFactors != null && qFactors.length != bands) return;

    final freqPtr = _malloc(bands * ffi.sizeOf<ffi.Float>()).cast<ffi.Float>();
    final freqList = freqPtr.asTypedList(bands);
    freqList.setAll(0, frequencies);

    ffi.Pointer<ffi.Float> qPtr = ffi.nullptr;
    if (qFactors != null) {
      qPtr = _malloc(bands * ffi.sizeOf<ffi.Float>()).cast<ffi.Float>();
      final qList = qPtr.asTypedList(bands);
      qList.setAll(0, qFactors);
    }

    try {
      _initMultibandEq(_engine, bands, freqPtr, qPtr);
    } finally {
      _freePtr(freqPtr.cast<ffi.Void>());
      if (qPtr != ffi.nullptr) {
        _freePtr(qPtr.cast<ffi.Void>());
      }
    }
  }

  void setMultibandEqEnabled(bool enabled) {
    if (_engine == ffi.nullptr) return;
    _setMultibandEqEnabled(_engine, enabled ? 1 : 0);
  }

  void setMultibandEqGain(int bandIndex, double gain) {
    if (_engine == ffi.nullptr) return;
    _setMultibandEqGain(_engine, bandIndex, gain);
  }

  double getMultibandEqGain(int bandIndex) {
    if (_engine == ffi.nullptr) return 0.0;
    return _getMultibandEqGain(_engine, bandIndex);
  }

  void setMultibandFxEnabled(bool enabled) {
    if (_engine == ffi.nullptr) return;
    _setMultibandFxEnabled(_engine, enabled ? 1 : 0);
  }

  void clearMultibandFx() {
    if (_engine == ffi.nullptr) return;
    _clearMultibandFx(_engine);
  }

  void setMultibandFxBands(List<EqBandConfig> bands) {
    if (_engine == ffi.nullptr) return;
    if (bands.isEmpty) {
      clearMultibandFx();
      return;
    }

    final count = bands.length;
    final typesPtr = _malloc(count * ffi.sizeOf<ffi.Int32>()).cast<ffi.Int32>();
    final frequencyPtr =
        _malloc(count * ffi.sizeOf<ffi.Float>()).cast<ffi.Float>();
    final qPtr = _malloc(count * ffi.sizeOf<ffi.Float>()).cast<ffi.Float>();
    final gainPtr = _malloc(count * ffi.sizeOf<ffi.Float>()).cast<ffi.Float>();
    final slopePtr = _malloc(count * ffi.sizeOf<ffi.Float>()).cast<ffi.Float>();
    final enabledPtr =
        _malloc(count * ffi.sizeOf<ffi.Int32>()).cast<ffi.Int32>();

    try {
      final types = typesPtr.asTypedList(count);
      final freqs = frequencyPtr.asTypedList(count);
      final qs = qPtr.asTypedList(count);
      final gains = gainPtr.asTypedList(count);
      final slopes = slopePtr.asTypedList(count);
      final enabledFlags = enabledPtr.asTypedList(count);

      for (var i = 0; i < count; i++) {
        final band = bands[i];
        types[i] = band.type.index;
        freqs[i] = band.frequencyHz;
        qs[i] = band.q;
        gains[i] = band.gainDb;
        slopes[i] = band.slope;
        enabledFlags[i] = band.enabled ? 1 : 0;
      }

      _setMultibandFxBands(
        _engine,
        count,
        typesPtr,
        frequencyPtr,
        qPtr,
        gainPtr,
        slopePtr,
        enabledPtr,
      );
    } finally {
      _freePtr(typesPtr.cast<ffi.Void>());
      _freePtr(frequencyPtr.cast<ffi.Void>());
      _freePtr(qPtr.cast<ffi.Void>());
      _freePtr(gainPtr.cast<ffi.Void>());
      _freePtr(slopePtr.cast<ffi.Void>());
      _freePtr(enabledPtr.cast<ffi.Void>());
    }
  }

  // Push Stream API
  void initPushStream() {
    if (_engine == ffi.nullptr) return;
    _initPushStream(_engine);
  }

  void pushStreamChunk(ffi.Pointer<ffi.Uint8> data, int size) {
    if (_engine == ffi.nullptr) return;
    _pushStreamChunk(_engine, data, size);
  }

  void endPushStream() {
    if (_engine == ffi.nullptr) return;
    _endPushStream(_engine);
  }

  int getPushStreamBufferedBytes() {
    if (_engine == ffi.nullptr) return 0;
    return _getPushStreamBufferedBytes(_engine);
  }

  void setAnalyzerEnabled(bool enabled) {
    if (_engine == ffi.nullptr) return;
    _setAnalyzerEnabled(_engine, enabled ? 1 : 0);
  }

  void configureAnalyzer(int frameSize) {
    if (_engine == ffi.nullptr) return;
    _configureAnalyzer(_engine, frameSize);
  }

  int getAnalyzerFrameSize() {
    if (_engine == ffi.nullptr) return 0;
    return _getAnalyzerFrameSize(_engine);
  }

  int getAnalyzerDroppedFrames() {
    if (_engine == ffi.nullptr) return 0;
    return _getAnalyzerDroppedFrames(_engine);
  }

  Float32List pollAnalyzerFrame({int? maxSamples, Float32List? targetBuffer}) {
    if (_engine == ffi.nullptr) {
      return targetBuffer ?? Float32List(0);
    }

    final size = maxSamples ?? getAnalyzerFrameSize();
    if (size <= 0) {
      return targetBuffer ?? Float32List(0);
    }

    if (_analyzerBufferPtr == null || _analyzerBufferCapacity < size) {
      if (_analyzerBufferPtr != null && _analyzerBufferPtr != ffi.nullptr) {
        _freePtr(_analyzerBufferPtr!.cast<ffi.Void>());
      }
      _analyzerBufferCapacity = size < 4096 ? 4096 : size;
      _analyzerBufferPtr =
          _malloc(_analyzerBufferCapacity * ffi.sizeOf<ffi.Float>())
              .cast<ffi.Float>();
    }

    final ptr = _analyzerBufferPtr!;
    final copied = _pollAnalyzerFrame(_engine, ptr, size);
    if (copied <= 0) {
      return targetBuffer ?? Float32List(0);
    }
    final src = ptr.asTypedList(copied);
    if (targetBuffer != null && targetBuffer.length >= copied) {
      targetBuffer.setRange(0, copied, src);
      return targetBuffer;
    }
    return src;
  }

  // ---------------------------------------------------------------------------
  // Crystalizer
  // ---------------------------------------------------------------------------

  /// Enable or disable the Crystalizer effect.
  ///
  /// The Crystalizer reconstructs transient detail lost in lossy compression
  /// (MP3/AAC) and optionally adds a gentle high-shelf "air" boost.
  void setCrystalizerEnabled(bool enabled) {
    if (_engine == ffi.nullptr) return;
    _setCrystalizerEnabled(_engine, enabled ? 1 : 0);
  }

  /// Configure the Crystalizer parameters.
  ///
  /// [intensity]          – transient reconstruction strength [0.0 – 1.0] (default 0.5).
  ///                        Higher values add more transient detail and "crispness".
  /// [highShelfEnabled]   – if `true`, a gentle 2nd-order high-shelf is applied
  ///                        above 8 kHz to restore "air" lost in compression.
  /// [highShelfGainDb]    – shelf boost in dB [0.0 – 6.0] (default 2.0).
  void setCrystalizerParams({
    double intensity = 0.5,
    bool highShelfEnabled = true,
    double highShelfGainDb = 2.0,
  }) {
    if (_engine == ffi.nullptr) return;
    _setCrystalizerParams(
      _engine,
      intensity,
      highShelfEnabled ? 1 : 0,
      highShelfGainDb,
    );
  }

  /// Returns the current Crystalizer intensity in [0.0 – 1.0].
  double getCrystalizerIntensity() {
    if (_engine == ffi.nullptr) return 0.0;
    return _getCrystalizerIntensity(_engine);
  }
}
