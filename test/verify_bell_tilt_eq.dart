import '../lib/audio_engine_ffi.dart';

void main() {
  print('=== Testing Bell & Tilt Parametric EQ in Engine ===');

  final engine = AudioEngineFFI(libraryPath: 'audio_engine.dll');
  final created = engine.create(sampleRate: 48000, channels: 2);
  print('AudioEngine created: $created');
  if (!created) {
    throw Exception('Failed to create AudioEngine!');
  }

  // Define mixed bands including Low Shelf, Peak, High Shelf, Bell, and Tilt
  final bands = [
    const EqBandConfig(
      type: EqBandType.lowshelf,
      frequencyHz: 100.0,
      gainDb: 3.0,
      slope: 1.0,
    ),
    const EqBandConfig(
      type: EqBandType.peak,
      frequencyHz: 1000.0,
      gainDb: -2.0,
      q: 1.2,
    ),
    const EqBandConfig(
      type: EqBandType.bell,
      frequencyHz: 3000.0,
      gainDb: 4.5,
      q: 2.0,
    ),
    const EqBandConfig(
      type: EqBandType.tilt,
      frequencyHz: 1000.0,
      gainDb: 6.0,
      slope: 1.0,
    ),
    const EqBandConfig(
      type: EqBandType.highshelf,
      frequencyHz: 10000.0,
      gainDb: 2.0,
      slope: 1.0,
    ),
  ];

  print('Applying ${bands.length} multiband FX bands (including Bell and Tilt)...');
  engine.setMultibandFxBands(bands);
  engine.setMultibandFxEnabled(true);
  print('Multiband FX enabled with Bell and Tilt.');

  // Update Tilt band to negative gain (bass boost / treble cut)
  final updatedBands = [
    const EqBandConfig(
      type: EqBandType.bell,
      frequencyHz: 2500.0,
      gainDb: -3.0,
      q: 1.5,
    ),
    const EqBandConfig(
      type: EqBandType.tilt,
      frequencyHz: 1200.0,
      gainDb: -5.0,
      slope: 1.2,
    ),
  ];
  print('Updating to 2 bands with Bell and negative Tilt...');
  engine.setMultibandFxBands(updatedBands);

  print('Clearing multiband FX...');
  engine.clearMultibandFx();

  engine.dispose();
  print('=== Bell & Tilt Parametric EQ Tests Passed Successfully! ===');
}
