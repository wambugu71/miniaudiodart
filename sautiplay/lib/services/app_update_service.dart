import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path_provider/path_provider.dart';
import 'package:url_launcher/url_launcher.dart';

import 'platform_asset_matcher.dart';

enum UpdateStage {
  idle,
  checking,
  available,
  downloading,
  downloaded,
  error,
}

class AppReleaseInfo {
  final String tagName;
  final String version;
  final String name;
  final String body;
  final String htmlUrl;
  final String fileName;
  final String downloadUrl;
  final int sizeBytes;
  final DateTime publishedAt;

  AppReleaseInfo({
    required this.tagName,
    required this.version,
    required this.name,
    required this.body,
    required this.htmlUrl,
    required this.fileName,
    required this.downloadUrl,
    required this.sizeBytes,
    required this.publishedAt,
  });

  String get formattedSize {
    if (sizeBytes <= 0) return '';
    return '${(sizeBytes / (1024 * 1024)).toStringAsFixed(1)} MB';
  }
}

/// Message payload passed to the background download worker isolate.
class _DownloadWorkerParams {
  final SendPort sendPort;
  final String url;
  final String filePath;
  final int existingBytes;
  final int expectedTotal;

  _DownloadWorkerParams({
    required this.sendPort,
    required this.url,
    required this.filePath,
    required this.existingBytes,
    required this.expectedTotal,
  });
}

/// Background Isolate worker function.
/// Handles the network I/O, byte streaming, file writing, and watchdog entirely
/// off the UI thread so high-refresh (120 FPS) rendering and audio playback remain uninterrupted.
void _downloadWorkerEntryPoint(_DownloadWorkerParams params) async {
  final sendPort = params.sendPort;
  http.Client? client;
  IOSink? sink;
  Timer? watchdog;

  try {
    client = http.Client();
    final request = http.Request('GET', Uri.parse(params.url));
    request.headers['User-Agent'] = 'Sautiplay-App';

    if (params.existingBytes > 0) {
      request.headers['Range'] = 'bytes=${params.existingBytes}-';
    }

    final response = await client.send(request).timeout(
      const Duration(seconds: 15),
      onTimeout: () => throw TimeoutException(
          'Server response timed out. Please check your connection.'),
    );

    if (response.statusCode == 416) {
      // Range not satisfiable: existing file is corrupt or out of range
      sendPort.send({'type': 'range_invalid'});
      return;
    } else if (response.statusCode == 403) {
      throw Exception(
          'GitHub API rate limit exceeded or access denied. Please wait a few minutes.');
    } else if (response.statusCode == 404) {
      throw Exception('Update file not found on server.');
    } else if (response.statusCode != 200 && response.statusCode != 206) {
      throw Exception('Server returned HTTP status ${response.statusCode}');
    }

    final isResuming = response.statusCode == 206 && params.existingBytes > 0;
    final startByte = isResuming ? params.existingBytes : 0;
    final total = isResuming
        ? startByte + (response.contentLength ?? 0)
        : (response.contentLength ?? params.expectedTotal);

    sendPort.send({
      'type': 'started',
      'total': total,
      'received': startByte,
    });

    final targetFile = File(params.filePath);
    sink = targetFile.openWrite(
      mode: isResuming ? FileMode.append : FileMode.write,
    );

    int receivedBytes = startByte;
    int lastNotifiedMs = DateTime.now().millisecondsSinceEpoch;
    final completer = Completer<void>();

    // 18-second watchdog timer for silent drops
    void resetWatchdog() {
      watchdog?.cancel();
      watchdog = Timer(const Duration(seconds: 18), () {
        completer.completeError(
          TimeoutException(
              'Connection stalled: No data received for 18 seconds. Check your connection.'),
        );
      });
    }

    resetWatchdog();

    final sub = response.stream.listen(
      (chunk) {
        resetWatchdog();
        sink?.add(chunk);
        receivedBytes += chunk.length;

        final nowMs = DateTime.now().millisecondsSinceEpoch;
        // Throttle progress updates to UI thread to ~80ms (avoids flooding the UI thread)
        if (nowMs - lastNotifiedMs >= 80 || receivedBytes >= total) {
          lastNotifiedMs = nowMs;
          sendPort.send({
            'type': 'progress',
            'received': receivedBytes,
            'total': total,
          });
        }
      },
      onDone: () async {
        watchdog?.cancel();
        try {
          await sink?.flush();
          await sink?.close();
        } catch (_) {}
        sink = null;
        sendPort.send({
          'type': 'completed',
          'received': receivedBytes,
          'total': total,
        });
        completer.complete();
      },
      onError: (e) {
        watchdog?.cancel();
        completer.completeError(e);
      },
      cancelOnError: true,
    );

    await completer.future;
    await sub.cancel();
  } catch (e) {
    watchdog?.cancel();
    try {
      await sink?.flush();
      await sink?.close();
    } catch (_) {}
    sink = null;
    sendPort.send({
      'type': 'error',
      'message': e.toString(),
    });
  } finally {
    watchdog?.cancel();
    client?.close();
  }
}

class AppUpdateService extends ChangeNotifier {
  static final AppUpdateService instance = AppUpdateService._internal();
  AppUpdateService._internal();

  static const MethodChannel _androidChannel =
      MethodChannel('com.wambugu.sautiflow/hardware');

  UpdateStage _stage = UpdateStage.idle;
  UpdateStage get stage => _stage;

  AppReleaseInfo? _release;
  AppReleaseInfo? get release => _release;

  String _currentVersion = '';
  String get currentVersion => _currentVersion;

  double _downloadProgress = 0.0;
  double get downloadProgress => _downloadProgress;

  int _downloadedBytes = 0;
  int get downloadedBytes => _downloadedBytes;

  int _totalBytes = 0;
  int get totalBytes => _totalBytes;

  File? _downloadedFile;
  File? get downloadedFile => _downloadedFile;

  String? _errorMessage;
  String? get errorMessage => _errorMessage;

  Isolate? _downloadIsolate;
  ReceivePort? _receivePort;

  /// Checks GitHub releases API for newer Sautiplay releases.
  /// Returns `true` if an update is available, `false` otherwise.
  Future<bool> checkForUpdates({bool isManual = false}) async {
    _stage = UpdateStage.checking;
    _errorMessage = null;
    notifyListeners();

    try {
      final packageInfo = await PackageInfo.fromPlatform();
      _currentVersion = packageInfo.version;

      final res = await http.get(
        Uri.parse(
            'https://api.github.com/repos/wambugu71/sautiflow/releases/latest'),
        headers: {
          'Accept': 'application/vnd.github.v3+json',
          'User-Agent': 'Sautiplay-App',
        },
      ).timeout(const Duration(seconds: 12));

      if (res.statusCode == 403) {
        throw Exception(
            'GitHub API rate limit reached. Please try again in a few minutes.');
      } else if (res.statusCode != 200) {
        throw Exception('GitHub API returned error code ${res.statusCode}');
      }

      final data = jsonDecode(res.body) as Map<String, dynamic>;
      final tag = (data['tag_name'] as String? ?? '').trim();
      final remoteVersion = tag.replaceFirst(RegExp(r'^v'), '');

      // Compare semantic version
      if (!_isVersionNewer(remoteVersion, _currentVersion)) {
        _stage = UpdateStage.idle;
        notifyListeners();
        return false;
      }

      final assets = (data['assets'] as List<dynamic>?) ?? [];
      final matchedAsset = PlatformAssetMatcher.matchAsset(assets);

      final fileName = matchedAsset != null
          ? (matchedAsset['name'] as String? ?? '')
          : '';
      final downloadUrl = matchedAsset != null
          ? (matchedAsset['browser_download_url'] as String? ?? '')
          : (data['html_url'] as String? ?? '');
      final sizeBytes = matchedAsset != null
          ? (matchedAsset['size'] as int? ?? 0)
          : 0;

      _release = AppReleaseInfo(
        tagName: tag,
        version: remoteVersion,
        name: data['name'] as String? ?? tag,
        body: data['body'] as String? ?? '',
        htmlUrl: data['html_url'] as String? ??
            'https://github.com/wambugu71/sautiflow/releases/latest',
        fileName: fileName.isNotEmpty ? fileName : 'sautiplay_update',
        downloadUrl: downloadUrl,
        sizeBytes: sizeBytes,
        publishedAt: DateTime.tryParse(data['published_at'] as String? ?? '') ??
            DateTime.now(),
      );

      _totalBytes = sizeBytes;
      _stage = UpdateStage.available;
      notifyListeners();
      return true;
    } on SocketException {
      _stage = UpdateStage.error;
      _errorMessage =
          'No internet connection. Please check your network and try again.';
      notifyListeners();
      return false;
    } on TimeoutException {
      _stage = UpdateStage.error;
      _errorMessage =
          'Connection timed out while checking for updates. Please try again.';
      notifyListeners();
      return false;
    } catch (e) {
      _stage = UpdateStage.error;
      _errorMessage = _cleanErrorMessage(e);
      notifyListeners();
      return false;
    }
  }

  /// Downloads the release binary on a dedicated background Isolate (worker thread)
  /// with live progress throttling, HTTP Range resumption, and stall watchdog.
  Future<void> startDownload() async {
    if (_release == null || _release!.downloadUrl.isEmpty) return;

    _stage = UpdateStage.downloading;
    _errorMessage = null;
    notifyListeners();

    try {
      final tempDir = await getTemporaryDirectory();
      final targetFile = File('${tempDir.path}/${_release!.fileName}');

      int existingBytes = 0;
      if (await targetFile.exists()) {
        existingBytes = await targetFile.length();
        if (_release!.sizeBytes > 0 && existingBytes >= _release!.sizeBytes) {
          // File was already downloaded completely
          _downloadedFile = targetFile;
          _downloadedBytes = _release!.sizeBytes;
          _totalBytes = _release!.sizeBytes;
          _downloadProgress = 1.0;
          _stage = UpdateStage.downloaded;
          notifyListeners();
          return;
        }
      }

      _receivePort = ReceivePort();

      final params = _DownloadWorkerParams(
        sendPort: _receivePort!.sendPort,
        url: _release!.downloadUrl,
        filePath: targetFile.path,
        existingBytes: existingBytes,
        expectedTotal: _release!.sizeBytes,
      );

      _downloadIsolate = await Isolate.spawn(
        _downloadWorkerEntryPoint,
        params,
        debugName: 'SautiplayDownloadWorker',
      );

      _receivePort!.listen((message) {
        if (message is Map<String, dynamic>) {
          final type = message['type'] as String?;
          switch (type) {
            case 'started':
              _totalBytes = message['total'] as int? ?? _release!.sizeBytes;
              _downloadedBytes = message['received'] as int? ?? 0;
              if (_totalBytes > 0) {
                _downloadProgress =
                    (_downloadedBytes / _totalBytes).clamp(0.0, 1.0);
              }
              notifyListeners();
              break;
            case 'progress':
              _downloadedBytes = message['received'] as int? ?? _downloadedBytes;
              _totalBytes = message['total'] as int? ?? _totalBytes;
              if (_totalBytes > 0) {
                _downloadProgress =
                    (_downloadedBytes / _totalBytes).clamp(0.0, 1.0);
              }
              notifyListeners();
              break;
            case 'completed':
              _downloadedFile = targetFile;
              _downloadedBytes = message['received'] as int? ?? _totalBytes;
              _downloadProgress = 1.0;
              _stage = UpdateStage.downloaded;
              _cleanupIsolate();
              notifyListeners();
              break;
            case 'range_invalid':
              _cleanupIsolate();
              targetFile.delete().ignore();
              startDownload();
              break;
            case 'error':
              final rawMsg = message['message'] as String? ?? 'Unknown error';
              _stage = UpdateStage.error;
              _errorMessage = _cleanErrorMessage(rawMsg);
              _cleanupIsolate();
              notifyListeners();
              break;
          }
        }
      });
    } catch (e) {
      _cleanupIsolate();
      if (_stage == UpdateStage.downloading) {
        _stage = UpdateStage.error;
        _errorMessage = _cleanErrorMessage(e);
        notifyListeners();
      }
    }
  }

  /// Cancels in-flight download and cleans up the background isolate and file.
  Future<void> cancelDownload() async {
    _cleanupIsolate();

    if (_release != null) {
      try {
        final tempDir = await getTemporaryDirectory();
        final targetFile = File('${tempDir.path}/${_release!.fileName}');
        if (await targetFile.exists()) {
          await targetFile.delete();
        }
      } catch (_) {}
    }

    _downloadedFile = null;
    _stage = UpdateStage.available;
    _downloadProgress = 0.0;
    _downloadedBytes = 0;
    _errorMessage = null;
    notifyListeners();
  }

  /// Discards any partial download on disk and starts completely fresh.
  Future<void> resetAndDownload() async {
    await cancelDownload();
    await startDownload();
  }

  void _cleanupIsolate() {
    _downloadIsolate?.kill(priority: Isolate.immediate);
    _downloadIsolate = null;
    _receivePort?.close();
    _receivePort = null;
  }

  /// Triggers platform-specific installation of the downloaded binary.
  Future<void> installUpdate() async {
    if (_downloadedFile == null || !await _downloadedFile!.exists()) {
      if (_release != null && _release!.htmlUrl.isNotEmpty) {
        final uri = Uri.parse(_release!.htmlUrl);
        await launchUrl(uri, mode: LaunchMode.externalApplication);
      }
      return;
    }

    final filePath = _downloadedFile!.path;

    if (Platform.isAndroid) {
      try {
        await _androidChannel
            .invokeMethod('installApk', {'filePath': filePath});
      } catch (_) {
        if (_release != null) {
          await launchUrl(Uri.parse(_release!.htmlUrl),
              mode: LaunchMode.externalApplication);
        }
      }
    } else if (Platform.isMacOS) {
      try {
        await Process.run('open', [filePath]);
        await Process.run('open', ['-R', filePath]);
      } catch (_) {
        await launchUrl(Uri.parse(_release?.htmlUrl ?? ''),
            mode: LaunchMode.externalApplication);
      }
    } else if (Platform.isWindows) {
      try {
        if (filePath.endsWith('.msix')) {
          await Process.start('explorer.exe', [filePath]);
        } else {
          await Process.start('explorer.exe', ['/select,', filePath]);
        }
      } catch (_) {
        await launchUrl(Uri.parse(_release?.htmlUrl ?? ''),
            mode: LaunchMode.externalApplication);
      }
    } else if (Platform.isLinux) {
      try {
        await Process.start('xdg-open', [filePath]);
      } catch (_) {
        await launchUrl(Uri.parse(_release?.htmlUrl ?? ''),
            mode: LaunchMode.externalApplication);
      }
    } else if (Platform.isIOS) {
      if (_release != null) {
        await launchUrl(Uri.parse(_release!.htmlUrl),
            mode: LaunchMode.externalApplication);
      }
    }
  }

  /// Transforms raw technical exceptions into clear, friendly human guidance.
  String _cleanErrorMessage(dynamic error) {
    final str = error.toString();
    if (error is SocketException || str.contains('SocketException')) {
      return 'Network connection lost. Please verify your Wi-Fi or mobile data and tap Resume.';
    } else if (error is TimeoutException || str.contains('TimeoutException')) {
      return 'Connection timed out. The network is either slow or unreachable.';
    } else if (str.contains('ClientException')) {
      return 'Network stream interrupted. Tap Resume to continue downloading.';
    } else if (error is FileSystemException || str.contains('FileSystemException')) {
      return 'Storage error: Unable to save update file. Please verify disk space.';
    }
    return str.replaceFirst(RegExp(r'^Exception:\s*'), '');
  }

  bool _isVersionNewer(String remote, String current) {
    try {
      final rParts = remote
          .split('.')
          .map((p) => int.tryParse(p.split('-')[0]) ?? 0)
          .toList();
      final cParts = current
          .split('.')
          .map((p) => int.tryParse(p.split('-')[0]) ?? 0)
          .toList();

      final maxLen =
          rParts.length > cParts.length ? rParts.length : cParts.length;
      for (int i = 0; i < maxLen; i++) {
        final r = i < rParts.length ? rParts[i] : 0;
        final c = i < cParts.length ? cParts[i] : 0;
        if (r > c) return true;
        if (r < c) return false;
      }
    } catch (_) {}
    return false;
  }
}
