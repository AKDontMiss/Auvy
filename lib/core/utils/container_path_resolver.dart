import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

/// Repairs stored file paths after the iOS app container moves.
///
/// iOS changes the container UUID on reinstalls and updates
/// (`/var/mobile/Containers/Data/Application/<UUID>/...`), so absolute paths saved
/// earlier stop resolving even though the files moved with the app. This keeps
/// the part after the UUID and re-bases it on the current container.
class ContainerPathResolver {
  static String? _currentContainerRoot;
  static String? _currentDocumentsDir;
  static String? _currentSupportDir;

  static String? get currentContainerRoot => _currentContainerRoot;
  static String? get currentDocumentsDir => _currentDocumentsDir;
  static String? get currentSupportDir => _currentSupportDir;

  @visibleForTesting
  static void resetForTesting() {
    _currentContainerRoot = null;
    _currentDocumentsDir = null;
    _currentSupportDir = null;
  }

  /// Sets the directories directly (used by tests).
  static void setDirectories({
    required String documentsDir,
    String? supportDir,
  }) {
    _currentDocumentsDir = documentsDir;
    final docDir = Directory(documentsDir);
    // On iOS: /var/mobile/Containers/Data/Application/<UUID>/Documents
    // Its parent is /var/mobile/Containers/Data/Application/<UUID>
    _currentContainerRoot = docDir.parent.path;
    _currentSupportDir = supportDir;
  }

  /// Resolves the directories once, if not already set.
  static Future<void> ensureInitialized() async {
    if (_currentContainerRoot != null) return;
    try {
      final doc = await getApplicationDocumentsDirectory();
      _currentDocumentsDir = doc.path;
      _currentContainerRoot = doc.parent.path;
      if (Platform.isIOS) {
        final supp = await getApplicationSupportDirectory();
        _currentSupportDir = supp.path;
      }
    } catch (_) {}
  }

  /// Returns [path] re-based onto the current container when it points at an old
  /// one. Paths that exist, or are not container paths, are returned unchanged.
  static String rebaseIfNeeded(String path) {
    if (path.isEmpty || path.startsWith('http') || path.startsWith('assets/')) {
      return path;
    }

    try {
      if (File(path).existsSync()) return path;
    } catch (_) {
      return path;
    }

    final root = _currentContainerRoot;

    // 1. Old sandbox UUID (device, /private/var, or simulator paths).
    if (root != null) {
      final match = RegExp(
        r'.*/(?:Containers/Data/Application|Application)/[A-Fa-f0-9-]+/(.*)',
        caseSensitive: false,
      ).firstMatch(path);

      if (match != null) {
        final rel = match.group(1)!;
        final candidate = '$root/$rel';
        try {
          if (File(candidate).existsSync()) {
            return candidate;
          }
        } catch (_) {}
      }
    }

    // 2. Known app folders, matched by name. Both folders live in Application
    //    Support on iOS but used to be in Documents, so check both.
    for (final folder in const ['artwork_overrides', 'audio_cache']) {
      final marker = '/$folder/';
      if (!path.contains(marker)) continue;
      final fileName = path.split(marker).last;
      for (final base in [_currentSupportDir, _currentDocumentsDir]) {
        if (base == null) continue;
        final candidate = '$base/$folder/$fileName';
        try {
          if (File(candidate).existsSync()) return candidate;
        } catch (_) {}
      }
    }

    return path;
  }
}
