import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:material_3_expressive/components/buttons/enums/m3e_button_enums.dart';
import 'package:material_3_expressive/material_3_expressive.dart';

import '../services/app_theme_service.dart';
import '../services/app_update_service.dart';
import '../services/platform_asset_matcher.dart';

/// A Material 3 Expressive dialog for Sautiplay updates featuring:
/// - M3EDialog container with expressive motion and typography
/// - M3EProgressIndicator.linearWavy for dynamic progress
/// - Evenly formatted total file size with tabular figures
/// - Background isolate worker for smooth, non-blocking 120 FPS UI
/// - Resumable downloads and robust error handling
class AppUpdateDialog extends StatelessWidget {
  const AppUpdateDialog({super.key});

  static bool _isShowing = false;

  /// Presents the M3E update dialog.
  static Future<void> show(BuildContext context) async {
    if (_isShowing) return;
    _isShowing = true;
    try {
      await M3EDialog.show<void>(
        context,
        barrierDismissible: true,
        dialog: const AppUpdateDialog(),
      );
    } finally {
      _isShowing = false;
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final primary = theme.colorScheme.primary;

    return ListenableBuilder(
      listenable: AppUpdateService.instance,
      builder: (context, _) {
        final service = AppUpdateService.instance;
        final release = service.release;

        if (release == null) return const SizedBox.shrink();

        final isDownloading = service.stage == UpdateStage.downloading;
        final isDownloaded = service.stage == UpdateStage.downloaded;
        final isError = service.stage == UpdateStage.error;
        final hasPartial = service.downloadedBytes > 0;
        final percent = (service.downloadProgress * 100).toInt();

        // Evenly formatted size strings (e.g. " 25.1 MB /  40.6 MB")
        final receivedMb = (service.downloadedBytes / (1024 * 1024)).toStringAsFixed(1);
        final totalMb = service.totalBytes > 0
            ? (service.totalBytes / (1024 * 1024)).toStringAsFixed(1)
            : (release.sizeBytes / (1024 * 1024)).toStringAsFixed(1);
        final evenSizeText = '$receivedMb MB / $totalMb MB';

        return PopScope(
          canPop: !isDownloading,
          onPopInvokedWithResult: (didPop, _) {
            if (!didPop && isDownloading) {
              service.cancelDownload();
            }
          },
          child: M3EDialog(
            title: isDownloaded
                ? 'Ready to Install'
                : (isDownloading
                    ? 'Downloading Update'
                    : (isError
                        ? (hasPartial ? 'Download Paused' : 'Update Failed')
                        : 'New Update Available')),
            icon: Container(
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: (isDownloaded
                        ? Colors.green
                        : (isError ? Colors.amber : primary))
                    .withValues(alpha: 0.15),
                borderRadius: BorderRadius.circular(14),
              ),
              child: Icon(
                isDownloaded
                    ? Icons.check_circle_rounded
                    : (isDownloading
                        ? Icons.cloud_download_rounded
                        : (isError
                            ? (hasPartial
                                ? Icons.pause_circle_filled_rounded
                                : Icons.wifi_off_rounded)
                            : Icons.system_update_rounded)),
                color: isDownloaded
                    ? Colors.greenAccent
                    : (isError ? Colors.amberAccent : primary),
                size: 26,
              ),
            ),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // Platform & Architecture Tag
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                  decoration: BoxDecoration(
                    color: primary.withValues(alpha: 0.12),
                    borderRadius: BorderRadius.circular(8),
                    border:
                        Border.all(color: primary.withValues(alpha: 0.3)),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.devices_rounded, size: 14, color: primary),
                      const SizedBox(width: 6),
                      Text(
                        '${release.tagName} • ${PlatformAssetMatcher.platformDescription}',
                        style: TextStyle(
                          color: primary,
                          fontWeight: FontWeight.w600,
                          fontSize: 12,
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 14),

                if (isDownloading) ...[
                  // Progress and Evenly Formatted Total Size
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Text(
                        '$percent%',
                        style: const TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.bold,
                          fontFeatures: [FontFeature.tabularFigures()],
                        ),
                      ),
                      Text(
                        evenSizeText,
                        style: TextStyle(
                          fontSize: 12,
                          color: context.textMuted,
                          fontWeight: FontWeight.w600,
                          fontFeatures: const [FontFeature.tabularFigures()],
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 10),
                  // M3E Linear Wavy Progress Indicator
                  ClipRRect(
                    borderRadius: BorderRadius.circular(8),
                    child: M3EProgressIndicator.linearWavy(
                      value: service.downloadProgress > 0
                          ? service.downloadProgress
                          : null,
                      color: primary,
                      trackColor: context.outlineColor.withValues(alpha: 0.2),
                    ),
                  ),
                  const SizedBox(height: 10),
                  Text(
                    'Saving: ${release.fileName}',
                    style: TextStyle(fontSize: 11, color: context.textMuted),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ] else if (isDownloaded) ...[
                  Container(
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: Colors.green.withValues(alpha: 0.1),
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(
                          color: Colors.green.withValues(alpha: 0.3)),
                    ),
                    child: Row(
                      children: [
                        const Icon(Icons.download_done_rounded,
                            color: Colors.greenAccent, size: 22),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Text(
                            'Package downloaded ($totalMb MB). Tap "Install Now" to apply update.',
                            style: TextStyle(
                              fontSize: 12,
                              color: context.textDark,
                              fontWeight: FontWeight.w500,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ] else if (isError) ...[
                  if (hasPartial) ...[
                    // Paused progress state with wavy indicator
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Text(
                          'Paused at $percent%',
                          style: const TextStyle(
                            fontSize: 14,
                            fontWeight: FontWeight.bold,
                            color: Colors.amberAccent,
                            fontFeatures: [FontFeature.tabularFigures()],
                          ),
                        ),
                        Text(
                          evenSizeText,
                          style: TextStyle(
                            fontSize: 12,
                            color: context.textMuted,
                            fontWeight: FontWeight.w600,
                            fontFeatures: const [FontFeature.tabularFigures()],
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 10),
                    ClipRRect(
                      borderRadius: BorderRadius.circular(8),
                      child: M3EProgressIndicator.linearWavy(
                        value: service.downloadProgress,
                        color: Colors.amberAccent,
                        trackColor:
                            context.outlineColor.withValues(alpha: 0.2),
                      ),
                    ),
                    const SizedBox(height: 12),
                  ],
                  Container(
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: Colors.amber.withValues(alpha: 0.1),
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(
                          color: Colors.amber.withValues(alpha: 0.3)),
                    ),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Icon(Icons.info_outline_rounded,
                            color: Colors.amberAccent, size: 18),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Text(
                            service.errorMessage ??
                                'Download interrupted. Please check your internet connection.',
                            style: TextStyle(
                              fontSize: 12,
                              color: context.textDark,
                              height: 1.3,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ] else ...[
                  // Changelog preview
                  if (release.body.isNotEmpty) ...[
                    ConstrainedBox(
                      constraints: const BoxConstraints(maxHeight: 160),
                      child: Container(
                        padding: const EdgeInsets.all(12),
                        decoration: BoxDecoration(
                          color: context.bgDark.withValues(alpha: 0.5),
                          borderRadius: BorderRadius.circular(12),
                          border: Border.all(
                            color: context.outlineColor.withValues(alpha: 0.15),
                          ),
                        ),
                        child: SingleChildScrollView(
                          child: Text(
                            release.body,
                            style: TextStyle(
                              color: context.textDark,
                              fontSize: 13,
                              height: 1.4,
                            ),
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(height: 10),
                  ],
                  Row(
                    children: [
                      Icon(Icons.folder_zip_outlined,
                          size: 14, color: context.textMuted),
                      const SizedBox(width: 6),
                      Expanded(
                        child: Text(
                          '${release.fileName} ($totalMb MB)',
                          style: TextStyle(
                            fontSize: 12,
                            color: context.textMuted,
                            fontFeatures: const [FontFeature.tabularFigures()],
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    ],
                  ),
                ],
              ],
            ),
            actions: [
              if (isDownloading) ...[
                M3EButton(
                  style: M3EButtonStyle.text,
                  onPressed: () => service.cancelDownload(),
                  child: const Text(
                    'Cancel Download',
                    style: TextStyle(
                      color: Colors.redAccent,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
              ] else if (isDownloaded) ...[
                M3EButton(
                  style: M3EButtonStyle.text,
                  onPressed: () => Navigator.of(context).pop(),
                  child: Text('Later',
                      style: TextStyle(color: context.textMuted)),
                ),
                M3EButton(
                  style: M3EButtonStyle.filled,
                  onPressed: () {
                    Navigator.of(context).pop();
                    service.installUpdate();
                  },
                  child: const Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.install_mobile_rounded, size: 18),
                      SizedBox(width: 6),
                      Text('Install Now'),
                    ],
                  ),
                ),
              ] else if (isError) ...[
                if (hasPartial) ...[
                  M3EButton(
                    style: M3EButtonStyle.text,
                    onPressed: () {
                      service.cancelDownload();
                      Navigator.of(context).pop();
                    },
                    child: const Text('Cancel',
                        style: TextStyle(color: Colors.redAccent)),
                  ),
                  M3EButton(
                    style: M3EButtonStyle.tonal,
                    onPressed: () => service.resetAndDownload(),
                    child: const Text('Restart'),
                  ),
                  M3EButton(
                    style: M3EButtonStyle.filled,
                    onPressed: () => service.startDownload(),
                    child: const Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(Icons.play_arrow_rounded, size: 18),
                        SizedBox(width: 6),
                        Text('Resume'),
                      ],
                    ),
                  ),
                ] else ...[
                  M3EButton(
                    style: M3EButtonStyle.text,
                    onPressed: () => Navigator.of(context).pop(),
                    child: Text('Dismiss',
                        style: TextStyle(color: context.textMuted)),
                  ),
                  M3EButton(
                    style: M3EButtonStyle.filled,
                    onPressed: () => service.startDownload(),
                    child: const Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(Icons.refresh_rounded, size: 18),
                        SizedBox(width: 6),
                        Text('Retry'),
                      ],
                    ),
                  ),
                ],
              ] else ...[
                M3EButton(
                  style: M3EButtonStyle.text,
                  onPressed: () => Navigator.of(context).pop(),
                  child: Text('Later',
                      style: TextStyle(color: context.textMuted)),
                ),
                M3EButton(
                  style: M3EButtonStyle.filled,
                  onPressed: () => service.startDownload(),
                  child: const Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.download_rounded, size: 18),
                      SizedBox(width: 6),
                      Text('Update Now'),
                    ],
                  ),
                ),
              ],
            ],
          ),
        );
      },
    );
  }
}
