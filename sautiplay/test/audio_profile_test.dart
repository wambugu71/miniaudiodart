import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sautiplay/services/audio_profile_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  test('AudioProfileService returns all redefined factory profiles', () async {
    final profiles = await AudioProfileService.instance.getProfiles();
    expect(profiles.length, greaterThanOrEqualTo(7));

    final ids = profiles.map((p) => p.id).toList();
    expect(ids, contains('builtin_flat'));
    expect(ids, contains('builtin_basshead'));
    expect(ids, contains('builtin_vocal'));
    expect(ids, contains('builtin_rock'));
    expect(ids, contains('builtin_audiophile'));
    expect(ids, contains('builtin_cinema_3d'));
    expect(ids, contains('builtin_vintage'));

    final bassExtreme = profiles.firstWhere((p) => p.id == 'builtin_basshead');
    expect(bassExtreme.name, 'Bass Extreme');
    expect(bassExtreme.eqState['preampDb'], -3.0);

    // Check Sauti DSP settings
    expect(bassExtreme.sautiDspState['dynamicSystemEnabled'], true);

    // Check Parametric EQ bands in Bass Extreme
    expect(bassExtreme.eqState['parametricEnabled'], true);
    final bassPBands = bassExtreme.eqState['parametricBands'] as List;
    expect(bassPBands.length, 5);
    expect(bassPBands[0]['frequency'], 28.0); // Subsonic highpass
    expect(bassPBands[1]['frequency'], 60.0); // Sub-bass lowshelf
    expect(bassPBands[2]['frequency'], 180.0); // Sifting mud cut
    expect(bassPBands[2]['gainDb'], -2.8);

    // Check Spatial / Cinema profile has acoustic stage and parametric EQ enabled
    final spatial = profiles.firstWhere((p) => p.id == 'builtin_cinema_3d');
    expect(spatial.sautiDspState['dspMasterEnabled'], true);
    expect(spatial.sautiDspState['surroundEnabled'], true);
    expect(spatial.sautiDspState['surroundMode'], 3); // SurroundMode.acousticStage.value
    expect(spatial.eqState['parametricEnabled'], true);
    expect((spatial.eqState['parametricBands'] as List).length, 5);

    // Verify round-trip serialization
    for (final profile in profiles) {
      final json = profile.toJson();
      expect(json['id'], profile.id);
      expect(json['name'], profile.name);
    }
  });
}
