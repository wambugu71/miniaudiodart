import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:material_3_expressive/material_3_expressive.dart';
import '../isolate_player.dart';
import '../services/app_state_service.dart';
import '../services/app_theme_service.dart';

/// Shows a bottom sheet modal allowing the user to tune Playback Speed (Rate),
/// Independent Pitch Shifting, and Scaletempo Pitch Correction.
Future<void> showPlaybackSpeedModal(
  BuildContext context,
  IsolateAudioPlayer player, {
  double currentRate = 1.0,
  double currentPitch = 1.0,
  bool currentPitchCorrection = true,
  ValueChanged<double>? onRateChanged,
  ValueChanged<double>? onPitchChanged,
  ValueChanged<bool>? onPitchCorrectionChanged,
}) async {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    backgroundColor: AppThemeService.instance.currentData.cardDark,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
    ),
    builder: (sheetContext) {
      return _PlaybackSpeedSheet(
        player: player,
        initialRate: currentRate,
        initialPitch: currentPitch,
        initialPitchCorrection: currentPitchCorrection,
        onRateChanged: onRateChanged,
        onPitchChanged: onPitchChanged,
        onPitchCorrectionChanged: onPitchCorrectionChanged,
      );
    },
  );
}

class _PlaybackSpeedSheet extends StatefulWidget {
  final IsolateAudioPlayer player;
  final double initialRate;
  final double initialPitch;
  final bool initialPitchCorrection;
  final ValueChanged<double>? onRateChanged;
  final ValueChanged<double>? onPitchChanged;
  final ValueChanged<bool>? onPitchCorrectionChanged;

  const _PlaybackSpeedSheet({
    required this.player,
    required this.initialRate,
    required this.initialPitch,
    required this.initialPitchCorrection,
    this.onRateChanged,
    this.onPitchChanged,
    this.onPitchCorrectionChanged,
  });

  @override
  State<_PlaybackSpeedSheet> createState() => _PlaybackSpeedSheetState();
}

class _PlaybackSpeedSheetState extends State<_PlaybackSpeedSheet> {
  late double _rate;
  late double _pitch;
  late bool _pitchCorrection;

  Color get primaryColor => AppThemeService.instance.currentData.primary;

  final List<double> _speedPresets = [0.5, 0.75, 1.0, 1.25, 1.5, 1.75, 2.0];
  final List<int> _semitonePresets = [-4, -2, 0, 2, 4];

  @override
  void initState() {
    super.initState();
    _rate = widget.initialRate;
    _pitch = widget.initialPitch;
    _pitchCorrection = widget.initialPitchCorrection;
  }

  void _updateRate(double newRate) {
    final clamped = newRate.clamp(0.25, 3.0);
    setState(() {
      _rate = clamped;
    });
    widget.player.setRate(clamped);
    AppStateService.instance.savePlaybackRate(clamped);
    widget.onRateChanged?.call(clamped);
  }

  void _updatePitch(double newPitch) {
    final clamped = newPitch.clamp(0.5, 1.5);
    setState(() {
      _pitch = clamped;
    });
    widget.player.setPitch(clamped);
    AppStateService.instance.savePlaybackPitch(clamped);
    widget.onPitchChanged?.call(clamped);
  }

  void _updatePitchCorrection(bool enabled) {
    setState(() {
      _pitchCorrection = enabled;
    });
    widget.player.setPitchCorrection(enabled);
    AppStateService.instance.savePitchCorrection(enabled);
    widget.onPitchCorrectionChanged?.call(enabled);
  }

  void _setPitchSemitones(int semitones) {
    final newPitch = math.pow(2.0, semitones / 12.0).toDouble();
    _updatePitch(newPitch);
  }

  int get _currentSemitones {
    if ((_pitch - 1.0).abs() < 0.005) return 0;
    return (12.0 * (math.log(_pitch) / math.ln2)).round();
  }

  void _resetAll() {
    _updateRate(1.0);
    _updatePitch(1.0);
    _updatePitchCorrection(true);
  }

  @override
  Widget build(BuildContext context) {
    final isDefault = (_rate - 1.0).abs() < 0.01 &&
        (_pitch - 1.0).abs() < 0.01 &&
        _pitchCorrection;

    return Padding(
      padding: const EdgeInsets.fromLTRB(24.0, 16.0, 24.0, 32.0),
      child: SingleChildScrollView(
        physics: const BouncingScrollPhysics(),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // ── Drag Handle ──────────────────────────────────────────────────
            Center(
              child: Container(
                width: 36,
                height: 4,
                margin: const EdgeInsets.only(bottom: 16),
                decoration: BoxDecoration(
                  color: Colors.white24,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),

            // ── Header ───────────────────────────────────────────────────────
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Row(
                  children: [
                    Container(
                      padding: const EdgeInsets.all(10),
                      decoration: BoxDecoration(
                        color: primaryColor.withValues(alpha: 0.2),
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: Icon(Icons.speed_rounded,
                          color: primaryColor, size: 22),
                    ),
                    const SizedBox(width: 12),
                    Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'SPEED & PITCH',
                          style: TextStyle(
                            fontSize: 11,
                            fontWeight: FontWeight.bold,
                            letterSpacing: 1.2,
                            color: primaryColor,
                          ),
                        ),
                        const SizedBox(height: 2),
                        Row(
                          children: [
                            Text(
                              '${_rate.toStringAsFixed(2)}x Speed',
                              style: const TextStyle(
                                fontSize: 18,
                                fontWeight: FontWeight.bold,
                                color: Colors.white,
                              ),
                            ),
                            if ((_pitch - 1.0).abs() >= 0.01) ...[
                              const SizedBox(width: 8),
                              Container(
                                padding: const EdgeInsets.symmetric(
                                    horizontal: 6, vertical: 2),
                                decoration: BoxDecoration(
                                  color: Colors.white.withValues(alpha: 0.12),
                                  borderRadius: BorderRadius.circular(6),
                                ),
                                child: Text(
                                  '${_currentSemitones >= 0 ? '+' : ''}$_currentSemitones st',
                                  style: const TextStyle(
                                    fontSize: 11,
                                    fontWeight: FontWeight.bold,
                                    color: Colors.white70,
                                  ),
                                ),
                              ),
                            ],
                          ],
                        ),
                      ],
                    ),
                  ],
                ),
                if (!isDefault)
                  TextButton.icon(
                    onPressed: _resetAll,
                    icon: const Icon(Icons.refresh,
                        size: 16, color: Colors.white70),
                    label: const Text('Reset',
                        style: TextStyle(color: Colors.white70)),
                    style: TextButton.styleFrom(
                      backgroundColor: Colors.white.withValues(alpha: 0.08),
                      shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(20)),
                    ),
                  ),
              ],
            ),

            const SizedBox(height: 20),
            const Divider(color: Colors.white12),
            const SizedBox(height: 16),

            // ── Section 1: Playback Speed (Rate) ─────────────────────────────
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                const Text(
                  'PLAYBACK SPEED',
                  style: TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.bold,
                    letterSpacing: 1.0,
                    color: Colors.white70,
                  ),
                ),
                Text(
                  '${_rate.toStringAsFixed(2)}x',
                  style: TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.bold,
                    color: primaryColor,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),

            // Speed Presets
            SizedBox(
              height: 36,
              child: ListView.separated(
                scrollDirection: Axis.horizontal,
                physics: const BouncingScrollPhysics(),
                itemCount: _speedPresets.length,
                separatorBuilder: (_, __) => const SizedBox(width: 8),
                itemBuilder: (context, index) {
                  final preset = _speedPresets[index];
                  final isSelected = (_rate - preset).abs() < 0.02;
                  return GestureDetector(
                    onTap: () => _updateRate(preset),
                    child: AnimatedContainer(
                      duration: const Duration(milliseconds: 150),
                      padding: const EdgeInsets.symmetric(horizontal: 14),
                      alignment: Alignment.center,
                      decoration: BoxDecoration(
                        color: isSelected
                            ? primaryColor
                            : Colors.white.withValues(alpha: 0.06),
                        borderRadius: BorderRadius.circular(18),
                        border: Border.all(
                          color: isSelected
                              ? primaryColor
                              : Colors.white.withValues(alpha: 0.1),
                        ),
                        boxShadow: isSelected
                            ? [
                                BoxShadow(
                                  color: primaryColor.withValues(alpha: 0.35),
                                  blurRadius: 8,
                                  offset: const Offset(0, 2),
                                )
                              ]
                            : null,
                      ),
                      child: Text(
                        preset == 1.0 ? '1.0x Normal' : '${preset}x',
                        style: TextStyle(
                          color: isSelected ? Colors.white : Colors.white70,
                          fontSize: 12,
                          fontWeight:
                              isSelected ? FontWeight.bold : FontWeight.w500,
                        ),
                      ),
                    ),
                  );
                },
              ),
            ),
            const SizedBox(height: 12),

            // Speed Slider
            M3ESlider(
              value: _rate.clamp(0.25, 3.0),
              min: 0.25,
              max: 3.0,
              divisions: 55, // 0.05 step
              onChanged: _updateRate,
            ),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: const [
                Text('0.25x',
                    style: TextStyle(fontSize: 11, color: Colors.white38)),
                Text('1.0x',
                    style: TextStyle(fontSize: 11, color: Colors.white38)),
                Text('3.0x',
                    style: TextStyle(fontSize: 11, color: Colors.white38)),
              ],
            ),

            const SizedBox(height: 20),

            // ── Section 2: Pitch Correction (Scaletempo) ─────────────────────
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
              decoration: BoxDecoration(
                color: Colors.white.withValues(alpha: 0.04),
                borderRadius: BorderRadius.circular(16),
                border: Border.all(
                  color: _pitchCorrection
                      ? primaryColor.withValues(alpha: 0.3)
                      : Colors.white.withValues(alpha: 0.08),
                ),
              ),
              child: Row(
                children: [
                  Container(
                    padding: const EdgeInsets.all(8),
                    decoration: BoxDecoration(
                      color: (_pitchCorrection ? primaryColor : Colors.white24)
                          .withValues(alpha: 0.15),
                      shape: BoxShape.circle,
                    ),
                    child: Icon(
                      Icons.graphic_eq_rounded,
                      color: _pitchCorrection ? primaryColor : Colors.white38,
                      size: 20,
                    ),
                  ),
                  const SizedBox(width: 14),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            const Text(
                              'Pitch Correction',
                              style: TextStyle(
                                fontSize: 13,
                                fontWeight: FontWeight.bold,
                                color: Colors.white,
                              ),
                            ),
                            const SizedBox(width: 6),
                            /*Container(
                              padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
                              decoration: BoxDecoration(
                                color: primaryColor.withValues(alpha: 0.2),
                                borderRadius: BorderRadius.circular(4),
                              ),
                              child: Text(
                                'Scaletempo WSOLA',
                                style: TextStyle(
                                  fontSize: 9,
                                  fontWeight: FontWeight.bold,
                                  color: primaryColor,
                                ),
                              ),
                            ),*/
                          ],
                        ),
                        const SizedBox(height: 2),
                        Text(
                          _pitchCorrection
                              ? 'Preserves original musical pitch'
                              : 'Pitch changes with speed',
                          style: TextStyle(
                            fontSize: 11,
                            color: Colors.white.withValues(alpha: 0.6),
                          ),
                        ),
                      ],
                    ),
                  ),
                  Switch.adaptive(
                    value: _pitchCorrection,
                    activeTrackColor: primaryColor,
                    onChanged: _updatePitchCorrection,
                  ),
                ],
              ),
            ),

            const SizedBox(height: 24),

            // ── Section 3: Independent Pitch Shift ───────────────────────────
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      'INDEPENDENT PITCH SHIFT',
                      style: TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.bold,
                        letterSpacing: 1.0,
                        color: Colors.white70,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      'Transposes audio without altering tempo',
                      style: TextStyle(
                        fontSize: 10,
                        color: Colors.white.withValues(alpha: 0.5),
                      ),
                    ),
                  ],
                ),
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                  decoration: BoxDecoration(
                    color: (_pitch - 1.0).abs() >= 0.01
                        ? primaryColor.withValues(alpha: 0.2)
                        : Colors.white.withValues(alpha: 0.06),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Text(
                    '${_pitch.toStringAsFixed(2)}x (${_currentSemitones >= 0 ? '+' : ''}$_currentSemitones st)',
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.bold,
                      color: (_pitch - 1.0).abs() >= 0.01
                          ? primaryColor
                          : Colors.white60,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),

            // Semitone Presets
            SizedBox(
              height: 34,
              child: Row(
                children: _semitonePresets.map((st) {
                  final targetP = math.pow(2.0, st / 12.0).toDouble();
                  final isSelected = (_pitch - targetP).abs() < 0.02;
                  return Expanded(
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 3.0),
                      child: GestureDetector(
                        onTap: () => _setPitchSemitones(st),
                        child: AnimatedContainer(
                          duration: const Duration(milliseconds: 150),
                          alignment: Alignment.center,
                          decoration: BoxDecoration(
                            color: isSelected
                                ? primaryColor
                                : Colors.white.withValues(alpha: 0.06),
                            borderRadius: BorderRadius.circular(10),
                            border: Border.all(
                              color: isSelected
                                  ? primaryColor
                                  : Colors.white.withValues(alpha: 0.08),
                            ),
                          ),
                          child: Text(
                            st == 0 ? 'Normal' : '${st >= 0 ? '+' : ''}$st st',
                            style: TextStyle(
                              color: isSelected ? Colors.white : Colors.white70,
                              fontSize: 11,
                              fontWeight: isSelected
                                  ? FontWeight.bold
                                  : FontWeight.w500,
                            ),
                          ),
                        ),
                      ),
                    ),
                  );
                }).toList(),
              ),
            ),
            const SizedBox(height: 12),

            // Pitch Slider
            M3ESlider(
              value: _pitch.clamp(0.5, 1.5),
              min: 0.5,
              max: 1.5,
              divisions: 40,
              onChanged: _updatePitch,
            ),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: const [
                Text('0.5x (-12 st)',
                    style: TextStyle(fontSize: 11, color: Colors.white38)),
                Text('1.0x (Original)',
                    style: TextStyle(fontSize: 11, color: Colors.white38)),
                Text('1.5x (+7 st)',
                    style: TextStyle(fontSize: 11, color: Colors.white38)),
              ],
            ),

            const SizedBox(height: 16),
          ],
        ),
      ),
    );
  }
}
