import 'package:auvy/services/listening_policy.dart';
import 'package:flutter/material.dart';
import 'package:auvy/presentation/widgets/now_playing_row.dart';
import 'package:auvy/services/search_service.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:auvy/data/dummy_data.dart';
import 'package:auvy/data/artist_model.dart';
import 'package:auvy/core/app_navigation.dart';
import 'package:auvy/presentation/pages/album_page.dart';
import 'package:auvy/presentation/pages/artist_page.dart';
import 'package:auvy/presentation/pages/wrapped_page.dart';
import 'package:auvy/presentation/main_layout.dart';
import 'package:auvy/presentation/widgets/auvy_image.dart';
import 'package:auvy/presentation/widgets/content_menus.dart';
import 'package:auvy/presentation/widgets/dynamic_background.dart';
import 'package:auvy/providers/intelligence_provider.dart';
import 'package:auvy/providers/player_provider.dart';
import 'package:auvy/providers/artist_image_provider.dart';
import 'package:auvy/providers/search_provider.dart';
import 'package:auvy/providers/theme_provider.dart';
import 'package:auvy/services/haptic_service.dart';

// YOUR STATS — complete makeover.
// One clean scroll: time-range chips → overview cards → taste profile →
// listening clock → weekday activity → top tracks / artists / albums →
// podcasts & radio → fun facts. All computed from the intelligence ledger.

class _RangeOption {
  final String label;
  final Duration? span; // null = all time
  const _RangeOption(this.label, this.span);
}

const List<_RangeOption> _kRanges = [
  _RangeOption('All Time', null),
  _RangeOption('Week', Duration(days: 7)),
  _RangeOption('Month', Duration(days: 30)),
  _RangeOption('6 Months', Duration(days: 180)),
  _RangeOption('Year', Duration(days: 365)),
];

class _RankedItem {
  final String title;
  final String subtitle;
  final String image;
  final int plays;
  final int minutes;
  final Song source;
  _RankedItem({
    required this.title,
    required this.subtitle,
    required this.image,
    required this.plays,
    required this.minutes,
    required this.source,
  });
}

class _StatsData {
  int totalPlays = 0;
  int totalMinutes = 0;
  final List<int> hourly = List<int>.filled(24, 0);
  final List<int> weekday = List<int>.filled(7, 0); // Mon..Sun
  List<_RankedItem> topTracks = [];
  List<_RankedItem> topArtists = [];
  List<_RankedItem> topAlbums = [];
  List<_RankedItem> podcasts = [];
  List<_RankedItem> radio = [];
  int streakDays = 0;
  String busiestDay = '—';
  int busiestDayPlays = 0;
  int get uniqueTracks => topTracks.length;
  int get uniqueArtists => topArtists.length;
  bool get isEmpty => totalPlays == 0;
}

class StatsPage extends ConsumerStatefulWidget {
  const StatsPage({super.key});

  @override
  ConsumerState<StatsPage> createState() => _StatsPageState();
}

class _StatsPageState extends ConsumerState<StatsPage> {
  int _rangeIndex = 0;
  bool _tracksExpanded = false;
  bool _artistsExpanded = false;
  bool _albumsExpanded = false;
  /// The two "when do I listen" charts are collapsed by DEFAULT. Stacked open,
  /// they pushed the actual rankings (top tracks/artists/albums) below the fold
  /// behind four heavy blocks — the "too much going on" problem.
  bool _patternsExpanded = false;

  // Data crunching

  /// The state the cached aggregate was built from, and the aggregate itself.
  ///
  /// WITHOUT THIS, STATS RE-AGGREGATED ON EVERY TRACK EVENT. `build` watches
  /// the WHOLE intelligence provider (it needs most of it), and every play, skip
  /// or timestamp bump replaces that state, so with the page open and music
  /// playing, [_compute] re-walked the entire listening history, rebuilt five
  /// maps and ran five sorts, several times per song.
  ///
  /// [_compute] is a pure function of the state it is handed, so an identical
  /// state can only produce an identical aggregate, and any real change replaces
  /// the object and invalidates this by construction.
  IntelligenceState? _statsFrom;
  _StatsData? _statsMemo;

  _StatsData _compute(IntelligenceState intel) {
    if (_statsMemo != null && identical(_statsFrom, intel)) return _statsMemo!;
    final data = _StatsData();
    final now = DateTime.now();
    final span = _kRanges[_rangeIndex].span;
    final cutoff = span == null ? null : now.subtract(span);

    final Map<String, int> windowPlays = {};
    final Map<String, int> playsPerDay = {}; // dayKey → plays (in range)
    final Set<String> allDays = {}; // every day ever played (for streak)

    intel.playHistory.forEach((id, timestamps) {
      int plays = 0;
      for (final raw in timestamps) {
        int ts = raw;
        if (ts <= 0) continue;
        if (ts < 10000000000) ts *= 1000; // seconds → ms
        final date = DateTime.fromMillisecondsSinceEpoch(ts);
        final dayKey = '${date.year}-${date.month}-${date.day}';
        allDays.add(dayKey);
        if (cutoff != null && date.isBefore(cutoff)) continue;
        plays++;
        data.hourly[date.hour]++;
        data.weekday[date.weekday - 1]++;
        playsPerDay[dayKey] = (playsPerDay[dayKey] ?? 0) + 1;
      }
      if (plays > 0) windowPlays[id] = plays;
    });

    // All-time: lifetime playCounts is authoritative (the timestamp ledger
    // lags/under-counts legacy plays) — take the larger of the two.
    if (cutoff == null) {
      intel.playCounts.forEach((id, count) {
        if (count > (windowPlays[id] ?? 0)) windowPlays[id] = count;
      });
    }

    // Streak: consecutive days with ≥1 play, ending today (or yesterday).
    DateTime cursor = DateTime(now.year, now.month, now.day);
    String key(DateTime d) => '${d.year}-${d.month}-${d.day}';
    if (!allDays.contains(key(cursor))) {
      cursor = cursor.subtract(const Duration(days: 1)); // allow "yesterday"
    }
    while (allDays.contains(key(cursor))) {
      data.streakDays++;
      cursor = cursor.subtract(const Duration(days: 1));
    }

    // Busiest day in range.
    playsPerDay.forEach((day, plays) {
      if (plays > data.busiestDayPlays) {
        data.busiestDayPlays = plays;
        final parts = day.split('-').map(int.parse).toList();
        data.busiestDay = _formatDay(DateTime(parts[0], parts[1], parts[2]));
      }
    });

    // Aggregate per track / artist / album, splitting podcasts + radio out.
    // Tracks are a MAP, keyed by recording rather than by id. See _trackSig.
    final Map<String, _RankedItem> trackMap = {};
    final Map<String, _RankedItem> artists = {};
    final Map<String, _RankedItem> albums = {};
    final Map<String, _RankedItem> podcasts = {};
    final Map<String, _RankedItem> radio = {};

    windowPlays.forEach((id, plays) {
      final song = intel.trackMetadata[id];
      if (song == null || song.title.isEmpty) return;
      if (song.id.startsWith('onb_') || song.id.startsWith('dummy')) return;

      final bool isPodcast = song.albumTitle == 'Podcast';
      final bool isRadio = song.id.startsWith('http') && !isPodcast;
      final minutes = _songMinutes(song) * plays;

      if (isPodcast) {
        // Group episodes by show (artist = show name).
        final show = podcasts[song.artist];
        if (show == null) {
          podcasts[song.artist] = _RankedItem(
              title: song.artist, subtitle: 'Podcast', image: song.image,
              plays: plays, minutes: minutes, source: song);
        } else {
          podcasts[song.artist] = _RankedItem(
              title: show.title, subtitle: show.subtitle,
              image: show.image.isNotEmpty ? show.image : song.image,
              plays: show.plays + plays, minutes: show.minutes + minutes,
              source: show.source);
        }
        return;
      }
      if (isRadio) {
        final st = radio[song.title];
        if (st == null) {
          radio[song.title] = _RankedItem(
              title: song.title, subtitle: 'Radio', image: song.image,
              plays: plays, minutes: minutes, source: song);
        } else {
          radio[song.title] = _RankedItem(
              title: st.title, subtitle: st.subtitle, image: st.image,
              plays: st.plays + plays, minutes: st.minutes + minutes,
              source: st.source);
        }
        return;
      }

      data.totalPlays += plays;
      data.totalMinutes += minutes;

      // One row per recording, NOT per ID
      //
      // THIS IS WHY A TRACK UNDER-REPORTED ITS PLAYS. Everything else here is
      // merged into a map — artists, albums, podcasts, radio, but tracks were
      // `tracks.add(...)` once per ID. And a song does NOT have one stable id in
      // this app: audio-only mode conforms a music VIDEO to its studio-audio
      // twin, so the same recording is credited to the video id sometimes and the
      // audio id other times (see SearchService.mergeConformedAudio), and the
      // conform cache evicts at 500 entries so which one you get varies. Search,
      // album and playlist rows can also carry different ids for the same track.
      //
      // The counts were therefore real but SPLIT: a track played 14 times showed
      // as 7, with its other half sitting further down the list as a second row.
      // Merging on a normalised title+artist signature — the same idea the artist
      // and album maps already use — puts the halves back together.
      final tsig = _trackSig(song);
      final existing = trackMap[tsig];
      if (existing == null) {
        trackMap[tsig] = _RankedItem(
            title: song.title, subtitle: song.artist, image: song.image,
            plays: plays, minutes: minutes, source: song);
      } else {
        trackMap[tsig] = _RankedItem(
            // Keep the title/artist of whichever variant we saw first, but prefer
            // a SQUARE cover: the video-id variant carries a 16:9 still.
            title: existing.title, subtitle: existing.subtitle,
            image: _preferSquare(existing.image, song.image),
            plays: existing.plays + plays,
            minutes: existing.minutes + minutes,
            source: existing.source);
      }

      // Multi-artist credits ("A, B & C") are SPLIT so each artist gets the
      // play counted individually — previously the combined string was ranked
      // as if it were one artist.
      for (final name in ContentMenus.splitArtists(song.artist)) {
        final a = artists[name];
        if (a == null) {
          // image is EMPTY on purpose. This row is an ARTIST; song.image is
          // the cover of whichever of their tracks happened to be seen first,
          // so a soundtrack single would label the artist with a film poster.
          // The tile falls back to an initial, which is not wrong.
          artists[name] = _RankedItem(
              title: name, subtitle: 'Artist', image: '',
              plays: plays, minutes: minutes, source: song);
        } else {
          artists[name] = _RankedItem(
              // STILL EMPTY — DO NOT FALL BACK TO song.image HERE.
              //
              // The branch above sets `image: ''` deliberately (an artist row must
              // not wear one of their track's covers), and this branch used to
              // undo it on the very next play: `a.image.isNotEmpty ? a.image :
              // song.image` is always false on the first merge, so the second play
              // of any artist stamped them with a track thumbnail. That is the
              // reported "top artists shows the cover of a track instead of the
              // artist's real picture", and it only appeared for artists with
              // MORE than one counted play, which is why it looked arbitrary.
              //
              // The real artist picture is resolved by the row widget via
              // artistImageProvider (YouTube Music's artist-channel header), so
              // leaving this blank is what lets the correct image win.
              title: a.title, subtitle: a.subtitle, image: '',
              plays: a.plays + plays, minutes: a.minutes + minutes,
              source: a.source);
        }
      }

      // Albums only, no "singles" catch-all
      //
      // Tracks with no album used to be bucketed under the literal name
      // "Singles", which then ranked in Top Albums as though it were a release —
      // and because it pooled every album-less track by every artist, it usually
      // ranked FIRST. "Your most played album: Singles" is not a fact about the
      // user's listening, it is a fact about missing metadata.
      //
      // Such tracks are simply not counted toward the album chart. They still
      // count everywhere else (total plays, minutes, tracks, artists); they just
      // do not invent an album that does not exist.
      final rawAlbum = song.albumTitle.trim();
      if (rawAlbum.isEmpty ||
          rawAlbum == 'null' ||
          rawAlbum.toLowerCase() == 'singles' ||
          rawAlbum.toLowerCase() == 'single') {
        return;
      }
      final albumName = rawAlbum;
      final al = albums[albumName];
      if (al == null) {
        albums[albumName] = _RankedItem(
            title: albumName, subtitle: song.artist, image: song.image,
            plays: plays, minutes: minutes, source: song);
      } else {
        albums[albumName] = _RankedItem(
            title: al.title, subtitle: al.subtitle,
            image: al.image.isNotEmpty ? al.image : song.image,
            plays: al.plays + plays, minutes: al.minutes + minutes,
            source: al.source);
      }
    });

    int byPlays(_RankedItem a, _RankedItem b) => b.plays.compareTo(a.plays);
    data.topTracks = trackMap.values.toList()..sort(byPlays);
    data.topArtists = artists.values.toList()..sort(byPlays);
    data.topAlbums = albums.values.toList()..sort(byPlays);
    data.podcasts = podcasts.values.toList()..sort(byPlays);
    data.radio = radio.values.toList()..sort(byPlays);
    _statsFrom = intel;
    _statsMemo = data;
    // Says how much work a recompute actually is, and — more usefully — proves
    // by its ABSENCE that the page is not re-aggregating on every track event,
    // which is what it used to do.
    print('stats aggregated: ${data.topTracks.length} track(s), '
        '${data.topArtists.length} artist(s), ${data.topAlbums.length} album(s), '
        '${data.podcasts.length} podcast(s), ${data.radio.length} station(s)');
    return data;
  }

  /// Identity of a RECORDING, independent of which id it was played under.
  ///
  /// Normalised so the video and audio variants of one song collapse together:
  /// case-folded, bracketed qualifiers dropped ("(Official Video)",
  /// "[Remastered]"), punctuation stripped. Only the PRIMARY artist is used —
  /// "Artist" and "Artist, Guest" are the same recording credited differently by
  /// two parsers.
  ///
  /// Deliberately not fuzzy: two genuinely different songs must never merge, so
  /// this is exact-match-after-normalising rather than a similarity score.
  static String _trackSig(Song song) {
    String norm(String s) => s
        .toLowerCase()
        .replaceAll(RegExp(r'\(.*?\)'), ' ')
        .replaceAll(RegExp(r'\[.*?\]'), ' ')
        .replaceAll(RegExp(r'[^a-z0-9 ]'), ' ')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
    final t = norm(song.title);
    final a = norm(song.artist
        .split(RegExp(r'\s*(?:,|&|feat\.?|ft\.?)\s+', caseSensitive: false))
        .first);
    // A track with no usable title falls back to its id, so unrelated
    // metadata-less entries cannot all merge into one row.
    return t.isEmpty ? 'id:${song.id}' : '$t|$a';
  }

  /// Prefer a square sleeve over a 16:9 video still when merging variants.
  static String _preferSquare(String a, String b) {
    bool isStill(String u) => u.contains('ytimg.com') || u.contains('/vi/');
    if (a.isEmpty) return b;
    if (b.isEmpty) return a;
    if (isStill(a) && !isStill(b)) return b;
    return a;
  }

  static int _songMinutes(Song song) {
    final str = song.duration;
    if (str.contains(':')) {
      final parts = str.split(':');
      final m = int.tryParse(parts[0]) ?? 3;
      return m.clamp(1, 90);
    }
    final v = int.tryParse(str);
    if (v != null && v > 0) {
      if (v > 10000) return (v / 60000).round().clamp(1, 90); // ms
      return (v / 60).round().clamp(1, 90); // seconds
    }
    return 3; // sensible fallback
  }

  static String _formatDay(DateTime d) {
    const week = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
    const months = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
    return '${week[d.weekday - 1]}, ${months[d.month - 1]} ${d.day}';
  }

  static String _formatListeningTime(int minutes) {
    if (minutes < 60) return '${minutes}m';
    final h = minutes ~/ 60;
    if (h < 100) return '${h}h ${minutes % 60}m';
    return '${h}h';
  }

  static String _hourLabel(int h) {
    if (h == 0) return '12 AM';
    if (h < 12) return '$h AM';
    if (h == 12) return '12 PM';
    return '${h - 12} PM';
  }

  // Navigation

  void _openTrack(Song song) {
    HapticService.light();
    ref.read(playerProvider.notifier).playSong(song, newQueue: [song], source: 'Stats');
  }

  Future<void> _openArtist(String name, String image) async {
    HapticService.light();
    final service = ref.read(searchServiceProvider);
    final results = await service.search(name, 'artist');
    if (!mounted) return;
    // A name-only Song is a perfectly good fallback here — ArtistPage resolves
    // it properly, so an unmatched search costs nothing, while the wrong first
    // hit would open a stranger's page.
    final match = SearchService.pickArtistMatch(results, name, (s) => s.title);
    final artist = match ??
        Song(id: name, title: name, artist: 'Artist', image: image);
    AppNavigation.push(context, ArtistPage(artist: artist),
        name: AppNavigation.artistTag(artist));
  }

  Future<void> _openAlbum(_RankedItem item) async {
    HapticService.light();
    if (item.title == 'Singles') {
      _openTrack(item.source);
      return;
    }
    final song = item.source;
    final bool hasRealAlbum =
        song.albumId.isNotEmpty && song.albumId != 'null' && song.albumId != song.id;
    final album = Album(
      id: hasRealAlbum ? song.albumId : song.id,
      title: item.title,
      image: item.image,
      releaseDate: 'Unknown',
      recordType: 'album',
    );
    AppNavigation.push(
        context, AlbumPage(album: album, artistName: item.subtitle, fallbackTrack: song),
        name: AppNavigation.albumTag(album));
  }

  // Build

  @override
  Widget build(BuildContext context) {
    final theme = ref.watch(themeProvider);
    final intel = ref.watch(intelligenceProvider);
    final data = _compute(intel);

    return DynamicBackground(
      child: Scaffold(
        backgroundColor: Colors.transparent,
        body: SafeArea(
          child: CustomScrollView(
            physics: const BouncingScrollPhysics(),
            slivers: [
              SliverToBoxAdapter(child: _header(theme)),
              SliverToBoxAdapter(child: _rangeChips(theme)),
              if (data.isEmpty)
                SliverFillRemaining(
                  hasScrollBody: false,
                  child: _emptyState(),
                )
              else ...[
                // ONE compact strip instead of a 2×2 grid of tall cards, then
                // the two "when" charts folded into a single collapsible card.
                // Net effect: the rankings people actually come here for are
                // reachable without scrolling past four full-height blocks.
                // Auvy Wrapped entry — the recap belongs where the stats live.
                SliverToBoxAdapter(child: _wrappedBanner(theme)),
                SliverToBoxAdapter(child: _overviewStrip(data, theme)),
                const SliverToBoxAdapter(child: _TasteProfileCard()),
                SliverToBoxAdapter(child: _patternsCard(data, theme)),
                SliverToBoxAdapter(child: _topSection(
                  'Top Tracks', data.topTracks, _tracksExpanded,
                  () => setState(() => _tracksExpanded = !_tracksExpanded),
                  theme, _TopKind.track,
                )),
                SliverToBoxAdapter(child: _topSection(
                  'Top Artists', data.topArtists, _artistsExpanded,
                  () => setState(() => _artistsExpanded = !_artistsExpanded),
                  theme, _TopKind.artist,
                )),
                SliverToBoxAdapter(child: _topSection(
                  'Top Albums', data.topAlbums, _albumsExpanded,
                  () => setState(() => _albumsExpanded = !_albumsExpanded),
                  theme, _TopKind.album,
                )),
                if (data.podcasts.isNotEmpty)
                  SliverToBoxAdapter(child: _compactSection(
                      'Podcasts', data.podcasts, theme, 'episodes')),
                if (data.radio.isNotEmpty)
                  SliverToBoxAdapter(child: _compactSection(
                      'Radio', data.radio, theme, 'sessions')),
                SliverToBoxAdapter(child: _funFacts(data, intel, theme)),
                // Fills the lower page with something actually informative and
                // TAPPABLE, instead of trailing off into padding.
                const SliverToBoxAdapter(child: _DayPartHeatmap()),
                const SliverToBoxAdapter(child: SizedBox(height: 140)),
              ],
            ],
          ),
        ),
      ),
    );
  }

  Widget _header(Color theme) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 8, 16, 4),
      child: Row(
        children: [
          IconButton(
            icon: const Icon(Icons.arrow_back, color: Colors.white),
            onPressed: () => Navigator.of(context).pop(),
          ),
          const SizedBox(width: 4),
          const Text('Your Stats',
              style: TextStyle(fontSize: 26, fontWeight: FontWeight.w800, color: Colors.white)),
          const Spacer(),
          Icon(Icons.insights_rounded, color: theme, size: 24),
        ],
      ),
    );
  }

  Widget _rangeChips(Color theme) {
    return SizedBox(
      height: 44,
      child: ListView.builder(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
        itemCount: _kRanges.length,
        itemBuilder: (context, i) {
          final selected = i == _rangeIndex;
          return Padding(
            padding: const EdgeInsets.only(right: 8),
            child: GestureDetector(
              onTap: () {
                HapticService.selection();
                setState(() => _rangeIndex = i);
              },
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 200),
                padding: const EdgeInsets.symmetric(horizontal: 16),
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: selected ? theme : Colors.white.withOpacity(0.06),
                  borderRadius: BorderRadius.circular(20),
                  border: Border.all(
                      color: selected ? theme : Colors.white.withOpacity(0.10)),
                ),
                child: Text(
                  _kRanges[i].label,
                  style: TextStyle(
                    color: selected ? Colors.black : Colors.white70,
                    fontWeight: selected ? FontWeight.w800 : FontWeight.w500,
                    fontSize: 13,
                  ),
                ),
              ),
            ),
          );
        },
      ),
    );
  }

  Widget _emptyState() {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(Icons.equalizer_rounded, size: 56, color: Colors.white.withOpacity(0.2)),
          const SizedBox(height: 16),
          Text('Nothing played in this period',
              style: TextStyle(color: Colors.white.withOpacity(0.72), fontSize: 16)),
          const SizedBox(height: 6),
          Text('Play some music and come back!',
              style: TextStyle(color: Colors.white.withOpacity(0.66), fontSize: 13)),
        ],
      ),
    );
  }

  /// Entry point for Auvy Wrapped. A single gradient banner rather than a buried
  /// menu row — it's the most shareable thing in the app, so it should be the
  /// first thing on the stats screen.
  Widget _wrappedBanner(Color theme) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 6, 16, 2),
      child: GestureDetector(
        onTap: () {
          HapticService.medium();
          Navigator.push(
              context, MainLayout.smoothRoute(const WrappedPage()));
        },
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 15),
          decoration: BoxDecoration(
            gradient: LinearGradient(
              colors: [theme.withOpacity(0.42), theme.withOpacity(0.12)],
              begin: Alignment.centerLeft,
              end: Alignment.centerRight,
            ),
            borderRadius: BorderRadius.circular(18),
            border: Border.all(color: theme.withOpacity(0.35)),
          ),
          child: Row(children: [
            Icon(Icons.auto_awesome_rounded, color: Colors.white, size: 22),
            const SizedBox(width: 13),
            const Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Auvy Wrapped',
                      style: TextStyle(
                          color: Colors.white,
                          fontSize: 15.5,
                          fontWeight: FontWeight.w900)),
                  SizedBox(height: 2),
                  Text('Your listening, as a story',
                      style: TextStyle(color: Colors.white70, fontSize: 12)),
                ],
              ),
            ),
            const Icon(Icons.chevron_right_rounded,
                color: Colors.white70, size: 22),
          ]),
        ),
      ),
    );
  }

  // Overview

  /// Four headline numbers in ONE compact row.
  ///
  /// Replaces a 2×2 grid of tall cards that ate roughly a third of the first
  /// screen to show four integers. Same information, a quarter of the height, and
  /// it reads as a single summary rather than four competing tiles.
  Widget _overviewStrip(_StatsData d, Color theme) {
    Widget cell(IconData icon, String value, String label) {
      return Expanded(
        child: Column(
          children: [
            Icon(icon, color: theme, size: 16),
            const SizedBox(height: 6),
            FittedBox(
              fit: BoxFit.scaleDown,
              child: Text(value,
                  style: const TextStyle(
                      color: Colors.white,
                      fontSize: 17,
                      fontWeight: FontWeight.w800,
                      height: 1.1)),
            ),
            const SizedBox(height: 2),
            Text(label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                    color: Colors.white.withOpacity(0.66),
                    fontSize: 10,
                    fontWeight: FontWeight.w600)),
          ],
        ),
      );
    }

    return Container(
      margin: const EdgeInsets.fromLTRB(16, 12, 16, 4),
      padding: const EdgeInsets.symmetric(vertical: 14, horizontal: 8),
      decoration: BoxDecoration(
        color: Colors.white.withOpacity(0.05),
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: Colors.white.withOpacity(0.06)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          cell(Icons.play_circle_fill_rounded, '${d.totalPlays}', 'Plays'),
          _stripDivider(),
          cell(Icons.schedule_rounded, _formatListeningTime(d.totalMinutes), 'Listened'),
          _stripDivider(),
          cell(Icons.music_note_rounded, '${d.uniqueTracks}', 'Tracks'),
          _stripDivider(),
          cell(Icons.people_alt_rounded, '${d.uniqueArtists}', 'Artists'),
        ],
      ),
    );
  }

  Widget _stripDivider() => Container(
        width: 1,
        height: 34,
        color: Colors.white.withOpacity(0.07),
      );

  /// The listening clock + active days, folded into ONE collapsible card.
  ///
  /// Both answer the same question ("when do I listen"), and open by default
  /// they pushed the rankings off the first two screens. Collapsed, the header
  /// still carries the two headline answers (peak hour, busiest day) so the
  /// summary survives without the charts.
  Widget _patternsCard(_StatsData d, Color theme) {
    final maxHour = d.hourly.fold<int>(0, (m, v) => v > m ? v : m);
    final maxDay = d.weekday.fold<int>(0, (m, v) => v > m ? v : m);
    if (maxHour == 0 && maxDay == 0) return const SizedBox.shrink();

    int peak = 0;
    for (int h = 0; h < 24; h++) {
      if (d.hourly[h] > d.hourly[peak]) peak = h;
    }
    int best = 0;
    for (int i = 0; i < 7; i++) {
      if (d.weekday[i] > d.weekday[best]) best = i;
    }
    const dayNames = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];

    return Container(
      margin: const EdgeInsets.fromLTRB(16, 8, 16, 8),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.white.withOpacity(0.05),
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: Colors.white.withOpacity(0.06)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: () {
              HapticService.selection();
              setState(() => _patternsExpanded = !_patternsExpanded);
            },
            child: Row(
              children: [
                const Text('When you listen',
                    style: TextStyle(
                        color: Colors.white,
                        fontSize: 16,
                        fontWeight: FontWeight.w800)),
                const Spacer(),
                if (!_patternsExpanded && maxHour > 0)
                  Text('${_hourLabel(peak)} · ${dayNames[best]}',
                      style: TextStyle(
                          color: theme,
                          fontSize: 12,
                          fontWeight: FontWeight.w700)),
                const SizedBox(width: 6),
                AnimatedRotation(
                  turns: _patternsExpanded ? 0.5 : 0,
                  duration: const Duration(milliseconds: 220),
                  child: Icon(Icons.expand_more_rounded,
                      color: Colors.white.withOpacity(0.5), size: 20),
                ),
              ],
            ),
          ),
          AnimatedCrossFade(
            duration: const Duration(milliseconds: 240),
            firstCurve: Curves.easeOut,
            secondCurve: Curves.easeOut,
            sizeCurve: Curves.easeOutCubic,
            crossFadeState: _patternsExpanded
                ? CrossFadeState.showSecond
                : CrossFadeState.showFirst,
            firstChild: const SizedBox(width: double.infinity),
            secondChild: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const SizedBox(height: 14),
                if (maxHour > 0) ..._clockChart(d, theme, peak),
                if (maxDay > 0) ..._weekdayChart(d, theme, best),
              ],
            ),
          ),
        ],
      ),
    );
  }

  // Listening clock (24h)

  /// 24-hour bar chart, as CHART BODY ONLY — the card and heading now come from
  /// [_patternsCard], which hosts this alongside the weekday chart.
  List<Widget> _clockChart(_StatsData d, Color theme, int peak) {
    final maxCount = d.hourly.fold<int>(0, (m, v) => v > m ? v : m);
    if (maxCount == 0) return const [];

    return [
      Row(children: [
        Text('Across the day',
            style: TextStyle(
                color: Colors.white.withOpacity(0.72),
                fontSize: 11.5,
                fontWeight: FontWeight.w700)),
        const Spacer(),
        Text('peak ${_hourLabel(peak)}',
            style: TextStyle(
                color: theme, fontSize: 11.5, fontWeight: FontWeight.w700)),
      ]),
      const SizedBox(height: 8),
      Column(
        children: [
          SizedBox(
            height: 72,
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: List.generate(24, (h) {
                final frac = d.hourly[h] / maxCount;
                final isPeak = h == peak;
                return Expanded(
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 1.5),
                    child: AnimatedContainer(
                      duration: const Duration(milliseconds: 350),
                      curve: Curves.easeOutCubic,
                      height: 6 + 62 * frac,
                      decoration: BoxDecoration(
                        color: isPeak
                            ? theme
                            : theme.withOpacity(0.18 + 0.45 * frac),
                        borderRadius: BorderRadius.circular(3),
                      ),
                    ),
                  ),
                );
              }),
            ),
          ),
          const SizedBox(height: 6),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: ['12AM', '6AM', '12PM', '6PM', '11PM']
                .map((t) => Text(t,
                    style: TextStyle(
                        color: Colors.white.withOpacity(0.66), fontSize: 10)))
                .toList(),
          ),
        ],
      ),
    ];
  }

  /// Weekday bar chart, chart body only (see [_clockChart]).
  List<Widget> _weekdayChart(_StatsData d, Color theme, int best) {
    final maxCount = d.weekday.fold<int>(0, (m, v) => v > m ? v : m);
    if (maxCount == 0) return const [];
    const labels = ['M', 'T', 'W', 'T', 'F', 'S', 'S'];
    const fullNames = ['Mondays', 'Tuesdays', 'Wednesdays', 'Thursdays', 'Fridays', 'Saturdays', 'Sundays'];

    return [
      const SizedBox(height: 18),
      Row(children: [
        Text('Across the week',
            style: TextStyle(
                color: Colors.white.withOpacity(0.72),
                fontSize: 11.5,
                fontWeight: FontWeight.w700)),
        const Spacer(),
        Text('mostly ${fullNames[best]}',
            style: TextStyle(
                color: theme, fontSize: 11.5, fontWeight: FontWeight.w700)),
      ]),
      const SizedBox(height: 8),
      SizedBox(
        height: 84,
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: List.generate(7, (i) {
            final frac = d.weekday[i] / maxCount;
            return Expanded(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 8),
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.end,
                  children: [
                    AnimatedContainer(
                      duration: const Duration(milliseconds: 350),
                      curve: Curves.easeOutCubic,
                      height: 6 + 54 * frac,
                      decoration: BoxDecoration(
                        color: i == best ? theme : theme.withOpacity(0.18 + 0.45 * frac),
                        borderRadius: BorderRadius.circular(4),
                      ),
                    ),
                    const SizedBox(height: 6),
                    Text(labels[i],
                        style: TextStyle(
                            color: Colors.white.withOpacity(i == best ? 0.9 : 0.35),
                            fontSize: 11,
                            fontWeight: i == best ? FontWeight.w800 : FontWeight.w500)),
                  ],
                ),
              ),
            );
          }),
        ),
      ),
    ];
  }

  // Top lists

  Widget _topSection(String title, List<_RankedItem> items, bool expanded,
      VoidCallback onToggle, Color theme, _TopKind kind) {
    if (items.isEmpty) return const SizedBox.shrink();
    final visible = items.take(expanded ? 15 : 5).toList();
    final maxPlays = items.first.plays;

    return _sectionCard(
      title: title,
      trailing: items.length > 5
          ? GestureDetector(
              onTap: () {
                HapticService.selection();
                onToggle();
              },
              child: Text(expanded ? 'Show less' : 'Show all',
                  style: TextStyle(color: theme, fontSize: 12, fontWeight: FontWeight.w700)),
            )
          : null,
      child: Column(
        children: [
          for (int i = 0; i < visible.length; i++)
            _rankedRow(i + 1, visible[i], maxPlays, theme, kind),
        ],
      ),
    );
  }

  Widget _rankedRow(int rank, _RankedItem item, int maxPlays, Color theme, _TopKind kind) {
    final isArtist = kind == _TopKind.artist;
    return InkWell(
      borderRadius: BorderRadius.circular(12),
      onTap: () {
        switch (kind) {
          case _TopKind.track:
            _openTrack(item.source);
            break;
          case _TopKind.artist:
            _openArtist(item.title, item.image);
            break;
          case _TopKind.album:
            _openAlbum(item);
            break;
        }
      },
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 7),
        child: Row(
          children: [
            SizedBox(
              width: 26,
              child: Text('$rank',
                  style: TextStyle(
                      color: rank <= 3 ? theme : Colors.white.withOpacity(0.66),
                      fontSize: 13,
                      fontWeight: rank <= 3 ? FontWeight.w800 : FontWeight.w600)),
            ),
            Stack(children: [
            ClipRRect(
              borderRadius: BorderRadius.circular(ListeningPolicy.roundArtwork(isArtist ? 24 : 9)),
              // The artist's own picture, NOT one of their covers
              //
              // Artist rows carry no image by design (see the aggregation), so
              // this used to render a generic person icon. The real picture is
              // YouTube Music's artist-channel header, already resolved and cached
              // for the rest of the app by artistImageProvider — the same source
              // the artist page and "Your Artists" use, so all three now agree
              // instead of each showing whatever art happened to be nearby.
              //
              // Resolved per ROW rather than during aggregation: it is a network
              // lookup, and only the handful of rows actually on screen should pay
              // for one. The provider is session-cached and disk-cached, so
              // scrolling back costs nothing.
              child: isArtist
                  ? _ArtistAvatar(name: item.title, fallback: item.image)
                  : (item.image.isNotEmpty
                      ? AuvyImage(path: item.image, width: 46, height: 46, fit: BoxFit.cover)
                      : Container(
                          width: 46, height: 46,
                          color: Colors.white.withOpacity(0.08),
                          child: const Icon(Icons.music_note,
                              color: Colors.white38, size: 22),
                        )),
            ),
              if (kind == _TopKind.track)
                NowPlayingArtOverlay(
                    rowId: item.source.id,
                    title: item.title,
                    artist: item.subtitle,
                    size: 46,
                    borderRadius: 9),
            ]),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  kind == _TopKind.track
                      ? NowPlayingTitle(
                          title: item.title,
                          rowId: item.source.id,
                          artist: item.subtitle,
                          style: const TextStyle(
                              color: Colors.white,
                              fontSize: 14.5,
                              fontWeight: FontWeight.w600))
                      : Text(item.title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                              color: Colors.white,
                              fontSize: 14.5,
                              fontWeight: FontWeight.w600)),
                  const SizedBox(height: 5),
                  // Relative-share bar — makes rankings readable at a glance.
                  ClipRRect(
                    borderRadius: BorderRadius.circular(2),
                    child: SizedBox(
                      height: 3,
                      child: Row(
                        children: [
                          Flexible(
                            flex: (100 * item.plays / maxPlays).round().clamp(1, 100),
                            child: Container(color: theme.withOpacity(0.85)),
                          ),
                          Flexible(
                            flex: (100 - 100 * item.plays / maxPlays).round().clamp(0, 99),
                            child: Container(color: Colors.white.withOpacity(0.06)),
                          ),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 12),
            Column(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Text('${item.plays}',
                    style: const TextStyle(
                        color: Colors.white, fontSize: 14, fontWeight: FontWeight.w800)),
                Text('plays',
                    style: TextStyle(color: Colors.white.withOpacity(0.66), fontSize: 10)),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _compactSection(String title, List<_RankedItem> items, Color theme, String unit) {
    return _sectionCard(
      title: title,
      child: Column(
        children: items.take(5).map((item) {
          return InkWell(
            borderRadius: BorderRadius.circular(12),
            onTap: () => _openTrack(item.source),
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 7),
              child: Row(
                children: [
                  ClipRRect(
                    borderRadius: BorderRadius.circular(ListeningPolicy.roundArtwork(9)),
                    child: item.image.isNotEmpty
                        ? AuvyImage(path: item.image, width: 42, height: 42, fit: BoxFit.cover)
                        : Container(
                            width: 42, height: 42,
                            color: Colors.white.withOpacity(0.08),
                            child: const Icon(Icons.podcasts_rounded,
                                color: Colors.white38, size: 20),
                          ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(item.title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                            color: Colors.white, fontSize: 14, fontWeight: FontWeight.w600)),
                  ),
                  Text('${item.plays} $unit',
                      style: TextStyle(
                          color: theme, fontSize: 12, fontWeight: FontWeight.w700)),
                ],
              ),
            ),
          );
        }).toList(),
      ),
    );
  }

  // Fun facts

  Widget _funFacts(_StatsData d, IntelligenceState intel, Color theme) {
    final profile = ref.read(intelligenceProvider.notifier).getTasteProfile();
    final discovery = (profile['discoveryScore'] as int?) ?? 0;

    Widget fact(IconData icon, String value, String label) {
      return Expanded(
        child: Column(
          children: [
            Icon(icon, color: theme, size: 22),
            const SizedBox(height: 8),
            Text(value,
                textAlign: TextAlign.center,
                style: const TextStyle(
                    color: Colors.white, fontSize: 15, fontWeight: FontWeight.w800)),
            const SizedBox(height: 3),
            Text(label,
                textAlign: TextAlign.center,
                style: TextStyle(color: Colors.white.withOpacity(0.66), fontSize: 10.5)),
          ],
        ),
      );
    }

    return Container(
      margin: const EdgeInsets.fromLTRB(16, 8, 16, 8),
      padding: const EdgeInsets.symmetric(vertical: 18, horizontal: 8),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          colors: [theme.withOpacity(0.16), theme.withOpacity(0.03)],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: theme.withOpacity(0.22)),
      ),
      child: Row(
        children: [
          fact(Icons.local_fire_department_rounded,
              d.streakDays > 0 ? '${d.streakDays} day${d.streakDays == 1 ? '' : 's'}' : '—',
              'Streak'),
          fact(Icons.event_available_rounded, d.busiestDay, 'Busiest day'),
          fact(Icons.explore_rounded, '$discovery%', 'Explorer'),
        ],
      ),
    );
  }

  // Shared section card

  Widget _sectionCard({required String title, Widget? trailing, required Widget child}) {
    return Container(
      margin: const EdgeInsets.fromLTRB(16, 8, 16, 8),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.white.withOpacity(0.05),
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: Colors.white.withOpacity(0.06)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(title,
                    style: const TextStyle(
                        color: Colors.white, fontSize: 16, fontWeight: FontWeight.w800)),
              ),
              if (trailing != null) trailing,
            ],
          ),
          const SizedBox(height: 14),
          child,
        ],
      ),
    );
  }
}

enum _TopKind { track, artist, album }

// "Your Taste" card — kept from the previous page (driven by the intelligence
// layer's derived profile), restyled to match the new section cards.

class _TasteProfileCard extends ConsumerWidget {
  const _TasteProfileCard();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = ref.watch(themeProvider);
    ref.watch(intelligenceProvider); // rebuild as the profile grows
    final p = ref.read(intelligenceProvider.notifier).getTasteProfile();

    final personality = (p['personality'] as String?) ?? 'Listener';
    final discovery = (p['discoveryScore'] as int?) ?? 0;
    final days = (p['daysListening'] as int?) ?? 0;
    final totalArtists = (p['totalArtists'] as int?) ?? 0;
    final mood = (p['currentMood'] as String?) ?? 'neutral';
    final peakHour = (p['peakHour'] as int?) ?? -1;
    final topGenres = (p['topGenres'] as List?)?.cast<String>() ?? const [];
    final rising = (p['risingArtists'] as List?)?.cast<String>() ?? const [];
    final next = (p['predictedNext'] as List?)?.cast<String>() ?? const [];

    if (totalArtists == 0 && topGenres.isEmpty) return const SizedBox.shrink();

    String hourLabel(int h) => h < 0
        ? '—'
        : h == 0
            ? '12 AM'
            : h < 12
                ? '$h AM'
                : h == 12
                    ? '12 PM'
                    : '${h - 12} PM';

    final chips = <Widget>[
      if (next.isNotEmpty) _chip(Icons.auto_awesome_rounded, 'Up next: ${next.first}', theme),
      if (rising.isNotEmpty) _chip(Icons.trending_up_rounded, 'Rising: ${rising.take(2).join(", ")}', theme),
      _chip(Icons.explore_rounded, '$discovery% explorer', theme),
      if (peakHour >= 0) _chip(Icons.schedule_rounded, 'Peak ${hourLabel(peakHour)}', theme),
      _chip(Icons.mood_rounded, mood, theme),
    ];

    return Container(
      margin: const EdgeInsets.fromLTRB(16, 8, 16, 8),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          colors: [theme.withOpacity(0.20), theme.withOpacity(0.04)],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: theme.withOpacity(0.28)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(children: [
            Icon(Icons.psychology_alt_rounded, color: theme, size: 20),
            const SizedBox(width: 8),
            Expanded(
              child: Text('Your Taste · $personality',
                  style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 15),
                  overflow: TextOverflow.ellipsis),
            ),
          ]),
          const SizedBox(height: 3),
          Text(
            '$days days · $totalArtists artists'
            '${topGenres.isNotEmpty ? " · ${topGenres.take(3).join(" / ")}" : ""}',
            style: TextStyle(color: Colors.white.withOpacity(0.78), fontSize: 11),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          const SizedBox(height: 10),
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(children: [
              for (final c in chips) Padding(padding: const EdgeInsets.only(right: 8), child: c),
            ]),
          ),
        ],
      ),
    );
  }

  Widget _chip(IconData icon, String label, Color theme) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        decoration: BoxDecoration(
          color: Colors.white.withOpacity(0.08),
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: Colors.white.withOpacity(0.08)),
        ),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          Icon(icon, size: 13, color: theme),
          const SizedBox(width: 5),
          Text(label, style: const TextStyle(color: Colors.white, fontSize: 11, fontWeight: FontWeight.w600)),
        ]),
      );
}

/// Interactive day-part heatmap — "when you listen, and to whom".
///
/// Reads `dayPartAffinities`, the same profile that powers the Home "Right Now"
/// rail. The grid is 4 day parts × weekday/weekend because that is EXACTLY the
/// granularity the data has (`weekday-morning`, `weekend-night`, …) — inventing a
/// 7-day grid would imply precision that isn't there.
///
/// Tapping a cell reveals who defines it, ranked by **lift** (how much more you
/// play them then versus your own average) rather than raw plays, so it names
/// your 2am artist rather than repeating your all-time favourite in every cell.
class _DayPartHeatmap extends ConsumerStatefulWidget {
  const _DayPartHeatmap();

  @override
  ConsumerState<_DayPartHeatmap> createState() => _DayPartHeatmapState();
}

class _DayPartHeatmapState extends ConsumerState<_DayPartHeatmap> {
  static const _parts = ['morning', 'afternoon', 'evening', 'night'];
  static const _partLabels = ['Morning', 'Afternoon', 'Evening', 'Night'];
  static const _cols = ['weekday', 'weekend'];
  static const _colLabels = ['Weekdays', 'Weekends'];

  String? _selected;

  /// Live day-part key, so "now" can be outlined in the grid.
  String _currentKey() {
    final now = DateTime.now();
    final h = now.hour;
    final part = h >= 5 && h < 12
        ? 'morning'
        : h >= 12 && h < 17
            ? 'afternoon'
            : h >= 17 && h < 22
                ? 'evening'
                : 'night';
    final weekend =
        now.weekday == DateTime.saturday || now.weekday == DateTime.sunday;
    return '${weekend ? 'weekend' : 'weekday'}-$part';
  }

  @override
  Widget build(BuildContext context) {
    final theme = ref.watch(themeProvider);
    final buckets = ref.watch(intelligenceProvider).dayPartAffinities;
    if (buckets.isEmpty) return const SizedBox.shrink();

    // Cell weight = total affinity accumulated in that bucket.
    double total(String key) =>
        (buckets[key]?.values.fold<double>(0, (s, v) => s + v)) ?? 0;

    var maxWeight = 0.0;
    for (final c in _cols) {
      for (final p in _parts) {
        final t = total('$c-$p');
        if (t > maxWeight) maxWeight = t;
      }
    }
    if (maxWeight <= 0) return const SizedBox.shrink();

    final nowKey = _currentKey();
    final selKey = _selected ?? nowKey;

    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 8, 20, 0),
      child: Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: Colors.white.withOpacity(0.04),
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: Colors.white.withOpacity(0.06)),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(children: [
              Text('Your listening week',
                  style: TextStyle(
                      color: Colors.white.withOpacity(0.9),
                      fontSize: 15,
                      fontWeight: FontWeight.w800)),
              const Spacer(),
              Text('tap a slot',
                  style: TextStyle(
                      color: Colors.white.withOpacity(0.55),
                      fontSize: 10.5,
                      fontWeight: FontWeight.w700)),
            ]),
            const SizedBox(height: 14),

            // Column headers.
            Row(children: [
              const SizedBox(width: 74),
              for (final label in _colLabels)
                Expanded(
                  child: Text(label,
                      textAlign: TextAlign.center,
                      style: TextStyle(
                          color: Colors.white.withOpacity(0.66),
                          fontSize: 10.5,
                          fontWeight: FontWeight.w800,
                          letterSpacing: 0.4)),
                ),
            ]),
            const SizedBox(height: 6),

            for (int r = 0; r < _parts.length; r++)
              Padding(
                padding: const EdgeInsets.only(bottom: 6),
                child: Row(children: [
                  SizedBox(
                    width: 74,
                    child: Text(_partLabels[r],
                        style: TextStyle(
                            color: Colors.white.withOpacity(0.66),
                            fontSize: 11.5,
                            fontWeight: FontWeight.w600)),
                  ),
                  for (final c in _cols)
                    Expanded(
                      child: _cell(
                        key: '$c-${_parts[r]}',
                        intensity: (total('$c-${_parts[r]}') / maxWeight)
                            .clamp(0.0, 1.0),
                        theme: theme,
                        isNow: '$c-${_parts[r]}' == nowKey,
                        isSelected: '$c-${_parts[r]}' == selKey,
                      ),
                    ),
                ]),
              ),

            const SizedBox(height: 12),
            _detail(selKey, buckets, theme, isNow: selKey == nowKey),
          ],
        ),
      ),
    );
  }

  Widget _cell({
    required String key,
    required double intensity,
    required Color theme,
    required bool isNow,
    required bool isSelected,
  }) {
    return GestureDetector(
      onTap: () {
        HapticService.selection();
        setState(() => _selected = key);
      },
      child: Container(
        height: 34,
        margin: const EdgeInsets.symmetric(horizontal: 3),
        decoration: BoxDecoration(
          // A floor of 0.06 keeps an empty slot visible as an empty slot rather
          // than a hole in the grid.
          color: theme.withOpacity(0.06 + intensity * 0.62),
          borderRadius: BorderRadius.circular(9),
          border: Border.all(
            color: isSelected
                ? Colors.white.withOpacity(0.85)
                : (isNow ? theme.withOpacity(0.9) : Colors.transparent),
            width: isSelected ? 1.6 : 1.2,
          ),
        ),
        child: isNow
            ? Center(
                child: Text('NOW',
                    style: TextStyle(
                        color: Colors.white.withOpacity(0.85),
                        fontSize: 8.5,
                        fontWeight: FontWeight.w900,
                        letterSpacing: 0.8)),
              )
            : null,
      ),
    );
  }

  /// Who defines the selected slot, by LIFT against that name's own average
  /// across every slot — the same measure the "Right Now" rail ranks by.
  Widget _detail(
    String key,
    Map<String, Map<String, double>> buckets,
    Color theme, {
    required bool isNow,
  }) {
    final here = buckets[key];
    final label = key.split('-');
    final pretty =
        '${label.first == 'weekend' ? 'Weekend' : 'Weekday'} ${label.last}';

    if (here == null || here.isEmpty) {
      return Text('Nothing recorded for $pretty yet.',
          style: TextStyle(
              color: Colors.white.withOpacity(0.66),
              fontSize: 12,
              fontStyle: FontStyle.italic));
    }

    final totals = <String, double>{};
    final counts = <String, int>{};
    for (final b in buckets.values) {
      b.forEach((n, w) {
        totals[n] = (totals[n] ?? 0) + w;
        counts[n] = (counts[n] ?? 0) + 1;
      });
    }
    final ranked = here.entries.map((e) {
      final n = counts[e.key] ?? 1;
      final mean = (totals[e.key] ?? e.value) / n;
      final lift = n <= 1 ? 1.6 : (mean > 0 ? e.value / mean : 1.0);
      return (name: e.key, lift: lift);
    }).toList()
      ..sort((a, b) => b.lift.compareTo(a.lift));

    final top = ranked.take(3).toList();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(isNow ? '$pretty · right now' : pretty,
            style: TextStyle(
                color: theme, fontSize: 12, fontWeight: FontWeight.w800)),
        const SizedBox(height: 6),
        Wrap(
          spacing: 6,
          runSpacing: 6,
          children: [
            for (final t in top)
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 9, vertical: 5),
                decoration: BoxDecoration(
                  color: Colors.white.withOpacity(0.06),
                  borderRadius: BorderRadius.circular(9),
                ),
                child: Text(t.name,
                    style: const TextStyle(
                        color: Colors.white70,
                        fontSize: 11.5,
                        fontWeight: FontWeight.w600)),
              ),
          ],
        ),
      ],
    );
  }
}

/// The artist's OWN picture for a Top-Artists row.
///
/// Watches [artistImageProvider], which resolves YouTube Music's artist-channel
/// header for a NAME and caches it for the session and on disk, so this is the
/// same picture the artist page and "Your Artists" show, instead of each surface
/// displaying whichever track cover was nearest.
///
/// [fallback] is used while the lookup is in flight or if it fails. It is normally
/// empty for artist rows (deliberately. See the aggregation), in which case the
/// row shows a neutral initial rather than a wrong picture.
class _ArtistAvatar extends ConsumerWidget {
  const _ArtistAvatar({required this.name, this.fallback = ''});

  final String name;
  final String fallback;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final resolved = ref.watch(artistImageProvider(name));
    final url = resolved.asData?.value ?? '';
    final path = url.isNotEmpty ? url : fallback;
    if (path.isEmpty) {
      // An initial reads as "this is an artist" far better than a generic person
      // glyph, and never claims to be a photograph.
      final initial = name.trim().isEmpty ? '?' : name.trim()[0].toUpperCase();
      return Container(
        width: 46,
        height: 46,
        alignment: Alignment.center,
        color: Colors.white.withOpacity(0.08),
        child: Text(initial,
            style: const TextStyle(
                color: Colors.white54, fontSize: 18, fontWeight: FontWeight.w700)),
      );
    }
    return AuvyImage(path: path, width: 46, height: 46, fit: BoxFit.cover);
  }
}
