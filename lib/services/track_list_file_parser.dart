import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';

/// Reads a list of songs out of another service's export file.
///
/// A Metrolist-family backup contains real video ids and is imported directly
/// ([ForeignBackupReader]). Other files (a Spotify data export, an Exportify
/// CSV, a playlist dumped to JSON) contain only names:
///
///     {"track": {"trackName": "Dandelions", "artistName": "Ruth B.", …}}
///
/// So this parser produces "Title Artist" search queries, and the caller
/// resolves them with the same matcher a pasted Spotify link uses
/// (`LibraryNotifier.resolveQueriesToSongs`). That costs one search per track,
/// minutes for a large export, so the caller shows progress.
///
/// Formats, detected by content rather than file name:
///
///  • Spotify data export: `Playlist1.json` (playlists → items → track),
///    `YourLibrary.json` (tracks / albums / artists), `Streaming_History*.json`
///    or `StreamingHistory*.json` (old and current shapes), loose or zipped.
///  • Exportify / generic CSV with a header naming a track and an artist column.
///  • Any JSON that is, or contains, a list of objects with title-like and
///    artist-like fields.
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
        // A Spotify export is many JSON files in one zip; every file that yields tracks
        // contributes, so one import covers playlists and likes.
        for (final entry in archive.files) {
          final name = entry.name.split('/').last;
          final lowerName = name.toLowerCase();
          final isJson = lowerName.endsWith('.json');
          final isCsv = lowerName.endsWith('.csv') || lowerName.endsWith('.tsv');
          final isM3u = lowerName.endsWith('.m3u') || lowerName.endsWith('.m3u8');
          if (!isJson && !isCsv && !isM3u) {
            continue;
          }
          // A whole Spotify export is a few MB of JSON; much larger entries aren't track
          // lists.
          if (entry.size > 40 * 1024 * 1024) continue;
          final text = _decodeUtf8(entry.content as List<int>);
          if (text == null) continue;
          final parsed = isM3u
              ? _parseM3u(text, name)
              : (isCsv ? _parseCsv(text, name) : _parseJsonText(text, name));
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
      final isCsv = lower.endsWith('.csv') || lower.endsWith('.tsv');
      final isM3u = lower.endsWith('.m3u') || lower.endsWith('.m3u8') || text.startsWith('#EXTM3U');
      final parsed = isM3u
          ? _parseM3u(text, file.path.split('/').last)
          : (isCsv
              ? _parseCsv(text, file.path.split('/').last)
              : _parseJsonText(text, file.path.split('/').last));
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
    // Deduplicate within each group while keeping order: playlist order matters,
    // and a Spotify export lists a re-added track twice.
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
      var text = utf8.decode(bytes, allowMalformed: true);
      if (text.startsWith('\uFEFF')) {
        text = text.substring(1);
      }
      return text;
    } catch (_) {
      return null;
    }
  }

  /// M3U and M3U8 playlist files.
  /// Handles #EXTINF tags (duration and Artist - Title) as well as bare filename/URL lines.
  static ParsedTrackFile? _parseM3u(String text, String filename) {
    final lines = const LineSplitter().convert(text);
    if (lines.isEmpty) return null;

    final queries = <String>[];
    String? pendingExtInf;

    for (final rawLine in lines) {
      final line = rawLine.trim();
      if (line.isEmpty) continue;

      if (line.startsWith('#EXTM3U')) continue;

      if (line.startsWith('#EXTINF:')) {
        final commaIdx = line.indexOf(',');
        if (commaIdx >= 0 && commaIdx + 1 < line.length) {
          pendingExtInf = line.substring(commaIdx + 1).trim();
        }
        continue;
      }

      if (line.startsWith('#')) continue;

      String trackDesc = pendingExtInf ?? '';
      pendingExtInf = null;

      if (trackDesc.isEmpty) {
        var base = line.split(Platform.isWindows ? '\\' : '/').last;
        if (base.contains('.')) {
          base = base.substring(0, base.lastIndexOf('.'));
        }
        trackDesc = base.trim();
      }

      if (trackDesc.isNotEmpty) {
        if (trackDesc.contains(' - ')) {
          final parts = trackDesc.split(' - ');
          final artist = parts.first.trim();
          final title = parts.sublist(1).join(' - ').trim();
          final q = _query(title, artist);
          if (q != null) queries.add(q);
        } else {
          final q = _query(trackDesc, '');
          if (q != null) queries.add(q);
        }
      }
    }

    if (queries.isEmpty) return null;
    print('TrackListParser: parsed ${queries.length} track(s) from M3U "$filename"');
    return ParsedTrackFile(
      sourceApp: 'M3U Playlist',
      groups: [
        ParsedGroup(
          name: _nameFromFilename(filename),
          kind: GroupKind.playlist,
          queries: queries,
        ),
      ],
    );
  }

  static ParsedTrackFile? _parseJsonText(String text, String filename) {
    dynamic json;
    try {
      json = jsonDecode(text);
    } catch (_) {
      return null;
    }

    // Spotify: Playlist1.json / Playlist2.json.
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

    // Spotify: YourLibrary.json.
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

    // Spotify: streaming history (both shapes). Not imported as a playlist: it's a
    // play log, often tens of thousands of rows. Only the distinct top tracks are
    // offered.
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
    final firstLine = lines.first;
    final commaHeader = _csvRow(firstLine, delimiter: ',');
    final semiHeader = _csvRow(firstLine, delimiter: ';');
    final tabHeader = _csvRow(firstLine, delimiter: '\t');
    String delimiter = ',';
    int maxCols = commaHeader.length;
    if (semiHeader.length > maxCols && firstLine.contains(';')) {
      delimiter = ';';
      maxCols = semiHeader.length;
    }
    if (tabHeader.length > maxCols && firstLine.contains('\t')) {
      delimiter = '\t';
      maxCols = tabHeader.length;
    }
    final header = (delimiter == '\t'
            ? tabHeader
            : (delimiter == ';' ? semiHeader : commaHeader))
        .map((h) => h.toLowerCase().trim())
        .toList();
    // Exact header matches first, and never an identifier column. A loose "header
    // contains 'track'" test would pick Exportify's first column, "Track URI", and
    // every query would become "spotify:track:… <artist>", matching nothing.
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
      final row = _csvRow(line, delimiter: delimiter);
      if (titleCol >= row.length) continue;
      final q = _query(row[titleCol],
          artistCol >= 0 && artistCol < row.length ? row[artistCol] : '');
      if (q != null) queries.add(q);
    }
    if (queries.isEmpty) return null;
    print('TrackListFileParser: parsed ${queries.length} tracks from $filename (delimiter: "$delimiter")');
    return ParsedTrackFile(sourceApp: delimiter == '\t' ? 'a TSV' : 'a CSV', groups: [
      ParsedGroup(
          name: _nameFromFilename(filename),
          kind: GroupKind.playlist,
          queries: queries),
    ]);
  }

  /// Splits one CSV line, honouring double quotes and doubled-quote escapes.
  /// Supports comma or semicolon delimiters.
  /// Hand-rolled rather than a package: this is the whole of CSV that a playlist
  /// export uses, and it is not worth a dependency.
  static List<String> _csvRow(String line, {String delimiter = ','}) {
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
      } else if (c == delimiter && !inQuotes) {
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

  static String _stripQuotes(String s) {
    var str = s.trim();
    if (str.length >= 2 &&
        ((str.startsWith('"') && str.endsWith('"')) ||
         (str.startsWith("'") && str.endsWith("'")))) {
      str = str.substring(1, str.length - 1).trim();
    }
    return str;
  }

  /// "Title Artist" — the shape [resolveQueriesToSongs] expects. Null when there
  /// is not enough to search for: a one-character title would match anything.
  static String? _query(String title, String artist) {
    final t = _stripQuotes(title);
    if (t.length < 2) return null;
    final a = _stripQuotes(artist);
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
