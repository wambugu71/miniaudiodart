import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:sautiflow/sautiflow.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const MixedMultibandFxExampleApp());
}

class AppScrollBehavior extends MaterialScrollBehavior {
  const AppScrollBehavior();

  @override
  ScrollPhysics getScrollPhysics(BuildContext context) {
    return const BouncingScrollPhysics(parent: AlwaysScrollableScrollPhysics());
  }

  @override
  Set<PointerDeviceKind> get dragDevices => {
        PointerDeviceKind.touch,
        PointerDeviceKind.mouse,
        PointerDeviceKind.trackpad,
        PointerDeviceKind.stylus,
      };
}

class MixedMultibandFxExampleApp extends StatelessWidget {
  const MixedMultibandFxExampleApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'Sautiflow EQ Screen',
      scrollBehavior: const AppScrollBehavior(),
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.deepPurple),
        useMaterial3: true,
      ),
      home: const MixedMultibandFxPage(),
    );
  }
}

class MixedMultibandFxPage extends StatefulWidget {
  const MixedMultibandFxPage({super.key});

  @override
  State<MixedMultibandFxPage> createState() => _MixedMultibandFxPageState();
}

class _MixedMultibandFxPageState extends State<MixedMultibandFxPage> {
  final MiniAudioPlayer _player = MiniAudioPlayer();

  bool _initialized = false;
  bool _fxEnabled = true;
  ProcessingType _processingType = ProcessingType.mixedMultibandFx;
  String _status = 'Initializing...';

  final List<EqBandConfig> _bands = _buildTenBandMixedPreset();

  static List<EqBandConfig> _buildTenBandMixedPreset() {
    return <EqBandConfig>[
      const EqBandConfig(
        type: EqBandType.lowshelf,
        frequencyHz: 31.25,
        gainDb: 4.0,
        slope: 1.0,
      ),
      const EqBandConfig(
        type: EqBandType.peak,
        frequencyHz: 62.5,
        gainDb: 2.5,
        q: 1.2,
      ),
      const EqBandConfig(
        type: EqBandType.notch,
        frequencyHz: 125.0,
        q: 10.0,
      ),
      const EqBandConfig(
        type: EqBandType.bandpass,
        frequencyHz: 250.0,
        q: 0.9,
      ),
      const EqBandConfig(
        type: EqBandType.peak,
        frequencyHz: 500.0,
        gainDb: 1.5,
        q: 1.0,
      ),
      const EqBandConfig(
        type: EqBandType.peak,
        frequencyHz: 1000.0,
        gainDb: 2.0,
        q: 1.0,
      ),
      const EqBandConfig(
        type: EqBandType.notch,
        frequencyHz: 2000.0,
        q: 3.5,
      ),
      const EqBandConfig(
        type: EqBandType.bandpass,
        frequencyHz: 4000.0,
        q: 1.1,
      ),
      const EqBandConfig(
        type: EqBandType.peak,
        frequencyHz: 8000.0,
        gainDb: 1.0,
        q: 0.9,
      ),
      const EqBandConfig(
        type: EqBandType.highshelf,
        frequencyHz: 16000.0,
        gainDb: 2.0,
        slope: 1.0,
      ),
    ];
  }

  @override
  void initState() {
    super.initState();
    _init();
  }

  Future<void> _init() async {
    final ok = _player.init();
    if (!mounted) return;

    if (!ok) {
      setState(() {
        _initialized = false;
        _status = 'Init failed: ${_player.getLastError()}';
      });
      return;
    }

    _applySelectedProcessor();
    setState(() {
      _initialized = true;
      _status = 'Engine ready. ${_processingType.label} applied.';
    });
  }

  void _applyFx({bool updateStatus = true}) {
    if (!_initialized) return;
    _applySelectedProcessor();
    if (updateStatus) {
      setState(() {
        _status =
            'Applied ${_bands.length} bands using ${_processingType.label}.';
      });
    }
  }

  void _updateBand(
    int index, {
    EqBandType? type,
    double? frequencyHz,
    double? q,
    double? gainDb,
    double? slope,
    bool? enabled,
  }) {
    final current = _bands[index];
    _bands[index] = EqBandConfig(
      type: type ?? current.type,
      frequencyHz: frequencyHz ?? current.frequencyHz,
      q: q ?? current.q,
      gainDb: gainDb ?? current.gainDb,
      slope: slope ?? current.slope,
      enabled: enabled ?? current.enabled,
    );
    _applyFx(updateStatus: false);
  }

  void _applySelectedProcessor() {
    if (_processingType == ProcessingType.mixedMultibandFx) {
      _player.setMultibandEqEnabled(false);
      _player.initMultibandFx(_bands, enabled: _fxEnabled);
      return;
    }

    // Multiband EQ path (peak-only bands).
    _player.setMultibandFxEnabled(false);

    final frequencies = _bands.map((b) => b.frequencyHz).toList();
    final qFactors = _bands.map((b) => b.q).toList();
    _player.initMultibandEq(frequencies, qFactors: qFactors);
    for (var i = 0; i < _bands.length; i++) {
      _player.setMultibandEqBandGain(i, _bands[i].gainDb);
    }
    _player.setMultibandEqEnabled(_fxEnabled);
  }

  void _loadTenBandPreset() {
    _bands
      ..clear()
      ..addAll(_buildTenBandMixedPreset());
    _applyFx();
  }

  void _replaceAllBandsWithExtraPeak() {
    if (_processingType != ProcessingType.mixedMultibandFx) {
      setState(() {
        _status =
            'Switch to Mixed Multiband FX to use setMultibandFxBands(...).';
      });
      return;
    }

    final replaced = <EqBandConfig>[
      ..._bands,
      const EqBandConfig(
        type: EqBandType.peak,
        frequencyHz: 3500.0,
        gainDb: -1.5,
        q: 1.0,
      ),
    ];

    _bands
      ..clear()
      ..addAll(replaced);

    _player.setMultibandFxBands(replaced);
    _player.setMultibandFxEnabled(_fxEnabled);
    setState(() {
      _status = 'Replaced chain with ${replaced.length} mixed FX bands.';
    });
  }

  void _clearMixedFx() {
    _player.clearMultibandFx();
    setState(() {
      _status = 'Mixed multiband FX cleared.';
    });
  }

  void _addPeakBand() {
    final nextFrequency = (400.0 * (_bands.length + 1)).clamp(80.0, 14000.0);
    _bands.add(
      EqBandConfig(
        type: EqBandType.peak,
        frequencyHz: nextFrequency,
        gainDb: 1.5,
        q: 1.0,
      ),
    );
    _applyFx();
  }

  void _removeLastBand() {
    if (_bands.isEmpty) return;
    _bands.removeLast();
    if (_bands.isEmpty) {
      _player.clearMultibandFx();
      setState(() {
        _status = 'All bands removed. Mixed FX cleared.';
      });
      return;
    }
    _applyFx();
  }

  @override
  void dispose() {
    _player.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('EQ Screen'),
      ),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: Text('Enable ${_processingType.label}'),
              value: _fxEnabled,
              onChanged: !_initialized
                  ? null
                  : (value) {
                      setState(() {
                        _fxEnabled = value;
                      });
                      _applySelectedProcessor();
                    },
            ),
            const SizedBox(height: 8),
            DropdownButtonFormField<ProcessingType>(
              initialValue: _processingType,
              decoration: const InputDecoration(
                labelText: 'EQ mode',
                border: OutlineInputBorder(),
              ),
              items: ProcessingType.values
                  .map(
                    (type) => DropdownMenuItem<ProcessingType>(
                      value: type,
                      child: Text(type.label),
                    ),
                  )
                  .toList(),
              onChanged: !_initialized
                  ? null
                  : (value) {
                      if (value == null) return;
                      setState(() {
                        _processingType = value;
                      });
                      _applyFx();
                    },
            ),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                FilledButton(
                  onPressed: _initialized ? _applyFx : null,
                  child: const Text('Apply Bands'),
                ),
                OutlinedButton(
                  onPressed: _initialized ? _loadTenBandPreset : null,
                  child: const Text('Load 10-Band Preset'),
                ),
                OutlinedButton(
                  onPressed: _initialized ? _addPeakBand : null,
                  child: const Text('Add Band'),
                ),
                OutlinedButton(
                  onPressed:
                      _initialized ? _replaceAllBandsWithExtraPeak : null,
                  child: const Text('Replace +1 Peak@3500'),
                ),
                OutlinedButton(
                  onPressed: _initialized ? _removeLastBand : null,
                  child: const Text('Remove Last Band'),
                ),
                OutlinedButton(
                  onPressed: _initialized ? _clearMixedFx : null,
                  child: const Text('Clear Mixed FX'),
                ),
              ],
            ),
            const SizedBox(height: 12),
            Text(
              _status,
              style: Theme.of(context).textTheme.bodyMedium,
            ),
            const SizedBox(height: 12),
            Text(
              'Current band chain (${_bands.length})',
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: 8),
            Expanded(
              child: ListView.separated(
                itemCount: _bands.length,
                separatorBuilder: (_, __) => const Divider(height: 1),
                itemBuilder: (context, index) {
                  final b = _bands[index];
                  return Card(
                    margin: EdgeInsets.zero,
                    child: Padding(
                      padding: const EdgeInsets.all(10),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            '${index + 1}. ${b.frequencyHz.toStringAsFixed(2)} Hz',
                            style: Theme.of(context).textTheme.titleSmall,
                          ),
                          const SizedBox(height: 8),
                          Row(
                            children: [
                              const Text('Type: '),
                              const SizedBox(width: 8),
                              DropdownButton<EqBandType>(
                                value: b.type == EqBandType.bell
                                    ? EqBandType.peak
                                    : b.type,
                                items: EqBandType.values
                                    .where((type) => type != EqBandType.bell)
                                    .map(
                                      (type) => DropdownMenuItem<EqBandType>(
                                        value: type,
                                        child: Text(type == EqBandType.peak
                                            ? 'Peak / Bell'
                                            : type.name),
                                      ),
                                    )
                                    .toList(),
                                onChanged: !_initialized
                                    ? null
                                    : (value) {
                                        if (value == null) return;
                                        setState(() {
                                          _updateBand(index, type: value);
                                        });
                                      },
                              ),
                              const Spacer(),
                              Text('Q: ${b.q.toStringAsFixed(2)}'),
                            ],
                          ),
                          Slider(
                            value: b.q.clamp(0.1, 18.0),
                            min: 0.1,
                            max: 18.0,
                            divisions: 179,
                            label: b.q.toStringAsFixed(2),
                            onChanged: !_initialized
                                ? null
                                : (value) {
                                    setState(() {
                                      _updateBand(index, q: value);
                                    });
                                  },
                          ),
                        ],
                      ),
                    ),
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }
}

enum ProcessingType {
  mixedMultibandFx('Enable Mix EQ'),
  multibandEq('Enable Multiband EQ');

  const ProcessingType(this.label);
  final String label;
}
