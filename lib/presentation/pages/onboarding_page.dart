import 'package:flutter/material.dart';
import 'package:auvy/presentation/widgets/dynamic_background.dart';
import 'package:auvy/presentation/main_layout.dart';
import 'package:auvy/presentation/widgets/coach_marks.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:auvy/providers/search_provider.dart';
import 'package:auvy/providers/intelligence_provider.dart';
import 'package:auvy/providers/theme_provider.dart';
import 'package:auvy/services/artist_metadata_service.dart';
import 'package:auvy/services/cloud_sync_service.dart';
import 'package:auvy/services/haptic_service.dart';
import 'package:auvy/presentation/widgets/auvy_image.dart';
import 'package:auvy/data/dummy_data.dart';

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

/// Three-step taste profiling (languages → genres → artists) that seeds
/// the recommendation engine. Redesigned to feel like a premium streaming
/// setup flow: quiet dark canvas, a real stepper with back navigation, theme-
/// colored selection, and helpful micro-copy — no background music, no
/// gimmicks, nothing heavier than implicit animations.
///
/// Two entry points, one flow:
///  * FIRST RUN — three steps, then the tutorial. A **Quick start** escape hatch
///    (HYDRV) skips straight in: three screens of taxonomy before a single note
///    plays is a hard ask of someone who just wants to hear a song, and Auvy
///    learns taste from listening anyway. Skipping seeds NOTHING rather than
///    guessing — a fabricated profile is worse than an empty one, because the
///    engine can't tell it from a real one and it never decays.
///  * REDO ([isRedo]) — the same flow reached later from Settings, which pops
///    back instead of running the tutorial again.
class OnboardingPage extends ConsumerStatefulWidget {
  /// Opened from Settings to re-seed taste, not as the first-run gate.
  final bool isRedo;

  const OnboardingPage({super.key, this.isRedo = false});

  @override
  ConsumerState<OnboardingPage> createState() => _OnboardingPageState();
}

class _OnboardingPageState extends ConsumerState<OnboardingPage> {
  int _currentStep = 0; // 0=Language, 1=Genres, 2=Artists
  bool _goingForward = true; // slide direction for the step transition

  // Selections
  final Set<String> _selectedLanguages = {};
  final Set<String> _selectedGenres = {};

  // Multiplexing Artist List
  final List<ArtistItem> _displayedArtists = [];
  // Artist search (find + add any artist, not just the seeded grid).
  final TextEditingController _artistSearchCtrl = TextEditingController();
  bool _artistSearching = false;

  // Options
  final List<String> _languages = [
    'English', 'Spanish', 'Hindi', 'Korean (K-Pop)', 'Japanese',
    'French', 'Portuguese', 'Arabic', 'Mandarin', 'German', 'Italian', 'Russian'
  ];

  final List<String> _genres = [
    'Pop', 'Hip-Hop', 'R&B', 'Electronic', 'Rock', 'Latin', 'Indie',
    'K-Pop', 'Country', 'Afrobeats', 'Metal', 'Jazz', 'Classical',
    'Lo-Fi', 'Reggae', 'House', 'Ambient'
  ];

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

  Future<void> _fetchSeedImages() async {
    final searchService = ref.read(searchServiceProvider);

    for (int i = 0; i < _displayedArtists.length; i++) {
      if (_displayedArtists[i].imageUrl.isEmpty || _displayedArtists[i].imageUrl.contains('lastfm')) {
        try {
          // The OFFICIAL artist picture, not a search thumbnail
          //
          // This used to take `search(name, 'artist').first.image`, i.e. whichever
          // Deezer/Spotify/Last.fm thumbnail the search happened to surface — so
          // the very first screen of the app showed artists with pictures that
          // don't match their artist page two taps later.
          //
          // `getArtistData` with a NAME resolves the YouTube channel first and
          // re-enters through the `UC…` path, which reads YouTube Music's own
          // artist-channel header — the picture on the artist's official page.
          // Same call the artist page itself uses, so they now agree.
          final data = await searchService.getArtistData(
            '',
            fallbackName: _displayedArtists[i].name,
          );
          final resolved = data.image;

          if (resolved.isNotEmpty && mounted) {
            setState(() {
              _displayedArtists[i] = ArtistItem(
                name: _displayedArtists[i].name,
                imageUrl: resolved,
                isSelected: _displayedArtists[i].isSelected,
                hasExpanded: _displayedArtists[i].hasExpanded,
              );
            });
          }
        } catch (_) {}
      }
    }
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

        // Resolve the suggestions' images IN PARALLEL and insert EACH one the
        // moment it resolves. The old sequential await chain meant the first
        // suggestion only appeared after all three searches finished (2-5s);
        // now the first pops in one search round-trip after the tap.
        for (final s in similar) {
          if (existingNames.contains(s.title.toLowerCase())) continue;
          // Same official-channel resolution as the seed grid above — otherwise
          // tapping an artist would inject suggestions whose pictures came from a
          // different source than the tiles already on screen, and the grid would
          // be visibly mixed.
          searchService
              .getArtistData('', fallbackName: s.title)
              .timeout(const Duration(seconds: 4))
              .then((resolved) {
            if (!mounted || resolved.image.isEmpty) return;
            final item = ArtistItem(
              name: resolved.name.isNotEmpty ? resolved.name : s.title,
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

  void _nextStep() {
    HapticService.light();
    if (_currentStep < 2) {
      setState(() {
        _goingForward = true;
        _currentStep++;
      });
    } else {
      _finishOnboarding();
    }
  }

  void _previousStep() {
    if (_currentStep == 0) return;
    HapticService.light();
    setState(() {
      _goingForward = false;
      _currentStep--;
    });
  }

  /// HYDRV's quick start: into the app now, personalise later.
  ///
  /// Deliberately seeds nothing. The alternative — quietly seeding "Pop" and a
  /// handful of chart artists — would look identical from the outside but would
  /// hand the taste engine invented preferences it treats exactly like real
  /// ones. An empty profile is honest and fills itself within a few plays; a
  /// wrong one has to be un-learned. Settings → Intelligence → "Personalise your
  /// taste" runs the full flow whenever the user wants it.
  Future<void> _quickStart() async {
    HapticService.light();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('has_onboarded', true);
    CloudSyncService.instance.scheduleBackup();
    if (!mounted) return;
    // Still routes through the tutorial: skipping the taste questions is a
    // choice about personalisation, not a request to be dropped into an app
    // whose core gestures are undocumented. The tutorial has its own Skip.
    // Arm the interactive walkthrough and hand over to the real app — it points
    // at the actual tabs and mini-player, so it cannot run before they exist.
    CoachTour.armed = true;
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
    final intel = ref.read(intelligenceProvider.notifier);

    // 1. Seed Genres
    // (The old "mood" step was removed: a one-day answer like "Sleep & Unwind"
    // was being seeded into the PERMANENT taste profile.)
    for (var genre in _selectedGenres) {
      final dummyGenre = Song(id: 'onb_genre_$genre', title: '', artist: '', image: '');
      intel.trackInteraction(dummyGenre, percent: 1.0, genreContext: genre);
    }

    // 2. Seed Artists
    final selectedArtists = _displayedArtists.where((a) => a.isSelected).toList();
    for (var artist in selectedArtists) {
      final dummyArtist = Song(id: 'onb_artist_${artist.name}', title: '', artist: artist.name, image: '');
      intel.trackInteraction(dummyArtist, percent: 1.0);
    }

    intel.pruneOnboardingData();

    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('has_onboarded', true);
    // Push the flag (plus the freshly-seeded taste data) to the cloud now, so a
    // future reinstall + same-account login restores "already onboarded" and
    // skips this flow. Safe no-op when cloud sync isn't active.
    CloudSyncService.instance.scheduleBackup();

    if (!mounted) return;
    // Re-running the flow from Settings must not replay the tutorial or replace
    // the Settings stack — it just hands the new seeds over and steps back.
    if (widget.isRedo) {
      Navigator.of(context).pop(true);
      return;
    }
    // Arm the interactive walkthrough and hand over to the real app — it points
    // at the actual tabs and mini-player, so it cannot run before they exist.
    CoachTour.armed = true;
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

  bool get _canProceed {
    switch (_currentStep) {
      case 0: return _selectedLanguages.isNotEmpty;
      case 1: return _selectedGenres.length >= 3;
      case 2: return _displayedArtists.where((a) => a.isSelected).length >= 3;
      default: return false;
    }
  }

  /// Friendly progress hint shown over the CTA while it's still locked.
  String? get _helperText {
    switch (_currentStep) {
      case 0:
        return _selectedLanguages.isEmpty ? 'Pick at least one language' : null;
      case 1:
        final left = 3 - _selectedGenres.length;
        return left > 0 ? 'Pick $left more ${left == 1 ? 'genre' : 'genres'}' : null;
      case 2:
        final left = 3 - _displayedArtists.where((a) => a.isSelected).length;
        return left > 0 ? 'Pick $left more ${left == 1 ? 'artist' : 'artists'}' : null;
      default:
        return null;
    }
  }

  static const List<String> _titles = [
    'What do you\nlisten in?',
    'Pick the genres\nyou love',
    'Now, your\nartists',
  ];

  static const List<String> _subtitles = [
    'Choose every language you enjoy — your feed tunes itself around them.',
    'At least three. The more you pick, the sharper your mixes get.',
    'Select 3 or more. Tapping an artist reveals similar ones you might love.',
  ];

  @override
  Widget build(BuildContext context) {
    final themeColor = ref.watch(themeProvider);
    final canProceed = _canProceed;

    return DynamicBackground(
      child: Scaffold(
        backgroundColor: Colors.transparent,
        body: SafeArea(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Stepper header: back chevron + 3 progress segments
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 10, 24, 0),
                child: Row(
                  children: [
                    AnimatedOpacity(
                      duration: const Duration(milliseconds: 250),
                      opacity: _currentStep > 0 ? 1 : 0,
                      child: IconButton(
                        onPressed: _currentStep > 0 ? _previousStep : null,
                        icon: const Icon(Icons.arrow_back_ios_new_rounded,
                            color: Colors.white, size: 18),
                      ),
                    ),
                    const SizedBox(width: 4),
                    Expanded(
                      child: Row(
                        children: List.generate(3, (i) {
                          final done = i <= _currentStep;
                          return Expanded(
                            child: AnimatedContainer(
                              duration: const Duration(milliseconds: 350),
                              curve: Curves.easeOutCubic,
                              height: 4,
                              margin: const EdgeInsets.symmetric(horizontal: 3),
                              decoration: BoxDecoration(
                                color: done ? themeColor : Colors.white.withOpacity(0.12),
                                borderRadius: BorderRadius.circular(2),
                                boxShadow: done
                                    ? [BoxShadow(color: themeColor.withOpacity(0.4), blurRadius: 8)]
                                    : null,
                              ),
                            ),
                          );
                        }),
                      ),
                    ),
                    const SizedBox(width: 16),
                    Text(
                      '${_currentStep + 1}/3',
                      style: TextStyle(
                          color: Colors.white.withOpacity(0.66),
                          fontSize: 12,
                          fontWeight: FontWeight.w800,
                          letterSpacing: 1),
                    ),
                    // Quick start / Cancel. Present on every step, not just the
                    // first: the flow used to be a wall with no way out at all,
                    // and someone who stalls on "pick 3 artists" is exactly the
                    // person who needs it.
                    const SizedBox(width: 4),
                    TextButton(
                      onPressed: widget.isRedo
                          ? () => Navigator.of(context).pop(false)
                          : _quickStart,
                      style: TextButton.styleFrom(
                        padding: const EdgeInsets.symmetric(horizontal: 8),
                        minimumSize: Size.zero,
                        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                      ),
                      child: Text(
                        widget.isRedo ? 'Cancel' : 'Quick start',
                        style: TextStyle(
                            color: Colors.white.withOpacity(0.72),
                            fontSize: 12.5,
                            fontWeight: FontWeight.w700),
                      ),
                    ),
                  ],
                ),
              ),

              // Title + subtitle
              Padding(
                padding: const EdgeInsets.fromLTRB(24, 26, 24, 18),
                child: AnimatedSwitcher(
                  duration: const Duration(milliseconds: 350),
                  switchInCurve: Curves.easeOutCubic,
                  transitionBuilder: (child, anim) => FadeTransition(
                    opacity: anim,
                    child: SlideTransition(
                      position: Tween<Offset>(
                              begin: Offset(_goingForward ? 0.06 : -0.06, 0),
                              end: Offset.zero)
                          .animate(anim),
                      child: child,
                    ),
                  ),
                  child: Column(
                    key: ValueKey<int>(_currentStep),
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'YOUR TASTE',
                        style: TextStyle(
                            color: themeColor,
                            fontSize: 11,
                            fontWeight: FontWeight.w900,
                            letterSpacing: 3),
                      ),
                      const SizedBox(height: 10),
                      Text(
                        _titles[_currentStep],
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 34,
                          fontWeight: FontWeight.w900,
                          height: 1.08,
                          letterSpacing: -1.0,
                        ),
                      ),
                      const SizedBox(height: 10),
                      Text(
                        _subtitles[_currentStep],
                        style: TextStyle(
                            color: Colors.white.withOpacity(0.72),
                            fontSize: 14,
                            height: 1.4,
                            fontWeight: FontWeight.w500),
                      ),
                    ],
                  ),
                ),
              ),

              // Dynamic body
              Expanded(
                child: AnimatedSwitcher(
                  duration: const Duration(milliseconds: 400),
                  switchInCurve: Curves.easeOutCubic,
                  switchOutCurve: Curves.easeInCubic,
                  child: _buildCurrentStep(themeColor),
                ),
              ),

              // Bottom bar: helper micro-copy + CTA pill
              Container(
                padding: const EdgeInsets.fromLTRB(24, 10, 24, 26),
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
                        opacity: canProceed ? 1.0 : 0.35,
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
                          onPressed: canProceed ? _nextStep : null,
                          child: Row(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              Text(
                                _currentStep == 2 ? 'Build my mix' : 'Continue',
                                style: const TextStyle(
                                    fontSize: 16,
                                    fontWeight: FontWeight.w800,
                                    letterSpacing: 0.2),
                              ),
                              const SizedBox(width: 6),
                              Icon(
                                  _currentStep == 2
                                      ? Icons.auto_awesome_rounded
                                      : Icons.arrow_forward_rounded,
                                  size: 18),
                            ],
                          ),
                        ),
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

  Widget _buildCurrentStep(Color themeColor) {
    switch (_currentStep) {
      case 0: return _buildPillGrid(_languages, _selectedLanguages, themeColor);
      case 1: return _buildPillGrid(_genres, _selectedGenres, themeColor);
      case 2: return _buildArtistMultiplexer(themeColor);
      default: return const SizedBox.shrink();
    }
  }

  Widget _buildPillGrid(List<String> items, Set<String> selection, Color themeColor) {
    return SingleChildScrollView(
      key: ValueKey("step_$_currentStep"),
      padding: const EdgeInsets.fromLTRB(24, 6, 24, 24),
      physics: const BouncingScrollPhysics(),
      child: Wrap(
        spacing: 12,
        runSpacing: 14,
        children: items.map((item) {
          final isSelected = selection.contains(item);
          return GestureDetector(
            onTap: () {
              HapticService.light();
              setState(() {
                isSelected ? selection.remove(item) : selection.add(item);
              });
            },
            child: AnimatedScale(
              scale: isSelected ? 1.04 : 1.0,
              duration: const Duration(milliseconds: 250),
              curve: Curves.easeOutBack,
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 250),
                padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
                decoration: BoxDecoration(
                  color: isSelected ? themeColor : Colors.white.withOpacity(0.05),
                  borderRadius: BorderRadius.circular(28),
                  border: Border.all(
                    color: isSelected ? themeColor : Colors.white.withOpacity(0.1),
                    width: 1.4,
                  ),
                  boxShadow: isSelected
                      ? [BoxShadow(color: themeColor.withOpacity(0.35), blurRadius: 18, offset: const Offset(0, 6))]
                      : const [],
                ),
                // The pill's LAYOUT SIZE must NOT change on selection or the Wrap
                // reflows and neighbouring pills visibly jump/reorder (the annoying
                // shift). So: no check icon appearing on select, and a CONSTANT
                // font weight. The filled theme-colour background + black text +
                // glow already read clearly as "selected". (AnimatedScale is a
                // paint-time transform, so its 1.04 pop never reflows the Wrap.)
                child: Text(
                  item,
                  style: TextStyle(
                    color: isSelected ? Colors.black : Colors.white.withOpacity(0.88),
                    fontWeight: FontWeight.w700,
                    fontSize: 14.5,
                    letterSpacing: 0.2,
                  ),
                ),
              ),
            ),
          );
        }).toList(),
      ),
    );
  }

  /// Search YouTube Music for any artist and prepend the matches to the grid,
  /// so users aren't limited to the seeded set. New tiles pop in at the top.
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
            key: const ValueKey("step_3_artists"),
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
          // Fast, lively pop — the old 600ms elasticOut spent most of its time
          // wobbling, which read as "slow to appear".
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
