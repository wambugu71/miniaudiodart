import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:audio_metadata_reader/audio_metadata_reader.dart';
import 'package:file_picker/file_picker.dart';
import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';
import 'package:flutter_m3shapes_extended/flutter_m3shapes_extended.dart';
import 'package:loading_indicator_m3e/loading_indicator_m3e.dart';
import 'package:material_3_expressive/material_3_expressive.dart';
import 'package:sautiflow/sautiflow.dart';

import 'album_detail_screen.dart'; // For TrackInfo
import 'isolate_player.dart';
import 'models/liked_song.dart';
import 'queue_screen.dart';
import 'services/app_state_service.dart';
import 'services/app_theme_service.dart';
import 'services/audio_file_inspector.dart';
import 'services/audio_hardware_inspector.dart';
import 'services/fft_processor.dart';
import 'services/liked_songs_service.dart';
import 'services/lyrics_service.dart';
import 'services/waveform_extractor_service.dart';
import 'widgets/adaptive_marquee_text.dart';
import 'widgets/audio_engine_diagnostic_panel.dart';
import 'widgets/music_info_dialog.dart';
import 'widgets/playback_speed_modal.dart';
import 'widgets/synced_lyrics_widget.dart';
import 'widgets/waveform_seek_bar_widget.dart';

class NowPlayingScreen extends StatefulWidget {
  final ValueNotifier<PlayerStatus> statusNotifier;
  final IsolateAudioPlayer player;
  final String Function(int index) getTitle;
  final String artist;
  final Uint8List? albumArt;
  final String codec; // e.g. 'FLAC'
  final int? durationOverride; // Override duration for online streams
  final String? videoId;
  final VoidCallback onMinimize;
  final List<TrackInfo> queue;
  final void Function(int) onPlayQueueIndex;
  final void Function(int, int) onReorderQueue;
  final void Function(int)? onRemoveFromQueue;
  final VoidCallback? onClearQueue;
  final VoidCallback? onShuffleQueue;
  final String sourceType;
  final Future<void> Function(List<TrackInfo> tracks, {int initialIndex})?
      onPlayTracks;
  final bool analyzerEnabled;
  final ValueChanged<bool> onAnalyzerEnabledChanged;
  final String analyzerType;
  final bool analyzerAutoFit;
  final bool analyzerShowGrids;
  final int outputSampleRate;
  final VoidCallback? onNavigateToHistory;

  const NowPlayingScreen({
    super.key,
    required this.statusNotifier,
    required this.player,
    required this.getTitle,
    required this.artist,
    this.albumArt,
    this.codec = 'MP3',
    this.durationOverride,
    this.videoId,
    required this.onMinimize,
    this.queue = const [],
    required this.onPlayQueueIndex,
    required this.onReorderQueue,
    this.onRemoveFromQueue,
    this.onClearQueue,
    this.onShuffleQueue,
    required this.sourceType,
    this.onPlayTracks,
    required this.analyzerEnabled,
    required this.onAnalyzerEnabledChanged,
    required this.analyzerType,
    required this.analyzerAutoFit,
    required this.analyzerShowGrids,
    required this.outputSampleRate,
    this.onNavigateToHistory,
  });

  @override
  State<NowPlayingScreen> createState() => _NowPlayingScreenState();
}

class _NowPlayingScreenState extends State<NowPlayingScreen>
    with SingleTickerProviderStateMixin {
  late bool _isAnalyzerEnabled;
  late final AnimationController _rotationController;
  late final PageController _pageController;

  final ValueNotifier<List<double>> _analyzerValuesNotifier = ValueNotifier([]);
  StreamSubscription? _analyzerSub;
  FftProcessor? _fftProcessor;

  bool _showLyrics = false;
  String? _lyricsRaw;
  bool _isLoadingLyrics = false;
  bool _showLyricsOverlayOnAlbumArt = false;
  bool _isCustomLyricsLoaded = false;
  String? _customLyricsFileName;
  int _lyricsRequestId = 0;

  // ── Live hardware specs (updates on route change) ─────────────────────────
  AudioHardwareSpecs? _hardwareSpecs;
  StreamSubscription<AudioHardwareSpecs>? _hardwareSub;

  int _fileSizeBytes = 0;
  String _originalBitDepth = '';
  String _sampleRate = '...';
  String _channels = '...';
  String? _detectedCodec;
  int _bitrateKbps = 0;

  String? _customTitle;
  String? _customArtist;
  String _customAlbum = 'Unknown Album';
  String _customGenre = 'Unknown Genre';
  String _customYear = '';
  String _customTrackNum = '';

  // ── Seek-state machine ────────────────────────────────────────────────────
  bool _isDragging = false;
  double _dragPositionMs = 0.0;
  double? _pendingSeekMs; // non-null while seek is in-flight
  Timer? _seekTimeoutTimer;
  double _currentRate = 1.0;
  double _currentPitch = 1.0;
  bool _currentPitchCorrection = true;

  // ── Swipe-to-navigate transition direction ────────────────────────────────
  // 1 = swiped left (next), -1 = swiped right (prev), 0 = no swipe
  int _swipeDirection = 0;

  // ── A-B Repeat ────────────────────────────────────────────────────────────
  // State machine: 0 = off, 1 = point A set (waiting for B), 2 = active loop
  int _abRepeatState = 0;
  double? _abPointAMs;
  double? _abPointBMs;

  // ── Waveform & Slider Seek Bar ─────────────────────────────────────────────
  bool _useWaveformSeekBar = false;
  bool _useWavySlider = true;
  List<double>? _currentWaveformPeaks;
  StreamSubscription<bool>? _waveformSub;
  StreamSubscription<bool>? _sliderStyleSub;
  StreamSubscription<Shapes>? _albumArtShapeSub;
  StreamSubscription<bool>? _bufferingSub;
  StreamSubscription<StreamTelemetry>? _telemetrySub;
  bool _isBuffering = false;
  StreamTelemetry _streamTelemetry = const StreamTelemetry();
  int _lastKnownTrackIndex = -1;
  bool _queueMounted = false;

  @override
  void initState() {
    super.initState();
    _pageController = PageController(initialPage: 0);
    _pageController.addListener(_handlePageScroll);
    _isAnalyzerEnabled = widget.analyzerEnabled;
    _fetchLyrics();
    _fetchAudioProperties();
    _loadPlaybackSpeed();
    _loadWaveformSetting();

    _albumArtShapeSub =
        AppThemeService.instance.albumArtShapeChanged.stream.listen((_) {
      if (mounted) setState(() {});
    });

    _bufferingSub = widget.player.bufferingStream.listen((buffering) {
      if (mounted && _isBuffering != buffering) {
        setState(() => _isBuffering = buffering);
      }
    });

    _telemetrySub = widget.player.streamTelemetryStream.listen((tel) {
      if (mounted) {
        setState(() => _streamTelemetry = tel);
        if (_originalBitDepth.isEmpty || _sampleRate == '...') {
          _fetchAudioProperties();
        }
      }
    });

    _setupAnalyzer(_isAnalyzerEnabled);
    _initHardwareSpecs();

    _rotationController = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 20),
    );

    widget.statusNotifier.addListener(_onStatusChanged);
  }

  Future<void> _loadWaveformSetting() async {
    final enabled = await AppStateService.instance.loadUseWaveformSeekBar();
    final wavy = await AppStateService.instance.loadUseWavySlider();
    if (mounted) {
      setState(() {
        _useWaveformSeekBar = enabled;
        _useWavySlider = wavy;
      });
      if (enabled) _updateCurrentTrackWaveform();
    }
    _waveformSub = AppStateService.instance.useWaveformSeekBarChanged.stream
        .listen((enabled) {
      if (mounted) {
        setState(() => _useWaveformSeekBar = enabled);
        if (enabled && _currentWaveformPeaks == null) {
          _updateCurrentTrackWaveform();
        }
      }
    });
    _sliderStyleSub =
        AppStateService.instance.useWavySliderChanged.stream.listen((wavy) {
      if (mounted) {
        setState(() => _useWavySlider = wavy);
      }
    });
  }

  Future<void> _updateCurrentTrackWaveform() async {
    final status = widget.statusNotifier.value;
    String trackPath = '';
    if (widget.queue.isNotEmpty &&
        status.currentIndex >= 0 &&
        status.currentIndex < widget.queue.length) {
      final track = widget.queue[status.currentIndex];
      trackPath = track.videoId.isNotEmpty ? track.videoId : track.title;
    }
    if (trackPath.isEmpty) {
      trackPath = widget.videoId ?? widget.getTitle(status.currentIndex);
    }
    if (trackPath.isEmpty) return;

    final peaks =
        await WaveformExtractorService.instance.getWaveform(trackPath);
    if (mounted) {
      setState(() {
        _currentWaveformPeaks = peaks;
      });
    }
  }

  Future<void> _loadPlaybackSpeed() async {
    final rate = await AppStateService.instance.loadPlaybackRate();
    final pitch = await AppStateService.instance.loadPlaybackPitch();
    final pitchCorrection =
        await AppStateService.instance.loadPitchCorrection();
    if (mounted) {
      setState(() {
        _currentRate = rate;
        _currentPitch = pitch;
        _currentPitchCorrection = pitchCorrection;
      });
      if ((rate - 1.0).abs() > 0.01) {
        widget.player.setRate(rate);
      }
      if ((pitch - 1.0).abs() > 0.01) {
        widget.player.setPitch(pitch);
      }
      if (!pitchCorrection) {
        widget.player.setPitchCorrection(pitchCorrection);
      }
    }
  }

  void _onStatusChanged() {
    final status = widget.statusNotifier.value;
    if (status.isPlaying) {
      if (!_rotationController.isAnimating) {
        _rotationController.repeat();
      }
    } else {
      if (_rotationController.isAnimating) {
        _rotationController.stop();
      }
    }

    if (status.currentIndex != _lastKnownTrackIndex) {
      _lastKnownTrackIndex = status.currentIndex;
      _pendingSeekMs = null;
      _isDragging = false;
      _seekTimeoutTimer?.cancel();
      _abRepeatState = 0;
      _abPointAMs = null;
      _abPointBMs = null;
      widget.player.setAbRepeat(enabled: false, startSeconds: 0, endSeconds: 0);

      // Immediately clear previous song's lyrics so they don't linger
      _isCustomLyricsLoaded = false;
      _customLyricsFileName = null;
      _lyricsRaw = null;
      _isLoadingLyrics = true;
      if (mounted) setState(() {});

      _fetchLyrics();
      _fetchAudioProperties();

      if (_useWaveformSeekBar) {
        _updateCurrentTrackWaveform();
      }
    }

    final target = _pendingSeekMs;
    if (target == null) return;
    final enginePosMs = status.positionSeconds * 1000.0;
    if ((enginePosMs - target).abs() < 1500) {
      _seekTimeoutTimer?.cancel();
      if (mounted) setState(() => _pendingSeekMs = null);
    }
  }

  @override
  void didUpdateWidget(covariant NowPlayingScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.analyzerEnabled != widget.analyzerEnabled) {
      _isAnalyzerEnabled = widget.analyzerEnabled;
      _setupAnalyzer(_isAnalyzerEnabled);
    }
    if (oldWidget.outputSampleRate != widget.outputSampleRate) {
      final sr = widget.outputSampleRate > 0 ? widget.outputSampleRate : 48000;
      _fftProcessor?.setSampleRate(sr);
    }
    final currentIdx = widget.statusNotifier.value.currentIndex;
    final oldTitle = oldWidget.getTitle(currentIdx);
    final newTitle = widget.getTitle(currentIdx);

    if (oldWidget.videoId != widget.videoId ||
        oldWidget.sourceType != widget.sourceType ||
        oldWidget.artist != widget.artist ||
        oldTitle != newTitle) {
      _pendingSeekMs = null;
      _isDragging = false;
      _seekTimeoutTimer?.cancel();
      _lyricsRaw = null;
      _isLoadingLyrics = true;
      _fetchAudioProperties();
      _fetchLyrics();
      if (_useWaveformSeekBar) {
        _updateCurrentTrackWaveform();
      }
    }
  }

  @override
  void dispose() {
    widget.statusNotifier.removeListener(_onStatusChanged);
    _seekTimeoutTimer?.cancel();
    _analyzerSub?.cancel();
    _hardwareSub?.cancel();
    _waveformSub?.cancel();
    _sliderStyleSub?.cancel();
    _albumArtShapeSub?.cancel();
    _bufferingSub?.cancel();
    _telemetrySub?.cancel();
    _analyzerValuesNotifier.dispose();
    _rotationController.dispose();
    _pageController.removeListener(_handlePageScroll);
    _pageController.dispose();
    widget.player.setAbRepeat(enabled: false, startSeconds: 0, endSeconds: 0);
    super.dispose();
  }

  void _handlePageScroll() {
    if (!_queueMounted && _pageController.hasClients) {
      final page = _pageController.page ?? 0.0;
      if (page > 0.02) {
        setState(() => _queueMounted = true);
      }
    }
  }

  Future<void> _initHardwareSpecs() async {
    final initial = await AudioHardwareInspector.inspectAsync(widget.player);
    if (mounted) setState(() => _hardwareSpecs = initial);
    _subscribeHardwareStream();
  }

  void _subscribeHardwareStream() {
    _hardwareSub?.cancel();
    _hardwareSub = AudioHardwareInspector.hardwareStream(widget.player).listen(
      (specs) {
        if (mounted) setState(() => _hardwareSpecs = specs);
      },
      onError: (_) {/* ignore */},
    );
  }

  void _setupAnalyzer(bool enabled) {
    if (enabled) {
      final sr = widget.outputSampleRate > 0 ? widget.outputSampleRate : 48000;
      _fftProcessor ??= FftProcessor(sampleRate: sr);
      widget.player.setAnalyzerEnabled(true);
      _analyzerSub ??= widget.player.analyzerStream.listen((frame) {
        if (frame.isEmpty) return;
        final bins = _fftProcessor!.processFrame(frame, targetBins: 96);
        _analyzerValuesNotifier.value = bins;
      });
    } else {
      widget.player.setAnalyzerEnabled(false);
      _analyzerSub?.cancel();
      _analyzerSub = null;
      _fftProcessor?.reset();
      _analyzerValuesNotifier.value = [];
    }
  }

  String _formatSampleRate(int rateHz) {
    if (rateHz <= 0) return '44.1 kHz';
    if (rateHz % 1000 == 0) {
      return '${rateHz ~/ 1000}.0 kHz';
    }
    final double kHz = rateHz / 1000.0;
    return '${kHz.toStringAsFixed(1)} kHz';
  }

  Future<void> _fetchAudioProperties() async {
    _fileSizeBytes = 0;
    _originalBitDepth = '';
    _detectedCodec = null;
    _bitrateKbps = 0;

    try {
      final props = await widget.player.getAudioProperties();
      final pipelineState = await widget.player.getPipelineState();
      String? sampleRateStr;
      String? channelsStr;
      String? depthStr;
      String? codecStr;
      int bitrate = 0;

      String? cleanPath = widget.videoId;
      if (cleanPath != null && cleanPath.startsWith('file://')) {
        cleanPath = Uri.tryParse(cleanPath)?.toFilePath();
      }

      if (cleanPath != null) {
        try {
          final file = File(cleanPath);
          if (file.existsSync()) {
            _fileSizeBytes = file.lengthSync();
            final info = await AudioFileInspector.inspectNative(
                widget.player, cleanPath);
            sampleRateStr = info.formattedSampleRate;
            depthStr = info.formattedBitDepth;
            channelsStr = info.formattedChannels;
            codecStr = info.codec;
            bitrate = info.bitrateKbps;

            try {
              final metadata = readMetadata(file, getImage: false);
              if (metadata.album != null && metadata.album!.isNotEmpty) {
                _customAlbum = metadata.album!;
              }
              if (metadata.genres.isNotEmpty &&
                  metadata.genres.first.isNotEmpty) {
                _customGenre = metadata.genres.first;
              }
              if (metadata.year != null) {
                _customYear = metadata.year.toString();
              }
              if (metadata.trackNumber != null) {
                _customTrackNum = metadata.trackNumber.toString();
              }
              if (bitrate <= 0 &&
                  metadata.bitrate != null &&
                  metadata.bitrate! > 0) {
                bitrate = metadata.bitrate!;
              }
            } catch (_) {}

            if (bitrate <= 0 && _fileSizeBytes > 0) {
              final dur = widget.statusNotifier.value.durationSeconds;
              if (dur > 0) {
                bitrate = ((_fileSizeBytes * 8) / dur / 1000).round();
              }
            }
          }
        } catch (e) {
          debugPrint('[NowPlaying] Audio file inspector error: $e');
        }
      }

      if (sampleRateStr == null && pipelineState.inputSampleRate > 0) {
        sampleRateStr = _formatSampleRate(pipelineState.inputSampleRate);
      }
      if (channelsStr == null && pipelineState.inputChannels > 0) {
        channelsStr = pipelineState.inputChannels == 1 ? 'MONO' : 'STEREO';
      }
      if (depthStr == null) {
        switch (pipelineState.inputFormat) {
          case 0:
            depthStr = '32 bit float';
            break;
          case 3:
            depthStr = '24 bit';
            break;
          case 4:
            depthStr = '32 bit';
            break;
          case 2:
            depthStr = '8 bit';
            break;
          case 1:
          default:
            depthStr = '16 bit';
            break;
        }
      }

      if (mounted) {
        setState(() {
          final int rate = props['sampleRate'] as int? ?? 44100;
          _sampleRate = sampleRateStr ?? _formatSampleRate(rate);

          final int channels = props['channels'] as int? ?? 2;
          _channels = channelsStr ?? (channels == 1 ? 'MONO' : 'STEREO');
          _originalBitDepth = depthStr ?? '16 bit';
          _detectedCodec = codecStr;
          _bitrateKbps = bitrate;
        });
      }
    } catch (e) {
      debugPrint('[NowPlaying] Failed to fetch audio properties: $e');
    }
  }

  String _buildAudioInfoBadgeText(String trackPosition) {
    final posPart =
        trackPosition.trim().isNotEmpty ? '${trackPosition.trim()} ' : '';
    final depthPart = _originalBitDepth.isNotEmpty ? '$_originalBitDepth ' : '';
    return '$posPart$depthPart$_sampleRate'.toUpperCase().trim();
  }

  Future<void> _fetchLyrics() async {
    final requestId = ++_lyricsRequestId;

    if (_isCustomLyricsLoaded) return;

    final status = widget.statusNotifier.value;
    final currentIdx = status.currentIndex;

    String? trackTitle;
    String? trackArtist = widget.artist;
    String? trackVideoId = widget.videoId;
    String? trackFilePath;
    int? trackDuration = widget.durationOverride ??
        (status.durationSeconds > 0 ? status.durationSeconds.toInt() : null);

    if (widget.queue.isNotEmpty &&
        currentIdx >= 0 &&
        currentIdx < widget.queue.length) {
      final track = widget.queue[currentIdx];
      trackTitle = track.title;
      if (track.artist.isNotEmpty && track.artist != 'Unknown Artist') {
        trackArtist = track.artist;
      }
      if (track.videoId.isNotEmpty) {
        trackVideoId = track.videoId;
      }
      if (track.durationSeconds != null && track.durationSeconds! > 0) {
        trackDuration = track.durationSeconds;
      }
    }

    trackTitle ??= widget.getTitle(currentIdx);

    // If trackVideoId looks like a local file path, move to trackFilePath
    if (trackVideoId != null &&
        (trackVideoId.contains('/') ||
            trackVideoId.contains(r'\') ||
            trackVideoId.startsWith('file://'))) {
      trackFilePath = trackVideoId;
      trackVideoId = null;
    }

    try {
      if (mounted) {
        setState(() {
          _isLoadingLyrics = true;
          _lyricsRaw = null;
        });
      }

      final lyrics = await LyricsService.instance.fetchLyricsForTrack(
        videoId: trackVideoId,
        title: trackTitle,
        artist: trackArtist,
        filePath: trackFilePath,
        durationSeconds: trackDuration,
      );

      // Discard if user already changed song while request was in flight
      if (requestId != _lyricsRequestId) {
        debugPrint(
            '[NowPlaying] Discarding stale lyrics response for request #$requestId (active: #$_lyricsRequestId)');
        return;
      }

      if (mounted) {
        setState(() {
          _lyricsRaw = lyrics;
          _isLoadingLyrics = false;
        });
      }
    } catch (e) {
      debugPrint('[NowPlaying] Lyrics fetch notice: $e');
      if (requestId == _lyricsRequestId && mounted) {
        setState(() {
          _isLoadingLyrics = false;
          _lyricsRaw = null;
        });
      }
    }
  }

  Future<void> _pickLrcFile() async {
    try {
      final result = await FilePicker.pickFiles(
        type: FileType.custom,
        allowedExtensions: ['lrc', 'txt'],
      );

      if (result != null && result.files.single.path != null) {
        final file = File(result.files.single.path!);
        final content = await file.readAsString();
        if (content.trim().isEmpty) {
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(
                content: Text('Selected lyrics file is empty.'),
                backgroundColor: Color(0xFF1E2D3D),
              ),
            );
          }
          return;
        }

        if (mounted) {
          setState(() {
            _lyricsRaw = content;
            _isCustomLyricsLoaded = true;
            _customLyricsFileName = result.files.single.name;
            _showLyricsOverlayOnAlbumArt = true;
            _showLyrics = true;
          });

          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Row(
                children: [
                  Icon(Icons.lyrics_outlined,
                      color: AppThemeService.instance.currentData.primary,
                      size: 18),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      'Loaded lyrics: ${_customLyricsFileName!}',
                      style: const TextStyle(
                          color: Colors.white, fontWeight: FontWeight.bold),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ],
              ),
              backgroundColor: const Color(0xFF1E2D3D),
              duration: const Duration(seconds: 2),
            ),
          );
        }
      }
    } catch (e) {
      debugPrint('[NowPlaying] Failed to load .lrc file: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Failed to read .lrc file: $e'),
            backgroundColor: Colors.redAccent,
          ),
        );
      }
    }
  }

  void _clearCustomLyrics() {
    setState(() {
      _isCustomLyricsLoaded = false;
      _customLyricsFileName = null;
      _showLyricsOverlayOnAlbumArt = false;
      _lyricsRaw = null;
    });
    _fetchLyrics();
  }

  void _showMoreOptionsMenu(BuildContext context) {
    M3EBottomSheet.show<void>(
      context,
      builder: (sheetContext) {
        return Material(
          color: const Color(0xFF18232E),
          borderRadius: const BorderRadius.vertical(top: Radius.circular(28)),
          child: StatefulBuilder(
            builder: (ctx, setSheetState) {
              return SafeArea(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
                  child: SingleChildScrollView(
                    physics: const BouncingScrollPhysics(),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        /*  Center(
                          child: Container(
                            width: 36,
                            height: 4,
                            margin: const EdgeInsets.only(bottom: 16),
                            decoration: BoxDecoration(
                              color: Colors.white24,
                              borderRadius: BorderRadius.circular(2),
                            ),
                          ),
                        ),*/
                        const SizedBox(height: 8),
                        Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 16.0),
                          child: Text(
                            'TRACK OPTIONS',
                            style: TextStyle(
                              fontSize: 11,
                              fontWeight: FontWeight.bold,
                              letterSpacing: 1.2,
                              color:
                                  AppThemeService.instance.currentData.primary,
                            ),
                          ),
                        ),
                        const SizedBox(height: 12),
                        /*ListTile(
                          leading: M3EContainer(
                            AppThemeService.instance.albumArtShape,
                            width: 38,
                            height: 38,
                            color: AppThemeService.instance.currentData.primary
                                .withAlpha(35),
                            border: BorderSide(
                              color: AppThemeService
                                  .instance.currentData.primary
                                  .withAlpha(80),
                              width: 1.2,
                            ),
                            child: Center(
                              child: Icon(
                                Icons.crop_original_rounded,
                                color: AppThemeService
                                    .instance.currentData.primary,
                                size: 18,
                              ),
                            ),
                          ),
                          title: const Text('Album Art Shape',
                              style: TextStyle(
                                  color: Colors.white,
                                  fontWeight: FontWeight.w600)),
                          subtitle: Text(
                            'Current: ${kM3EAlbumArtShapes.firstWhere((s) => s.shape == AppThemeService.instance.albumArtShape, orElse: () => kM3EAlbumArtShapes.first).name} • Tap to customize',
                            style: const TextStyle(
                                color: Colors.white54, fontSize: 12),
                          ),
                          trailing: const Icon(Icons.chevron_right_rounded,
                              color: Colors.white54, size: 20),
                          onTap: () {
                            Navigator.pop(sheetContext);
                            AlbumArtShapePickerSheet.show(
                              context,
                              sampleAlbumArt: widget.albumArt,
                            );
                          },
                        ),*/
                        ////////////////////////////////////
                        ListTile(
                          leading: const Icon(Icons.info_outline,
                              color: Colors.white),
                          title: const Text('Song Info & Tags',
                              style: TextStyle(
                                  color: Colors.white,
                                  fontWeight: FontWeight.w600)),
                          subtitle: const Text('View or edit track metadata',
                              style: TextStyle(
                                  color: Colors.white54, fontSize: 12)),
                          onTap: () {
                            Navigator.pop(sheetContext);
                            _showMusicInfoDialog(context);
                          },
                        ),
                        /*  ListTile(
                          leading: Icon(Icons.developer_board,
                              color:
                                  AppThemeService.instance.currentData.primary),
                          title: const Text('Audio Output Signal Chain',
                              style: TextStyle(
                                  color: Colors.white,
                                  fontWeight: FontWeight.w600)),
                          subtitle: const Text('View live pipeline specs',
                              style: TextStyle(
                                  color: Colors.white54, fontSize: 12)),
                          onTap: () {
                            Navigator.pop(sheetContext);
                            _showHardwareSpecsModal(context);
                          },
                        ),*/
                        ListTile(
                          leading: Icon(Icons.subtitles_outlined,
                              color:
                                  AppThemeService.instance.currentData.primary),
                          title: const Text('Add .lrc Lyrics File',
                              style: TextStyle(
                                  color: Colors.white,
                                  fontWeight: FontWeight.w600)),
                          subtitle: Text(
                            _isCustomLyricsLoaded
                                ? 'Loaded: ${_customLyricsFileName ?? "Custom LRC"}'
                                : 'Select synchronized .lrc / .txt file from storage',
                            style: const TextStyle(
                                color: Colors.white54, fontSize: 12),
                            overflow: TextOverflow.ellipsis,
                          ),
                          onTap: () {
                            Navigator.pop(sheetContext);
                            _pickLrcFile();
                          },
                        ),
                        SwitchListTile(
                          secondary: Icon(
                            _showLyricsOverlayOnAlbumArt
                                ? Icons.layers
                                : Icons.layers_clear,
                            color: _showLyricsOverlayOnAlbumArt
                                ? AppThemeService.instance.currentData.primary
                                : Colors.white54,
                          ),
                          title: const Text('Lyrics Overlay on Album Art',
                              style: TextStyle(
                                  color: Colors.white,
                                  fontWeight: FontWeight.w600)),
                          subtitle: const Text(
                              'Display synchronized lyrics over album cover',
                              style: TextStyle(
                                  color: Colors.white54, fontSize: 12)),
                          activeThumbColor:
                              AppThemeService.instance.currentData.primary,
                          value: _showLyricsOverlayOnAlbumArt,
                          onChanged: (_lyricsRaw == null &&
                                  !_isCustomLyricsLoaded)
                              ? null
                              : (val) {
                                  setSheetState(
                                      () => _showLyricsOverlayOnAlbumArt = val);
                                  setState(
                                      () => _showLyricsOverlayOnAlbumArt = val);
                                },
                        ),
                        if (_isCustomLyricsLoaded)
                          ListTile(
                            leading: const Icon(
                                Icons.cleaning_services_outlined,
                                color: Colors.redAccent),
                            title: const Text('Reset to Default Lyrics',
                                style: TextStyle(
                                    color: Colors.redAccent,
                                    fontWeight: FontWeight.w600)),
                            onTap: () {
                              Navigator.pop(sheetContext);
                              _clearCustomLyrics();
                            },
                          ),
                      ],
                    ),
                  ),
                ),
              );
            },
          ),
        );
      },
    );
  }

  Widget _buildAlbumArtLyricsOverlay({
    required double borderRadius,
    required double bottomOffset,
    required double displayPosMs,
    String? title,
  }) {
    if (!_showLyricsOverlayOnAlbumArt) return const SizedBox.shrink();

    return Positioned(
      top: 0,
      left: 0,
      right: 0,
      bottom: bottomOffset,
      child: RepaintBoundary(
        child: Container(
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(borderRadius),
            color: Colors.black.withValues(alpha: 0.94),
            border: Border.all(
              color: AppThemeService.instance.currentData.primary
                  .withValues(alpha: 0.4),
              width: 1.5,
            ),
          ),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(borderRadius),
            child: Stack(
              children: [
                Positioned.fill(
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(12, 44, 12, 12),
                    child: _isLoadingLyrics
                        ? Center(
                            child: LoadingIndicatorM3E(
                              color:
                                  AppThemeService.instance.currentData.primary,
                              containerColor: AppThemeService
                                  .instance.currentData.primary
                                  .withAlpha(50),
                            ),
                          )
                        : SyncedLyricsWidget(
                            lyricsRaw: _lyricsRaw ?? '',
                            currentPosition:
                                Duration(milliseconds: displayPosMs.toInt()),
                            onSeek: (targetTime) {
                              widget.player.seekTo(targetTime);
                            },
                            onImportLrc: _pickLrcFile,
                            onRetryFetch: _fetchLyrics,
                          ),
                  ),
                ),
                Positioned(
                  top: 8,
                  left: 12,
                  right: 8,
                  child: Row(
                    children: [
                      Flexible(
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 8, vertical: 4),
                          decoration: BoxDecoration(
                            color: AppThemeService.instance.currentData.primary
                                .withValues(alpha: 0.25),
                            borderRadius: BorderRadius.circular(10),
                          ),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(Icons.lyrics,
                                  size: 12,
                                  color: AppThemeService
                                      .instance.currentData.primary),
                              const SizedBox(width: 4),
                              Flexible(
                                child: Text(
                                  _isCustomLyricsLoaded
                                      ? (_customLyricsFileName ?? 'Custom LRC')
                                      : (title != null && title.isNotEmpty
                                          ? title
                                          : 'Synced Lyrics'),
                                  style: const TextStyle(
                                    fontSize: 10,
                                    fontWeight: FontWeight.bold,
                                    color: Colors.white70,
                                  ),
                                  overflow: TextOverflow.ellipsis,
                                  maxLines: 1,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                      const SizedBox(width: 4),
                      IconButton(
                        icon: const Icon(Icons.file_upload_outlined,
                            size: 18, color: Colors.white70),
                        onPressed: _pickLrcFile,
                        tooltip: 'Import .lrc / .txt',
                      ),
                      if (_isCustomLyricsLoaded)
                        IconButton(
                          icon: const Icon(Icons.cleaning_services_outlined,
                              size: 18, color: Colors.redAccent),
                          onPressed: _clearCustomLyrics,
                          tooltip: 'Reset to Default Lyrics',
                        ),
                      IconButton(
                        icon: const Icon(Icons.close,
                            size: 18, color: Colors.white70),
                        onPressed: () {
                          setState(() => _showLyricsOverlayOnAlbumArt = false);
                        },
                        tooltip: 'Hide Lyrics Overlay',
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  String _fmt(Duration d) {
    final m = d.inMinutes.remainder(60).toString().padLeft(2, '0');
    final s = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    final h = d.inHours;
    return h > 0 ? '${h.toString().padLeft(2, '0')}:$m:$s' : '$m:$s';
  }

  IconData _loopIcon(LoopMode mode) {
    switch (mode) {
      case LoopMode.off:
        return Icons.repeat;
      case LoopMode.all:
        return Icons.repeat_on;
      case LoopMode.one:
        return Icons.repeat_one_on;
    }
  }

  void _showMusicInfoDialog(BuildContext context) {
    final status = widget.statusNotifier.value;
    final overrideSecs = widget.durationOverride;
    final baseDurationSecs = (overrideSecs != null && overrideSecs > 0)
        ? overrideSecs.toDouble()
        : status.durationSeconds;
    final duration = Duration(milliseconds: (baseDurationSecs * 1000).round());
    final rawTitle = widget.getTitle(status.currentIndex);

    MusicInfoDialog.show(
      context,
      title: _customTitle ?? rawTitle,
      artist: _customArtist ?? widget.artist,
      album: _customAlbum,
      genre: _customGenre,
      year: _customYear,
      trackNumber: _customTrackNum,
      albumArt: widget.albumArt,
      sourceType: widget.sourceType,
      videoId: widget.videoId,
      codec: _detectedCodec ?? widget.codec,
      sampleRate: _sampleRate,
      channels: _channels,
      bitDepth: _originalBitDepth,
      fileSizeBytes: _fileSizeBytes,
      duration: duration,
      onSaveTags: ({
        required String title,
        required String artist,
        required String album,
        required String genre,
        required String year,
        required String trackNumber,
      }) {
        setState(() {
          _customTitle = title.isNotEmpty ? title : null;
          _customArtist = artist.isNotEmpty ? artist : null;
          _customAlbum = album;
          _customGenre = genre;
          _customYear = year;
          _customTrackNum = trackNumber;
        });
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Song tags updated successfully'),
            duration: Duration(seconds: 2),
          ),
        );
      },
    );
  }

  void _showHardwareSpecsModal(BuildContext context) {
    if (_hardwareSpecs == null) {
      AudioHardwareInspector.inspectAsync(widget.player).then((specs) {
        if (mounted) setState(() => _hardwareSpecs = specs);
      });
    }

    final initial = _hardwareSpecs ?? AudioHardwareInspector.currentSpecs;

    M3EBottomSheet.show<void>(
      context,
      builder: (sheetContext) {
        return Material(
          color: const Color(0xFF18232E),
          borderRadius: const BorderRadius.vertical(top: Radius.circular(28)),
          child: StreamBuilder<AudioHardwareSpecs>(
            initialData: initial,
            stream: AudioHardwareInspector.hardwareStream(widget.player),
            builder: (context, snapshot) {
              final specs = snapshot.data ??
                  initial ??
                  AudioHardwareInspector.currentSpecs;
              return ConstrainedBox(
                constraints: BoxConstraints(
                  maxHeight: MediaQuery.of(context).size.height * 0.92,
                ),
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(20.0, 16.0, 20.0, 24.0),
                  child: SingleChildScrollView(
                    physics: const BouncingScrollPhysics(),
                    child: specs == null
                        ? SizedBox(
                            height: 160,
                            child: Center(
                              child: M3EProgressIndicator.circular(
                                color: AppThemeService
                                    .instance.currentData.primary,
                              ),
                            ),
                          )
                        : _buildHardwareSheetContent(specs),
                  ),
                ),
              );
            },
          ),
        );
      },
    );
  }

  Widget _buildHardwareSheetContent(AudioHardwareSpecs specs) {
    final primaryColor = AppThemeService.instance.currentData.primary;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        /* Center(
          child: Container(
            width: 36,
            height: 4,
            margin: const EdgeInsets.only(bottom: 16),
            decoration: BoxDecoration(
              color: Colors.white24,
              borderRadius: BorderRadius.circular(2),
            ),
          ),
        ),*/
        Row(
          children: [
            Container(
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: primaryColor.withValues(alpha: 0.2),
                borderRadius: BorderRadius.circular(12),
              ),
              child: Icon(Icons.equalizer, color: primaryColor),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'AUDIO OUTPUT CHAIN',
                    style: TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.bold,
                      letterSpacing: 1.2,
                      color: primaryColor,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    specs.isBluetooth
                        ? (specs.bluetoothDeviceName ?? specs.deviceName)
                        : specs.deviceName,
                    style: const TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.bold,
                      color: Colors.white,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
              ),
            ),
            Container(
              width: 8,
              height: 8,
              decoration: BoxDecoration(
                color: const Color(0xFF22C55E),
                shape: BoxShape.circle,
                boxShadow: [
                  BoxShadow(
                    color: const Color(0xFF22C55E).withValues(alpha: 0.5),
                    blurRadius: 6,
                    spreadRadius: 1,
                  )
                ],
              ),
            ),
            const SizedBox(width: 6),
            const Text(
              'LIVE',
              style: TextStyle(
                fontSize: 9,
                fontWeight: FontWeight.bold,
                color: Color(0xFF22C55E),
                letterSpacing: 1.0,
              ),
            ),
          ],
        ),
        const SizedBox(height: 20),
        const Divider(color: Colors.white12),
        const SizedBox(height: 16),
        const Text(
          'AUDIO SIGNAL CHAIN',
          style: TextStyle(
            fontSize: 10,
            fontWeight: FontWeight.bold,
            letterSpacing: 1.0,
            color: Colors.white38,
          ),
        ),
        const SizedBox(height: 12),
        _buildSignalChain(specs),
        const SizedBox(height: 20),
        const Divider(color: Colors.white12),
        const SizedBox(height: 16),
        const Text(
          'HARDWARE SPECS',
          style: TextStyle(
            fontSize: 10,
            fontWeight: FontWeight.bold,
            letterSpacing: 1.0,
            color: Colors.white38,
          ),
        ),
        const SizedBox(height: 12),
        Wrap(
          spacing: 4,
          runSpacing: 10,
          children: [
            _buildSpecChip(Icons.api, 'Backend', specs.backendName),
            _buildSpecChip(
              Icons.headset,
              'Route',
              specs.deviceType,
            ),
            _buildSpecChip(
              Icons.speed,
              'Sample Rate',
              specs.formattedSampleRate,
              isHiRes: specs.isHiResAudio,
            ),
            _buildSpecChip(
              Icons.high_quality,
              'Bit Depth',
              specs.formattedBitDepth,
            ),
            _buildSpecChip(
              Icons.timer_outlined,
              'Buffer Latency',
              specs.formattedLatency,
            ),
            _buildSpecChip(
              Icons.surround_sound,
              'Channels',
              '${specs.channels} Ch (Stereo)',
            ),
            _buildSpecChip(
              Icons.lock_outline,
              'Mode',
              specs.isExclusiveMode ? 'Bit-Perfect Exclusive' : 'Shared Mixer',
            ),
            if (specs.bluetoothCodec != null)
              _buildSpecChip(
                Icons.bluetooth_audio,
                'BT Codec',
                specs.formattedBtCodec ?? specs.bluetoothCodec!,
                isHiRes: specs.bluetoothCodec == 'LDAC' ||
                    specs.bluetoothCodec == 'aptX HD' ||
                    specs.bluetoothCodec == 'LC3',
              ),
          ],
        ),
        const SizedBox(height: 16),
      ],
    );
  }

  Widget _buildSignalChain(AudioHardwareSpecs specs) {
    final nodes = specs.buildPowerampSignalChain(
      sourceCodec: _detectedCodec ?? widget.codec,
      sourceSampleRate: _sampleRate,
      sourceBitDepth: _originalBitDepth,
      sourceChannels: _channels,
    );
    return SizedBox(
      height: 96,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        physics: const BouncingScrollPhysics(),
        itemCount: nodes.length,
        separatorBuilder: (_, __) => _buildChainArrow(),
        itemBuilder: (context, i) => _buildChainNode(nodes[i]),
      ),
    );
  }

  Widget _buildChainArrow() {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 4),
      child: Center(
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 16,
              height: 1.5,
              color: Colors.white24,
            ),
            const Icon(
              Icons.arrow_forward_ios,
              size: 10,
              color: Colors.white38,
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildChainNode(SignalChainNode node) {
    final primaryColor = AppThemeService.instance.currentData.primary;
    final accent = node.isHighlight ? primaryColor : Colors.white24;
    final labelColor = node.isHighlight ? primaryColor : Colors.white70;

    return Container(
      width: 130,
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      decoration: BoxDecoration(
        color: node.isHighlight
            ? primaryColor.withValues(alpha: 0.12)
            : Colors.white.withValues(alpha: 0.05),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(
          color: accent.withValues(alpha: node.isHighlight ? 0.6 : 0.3),
          width: node.isHighlight ? 1.5 : 1.0,
        ),
      ),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(
            _iconDataForNode(node.icon),
            size: 18,
            color: labelColor,
          ),
          const SizedBox(height: 6),
          Text(
            node.label,
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.bold,
              color: labelColor,
            ),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          if (node.sublabel != null) ...[
            const SizedBox(height: 2),
            Text(
              node.sublabel!,
              style: TextStyle(
                fontSize: 10,
                color: node.isHighlight
                    ? primaryColor.withValues(alpha: 0.8)
                    : Colors.white38,
              ),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
          ],
        ],
      ),
    );
  }

  IconData _iconDataForNode(SignalChainIcon icon) {
    switch (icon) {
      case SignalChainIcon.source:
        return Icons.audio_file;
      case SignalChainIcon.dsp:
        return Icons.graphic_eq;
      case SignalChainIcon.backend:
        return Icons.developer_board;
      case SignalChainIcon.bluetooth:
        return Icons.bluetooth_audio;
      case SignalChainIcon.wiredHeadphone:
        return Icons.headphones;
      case SignalChainIcon.usbDac:
        return Icons.usb;
      case SignalChainIcon.speaker:
        return Icons.speaker;
      case SignalChainIcon.hdmi:
        return Icons.tv;
      case SignalChainIcon.output:
        return Icons.output;
    }
  }

  Widget _buildSpecChip(IconData icon, String label, String value,
      {bool isHiRes = false}) {
    return Container(
      width: 160,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.05),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: isHiRes
              ? AppThemeService.instance.currentData.primary
                  .withValues(alpha: 0.6)
              : Colors.white.withValues(alpha: 0.08),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(icon,
                  size: 14,
                  color: isHiRes
                      ? AppThemeService.instance.currentData.primary
                      : Colors.white54),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  label.toUpperCase(),
                  style: TextStyle(
                    fontSize: 10,
                    fontWeight: FontWeight.bold,
                    color: isHiRes
                        ? AppThemeService.instance.currentData.primary
                        : Colors.white54,
                    letterSpacing: 0.5,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Text(
            value,
            style: const TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w600,
              color: Colors.white,
            ),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<PlayerStatus>(
      valueListenable: widget.statusNotifier,
      builder: (context, status, _) {
        if (status.isPlaying) {
          if (!_rotationController.isAnimating) {
            _rotationController.repeat();
          }
        } else {
          if (_rotationController.isAnimating) {
            _rotationController.stop();
          }
        }

        final overrideSecs = widget.durationOverride;
        final baseDurationSecs = (overrideSecs != null && overrideSecs > 0)
            ? overrideSecs.toDouble()
            : status.durationSeconds;

        final trackTotal = widget.queue.isNotEmpty ? widget.queue.length : 0;
        final trackIdx = status.currentIndex >= 0 ? status.currentIndex + 1 : 1;
        final trackPosition = trackTotal > 0 ? '$trackIdx/$trackTotal' : '';

        final duration =
            Duration(milliseconds: (baseDurationSecs * 1000).round());
        final maxMs = duration.inMilliseconds <= 0
            ? 1.0
            : duration.inMilliseconds.toDouble();
        final posMs = status.positionSeconds * 1000.0;

        final displayPosMs = _isDragging
            ? _dragPositionMs.clamp(0.0, maxMs)
            : (_pendingSeekMs?.clamp(0.0, maxMs) ?? posMs.clamp(0.0, maxMs));

        final rawTitle = widget.getTitle(status.currentIndex);
        final title = _customTitle ?? rawTitle;
        final subtitle = _customArtist ?? widget.artist;

        final Color primaryColor = AppThemeService.instance.currentData.primary;
        final Color bgColor = AppThemeService.instance.currentData.bgDark;
        final Shapes albumArtShape = AppThemeService.instance.albumArtShape;
        const Color surfaceColor = Color(0xFF18232E);
        const Color textLight = Colors.white;

        return Theme(
          data: ThemeData.dark().copyWith(
            scaffoldBackgroundColor: bgColor,
            primaryColor: primaryColor,
            colorScheme: ColorScheme.dark(
              primary: primaryColor,
              surface: surfaceColor,
            ),
          ),
          child: Scaffold(
            body: Stack(
              children: [
                // Ambient Dynamic Background Glow Layer
                Positioned.fill(
                  child: Container(
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        begin: Alignment.topCenter,
                        end: Alignment.bottomCenter,
                        colors: [
                          primaryColor.withValues(alpha: 0.18),
                          bgColor,
                        ],
                      ),
                    ),
                  ),
                ),
                PageView(
                  controller: _pageController,
                  scrollDirection: Axis.vertical,
                  physics: const BouncingScrollPhysics(),
                  children: [
                    LayoutBuilder(builder: (context, constraints) {
                      final isDesktop = constraints.maxWidth >= 800;

                      final pureLyrics = _isLoadingLyrics
                          ? Center(
                              child: LoadingIndicatorM3E(
                                  color: primaryColor,
                                  containerColor: primaryColor.withAlpha(50)))
                          : SyncedLyricsWidget(
                              lyricsRaw: _lyricsRaw ?? '',
                              currentPosition:
                                  Duration(milliseconds: displayPosMs.toInt()),
                              onSeek: (targetTime) {
                                widget.player.seekTo(targetTime);
                              },
                              onImportLrc: _pickLrcFile,
                              onRetryFetch: _fetchLyrics,
                            );

                      Widget content;
                      if (isDesktop) {
                        content = Column(
                          children: [
                            const SizedBox(height: 16),
                            // Desktop M3E Expressive Header
                            Padding(
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 32.0, vertical: 8.0),
                              child: Row(
                                children: [
                                  M3EIconButton(
                                    variant: M3EIconButtonVariant.tonal,
                                    icon: const Icon(
                                        Icons.keyboard_arrow_down_rounded,
                                        size: 28),
                                    onPressed: widget.onMinimize,
                                  ),
                                  const SizedBox(width: 16),
                                  Expanded(
                                    child: Column(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.center,
                                      mainAxisSize: MainAxisSize.min,
                                      children: [
                                        Text(
                                          'PLAYING FROM PLAYLIST',
                                          style: TextStyle(
                                            fontSize: 11,
                                            fontWeight: FontWeight.bold,
                                            letterSpacing: 1.5,
                                            color: primaryColor,
                                          ),
                                          overflow: TextOverflow.ellipsis,
                                        ),
                                        const SizedBox(height: 2),
                                        Text(
                                          title,
                                          style: const TextStyle(
                                            fontSize: 15,
                                            fontWeight: FontWeight.w600,
                                            color: textLight,
                                          ),
                                          overflow: TextOverflow.ellipsis,
                                        ),
                                      ],
                                    ),
                                  ),
                                  const SizedBox(width: 16),
                                  M3EIconButton(
                                    variant: M3EIconButtonVariant.outlined,
                                    icon: Icon(
                                      Icons.more_vert_rounded,
                                      color: _isCustomLyricsLoaded
                                          ? primaryColor
                                          : textLight,
                                    ),
                                    onPressed: () =>
                                        _showMoreOptionsMenu(context),
                                  ),
                                ],
                              ),
                            ),
                            Expanded(
                              child: Padding(
                                padding: const EdgeInsets.symmetric(
                                    horizontal: 64.0, vertical: 16.0),
                                child: Row(
                                  crossAxisAlignment: CrossAxisAlignment.center,
                                  children: [
                                    // Left Column (M3E Expressive Album Art Container)
                                    Expanded(
                                      flex: 10,
                                      child: Center(
                                        child: AnimatedSwitcher(
                                          duration:
                                              const Duration(milliseconds: 350),
                                          switchInCurve: Curves.easeOutCubic,
                                          switchOutCurve: Curves.easeInCubic,
                                          transitionBuilder:
                                              (child, animation) {
                                            final dir = _swipeDirection == 0
                                                ? 1
                                                : _swipeDirection;
                                            final begin = child.key ==
                                                    ValueKey(
                                                        status.currentIndex)
                                                ? Offset(dir.toDouble(), 0.0)
                                                : Offset(-dir.toDouble(), 0.0);
                                            final slideAnimation =
                                                Tween<Offset>(
                                              begin: begin,
                                              end: Offset.zero,
                                            ).animate(animation);
                                            return FadeTransition(
                                              opacity: animation,
                                              child: SlideTransition(
                                                position: slideAnimation,
                                                child: child,
                                              ),
                                            );
                                          },
                                          child: AspectRatio(
                                            key: ValueKey(status.currentIndex),
                                            aspectRatio: 1.0,
                                            child: Stack(
                                              children: [
                                                // Album Art Image wrapped in RepaintBoundary
                                                Positioned.fill(
                                                  child: RepaintBoundary(
                                                    child: M3EContainer(
                                                      albumArtShape,
                                                      clipBehavior:
                                                          Clip.antiAlias,
                                                      color: surfaceColor,
                                                      boxShadow: [
                                                        BoxShadow(
                                                          color: primaryColor
                                                              .withValues(
                                                                  alpha: 0.35),
                                                          blurRadius: 36,
                                                          spreadRadius: 4,
                                                          offset: const Offset(
                                                              0, 8),
                                                        ),
                                                        BoxShadow(
                                                          color: Colors.black
                                                              .withValues(
                                                                  alpha: 0.6),
                                                          blurRadius: 28,
                                                          offset: const Offset(
                                                              0, 12),
                                                        ),
                                                      ],
                                                      child: (widget.albumArt !=
                                                                  null &&
                                                              widget.albumArt!
                                                                  .isNotEmpty)
                                                          ? RepaintBoundary(
                                                              child:
                                                                  M3EContainer(
                                                                albumArtShape,
                                                                clipBehavior: Clip
                                                                    .antiAlias,
                                                                child: Image
                                                                    .memory(
                                                                  widget
                                                                      .albumArt!,
                                                                  fit: BoxFit
                                                                      .cover,
                                                                ),
                                                              ),
                                                            )
                                                          : RotationTransition(
                                                              turns:
                                                                  _rotationController,
                                                              child:
                                                                  M3EContainer(
                                                                albumArtShape,
                                                                color:
                                                                    surfaceColor,
                                                                padding:
                                                                    const EdgeInsets
                                                                        .all(
                                                                        32.0),
                                                                child:
                                                                    Image.asset(
                                                                  'assets/icon/splash.png',
                                                                  fit: BoxFit
                                                                      .contain,
                                                                ),
                                                              ),
                                                            ),
                                                    ),
                                                  ),
                                                ),
                                                // Bottom Gradient Fade Overlay
                                                /*        Positioned(
                                                bottom: 0,
                                                left: 0,
                                                right: 0,
                                                height: 160,
                                                child: Container(
                                                  decoration: BoxDecoration(
                                                    borderRadius:
                                                        const BorderRadius
                                                            .vertical(
                                                            bottom:
                                                                Radius.circular(
                                                                    32.0)),
                                                    gradient: LinearGradient(
                                                      begin:
                                                          Alignment.topCenter,
                                                      end: Alignment
                                                          .bottomCenter,
                                                      colors: [
                                                        Colors.transparent,
                                                        Colors.black.withValues(
                                                            alpha: 0.9),
                                                      ],
                                                    ),
                                                  ),
                                                ),
                                              ),*/
                                                // Text Info (Title, Artist)
                                                Positioned(
                                                  left: 32,
                                                  bottom: 76,
                                                  right: 32,
                                                  child: Column(
                                                    crossAxisAlignment:
                                                        CrossAxisAlignment
                                                            .start,
                                                    children: [
                                                      AdaptiveMarqueeText(
                                                        text: title,
                                                        style: const TextStyle(
                                                          fontSize: 32,
                                                          fontWeight:
                                                              FontWeight.bold,
                                                          color: textLight,
                                                          letterSpacing: -0.5,
                                                        ),
                                                        blankSpace: 40.0,
                                                        velocity: 30.0,
                                                      ),
                                                      const SizedBox(height: 6),
                                                      Text(
                                                        subtitle,
                                                        style: TextStyle(
                                                          fontSize: 18,
                                                          fontWeight:
                                                              FontWeight.w600,
                                                          color: Colors.white
                                                              .withValues(
                                                                  alpha: 0.8),
                                                        ),
                                                        maxLines: 1,
                                                        overflow: TextOverflow
                                                            .ellipsis,
                                                      ),
                                                    ],
                                                  ),
                                                ),
                                                // Bottom Interactive Actions
                                                Positioned(
                                                  bottom: 20,
                                                  left: 28,
                                                  right: 28,
                                                  child: Row(
                                                    mainAxisAlignment:
                                                        MainAxisAlignment
                                                            .spaceBetween,
                                                    children: [
                                                      Row(
                                                        children: [
                                                          ValueListenableBuilder<
                                                              List<LikedSong>>(
                                                            valueListenable:
                                                                LikedSongsService
                                                                    .instance
                                                                    .likedSongsNotifier,
                                                            builder: (context,
                                                                likedSongs, _) {
                                                              final trackId = widget
                                                                      .videoId ??
                                                                  widget.getTitle(
                                                                      status
                                                                          .currentIndex);
                                                              final isCurrentlyLiked =
                                                                  likedSongs.any((s) =>
                                                                      s.videoId ==
                                                                      trackId);
                                                              return M3EIconButton(
                                                                variant: isCurrentlyLiked
                                                                    ? M3EIconButtonVariant
                                                                        .filled
                                                                    : M3EIconButtonVariant
                                                                        .outlined,
                                                                icon: Icon(
                                                                  isCurrentlyLiked
                                                                      ? Icons
                                                                          .thumb_up_rounded
                                                                      : Icons
                                                                          .thumb_up_outlined,
                                                                ),
                                                                onPressed:
                                                                    () async {
                                                                  if (trackId
                                                                      .isEmpty) {
                                                                    return;
                                                                  }
                                                                  if (isCurrentlyLiked) {
                                                                    await LikedSongsService
                                                                        .instance
                                                                        .removeLikedSong(
                                                                            trackId);
                                                                  } else {
                                                                    await LikedSongsService
                                                                        .instance
                                                                        .addLikedSong(
                                                                            LikedSong(
                                                                      videoId:
                                                                          trackId,
                                                                      title:
                                                                          title,
                                                                      artist:
                                                                          subtitle,
                                                                      thumbnailUrl: widget.albumArt ==
                                                                              null
                                                                          ? null
                                                                          : trackId,
                                                                      durationSeconds:
                                                                          duration
                                                                              .inSeconds,
                                                                      likedAt:
                                                                          DateTime
                                                                              .now(),
                                                                    ));
                                                                  }
                                                                },
                                                              );
                                                            },
                                                          ),
                                                          const SizedBox(
                                                              width: 12),
                                                          M3EIconButton(
                                                            variant:
                                                                M3EIconButtonVariant
                                                                    .outlined,
                                                            icon: const Icon(Icons
                                                                .thumb_down_outlined),
                                                            onPressed: () {},
                                                          ),
                                                        ],
                                                      ),
                                                      Row(
                                                        children: [
                                                          M3EIconButton(
                                                            variant:
                                                                M3EIconButtonVariant
                                                                    .tonal,
                                                            icon: const Icon(Icons
                                                                .playlist_play_rounded),
                                                            onPressed: () =>
                                                                _showQueueSheet(
                                                                    context),
                                                          ),
                                                        ],
                                                      ),
                                                    ],
                                                  ),
                                                ),
                                                // Lyrics Overlay on Album Art (Topmost)
                                                _buildAlbumArtLyricsOverlay(
                                                  borderRadius: 32.0,
                                                  bottomOffset: 0.0,
                                                  displayPosMs: displayPosMs,
                                                  title: title,
                                                ),
                                              ],
                                            ),
                                          ),
                                        ),
                                      ),
                                    ),
                                    const SizedBox(width: 48),
                                    // Right Column (Lyrics/Controls/Sliders)
                                    Expanded(
                                      flex: 11,
                                      child: Column(
                                        mainAxisAlignment:
                                            MainAxisAlignment.center,
                                        children: [
                                          if (_showLyrics)
                                            Expanded(
                                                child: RepaintBoundary(
                                                    child: pureLyrics))
                                          else
                                            const Spacer(),

                                          // M3 Expressive Secondary Action Toolbar
                                          RepaintBoundary(
                                            child: M3EToolbar(
                                              actions: <M3EToolbarItem>[
                                                /*     M3EToolbarAction(
                                                  icon:
                                                      Icons.graphic_eq_rounded,
                                                  onPressed: () {
                                                    Navigator.push(
                                                        context,
                                                        MaterialPageRoute(
                                                            builder: (context) =>
                                                                EffectsScreen(
                                                                  player: widget
                                                                      .player,
                                                                  analyzerEnabled:
                                                                      _isAnalyzerEnabled,
                                                                  analyzerType:
                                                                      widget
                                                                          .analyzerType,
                                                                  analyzerAutoFit:
                                                                      widget
                                                                          .analyzerAutoFit,
                                                                  analyzerShowGrids:
                                                                      widget
                                                                          .analyzerShowGrids,
                                                                  outputSampleRate:
                                                                      widget
                                                                          .outputSampleRate,
                                                                )));
                                                  },
                                                ),*/
                                                M3EToolbarAction(
                                                  icon: ((_currentRate - 1.0)
                                                                  .abs() >
                                                              0.01 ||
                                                          (_currentPitch - 1.0)
                                                                  .abs() >
                                                              0.01)
                                                      ? Icons.speed_rounded
                                                      : Icons.speed_outlined,
                                                  onPressed: () =>
                                                      showPlaybackSpeedModal(
                                                    context,
                                                    widget.player,
                                                    currentRate: _currentRate,
                                                    currentPitch: _currentPitch,
                                                    currentPitchCorrection:
                                                        _currentPitchCorrection,
                                                    onRateChanged: (r) =>
                                                        setState(() =>
                                                            _currentRate = r),
                                                    onPitchChanged: (p) =>
                                                        setState(() =>
                                                            _currentPitch = p),
                                                    onPitchCorrectionChanged:
                                                        (pc) => setState(() =>
                                                            _currentPitchCorrection =
                                                                pc),
                                                  ),
                                                ),
                                                M3EToolbarAction(
                                                  icon: _loopIcon(
                                                      status.loopMode),
                                                  onPressed: () {
                                                    final currentMode =
                                                        status.loopMode;
                                                    final nextMode =
                                                        currentMode ==
                                                                LoopMode.off
                                                            ? LoopMode.all
                                                            : (currentMode ==
                                                                    LoopMode.all
                                                                ? LoopMode.one
                                                                : LoopMode.off);
                                                    widget.player
                                                        .setLoopMode(nextMode);
                                                  },
                                                ),
                                                M3EToolbarAction(
                                                  icon: status.shuffleEnabled
                                                      ? Icons.shuffle_on_rounded
                                                      : Icons.shuffle_rounded,
                                                  onPressed: () {
                                                    widget.player
                                                        .setShuffleModeEnabled(
                                                            !status
                                                                .shuffleEnabled);
                                                  },
                                                ),
                                                M3EToolbarAction(
                                                  icon: _showLyrics
                                                      ? Icons.lyrics_rounded
                                                      : Icons.lyrics_outlined,
                                                  onPressed: () {
                                                    setState(() => _showLyrics =
                                                        !_showLyrics);
                                                  },
                                                ),
                                                M3EToolbarWidget(
                                                  child: _buildAbRepeatButton(
                                                    currentPositionMs:
                                                        displayPosMs,
                                                    maxMs: maxMs,
                                                  ),
                                                ),
                                              ],
                                            ),
                                          ),
                                          const SizedBox(height: 36),

                                          // Main Playback Controls
                                          RepaintBoundary(
                                            child: Row(
                                              mainAxisAlignment:
                                                  MainAxisAlignment.center,
                                              children: [
                                                M3EIconButton(
                                                  variant: M3EIconButtonVariant
                                                      .standard,
                                                  icon: const Icon(
                                                      Icons.fast_rewind_rounded,
                                                      size: 32),
                                                  onPressed: () {
                                                    widget.player.seekTo(Duration(
                                                        milliseconds:
                                                            (displayPosMs -
                                                                    10000)
                                                                .toInt()
                                                                .clamp(
                                                                    0,
                                                                    maxMs
                                                                        .toInt())));
                                                  },
                                                ),
                                                const SizedBox(width: 12),
                                                M3EIconButton(
                                                  variant: M3EIconButtonVariant
                                                      .tonal,
                                                  icon: const Icon(
                                                      Icons
                                                          .skip_previous_rounded,
                                                      size: 36),
                                                  onPressed: widget
                                                      .player.seekToPrevious,
                                                ),
                                                const SizedBox(width: 20),
                                                // Center Play/Pause Button
                                                GestureDetector(
                                                  onTap: status.isPlaying
                                                      ? widget.player.pause
                                                      : widget.player.play,
                                                  child: M3EContainer.circle(
                                                    width: 84,
                                                    height: 84,
                                                    color: primaryColor,
                                                    boxShadow: [
                                                      BoxShadow(
                                                        color: primaryColor
                                                            .withValues(
                                                                alpha: 0.45),
                                                        blurRadius: 24,
                                                        spreadRadius: 2,
                                                      )
                                                    ],
                                                    child: Center(
                                                      child: _isBuffering
                                                          ? const SizedBox(
                                                              width: 36,
                                                              height: 36,
                                                              child: M3EProgressIndicator
                                                                  .circularWavy(
                                                                strokeWidth:
                                                                    3.5,
                                                                trackColor:
                                                                    Colors
                                                                        .white,
                                                              ),
                                                            )
                                                          : Icon(
                                                              status.isPlaying
                                                                  ? Icons
                                                                      .pause_rounded
                                                                  : Icons
                                                                      .play_arrow_rounded,
                                                              size: 48,
                                                              color:
                                                                  Colors.white,
                                                            ),
                                                    ),
                                                  ),
                                                ),
                                                const SizedBox(width: 20),
                                                M3EIconButton(
                                                  variant: M3EIconButtonVariant
                                                      .tonal,
                                                  icon: const Icon(
                                                      Icons.skip_next_rounded,
                                                      size: 36),
                                                  onPressed:
                                                      widget.player.seekToNext,
                                                ),
                                                const SizedBox(width: 12),
                                                M3EIconButton(
                                                  variant: M3EIconButtonVariant
                                                      .standard,
                                                  icon: const Icon(
                                                      Icons
                                                          .fast_forward_rounded,
                                                      size: 32),
                                                  onPressed: () {
                                                    widget.player.seekTo(Duration(
                                                        milliseconds:
                                                            (displayPosMs +
                                                                    10000)
                                                                .toInt()
                                                                .clamp(
                                                                    0,
                                                                    maxMs
                                                                        .toInt())));
                                                  },
                                                ),
                                              ],
                                            ),
                                          ),
                                          const SizedBox(height: 36),

                                          // Seek Bar & Diagnostic Info Chip wrapped in RepaintBoundary
                                          RepaintBoundary(
                                            child: Column(
                                              children: [
                                                if (_abRepeatState >= 1)
                                                  _buildAbRegionLabels(
                                                      maxMs: maxMs),
                                                LayoutBuilder(
                                                  builder:
                                                      (context, constraints) {
                                                    return _buildSeekBarWidget(
                                                      displayPosMs:
                                                          displayPosMs,
                                                      maxMs: maxMs,
                                                      totalWidth:
                                                          constraints.maxWidth,
                                                      isMobile: false,
                                                      primaryColor:
                                                          primaryColor,
                                                    );
                                                  },
                                                ),
                                                const SizedBox(height: 10),
                                                Row(
                                                  mainAxisAlignment:
                                                      MainAxisAlignment
                                                          .spaceBetween,
                                                  children: [
                                                    Text(
                                                      _fmt(Duration(
                                                          milliseconds:
                                                              displayPosMs
                                                                  .toInt())),
                                                      style: const TextStyle(
                                                          fontSize: 14,
                                                          color: Colors.white,
                                                          fontWeight:
                                                              FontWeight.bold),
                                                    ),
                                                    // M3E Audio Diagnostic Badge Chip
                                                    M3EChip(
                                                      leading: Icon(
                                                        Icons.info,
                                                        size: 13,
                                                        color: primaryColor,
                                                      ),
                                                      label:
                                                          _buildAudioInfoBadgeText(
                                                              trackPosition),
                                                      onPressed: () =>
                                                          showAudioEngineDiagnosticPanel(
                                                              context,
                                                              widget.player),
                                                    ),
                                                    Text(
                                                      _fmt(duration),
                                                      style: const TextStyle(
                                                          fontSize: 14,
                                                          color: Colors.white,
                                                          fontWeight:
                                                              FontWeight.bold),
                                                    ),
                                                  ],
                                                ),
                                              ],
                                            ),
                                          ),
                                          if (!_showLyrics) const Spacer(),
                                        ],
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ),
                            const SizedBox(height: 8),
                            Center(
                              child: M3EChip(
                                leading:
                                    const Icon(Icons.keyboard_arrow_up_rounded),
                                label: "UP NEXT",
                                onPressed: () => _showQueueSheet(context),
                              ),
                            ),
                            const SizedBox(height: 8),
                          ],
                        );
                      } else {
                        // Mobile Layout (< 800px)
                        content = Column(
                          children: [
                            const SizedBox(height: 24),
                            // Mobile Header Bar
                            Padding(
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 16.0, vertical: 4.0),
                              child: Row(
                                children: [
                                  M3EIconButton(
                                    variant: M3EIconButtonVariant.tonal,
                                    icon: const Icon(
                                        Icons.keyboard_arrow_down_rounded,
                                        size: 28),
                                    onPressed: widget.onMinimize,
                                  ),
                                  Expanded(
                                    child: Column(
                                      mainAxisSize: MainAxisSize.min,
                                      children: [
                                        Text(
                                          'PLAYING FROM PLAYLIST',
                                          style: TextStyle(
                                            fontSize: 10,
                                            fontWeight: FontWeight.bold,
                                            letterSpacing: 1.5,
                                            color: primaryColor,
                                          ),
                                          overflow: TextOverflow.ellipsis,
                                        ),
                                        const SizedBox(height: 2),
                                        const Text(
                                          'Now Playing',
                                          style: TextStyle(
                                            fontSize: 14,
                                            fontWeight: FontWeight.w600,
                                            color: textLight,
                                          ),
                                          overflow: TextOverflow.ellipsis,
                                        ),
                                      ],
                                    ),
                                  ),
                                  M3EIconButton(
                                    variant: M3EIconButtonVariant.outlined,
                                    icon: Icon(
                                      Icons.more_vert_rounded,
                                      color: _isCustomLyricsLoaded
                                          ? primaryColor
                                          : textLight,
                                    ),
                                    onPressed: () =>
                                        _showMoreOptionsMenu(context),
                                  ),
                                ],
                              ),
                            ),
                            const SizedBox(height: 8),

                            // Mobile Album Art Container wrapped in RepaintBoundary
                            Expanded(
                              flex: 5,
                              child: Padding(
                                padding: const EdgeInsets.symmetric(
                                    horizontal: 20.0),
                                child: Center(
                                  child: AnimatedSwitcher(
                                    duration: const Duration(milliseconds: 350),
                                    switchInCurve: Curves.easeOutCubic,
                                    switchOutCurve: Curves.easeInCubic,
                                    transitionBuilder: (child, animation) {
                                      final dir = _swipeDirection == 0
                                          ? 1
                                          : _swipeDirection;
                                      final begin = child.key ==
                                              ValueKey(status.currentIndex)
                                          ? Offset(dir.toDouble(), 0.0)
                                          : Offset(-dir.toDouble(), 0.0);
                                      final slideAnimation = Tween<Offset>(
                                        begin: begin,
                                        end: Offset.zero,
                                      ).animate(animation);
                                      return FadeTransition(
                                        opacity: animation,
                                        child: SlideTransition(
                                          position: slideAnimation,
                                          child: child,
                                        ),
                                      );
                                    },
                                    child: AspectRatio(
                                      key: ValueKey(status.currentIndex),
                                      aspectRatio: 1.0,
                                      child: Stack(
                                        children: [
                                          Positioned.fill(
                                            child: RepaintBoundary(
                                              child: M3EContainer(
                                                albumArtShape,
                                                clipBehavior: Clip.antiAlias,
                                                color: surfaceColor,
                                                boxShadow: [
                                                  BoxShadow(
                                                    color: primaryColor
                                                        .withValues(alpha: 0.3),
                                                    blurRadius: 28,
                                                    spreadRadius: 2,
                                                    offset: const Offset(0, 6),
                                                  ),
                                                ],
                                                child: (widget.albumArt !=
                                                            null &&
                                                        widget.albumArt!
                                                            .isNotEmpty)
                                                    ? M3EContainer(
                                                        albumArtShape,
                                                        clipBehavior:
                                                            Clip.antiAlias,
                                                        child: Image.memory(
                                                          widget.albumArt!,
                                                          fit: BoxFit.cover,
                                                        ),
                                                      )
                                                    : RotationTransition(
                                                        turns:
                                                            _rotationController,
                                                        child: M3EContainer(
                                                          albumArtShape,
                                                          color: surfaceColor,
                                                          padding:
                                                              const EdgeInsets
                                                                  .all(24.0),
                                                          child: Image.asset(
                                                            'assets/icon/splash.png',
                                                            fit: BoxFit.contain,
                                                          ),
                                                        ),
                                                      ),
                                              ),
                                            ),
                                          ),
                                          /* Positioned(
                                          bottom: 0,
                                          left: 0,
                                          right: 0,
                                          height: 120,
                                          child: Container(
                                            decoration: BoxDecoration(
                                              borderRadius:
                                                  const BorderRadius.vertical(
                                                      bottom: Radius.circular(
                                                          24.0)),
                                              gradient: LinearGradient(
                                                begin: Alignment.topCenter,
                                                end: Alignment.bottomCenter,
                                                colors: [
                                                  Colors.transparent,
                                                  Colors.black
                                                      .withValues(alpha: 0.85),
                                                ],
                                              ),
                                            ),
                                          ),
                                        ),*/
                                          Positioned(
                                            left: 16,
                                            bottom: 56,
                                            right: 16,
                                            child: Column(
                                              crossAxisAlignment:
                                                  CrossAxisAlignment.start,
                                              children: [
                                                AdaptiveMarqueeText(
                                                  text: title,
                                                  style: const TextStyle(
                                                    fontSize: 22,
                                                    fontWeight: FontWeight.bold,
                                                    color: textLight,
                                                  ),
                                                  blankSpace: 40.0,
                                                  velocity: 30.0,
                                                ),
                                                const SizedBox(height: 4),
                                                Text(
                                                  subtitle,
                                                  style: const TextStyle(
                                                    fontSize: 15,
                                                    fontWeight: FontWeight.w600,
                                                    color: Colors.white70,
                                                  ),
                                                  maxLines: 1,
                                                  overflow:
                                                      TextOverflow.ellipsis,
                                                ),
                                              ],
                                            ),
                                          ),
                                          Positioned(
                                            bottom: 12,
                                            left: 16,
                                            right: 16,
                                            child: Row(
                                              mainAxisAlignment:
                                                  MainAxisAlignment
                                                      .spaceBetween,
                                              children: [
                                                Row(
                                                  children: [
                                                    ValueListenableBuilder<
                                                        List<LikedSong>>(
                                                      valueListenable:
                                                          LikedSongsService
                                                              .instance
                                                              .likedSongsNotifier,
                                                      builder: (context,
                                                          likedSongs, _) {
                                                        final trackId = widget
                                                                .videoId ??
                                                            widget.getTitle(status
                                                                .currentIndex);
                                                        final isCurrentlyLiked =
                                                            likedSongs.any(
                                                                (s) =>
                                                                    s.videoId ==
                                                                    trackId);
                                                        return M3EIconButton(
                                                          variant: isCurrentlyLiked
                                                              ? M3EIconButtonVariant
                                                                  .filled
                                                              : M3EIconButtonVariant
                                                                  .outlined,
                                                          icon: Icon(
                                                            isCurrentlyLiked
                                                                ? Icons
                                                                    .thumb_up_rounded
                                                                : Icons
                                                                    .thumb_up_outlined,
                                                          ),
                                                          onPressed: () async {
                                                            if (trackId
                                                                .isEmpty) {
                                                              return;
                                                            }
                                                            if (isCurrentlyLiked) {
                                                              await LikedSongsService
                                                                  .instance
                                                                  .removeLikedSong(
                                                                      trackId);
                                                            } else {
                                                              await LikedSongsService
                                                                  .instance
                                                                  .addLikedSong(
                                                                      LikedSong(
                                                                videoId:
                                                                    trackId,
                                                                title: title,
                                                                artist:
                                                                    subtitle,
                                                                thumbnailUrl:
                                                                    widget.albumArt ==
                                                                            null
                                                                        ? null
                                                                        : trackId,
                                                                durationSeconds:
                                                                    duration
                                                                        .inSeconds,
                                                                likedAt:
                                                                    DateTime
                                                                        .now(),
                                                              ));
                                                            }
                                                          },
                                                        );
                                                      },
                                                    ),
                                                    const SizedBox(width: 8),
                                                    M3EIconButton(
                                                      variant:
                                                          M3EIconButtonVariant
                                                              .outlined,
                                                      icon: const Icon(Icons
                                                          .thumb_down_outlined),
                                                      onPressed: () {},
                                                    ),
                                                  ],
                                                ),
                                                Row(
                                                  children: [
                                                    M3EIconButton(
                                                      variant: (_showLyricsOverlayOnAlbumArt ||
                                                              _showLyrics)
                                                          ? M3EIconButtonVariant
                                                              .filled
                                                          : M3EIconButtonVariant
                                                              .tonal,
                                                      icon: Icon(
                                                        (_showLyricsOverlayOnAlbumArt ||
                                                                _showLyrics)
                                                            ? Icons
                                                                .lyrics_rounded
                                                            : Icons
                                                                .lyrics_outlined,
                                                        color:
                                                            (_showLyricsOverlayOnAlbumArt ||
                                                                    _showLyrics)
                                                                ? Colors.white
                                                                : primaryColor,
                                                      ),
                                                      onPressed: () {
                                                        setState(() {
                                                          _showLyricsOverlayOnAlbumArt =
                                                              !_showLyricsOverlayOnAlbumArt;
                                                          _showLyrics =
                                                              _showLyricsOverlayOnAlbumArt;
                                                        });
                                                      },
                                                    ),
                                                    const SizedBox(width: 8),
                                                    M3EIconButton(
                                                      variant:
                                                          M3EIconButtonVariant
                                                              .tonal,
                                                      icon: const Icon(Icons
                                                          .playlist_play_rounded),
                                                      onPressed: () =>
                                                          _showQueueSheet(
                                                              context),
                                                    ),
                                                  ],
                                                ),
                                              ],
                                            ),
                                          ),
                                          // Lyrics Overlay on Album Art (Topmost layer)
                                          _buildAlbumArtLyricsOverlay(
                                            borderRadius: 24.0,
                                            bottomOffset: 0.0,
                                            displayPosMs: displayPosMs,
                                            title: title,
                                          ),
                                        ],
                                      ),
                                    ),
                                  ),
                                ),
                              ),
                            ),
                            const SizedBox(height: 8),

                            // Mobile Playback Controls wrapped in RepaintBoundary
                            RepaintBoundary(
                              child: Row(
                                mainAxisAlignment: MainAxisAlignment.center,
                                children: [
                                  M3EIconButton(
                                    variant: M3EIconButtonVariant.standard,
                                    icon: const Icon(Icons.fast_rewind_rounded,
                                        size: 28),
                                    onPressed: () {
                                      widget.player.seekTo(Duration(
                                          milliseconds: (displayPosMs - 10000)
                                              .toInt()
                                              .clamp(0, maxMs.toInt())));
                                    },
                                  ),
                                  const SizedBox(width: 8),
                                  M3EIconButton(
                                    variant: M3EIconButtonVariant.tonal,
                                    icon: const Icon(
                                        Icons.skip_previous_rounded,
                                        size: 32),
                                    onPressed: widget.player.seekToPrevious,
                                  ),
                                  const SizedBox(width: 16),
                                  GestureDetector(
                                    onTap: status.isPlaying
                                        ? widget.player.pause
                                        : widget.player.play,
                                    child: M3EContainer.circle(
                                      width: 72,
                                      height: 72,
                                      color: primaryColor,
                                      boxShadow: [
                                        BoxShadow(
                                          color: primaryColor.withValues(
                                              alpha: 0.45),
                                          blurRadius: 20,
                                          spreadRadius: 2,
                                        )
                                      ],
                                      child: Center(
                                        child: _isBuffering
                                            ? const SizedBox(
                                                width: 32,
                                                height: 32,
                                                child:
                                                    CircularProgressIndicator(
                                                  strokeWidth: 3.0,
                                                  valueColor:
                                                      AlwaysStoppedAnimation<
                                                          Color>(Colors.white),
                                                ),
                                              )
                                            : Icon(
                                                status.isPlaying
                                                    ? Icons.pause_rounded
                                                    : Icons.play_arrow_rounded,
                                                size: 40,
                                                color: Colors.white,
                                              ),
                                      ),
                                    ),
                                  ),
                                  const SizedBox(width: 16),
                                  M3EIconButton(
                                    variant: M3EIconButtonVariant.tonal,
                                    icon: const Icon(Icons.skip_next_rounded,
                                        size: 32),
                                    onPressed: widget.player.seekToNext,
                                  ),
                                  const SizedBox(width: 8),
                                  M3EIconButton(
                                    variant: M3EIconButtonVariant.standard,
                                    icon: const Icon(Icons.fast_forward_rounded,
                                        size: 28),
                                    onPressed: () {
                                      widget.player.seekTo(Duration(
                                          milliseconds: (displayPosMs + 10000)
                                              .toInt()
                                              .clamp(0, maxMs.toInt())));
                                    },
                                  ),
                                ],
                              ),
                            ),

                            const SizedBox(height: 8),

                            // Mobile Seekbar & Format Chip wrapped in RepaintBoundary
                            Padding(
                              padding:
                                  const EdgeInsets.symmetric(horizontal: 20.0),
                              child: RepaintBoundary(
                                child: Column(
                                  children: [
                                    if (_abRepeatState >= 1)
                                      _buildAbRegionLabels(maxMs: maxMs),
                                    LayoutBuilder(
                                      builder: (context, constraints) {
                                        return _buildSeekBarWidget(
                                          displayPosMs: displayPosMs,
                                          maxMs: maxMs,
                                          totalWidth: constraints.maxWidth,
                                          isMobile: true,
                                          primaryColor: primaryColor,
                                        );
                                      },
                                    ),
                                    const SizedBox(height: 6),
                                    Row(
                                      mainAxisAlignment:
                                          MainAxisAlignment.spaceBetween,
                                      children: [
                                        Text(
                                          _fmt(Duration(
                                              milliseconds:
                                                  displayPosMs.toInt())),
                                          style: const TextStyle(
                                              fontSize: 12,
                                              color: Colors.white,
                                              fontWeight: FontWeight.bold),
                                        ),
                                        Flexible(
                                          child: Padding(
                                            padding: const EdgeInsets.symmetric(
                                                horizontal: 4.0),
                                            child: M3EChip(
                                              leading: Icon(
                                                  Icons.info_outline_rounded,
                                                  size: 10,
                                                  color: primaryColor),
                                              label: _buildAudioInfoBadgeText(
                                                  trackPosition),
                                              onPressed: () =>
                                                  showAudioEngineDiagnosticPanel(
                                                      context, widget.player),
                                            ),
                                          ),
                                        ),
                                        Text(
                                          _fmt(duration),
                                          style: const TextStyle(
                                              fontSize: 8,
                                              color: Colors.white,
                                              fontWeight: FontWeight.bold),
                                        ),
                                      ],
                                    ),
                                  ],
                                ),
                              ),
                            ),

                            const SizedBox(height: 12),

                            // Mobile Action Toolbar (EQ, Speed, Loop, Shuffle, A-B)
                            Padding(
                              padding:
                                  const EdgeInsets.symmetric(horizontal: 16.0),
                              child: RepaintBoundary(
                                child: FittedBox(
                                  fit: BoxFit.scaleDown,
                                  child: Row(
                                    mainAxisAlignment:
                                        MainAxisAlignment.spaceEvenly,
                                    children: [
                                      /*  M3EIconButton(
                                        variant: M3EIconButtonVariant.tonal,
                                        icon: const Icon(
                                            Icons.graphic_eq_rounded),
                                        onPressed: () {
                                          Navigator.push(
                                              context,
                                              MaterialPageRoute(
                                                  builder: (context) =>
                                                      EffectsScreen(
                                                        player: widget.player,
                                                        analyzerEnabled:
                                                            _isAnalyzerEnabled,
                                                        analyzerType:
                                                            widget.analyzerType,
                                                        analyzerAutoFit: widget
                                                            .analyzerAutoFit,
                                                        analyzerShowGrids: widget
                                                            .analyzerShowGrids,
                                                        outputSampleRate: widget
                                                            .outputSampleRate,
                                                      )));
                                        },
                                      ),*/
                                      // const SizedBox(width: 8),
                                      M3EIconButton(
                                        variant: M3EIconButtonVariant.tonal,
                                        icon: Icon(((_currentRate - 1.0).abs() >
                                                    0.01 ||
                                                (_currentPitch - 1.0).abs() >
                                                    0.01)
                                            ? Icons.speed_rounded
                                            : Icons.speed_outlined),
                                        onPressed: () => showPlaybackSpeedModal(
                                          context,
                                          widget.player,
                                          currentRate: _currentRate,
                                          currentPitch: _currentPitch,
                                          currentPitchCorrection:
                                              _currentPitchCorrection,
                                          onRateChanged: (r) =>
                                              setState(() => _currentRate = r),
                                          onPitchChanged: (p) =>
                                              setState(() => _currentPitch = p),
                                          onPitchCorrectionChanged: (pc) =>
                                              setState(() =>
                                                  _currentPitchCorrection = pc),
                                        ),
                                      ),
                                      const SizedBox(width: 8),
                                      M3EIconButton(
                                        variant: status.loopMode != LoopMode.off
                                            ? M3EIconButtonVariant.filled
                                            : M3EIconButtonVariant.tonal,
                                        icon: Icon(_loopIcon(status.loopMode)),
                                        onPressed: () {
                                          final currentMode = status.loopMode;
                                          final nextMode =
                                              currentMode == LoopMode.off
                                                  ? LoopMode.all
                                                  : (currentMode == LoopMode.all
                                                      ? LoopMode.one
                                                      : LoopMode.off);
                                          widget.player.setLoopMode(nextMode);
                                        },
                                      ),
                                      const SizedBox(width: 8),
                                      M3EIconButton(
                                        variant: status.shuffleEnabled
                                            ? M3EIconButtonVariant.filled
                                            : M3EIconButtonVariant.tonal,
                                        icon: Icon(status.shuffleEnabled
                                            ? Icons.shuffle_on_rounded
                                            : Icons.shuffle_rounded),
                                        onPressed: () {
                                          widget.player.setShuffleModeEnabled(
                                              !status.shuffleEnabled);
                                        },
                                      ),
                                      const SizedBox(width: 8),
                                      _buildAbRepeatButton(
                                        currentPositionMs: displayPosMs,
                                        maxMs: maxMs,
                                      ),
                                    ],
                                  ),
                                ),
                              ),
                            ),

                            const SizedBox(height: 10),

                            // Queue Navigation (Up Next)
                            Center(
                              child: M3EChip(
                                leading:
                                    const Icon(Icons.keyboard_arrow_up_rounded),
                                label: "UP NEXT",
                                onPressed: () => _showQueueSheet(context),
                              ),
                            ),

                            const SizedBox(height: 6),
                          ],
                        );
                      }

                      return GestureDetector(
                        // Swipe left → next song, swipe right → previous song
                        onHorizontalDragEnd: (details) {
                          const double kSwipeThreshold = 200.0; // px/s
                          final velocity = details.primaryVelocity ?? 0.0;
                          if (velocity < -kSwipeThreshold) {
                            // Swiped left → next
                            setState(() => _swipeDirection = 1);
                            widget.player.seekToNext();
                            Future.delayed(const Duration(milliseconds: 400),
                                () {
                              if (mounted) setState(() => _swipeDirection = 0);
                            });
                          } else if (velocity > kSwipeThreshold) {
                            // Swiped right → previous
                            setState(() => _swipeDirection = -1);
                            widget.player.seekToPrevious();
                            Future.delayed(const Duration(milliseconds: 400),
                                () {
                              if (mounted) setState(() => _swipeDirection = 0);
                            });
                          }
                        },
                        child: Align(
                          alignment: Alignment.topCenter,
                          child: ConstrainedBox(
                            constraints: BoxConstraints(
                                maxWidth: isDesktop ? double.infinity : 600.0),
                            child: SafeArea(
                              child: content,
                            ),
                          ),
                        ),
                      );
                    }),
                    // Queue Screen Page wrapped in RepaintBoundary
                    RepaintBoundary(
                      child: Align(
                        alignment: Alignment.topCenter,
                        child: ConstrainedBox(
                          constraints: BoxConstraints(
                              maxWidth: MediaQuery.of(context).size.width >= 800
                                  ? double.infinity
                                  : 600.0),
                          child: SafeArea(
                            child: _queueMounted
                                ? QueueScreen(
                                    queue: widget.queue,
                                    videoId: widget.videoId,
                                    albumArt: widget.albumArt,
                                    onPlayQueueIndex: widget.onPlayQueueIndex,
                                    onReorderQueue: widget.onReorderQueue,
                                    onRemoveFromQueue: widget.onRemoveFromQueue,
                                    onClearQueue: widget.onClearQueue,
                                    onShuffleQueue: widget.onShuffleQueue,
                                    statusNotifier: widget.statusNotifier,
                                    onClose: () {
                                      if (_pageController.hasClients) {
                                        _pageController.animateToPage(
                                          0,
                                          duration:
                                              const Duration(milliseconds: 350),
                                          curve: Curves.easeOutCubic,
                                        );
                                      }
                                    },
                                  )
                                : const SizedBox.shrink(),
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  // ignore: unused_element
  Widget _buildVisualizer(
      Color primaryColor, List<double> currentAnalyzerValues) {
    const int numBars = 50;

    final visualData = <double>[];
    if (currentAnalyzerValues.isEmpty) {
      for (int i = 0; i < numBars; i++) {
        visualData.add(0.0);
      }
    } else {
      final step = math.max(1, currentAnalyzerValues.length / numBars);
      for (int i = 0; i < numBars; i++) {
        final index =
            (i * step).floor().clamp(0, currentAnalyzerValues.length - 1);
        final val = (currentAnalyzerValues[index] * 8.0).clamp(0.0, 1.0);
        visualData.add(val);
      }
    }

    final barGroups = List.generate(numBars, (i) {
      return BarChartGroupData(
        x: i,
        barRods: [
          BarChartRodData(
            toY: math.max(0.05, visualData[i]),
            color: primaryColor.withValues(alpha: 0.7 + (visualData[i] * 0.3)),
            width: 4,
            borderRadius: BorderRadius.circular(2),
          ),
        ],
      );
    });

    return BarChart(
      BarChartData(
        barTouchData: BarTouchData(enabled: false),
        alignment: BarChartAlignment.spaceBetween,
        maxY: 1.0,
        minY: 0,
        barGroups: barGroups,
        titlesData: const FlTitlesData(show: false),
        borderData: FlBorderData(show: false),
        gridData: const FlGridData(show: false),
      ),
    );
  }

  void _showQueueSheet(BuildContext context) {
    if (!_queueMounted) {
      setState(() => _queueMounted = true);
    }
    if (_pageController.hasClients) {
      _pageController.animateToPage(
        1,
        duration: const Duration(milliseconds: 350),
        curve: Curves.easeOutCubic,
      );
    }
  }

  // ─────────────────────────────────────────────────────────────────────────
  // A-B Repeat helpers
  // ─────────────────────────────────────────────────────────────────────────

  Widget _buildAbRepeatButton({
    required double currentPositionMs,
    required double maxMs,
  }) {
    String tooltip;

    switch (_abRepeatState) {
      case 1:
        tooltip = 'Set Point B';
        break;
      case 2:
        tooltip = 'Clear A-B Repeat';
        break;
      default:
        tooltip = 'Set Point A';
    }

    return GestureDetector(
      onLongPress:
          _abRepeatState == 2 ? () => _showAbRepeatSheet(context, maxMs) : null,
      child: Tooltip(
        message: tooltip,
        child: InkWell(
          borderRadius: BorderRadius.circular(20),
          onTap: () {
            setState(() {
              if (_abRepeatState == 0) {
                _abPointAMs = currentPositionMs;
                _abRepeatState = 1;
              } else if (_abRepeatState == 1) {
                final b = currentPositionMs;
                final a = _abPointAMs!;
                if (b > a + 500) {
                  _abPointBMs = b;
                  _abRepeatState = 2;
                  widget.player.setAbRepeat(
                    enabled: true,
                    startSeconds: a / 1000.0,
                    endSeconds: b / 1000.0,
                  );
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(
                      content: Row(
                        children: [
                          Icon(Icons.repeat_on_rounded,
                              color:
                                  AppThemeService.instance.currentData.primary,
                              size: 18),
                          const SizedBox(width: 8),
                          Text(
                            'A-B Loop Active: ${_fmt(Duration(milliseconds: a.toInt()))} ⇄ ${_fmt(Duration(milliseconds: b.toInt()))}',
                            style: const TextStyle(
                                color: Colors.white,
                                fontWeight: FontWeight.bold),
                          ),
                        ],
                      ),
                      backgroundColor: const Color(0xFF1E2D3D),
                      duration: const Duration(seconds: 2),
                    ),
                  );
                } else {
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(
                      content:
                          Text('Point B must be at least 0.5s after Point A'),
                      backgroundColor: Color(0xFF1E2D3D),
                      duration: Duration(seconds: 2),
                    ),
                  );
                }
              } else {
                _abRepeatState = 0;
                _abPointAMs = null;
                _abPointBMs = null;
                widget.player.setAbRepeat(
                    enabled: false, startSeconds: 0, endSeconds: 0);
              }
            });
          },
          child: _AbRepeatCustomIcon(state: _abRepeatState),
        ),
      ),
    );
  }

  Widget _buildAbRegionLabels({required double maxMs}) {
    if (_abPointAMs == null) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(bottom: 2.0),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
            decoration: BoxDecoration(
              color: const Color(0xFFFFA726).withValues(alpha: 0.2),
              borderRadius: BorderRadius.circular(6),
              border: Border.all(color: const Color(0xFFFFA726), width: 1),
            ),
            child: Text(
              'A ${_fmt(Duration(milliseconds: _abPointAMs!.toInt()))}',
              style: const TextStyle(
                fontSize: 10,
                fontWeight: FontWeight.bold,
                color: Color(0xFFFFA726),
              ),
            ),
          ),
          if (_abRepeatState == 2 && _abPointBMs != null)
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
              decoration: BoxDecoration(
                color: AppThemeService.instance.currentData.primary
                    .withValues(alpha: 0.2),
                borderRadius: BorderRadius.circular(6),
                border: Border.all(
                    color: AppThemeService.instance.currentData.primary,
                    width: 1),
              ),
              child: Text(
                'B ${_fmt(Duration(milliseconds: _abPointBMs!.toInt()))}',
                style: TextStyle(
                  fontSize: 10,
                  fontWeight: FontWeight.bold,
                  color: AppThemeService.instance.currentData.primary,
                ),
              ),
            )
          else
            const Text(
              '← tap button to set B',
              style: TextStyle(fontSize: 10, color: Colors.white38),
            ),
        ],
      ),
    );
  }

  void _showAbRepeatSheet(BuildContext context, double maxMs) {
    M3EBottomSheet.show<void>(
      context,
      builder: (ctx) {
        double localA = _abPointAMs ?? 0;
        double localB = _abPointBMs ?? maxMs;
        return Material(
          color: const Color(0xFF18232E),
          borderRadius: const BorderRadius.vertical(top: Radius.circular(28)),
          child: StatefulBuilder(
            builder: (ctx, setSheetState) {
              void apply() {
                setState(() {
                  _abPointAMs = localA;
                  _abPointBMs = localB;
                });
                widget.player.setAbRepeat(
                  enabled: true,
                  startSeconds: localA / 1000.0,
                  endSeconds: localB / 1000.0,
                );
              }

              return Padding(
                padding: const EdgeInsets.fromLTRB(20, 16, 20, 32),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Center(
                      child: Container(
                        width: 36,
                        height: 4,
                        margin: const EdgeInsets.only(bottom: 16),
                        decoration: BoxDecoration(
                          color: Colors.white24,
                          borderRadius: BorderRadius.circular(2),
                        ),
                      ),
                    ),
                    Text(
                      'A-B REPEAT FINE-TUNE',
                      style: TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.bold,
                        letterSpacing: 1.2,
                        color: AppThemeService.instance.currentData.primary,
                      ),
                    ),
                    const SizedBox(height: 20),
                    Row(
                      children: [
                        const Text('Point A',
                            style: TextStyle(
                                color: Color(0xFFFFA726),
                                fontWeight: FontWeight.bold)),
                        const Spacer(),
                        M3EIconButton(
                          variant: M3EIconButtonVariant.tonal,
                          icon: const Icon(Icons.remove, color: Colors.white70),
                          onPressed: () {
                            setSheetState(() {
                              localA = (localA - 100).clamp(0, localB - 500);
                            });
                            apply();
                          },
                        ),
                        const SizedBox(width: 8),
                        Text(_fmt(Duration(milliseconds: localA.toInt())),
                            style: const TextStyle(
                                color: Colors.white,
                                fontWeight: FontWeight.bold)),
                        const SizedBox(width: 8),
                        M3EIconButton(
                          variant: M3EIconButtonVariant.tonal,
                          icon: const Icon(Icons.add, color: Colors.white70),
                          onPressed: () {
                            setSheetState(() {
                              localA = (localA + 100).clamp(0, localB - 500);
                            });
                            apply();
                          },
                        ),
                      ],
                    ),
                    const SizedBox(height: 12),
                    Row(
                      children: [
                        Text('Point B',
                            style: TextStyle(
                                color: AppThemeService
                                    .instance.currentData.primary,
                                fontWeight: FontWeight.bold)),
                        const Spacer(),
                        M3EIconButton(
                          variant: M3EIconButtonVariant.tonal,
                          icon: const Icon(Icons.remove, color: Colors.white70),
                          onPressed: () {
                            setSheetState(() {
                              localB =
                                  (localB - 100).clamp(localA + 500, maxMs);
                            });
                            apply();
                          },
                        ),
                        const SizedBox(width: 8),
                        Text(_fmt(Duration(milliseconds: localB.toInt())),
                            style: const TextStyle(
                                color: Colors.white,
                                fontWeight: FontWeight.bold)),
                        const SizedBox(width: 8),
                        M3EIconButton(
                          variant: M3EIconButtonVariant.tonal,
                          icon: const Icon(Icons.add, color: Colors.white70),
                          onPressed: () {
                            setSheetState(() {
                              localB =
                                  (localB + 100).clamp(localA + 500, maxMs);
                            });
                            apply();
                          },
                        ),
                      ],
                    ),
                    const SizedBox(height: 16),
                    Row(
                      children: [
                        Expanded(
                          child: M3EButton.outlined(
                            onPressed: () {
                              setState(() {
                                _abRepeatState = 0;
                                _abPointAMs = null;
                                _abPointBMs = null;
                              });
                              widget.player.setAbRepeat(
                                  enabled: false,
                                  startSeconds: 0,
                                  endSeconds: 0);
                              Navigator.pop(ctx);
                            },
                            child: const Text('Clear A-B Loop'),
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              );
            },
          ),
        );
      },
    );
  }

  Widget _buildSeekBarWidget({
    required double displayPosMs,
    required double maxMs,
    required double totalWidth,
    required bool isMobile,
    required Color primaryColor,
  }) {
    if (_useWaveformSeekBar &&
        _currentWaveformPeaks != null &&
        _currentWaveformPeaks!.isNotEmpty) {
      return WaveformSeekBarWidget(
        peaks: _currentWaveformPeaks!,
        displayPosMs: displayPosMs,
        maxMs: maxMs,
        abRepeatState: _abRepeatState,
        abPointAMs: _abPointAMs,
        abPointBMs: _abPointBMs,
        height: isMobile ? 42.0 : 48.0,
        activeColor: primaryColor,
        onDragStateChanged: (dragging) {
          setState(() {
            _isDragging = dragging;
          });
        },
        onDragUpdate: (v) {
          setState(() {
            _dragPositionMs = v;
          });
        },
        onSeekEnd: (v) {
          _seekTimeoutTimer?.cancel();
          setState(() {
            _isDragging = false;
            _pendingSeekMs = v;
          });
          widget.player.seekTo(Duration(milliseconds: v.toInt()));
          _seekTimeoutTimer = Timer(const Duration(milliseconds: 1500), () {
            if (mounted) setState(() => _pendingSeekMs = null);
          });
        },
      );
    }

    final Widget sliderWidget = _useWavySlider
        ? M3ESlider.wavy(
            value: displayPosMs.clamp(0.0, maxMs),
            min: 0.0,
            max: maxMs,
            trackThickness: isMobile ? 8.0 : 10.0,
            cornerRadius: 8,
            thumbLength: isMobile ? 24.0 : 28.0,
            showValueIndicator: false,
            onChanged: (v) {
              setState(() {
                _isDragging = true;
                _dragPositionMs = v;
              });
            },
            onChangeEnd: (v) {
              _seekTimeoutTimer?.cancel();
              setState(() {
                _isDragging = false;
                _pendingSeekMs = v;
              });
              widget.player.seekTo(Duration(milliseconds: v.toInt()));
              _seekTimeoutTimer = Timer(const Duration(milliseconds: 1500), () {
                if (mounted) setState(() => _pendingSeekMs = null);
              });
            },
          )
        : M3ESlider(
            value: displayPosMs.clamp(0.0, maxMs),
            min: 0.0,
            max: maxMs,
            trackThickness: isMobile ? 8.0 : 10.0,
            cornerRadius: 8,
            thumbLength: isMobile ? 24.0 : 28.0,
            showValueIndicator: false,
            onChanged: (v) {
              setState(() {
                _isDragging = true;
                _dragPositionMs = v;
              });
            },
            onChangeEnd: (v) {
              _seekTimeoutTimer?.cancel();
              setState(() {
                _isDragging = false;
                _pendingSeekMs = v;
              });
              widget.player.seekTo(Duration(milliseconds: v.toInt()));
              _seekTimeoutTimer = Timer(const Duration(milliseconds: 1500), () {
                if (mounted) setState(() => _pendingSeekMs = null);
              });
            },
          );

    return Stack(
      children: [
        if (_abRepeatState >= 1 && _abPointAMs != null)
          Positioned.fill(
            child: ClipRect(
              child: _AbRegionPainter(
                abRepeatState: _abRepeatState,
                pointAMs: _abPointAMs!,
                pointBMs: _abPointBMs,
                maxMs: maxMs,
                totalWidth: totalWidth,
              ),
            ),
          ),
        sliderWidget,
      ],
    );
  }
}

class _AbRegionPainter extends StatelessWidget {
  final int abRepeatState;
  final double pointAMs;
  final double? pointBMs;
  final double maxMs;
  final double totalWidth;

  const _AbRegionPainter({
    required this.abRepeatState,
    required this.pointAMs,
    this.pointBMs,
    required this.maxMs,
    required this.totalWidth,
  });

  @override
  Widget build(BuildContext context) {
    if (maxMs <= 0) return const SizedBox.shrink();
    const double thumbRadius = 8.0;
    const double horizontalPadding = 24.0;
    final double usable = totalWidth - horizontalPadding * 2 - thumbRadius * 2;
    final double left =
        horizontalPadding + thumbRadius + (pointAMs / maxMs) * usable;
    final double? right = (abRepeatState == 2 && pointBMs != null)
        ? (horizontalPadding + thumbRadius + (pointBMs! / maxMs) * usable)
        : null;
    return CustomPaint(
      painter: _AbHighlightCustomPainter(
        abRepeatState: abRepeatState,
        left: left,
        right: right,
      ),
    );
  }
}

class _AbHighlightCustomPainter extends CustomPainter {
  final int abRepeatState;
  final double left;
  final double? right;

  const _AbHighlightCustomPainter({
    required this.abRepeatState,
    required this.left,
    this.right,
  });

  @override
  void paint(Canvas canvas, Size size) {
    if (abRepeatState == 2 && right != null) {
      final paint = Paint()
        ..color =
            AppThemeService.instance.currentData.primary.withValues(alpha: 0.25)
        ..style = PaintingStyle.fill;
      canvas.drawRect(Rect.fromLTRB(left, 0, right!, size.height), paint);

      final pinBPaint = Paint()
        ..color = AppThemeService.instance.currentData.primary
        ..style = PaintingStyle.fill;
      canvas.drawRect(
          Rect.fromLTRB(right! - 1.5, 0, right! + 1.5, size.height), pinBPaint);
    }

    final pinPaint = Paint()
      ..color = const Color(0xFFFFA726)
      ..style = PaintingStyle.fill;
    canvas.drawRect(
        Rect.fromLTRB(left - 1.5, 0, left + 1.5, size.height), pinPaint);
  }

  @override
  bool shouldRepaint(_AbHighlightCustomPainter old) =>
      old.abRepeatState != abRepeatState ||
      old.left != left ||
      old.right != right;
}

class _AbRepeatCustomIcon extends StatelessWidget {
  final int state;

  const _AbRepeatCustomIcon({required this.state});

  @override
  Widget build(BuildContext context) {
    Color borderClr;
    Color bgClr;
    Color textClr;
    String label;
    IconData iconData;

    switch (state) {
      case 1:
        borderClr = const Color(0xFFFFA726);
        bgClr = const Color(0xFFFFA726).withValues(alpha: 0.22);
        textClr = const Color(0xFFFFA726);
        label = 'A →';
        iconData = Icons.repeat_one_rounded;
        break;
      case 2:
        borderClr = AppThemeService.instance.currentData.primary;
        bgClr = AppThemeService.instance.currentData.primary
            .withValues(alpha: 0.25);
        textClr = const Color(0xFF38BDF8);
        label = 'A-B';
        iconData = Icons.repeat_on_rounded;
        break;
      default:
        borderClr = Colors.white24;
        bgClr = Colors.white10;
        textClr = Colors.white70;
        label = 'A-B';
        iconData = Icons.repeat_rounded;
    }

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      decoration: BoxDecoration(
        color: bgClr,
        borderRadius: BorderRadius.circular(24),
        border: Border.all(
          color: state > 0 ? borderClr : Colors.transparent,
          width: 1.2,
        ),
        boxShadow: state > 0
            ? [
                BoxShadow(
                  color: borderClr.withValues(alpha: 0.35),
                  blurRadius: 8,
                  spreadRadius: 0,
                ),
              ]
            : null,
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            iconData,
            size: 20,
            color: textClr,
          ),
          const SizedBox(width: 6),
          Text(
            label,
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w900,
              letterSpacing: 0.8,
              color: textClr,
            ),
          ),
        ],
      ),
    );
  }
}
