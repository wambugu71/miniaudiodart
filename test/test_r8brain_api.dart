import 'package:flutter_test/flutter_test.dart';
import 'package:sautiflow/sautiflow.dart';

void main() {
  test('R8brain resampler API verification test', () {
    final player = MiniAudioPlayer(libraryPath: 'sautiflow.dll');
    final ok = player.init(sampleRate: 48000);
    expect(ok, isTrue, reason: 'Failed to initialize MiniAudioPlayer');

    // 1. Verify AEResampleAlgorithm enum alignment
    expect(AEResampleAlgorithm.r8brain24LinearPhase.index, equals(11));
    expect(AEResampleAlgorithm.r8brain24MinimumPhase.index, equals(12));
    expect(ResampleAlgorithm.r8brain24LinearPhase.index, equals(11));
    expect(ResampleAlgorithm.r8brain24MinimumPhase.index, equals(12));

    // 2. Test r8brain 24-bit Linear Phase (Mode 11)
    player.setEngineResampleAlgorithm(ResampleAlgorithm.r8brain24LinearPhase);
    final algo11 = player.getEngineResampleAlgorithm();
    expect(algo11, equals(ResampleAlgorithm.r8brain24LinearPhase));

    final policy11 = player.getResamplingPolicyInfo();
    expect(policy11.isLinearPhase, isTrue,
        reason: 'r8brain Linear Phase must report isLinearPhase == true');

    // 3. Test r8brain 24-bit Minimum Phase (Mode 12)
    player.setEngineResampleAlgorithm(ResampleAlgorithm.r8brain24MinimumPhase);
    final algo12 = player.getEngineResampleAlgorithm();
    expect(algo12, equals(ResampleAlgorithm.r8brain24MinimumPhase));

    final policy12 = player.getResamplingPolicyInfo();
    expect(policy12.isLinearPhase, isFalse,
        reason: 'r8brain Minimum Phase must report isLinearPhase == false');

    // 4. Verify quality telemetry is accessible
    final qt = player.getQualityTelemetry();
    expect(qt, isNotNull);

    player.dispose();
  });
}


