import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';

/// Reading a list of songs out of someone else's file
///
/// A Metrolist-family backup carries a database with real video ids, so it can
/// be imported outright ([ForeignBackupReader]). Everything ELSE a person is
/// likely to have — a Spotify "Download your data" export, an Exportify CSV, a
/// playlist someone dumped to JSON — carries only NAMES:
///
///     {"track": {"trackName": "Dandelions", "artistName": "Ruth B.", …}}
///
/// There is no id in there that Auvy could play, and there cannot be: those
/// files describe a different catalogue. So this parser's job stops at producing
/// "Title Artist" search queries, and the caller resolves them through the SAME
/// matcher a pasted Spotify link already uses
/// (`LibraryNotifier.resolveQueriesToSongs`).
///
/// THAT MEANS AN IMPORT FROM THESE FILES COSTS ONE SEARCH PER TRACK. It is
/// minutes for a large export, and the caller must show progress rather than
/// pretend otherwise. The alternative — inventing ids — produces a library of
/// rows that cannot play, which is worse than a slow import.
///
/// Formats understood, all detected by CONTENT rather than by filename, because
/// people rename files:
///
///  • Spotify data export — `Playlist1.json` (playlists → items → track),
///    `YourLibrary.json` (tracks / albums / artists), `Streaming_History*.json`
///    or `StreamingHistory*.json` (both the old and current shapes). Loose or
///    inside the export's zip.
///  • Exportify / generic CSV with a header naming a track and an artist column.
///  • Any JSON that is, or contains, a list of objects with a title-ish and an
///    artist-ish field.
class TrackListFileParser {
  TrackListFileParser._();

  /// Parse [file]; null when it holds nothing this can use.
  static Future<ParsedTrackFile?> parse(File file) async {
    try {
      final bytes = await file.readAsBytes();
      final isZip = bytes.length > 4 &&
          bytes[0] == 0x50 &&
          bytes[1] == 0x4B &&
          bytes[2] == 0x03 &&
          bytes[3] == 0x04;

      if (isZip) {
        final archive = ZipDecoder().decodeBytes(bytes);
        final groups = <ParsedGroup>[];
        var source = 'a backup';
        // A Spotify export is many json files in one zip; every one that yields
        // tracks contributes, so a single import covers playlists AND likes.
        for (final entry in archive.files) {
          final name = entry.name.split('/').last;
          if (!name.toLowerCase().endsWith('.json') &&
              !name.toLowerCase().endsWith('.csv')) {
            continue;
          }
          // A whole Spotify export is a few MB of json; anything vastly larger
          // in a zip is not a track list and is not worth decoding.
          if (entry.size > 40 * 1024 * 1024) continue;
          final text = _decodeUtf8(entry.content as List<int>);
          if (text == null) continue;
          final parsed = name.toLowerCase().endsWith('.csv')
              ? _parseCsv(text, name)
              : _parseJsonText(text, name);
          if (parsed != null) {
            groups.addAll(parsed.groups);
            if (parsed.sourceApp != 'a backup') source = parsed.sourceApp;
          }
        }
        if (groups.isEmpty) return null;
        return ParsedTrackFile(sourceApp: source, groups: _merge(groups));
      }

      final text = _decodeUtf8(bytes);
      if (text == null) return null;
      final lower = file.path.toLowerCase();
      final parsed = lower.endsWith('.csv')
          ? _parseCsv(text, file.path.split('/').last)
          : _parseJsonText(text, file.path.split('/').last);
      if (parsed == null || parsed.groups.isEmpty) return null;
      return ParsedTrackFile(
          sourceApp: parsed.sourceApp, groups: _merge(parsed.groups));
    } catch (_) {
      return null;
    }
  }

  /// Same-named groups from different files in one archive become one playlist.
  static List<ParsedGroup> _merge(List<ParsedGroup> groups) {
    final byName = <String, ParsedGroup>{};
    for (final g in groups) {
      if (g.queries.isEmpty) continue;
      final existing = byName[g.name];
      if (existing == null) {
        byName[g.name] = g;
      } else {
        byName[g.name] = ParsedGroup(
          name: g.name,
          kind: existing.kind,
          queries: [...existing.queries, ...g.queries],
        );
      }
    }
    // Deduplicate inside each group while KEEPING ORDER — a playlist's order is
    // information, and a Spotify export lists a re-added track twice.
    return [
      for (final g in byName.values)
        ParsedGroup(
          name: g.name,
          kind: g.kind,
          queries: {for (final q in g.queries) q}.toList(),
        ),
    ];
  }

  static String? _decodeUtf8(List<int> bytes) {
    try {
      return utf8.decode(bytes, allowMalformed: true);
    } catch (_) {
      return null;
    }
  }

  static ParsedTrackFile? _parseJsonText(String text, String filename) {
    dynamic json;
    try {
      json = jsonDecode(text);
    } catch (_) {
      return null;
    }

    // Spotify: Playlist1.json / Playlist2.json
    if (json is Map && json['playlists'] is List) {
      final groups = <ParsedGroup>[];
      for (final p in json['playlists'] as List) {
        if (p is! Map) continue;
        final name = _str(p['name']);
        final items = p['items'];
        if (items is! List) continue;
        final queries = <String>[];
        for (final item in items) {
          if (item is! Map) continue;
          final track = item['track'];
          if (track is Map) {
            final q = _query(_str(track['trackName']), _str(track['artistName']));
            if (q != null) queries.add(q);
            continue;
          }
          // A local file or a podcast episode in a playlist — a title alone is
          // still worth trying, an episode is not.
          final local = item['localTrack'];
          if (local is Map) {
            final q = _query(_str(local['trackName']), _str(local['artistName']));
            if (q != null) queries.add(q);
          }
        }
        if (queries.isNotEmpty) {
          groups.add(ParsedGroup(
              name: name.isEmpty ? 'Spotify playlist' : name,
              kind: GroupKind.playlist,
              queries: queries));
        }
      }
      if (groups.isNotEmpty) {
        return ParsedTrackFile(sourceApp: 'Spotify', groups: groups);
      }
    }

    // Spotify: YourLibrary.json
    if (json is Map && (json['tracks'] is List || json['albums'] is List)) {
      final groups = <ParsedGroup>[];
      final tracks = json['tracks'];
      if (tracks is List) {
        final queries = <String>[];
        for (final t in tracks) {
          if (t is! Map) continue;
          final q = _query(_str(t['track']), _str(t['artist']));
          if (q != null) queries.add(q);
        }
        if (queries.isNotEmpty) {
          groups.add(ParsedGroup(
              name: 'Liked Songs',
              kind: GroupKind.liked,
              queries: queries));
        }
      }
      if (groups.isNotEmpty) {
        return ParsedTrackFile(sourceApp: 'Spotify', groups: groups);
      }
    }

    // Spotify: streaming history (both shapes)
    // Deliberately NOT imported as a playlist: it is a play LOG, often tens of
    // thousands of rows, and turning it into a playlist would produce something
    // nobody asked for. Only the distinct top tracks are offered.
    if (json is List &&
        json.isNotEmpty &&
        json.first is Map &&
        ((json.first as Map).containsKey('msPlayed') ||
            (json.first as Map).containsKey('ms_played'))) {
      final counts = <String, int>{};
      for (final row in json) {
        if (row is! Map) continue;
        final title = _str(row['trackName']).isNotEmpty
            ? _str(row['trackName'])
            : _str(row['master_metadata_track_name']);
        final artist = _str(row['artistName']).isNotEmpty
            ? _str(row['artistName'])
            : _str(row['master_metadata_album_artist_name']);
        final ms = _int(row['msPlayed']) + _int(row['ms_played']);
        // Under 30 seconds is a skip, not a listen — the same threshold
        // scrobbling has used for twenty years.
        if (ms < 30000) continue;
        final q = _query(title, artist);
        if (q == null) continue;
        counts[q] = (counts[q] ?? 0) + 1;
      }
      if (counts.isNotEmpty) {
        final ranked = counts.entries.toList()
          ..sort((a, b) => b.value.compareTo(a.value));
        return ParsedTrackFile(sourceApp: 'Spotify', groups: [
          ParsedGroup(
            name: 'Spotify Most Played',
            kind: GroupKind.playlist,
            // Capped: this is a "here is your history as a playlist" nicety, and
            // every entry costs a search to resolve.
            queries: [for (final e in ranked.take(100)) e.key],
          ),
        ]);
      }
    }

    // Anything else: find a list of track-shaped objects
    final generic = _genericTracks(json);
    if (generic.isNotEmpty) {
      return ParsedTrackFile(sourceApp: 'a file', groups: [
        ParsedGroup(
            name: _nameFromFilename(filename),
            kind: GroupKind.playlist,
            queries: generic),
      ]);
    }
    return null;
  }

  /// Walks a decoded JSON tree (bounded depth) for the first list of objects
  /// that look like tracks. Deliberately shallow: this is a best-effort
  /// convenience for hand-made files, not a schema inference engine.
  static List<String> _genericTracks(dynamic node, [int depth = 0]) {
    if (depth > 4) return const [];
    if (node is List) {
      final queries = <String>[];
      for (final item in node) {
        if (item is Map) {
          final q = _queryFromLooseMap(item);
          if (q != null) queries.add(q);
        }
      }
      if (queries.length >= 2) return queries;
      for (final item in node) {
        final nested = _genericTracks(item, depth + 1);
        if (nested.isNotEmpty) return nested;
      }
      return const [];
    }
    if (node is Map) {
      for (final v in node.values) {
        final nested = _genericTracks(v, depth + 1);
        if (nested.isNotEmpty) return nested;
      }
    }
    return const [];
  }

  static const List<String> _titleKeys = [
    'trackName', 'track_name', 'track', 'title', 'songName', 'song', 'name'
  ];
  static const List<String> _artistKeys = [
    'artistName', 'artist_name', 'artist', 'artists', 'albumArtist',
    'album_artist', 'creator'
  ];

  static String? _queryFromLooseMap(Map map) {
    // A nested {"track": {...}} wrapper, as Spotify uses.
    for (final key in ['track', 'song', 'item']) {
      final inner = map[key];
      if (inner is Map) {
        final q = _queryFromLooseMap(inner);
        if (q != null) return q;
      }
    }
    String title = '';
    for (final k in _titleKeys) {
      final v = map[k];
      if (v is String && v.trim().isNotEmpty) {
        title = v.trim();
        break;
      }
    }
    if (title.isEmpty) return null;
    String artist = '';
    for (final k in _artistKeys) {
      final v = map[k];
      if (v is String && v.trim().isNotEmpty) {
        artist = v.trim();
        break;
      }
      if (v is List && v.isNotEmpty) {
        final first = v.first;
        if (first is String) {
          artist = first;
          break;
        }
        if (first is Map) {
          final n = first['name'];
          if (n is String) {
            artist = n;
            break;
          }
        }
      }
    }
    return _query(title, artist);
  }

  /// CSV with a header row — Exportify's "Track Name","Artist Name(s)" and
  /// anything shaped like it.
  static ParsedTrackFile? _parseCsv(String text, String filename) {
    final lines = const LineSplitter().convert(text);
    if (lines.length < 2) return null;
    final header = _csvRow(lines.first).map((h) => h.toLowerCase().trim()).toList();
    // Exact header matches first, AND never an identifier column.
    //
    // A single loose "does the header contain 'track'" test picks Exportify's
    // FIRST column, "Track URI", and every imported query becomes
    // "spotify:track:… <artist>" — a search for a string no catalogue contains,
    // so the import silently matches nothing. Ranked matching plus an
    // identifier blocklist is what makes the right column win.
    bool isIdentifier(String h) =>
        h.contains('uri') ||
        h.contains('url') ||
        h.contains('isrc') ||
        h.endsWith(' id') ||
        h == 'id';
    int findCol(List<String> wants) {
      for (final w in wants) {
        for (var i = 0; i < header.length; i++) {
          if (!isIdentifier(header[i]) && header[i] == w) return i;
        }
      }
      for (final w in wants) {
        for (var i = 0; i < header.length; i++) {
          if (!isIdentifier(header[i]) && header[i].contains(w)) return i;
        }
      }
      return -1;
    }

    final titleCol = findCol(['track name', 'title', 'song', 'name', 'track']);
    final artistCol = findCol(['artist name', 'artist', 'artists']);
    if (titleCol < 0) return null;

    final queries = <String>[];
    for (final line in lines.skip(1)) {
      if (line.trim().isEmpty) continue;
      final row = _csvRow(line);
      if (titleCol >= row.length) continue;
      final q = _query(row[titleCol],
          artistCol >= 0 && artistCol < row.length ? row[artistCol] : '');
      if (q != null) queries.add(q);
    }
    if (queries.isEmpty) return null;
    return ParsedTrackFile(sourceApp: 'a CSV', groups: [
      ParsedGroup(
          name: _nameFromFilename(filename),
          kind: GroupKind.playlist,
          queries: queries),
    ]);
  }

  /// Splits one CSV line, honouring double quotes and doubled-quote escapes.
  /// Hand-rolled rather than a package: this is the whole of CSV that a playlist
  /// export uses, and it is not worth a dependency.
  static List<String> _csvRow(String line) {
    final out = <String>[];
    final sb = StringBuffer();
    var inQuotes = false;
    for (var i = 0; i < line.length; i++) {
      final c = line[i];
      if (c == '"') {
        if (inQuotes && i + 1 < line.length && line[i + 1] == '"') {
          sb.write('"');
          i++;
        } else {
          inQuotes = !inQuotes;
        }
      } else if (c == ',' && !inQuotes) {
        out.add(sb.toString().trim());
        sb.clear();
      } else {
        sb.write(c);
      }
    }
    out.add(sb.toString().trim());
    return out;
  }

  static String _nameFromFilename(String filename) {
    var n = filename.split('/').last;
    final dot = n.lastIndexOf('.');
    if (dot > 0) n = n.substring(0, dot);
    n = n.replaceAll('_', ' ').replaceAll('-', ' ').trim();
    return n.isEmpty ? 'Imported' : n;
  }

  /// "Title Artist" — the shape [resolveQueriesToSongs] expects. Null when there
  /// is not enough to search for: a one-character title would match anything.
  static String? _query(String title, String artist) {
    final t = title.trim();
    if (t.length < 2) return null;
    final a = artist.trim();
    return a.isEmpty ? t : '$t $a';
  }

  static String _str(Object? v) => v is String ? v.trim() : '';
  static int _int(Object? v) => v is int ? v : (v is num ? v.toInt() : 0);
}

enum GroupKind { playlist, liked }

class ParsedGroup {
  final String name;
  final GroupKind kind;
  final List<String> queries;
  const ParsedGroup(
      {required this.name, required this.kind, required this.queries});
}

class ParsedTrackFile {
  final String sourceApp;
  final List<ParsedGroup> groups;
  const ParsedTrackFile({required this.sourceApp, required this.groups});

  int get trackCount =>
      groups.fold(0, (sum, g) => sum + g.queries.length);
}
