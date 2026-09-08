import 'dart:math' as math;
import 'dart:typed_data';
import 'package:sautiflow/sautiflow.dart' show FftWindowType;

/// Real-time Audio Spectrum Processor using Radix-2 Cooley-Tukey FFT,
/// configurable FFT windowing (Hann, Hamming, Blackman-Harris, Flat-Top),
/// decibel magnitude normalization, and logarithmic frequency binning
/// across all audible frequencies (20 Hz to 20,000 Hz).
class FftProcessor {
  final int fftSize;
  final int sampleRate;
  FftWindowType _windowType;
  FftWindowType get windowType => _windowType;

  late Float32List _windowTable;
  late final Uint16List _bitReverseTable;
  late final Float32List _cosTable;
  late final Float32List _sinTable;

  late Float32List _real;
  late Float32List _imag;
  late Float32List _magnitudes;
  Float32List? _smoothedBins;

  FftProcessor({
    this.fftSize = 512,
    this.sampleRate = 48000,
    FftWindowType windowType = FftWindowType.hann,
  }) : _windowType = windowType {
    // Assert power of two
    assert((fftSize & (fftSize - 1)) == 0, 'fftSize must be a power of 2');

    _real = Float32List(fftSize);
    _imag = Float32List(fftSize);
    _magnitudes = Float32List(fftSize ~/ 2);

    // Precalculate Window Table
    _computeWindowTable();

    // Precalculate Bit Reversal Table
    final bits = (math.log(fftSize) / math.ln2).round();
    _bitReverseTable = Uint16List(fftSize);
    for (int i = 0; i < fftSize; i++) {
      int rev = 0;
      for (int b = 0; b < bits; b++) {
        if ((i & (1 << b)) != 0) {
          rev |= 1 << (bits - 1 - b);
        }
      }
      _bitReverseTable[i] = rev;
    }

    // Precalculate Trigonometric Lookup Tables
    _cosTable = Float32List(fftSize ~/ 2);
    _sinTable = Float32List(fftSize ~/ 2);
    for (int i = 0; i < fftSize ~/ 2; i++) {
      final angle = -2.0 * math.pi * i / fftSize;
      _cosTable[i] = math.cos(angle);
      _sinTable[i] = math.sin(angle);
    }
  }

  /// Change active FFT window function dynamically.
  void setWindowType(FftWindowType windowType) {
    if (_windowType == windowType) return;
    _windowType = windowType;
    _computeWindowTable();
  }

  void _computeWindowTable() {
    final n = fftSize;
    _windowTable = Float32List(n);
    if (n <= 1) {
      if (n == 1) _windowTable[0] = 1.0;
      return;
    }
    final twoPi = 2.0 * math.pi;
    final invN = 1.0 / (n - 1);
    for (int i = 0; i < n; i++) {
      final x = twoPi * i * invN;
      switch (_windowType) {
        case FftWindowType.hamming:
          _windowTable[i] = 0.54 - 0.46 * math.cos(x);
          break;
        case FftWindowType.blackmanHarris:
          _windowTable[i] = 0.35875 -
              0.48829 * math.cos(x) +
              0.14128 * math.cos(2.0 * x) -
              0.01168 * math.cos(3.0 * x);
          break;
        case FftWindowType.flatTop:
          _windowTable[i] = 0.21557895 -
              0.41663158 * math.cos(x) +
              0.277263158 * math.cos(2.0 * x) -
              0.083578947 * math.cos(3.0 * x) +
              0.006947368 * math.cos(4.0 * x);
          break;
        case FftWindowType.hann:
        default:
          _windowTable[i] = 0.5 * (1.0 - math.cos(x));
          break;
      }
    }
  }

  /// Reset smoothed states
  void reset() {
    _smoothedBins?.fillRange(0, _smoothedBins!.length, 0.0);
  }

  /// Process raw time-domain PCM samples into [targetBins] logarithmic frequency spectrum values.
  ///
  /// Returns a list of values normalized between 0.0 and 1.0 representing
  /// frequencies across the entire spectrum (20 Hz to 20,000 Hz).
  List<double> processFrame(Float32List pcmSamples, {int targetBins = 96, double decayFactor = 0.82}) {
    if (pcmSamples.isEmpty) return List<double>.filled(targetBins, 0.0);

    if (_smoothedBins == null || _smoothedBins!.length != targetBins) {
      _smoothedBins = Float32List(targetBins);
    }
    final smoothed = _smoothedBins!;

    final n = fftSize;
    final halfN = n ~/ 2;

    // 1. Fill input buffer with windowed PCM samples
    final inputLen = math.min(pcmSamples.length, n);
    for (int i = 0; i < n; i++) {
      final rev = _bitReverseTable[i];
      if (i < inputLen) {
        _real[rev] = pcmSamples[i] * _windowTable[i];
      } else {
        _real[rev] = 0.0;
      }
      _imag[rev] = 0.0;
    }

    // 2. In-place Cooley-Tukey Radix-2 FFT
    int step = 1;
    while (step < n) {
      final jump = step << 1;
      final stepInc = n ~/ jump;
      for (int i = 0; i < step; i++) {
        final tableIdx = i * stepInc;
        final wr = _cosTable[tableIdx];
        final wi = _sinTable[tableIdx];

        for (int j = i; j < n; j += jump) {
          final k = j + step;
          final tr = wr * _real[k] - wi * _imag[k];
          final ti = wr * _imag[k] + wi * _real[k];

          _real[k] = _real[j] - tr;
          _imag[k] = _imag[j] - ti;
          _real[j] = _real[j] + tr;
          _imag[j] = _imag[j] + ti;
        }
      }
      step = jump;
    }

    // 3. Calculate Normalized Magnitude Spectrum with Window Coherent Gain
    final normFactor = _windowType.coherentGainFactor / n;
    for (int i = 0; i < halfN; i++) {
      final r = _real[i];
      final im = _imag[i];
      _magnitudes[i] = math.sqrt(r * r + im * im) * normFactor;
    }

    // 4. Logarithmic Frequency Binning across all frequencies (20 Hz - 20,000 Hz)
    final double minFreq = 20.0;
    final double maxFreq = math.min(20000.0, sampleRate / 2.0);
    final double hzPerBin = sampleRate / n;

    final output = List<double>.filled(targetBins, 0.0);

    for (int i = 0; i < targetBins; i++) {
      // Calculate start and end frequency for logarithmic bin i
      final fLow = minFreq * math.pow(maxFreq / minFreq, i / targetBins);
      final fHigh = minFreq * math.pow(maxFreq / minFreq, (i + 1) / targetBins);

      int binStart = (fLow / hzPerBin).floor().clamp(0, halfN - 1);
      int binEnd = (fHigh / hzPerBin).ceil().clamp(0, halfN - 1);
      if (binEnd <= binStart) binEnd = binStart + 1;

      double maxMag = 0.0;
      double sumMag = 0.0;
      int count = 0;

      for (int k = binStart; k < binEnd && k < halfN; k++) {
        final mag = _magnitudes[k];
        if (mag > maxMag) maxMag = mag;
        sumMag += mag;
        count++;
      }

      // 5. Frequency-dependent tilt & boost (Pink Noise / Equal Loudness Compensation)
      // Music naturally loses amplitude at higher frequencies (~-6dB/octave).
      // We apply an equalizer tilt curve so high frequencies (hi-hats, cymbals, vocal air)
      // are elevated to display vibrantly alongside bass and mid-range frequencies.
      final centerFreq = math.sqrt(fLow * fHigh);
      final freqBoost = 0.8 + 0.85 * (math.log(centerFreq / 20.0) / math.ln10);

      final avgMag = count > 0 ? sumMag / count : 0.0;
      final combinedMag = (maxMag * 0.7) + (avgMag * 0.3);
      final boostedMag = combinedMag * freqBoost;

      // 6. Logarithmic Decibel (dB) Normalization (-45 dB floor to 0 dB ceiling)
      final double dB = 20.0 * (math.log(boostedMag + 1e-4) / math.ln10);
      double scaledVal = ((dB + 45.0) / 45.0).clamp(0.0, 1.0);

      // 7. Exponential attack and smooth decay
      if (scaledVal >= smoothed[i]) {
        // Fast attack
        smoothed[i] = scaledVal;
      } else {
        // Smooth decay
        smoothed[i] = math.max(0.0, smoothed[i] * decayFactor);
      }

      output[i] = smoothed[i];
    }

    return output;
  }
}
