import 'dart:async';
import 'package:flutter/material.dart';
import 'package:material_3_expressive/components/progress_indicators/m3e_progress_indicators.dart';
import 'package:sautiplay/isolate_player.dart';
import 'package:sautiplay/services/audio_hardware_inspector.dart';

/// Shows the Developer & Audiophile Audio Engine Diagnostic Panel as a glassmorphic bottom sheet.
void showAudioEngineDiagnosticPanel(
    BuildContext context, IsolateAudioPlayer player) {
  showModalBottomSheet(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    barrierColor: Colors.black.withValues(alpha: 0.65),
    builder: (ctx) => AudioEngineDiagnosticPanel(player: player),
  );
}

class AudioEngineDiagnosticPanel extends StatefulWidget {
  final IsolateAudioPlayer player;

  const AudioEngineDiagnosticPanel({
    super.key,
    required this.player,
  });

  @override
  State<AudioEngineDiagnosticPanel> createState() =>
      _AudioEngineDiagnosticPanelState();
}

class _AudioEngineDiagnosticPanelState
    extends State<AudioEngineDiagnosticPanel> {
  Timer? _telemetryTimer;
  StreamSubscription<AudioHardwareSpecs>? _hardwareSub;
  AudioHardwareSpecs? _hardwareSpecs;
  Map<String, dynamic>? _telemetry;
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _hardwareSpecs = AudioHardwareInspector.currentSpecs;
    _hardwareSub =
        AudioHardwareInspector.hardwareStream(widget.player).listen((specs) {
      if (mounted) {
        setState(() {
          _hardwareSpecs = specs;
        });
      }
    });
    AudioHardwareInspector.inspectAsync(widget.player).then((specs) {
      if (mounted) {
        setState(() {
          _hardwareSpecs = specs;
        });
      }
    });

    _fetchTelemetry();
    _telemetryTimer = Timer.periodic(const Duration(milliseconds: 250), (_) {
      _fetchTelemetry();
    });
  }

  @override
  void dispose() {
    _telemetryTimer?.cancel();
    _hardwareSub?.cancel();
    super.dispose();
  }

  Future<void> _fetchTelemetry() async {
    try {
      final data = await widget.player.getEngineTelemetry();
      if (mounted) {
        setState(() {
          _telemetry = data;
          _loading = false;
          _error = null;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _error = e.toString();
          _loading = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final mediaQuery = MediaQuery.of(context);

    return Container(
      constraints: BoxConstraints(
        maxHeight: mediaQuery.size.height * 0.90,
      ),
      decoration: BoxDecoration(
        color: const Color(0xFF0F121A).withValues(alpha: 0.96),
        borderRadius: const BorderRadius.vertical(top: Radius.circular(28)),
        border: Border.all(color: const Color(0xFF2A324B), width: 1.2),
        boxShadow: [
          BoxShadow(
            color: Colors.cyanAccent.withValues(alpha: 0.12),
            blurRadius: 32,
            spreadRadius: 2,
          )
        ],
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // Drag handle
          Center(
            child: Container(
              margin: const EdgeInsets.only(top: 12, bottom: 8),
              width: 42,
              height: 5,
              decoration: BoxDecoration(
                color: Colors.white24,
                borderRadius: BorderRadius.circular(2.5),
              ),
            ),
          ),

          // Header
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
            child: Row(
              children: [
                const SizedBox(width: 4),
                Expanded(
                  child: Row(
                    children: [
                      const Text(
                        'Audio Info & Diagnostics',
                        style: TextStyle(
                          color: Colors.white,
                          fontWeight: FontWeight.bold,
                          fontSize: 15,
                          letterSpacing: 1.1,
                        ),
                      ),
                      const SizedBox(width: 8),
                      Container(
                        width: 7,
                        height: 7,
                        decoration: const BoxDecoration(
                          color: Colors.greenAccent,
                          shape: BoxShape.circle,
                        ),
                      ),
                      const SizedBox(width: 6),
                      const Text(
                        'LIVE',
                        style: TextStyle(
                          fontFamily: 'monospace',
                          color: Colors.greenAccent,
                          fontWeight: FontWeight.bold,
                          fontSize: 10,
                          letterSpacing: 0.8,
                        ),
                      ),
                    ],
                  ),
                ),
                Container(
                  width: 36,
                  height: 36,
                  decoration: BoxDecoration(
                    color: const Color(0xFF222B40),
                    borderRadius: BorderRadius.circular(18),
                  ),
                  child: Center(
                    child: IconButton(
                      padding: EdgeInsets.zero,
                      icon: const Icon(Icons.close_rounded,
                          color: Colors.white70, size: 20),
                      onPressed: () => Navigator.of(context).pop(),
                    ),
                  ),
                )
              ],
            ),
          ),

          const Divider(color: Color(0xFF222B40), height: 1),

          // Body
          Flexible(
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(20),
              child: _loading
                  ? const Padding(
                      padding: EdgeInsets.all(40),
                      child: Center(child: M3EProgressIndicator.circularWavy()),
                    )
                  : _error != null
                      ? Padding(
                          padding: const EdgeInsets.all(20),
                          child: Text(
                            'Engine Telemetry Error: $_error',
                            style: const TextStyle(color: Colors.redAccent),
                          ),
                        )
                      : _buildDiagnosticsContent(context),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildDiagnosticsContent(BuildContext context) {
    final t = _telemetry!;
    final hw = t['hardware'] as Map<String, dynamic>? ?? {};

    final specs = _hardwareSpecs ??
        AudioHardwareInspector.currentSpecs ??
        AudioHardwareInspector.inspect(widget.player);

    final String activeDeviceName = specs.isBluetooth
        ? (specs.bluetoothDeviceName?.isNotEmpty == true
            ? specs.bluetoothDeviceName!
            : specs.deviceName)
        : specs.deviceName;

    final String fileType = (t['fileType'] as String? ?? 'PCM').toUpperCase();
    final int bitrateKbps = t['bitrateKbps'] as int? ?? 0;
    final int fileSizeBytes = t['fileSizeBytes'] as int? ?? 0;

    String bitrateDisplay = 'N/A';
    if (bitrateKbps > 0) {
      bitrateDisplay = '$bitrateKbps kbps';
      if (['FLAC', 'ALAC'].contains(fileType)) {
        bitrateDisplay += '';
      } else if (['WAV', 'AIFF'].contains(fileType)) {
        bitrateDisplay += '';
      } else if (['MP3', 'AAC', 'M4A', 'OGG', 'OPUS'].contains(fileType)) {
        bitrateDisplay += '';
      }
    }

    final int srcRate = t['inputSampleRate'] as int? ?? 48000;
    final int srcDepth =
        t['inputBitDepth'] as int? ?? ((hw['bitDepth'] as int?) ?? 16);
    final int dspRate = t['processingSampleRate'] as int? ?? 48000;
    final int dspChannels = t['processingChannels'] as int? ?? 2;
    final int dacRate = t['outputSampleRate'] as int? ??
        (hw['sampleRate'] as int? ?? specs.sampleRate);
    final int dacDepth = hw['bitDepth'] as int? ?? specs.bitDepth;
    final bool isExclusive =
        hw['isExclusiveMode'] as bool? ?? specs.isExclusiveMode;
    final String backend = hw['backendName'] as String? ?? specs.backendName;
    final int periodFrames =
        hw['periodSizeFrames'] as int? ?? specs.periodSizeFrames;
    final int periodCount = hw['periodCount'] as int? ?? specs.periodCount;

    final bool eqOn = t['eqEnabled'] == true;
    final double crossfeedMix = (t['crossfeedMix'] as num?)?.toDouble() ?? 0.0;
    final String crossfeedAlgo =
        _formatCrossfeedAlgo(t['crossfeedAlgo']?.toString(), crossfeedMix);
    final bool sautiDspOn = t['sautiDspEnabled'] == true;
    final bool limiterOn = t['limiterEnabled'] == true;
    final bool stereoWidenOn = t['stereoWidenEnabled'] == true;
    final bool stereoEnhanceOn = t['stereoEnhancementEnabled'] == true;

    // Calculate node latencies
    final nodeLatencies = _calculatePerNodeLatencies(
      sampleRate: dspRate,
      hwLatencyMs:
          (t['deviceLatencyMs'] as num?)?.toDouble() ?? specs.latencyMs,
      crossfeedAlgo: crossfeedAlgo,
      crossfeedDelayMs: (t['crossfeedDelayMs'] as num?)?.toDouble() ?? 0.40,
      limiterOn: limiterOn,
      stereoWidenOn: stereoWidenOn,
      stereoEnhanceOn: stereoEnhanceOn,
      sautiDspOn: sautiDspOn,
      isSrcActive: (srcRate != dacRate),
      resampleLatencyMs: (t['resampleLatencyMs'] as num?)?.toDouble(),
      deviceType: specs.deviceType,
    );

    // Sum DSP node latencies
    double sumDspMs = 0.0;
    double sumDspSamples = 0.0;
    for (final n in nodeLatencies) {
      if (n.nodeName != 'Source / Decoder' &&
          !n.nodeName.startsWith('Output')) {
        sumDspMs += n.latencyMs;
        sumDspSamples += n.latencySamples;
      }
    }

    final double hwLatencyMs =
        (t['deviceLatencyMs'] as num?)?.toDouble() ?? specs.latencyMs;
    final double totalEndToEndLatencyMs = hwLatencyMs + sumDspMs;
    final int clippedCount = t['clippedCount'] as int? ?? 0;

    final bool isSrcActive = (srcRate != dacRate);
    final String resamplerAlgo =
        _formatResamplerAlgo(t['resampleAlgorithm']?.toString());

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // 1. Hardware Output Device Card (Speakers, Built-in Earpiece, 3.5mm, BT, USB DAC, etc.)
        //  _buildHardwareDeviceCard(specs, activeDeviceName),

        const SizedBox(height: 16),

        // 2. Per-Node Latency Breakdown Card (Source -> DAC)
        _buildPerNodeLatencyCard(
            nodeLatencies, totalEndToEndLatencyMs, sumDspSamples),

        const SizedBox(height: 16),

        // 3. Terminal Matrix Display Box (DSP & Telemetry Details)
        Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: const Color(0xFF080A10),
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: const Color(0xFF1E2638)),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  const Text(
                    'DSP Status',
                    style: TextStyle(
                      fontFamily: 'monospace',
                      color: Colors.white70,
                      fontSize: 12,
                      fontWeight: FontWeight.bold,
                      letterSpacing: 1.5,
                    ),
                  ),
                  /*  Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                    decoration: BoxDecoration(
                      color: isSrcActive
                          ? Colors.amber.withValues(alpha: 0.2)
                          : Colors.greenAccent.withValues(alpha: 0.2),
                      borderRadius: BorderRadius.circular(6),
                    ),
                    child: Text(
                      isSrcActive ? 'SRC ACTIVE' : 'BIT-PERFECT',
                      style: TextStyle(
                        fontFamily: 'monospace',
                        color: isSrcActive
                            ? Colors.amberAccent
                            : Colors.greenAccent,
                        fontSize: 10,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ), */
                ],
              ),
              const SizedBox(height: 12),
              const Divider(color: Color(0xFF1B2336), height: 1),
              const SizedBox(height: 12),
              _buildTelemetryRow('Device', activeDeviceName,
                  isValueActive: true),
              _buildTelemetryRow('Device Type', specs.deviceType,
                  isValueActive: true),
              if (specs.bluetoothCodec != null)
                _buildTelemetryRow(
                  'BT Codec',
                  specs.formattedBtCodec ?? specs.bluetoothCodec!,
                  isValueActive: true,
                ),
              _buildTelemetryRow('File Format', fileType, isValueActive: true),
              _buildTelemetryRow('Bitrate', bitrateDisplay,
                  isValueActive: bitrateKbps > 0),
              if (fileSizeBytes > 0)
                _buildTelemetryRow('File Size',
                    '${(fileSizeBytes / (1024 * 1024)).toStringAsFixed(2)} MB',
                    isValueActive: true),
              _buildTelemetryRow('Source',
                  '${(srcRate / 1000.0).toStringAsFixed(1)} kHz / $srcDepth-bit PCM'),
              _buildTelemetryRow('Decoder',
                  '${(srcRate / 1000.0).toStringAsFixed(1)} kHz PCM'),
              _buildTelemetryRow('DSP',
                  '${(dspRate / 1000.0).toStringAsFixed(1)} kHz Float32 ($dspChannels ch)'),
              _buildTelemetryRow('Output',
                  '${(dacRate / 1000.0).toStringAsFixed(1)} kHz / $dacDepth-bit (${specs.deviceType})'),
              if (specs.socName != null && specs.socName!.isNotEmpty)
                _buildTelemetryRow('SoC Processor', specs.socName!,
                    isValueActive: true),
              if (specs.dspHardware != null && specs.dspHardware!.isNotEmpty)
                _buildTelemetryRow('DSP Hardware', specs.dspHardware!,
                    isValueActive: true),
              _buildTelemetryRow('Backend',
                  '$backend (${specs.isDirectPcm ? "Hi-Res Bit-Perfect" : (isExclusive ? "Exclusive" : "Shared")})'),
              _buildTelemetryRow(
                  'Buffer', '$periodFrames frames ($periodCount periods)'),
              _buildTelemetryRow('Total Latency',
                  '${totalEndToEndLatencyMs.toStringAsFixed(2)} ms (DSP: ${sumDspMs.toStringAsFixed(2)} ms + Hardware: ${hwLatencyMs.toStringAsFixed(2)} ms)'),
              _buildTelemetryRow(
                  'SRC',
                  isSrcActive
                      ? 'ON (${(srcRate / 1000.0).toStringAsFixed(1)} → ${(dacRate / 1000.0).toStringAsFixed(1)} kHz)'
                      : 'OFF'),
              _buildTelemetryRow('Resampler', resamplerAlgo),
              _buildTelemetryRow('True-Peak',
                  '${((t['truePeakDBTP'] as num?)?.toDouble() ?? -100.0).toStringAsFixed(1)} dBTP',
                  isValueActive:
                      ((t['truePeakDBTP'] as num?)?.toDouble() ?? -100.0) >
                          -90.0,
                  isWarning:
                      ((t['truePeakDBTP'] as num?)?.toDouble() ?? -100.0) >
                          -0.5),
              _buildTelemetryRow('Loudness (LUFS)',
                  'Mom: ${((t['momentaryLUFS'] as num?)?.toDouble() ?? -100.0).toStringAsFixed(1)} / Int: ${((t['integratedLUFS'] as num?)?.toDouble() ?? -100.0).toStringAsFixed(1)}'),
              _buildTelemetryRow('Limiter GR',
                  '${((t['limiterGainReductionDB'] as num?)?.toDouble() ?? 0.0).toStringAsFixed(1)} dB',
                  isValueActive:
                      ((t['limiterGainReductionDB'] as num?)?.toDouble() ??
                              0.0) <
                          -0.1),
              _buildTelemetryRow('EQ', eqOn ? 'ON' : 'OFF',
                  isValueActive: eqOn),
              _buildTelemetryRow('Crossfeed', crossfeedAlgo,
                  isValueActive: crossfeedAlgo != 'OFF'),
              _buildTelemetryRow('Sauti DSP', sautiDspOn ? 'ON' : 'OFF',
                  isValueActive: sautiDspOn),
              _buildTelemetryRow('Limiter', limiterOn ? 'ON' : 'OFF',
                  isValueActive: limiterOn),
              _buildTelemetryRow('Clipping', '$clippedCount samples',
                  isWarning: clippedCount > 0),
              _buildTelemetryRow('Underruns', '0', isValueActive: false),
            ],
          ),
        ),

        const SizedBox(height: 16),
      ],
    );
  }

  /// Builds a dedicated, sleek hardware output device card
  /* Widget _buildHardwareDeviceCard(
      AudioHardwareSpecs specs, String activeDeviceName) {
    final deviceIcon = _getDeviceIcon(specs.deviceType);

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: const Color(0xFF0C101A),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: const Color(0xFF1E2840)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // Header Row with Icon, Device Name, and Live badge
          Row(
            children: [
              Container(
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: Colors.cyanAccent.withValues(alpha: 0.15),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Icon(
                  deviceIcon,
                  color: Colors.cyanAccent,
                  size: 22,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        const Text(
                          'HARDWARE OUTPUT',
                          style: TextStyle(
                            fontFamily: 'monospace',
                            color: Colors.cyanAccent,
                            fontSize: 10,
                            fontWeight: FontWeight.bold,
                            letterSpacing: 1.2,
                          ),
                        ),
                        /* if (specs.isHiResAudio) ...[
                          const SizedBox(width: 8),
                          Container(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 6, vertical: 2),
                            decoration: BoxDecoration(
                              color: Colors.amber.withValues(alpha: 0.2),
                              borderRadius: BorderRadius.circular(4),
                              border: Border.all(
                                color: Colors.amber.withValues(alpha: 0.4),
                                width: 0.8,
                              ),
                            ),
                            child: const Text(
                              'HI-RES',
                              style: TextStyle(
                                fontFamily: 'monospace',
                                color: Colors.amberAccent,
                                fontSize: 9,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                          ),
                        ],*/
                      ],
                    ),
                    const SizedBox(height: 3),
                    Text(
                      activeDeviceName,
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 15,
                        fontWeight: FontWeight.bold,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                ),
              ),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                decoration: BoxDecoration(
                  color: Colors.greenAccent.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(6),
                  border: Border.all(
                    color: Colors.greenAccent.withValues(alpha: 0.3),
                    width: 0.8,
                  ),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Container(
                      width: 6,
                      height: 6,
                      decoration: const BoxDecoration(
                        color: Colors.greenAccent,
                        shape: BoxShape.circle,
                      ),
                    ),
                    const SizedBox(width: 5),
                    const Text(
                      'ACTIVE',
                      style: TextStyle(
                        fontFamily: 'monospace',
                        color: Colors.greenAccent,
                        fontSize: 10,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          const Divider(color: Color(0xFF1A2234), height: 1),
          const SizedBox(height: 12),

          // Wrap of specs badges
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              _buildMiniSpecBadge(
                icon: Icons.alt_route_rounded,
                label: 'Route',
                value: specs.deviceType,
                highlight: true,
              ),
              _buildMiniSpecBadge(
                icon: Icons.developer_board_rounded,
                label: 'Backend',
                value: specs.backendName,
              ),
              _buildMiniSpecBadge(
                icon: Icons.speed_rounded,
                label: 'Format',
                value:
                    '${specs.formattedSampleRate} / ${specs.formattedBitDepth}',
                highlight: specs.isHiResAudio,
              ),
              _buildMiniSpecBadge(
                icon: (specs.isDirectPcm || specs.isExclusiveMode)
                    ? Icons.lock_outline_rounded
                    : Icons.lock_open_rounded,
                label: 'Mode',
                value: specs.isDirectPcm
                    ? 'Direct Hi-Res'
                    : (specs.isExclusiveMode ? 'Bit-Perfect' : 'Shared Mixer'),
                highlight: specs.isDirectPcm || specs.isExclusiveMode,
              ),
              if (specs.dspHardware != null && specs.dspHardware!.isNotEmpty)
                _buildMiniSpecBadge(
                  icon: Icons.memory_rounded,
                  label: 'DSP',
                  value: specs.dspHardware!,
                  highlight: true,
                ),
              if (specs.bluetoothCodec != null)
                _buildMiniSpecBadge(
                  icon: Icons.bluetooth_audio_rounded,
                  label: 'BT Codec',
                  value: specs.formattedBtCodec ?? specs.bluetoothCodec!,
                  highlight: specs.bluetoothCodec == 'LDAC' ||
                      specs.bluetoothCodec == 'aptX HD' ||
                      specs.bluetoothCodec == 'LC3',
                ),
              _buildMiniSpecBadge(
                icon: Icons.timer_outlined,
                label: 'HW Latency',
                value: specs.formattedLatency,
              ),
            ],
          ),
        ],
      ),
    );
  }
*/
  Widget _buildMiniSpecBadge({
    required IconData icon,
    required String label,
    required String value,
    bool highlight = false,
  }) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: highlight
            ? Colors.cyanAccent.withValues(alpha: 0.1)
            : const Color(0xFF141A29),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(
          color: highlight
              ? Colors.cyanAccent.withValues(alpha: 0.4)
              : const Color(0xFF232D42),
          width: 0.8,
        ),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            icon,
            size: 13,
            color: highlight ? Colors.cyanAccent : Colors.white60,
          ),
          const SizedBox(width: 6),
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                label.toUpperCase(),
                style: TextStyle(
                  fontFamily: 'monospace',
                  color: highlight
                      ? Colors.cyanAccent.withValues(alpha: 0.8)
                      : Colors.white38,
                  fontSize: 8,
                  fontWeight: FontWeight.bold,
                ),
              ),
              Text(
                value,
                style: TextStyle(
                  fontFamily: 'monospace',
                  color: highlight ? Colors.white : Colors.white70,
                  fontSize: 11,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  IconData _getDeviceIcon(String type) {
    final lower = type.toLowerCase();
    if (lower.contains('earpiece')) {
      return Icons.phone_in_talk_rounded;
    } else if (lower.contains('usb') || lower.contains('dac')) {
      return Icons.usb_rounded;
    } else if (lower.contains('3.5mm') ||
        lower.contains('headphone') ||
        lower.contains('headset') ||
        lower.contains('jack')) {
      return Icons.headphones_rounded;
    } else if (lower.contains('bluetooth') ||
        lower.contains('wireless') ||
        lower.contains('buds') ||
        lower.contains('airpods')) {
      return Icons.bluetooth_audio_rounded;
    } else if (lower.contains('hdmi') || lower.contains('tv')) {
      return Icons.tv_rounded;
    } else if (lower.contains('line') || lower.contains('aux')) {
      return Icons.settings_input_component_rounded;
    }
    return Icons.speaker_rounded;
  }

  Widget _buildPerNodeLatencyCard(
      List<_NodeLatencyInfo> nodes, double totalMs, double dspSamples) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: const Color(0xFF0C101A),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: const Color(0xFF1E2840)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              const Row(
                children: [
                  Text(
                    'Latency',
                    style: TextStyle(
                      fontFamily: 'monospace',
                      color: Colors.white70,
                      fontSize: 12,
                      fontWeight: FontWeight.bold,
                      letterSpacing: 1.2,
                    ),
                  ),
                ],
              ),
              Text(
                '${totalMs.toStringAsFixed(2)} ms',
                style: const TextStyle(
                  fontFamily: 'monospace',
                  color: Colors.greenAccent,
                  fontSize: 11,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          const Divider(color: Color(0xFF1A2234), height: 1),
          const SizedBox(height: 10),
          ...nodes.map((node) => Padding(
                padding: const EdgeInsets.symmetric(vertical: 3),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Row(
                      children: [
                        Text(
                          node.stepNumber,
                          style: TextStyle(
                            fontFamily: 'monospace',
                            color: Colors.white.withValues(alpha: 0.4),
                            fontSize: 11,
                          ),
                        ),
                        const SizedBox(width: 6),
                        Text(
                          node.nodeName,
                          style: TextStyle(
                            fontFamily: 'monospace',
                            color: node.latencyMs > 0
                                ? Colors.white
                                : Colors.white54,
                            fontSize: 11,
                            fontWeight: node.latencyMs > 0
                                ? FontWeight.bold
                                : FontWeight.normal,
                          ),
                        ),
                      ],
                    ),
                    Text(
                      node.latencyMs > 0
                          ? '${node.latencyMs.toStringAsFixed(2)} ms'
                          : '0.00 ms',
                      style: TextStyle(
                        fontFamily: 'monospace',
                        color: node.latencyMs > 0
                            ? Colors.amberAccent
                            : Colors.white38,
                        fontSize: 11,
                      ),
                    ),
                  ],
                ),
              )),
        ],
      ),
    );
  }

  Widget _buildTelemetryRow(String label, String value,
      {bool isValueActive = false, bool isWarning = false}) {
    Color valColor = Colors.white;
    if (isWarning) {
      valColor = Colors.redAccent;
    } else if (isValueActive) {
      valColor = Colors.cyanAccent;
    }

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(
            label,
            style: TextStyle(
              fontFamily: 'monospace',
              color: Colors.white.withValues(alpha: 0.5),
              fontSize: 12,
            ),
          ),
          Flexible(
            child: Text(
              value,
              textAlign: TextAlign.right,
              style: TextStyle(
                fontFamily: 'monospace',
                color: valColor,
                fontWeight: isValueActive ? FontWeight.bold : FontWeight.normal,
                fontSize: 12,
              ),
            ),
          ),
        ],
      ),
    );
  }

  List<_NodeLatencyInfo> _calculatePerNodeLatencies({
    required int sampleRate,
    required double hwLatencyMs,
    required String crossfeedAlgo,
    required double crossfeedDelayMs,
    required bool limiterOn,
    required bool stereoWidenOn,
    required bool stereoEnhanceOn,
    required bool sautiDspOn,
    required bool isSrcActive,
    double? resampleLatencyMs,
    String? deviceType,
  }) {
    final list = <_NodeLatencyInfo>[];
    int step = 1;

    // 1. Source / Decoder
    list.add(_NodeLatencyInfo('${step++}.', 'Source / Decoder', 0.0, 0.0));

    // 2. Crossfeed Node
    if (crossfeedAlgo != 'OFF') {
      final double delayMs = crossfeedDelayMs > 0 ? crossfeedDelayMs : 0.40;
      final double samples = delayMs * 0.001 * sampleRate;
      list.add(_NodeLatencyInfo(
          '${step++}.', 'Crossfeed ($crossfeedAlgo)', delayMs, samples));
    } else {
      list.add(_NodeLatencyInfo('${step++}.', 'Crossfeed Node', 0.0, 0.0));
    }

    // 3. Sauti DSP Suite Node (Convolver & Enhancers)
    if (sautiDspOn) {
      const double dspMs = 0.50; // Low-latency partitioned convolution & DSP
      final double samples = dspMs * 0.001 * sampleRate;
      list.add(_NodeLatencyInfo('${step++}.', 'Sauti DSP', dspMs, samples));
    } else {
      list.add(_NodeLatencyInfo('${step++}.', 'Sauti DSP', 0.0, 0.0));
    }

    // 4. Stereo Widen (Haas delay)
    if (stereoWidenOn) {
      const double delayMs = 15.0;
      final double samples = delayMs * 0.001 * sampleRate;
      list.add(
          _NodeLatencyInfo('${step++}.', 'Stereo Widen', delayMs, samples));
    }

    // 5. Stereo Enhancement (PFB analysis)
    if (stereoEnhanceOn) {
      const double delayMs = 1.20;
      final double samples = delayMs * 0.001 * sampleRate;
      list.add(_NodeLatencyInfo(
          '${step++}.', 'Stereo Enhancement', delayMs, samples));
    }

    // 6. Lookahead Limiter Node
    if (limiterOn) {
      const double attackMs = 2.0;
      final double samples = attackMs * 0.001 * sampleRate;
      list.add(_NodeLatencyInfo(
          '${step++}.', 'Software Limiter', attackMs, samples));
    } else {
      list.add(_NodeLatencyInfo('${step++}.', 'Software Limiter', 0.0, 0.0));
    }

    // 7. Resampler Node
    if (isSrcActive) {
      final double resampleMs = (resampleLatencyMs != null && resampleLatencyMs > 0.0)
          ? resampleLatencyMs
          : 0.50;
      final double samples = resampleMs * 0.001 * sampleRate;
      list.add(
          _NodeLatencyInfo('${step++}.', 'SRC Resampler', resampleMs, samples));
    }

    // 8. Hardware Output DAC
    final double hwSamples = hwLatencyMs * 0.001 * sampleRate;
    final hwLabel = deviceType != null && deviceType.isNotEmpty
        ? 'Hardware Output'
        : 'Hardware Output DAC';
    list.add(_NodeLatencyInfo('${step++}.', hwLabel, hwLatencyMs, hwSamples));

    return list;
  }

  String _formatResamplerAlgo(String? algo) {
    if (algo == null) return 'Miniaudio Linear';
    switch (algo) {
      case 'miniaudioLinear':
        return 'Miniaudio Linear';
      case 'srcSincBestQuality':
        return 'SRC Sinc Best Quality';
      case 'srcSincMediumQuality':
        return 'SRC Sinc Medium Quality';
      case 'srcSincFastest':
        return 'SRC Sinc Fastest';
      case 'soxrVHQLinearPhase':
        return 'SOXR VHQ Linear Phase';
      case 'soxrVHQMinimumPhase':
        return 'SOXR VHQ Minimum Phase';
      case 'soxrHQ':
        return 'SOXR HQ';
      case 'soxrFast':
        return 'SOXR Fast';
      case 'r8brain24LinearPhase':
        return 'r8brain Linear Phase';
      case 'r8brain24MinimumPhase':
        return 'r8brain Minimum Phase';
      default:
        return algo;
    }
  }

  String _formatCrossfeedAlgo(String? algo, double mix) {
    if (algo == null || algo == 'off' || algo == 'OFF' || mix <= 0.0001) {
      return 'OFF';
    }
    switch (algo.toLowerCase()) {
      case 'simple':
        return 'Simple ITD';
      case 'bs2b':
        return 'BS2B Chu Moy';
      case 'meier':
        return 'Jan Meier';
      case 'natural':
        return 'Natural Crossfeed';
      default:
        return algo.toUpperCase();
    }
  }
}

class _NodeLatencyInfo {
  final String stepNumber;
  final String nodeName;
  final double latencyMs;
  final double latencySamples;

  _NodeLatencyInfo(
      this.stepNumber, this.nodeName, this.latencyMs, this.latencySamples);
}
