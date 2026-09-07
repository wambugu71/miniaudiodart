import 'dart:async';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:sautiflow/sautiflow.dart';

// ── Data Model ────────────────────────────────────────────────────────────────

/// Comprehensive snapshot of active output audio hardware specifications.
class AudioHardwareSpecs {
  final String backendName; // e.g. "WASAPI", "AAudio", "ALSA", "Core Audio"
  final String deviceName; // Friendly device name string
  final int sampleRate; // Hardware sample rate in Hz (e.g. 48000, 96000)
  final int bitDepth; // Hardware bit depth in bits (e.g. 16, 24, 32)
  final bool isFloat; // True if 32-bit Floating point PCM
  final int channels; // Channel count (1=Mono, 2=Stereo)
  final int periodSizeFrames; // Frame count per period
  final int periodCount; // Total periods
  final double latencyMs; // Hardware buffer latency in milliseconds
  final bool isExclusiveMode; // True if exclusive mode (Bit-Perfect)
  final String
      deviceType; // "Speakers", "3.5mm Headphone Jack", "Bluetooth", "USB DAC"
  final String? dspHardware; // e.g. "Qualcomm Hexagon v73 aDSP", "MediaTek Tensilica HiFi 5"
  final String? socName; // e.g. "Snapdragon 8 Gen 2", "Dimensity 9200"
  final bool isDirectPcm; // True if direct bit-perfect HAL output

  // ── Bluetooth-specific fields ─────────────────────────────────────────────
  final String? bluetoothCodec; // e.g. "LDAC", "aptX HD", "AAC", "SBC", "LC3"
  final String?
      bluetoothDeviceName; // Actual BT device name (e.g. "Sony WH-1000XM5")
  final int? btSampleRate; // BT codec negotiated sample rate
  final int? btBitDepth; // BT codec bit depth

  final List<int> supportedSampleRates;

  // ── System info ───────────────────────────────────────────────────────────
  final int? androidVersion; // Android SDK version
  final String? androidRelease; // Android version string (e.g. "14")

  const AudioHardwareSpecs({
    required this.backendName,
    required this.deviceName,
    required this.sampleRate,
    required this.bitDepth,
    required this.isFloat,
    required this.channels,
    required this.periodSizeFrames,
    required this.periodCount,
    required this.latencyMs,
    required this.isExclusiveMode,
    required this.deviceType,
    this.dspHardware,
    this.socName,
    this.isDirectPcm = false,
    this.bluetoothCodec,
    this.bluetoothDeviceName,
    this.btSampleRate,
    this.btBitDepth,
    this.supportedSampleRates = const [],
    this.androidVersion,
    this.androidRelease,
  });

  /// Factory: build from the Map pushed by the Android EventChannel / MethodChannel.
  factory AudioHardwareSpecs.fromAndroidMap(Map<dynamic, dynamic> m) {
    final rawDevType = m['deviceType']?.toString() ?? 'Built-in Speaker';
    final devName = (m['deviceName']?.toString() ?? '').isNotEmpty
        ? m['deviceName'].toString()
        : 'Default Soundcard';

    final int? btRate = (m['btSampleRate'] as num?)?.toInt();
    final int? btBits = (m['btBitDepth'] as num?)?.toInt();
    final int rawRate = (m['sampleRate'] as num?)?.toInt() ?? 48000;
    final int rawBitDepth = (m['bitDepth'] as num?)?.toInt() ?? 32;
    final bool rawIsFloat = (m['isFloat'] as bool?) ?? true;

    final isBt = rawDevType.contains('Bluetooth') ||
        rawDevType.contains('bluetooth') ||
        m['bluetoothCodec'] != null;

    final int effectiveSampleRate =
        (isBt && btRate != null && btRate > 0) ? btRate : rawRate;
    final int effectiveBitDepth =
        (isBt && btBits != null && btBits > 0) ? btBits : rawBitDepth;
    final bool effectiveIsFloat = isBt ? false : rawIsFloat;

    final supportedRatesRaw = m['supportedSampleRates'];
    final List<int> supportedRates = (supportedRatesRaw is List)
        ? supportedRatesRaw.map((e) => (e as num).toInt()).toList()
        : const <int>[];

    return AudioHardwareSpecs(
      backendName: 'AAudio / Android HAL',
      deviceName: devName,
      sampleRate: effectiveSampleRate,
      bitDepth: effectiveBitDepth,
      isFloat: effectiveIsFloat,
      channels: (m['channels'] as num?)?.toInt() ?? 2,
      periodSizeFrames: (m['periodSizeFrames'] as num?)?.toInt() ?? 192,
      periodCount: (m['periodCount'] as num?)?.toInt() ?? 2,
      latencyMs: (m['latencyMs'] as num?)?.toDouble() ?? 0.0,
      isExclusiveMode: false,
      deviceType: rawDevType,
      dspHardware: m['dspHardware']?.toString(),
      socName: m['socName']?.toString(),
      isDirectPcm: m['isDirectPcm'] == true,
      bluetoothCodec: m['bluetoothCodec']?.toString(),
      bluetoothDeviceName: m['bluetoothDeviceName']?.toString(),
      btSampleRate: btRate,
      btBitDepth: btBits,
      supportedSampleRates: supportedRates,
      androidVersion: (m['androidVersion'] as num?)?.toInt(),
      androidRelease: m['androidRelease']?.toString(),
    );
  }

  /// Factory: build from native miniaudio AEHardwareInfo (Desktop / iOS).
  factory AudioHardwareSpecs.fromNative(AEHardwareInfo native) {
    String devType = 'Speakers / Output Device';
    final lowerName = native.deviceName.toLowerCase();

    if (lowerName.contains('bluetooth') ||
        lowerName.contains('wh-') ||
        lowerName.contains('airpods') ||
        lowerName.contains('buds')) {
      devType = 'Bluetooth Wireless';
    } else if (lowerName.contains('dac') ||
        lowerName.contains('dragonfly') ||
        lowerName.contains('usb') ||
        lowerName.contains('fiio')) {
      devType = 'USB DAC';
    } else if (lowerName.contains('headphone') ||
        lowerName.contains('jack') ||
        lowerName.contains('headset')) {
      devType = '3.5mm Headphone Jack';
    } else if (lowerName.contains('airplay')) {
      devType = 'AirPlay Stream';
    }

    return AudioHardwareSpecs(
      backendName:
          native.backendName.isNotEmpty ? native.backendName : 'Audio Backend',
      deviceName: native.deviceName.isNotEmpty
          ? native.deviceName
          : 'Default Soundcard',
      sampleRate: native.sampleRate > 0 ? native.sampleRate : 48000,
      bitDepth: native.bitDepth > 0 ? native.bitDepth : 32,
      isFloat: native.isFloat,
      channels: native.channels > 0 ? native.channels : 2,
      periodSizeFrames: native.periodSizeFrames,
      periodCount: native.periodCount,
      latencyMs: native.latencyMs,
      isExclusiveMode: native.isExclusiveMode,
      deviceType: devType,
      dspHardware: native.dspHardware.isNotEmpty ? native.dspHardware : null,
      socName: native.socName.isNotEmpty ? native.socName : null,
      isDirectPcm: native.isDirectPcm,
    );
  }

  // ── Computed properties ───────────────────────────────────────────────────

  /// True if device hardware supports Hi-Res Audio (>48kHz or >16-bit or USB DAC)
  bool get isHiResAudio =>
      sampleRate > 48000 || bitDepth > 16 || deviceType.contains('USB');

  /// True if Bluetooth is the active output route
  bool get isBluetooth =>
      deviceType.contains('Bluetooth') ||
      deviceType.contains('bluetooth') ||
      bluetoothCodec != null;

  /// Human-readable sample rate string
  String get formattedSampleRate {
    final kHz = (sampleRate / 1000.0).toStringAsFixed(1);
    return '$kHz kHz';
  }

  /// Human-readable bit depth string
  String get formattedBitDepth {
    if (isFloat) return '$bitDepth-bit Float';
    return '$bitDepth-bit Int';
  }

  /// Human-readable latency string
  String get formattedLatency => '${latencyMs.toStringAsFixed(2)} ms';

  /// Bluetooth codec + quality string, e.g. "LDAC 96kHz / 24-bit"
  String? get formattedBtCodec {
    if (bluetoothCodec == null) return null;
    final codec = bluetoothCodec!;
    if (btSampleRate != null && btBitDepth != null) {
      final kHz = (btSampleRate! / 1000.0)
          .toStringAsFixed(btSampleRate! % 1000 == 0 ? 0 : 1);
      return '$codec ${kHz}kHz / $btBitDepth-bit';
    }
    return codec;
  }

  /// Node 1: Track Source File / Stream
  /// Node 2: miniaudio DSP / Resampler
  /// Node 3: Audio Engine / HAL Driver
  /// Node 4: Output Route / Connection Type
  /// Node 5: Target Hardware DAC / Device
  List<SignalChainNode> buildPowerampSignalChain({
    String? sourceCodec,
    String? sourceSampleRate,
    String? sourceBitDepth,
    String? sourceChannels,
    String? dspSummary,
  }) {
    final nodes = <SignalChainNode>[];

    // Node 1: Source File / Track Info
    final codec = (sourceCodec?.isNotEmpty ?? false)
        ? sourceCodec!.toUpperCase()
        : 'AUDIO';
    final srcRate =
        sourceSampleRate ?? '${(sampleRate / 1000.0).toStringAsFixed(1)} kHz';
    final srcDepth = sourceBitDepth ?? '$bitDepth-bit';
    nodes.add(SignalChainNode(
      label: 'Track Source',
      sublabel: '$codec · $srcRate · $srcDepth',
      icon: SignalChainIcon.source,
      isHighlight: false,
    ));

    // Node 2: miniaudio DSP / Engine
    final dspText = dspSummary ?? '32-bit Float PCM';
    nodes.add(SignalChainNode(
      label: 'miniaudio DSP',
      sublabel: dspText,
      icon: SignalChainIcon.dsp,
      isHighlight: dspHardware != null || dspSummary != null,
    ));

    // Node 3: Audio Engine / Driver
    if (isDirectPcm) {
      nodes.add(SignalChainNode(
        label: backendName,
        sublabel: 'Direct Hi-Res Bit-Perfect',
        icon: SignalChainIcon.backend,
        isHighlight: true,
      ));
    } else if (isExclusiveMode) {
      nodes.add(SignalChainNode(
        label: backendName,
        sublabel: 'Exclusive Bit-Perfect',
        icon: SignalChainIcon.backend,
        isHighlight: true,
      ));
    } else {
      final osLabel = androidRelease != null
          ? 'Android $androidRelease HAL'
          : 'Shared Mixer';
      final latLabel =
          latencyMs > 0 ? '${latencyMs.toStringAsFixed(1)}ms latency' : osLabel;
      nodes.add(SignalChainNode(
        label: backendName,
        sublabel: latLabel,
        icon: SignalChainIcon.backend,
      ));
    }

    // Node 4: Output Route / Transport
    if (isBluetooth) {
      final codecStr = formattedBtCodec ?? bluetoothCodec ?? 'SBC';
      nodes.add(SignalChainNode(
        label: deviceType,
        sublabel: codecStr,
        icon: SignalChainIcon.bluetooth,
        isHighlight: bluetoothCodec == 'LDAC' ||
            bluetoothCodec == 'aptX HD' ||
            bluetoothCodec == 'LC3',
      ));
    } else {
      final kHz = (sampleRate / 1000.0)
          .toStringAsFixed(sampleRate % 1000 == 0 ? 0 : 1);
      final routeRate = '$kHz kHz / $bitDepth-bit';
      nodes.add(SignalChainNode(
        label: deviceType,
        sublabel: routeRate,
        icon: _iconForDeviceType(deviceType),
        isHighlight: isHiResAudio,
      ));
    }

    // Node 5: Target Hardware DAC / Device
    final effectiveDeviceName = (bluetoothDeviceName?.isNotEmpty ?? false)
        ? bluetoothDeviceName!
        : (dspHardware != null && dspHardware!.isNotEmpty
            ? dspHardware!
            : deviceName);

    final effRate = (isBluetooth && btSampleRate != null && btSampleRate! > 0)
        ? btSampleRate!
        : sampleRate;
    final effBits = (isBluetooth && btBitDepth != null && btBitDepth! > 0)
        ? btBitDepth!
        : bitDepth;
    final kHz = (effRate / 1000.0).toStringAsFixed(effRate % 1000 == 0 ? 0 : 1);
    final outSub = '$kHz kHz / $effBits-bit Out';

    nodes.add(SignalChainNode(
      label: effectiveDeviceName,
      sublabel: outSub,
      icon: SignalChainIcon.output,
      isHighlight: isHiResAudio,
    ));

    return nodes;
  }

  SignalChainIcon _iconForDeviceType(String type) {
    if (type.contains('USB')) return SignalChainIcon.usbDac;
    if (type.contains('3.5mm') ||
        type.contains('Headphone') ||
        type.contains('Headset')) {
      return SignalChainIcon.wiredHeadphone;
    }
    if (type.contains('HDMI')) return SignalChainIcon.hdmi;
    if (type.contains('Speaker')) return SignalChainIcon.speaker;
    return SignalChainIcon.output;
  }
}

// ── Signal Chain Model ────────────────────────────────────────────────────────

enum SignalChainIcon {
  source,
  dsp,
  backend,
  bluetooth,
  wiredHeadphone,
  usbDac,
  speaker,
  hdmi,
  output,
}

class SignalChainNode {
  final String label;
  final String? sublabel;
  final SignalChainIcon icon;
  final bool isHighlight;

  const SignalChainNode({
    required this.label,
    this.sublabel,
    required this.icon,
    this.isHighlight = false,
  });
}

// ── Service ───────────────────────────────────────────────────────────────────

/// Service to inspect active hardware audio specifications and device routes.
///
/// On Android: uses MethodChannel for immediate async lookup and an EventChannel
/// broadcast stream to receive live updates whenever the output device changes.
class AudioHardwareInspector {
  static const MethodChannel _methodChannel =
      MethodChannel('com.wambugu.sautiflow/hardware');
  static const EventChannel _eventChannel =
      EventChannel('com.wambugu.sautiflow/hardware_stream');

  static AudioHardwareSpecs? _currentSpecs;
  static StreamSubscription? _androidEventSub;
  static final StreamController<AudioHardwareSpecs> _controller =
      StreamController<AudioHardwareSpecs>.broadcast();

  /// Synchronous fallback inspection
  static AudioHardwareSpecs inspect(dynamic player) {
    if (_currentSpecs != null) return _currentSpecs!;
    try {
      final nativeInfo = player.getHardwareInfo();
      if (nativeInfo is AEHardwareInfo) {
        _currentSpecs = AudioHardwareSpecs.fromNative(nativeInfo);
        return _currentSpecs!;
      }
    } catch (_) {}

    return const AudioHardwareSpecs(
      backendName: 'Audio Backend',
      deviceName: 'Default Soundcard',
      sampleRate: 48000,
      bitDepth: 32,
      isFloat: true,
      channels: 2,
      periodSizeFrames: 192,
      periodCount: 2,
      latencyMs: 0.0,
      isExclusiveMode: false,
      deviceType: 'Built-in Speaker',
    );
  }

  /// Single async fetch — updates cached specs and notifies broadcast subscribers.
  static Future<AudioHardwareSpecs> inspectAsync(dynamic player) async {
    if (Platform.isAndroid) {
      try {
        final res = await _methodChannel.invokeMethod('getHardwareAudioSpecs');
        if (res is Map) {
          _currentSpecs = AudioHardwareSpecs.fromAndroidMap(res);
          _controller.add(_currentSpecs!);
          return _currentSpecs!;
        }
      } catch (e) {
        debugPrint('[AudioHardwareInspector] Android MethodChannel error: $e');
      }
    }

    try {
      final rawNative = await player.getHardwareInfo();
      if (rawNative is AEHardwareInfo) {
        _currentSpecs = AudioHardwareSpecs.fromNative(rawNative);
        _controller.add(_currentSpecs!);
        return _currentSpecs!;
      }
    } catch (e) {
      debugPrint('[AudioHardwareInspector] Native getHardwareInfo error: $e');
    }

    _currentSpecs ??= const AudioHardwareSpecs(
      backendName: 'AAudio / Android HAL',
      deviceName: 'Built-in Speaker',
      sampleRate: 48000,
      bitDepth: 32,
      isFloat: true,
      channels: 2,
      periodSizeFrames: 192,
      periodCount: 2,
      latencyMs: 0.0,
      isExclusiveMode: false,
      deviceType: 'Built-in Speaker',
    );
    return _currentSpecs!;
  }

  /// Returns a broadcast [Stream<AudioHardwareSpecs>] that emits current specs immediately
  /// and receives real-time updates on route/hardware changes.
  static Stream<AudioHardwareSpecs> hardwareStream(dynamic player) {
    // Eagerly fetch initial state if not cached
    if (_currentSpecs == null) {
      inspectAsync(player);
    }

    if (Platform.isAndroid && _androidEventSub == null) {
      _androidEventSub = _eventChannel.receiveBroadcastStream().listen(
        (event) {
          if (event is Map) {
            _currentSpecs = AudioHardwareSpecs.fromAndroidMap(event);
            _controller.add(_currentSpecs!);
          }
        },
        onError: (e) {
          debugPrint('[AudioHardwareInspector] EventChannel error: $e');
        },
      );
    }

    return _controller.stream;
  }

  /// Get current cached specs synchronously (or null if not yet fetched)
  static AudioHardwareSpecs? get currentSpecs => _currentSpecs;

  /// Resets cached stream and specs (e.g. on hot restart)
  static void resetStream() {
    _androidEventSub?.cancel();
    _androidEventSub = null;
    _currentSpecs = null;
  }
}
