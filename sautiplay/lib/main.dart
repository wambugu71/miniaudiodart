import 'dart:async';
import 'dart:io';
import 'dart:ui';

import 'package:dart_ytmusic_api/dart_ytmusic_api.dart'; // Added
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_cache_manager/flutter_cache_manager.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:showcaseview/showcaseview.dart';
import 'package:flutter_m3shapes_extended/flutter_m3shapes_extended.dart';
import 'package:material_3_expressive/material_3_expressive.dart';
import 'package:material_3_expressive/components/navigation_bar/enums/m3e_nav_bar_enums.dart';
import 'package:material_3_expressive/components/navigation_bar/models/m3e_navigation_bar_destination.dart';
import 'package:audio_metadata_reader/audio_metadata_reader.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:sautiflow/sautiflow.dart';
import 'services/app_theme_service.dart';
import 'services/artwork_theme_service.dart';

import 'album_detail_screen.dart'; // For TrackInfo
import 'effects_screen.dart';
import 'home_screen.dart';
import 'library_screen.dart';
import 'eq_screen.dart';
import 'isolate_player.dart';
import 'mini_player.dart';
import 'models/cached_stream_item.dart';
import 'models/liked_song.dart';
import 'models/recently_played_track.dart';
import 'now_playing_screen.dart';
import 'recently_played_screen.dart';
import 'services/app_state_service.dart';
import 'services/cached_stream_service.dart';
import 'services/lastfm_service.dart';
import 'services/recently_played_service.dart';
import 'settings_screen.dart';
import 'shimmer_mini_player.dart';
import 'widgets/app_showcase.dart';
import 'package:sautiplay/services/dlna_service.dart';
import 'package:sautiplay/services/dlna_renderer_service.dart';
import 'package:sautiplay/services/local_media_server.dart';
import 'services/ftp_service.dart';
import 'services/audio_hardware_inspector.dart';
import 'services/app_update_service.dart';
import 'streaming_service.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  // Metadata God removed in favor of audiotags
  FlutterError.onError = (FlutterErrorDetails details) {
    FlutterError.presentError(details);
    debugPrint('[flutter-error] ${details.exceptionAsString()}');
    if (details.stack != null) {
      debugPrint('${details.stack}');
    }
  };

  PlatformDispatcher.instance.onError = (error, stack) {
    debugPrint('[platform-error] $error');
    debugPrint('$stack');
    return false;
  };

  runApp(const DemoApp());
}

// ─── App root ─────────────────────────────────────────────────────────────────
class DemoApp extends StatefulWidget {
  const DemoApp({super.key});

  @override
  State<DemoApp> createState() => _DemoAppState();
}

class _DemoAppState extends State<DemoApp> {
  AppThemeData _themeData =
      AppThemeService.themes.first; // default until loaded
  Shapes _albumArtShape = Shapes.slanted;
  StreamSubscription<AppThemeId>? _themeSub;
  StreamSubscription<Shapes>? _shapeSub;

  @override
  void initState() {
    super.initState();
    _loadTheme();
    _themeSub = AppThemeService.instance.themeChanged.stream.listen((id) {
      if (mounted) {
        setState(() {
          _themeData = AppThemeService.instance.currentData;
        });
      }
    });
    _shapeSub =
        AppThemeService.instance.albumArtShapeChanged.stream.listen((shape) {
      if (mounted) {
        setState(() {
          _albumArtShape = shape;
        });
      }
    });
  }

  Future<void> _loadTheme() async {
    await AppThemeService.instance.loadTheme();
    if (mounted) {
      setState(() {
        _themeData = AppThemeService.instance.currentData;
        _albumArtShape = AppThemeService.instance.albumArtShape;
      });
    }
  }

  @override
  void dispose() {
    _themeSub?.cancel();
    _shapeSub?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AppThemeProvider(
      themeData: _themeData,
      albumArtShape: _albumArtShape,
      child: M3EMaterialApp(
        title: 'SautiPlay',
        data: _themeData.toM3EThemeData(),
        autoTheming: false,
        dynamicColoring: false,
        drawUnderSystemBars: false,
        theme: _themeData.toThemeData(),
        home: const PlayerShell(),
      ),
    );
  }
}

enum EqScreenMode {
  multibandEq('Enable Multiband EQ'),
  mixEq('Enable Mix EQ');

  const EqScreenMode(this.label);
  final String label;
}

class TrackMetadata {
  final String artist;
  final Uint8List? albumArt;
  final double? replayGainTrack;
  final double? replayGainAlbum;
  const TrackMetadata(this.artist, this.albumArt,
      {this.replayGainTrack, this.replayGainAlbum});
}

class PlayerShell extends StatefulWidget {
  const PlayerShell({super.key});

  @override
  State<PlayerShell> createState() => _PlayerShellState();
}

class _PlayerShellState extends State<PlayerShell> {
  final IsolateAudioPlayer _player = IsolateAudioPlayer();

  final ValueNotifier<PlayerStatus> _status = ValueNotifier(
    const PlayerStatus(
      positionSeconds: 0,
      durationSeconds: 0,
      isPlaying: false,
      currentIndex: -1,
      playlistCount: 0,
      shuffleEnabled: false,
      loopMode: LoopMode.off,
    ),
  );
  final ValueNotifier<TrackMetadata> _metadata = ValueNotifier(
    const TrackMetadata('Unknown Artist', null),
  );

  final List<AudioSource> _playlist = <AudioSource>[];
  final List<TrackInfo> _currentUiQueue = <TrackInfo>[];
  final List<String> _logs = <String>[];
  final ValueNotifier<int> _logUpdateCounter = ValueNotifier(0);
  int _tabIndex = 0;

  // Metadata mapping for online tracks stored in local temporary files
  final Map<Uri, TrackInfo> _onlineTrackMetadata = {};
  final Map<String, Uint8List> _thumbnailCache = {};

  bool _nativeNetworkStreamingSupported = false;
  bool _allowInvalidTlsForDownloads = false;
  int _lastPublishedNowPlayingIndex = -1;
  int _playbackSessionId = 0;

  // FTP Background Downloading State
  List<FtpFileEntry> _pendingFtpDownloads = [];
  FtpConfig? _activeFtpConfig;
  bool _isFtpDownloading = false;
  bool _isLoading = false; // Added loading state for miniplayer
  bool _isPlayerBuffering = false;

  StreamSubscription? _statusSubscription;
  StreamSubscription? _logSubscription;
  StreamSubscription? _replayGainSubscription;
  StreamSubscription? _bufferingSubscription;
  StreamSubscription<AudioHardwareSpecs>? _hardwareSubscription;

  final List<double> _eqFrequencies = const [
    31.25,
    62.5,
    125,
    250,
    500,
    1000,
    2000,
    4000,
    8000,
    16000
  ];

  AudioFormat _outputFormat = AudioFormat.f32;
  int _outputSampleRate = 0; // 0=Native
  int _outputChannels = 2; // Stereo
  bool _crossfadeEnabled = false;
  int _crossfadeDurationMs = 250;

  bool _exclusiveMode = false;

  bool _analyzerEnabled = true;
  String _analyzerType = 'area';
  int _analyzerSampleSize = 1024;
  String _analyzerWindowType = 'hann';
  bool _analyzerAutoFit = true;
  bool _analyzerShowGrids = true;
  bool _analyzerLogScale = true;
  String _spectrumStyle = 'neon';

  int _lastPlaybackTrackIndex = -1;
  double _lastPlaybackMaxPosition = 0.0;
  double _lastPlaybackDuration = 0.0;
  AudioSource? _lastPlaybackSource;
  final Set<String> _cachedTrackIdsThisSession = <String>{};
  DateTime? _lastOfflineSnackBarTime;

  void _showOfflineSnackBar({String? message}) {
    if (!mounted) return;
    final now = DateTime.now();
    if (_lastOfflineSnackBarTime != null &&
        now.difference(_lastOfflineSnackBarTime!).inSeconds < 10) {
      return; // Debounce snackbar
    }
    _lastOfflineSnackBarTime = now;
    final messenger = ScaffoldMessenger.maybeOf(context);
    messenger?.hideCurrentSnackBar();
    messenger?.showSnackBar(
      SnackBar(
        content: Row(
          children: [
            const Icon(Icons.wifi_off_rounded, color: Colors.white, size: 20),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                message ?? 'No internet connection. Reconnect to resume streaming.',
                style: const TextStyle(fontSize: 13),
              ),
            ),
          ],
        ),
        duration: const Duration(seconds: 4),
        behavior: SnackBarBehavior.floating,
      ),
    );
  }

  // Showcase Keys for Feature Tour
  final GlobalKey _homeTabKey = GlobalKey();
  final GlobalKey _libraryTabKey = GlobalKey();
  final GlobalKey _effectsTabKey = GlobalKey();
  final GlobalKey _effectsKnobKey = GlobalKey();
  final GlobalKey _miniPlayerKey = GlobalKey();
  final GlobalKey _settingsTabKey = GlobalKey();
  final GlobalKey<LibraryScreenState> _libraryScreenKey = GlobalKey<LibraryScreenState>();
  int _librarySubTabIndex = 0;

  void _goToLibraryTracks() {
    setState(() {
      _tabIndex = 1;
      _librarySubTabIndex = 1;
    });
    _libraryScreenKey.currentState?.switchToTab(1);
  }

  BuildContext? _showcaseContext;

  Future<void> _checkAndShowOnboarding({bool force = false}) async {
    final prefs = await SharedPreferences.getInstance();
    final done = prefs.getBool('showcase_completed') ?? false;
    if ((!done || force) && _showcaseContext != null) {
      if (mounted) {
        ShowCaseWidget.of(_showcaseContext!).startShowCase([
          _homeTabKey,
          _libraryTabKey,
          _effectsTabKey,
          _effectsKnobKey,
          _settingsTabKey,
        ]);
        await prefs.setBool('showcase_completed', true);
      }
    }
  }

  Future<void> _checkAppUpdateOnLaunch() async {
    final prefs = await SharedPreferences.getInstance();
    final showcaseDone = prefs.getBool('showcase_completed') ?? false;
    // Allow cold-start UI animations and audio hardware detection to settle smoothly
    await Future.delayed(Duration(milliseconds: showcaseDone ? 2500 : 8000));
    if (!mounted) return;
    await AppUpdateService.instance.checkOnLaunch(context);
  }

  @override
  void initState() {
    super.initState();
    // Initialize the engine with defaults
    _player.init(enableSystemAudio: true);

    // Initialize the multiband EQ (safe to call even if unnecessary, but good practice)
    _player.initMultibandEq(_eqFrequencies);
    _nativeNetworkStreamingSupported = _player.isNetworkStreamingSupported();
    _logs.insert(
      0,
      _nativeNetworkStreamingSupported
          ? '[init] Native URL byte-streaming: enabled'
          : '[init] Native URL byte-streaming: disabled (download fallback for URLs)',
    );
    final initErr = _player.getLastError();
    if (initErr.isNotEmpty) {
      _logs.insert(0, '[init] $initErr');
    }
    _statusSubscription = _player.statusStream.listen((s) {
      // Save position periodically (every ~5s)
      if (s.isPlaying && (s.positionSeconds % 5 == 0)) {
        AppStateService.instance.saveQueue(
          tracks: _currentUiQueue.map((t) => t.toJson()).toList(),
          index: s.currentIndex,
          positionMs: (s.positionSeconds * 1000).toInt(),
        );
      }

      _handleTrackPlaybackProgress(s);
      _status.value = s;
      _publishNowPlayingFromStatus(s);
    });
    _logSubscription = _player.logStream.listen((line) {
      _logs.insert(0, '[${DateTime.now().toIso8601String()}] $line');
      if (_logs.length > 200) {
        _logs.removeRange(200, _logs.length);
      }
      _logUpdateCounter.value++;
    });
    _bufferingSubscription = _player.bufferingStream.listen((buffering) {
      if (mounted && _isPlayerBuffering != buffering) {
        setState(() => _isPlayerBuffering = buffering);
      }
    });

    _hardwareSubscription =
        AudioHardwareInspector.hardwareStream(_player).listen((specs) {
      if (!mounted) return;
      // When engine output sample rate is set to Native (0), match active device hardware rate
      if (_outputSampleRate == 0 && specs.sampleRate > 0) {
        _player.setOutputSampleRate(specs.sampleRate);
      }
    });

    if (Platform.isAndroid) {
      unawaited(_ensureNotificationPermission());
    }

    // Load persisted app state (settings, queue, etc.)
    _loadAppState();
    CachedStreamService.instance.init();
    LastFmService.instance.init();
    LastFmService.instance.logStream.listen((line) {
      _logs.insert(0, '[${DateTime.now().toIso8601String()}] $line');
      if (_logs.length > 200) {
        _logs.removeRange(200, _logs.length);
      }
      _logUpdateCounter.value++;
    });

    _metadata.addListener(_applyReplayGain);
    _metadata.addListener(_extractArtworkTheme);
    _replayGainSubscription =
        AppStateService.instance.replayGainChanged.stream.listen((_) {
      _applyReplayGain();
    });

    WidgetsBinding.instance.addPostFrameCallback((_) {
      _checkAndShowOnboarding();
      _checkAppUpdateOnLaunch();
    });

    // DLNA receiver (act as a cast target for other devices)
    unawaited(_initDlnaRenderer());
  }

  /// Plays a URL pushed from a DLNA controller (receiver mode).
  void playDlnaCast(String url, String title, String artist) {
    _playbackSessionId++;
    final session = _playbackSessionId;
    final src = AudioSource.network(url, title: title, artist: artist);

    if (!mounted || _playbackSessionId != session) return;

    setState(() {
      _currentUiQueue.clear();
      _currentUiQueue.add(TrackInfo(
        videoId: url,
        title: title,
        artist: artist,
        thumbnailUrl: null,
      ));
      _playlist.clear();
      _playlist.add(src);
    });

    _player.setAudioSources(
      _playlist,
      initialIndex: 0,
      initialPosition: Duration.zero,
      useLazyPreparation: true,
    );
  }

  Future<void> _initDlnaRenderer() async {
    await DlnaRendererService.instance.restoreName();
    await DlnaRendererService.instance
        .configure(bridge: _SautiRendererBridge(this));
    final prefs = await SharedPreferences.getInstance();
    if (prefs.getBool('dlna_receiver_enabled') == true) {
      final ok = await DlnaRendererService.instance.start();
      if (ok) {
        _logs.insert(0,
            '[dlna] Receiving casts as "${DlnaRendererService.instance.friendlyName}"');
      }
    }
  }

  void _extractArtworkTheme() {
    final meta = _metadata.value;
    final artHash = (meta.albumArt != null && meta.albumArt!.isNotEmpty)
        ? (meta.albumArt!.length ^ meta.albumArt!.first)
        : 0;
    final trackKey = 'track_${_status.value.currentIndex}_$artHash';
    ArtworkThemeService.instance.extractAndEmit(
      trackKey: trackKey,
      artBytes: meta.albumArt,
      isDark: true,
    );
  }

  Future<void> _applyReplayGain() async {
    final rgState = await AppStateService.instance.loadReplayGainSettings();
    final metadata = _metadata.value;

    double gainDb = rgState.preamp;

    if (rgState.mode == ReplayGainMode.track) {
      if (metadata.replayGainTrack != null) {
        gainDb += metadata.replayGainTrack!;
      }
    } else if (rgState.mode == ReplayGainMode.album) {
      if (metadata.replayGainAlbum != null) {
        gainDb += metadata.replayGainAlbum!;
      } else if (metadata.replayGainTrack != null) {
        gainDb += metadata.replayGainTrack!;
      }
    } else {
      gainDb =
          0.0; // None bypasses preamp in this logic, wait, if none, maybe preamp still applies?
      // Let's just set it to 0 if none.
    }

    _player.setReplayGain(gainDb);
  }

  Future<void> _loadAppState() async {
    final engine = await AppStateService.instance.loadEngineSettings();

    setState(() {
      _outputFormat = AudioFormat.values[engine.outputFormatIndex];
      _outputSampleRate = engine.sampleRate;
      _outputChannels = engine.channels;
      _crossfadeEnabled = engine.crossfadeEnabled;
      _crossfadeDurationMs = engine.crossfadeMs;
      _analyzerEnabled = engine.analyzerEnabled;
      _analyzerType = engine.analyzerType;
      _analyzerSampleSize = engine.analyzerSampleSize;
      _analyzerWindowType = engine.analyzerWindowType;
      _allowInvalidTlsForDownloads = engine.allowInvalidTls;
      _exclusiveMode = engine.exclusiveMode;
      _analyzerAutoFit = engine.analyzerAutoFit;
      _analyzerShowGrids = engine.analyzerShowGrids;
      _analyzerLogScale = engine.analyzerLogScale;
      _spectrumStyle = engine.spectrumStyle;
    });

    // Apply basic engine settings
    if (_outputSampleRate > 0) {
      _player.setOutputSampleRate(_outputSampleRate);
    } else {
      final activeRate = AudioHardwareInspector.currentSpecs?.sampleRate;
      if (activeRate != null && activeRate > 0) {
        _player.setOutputSampleRate(activeRate);
      }
    }
    _player.setExclusiveMode(_exclusiveMode);
    _player.setCrossfadeEnabled(_crossfadeEnabled);
    _player.setCrossfadeDurationMs(_crossfadeDurationMs);
    _player.setAnalyzerEnabled(_analyzerEnabled);
    _player.configureAnalyzer(
      frameSize: _analyzerSampleSize,
      windowType: _analyzerWindowType,
    );

    // Apply Phase Inversion, Speaker Protection, 64-bit float & Auto Bit-Perfect
    final phaseSaved = await AppStateService.instance.loadPhaseInversion();
    final is64Bit = await AppStateService.instance.load64BitProcessingEnabled();
    final autoBp = await AppStateService.instance.loadAutoBitPerfectEnabled();
    final spSaved = await AppStateService.instance.loadSpeakerProtection();
    final loudnessSaved =
        await AppStateService.instance.loadLoudnessNormalizer();
    final lookaheadSaved =
        await AppStateService.instance.loadLookaheadLimiter();

    _player.set64BitProcessingEnabled(is64Bit);
    _player.setAutoSampleRateMatchEnabled(autoBp);
    _player.setLoudnessCrossfadeEnabled(engine.loudnessCrossfadeEnabled);
    _player.setLoudnessNormalizerEnabled(loudnessSaved.enabled);
    _player.setLoudnessNormalizerTarget(loudnessSaved.targetLUFS);
    _player.setLookaheadLimiterEnabled(lookaheadSaved.enabled);
    _player.setLookaheadLimiterParams(ceilingDBTP: lookaheadSaved.ceilingDBTP);
    _player.setPhaseInversion(
      invertLeft: phaseSaved.invertLeft,
      invertRight: phaseSaved.invertRight,
    );
    _player.setSpeakerProtectionParams(
      enabled: spSaved.enabled,
      subsonicCutoffHz: spSaved.subsonicCutoffHz,
      ultrasonicCutoffHz: spSaved.ultrasonicCutoffHz,
      limiterThreshold: spSaved.limiterThreshold,
      safetyAttenuationDb: spSaved.safetyAttenuationDb,
    );

    // Apply saved resampler algorithm & dither mode
    final ui = await AppStateService.instance.loadUiSettings();
    _player.setEngineResampleAlgorithm(ui.resampleAlgorithm);
    _player.setEngineDitherMode(ui.ditherMode);

    // Apply saved playback speed
    final savedPitch = await AppStateService.instance.loadPlaybackSpeed();
    if ((savedPitch - 1.0).abs() > 0.01) {
      _player.setPitch(savedPitch);
    }

    // Apply Sauti DSP Suite settings
    await EqScreen.applySavedStateToEngine(_player);

    // Load and restore queue
    final queueData = await AppStateService.instance.loadQueue();
    if (queueData.tracks.isNotEmpty) {
      _logs.insert(0,
          '[init] Restoring saved queue (${queueData.tracks.length} tracks)...');
      final tracks =
          queueData.tracks.map((t) => TrackInfo.fromJson(t)).toList();

      _playbackSessionId++;
      final session = _playbackSessionId;

      final sources = <AudioSource>[];
      for (final t in tracks) {
        if (_isLocalTrack(t)) {
          final file = File(t.videoId);
          if (file.existsSync()) {
            sources.add(AudioSource.uri(file.uri));
          }
        } else {
          final cached =
              CachedStreamService.instance.getCachedItem(t.videoId);
          if (cached != null && File(cached.filePath).existsSync()) {
            final src = AudioSource.uri(File(cached.filePath).uri);
            sources.add(src);
            _onlineTrackMetadata[src.uri] = t;
          } else if (t.videoId.startsWith('http://') ||
              t.videoId.startsWith('https://')) {
            final src = await _materializeSource(Uri.parse(t.videoId));
            if (src != null) {
              sources.add(src);
              _onlineTrackMetadata[src.uri] = t;
            }
          }
        }
      }

      if (sources.isNotEmpty && mounted && _playbackSessionId == session) {
        setState(() {
          _currentUiQueue.clear();
          _currentUiQueue.addAll(tracks);
          _playlist.clear();
          _playlist.addAll(sources);
        });

        int initialIndex = queueData.index;
        if (initialIndex < 0 || initialIndex >= sources.length) {
          initialIndex = 0;
        }

        _player.setAudioSources(
          _playlist,
          initialIndex: initialIndex,
          initialPosition: Duration(milliseconds: queueData.positionMs),
          useLazyPreparation: true,
          autoPlay: false,
        );

        _logs.insert(0,
            '[init] Queue restored at index $initialIndex position ${queueData.positionMs}ms');
      }
    }
  }

  void _saveQueue() {
    AppStateService.instance.saveQueue(
      tracks: _currentUiQueue.map((t) => t.toJson()).toList(),
      index: _status.value.currentIndex,
      positionMs: (_status.value.positionSeconds * 1000).toInt(),
    );
  }

  void _saveEngineSettings() {
    AppStateService.instance.saveEngineSettings(
      outputFormatIndex: _outputFormat.index,
      sampleRate: _outputSampleRate,
      channels: _outputChannels,
      crossfadeEnabled: _crossfadeEnabled,
      crossfadeMs: _crossfadeDurationMs,
      analyzerEnabled: _analyzerEnabled,
      analyzerType: _analyzerType,
      analyzerSampleSize: _analyzerSampleSize,
      analyzerWindowType: _analyzerWindowType,
      allowInvalidTls: _allowInvalidTlsForDownloads,
      exclusiveMode: _exclusiveMode,
      analyzerAutoFit: _analyzerAutoFit,
      analyzerShowGrids: _analyzerShowGrids,
      analyzerLogScale: _analyzerLogScale,
      spectrumStyle: _spectrumStyle,
    );
  }

  @override
  void dispose() {
    _statusSubscription?.cancel();
    _logSubscription?.cancel();
    _replayGainSubscription?.cancel();
    _bufferingSubscription?.cancel();
    _hardwareSubscription?.cancel();
    _metadata.removeListener(_applyReplayGain);
    _metadata.removeListener(_extractArtworkTheme);
    DlnaRendererService.instance.stopInternal();
    _status.dispose();
    _player.dispose();
    super.dispose();
  }

  Future<void> _ensureNotificationPermission() async {
    final notif = await Permission.notification.status;
    if (notif.isGranted) return;

    final req = await Permission.notification.request();
    if (!req.isGranted) {
      _logs.insert(
        0,
        '[permission] Notification permission denied. Media notification may not appear.',
      );
      if (req.isPermanentlyDenied) {
        _logs.insert(
          0,
          '[permission] Notification permission permanently denied. Open app settings.',
        );
      }
    }
  }

  void _publishNowPlayingFromStatus(PlayerStatus status) {
    final idx = status.currentIndex;
    if (idx < 0 || idx >= _playlist.length) return;

    final source = _playlist[idx];
    final title = _nameFromSource(source);

    final overrideDuration = _durationFromSource(source);
    final finalDurationSecs = (overrideDuration != null && overrideDuration > 0)
        ? overrideDuration
        : status.durationSeconds.toInt();

    // Only re-publish system audio notification when the track index changes.
    // But always ensure metadata (including album art) is loaded.
    final isNewTrack = idx != _lastPublishedNowPlayingIndex;
    _lastPublishedNowPlayingIndex = idx;

    _updateMetadata(source).then((_) async {
      // --- DLNA Casting & Local Mute ---
      if (DlnaService.instance.activeRenderer != null) {
        if (isNewTrack) {
          String? castUrl;
          if (source.uri.scheme == 'file') {
            final path = _safeFilePathFromUri(source.uri);
            if (path != null) {
              castUrl = await LocalMediaServer.instance.serveFile(path);
            }
          } else {
            castUrl = source.uri.toString();
          }

          if (castUrl != null) {
            await DlnaService.instance.castAudioUrl(
              renderer: DlnaService.instance.activeRenderer!,
              audioUrl: castUrl,
              title: title,
            );
          }
        }
        _player.setGain(0.0); // Mute local audio
      }

      if (!isNewTrack) return; // art is loaded, skip notification re-publish

      // Lookahead: ensure immediate next track in the queue is resolved and ready in the engine
      _ensureLookaheadForActiveTrack(source);

      // Pre-fetch next track's ReplayGain for loudness-aware crossfade
      _prefetchNextTrackReplayGain(idx);

      final artUri = await _resolveNowPlayingArtUri(
        source,
        _metadata.value.albumArt,
      );

      final finalArtist = _metadata.value.artist;

      unawaited(
        _player.updateNowPlaying(
          id: 'track_$idx',
          title: title,
          artist: finalArtist,
          duration: Duration(milliseconds: finalDurationSecs * 1000),
          artUri: artUri,
        ),
      );

      unawaited(
        LastFmService.instance.onTrackStarted(
          title: title,
          artist: finalArtist,
          durationSeconds: finalDurationSecs,
        ),
      );

      // Record in History
      String videoIdToSave = title; // fallback
      String? thumbnailUrlToSave;
      if (_onlineTrackMetadata.containsKey(source.uri)) {
        videoIdToSave = _onlineTrackMetadata[source.uri]!.videoId;
        thumbnailUrlToSave = _onlineTrackMetadata[source.uri]!.thumbnailUrl;
      } else if (source.uri.scheme == 'file') {
        final path = _safeFilePathFromUri(source.uri);
        if (path != null) videoIdToSave = path;
      }

      unawaited(
        RecentlyPlayedService.instance.addTrack(
          RecentlyPlayedTrack(
            videoId: videoIdToSave,
            title: title,
            artist: finalArtist,
            thumbnailUrl: thumbnailUrlToSave,
            durationSeconds: finalDurationSecs,
            playedAt: DateTime.now(),
          ),
        ),
      );
    });
  }

  Future<String?> _resolveNowPlayingArtUri(
    AudioSource source,
    Uint8List? albumArt,
  ) async {
    final onlineTrack = _onlineTrackMetadata[source.uri];
    final thumbUrl = onlineTrack?.thumbnailUrl;
    if (thumbUrl != null && thumbUrl.isNotEmpty) {
      try {
        final cachedFile = await DefaultCacheManager().getSingleFile(thumbUrl);
        return cachedFile.uri.toString();
      } catch (e) {
        _logs.insert(
            0, '[metadata] Artwork cache failed, using URL directly: $e');
        return thumbUrl;
      }
    }

    return _buildNowPlayingArtUri(albumArt);
  }

  Future<String?> _buildNowPlayingArtUri(Uint8List? albumArt) async {
    if (albumArt == null || albumArt.isEmpty) return null;
    try {
      final tempDir = Directory.systemTemp;
      try {
        if (tempDir.existsSync()) {
          final files = tempDir.listSync();
          for (final f in files) {
            if (f.path.contains('sautiplay_now_playing_art_')) {
              try {
                f.deleteSync();
              } catch (_) {}
            }
          }
        }
      } catch (_) {}
      final timestamp = DateTime.now().millisecondsSinceEpoch;
      final artFile = File(
        '${tempDir.path}${Platform.pathSeparator}sautiplay_now_playing_art_$timestamp.jpg',
      );
      await artFile.writeAsBytes(albumArt, flush: true);
      return artFile.uri.toString();
    } catch (e) {
      _logs.insert(
          0, '[metadata] Failed to persist album art for now playing: $e');
      if (mounted) setState(() {});
      return null;
    }
  }

  AudioSource? _lastMetadataSource;

  /// Pre-reads the ReplayGain value for the next track in the queue and
  /// forwards it to the engine so loudness-aware crossfade can compensate
  /// before the blend even starts.
  Future<void> _prefetchNextTrackReplayGain(int currentIndex) async {
    final nextIndex = currentIndex + 1;
    if (nextIndex >= _playlist.length) return;
    final nextSource = _playlist[nextIndex];

    // Prefer online track metadata (no RG in that path, send 0)
    if (_onlineTrackMetadata.containsKey(nextSource.uri)) {
      _player.setNextReplayGain(0.0);
      return;
    }

    String? filePath;
    final uri = nextSource.uri;
    if (uri.scheme == 'file') {
      filePath = _safeFilePathFromUri(uri);
    } else {
      final str = Uri.decodeFull(uri.toString());
      if (str.startsWith(RegExp(r'^[a-zA-Z]:[\\/]')) || str.startsWith('/')) {
        filePath = str;
      }
    }

    if (filePath == null) {
      _player.setNextReplayGain(0.0);
      return;
    }

    double rgDb = 0.0;
    try {
      final metadata = readMetadata(File(filePath), getImage: false);
      final rgState = await AppStateService.instance.loadReplayGainSettings();
      double? found;
      try {
        final dynamic m = metadata;
        if (m.customMetadata != null) {
          final Map<String, String> custom = m.customMetadata;
          if (rgState.mode == ReplayGainMode.album &&
              custom.containsKey('REPLAYGAIN_ALBUM_GAIN')) {
            found = double.tryParse(custom['REPLAYGAIN_ALBUM_GAIN']!
                .replaceAll(RegExp(r'[^\d.-]'), ''));
          }
          found ??= double.tryParse((custom['REPLAYGAIN_TRACK_GAIN'] ?? '')
              .replaceAll(RegExp(r'[^\d.-]'), ''));
        }
      } catch (_) {}
      try {
        final dynamic m = metadata;
        if (found == null) {
          if (rgState.mode == ReplayGainMode.album &&
              m.replayGainAlbumGain != null &&
              (m.replayGainAlbumGain as List).isNotEmpty) {
            found = double.tryParse((m.replayGainAlbumGain as List)
                .first
                .toString()
                .replaceAll(RegExp(r'[^\d.-]'), ''));
          }
          if (found == null &&
              m.replayGainTrackGain != null &&
              (m.replayGainTrackGain as List).isNotEmpty) {
            found = double.tryParse((m.replayGainTrackGain as List)
                .first
                .toString()
                .replaceAll(RegExp(r'[^\d.-]'), ''));
          }
        }
      } catch (_) {}
      rgDb = (found ?? 0.0) + rgState.preamp;
    } catch (_) {}

    _player.setNextReplayGain(rgDb);
  }

  Future<void> _updateMetadata(AudioSource source) async {
    if (_lastMetadataSource == source) return;
    _lastMetadataSource = source;

    String artist = _subtitleFromSource(source);
    Uint8List? albumArt;
    double? rgTrack;
    double? rgAlbum;
    bool isOnlineTrackWithThumbnail = false;

    if (_onlineTrackMetadata.containsKey(source.uri)) {
      final track = _onlineTrackMetadata[source.uri]!;
      artist = track.artist;
      if (track.thumbnailUrl != null) {
        isOnlineTrackWithThumbnail = true;
        if (_thumbnailCache.containsKey(track.thumbnailUrl)) {
          albumArt = _thumbnailCache[track.thumbnailUrl];
        } else {
          try {
            final client = HttpClient();
            final req = await client.getUrl(Uri.parse(track.thumbnailUrl!));
            final res = await req.close();
            if (res.statusCode == 200) {
              final bytes = <int>[];
              await for (var chunk in res) {
                bytes.addAll(chunk);
              }
              albumArt = Uint8List.fromList(bytes);
              if (_thumbnailCache.length > 50) _thumbnailCache.clear();
              _thumbnailCache[track.thumbnailUrl!] = albumArt;
            }
            client.close(force: true);
          } catch (e) {
            _logs.insert(0, '[metadata] Failed to download thumbnail: $e');
            if (mounted) setState(() {});
          }
        }
      }
    }

    if (!isOnlineTrackWithThumbnail) {
      try {
        final uri = source.uri;
        String? filePath;

        if (uri.scheme == 'file') {
          filePath = _safeFilePathFromUri(uri);
        } else {
          final str = Uri.decodeFull(uri.toString());
          if (str.startsWith(RegExp(r'^[a-zA-Z]:[\\/]')) ||
              str.startsWith('/')) {
            filePath = str;
          }
        }

        if (filePath != null) {
          try {
            final metadata = readMetadata(File(filePath), getImage: true);
            if (metadata.artist != null && metadata.artist!.isNotEmpty) {
              artist = metadata.artist!;
            }
            if (metadata.pictures.isNotEmpty) {
              albumArt = metadata.pictures.first.bytes;
            } else if (albumArt == null) {
              // Fallback to directory images
              final dir = File(filePath).parent;
              if (dir.existsSync()) {
                final files = await dir.list().toList();
                for (final f in files) {
                  if (f is File) {
                    final lowerPath = f.path.toLowerCase();
                    if (lowerPath.endsWith('.jpg') ||
                        lowerPath.endsWith('.jpeg') ||
                        lowerPath.endsWith('.png') ||
                        lowerPath.endsWith('.webp')) {
                      albumArt = await f.readAsBytes();
                      break;
                    }
                  }
                }
              }
            }

            // Extract ReplayGain
            try {
              final dynamic m = metadata;
              if (m.customMetadata != null) {
                // MP3 ID3v2 TXXX
                final Map<String, String> custom = m.customMetadata;
                if (custom.containsKey('REPLAYGAIN_TRACK_GAIN')) {
                  rgTrack = double.tryParse(custom['REPLAYGAIN_TRACK_GAIN']!
                      .replaceAll(RegExp(r'[^\d.-]'), ''));
                }
                if (custom.containsKey('REPLAYGAIN_ALBUM_GAIN')) {
                  rgAlbum = double.tryParse(custom['REPLAYGAIN_ALBUM_GAIN']!
                      .replaceAll(RegExp(r'[^\d.-]'), ''));
                }
              }
            } catch (_) {}

            try {
              final dynamic m = metadata;
              if (m.replayGainTrackGain != null &&
                  m.replayGainTrackGain.isNotEmpty) {
                rgTrack = double.tryParse(m.replayGainTrackGain.first
                    .replaceAll(RegExp(r'[^\d.-]'), ''));
              }
              if (m.replayGainAlbumGain != null &&
                  m.replayGainAlbumGain.isNotEmpty) {
                rgAlbum = double.tryParse(m.replayGainAlbumGain.first
                    .replaceAll(RegExp(r'[^\d.-]'), ''));
              }
            } catch (_) {}
          } catch (e) {
            _logs.insert(0, '[metadata] Read error: $e');
          }
        } else if (!_onlineTrackMetadata.containsKey(source.uri)) {
          _logs.insert(0, '[metadata] Could not resolve file path for $uri');
          if (mounted) setState(() {});
        }
      } catch (e) {
        _logs.insert(0, '[metadata] Read error: $e');
        if (mounted) setState(() {});
      }
    }

    _metadata.value = TrackMetadata(artist, albumArt,
        replayGainTrack: rgTrack, replayGainAlbum: rgAlbum);

    final idx = _status.value.currentIndex;
    if (idx >= 0 && idx < _currentUiQueue.length) {
      final currentTrack = _currentUiQueue[idx];
      if (currentTrack.artist == 'Local File' &&
          artist != 'Local File' &&
          artist.isNotEmpty) {
        _currentUiQueue[idx] = TrackInfo(
          videoId: currentTrack.videoId,
          title: currentTrack.title,
          artist: artist,
          thumbnailUrl: currentTrack.thumbnailUrl,
          durationSeconds: currentTrack.durationSeconds,
        );
        if (mounted) setState(() {});
      }
    }
  }

  String? _safeFilePathFromUri(Uri uri) {
    if (uri.scheme != 'file') return null;
    try {
      return uri.toFilePath();
    } catch (_) {
      return null;
    }
  }

  Future<AudioSource?> _materializeSource(Uri uri) async {
    if (uri.scheme == 'file') {
      final filePath = _safeFilePathFromUri(uri);
      if (filePath == null || filePath.isEmpty) {
        _logs.insert(0, '[source] Invalid file URI: $uri');
        return null;
      }
      final file = File(filePath);
      if (!file.existsSync()) {
        _logs.insert(0, '[source] Local file not found: ${file.path}');
        return null;
      }
      return AudioSource.uri(uri);
    }

    if (uri.scheme != 'http' && uri.scheme != 'https') {
      _logs.insert(0, '[source] Unsupported URI scheme: ${uri.scheme}');
      return null;
    }

    // Default to native online streaming via embedded FFmpeg backend (Spotify/ExoPlayer style)
    _logs.insert(0, '[source] Streaming native online source: $uri');
    return AudioSource.network(uri.toString());
  }

  Future<void> _playFolder(List<String> paths, {int initialIndex = 0}) async {
    _isFtpDownloading = false;
    _playbackSessionId++;
    final session = _playbackSessionId;

    final uniquePaths = <String>[];
    final seenPaths = <String>{};
    for (final path in paths) {
      final key = p.canonicalize(path).toLowerCase();
      if (seenPaths.add(key)) {
        uniquePaths.add(path);
      }
    }

    final sources = <AudioSource>[];
    final uiQueue = <TrackInfo>[];

    for (int i = 0; i < uniquePaths.length; i++) {
      final file = File(uniquePaths[i]);
      final uri = file.absolute.uri;
      final src = await _materializeSource(uri);

      if (!mounted || _playbackSessionId != session) return;

      if (src != null) {
        sources.add(src);
        // Populate UI queue with local file info
        uiQueue.add(TrackInfo(
          videoId: file.absolute.path,
          title: file.uri.pathSegments.where((s) => s.isNotEmpty).last,
          artist: 'Local File',
          thumbnailUrl: null,
        ));
      } else if (i < initialIndex) {
        // If a file before the initialIndex fails to materialize, decrement the index so we stay on track
        initialIndex--;
      }
    }

    if (sources.isEmpty) {
      _logs.insert(0, '[folder] No valid audio sources found in the folder.');
      setState(() {});
      return;
    }

    if (initialIndex < 0 || initialIndex >= sources.length) {
      initialIndex = 0;
    }

    if (!mounted || _playbackSessionId != session) return;

    setState(() {
      _currentUiQueue.clear();
      _currentUiQueue.addAll(uiQueue);

      _playlist
        ..clear()
        ..addAll(sources);
    });

    _player.setAudioSources(
      _playlist,
      initialIndex: initialIndex,
      initialPosition: Duration.zero,
      useLazyPreparation: true,
    );

    _saveQueue();

    final msg = _player.getLastError();
    if (msg.isNotEmpty) {
      _logs.insert(0, '[folder-play] $msg');
      setState(() {});
    }

    _showNowPlayingScreen();
  }

  Future<void> _fetchAndAppendUpNext(String videoId, {int? sessionId}) async {
    final session = sessionId ?? _playbackSessionId;
    _logs.insert(0, '[stream] Fetching "Up Next" suggestions...');
    try {
      final yt = YTMusic();
      await yt.initialize();
      if (!mounted || _playbackSessionId != session) return;
      final upNexts = await yt.getUpNexts(videoId).timeout(const Duration(seconds: 8));

      if (!mounted || _playbackSessionId != session) return;

      if (upNexts.isEmpty) {
        _logs.insert(0, '[stream] No recommendations found.');
        return;
      }

      final newTracks = <TrackInfo>[];
      for (final item in upNexts) {
        // Only include songs, skip videos if needed, but UpNextsDetails usually are songs/videos
        // Filter out the currently playing song if returned
        if (item.videoId == videoId) continue;

        // Find the largest thumbnail
        String? thumbUrl;
        if (item.thumbnails.isNotEmpty) {
          item.thumbnails.sort((a, b) => b.width.compareTo(a.width));
          thumbUrl = item.thumbnails.first.url;
        }

        newTracks.add(TrackInfo(
          videoId: item.videoId,
          title: item.title,
          artist: item.artists.name,
          durationSeconds: item.duration, // integer seconds
          thumbnailUrl: thumbUrl,
        ));
      }

      if (newTracks.isEmpty) return;

      // Cap at 20 tracks max
      if (newTracks.length > 20) {
        newTracks.removeRange(20, newTracks.length);
      }

      if (!mounted || _playbackSessionId != session) return;

      _logs.insert(0, '[stream] Adding ${newTracks.length} tracks to queue...');
      // Update UI queue immediately
      setState(() {
        _currentUiQueue.addAll(newTracks);
      });

      // Lookahead resolution: resolve next track immediately for gapless preload, then rest in background
      _resolveLookaheadAndAppend(newTracks, sessionId: session);
    } catch (e) {
      if (!mounted || _playbackSessionId != session) return;
      _logs.insert(0, '[stream] Failed to fetch Up Next: $e');
    }
  }

  void _registerCachedStreamMeta(
    AudioSource src,
    TrackInfo track, {
    String? streamUrl,
  }) {
    if (src.uri.scheme == 'file') {
      // Never let genuinely local music files enter the online-stream cache;
      // only offline copies of online streams belong here.
      if (_isLocalTrack(track)) return;

      final filePath = _safeFilePathFromUri(src.uri);
      if (filePath != null &&
          filePath.isNotEmpty &&
          File(filePath).existsSync()) {
        CachedStreamService.instance.registerCachedStream(
          videoId: track.videoId,
          title: track.title,
          artist: track.artist,
          thumbnailUrl: track.thumbnailUrl,
          durationSeconds: track.durationSeconds,
          filePath: filePath,
          streamUrl: streamUrl,
          fileSizeBytes: File(filePath).lengthSync(),
        );
      }
    }
  }

  void _handleTrackPlaybackProgress(PlayerStatus s) {
    final curIdx = s.currentIndex;
    if (curIdx < 0 || curIdx >= _playlist.length) return;

    final curSource = _playlist[curIdx];

    // Case 1: Track index changed (track transitioned to next or user switched tracks)
    if (_lastPlaybackTrackIndex != curIdx) {
      if (_lastPlaybackTrackIndex != -1 && _lastPlaybackSource != null) {
        final wasCompleted = _checkIfCompleted(
          maxPosition: _lastPlaybackMaxPosition,
          duration: _lastPlaybackDuration,
        );
        if (wasCompleted) {
          _onTrackPlaybackCompleted(_lastPlaybackSource!, _lastPlaybackTrackIndex);
        }
      }

      _lastPlaybackTrackIndex = curIdx;
      _lastPlaybackSource = curSource;
      _lastPlaybackMaxPosition = s.positionSeconds;
      _lastPlaybackDuration = s.durationSeconds;
    } else {
      // Same track: update maximum playback position reached and duration
      if (s.positionSeconds > _lastPlaybackMaxPosition) {
        _lastPlaybackMaxPosition = s.positionSeconds;
      }
      if (s.durationSeconds > 0) {
        _lastPlaybackDuration = s.durationSeconds;
      }

      // Check single-track repeat / loop wrap-around
      if (_lastPlaybackDuration > 10 &&
          _lastPlaybackMaxPosition >= _lastPlaybackDuration - 3.0 &&
          s.positionSeconds < 3.0) {
        _onTrackPlaybackCompleted(curSource, curIdx);
        _lastPlaybackMaxPosition = s.positionSeconds;
      }

      // Case 2: At end of playlist or stopped near the end of track
      if (!s.isPlaying ||
          (s.durationSeconds > 0 &&
              s.positionSeconds >= s.durationSeconds - 1.5)) {
        final wasCompleted = _checkIfCompleted(
          maxPosition: _lastPlaybackMaxPosition,
          duration: _lastPlaybackDuration,
        );
        if (wasCompleted) {
          _onTrackPlaybackCompleted(curSource, curIdx);
        }
      }
    }

    if (s.isPlaying && s.durationSeconds > 0) {
      unawaited(
        LastFmService.instance.onPlaybackProgress(
          title: _nameFromSource(curSource),
          artist: _metadata.value.artist,
          currentPositionSeconds: s.positionSeconds,
          totalDurationSeconds: s.durationSeconds,
          isPlaying: s.isPlaying,
        ),
      );
    }
  }

  bool _checkIfCompleted({
    required double maxPosition,
    required double duration,
  }) {
    if (duration <= 0) return false;
    if (duration <= 10) {
      return maxPosition >= duration - 1.0;
    }
    return maxPosition >= (duration - 3.0) || (maxPosition / duration) >= 0.90;
  }

  void _onTrackPlaybackCompleted(AudioSource source, int trackIndex) {
    TrackInfo? track = _onlineTrackMetadata[source.uri];
    if (track == null &&
        trackIndex >= 0 &&
        trackIndex < _currentUiQueue.length) {
      track = _currentUiQueue[trackIndex];
    }
    if (track == null) return;

    final videoId = track.videoId;
    if (videoId.isEmpty) return;
    if (_cachedTrackIdsThisSession.contains(videoId)) return;

    final cached = CachedStreamService.instance.getCachedItem(videoId);
    if (cached != null && File(cached.filePath).existsSync()) {
      return;
    }

    _cachedTrackIdsThisSession.add(videoId);

    if (source.uri.scheme == 'file') {
      // Guard: only register files that are offline copies of ONLINE streams.
      // A local song finishing playback (e.g. after switching away from an
      // online playlist) must never be added to the stream cache.
      if (_isLocalTrack(track)) {
        debugPrint(
            '[cache] Skipping cache registration for local track: ${track.title}');
      } else {
        final filePath = _safeFilePathFromUri(source.uri);
        if (filePath != null && File(filePath).existsSync()) {
          CachedStreamService.instance.registerCachedStream(
            videoId: videoId,
            title: track.title,
            artist: track.artist,
            thumbnailUrl: track.thumbnailUrl,
            durationSeconds: track.durationSeconds,
            filePath: filePath,
            fileSizeBytes: File(filePath).lengthSync(),
          );
        }
      }
    } else if (source.uri.scheme == 'http' || source.uri.scheme == 'https') {
      _logs.insert(
          0, '[cache] Completed song playback, caching to disk: ${track.title}');
      CachedStreamService.instance.cacheStreamInBackground(
        videoId: videoId,
        streamUrl: source.uri.toString(),
        title: track.title,
        artist: track.artist,
        thumbnailUrl: track.thumbnailUrl,
        durationSeconds: track.durationSeconds,
      );
    }

    unawaited(
      LastFmService.instance.onTrackCompleted(
        title: track.title,
        artist: track.artist,
        maxPositionSeconds: _lastPlaybackMaxPosition,
        durationSeconds: _lastPlaybackDuration,
      ),
    );

    // End-of-loaded-playlist auto-heal: If we completed the last loaded track and more remain in UI queue, resolve the next one!
    if (trackIndex >= _playlist.length - 1 && _playlist.length < _currentUiQueue.length) {
      _ensureTrackInPlaylist(_currentUiQueue[_playlist.length]);
    }
  }

  bool _isLocalTrack(TrackInfo track) {
    if (track.videoId.startsWith('http://') ||
        track.videoId.startsWith('https://')) {
      return false;
    }
    return track.videoId.contains(r'\') ||
        track.videoId.contains('/') ||
        File(track.videoId).existsSync();
  }

  bool _pathsMatch(String a, String b) {
    return a.replaceAll('/', r'\').toLowerCase() ==
        b.replaceAll('/', r'\').toLowerCase();
  }

  void _ensureLookaheadForActiveTrack(AudioSource currentSource) {
    if (_currentUiQueue.isEmpty) return;

    int queueIdx = -1;
    if (_onlineTrackMetadata.containsKey(currentSource.uri)) {
      final curTrack = _onlineTrackMetadata[currentSource.uri]!;
      queueIdx = _currentUiQueue.indexWhere((t) => t.videoId == curTrack.videoId);
    } else if (currentSource.uri.scheme == 'file') {
      final path = _safeFilePathFromUri(currentSource.uri);
      queueIdx = _currentUiQueue.indexWhere((t) => path != null && _pathsMatch(path, t.videoId));
    }

    if (queueIdx != -1 && queueIdx + 1 < _currentUiQueue.length) {
      final nextTrack = _currentUiQueue[queueIdx + 1];
      _ensureTrackInPlaylist(nextTrack).then((success) {
        // If the immediate next track failed to resolve (e.g. broken/geoblocked/offline),
        // try to look ahead one more track so the playback pipeline doesn't stall
        if (!success && queueIdx + 2 < _currentUiQueue.length) {
          _ensureTrackInPlaylist(_currentUiQueue[queueIdx + 2]);
        }
      });
    }
  }

  Future<bool> _ensureTrackInPlaylist(TrackInfo track, {int? sessionId}) async {
    final session = sessionId ?? _playbackSessionId;
    if (!mounted || _playbackSessionId != session) return false;

    final alreadyInPlaylist = _playlist.any((src) {
      if (_onlineTrackMetadata.containsKey(src.uri)) {
        return _onlineTrackMetadata[src.uri]?.videoId == track.videoId;
      } else if (src.uri.scheme == 'file') {
        final path = _safeFilePathFromUri(src.uri);
        return path != null && _pathsMatch(path, track.videoId);
      }
      return false;
    });
    if (alreadyInPlaylist) return true;

    // Handle genuine local tracks (e.g. from local folder or restored local queue)
    if (_isLocalTrack(track)) {
      final file = File(track.videoId);
      if (file.existsSync()) {
        final fileSrc = AudioSource.uri(file.uri);
        if (mounted && _playbackSessionId == session) {
          setState(() {
            _playlist.add(fileSrc);
          });
          _player.addAudioSource(fileSrc);
          return true;
        }
      }
      return false;
    }

    // Check if track is already cached offline on disk
    final cached = CachedStreamService.instance.getCachedItem(track.videoId);
    if (cached != null && File(cached.filePath).existsSync()) {
      if (!mounted || _playbackSessionId != session) return false;
      final fileSrc = AudioSource.uri(File(cached.filePath).uri);
      _onlineTrackMetadata[fileSrc.uri] = track;
      setState(() {
        _playlist.add(fileSrc);
      });
      _player.addAudioSource(fileSrc);
      return true;
    }

    try {
      final url = await StreamingService.resolveStreamUrl(track.videoId);
      if (!mounted || _playbackSessionId != session) return false;
      if (url != null) {
        final src = await _materializeSource(Uri.parse(url));
        if (src != null && mounted && _playbackSessionId == session) {
          _onlineTrackMetadata[src.uri] = track;
          _registerCachedStreamMeta(src, track, streamUrl: url);
          setState(() {
            _playlist.add(src);
          });
          _player.addAudioSource(src);
          return true;
        }
      } else {
        _showOfflineSnackBar();
      }
    } catch (e) {
      if (e is SocketException || e is HandshakeException || e is TimeoutException) {
        _showOfflineSnackBar();
      }
    }
    return false;
  }

  Future<void> _resolveLookaheadAndAppend(List<TrackInfo> tracks, {int? sessionId}) async {
    final session = sessionId ?? _playbackSessionId;
    if (tracks.isEmpty) return;
    if (!mounted || _playbackSessionId != session) return;

    // 1. Immediately resolve and add the first lookahead track for gapless preload
    final firstTrack = tracks.first;
    bool isNetworkDown = false;
    try {
      if (_isLocalTrack(firstTrack)) {
        final file = File(firstTrack.videoId);
        if (file.existsSync()) {
          final src = AudioSource.uri(file.uri);
          final alreadyIn = _playlist.any((s) {
            if (s.uri.scheme == 'file') {
              final path = _safeFilePathFromUri(s.uri);
              return path != null && _pathsMatch(path, firstTrack.videoId);
            }
            return false;
          });
          if (!alreadyIn) {
            setState(() {
              _playlist.add(src);
            });
            _player.addAudioSource(src);
            _logs.insert(
                0, '[local] Lookahead added local track: ${firstTrack.title}');
          }
        }
      } else {
        final cachedFirst =
            CachedStreamService.instance.getCachedItem(firstTrack.videoId);
        if (cachedFirst != null && File(cachedFirst.filePath).existsSync()) {
          if (!mounted || _playbackSessionId != session) return;
          final src = AudioSource.uri(File(cachedFirst.filePath).uri);
          final alreadyIn = _playlist.any((s) =>
              _onlineTrackMetadata[s.uri]?.videoId == firstTrack.videoId);
          if (!alreadyIn) {
            _onlineTrackMetadata[src.uri] = firstTrack;
            setState(() {
              _playlist.add(src);
            });
            _player.addAudioSource(src);
            _logs.insert(
                0, '[stream] Lookahead loaded from cache: ${firstTrack.title}');
          }
        } else {
          final firstUrl =
              await StreamingService.resolveStreamUrl(firstTrack.videoId);
          if (!mounted || _playbackSessionId != session) return;
          if (firstUrl != null) {
            final src = await _materializeSource(Uri.parse(firstUrl));
            if (src != null && mounted && _playbackSessionId == session) {
              final alreadyIn = _playlist.any((s) =>
                  _onlineTrackMetadata[s.uri]?.videoId == firstTrack.videoId);
              if (!alreadyIn) {
                _onlineTrackMetadata[src.uri] = firstTrack;
                _registerCachedStreamMeta(src, firstTrack, streamUrl: firstUrl);
                setState(() {
                  _playlist.add(src);
                });
                _player.addAudioSource(src);
                _logs.insert(
                    0, '[stream] Lookahead preloaded: ${firstTrack.title}');
              }
            }
          } else {
            isNetworkDown = true;
          }
        }
      }
    } catch (e) {
      if (!mounted || _playbackSessionId != session) return;
      _logs.insert(
          0, '[stream] Lookahead resolve error for ${firstTrack.title}: $e');
      if (e is SocketException || e is HandshakeException || e is TimeoutException) {
        isNetworkDown = true;
      }
    }

    if (isNetworkDown) {
      // If the immediate lookahead failed due to network being down/offline, stop hammering remaining tracks
      _showOfflineSnackBar();
      return;
    }

    // 2. Progressively resolve remaining tracks in background
    if (tracks.length > 1) {
      final remaining = tracks.sublist(1);
      for (final track in remaining) {
        if (!mounted || _playbackSessionId != session) break;
        try {
          if (_isLocalTrack(track)) {
            final file = File(track.videoId);
            if (file.existsSync()) {
              final src = AudioSource.uri(file.uri);
              final alreadyIn = _playlist.any((s) {
                if (s.uri.scheme == 'file') {
                  final path = _safeFilePathFromUri(s.uri);
                  return path != null && _pathsMatch(path, track.videoId);
                }
                return false;
              });
              if (!alreadyIn) {
                setState(() {
                  _playlist.add(src);
                });
                _player.addAudioSource(src);
              }
            }
          } else {
            final cachedRem =
                CachedStreamService.instance.getCachedItem(track.videoId);
            if (cachedRem != null && File(cachedRem.filePath).existsSync()) {
              if (!mounted || _playbackSessionId != session) break;
              final src = AudioSource.uri(File(cachedRem.filePath).uri);
              final alreadyIn = _playlist.any((s) =>
                  _onlineTrackMetadata[s.uri]?.videoId == track.videoId);
              if (!alreadyIn) {
                _onlineTrackMetadata[src.uri] = track;
                setState(() {
                  _playlist.add(src);
                });
                _player.addAudioSource(src);
              }
            } else {
              final url = await StreamingService.resolveStreamUrl(track.videoId);
              if (!mounted || _playbackSessionId != session) break;
              if (url != null) {
                final src = await _materializeSource(Uri.parse(url));
                if (src != null && mounted && _playbackSessionId == session) {
                  final alreadyIn = _playlist.any((s) =>
                      _onlineTrackMetadata[s.uri]?.videoId == track.videoId);
                  if (!alreadyIn) {
                    _onlineTrackMetadata[src.uri] = track;
                    _registerCachedStreamMeta(src, track, streamUrl: url);
                    setState(() {
                      _playlist.add(src);
                    });
                    _player.addAudioSource(src);
                  }
                }
              } else {
                // Network failed / offline, abort background lookahead loop
                _showOfflineSnackBar();
                break;
              }
            }
          }
        } catch (e) {
          if (e is SocketException || e is HandshakeException || e is TimeoutException) {
            _showOfflineSnackBar();
            break;
          }
        }
      }
    }
  }

  /// Plays online tracks from album/playlist detail screen.
  /// Resolves videoIds → MP3 URLs via the streaming API.
  Future<void> _playOnlineTracks(
    List<TrackInfo> tracks, {
    int initialIndex = 0,
  }) async {
    _isFtpDownloading = false;
    if (tracks.isEmpty) return;

    _playbackSessionId++;
    final session = _playbackSessionId;

    if (initialIndex < 0 || initialIndex >= tracks.length) {
      initialIndex = 0;
    }
    final tappedTrack = tracks[initialIndex];
    final AudioSource firstSource;

    if (_isLocalTrack(tappedTrack)) {
      final file = File(tappedTrack.videoId);
      if (!file.existsSync()) {
        _logs.insert(0, '[local] File not found: ${tappedTrack.videoId}');
        _showOfflineSnackBar(
            message: 'Local file not found: "${tappedTrack.title}"');
        return;
      }
      firstSource = AudioSource.uri(file.uri);
    } else {
      _logs.insert(0,
          '[stream] Resolving ${tracks.length} tracks (starting at #${initialIndex + 1})...');
      setState(() {
        _isLoading = true; // Start loading
      });

      // Check if the tapped track is already cached offline on disk
      final cached =
          CachedStreamService.instance.getCachedItem(tappedTrack.videoId);

      if (cached != null && File(cached.filePath).existsSync()) {
        _logs.insert(0,
            '[stream] Playing from offline cache: ${tappedTrack.title} (${CachedStreamService.formatBytes(cached.fileSizeBytes)})');
        firstSource = AudioSource.uri(File(cached.filePath).uri);
        _onlineTrackMetadata[firstSource.uri] = tappedTrack;
      } else {
        // Resolve online stream
        final detail =
            await StreamingService.resolveStreamDetailed(tappedTrack.videoId);
        if (!mounted || _playbackSessionId != session) return;
        if (detail == null) {
          _logs.insert(0, '[stream] Failed to resolve: ${tappedTrack.title}');
          _showOfflineSnackBar(
              message:
                  'Unable to stream "${tappedTrack.title}". Please check your internet connection.');
          setState(() {
            _isLoading = false; // Stop loading on failure
          });
          return;
        }
        final firstUrl = detail.url;

        _logs.insert(
          0,
          detail.isFallback
              ? '[stream] Fallback stream: ${detail.bitrateKbps.toStringAsFixed(0)}k MP3 (${tappedTrack.title})'
              : '[stream] Direct stream: Tag ${detail.itag ?? 0} • ${detail.audioCodec} • ${detail.bitrateKbps.toStringAsFixed(1)} kbps (${tappedTrack.title})',
        );

        final materialized = await _materializeSource(Uri.parse(firstUrl));
        if (!mounted || _playbackSessionId != session) return;
        if (materialized == null) {
          _logs.insert(0, '[stream] Failed to materialize: ${tappedTrack.title}');
          setState(() {
            _isLoading = false; // Stop loading on failure
          });
          return;
        }

        firstSource = materialized;
        _onlineTrackMetadata[firstSource.uri] = tappedTrack;
        _registerCachedStreamMeta(firstSource, tappedTrack, streamUrl: firstUrl);
      }
    }

    if (!mounted || _playbackSessionId != session) return;

    // Populate UI queue immediately
    setState(() {
      _currentUiQueue.clear();
      _currentUiQueue.addAll(tracks);
    });

    // Populate playlist with initial source
    setState(() {
      _playlist
        ..clear()
        ..add(firstSource);
    });

    _player.setAudioSources(
      _playlist,
      initialIndex: 0,
      initialPosition: Duration.zero,
      useLazyPreparation: true,
    );

    // Stop loading once audio sources are set and player command sent
    setState(() {
      _isLoading = false;
    });

    _showNowPlayingScreen();

    // If only one track was selected and it's an online stream, fetch "Up Next" suggestions
    if (tracks.length == 1 && !_isLocalTrack(tappedTrack)) {
      _fetchAndAppendUpNext(tappedTrack.videoId, sessionId: session);
    } else if (tracks.length > 1) {
      // Multiple tracks provided: resolve remaining tracks with lookahead priority
      final remainingTracks = [
        for (int i = 0; i < tracks.length; i++)
          if (i != initialIndex) tracks[i],
      ];
      _resolveLookaheadAndAppend(remainingTracks, sessionId: session);
    }
  }

  bool _isSwitchingQueueTrack = false;

  /// Prioritizes resolving and playing a track from the _currentUiQueue.
  Future<void> _playQueueIndex(int queueIndex) async {
    _isFtpDownloading = false;
    if (_isSwitchingQueueTrack) return;
    if (queueIndex < 0 || queueIndex >= _currentUiQueue.length) return;

    _isSwitchingQueueTrack = true;
    final session = _playbackSessionId;
    try {
      final targetTrack = _currentUiQueue[queueIndex];
      _logs.insert(0, '[queue] Prioritizing: ${targetTrack.title}');

      // If it's already in the playlist, just jump to it
      // We assume the playlist order roughly matches the queue order of resolved tracks
      final existingIndex = _playlist.indexWhere((src) {
        if (_onlineTrackMetadata.containsKey(src.uri)) {
          return _onlineTrackMetadata[src.uri]?.videoId == targetTrack.videoId;
        } else if (src.uri.scheme == 'file') {
          final path = _safeFilePathFromUri(src.uri);
          return path != null && _pathsMatch(path, targetTrack.videoId);
        }
        return false;
      });

      if (existingIndex != -1) {
        // Track is already resolved and in the playlist. Just seek to it.
        _player.setAudioSources(
          _playlist,
          initialIndex: existingIndex,
          initialPosition: Duration.zero,
          useLazyPreparation: true,
        );
      } else {
        // It's unresolved in playlist. Check if it's local or cached offline on disk first.
        bool resolved = false;
        try {
          if (_isLocalTrack(targetTrack)) {
            final file = File(targetTrack.videoId);
            if (file.existsSync()) {
              final src = AudioSource.uri(file.uri);
              if (mounted && _playbackSessionId == session) {
                setState(() {
                  _playlist.add(src);
                });
                _player.setAudioSources(
                  _playlist,
                  initialIndex: _playlist.length - 1,
                  initialPosition: Duration.zero,
                  useLazyPreparation: true,
                );
                resolved = true;
              }
            }
          } else {
            final cached =
                CachedStreamService.instance.getCachedItem(targetTrack.videoId);
            if (cached != null && File(cached.filePath).existsSync()) {
              final src = AudioSource.uri(File(cached.filePath).uri);
              if (mounted && _playbackSessionId == session) {
                _onlineTrackMetadata[src.uri] = targetTrack;
                setState(() {
                  _playlist.add(src);
                });
                _player.setAudioSources(
                  _playlist,
                  initialIndex: _playlist.length - 1,
                  initialPosition: Duration.zero,
                  useLazyPreparation: true,
                );
                resolved = true;
              }
            } else {
              final url =
                  await StreamingService.resolveStreamUrl(targetTrack.videoId);
              if (!mounted || _playbackSessionId != session) return;
              if (url != null) {
                final src = await _materializeSource(Uri.parse(url));
                if (src != null && mounted && _playbackSessionId == session) {
                  _onlineTrackMetadata[src.uri] = targetTrack;
                  _registerCachedStreamMeta(src, targetTrack, streamUrl: url);

                  setState(() {
                    _playlist.add(src);
                  });

                  _player.setAudioSources(
                    _playlist,
                    initialIndex: _playlist.length - 1,
                    initialPosition: Duration.zero,
                    useLazyPreparation: true,
                  );
                  resolved = true;
                }
              } else {
                _logs.insert(0, '[queue] Skip: ${targetTrack.title} (no URL)');
                _showOfflineSnackBar(
                    message:
                        'Unable to stream "${targetTrack.title}". Trying next track...');
              }
            }
          }
        } catch (e) {
          _logs.insert(0, '[queue] Error resolving ${targetTrack.title}: $e');
          _showOfflineSnackBar();
        }

        // If this track failed to resolve (e.g. broken / geo-blocked / offline), auto-skip to next track in queue
        if (!resolved &&
            queueIndex + 1 < _currentUiQueue.length &&
            mounted &&
            _playbackSessionId == session) {
          _isSwitchingQueueTrack = false;
          _playQueueIndex(queueIndex + 1);
          return;
        }
      }

      // Lookahead window shift: resolve next track in queue if available
      if (queueIndex + 1 < _currentUiQueue.length &&
          mounted &&
          _playbackSessionId == session) {
        _ensureTrackInPlaylist(_currentUiQueue[queueIndex + 1],
            sessionId: session);
      }
    } finally {
      _isSwitchingQueueTrack = false;
    }
  }

  void _reorderQueue(int oldIndex, int newIndex) {
    setState(() {
      if (oldIndex < newIndex) {
        newIndex -= 1;
      }
      final item = _currentUiQueue.removeAt(oldIndex);
      _currentUiQueue.insert(newIndex, item);

      // Attempt to reorder _playlist to match if the items are resolved
      final resolvedOldIndex = _playlist.indexWhere((src) {
        if (_onlineTrackMetadata.containsKey(src.uri)) {
          return _onlineTrackMetadata[src.uri]?.videoId == item.videoId;
        } else if (src.uri.scheme == 'file') {
          final path = _safeFilePathFromUri(src.uri);
          return path != null && path == item.videoId;
        }
        return false;
      });
      if (resolvedOldIndex != -1) {
        // Find the resolved new index based on the nearest resolved neighbor
        // This is complex, so for simplicity we just reorder the UI queue and
        // let the audio engine rely on `_playlist`'s current order unless we
        // fully reconstruct `_playlist`.
        // For now, we will just move the item in `_playlist` to the end if we can't figure it out,
        // or ideally, we'd rebuild `_playlist` securely based on `_currentUiQueue`.

        // Simple reconstruction of `_playlist` based on `_currentUiQueue` order
        final newPlaylist = <AudioSource>[];
        for (final track in _currentUiQueue) {
          final existingSrc = _playlist.firstWhere((src) {
            if (_onlineTrackMetadata.containsKey(src.uri)) {
              return _onlineTrackMetadata[src.uri]?.videoId == track.videoId;
            } else if (src.uri.scheme == 'file') {
              final path = _safeFilePathFromUri(src.uri);
              return path != null && path == track.videoId;
            }
            return false;
          }, orElse: () => AudioSource.uri(Uri()) // Dummy that won't match
              );
          if (existingSrc.uri.toString().isNotEmpty) {
            newPlaylist.add(existingSrc);
          }
        }
        _playlist
          ..clear()
          ..addAll(newPlaylist);

        final currentIndex = _status.value.currentIndex;
        _player.setAudioSources(
          _playlist,
          initialIndex: currentIndex >= 0 && currentIndex < _playlist.length
              ? currentIndex
              : 0,
          initialPosition:
              Duration(seconds: _status.value.positionSeconds.toInt()),
          useLazyPreparation: true,
        );
      }
    });
  }

  void _removeFromQueue(int index) {
    if (index < 0 || index >= _currentUiQueue.length) return;
    setState(() {
      final removedTrack = _currentUiQueue.removeAt(index);

      int playlistIndex = _playlist.indexWhere((src) {
        if (_onlineTrackMetadata.containsKey(src.uri)) {
          return _onlineTrackMetadata[src.uri]?.videoId == removedTrack.videoId;
        } else if (src.uri.scheme == 'file') {
          final path = _safeFilePathFromUri(src.uri);
          return path != null && path == removedTrack.videoId;
        }
        return false;
      });

      if (playlistIndex != -1) {
        _playlist.removeAt(playlistIndex);
      } else if (index < _playlist.length) {
        _playlist.removeAt(index);
      }

      final currentIndex = _status.value.currentIndex;
      if (_playlist.isNotEmpty) {
        int newIndex = currentIndex;
        if (playlistIndex != -1 && playlistIndex < currentIndex) {
          newIndex = (currentIndex - 1).clamp(0, _playlist.length - 1);
        } else if (newIndex >= _playlist.length) {
          newIndex = _playlist.length - 1;
        }

        _player.setAudioSources(
          _playlist,
          initialIndex: newIndex,
          initialPosition:
              Duration(seconds: _status.value.positionSeconds.toInt()),
          useLazyPreparation: true,
        );
      } else {
        _player.stop();
      }
    });
    _saveQueue();
    _logs.insert(0, '[queue] Removed track from queue at index $index');
  }

  void _clearQueue() {
    _playbackSessionId++;
    setState(() {
      _currentUiQueue.clear();
      _playlist.clear();
      _player.stop();
    });
    _saveQueue();
    _logs.insert(0, '[queue] Queue cleared.');
  }

  void _shuffleQueue() {
    if (_currentUiQueue.length <= 1) return;
    setState(() {
      final currentIndex = _status.value.currentIndex;
      TrackInfo? currentTrack;
      AudioSource? currentSource;

      if (currentIndex >= 0 && currentIndex < _currentUiQueue.length) {
        currentTrack = _currentUiQueue[currentIndex];
      }
      if (currentIndex >= 0 && currentIndex < _playlist.length) {
        currentSource = _playlist[currentIndex];
      }

      final remainingTracks = List<TrackInfo>.from(_currentUiQueue);
      if (currentTrack != null) {
        remainingTracks.remove(currentTrack);
      }
      remainingTracks.shuffle();

      _currentUiQueue.clear();
      if (currentTrack != null) {
        _currentUiQueue.add(currentTrack);
      }
      _currentUiQueue.addAll(remainingTracks);

      final newPlaylist = <AudioSource>[];
      if (currentSource != null) {
        newPlaylist.add(currentSource);
      }
      for (final track in remainingTracks) {
        final existingSrc = _playlist.firstWhere((src) {
          if (_onlineTrackMetadata.containsKey(src.uri)) {
            return _onlineTrackMetadata[src.uri]?.videoId == track.videoId;
          } else if (src.uri.scheme == 'file') {
            final path = _safeFilePathFromUri(src.uri);
            return path != null && path == track.videoId;
          }
          return false;
        }, orElse: () => AudioSource.uri(Uri()));
        if (existingSrc.uri.toString().isNotEmpty) {
          newPlaylist.add(existingSrc);
        }
      }

      _playlist
        ..clear()
        ..addAll(newPlaylist);

      _player.setAudioSources(
        _playlist,
        initialIndex: 0,
        initialPosition:
            Duration(seconds: _status.value.positionSeconds.toInt()),
        useLazyPreparation: true,
      );
    });
    _saveQueue();
    _logs.insert(0, '[queue] Queue shuffled.');
  }

  Future<void> _queueNextTrack(TrackInfo track) async {
    _isFtpDownloading = false;
    final uri = track.videoId.startsWith('http')
        ? Uri.parse(track.videoId)
        : Uri.file(track.videoId, windows: Platform.isWindows);

    final src = await _materializeSource(uri);
    if (src == null) {
      _logs.insert(
          0, '[queue] Failed to materialize source for: ${track.title}');
      return;
    }

    if (src.uri.scheme != 'file') {
      _onlineTrackMetadata[src.uri] = track;
    }

    final currentIdx = _status.value.currentIndex;
    final insertIdx = (currentIdx >= 0 && currentIdx < _playlist.length)
        ? currentIdx + 1
        : _playlist.length;

    setState(() {
      if (insertIdx >= _currentUiQueue.length) {
        _currentUiQueue.add(track);
        _playlist.add(src);
      } else {
        _currentUiQueue.insert(insertIdx, track);
        _playlist.insert(insertIdx, src);
      }
    });

    _player.setAudioSources(
      _playlist,
      initialIndex: currentIdx >= 0 ? currentIdx : 0,
      initialPosition: Duration(seconds: _status.value.positionSeconds.toInt()),
      useLazyPreparation: true,
    );

    _saveQueue();
    _logs.insert(0, '[queue] Appended to Play Next: ${track.title}');
  }

  Future<void> _handleDeletedTrack(String filePath) async {
    final currentIdx = _status.value.currentIndex;
    final isCurrentPlaying = currentIdx >= 0 &&
        currentIdx < _currentUiQueue.length &&
        _currentUiQueue[currentIdx].videoId == filePath;

    if (isCurrentPlaying) {
      if (_currentUiQueue.length > 1) {
        _player.next();
      } else {
        _player.stop();
      }
    }

    setState(() {
      _currentUiQueue.removeWhere((t) => t.videoId == filePath);
      _playlist.removeWhere((src) {
        if (src.uri.scheme == 'file') {
          final p = _safeFilePathFromUri(src.uri);
          return p != null && p == filePath;
        }
        return false;
      });
    });

    if (_playlist.isNotEmpty) {
      int newIndex = _status.value.currentIndex;
      if (newIndex >= _playlist.length) newIndex = _playlist.length - 1;
      if (newIndex < 0) newIndex = 0;
      _player.setAudioSources(
        _playlist,
        initialIndex: newIndex,
        autoPlay: _status.value.isPlaying,
      );
    } else {
      _player.stop();
    }

    _saveQueue();
    _logs.insert(
        0, '[delete] Removed deleted track from active queue and re-synced player: $filePath');
  }

  /// Plays tracks selected from the Recently Played history list.
  Future<void> _playHistoryTracks(
    List<RecentlyPlayedTrack> tracks, {
    int initialIndex = 0,
  }) async {
    if (tracks.isEmpty) return;

    // We can convert RecentlyPlayedTrack to TrackInfo and re-use _playOnlineTracks
    // because it handles both local file paths and online streams smoothly due to our earlier fixes.
    final trackInfos = tracks
        .map((t) => TrackInfo(
              videoId: t.videoId,
              title: t.title,
              artist: t.artist,
              thumbnailUrl: t.thumbnailUrl,
              durationSeconds: t.durationSeconds,
            ))
        .toList();

    await _playOnlineTracks(trackInfos, initialIndex: initialIndex);
  }

  /// Plays tracks selected from the Liked Songs list.
  Future<void> _playLikedSongs(
    List<LikedSong> tracks, {
    int initialIndex = 0,
  }) async {
    if (tracks.isEmpty) return;

    final trackInfos = tracks
        .map((t) => TrackInfo(
              videoId: t.videoId,
              title: t.title,
              artist: t.artist,
              thumbnailUrl: t.thumbnailUrl,
              durationSeconds: t.durationSeconds,
            ))
        .toList();

    await _playOnlineTracks(trackInfos, initialIndex: initialIndex);
  }

  /// Plays tracks selected from the Cached Streams list as an offline playlist queue.
  Future<void> _playCachedStreams(
    List<CachedStreamItem> tracks, {
    int initialIndex = 0,
  }) async {
    _isFtpDownloading = false;
    if (tracks.isEmpty) return;

    _playbackSessionId++;
    final session = _playbackSessionId;

    final sources = <AudioSource>[];
    final uiQueue = <TrackInfo>[];
    int resolvedIndex = 0;

    for (int i = 0; i < tracks.length; i++) {
      final t = tracks[i];
      final file = File(t.filePath);
      if (file.existsSync()) {
        final src = AudioSource.uri(file.uri);
        sources.add(src);
        final trackInfo = TrackInfo(
          videoId: t.videoId.isNotEmpty ? t.videoId : t.filePath,
          title: t.title,
          artist: t.artist,
          thumbnailUrl: t.thumbnailUrl,
          durationSeconds: t.durationSeconds,
        );
        _onlineTrackMetadata[src.uri] = trackInfo;
        uiQueue.add(trackInfo);
        if (i == initialIndex) {
          resolvedIndex = sources.length - 1;
        }
      } else if (t.videoId.isNotEmpty &&
          !t.videoId.contains(Platform.pathSeparator)) {
        // Cached file missing (evicted by OS temp cleaning), queue online stream
        uiQueue.add(TrackInfo(
          videoId: t.videoId,
          title: t.title,
          artist: t.artist,
          thumbnailUrl: t.thumbnailUrl,
          durationSeconds: t.durationSeconds,
        ));
      }
    }

    if (sources.isEmpty) {
      if (uiQueue.isNotEmpty) {
        await _playOnlineTracks(uiQueue, initialIndex: initialIndex);
      }
      return;
    }

    if (!mounted || _playbackSessionId != session) return;

    setState(() {
      _currentUiQueue
        ..clear()
        ..addAll(uiQueue);

      _playlist
        ..clear()
        ..addAll(sources);
    });

    _player.setAudioSources(
      _playlist,
      initialIndex: resolvedIndex.clamp(0, _playlist.length - 1),
      initialPosition: Duration.zero,
      useLazyPreparation: true,
    );

    _saveQueue();
    _showNowPlayingScreen();
  }

  String _nameFromSource(AudioSource source) {
    if (_onlineTrackMetadata.containsKey(source.uri)) {
      return _onlineTrackMetadata[source.uri]!.title;
    }
    final uri = source.uri;
    if (uri.scheme == 'file') {
      final p = _safeFilePathFromUri(uri);
      if (p == null || p.isEmpty) {
        return uri.toString();
      }
      final sep = Platform.pathSeparator;
      final i = p.lastIndexOf(sep);
      return i >= 0 ? p.substring(i + 1) : p;
    }
    if (uri.pathSegments.isNotEmpty) {
      final last = uri.pathSegments.last;
      if (last.isNotEmpty) return last;
    }
    return uri.toString();
  }

  String _subtitleFromSource(AudioSource source) {
    if (_onlineTrackMetadata.containsKey(source.uri)) {
      return _onlineTrackMetadata[source.uri]!.artist;
    }
    final uri = source.uri;
    if (uri.scheme == 'file') {
      final p = _safeFilePathFromUri(uri);
      return (p == null || p.isEmpty) ? uri.toString() : p;
    }
    return uri.toString();
  }

  int? _durationFromSource(AudioSource source) {
    if (_onlineTrackMetadata.containsKey(source.uri)) {
      return _onlineTrackMetadata[source.uri]!.durationSeconds;
    }
    return null;
  }

  String _codecFromCurrentTrack() {
    final status = _status.value;
    final idx = status.currentIndex;
    if (idx < 0 || idx >= _playlist.length) return 'AUDIO';
    final name = _nameFromSource(_playlist[idx]).toLowerCase();
    if (name.endsWith('.flac')) return 'FLAC';
    if (name.endsWith('.wav')) return 'WAV';
    if (name.endsWith('.ogg')) return 'OGG';
    if (name.endsWith('.m4a')) return 'AAC';
    if (name.endsWith('.aac')) return 'AAC';
    if (name.endsWith('.mp3')) return 'MP3';
    // Try to extract extension
    final dotIdx = name.lastIndexOf('.');
    if (dotIdx > 0 && dotIdx < name.length - 1) {
      return name.substring(dotIdx + 1).toUpperCase();
    }
    return 'AUDIO';
  }

  Future<void> _playNetworkFile(
      String filePath, String title, String artist) async {
    _isFtpDownloading = false;
    _playbackSessionId++;
    final session = _playbackSessionId;
    final file = File(filePath);
    final src = AudioSource.file(filePath, title: title, artist: artist);

    if (!mounted || _playbackSessionId != session) return;

    setState(() {
      _currentUiQueue.clear();
      _currentUiQueue.add(TrackInfo(
        videoId: file.absolute.path,
        title: title,
        artist: artist,
        thumbnailUrl: null,
      ));
      _playlist.clear();
      _playlist.add(src);
    });

    _player.setAudioSources(
      _playlist,
      initialIndex: 0,
      initialPosition: Duration.zero,
      useLazyPreparation: true,
    );

    _saveQueue();

    final msg = _player.getLastError();
    if (msg.isNotEmpty) {
      _logs.insert(0, '[network-play] $msg');
      setState(() {});
    }

    _showNowPlayingScreen();
  }

  Future<void> _playFtpFolder(
      List<dynamic> dynamicEntries, dynamic config, int initialIndex) async {
    final entries = dynamicEntries.cast<FtpFileEntry>();
    final ftpConfig = config as FtpConfig;

    _playbackSessionId++;
    final session = _playbackSessionId;

    _activeFtpConfig = ftpConfig;
    _pendingFtpDownloads = List.from(entries);

    final messenger = ScaffoldMessenger.of(context);
    messenger.showSnackBar(
      SnackBar(
        content: Text('Starting playback for ${entries.length} FTP tracks...'),
        duration: const Duration(seconds: 2),
      ),
    );

    try {
      final tempDir = await getTemporaryDirectory();
      final cacheDir = p.join(tempDir.path, 'ftp_cache', ftpConfig.id);
      final cacheDirFile = Directory(cacheDir);
      if (!await cacheDirFile.exists()) {
        await cacheDirFile.create(recursive: true);
      }

      if (!mounted || _playbackSessionId != session) return;

      // Prepare UI queue and AudioSources with predicted cache paths
      _currentUiQueue.clear();
      _playlist.clear();

      for (var entry in entries) {
        final cachePath = p.join(cacheDir, entry.name);
        _currentUiQueue.add(TrackInfo(
          videoId: cachePath,
          title: entry.name,
          artist: ftpConfig.name,
          thumbnailUrl: null,
        ));
        _playlist.add(AudioSource.file(cachePath,
            title: entry.name, artist: ftpConfig.name));
      }

      setState(() {});

      // Download the initial track so we can start playing immediately
      final initialEntry = entries[initialIndex];
      final initialPath = p.join(cacheDir, initialEntry.name);
      final initialFile = File(initialPath);

      if (!await initialFile.exists()) {
        messenger.showSnackBar(
          SnackBar(
              content:
                  Text('Downloading first track: ${initialEntry.name}...')),
        );
        await FtpService.downloadFile(
            ftpConfig, initialEntry.path, initialFile);
      }

      if (!mounted || _playbackSessionId != session) return;

      _player.setAudioSources(
        _playlist,
        initialIndex: initialIndex,
        initialPosition: Duration.zero,
        useLazyPreparation: true,
      );

      _saveQueue();
      _showNowPlayingScreen();

      // Start downloading the rest
      _isFtpDownloading = true;
      _processPendingFtpDownloads(cacheDir, initialIndex);
    } catch (e) {
      debugPrint('[NetworkSources] Error playing FTP folder: $e');
      messenger.showSnackBar(SnackBar(content: Text('Error: $e')));
    }
  }

  Future<void> _processPendingFtpDownloads(
      String cacheDir, int startIndex) async {
    if (_activeFtpConfig == null || _pendingFtpDownloads.isEmpty) {
      _isFtpDownloading = false;
      return;
    }

    // Determine the order to download (start from the track AFTER initialIndex, then loop around if needed)
    final downloadQueue = <FtpFileEntry>[];
    for (int i = startIndex + 1; i < _pendingFtpDownloads.length; i++) {
      downloadQueue.add(_pendingFtpDownloads[i]);
    }
    // We can also download the ones before startIndex if we want, but let's just do forward for now.

    for (var entry in downloadQueue) {
      if (!_isFtpDownloading) break; // User cancelled or started another list

      final filePath = p.join(cacheDir, entry.name);
      final file = File(filePath);

      if (await file.exists()) {
        continue; // Already downloaded
      }

      try {
        debugPrint('[FTP Download] Background fetching: ${entry.name}');
        final success =
            await FtpService.downloadFile(_activeFtpConfig!, entry.path, file);
        if (success) {
          debugPrint('[FTP Download] Finished: ${entry.name}');
        } else {
          debugPrint('[FTP Download] Failed: ${entry.name}');
        }
      } catch (e) {
        debugPrint('[FTP Download] Error on ${entry.name}: $e');
      }
    }
    _isFtpDownloading = false;
  }

  void _showNowPlayingScreen() {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      useSafeArea: false,
      constraints: BoxConstraints(
        maxWidth: MediaQuery.of(context).size.width,
        maxHeight: MediaQuery.of(context).size.height,
      ),
      builder: (context) {
        return ValueListenableBuilder<PlayerStatus>(
          valueListenable: _status,
          builder: (context, status, _) {
            final idx = status.currentIndex;
            final hasTrack =
                _playlist.isNotEmpty && idx >= 0 && idx < _playlist.length;
            final currentSource = hasTrack ? _playlist[idx] : null;

            final currentSourceType = (hasTrack &&
                    !_onlineTrackMetadata.containsKey(currentSource!.uri))
                ? 'local'
                : 'online';

            final currentVideoId = (hasTrack && currentSourceType == 'online')
                ? _onlineTrackMetadata[currentSource!.uri]?.videoId
                : null;

            return ValueListenableBuilder<TrackMetadata>(
              valueListenable: _metadata,
              builder: (context, meta, _) {
                return NowPlayingScreen(
                  statusNotifier: _status,
                  player: _player,
                  albumArt: meta.albumArt,
                  artist: meta.artist,
                  codec: _codecFromCurrentTrack(),
                  durationOverride:
                      hasTrack ? _durationFromSource(currentSource!) : null,
                  videoId: currentVideoId,
                  getTitle: (index) => (index >= 0 && index < _playlist.length)
                      ? _nameFromSource(_playlist[index])
                      : 'No track selected',
                  onMinimize: () => Navigator.of(context).pop(),
                  queue: _currentUiQueue,
                  onPlayQueueIndex: _playQueueIndex,
                  onReorderQueue: _reorderQueue,
                  onRemoveFromQueue: _removeFromQueue,
                  onClearQueue: _clearQueue,
                  onShuffleQueue: _shuffleQueue,
                  sourceType: currentSourceType,
                  onPlayTracks: _playOnlineTracks,
                  analyzerEnabled: _analyzerEnabled,
                  analyzerType: _analyzerType,
                  analyzerAutoFit: _analyzerAutoFit,
                  analyzerShowGrids: _analyzerShowGrids,
                  outputSampleRate: _outputSampleRate,
                  onAnalyzerEnabledChanged: (v) {
                    setState(() => _analyzerEnabled = v);
                    _player.setAnalyzerEnabled(v);
                    _saveEngineSettings();
                  },
                  onNavigateToHistory: () {
                    Navigator.of(context).pop();
                    Navigator.of(context).push(
                      MaterialPageRoute(
                        builder: (_) => RecentlyPlayedScreen(
                          onPlayTracks: _playHistoryTracks,
                        ),
                      ),
                    );
                  },
                );
              },
            );
          },
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    return ShowCaseWidget(
      onStart: (index, key) {
        if (key == _homeTabKey) {
          setState(() => _tabIndex = 0);
        } else if (key == _libraryTabKey) {
          setState(() => _tabIndex = 1);
        } else if (key == _effectsTabKey || key == _effectsKnobKey) {
          setState(() => _tabIndex = 2);
        } else if (key == _settingsTabKey) {
          setState(() => _tabIndex = 3);
        }
      },
      onComplete: (index, key) {
        if (mounted) {
          setState(() => _tabIndex = 0);
        }
      },
      builder: (showContext) {
        _showcaseContext = showContext;
        return Scaffold(
          backgroundColor: context.bgDark,
          // appBar: AppBar(title: const Text('MiniAudio Playlist Demo')),
          body: IndexedStack(
            index: _tabIndex,
            children: [
              HomeScreen(
                onPlayTracks: _playOnlineTracks,
                onGoToDownloads: _goToLibraryTracks,
                isNested: false,
              ),
              LibraryScreen(
                key: _libraryScreenKey,
                onPlayFolder: _playFolder,
                onPlayLikedSongs: _playLikedSongs,
                onPlayCachedStreams: _playCachedStreams,
                onPlayTracks: _playOnlineTracks,
                onQueueTrack: _queueNextTrack,
                onDeleteTrack: _handleDeletedTrack,
                player: _player,
                onPlayNetworkFile: _playNetworkFile,
                onPlayFtpFolder: _playFtpFolder,
                isNested: false,
                initialTabIndex: _librarySubTabIndex,
              ),
              EffectsScreen(
                effectsKnobKey: _effectsKnobKey,
                player: _player,
                analyzerEnabled: _analyzerEnabled,
                analyzerType: _analyzerType,
                analyzerAutoFit: _analyzerAutoFit,
                analyzerShowGrids: _analyzerShowGrids,
                analyzerLogScale: _analyzerLogScale,
                outputSampleRate: _outputSampleRate,
                spectrumStyle: _spectrumStyle,
              ),
              SettingsScreen(
                  onTriggerShowcase: () => _checkAndShowOnboarding(force: true),
                  exclusiveMode: _exclusiveMode,
                  onExclusiveModeChanged: (v) {
                    setState(() => _exclusiveMode = v);
                    _saveEngineSettings();
                  },
                  player: _player,
                  analyzerEnabled: _analyzerEnabled,
                  onAnalyzerEnabledChanged: (v) {
                    setState(() => _analyzerEnabled = v);
                    _player.setAnalyzerEnabled(v);
                    _saveEngineSettings();
                  },
                  analyzerType: _analyzerType,
                  onAnalyzerTypeChanged: (v) {
                    setState(() => _analyzerType = v);
                    _saveEngineSettings();
                  },
                  onPlayNetworkFile: _playNetworkFile,
                  analyzerAutoFit: _analyzerAutoFit,
                  onAnalyzerAutoFitChanged: (v) {
                    setState(() => _analyzerAutoFit = v);
                    _saveEngineSettings();
                  },
                  analyzerShowGrids: _analyzerShowGrids,
                  onAnalyzerShowGridsChanged: (v) {
                    setState(() => _analyzerShowGrids = v);
                    _saveEngineSettings();
                  },
                  analyzerLogScale: _analyzerLogScale,
                  onAnalyzerLogScaleChanged: (v) {
                    setState(() => _analyzerLogScale = v);
                    _saveEngineSettings();
                  },
                  spectrumStyle: _spectrumStyle,
                  onSpectrumStyleChanged: (v) {
                    setState(() => _spectrumStyle = v);
                    _saveEngineSettings();
                  },
                  analyzerSampleSize: _analyzerSampleSize,
                  onAnalyzerSampleSizeChanged: (v) {
                    setState(() => _analyzerSampleSize = v);
                    _player.configureAnalyzer(
                      frameSize: v,
                      windowType: _analyzerWindowType,
                    );
                    _saveEngineSettings();
                  },
                  analyzerWindowType: _analyzerWindowType,
                  onAnalyzerWindowTypeChanged: (v) {
                    setState(() => _analyzerWindowType = v);
                    _player.configureAnalyzer(
                      frameSize: _analyzerSampleSize,
                      windowType: v,
                    );
                    _saveEngineSettings();
                  },
                  outputFormat: _outputFormat,
                  onOutputFormatChanged: (v) {
                    setState(() => _outputFormat = v);
                    _saveEngineSettings();
                  },
                  outputSampleRate: _outputSampleRate,
                  onOutputSampleRateChanged: (v) {
                    setState(() => _outputSampleRate = v);
                    if (v == 0) {
                      final activeRate =
                          AudioHardwareInspector.currentSpecs?.sampleRate ?? 48000;
                      _player.setOutputSampleRate(activeRate);
                    }
                    _saveEngineSettings();
                  },
                  outputChannels: _outputChannels,
                  onOutputChannelsChanged: (v) {
                    setState(() => _outputChannels = v);
                    _saveEngineSettings();
                  },
                  crossfadeEnabled: _crossfadeEnabled,
                  onCrossfadeEnabledChanged: (v) {
                    setState(() => _crossfadeEnabled = v);
                    _player.setCrossfadeEnabled(v);
                    _saveEngineSettings();
                  },
                  crossfadeDurationMs: _crossfadeDurationMs,
                  onCrossfadeDurationMsChanged: (v) {
                    setState(() => _crossfadeDurationMs = v);
                    _player.setCrossfadeDurationMs(v);
                    _saveEngineSettings();
                  },
                  logs: _logs,
                  logUpdateNotifier: _logUpdateCounter,
                  allowInvalidTls: _allowInvalidTlsForDownloads,
                  onAllowInvalidTlsChanged: (selected) {
                    setState(() => _allowInvalidTlsForDownloads = selected);
                    _logs.insert(
                      0,
                      selected
                          ? '[security] Invalid TLS cert acceptance enabled for fallback downloads.'
                          : '[security] Invalid TLS cert acceptance disabled.',
                    );
                    _logUpdateCounter.value++;
                    _saveEngineSettings();
                  },
                  onPollError: () {
                    final msg = _player.getLastError();
                    _logs.insert(
                        0, '[poll] ${msg.isEmpty ? "(no error)" : msg}');
                    _logUpdateCounter.value++;
                  },
                  onClearNativeError: () {
                    _player.clearLastError();
                    _logs.insert(0, '[action] Cleared native error state');
                    _logUpdateCounter.value++;
                  },
                  onClearLogs: () {
                    _logs.clear();
                    _logUpdateCounter.value++;
                  }),
            ],
          ),
          bottomNavigationBar: Container(
            color: context.bgDark,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                ValueListenableBuilder<PlayerStatus>(
                  valueListenable: _status,
                  builder: (context, status, _) {
                    if (_isLoading) {
                      return const ShimmerMiniPlayer();
                    }

                    final idx = status.currentIndex;
                    if (_playlist.isEmpty || idx < 0 || idx >= _playlist.length) {
                      return const SizedBox.shrink();
                    }
                    final src = _playlist[idx];
                    final overrideDuration = _durationFromSource(src);
                    final finalDurationSecs =
                        (overrideDuration != null && overrideDuration > 0)
                            ? overrideDuration.toDouble()
                            : status.durationSeconds;

                    final progress = finalDurationSecs > 0
                        ? (status.positionSeconds / finalDurationSecs)
                            .clamp(0.0, 1.0)
                        : 0.0;

                    return ValueListenableBuilder<TrackMetadata>(
                      valueListenable: _metadata,
                      builder: (context, meta, _) {
                        return AppShowcase(
                          showcaseKey: _miniPlayerKey,
                          title: 'Interactive Playback',
                          description:
                              'Tap to expand full controls, or swipe left/right to skip to next/previous song.',
                          currentStep: 4,
                          totalSteps: 5,
                          child: MiniPlayer(
                            title: _nameFromSource(src),
                            artist: meta.artist,
                            albumArt: meta.albumArt,
                            progress: progress,
                            isPlaying: status.isPlaying,
                            isBuffering: _isPlayerBuffering,
                            onPlayPause: () {
                              if (status.isPlaying) {
                                _player.pause();
                              } else {
                                _player.play();
                              }
                            },
                            onNext: () => _player.next(),
                            onPrevious: () => _player.previous(),
                            onTap: _showNowPlayingScreen,
                          ),
                        );
                      },
                    );
                  },
                ),
                M3ENavigationBar(
                selectedIndex: _tabIndex,
                onDestinationSelected: (i) => setState(() => _tabIndex = i),
                indicatorStyle: M3ENavBarIndicatorStyle.pill,
                labelBehavior: M3ENavBarLabelBehavior.alwaysShow,
                backgroundColor: context.bgDark,
                destinations: [
                  M3ENavigationBarDestination(
                    icon: AppShowcase(
                      showcaseKey: _homeTabKey,
                      title: 'Welcome to SautiPlay',
                      description:
                          'Your high-fidelity audio hub. Discover trending tracks, online music & curated recommendations.',
                      currentStep: 1,
                      totalSteps: 5,
                      child: const Icon(Icons.home_rounded),
                    ),
                    label: 'Home',
                  ),
                  M3ENavigationBarDestination(
                    icon: AppShowcase(
                      showcaseKey: _libraryTabKey,
                      title: 'Music Library',
                      description:
                          'Your offline audio vault. Browse local files, playlists, artists, albums & network sources.',
                      currentStep: 2,
                      totalSteps: 5,
                      child: const Icon(Icons.library_music_rounded),
                    ),
                    label: 'Library',
                  ),
                  M3ENavigationBarDestination(
                    icon: AppShowcase(
                      showcaseKey: _effectsTabKey,
                      title: 'Sauti DSP & EQ',
                      description:
                          'Tailor your sound with 10-band EQ, Sauti DSP Suite effects & real-time spectrum visualizers.',
                      currentStep: 3,
                      totalSteps: 5,
                      child: const Icon(Icons.tune),
                    ),
                    label: 'Effects',
                  ),
                  M3ENavigationBarDestination(
                    icon: AppShowcase(
                      showcaseKey: _settingsTabKey,
                      title: 'Settings & Customization',
                      description:
                          'Configure sample rates, exclusive mode, crossfade & re-trigger this tour anytime.',
                      currentStep: 5,
                      totalSteps: 5,
                      child: const Icon(Icons.settings),
                    ),
                    label: 'Settings',
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
 }

/// Bridges incoming DLNA cast requests into SautiPlay's player engine.
class _SautiRendererBridge implements DlnaRendererBridge {
  final _PlayerShellState state;
  _SautiRendererBridge(this.state);

  @override
  Future<void> loadUrl(String url, {String? title, String? artist}) async {
    state.playDlnaCast(
      url,
      title ?? 'DLNA Cast',
      artist ?? 'DLNA',
    );
  }

  @override
  void play() => state._player.play();

  @override
  void pause() => state._player.pause();

  @override
  void stop() => state._player.stop();

  @override
  Future<void> seek(Duration position) async {
    state._player.seekTo(position);
  }

  @override
  void setVolume(double gain) => state._player.setGain(gain.clamp(0.0, 1.0));

  @override
  ({bool playing, Duration position, Duration duration}) snapshot() {
    final st = state._status.value;
    return (
      playing: st.isPlaying,
      position:
          Duration(milliseconds: (st.positionSeconds * 1000).round()),
      duration: Duration(seconds: st.durationSeconds.round()),
    );
  }
}
