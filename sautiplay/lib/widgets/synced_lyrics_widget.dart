import 'package:flutter/material.dart';

class LrcLine {
  final Duration time;
  final String text;

  const LrcLine({required this.time, required this.text});

  @override
  String toString() =>
      '[${time.inMinutes.remainder(60).toString().padLeft(2, '0')}:${(time.inSeconds % 60).toString().padLeft(2, '0')}.${((time.inMilliseconds % 1000) ~/ 10).toString().padLeft(2, '0')}] $text';
}

class LrcParser {
  static List<LrcLine> parse(String content) {
    if (content.trim().isEmpty) return [];

    final lines = <LrcLine>[];
    final tagRegex = RegExp(r'\[(\d+):(\d+)(?:[\.\:](\d+))?\]');

    for (final rawLine in content.split('\n')) {
      final line = rawLine.trim();
      if (line.isEmpty) continue;

      final allMatches = tagRegex.allMatches(line).toList();
      if (allMatches.isNotEmpty) {
        // Extract text by removing all timestamp tags
        final text = line.replaceAll(tagRegex, '').trim();

        for (final match in allMatches) {
          final minutes = int.parse(match.group(1)!);
          final seconds = int.parse(match.group(2)!);
          final subStr = match.group(3) ?? '0';

          int millis = 0;
          if (subStr.length == 1) {
            millis = int.parse(subStr) * 100;
          } else if (subStr.length == 2) {
            millis = int.parse(subStr) * 10;
          } else if (subStr.length >= 3) {
            millis = int.parse(subStr.substring(0, 3));
          }

          final dur = Duration(
            minutes: minutes,
            seconds: seconds,
            milliseconds: millis,
          );

          lines.add(LrcLine(time: dur, text: text.isNotEmpty ? text : '♪'));
        }
      }
    }

    lines.sort((a, b) => a.time.compareTo(b.time));
    return lines;
  }
}

class SyncedLyricsWidget extends StatefulWidget {
  final String lyricsRaw;
  final Duration currentPosition;
  final ValueChanged<Duration>? onSeek;
  final VoidCallback? onImportLrc;
  final VoidCallback? onRetryFetch;
  final double fontSize;
  final Color activeColor;
  final Color inactiveColor;

  const SyncedLyricsWidget({
    super.key,
    required this.lyricsRaw,
    required this.currentPosition,
    this.onSeek,
    this.onImportLrc,
    this.onRetryFetch,
    this.fontSize = 16.0,
    this.activeColor = const Color(0xFF38BDF8),
    this.inactiveColor = Colors.white60,
  });

  @override
  State<SyncedLyricsWidget> createState() => _SyncedLyricsWidgetState();
}

class _SyncedLyricsWidgetState extends State<SyncedLyricsWidget> {
  final ScrollController _scrollController = ScrollController();
  List<LrcLine> _lines = [];
  int _lastActiveIndex = -1;

  @override
  void initState() {
    super.initState();
    _parseLyrics();
  }

  @override
  void didUpdateWidget(covariant SyncedLyricsWidget oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.lyricsRaw != widget.lyricsRaw) {
      _parseLyrics();
    } else {
      _updateActiveIndex();
    }
  }

  void _parseLyrics() {
    _lines = LrcParser.parse(widget.lyricsRaw);
    _lastActiveIndex = -1;
    _updateActiveIndex();
  }

  static const double _kLineHeight = 52.0;

  void _updateActiveIndex() {
    if (_lines.isEmpty) return;
    int active = -1;
    final posMs = widget.currentPosition.inMilliseconds;
    for (int i = 0; i < _lines.length; i++) {
      if (posMs >= _lines[i].time.inMilliseconds) {
        active = i;
      } else {
        break;
      }
    }

    if (active != _lastActiveIndex) {
      _lastActiveIndex = active;
      if (active >= 0 && _scrollController.hasClients) {
        final targetOffset = active * _kLineHeight;
        _scrollController.animateTo(
          targetOffset.clamp(0.0, _scrollController.position.maxScrollExtent),
          duration: const Duration(milliseconds: 350),
          curve: Curves.easeOutCubic,
        );
      }
    }
  }

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_lines.isEmpty) {
      if (widget.lyricsRaw.trim().isNotEmpty) {
        return Center(
          child: Padding(
            padding:
                const EdgeInsets.symmetric(horizontal: 24.0, vertical: 16.0),
            child: SingleChildScrollView(
              physics: const BouncingScrollPhysics(),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    widget.lyricsRaw.trim(),
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      color: widget.inactiveColor,
                      fontSize: widget.fontSize,
                      height: 1.6,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                  if (widget.onImportLrc != null) ...[
                    const SizedBox(height: 20),
                    OutlinedButton.icon(
                      onPressed: widget.onImportLrc,
                      icon: const Icon(Icons.file_upload_outlined, size: 16),
                      label: const Text('Import Timed .lrc File',
                          style: TextStyle(fontSize: 12)),
                      style: OutlinedButton.styleFrom(
                        foregroundColor: widget.activeColor,
                        side: BorderSide(
                            color: widget.activeColor.withValues(alpha: 0.5)),
                        shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(16)),
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),
        );
      }

      // Empty lyrics state
      return Center(
        child: SingleChildScrollView(
          physics: const BouncingScrollPhysics(),
          padding: const EdgeInsets.symmetric(horizontal: 16.0, vertical: 12.0),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: widget.activeColor.withValues(alpha: 0.12),
                  shape: BoxShape.circle,
                ),
                child: Icon(
                  Icons.lyrics_outlined,
                  size: 24,
                  color: widget.activeColor,
                ),
              ),
              const SizedBox(height: 8),
              Text(
                'No Lyrics Available',
                style: TextStyle(
                  color: Colors.white.withValues(alpha: 0.9),
                  fontSize: 14,
                  fontWeight: FontWeight.bold,
                ),
              ),
              const SizedBox(height: 4),
              Text(
                'Import a .lrc/.txt file or fetch online',
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: widget.inactiveColor,
                  fontSize: 11,
                ),
              ),
              const SizedBox(height: 12),
              Wrap(
                spacing: 8,
                runSpacing: 6,
                alignment: WrapAlignment.center,
                children: [
                  if (widget.onImportLrc != null)
                    ElevatedButton.icon(
                      onPressed: widget.onImportLrc,
                      icon: const Icon(Icons.add, size: 14),
                      label: const Text('Import .lrc / .txt',
                          style: TextStyle(fontSize: 11)),
                      style: ElevatedButton.styleFrom(
                        backgroundColor:
                            widget.activeColor.withValues(alpha: 0.2),
                        foregroundColor: widget.activeColor,
                        padding: const EdgeInsets.symmetric(
                            horizontal: 10, vertical: 6),
                        elevation: 0,
                        shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(14)),
                      ),
                    ),
                  if (widget.onRetryFetch != null)
                    OutlinedButton.icon(
                      onPressed: widget.onRetryFetch,
                      icon: const Icon(Icons.refresh_rounded, size: 14),
                      label: const Text('Search Online',
                          style: TextStyle(fontSize: 11)),
                      style: OutlinedButton.styleFrom(
                        foregroundColor: Colors.white70,
                        padding: const EdgeInsets.symmetric(
                            horizontal: 10, vertical: 6),
                        side: BorderSide(
                            color: Colors.white.withValues(alpha: 0.2)),
                        shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(14)),
                      ),
                    ),
                ],
              ),
            ],
          ),
        ),
      );
    }

    return LayoutBuilder(
      builder: (context, constraints) {
        final viewportHeight = constraints.maxHeight;
        final verticalPadding = (viewportHeight / 2.0) - (_kLineHeight / 2.0);

        return ListView.builder(
          controller: _scrollController,
          physics: const BouncingScrollPhysics(),
          padding: EdgeInsets.symmetric(
            vertical: verticalPadding > 0 ? verticalPadding : 60.0,
            horizontal: 16.0,
          ),
          itemCount: _lines.length,
          itemExtent: _kLineHeight,
          itemBuilder: (context, index) {
            final line = _lines[index];
            final isActive = index == _lastActiveIndex;

            return GestureDetector(
              onTap: () {
                widget.onSeek?.call(line.time);
              },
              child: Container(
                height: _kLineHeight,
                padding:
                    const EdgeInsets.symmetric(vertical: 4, horizontal: 12),
                alignment: Alignment.center,
                child: AnimatedDefaultTextStyle(
                  duration: const Duration(milliseconds: 250),
                  style: TextStyle(
                    fontSize:
                        isActive ? widget.fontSize + 1.0 : widget.fontSize,
                    fontWeight: isActive ? FontWeight.bold : FontWeight.w500,
                    color: isActive ? widget.activeColor : widget.inactiveColor,
                    height: 1.3,
                    shadows: isActive
                        ? [
                            Shadow(
                              color: widget.activeColor.withValues(alpha: 0.7),
                              blurRadius: 14,
                            ),
                          ]
                        : null,
                  ),
                  child: Text(
                    line.text,
                    textAlign: TextAlign.center,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ),
            );
          },
        );
      },
    );
  }
}
