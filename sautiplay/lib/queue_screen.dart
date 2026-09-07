import 'dart:typed_data';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:material_3_expressive/material_3_expressive.dart';
import 'package:flutter_m3shapes_extended/flutter_m3shapes_extended.dart';
import 'package:mini_music_visualizer/mini_music_visualizer.dart';
import 'package:sautiflow/sautiflow.dart';
import 'album_detail_screen.dart'; // For TrackInfo
import 'services/app_theme_service.dart';
import 'widgets/local_album_art.dart';
import 'widgets/music_info_dialog.dart';

class QueueScreen extends StatefulWidget {
  final List<TrackInfo> queue;
  final String? videoId;
  final Uint8List? albumArt;
  final void Function(int) onPlayQueueIndex;
  final void Function(int, int) onReorderQueue;
  final void Function(int)? onRemoveFromQueue;
  final VoidCallback? onClearQueue;
  final VoidCallback? onShuffleQueue;
  final ValueNotifier<PlayerStatus>? statusNotifier;
  final VoidCallback? onClose;

  const QueueScreen({
    super.key,
    required this.queue,
    this.videoId,
    this.albumArt,
    required this.onPlayQueueIndex,
    required this.onReorderQueue,
    this.onRemoveFromQueue,
    this.onClearQueue,
    this.onShuffleQueue,
    this.statusNotifier,
    this.onClose,
  });

  @override
  State<QueueScreen> createState() => _QueueScreenState();
}

class _QueueScreenState extends State<QueueScreen>
    with AutomaticKeepAliveClientMixin {
  @override
  bool get wantKeepAlive => true;
  late ScrollController _scrollController;
  int? _lastPlayingIndex;
  bool _hasInitialScrolled = false;
  bool _showUpcomingOnly = false;
  bool _showScrollHelper = false;
  int _currentScrollItemIndex = 0;

  int _lastTapTimeMs = 0;

  void _handleTrackTap(int actualIndex) {
    final now = DateTime.now().millisecondsSinceEpoch;
    if (now - _lastTapTimeMs < 300) {
      return; // Debounce rapid taps during scrolling
    }
    _lastTapTimeMs = now;
    widget.onPlayQueueIndex(actualIndex);
  }

  @override
  void initState() {
    super.initState();
    _scrollController = ScrollController();
    _scrollController.addListener(_onScroll);
    _lastPlayingIndex = _getPlayingIndex(widget.statusNotifier?.value);
    widget.statusNotifier?.addListener(_onStatusChanged);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_hasInitialScrolled) {
        _scrollToPlayingItem(animate: false);
        _hasInitialScrolled = true;
      }
    });
  }

  void _onScroll() {
    if (!_scrollController.hasClients) return;
    final playingIndex = _getPlayingIndex(widget.statusNotifier?.value);
    const itemHeight = 67.0;
    final currentOffset = _scrollController.offset;
    final visibleIndex = (currentOffset / itemHeight).floor();

    if (visibleIndex != _currentScrollItemIndex) {
      _currentScrollItemIndex = visibleIndex;
    }

    // Show jump-to-playing helper if user has scrolled away from the currently playing item
    final isScrolledAway =
        playingIndex >= 0 && (visibleIndex - playingIndex).abs() > 4;
    if (_showScrollHelper != isScrolledAway) {
      setState(() => _showScrollHelper = isScrolledAway);
    }
  }

  @override
  void didUpdateWidget(QueueScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.statusNotifier != widget.statusNotifier) {
      oldWidget.statusNotifier?.removeListener(_onStatusChanged);
      widget.statusNotifier?.addListener(_onStatusChanged);
    }
    if (oldWidget.videoId != widget.videoId ||
        oldWidget.queue != widget.queue) {
      final newIndex = _getPlayingIndex(widget.statusNotifier?.value);
      if (_lastPlayingIndex != newIndex) {
        _lastPlayingIndex = newIndex;
        WidgetsBinding.instance.addPostFrameCallback((_) {
          _scrollToPlayingItem(animate: true);
        });
      }
    }
  }

  @override
  void dispose() {
    _scrollController.removeListener(_onScroll);
    widget.statusNotifier?.removeListener(_onStatusChanged);
    _scrollController.dispose();
    super.dispose();
  }

  void _onStatusChanged() {
    if (!mounted) return;
    final newIndex = _getPlayingIndex(widget.statusNotifier?.value);

    // Performance optimization: Avoid rebuilding the queue screen on playback position ticks.
    // Only update state if the current playing index actually changed.
    if (_lastPlayingIndex == newIndex) {
      return;
    }

    _lastPlayingIndex = newIndex;
    setState(() {});

    _scrollToPlayingItem(animate: true);
  }

  int _getPlayingIndex(PlayerStatus? status) {
    if (widget.queue.isEmpty) return -1;
    if (status != null && status.currentIndex >= 0) {
      if (status.currentIndex < widget.queue.length) {
        return status.currentIndex;
      }
    }
    if (widget.videoId != null) {
      final index =
          widget.queue.indexWhere((track) => track.videoId == widget.videoId);
      if (index >= 0) return index;
    }
    return -1;
  }

  void _scrollToPlayingItem({bool animate = true}) {
    if (!_scrollController.hasClients || widget.queue.isEmpty) return;

    final playingIndex = _getPlayingIndex(widget.statusNotifier?.value);
    if (playingIndex < 0) return;

    // Fixed item height (card 64.0 + 3.0 margin)
    const itemHeight = 67.0;
    if (!_scrollController.position.hasContentDimensions) return;

    final viewportHeight = _scrollController.position.viewportDimension;
    final targetOffset = ((playingIndex * itemHeight) -
            (viewportHeight / 2) +
            (itemHeight / 2))
        .clamp(
      0.0,
      _scrollController.position.maxScrollExtent,
    );

    if (animate) {
      _scrollController.animateTo(
        targetOffset,
        duration: const Duration(milliseconds: 350),
        curve: Curves.easeOutCubic,
      );
    } else {
      _scrollController.jumpTo(targetOffset);
    }
  }

  String _formatDuration(int? durationSeconds) {
    if (durationSeconds == null || durationSeconds <= 0) return '';
    final minutes = durationSeconds ~/ 60;
    final seconds = durationSeconds % 60;
    return '$minutes:${seconds.toString().padLeft(2, '0')}';
  }

  void _confirmClearQueue(BuildContext context) {
    M3EDialog.show<void>(
      context,
      dialog: M3EDialog(
        title: 'Clear Playback Queue',
        content: const Text(
          'Are you sure you want to clear all tracks from your current playback queue?',
        ),
        actions: [
          M3EButton.text(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Cancel'),
          ),
          M3EButton(
            onPressed: () {
              Navigator.of(context).pop();
              if (widget.onClearQueue != null) {
                widget.onClearQueue!();
              }
            },
            child: const Text('Clear All'),
          ),
        ],
      ),
    );
  }

  void _showTrackInfo(BuildContext context, TrackInfo track) {
    final isLocal = track.videoId.contains('/') ||
        track.videoId.contains('\\') ||
        track.videoId.endsWith('.mp3') ||
        track.videoId.endsWith('.flac') ||
        track.videoId.endsWith('.m4a');

    MusicInfoDialog.show(
      context,
      title: track.title,
      artist: track.artist,
      sourceType: isLocal ? 'local' : 'online',
      videoId: track.videoId,
      duration: Duration(seconds: track.durationSeconds ?? 0),
    );
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final Color primaryColor = context.primaryColor;
    final Color bgColor = context.bgDark;
    final Color textPrimary = context.textPrimary;
    final Color textDark = context.textMuted;
    final Color outlineColor = context.outlineColor;

    final playingIndex = _getPlayingIndex(widget.statusNotifier?.value);
    final itemCount = _showUpcomingOnly && playingIndex >= 0
        ? (widget.queue.length - playingIndex)
        : widget.queue.length;

    return Scaffold(
      backgroundColor: bgColor,
      body: Column(
        children: [
          // Expressive Material 3 Top Header
          Container(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
            decoration: BoxDecoration(
              color: bgColor,
              border: Border(
                bottom: BorderSide(
                  color: outlineColor.withValues(alpha: 0.15),
                  width: 1,
                ),
              ),
            ),
            child: Row(
              children: [
                if (widget.onClose != null)
                  M3EIconButton(
                    icon:
                        const Icon(Icons.keyboard_arrow_down_rounded, size: 28),
                    variant: M3EIconButtonVariant.standard,
                    tooltip: 'Minimize Queue',
                    onPressed: widget.onClose,
                  )
                else
                  const Icon(Icons.queue_music_rounded, size: 24),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Up Next Queue',
                        style: TextStyle(
                          color: textPrimary,
                          fontSize: 18,
                          fontWeight: FontWeight.bold,
                          letterSpacing: -0.3,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        '${widget.queue.length} ${widget.queue.length == 1 ? 'track' : 'tracks'}',
                        style: TextStyle(
                          color: textDark,
                          fontSize: 12.5,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),

          // Expressive Filter / Action Toolbar
          if (widget.queue.isNotEmpty)
            Padding(
              padding:
                  const EdgeInsets.symmetric(horizontal: 16.0, vertical: 10.0),
              child: SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                physics: const BouncingScrollPhysics(),
                child: Row(
                  children: [
                    M3EChip(
                      label: _showUpcomingOnly ? 'Upcoming Only' : 'Show All',
                      leading: Icon(
                        _showUpcomingOnly
                            ? Icons.filter_list_rounded
                            : Icons.format_list_bulleted_rounded,
                        size: 16,
                      ),
                      selected: _showUpcomingOnly,
                      onPressed: () {
                        setState(() => _showUpcomingOnly = !_showUpcomingOnly);
                      },
                    ),
                    if (playingIndex >= 0) ...[
                      const SizedBox(width: 8),
                      M3EChip(
                        label: 'Playing #${playingIndex + 1}',
                        leading:
                            const Icon(Icons.my_location_rounded, size: 16),
                        onPressed: () => _scrollToPlayingItem(animate: true),
                      ),
                    ],
                    if (widget.onShuffleQueue != null) ...[
                      const SizedBox(width: 8),
                      M3EChip(
                        label: 'Shuffle',
                        leading: const Icon(Icons.shuffle_rounded, size: 16),
                        onPressed: widget.onShuffleQueue,
                      ),
                    ],
                    if (widget.onClearQueue != null ||
                        widget.onRemoveFromQueue != null) ...[
                      const SizedBox(width: 8),
                      M3EChip(
                        label: 'Clear',
                        leading: const Icon(Icons.clear_all_rounded, size: 16),
                        onPressed: () => _confirmClearQueue(context),
                      ),
                    ],
                  ],
                ),
              ),
            ),

          // Main Playback Queue Content
          Expanded(
            child: widget.queue.isEmpty
                ? Center(
                    child: Padding(
                      padding: const EdgeInsets.all(32.0),
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Container(
                            width: 96,
                            height: 96,
                            decoration: BoxDecoration(
                              color: primaryColor.withValues(alpha: 0.12),
                              borderRadius: BorderRadius.circular(24),
                              border: Border.all(
                                color: primaryColor.withValues(alpha: 0.3),
                                width: 1.5,
                              ),
                            ),
                            child: Center(
                              child: Icon(Icons.queue_music_rounded,
                                  color: primaryColor, size: 44),
                            ),
                          ),
                          const SizedBox(height: 20),
                          Text(
                            'Queue is empty',
                            style: TextStyle(
                              color: textPrimary,
                              fontSize: 18,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                          const SizedBox(height: 6),
                          Text(
                            'Play a track or album to populate the playback queue',
                            style: TextStyle(
                              color: textDark,
                              fontSize: 13.5,
                            ),
                            textAlign: TextAlign.center,
                          ),
                        ],
                      ),
                    ),
                  )
                : Stack(
                    children: [
                      Scrollbar(
                        controller: _scrollController,
                        thumbVisibility: true,
                        interactive: true,
                        thickness: 6.0,
                        radius: const Radius.circular(8),
                        child: ListView.builder(
                          controller: _scrollController,
                          itemExtent: 67.0,
                          cacheExtent: 120.0,
                          addAutomaticKeepAlives: false,
                          addRepaintBoundaries: true,
                          physics: const BouncingScrollPhysics(
                              parent: AlwaysScrollableScrollPhysics()),
                          padding: const EdgeInsets.symmetric(horizontal: 12.0)
                              .copyWith(bottom: 140),
                          itemCount: itemCount,
                    itemBuilder: (context, index) {
                      final actualIndex = _showUpcomingOnly && playingIndex >= 0
                          ? index + playingIndex
                          : index;
                      final track = widget.queue[actualIndex];
                      final isPlaying = (playingIndex == actualIndex) ||
                          (widget.videoId != null &&
                              track.videoId == widget.videoId);

                      final isFirst = index == 0;
                      final isLast = index == itemCount - 1;

                      final borderRadius = BorderRadius.only(
                        topLeft: Radius.circular(isFirst ? 20 : 6),
                        topRight: Radius.circular(isFirst ? 20 : 6),
                        bottomLeft: Radius.circular(isLast ? 20 : 6),
                        bottomRight: Radius.circular(isLast ? 20 : 6),
                      );

                      final itemKey = ValueKey(
                          '${track.videoId}_${actualIndex}_${widget.queue.length}');

                      return Padding(
                        padding: const EdgeInsets.only(bottom: 3.0),
                        child: Dismissible(
                          key: itemKey,
                          direction: widget.onRemoveFromQueue != null
                              ? DismissDirection.horizontal
                              : DismissDirection.none,
                          dragStartBehavior: DragStartBehavior.down,
                          dismissThresholds: const {
                            DismissDirection.startToEnd: 0.5,
                            DismissDirection.endToStart: 0.5,
                          },
                          movementDuration: const Duration(milliseconds: 200),
                          onDismissed: (_) {
                            if (widget.onRemoveFromQueue != null) {
                              widget.onRemoveFromQueue!(actualIndex);
                            }
                          },
                          background: Container(
                            alignment: Alignment.centerLeft,
                            padding: const EdgeInsets.symmetric(horizontal: 20),
                            decoration: BoxDecoration(
                              color:
                                  Theme.of(context).colorScheme.errorContainer,
                              borderRadius: borderRadius,
                            ),
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Icon(Icons.delete_outline_rounded,
                                    color: Theme.of(context)
                                        .colorScheme
                                        .onErrorContainer),
                                const SizedBox(width: 8),
                                Text(
                                  'Remove',
                                  style: TextStyle(
                                    color: Theme.of(context)
                                        .colorScheme
                                        .onErrorContainer,
                                    fontWeight: FontWeight.bold,
                                  ),
                                ),
                              ],
                            ),
                          ),
                          secondaryBackground: Container(
                            alignment: Alignment.centerRight,
                            padding: const EdgeInsets.symmetric(horizontal: 20),
                            decoration: BoxDecoration(
                              color:
                                  Theme.of(context).colorScheme.errorContainer,
                              borderRadius: borderRadius,
                            ),
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Text(
                                  'Remove',
                                  style: TextStyle(
                                    color: Theme.of(context)
                                        .colorScheme
                                        .onErrorContainer,
                                    fontWeight: FontWeight.bold,
                                  ),
                                ),
                                const SizedBox(width: 8),
                                Icon(Icons.delete_outline_rounded,
                                    color: Theme.of(context)
                                        .colorScheme
                                        .onErrorContainer),
                              ],
                            ),
                          ),
                          child: Material(
                            color: isPlaying
                                ? primaryColor.withValues(alpha: 0.14)
                                : context.cardDark,
                            shape: RoundedRectangleBorder(
                              borderRadius: borderRadius,
                              side: BorderSide(
                                color: isPlaying
                                    ? primaryColor.withValues(alpha: 0.45)
                                    : outlineColor.withValues(alpha: 0.12),
                                width: isPlaying ? 1.5 : 1.0,
                              ),
                            ),
                            clipBehavior: Clip.antiAlias,
                            child: InkWell(
                              onTap: () => _handleTrackTap(actualIndex),
                              onLongPress: () => _showTrackInfo(context, track),
                              child: Padding(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 14,
                                  vertical: 10,
                                ),
                                child: Row(
                                  children: [
                                    SizedBox(
                                      width: 22,
                                      child: Text(
                                        '${actualIndex + 1}',
                                        textAlign: TextAlign.center,
                                        style: TextStyle(
                                          color: isPlaying
                                              ? primaryColor
                                              : textDark,
                                          fontSize: 12,
                                          fontWeight: isPlaying
                                              ? FontWeight.bold
                                              : FontWeight.w600,
                                        ),
                                      ),
                                    ),
                                    const SizedBox(width: 10),
                                    _QueueTrackArtwork(
                                      track: track,
                                      isPlaying: isPlaying,
                                      albumArt: widget.albumArt,
                                      primaryColor: primaryColor,
                                    ),
                                    const SizedBox(width: 12),
                                    Expanded(
                                      child: Column(
                                        crossAxisAlignment:
                                            CrossAxisAlignment.start,
                                        mainAxisSize: MainAxisSize.min,
                                        children: [
                                          Text(
                                            track.title,
                                            maxLines: 1,
                                            overflow: TextOverflow.ellipsis,
                                            style: TextStyle(
                                              color: isPlaying
                                                  ? primaryColor
                                                  : textPrimary,
                                              fontSize: 14,
                                              fontWeight: isPlaying
                                                  ? FontWeight.bold
                                                  : FontWeight.w500,
                                            ),
                                          ),
                                          const SizedBox(height: 2),
                                          Text(
                                            track.artist,
                                            maxLines: 1,
                                            overflow: TextOverflow.ellipsis,
                                            style: TextStyle(
                                              color: textDark,
                                              fontSize: 12,
                                            ),
                                          ),
                                        ],
                                      ),
                                    ),
                                    const SizedBox(width: 8),
                                    if (track.durationSeconds != null &&
                                        track.durationSeconds! > 0)
                                      Padding(
                                        padding:
                                            const EdgeInsets.only(right: 6.0),
                                        child: Text(
                                          _formatDuration(
                                              track.durationSeconds),
                                          style: TextStyle(
                                            color: Colors.white
                                                .withValues(alpha: 0.35),
                                            fontSize: 11.5,
                                            fontWeight: FontWeight.w500,
                                          ),
                                        ),
                                      ),
                                    Row(
                                      mainAxisSize: MainAxisSize.min,
                                      children: [
                                        IconButton(
                                          icon: const Icon(
                                            Icons.vertical_align_top_rounded,
                                            size: 18,
                                          ),
                                          visualDensity: VisualDensity.compact,
                                          padding: const EdgeInsets.all(4),
                                          constraints: const BoxConstraints(
                                            minWidth: 28,
                                            minHeight: 28,
                                          ),
                                          color: textDark,
                                          tooltip: 'Move to Top',
                                          onPressed: () => widget.onReorderQueue(
                                              actualIndex, 0),
                                        ),
                                        IconButton(
                                          icon: const Icon(
                                            Icons.vertical_align_bottom_rounded,
                                            size: 18,
                                          ),
                                          visualDensity: VisualDensity.compact,
                                          padding: const EdgeInsets.all(4),
                                          constraints: const BoxConstraints(
                                            minWidth: 28,
                                            minHeight: 28,
                                          ),
                                          color: textDark,
                                          tooltip: 'Move to Bottom',
                                          onPressed: () => widget.onReorderQueue(
                                            actualIndex,
                                            widget.queue.length,
                                          ),
                                        ),
                                      ],
                                    ),
                                  ],
                                ),
                              ),
                            ),
                          ),
                        ),
                      );
                    },
                  ),
                ),
                // Floating Scroll Helper Dock
                if (playingIndex >= 0)
                  Positioned(
                    bottom: 70,
                    right: 16,
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
                          child: Material(
                            elevation: 6,
                            shadowColor: Colors.black.withValues(alpha: 0.45),
                            color: primaryColor,
                            borderRadius: BorderRadius.circular(24),
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                if (_currentScrollItemIndex > 15) ...[
                                  InkWell(
                                    borderRadius: const BorderRadius.horizontal(
                                      left: Radius.circular(24),
                                    ),
                                    onTap: () {
                                      _scrollController.animateTo(
                                        0,
                                        duration:
                                            const Duration(milliseconds: 350),
                                        curve: Curves.easeOutCubic,
                                      );
                                    },
                                    child: Padding(
                                      padding: const EdgeInsets.fromLTRB(
                                          12, 9, 8, 9),
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
                                          const SizedBox(width: 4),
                                          Text(
                                            'Top',
                                            style: TextStyle(
                                              color: Theme.of(context)
                                                  .colorScheme
                                                  .onPrimary,
                                              fontSize: 12,
                                              fontWeight: FontWeight.w600,
                                            ),
                                          ),
                                        ],
                                      ),
                                    ),
                                  ),
                                  Container(
                                    width: 1,
                                    height: 16,
                                    color: Theme.of(context)
                                        .colorScheme
                                        .onPrimary
                                        .withValues(alpha: 0.25),
                                  ),
                                ],
                                InkWell(
                                  borderRadius: BorderRadius.horizontal(
                                    left: Radius.circular(
                                        _currentScrollItemIndex > 15 ? 0 : 24),
                                    right: const Radius.circular(24),
                                  ),
                                  onTap: () =>
                                      _scrollToPlayingItem(animate: true),
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
                                          'Playing #${playingIndex + 1}',
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
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _QueueTrackArtwork extends StatelessWidget {
  final TrackInfo track;
  final bool isPlaying;
  final Uint8List? albumArt;
  final Color primaryColor;

  const _QueueTrackArtwork({
    required this.track,
    required this.isPlaying,
    this.albumArt,
    required this.primaryColor,
  });

  @override
  Widget build(BuildContext context) {
    final isLocal = track.videoId.contains('/') ||
        track.videoId.contains('\\') ||
        track.videoId.endsWith('.mp3') ||
        track.videoId.endsWith('.flac') ||
        track.videoId.endsWith('.m4a');

    return Container(
      width: 44,
      height: 44,
      decoration: BoxDecoration(
        color: context.cardDark,
        borderRadius: BorderRadius.circular(10),
      ),
      clipBehavior: Clip.antiAlias,
      child: Stack(
        children: [
          if (albumArt != null && isPlaying)
            Image.memory(
              albumArt!,
              width: 44,
              height: 44,
              cacheWidth: 100,
              cacheHeight: 100,
              fit: BoxFit.cover,
            )
          else if (isLocal)
            LocalAlbumArt(
              path: track.videoId,
              size: 44,
              shape: Shapes.pill,
              useM3Shape: false,
            )
          else if (track.thumbnailUrl != null && track.thumbnailUrl!.isNotEmpty)
            CachedNetworkImage(
              imageUrl: track.thumbnailUrl!,
              width: 44,
              height: 44,
              memCacheWidth: 100,
              memCacheHeight: 100,
              fit: BoxFit.cover,
              errorWidget: (_, __, ___) => _fallbackIcon(),
            )
          else
            _fallbackIcon(),
          if (isPlaying)
            RepaintBoundary(
              child: Container(
                color: Colors.black.withValues(alpha: 0.45),
                child: Center(
                  child: MiniMusicVisualizer(
                    color: primaryColor,
                    width: 4,
                    height: 15,
                    radius: 2,
                    animate: true,
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _fallbackIcon() {
    return Container(
      color: Colors.white.withValues(alpha: 0.06),
      child: const Center(
        child: Icon(
          Icons.music_note_rounded,
          color: Colors.white38,
          size: 22,
        ),
      ),
    );
  }
}
