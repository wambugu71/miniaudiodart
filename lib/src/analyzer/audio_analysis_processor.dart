import 'dart:math' as math;
import 'dart:typed_data';
import '../../audio_engine_ffi.dart' show FftWindowType;
export '../../audio_engine_ffi.dart' show FftWindowType;

/// Immutable snapshot of real-time audio analysis (RMS and Spectrum).
class AudioAnalysisData {
  /// Root Mean Square level in dBFS (typically -60.0 to 0.0 dBFS).
  final double rmsDb;

  /// Peak sample level in dBFS (typically -60.0 to 0.0 dBFS).
  final double peakDb;

  /// Linear RMS magnitude [0.0 - 1.0].
  final double rmsLinear;

  /// Linear Peak magnitude [0.0 - 1.0].
  final double peakLinear;

  /// True if any sample in the frame clipped (> 1.0 or < -1.0).
  final bool isClipped;

  /// Normalized frequency band magnitudes [0.0 - 1.0] (logarithmically grouped).
  final Float32List bands;

  /// Peak hold positions for each frequency band [0.0 - 1.0].
  final Float32List peakHoldBands;

  const AudioAnalysisData({
    required this.rmsDb,
    required this.peakDb,
    required this.rmsLinear,
    required this.peakLinear,
    required this.isClipped,
    required this.bands,
    required this.peakHoldBands,
  });

  factory AudioAnalysisData.empty(int numBands) {
    return AudioAnalysisData(
      rmsDb: -60.0,
      peakDb: -60.0,
      rmsLinear: 0.0,
      peakLinear: 0.0,
      isClipped: false,
      bands: Float32List(numBands),
      peakHoldBands: Float32List(numBands),
    );
  }
}

/// High-performance audio DSP processor for FFT and RMS analysis.
class AudioAnalysisProcessor {
  final int numBands;
  final int sampleRate;
  final double minFrequency;
  final double maxFrequency;
  final double attackFactor;
  final double decayFactor;
  final double peakHoldDecay;

  late final Float32List _smoothedBands;
  late final Float32List _peakHoldBands;
  late final Int64List _peakHoldUntilMs;

  FftWindowType _windowType;
  FftWindowType get windowType => _windowType;

  // Precomputed FFT tables
  int _fftSize = 0;
  late Float32List _window;
  late Float32List _real;
  late Float32List _imag;
  late Int32List _bitReverse;
  late Float32List _cosTable;
  late Float32List _sinTable;

  AudioAnalysisProcessor({
    this.numBands = 32,
    this.sampleRate = 48000,
    this.minFrequency = 20.0,
    this.maxFrequency = 20000.0,
    this.attackFactor = 0.65,
    this.decayFactor = 0.15,
    this.peakHoldDecay = 0.02,
    this.peakHoldDurationMs = 250,
    this.useEqualLoudnessWeighting = true,
    FftWindowType windowType = FftWindowType.hann,
  }) : _windowType = windowType {
    _smoothedBands = Float32List(numBands);
    _peakHoldBands = Float32List(numBands);
    _peakHoldUntilMs = Int64List(numBands);
  }

  /// Change active FFT window function dynamically.
  void setWindowType(FftWindowType type) {
    if (_windowType == type) return;
    _windowType = type;
    if (_fftSize > 0) {
      _computeWindowTable(_fftSize);
    }
  }

  final int peakHoldDurationMs;
  final bool useEqualLoudnessWeighting;

  /// Psychoacoustic A-weighting approximation for equal-loudness spectral balancing.
  static double _getEqualLoudnessFactor(double fHz) {
    if (fHz < 10.0) return 0.2;
    final f2 = fHz * fHz;
    final num = 1.2588966e8 * f2 * f2;
    final den = (f2 + 424.36) * math.sqrt((f2 + 11599.29) * (f2 + 544496.41)) * (f2 + 148699001.44);
    final aWeightLin = num / den;
    return (0.5 + 0.5 * aWeightLin).clamp(0.25, 1.5);
  }

  /// Reset internal smoothing buffers.
  void reset() {
    _smoothedBands.fillRange(0, numBands, 0.0);
    _peakHoldBands.fillRange(0, numBands, 0.0);
    _peakHoldUntilMs.fillRange(0, numBands, 0);
  }

  /// Process a raw PCM float sample frame into [AudioAnalysisData].
  AudioAnalysisData processFrame(Float32List pcmSamples) {
    if (pcmSamples.isEmpty) {
      return AudioAnalysisData.empty(numBands);
    }

    final len = pcmSamples.length;

    // 1. RMS and Peak Calculation
    double sumSquares = 0.0;
    double maxAbs = 0.0;
    bool clipped = false;

    for (int i = 0; i < len; i++) {
      final sample = pcmSamples[i];
      final absSample = sample.abs();
      if (absSample > maxAbs) maxAbs = absSample;
      if (absSample >= 0.999) clipped = true;
      sumSquares += sample * sample;
    }

    final rmsLinear = math.sqrt(sumSquares / len);
    final rmsDb = _linearToDb(rmsLinear);
    final peakDb = _linearToDb(maxAbs);

    // 2. Prepare FFT size (power of 2)
    final fftSize = _nextPowerOf2(len);
    if (fftSize != _fftSize) {
      _initFftTables(fftSize);
    }

    // 3. Apply Window and Copy into FFT Real Buffer
    for (int i = 0; i < fftSize; i++) {
      if (i < len) {
        _real[i] = pcmSamples[i] * _window[i];
      } else {
        _real[i] = 0.0; // Zero padding if frame < fftSize
      }
      _imag[i] = 0.0;
    }

    // 4. Perform Radix-2 In-place FFT
    _executeFft();

    // 5. Calculate Magnitudes for positive frequencies (0 to N/2)
    final numBins = _fftSize ~/ 2;
    final binWidth = sampleRate / _fftSize;
    final normFactor = _windowType.coherentGainFactor / _fftSize;

    // 6. Map FFT Bins to Logarithmic Frequency Bands
    final bandValues = Float32List(numBands);
    final peakHoldValues = Float32List(numBands);
    final nowMs = DateTime.now().millisecondsSinceEpoch;

    for (int b = 0; b < numBands; b++) {
      final fStart = minFrequency * math.pow(maxFrequency / minFrequency, b / numBands);
      final fEnd = minFrequency * math.pow(maxFrequency / minFrequency, (b + 1) / numBands);

      int binStart = (fStart / binWidth).floor().clamp(0, numBins - 1);
      int binEnd = (fEnd / binWidth).ceil().clamp(binStart + 1, numBins);

      double maxMagInBand = 0.0;
      double sumMagInBand = 0.0;
      int count = 0;

      for (int bin = binStart; bin < binEnd; bin++) {
        final re = _real[bin];
        final im = _imag[bin];
        // Normalized FFT magnitude using window-specific coherent gain
        final mag = math.sqrt(re * re + im * im) * normFactor;
        if (mag > maxMagInBand) maxMagInBand = mag;
        sumMagInBand += mag;
        count++;
      }

      // Hybrid average & peak magnitude for natural visual balance
      final avgMag = count > 0 ? sumMagInBand / count : 0.0;
      final rawBandVal = (maxMagInBand * 0.7 + avgMag * 0.3);

      final centerFreq = math.sqrt(fStart * fEnd);
      final weightFactor = useEqualLoudnessWeighting
          ? _getEqualLoudnessFactor(centerFreq)
          : 1.0;
      final scaledVal = (rawBandVal * weightFactor).clamp(0.0, 1.0);

      // 7. Temporal Ballistics (Attack / Decay)
      final prevSmoothed = _smoothedBands[b];
      if (scaledVal > prevSmoothed) {
        _smoothedBands[b] = prevSmoothed + (scaledVal - prevSmoothed) * attackFactor;
      } else {
        _smoothedBands[b] = prevSmoothed + (scaledVal - prevSmoothed) * decayFactor;
      }

      bandValues[b] = _smoothedBands[b].clamp(0.0, 1.0);

      // 8. Time-Based Peak Hold Logic (Independent of frame rate)
      if (_smoothedBands[b] >= _peakHoldBands[b]) {
        _peakHoldBands[b] = _smoothedBands[b];
        _peakHoldUntilMs[b] = nowMs + peakHoldDurationMs;
      } else {
        if (nowMs >= _peakHoldUntilMs[b]) {
          _peakHoldBands[b] = (_peakHoldBands[b] - peakHoldDecay).clamp(0.0, 1.0);
        }
      }
      peakHoldValues[b] = _peakHoldBands[b];
    }

    return AudioAnalysisData(
      rmsDb: rmsDb,
      peakDb: peakDb,
      rmsLinear: rmsLinear,
      peakLinear: maxAbs,
      isClipped: clipped,
      bands: bandValues,
      peakHoldBands: peakHoldValues,
    );
  }

  static double _linearToDb(double linear) {
    if (linear <= 0.00001) return -60.0;
    final db = 20.0 * (math.log(linear) / math.ln10);
    return db.clamp(-60.0, 0.0);
  }

  static int _nextPowerOf2(int n) {
    int p = 1;
    while (p < n) {
      p <<= 1;
    }
    return p < 64 ? 64 : p;
  }

  void _initFftTables(int fftSize) {
    _fftSize = fftSize;
    _real = Float32List(fftSize);
    _imag = Float32List(fftSize);
    _bitReverse = Int32List(fftSize);
    _cosTable = Float32List(fftSize ~/ 2);
    _sinTable = Float32List(fftSize ~/ 2);

    _computeWindowTable(fftSize);

    // Precompute Bit-Reversal Table
    int bits = (math.log(fftSize) / math.ln2).round();
    for (int i = 0; i < fftSize; i++) {
      int rev = 0;
      for (int b = 0; b < bits; b++) {
        if ((i & (1 << b)) != 0) {
          rev |= 1 << (bits - 1 - b);
        }
      }
      _bitReverse[i] = rev;
    }

    // Precompute Twiddle Factors
    for (int i = 0; i < fftSize ~/ 2; i++) {
      final angle = -2.0 * math.pi * i / fftSize;
      _cosTable[i] = math.cos(angle);
      _sinTable[i] = math.sin(angle);
    }
  }

  void _computeWindowTable(int fftSize) {
    _window = Float32List(fftSize);
    if (fftSize <= 1) {
      if (fftSize == 1) _window[0] = 1.0;
      return;
    }
    final twoPi = 2.0 * math.pi;
    final invN = 1.0 / (fftSize - 1);
    for (int i = 0; i < fftSize; i++) {
      final x = twoPi * i * invN;
      switch (_windowType) {
        case FftWindowType.hamming:
          _window[i] = 0.54 - 0.46 * math.cos(x);
          break;
        case FftWindowType.blackmanHarris:
          _window[i] = 0.35875 -
              0.48829 * math.cos(x) +
              0.14128 * math.cos(2.0 * math.pi * 2.0 * i * invN) -
              0.01168 * math.cos(2.0 * math.pi * 3.0 * i * invN);
          break;
        case FftWindowType.flatTop:
          _window[i] = 0.21557895 -
              0.41663158 * math.cos(x) +
              0.277263158 * math.cos(2.0 * math.pi * 2.0 * i * invN) -
              0.083578947 * math.cos(2.0 * math.pi * 3.0 * i * invN) +
              0.006947368 * math.cos(2.0 * math.pi * 4.0 * i * invN);
          break;
        case FftWindowType.hann:
        default:
          _window[i] = 0.5 * (1.0 - math.cos(x));
          break;
      }
    }
  }

  void _executeFft() {
    final n = _fftSize;

    // Bit reversal permutation
    for (int i = 0; i < n; i++) {
      final j = _bitReverse[i];
      if (j > i) {
        final tempR = _real[i];
        final tempI = _imag[i];
        _real[i] = _real[j];
        _imag[i] = _imag[j];
        _real[j] = tempR;
        _imag[j] = tempI;
      }
    }

    // Cooley-Tukey Radix-2 decimation in time
    for (int len = 2; len <= n; len <<= 1) {
      final halfLen = len >> 1;
      final step = n ~/ len;

      for (int i = 0; i < n; i += len) {
        for (int j = 0; j < halfLen; j++) {
          final k = j * step;
          final cos = _cosTable[k];
          final sin = _sinTable[k];

          final uR = _real[i + j];
          final uI = _imag[i + j];

          final vR = _real[i + j + halfLen] * cos - _imag[i + j + halfLen] * sin;
          final vI = _real[i + j + halfLen] * sin + _imag[i + j + halfLen] * cos;

          _real[i + j] = uR + vR;
          _imag[i + j] = uI + vI;

          _real[i + j + halfLen] = uR - vR;
          _imag[i + j + halfLen] = uI - vI;
        }
      }
    }
  }
}
