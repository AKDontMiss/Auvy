import 'package:flutter/material.dart';
import 'package:auvy/presentation/widgets/dynamic_background.dart';
import 'package:auvy/presentation/main_layout.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:auvy/providers/search_provider.dart';
import 'package:auvy/providers/intelligence_provider.dart';
import 'package:auvy/providers/theme_provider.dart';
import 'package:auvy/services/artist_metadata_service.dart';
import 'package:auvy/services/cloud_sync_service.dart';
import 'package:auvy/services/haptic_service.dart';
import 'package:auvy/presentation/widgets/auvy_image.dart';

// --- Data Models for Onboarding ---
class ArtistItem {
  final String name;
  final String imageUrl;
  bool isSelected;
  bool hasExpanded;
  bool isNewlyAdded; // triggers the pop-in animation

  ArtistItem({
    required this.name,
    required this.imageUrl,
    this.isSelected = false,
    this.hasExpanded = false,
    this.isNewlyAdded = false,
  });
}

/// Onboarding: one question (pick some artists), and the answer is actually used.
///
/// Artists are what the recommender seeds from, and `artistAffinities` is what
/// `isInColdStart` counts. Genres follow from the artists:
/// [IntelligenceNotifier.seedTasteFromPickedArtists] fetches each pick's tags and
/// seeds `genreAffinities` from them. Picks are written directly as declarations,
/// not as fake plays, so nothing shows up in history, stats or the recap.
///
/// Tapping an artist adds similar artists to the grid, so the grid grows toward the
/// person using it.
///
/// Shown on first run, then the app. **Skip for now** seeds nothing: an invented
/// profile is worse than an empty one, since the engine treats it as real and it
/// never decays. An empty profile fills itself from real plays.
class OnboardingPage extends ConsumerStatefulWidget {
  const OnboardingPage({super.key});

  @override
  ConsumerState<OnboardingPage> createState() => _OnboardingPageState();
}

class _OnboardingPageState extends ConsumerState<OnboardingPage> {
  /// How many picks before the mix is worth building. Five is enough for the
  /// similar-artist halo to cover a range without the screen feeling like a
  /// form; below that the seeds all sound like one artist.
  static const int _kMinPicks = 5;

  /// True while the seed is being written, so the CTA can say what it is doing
  /// instead of appearing to hang. Genre tags and similar artists are network
  /// calls, and this screen is the one place the user is waiting on them.
  bool _seeding = false;

  // Multiplexing Artist List
  final List<ArtistItem> _displayedArtists = [];
  // Artist search (find + add any artist, not just the seeded grid).
  final TextEditingController _artistSearchCtrl = TextEditingController();
  bool _artistSearching = false;

  // Seed-artist POOL — a broad, genre-diverse set. A fresh RANDOM SUBSET is
  // shown each time onboarding runs (see initState), so deleting the account
  // and re-onboarding surfaces DIFFERENT artists (YouTube-Music-style), not the
  // same fixed grid every time. Tapping one still expands with Last.fm similars.
  static const List<String> _seedArtistPool = [
    'The Weeknd', 'Taylor Swift', 'Drake', 'Bad Bunny', 'Billie Eilish',
    'Kendrick Lamar', 'Ariana Grande', 'Travis Scott', 'SZA', 'Arctic Monkeys',
    'Rosalía', 'Frank Ocean', 'Ed Sheeran', 'Dua Lipa', 'Post Malone',
    'J. Cole', 'Olivia Rodrigo', 'Coldplay', 'Beyoncé', 'Kanye West',
    'Rihanna', 'Lana Del Rey', 'Tyler, The Creator', 'Doja Cat', 'Metro Boomin',
    'Bruno Mars', 'Adele', 'Harry Styles', 'Playboi Carti', 'Daft Punk',
    'BTS', 'BLACKPINK', 'Karol G', 'Peso Pluma', 'Burna Boy', 'Tame Impala',
    'Radiohead', 'Lady Gaga', 'Nirvana', 'Kali Uchis', 'Future', '21 Savage',
    'Cardi B', 'Nicki Minaj', 'Sabrina Carpenter', 'Chappell Roan',
  ];

  @override
  void initState() {
    super.initState();
    // Shuffle the pool and take a subset → a different grid every onboarding.
    final pool = List<String>.of(_seedArtistPool)..shuffle();
    _displayedArtists.addAll(
        pool.take(18).map((name) => ArtistItem(name: name, imageUrl: '')));
    _fetchSeedImages();
  }

  @override
  void dispose() {
    _artistSearchCtrl.dispose();
    super.dispose();
  }

  /// How many seed pictures to fetch at once. Bounded, since an unbounded
  /// Future.wait would open a connection per artist and hold every response in
  /// memory. Each fetch is a single search, so nine at a time fills the 18-tile grid
  /// in two waves.
  static const int _seedImageConcurrency = 9;

  /// Fetches the seed pictures concurrently (the work is network-bound). Each result
  /// is written back by name, not by a captured index, because tapping an artist
  /// inserts similar ones into the grid while these are in flight.
  Future<void> _fetchSeedImages() async {
    final searchService = ref.read(searchServiceProvider);

    final pending = <String>[
      for (final a in _displayedArtists)
        if (a.imageUrl.isEmpty || a.imageUrl.contains('lastfm')) a.name,
    ];
    if (pending.isEmpty) return;

    var next = 0;

    Future<void> worker() async {
      while (true) {
        // Stop the whole queue the moment the screen goes away, rather than
        // finishing a dozen fetches whose results nothing can receive.
        if (!mounted) return;
        final slot = next++;
        if (slot >= pending.length) return;
        final name = pending[slot];
        try {
          // resolveArtistCard, NOT getArtistData. The latter resolves the name
          // with a search and then browses the artist's ENTIRE PAGE — discography,
          // related artists, playlists — to read one thumbnail off the header.
          // That second request is the expensive half of the pair and none of it
          // reaches this grid. See SearchService.resolveArtistCard.
          final card = await searchService.resolveArtistCard(name);
          final resolved = card?.image ?? '';
          if (resolved.isEmpty || !mounted) continue;
          final at = _displayedArtists.indexWhere((a) => a.name == name);
          if (at < 0) continue;
          setState(() {
            _displayedArtists[at] = ArtistItem(
              name: _displayedArtists[at].name,
              imageUrl: resolved,
              // Preserve anything the user did while this was in flight.
              isSelected: _displayedArtists[at].isSelected,
              hasExpanded: _displayedArtists[at].hasExpanded,
            );
          });
        } catch (_) {}
      }
    }

    await Future.wait(<Future<void>>[
      for (var w = 0;
          w < (pending.length < _seedImageConcurrency
              ? pending.length
              : _seedImageConcurrency);
          w++)
        worker(),
    ]);
  }

  // --- MULTIPLEXING LOGIC ---
  void _onArtistTapped(int index) async {
    final artist = _displayedArtists[index];

    setState(() {
      artist.isSelected = !artist.isSelected;
    });

    // Inject similar artists using proper APIs
    if (artist.isSelected && !artist.hasExpanded) {
      artist.hasExpanded = true;

      try {
        final searchService = ref.read(searchServiceProvider);

        // Similar artists from Last.fm — time-bounded so a slow relation
        // lookup can never make the grid feel dead after a tap.
        final similar = await ArtistMetadataService()
            .getSimilarArtists(artist.name, limit: 3)
            .timeout(const Duration(seconds: 3));
        final existingNames =
            _displayedArtists.map((a) => a.name.toLowerCase()).toSet();

        // Resolve the suggestions' images in parallel and insert each as soon as it
        // resolves, so the first appears one search round trip after the tap.
        for (final s in similar) {
          if (existingNames.contains(s.title.toLowerCase())) continue;
          // Same resolver as the seed grid above — otherwise tapping an artist
          // would inject suggestions whose pictures came from a different source
          // than the tiles already on screen, and the grid would be visibly
          // mixed. Both now stop at the artist SEARCH result rather than
          // browsing the artist page for its header art.
          searchService
              .resolveArtistCard(s.title)
              .timeout(const Duration(seconds: 4))
              .then((resolved) {
            if (!mounted || resolved == null || resolved.image.isEmpty) return;
            final item = ArtistItem(
              name: s.title,
              imageUrl: resolved.image,
              isNewlyAdded: true, // trigger the pop-in animation
            );
            setState(() {
              // Strict double-check: never insert a duplicate.
              final names =
                  _displayedArtists.map((a) => a.name.toLowerCase()).toSet();
              if (names.contains(item.name.toLowerCase())) return;
              // Insert right below the tapped artist — its index may have
              // shifted since the tap, so look it up live.
              final anchor =
                  _displayedArtists.indexWhere((a) => a.name == artist.name);
              _displayedArtists.insert(
                  anchor == -1 ? _displayedArtists.length : anchor + 1, item);
            });
            // One-shot: once the pop-in has played, scrolling the tile out of
            // the grid's cache and back must not replay it.
            Future.delayed(const Duration(milliseconds: 450), () {
              item.isNewlyAdded = false;
            });
          }).catchError((_) {});
        }
      } catch (_) {}
    }
  }

  /// The picks, in the order the grid shows them.
  List<String> get _picked => _displayedArtists
      .where((a) => a.isSelected)
      .map((a) => a.name)
      .toList();

  /// Into the app now, personalise later. Seeds nothing: seeding chart artists would
  /// hand the taste engine invented preferences it treats like real ones. An empty
  /// profile fills itself within a few plays.
  Future<void> _quickStart() async {
    HapticService.light();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('has_onboarded', true);
    print('DIAG: Onboarding _quickStart: set has_onboarded to true');
    CloudSyncService.instance.scheduleBackup();
    if (!mounted) return;
    // No tutorial here: the walkthrough is only started from Settings (see
    // CoachTour.armedSignal).
    Navigator.of(context).pushReplacement(
      PageRouteBuilder(
        pageBuilder: (context, animation, secondaryAnimation) => const MainLayout(),
        transitionsBuilder: (context, animation, secondaryAnimation, child) =>
            FadeTransition(opacity: animation, child: child),
        transitionDuration: const Duration(milliseconds: 700),
      ),
    );
  }

  void _finishOnboarding() async {
    if (_seeding) return; // the CTA is a network call now; one at a time
    HapticService.light();
    setState(() => _seeding = true);
    final intel = ref.read(intelligenceProvider.notifier);

    // The picks go straight into the affinity maps via seedTasteFromPickedArtists,
    // which writes them by name, derives their genres and adds a bounded set of
    // similar artists, so the first mix is drawn from these names. It creates no
    // track row, so nothing appears as a play. Awaited, because the model should be
    // populated before the first recommendation is requested; the button says it's
    // working meanwhile.
    await intel.seedTasteFromPickedArtists(_picked);

    // Legacy cleanup, not part of the new path: builds that predate the `onb_`
    // guard could have real placeholder rows on disk, and this is the only
    // thing that removes them. Cheap, and it never has anything to do now.
    intel.pruneOnboardingData();

    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('has_onboarded', true);
    print('DIAG: Onboarding _finishOnboarding: set has_onboarded to true');
    // Push the flag (plus the freshly-seeded taste data) to the cloud now, so a
    // future reinstall + same-account login restores "already onboarded" and
    // skips this flow. Safe no-op when cloud sync isn't active.
    CloudSyncService.instance.scheduleBackup();

    if (!mounted) return;
    // NO TUTORIAL HERE either — same reason as the skip path above.
    Navigator.of(context).pushReplacement(
      PageRouteBuilder(
        pageBuilder: (context, animation, secondaryAnimation) => const MainLayout(),
        transitionsBuilder: (context, animation, secondaryAnimation, child) {
          return FadeTransition(opacity: animation, child: child);
        },
        transitionDuration: const Duration(milliseconds: 700),
      ),
    );
  }

  // Step metadata

  bool get _canProceed => _picked.length >= _kMinPicks;

  /// Progress hint over the CTA while it is still locked.
  ///
  /// Counts DOWN rather than reporting a fraction: "2 more" is an instruction,
  /// "3/5 picked" is a status. The screen only asks for one thing, so the copy
  /// should read as the one thing left to do.
  String? get _helperText {
    if (_seeding) return null;
    final left = _kMinPicks - _picked.length;
    if (left <= 0) return null;
    return left == _kMinPicks
        ? 'Pick $_kMinPicks artists you actually listen to'
        : '$left more to go';
  }

  @override
  Widget build(BuildContext context) {
    final themeColor = ref.watch(themeProvider);
    final canProceed = _canProceed;
    final picked = _picked.length;

    return DynamicBackground(
      child: Scaffold(
        backgroundColor: Colors.transparent,
        // Deliberately NOT resizeToAvoidBottomInset: false, unlike the pages
        // with a search field and no footer. The CTA lives at the bottom of a
        // Column, and letting the keyboard shrink the page is what keeps that
        // button reachable while the artist search is focused.
        body: SafeArea(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Header: a live count of how many more picks, beside the title.
              Padding(
                padding: const EdgeInsets.fromLTRB(24, 18, 24, 0),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            'Who do you\nlisten to?',
                            style: TextStyle(
                              color: Colors.white,
                              fontSize: 30,
                              height: 1.12,
                              fontWeight: FontWeight.w800,
                              letterSpacing: -0.5,
                            ),
                          ),
                          const SizedBox(height: 10),
                          // Says what the picks are used for: they become the seeds, and tapping one grows
                          // the grid.
                          Text(
                            'Auvy builds your first mixes from these — and '
                            'tapping one brings up artists like them.',
                            style: TextStyle(
                              color: Colors.white.withOpacity(0.62),
                              fontSize: 13.5,
                              height: 1.45,
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(width: 14),
                    _pickCounter(themeColor, picked),
                  ],
                ),
              ),
              const SizedBox(height: 18),

              // The one step.
              Expanded(child: _buildArtistMultiplexer(themeColor)),

              // Bottom bar.
              Container(
                padding: const EdgeInsets.fromLTRB(24, 10, 24, 20),
                child: Column(
                  children: [
                    AnimatedSwitcher(
                      duration: const Duration(milliseconds: 250),
                      child: _helperText != null
                          ? Padding(
                              key: ValueKey(_helperText),
                              padding: const EdgeInsets.only(bottom: 10),
                              child: Text(
                                _helperText!,
                                style: TextStyle(
                                    color: Colors.white.withOpacity(0.66),
                                    fontSize: 12.5,
                                    fontWeight: FontWeight.w600),
                              ),
                            )
                          : const SizedBox(height: 0, key: ValueKey('no_helper')),
                    ),
                    SizedBox(
                      width: double.infinity,
                      height: 56,
                      child: AnimatedOpacity(
                        opacity: canProceed || _seeding ? 1.0 : 0.35,
                        duration: const Duration(milliseconds: 250),
                        child: ElevatedButton(
                          style: ElevatedButton.styleFrom(
                            backgroundColor: Colors.white,
                            foregroundColor: Colors.black,
                            elevation: canProceed ? 10 : 0,
                            shadowColor: Colors.white.withOpacity(0.25),
                            shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(28)),
                          ),
                          onPressed:
                              canProceed && !_seeding ? _finishOnboarding : null,
                          // The button shows that it's working, since seeding fetches genre tags and similar
                          // artists after the tap.
                          child: _seeding
                              ? Row(
                                  mainAxisAlignment: MainAxisAlignment.center,
                                  children: [
                                    SizedBox(
                                      width: 17,
                                      height: 17,
                                      child: CircularProgressIndicator(
                                          strokeWidth: 2.2,
                                          valueColor:
                                              const AlwaysStoppedAnimation<Color>(
                                                  Colors.black54)),
                                    ),
                                    const SizedBox(width: 10),
                                    const Text('Building your mix…',
                                        style: TextStyle(
                                            fontSize: 15.5,
                                            fontWeight: FontWeight.w800)),
                                  ],
                                )
                              : const Row(
                                  mainAxisAlignment: MainAxisAlignment.center,
                                  children: [
                                    Text(
                                      'Build my mix',
                                      style: TextStyle(
                                          fontSize: 16,
                                          fontWeight: FontWeight.w800,
                                          letterSpacing: 0.2),
                                    ),
                                    SizedBox(width: 6),
                                    Icon(Icons.auto_awesome_rounded, size: 18),
                                  ],
                                ),
                        ),
                      ),
                    ),
                    const SizedBox(height: 6),
                    // The escape hatch stays a real option, not a hidden one.
                    // See the note on [_quickStart]: skipping seeds nothing on
                    // purpose, and that is a defensible outcome rather than a
                    // penalty, so it does not need to be buried.
                    if (!_seeding)
                      TextButton(
                        onPressed: _quickStart,
                        child: Text(
                          'Skip for now',
                          style: TextStyle(
                              color: Colors.white.withOpacity(0.6),
                              fontSize: 13.5,
                              fontWeight: FontWeight.w600),
                        ),
                      ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// Live pick count, in the accent colour once it is satisfied.
  ///
  /// Reads as a target rather than a score: dim while short, accent and ticked
  /// the moment there are enough, so the state of the screen is legible without
  /// reading the footer.
  Widget _pickCounter(Color themeColor, int picked) {
    final done = picked >= _kMinPicks;
    return AnimatedContainer(
      duration: const Duration(milliseconds: 220),
      padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 8),
      decoration: BoxDecoration(
        color: done ? themeColor.withOpacity(0.16) : Colors.white.withOpacity(0.06),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: done ? themeColor.withOpacity(0.55) : Colors.white.withOpacity(0.10),
        ),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (done) ...[
            Icon(Icons.check_rounded, size: 15, color: themeColor),
            const SizedBox(width: 5),
          ],
          Text(
            done ? '$picked' : '$picked/$_kMinPicks',
            style: TextStyle(
              color: done ? themeColor : Colors.white.withOpacity(0.72),
              fontSize: 14,
              fontWeight: FontWeight.w800,
              // Digits change every tap; without this the chip jitters.
              fontFeatures: const [FontFeature.tabularFigures()],
            ),
          ),
        ],
      ),
    );
  }


  Future<void> _searchAndAddArtist(String query) async {
    final q = query.trim();
    if (q.isEmpty || _artistSearching) return;
    FocusScope.of(context).unfocus();
    setState(() => _artistSearching = true);
    try {
      final results = await ref
          .read(searchServiceProvider)
          .search(q, 'artist')
          .timeout(const Duration(seconds: 6));
      final seen = _displayedArtists.map((a) => a.name.toLowerCase()).toSet();
      final adds = <ArtistItem>[];
      for (final r in results.take(6)) {
        final name = r.title.trim();
        if (name.isEmpty || seen.contains(name.toLowerCase())) continue;
        seen.add(name.toLowerCase());
        adds.add(ArtistItem(
            name: name, imageUrl: r.image, isNewlyAdded: true));
      }
      if (mounted) {
        setState(() {
          _displayedArtists.insertAll(0, adds); // newest matches first
          _artistSearchCtrl.clear();
        });
        // Let the pop-in play once, then stop re-triggering it on scroll.
        for (final a in adds) {
          Future.delayed(const Duration(milliseconds: 450),
              () => a.isNewlyAdded = false);
        }
      }
    } catch (_) {
      // Silent: a failed lookup just leaves the grid unchanged.
    } finally {
      if (mounted) setState(() => _artistSearching = false);
    }
  }

  Widget _buildArtistMultiplexer(Color themeColor) {
    return Column(
      children: [
        // Search any artist — not just the seeded grid.
        Padding(
          padding: const EdgeInsets.fromLTRB(24, 2, 24, 12),
          child: TextField(
            controller: _artistSearchCtrl,
            onSubmitted: _searchAndAddArtist,
            textInputAction: TextInputAction.search,
            style: const TextStyle(color: Colors.white, fontSize: 14.5),
            cursorColor: themeColor,
            decoration: InputDecoration(
              hintText: 'Search for an artist…',
              hintStyle: TextStyle(
                  color: Colors.white.withOpacity(0.66), fontSize: 14),
              isDense: true,
              prefixIcon: _artistSearching
                  ? Padding(
                      padding: const EdgeInsets.all(13),
                      child: SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(
                            strokeWidth: 2,
                            valueColor:
                                AlwaysStoppedAnimation<Color>(themeColor)),
                      ),
                    )
                  : Icon(Icons.search_rounded,
                      color: Colors.white.withOpacity(0.5), size: 20),
              filled: true,
              fillColor: Colors.white.withOpacity(0.06),
              contentPadding: const EdgeInsets.symmetric(vertical: 14),
              enabledBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(16),
                borderSide:
                    BorderSide(color: Colors.white.withOpacity(0.10)),
              ),
              focusedBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(16),
                borderSide: BorderSide(
                    color: themeColor.withOpacity(0.6), width: 1.4),
              ),
            ),
          ),
        ),
        Expanded(
          child: GridView.builder(
            key: const ValueKey('onboarding_artists'),
            padding: const EdgeInsets.fromLTRB(24, 2, 24, 24),
      physics: const BouncingScrollPhysics(),
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 3,
        crossAxisSpacing: 18,
        mainAxisSpacing: 26,
        childAspectRatio: 0.72, // leaves exact room for the name under the circle
      ),
      itemCount: _displayedArtists.length,
      itemBuilder: (context, index) {
        final artist = _displayedArtists[index];
        final isSelected = artist.isSelected;

        final colorHash = artist.name.hashCode;
        final color1 = HSLColor.fromAHSL(1.0, (colorHash % 360).toDouble(), 0.7, 0.5).toColor();
        final color2 = HSLColor.fromAHSL(1.0, ((colorHash + 40) % 360).toDouble(), 0.8, 0.4).toColor();

        return TweenAnimationBuilder<double>(
          // Stable per-artist key so Flutter tracks tiles by IDENTITY, not grid
          // position — freshly inserted similar-artist tiles each get their own
          // element and play the elastic pop-in.
          key: ValueKey(artist.name),
          tween: Tween(begin: artist.isNewlyAdded ? 0.0 : 1.0, end: 1.0),
          // A quick pop (300 ms); a long elastic curve spends most of its time wobbling.
          duration: const Duration(milliseconds: 300),
          curve: Curves.easeOutBack,
          builder: (context, value, child) {
            return Transform.scale(
              scale: value,
              child: Opacity(opacity: value.clamp(0.0, 1.0), child: child),
            );
          },
          child: GestureDetector(
            onTap: () {
              HapticService.medium();
              _onArtistTapped(index);
            },
            child: Column(
              mainAxisAlignment: MainAxisAlignment.start,
              children: [
                AspectRatio(
                  aspectRatio: 1.0,
                  child: AnimatedContainer(
                    duration: const Duration(milliseconds: 300),
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      border: Border.all(
                        color: isSelected ? themeColor : Colors.transparent,
                        width: 2.4,
                      ),
                      boxShadow: isSelected
                          ? [BoxShadow(color: themeColor.withOpacity(0.45), blurRadius: 20, spreadRadius: 1, offset: const Offset(0, 6))]
                          : [BoxShadow(color: Colors.black.withOpacity(0.3), blurRadius: 10, offset: const Offset(0, 4))],
                    ),
                    child: AnimatedScale(
                      scale: isSelected ? 0.9 : 1.0,
                      duration: const Duration(milliseconds: 300),
                      curve: Curves.easeOutBack,
                      child: Stack(
                        fit: StackFit.expand,
                        children: [
                          Container(
                            decoration: BoxDecoration(
                              shape: BoxShape.circle,
                              gradient: LinearGradient(colors: [color1, color2], begin: Alignment.topLeft, end: Alignment.bottomRight),
                            ),
                            child: ClipOval(
                              child: artist.imageUrl.isNotEmpty
                                  ? AuvyImage(path: artist.imageUrl, decodeWidth: 256, fit: BoxFit.cover)
                                  : Center(child: Text(artist.name[0], style: const TextStyle(color: Colors.white, fontSize: 32, fontWeight: FontWeight.w900))),
                            ),
                          ),
                          if (isSelected)
                            Container(
                              decoration: BoxDecoration(
                                shape: BoxShape.circle,
                                color: Colors.black.withOpacity(0.45),
                              ),
                              child: Center(
                                child: Container(
                                  padding: const EdgeInsets.all(6),
                                  decoration: BoxDecoration(shape: BoxShape.circle, color: themeColor),
                                  child: const Icon(Icons.check_rounded, color: Colors.black, size: 22),
                                ),
                              ),
                            ),
                        ],
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: 10),
                Text(
                  artist.name,
                  textAlign: TextAlign.center,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: isSelected ? Colors.white : Colors.white.withOpacity(0.7),
                    fontSize: 12.5,
                    height: 1.2,
                    fontWeight: isSelected ? FontWeight.w800 : FontWeight.w600,
                  ),
                ),
              ],
            ),
          ),
        );
      },
          ),
        ),
      ],
    );
  }
}
