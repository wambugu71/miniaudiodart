import 'package:flutter_test/flutter_test.dart';
import 'package:sautiplay/services/app_update_service.dart';
import 'package:sautiplay/services/platform_asset_matcher.dart';

void main() {
  group('PlatformAssetMatcher Tests', () {
    final sampleAssets = [
      {
        'name': 'sautiflow_android_arm64.apk',
        'browser_download_url':
            'https://github.com/wambugu71/sautiflow/releases/download/v0.6.25/sautiflow_android_arm64.apk',
        'size': 40619324,
      },
      {
        'name': 'sautiflow_android_armv7.apk',
        'browser_download_url':
            'https://github.com/wambugu71/sautiflow/releases/download/v0.6.25/sautiflow_android_armv7.apk',
        'size': 37651776,
      },
      {
        'name': 'sautiflow_windows.zip',
        'browser_download_url':
            'https://github.com/wambugu71/sautiflow/releases/download/v0.6.25/sautiflow_windows.zip',
        'size': 139400960,
      },
      {
        'name': 'sautiplay.msix',
        'browser_download_url':
            'https://github.com/wambugu71/sautiflow/releases/download/v0.6.25/sautiplay.msix',
        'size': 74057604,
      },
      {
        'name': 'sautiflow_macos.zip',
        'browser_download_url':
            'https://github.com/wambugu71/sautiflow/releases/download/v0.6.25/sautiflow_macos.zip',
        'size': 84386296,
      },
      {
        'name': 'sautiplay_0.6.25_amd64.deb',
        'browser_download_url':
            'https://github.com/wambugu71/sautiflow/releases/download/v0.6.25/sautiplay_0.6.25_amd64.deb',
        'size': 17633516,
      },
      {
        'name': 'sautiflow_linux.tar.gz',
        'browser_download_url':
            'https://github.com/wambugu71/sautiflow/releases/download/v0.6.25/sautiflow_linux.tar.gz',
        'size': 23673798,
      },
    ];

    test('Identifies current platform description accurately', () {
      final desc = PlatformAssetMatcher.platformDescription;
      expect(desc, isNotEmpty);
      // On Windows test runner, it should be Windows
      expect(desc.contains('Windows'), isTrue);
    });

    test('Matches Windows MSIX or ZIP on Windows host without picking APK or Linux', () {
      final matched = PlatformAssetMatcher.matchAsset(sampleAssets);
      expect(matched, isNotNull);
      final name = matched!['name'] as String;
      expect(name.endsWith('.msix') || name.contains('windows'), isTrue);
      expect(name.endsWith('.apk'), isFalse);
      expect(name.endsWith('.deb'), isFalse);
    });

    test('isInternetAvailable completes and returns a boolean without throwing', () async {
      final available = await AppUpdateService.instance.isInternetAvailable();
      expect(available, isA<bool>());
    });
  });
}
