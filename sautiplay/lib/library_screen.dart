import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:audio_metadata_reader/audio_metadata_reader.dart' as amr;
import 'package:file_picker/file_picker.dart';
import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:material_3_expressive/material_3_expressive.dart';
import 'package:flutter_m3shapes_extended/flutter_m3shapes_extended.dart';
import 'package:path/path.dart' as p;
import 'package:permission_handler/permission_handler.dart';
import 'package:share_plus/share_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:sautiflow/sautiflow.dart';
import 'services/m3u_playlist_service.dart';

import 'album_detail_screen.dart';
import 'artist_profile_screen.dart';
import 'cached_streams_screen.dart';
import 'isolate_player.dart';
import 'models/cached_stream_item.dart';
import 'playlist_detail_screen.dart';
import 'services/app_theme_service.dart';
import 'services/cached_stream_service.dart';
import 'services/file_deletion_helper.dart';
import 'liked_songs_screen.dart'; // NEW
import 'models/liked_song.dart'; // NEW
import 'models/local_song_item.dart';
import 'network_sources_screen.dart';
import 'services/audio_file_inspector.dart';
import 'widgets/local_album_art.dart';
import 'widgets/music_info_dialog.dart';
import 'widgets/song_options_menu.dart';

class LibraryScreen extends StatefulWidget {
  final Future<void> Function(List<String> audioFilePaths, {int initialIndex})
      onPlayFolder;
  final Future<void> Function(List<LikedSong> tracks, {int initialIndex})
      onPlayLikedSongs; // NEW
  final Future<void> Function(List<CachedStreamItem> tracks,
      {int initialIndex})? onPlayCachedStreams;
  final Future<void> Function(List<TrackInfo> tracks, {int initialIndex})?
      onPlayTracks;
  final Function(TrackInfo track)? onQueueTrack;
  final Function(String filePath)? onDeleteTrack;
  final IsolateAudioPlayer? player;
  final void Function(String filePath, String title, String artist)?
      onPlayNetworkFile;
  final void Function(List<dynamic> entries, dynamic config, int initialIndex)?
      onPlayFtpFolder;
  final bool isNested;
  final int initialTabIndex;

  const LibraryScreen({
    super.key,
    required this.onPlayFolder,
    required this.onPlayLikedSongs,
    this.onPlayCachedStreams,
    this.onPlayTracks,
    this.onQueueTrack,
    this.onDeleteTrack,
    this.player,
    this.onPlayNetworkFile,
    this.onPlayFtpFolder,
    this.isNested = false,
    this.initialTabIndex = 0,
  });

  @override
  LibraryScreenState createState() => LibraryScreenState();
}

enum TrackViewMode {
  list('Standard List', Icons.view_list_rounded),
  compact('Compact List', Icons.format_list_bulleted_rounded),
  grid('Grid View', Icons.grid_view_rounded);

  const TrackViewMode(this.label, this.icon);
  final String label;
  final IconData icon;
}

enum LibraryCategory {
  tracks('Tracks', Icons.audiotrack_rounded),
  albums('Albums', Icons.album_outlined),
  artists('Artists', Icons.person_outline_rounded),
  playlists('Playlists', Icons.queue_music_rounded),
  folders('Folders', Icons.folder_outlined);

  const LibraryCategory(this.label, this.icon);
  final String label;
  final IconData icon;
}

class LibraryScreenState extends State<LibraryScreen>
    with AutomaticKeepAliveClientMixin {
  LibraryCategory _selectedCategory = LibraryCategory.tracks;

  void switchToTab(int index) {
    if (mounted) {
      setState(() {
        if (index == 0 || index == 1) {
          _selectedCategory = LibraryCategory.tracks;
        } else if (index == 2) {
          _selectedCategory = LibraryCategory.artists;
        } else if (index == 3) {
          _selectedCategory = LibraryCategory.albums;
        } else {
          _selectedCategory = LibraryCategory.playlists;
        }
      });
    }
  }

  String get _categorySectionTitle {
    switch (_selectedCategory) {
      case LibraryCategory.tracks:
        return 'Songs (${_filteredSongs.length})';
      case LibraryCategory.albums:
        return 'Albums';
      case LibraryCategory.artists:
        return 'Artists';
      case LibraryCategory.playlists:
        return 'Playlists (${_m3uPlaylists.length})';
      case LibraryCategory.folders:
        return 'Folders (${_folders.length})';
    }
  }

  @override
  bool get wantKeepAlive => true;
  static const String _prefsKey = 'sautiplay_library_folders';
  static const String _cachedSongsKey = 'sautiplay_library_cached_songs';

  Color get _surfaceDark => context.cardDark;
  Color get _primary => context.primaryColor;
  Color get _textPrimary => context.textPrimary;
  Color get _textDark => context.textMuted;
  Color get _outline => context.outlineColor;

  // State
  List<Map<String, dynamic>> _folders = [];
  List<LocalSongItem> _allSongs = [];
  List<LocalSongItem> _filteredSongs = [];
  List<SavedM3uPlaylist> _m3uPlaylists = [];
  bool _isLoading = true;
  bool _isScanning = false;
  String _scanStatus = 'Checking library for changes...';

  // Scroll Controller & Scroll Helper for large lists
  late final ScrollController _scrollController;
  bool _showScrollHelper = false;
  StreamSubscription<PlayerStatus>? _playerStatusSub;
  String? _currentlyPlayingPath;
  List<LocalSongItem>? _lastPlayedTrackList;
  TrackViewMode _trackViewMode = TrackViewMode.list;
  String _groupByOption = 'None';
  bool _isSelectionMode = false;
  final Set<String> _selectedTrackPaths = {};

  // Search & Sort filters
  final TextEditingController _searchController = TextEditingController();
  String _currentSort = 'Name (A-Z)';
  static const List<String> _sortOptions = [
    'Name (A-Z)',
    'Name (Z-A)',
    'Date Added (New-Old)',
    'Date Added (Old-New)',
    'Size (Largest)',
    'Size (Smallest)',
    'File Extension (A-Z)',
    'File Extension (Z-A)',
  ];
  static const List<String> _groupByOptions = [
    'None',
    'Album',
    'Artist',
    'Folder',
  ];

  @override
  void initState() {
    super.initState();
    _scrollController = ScrollController();
    _scrollController.addListener(_onScroll);
    if (widget.player != null) {
      _playerStatusSub = widget.player!.statusStream.listen((status) {
        if (!mounted) return;
        if (_lastPlayedTrackList != null &&
            status.currentIndex >= 0 &&
            status.currentIndex < _lastPlayedTrackList!.length) {
          final currentPath = _lastPlayedTrackList![status.currentIndex].path;
          if (_currentlyPlayingPath != currentPath) {
            setState(() => _currentlyPlayingPath = currentPath);
          }
        }
      });
    }

    if (widget.initialTabIndex == 1 || widget.initialTabIndex == 0) {
      _selectedCategory = LibraryCategory.tracks;
    } else if (widget.initialTabIndex == 2) {
      _selectedCategory = LibraryCategory.artists;
    } else if (widget.initialTabIndex == 3) {
      _selectedCategory = LibraryCategory.albums;
    } else {
      _selectedCategory = LibraryCategory.playlists;
    }
    _loadSavedFolders();
    _loadSavedM3uPlaylists();
    CachedStreamService.instance.init();
  }

  void _onScroll() {
    if (!_scrollController.hasClients) return;
    final isScrolledDown = _scrollController.offset > 350.0;
    if (_showScrollHelper != isScrolledDown) {
      setState(() => _showScrollHelper = isScrolledDown);
    }
  }

  void _scrollToPlayingTrack() {
    if (!_scrollController.hasClients || _filteredSongs.isEmpty) return;
    final playingIdx = _currentlyPlayingPath != null
        ? _filteredSongs.indexWhere((s) => s.path == _currentlyPlayingPath)
        : -1;
    if (playingIdx < 0) {
      _scrollController.animateTo(
        0,
        duration: const Duration(milliseconds: 350),
        curve: Curves.easeOutCubic,
      );
      return;
    }

    final double itemHeight =
        _trackViewMode == TrackViewMode.compact ? 58.0 : 74.0;
    // Account for slivers above the tracks list (~280px)
    final targetOffset =
        ((280.0 + (playingIdx * itemHeight)) - 180.0).clamp(
      0.0,
      _scrollController.position.maxScrollExtent,
    );

    _scrollController.animateTo(
      targetOffset,
      duration: const Duration(milliseconds: 380),
      curve: Curves.easeOutCubic,
    );
  }

  @override
  void didUpdateWidget(LibraryScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.initialTabIndex != widget.initialTabIndex) {
      switchToTab(widget.initialTabIndex);
    }
  }

  @override
  void dispose() {
    _scrollController.removeListener(_onScroll);
    _scrollController.dispose();
    _playerStatusSub?.cancel();
    _searchController.dispose();
    super.dispose();
  }

  Future<void> _loadSavedM3uPlaylists() async {
    try {
      final list = await M3uPlaylistService.instance.loadPlaylists();
      if (mounted) {
        setState(() {
          _m3uPlaylists = list;
        });
      }
    } catch (e) {
      debugPrint('Error loading M3U playlists: $e');
    }
  }

  Future<void> _importM3uFile() async {
    final hasPerm = await _requestPermissions();
    if (!hasPerm) return;

    String? path;
    try {
      if (Platform.isWindows || Platform.isLinux || Platform.isMacOS) {
        const typeGroup = XTypeGroup(
          label: 'M3U Playlists',
          extensions: <String>['m3u', 'm3u8'],
        );
        final XFile? file =
            await openFile(acceptedTypeGroups: <XTypeGroup>[typeGroup]);
        path = file?.path;
      } else {
        final result = await FilePicker.pickFiles(
          type: FileType.custom,
          allowedExtensions: ['m3u', 'm3u8'],
        );
        if (result != null && result.files.isNotEmpty) {
          path = result.files.single.path;
        }
      }
    } catch (e) {
      debugPrint('Error picking M3U file: $e');
    }

    if (path == null || path.isEmpty) return;

    setState(() => _isLoading = true);

    try {
      final sources = await AudioSource.fromM3u(path);
      final playlistName = p.basenameWithoutExtension(path);
      final tracks = sources.map((s) {
        return LocalSongItem(
          path: s.uri.scheme == 'file' ? s.uri.toFilePath() : s.uri.toString(),
          title: s.title ??
              (s.uri.scheme == 'file'
                  ? p.basenameWithoutExtension(s.uri.toFilePath())
                  : s.uri.toString()),
          artist: s.artist ?? 'Unknown Artist',
          album: playlistName,
          sizeBytes: 0,
          lastModified: DateTime.now(),
        );
      }).toList();

      final newPlaylist = SavedM3uPlaylist(
        id: DateTime.now().millisecondsSinceEpoch.toString(),
        name: playlistName,
        pathOrUrl: path,
        isNetwork: false,
        tracks: tracks,
        dateAdded: DateTime.now(),
      );

      await M3uPlaylistService.instance.saveSinglePlaylist(newPlaylist);
      await _loadSavedM3uPlaylists();

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
              content: Text(
                  'Imported M3U playlist "$playlistName" (${tracks.length} tracks)')),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Failed to import M3U file: $e')),
        );
      }
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  Future<void> _importM3uUrlDialog() async {
    final urlController = TextEditingController();
    final nameController = TextEditingController();
    final textDark = context.textMuted;
    final cardDark = context.cardDark;
    final textPrimary = context.textPrimary;

    final isMobile = MediaQuery.of(context).size.width < 600;

    final dialogContent = Material(
      color: Colors.transparent,
      child: SingleChildScrollView(
        physics: const BouncingScrollPhysics(),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            TextField(
              controller: nameController,
              style: TextStyle(color: textPrimary),
              decoration: InputDecoration(
                labelText: 'Playlist Name (Optional)',
                labelStyle: TextStyle(color: textDark),
                hintText: 'e.g. Live Radio Stations',
                hintStyle: TextStyle(color: textDark.withValues(alpha: 0.6)),
                filled: true,
                fillColor: cardDark,
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(14),
                  borderSide: BorderSide.none,
                ),
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: urlController,
              style: TextStyle(color: textPrimary),
              decoration: InputDecoration(
                labelText: 'Stream / M3U URL',
                labelStyle: TextStyle(color: textDark),
                hintText: 'https://example.com/playlist.m3u8',
                hintStyle: TextStyle(color: textDark.withValues(alpha: 0.6)),
                filled: true,
                fillColor: cardDark,
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(14),
                  borderSide: BorderSide.none,
                ),
              ),
            ),
          ],
        ),
      ),
    );

    final confirm = isMobile
        ? await M3EBottomSheet.show<bool>(
            context,
            builder: (ctx) => Padding(
              padding: EdgeInsets.only(
                left: 20,
                right: 20,
                top: 20,
                bottom: MediaQuery.of(ctx).viewInsets.bottom + 20,
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const Text(
                    'Import Stream URL',
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: 18,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  const SizedBox(height: 16),
                  dialogContent,
                  const SizedBox(height: 20),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.end,
                    children: [
                      M3EButton(
                        onPressed: () => Navigator.of(ctx).pop(false),
                        child: const Text('Cancel'),
                      ),
                      const SizedBox(width: 10),
                      M3EButton(
                        onPressed: () => Navigator.of(ctx).pop(true),
                        child: const Text('Import Stream'),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          )
        : await M3EDialog.show<bool>(
            context,
            dialog: M3EDialog(
              title: 'Import Stream URL',
              topDivider: true,
              bottomDivider: true,
              content: SizedBox(
                width: 480,
                child: dialogContent,
              ),
              actions: [
                M3EButton(
                  onPressed: () => Navigator.of(context).pop(false),
                  child: const Text('Cancel'),
                ),
                M3EButton(
                  onPressed: () => Navigator.of(context).pop(true),
                  child: const Text('Import Stream'),
                ),
              ],
            ),
          );

    if (confirm != true || urlController.text.trim().isEmpty) return;

    final url = urlController.text.trim();
    final customName = nameController.text.trim();

    setState(() => _isLoading = true);

    try {
      final sources = await AudioSource.fromM3u(url);
      final playlistName =
          customName.isNotEmpty ? customName : 'M3U Web Stream';
      final tracks = sources.map((s) {
        return LocalSongItem(
          path: s.uri.scheme == 'file' ? s.uri.toFilePath() : s.uri.toString(),
          title: s.title ??
              (s.uri.scheme == 'file'
                  ? p.basenameWithoutExtension(s.uri.toFilePath())
                  : s.uri.toString()),
          artist: s.artist ?? 'Radio Stream',
          album: playlistName,
          sizeBytes: 0,
          lastModified: DateTime.now(),
        );
      }).toList();

      final newPlaylist = SavedM3uPlaylist(
        id: DateTime.now().millisecondsSinceEpoch.toString(),
        name: playlistName,
        pathOrUrl: url,
        isNetwork: true,
        tracks: tracks,
        dateAdded: DateTime.now(),
      );

      await M3uPlaylistService.instance.saveSinglePlaylist(newPlaylist);
      await _loadSavedM3uPlaylists();

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
              content: Text(
                  'Imported M3U stream "$playlistName" (${tracks.length} tracks)')),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Failed to load M3U URL: $e')),
        );
      }
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  void _playM3uPlaylist(SavedM3uPlaylist playlist) {
    if (playlist.tracks.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Playlist has no playable tracks.')),
      );
      return;
    }
    final paths = playlist.tracks.map((t) => t.path).toList();
    widget.onPlayFolder(paths);
  }

  Future<void> _showM3uPlaylistOptions(SavedM3uPlaylist playlist) async {
    await M3EBottomSheet.show<void>(
      context,
      builder: (ctx) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 8),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              M3EListItem(
                headline: 'Play "${playlist.name}"',
                leading: Icon(
                  Icons.play_arrow_rounded,
                  color: AppThemeService.instance.currentData.primary,
                ),
                onTap: () {
                  Navigator.of(ctx).pop();
                  _playM3uPlaylist(playlist);
                },
              ),
              M3EListItem(
                headline: 'Export Playlist as .m3u8',
                leading: const Icon(
                  Icons.file_upload_outlined,
                  color: Colors.amberAccent,
                ),
                onTap: () {
                  Navigator.of(ctx).pop();
                  _exportPlaylistToM3u8(playlist.name, playlist.tracks);
                },
              ),
              M3EListItem(
                headline: 'Delete Playlist',
                leading: const Icon(
                  Icons.delete_outline_rounded,
                  color: Colors.redAccent,
                ),
                onTap: () async {
                  Navigator.of(ctx).pop();
                  await M3uPlaylistService.instance.deletePlaylist(playlist.id);
                  await _loadSavedM3uPlaylists();
                  if (mounted) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(
                        content: Text('Deleted playlist "${playlist.name}"'),
                      ),
                    );
                  }
                },
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _exportPlaylistToM3u8(
      String name, List<LocalSongItem> tracks) async {
    if (tracks.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('No tracks available to export.')),
      );
      return;
    }
    String? targetPath;
    final m3uContent = M3uPlaylistService.instance.generateM3u8Content(
      playlistName: name,
      tracks: tracks,
    );
    final bytes = Uint8List.fromList(utf8.encode(m3uContent));

    try {
      if (Platform.isWindows || Platform.isLinux || Platform.isMacOS) {
        final FileSaveLocation? location = await getSaveLocation(
          suggestedName: '${name.replaceAll(' ', '_')}.m3u8',
          acceptedTypeGroups: const [
            XTypeGroup(label: 'M3U8 Playlist', extensions: ['m3u8']),
          ],
        );
        targetPath = location?.path;
        if (targetPath != null && targetPath.isNotEmpty) {
          await M3uPlaylistService.instance.exportToM3u8(
            targetFilePath: targetPath,
            playlistName: name,
            tracks: tracks,
          );
        }
      } else {
        targetPath = await FilePicker.saveFile(
          dialogTitle: 'Export Playlist to M3U8',
          fileName: '${name.replaceAll(' ', '_')}.m3u8',
          type: FileType.custom,
          allowedExtensions: ['m3u8'],
          bytes: bytes,
        );
      }
    } catch (e) {
      debugPrint('Error opening save dialog: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Failed to export playlist: $e')),
        );
      }
      return;
    }

    if (targetPath != null && targetPath.isNotEmpty) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
              content: Text('Exported playlist to ${p.basename(targetPath)}')),
        );
      }
    }
  }

  void _toggleSelectionMode(bool enable) {
    setState(() {
      _isSelectionMode = enable;
      if (!enable) {
        _selectedTrackPaths.clear();
      }
    });
  }

  void _toggleTrackSelection(String path) {
    setState(() {
      if (_selectedTrackPaths.contains(path)) {
        _selectedTrackPaths.remove(path);
        if (_selectedTrackPaths.isEmpty) {
          _isSelectionMode = false;
        }
      } else {
        _selectedTrackPaths.add(path);
      }
    });
  }

  void _selectAllTracks() {
    setState(() {
      _selectedTrackPaths.addAll(_filteredSongs.map((s) => s.path));
    });
  }

  void _deselectAllTracks() {
    setState(() {
      _selectedTrackPaths.clear();
    });
  }

  void _playSelectedTracks({bool shuffle = false}) {
    if (_selectedTrackPaths.isEmpty) return;
    final paths = _filteredSongs
        .where((s) => _selectedTrackPaths.contains(s.path))
        .map((s) => s.path)
        .toList();
    if (shuffle) {
      paths.shuffle();
    }
    _toggleSelectionMode(false);
    widget.onPlayFolder(paths, initialIndex: 0);
  }

  void _queueSelectedTracks() {
    if (_selectedTrackPaths.isEmpty) return;
    final selectedSongs = _filteredSongs
        .where((s) => _selectedTrackPaths.contains(s.path))
        .toList();

    for (final song in selectedSongs) {
      final track = TrackInfo(
        videoId: song.path,
        title: song.title,
        artist: song.artist != 'Unknown Artist' ? song.artist : 'Local File',
        thumbnailUrl: null,
      );
      widget.onQueueTrack?.call(track);
    }
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('Added ${selectedSongs.length} tracks to Queue'),
        duration: const Duration(seconds: 2),
      ),
    );
    _toggleSelectionMode(false);
  }

  Future<void> _showAddToPlaylistSheet(
      {List<LocalSongItem>? explicitSongs}) async {
    final songsToAdd = explicitSongs ??
        _filteredSongs
            .where((s) => _selectedTrackPaths.contains(s.path))
            .toList();

    if (songsToAdd.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('No tracks selected to add.')),
      );
      return;
    }

    final isMobile = MediaQuery.of(context).size.width < 600;
    final primaryColor = context.primaryColor;
    final textPrimary = context.textPrimary;
    final textDark = context.textMuted;
    final cardDark = context.cardDark;

    final sheetContent = Material(
      color: Colors.transparent,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxHeight: 450),
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding:
                    const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                child: Row(
                  children: [
                    Icon(Icons.playlist_add_rounded,
                        color: primaryColor, size: 24),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        'Add to Playlist (${songsToAdd.length} track${songsToAdd.length == 1 ? '' : 's'})',
                        style: TextStyle(
                          color: textPrimary,
                          fontSize: 17,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              Divider(height: 1, color: Colors.white.withValues(alpha: 0.1)),
              const SizedBox(height: 6),
              // Create New Playlist Option
              Padding(
                padding:
                    const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
                child: Material(
                  color: primaryColor.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(14),
                  child: InkWell(
                    borderRadius: BorderRadius.circular(14),
                    onTap: () async {
                      Navigator.of(context).pop();
                      await _createNewPlaylistDialog(songsToAdd);
                    },
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 14, vertical: 12),
                      child: Row(
                        children: [
                          Container(
                            width: 40,
                            height: 40,
                            decoration: BoxDecoration(
                              color: primaryColor.withValues(alpha: 0.2),
                              borderRadius: BorderRadius.circular(10),
                            ),
                            child: Icon(Icons.add_rounded,
                                color: primaryColor, size: 24),
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  'New Playlist',
                                  style: TextStyle(
                                    color: textPrimary,
                                    fontWeight: FontWeight.bold,
                                    fontSize: 15,
                                  ),
                                ),
                                const SizedBox(height: 2),
                                Text(
                                  'Create a new mix from selected songs',
                                  style:
                                      TextStyle(color: textDark, fontSize: 12),
                                ),
                              ],
                            ),
                          ),
                          Icon(Icons.arrow_forward_ios_rounded,
                              color: primaryColor, size: 16),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
              if (_m3uPlaylists.isNotEmpty) ...[
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 12, 16, 6),
                  child: Text(
                    'EXISTING PLAYLISTS',
                    style: TextStyle(
                      color: textDark.withValues(alpha: 0.8),
                      fontSize: 11,
                      fontWeight: FontWeight.bold,
                      letterSpacing: 1.0,
                    ),
                  ),
                ),
                ...List.generate(_m3uPlaylists.length, (idx) {
                  final pl = _m3uPlaylists[idx];
                  return Padding(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 12, vertical: 3),
                    child: Material(
                      color: cardDark,
                      borderRadius: BorderRadius.circular(12),
                      child: InkWell(
                        borderRadius: BorderRadius.circular(12),
                        onTap: () async {
                          Navigator.of(context).pop();
                          final updated = await M3uPlaylistService.instance
                              .addTracksToPlaylist(
                            playlistId: pl.id,
                            tracks: songsToAdd,
                          );
                          if (updated != null) {
                            await _loadSavedM3uPlaylists();
                            _toggleSelectionMode(false);
                            if (mounted) {
                              ScaffoldMessenger.of(context).showSnackBar(
                                SnackBar(
                                  content: Text(
                                      'Added ${songsToAdd.length} tracks to "${pl.name}"'),
                                  duration: const Duration(seconds: 2),
                                ),
                              );
                            }
                          }
                        },
                        child: Padding(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 14, vertical: 10),
                          child: Row(
                            children: [
                              Container(
                                width: 38,
                                height: 38,
                                decoration: BoxDecoration(
                                  color: primaryColor.withValues(alpha: 0.15),
                                  borderRadius: BorderRadius.circular(9),
                                ),
                                child: Icon(
                                  Icons.queue_music_rounded,
                                  color: primaryColor,
                                  size: 20,
                                ),
                              ),
                              const SizedBox(width: 12),
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                      pl.name,
                                      style: TextStyle(
                                        color: textPrimary,
                                        fontWeight: FontWeight.w600,
                                        fontSize: 14,
                                      ),
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                    ),
                                    const SizedBox(height: 2),
                                    Text(
                                      '${pl.tracks.length} track${pl.tracks.length == 1 ? '' : 's'}',
                                      style: TextStyle(
                                          color: textDark, fontSize: 12),
                                    ),
                                  ],
                                ),
                              ),
                              Icon(Icons.add_circle_outline_rounded,
                                  color: primaryColor, size: 22),
                            ],
                          ),
                        ),
                      ),
                    ),
                  );
                }),
                const SizedBox(height: 12),
              ],
            ],
          ),
        ),
      ),
    );

    if (isMobile) {
      await M3EBottomSheet.show<void>(
        context,
        builder: (ctx) => SafeArea(
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 8),
            child: sheetContent,
          ),
        ),
      );
    } else {
      await M3EDialog.show<void>(
        context,
        dialog: M3EDialog(
          title: 'Add to Playlist',
          topDivider: true,
          bottomDivider: true,
          content: SizedBox(
            width: 440,
            child: sheetContent,
          ),
          actions: [
            M3EButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('Cancel'),
            ),
          ],
        ),
      );
    }
  }

  Future<void> _createNewPlaylistDialog(List<LocalSongItem> songsToAdd) async {
    final controller = TextEditingController(
      text: 'My Playlist ${_m3uPlaylists.length + 1}',
    );
    final confirm = await M3EDialog.show<bool>(
      context,
      dialog: M3EDialog(
        title: 'Create Playlist',
        topDivider: true,
        bottomDivider: true,
        content: Material(
          color: Colors.transparent,
          child: TextField(
            controller: controller,
            autofocus: true,
            style: TextStyle(color: _textPrimary),
            decoration: InputDecoration(
              labelText: 'Playlist Name',
              labelStyle: TextStyle(color: _textDark),
              filled: true,
              fillColor: _surfaceDark,
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(12),
                borderSide: BorderSide.none,
              ),
            ),
          ),
        ),
        actions: [
          M3EButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          M3EButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Create'),
          ),
        ],
      ),
    );

    if (confirm == true && controller.text.trim().isNotEmpty) {
      final pl = await M3uPlaylistService.instance.createPlaylist(
        name: controller.text.trim(),
        tracks: songsToAdd,
      );
      await _loadSavedM3uPlaylists();
      _toggleSelectionMode(false);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
                'Created playlist "${pl.name}" with ${songsToAdd.length} tracks'),
            action: SnackBarAction(
              label: 'View',
              onPressed: () {
                setState(() => _selectedCategory = LibraryCategory.playlists);
              },
            ),
          ),
        );
      }
    }
  }

  Future<void> _loadSavedFolders() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final savedData = prefs.getStringList(_prefsKey) ?? [];

      final loadedFolders = savedData
          .map((item) => jsonDecode(item) as Map<String, dynamic>)
          .toList();

      final cachedSongsData = prefs.getStringList(_cachedSongsKey) ?? [];
      final loadedSongs = <LocalSongItem>[];
      for (final jsonStr in cachedSongsData) {
        try {
          final map = jsonDecode(jsonStr) as Map<String, dynamic>;
          loadedSongs.add(LocalSongItem.fromJson(map));
        } catch (_) {}
      }

      setState(() {
        _folders = loadedFolders;
        _allSongs = loadedSongs;
        _isLoading = false; // Show cached songs immediately!
        _applySearchAndSort();
      });

      // Run non-blocking delta scan in the background
      await _smartScanFolders(
          showFullLoading: loadedSongs.isEmpty && loadedFolders.isNotEmpty);
    } catch (e) {
      debugPrint('Error loading folders: $e');
      setState(() => _isLoading = false);
    }
  }

  Future<void> _saveCachedSongs() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final strList = _allSongs.map((s) => jsonEncode(s.toJson())).toList();
      await prefs.setStringList(_cachedSongsKey, strList);
    } catch (e) {
      debugPrint('Error saving cached songs: $e');
    }
  }

  static Future<String> _computeFastFileHash(File file, int sizeBytes) async {
    if (sizeBytes <= 0) return '';
    try {
      if (!await file.exists()) return '';
      final raf = await file.open(mode: FileMode.read);
      try {
        final sampleSize = sizeBytes > 65536 ? 65536 : sizeBytes;
        final headerBytes = await raf.read(sampleSize);

        int checksum = 5381;
        for (int i = 0; i < headerBytes.length; i += 4) {
          checksum = ((checksum << 5) + checksum) ^ headerBytes[i];
        }

        if (sizeBytes > 131072) {
          await raf.setPosition(sizeBytes - 65536);
          final tailBytes = await raf.read(65536);
          for (int i = 0; i < tailBytes.length; i += 4) {
            checksum = ((checksum << 5) + checksum) ^ tailBytes[i];
          }
        }

        return '${sizeBytes}_${checksum.toRadixString(16)}';
      } finally {
        await raf.close();
      }
    } catch (_) {
      return '';
    }
  }

  Future<void> _smartScanFolders({bool showFullLoading = false}) async {
    if (_folders.isEmpty) {
      if (mounted) {
        setState(() {
          _allSongs = [];
          _filteredSongs = [];
          _isLoading = false;
          _isScanning = false;
        });
      }
      await _saveCachedSongs();
      return;
    }

    if (showFullLoading) {
      setState(() => _isLoading = true);
    } else {
      setState(() {
        _isScanning = true;
        _scanStatus = 'Checking folders for updates...';
      });
    }

    final existingSongsMap = <String, LocalSongItem>{
      for (final song in _allSongs)
        p.canonicalize(song.path).toLowerCase(): song
    };

    final updatedSongs = <LocalSongItem>[];
    final seenSongHashes = <String>{};
    bool changesDetected = false;
    int newSongsScanned = 0;

    for (final f in _folders) {
      final folderPath = f['path'] as String;
      final audioPaths = await _scanForAudioFiles(folderPath);

      if (f['count'] != audioPaths.length) {
        f['count'] = audioPaths.length;
        changesDetected = true;
      }

      for (final path in audioPaths) {
        final canonicalPath = p.canonicalize(path);
        final key = canonicalPath.toLowerCase();

        try {
          final file = File(canonicalPath);
          final stat = await file.stat();
          final existing = existingSongsMap[key];

          String? hash = existing?.fileHash;
          if (hash == null || hash.isEmpty) {
            hash = await _computeFastFileHash(file, stat.size);
          }

          final dedupeKey = hash.isNotEmpty ? hash : key;

          // Ensure each physical file content is added to updatedSongs ONLY ONCE by hash
          if (!seenSongHashes.add(dedupeKey)) {
            continue;
          }

          // Re-use cached metadata if file size and modified timestamp match
          if (existing != null &&
              existing.sizeBytes == stat.size &&
              existing.lastModified.millisecondsSinceEpoch ==
                  stat.modified.millisecondsSinceEpoch) {
            updatedSongs.add(existing.fileHash == hash
                ? existing
                : LocalSongItem.fallback(
                    existing.path,
                    existing.sizeBytes,
                    existing.lastModified,
                    title: existing.title,
                    artist: existing.artist,
                    album: existing.album,
                    genre: existing.genre,
                    fileHash: hash,
                  ));
          } else {
            changesDetected = true;
            newSongsScanned++;
            if (mounted && !showFullLoading) {
              setState(() {
                _scanStatus = 'Scanning new songs ($newSongsScanned)...';
              });
            }

            String? metaTitle;
            String? metaArtist;
            String? metaAlbum;
            String? metaGenre;
            try {
              final meta = amr.readMetadata(file, getImage: false);
              if (meta.title != null && meta.title!.isNotEmpty) {
                metaTitle = meta.title;
              }
              if (meta.artist != null && meta.artist!.isNotEmpty) {
                metaArtist = meta.artist;
              }
              if (meta.album != null && meta.album!.isNotEmpty) {
                metaAlbum = meta.album;
              }
              if (meta.genres.isNotEmpty && meta.genres.first.isNotEmpty) {
                metaGenre = meta.genres.first;
              }
            } catch (_) {}

            updatedSongs.add(LocalSongItem.fallback(
              canonicalPath,
              stat.size,
              stat.modified,
              title: metaTitle,
              artist: metaArtist,
              album: metaAlbum,
              genre: metaGenre,
              fileHash: hash,
            ));
          }
        } catch (_) {
          updatedSongs
              .add(LocalSongItem.fallback(canonicalPath, 0, DateTime.now()));
        }
      }
    }

    if (updatedSongs.length != _allSongs.length) {
      changesDetected = true;
    }

    if (mounted) {
      setState(() {
        _allSongs = updatedSongs;
        _isLoading = false;
        _isScanning = false;
        _applySearchAndSort();
      });
    }

    if (changesDetected) {
      await _saveFolders();
      await _saveCachedSongs();
    }
  }

  Future<void> _updateAllSongs() async {
    await _smartScanFolders(showFullLoading: false);
  }

  void _applySearchAndSort() {
    var list = _allSongs.toList();
    final query = _searchController.text.toLowerCase();

    if (query.isNotEmpty) {
      list = list.where((s) => s.title.toLowerCase().contains(query)).toList();
    }

    switch (_currentSort) {
      case 'Name (A-Z)':
        list.sort((a, b) => a.title.compareTo(b.title));
        break;
      case 'Name (Z-A)':
        list.sort((a, b) => b.title.compareTo(a.title));
        break;
      case 'Date Added (New-Old)':
        list.sort((a, b) => b.lastModified.compareTo(a.lastModified));
        break;
      case 'Date Added (Old-New)':
        list.sort((a, b) => a.lastModified.compareTo(b.lastModified));
        break;
      case 'Size (Largest)':
        list.sort((a, b) => b.sizeBytes.compareTo(a.sizeBytes));
        break;
      case 'Size (Smallest)':
        list.sort((a, b) => a.sizeBytes.compareTo(b.sizeBytes));
        break;
      case 'File Extension (A-Z)':
        list.sort((a, b) => p
            .extension(a.path)
            .toLowerCase()
            .compareTo(p.extension(b.path).toLowerCase()));
        break;
      case 'File Extension (Z-A)':
        list.sort((a, b) => p
            .extension(b.path)
            .toLowerCase()
            .compareTo(p.extension(a.path).toLowerCase()));
        break;
    }

    setState(() {
      _filteredSongs = list;
    });
  }

  Future<void> _saveFolders() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final strList = _folders.map((f) => jsonEncode(f)).toList();
      await prefs.setStringList(_prefsKey, strList);
    } catch (e) {
      debugPrint('Error saving folders: $e');
    }
  }

  Future<bool> _requestPermissions() async {
    if (Platform.isAndroid) {
      if (await Permission.manageExternalStorage.isGranted) {
        return true;
      }
      var status = await Permission.storage.status;
      if (!status.isGranted) {
        status = await Permission.storage.request();
      }
      var audioStatus = await Permission.audio.status;
      if (!audioStatus.isGranted) {
        audioStatus = await Permission.audio.request();
      }
      return status.isGranted || audioStatus.isGranted;
    }
    return true; // Assume iOS/Desktop permissions are handled at pick time
  }

  Future<List<String>> _scanForAudioFiles(String dirPath) async {
    final audioFiles = <String>[];
    final seenPaths = <String>{};
    final rootDir = Directory(dirPath);
    if (!await rootDir.exists()) return audioFiles;

    const allowedExtensions = {
      '.mp3',
      '.m4a',
      '.wav',
      '.flac',
      '.aac',
      '.ogg',
      '.opus',
      '.wma',
      '.alac',
      '.aiff',
      '.aif',
      '.ape',
      '.wv',
      '.m4b',
      '.m4p',
    };

    final dirsToScan = <Directory>[rootDir];
    final visitedDirs = <String>{};

    while (dirsToScan.isNotEmpty) {
      final currentDir = dirsToScan.removeLast();
      final canonicalDirPath = p.canonicalize(currentDir.path).toLowerCase();
      if (!visitedDirs.add(canonicalDirPath)) {
        continue;
      }

      try {
        await for (final entity
            in currentDir.list(followLinks: false).handleError((e) {
          debugPrint('Error listing entry in ${currentDir.path}: $e');
        })) {
          try {
            if (entity is Directory) {
              final dirName = p.basename(entity.path);
              // Skip hidden directories (e.g. .git, .thumbnails, .trashed, .cache)
              if (!dirName.startsWith('.')) {
                dirsToScan.add(entity);
              }
            } else if (entity is File) {
              final ext = p.extension(entity.path).toLowerCase();
              if (allowedExtensions.contains(ext)) {
                final canonicalPath = p.canonicalize(entity.path);
                if (seenPaths.add(canonicalPath.toLowerCase())) {
                  audioFiles.add(canonicalPath);
                }
              }
            }
          } catch (e) {
            debugPrint('Error processing entity ${entity.path}: $e');
          }
        }
      } catch (e) {
        debugPrint('Error accessing directory ${currentDir.path}: $e');
      }
    }

    return audioFiles;
  }

  void _navigateToNetworkSources() {
    if (widget.player == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Player engine unavailable.')),
      );
      return;
    }
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (context) => NetworkSourcesScreen(
          player: widget.player!,
          onPlayNetworkFile: widget.onPlayNetworkFile,
          onPlayFtpFolder: widget.onPlayFtpFolder,
        ),
      ),
    );
  }

  Future<void> _rescanLibrary() async {
    if (_isScanning || _isLoading) return;
    if (_folders.isEmpty) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text(
                'No folders tracked. Add a local folder first to scan songs.'),
          ),
        );
      }
      return;
    }

    final prevCount = _allSongs.length;
    await _smartScanFolders(showFullLoading: false);

    if (mounted) {
      final newCount = _allSongs.length;
      final diff = newCount - prevCount;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            diff > 0
                ? 'Scan complete: Added $diff new track(s) ($newCount total).'
                : 'Scan complete: Library is up to date ($newCount tracks).',
          ),
          duration: const Duration(seconds: 2),
        ),
      );
    }
  }

  Future<void> _addDirectory() async {
    final hasPerm = await _requestPermissions();
    if (!hasPerm) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
            content: Text('Storage permissions are required to add folders.')),
      );
      return;
    }

    String? selectedDirectory;
    if (Platform.isWindows || Platform.isLinux || Platform.isMacOS) {
      selectedDirectory = await getDirectoryPath();
    } else {
      selectedDirectory = await FilePicker.getDirectoryPath();
    }
    if (selectedDirectory == null) return;

    final canonicalSelected = p.canonicalize(selectedDirectory);

    // 1. Check if selectedDirectory is inside/subfolder of an existing tracked folder
    bool isAlreadyCovered = false;
    for (final f in _folders) {
      final existingPath = p.canonicalize(f['path'] as String);
      if (canonicalSelected == existingPath ||
          p.isWithin(existingPath, canonicalSelected)) {
        isAlreadyCovered = true;
        break;
      }
    }

    if (isAlreadyCovered) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Folder (or its parent) is already in your library.'),
        ),
      );
      return;
    }

    // 2. Check if selectedDirectory is a parent of any existing tracked folder(s)
    final remainingFolders = <Map<String, dynamic>>[];
    int subsumedCount = 0;
    for (final f in _folders) {
      final existingPath = p.canonicalize(f['path'] as String);
      if (p.isWithin(canonicalSelected, existingPath)) {
        subsumedCount++;
      } else {
        remainingFolders.add(f);
      }
    }

    setState(() => _isLoading = true);

    final audioPaths = await _scanForAudioFiles(canonicalSelected);

    final newFolder = {
      'path': canonicalSelected,
      'name': p.basename(canonicalSelected),
      'count': audioPaths.length,
    };

    setState(() {
      _folders = remainingFolders..add(newFolder);
    });

    await _saveFolders();
    await _updateAllSongs();

    if (mounted && subsumedCount > 0) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            'Added folder and merged $subsumedCount subfolder(s) into parent library entry.',
          ),
        ),
      );
    }
  }

  Future<void> _removeFolder(int index) async {
    final folderName = _folders[index]['name'] as String;
    final confirm = await M3EDialog.show<bool>(
      context,
      dialog: M3EDialog(
        title: 'Remove Folder?',
        topDivider: true,
        bottomDivider: true,
        content: Text(
          'Remove "$folderName" from your library? Audio files on disk will not be deleted.',
          style: TextStyle(
              color: AppThemeService.instance.currentData.textDark,
              fontSize: 14),
        ),
        actions: [
          M3EButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          M3EButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Remove Folder'),
          ),
        ],
      ),
    );

    if (confirm != true) return;
    setState(() {
      _folders.removeAt(index);
    });
    await _saveFolders();
    await _updateAllSongs();
  }

  Future<void> _removeDuplicateSongs() async {
    if (_allSongs.isEmpty && _folders.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Library is empty.')),
      );
      return;
    }

    final uniqueSongs = <LocalSongItem>[];
    final seenKeys = <String>{};
    int removedSongsCount = 0;

    for (final song in _allSongs) {
      final canonicalPath = p.canonicalize(song.path).toLowerCase();
      final key = (song.fileHash != null && song.fileHash!.isNotEmpty)
          ? song.fileHash!
          : (canonicalPath.isNotEmpty
              ? canonicalPath
              : '${song.title.toLowerCase()}_${song.artist.toLowerCase()}_${song.sizeBytes}');

      if (seenKeys.add(key)) {
        uniqueSongs.add(song);
      } else {
        removedSongsCount++;
      }
    }

    // Deduplicate folder hierarchy in _folders
    final uniqueFolders = <Map<String, dynamic>>[];
    for (final f in _folders) {
      final folderPath = p.canonicalize(f['path'] as String);
      final isSubsumed = uniqueFolders.any((uf) {
        final ufPath = p.canonicalize(uf['path'] as String);
        return folderPath == ufPath || p.isWithin(ufPath, folderPath);
      });
      if (!isSubsumed) {
        uniqueFolders.removeWhere((uf) {
          final ufPath = p.canonicalize(uf['path'] as String);
          return p.isWithin(folderPath, ufPath);
        });
        uniqueFolders.add(f);
      }
    }

    final bool foldersChanged = uniqueFolders.length != _folders.length;

    setState(() {
      _allSongs = uniqueSongs;
      _folders = uniqueFolders;
      _applySearchAndSort();
    });

    await _saveCachedSongs();
    if (foldersChanged) {
      await _saveFolders();
    }

    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            (removedSongsCount > 0 || foldersChanged)
                ? 'Removed $removedSongsCount duplicate track(s) and cleaned folder structure.'
                : 'No duplicate songs found in your library.',
          ),
          duration: const Duration(seconds: 3),
        ),
      );
    }
  }

  Future<void> _playFolder(String dirPath) async {
    setState(() => _isLoading = true);
    final audioPaths = await _scanForAudioFiles(dirPath);
    setState(() => _isLoading = false);

    if (audioPaths.isEmpty) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('No audio files found in this folder.')),
      );
      return;
    }

    final uniquePaths = <String>[];
    final seen = <String>{};
    for (final path in audioPaths) {
      final key = p.canonicalize(path).toLowerCase();
      if (seen.add(key)) {
        uniquePaths.add(path);
      }
    }

    // Hand off to main player
    widget.onPlayFolder(uniquePaths);
  }

  Future<void> _shufflePlayAll() async {
    if (_allSongs.isEmpty) return;

    final paths = _allSongs.map((e) => e.path).toList();
    paths.shuffle();
    widget.onPlayFolder(paths);
  }

  Future<void> _handleSongOption(LocalSongItem song, SongOption option) async {
    switch (option) {
      case SongOption.queue:
        _queueSong(song);
        break;
      case SongOption.addToPlaylist:
        await _showAddToPlaylistSheet(explicitSongs: [song]);
        break;
      case SongOption.info:
        await _showSongInfo(song);
        break;
      case SongOption.share:
        await _shareSong(song);
        break;
      case SongOption.delete:
        await _confirmAndDeleteSong(song);
        break;
    }
  }

  void _queueSong(LocalSongItem song) {
    final track = TrackInfo(
      videoId: song.path,
      title: song.title,
      artist: song.artist != 'Unknown Artist' ? song.artist : 'Local File',
      thumbnailUrl: null,
    );
    if (widget.onQueueTrack != null) {
      widget.onQueueTrack!(track);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Added "${song.title}" to Queue (Play Next)'),
          duration: const Duration(seconds: 2),
        ),
      );
    } else {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Player queue control unavailable.')),
      );
    }
  }

  Future<void> _showSongInfo(LocalSongItem song) async {
    final file = File(song.path);
    String artist = song.artist;
    String title = song.title;
    String album = 'Unknown Album';
    String genre = 'Unknown Genre';
    String year = '';
    String trackNumber = '';
    Uint8List? albumArt;
    Duration duration = Duration.zero;

    final fileInfo = await AudioFileInspector.inspect(song.path);

    try {
      if (file.existsSync()) {
        final meta = amr.readMetadata(file, getImage: true);
        if (meta.title != null && meta.title!.isNotEmpty) title = meta.title!;
        if (meta.artist != null && meta.artist!.isNotEmpty) {
          artist = meta.artist!;
        }
        if (meta.album != null && meta.album!.isNotEmpty) album = meta.album!;
        if (meta.genres.isNotEmpty && meta.genres.first.isNotEmpty) {
          genre = meta.genres.first;
        }
        if (meta.year != null) year = meta.year.toString();
        if (meta.trackNumber != null) trackNumber = meta.trackNumber.toString();
        if (meta.pictures.isNotEmpty) albumArt = meta.pictures.first.bytes;
        if (meta.duration != null) duration = meta.duration!;
      }
    } catch (_) {}

    if (!mounted) return;

    await MusicInfoDialog.show(
      context,
      title: title,
      artist: artist,
      album: album,
      genre: genre,
      year: year,
      trackNumber: trackNumber,
      albumArt: albumArt,
      sourceType: 'local',
      videoId: song.path,
      codec: fileInfo.codec,
      sampleRate: fileInfo.formattedSampleRate,
      channels: fileInfo.formattedChannels,
      bitDepth: fileInfo.formattedBitDepth,
      fileSizeBytes: song.sizeBytes,
      duration: duration,
      onSaveTags: ({
        required String title,
        required String artist,
        required String album,
        required String genre,
        required String year,
        required String trackNumber,
      }) async {
        setState(() {
          final targetIndex = _allSongs.indexWhere((s) => s.path == song.path);
          if (targetIndex != -1) {
            _allSongs[targetIndex] = LocalSongItem.fallback(
              song.path,
              song.sizeBytes,
              song.lastModified,
              title: title.isNotEmpty ? title : song.title,
              artist: artist.isNotEmpty ? artist : song.artist,
              album: album.isNotEmpty ? album : song.album,
              genre: genre.isNotEmpty ? genre : song.genre,
              fileHash: song.fileHash,
            );
          }
          _applySearchAndSort();
        });
        await _saveCachedSongs();
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
                content: Text(
                    'Saved tags for "${title.isNotEmpty ? title : song.title}"')),
          );
        }
      },
    );
  }

  Future<void> _shareSong(LocalSongItem song) async {
    final file = File(song.path);
    if (!file.existsSync()) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Audio file does not exist on disk.')),
      );
      return;
    }
    try {
      final xfile = XFile(song.path);
      await Share.shareXFiles([xfile], text: song.title);
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Could not share file: $e')),
      );
    }
  }

  Future<void> _confirmAndDeleteSong(LocalSongItem song) async {
    final confirm = await M3EDialog.show<bool>(
      context,
      dialog: M3EDialog(
        title: 'Delete Song File',
        topDivider: true,
        bottomDivider: true,
        content: Text(
          'Are you sure you want to delete "${song.title}"? The file will be permanently removed from storage.',
          style: TextStyle(
              color: AppThemeService.instance.currentData.textDark,
              fontSize: 14),
        ),
        actions: [
          M3EButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          M3EButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Delete Permanently'),
          ),
        ],
      ),
    );

    if (confirm != true) return;

    final result = await FileDeletionHelper.safeDeleteTrackFile(
      song.path,
      context: context,
      player: widget.player,
      onBeforeDelete: (path) async {
        if (widget.onDeleteTrack != null) {
          await widget.onDeleteTrack!(path);
        }
      },
    );

    if (!mounted) return;

    if (result.success) {
      setState(() {
        _allSongs.removeWhere((s) => s.path == song.path);
        _filteredSongs.removeWhere((s) => s.path == song.path);
      });
      await _saveCachedSongs();

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Deleted "${song.title}" permanently.'),
          duration: const Duration(seconds: 2),
        ),
      );
    } else {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(result.errorMessage ?? 'Failed to delete track.'),
          backgroundColor: Colors.redAccent.shade700,
          duration: const Duration(seconds: 4),
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    // Theme colors
    final Color primaryColor = context.primaryColor;
    final Color bgDark = context.bgDark;
    final Color surfaceColor = context.cardDark;
    final Color textLight = context.textPrimary;
    final Color textDark = context.textMuted;

    return LayoutBuilder(
      builder: (context, constraints) {
        final isDesktop = constraints.maxWidth >= 800;
        final contentMaxWidth = isDesktop ? 1000.0 : double.infinity;

        final horizontalPadding = isDesktop ? 32.0 : 16.0;

        return Scaffold(
          backgroundColor: bgDark,
          body: SafeArea(
            bottom: false,
            child: Align(
              alignment: Alignment.topCenter,
              child: ConstrainedBox(
                constraints: BoxConstraints(maxWidth: contentMaxWidth),
                child: Stack(
                  children: [
                    RefreshIndicator(
                      color: primaryColor,
                      backgroundColor: surfaceColor,
                      onRefresh: _rescanLibrary,
                      child: Scrollbar(
                        controller: _scrollController,
                        thumbVisibility: true,
                        interactive: true,
                        thickness: 6.0,
                        radius: const Radius.circular(8),
                        child: CustomScrollView(
                          controller: _scrollController,
                          cacheExtent: 140.0,
                          physics: const BouncingScrollPhysics(
                              parent: AlwaysScrollableScrollPhysics()),
                          slivers: [
                          // Top breathing space
                          const SliverToBoxAdapter(child: SizedBox(height: 12)),

                          // 1. App Bar Row + Total local track count (Scrolls away)
                          PinnedHeaderSliver(
                            child: Container(
                              color: bgDark,
                              padding: EdgeInsets.symmetric(
                                  horizontal: horizontalPadding),
                              child: Padding(
                                padding: EdgeInsets.fromLTRB(
                                  horizontalPadding,
                                  widget.isNested
                                      ? 4.0
                                      : (isDesktop ? 14.0 : 4.0),
                                  horizontalPadding,
                                  4.0,
                                ),
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Row(
                                      mainAxisAlignment:
                                          MainAxisAlignment.spaceBetween,
                                      crossAxisAlignment:
                                          CrossAxisAlignment.center,
                                      children: [
                                        if (!widget.isNested)
                                          Text(
                                            'Library',
                                            style: TextStyle(
                                              fontSize: isDesktop ? 30 : 24,
                                              fontWeight: FontWeight.bold,
                                              color: textLight,
                                              letterSpacing: -0.5,
                                            ),
                                          )
                                        else
                                          const SizedBox.shrink(),
                                        M3EMenu(
                                          anchorBuilder: (context, open) =>
                                              M3EIconButton(
                                            icon: Icon(Icons.add_rounded,
                                                size: isDesktop ? 22 : 20),
                                            variant:
                                                M3EIconButtonVariant.filled,
                                            onPressed: open,
                                          ),
                                          children: [
                                            M3EMenuGroup.entries(
                                              entries: [
                                                M3EMenuEntry(
                                                  label: 'Rescan for New Songs',
                                                  leading: const Icon(
                                                      Icons.sync_rounded,
                                                      color: Colors
                                                          .lightGreenAccent,
                                                      size: 20),
                                                  onPressed: _rescanLibrary,
                                                ),
                                                M3EMenuEntry(
                                                  label: 'Add Local Folder',
                                                  leading: const Icon(
                                                      Icons
                                                          .create_new_folder_rounded,
                                                      color: Colors.blueAccent,
                                                      size: 20),
                                                  onPressed: _addDirectory,
                                                ),
                                                M3EMenuEntry(
                                                  label:
                                                      'Import M3U / M3U8 File',
                                                  leading: const Icon(
                                                      Icons
                                                          .playlist_add_rounded,
                                                      color: Colors.cyanAccent,
                                                      size: 20),
                                                  onPressed: _importM3uFile,
                                                ),
                                                M3EMenuEntry(
                                                  label:
                                                      'Import M3U Stream URL',
                                                  leading: const Icon(
                                                      Icons.podcasts_rounded,
                                                      color: Colors.tealAccent,
                                                      size: 20),
                                                  onPressed:
                                                      _importM3uUrlDialog,
                                                ),
                                                M3EMenuEntry(
                                                  label:
                                                      'Network Stream (FTP & DLNA)',
                                                  leading: const Icon(
                                                      Icons.lan_rounded,
                                                      color: Colors
                                                          .lightBlueAccent,
                                                      size: 20),
                                                  onPressed:
                                                      _navigateToNetworkSources,
                                                ),
                                                M3EMenuEntry(
                                                  label: 'Clean Up Duplicates',
                                                  leading: const Icon(
                                                      Icons
                                                          .cleaning_services_rounded,
                                                      color:
                                                          Colors.orangeAccent,
                                                      size: 20),
                                                  onPressed:
                                                      _removeDuplicateSongs,
                                                ),
                                                M3EMenuEntry(
                                                  label:
                                                      'Export Library to M3U8',
                                                  leading: const Icon(
                                                      Icons.file_upload_rounded,
                                                      color: Colors.amberAccent,
                                                      size: 20),
                                                  onPressed: () =>
                                                      _exportPlaylistToM3u8(
                                                          'SautiPlay_Library',
                                                          _allSongs),
                                                ),
                                              ],
                                            ),
                                          ],
                                        ),
                                      ],
                                    ),
                                    const SizedBox(height: 2),

                                    // Total local track count
                                    Text(
                                      '${_allSongs.length} local tracks',
                                      style: TextStyle(
                                        color: textDark,
                                        fontSize: isDesktop ? 13.5 : 12.5,
                                        fontWeight: FontWeight.w500,
                                        letterSpacing: 0.1,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ),
                          ),

                          // 2. PINNED Search Bar + M3E Chips
                          PinnedHeaderSliver(
                            child: Container(
                              color: bgDark,
                              padding: EdgeInsets.symmetric(
                                  horizontal: horizontalPadding),
                              child: Column(
                                mainAxisSize: MainAxisSize.min,
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  const SizedBox(height: 6),
                                  // Search Bar
                                  SizedBox(
                                    height: isDesktop ? 48 : 42,
                                    child: TextField(
                                      controller: _searchController,
                                      style: TextStyle(
                                          color: textLight,
                                          fontSize: isDesktop ? 15 : 14),
                                      decoration: InputDecoration(
                                        hintText: 'Search library...',
                                        hintStyle: TextStyle(
                                            color: textDark,
                                            fontSize: isDesktop ? 15 : 14),
                                        prefixIcon: Icon(Icons.search_rounded,
                                            color: textDark,
                                            size: isDesktop ? 22 : 20),
                                        suffixIcon: _searchController
                                                .text.isNotEmpty
                                            ? IconButton(
                                                icon: Icon(Icons.clear_rounded,
                                                    color: textDark, size: 18),
                                                onPressed: () {
                                                  _searchController.clear();
                                                  _applySearchAndSort();
                                                },
                                              )
                                            : null,
                                        filled: true,
                                        fillColor: surfaceColor,
                                        border: OutlineInputBorder(
                                          borderRadius: BorderRadius.circular(
                                              isDesktop ? 14 : 12),
                                          borderSide: BorderSide.none,
                                        ),
                                        contentPadding:
                                            const EdgeInsets.symmetric(
                                                vertical: 0, horizontal: 12),
                                      ),
                                      onChanged: (v) => _applySearchAndSort(),
                                    ),
                                  ),
                                  const SizedBox(height: 8),

                                  // M3E Chips
                                  SizedBox(
                                    height: isDesktop ? 42 : 36,
                                    child: SingleChildScrollView(
                                      scrollDirection: Axis.horizontal,
                                      physics: const BouncingScrollPhysics(),
                                      child: Row(
                                        children:
                                            LibraryCategory.values.map((cat) {
                                          final isSelected =
                                              _selectedCategory == cat;
                                          return Padding(
                                            padding: const EdgeInsets.only(
                                                right: 8.0),
                                            child: M3EChip(
                                              label: cat.label,
                                              type: M3EChipType.filter,
                                              selected: isSelected,
                                              leading: Icon(cat.icon, size: 16),
                                              onPressed: () {
                                                setState(() {
                                                  _selectedCategory = cat;
                                                });
                                              },
                                            ),
                                          );
                                        }).toList(),
                                      ),
                                    ),
                                  ),
                                  const SizedBox(height: 8),
                                ],
                              ),
                            ),
                          ),

                          // 3. Scanning status indicator (if scanning)
                          if (_isScanning)
                            SliverToBoxAdapter(
                              child: Padding(
                                padding: EdgeInsets.symmetric(
                                    horizontal: horizontalPadding, vertical: 6),
                                child: Container(
                                  padding: const EdgeInsets.symmetric(
                                      horizontal: 12, vertical: 6),
                                  decoration: BoxDecoration(
                                    color: surfaceColor,
                                    borderRadius: BorderRadius.circular(20),
                                    border: Border.all(
                                        color: primaryColor.withValues(
                                            alpha: 0.3)),
                                  ),
                                  child: Row(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      SizedBox(
                                        width: 18,
                                        height: 18,
                                        child:
                                            M3EProgressIndicator.circularWavy(
                                          color: primaryColor,
                                          trackColor: primaryColor.withValues(
                                              alpha: 0.15),
                                        ),
                                      ),
                                      const SizedBox(width: 8),
                                      Text(
                                        _scanStatus,
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                        style: TextStyle(
                                          color: textDark,
                                          fontSize: 12,
                                          fontWeight: FontWeight.w500,
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                              ),
                            ),

                          // 4. QUICK ACCESS Section (Scrolls away)
                          SliverToBoxAdapter(
                            child: Padding(
                              padding: EdgeInsets.symmetric(
                                  horizontal: horizontalPadding),
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  const SizedBox(height: 8),
                                  Text(
                                    'QUICK ACCESS',
                                    style: TextStyle(
                                      color: textDark,
                                      fontSize: 11,
                                      fontWeight: FontWeight.w700,
                                      letterSpacing: 1.2,
                                    ),
                                  ),
                                  const SizedBox(height: 8),
                                  SizedBox(
                                    height: isDesktop ? 116 : 96,
                                    child: M3ECarousel(
                                      type: M3ECarouselType.hero,
                                      heroAlignment:
                                          M3ECarouselHeroAlignment.left,
                                      isExtended: isDesktop,
                                      childElementBorderRadius: 16,
                                      onTap: (i) => _handleQuickAccessTap(i),
                                      children: [
                                        _buildLikedSongsHeroCard(
                                            isDesktop: isDesktop),
                                        _buildCachedStreamsHeroCard(
                                            isDesktop: isDesktop),
                                        _buildPlaylistsHeroCard(
                                            isDesktop: isDesktop),
                                        _buildNetworkStreamsHeroCard(
                                            isDesktop: isDesktop),
                                        _buildShuffleAllHeroCard(primaryColor,
                                            isDesktop: isDesktop),
                                      ],
                                    ),
                                  ),
                                  const SizedBox(height: 10),
                                ],
                              ),
                            ),
                          ),

                          // 5. Category Header / Sort row (or selection action bar)
                          SliverToBoxAdapter(
                            child: Padding(
                              padding: EdgeInsets.symmetric(
                                  horizontal: horizontalPadding),
                              child: _isSelectionMode
                                  ? _buildSelectionActionBar(primaryColor,
                                      isDesktop: isDesktop)
                                  : _buildCategoryHeaderRow(
                                      primaryColor, textDark,
                                      isDesktop: isDesktop),
                            ),
                          ),

                          // 6. Active Category Content Sliver
                          _buildSelectedSliverContent(primaryColor, textDark,
                              isDesktop: isDesktop),

                          // 7. Bottom spacing so content is never hidden behind mini player
                          const SliverToBoxAdapter(
                            child: SizedBox(height: 140),
                          ),
                        ],
                      ),
                      ),
                    ),
                    if (_isLoading)
                      Container(
                        color: bgDark.withValues(alpha: 0.5),
                        child: Center(
                          child: M3EProgressIndicator.circularWavy(
                              color: primaryColor,
                              trackColor: primaryColor.withValues(alpha: 0.15)),
                        ),
                      ),
                    // Floating Scroll Helper Dock (M3E style)
                    Positioned(
                      bottom: 85,
                      right: isDesktop ? 36 : 16,
                      child: AnimatedSlide(
                        duration: const Duration(milliseconds: 260),
                        curve: Curves.easeOutCubic,
                        offset: _showScrollHelper
                            ? Offset.zero
                            : const Offset(0, 1.8),
                        child: AnimatedOpacity(
                          duration: const Duration(milliseconds: 220),
                          curve: Curves.easeInOut,
                          opacity: _showScrollHelper ? 1.0 : 0.0,
                          child: IgnorePointer(
                            ignoring: !_showScrollHelper,
                            child: Builder(
                              builder: (context) {
                                final playingIdx = _currentlyPlayingPath != null
                                    ? _filteredSongs.indexWhere((s) =>
                                        s.path == _currentlyPlayingPath)
                                    : -1;

                                return Material(
                                  elevation: 6,
                                  shadowColor:
                                      Colors.black.withValues(alpha: 0.45),
                                  color: primaryColor,
                                  borderRadius: BorderRadius.circular(24),
                                  child: Row(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      InkWell(
                                        borderRadius: BorderRadius.horizontal(
                                          left: const Radius.circular(24),
                                          right: Radius.circular(
                                              playingIdx >= 0 ? 0 : 24),
                                        ),
                                        onTap: () {
                                          _scrollController.animateTo(
                                            0,
                                            duration: const Duration(
                                                milliseconds: 350),
                                            curve: Curves.easeOutCubic,
                                          );
                                        },
                                        child: Padding(
                                          padding: const EdgeInsets.symmetric(
                                            horizontal: 14,
                                            vertical: 9,
                                          ),
                                          child: Row(
                                            mainAxisSize: MainAxisSize.min,
                                            children: [
                                              Icon(
                                                Icons.arrow_upward_rounded,
                                                size: 16,
                                                color: Theme.of(context)
                                                    .colorScheme
                                                    .onPrimary,
                                              ),
                                              const SizedBox(width: 5),
                                              Text(
                                                'Top',
                                                style: TextStyle(
                                                  color: Theme.of(context)
                                                      .colorScheme
                                                      .onPrimary,
                                                  fontSize: 12.5,
                                                  fontWeight: FontWeight.bold,
                                                ),
                                              ),
                                            ],
                                          ),
                                        ),
                                      ),
                                      if (playingIdx >= 0) ...[
                                        Container(
                                          width: 1,
                                          height: 16,
                                          color: Theme.of(context)
                                              .colorScheme
                                              .onPrimary
                                              .withValues(alpha: 0.25),
                                        ),
                                        InkWell(
                                          borderRadius:
                                              const BorderRadius.horizontal(
                                            right: Radius.circular(24),
                                          ),
                                          onTap: _scrollToPlayingTrack,
                                          child: Padding(
                                            padding: const EdgeInsets.symmetric(
                                              horizontal: 13,
                                              vertical: 9,
                                            ),
                                            child: Row(
                                              mainAxisSize: MainAxisSize.min,
                                              children: [
                                                Icon(
                                                  Icons.my_location_rounded,
                                                  size: 16,
                                                  color: Theme.of(context)
                                                      .colorScheme
                                                      .onPrimary,
                                                ),
                                                const SizedBox(width: 6),
                                                Text(
                                                  'Playing #${playingIdx + 1}',
                                                  style: TextStyle(
                                                    color: Theme.of(context)
                                                        .colorScheme
                                                        .onPrimary,
                                                    fontSize: 12.5,
                                                    fontWeight: FontWeight.bold,
                                                  ),
                                                ),
                                              ],
                                            ),
                                          ),
                                        ),
                                      ],
                                    ],
                                  ),
                                );
                              },
                            ),
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );
  }

  void _handleQuickAccessTap(int index) {
    switch (index) {
      case 0:
        Navigator.of(context).push(
          MaterialPageRoute(
            builder: (_) => LikedSongsScreen(
              onPlayTracks: widget.onPlayLikedSongs,
            ),
          ),
        );
        break;
      case 1:
        Navigator.of(context).push(
          MaterialPageRoute(
            builder: (_) => CachedStreamsScreen(
              onPlayTracks: widget.onPlayCachedStreams ??
                  (tracks, {initialIndex = 0}) async {},
              onQueueTrack: widget.onQueueTrack,
            ),
          ),
        );
        break;
      case 2:
        setState(() => _selectedCategory = LibraryCategory.playlists);
        break;
      case 3:
        _navigateToNetworkSources();
        break;
      case 4:
        _shufflePlayAll();
        break;
    }
  }

  Widget _buildQuickAccessHeroCard({
    required String title,
    required String subtitle,
    required IconData icon,
    required Gradient gradient,
    required VoidCallback onTap,
    bool isDesktop = false,
  }) {
    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: Container(
        padding: EdgeInsets.symmetric(
          horizontal: isDesktop ? 18 : 14,
          vertical: isDesktop ? 14 : 10,
        ),
        decoration: BoxDecoration(
          gradient: gradient,
          borderRadius: BorderRadius.circular(16),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.25),
              blurRadius: 8,
              offset: const Offset(0, 3),
            ),
          ],
        ),
        child: Row(
          children: [
            Container(
              width: isDesktop ? 46 : 40,
              height: isDesktop ? 46 : 40,
              decoration: BoxDecoration(
                color: Colors.white.withValues(alpha: 0.18),
                shape: BoxShape.circle,
              ),
              child: Icon(icon, color: Colors.white, size: isDesktop ? 24 : 22),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: isDesktop ? 16 : 14,
                      fontWeight: FontWeight.bold,
                      letterSpacing: -0.2,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    subtitle,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: Colors.white.withValues(alpha: 0.8),
                      fontSize: isDesktop ? 12 : 11,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 8),
            Container(
              padding: const EdgeInsets.all(6),
              decoration: BoxDecoration(
                color: Colors.black.withValues(alpha: 0.2),
                shape: BoxShape.circle,
              ),
              child: const Icon(
                Icons.arrow_forward_ios_rounded,
                size: 11,
                color: Colors.white70,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildLikedSongsHeroCard({bool isDesktop = false}) {
    return _buildQuickAccessHeroCard(
      title: 'Liked Songs',
      subtitle: 'Favorites',
      icon: Icons.favorite_rounded,
      gradient: const LinearGradient(
        colors: [Color(0xFF4527A0), Color(0xFF6A1B9A)],
        begin: Alignment.topLeft,
        end: Alignment.bottomRight,
      ),
      onTap: () {
        Navigator.of(context).push(
          MaterialPageRoute(
            builder: (_) => LikedSongsScreen(
              onPlayTracks: widget.onPlayLikedSongs,
            ),
          ),
        );
      },
      isDesktop: isDesktop,
    );
  }

  Widget _buildCachedStreamsHeroCard({bool isDesktop = false}) {
    return ValueListenableBuilder<List<CachedStreamItem>>(
      valueListenable: CachedStreamService.instance.cachedStreamsNotifier,
      builder: (context, cached, _) {
        return ValueListenableBuilder<int>(
          valueListenable: CachedStreamService.instance.totalSizeBytesNotifier,
          builder: (context, totalBytes, _) {
            return _buildQuickAccessHeroCard(
              title: 'Cached Streams',
              subtitle:
                  '${cached.length} Tracks • ${CachedStreamService.formatBytes(totalBytes)}',
              icon: Icons.cloud_done_rounded,
              gradient: const LinearGradient(
                colors: [Color(0xFF00796B), Color(0xFF004D40)],
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
              ),
              onTap: () {
                Navigator.of(context).push(
                  MaterialPageRoute(
                    builder: (_) => CachedStreamsScreen(
                      onPlayTracks: widget.onPlayCachedStreams ??
                          (tracks, {initialIndex = 0}) async {},
                      onQueueTrack: widget.onQueueTrack,
                    ),
                  ),
                );
              },
              isDesktop: isDesktop,
            );
          },
        );
      },
    );
  }

  Widget _buildPlaylistsHeroCard({bool isDesktop = false}) {
    return _buildQuickAccessHeroCard(
      title: 'Playlists',
      subtitle: '${_m3uPlaylists.length} M3U Playlists',
      icon: Icons.queue_music_rounded,
      gradient: const LinearGradient(
        colors: [Color(0xFF1A237E), Color(0xFF283593)],
        begin: Alignment.topLeft,
        end: Alignment.bottomRight,
      ),
      onTap: () {
        setState(() => _selectedCategory = LibraryCategory.playlists);
      },
      isDesktop: isDesktop,
    );
  }

  Widget _buildNetworkStreamsHeroCard({bool isDesktop = false}) {
    return _buildQuickAccessHeroCard(
      title: 'Network Stream',
      subtitle: 'FTP Remote & DLNA',
      icon: Icons.lan_rounded,
      gradient: const LinearGradient(
        colors: [Color(0xFF00695C), Color(0xFF004D40)],
        begin: Alignment.topLeft,
        end: Alignment.bottomRight,
      ),
      onTap: _navigateToNetworkSources,
      isDesktop: isDesktop,
    );
  }

  Widget _buildShuffleAllHeroCard(Color primaryColor,
      {bool isDesktop = false}) {
    return _buildQuickAccessHeroCard(
      title: 'Shuffle All',
      subtitle: '${_allSongs.length} Local Tracks',
      icon: Icons.shuffle_rounded,
      gradient: LinearGradient(
        colors: [primaryColor, const Color(0xFF0288D1)],
        begin: Alignment.topLeft,
        end: Alignment.bottomRight,
      ),
      onTap: _shufflePlayAll,
      isDesktop: isDesktop,
    );
  }

  Widget _buildCategoryHeaderRow(Color primaryColor, Color textDark,
      {bool isDesktop = false}) {
    return Row(
      children: [
        // Category / Song Title on the leading edge
        Text(
          _categorySectionTitle,
          style: TextStyle(
            color: _textPrimary,
            fontSize: isDesktop ? 18 : 15,
            fontWeight: FontWeight.bold,
            letterSpacing: -0.3,
          ),
        ),
        const Spacer(),
        // Dropdown for sorting on the other end of the row
        M3EMenu(
          anchorBuilder: (context, open) => InkWell(
            onTap: open,
            borderRadius: BorderRadius.circular(10),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
              decoration: BoxDecoration(
                color: _surfaceDark,
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: _outline.withValues(alpha: 0.2)),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.sort_rounded, size: 16, color: primaryColor),
                  const SizedBox(width: 5),
                  ConstrainedBox(
                    constraints:
                        BoxConstraints(maxWidth: isDesktop ? 160 : 115),
                    child: Text(
                      _currentSort,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: _textPrimary,
                        fontSize: isDesktop ? 13 : 11.5,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                  const SizedBox(width: 2),
                  Icon(Icons.arrow_drop_down_rounded,
                      size: 16, color: textDark),
                ],
              ),
            ),
          ),
          children: [
            M3EMenuGroup.entries(
              label: 'Sort Tracks',
              entries: _sortOptions.map((choice) {
                final isSelected = _currentSort == choice;
                return M3EMenuEntry(
                  label: choice,
                  leading: isSelected
                      ? Icon(Icons.check_rounded, color: primaryColor, size: 16)
                      : const SizedBox(width: 16),
                  onPressed: () {
                    setState(() {
                      _currentSort = choice;
                      _applySearchAndSort();
                    });
                  },
                );
              }).toList(),
            ),
          ],
        ),
        const SizedBox(width: 6),
        // Layout switcher (list, compact, grid)
        M3EMenu(
          anchorBuilder: (context, open) => InkWell(
            onTap: open,
            borderRadius: BorderRadius.circular(10),
            child: Container(
              padding: const EdgeInsets.all(7),
              decoration: BoxDecoration(
                color: _surfaceDark,
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: _outline.withValues(alpha: 0.2)),
              ),
              child: Icon(_trackViewMode.icon, size: 16, color: primaryColor),
            ),
          ),
          children: [
            M3EMenuGroup.entries(
              label: 'Layout Mode',
              entries: TrackViewMode.values.map((mode) {
                final isSelected = _trackViewMode == mode;
                return M3EMenuEntry(
                  label: mode.label,
                  leading: Icon(mode.icon,
                      size: 16, color: isSelected ? primaryColor : textDark),
                  trailingText: isSelected ? '✓' : null,
                  onPressed: () {
                    setState(() {
                      _trackViewMode = mode;
                    });
                  },
                );
              }).toList(),
            ),
          ],
        ),
        if (_selectedCategory == LibraryCategory.tracks) ...[
          const SizedBox(width: 6),
          // Group by menu
          /* M3EMenu(
            anchorBuilder: (context, open) => InkWell(
              onTap: open,
              borderRadius: BorderRadius.circular(10),
              child: Container(
                padding: const EdgeInsets.all(7),
                decoration: BoxDecoration(
                  color: _surfaceDark,
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(
                    color: _groupByOption != 'None'
                        ? primaryColor.withValues(alpha: 0.5)
                        : _outline.withValues(alpha: 0.2),
                  ),
                ),
                child: Icon(
                  Icons.account_tree_rounded,
                  size: 16,
                  color: _groupByOption != 'None' ? primaryColor : textDark,
                ),
              ),
            ),
            children: [
              M3EMenuGroup.entries(
                label: 'Group Tracks By',
                entries: _groupByOptions.map((choice) {
                  final isSelected = _groupByOption == choice;
                  return M3EMenuEntry(
                    label: choice == 'None' ? 'No Grouping' : 'By $choice',
                    trailingText: isSelected ? '✓' : null,
                    onPressed: () {
                      setState(() {
                        _groupByOption = choice;
                      });
                    },
                  );
                }).toList(),
              ),
            ],
          ),
           //const SizedBox(width: 6),
          // Selection mode toggle
          InkWell(
            onTap: () => _toggleSelectionMode(true),
            borderRadius: BorderRadius.circular(10),
            child: Container(
              padding: const EdgeInsets.all(7),
              decoration: BoxDecoration(
                color: _surfaceDark,
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: _outline.withValues(alpha: 0.2)),
              ),
              child: Icon(Icons.checklist_rounded, size: 16, color: textDark),
            ),
          ),*/
        ],
      ],
    );
  }

  Widget _buildSelectionActionBar(Color primaryColor,
      {bool isDesktop = false}) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
      decoration: BoxDecoration(
        color: primaryColor.withValues(alpha: 0.15),
        borderRadius: BorderRadius.circular(isDesktop ? 16 : 14),
        border: Border.all(
          color: primaryColor.withValues(alpha: 0.45),
          width: 1.5,
        ),
      ),
      child: Row(
        children: [
          M3EIconButton(
            icon: Icon(Icons.close_rounded, size: isDesktop ? 22 : 20),
            variant: M3EIconButtonVariant.tonal,
            onPressed: () => _toggleSelectionMode(false),
          ),
          const SizedBox(width: 6),
          // Selection count pill
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
            decoration: BoxDecoration(
              color: primaryColor.withValues(alpha: 0.2),
              borderRadius: BorderRadius.circular(12),
            ),
            child: Text(
              '${_selectedTrackPaths.length} Selected',
              style: TextStyle(
                color: _textPrimary,
                fontWeight: FontWeight.bold,
                fontSize: isDesktop ? 14 : 12.5,
              ),
            ),
          ),
          const Spacer(),
          M3EIconButton(
            icon: Icon(
              _selectedTrackPaths.length == _filteredSongs.length &&
                      _filteredSongs.isNotEmpty
                  ? Icons.deselect_rounded
                  : Icons.select_all_rounded,
              size: isDesktop ? 22 : 20,
            ),
            variant: M3EIconButtonVariant.tonal,
            onPressed: () {
              if (_selectedTrackPaths.length == _filteredSongs.length) {
                _deselectAllTracks();
              } else {
                _selectAllTracks();
              }
            },
          ),
          const SizedBox(width: 6),
          M3EIconButton(
            icon: Icon(Icons.playlist_add_rounded, size: isDesktop ? 22 : 20),
            variant: M3EIconButtonVariant.tonal,
            onPressed: () => _showAddToPlaylistSheet(),
          ),
          const SizedBox(width: 6),
          M3EIconButton(
            icon: Icon(Icons.queue_music_rounded, size: isDesktop ? 22 : 20),
            variant: M3EIconButtonVariant.tonal,
            onPressed: _queueSelectedTracks,
          ),
          const SizedBox(width: 6),
          M3EIconButton(
            icon: Icon(Icons.play_arrow_rounded, size: isDesktop ? 24 : 22),
            variant: M3EIconButtonVariant.filled,
            onPressed: () => _playSelectedTracks(),
          ),
        ],
      ),
    );
  }

  Widget _buildSelectedSliverContent(Color primaryColor, Color textDark,
      {bool isDesktop = false}) {
    switch (_selectedCategory) {
      case LibraryCategory.tracks:
        return _buildDownloadsTabSliver(primaryColor, textDark,
            isDesktop: isDesktop);
      case LibraryCategory.albums:
        return _buildAlbumsTabSliver(primaryColor, textDark,
            isDesktop: isDesktop);
      case LibraryCategory.artists:
        return _buildArtistsTabSliver(primaryColor, textDark,
            isDesktop: isDesktop);
      case LibraryCategory.playlists:
        return _buildPlaylistsTabSliver(primaryColor, textDark,
            isDesktop: isDesktop);
      case LibraryCategory.folders:
        return _buildFoldersTabSliver(primaryColor, textDark,
            isDesktop: isDesktop);
    }
  }

  Widget _buildPlaylistsTabSliver(Color primaryColor, Color textDark,
      {bool isDesktop = false}) {
    if (_m3uPlaylists.isEmpty && !_isLoading) {
      return SliverFillRemaining(
        hasScrollBody: false,
        child: _buildEmptyState(textDark,
            message: 'No playlists found',
            subMessage:
                'Use the (+) button above to import M3U / M3U8 playlists or streams.',
            isDesktop: isDesktop),
      );
    }
    return SliverPadding(
      padding: EdgeInsets.symmetric(
        horizontal: isDesktop ? 32.0 : 16.0,
        vertical: 8.0,
      ),
      sliver: SliverList(
        delegate: SliverChildBuilderDelegate(
          (context, index) {
            final totalCount = 2 + _m3uPlaylists.length;
            final isFirst = index == 0;
            final isLast = index == totalCount - 1;

            if (index == 0) {
              return _buildLibraryItem(
                title: 'Network Stream (FTP & DLNA)',
                subtitle: 'FTP Remote Explorer & DLNA Media Casting',
                iconData: Icons.lan_rounded,
                iconGradient: const LinearGradient(
                  colors: [Color(0xFF00897B), Color(0xFF004D40)],
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                ),
                onTap: _navigateToNetworkSources,
                context: context,
                isDesktop: isDesktop,
                isFirst: isFirst,
                isLast: isLast,
              );
            } else if (index == 1) {
              return ValueListenableBuilder<List<CachedStreamItem>>(
                valueListenable:
                    CachedStreamService.instance.cachedStreamsNotifier,
                builder: (context, cachedItems, _) {
                  return ValueListenableBuilder<int>(
                    valueListenable:
                        CachedStreamService.instance.totalSizeBytesNotifier,
                    builder: (context, totalBytes, _) {
                      return _buildLibraryItem(
                        title: 'Cached Online Streams',
                        subtitle:
                            '${cachedItems.length} Tracks • ${CachedStreamService.formatBytes(totalBytes)} Cached Offline',
                        iconData: Icons.cloud_done_rounded,
                        iconGradient: const LinearGradient(
                          colors: [Color(0xFF00796B), Color(0xFF004D40)],
                          begin: Alignment.topLeft,
                          end: Alignment.bottomRight,
                        ),
                        onTap: () {
                          Navigator.of(context).push(
                            MaterialPageRoute(
                              builder: (_) => CachedStreamsScreen(
                                onPlayTracks: widget.onPlayCachedStreams ??
                                    (tracks, {initialIndex = 0}) async {},
                                onQueueTrack: widget.onQueueTrack,
                              ),
                            ),
                          );
                        },
                        context: context,
                        isDesktop: isDesktop,
                        isFirst: isFirst,
                        isLast: isLast,
                      );
                    },
                  );
                },
              );
            } else {
              final pl = _m3uPlaylists[index - 2];
              return _buildLibraryItem(
                title: pl.name,
                subtitle:
                    '${pl.tracks.length} Songs • M3U ${pl.isNetwork ? 'Stream' : 'Playlist'}',
                iconData: pl.isNetwork
                    ? Icons.podcasts_rounded
                    : Icons.queue_music_rounded,
                iconGradient: pl.isNetwork
                    ? const LinearGradient(
                        colors: [Color(0xFF00897B), Color(0xFF004D40)],
                        begin: Alignment.topLeft,
                        end: Alignment.bottomRight,
                      )
                    : const LinearGradient(
                        colors: [Color(0xFF0288D1), Color(0xFF01579B)],
                        begin: Alignment.topLeft,
                        end: Alignment.bottomRight,
                      ),
                onTap: () {
                  if (pl.isNetwork) {
                    _playM3uPlaylist(pl);
                  } else {
                    Navigator.of(context).push(
                      MaterialPageRoute(
                        builder: (_) => PlaylistDetailScreen(
                          playlist: pl,
                          onPlayFolder: widget.onPlayFolder,
                          onPlaylistUpdated: _loadSavedM3uPlaylists,
                        ),
                      ),
                    );
                  }
                },
                onLongPress: () => _showM3uPlaylistOptions(pl),
                context: context,
                isDesktop: isDesktop,
                isFirst: isFirst,
                isLast: isLast,
              );
            }
          },
          childCount: 2 + _m3uPlaylists.length,
        ),
      ),
    );
  }

  Widget _buildFoldersTabSliver(Color primaryColor, Color textDark,
      {bool isDesktop = false}) {
    if (_folders.isEmpty && !_isLoading) {
      return SliverFillRemaining(
        hasScrollBody: false,
        child: _buildEmptyState(textDark,
            message: 'No local folders added',
            subMessage:
                'Use the (+) button above to add music folders from your device.',
            isDesktop: isDesktop),
      );
    }
    return SliverPadding(
      padding: EdgeInsets.symmetric(
        horizontal: isDesktop ? 32.0 : 16.0,
        vertical: 8.0,
      ),
      sliver: SliverList(
        delegate: SliverChildBuilderDelegate(
          (context, index) {
            final f = _folders[index];
            final isFirst = index == 0;
            final isLast = index == _folders.length - 1;
            return _buildLibraryItem(
              title: f['name'] as String,
              subtitle: '${f['count']} Songs • Local Folder',
              iconData: Icons.folder_rounded,
              onTap: () => _playFolder(f['path'] as String),
              onLongPress: () => _removeFolder(index),
              context: context,
              isDesktop: isDesktop,
              isFirst: isFirst,
              isLast: isLast,
            );
          },
          childCount: _folders.length,
        ),
      ),
    );
  }

  Widget _buildDownloadsTabSliver(Color primaryColor, Color textDark,
      {bool isDesktop = false}) {
    return _filteredSongs.isEmpty && !_isLoading
        ? SliverFillRemaining(
            hasScrollBody: false,
            child: _buildEmptyState(textDark,
                message: 'No songs found',
                subMessage: _searchController.text.isNotEmpty
                    ? 'No matches for your search.'
                    : 'Add local folders using the (+) menu to view your songs here.',
                isDesktop: isDesktop),
          )
        : _buildTrackViewSliver(isDesktop: isDesktop);
  }

  bool _hasValidArtist(String? artist) {
    if (artist == null) return false;
    final a = artist.trim().toLowerCase();
    return a.isNotEmpty &&
        a != 'unknown' &&
        a != 'unknown artist' &&
        a != 'local file' &&
        a != 'n/a' &&
        a != 'none';
  }

  bool _hasValidAlbum(String? album) {
    if (album == null) return false;
    final a = album.trim().toLowerCase();
    return a.isNotEmpty &&
        a != 'unknown' &&
        a != 'unknown album' &&
        a != 'n/a' &&
        a != 'none';
  }

  Widget _buildTrackViewSliver({bool isDesktop = false}) {
    if (_groupByOption != 'None') {
      final Map<String, List<LocalSongItem>> groupedMap = {};
      for (final song in _filteredSongs) {
        String? key;
        if (_groupByOption == 'Album') {
          if (_hasValidAlbum(song.album)) {
            key = song.album.trim();
          }
        } else if (_groupByOption == 'Artist') {
          if (_hasValidArtist(song.artist)) {
            key = song.artist.trim();
          }
        } else if (_groupByOption == 'Folder') {
          key = p.basename(p.dirname(song.path));
        }
        if (key != null && key.isNotEmpty) {
          groupedMap.putIfAbsent(key, () => []).add(song);
        }
      }

      final groupKeys = groupedMap.keys.toList()
        ..sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));

      if (groupKeys.isEmpty && !_isLoading) {
        return SliverFillRemaining(
          hasScrollBody: false,
          child: _buildEmptyState(
            _textDark,
            message: 'No grouped tracks found',
            subMessage: _filteredSongs.isNotEmpty
                ? 'None of the tracks have valid $_groupByOption tags.'
                : 'Add local folders in Playlists to view tracks here.',
            isDesktop: isDesktop,
          ),
        );
      }

    return SliverList(
      delegate: SliverChildBuilderDelegate(
        (context, groupIdx) {
          final key = groupKeys[groupIdx];
          final songs = groupedMap[key]!;
          return Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Group Header Banner
              InkWell(
                onTap: () {
                  Navigator.of(context).push(
                    MaterialPageRoute(
                      builder: (_) => LocalGroupDetailScreen(
                        groupTitle: key,
                        groupType: _groupByOption,
                        songs: songs,
                        onPlayFolder: widget.onPlayFolder,
                        onPlayTracks: widget.onPlayTracks,
                        onQueueTrack: widget.onQueueTrack,
                        onDeleteTrack: (path) {
                          widget.onDeleteTrack?.call(path);
                          _updateAllSongs();
                        },
                        player: widget.player,
                      ),
                    ),
                  );
                },
                child: Container(
                  margin: EdgeInsets.symmetric(
                    horizontal: isDesktop ? 32.0 : 16.0,
                    vertical: 8.0,
                  ),
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: _surfaceDark,
                    borderRadius: BorderRadius.circular(14),
                    border:
                        Border.all(color: _outline.withValues(alpha: 0.15)),
                  ),
                  child: Row(
                    children: [
                      LocalAlbumArt(
                        path: songs.first.path,
                        size: isDesktop ? 52 : 44,
                        borderRadius: 8,
                        shape: Shapes.pill,
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              key,
                              style: TextStyle(
                                fontSize: isDesktop ? 16 : 14,
                                fontWeight: FontWeight.bold,
                                color: _textPrimary,
                              ),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                            const SizedBox(height: 2),
                            Text(
                              '${songs.length} Track${songs.length == 1 ? '' : 's'} • $_groupByOption',
                              style: TextStyle(
                                fontSize: 11,
                                color: AppThemeService
                                    .instance.currentData.textDark,
                              ),
                            ),
                          ],
                        ),
                      ),
                      IconButton(
                        icon: Icon(Icons.play_circle_fill_rounded,
                            color:
                                AppThemeService.instance.currentData.primary,
                            size: 28),
                        onPressed: () {
                          final paths = songs.map((s) => s.path).toList();
                          widget.onPlayFolder(paths, initialIndex: 0);
                        },
                        tooltip: 'Play Group',
                      ),
                    ],
                  ),
                ),
              ),

                // Group Tracks
                ...List.generate(songs.length, (i) {
                  final song = songs[i];
                  final isFirst = i == 0;
                  final isLast = i == songs.length - 1;

                  return _buildLibraryItem(
                    title: song.title,
                    subtitle:
                        '${song.artist != "Unknown Artist" ? song.artist : "Local File"} • ${(song.sizeBytes / (1024 * 1024)).toStringAsFixed(1)} MB',
                    customIcon: LocalAlbumArt(
                        path: song.path,
                        size: isDesktop ? 80 : 56,
                        shape: Shapes.pill),
                    isFirst: isFirst,
                    isLast: isLast,
                    onTap: () {
                      setState(() {
                        _currentlyPlayingPath = song.path;
                        _lastPlayedTrackList = List.from(songs);
                      });
                      final paths = songs.map((e) => e.path).toList();
                      widget.onPlayFolder(paths, initialIndex: i);
                    },
                    onOptionSelected: (option) =>
                        _handleSongOption(song, option),
                    context: context,
                    isDesktop: isDesktop,
                  );
                }),
                const SizedBox(height: 12),
              ],
            );
          },
          childCount: groupKeys.length,
          addAutomaticKeepAlives: false,
          addRepaintBoundaries: true,
        ),
      );
    }

    if (_trackViewMode == TrackViewMode.compact) {
      return SliverPadding(
        padding: EdgeInsets.symmetric(
          horizontal: isDesktop ? 32 : 16,
          vertical: 8,
        ),
        sliver: SliverList(
          delegate: SliverChildBuilderDelegate(
            (context, index) {
              final song = _filteredSongs[index];
              final isFirst = index == 0;
              final isLast = index == _filteredSongs.length - 1;
              return _buildCompactSongItem(
                song,
                index,
                isDesktop: isDesktop,
                isFirst: isFirst,
                isLast: isLast,
                isSelectionMode: _isSelectionMode,
                isSelected: _selectedTrackPaths.contains(song.path),
                onSelectionChanged: (_) => _toggleTrackSelection(song.path),
              );
            },
            childCount: _filteredSongs.length,
            addAutomaticKeepAlives: false,
            addRepaintBoundaries: true,
          ),
        ),
      );
    } else if (_trackViewMode == TrackViewMode.grid) {
      return SliverPadding(
        padding: EdgeInsets.fromLTRB(
          isDesktop ? 32 : 16,
          8,
          isDesktop ? 32 : 16,
          8,
        ),
        sliver: SliverGrid(
          gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: isDesktop ? 4 : 2,
            childAspectRatio: 0.78,
            crossAxisSpacing: 12,
            mainAxisSpacing: 12,
          ),
          delegate: SliverChildBuilderDelegate(
            (context, index) {
              final song = _filteredSongs[index];
              return _buildGridSongItem(
                song,
                index,
                isDesktop: isDesktop,
                isSelectionMode: _isSelectionMode,
                isSelected: _selectedTrackPaths.contains(song.path),
                onSelectionChanged: (_) => _toggleTrackSelection(song.path),
              );
            },
            childCount: _filteredSongs.length,
            addAutomaticKeepAlives: false,
            addRepaintBoundaries: true,
          ),
        ),
      );
    } else {
      // Standard Virtualized ListView with connected M3E rounded card style
      return SliverPadding(
        padding: EdgeInsets.symmetric(
          horizontal: isDesktop ? 32 : 16,
          vertical: 8,
        ),
        sliver: SliverList(
          delegate: SliverChildBuilderDelegate(
            (context, index) {
              final song = _filteredSongs[index];
              final isFirst = index == 0;
              final isLast = index == _filteredSongs.length - 1;

              return _buildLibraryItem(
                title: song.title,
                subtitle:
                    '${song.artist != "Unknown Artist" ? song.artist : "Local File"} • ${(song.sizeBytes / (1024 * 1024)).toStringAsFixed(1)} MB',
                customIcon: LocalAlbumArt(
                    path: song.path,
                    size: isDesktop ? 60 : 48,
                    shape: Shapes.pill),
                isFirst: isFirst,
                isLast: isLast,
                isSelectionMode: _isSelectionMode,
                isSelected: _selectedTrackPaths.contains(song.path),
                onSelectionChanged: (_) => _toggleTrackSelection(song.path),
                onTap: () {
                  if (_isSelectionMode) {
                    _toggleTrackSelection(song.path);
                  } else {
                    setState(() {
                      _currentlyPlayingPath = song.path;
                      _lastPlayedTrackList = List.from(_filteredSongs);
                    });
                    final paths = _filteredSongs.map((e) => e.path).toList();
                    widget.onPlayFolder(paths, initialIndex: index);
                  }
                },
                onLongPress: () {
                  if (!_isSelectionMode) {
                    _toggleSelectionMode(true);
                  }
                  _toggleTrackSelection(song.path);
                },
                onOptionSelected: (option) => _handleSongOption(song, option),
                context: context,
                isDesktop: isDesktop,
              );
            },
            childCount: _filteredSongs.length,
            addAutomaticKeepAlives: false,
            addRepaintBoundaries: true,
          ),
        ),
      );
    }
  }

  Widget _buildCompactSongItem(
    LocalSongItem song,
    int index, {
    bool isDesktop = false,
    bool isFirst = false,
    bool isLast = false,
    bool isSelectionMode = false,
    bool isSelected = false,
    ValueChanged<bool?>? onSelectionChanged,
  }) {
    final artistName =
        song.artist != 'Unknown Artist' ? song.artist : 'Local File';
    final borderRadius = BorderRadius.only(
      topLeft: Radius.circular(isFirst ? 20 : 6),
      topRight: Radius.circular(isFirst ? 20 : 6),
      bottomLeft: Radius.circular(isLast ? 20 : 6),
      bottomRight: Radius.circular(isLast ? 20 : 6),
    );

    final itemColor =
        isSelected ? _primary.withValues(alpha: 0.16) : _surfaceDark;
    final borderColor = isSelected
        ? _primary.withValues(alpha: 0.55)
        : _outline.withValues(alpha: 0.12);

    return Padding(
      padding: const EdgeInsets.only(bottom: 3.0),
      child: Material(
        color: itemColor,
        shape: RoundedRectangleBorder(
          borderRadius: borderRadius,
          side: BorderSide(
            color: borderColor,
            width: isSelected ? 1.4 : 1.0,
          ),
        ),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: () {
            if (isSelectionMode) {
              _toggleTrackSelection(song.path);
            } else {
              setState(() {
                _currentlyPlayingPath = song.path;
                _lastPlayedTrackList = List.from(_filteredSongs);
              });
              final paths = _filteredSongs.map((e) => e.path).toList();
              widget.onPlayFolder(paths, initialIndex: index);
            }
          },
          onLongPress: () {
            if (!isSelectionMode) {
              _toggleSelectionMode(true);
            }
            _toggleTrackSelection(song.path);
          },
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
            child: Row(
              children: [
                if (isSelectionMode) ...[
                  Checkbox(
                    value: isSelected,
                    activeColor: _primary,
                    checkColor: Colors.white,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(5),
                    ),
                    side: BorderSide(
                      color: isSelected
                          ? _primary
                          : _textDark.withValues(alpha: 0.6),
                      width: 1.5,
                    ),
                    onChanged: onSelectionChanged,
                  ),
                  const SizedBox(width: 4),
                ],
                LocalAlbumArt(
                  path: song.path,
                  size: isDesktop ? 40 : 34,
                  borderRadius: 6,
                  shape: Shapes.pill,
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        song.title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: isDesktop ? 14 : 12.5,
                          fontWeight: FontWeight.w600,
                          color: _textPrimary,
                        ),
                      ),
                      const SizedBox(height: 1),
                      Text(
                        artistName,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: isDesktop ? 12 : 11,
                          color: _textDark,
                        ),
                      ),
                    ],
                  ),
                ),
                if (!isSelectionMode)
                  SongOptionsMenuButton(
                    iconSize: isDesktop ? 18 : 16,
                    onOptionSelected: (option) =>
                        _handleSongOption(song, option),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildGridSongItem(
    LocalSongItem song,
    int index, {
    bool isDesktop = false,
    bool isSelectionMode = false,
    bool isSelected = false,
    ValueChanged<bool?>? onSelectionChanged,
  }) {
    final artistName =
        song.artist != 'Unknown Artist' ? song.artist : 'Local File';
    final primaryColor = context.primaryColor;
    final cardColor = context.cardDark;

    const Shapes itemShape = Shapes.slanted;

    final itemBg = isSelected
        ? primaryColor.withValues(alpha: 0.16)
        : cardColor.withAlpha(240);
    final itemBorder = isSelected
        ? primaryColor.withValues(alpha: 0.7)
        : primaryColor.withValues(alpha: 0.18);

    return RepaintBoundary(
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          borderRadius: BorderRadius.circular(16),
          onTap: () {
            if (isSelectionMode) {
              _toggleTrackSelection(song.path);
            } else {
              setState(() {
                _currentlyPlayingPath = song.path;
                _lastPlayedTrackList = List.from(_filteredSongs);
              });
              final paths = _filteredSongs.map((e) => e.path).toList();
              widget.onPlayFolder(paths, initialIndex: index);
            }
          },
          onLongPress: () {
            if (!isSelectionMode) {
              _toggleSelectionMode(true);
            }
            _toggleTrackSelection(song.path);
          },
          child: M3EContainer(
            Shapes.bun,
            width: double.infinity,
            height: double.infinity,
            color: itemBg,
            border: BorderSide(
              color: itemBorder,
              width: isSelected ? 1.8 : 1.2,
            ),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.35),
                blurRadius: 10,
                offset: const Offset(0, 4),
              ),
            ],
            padding: const EdgeInsets.all(10),
            clipBehavior: Clip.antiAlias,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: Stack(
                    children: [
                      Positioned.fill(
                        child: M3EContainer(
                          itemShape,
                          color: cardColor,
                          clipBehavior: Clip.antiAlias,
                          border: BorderSide(
                            color: primaryColor.withValues(alpha: 0.3),
                            width: 1.5,
                          ),
                          boxShadow: [
                            BoxShadow(
                              color: primaryColor.withValues(alpha: 0.15),
                              blurRadius: 6,
                              offset: const Offset(0, 2),
                            ),
                          ],
                          child: LocalAlbumArt(
                            path: song.path,
                            shape: itemShape,
                            useM3Shape: true,
                          ),
                        ),
                      ),
                      if (isSelectionMode)
                        Positioned(
                          top: 4,
                          left: 4,
                          child: Container(
                            decoration: BoxDecoration(
                              color: Colors.black.withValues(alpha: 0.7),
                              shape: BoxShape.circle,
                            ),
                            child: Checkbox(
                              value: isSelected,
                              activeColor: primaryColor,
                              checkColor: Colors.white,
                              shape: const CircleBorder(),
                              onChanged: onSelectionChanged,
                            ),
                          ),
                        ),
                      // Top-Right Options Badge
                      if (!isSelectionMode)
                        Positioned(
                          top: 4,
                          right: 4,
                          child: M3EContainer.circle(
                            width: 32,
                            height: 32,
                            color: Colors.black.withValues(alpha: 0.65),
                            child: SongOptionsMenuButton(
                              iconSize: 18,
                              onOptionSelected: (option) =>
                                  _handleSongOption(song, option),
                            ),
                          ),
                        ),
                      // Bottom-Right Play Badge
                      if (!isSelectionMode)
                        Positioned(
                          bottom: 4,
                          right: 4,
                          child: M3EContainer.circle(
                            width: 32,
                            height: 32,
                            gradient: LinearGradient(
                              colors: [
                                primaryColor,
                                primaryColor.withValues(alpha: 0.8),
                              ],
                              begin: Alignment.topLeft,
                              end: Alignment.bottomRight,
                            ),
                            boxShadow: [
                              BoxShadow(
                                color: Colors.black.withValues(alpha: 0.4),
                                blurRadius: 4,
                                offset: const Offset(0, 2),
                              ),
                            ],
                            child: const Center(
                              child: Icon(
                                Icons.play_arrow_rounded,
                                size: 20,
                                color: Colors.white,
                              ),
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  song.title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: isDesktop ? 14 : 13,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                const SizedBox(height: 2),
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        artistName,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: AppThemeService.instance.currentData.textDark,
                          fontSize: 11,
                        ),
                      ),
                    ),
                    const SizedBox(width: 4),
                    M3EShape(
                      itemShape,
                      width: 12,
                      height: 12,
                      color: primaryColor.withValues(alpha: 0.8),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildArtistsTabSliver(Color primaryColor, Color textDark,
      {bool isDesktop = false}) {
    final Map<String, List<LocalSongItem>> artistMap = {};
    for (final song in _allSongs) {
      if (_hasValidArtist(song.artist)) {
        artistMap.putIfAbsent(song.artist.trim(), () => []).add(song);
      }
    }

    final query = _searchController.text.trim().toLowerCase();
    final artistKeys = artistMap.keys.where((a) {
      if (query.isEmpty) return true;
      return a.toLowerCase().contains(query);
    }).toList()
      ..sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));

    if (artistKeys.isEmpty && !_isLoading) {
      return SliverFillRemaining(
        hasScrollBody: false,
        child: _buildEmptyState(
          textDark,
          message: 'No artists found',
          subMessage: _searchController.text.isNotEmpty
              ? 'No matches for "${_searchController.text}".'
              : 'Add local folders using the (+) menu to view artists here.',
          isDesktop: isDesktop,
        ),
      );
    }

    return SliverPadding(
      padding: EdgeInsets.symmetric(
        horizontal: isDesktop ? 32 : 16,
        vertical: 8,
      ),
      sliver: SliverList(
        delegate: SliverChildBuilderDelegate(
          (context, index) {
            final artistName = artistKeys[index];
            final songs = artistMap[artistName] ?? [];
            final sampleSongPath = songs.isNotEmpty ? songs.first.path : null;
            final isFirst = index == 0;
            final isLast = index == artistKeys.length - 1;

            return _buildLibraryItem(
              title: artistName,
              subtitle:
                  '${songs.length} Song${songs.length == 1 ? '' : 's'} • Artist',
              iconData: Icons.person_rounded,
              isArtist: true,
              isFirst: isFirst,
              isLast: isLast,
              customIcon: sampleSongPath != null
                  ? LocalAlbumArt(
                      path: sampleSongPath,
                      size: isDesktop ? 60 : 48,
                      shape: Shapes.circle,
                    )
                  : null,
              onTap: () {
                Navigator.of(context).push(
                  MaterialPageRoute(
                    builder: (_) => LocalGroupDetailScreen(
                      groupTitle: artistName,
                      groupType: 'Artist',
                      songs: songs,
                      onPlayFolder: widget.onPlayFolder,
                      onPlayTracks: widget.onPlayTracks,
                      onQueueTrack: widget.onQueueTrack,
                      onDeleteTrack: (path) {
                        widget.onDeleteTrack?.call(path);
                        _updateAllSongs();
                      },
                      player: widget.player,
                    ),
                  ),
                );
              },
              context: context,
              isDesktop: isDesktop,
            );
          },
          childCount: artistKeys.length,
        ),
      ),
    );
  }

  Widget _buildAlbumsTabSliver(Color primaryColor, Color textDark,
      {bool isDesktop = false}) {
    final Map<String, List<LocalSongItem>> albumMap = {};
    for (final song in _allSongs) {
      if (_hasValidAlbum(song.album)) {
        albumMap.putIfAbsent(song.album.trim(), () => []).add(song);
      }
    }

    final query = _searchController.text.trim().toLowerCase();
    final albumKeys = albumMap.keys.where((a) {
      if (query.isEmpty) return true;
      return a.toLowerCase().contains(query);
    }).toList()
      ..sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));

    if (albumKeys.isEmpty && !_isLoading) {
      return SliverFillRemaining(
        hasScrollBody: false,
        child: _buildEmptyState(
          textDark,
          message: 'No albums found',
          subMessage: _searchController.text.isNotEmpty
              ? 'No matches for "${_searchController.text}".'
              : 'Add local folders using the (+) menu to view albums here.',
          isDesktop: isDesktop,
        ),
      );
    }

    return SliverPadding(
      padding: EdgeInsets.symmetric(
        horizontal: isDesktop ? 32 : 16,
        vertical: 8,
      ),
      sliver: SliverList(
        delegate: SliverChildBuilderDelegate(
          (context, index) {
            final albumName = albumKeys[index];
            final songs = albumMap[albumName] ?? [];
            final sampleSongPath = songs.isNotEmpty ? songs.first.path : null;
            final artistName =
                songs.isNotEmpty && _hasValidArtist(songs.first.artist)
                    ? songs.first.artist
                    : '';
            final isFirst = index == 0;
            final isLast = index == albumKeys.length - 1;

            return _buildLibraryItem(
              title: albumName,
              subtitle: artistName.isNotEmpty
                  ? '${songs.length} Song${songs.length == 1 ? '' : 's'} • $artistName'
                  : '${songs.length} Song${songs.length == 1 ? '' : 's'}',
              iconData: Icons.album_rounded,
              isFirst: isFirst,
              isLast: isLast,
              customIcon: sampleSongPath != null
                  ? LocalAlbumArt(
                      path: sampleSongPath,
                      size: isDesktop ? 60 : 48,
                      shape: Shapes.pill,
                    )
                  : null,
              onTap: () {
                Navigator.of(context).push(
                  MaterialPageRoute(
                    builder: (_) => LocalGroupDetailScreen(
                      groupTitle: albumName,
                      groupType: 'Album',
                      songs: songs,
                      onPlayFolder: widget.onPlayFolder,
                      onPlayTracks: widget.onPlayTracks,
                      onQueueTrack: widget.onQueueTrack,
                      onDeleteTrack: (path) {
                        widget.onDeleteTrack?.call(path);
                        _updateAllSongs();
                      },
                      player: widget.player,
                    ),
                  ),
                );
              },
              context: context,
              isDesktop: isDesktop,
            );
          },
          childCount: albumKeys.length,
        ),
      ),
    );
  }

  Widget _buildEmptyState(Color textDark,
      {String message = 'Library is empty',
      String subMessage = 'Tap the + button to add local music folders.',
      bool isDesktop = false}) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.library_music_outlined,
              size: isDesktop ? 80 : 56,
              color: textDark.withValues(alpha: 0.4)),
          SizedBox(height: isDesktop ? 20 : 14),
          Text(
            message,
            style: TextStyle(
                fontSize: isDesktop ? 20 : 16,
                fontWeight: FontWeight.bold,
                color: Colors.white),
          ),
          SizedBox(height: isDesktop ? 10 : 6),
          Padding(
            padding: EdgeInsets.symmetric(horizontal: isDesktop ? 64.0 : 32.0),
            child: Text(
              subMessage,
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: isDesktop ? 15 : 13, color: textDark),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildLibraryItem({
    required String title,
    required String subtitle,
    required BuildContext context,
    IconData? iconData,
    Widget? customIcon,
    Gradient? iconGradient,
    VoidCallback? onTap,
    VoidCallback? onLongPress,
    ValueChanged<SongOption>? onOptionSelected,
    bool isDesktop = false,
    bool isArtist = false,
    bool isFirst = false,
    bool isLast = false,
    bool isSelectionMode = false,
    bool isSelected = false,
    ValueChanged<bool?>? onSelectionChanged,
  }) {
    final thumbSize = isDesktop ? 60.0 : 48.0;
    final borderRadius = BorderRadius.only(
      topLeft: Radius.circular(isFirst ? 20 : 6),
      topRight: Radius.circular(isFirst ? 20 : 6),
      bottomLeft: Radius.circular(isLast ? 20 : 6),
      bottomRight: Radius.circular(isLast ? 20 : 6),
    );

    final leadingWidget = customIcon ??
        Container(
          width: thumbSize,
          height: thumbSize,
          decoration: BoxDecoration(
            gradient: iconGradient,
            color: iconGradient == null ? _surfaceDark : null,
            shape: isArtist ? BoxShape.circle : BoxShape.rectangle,
            borderRadius: isArtist ? null : BorderRadius.circular(10),
          ),
          child: Center(
            child: Icon(
              iconData ?? Icons.music_note_rounded,
              color: Colors.white.withValues(alpha: 0.7),
              size: isDesktop ? 28 : 22,
            ),
          ),
        );

    final itemColor =
        isSelected ? _primary.withValues(alpha: 0.16) : _surfaceDark;
    final borderColor = isSelected
        ? _primary.withValues(alpha: 0.55)
        : _outline.withValues(alpha: 0.12);

    return Padding(
      padding: const EdgeInsets.only(bottom: 3.0),
      child: Material(
        color: itemColor,
        shape: RoundedRectangleBorder(
          borderRadius: borderRadius,
          side: BorderSide(
            color: borderColor,
            width: isSelected ? 1.4 : 1.0,
          ),
        ),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          onLongPress: onLongPress,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
            child: Row(
              children: [
                if (isSelectionMode) ...[
                  Checkbox(
                    value: isSelected,
                    activeColor: _primary,
                    checkColor: Colors.white,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(5),
                    ),
                    side: BorderSide(
                      color: isSelected
                          ? _primary
                          : _textDark.withValues(alpha: 0.6),
                      width: 1.5,
                    ),
                    onChanged: onSelectionChanged,
                  ),
                  const SizedBox(width: 4),
                ],
                leadingWidget,
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: isDesktop ? 15 : 13.5,
                          fontWeight: FontWeight.w600,
                          color: _textPrimary,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        subtitle,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: isDesktop ? 13 : 11.5,
                          color: _textDark,
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 8),
                if (!isSelectionMode && onOptionSelected != null)
                  SongOptionsMenuButton(
                    iconSize: isDesktop ? 22 : 18,
                    onOptionSelected: onOptionSelected,
                  )
                else if (!isSelectionMode)
                  Icon(
                    Icons.chevron_right_rounded,
                    color: const Color(0xFF64748B),
                    size: isDesktop ? 20 : 18,
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class LocalGroupDetailScreen extends StatefulWidget {
  final String groupTitle;
  final String groupType; // 'Artist', 'Album', 'Folder'
  final List<LocalSongItem> songs;
  final Future<void> Function(List<String> audioFilePaths, {int initialIndex})
      onPlayFolder;
  final Future<void> Function(List<TrackInfo> tracks, {int initialIndex})?
      onPlayTracks;
  final Function(TrackInfo track)? onQueueTrack;
  final Function(String filePath)? onDeleteTrack;
  final IsolateAudioPlayer? player;

  const LocalGroupDetailScreen({
    super.key,
    required this.groupTitle,
    this.groupType = 'Group',
    required this.songs,
    required this.onPlayFolder,
    this.onPlayTracks,
    this.onQueueTrack,
    this.onDeleteTrack,
    this.player,
  });

  @override
  State<LocalGroupDetailScreen> createState() => _LocalGroupDetailScreenState();
}

class _LocalGroupDetailScreenState extends State<LocalGroupDetailScreen> {
  late List<LocalSongItem> _groupSongs;

  @override
  void initState() {
    super.initState();
    _groupSongs = List.from(widget.songs);
  }

  @override
  Widget build(BuildContext context) {
    final bgDark = context.bgDark;
    final surfaceColor = context.cardDark;
    final primaryColor = context.primaryColor;
    final textPrimary = context.textPrimary;
    final textDark = context.textMuted;
    final outlineColor = context.outlineColor;

    return Scaffold(
      backgroundColor: bgDark,
      appBar: AppBar(
        backgroundColor: bgDark,
        elevation: 0,
        title: Text(
          widget.groupTitle,
          style: TextStyle(fontWeight: FontWeight.bold, color: textPrimary),
        ),
        actions: [
          if (widget.onPlayTracks != null && widget.groupType == 'Artist')
            IconButton(
              icon: Icon(Icons.language, color: textDark),
              tooltip: 'View Online Discography',
              onPressed: () {
                Navigator.of(context).push(
                  MaterialPageRoute(
                    builder: (_) => ArtistProfileScreen(
                      artistName: widget.groupTitle,
                      onPlayTracks: widget.onPlayTracks,
                    ),
                  ),
                );
              },
            ),
        ],
      ),
      body: SafeArea(
        child: Column(
          children: [
            // Header Card
            Container(
              padding: const EdgeInsets.all(20),
              margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              decoration: BoxDecoration(
                color: surfaceColor,
                borderRadius: BorderRadius.circular(16),
                border: Border.all(color: outlineColor),
              ),
              child: Row(
                children: [
                  Container(
                    width: 64,
                    height: 64,
                    decoration: BoxDecoration(
                      color: primaryColor.withValues(alpha: 0.2),
                      borderRadius: widget.groupType == 'Artist'
                          ? BorderRadius.circular(32)
                          : BorderRadius.circular(12),
                    ),
                    clipBehavior: Clip.antiAlias,
                    child: _groupSongs.isNotEmpty
                        ? LocalAlbumArt(
                            path: _groupSongs.first.path,
                            size: 64,
                            shape: widget.groupType == 'Artist'
                                ? Shapes.circle
                                : Shapes.pill,
                          )
                        : Icon(
                            widget.groupType == 'Artist'
                                ? Icons.person
                                : (widget.groupType == 'Album'
                                    ? Icons.album
                                    : Icons.folder),
                            color: primaryColor,
                            size: 36),
                  ),
                  const SizedBox(width: 16),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          widget.groupTitle,
                          style: TextStyle(
                            fontSize: 20,
                            fontWeight: FontWeight.bold,
                            color: textPrimary,
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        const SizedBox(height: 4),
                        Text(
                          '${_groupSongs.length} Track${_groupSongs.length == 1 ? '' : 's'} • ${widget.groupType}',
                          style: TextStyle(color: textDark, fontSize: 13),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 8),
                  ElevatedButton.icon(
                    onPressed: () {
                      if (_groupSongs.isEmpty) return;
                      final paths = _groupSongs.map((e) => e.path).toList();
                      widget.onPlayFolder(paths, initialIndex: 0);
                    },
                    icon: const Icon(Icons.play_arrow, color: Colors.white),
                    label: const Text('Play All'),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: primaryColor,
                      foregroundColor: Colors.white,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(20),
                      ),
                    ),
                  ),
                ],
              ),
            ),

            // Track List
            Expanded(
              child: _groupSongs.isEmpty
                  ? Center(
                      child: Text(
                        'No songs left in this group.',
                        style: TextStyle(color: textDark),
                      ),
                    )
                  : ListView.builder(
                      padding: const EdgeInsets.symmetric(
                              horizontal: 16, vertical: 8)
                          .copyWith(bottom: 120),
                      itemCount: _groupSongs.length,
                      itemBuilder: (context, index) {
                        final song = _groupSongs[index];
                        final isFirst = index == 0;
                        final isLast = index == _groupSongs.length - 1;
                        final borderRadius = BorderRadius.only(
                          topLeft: Radius.circular(isFirst ? 20 : 6),
                          topRight: Radius.circular(isFirst ? 20 : 6),
                          bottomLeft: Radius.circular(isLast ? 20 : 6),
                          bottomRight: Radius.circular(isLast ? 20 : 6),
                        );

                        return Padding(
                          padding: const EdgeInsets.only(bottom: 3.0),
                          child: Material(
                            color: surfaceColor,
                            shape: RoundedRectangleBorder(
                              borderRadius: borderRadius,
                              side: BorderSide(
                                color: outlineColor.withValues(alpha: 0.12),
                                width: 1.0,
                              ),
                            ),
                            clipBehavior: Clip.antiAlias,
                            child: InkWell(
                              onTap: () {
                                final paths =
                                    _groupSongs.map((e) => e.path).toList();
                                widget.onPlayFolder(paths, initialIndex: index);
                              },
                              child: Padding(
                                padding: const EdgeInsets.symmetric(
                                    horizontal: 14, vertical: 10),
                                child: Row(
                                  children: [
                                    LocalAlbumArt(
                                      path: song.path,
                                      size: 48,
                                      shape: Shapes.pill,
                                    ),
                                    const SizedBox(width: 12),
                                    Expanded(
                                      child: Column(
                                        crossAxisAlignment:
                                            CrossAxisAlignment.start,
                                        mainAxisSize: MainAxisSize.min,
                                        children: [
                                          Text(
                                            song.title,
                                            maxLines: 1,
                                            overflow: TextOverflow.ellipsis,
                                            style: TextStyle(
                                              fontSize: 14,
                                              fontWeight: FontWeight.w600,
                                              color: textPrimary,
                                            ),
                                          ),
                                          const SizedBox(height: 2),
                                          Text(
                                            '${song.artist} • ${song.album}',
                                            maxLines: 1,
                                            overflow: TextOverflow.ellipsis,
                                            style: TextStyle(
                                              fontSize: 12,
                                              color: textDark,
                                            ),
                                          ),
                                        ],
                                      ),
                                    ),
                                    SongOptionsMenuButton(
                                      iconSize: 20,
                                      onOptionSelected: (option) =>
                                          _handleDetailSongOption(song, option),
                                    ),
                                  ],
                                ),
                              ),
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

  Future<void> _handleDetailSongOption(
      LocalSongItem song, SongOption option) async {
    switch (option) {
      case SongOption.queue:
        if (widget.onQueueTrack != null) {
          widget.onQueueTrack!(TrackInfo(
            videoId: song.path,
            title: song.title,
            artist: song.artist,
          ));
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Added "${song.title}" to Queue')),
          );
        }
        break;
      case SongOption.addToPlaylist:
        await _showAddToPlaylistForSong(song);
        break;
      case SongOption.info:
        final file = File(song.path);
        final fileInfo = await AudioFileInspector.inspect(song.path);
        Duration d = Duration.zero;
        Uint8List? art;
        try {
          final meta = amr.readMetadata(file, getImage: true);
          if (meta.duration != null) d = meta.duration!;
          if (meta.pictures.isNotEmpty) art = meta.pictures.first.bytes;
        } catch (_) {}
        await MusicInfoDialog.show(
          context,
          title: song.title,
          artist: song.artist,
          album: song.album,
          genre: song.genre,
          albumArt: art,
          sourceType: 'local',
          videoId: song.path,
          codec: fileInfo.codec,
          sampleRate: fileInfo.formattedSampleRate,
          channels: fileInfo.formattedChannels,
          bitDepth: fileInfo.formattedBitDepth,
          fileSizeBytes: song.sizeBytes,
          duration: d,
          onSaveTags: ({
            required String title,
            required String artist,
            required String album,
            required String genre,
            required String year,
            required String trackNumber,
          }) async {
            setState(() {
              final idx = _groupSongs.indexWhere((s) => s.path == song.path);
              if (idx != -1) {
                _groupSongs[idx] = LocalSongItem.fallback(
                  song.path,
                  song.sizeBytes,
                  song.lastModified,
                  title: title.isNotEmpty ? title : song.title,
                  artist: artist.isNotEmpty ? artist : song.artist,
                  album: album.isNotEmpty ? album : song.album,
                  genre: genre.isNotEmpty ? genre : song.genre,
                  fileHash: song.fileHash,
                );
              }
            });
            if (mounted) {
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(
                    content: Text(
                        'Saved tags for "${title.isNotEmpty ? title : song.title}"')),
              );
            }
          },
        );
        break;
      case SongOption.share:
        try {
          await Share.shareXFiles([XFile(song.path)], text: song.title);
        } catch (e) {
          if (!mounted) return;
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Could not share: $e')),
          );
        }
        break;
      case SongOption.delete:
        final confirm = await showDialog<bool>(
          context: context,
          builder: (ctx) => AlertDialog(
            backgroundColor: context.cardDark,
            shape:
                RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
            title: Row(
              children: [
                Container(
                  padding: const EdgeInsets.all(8),
                  decoration: BoxDecoration(
                    color: Colors.redAccent.withValues(alpha: 0.15),
                    shape: BoxShape.circle,
                  ),
                  child: const Icon(Icons.delete_forever_rounded,
                      color: Colors.redAccent, size: 24),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    'Delete Song?',
                    style: TextStyle(
                        color: context.textPrimary,
                        fontWeight: FontWeight.bold,
                        fontSize: 18),
                  ),
                ),
              ],
            ),
            content: Text(
              'Are you sure you want to delete "${song.title}"? This action cannot be undone.',
              style: TextStyle(color: context.textMuted, fontSize: 14),
            ),
            actionsPadding:
                const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            actions: [
              OutlinedButton(
                style: OutlinedButton.styleFrom(
                  foregroundColor: context.textMuted,
                  side: BorderSide(
                      color: context.textMuted.withValues(alpha: 0.3)),
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(14)),
                ),
                onPressed: () => Navigator.pop(ctx, false),
                child: const Text('Cancel'),
              ),
              ElevatedButton(
                style: ElevatedButton.styleFrom(
                  backgroundColor: Colors.redAccent,
                  foregroundColor: Colors.white,
                  elevation: 2,
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(14)),
                ),
                onPressed: () => Navigator.pop(ctx, true),
                child: const Text('Delete Permanently',
                    style: TextStyle(fontWeight: FontWeight.bold)),
              ),
            ],
          ),
        );
        if (confirm == true) {
          final result = await FileDeletionHelper.safeDeleteTrackFile(
            song.path,
            context: context,
            player: widget.player,
            onBeforeDelete: (path) async {
              widget.onDeleteTrack?.call(path);
            },
          );
          if (!mounted) return;
          if (result.success) {
            setState(() {
              _groupSongs.removeWhere((s) => s.path == song.path);
            });
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(content: Text('Deleted "${song.title}" permanently.')),
            );
          } else {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(
                content: Text(result.errorMessage ?? 'Failed to delete track.'),
                backgroundColor: Colors.redAccent.shade700,
                duration: const Duration(seconds: 4),
              ),
            );
          }
        }
        break;
    }
  }

  Future<void> _showAddToPlaylistForSong(LocalSongItem song) async {
    final playlists = await M3uPlaylistService.instance.loadPlaylists();
    if (!mounted) return;

    final primaryColor = context.primaryColor;
    final textPrimary = context.textPrimary;
    final textDark = context.textMuted;
    final cardDark = context.cardDark;
    final isMobile = MediaQuery.of(context).size.width < 600;

    final sheetContent = Material(
      color: Colors.transparent,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxHeight: 450),
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding:
                    const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                child: Row(
                  children: [
                    Icon(Icons.playlist_add_rounded,
                        color: primaryColor, size: 24),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        'Add "${song.title}" to Playlist',
                        style: TextStyle(
                          color: textPrimary,
                          fontSize: 16,
                          fontWeight: FontWeight.bold,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ],
                ),
              ),
              Divider(height: 1, color: Colors.white.withValues(alpha: 0.1)),
              const SizedBox(height: 6),
              // Create New Playlist Option
              Padding(
                padding:
                    const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
                child: Material(
                  color: primaryColor.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(14),
                  child: InkWell(
                    borderRadius: BorderRadius.circular(14),
                    onTap: () async {
                      Navigator.of(context).pop();
                      final controller = TextEditingController(
                        text: 'My Playlist ${playlists.length + 1}',
                      );
                      final confirm = await M3EDialog.show<bool>(
                        context,
                        dialog: M3EDialog(
                          title: 'Create Playlist',
                          topDivider: true,
                          bottomDivider: true,
                          content: Material(
                            color: Colors.transparent,
                            child: TextField(
                              controller: controller,
                              autofocus: true,
                              style: TextStyle(color: textPrimary),
                              decoration: InputDecoration(
                                labelText: 'Playlist Name',
                                labelStyle: TextStyle(color: textDark),
                                filled: true,
                                fillColor: cardDark,
                                border: OutlineInputBorder(
                                  borderRadius: BorderRadius.circular(12),
                                  borderSide: BorderSide.none,
                                ),
                              ),
                            ),
                          ),
                          actions: [
                            M3EButton(
                              onPressed: () => Navigator.of(context).pop(false),
                              child: const Text('Cancel'),
                            ),
                            M3EButton(
                              onPressed: () => Navigator.of(context).pop(true),
                              child: const Text('Create'),
                            ),
                          ],
                        ),
                      );

                      if (confirm == true &&
                          controller.text.trim().isNotEmpty) {
                        final pl =
                            await M3uPlaylistService.instance.createPlaylist(
                          name: controller.text.trim(),
                          tracks: [song],
                        );
                        if (mounted) {
                          ScaffoldMessenger.of(context).showSnackBar(
                            SnackBar(
                              content: Text(
                                  'Created playlist "${pl.name}" with "${song.title}"'),
                            ),
                          );
                        }
                      }
                    },
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 14, vertical: 12),
                      child: Row(
                        children: [
                          Container(
                            width: 40,
                            height: 40,
                            decoration: BoxDecoration(
                              color: primaryColor.withValues(alpha: 0.2),
                              borderRadius: BorderRadius.circular(10),
                            ),
                            child: Icon(Icons.add_rounded,
                                color: primaryColor, size: 24),
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  'New Playlist',
                                  style: TextStyle(
                                    color: textPrimary,
                                    fontWeight: FontWeight.bold,
                                    fontSize: 15,
                                  ),
                                ),
                                const SizedBox(height: 2),
                                Text(
                                  'Create a new playlist with this track',
                                  style:
                                      TextStyle(color: textDark, fontSize: 12),
                                ),
                              ],
                            ),
                          ),
                          Icon(Icons.arrow_forward_ios_rounded,
                              color: primaryColor, size: 16),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
              if (playlists.isNotEmpty) ...[
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 12, 16, 6),
                  child: Text(
                    'EXISTING PLAYLISTS',
                    style: TextStyle(
                      color: textDark.withValues(alpha: 0.8),
                      fontSize: 11,
                      fontWeight: FontWeight.bold,
                      letterSpacing: 1.0,
                    ),
                  ),
                ),
                ...List.generate(playlists.length, (idx) {
                  final pl = playlists[idx];
                  return Padding(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 12, vertical: 3),
                    child: Material(
                      color: cardDark,
                      borderRadius: BorderRadius.circular(12),
                      child: InkWell(
                        borderRadius: BorderRadius.circular(12),
                        onTap: () async {
                          Navigator.of(context).pop();
                          final updated = await M3uPlaylistService.instance
                              .addTracksToPlaylist(
                            playlistId: pl.id,
                            tracks: [song],
                          );
                          if (updated != null && mounted) {
                            ScaffoldMessenger.of(context).showSnackBar(
                              SnackBar(
                                content: Text(
                                    'Added "${song.title}" to "${pl.name}"'),
                                duration: const Duration(seconds: 2),
                              ),
                            );
                          }
                        },
                        child: Padding(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 14, vertical: 10),
                          child: Row(
                            children: [
                              Container(
                                width: 38,
                                height: 38,
                                decoration: BoxDecoration(
                                  color: primaryColor.withValues(alpha: 0.15),
                                  borderRadius: BorderRadius.circular(9),
                                ),
                                child: Icon(
                                  Icons.queue_music_rounded,
                                  color: primaryColor,
                                  size: 20,
                                ),
                              ),
                              const SizedBox(width: 12),
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                      pl.name,
                                      style: TextStyle(
                                        color: textPrimary,
                                        fontWeight: FontWeight.w600,
                                        fontSize: 14,
                                      ),
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                    ),
                                    const SizedBox(height: 2),
                                    Text(
                                      '${pl.tracks.length} track${pl.tracks.length == 1 ? '' : 's'}',
                                      style: TextStyle(
                                          color: textDark, fontSize: 12),
                                    ),
                                  ],
                                ),
                              ),
                              Icon(Icons.add_circle_outline_rounded,
                                  color: primaryColor, size: 22),
                            ],
                          ),
                        ),
                      ),
                    ),
                  );
                }),
                const SizedBox(height: 12),
              ],
            ],
          ),
        ),
      ),
    );

    if (isMobile) {
      await M3EBottomSheet.show<void>(
        context,
        builder: (ctx) => SafeArea(
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 8),
            child: sheetContent,
          ),
        ),
      );
    } else {
      await M3EDialog.show<void>(
        context,
        dialog: M3EDialog(
          title: 'Add to Playlist',
          topDivider: true,
          bottomDivider: true,
          content: SizedBox(
            width: 440,
            child: sheetContent,
          ),
          actions: [
            M3EButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('Cancel'),
            ),
          ],
        ),
      );
    }
  }
}

class LocalArtistDetailScreen extends LocalGroupDetailScreen {
  const LocalArtistDetailScreen({
    super.key,
    required String artistName,
    required super.songs,
    required super.onPlayFolder,
    super.onPlayTracks,
    super.onQueueTrack,
    super.onDeleteTrack,
  }) : super(
          groupTitle: artistName,
          groupType: 'Artist',
        );
}
