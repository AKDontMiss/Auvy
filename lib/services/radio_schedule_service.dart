import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:auvy/data/dummy_data.dart';
import 'package:auvy/services/http_pool.dart';
import 'package:auvy/services/icy_metadata_service.dart';

/// Represents a broadcast program slot in a radio station schedule with minute precision.
class RadioProgram {
  final String title;
  final String host;
  final String description;
  final int startHour;
  final int startMinute;
  final int endHour;
  final int endMinute;
  final String timeRange;
  final bool isLiveNow;
  final double progress;
  final int elapsedMinutes;
  final int remainingMinutes;
  final int durationMinutes;
  final String? liveStreamTitle;
  final String? streamBitrate;
  final String? imageUrl;
  final bool isOfficialSchedule;

  const RadioProgram({
    required this.title,
    required this.host,
    required this.description,
    required this.startHour,
    required this.startMinute,
    required this.endHour,
    required this.endMinute,
    required this.timeRange,
    required this.isLiveNow,
    this.progress = 0.0,
    this.elapsedMinutes = 0,
    this.remainingMinutes = 0,
    this.durationMinutes = 0,
    this.liveStreamTitle,
    this.streamBitrate,
    this.imageUrl,
    this.isOfficialSchedule = false,
  });

  RadioProgram copyWith({
    String? title,
    String? host,
    String? description,
    int? startHour,
    int? startMinute,
    int? endHour,
    int? endMinute,
    String? timeRange,
    bool? isLiveNow,
    double? progress,
    int? elapsedMinutes,
    int? remainingMinutes,
    int? durationMinutes,
    String? liveStreamTitle,
    String? streamBitrate,
    String? imageUrl,
    bool? isOfficialSchedule,
  }) {
    return RadioProgram(
      title: title ?? this.title,
      host: host ?? this.host,
      description: description ?? this.description,
      startHour: startHour ?? this.startHour,
      startMinute: startMinute ?? this.startMinute,
      endHour: endHour ?? this.endHour,
      endMinute: endMinute ?? this.endMinute,
      timeRange: timeRange ?? this.timeRange,
      isLiveNow: isLiveNow ?? this.isLiveNow,
      progress: progress ?? this.progress,
      elapsedMinutes: elapsedMinutes ?? this.elapsedMinutes,
      remainingMinutes: remainingMinutes ?? this.remainingMinutes,
      durationMinutes: durationMinutes ?? this.durationMinutes,
      liveStreamTitle: liveStreamTitle ?? this.liveStreamTitle,
      streamBitrate: streamBitrate ?? this.streamBitrate,
      imageUrl: imageUrl ?? this.imageUrl,
      isOfficialSchedule: isOfficialSchedule ?? this.isOfficialSchedule,
    );
  }
}

/// Service that provides authentic minute-precision broadcast schedules and live stream metadata.
class RadioScheduleService {
  static final Map<String, List<RadioProgram>> _scheduleCache = {};

  /// Cache key for the 5-minute window [at] falls in.
  ///
  /// ONE PLACE, because the same expression was written out at four call sites
  /// and a cache whose key is spelled differently in two of them is a cache
  /// that silently never hits.
  static String _bucketKey(String songId, DateTime at) =>
      '${songId}_${at.day}_${at.hour}_${at.minute ~/ 5}';

  /// Stores a schedule and drops this station's earlier windows. The key changes
  /// every five minutes (which is what advances the countdowns), so without
  /// dropping old windows the map gained an entry per station every five minutes
  /// for the life of the process. Now it holds one entry per station played.
  static void _putSchedule(String songId, String cacheKey, List<RadioProgram> schedule) {
    _scheduleCache.removeWhere(
        (k, _) => k.startsWith('${songId}_') && k != cacheKey);
    _scheduleCache[cacheKey] = schedule;
  }

  static final Map<String, List<RadioProgram>> _officialScheduleCache = {};
  static final Map<String, DateTime> _officialScheduleFetchedAt = {};
  static final ValueNotifier<int> liveIcyUpdateNotifier = ValueNotifier<int>(0);

  /// Detects whether this station belongs to Sveriges Radio (SR) and resolves its channel ID.
  static int? detectSrChannelId(Song song) {
    final url = song.id.toLowerCase();
    final title = song.title.toLowerCase();
    final album = song.albumTitle.toLowerCase();

    final isSr = url.contains('sr.se') ||
        url.contains('sverigesradio') ||
        title.contains('sveriges radio') ||
        title.startsWith('sr ') ||
        album.contains('sveriges radio');
    if (!isSr) return null;

    // Check direct numeric ID in stream URL (e.g. srapi/132.mp3, 132-hi-mp3)
    final urlIdMatch =
        RegExp(r'(?:srapi|sspar|channelid=|\/)(\d{3,4})(?:\.|\b|-)').firstMatch(url);
    if (urlIdMatch != null) {
      final parsed = int.tryParse(urlIdMatch.group(1)!);
      if (parsed != null && parsed > 100) return parsed;
    }

    final combined = '$title $url $album';
    if (combined.contains('p1')) return 132;
    if (combined.contains('p2 musik')) return 562;
    if (combined.contains('p2')) return 163;
    if (combined.contains('din gata')) return 576;
    if (combined.contains('p3')) return 164;
    if (combined.contains('p4 plus')) return 951;
    if (combined.contains('p4 stockholm')) return 701;
    if (combined.contains('p4 göteborg') || combined.contains('p4 goteborg')) return 212;
    if (combined.contains('p4 malmö') || combined.contains('p4 malmo')) return 207;
    if (combined.contains('p4 blekinge')) return 213;
    if (combined.contains('p4 dalarna')) return 223;
    if (combined.contains('p4 gotland')) return 205;
    if (combined.contains('p4 gävleborg') || combined.contains('p4 gavleborg')) return 210;
    if (combined.contains('p4 halland')) return 220;
    if (combined.contains('p4 jämtland') || combined.contains('p4 jamtland')) return 200;
    if (combined.contains('p4 jönköping') || combined.contains('p4 jonkoping')) return 203;
    if (combined.contains('p4 kalmar')) return 201;
    if (combined.contains('p4 kristianstad')) return 211;
    if (combined.contains('p4 kronoberg')) return 214;
    if (combined.contains('p4 norrbotten')) return 209;
    if (combined.contains('p4 sjuhärad') || combined.contains('p4 sjuharad')) return 206;
    if (combined.contains('p4 skaraborg')) return 208;
    if (combined.contains('p4 sörmland') || combined.contains('p4 sormland')) return 202;
    if (combined.contains('p4 uppland')) return 218;
    if (combined.contains('p4 värmland') || combined.contains('p4 varmland')) return 204;
    if (combined.contains('p4 väst') || combined.contains('p4 vast')) return 219;
    if (combined.contains('p4 västerbotten') || combined.contains('p4 vasterbotten')) return 215;
    if (combined.contains('p4 västernorrland') || combined.contains('p4 vasternorrland')) return 216;
    if (combined.contains('p4 västmanland') || combined.contains('p4 vastmanland')) return 217;
    if (combined.contains('p4 örebro') || combined.contains('p4 orebro')) return 221;
    if (combined.contains('p4 östergötland') || combined.contains('p4 ostergotland')) return 222;
    if (combined.contains('p4')) return 701;
    if (combined.contains('p6')) return 166;

    // Default to P1 for national Swedish Radio
    return 132;
  }

  /// Fetches authentic broadcast schedule from Sveriges Radio's official Open API.
  static Future<List<RadioProgram>?> _fetchSrSchedule(Song song, int channelId) async {
    try {
      final now = DateTime.now();
      final dateStr =
          '${now.year}-${now.month.toString().padLeft(2, '0')}-${now.day.toString().padLeft(2, '0')}';
      final uri = Uri.parse(
          'https://api.sr.se/api/v2/scheduledepisodes?channelid=$channelId&date=$dateStr&format=json&size=100');

      final res = await HttpPool()
          .getClient()
          .get(uri)
          .timeout(const Duration(seconds: 8));
      if (res.statusCode != 200) return null;

      final data = jsonDecode(utf8.decode(res.bodyBytes)) as Map<String, dynamic>;
      final scheduleRaw = data['schedule'] as List<dynamic>?;
      if (scheduleRaw == null || scheduleRaw.isEmpty) return null;

      DateTime? parseSrDate(String? raw) {
        if (raw == null) return null;
        final match = RegExp(r'/Date\((\d+)\)/').firstMatch(raw);
        if (match != null) {
          final ms = int.tryParse(match.group(1)!);
          if (ms != null) {
            return DateTime.fromMillisecondsSinceEpoch(ms, isUtc: true).toLocal();
          }
        }
        return DateTime.tryParse(raw)?.toLocal();
      }

      final List<RadioProgram> programs = [];
      final icy = IcyMetadataService.getCached(song.id);

      for (final item in scheduleRaw) {
        if (item is! Map<String, dynamic>) continue;
        final start = parseSrDate(item['starttimeutc'] as String?);
        final end = parseSrDate(item['endtimeutc'] as String?);
        if (start == null || end == null) continue;

        final title = (item['title'] as String? ?? '').trim();
        if (title.isEmpty) continue;
        final desc = (item['description'] as String? ?? '').trim();
        final progName = (item['program']?['name'] as String? ?? '').trim();
        final img = item['socialimage'] as String?;

        final isLive = now.isAfter(start) && now.isBefore(end);
        final duration = end.difference(start).inMinutes;
        final safeDuration = duration > 0 ? duration : 30;
        final elapsed = isLive ? now.difference(start).inMinutes.clamp(0, safeDuration) : 0;
        final remaining = (safeDuration - elapsed).clamp(0, safeDuration);
        final progress = safeDuration > 0 ? (elapsed / safeDuration).clamp(0.0, 1.0) : 0.0;

        final startStr =
            '${start.hour.toString().padLeft(2, '0')}:${start.minute.toString().padLeft(2, '0')}';
        final endStr =
            '${end.hour.toString().padLeft(2, '0')}:${end.minute.toString().padLeft(2, '0')}';

        String? streamTitle;
        String? bitrate;
        if (isLive && icy != null) {
          if (icy.streamTitle != null && icy.streamTitle!.isNotEmpty) {
            streamTitle = icy.streamTitle;
          }
          if (icy.bitrate != null && icy.bitrate!.isNotEmpty) {
            bitrate = '${icy.bitrate} kbps';
          }
        }

        programs.add(RadioProgram(
          title: title,
          host: progName.isNotEmpty ? progName : song.title,
          description: desc,
          startHour: start.hour,
          startMinute: start.minute,
          endHour: end.hour,
          endMinute: end.minute,
          timeRange: '$startStr - $endStr',
          isLiveNow: isLive,
          progress: progress,
          elapsedMinutes: elapsed,
          remainingMinutes: remaining,
          durationMinutes: safeDuration,
          liveStreamTitle: streamTitle,
          streamBitrate: bitrate,
          imageUrl: img,
          isOfficialSchedule: true,
        ));
      }

      if (programs.isEmpty) return null;
      return programs;
    } catch (_) {
      return null;
    }
  }

  /// Triggers background retrieval of official broadcast schedules if supported for this station.
  static Future<void> _fetchOfficialScheduleIfSupported(
    Song song,
    VoidCallback onUpdated, {
    bool force = false,
  }) async {
    final channelId = detectSrChannelId(song);
    if (channelId == null) return;

    final lastFetched = _officialScheduleFetchedAt[song.id];
    final now = DateTime.now();
    if (!force &&
        lastFetched != null &&
        lastFetched.day == now.day &&
        now.difference(lastFetched) < const Duration(minutes: 30)) {
      return;
    }

    final official = await _fetchSrSchedule(song, channelId);
    if (official != null && official.isNotEmpty) {
      _officialScheduleCache[song.id] = official;
      _officialScheduleFetchedAt[song.id] = DateTime.now();
      _scheduleCache.clear();
      liveIcyUpdateNotifier.value++;
      onUpdated();
    }
  }

  /// Asynchronously fetches live ICY metadata and official station schedule.
  static Future<void> refreshLiveMetadata(
    Song song,
    VoidCallback onUpdated, {
    bool force = false,
    bool isCurrentlyPlaying = false,
  }) async {
    if (!song.id.startsWith('http')) return;
    try {
      // Refresh does two separate things, and only one of them is unsafe while
      // playing, so they're gated separately (the player page always passes
      // isCurrentlyPlaying: true, so gating both on it made refresh do nothing).
      if (force) {
        // Derived state only. Clearing it just makes the card recompute from
        // the ICY data already in hand, touches no socket, and is what the user
        // is asking for when they press refresh.
        _scheduleCache.clear();
        // This one must stay gated: invalidating the ICY cache makes the next
        // fetchMetadata open a second connection to the stream, and single-connection
        // Shoutcast/Icecast servers then drop the player's socket (a one-second
        // dropout). While playing it gains nothing anyway, since the native ICY
        // listener keeps the cache current.
        if (!isCurrentlyPlaying) {
          IcyMetadataService.invalidate(song.id);
        }
        print('radio schedule refresh (force): recomputed schedule'
            '${isCurrentlyPlaying ? "" : ", invalidated ICY cache"}'
            ' for "${song.title}"');
      }

      // 1. Kick off official schedule query (Sveriges Radio etc.)
      _fetchOfficialScheduleIfSupported(song, onUpdated, force: force);

      // 2. Fetch live stream ICY info (real on-air track title & bitrate)
      final meta = await IcyMetadataService.fetchMetadata(
        song.id,
        isCurrentlyPlaying: isCurrentlyPlaying,
      );
      if (meta != null && !meta.isEmpty) {
        final now = DateTime.now();
        final cacheKey = _bucketKey(song.id, now);
        _scheduleCache.remove(cacheKey);
        onUpdated();
      }
    } catch (_) {}
  }

  /// Called when native ExoPlayer reports ICY metadata on the active stream.
  static void onNativeIcyMetadata(Song song, VoidCallback? onUpdated) {
    if (!song.id.startsWith('http')) return;
    final now = DateTime.now();
    final cacheKey = _bucketKey(song.id, now);
    _scheduleCache.remove(cacheKey);
    liveIcyUpdateNotifier.value++;
    onUpdated?.call();
  }

  /// Generates the schedule for the station: prioritizes official broadcast schedules
  /// when available, and generates genuine on-air blocks when an API is not present.
  static List<RadioProgram> getScheduleForStation(Song song) {
    final now = DateTime.now();
    final currentHour = now.hour;
    final currentMinute = now.minute;
    final nowMins = currentHour * 60 + currentMinute;
    final stationName = song.title.trim().isEmpty ? 'Radio' : song.title.trim();

    // 1. If official schedule is cached and from today, evaluate live progress dynamically with minute precision
    final lastFetched = _officialScheduleFetchedAt[song.id];
    final isFromToday = lastFetched != null &&
        lastFetched.year == now.year &&
        lastFetched.month == now.month &&
        lastFetched.day == now.day;
    if (!isFromToday && _officialScheduleCache.containsKey(song.id)) {
      print('RadioScheduleService: ignoring stale official schedule from previous day for ${song.title}');
    }
    if (isFromToday && _officialScheduleCache.containsKey(song.id)) {
      final cachedList = _officialScheduleCache[song.id]!;
      final icy = IcyMetadataService.getCached(song.id);
      final List<RadioProgram> updated = [];

      for (final p in cachedList) {
        final startMins = p.startHour * 60 + p.startMinute;
        int endMins = p.endHour * 60 + p.endMinute;
        if (endMins <= startMins) endMins += 24 * 60;

        bool isLive = false;
        int elapsed = 0;
        if (startMins < (p.endHour * 60 + p.endMinute)) {
          isLive = nowMins >= startMins && nowMins < endMins;
          if (isLive) elapsed = (nowMins - startMins).clamp(0, p.durationMinutes);
        } else {
          final adjustedNow = (nowMins < startMins) ? (nowMins + 24 * 60) : nowMins;
          isLive = adjustedNow >= startMins && adjustedNow < endMins;
          if (isLive) elapsed = (adjustedNow - startMins).clamp(0, p.durationMinutes);
        }

        final remaining = (p.durationMinutes - elapsed).clamp(0, p.durationMinutes);
        final progress = p.durationMinutes > 0
            ? (elapsed / p.durationMinutes).clamp(0.0, 1.0)
            : 0.0;

        String? streamTitle;
        String? bitrate;
        if (isLive && icy != null) {
          if (icy.streamTitle != null && icy.streamTitle!.isNotEmpty) {
            streamTitle = icy.streamTitle;
          }
          if (icy.bitrate != null && icy.bitrate!.isNotEmpty) {
            bitrate = '${icy.bitrate} kbps';
          }
        }

        updated.add(p.copyWith(
          isLiveNow: isLive,
          progress: progress,
          elapsedMinutes: elapsed,
          remainingMinutes: remaining,
          liveStreamTitle: streamTitle ?? p.liveStreamTitle,
          streamBitrate: bitrate ?? p.streamBitrate,
        ));
      }

      final liveIndex = updated.indexWhere((p) => p.isLiveNow);
      if (liveIndex != -1) {
        return [
          ...updated.sublist(liveIndex),
          ...updated.sublist(0, liveIndex),
        ];
      }
      return updated;
    }

    // 2. Cache key valid for 5-minute precision windows
    final cacheKey = _bucketKey(song.id, now);
    if (_scheduleCache.containsKey(cacheKey)) {
      return _scheduleCache[cacheKey]!;
    }

    // 3. No schedule published: report what is known and invent nothing. That is
    // the station, its genre and country from the station record, and the current
    // track from ICY when the stream sends one. One live entry with zero duration
    // and progress, telling the card there's no time slot to count down.
    // stationName is already in scope from the top of this method.
    final icy = IcyMetadataService.getCached(song.id);

    // A real on-air track if the stream is sending one, otherwise the station
    // itself. Never a programme name, because we do not have one.
    final live = icy?.streamTitle?.trim();
    final title = (live != null && live.isNotEmpty) ? live : stationName;

    // Only real attributes, joined with what the station record already says.
    final facts = <String>[
      if (song.albumTitle.trim().isNotEmpty) song.albumTitle.trim(),
      if (icy?.genre != null && icy!.genre!.trim().isNotEmpty) icy.genre!.trim(),
      if (icy?.description != null && icy!.description!.trim().isNotEmpty)
        icy.description!.trim(),
    ];
    // Deduplicate: the station genre and the ICY genre are usually the same word.
    final seen = <String>{};
    final description = facts
        .where((f) => seen.add(f.toLowerCase()))
        .join(' · ');

    final schedule = <RadioProgram>[
      RadioProgram(
        title: title,
        host: stationName,
        description: description,
        // No published boundaries, so none are claimed. The card reads
        // durationMinutes == 0 as "continuous, nothing to count down".
        startHour: 0,
        startMinute: 0,
        endHour: 0,
        endMinute: 0,
        timeRange: '',
        isLiveNow: true,
        progress: 0.0,
        elapsedMinutes: 0,
        remainingMinutes: 0,
        durationMinutes: 0,
        liveStreamTitle: live,
        streamBitrate: icy?.bitrate,
        isOfficialSchedule: false,
      ),
    ];
    _putSchedule(song.id, cacheKey, schedule);
    return schedule;
  }

}
