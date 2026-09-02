import 'dart:io';

import 'package:archive/archive.dart';
import 'package:auvy/data/dummy_data.dart';
import 'package:auvy/logic/music_db_schema.dart';
import 'package:path_provider/path_provider.dart';
import 'package:sqflite/sqflite.dart';

/// Reading someone else's backup
///
/// A `.backup` from Metrolist, and from the whole InnerTune family it descends
/// from (InnerTune, OuterTune, ViTune, SimpMusic) — is a ZIP holding the app's
/// live Room database, `song.db`, plus its DataStore preferences blob:
///
///     song.db                    ← SQLite, the entire library
///     song.db-wal / -shm         ← write-ahead log (skipped, see below)
///     settings.preferences_pb    ← protobuf settings (NOT read, see below)
///     artist_name_aliases.json
///
/// Verified against MetrolistGroup/Metrolist: `BackupRestoreViewModel.backup`
/// writes exactly those entries, and its own restore reads `song.db` while
/// deliberately skipping `-wal`/`-shm` so the database opens clean. This reader
/// does the same, and for the same reason: the app checkpoints the database
/// before writing the archive, so the main file is complete on its own.
///
/// THE SETTINGS BLOB IS DELIBERATELY NOT READ. `settings.preferences_pb`
/// carries that app's InnerTube COOKIE, visitor data and auth-user index — it is
/// a credential store. Metrolist itself offers to strip those keys on restore.
/// Auvy has no business parsing another app's session, so the entry is skipped
/// entirely rather than read-and-filtered: nothing that is never parsed can leak.
///
/// NOTHING IS WRITTEN TO THE USER'S LIBRARY FROM HERE. This file only READS,
/// into plain Dart objects. Merging is the library provider's job, and it merges
/// — never replaces, so importing someone else's playlists cannot erase yours.
class ForeignBackupReader {
  ForeignBackupReader._();

  /// Entries that tell us this is a music-app database backup.
  static const List<String> _dbEntryNames = [
    'song.db', // Metrolist / InnerTune / OuterTune
    'internal.db',
    'music.db',
    'song_db',
  ];

  /// Is this file plausibly a foreign backup? Cheap check on the ZIP index only —
  /// no database is opened, nothing is extracted.
  static Future<bool> looksForeign(File file) async {
    try {
      final entry = await _findDbEntryName(file);
      return entry != null;
    } catch (_) {
      return false;
    }
  }

  static Future<String?> _findDbEntryName(File file) async {
    // THE SAME CEILING AS read(). This inflates no payload, but it still
    // loads the whole file to reach the index, and this is the FIRST thing a
    // picked file touches, so an oversized one would OOM here before read() got
    // the chance to refuse it politely.
    if (await file.length() > _maxArchiveBytes) return null;
    // Read the archive index without inflating any payload.
    final bytes = await file.readAsBytes();
    final archive = ZipDecoder().decodeBytes(bytes, verify: false);
    for (final f in archive.files) {
      final name = f.name.split('/').last;
      if (_dbEntryNames.contains(name)) return f.name;
    }
    // Any other single .db entry — a fork may have renamed its database, and a
    // schema check below still decides whether it is readable.
    for (final f in archive.files) {
      if (f.name.toLowerCase().endsWith('.db')) return f.name;
    }
    return null;
  }

  /// Extract, read and delete. Returns null when the file is not a readable
  /// foreign backup — callers treat that as "not this format", not as an error.
  /// Size ceilings, because this file came from outside
  ///
  /// The path handling here is already safe: the archive entry's NAME is never
  /// used to build an output path (the temp file is generated), so there is no
  /// zip-slip. Memory was the unguarded part.
  ///
  /// Reading a backup materialises it three times over — the compressed bytes,
  /// the decoded archive, and the decompressed database before it is written —
  /// so a file that is merely LARGE can exhaust a mid-range device, and a file
  /// crafted to decompress enormously (a few KB expanding to gigabytes) is a
  /// trivial way to kill the app from a share sheet.
  ///
  /// The uncompressed size is in the ZIP's own header, so the second check costs
  /// nothing and happens BEFORE any allocation. A real Metrolist backup of a
  /// large library is single-digit megabytes; these ceilings are far above any
  /// genuine file and far below what an OOM needs.
  static const int _maxArchiveBytes = 256 * 1024 * 1024;
  static const int _maxDatabaseBytes = 512 * 1024 * 1024;

  static Future<ImportedLibrary?> read(File file) async {
    File? temp;
    Database? db;
    try {
      final onDisk = await file.length();
      if (onDisk > _maxArchiveBytes) {
        print('WARN: foreign backup: refusing a ${onDisk ~/ (1024 * 1024)}MB file '
            '(ceiling ${_maxArchiveBytes ~/ (1024 * 1024)}MB) — reading it would '
            'hold it in memory three times over');
        return null;
      }
      final bytes = await file.readAsBytes();
      final archive = ZipDecoder().decodeBytes(bytes);
      ArchiveFile? dbEntry;
      for (final f in archive.files) {
        final base = f.name.split('/').last;
        if (_dbEntryNames.contains(base)) {
          dbEntry = f;
          break;
        }
      }
      dbEntry ??= archive.files.firstWhere(
          (f) => f.name.toLowerCase().endsWith('.db'),
          orElse: () => ArchiveFile('', 0, const <int>[]));
      if (dbEntry.name.isEmpty) {
        // EVERY REFUSAL SAYS WHY. A silent `return null` here is
        // indistinguishable from a crash, from an unreadable file and from an
        // empty library, and the app can only report the one useless sentence
        // "can't read that backup" for all four. One line per exit turns a
        // support round trip into a log grep.
        print('WARN: foreign backup: no database entry among '
            '${archive.files.map((f) => f.name).join(", ")}');
        return null;
      }

      // The header's claim, checked before the bytes are materialised.
      // `dbEntry.content` decompresses on access, so testing the size afterwards
      // would be testing it after the damage.
      if (dbEntry.size > _maxDatabaseBytes) {
        print('WARN: foreign backup: "${dbEntry.name}" claims '
            '${dbEntry.size ~/ (1024 * 1024)}MB uncompressed (ceiling '
            '${_maxDatabaseBytes ~/ (1024 * 1024)}MB) — refusing rather than '
            'decompressing it');
        return null;
      }

      // Into the CACHE directory, not documents: this copy is scratch, and it is
      // deleted in the finally block whether or not the read succeeds. A foreign
      // database left lying around is another app's data sitting in ours.
      final cache = await getTemporaryDirectory();
      // Unique per import: sqflite caches open handles by path, and a stale
      // handle from a previous import would be handed back for a different file.
      temp = File(
          '${cache.path}/import_${DateTime.now().millisecondsSinceEpoch}.db');
      await temp.writeAsBytes(dbEntry.content as List<int>, flush: true);

      // NOT openReadOnlyDatabase, DESPITE THIS BEING A READ.
      //
      // The archive holds a WAL-mode database (Room's default) and deliberately
      // does not restore its `-wal`/`-shm` sidecars. SQLite cannot open a
      // WAL-mode file read-only without the shared-memory file, so a read-only
      // open of this copy can fail outright with "unable to open database" — on
      // a file that is perfectly readable.
      //
      // Opening it writable lets SQLite recover the header itself. Safe because
      // this is OUR throwaway copy in the cache directory, deleted in `finally`;
      // nothing here writes to it, and the user's original file is never opened
      // at all beyond reading its bytes.
      db = await openDatabase(temp.path, readOnly: false, singleInstance: false);

      // Filtered here, at the source — NOT later
      //
      // The reasoning in music_db_schema.dart (see _safeIdentifier) was right but
      // applied one step too late: `resolveTable` and `resolveColumn` screen the
      // names they PICK, while the raw list was fed to
      // `PRAGMA table_info("$table")` below for EVERY name in the file first. A
      // backup is a file the user was given, so a crafted one could name a table
      // `x") --` and reach that query unscreened.
      //
      // sqflite's rawQuery prepares a single statement, so stacked SQL was not
      // executable — the practical worst case was a malformed or redirected
      // PRAGMA. That is still a hole in the one code path that parses untrusted
      // input, and screening at the source costs a comparison and closes it for
      // every downstream use at once, present and future.
      //
      // A skipped name is a table Auvy could not have read anyway: nothing legal
      // in a music schema needs a quote or a semicolon in its name.
      final tables = <String>{};
      var skipped = 0;
      for (final row in await db.rawQuery(
          "SELECT name FROM sqlite_master WHERE type='table'")) {
        final n = row['name'];
        if (n is! String) continue;
        if (!isSafeIdentifier(n)) {
          skipped++;
          continue;
        }
        tables.add(n);
      }
      if (skipped > 0) {
        print('WARN: import: skipped $skipped table name(s) that are not plain '
            'identifiers');
      }

      // What shape is this database?
      // Discovered, not assumed. See MusicDbMap: any player whose schema has
      // a track-shaped table can be read, including forks that renamed things.
      final map = await MusicDbMap.discoverWith(
          tables,
          (table) async => (await db!.rawQuery('PRAGMA table_info("$table")'))
              .map((r) => '${r['name']}')
              .toList());
      if (map == null) {
        print('WARN: import: no track table in (${tables.join(", ")})');
        return null;
      }
      print('import: mapped ${map.describe()}');

      final artistNames = await _artistNamesBySong(db, map);
      final songs = await _songs(db, map, artistNames);
      if (songs.isEmpty) {
        print('WARN: import: the track table is empty');
        return null;
      }

      final counts = await _playCounts(db, map);
      final log = await _playLog(db, map);
      // Metadata for every track with listening evidence, NOT just the ones
      // IN THE LIBRARY. The taste profile drops a play count for a track it has
      // no metadata for (nothing could render or recommend it), so counts for
      // tracks that were played but never liked or added were read, reported and
      // then silently discarded — 324 counted, ~229 kept. This carries exactly
      // the tracks that have a count or a play date: bounded by what was
      // actually listened to, not by the size of the browse cache.
      final evidenced = <String, Song>{
        for (final id in {...counts.keys, ...log.stamps.keys})
          if (songs[id] != null) id: songs[id]!,
      };
      final result = ImportedLibrary(
        sourceApp: _identify(tables),
        likedSongs: await _liked(db, map, songs),
        librarySongs: await _inLibrary(db, map, songs),
        playlists: await _playlists(db, map, songs),
        albums: await _albums(db, map),
        artists: await _followedArtists(db, map),
        playCounts: counts,
        history: await _history(db, map, songs),
        recognitions: await _recognitions(db, tables),
        playLog: log,
        searchHistory: await _searchHistory(db, map),
        tracksWithHistory: evidenced,
      );
      // What was actually found, so "it imported nothing" can be told apart from
      // "it could not read the file" without asking the user to try again.
      print('foreign backup: ${result.sourceApp} — ${songs.length} in the '
          'database, ${result.likedSongs.length} liked, '
          '${result.librarySongs.length} in library, '
          '${result.playlists.length} playlist(s), '
          '${result.albums.length} album(s), ${result.artists.length} artist(s), '
          '${result.playCounts.length} counted, ${result.playLog.stamps.length} with '
          'play dates, ${result.searchHistory.length} search(es)');
      return result;
    } catch (e) {
      // A malformed archive, an encrypted database, a schema we cannot read —
      // all "cannot import this file", none worth crashing a restore screen.
      print('WARN: foreign backup: unreadable ($e)');
      return null;
    } finally {
      try {
        await db?.close();
      } catch (_) {}
      try {
        if (temp != null && await temp.exists()) await temp.delete();
      } catch (_) {}
    }
  }

  /// Best-effort attribution for the confirmation screen, so the user is told
  /// what they are importing rather than just "a backup".
  ///
  /// A LABEL ONLY. Nothing about READING the file depends on recognising the
  /// app — the schema is discovered (see [MusicDbMap]). If a signature is not
  /// recognised the import proceeds exactly the same way and simply says so.
  static String _identify(Set<String> tables) {
    if (tables.contains('recognition_history') &&
        tables.contains('speed_dial_item')) {
      return 'Metrolist';
    }
    if (tables.contains('playlist_song_map') &&
        tables.contains('song_album_map')) {
      return 'an InnerTune-family player';
    }
    return 'another music app';
  }

  /// trackId → artist credits, in the source app's own order.
  static Future<Map<String, List<SongArtist>>> _artistNamesBySong(
      Database db, MusicDbMap map) async {
    final out = <String, List<SongArtist>>{};
    final link = map.trackArtists;
    final artists = map.artists;
    if (link == null || artists == null) return out;
    final songCol = link['song'], artistCol = link['artist'];
    final aId = artists['id'], aName = artists['title'];
    if (songCol == null || artistCol == null || aId == null || aName == null) {
      return out;
    }
    final order = link['position'] != null
        ? ' ORDER BY m."$songCol", m."${link['position']}"'
        : ' ORDER BY m."$songCol"';
    try {
      final rows = await db.rawQuery('SELECT m."$songCol" AS sid, '
          'a."$aName" AS name, a."$aId" AS aid '
          'FROM "${link.name}" m JOIN "${artists.name}" a '
          'ON a."$aId" = m."$artistCol"$order');
      for (final r in rows) {
        final sid = r['sid'];
        final name = r['name'];
        if (sid is! String || name is! String || name.isEmpty) continue;
        out.putIfAbsent(sid, () => []).add(
            SongArtist(name: name, id: (r['aid'] as String?) ?? ''));
      }
    } catch (_) {}
    return out;
  }

  /// Every track in the database, keyed by id — playlists and likes reference
  /// these rather than each carrying its own copy.
  static Future<Map<String, Song>> _songs(
      Database db, MusicDbMap map, Map<String, List<SongArtist>> credits) async {
    final out = <String, Song>{};
    final t = map.tracks;
    final idCol = t['id'], titleCol = t['title'];
    if (idCol == null || titleCol == null) return out;
    final rows = await db.query(t.name);
    for (final r in rows) {
      final id = r[idCol];
      final title = r[titleCol];
      if (id is! String || id.isEmpty || title is! String || title.isEmpty) {
        continue;
      }
      final artists = credits[id] ?? const <SongArtist>[];
      final joined = artists.map((a) => a.name).join(', ');
      // A row's own artist column, used when there is no artist TABLE to join —
      // which is how simpler players store it.
      final ownArtist = _col(r, t['artist']);
      final album = _col(r, t['albumName']);
      out[id] = Song(
        id: id,
        title: title,
        // Falls back to the row's own credit, then the album's, then nothing —
        // never to a fabricated "Unknown Artist", which would then be compared
        // against real credits by the now-playing matcher.
        artist: joined.isNotEmpty
            ? joined
            : (ownArtist.isNotEmpty ? ownArtist : album),
        image: _col(r, t['image']),
        albumId: _col(r, t['albumId']),
        albumTitle: album,
        releaseDate: t['year'] != null && r[t['year']!] is int
            ? '${r[t['year']!]}'
            : '',
        duration: _duration(t['duration'] == null ? null : r[t['duration']!]),
        isExplicit:
            t['explicit'] != null && _int(r[t['explicit']!]) == 1,
        artists: artists,
      );
    }
    return out;
  }

  /// Liked / favourited tracks. Falls back to "everything in the library" when
  /// the source app has no separate like flag at all.
  static Future<List<Song>> _liked(
      Database db, MusicDbMap map, Map<String, Song> songs) async {
    final t = map.tracks;
    final idCol = t['id'];
    final likedCol = t['liked'];
    if (idCol == null || likedCol == null) return const [];
    // A like is stored as a flag (0/1) by some apps and as a DATE by others; a
    // date is a large positive number, so "> 0" reads both correctly.
    final order = t['likedDate'] != null
        ? ' ORDER BY "${t['likedDate']}" DESC'
        : '';
    try {
      final rows = await db.rawQuery(
          'SELECT "$idCol" AS id FROM "${t.name}" '
          'WHERE "$likedCol" > 0$order');
      return _resolve(rows, songs, 'id');
    } catch (_) {
      return const [];
    }
  }

  static Future<List<Song>> _inLibrary(
      Database db, MusicDbMap map, Map<String, Song> songs) async {
    final t = map.tracks;
    final idCol = t['id'];
    final col = t['inLibrary'];
    if (idCol == null || col == null) return const [];
    try {
      final rows = await db.rawQuery('SELECT "$idCol" AS id FROM "${t.name}" '
          'WHERE "$col" IS NOT NULL AND "$col" > 0 ORDER BY "$col" DESC');
      return _resolve(rows, songs, 'id');
    } catch (_) {
      return const [];
    }
  }

  static Future<Map<String, List<Song>>> _playlists(
      Database db, MusicDbMap map, Map<String, Song> songs) async {
    final out = <String, List<Song>>{};
    final pl = map.playlists;
    final link = map.playlistTracks;
    if (pl == null || link == null) return out;
    final plId = pl['id'], plName = pl['title'];
    final linkPl = link['playlist'], linkSong = link['song'];
    if (plId == null || plName == null || linkPl == null || linkSong == null) {
      return out;
    }
    final order =
        link['position'] != null ? ' ORDER BY "${link['position']}"' : '';
    try {
      final playlists =
          await db.rawQuery('SELECT "$plId" AS id, "$plName" AS name '
              'FROM "${pl.name}"');
      for (final p in playlists) {
        final pid = p['id'];
        final name = p['name'];
        if (pid is! String || name is! String || name.trim().isEmpty) continue;
        final rows = await db.rawQuery(
            'SELECT "$linkSong" AS songId FROM "${link.name}" '
            'WHERE "$linkPl" = ?$order',
            [pid]);
        final tracks = _resolve(rows, songs, 'songId');
        // An empty playlist is not worth creating a row for on import; the user
        // asked for their music, not their scaffolding.
        if (tracks.isNotEmpty) out[name.trim()] = tracks;
      }
    } catch (_) {}
    return out;
  }

  static Future<List<ImportedAlbum>> _albums(
      Database db, MusicDbMap map) async {
    final t = map.albums;
    if (t == null) return const [];
    final idCol = t['id'], titleCol = t['title'];
    if (idCol == null || titleCol == null) return const [];
    // Only the ones they SAVED. Without a "saved" column every album the app
    // ever cached would be imported as a liked album.
    final savedCol = t['followedAt'];
    if (savedCol == null) return const [];
    try {
      final rows = await db.rawQuery('SELECT "$idCol" AS id, '
          '"$titleCol" AS title'
          '${t['image'] != null ? ', "${t['image']}" AS img' : ''}'
          '${t['year'] != null ? ', "${t['year']}" AS yr' : ''} '
          'FROM "${t.name}" WHERE "$savedCol" IS NOT NULL AND "$savedCol" > 0');
      return [
        for (final r in rows)
          if (_str(r['title']).isNotEmpty)
            ImportedAlbum(
              id: _str(r['id']),
              title: _str(r['title']),
              image: _str(r['img']),
              year: r['yr'] is int ? r['yr'] as int : null,
            ),
      ];
    } catch (_) {
      return const [];
    }
  }

  static Future<List<ImportedArtist>> _followedArtists(
      Database db, MusicDbMap map) async {
    final t = map.artists;
    if (t == null) return const [];
    final idCol = t['id'], nameCol = t['title'];
    final followedCol = t['followedAt'];
    if (idCol == null || nameCol == null || followedCol == null) {
      return const [];
    }
    try {
      final rows = await db.rawQuery('SELECT "$idCol" AS id, '
          '"$nameCol" AS name'
          '${t['image'] != null ? ', "${t['image']}" AS img' : ''} '
          'FROM "${t.name}" '
          'WHERE "$followedCol" IS NOT NULL AND "$followedCol" > 0');
      return [
        for (final r in rows)
          if (_str(r['name']).isNotEmpty)
            ImportedArtist(
              id: _str(r['id']),
              name: _str(r['name']),
              image: _str(r['img']),
            ),
      ];
    } catch (_) {
      return const [];
    }
  }

  /// Lifetime plays per track, from every source the database offers.
  ///
  /// ALL SOURCES, NOT THE FIRST ONE THAT ANSWERS. An earlier version used the
  /// monthly counter table and only fell back to the event log when that was
  /// EMPTY, and a real backup turned out to have zero counter rows and 779
  /// events, so a library with hundreds of tracked plays would have imported as
  /// "no listening history" and the taste profile got nothing.
  ///
  /// The sources answer slightly different questions and the highest wins:
  ///  • a counter table — the app's own lifetime total.
  ///  • an event log — one row per play, so a COUNT is a lower bound.
  ///  • total-play-time on the track — a track with real listening time but no
  ///    surviving events is still one they played, so it counts for as many whole
  ///    plays as its duration fits into. That is an inference, which is why it can
  ///    only ever RAISE a count derived from real rows.
  static Future<Map<String, int>> _playCounts(
      Database db, MusicDbMap map) async {
    final out = <String, int>{};
    void bump(Object? id, int n) {
      if (id is! String || id.isEmpty || n <= 0) return;
      if ((out[id] ?? 0) < n) out[id] = n;
    }

    final counts = map.playCounts;
    if (counts != null) {
      final idCol = counts['id'], nCol = counts['count'];
      if (idCol != null && nCol != null) {
        try {
          for (final r in await db.rawQuery('SELECT "$idCol" AS id, '
              'SUM("$nCol") AS n FROM "${counts.name}" GROUP BY "$idCol"')) {
            bump(r['id'], _int(r['n']));
          }
        } catch (_) {}
      }
    }

    final events = map.events;
    if (events != null && events['song'] != null) {
      try {
        for (final r in await db.rawQuery(
            'SELECT "${events['song']}" AS id, COUNT(*) AS n '
            'FROM "${events.name}" GROUP BY "${events['song']}"')) {
          bump(r['id'], _int(r['n']));
        }
      } catch (_) {}
    }

    final t = map.tracks;
    final playTime = t['totalPlayTime'];
    if (playTime != null && t['id'] != null && t['duration'] != null) {
      try {
        for (final r in await db.rawQuery('SELECT "${t['id']}" AS id, '
            '"$playTime" AS ms, "${t['duration']}" AS secs '
            'FROM "${t.name}" WHERE "$playTime" > 0')) {
          final secs = _int(r['secs']);
          if (secs <= 0) continue;
          bump(r['id'], _int(r['ms']) ~/ (secs * 1000));
        }
      } catch (_) {}
    }
    return out;
  }

  /// WHEN each track was played, from the event log.
  ///
  /// This is what makes an import feed the taste profile rather than just filling
  /// a number: first- and last-play stamps drive "discovered on", the listening
  /// clock, day streaks and the yearly wrap-up. Without them an import has to
  /// stamp everything "now", which makes months of listening look like it all
  /// happened this afternoon.
  static Future<ImportedPlayLog> _playLog(Database db, MusicDbMap map) async {
    final events = map.events;
    if (events == null) return const ImportedPlayLog({}, {}, {});
    final songCol = events['song'], tsCol = events['timestamp'];
    if (songCol == null || tsCol == null) {
      return const ImportedPlayLog({}, {}, {});
    }
    final stamps = <String, List<int>>{};
    try {
      for (final r in await db.rawQuery('SELECT "$songCol" AS id, '
          '"$tsCol" AS ts FROM "${events.name}" ORDER BY "$tsCol" DESC')) {
        final id = r['id'];
        var ts = _int(r['ts']);
        if (id is! String || id.isEmpty || ts <= 0) continue;
        // Seconds or milliseconds, depending on the app. Anything below this
        // threshold cannot be a millisecond timestamp in this century.
        if (ts < 100000000000) ts *= 1000;
        final list = stamps.putIfAbsent(id, () => <int>[]);
        // Capped per track exactly as recordPlay caps its own ledger, so an
        // import cannot bloat the stored profile.
        if (list.length < 120) list.add(ts);
      }
    } catch (_) {
      return const ImportedPlayLog({}, {}, {});
    }
    final first = <String, int>{};
    final last = <String, int>{};
    stamps.forEach((id, list) {
      list.sort();
      first[id] = list.first;
      last[id] = list.last;
    });
    return ImportedPlayLog(stamps, first, last);
  }

  /// Recently played, newest first — capped, because history is the one table
  /// that can hold tens of thousands of rows and none of it is worth an OOM.
  static Future<List<Song>> _history(
      Database db, MusicDbMap map, Map<String, Song> songs) async {
    final events = map.events;
    if (events == null) return const [];
    final songCol = events['song'], tsCol = events['timestamp'];
    if (songCol == null || tsCol == null) return const [];
    try {
      final rows = await db.rawQuery('SELECT "$songCol" AS songId, '
          'MAX("$tsCol") AS t FROM "${events.name}" GROUP BY "$songCol" '
          'ORDER BY t DESC LIMIT 200');
      return _resolve(rows, songs, 'songId');
    } catch (_) {
      return const [];
    }
  }

  /// What they searched for. Auvy keeps its own search history, so there is no
  /// reason for an import to arrive with an empty one.
  static Future<List<String>> _searchHistory(
      Database db, MusicDbMap map) async {
    final t = map.searches;
    if (t == null) return const [];
    final col = t['query'];
    if (col == null) return const [];
    try {
      final rows = await db.rawQuery(
          'SELECT "$col" AS q FROM "${t.name}" ORDER BY rowid DESC LIMIT 100');
      return [
        for (final r in rows)
          if (_str(r['q']).isNotEmpty) _str(r['q']),
      ];
    } catch (_) {
      return const [];
    }
  }

  /// Songs identified by a recognition feature, when the app has one. Matched by
  /// COLUMN NAME rather than by table, so any app storing title/artist/date rows
  /// under any table name is read.
  static Future<List<ImportedRecognition>> _recognitions(
      Database db, Set<String> tables) async {
    for (final name in tables) {
      if (!name.toLowerCase().contains('recogni')) continue;
      if (!isSafeIdentifier(name)) continue;
      try {
        final cols = (await db.rawQuery('PRAGMA table_info("$name")'))
            .map((r) => '${r['name']}')
            .toList();
        final resolved = resolveColumns(cols, {
          'title': ColumnAliases.title,
          'artist': ColumnAliases.artist,
          'image': ColumnAliases.image,
          'timestamp': ColumnAliases.timestamp,
        });
        final title = resolved['title'];
        if (title == null) continue;
        final artist = resolved['artist'];
        final img = resolved['image'];
        final ts = resolved['timestamp'];
        final rows = await db.rawQuery('SELECT "$title" AS t'
            '${artist != null ? ', "$artist" AS a' : ''}'
            '${img != null ? ', "$img" AS c' : ''}'
            '${ts != null ? ', "$ts" AS ms' : ''} '
            'FROM "$name"${ts != null ? ' ORDER BY "$ts" DESC' : ''} LIMIT 100');
        return [
          for (final r in rows)
            if (_str(r['t']).isNotEmpty)
              ImportedRecognition(
                title: _str(r['t']),
                artist: _str(r['a']),
                cover: _str(r['c']),
                atMs: _int(r['ms']),
              ),
        ];
      } catch (_) {
        // Try the next candidate table rather than giving up on the feature.
      }
    }
    return const [];
  }

  static List<Song> _resolve(
      List<Map<String, Object?>> rows, Map<String, Song> songs, String key) {
    final out = <Song>[];
    for (final r in rows) {
      final id = r[key];
      if (id is! String) continue;
      final song = songs[id];
      if (song != null) out.add(song);
    }
    return out;
  }

  static String _str(Object? v) => v is String ? v : '';
  static int _int(Object? v) => v is int ? v : (v is num ? v.toInt() : 0);

  /// Read a column that may not exist in this database.
  static String _col(Map<String, Object?> row, String? column) =>
      column == null ? '' : _str(row[column]);

  /// Seconds → "m:ss", matching what the rest of the app produces. Zero or
  /// missing becomes EMPTY rather than "0:00": every consumer reads an empty
  /// duration as "unknown" and skips it, whereas a zero would be summed into
  /// playlist runtimes and compared by the audio-match duration guard.
  ///
  /// Milliseconds are detected and converted — apps disagree about the unit, and
  /// a 227000-second track would render as "3783:20".
  static String _duration(Object? v) {
    var s = _int(v);
    if (s <= 0) return '';
    if (s > 36000) s = s ~/ 1000; // over 10 hours ⇒ it was milliseconds
    if (s <= 0) return '';
    final m = s ~/ 60;
    final rem = (s % 60).toString().padLeft(2, '0');
    return '$m:$rem';
  }
}

/// What a foreign backup turned out to contain. Plain data — no side effects.
class ImportedLibrary {
  final String sourceApp;
  final List<Song> likedSongs;
  final List<Song> librarySongs;
  final Map<String, List<Song>> playlists;
  final List<ImportedAlbum> albums;
  final List<ImportedArtist> artists;
  final Map<String, int> playCounts;
  final List<Song> history;
  final List<ImportedRecognition> recognitions;
  /// WHEN tracks were played, so an import can feed the taste profile with real
  /// dates instead of stamping everything "now".
  final ImportedPlayLog playLog;
  final List<String> searchHistory;
  /// Every track the backup has a play count or a play date for, so the taste
  /// profile has something to attach those numbers to.
  final Map<String, Song> tracksWithHistory;

  const ImportedLibrary({
    required this.sourceApp,
    required this.likedSongs,
    required this.librarySongs,
    required this.playlists,
    required this.albums,
    required this.artists,
    required this.playCounts,
    required this.history,
    required this.recognitions,
    this.playLog = const ImportedPlayLog({}, {}, {}),
    this.searchHistory = const [],
    this.tracksWithHistory = const {},
  });

  int get playlistTrackCount =>
      playlists.values.fold(0, (sum, list) => sum + list.length);

  /// Distinct tracks the import would bring in, for the confirmation line.
  int get trackCount {
    final ids = <String>{};
    for (final s in likedSongs) {
      ids.add(s.id);
    }
    for (final s in librarySongs) {
      ids.add(s.id);
    }
    for (final list in playlists.values) {
      for (final s in list) {
        ids.add(s.id);
      }
    }
    return ids.length;
  }

  bool get isEmpty =>
      likedSongs.isEmpty &&
      librarySongs.isEmpty &&
      playlists.isEmpty &&
      albums.isEmpty &&
      artists.isEmpty;
}

class ImportedAlbum {
  final String id;
  final String title;
  final String image;
  final int? year;
  const ImportedAlbum(
      {required this.id, required this.title, required this.image, this.year});
}

class ImportedArtist {
  final String id;
  final String name;
  final String image;
  const ImportedArtist(
      {required this.id, required this.name, required this.image});
}

class ImportedRecognition {
  final String title;
  final String artist;
  final String cover;
  final int atMs;
  const ImportedRecognition(
      {required this.title,
      required this.artist,
      required this.cover,
      required this.atMs});
}

/// The event log out of a foreign backup: per-track play timestamps, plus the
/// first and last of them. Empty when that app kept no event history.
class ImportedPlayLog {
  final Map<String, List<int>> stamps;
  final Map<String, int> firstPlayMs;
  final Map<String, int> lastPlayMs;
  const ImportedPlayLog(this.stamps, this.firstPlayMs, this.lastPlayMs);
  bool get isEmpty => stamps.isEmpty;
}
