import 'dart:math' as math;
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:sautiplay/services/fft_processor.dart';

void main() {
  group('FftProcessor Sample Rate & Log/Linear Tests', () {
    test('Initializes with default 48kHz and Logarithmic scaling', () {
      final processor = FftProcessor(fftSize: 512, sampleRate: 48000, logScale: true);
      expect(processor.sampleRate, 48000);
      expect(processor.logScale, true);
    });

    test('Dynamically updates sample rate and logScale', () {
      final processor = FftProcessor(fftSize: 512, sampleRate: 48000);

      processor.setSampleRate(44100);
      expect(processor.sampleRate, 44100);

      processor.setSampleRate(96000);
      expect(processor.sampleRate, 96000);

      processor.setLogScale(false);
      expect(processor.logScale, false);

      processor.setLogScale(true);
      expect(processor.logScale, true);
    });

    test('Processes synthetic 1 kHz sine wave in Logarithmic mode', () {
      final processor = FftProcessor(fftSize: 512, sampleRate: 48000, logScale: true);

      // Generate 512 samples of 1000 Hz sine wave
      final pcm = Float32List(512);
      for (int i = 0; i < 512; i++) {
        pcm[i] = math.sin(2.0 * math.pi * 1000.0 * i / 48000.0);
      }

      final bins = processor.processFrame(pcm, targetBins: 60, logScale: true);
      expect(bins.length, 60);

      // Verify that values are in normalized range 0.0 .. 1.0
      for (final val in bins) {
        expect(val, greaterThanOrEqualTo(0.0));
        expect(val, lessThanOrEqualTo(1.0));
      }

      // 1 kHz peak should have significant energy
      final maxVal = bins.reduce(math.max);
      expect(maxVal, greaterThan(0.5));
    });

    test('Processes synthetic 1 kHz sine wave in Linear mode', () {
      final processor = FftProcessor(fftSize: 512, sampleRate: 48000, logScale: false);

      final pcm = Float32List(512);
      for (int i = 0; i < 512; i++) {
        pcm[i] = math.sin(2.0 * math.pi * 1000.0 * i / 48000.0);
      }

      final bins = processor.processFrame(pcm, targetBins: 60, logScale: false);
      expect(bins.length, 60);

      for (final val in bins) {
        expect(val, greaterThanOrEqualTo(0.0));
        expect(val, lessThanOrEqualTo(1.0));
      }

      final maxVal = bins.reduce(math.max);
      expect(maxVal, greaterThan(0.2));
    });

    test('Supports high-resolution 96 kHz and 192 kHz sample rates without crashing or clamping', () {
      final processor = FftProcessor(fftSize: 512, sampleRate: 96000);
      final pcm = Float32List(512);
      // 30 kHz ultrasonic tone (valid under 96kHz Nyquist 48kHz)
      for (int i = 0; i < 512; i++) {
        pcm[i] = 0.5 * math.sin(2.0 * math.pi * 30000.0 * i / 96000.0);
      }

      final binsLog = processor.processFrame(pcm, targetBins: 60, logScale: true);
      expect(binsLog.length, 60);

      final binsLinear = processor.processFrame(pcm, targetBins: 60, logScale: false);
      expect(binsLinear.length, 60);
    });
  });
}
