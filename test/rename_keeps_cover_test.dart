import 'package:flutter_test/flutter_test.dart';

import 'helpers/source_text.dart';

/// Renaming a playlist must not throw away its custom cover.
///
/// ── WHAT WENT WRONG ────────────────────────────────
///
/// A manually-set cover is stored TWICE: in ArtworkOverrideNotifier under
/// `playlist:<title>`, and as a copy of that same file path in
/// LibraryItem.image (written by _commitPendingCover). Renaming moved only the
/// override.
///
/// That would have been harmless if setOverride reused the filename, but it
/// deliberately writes a fresh versioned name every time to defeat Flutter's
/// image cache, and clearOverride then deletes the old file. So after a rename
/// item.image pointed at a file that had just been deleted: a coverless
/// playlist in the library grid, while the home mosaic — which resolves through
/// the override map — still looked correct.
///
/// It came back after an app restart, because the load-time heal re-derives
/// item.image from the override map. That is what made it look intermittent
/// rather than reproducible, and it is why this is guarded by a test.
///
/// Source scans rather than a pumped widget: this is about the ORDER of three
/// calls inside one method on a StateNotifier that owns disk and network state.
void main() {
  final library = codeOf('lib/providers/library_provider.dart');

  /// The body of renamePlaylist, so a match elsewhere in this 3000-line file
  /// cannot satisfy these tests.
  String renameBody() {
    final start = library.indexOf('Future<bool> renamePlaylist(');
    expect(start, greaterThan(-1), reason: 'renamePlaylist is gone.');
    final end = library.indexOf('void addPlaylist(', start);
    expect(end, greaterThan(start), reason: 'renamePlaylist no longer ends where expected.');
    return library.substring(start, end);
  }

  group('the cover survives the rename', () {
    test('the item is re-pointed at the override map', () {
      expect(renameBody(), contains('_reconcileCustomCovers('),
          reason: 'Nothing re-points LibraryItem.image after the rename, so it '
              'still holds the pre-rename path — which clearOverride deletes. '
              'That is the coverless-playlist bug.');
    });

    test('it does not pay for a second disk write', () {
      expect(renameBody(), contains('_reconcileCustomCovers(persist: false)'),
          reason: 'renamePlaylist calls _saveToDisk() itself a few lines later. '
              'Letting the reconcile persist too means two writes for one '
              'rename.');
    });

    test('_reconcileCustomCovers still honours persist', () {
      expect(library, contains('if (persist) _saveToDisk(userInitiated: false)'),
          reason: 'The flag exists but is ignored, so persist: false no longer '
              'saves anything — the second write is back.');
    });
  });

  group('a failed move never deletes the last copy', () {
    test("setOverride's answer is read, not discarded", () {
      final body = renameBody();
      expect(body, contains('final moved = await notifier.setOverride('),
          reason: 'The return value is being thrown away again. setOverride '
              'returns false on an unreadable source or a failed re-encode.');
    });

    test('clearOverride is reached only when the move landed', () {
      final body = renameBody();
      final moved = body.indexOf('if (moved) {');
      final cleared = body.indexOf('clearOverride(oldKey)');
      expect(moved, greaterThan(-1),
          reason: 'clearOverride is unconditional again: a re-encode that '
              'failed now deletes the only remaining copy of the cover.');
      expect(cleared, greaterThan(moved),
          reason: 'clearOverride runs before the success check, which is the '
              'same data loss by a different route.');
    });
  });
}
