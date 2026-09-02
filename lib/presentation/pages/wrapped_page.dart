import 'package:auvy/services/listening_policy.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:auvy/data/dummy_data.dart';
import 'package:auvy/presentation/widgets/auvy_image.dart';
import 'package:auvy/presentation/widgets/dynamic_background.dart';
import 'package:auvy/presentation/widgets/share_postcard.dart';
import 'package:auvy/providers/intelligence_provider.dart';
import 'package:auvy/providers/player_provider.dart';
import 'package:auvy/providers/theme_provider.dart';
import 'package:auvy/services/haptic_service.dart';

/// **Auvy Wrapped** — a swipeable recap story built entirely from data
/// `intelligence_provider` has been collecting all along. No new tracking, no
/// backend, no network.
///
/// Two things make it different from a Spotify clone:
///
///  * **The night card.** Ranked by day-part LIFT, it names the artist you play
///    *disproportionately* late — not just your overall favourite. Nothing else
///    in this space keeps a per-day-part profile, so no other player can show it.
///  * **It's honest.** Minutes are explicitly labelled an estimate (Auvy records
///    play counts, not listened duration), and if history crediting was paused
///    the recap says so instead of quietly under-reporting.
///
/// Gated on `hasEnoughData` — a recap built from nine plays is worse than none.
class WrappedPage extends ConsumerStatefulWidget {
  const WrappedPage({super.key});

  @override
  ConsumerState<WrappedPage> createState() => _WrappedPageState();
}

class _WrappedPageState extends ConsumerState<WrappedPage> {
  final PageController _pages = PageController();
  int _index = 0;
  Map<String, dynamic>? _stats;

  @override
  void initState() {
    super.initState();
    // Computed ONCE: the cards must never recompute mid-swipe.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final s = ref.read(intelligenceProvider.notifier).wrappedStats();
      if (mounted) setState(() => _stats = s);
    });
  }

  @override
  void dispose() {
    _pages.dispose();
    super.dispose();
  }

  void _next() {
    HapticService.selection();
    final last = _cardCount - 1;
    if (_index >= last) {
      Navigator.of(context).maybePop();
    } else {
      _pages.nextPage(
          duration: const Duration(milliseconds: 420),
          curve: Curves.easeOutCubic);
    }
  }

  int get _cardCount {
    final s = _stats;
    if (s == null) return 1;
    var n = 4; // intro, minutes, top artists, top song
    if ((s['nightArtist'] as String).isNotEmpty) n++;
    if ((s['streakLength'] as int) >= 3) n++;
    n++; // discovery
    n++; // outro
    return n;
  }

  @override
  Widget build(BuildContext context) {
    final theme = ref.watch(themeProvider);
    final s = _stats;

    if (s == null) {
      return DynamicBackground(
        child: Scaffold(
          backgroundColor: Colors.transparent,
          body: const Center(
            child: CircularProgressIndicator(
                strokeWidth: 2, color: Colors.white24),
          ),
        ),
      );
    }

    if (s['hasEnoughData'] != true) {
      return _notEnoughYet(theme, s);
    }

    final cards = <Widget>[
      _intro(theme, s),
      _minutes(theme, s),
      _topArtists(theme, s),
      _topSong(theme, s),
      if ((s['nightArtist'] as String).isNotEmpty) _nightCard(theme, s),
      if ((s['streakLength'] as int) >= 3) _streak(theme, s),
      _discovery(theme, s),
      _outro(theme, s),
    ];

    return DynamicBackground(
      child: Scaffold(
        backgroundColor: Colors.transparent,
        body: SafeArea(
          child: Column(
            children: [
              // Story progress segments, like a Stories UI.
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 10, 8, 4),
                child: Row(children: [
                  Expanded(
                    child: Row(
                      children: List.generate(cards.length, (i) {
                        return Expanded(
                          child: AnimatedContainer(
                            duration: const Duration(milliseconds: 300),
                            height: 3,
                            margin: const EdgeInsets.symmetric(horizontal: 2),
                            decoration: BoxDecoration(
                              color: i <= _index
                                  ? theme
                                  : Colors.white.withOpacity(0.14),
                              borderRadius: BorderRadius.circular(2),
                            ),
                          ),
                        );
                      }),
                    ),
                  ),
                  IconButton(
                    icon: Icon(Icons.close_rounded,
                        color: Colors.white.withOpacity(0.6), size: 22),
                    onPressed: () => Navigator.of(context).maybePop(),
                  ),
                ]),
              ),
              Expanded(
                child: GestureDetector(
                  // Tap anywhere advances, like a story.
                  onTap: _next,
                  child: PageView(
                    controller: _pages,
                    onPageChanged: (i) => setState(() => _index = i),
                    children: cards,
                  ),
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(24, 0, 24, 18),
                child: Text(
                  _index == cards.length - 1 ? '' : 'Tap to continue',
                  style: TextStyle(
                      color: Colors.white.withOpacity(0.55),
                      fontSize: 11.5,
                      fontWeight: FontWeight.w600),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  // Shared card scaffolding

  Widget _card({required List<Widget> children, CrossAxisAlignment? align}) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 30),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        crossAxisAlignment: align ?? CrossAxisAlignment.start,
        children: children,
      ),
    );
  }

  Widget _kicker(String text, Color theme) => Text(
        text.toUpperCase(),
        style: TextStyle(
            color: theme,
            fontSize: 11.5,
            fontWeight: FontWeight.w900,
            letterSpacing: 2.0),
      );

  Widget _big(String text, {double size = 46}) => Text(
        text,
        style: TextStyle(
            color: Colors.white,
            fontSize: size,
            fontWeight: FontWeight.w900,
            height: 1.05,
            letterSpacing: -1.2),
      );

  Widget _body(String text) => Text(
        text,
        style: TextStyle(
            color: Colors.white.withOpacity(0.78),
            fontSize: 14.5,
            height: 1.5,
            fontWeight: FontWeight.w500),
      );

  // Cards

  Widget _intro(Color theme, Map<String, dynamic> s) => _card(children: [
        _kicker('Auvy Wrapped', theme),
        const SizedBox(height: 16),
        _big('Your\nlistening,\nunwrapped.', size: 40),
        const SizedBox(height: 18),
        _body('${s['totalPlays']} plays. ${s['uniqueArtists']} artists. '
            'One very specific taste.'),
        if (s['historyWasPaused'] == true) ...[
          const SizedBox(height: 18),
          // Said up front, not buried: a recap that hides a gap is worse than
          // one that admits it.
          Row(children: [
            Icon(Icons.pause_circle_outline_rounded,
                size: 15, color: Colors.orangeAccent.withOpacity(0.8)),
            const SizedBox(width: 7),
            Expanded(
              child: Text(
                'Listening history is paused, so anything played while it was '
                'off isn\'t counted here.',
                style: TextStyle(
                    color: Colors.orangeAccent.withOpacity(0.75),
                    fontSize: 12,
                    height: 1.4),
              ),
            ),
          ]),
        ],
      ]);

  Widget _minutes(Color theme, Map<String, dynamic> s) {
    final mins = s['estimatedMinutes'] as int;
    final hours = (mins / 60).floor();
    return _card(children: [
      _kicker('Time spent', theme),
      const SizedBox(height: 16),
      _big('about\n${_thousands(mins)}\nminutes', size: 42),
      const SizedBox(height: 18),
      _body(hours >= 1
          ? "That's roughly $hours ${hours == 1 ? 'hour' : 'hours'} of music."
          : 'Just getting started.'),
      const SizedBox(height: 14),
      // The estimate is disclosed, not implied.
      Row(children: [
        Icon(Icons.info_outline_rounded,
            size: 14, color: Colors.white.withOpacity(0.3)),
        const SizedBox(width: 6),
        Expanded(
          child: Text(
            'Estimated: Auvy counts plays, not exact listening time, so this is '
            'plays × track length.',
            style: TextStyle(
                color: Colors.white.withOpacity(0.66),
                fontSize: 11.5,
                height: 1.4),
          ),
        ),
      ]),
    ]);
  }

  Widget _topArtists(Color theme, Map<String, dynamic> s) {
    final list = (s['topArtists'] as List).cast<Map<String, dynamic>>();
    return _card(children: [
      _kicker('Your top artists', theme),
      const SizedBox(height: 20),
      for (var i = 0; i < list.length; i++)
        Padding(
          padding: const EdgeInsets.only(bottom: 14),
          child: Row(children: [
            SizedBox(
              width: 30,
              child: Text('${i + 1}',
                  style: TextStyle(
                      color: theme,
                      fontSize: 19,
                      fontWeight: FontWeight.w900)),
            ),
            Expanded(
              child: Text(list[i]['name'] as String,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                      color: Colors.white,
                      fontSize: i == 0 ? 24 : 18,
                      fontWeight: i == 0 ? FontWeight.w900 : FontWeight.w700)),
            ),
            Text('${list[i]['plays']}',
                style: TextStyle(
                    color: Colors.white.withOpacity(0.66),
                    fontSize: 13,
                    fontWeight: FontWeight.w700)),
          ]),
        ),
    ]);
  }

  Widget _topSong(Color theme, Map<String, dynamic> s) {
    final list = (s['topTracks'] as List).cast<Map<String, dynamic>>();
    if (list.isEmpty) return _card(children: [_body('No clear favourite yet.')]);
    final song = list.first['song'] as Song;
    final plays = list.first['plays'] as int;
    return _card(
      align: CrossAxisAlignment.center,
      children: [
        _kicker('Your #1 song', theme),
        const SizedBox(height: 22),
        Container(
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(16),
            boxShadow: [
              BoxShadow(
                  color: theme.withOpacity(0.35),
                  blurRadius: 50,
                  spreadRadius: 2),
            ],
          ),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(ListeningPolicy.roundArtwork(16)),
            child: AuvyImage(
                path: song.image, width: 196, height: 196, fit: BoxFit.cover),
          ),
        ),
        const SizedBox(height: 22),
        Text(song.title,
            textAlign: TextAlign.center,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(
                color: Colors.white,
                fontSize: 24,
                fontWeight: FontWeight.w900,
                height: 1.15)),
        const SizedBox(height: 6),
        Text(song.displayArtist,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
                color: Colors.white.withOpacity(0.72), fontSize: 15)),
        const SizedBox(height: 14),
        Text('$plays ${plays == 1 ? 'play' : 'plays'}',
            style: TextStyle(
                color: theme, fontSize: 13.5, fontWeight: FontWeight.w800)),
      ],
    );
  }

  /// The card no other player can produce.
  Widget _nightCard(Color theme, Map<String, dynamic> s) => _card(children: [
        _kicker('After dark', theme),
        const SizedBox(height: 16),
        _big('Your\n2am\nartist', size: 42),
        const SizedBox(height: 20),
        Text(s['nightArtist'] as String,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
                color: theme,
                fontSize: 30,
                fontWeight: FontWeight.w900,
                height: 1.1)),
        const SizedBox(height: 18),
        _body('Not your most-played overall — the one you reach for '
            'disproportionately at night. Auvy keeps a separate profile for '
            'every slice of your week.'),
      ]);

  Widget _streak(Color theme, Map<String, dynamic> s) => _card(children: [
        _kicker('On a run', theme),
        const SizedBox(height: 16),
        _big('${s['streakLength']}\nin a row', size: 44),
        const SizedBox(height: 20),
        Text(_titleCase(s['streakGenre'] as String),
            style: TextStyle(
                color: theme, fontSize: 26, fontWeight: FontWeight.w900)),
        const SizedBox(height: 16),
        _body('Your longest unbroken streak in one genre. Commitment.'),
      ]);

  Widget _discovery(Color theme, Map<String, dynamic> s) => _card(children: [
        _kicker('Discovery', theme),
        const SizedBox(height: 16),
        _big('${s['newArtists']}\nnew\nartists', size: 42),
        const SizedBox(height: 20),
        _body('First-time listens across ${s['uniqueTracks']} different '
            'tracks. Your top genre was '
            '${_titleCase(s['topGenre'] as String)}.'),
      ]);

  Widget _outro(Color theme, Map<String, dynamic> s) {
    final list = (s['topTracks'] as List).cast<Map<String, dynamic>>();
    final song = list.isNotEmpty ? list.first['song'] as Song : null;
    return _card(
      align: CrossAxisAlignment.center,
      children: [
        _kicker("That's your year", theme),
        const SizedBox(height: 18),
        _big('Keep\nlistening.', size: 40),
        const SizedBox(height: 26),
        if (song != null)
          SizedBox(
            width: double.infinity,
            height: 50,
            child: ElevatedButton.icon(
              onPressed: () {
                HapticService.medium();
                // Reuses the existing premium postcard rather than a bespoke
                // share image.
                showSharePostcardDialog(context, song, theme);
              },
              style: ElevatedButton.styleFrom(
                backgroundColor: theme,
                foregroundColor: Colors.black,
                elevation: 0,
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(25)),
              ),
              icon: const Icon(Icons.ios_share_rounded, size: 18),
              label: const Text('Share your top song',
                  style: TextStyle(fontWeight: FontWeight.w900, fontSize: 14.5)),
            ),
          ),
        const SizedBox(height: 10),
        if (song != null)
          SizedBox(
            width: double.infinity,
            height: 46,
            child: TextButton(
              onPressed: () {
                final songs = list.map((e) => e['song'] as Song).toList();
                ref.read(playerProvider.notifier).playSong(
                      songs.first,
                      newQueue: songs,
                      index: 0,
                      source: 'Auvy Wrapped',
                      locationName: 'Your top songs',
                    );
                Navigator.of(context).maybePop();
              },
              style: TextButton.styleFrom(
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(23),
                  side: BorderSide(color: Colors.white.withOpacity(0.14)),
                ),
              ),
              child: const Text('Play my top 5',
                  style: TextStyle(
                      color: Colors.white,
                      fontWeight: FontWeight.w800,
                      fontSize: 14)),
            ),
          ),
      ],
    );
  }

  Widget _notEnoughYet(Color theme, Map<String, dynamic> s) {
    return DynamicBackground(
      child: Scaffold(
        backgroundColor: Colors.transparent,
        appBar: AppBar(
          backgroundColor: Colors.transparent,
          elevation: 0,
          leading: IconButton(
            icon: const Icon(Icons.arrow_back_rounded, color: Colors.white),
            onPressed: () => Navigator.of(context).maybePop(),
          ),
        ),
        body: Center(
          child: Padding(
            padding: const EdgeInsets.all(34),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.auto_awesome_rounded, size: 46, color: theme),
                const SizedBox(height: 20),
                const Text('Your Wrapped is still brewing',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                        color: Colors.white,
                        fontSize: 20,
                        fontWeight: FontWeight.w900)),
                const SizedBox(height: 12),
                Text(
                  'Auvy needs a bit more listening before a recap says anything '
                  'meaningful — about 25 plays across 5 tracks. '
                  'You\'re at ${s['totalPlays']} '
                  '${s['totalPlays'] == 1 ? 'play' : 'plays'}.',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                      color: Colors.white.withOpacity(0.72),
                      fontSize: 13.5,
                      height: 1.5),
                ),
                if (s['historyWasPaused'] == true) ...[
                  const SizedBox(height: 16),
                  Text(
                    'Listening history is currently paused, so new plays '
                    'aren\'t being counted.',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                        color: Colors.orangeAccent.withOpacity(0.8),
                        fontSize: 12.5,
                        height: 1.45),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }

  static String _thousands(int n) {
    final s = n.toString();
    final out = StringBuffer();
    for (var i = 0; i < s.length; i++) {
      if (i > 0 && (s.length - i) % 3 == 0) out.write(' ');
      out.write(s[i]);
    }
    return out.toString();
  }

  static String _titleCase(String s) {
    if (s.trim().isEmpty) return 'music';
    return s
        .split(' ')
        .where((w) => w.isNotEmpty)
        .map((w) => w[0].toUpperCase() + w.substring(1))
        .join(' ');
  }
}

