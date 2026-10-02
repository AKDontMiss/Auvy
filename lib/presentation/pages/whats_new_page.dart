import 'dart:async';

import 'package:flutter/material.dart';
import 'package:auvy/presentation/widgets/auvy_pill.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:auvy/core/app_navigation.dart';
import 'package:auvy/data/artist_model.dart';
import 'package:auvy/data/podcast_model.dart';
import 'package:auvy/logic/whats_new_logic.dart';
import 'package:auvy/presentation/pages/album_page.dart';
import 'package:auvy/presentation/pages/changelog_page.dart';
import 'package:auvy/presentation/pages/playlist_page.dart';
import 'package:auvy/presentation/pages/podcast_page.dart';
import 'package:auvy/presentation/widgets/animated_toast.dart';
import 'package:auvy/presentation/widgets/auvy_image.dart';
import 'package:auvy/presentation/widgets/content_menus.dart';
import 'package:auvy/presentation/widgets/dynamic_background.dart';
import 'package:auvy/providers/artist_provider.dart';
import 'package:auvy/providers/library_provider.dart';
import 'package:auvy/providers/search_provider.dart' show searchServiceProvider;
import 'package:auvy/providers/theme_provider.dart';
import 'package:auvy/providers/whats_new_provider.dart';
import 'package:auvy/services/haptic_service.dart';
import 'package:auvy/services/updater_service.dart';

enum _Filter { all, music, podcasts, suggested, auvy }

/// The feed behind the bell on Home: new releases from followed artists, new
/// episodes of followed podcasts, Auvy updates and what was made for you.
/// Newest first, with what is new since the last visit on top (it stays marked
/// until the page is left), upcoming releases next, "You might like" (releases
/// from artists not followed that fit the listener's taste), then the rest.
/// Items stay 30 days; nothing is cleared by reading it.
class WhatsNewPage extends ConsumerStatefulWidget {
  const WhatsNewPage({super.key});

  @override
  ConsumerState<WhatsNewPage> createState() => _WhatsNewPageState();
}

class _WhatsNewPageState extends ConsumerState<WhatsNewPage> {
  late final WhatsNewNotifier _notifier;
  late final Set<String> _seenAtOpen;
  _Filter _filter = _Filter.all;
  String? _opening;
  Timer? _autoRefresh;

  @override
  void initState() {
    super.initState();
    _notifier = ref.read(whatsNewProvider.notifier);
    _seenAtOpen = {...ref.read(whatsNewProvider).seen};
    // Opening the page looks again unless it just did, and so does staying on it.
    _notifier.maybeCheck(minGap: const Duration(minutes: 15), force: true);
    _autoRefresh = Timer.periodic(const Duration(minutes: 15),
        (_) => _notifier.maybeCheck(minGap: const Duration(minutes: 15), force: true));
    _notifier.refreshPermission();
  }

  @override
  void dispose() {
    _autoRefresh?.cancel();
    _notifier.markAllSeen();
    super.dispose();
  }

  /// Pull to refresh and the refresh button: always looks, and says what it found.
  Future<void> _refresh() async {
    HapticService.selection();
    // Not more often than every 30 seconds: Apple's catalogue allows about 20
    // requests a minute, and a check is several.
    final added =
        await _notifier.maybeCheck(minGap: const Duration(seconds: 30), manual: true);
    if (!mounted) return;
    final s = ref.read(whatsNewProvider);
    final recent = DateTime.now().millisecondsSinceEpoch - s.lastCheckMs < 30000;
    AnimatedToast.message(added < 0
        ? (recent ? 'Already up to date' : "Couldn't check right now")
        : added == 0
            ? 'Nothing new yet'
            : '$added new');
  }

  bool _matches(WhatsNewItem i) => switch (_filter) {
        _Filter.all => true,
        _Filter.music => i.kind == WhatsNewKind.release,
        _Filter.podcasts => i.kind == WhatsNewKind.episode,
        _Filter.suggested => i.kind == WhatsNewKind.suggested,
        _Filter.auvy => i.kind == WhatsNewKind.app || i.kind == WhatsNewKind.madeForYou,
      };

  @override
  Widget build(BuildContext context) {
    final s = ref.watch(whatsNewProvider);
    final theme = ref.watch(themeProvider);
    final now = DateTime.now();
    final items = s.items.where(_matches).toList();
    bool suggestion(WhatsNewItem i) => i.kind == WhatsNewKind.suggested;
    final fresh = [
      for (final i in items)
        if (!suggestion(i) && !_seenAtOpen.contains(i.key) && !i.isUpcoming(now)) i
    ];
    final soon = [for (final i in items) if (!suggestion(i) && i.isUpcoming(now)) i]
      ..sort((a, b) => a.dateMs.compareTo(b.dateMs));
    final mightLike = [for (final i in items) if (suggestion(i)) i];
    final earlier = [
      for (final i in items)
        if (!suggestion(i) && _seenAtOpen.contains(i.key) && !i.isUpcoming(now)) i
    ];
    final kinds = {for (final i in s.items) i.kind};
    final follows = ref.watch(libraryProvider.select((l) =>
        l.subscribedArtists.length +
        l.likedAlbums.where((a) => a.recordType == 'podcast').length));

    return DynamicBackground(
      child: Scaffold(
        backgroundColor: Colors.transparent,
        body: SafeArea(
          bottom: false,
          child: RefreshIndicator(
            color: theme,
            backgroundColor: const Color(0xFF2A2A2A),
            onRefresh: _refresh,
            child: CustomScrollView(
              physics: const BouncingScrollPhysics(parent: AlwaysScrollableScrollPhysics()),
              slivers: [
                SliverToBoxAdapter(child: _header(s, theme)),
                if (s.notify == null)
                  SliverToBoxAdapter(child: _offer(theme)),
                if (kinds.length > 1)
                  SliverToBoxAdapter(child: _filters(kinds, theme)),
                if (s.checking && s.items.isEmpty)
                  SliverToBoxAdapter(
                    child: Padding(
                      padding: const EdgeInsets.all(40),
                      child: Center(child: CircularProgressIndicator(color: theme)),
                    ),
                  )
                else if (items.isEmpty)
                  SliverToBoxAdapter(child: _empty(follows == 0))
                else ...[
                  if (fresh.isNotEmpty) ..._section('New', fresh, theme, now, isNew: true),
                  if (soon.isNotEmpty) ..._section('Coming soon', soon, theme, now),
                  if (mightLike.isNotEmpty) ..._section('You might like', mightLike, theme, now),
                  if (earlier.isNotEmpty) ..._section('Earlier', earlier, theme, now),
                ],
                // Clears the mini-player and nav bar.
                const SliverToBoxAdapter(child: SizedBox(height: 180)),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _header(WhatsNewState s, Color theme) {
    final on = s.notify == true;
    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 8, 8, 4),
      child: Row(
        children: [
          IconButton(
            tooltip: 'Back',
            icon: const Icon(Icons.arrow_back, color: Colors.white),
            onPressed: () => Navigator.of(context).pop(),
          ),
          const SizedBox(width: 4),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text("What's New",
                    style: TextStyle(fontSize: 26, fontWeight: FontWeight.w800, color: Colors.white)),
                Text(_checkedLine(s),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(color: Colors.white.withValues(alpha: 0.55), fontSize: 12)),
              ],
            ),
          ),
          s.checking
              ? Padding(
                  padding: const EdgeInsets.all(14),
                  child: SizedBox(
                      width: 20, height: 20,
                      child: CircularProgressIndicator(strokeWidth: 2, color: theme)),
                )
              : IconButton(
                  tooltip: 'Refresh',
                  icon: Icon(Icons.refresh_rounded, color: Colors.white.withValues(alpha: 0.8)),
                  onPressed: _refresh,
                ),
          IconButton(
            tooltip: on ? 'Notifications on' : 'Notifications off',
            icon: Icon(
              on ? Icons.notifications_active_rounded : Icons.notifications_off_outlined,
              color: on ? theme : Colors.white.withValues(alpha: 0.6),
            ),
            onPressed: () async {
              HapticService.selection();
              if (on) {
                await _notifier.disableNotifications();
                AnimatedToast.message('New release notifications off');
              } else {
                final ok = await _notifier.enableNotifications();
                AnimatedToast.message(ok
                    ? "You'll be notified about new releases"
                    : 'Allow notifications for Auvy in Settings to get them');
              }
            },
          ),
        ],
      ),
    );
  }

  /// "Checked 5 min ago · 9 artists · 2 podcasts".
  String _checkedLine(WhatsNewState s) {
    if (s.checking) return 'Checking…';
    if (s.lastCheckMs == 0) return 'Not checked yet';
    final ago = DateTime.now().difference(DateTime.fromMillisecondsSinceEpoch(s.lastCheckMs));
    final when = ago.inMinutes < 1
        ? 'just now'
        : ago.inMinutes < 60
            ? '${ago.inMinutes} min ago'
            : ago.inHours < 24
                ? '${ago.inHours} h ago'
                : '${ago.inDays} d ago';
    String n(int count, String one) => '$count $one${count == 1 ? '' : 's'}';
    return 'Checked $when · ${n(s.artists, 'artist')} · ${n(s.podcasts, 'podcast')}';
  }

  Widget _offer(Color theme) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
      child: Container(
        padding: const EdgeInsets.fromLTRB(14, 14, 14, 6),
        decoration: BoxDecoration(
          color: Colors.white.withValues(alpha: 0.06),
          borderRadius: BorderRadius.circular(18),
          border: Border.all(color: theme.withValues(alpha: 0.35)),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(Icons.notifications_active_outlined, color: theme, size: 20),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    'Get a notification when artists and podcasts you follow '
                    'release something new, even when Auvy is closed.',
                    style: TextStyle(
                        color: Colors.white.withValues(alpha: 0.8), fontSize: 13, height: 1.4),
                  ),
                ),
              ],
            ),
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                TextButton(
                  onPressed: _notifier.disableNotifications,
                  child: Text('Not now',
                      style: TextStyle(color: Colors.white.withValues(alpha: 0.6))),
                ),
                TextButton(
                  onPressed: () async {
                    final ok = await _notifier.enableNotifications();
                    if (ok) AnimatedToast.message("You'll be notified about new releases");
                  },
                  child: Text('Turn on',
                      style: TextStyle(color: theme, fontWeight: FontWeight.w700)),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _filters(Set<WhatsNewKind> kinds, Color theme) {
    final options = [
      (_Filter.all, 'All'),
      if (kinds.contains(WhatsNewKind.release)) (_Filter.music, 'Music'),
      if (kinds.contains(WhatsNewKind.episode)) (_Filter.podcasts, 'Podcasts'),
      if (kinds.contains(WhatsNewKind.suggested)) (_Filter.suggested, 'You might like'),
      if (kinds.contains(WhatsNewKind.app) || kinds.contains(WhatsNewKind.madeForYou))
        (_Filter.auvy, 'For you'),
    ];
    return SizedBox(
      height: 44,
      child: ListView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
        children: [
          for (final (f, label) in options)
            Padding(
              padding: const EdgeInsets.only(right: 8),
              child: AuvyPill(
                label: label,
                selected: _filter == f,
                accent: theme,
                onTap: () => setState(() => _filter = f),
              ),
            ),
        ],
      ),
    );
  }

  Widget _empty(bool followsNobody) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(32, 60, 32, 0),
      child: Column(
        children: [
          Icon(Icons.notifications_none_rounded,
              size: 48, color: Colors.white.withValues(alpha: 0.35)),
          const SizedBox(height: 14),
          Text(
            followsNobody
                ? 'Follow artists and podcasts, and their new releases show up here.'
                : 'Nothing new from the artists and podcasts you follow in the last few weeks.',
            textAlign: TextAlign.center,
            style: TextStyle(color: Colors.white.withValues(alpha: 0.65), fontSize: 14, height: 1.45),
          ),
        ],
      ),
    );
  }

  List<Widget> _section(String title, List<WhatsNewItem> items, Color theme, DateTime now,
      {bool isNew = false}) {
    return [
      SliverToBoxAdapter(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 18, 20, 6),
          child: Text(title,
              style: const TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.w800)),
        ),
      ),
      SliverList.builder(
        itemCount: items.length,
        itemBuilder: (_, i) => _row(items[i], theme, now, isNew),
      ),
    ];
  }

  Widget _row(WhatsNewItem item, Color theme, DateTime now, bool isNew) {
    final upcoming = item.isUpcoming(now);
    final subtitle = [
      if (item.label.isNotEmpty) item.label,
      if (item.source.isNotEmpty && item.kind != WhatsNewKind.app) item.source,
    ].join(' · ');
    return InkWell(
      onTap: () => _open(item),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        child: Row(
          children: [
            SizedBox(
              width: 10,
              child: isNew
                  ? Container(
                      width: 7, height: 7,
                      decoration: BoxDecoration(color: theme, shape: BoxShape.circle))
                  : null,
            ),
            const SizedBox(width: 4),
            SizedBox(
              width: 56,
              height: 56,
              child: item.image.isNotEmpty
                  ? AuvyImage(path: item.image, width: 56, height: 56, borderRadius: 8, decodeWidth: 168)
                  : Container(
                      decoration: BoxDecoration(
                          color: Colors.white.withValues(alpha: 0.08),
                          borderRadius: BorderRadius.circular(8)),
                      child: Icon(
                          item.kind == WhatsNewKind.app
                              ? Icons.system_update_alt_rounded
                              : Icons.auto_awesome_rounded,
                          color: theme),
                    ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(item.title,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                          color: Colors.white, fontSize: 14.5, fontWeight: FontWeight.w600)),
                  if (subtitle.isNotEmpty) ...[
                    const SizedBox(height: 2),
                    Text(subtitle,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(color: Colors.white.withValues(alpha: 0.6), fontSize: 12.5)),
                  ],
                  if (item.note.isNotEmpty) ...[
                    const SizedBox(height: 2),
                    Text(item.note,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                            color: theme.withValues(alpha: 0.85),
                            fontSize: 11.5,
                            fontWeight: FontWeight.w600)),
                  ],
                ],
              ),
            ),
            const SizedBox(width: 8),
            if (_opening == item.key)
              SizedBox(
                  width: 16, height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2, color: theme))
            else
              Text(_when(item, now, upcoming),
                  style: TextStyle(
                      color: upcoming ? theme : Colors.white.withValues(alpha: 0.5),
                      fontSize: 12,
                      fontWeight: upcoming ? FontWeight.w700 : FontWeight.w500)),
          ],
        ),
      ),
    );
  }

  String _when(WhatsNewItem item, DateTime now, bool upcoming) {
    final d = DateTime.fromMillisecondsSinceEpoch(item.dateMs);
    final today = DateTime(now.year, now.month, now.day);
    final day = DateTime(d.year, d.month, d.day);
    final days = day.difference(today).inDays;
    final date = MaterialLocalizations.of(context).formatShortMonthDay(d);
    if (upcoming) return 'Out ${_outOn(item, now)}';
    if (days == 0) return 'Today';
    if (days == -1) return 'Yesterday';
    if (days > -7) return '${-days} days ago';
    return date;
  }

  /// "tomorrow" or "Oct 16", for an upcoming release.
  String _outOn(WhatsNewItem item, DateTime now) {
    final d = DateTime.fromMillisecondsSinceEpoch(item.dateMs);
    final days = DateTime(d.year, d.month, d.day)
        .difference(DateTime(now.year, now.month, now.day))
        .inDays;
    return days <= 1 ? 'tomorrow' : MaterialLocalizations.of(context).formatShortMonthDay(d);
  }

  Future<void> _open(WhatsNewItem item) async {
    if (_opening != null) return;
    HapticService.light();
    final now = DateTime.now();
    switch (item.kind) {
      case WhatsNewKind.release:
      case WhatsNewKind.suggested:
        if (item.isUpcoming(now)) {
          AnimatedToast.message('${item.title} comes out ${_outOn(item, now)}');
          return;
        }
        setState(() => _opening = item.key);
        try {
          await _openRelease(item);
        } finally {
          if (mounted) setState(() => _opening = null);
        }
      case WhatsNewKind.episode:
        final show = ref
            .read(libraryProvider)
            .likedAlbums
            .where((a) => a.recordType == 'podcast' && a.id == item.target)
            .firstOrNull;
        if (show == null) {
          AnimatedToast.message("You don't follow ${item.source} any more");
          return;
        }
        AppNavigation.push(
            context,
            PodcastShowPage(
              show: PodcastShow(
                  collectionName: show.title,
                  artistName: show.artist,
                  artworkUrl: show.image,
                  feedUrl: show.id),
              themeColor: ref.read(themeProvider),
            ));
      case WhatsNewKind.app:
        if (item.key.startsWith('app:installed:')) {
          AppNavigation.push(context, const ChangelogPage());
        } else {
          await UpdaterService.checkForUpdates(context, ref.read(themeProvider),
              manualCheck: true);
        }
      case WhatsNewKind.madeForYou:
        final row = ref
            .read(libraryProvider)
            .allItems
            .where((i) => i.title == item.target)
            .firstOrNull;
        if (row == null) {
          AnimatedToast.message('That playlist is gone');
          return;
        }
        AppNavigation.push(context, PlaylistPage(libraryPlaylist: row),
            name: AppNavigation.playlistTag(row.title));
    }
  }

  /// A release is opened on YouTube Music: from the followed artist's page when
  /// it is listed there (the page is cached), else by searching for it.
  Future<void> _openRelease(WhatsNewItem item) async {
    final want = normalizeArtistName(item.title);
    final artist = ref
        .read(libraryProvider)
        .subscribedArtists
        .where((a) => a.id == item.target || a.title == item.target)
        .firstOrNull;
    Album? album;
    if (artist != null) {
      try {
        final data = await ref.read(artistProvider(artist.artistPageKey).future);
        album = [...?data?.singles, ...?data?.albums]
            .where((a) => normalizeArtistName(a.title) == want)
            .firstOrNull;
      } catch (_) {}
    }
    if (!mounted) return;
    if (album != null) {
      await AppNavigation.push(context, AlbumPage(album: album, artistName: item.source),
          name: AppNavigation.albumTag(album));
      return;
    }
    try {
      final songs =
          await ref.read(searchServiceProvider).search('${item.source} ${item.title}', 'track');
      if (!mounted) return;
      if (songs.isEmpty) {
        AnimatedToast.message("${item.title} isn't on YouTube Music yet");
        return;
      }
      final song = songs.first;
      final found = ContentMenus.buildAlbumForSong(song);
      await AppNavigation.push(
          context, AlbumPage(album: found, artistName: song.artist, fallbackTrack: song),
          name: AppNavigation.albumTag(found));
    } catch (_) {
      AnimatedToast.message("Couldn't open ${item.title}");
    }
  }
}
