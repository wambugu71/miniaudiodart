import 'dart:async';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:audio_metadata_reader/audio_metadata_reader.dart';
import 'package:flutter_m3shapes_extended/flutter_m3shapes_extended.dart';
import '../services/app_theme_service.dart';

// Bounded in-memory cache to prevent memory ballooning on low-end devices
const int _maxAlbumArtCacheSize = 40;
const int _maxAlbumArtAttemptedSize = 300;
const int _maxDirectoryArtCacheSize = 20;

final Map<String, Uint8List?> _albumArtCache = {};
final Map<String, bool> _albumArtAttempted = {};
final Map<String, Uint8List?> _directoryArtCache = {};
final Map<String, bool> _directoryArtAttempted = {};

// Worker queue management
const int _maxConcurrentExtractions = 2;
int _activeExtractions = 0;
final List<_ArtRequest> _queue = [];
final Map<String, List<Completer<Uint8List?>>> _waitingCompleters = {};

class _ArtRequest {
  final String path;
  final Completer<Uint8List?> completer;
  bool isCancelled = false;

  _ArtRequest(this.path, this.completer);
}

void _cacheAlbumArt(String path, Uint8List? bytes) {
  if (_albumArtCache.length >= _maxAlbumArtCacheSize) {
    _albumArtCache.remove(_albumArtCache.keys.first);
  }
  _albumArtCache[path] = bytes;

  if (_albumArtAttempted.length >= _maxAlbumArtAttemptedSize) {
    _albumArtAttempted.remove(_albumArtAttempted.keys.first);
  }
  _albumArtAttempted[path] = true;
}

void _cacheDirectoryArt(String dirPath, Uint8List? bytes) {
  if (_directoryArtCache.length >= _maxDirectoryArtCacheSize) {
    _directoryArtCache.remove(_directoryArtCache.keys.first);
  }
  _directoryArtCache[dirPath] = bytes;
}

/// Downscales image to thumbnail size (~120x120 px) using Flutter's native decoder.
/// Prevents storing 3-10MB raw bitmaps in RAM.
Future<Uint8List?> _downscaleArtwork(Uint8List? rawBytes, {int targetDimension = 120}) async {
  if (rawBytes == null || rawBytes.isEmpty) return null;
  try {
    final codec = await ui.instantiateImageCodec(
      rawBytes,
      targetWidth: targetDimension,
      targetHeight: targetDimension,
    );
    final frame = await codec.getNextFrame();
    final byteData = await frame.image.toByteData(format: ui.ImageByteFormat.png);
    frame.image.dispose();
    codec.dispose();
    return byteData?.buffer.asUint8List() ?? rawBytes;
  } catch (_) {
    return rawBytes;
  }
}

/// Worker function executed in a background Isolate to prevent UI thread frame drops.
Uint8List? _readRawArtWorker(String path) {
  try {
    final file = File(path);
    if (!file.existsSync()) return null;

    // 1. Try reading embedded ID3 / FLAC / MP4 image
    try {
      final metadata = readMetadata(file, getImage: true);
      if (metadata.pictures.isNotEmpty) {
        return metadata.pictures.first.bytes;
      }
    } catch (_) {}

    // 2. Check parent directory for cover art
    final parentDir = file.parent;
    if (parentDir.existsSync()) {
      try {
        final files = parentDir.listSync(followLinks: false);
        for (final f in files) {
          if (f is File) {
            final lowerPath = f.path.toLowerCase();
            if (lowerPath.endsWith('.jpg') ||
                lowerPath.endsWith('.jpeg') ||
                lowerPath.endsWith('.png') ||
                lowerPath.endsWith('.webp')) {
              return f.readAsBytesSync();
            }
          }
        }
      } catch (_) {}
    }
  } catch (_) {}
  return null;
}

Future<Uint8List?> _extractArtTask(String path) async {
  try {
    final dirPath = File(path).parent.path;
    if (_directoryArtAttempted.containsKey(dirPath)) {
      final cachedDirArt = _directoryArtCache[dirPath];
      if (cachedDirArt != null) return cachedDirArt;
    }

    // Run file I/O and ID3 extraction on background worker isolate
    final rawBytes = await Isolate.run(() => _readRawArtWorker(path));
    if (rawBytes == null) {
      _directoryArtAttempted[dirPath] = true;
      _cacheDirectoryArt(dirPath, null);
      return null;
    }

    // Downscale to thumbnail size on native image decoding pipeline before caching
    final downscaled = await _downscaleArtwork(rawBytes, targetDimension: 120);
    _directoryArtAttempted[dirPath] = true;
    _cacheDirectoryArt(dirPath, downscaled);
    return downscaled;
  } catch (e) {
    debugPrint('[LocalAlbumArt] Failed to read art for $path: $e');
  }
  return null;
}

void _drainQueue() {
  while (_activeExtractions < _maxConcurrentExtractions && _queue.isNotEmpty) {
    final request = _queue.removeAt(0);
    if (request.isCancelled) {
      continue;
    }

    _activeExtractions++;
    _extractArtTask(request.path).then((bytes) {
      _cacheAlbumArt(request.path, bytes);

      if (!request.completer.isCompleted) {
        request.completer.complete(bytes);
      }

      final waiting = _waitingCompleters.remove(request.path);
      if (waiting != null) {
        for (final c in waiting) {
          if (!c.isCompleted) c.complete(bytes);
        }
      }
    }).catchError((e) {
      if (!request.completer.isCompleted) {
        request.completer.complete(null);
      }
      final waiting = _waitingCompleters.remove(request.path);
      if (waiting != null) {
        for (final c in waiting) {
          if (!c.isCompleted) c.complete(null);
        }
      }
    }).whenComplete(() {
      _activeExtractions--;
      _drainQueue();
    });
  }
}

class LocalAlbumArt extends StatefulWidget {
  final String path;
  final double size;
  final double borderRadius;
  final IconData fallbackIcon;
  final Shapes shape;
  final bool useM3Shape;

  const LocalAlbumArt({
    super.key,
    required this.path,
    this.size = 64.0,
    this.borderRadius = 12.0,
    this.fallbackIcon = Icons.music_note,
    this.shape = Shapes.pill,
    this.useM3Shape = false,
  });

  @override
  State<LocalAlbumArt> createState() => _LocalAlbumArtState();
}

class _LocalAlbumArtState extends State<LocalAlbumArt> {
  Uint8List? _imageData;
  bool _isLoading = true;
  bool _hasError = false;
  _ArtRequest? _activeRequest;

  @override
  void initState() {
    super.initState();
    _loadAlbumArt();
  }

  @override
  void didUpdateWidget(LocalAlbumArt oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.path != widget.path) {
      _cancelPendingRequest();
      _loadAlbumArt();
    }
  }

  @override
  void dispose() {
    _cancelPendingRequest();
    super.dispose();
  }

  void _cancelPendingRequest() {
    if (_activeRequest != null) {
      _activeRequest!.isCancelled = true;
      _activeRequest = null;
    }
  }

  void _loadAlbumArt() {
    if (!mounted) return;

    if (_albumArtAttempted.containsKey(widget.path)) {
      final cachedBytes = _albumArtCache[widget.path];
      setState(() {
        _imageData = cachedBytes;
        _isLoading = false;
        _hasError = cachedBytes == null;
      });
      return;
    }

    setState(() {
      _isLoading = true;
      _hasError = false;
      _imageData = null;
    });

    final completer = Completer<Uint8List?>();
    final request = _ArtRequest(widget.path, completer);
    _activeRequest = request;

    if (_waitingCompleters.containsKey(widget.path)) {
      _waitingCompleters[widget.path]!.add(completer);
    } else {
      _waitingCompleters[widget.path] = [];
      _queue.add(request);
      _drainQueue();
    }

    completer.future.then((bytes) {
      if (!mounted || _activeRequest != request) return;
      setState(() {
        _imageData = bytes;
        _isLoading = false;
        _hasError = bytes == null;
      });
    }).catchError((_) {
      if (!mounted || _activeRequest != request) return;
      setState(() {
        _hasError = true;
        _isLoading = false;
      });
    });
  }

  @override
  Widget build(BuildContext context) {
    final themeData = AppThemeProvider.of(context);
    final cardColor = themeData.cardDark;
    final double side = widget.size > 0 ? widget.size : 48.0;
    final double iconSize = (side * 0.5).clamp(14.0, 48.0);

    Widget innerContent;
    if (_isLoading) {
      innerContent = Center(
        child: Icon(
          widget.fallbackIcon,
          color: themeData.textDark.withAlpha(60),
          size: iconSize,
        ),
      );
    } else if (_imageData != null && !_hasError) {
      innerContent = Image.memory(
        _imageData!,
        fit: BoxFit.cover,
        cacheWidth: (side * 2).toInt().clamp(48, 200),
        cacheHeight: (side * 2).toInt().clamp(48, 200),
        errorBuilder: (_, __, ___) => _buildFallback(iconSize, themeData.textDark),
      );
    } else {
      innerContent = _buildFallback(iconSize, themeData.textDark);
    }

    if (widget.useM3Shape) {
      return RepaintBoundary(
        child: M3EContainer(
          widget.shape,
          width: side,
          height: side,
          color: cardColor,
          clipBehavior: Clip.antiAlias,
          child: innerContent,
        ),
      );
    }

    final isCircle = widget.shape == Shapes.circle;
    return RepaintBoundary(
      child: Container(
        width: side,
        height: side,
        decoration: BoxDecoration(
          color: cardColor,
          shape: isCircle ? BoxShape.circle : BoxShape.rectangle,
          borderRadius: isCircle ? null : BorderRadius.circular(widget.borderRadius),
        ),
        clipBehavior: Clip.antiAlias,
        child: innerContent,
      ),
    );
  }

  Widget _buildFallback(double iconSize, Color iconColor) {
    return Center(
      child: Icon(
        widget.fallbackIcon,
        color: iconColor.withAlpha(90),
        size: iconSize,
      ),
    );
  }
}
