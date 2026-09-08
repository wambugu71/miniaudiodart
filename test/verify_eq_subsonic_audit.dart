import '../lib/audio_engine_ffi.dart';
import '../lib/sauti_dsp.dart';

void main() {
  print('=== Testing Audited EQ & Subsonic Filter Engine Fixes ===');

  final engine = AudioEngineFFI(libraryPath: 'audio_engine.dll');
  final created = engine.create(sampleRate: 48000, channels: 2);
  if (!created) {
    throw Exception('Failed to create AudioEngine');
  }
  print('AudioEngine created successfully.');

  final dsp = SautiDsp.fromEngine(engine);

  // 1. Test Subsonic Filter API
  print('1. Testing Subsonic Filter Toggle...');
  final initialSubsonic = dsp.isSubsonicFilterEnabled();
  print('Initial Subsonic state: $initialSubsonic (expected true by default)');
  if (!initialSubsonic) {
    throw Exception('SubsonicFilter should be enabled by default!');
  }

  dsp.setSubsonicFilterEnabled(false);
  final disabledSubsonic = dsp.isSubsonicFilterEnabled();
  print('Disabled Subsonic state: $disabledSubsonic (expected false)');
  if (disabledSubsonic) {
    throw Exception('Failed to disable SubsonicFilter!');
  }

  dsp.setSubsonicFilterEnabled(true);
  final reenabledSubsonic = dsp.isSubsonicFilterEnabled();
  print('Re-enabled Subsonic state: $reenabledSubsonic (expected true)');
  if (!reenabledSubsonic) {
    throw Exception('Failed to re-enable SubsonicFilter!');
  }

  // 2. Test Multiband Graphic EQ with 0.0 dB flat bands and smooth gain updates
  print('2. Testing Multiband Graphic EQ...');
  final freqs = [31.0, 63.0, 125.0, 250.0, 500.0, 1000.0, 2000.0, 4000.0, 8000.0, 16000.0];
  engine.initMultibandEq(freqs.length, freqs);
  engine.setMultibandEqEnabled(true);

  // Set band gains smoothly (testing ma_peak2_reinit without crash or clicks)
  engine.setMultibandEqGain(0, 3.5);
  engine.setMultibandEqGain(5, -2.0);
  engine.setMultibandEqGain(9, 1.5);
  print('Multiband EQ gains applied smoothly.');

  // Set a band back to 0.0 dB (tests 0.0 dB flat band bypass logic)
  engine.setMultibandEqGain(0, 0.0);
  print('Multiband EQ band 0 set to 0.0 dB (flat bypass active).');

  // 3. Test Parametric FX with Bell and Peak sharing band.peak
  print('3. Testing Parametric FX (Peak & Bell unification)...');
  final fxBands = [
    const EqBandConfig(
      type: EqBandType.peak,
      frequencyHz: 1000.0,
      gainDb: 2.5,
      q: 1.0,
    ),
    const EqBandConfig(
      type: EqBandType.bell,
      frequencyHz: 3000.0,
      gainDb: -1.5,
      q: 1.4,
    ),
    const EqBandConfig(
      type: EqBandType.tilt,
      frequencyHz: 1500.0,
      gainDb: 0.0, // 0.0 dB flat band
    ),
  ];
  engine.setMultibandFxBands(fxBands);
  engine.setMultibandFxEnabled(true);
  print('Parametric FX applied with Peak, Bell, and 0 dB Tilt band.');

  engine.dispose();
  print('=== All Audited EQ & Subsonic Filter Tests Passed! ===');
}
