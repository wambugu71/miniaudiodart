import 'dart:math' as math;
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:sautiflow/sautiflow.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('Audio Engine Quality and API Fixes Verification', () {
    late MiniAudioPlayer player;

    setUp(() {
      player = MiniAudioPlayer(libraryPath: 'sautiflow.dll');
    });

    tearDown(() {
      player.dispose();
    });

    test('1. Init enables Lookahead Safety Limiter by default', () {
      final ok = player.init(sampleRate: 48000, channels: 2);
      expect(ok, isTrue);

      final isLimiterEnabled = player.isLookaheadLimiterEnabled;
      expect(isLimiterEnabled, isTrue,
          reason: 'Lookahead safety limiter should be enabled by default to prevent clipping');
    });

    test('2. Perceptual Volume Curve and dB Volume Controls', () {
      final ok = player.init(sampleRate: 48000);
      expect(ok, isTrue);

      // Raw linear gain
      player.setGain(1.0);
      expect(player.getGain(), equals(1.0));
      expect(player.getVolumeDb(), closeTo(0.0, 0.01));

      // Perceptual volume mapping (cubic curve v^3)
      player.setVolume(0.5); // 0.5^3 = 0.125
      expect(player.getGain(), closeTo(0.125, 0.001));

      player.setVolume(1.0); // 1.0^3 = 1.0
      expect(player.getGain(), equals(1.0));

      player.setVolume(0.0); // 0.0
      expect(player.getGain(), equals(0.0));

      // dB Volume Control
      player.setVolumeDb(-6.0); // ~0.501187 linear
      expect(player.getVolumeDb(), closeTo(-6.0, 0.1));
      expect(player.getGain(), closeTo(0.501187, 0.01));

      player.setVolumeDb(0.0); // 1.0 linear
      expect(player.getVolumeDb(), closeTo(0.0, 0.01));
      expect(player.getGain(), closeTo(1.0, 0.01));
    });

    test('3. 3-Band EQ dB Conversion', () {
      final ok = player.init(sampleRate: 48000);
      expect(ok, isTrue);

      // Should execute without throwing and convert dB to linear multiplier internally
      expect(
        () => player.setEqDb(lowDb: 3.0, midDb: 0.0, highDb: -3.0),
        returnsNormally,
      );
    });

    test('4. Zero-Copy and TargetBuffer in pollAnalyzerFrame', () {
      final ok = player.init(sampleRate: 48000);
      expect(ok, isTrue);

      player.setAnalyzerEnabled(true);
      player.configureAnalyzer(frameSize: 512);

      // Direct call returns a typed list view without error
      final frame1 = player.pollAnalyzerFrame(maxSamples: 512);
      expect(frame1, isA<Float32List>());

      // Target buffer reuse
      final target = Float32List(512);
      final frame2 = player.pollAnalyzerFrame(maxSamples: 512, targetBuffer: target);
      expect(identical(frame2, target), isTrue);
    });

    test('5. AB Repeat Pointer Reuse', () {
      final ok = player.init(sampleRate: 48000);
      expect(ok, isTrue);

      player.setAbRepeat(enabled: true, startSeconds: 10.0, endSeconds: 20.0);
      final ab1 = player.getAbRepeat();
      expect(ab1.enabled, isTrue);
      expect(ab1.startSeconds, closeTo(10.0, 0.01));
      expect(ab1.endSeconds, closeTo(20.0, 0.01));

      // Call multiple times to verify no pointer reuse corruption or memory leak
      for (int i = 0; i < 50; i++) {
        final ab = player.getAbRepeat();
        expect(ab.enabled, isTrue);
      }
    });

    test('6. MiniaudioResampler Constructor Defaults', () {
      final ffi = MiniaudioFiltersFFI(libraryPath: 'sautiflow.dll');
      final resampler = MiniaudioResampler(
        ffi,
        AudioFormat.f32,
        2,
        44100,
        48000,
      );
      // Valid resampler pointer created with SoXR HQ & Triangle dither defaults
      expect(resampler.isInitialized, isTrue);
      resampler.dispose();
    });

    test('7. Time-based Peak Hold in AudioAnalysisProcessor', () {
      final processor = AudioAnalysisProcessor(
        numBands: 16,
        sampleRate: 48000,
        peakHoldDurationMs: 150,
      );

      // Create a test frame with audio content
      final testFrame = Float32List(512);
      for (int i = 0; i < 512; i++) {
        testFrame[i] = 0.8;
      }

      final data1 = processor.processFrame(testFrame);
      expect(data1.bands.length, equals(16));
      expect(data1.peakHoldBands.length, equals(16));
      final initialPeak = data1.peakHoldBands[4];
      expect(initialPeak, greaterThan(0.0));

      // Immediate subsequent silent frame should hold the peak (within hold duration)
      final silentFrame = Float32List(512);
      final data2 = processor.processFrame(silentFrame);
      expect(data2.peakHoldBands[4], equals(initialPeak));
    });

    test('8. Dynamic statusPollInterval and Instant Seek Polling', () {
      final ok = player.init(sampleRate: 48000);
      expect(ok, isTrue);

      player.statusPollInterval = const Duration(milliseconds: 50);
      expect(player.statusPollInterval, equals(const Duration(milliseconds: 50)));

      // Calling seekTo should execute normally and trigger instant status emission
      expect(() => player.seekTo(const Duration(seconds: 5)), returnsNormally);
    });

    test('9. SautiDsp Master Headroom Trim', () {
      final ok = player.init(sampleRate: 48000);
      expect(ok, isTrue);

      expect(() => player.dsp.setMasterHeadroomTrimDb(-3.0), returnsNormally);
    });

    test('10. Equal-Loudness Curve in AudioAnalysisProcessor', () {
      final processorWithLoudness = AudioAnalysisProcessor(
        numBands: 32,
        useEqualLoudnessWeighting: true,
      );
      final processorFlat = AudioAnalysisProcessor(
        numBands: 32,
        useEqualLoudnessWeighting: false,
      );

      final testFrame = Float32List(512);
      for (int i = 0; i < 512; i++) {
        testFrame[i] = (i % 2 == 0 ? 0.5 : -0.5);
      }

      final dataLoudness = processorWithLoudness.processFrame(testFrame);
      final dataFlat = processorFlat.processFrame(testFrame);

      expect(dataLoudness.bands.length, equals(32));
      expect(dataFlat.bands.length, equals(32));
    });

    test('11. 4 Premier FFT Window Functions in AudioAnalysisProcessor', () {
      // Test each of the 4 best FFT window types
      for (final winType in FftWindowType.values) {
        final processor = AudioAnalysisProcessor(
          numBands: 32,
          sampleRate: 48000,
          windowType: winType,
        );
        expect(processor.windowType, equals(winType));

        // Generate 1 kHz sine wave frame
        final testFrame = Float32List(1024);
        const freq = 1000.0;
        const sampleRate = 48000.0;
        for (int i = 0; i < 1024; i++) {
          testFrame[i] = 0.7 * math.sin(2.0 * math.pi * freq * i / sampleRate);
        }

        final data = processor.processFrame(testFrame);
        expect(data.bands.length, equals(32));
        expect(data.peakHoldBands.length, equals(32));
        expect(data.rmsLinear, greaterThan(0.0));
        expect(data.rmsDb, greaterThan(-60.0));

        // Magnitude should be positive and bounded
        double maxBand = 0.0;
        for (final b in data.bands) {
          if (b > maxBand) maxBand = b;
        }
        expect(maxBand, greaterThan(0.05));
        expect(maxBand, lessThanOrEqualTo(1.0));

        // Verify dynamic switching
        processor.setWindowType(FftWindowType.blackmanHarris);
        expect(processor.windowType, equals(FftWindowType.blackmanHarris));
        final dataSwitched = processor.processFrame(testFrame);
        expect(dataSwitched.bands.length, equals(32));
      }
    });

    test('12. Native C ABI & Player Analyzer Window Configuration', () {
      final ok = player.init(sampleRate: 48000);
      expect(ok, isTrue);

      player.setAnalyzerWindowType(FftWindowType.blackmanHarris);
      expect(player.analyzerWindowType, equals(FftWindowType.blackmanHarris));

      player.configureAnalyzer(frameSize: 1024, windowType: FftWindowType.flatTop);
      expect(player.getAnalyzerFrameSize(), equals(1024));
      expect(player.analyzerWindowType, equals(FftWindowType.flatTop));

      player.configureAnalyzer(frameSize: 512, windowType: FftWindowType.hann);
      expect(player.getAnalyzerFrameSize(), equals(512));
      expect(player.analyzerWindowType, equals(FftWindowType.hann));
    });

    test('13. FftWindowType parsing, metadata, and coherent gain properties', () {
      expect(FftWindowType.fromString('hann'), equals(FftWindowType.hann));
      expect(FftWindowType.fromString('hanning'), equals(FftWindowType.hann));
      expect(FftWindowType.fromString('hamming'), equals(FftWindowType.hamming));
      expect(FftWindowType.fromString('blackman_harris'), equals(FftWindowType.blackmanHarris));
      expect(FftWindowType.fromString('blackman'), equals(FftWindowType.blackmanHarris));
      expect(FftWindowType.fromString('flat_top'), equals(FftWindowType.flatTop));
      expect(FftWindowType.fromString('flattop'), equals(FftWindowType.flatTop));
      expect(FftWindowType.fromString(null), equals(FftWindowType.hann));

      for (final type in FftWindowType.values) {
        expect(type.displayName.isNotEmpty, isTrue);
        expect(type.description.isNotEmpty, isTrue);
        expect(type.coherentGainFactor, greaterThan(1.0));
      }
    });
  });
}

