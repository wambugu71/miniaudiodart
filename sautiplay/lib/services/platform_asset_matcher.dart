import 'dart:ffi';
import 'dart:io';

/// Resolves the current operating system and CPU architecture (ABI),
/// and matches the exact binary asset from a GitHub Release to prevent
/// downloading inappropriate packages (e.g. Android APK on Windows, or
/// armv7 APK on an arm64 Android phone).
class PlatformAssetMatcher {
  /// Returns a user-friendly label for the current platform and architecture.
  static String get platformDescription {
    if (Platform.isAndroid) {
      final abi = Abi.current();
      if (abi == Abi.androidArm64) {
        return 'Android (ARM64)';
      } else if (abi == Abi.androidArm) {
        return 'Android (ARMv7)';
      } else if (abi == Abi.androidX64) {
        return 'Android (x86_64)';
      }
      return 'Android';
    } else if (Platform.isWindows) {
      final abi = Abi.current();
      return abi == Abi.windowsArm64 ? 'Windows (ARM64)' : 'Windows (x64)';
    } else if (Platform.isLinux) {
      final abi = Abi.current();
      return abi == Abi.linuxArm64 ? 'Linux (ARM64)' : 'Linux (x64)';
    } else if (Platform.isMacOS) {
      final abi = Abi.current();
      return abi == Abi.macosArm64
          ? 'macOS (Apple Silicon)'
          : 'macOS (Intel x64)';
    } else if (Platform.isIOS) {
      return 'iOS';
    }
    return Platform.operatingSystem;
  }

  /// Evaluates a list of GitHub release assets and selects the best binary for the current system.
  static Map<String, dynamic>? matchAsset(List<dynamic> assets) {
    if (assets.isEmpty) return null;
    final assetList = assets.cast<Map<String, dynamic>>();

    if (Platform.isAndroid) {
      final abi = Abi.current();
      final isArm64 = abi == Abi.androidArm64;
      final targetKeyword = isArm64 ? 'arm64' : 'armv7';

      // 1. Strict match: must end with .apk and contain the exact architecture keyword
      final exactMatch = assetList.firstWhere(
        (a) {
          final name = (a['name'] as String? ?? '').toLowerCase();
          return name.endsWith('.apk') && name.contains(targetKeyword);
        },
        orElse: () => <String, dynamic>{},
      );
      if (exactMatch.isNotEmpty) return exactMatch;

      // 2. Fallback to any .apk
      final anyApk = assetList.firstWhere(
        (a) => (a['name'] as String? ?? '').toLowerCase().endsWith('.apk'),
        orElse: () => <String, dynamic>{},
      );
      return anyApk.isNotEmpty ? anyApk : null;
    } else if (Platform.isWindows) {
      // 1. Prioritize installer package (.msix)
      final msixMatch = assetList.firstWhere(
        (a) => (a['name'] as String? ?? '').toLowerCase().endsWith('.msix'),
        orElse: () => <String, dynamic>{},
      );
      if (msixMatch.isNotEmpty) return msixMatch;

      // 2. Fallback to Windows portable zip
      final winZip = assetList.firstWhere(
        (a) {
          final name = (a['name'] as String? ?? '').toLowerCase();
          return name.contains('windows') && name.endsWith('.zip');
        },
        orElse: () => <String, dynamic>{},
      );
      return winZip.isNotEmpty ? winZip : null;
    } else if (Platform.isLinux) {
      // 1. Prioritize Debian package (.deb)
      final debMatch = assetList.firstWhere(
        (a) => (a['name'] as String? ?? '').toLowerCase().endsWith('.deb'),
        orElse: () => <String, dynamic>{},
      );
      if (debMatch.isNotEmpty) return debMatch;

      // 2. Fallback to Linux tar.gz
      final tarMatch = assetList.firstWhere(
        (a) {
          final name = (a['name'] as String? ?? '').toLowerCase();
          return name.contains('linux') &&
              (name.endsWith('.tar.gz') || name.endsWith('.tgz'));
        },
        orElse: () => <String, dynamic>{},
      );
      return tarMatch.isNotEmpty ? tarMatch : null;
    } else if (Platform.isMacOS) {
      // 1. Prioritize .dmg if present
      final dmgMatch = assetList.firstWhere(
        (a) => (a['name'] as String? ?? '').toLowerCase().endsWith('.dmg'),
        orElse: () => <String, dynamic>{},
      );
      if (dmgMatch.isNotEmpty) return dmgMatch;

      // 2. Fallback to macOS zip
      final macZip = assetList.firstWhere(
        (a) {
          final name = (a['name'] as String? ?? '').toLowerCase();
          return name.contains('macos') && name.endsWith('.zip');
        },
        orElse: () => <String, dynamic>{},
      );
      return macZip.isNotEmpty ? macZip : null;
    } else if (Platform.isIOS) {
      final ipaMatch = assetList.firstWhere(
        (a) => (a['name'] as String? ?? '').toLowerCase().endsWith('.ipa'),
        orElse: () => <String, dynamic>{},
      );
      return ipaMatch.isNotEmpty ? ipaMatch : null;
    }

    return null;
  }
}
