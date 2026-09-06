import 'package:flutter_test/flutter_test.dart';
import 'package:sautiflow/sautiflow.dart';

void main() {
  test('Rate, Pitch, and Pitch Correction (Scaletempo) API Test', () async {
    final player = MiniAudioPlayer(libraryPath: 'sautiflow.dll');
    final ok = player.init(sampleRate: 48000);
    expect(ok, isTrue, reason: 'Engine should initialize successfully');

    // 1. Check defaults
    expect(player.rate, closeTo(1.0, 0.001));
    expect(player.pitch, closeTo(1.0, 0.001));
    expect(player.pitchCorrectionEnabled, isTrue);

    // 2. Set rate
    await player.setRate(1.5);
    expect(player.rate, closeTo(1.5, 0.001));

    // Rate boundary clamping
    await player.setRate(150.0);
    expect(player.rate, closeTo(100.0, 0.001));

    await player.setRate(0.001);
    expect(player.rate, closeTo(0.01, 0.001));

    // Reset rate
    await player.setRate(1.0);
    expect(player.rate, closeTo(1.0, 0.001));

    // 3. Set pitch
    await player.setPitch(0.9);
    expect(player.pitch, closeTo(0.9, 0.001));

    await player.setPitch(1.25);
    expect(player.pitch, closeTo(1.25, 0.001));

    // Pitch boundary clamping
    await player.setPitch(25.0);
    expect(player.pitch, closeTo(10.0, 0.001));

    await player.setPitch(0.01);
    expect(player.pitch, closeTo(0.05, 0.001));

    // Reset pitch
    await player.setPitch(1.0);
    expect(player.pitch, closeTo(1.0, 0.001));

    // 4. Set pitch correction (Scaletempo WSOLA)
    await player.setPitchCorrection(false);
    expect(player.pitchCorrectionEnabled, isFalse);

    await player.setPitchCorrection(true);
    expect(player.pitchCorrectionEnabled, isTrue);

    // 5. Verify pipeline state reflection
    final pipelineState = player.pipelineState;
    expect(pipelineState, isNotNull);
    expect(pipelineState.rate, closeTo(1.0, 0.001));
    expect(pipelineState.pitchCorrectionEnabled, isTrue);

    player.dispose();
  });
}
