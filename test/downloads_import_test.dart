import 'package:flutter_test/flutter_test.dart';

import 'helpers/source_text.dart';

/// Re-importing downloads from disk after a reinstall.
///
/// ── THE BUG THIS FILE EXISTS FOR ────────────────────────────────────────────
///
/// A download that belongs to no album is TAGGED "Auvy Downloads" so it reads
/// sensibly in other music apps — an empty album tag shows as "Unknown album"
/// almost everywhere.
///
/// The importer then read that tag back as an album NAME. After a reinstall the
/// index is rebuilt from the files rather than from the cloud backup, so every
/// single collapsed into a folder called "Auvy Downloads" — a folder that had
/// never existed before, appearing out of nowhere, looking like data corruption.
/// On disk nothing was wrong: the files sit in Singles/ exactly as they always
/// did.
///
/// Reported after a deliberate uninstall/reinstall on 2026-09-02.
void main() {
  final cache = codeOf('lib/logic/audio_cache_manager.dart');

  group('the placeholder album tag is not a collection', () {
    test('the writer and the reader share one constant', () {
      // They disagreed by being two separate string literals, which is exactly
      // how the writer's placeholder became the reader's folder name.
      expect(cache.contains("kDownloadsAlbumTag = 'Auvy Downloads'"), isTrue,
          reason: 'The shared constant is gone.');
      expect(cache.contains("collectionName ?? kDownloadsAlbumTag"), isTrue,
          reason: 'The download path writes a literal again instead of the '
              'constant the importer checks for.');
    });

    test('no bare literal survives outside the constant', () {
      // A second literal anywhere is the drift starting over.
      final occurrences = "'Auvy Downloads'".allMatches(cache).length;
      expect(occurrences, 1,
          reason: 'The string appears $occurrences times; it must appear only '
              'in the kDownloadsAlbumTag declaration.');
    });

    test('the importer clears the sentinel', () {
      expect(cache.contains("if (album.trim() == kDownloadsAlbumTag) album = ''"),
          isTrue,
          reason: 'The importer treats the placeholder as a real album again, '
              'so a reinstall recreates the phantom folder.');
    });

    test('it is cleared AFTER the sidecar, so both sources are caught', () {
      // Sidecar metadata overwrites `album`, so clearing before it would let a
      // sidecar carrying the placeholder through.
      final sidecar = cache.indexOf('if (scAlbum.isNotEmpty) album = scAlbum;');
      final clear = cache.indexOf('if (album.trim() == kDownloadsAlbumTag)');
      expect(sidecar, greaterThan(-1));
      expect(clear, greaterThan(sidecar),
          reason: 'The sentinel is cleared before the sidecar can reinstate it.');
    });
  });

  group('real folders still group', () {
    test('only Albums/ and Playlists/ become collections', () {
      // Singles/ is deliberately NOT grouped — those are loose tracks and must
      // list flat, which is what the reported behaviour was before reinstall.
      expect(
          cache.contains(
              "segs.length >= 2 && (segs[0] == 'Albums' || segs[0] == 'Playlists')"),
          isTrue,
          reason: 'The folder-grouping rule changed. Singles/ must not group, '
              'or loose downloads turn into a folder again by a different '
              'route.');
    });

    test('a real album tag is still respected', () {
      // The fix must only remove Auvy's own placeholder, never a genuine album.
      // The clear is an equality test against the constant, not a blanket wipe.
      final clearLine = cache.substring(
          cache.indexOf('if (album.trim() == kDownloadsAlbumTag)'));
      expect(clearLine.startsWith("if (album.trim() == kDownloadsAlbumTag) album = '';"),
          isTrue,
          reason: 'The clear is broader than an exact match on the placeholder, '
              'so genuine album names could be discarded too.');
    });
  });
  group('existing indexes are repaired, not just future imports', () {
    // FIXING THE IMPORT ALONE WOULD HAVE LOOKED LIKE THE FIX FAILED.
    //
    // scanAndImportDownloads skips any file already in the index, so a device
    // that imported these tracks before the fix keeps the bad album name for
    // ever and the folder survives the update.

    test('the index loader runs the repair', () {
      expect(cache.contains('await _repairPlaceholderAlbums();'), isTrue,
          reason: 'Nothing repairs an index that already holds the bad album.');
    });

    test('the repair matches the same constant the writer uses', () {
      final fn = cache.substring(
          cache.indexOf('Future<void> _repairPlaceholderAlbums()'));
      expect(fn.contains('albumTitle.trim() == kDownloadsAlbumTag'), isTrue,
          reason: 'The repair matches something other than the placeholder, '
              'so it could clear real album names.');
    });

    test('it returns early when there is nothing to fix', () {
      // Runs on every index load, so a clean index must cost one pass and no
      // write.
      final fn = cache.substring(
          cache.indexOf('Future<void> _repairPlaceholderAlbums()'));
      expect(fn.contains('if (hits.isEmpty) return;'), isTrue,
          reason: 'The repair saves the index on every launch even when it is '
              'already clean.');
    });

    test('copyWith can actually clear the album', () {
      // It only accepted lastAccessedAt, isExplicitDownload and fileSizeBytes
      // before, so the repair could not have compiled.
      expect(cache.contains('albumTitle ?? this.albumTitle'), isTrue,
          reason: 'copyWith no longer honours an albumTitle override.');
    });
  });
}
