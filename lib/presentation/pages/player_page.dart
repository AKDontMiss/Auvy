import 'dart:ui';
import 'dart:async';
import 'package:auvy/core/utils/duration_ext.dart';
import 'package:flutter/material.dart';
import 'package:auvy/services/search_service.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:auvy/presentation/widgets/custom_sliders.dart';
import 'package:auvy/presentation/widgets/hydrv_transitions.dart';
import 'package:auvy/providers/conform_provider.dart';
import 'package:auvy/logic/media_kind.dart';
import 'package:auvy/presentation/pages/audiobooks_page.dart';
import 'package:auvy/providers/search_provider.dart';
import 'package:auvy/presentation/widgets/synced_lyrics_list.dart';
import 'package:auvy/core/app_navigation.dart';
import 'package:auvy/presentation/widgets/queue_sheet.dart';
import 'package:auvy/presentation/widgets/auvy_image.dart';
import 'package:auvy/providers/slider_provider.dart';
import 'package:auvy/providers/player_provider.dart' hide RepeatMode;
import 'package:auvy/providers/player_provider.dart' as pp show RepeatMode;
import 'package:auvy/services/haptic_service.dart';
import 'package:auvy/presentation/widgets/coach_marks.dart';
import 'package:auvy/services/listening_policy.dart';
import 'package:auvy/providers/lyrics_provider.dart';
import 'package:auvy/services/lyrics_translation_service.dart';
import 'package:auvy/services/audio_output_service.dart';
import 'package:auvy/presentation/widgets/audio_output_sheet.dart';
import 'package:auvy/providers/library_provider.dart';
import 'package:auvy/providers/theme_provider.dart'; 
import 'package:auvy/presentation/widgets/squiggly_wavy_slider.dart';
import 'package:auvy/data/dummy_data.dart';
import 'package:auvy/data/artist_model.dart';
import 'package:auvy/presentation/pages/artist_page.dart';
import 'package:auvy/data/lyrics_model.dart';
import 'package:auvy/services/lyrics_service.dart';
import 'package:auvy/presentation/widgets/lyrics_translation_selector.dart';
import 'package:auvy/presentation/widgets/player_menu_sheet.dart'; 
import 'package:auvy/presentation/pages/album_page.dart';
import 'package:auvy/presentation/pages/podcast_page.dart';
import 'package:auvy/presentation/pages/radio_page.dart';
import 'package:auvy/services/podcast_service.dart';
import 'package:auvy/data/podcast_model.dart';
import 'package:auvy/providers/podcast_extras_provider.dart';
import 'package:auvy/presentation/widgets/listen_together_sheet.dart';
import 'package:auvy/providers/listen_together_provider.dart';
import 'package:auvy/providers/connectivity_provider.dart';
import 'package:auvy/providers/density_provider.dart';

/// How far LEFT of the screen's centre the player's top-bar context badge sits.
///
/// The badge is an Expanded between a leading chevron and the trailing icons, so
/// it centres on the space LEFT OVER, not on the screen. With a heavier trailing
/// side that space is offset, and anything meant to line up with the badge has to
/// be offset by the same amount.
///
/// Both tap targets are an 8px-padded icon, so their widths are the icon size
/// plus 16:
///
///   leading  — chevron_down at 30 → 46
///   trailing — output speaker at 24 → 40, plus the overflow menu at 24 → 40
///
/// The badge's centre lands (trailing − leading) / 2 = (80 − 46) / 2 to the left.
/// Spelled out from the parts so that adding or resizing a button makes the sum
/// visibly wrong here rather than quietly misaligning two elements.
const double _kTopBarCentreOffset = ((40 + 40) - 46) / 2;

class PlayerPage extends ConsumerStatefulWidget {
  const PlayerPage({super.key});
  @override
  ConsumerState<PlayerPage> createState() => _PlayerPageState();
}

class _PlayerPageState extends ConsumerState<PlayerPage> with TickerProviderStateMixin {
  /// Drives the artwork ⇄ lyrics face swap. See [HydrvFaceSwap].
  late AnimationController _flipController;
  final ValueNotifier<double> _hOffset = ValueNotifier<double>(0.0);

  /// Which face is showing. The ONLY piece of swap state — the previous
  /// implementation also tracked a current and a target rotation angle, and kept
  /// them out of sync with the controller.
  /// Stable identities for the two faces, so the swap REPARENTS them instead
  /// of rebuilding them. See the AnimatedBuilder that uses them.
  final GlobalKey _artworkFaceKey = GlobalKey();
  final GlobalKey _lyricsFaceKey = GlobalKey();
  bool _showLyrics = false;

  /// Direction the content travelled on the last swap: +1 right, −1 left.
  int _swapDirection = -1;


  late AnimationController _slideRecenterController;
  late Animation<double> _slideAnimation;

  bool _showLeftFeedback = false; 
  bool _showRightFeedback = false; 
  bool _isSpeedingUp = false;      
  bool _isSlowingDown = false;   

  Timer? _feedbackTimer;

  Timer? _loadingCheckTimer;
  Timer? _loadingFailsafeTimer;
  bool _isLoadingNewSong = false;
  

  // Seek scrubbing: while the user drags the progress slider, _seekPreview holds
  // the finger position (0..1) so the slider + time label follow instantly,
  // decoupled from the native clock. The actual (expensive) native seek is fired
  // ONCE, debounced, after the user pauses/releases — issuing it on every drag
  // delta thrashed ExoPlayer, which stuttered the audio and flickered the
  // play/pause button. Null when not scrubbing (live position drives the UI).
  final ValueNotifier<double?> _seekPreview = ValueNotifier<double?>(null);
  Timer? _seekCommitTimer;
  Timer? _seekClearTimer;

  void _onSeekScrub(double percent) {
    final p = percent.clamp(0.0, 1.0);
    _seekPreview.value = p; // instant visual, no setState / full rebuild
    _seekClearTimer?.cancel();
    _seekCommitTimer?.cancel();
    // Commit once the finger settles (approximates release across all slider
    // styles, none of which expose a drag-end callback).
    _seekCommitTimer = Timer(const Duration(milliseconds: 140), () {
      final target = _seekPreview.value;
      if (target == null) return;
      ref.read(playerProvider.notifier).seek(target);
      // Keep showing the preview briefly so the native position can catch up,
      // then hand control back to the live clock without a visible jump.
      _seekClearTimer = Timer(const Duration(milliseconds: 350), () {
        _seekPreview.value = null;
      });
    });
  }

  // True once the open transition has finished. The expensive first paints
  // (full-screen sigma-60 blur rasterization, lyrics fetch) are deferred until
  // then, so the slide-in animates a CHEAP frame — this is the core fix for
  // "opening the player sometimes lags".
  bool _routeSettled = false;

  @override
  void initState() {
    super.initState();
    // Mark the player as open so neither the mini-player nor the media
    // notification can push a second, stacked PlayerPage on top of this one.
    AppNavigation.markPlayerOpened();
    // 240ms, not the old 800ms. Eight hundred milliseconds is longer than the
    // gesture that asks for it, so the card was still moving well after the
    // finger had left the screen.
    _flipController = AnimationController(vsync: this, duration: HydrvMotion.faceDuration);
    _slideRecenterController = AnimationController(vsync: this, duration: const Duration(milliseconds: 300));
    _slideRecenterController.addListener(() {
      _hOffset.value = _slideAnimation.value;
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _watchRouteSettle();
    });
  }

  void _watchRouteSettle() {
    final anim = ModalRoute.of(context)?.animation;
    if (anim == null || anim.isCompleted) {
      if (mounted && !_routeSettled) setState(() => _routeSettled = true);
      return;
    }
    late final AnimationStatusListener listener;
    listener = (status) {
      if (status == AnimationStatus.completed) {
        anim.removeStatusListener(listener);
        if (mounted && !_routeSettled) setState(() => _routeSettled = true);
      }
    };
    anim.addStatusListener(listener);
  }

  /// The artist line under the title. When the track credits multiple artists
  /// (e.g. "A, B, C"), each name is INDIVIDUALLY tappable and routes to that
  /// specific artist — not always the primary. Falls back to a single tappable
  /// string when per-artist data isn't available.
  Widget _buildArtistLine(BuildContext context, Song song) {
    final refs = song.artists.where((a) => a.name.trim().isNotEmpty).toList();
    final style = TextStyle(
        color: Colors.white.withOpacity(0.7), fontSize: 18, fontWeight: FontWeight.w500);

    if (refs.length <= 1) {
      final id = refs.isNotEmpty ? refs.first.id : '';
      return GestureDetector(
        onTap: () => _openArtist(context, song.artist, id),
        child: Hero(
          tag: 'player_artist_${song.id}',
          child: Material(
            color: Colors.transparent,
            child: Text(song.displayArtist, style: style, maxLines: 1, overflow: TextOverflow.ellipsis),
          ),
        ),
      );
    }

    final children = <Widget>[];
    for (var i = 0; i < refs.length; i++) {
      final a = refs[i];
      children.add(GestureDetector(
        onTap: () => _openArtist(context, a.name, a.id),
        child: Text(a.name, style: style),
      ));
      if (i < refs.length - 1) children.add(Text(', ', style: style));
    }
    return Hero(
      tag: 'player_artist_${song.id}',
      child: Material(
        color: Colors.transparent,
        child: Wrap(crossAxisAlignment: WrapCrossAlignment.center, children: children),
      ),
    );
  }

  /// Podcast title tap: open the SHOW PAGE for the episode that is playing, so
  /// the listener can read the notes, see how far into each episode they got, and
  /// pick another one.
  /// Episodes only carry the show's display name (no feed url), so resolve the
  /// show through the same iTunes search the podcast hub uses.
  Future<void> _openPodcastShowPage(BuildContext context, Song episode) async {
    final shows = await PodcastService().searchPodcasts(episode.artist);
    if (!context.mounted || shows.isEmpty) return;
    final show = shows.firstWhere(
      (s) => s.collectionName.toLowerCase() == episode.artist.toLowerCase(),
      orElse: () => shows.first,
    );
    // The player lives on the ROOT navigator, so route onto the active tab and
    // close the player — otherwise the show page would open UNDER it.
    Navigator.pop(context);
    openPodcastShow(context, show, ref.read(themeProvider), fromRootRoute: true);
  }

  /// Navigate to a specific artist. Uses the artist's channel/browse id when
  /// known (resolves directly, no search); otherwise searches by name.
  Future<void> _openArtist(BuildContext context, String name, String id) async {
    HapticService.light();
    // Podcast show / radio station names have no artist page — route to the
    // matching hub instead of searching YT Music for a nonsense "artist".
    final current = ref.read(playerProvider).currentSong;
    final kind = current?.mediaKind;
    // Each browse hub owns its own kind of media, so the title takes you back to
    // the one this came from. An audiobook used to land on Live Radio, because a
    // chapter looked like a stream. See media_kind.dart.
    if (kind == MediaKind.podcast ||
        kind == MediaKind.liveStream ||
        kind == MediaKind.audiobook) {
      Navigator.pop(context);
      AppNavigation.pushOnActiveTab(
        kind == MediaKind.podcast
            ? const PodcastPage()
            : kind == MediaKind.audiobook
                ? const AudiobooksPage()
                : const RadioPage(),
        name: kind == MediaKind.podcast
            ? AppNavigation.podcastTag
            : kind == MediaKind.audiobook
                ? AppNavigation.audiobooksTag
                : AppNavigation.radioTag,
      );
      return;
    }
    if (id.startsWith('UC')) {
      final pseudo = Song(id: id, title: name, artist: name, image: '');
      if (context.mounted) {
        Navigator.pop(context);
        AppNavigation.pushOnActiveTab(ArtistPage(artist: pseudo),
            name: AppNavigation.artistTag(pseudo));
      }
      return;
    }
    // No linked channel id on the track → resolve the SPECIFIC artist behind
    // THIS song (its title + name) so we open the right one when several artists
    // share a name (e.g. two "Xenia"s), instead of trusting the first name hit.
    final svc = ref.read(searchServiceProvider);
    final resolvedId =
        await svc.resolveArtistIdForTrack(current?.title ?? '', name);
    if (resolvedId != null && resolvedId.startsWith('UC') && context.mounted) {
      final pseudo = Song(id: resolvedId, title: name, artist: name, image: '');
      Navigator.pop(context);
      AppNavigation.pushOnActiveTab(ArtistPage(artist: pseudo),
          name: AppNavigation.artistTag(pseudo));
      return;
    }
    final results = await svc.search(name, 'artist');
    // Identity, not ranking. See SearchService.artistNameMatches. The top hit
    // for a name is regularly a tribute act or a bigger artist with a similar
    // name, and opening their page from "View artist" is silently wrong.
    final match = SearchService.pickArtistMatch(results, name, (s) => s.title);
    if (match != null && context.mounted) {
      Navigator.pop(context);
      AppNavigation.pushOnActiveTab(ArtistPage(artist: match),
          name: AppNavigation.artistTag(match));
    }
  }

  @override
  void dispose() {
    AppNavigation.markPlayerClosed();
    _flipController.dispose();
    _slideRecenterController.dispose();
    _hOffset.dispose();
    _loadingCheckTimer?.cancel();
    _loadingFailsafeTimer?.cancel();
    _feedbackTimer?.cancel();
    _feedbackTimer = null;
    _seekCommitTimer?.cancel();
    _seekClearTimer?.cancel();
    _seekPreview.dispose();
    super.dispose();
  }

  void _triggerFeedback(bool isLeft) { 
    setState(() { 
      if (isLeft) { _showLeftFeedback = true; _showRightFeedback = false; } 
      else { _showRightFeedback = true; _showLeftFeedback = false; } 
    }); 
    _feedbackTimer?.cancel(); 
    _feedbackTimer = Timer(const Duration(milliseconds: 600), () { 
      if (mounted) setState(() { _showLeftFeedback = false; _showRightFeedback = false; }); 
    }); 
  }

  /// Swap the artwork face for the lyrics face (or back), carrying the content
  /// in the direction the finger went.
  void _handleFlip(double velocity) {
    // Mid-swap input is DROPPED rather than queued. The old flip re-tweened from
    // an angle it had already advanced to the target, so a second swipe during
    // the first one started from the wrong place and the card jumped.
    if (_flipController.isAnimating) return;
    setState(() {
      _showLyrics = !_showLyrics;
      _swapDirection = velocity < 0 ? -1 : 1;
    });
    _flipController.forward(from: 0.0);
  }

  void _showQueueSheet(BuildContext context) {
    // Owned by this call, not the State: the sheet is transient, and holding a
    // controller past its route would keep a dead extent around. Disposed in
    // whenComplete below, which runs whether the sheet is dismissed by drag,
    // back button or tapping the scrim.
    final sheetController = DraggableScrollableController();
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      // Keeps a fully-expanded sheet clear of the status bar, so maxChildSize
      // 1.0 means "all the usable height" rather than "up under the clock".
      useSafeArea: true,
      builder: (context) {
        // A DRAGGABLE sheet: it opens showing a good chunk of the queue and can
        // be pulled up to cover the page, at which point the list scrolls.
        //
        // THE CONTROLLER IS THE WHOLE TRICK. An earlier attempt wrapped the
        // sheet in a DraggableScrollableSheet but left the list on its OWN
        // ScrollController, so the sheet never received the scroll notifications
        // and dragging did nothing. It was then replaced with a fixed
        // FractionallySizedBox and a note calling the machinery dead — it was not
        // dead, it was unplugged. QueueSheet now drives its list with the
        // controller the sheet hands out, which is what lets a single gesture
        // mean "resize the sheet" while short and "scroll the queue" while full.
        return DraggableScrollableSheet(
          controller: sheetController,
          // Opens FULL from the player page. The queue is what you came here for
          // — the artwork is on the page behind it, not something to preserve a
          // view of, and starting at 0.62 meant a pull-up before the list was
          // usable. Still fully draggable: collapsedSize remains a snap point,
          // so one downward flick gets the old height back.
          initialChildSize: 1.0,
          minChildSize: QueueSheet.minSize,
          maxChildSize: 1.0,
          // The sheet takes only the height it is given rather than filling the
          // modal, so the area above it stays tappable to dismiss.
          expand: false,
          // Settle on a useful height rather than wherever the finger stopped.
          // minChildSize and maxChildSize are implicit snap points, so listing
          // only the middle one avoids duplicating them.
          snap: true,
          snapSizes: const [QueueSheet.collapsedSize],
          builder: (ctx, controller) => QueueSheet(
            scrollController: controller,
            sheetController: sheetController,
          ),
        );
      },
    ).whenComplete(sheetController.dispose);
  }

  void _showPitchTempoSheet(BuildContext context, PlayerNotifier notifier, Color themeColor) {
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (context) => Consumer(
        builder: (context, ref, _) {
          final state = ref.watch(
              playerProvider.select((p) => (pitch: p.pitch, speed: p.speed)));
          return Container(
            padding: const EdgeInsets.fromLTRB(24, 10, 24, 24),
            decoration: BoxDecoration(
              // Translucent panel language: near-black surface + hairline edge.
              color: Colors.black.withOpacity(0.92),
              borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
              border: Border.all(color: Colors.white.withOpacity(0.10), width: 1),
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                // Grab handle
                Container(
                  width: 36,
                  height: 4,
                  margin: const EdgeInsets.only(bottom: 18),
                  decoration: BoxDecoration(
                    color: Colors.white24,
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
                const Text("Pitch & Tempo", style: TextStyle(color: Colors.white, fontSize: 20, fontWeight: FontWeight.bold)),
                const SizedBox(height: 30),
                SliderTheme(
                  data: SliderTheme.of(context).copyWith(
                    activeTrackColor: themeColor,
                    inactiveTrackColor: Colors.white.withOpacity(0.12),
                    thumbColor: Colors.white,
                    trackHeight: 3,
                    overlayColor: themeColor.withOpacity(0.12),
                  ),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Row(
                        children: [
                          const Icon(Icons.music_note, color: Colors.white54),
                          const SizedBox(width: 16),
                          Expanded(
                            child: Slider(
                              value: state.pitch,
                              min: -6.0,
                              max: 6.0,
                              divisions: 12,
                              onChanged: (val) => notifier.setPitch(val),
                            ),
                          ),
                          SizedBox(
                            width: 45,
                            child: Text("${state.pitch > 0 ? '+' : ''}${state.pitch.toInt()} st", style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold), textAlign: TextAlign.right),
                          ),
                        ],
                      ),
                      const SizedBox(height: 16),
                      Row(
                        children: [
                          const Icon(Icons.speed, color: Colors.white54),
                          const SizedBox(width: 16),
                          Expanded(
                            child: Slider(
                              value: state.speed,
                              min: 0.5,
                              max: 2.0,
                              divisions: 15,
                              onChanged: (val) => notifier.setSpeed(val),
                            ),
                          ),
                          SizedBox(
                            width: 45,
                            child: Text("${state.speed.toStringAsFixed(1)}x", style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold), textAlign: TextAlign.right),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 20),
                TextButton.icon(
                  onPressed: () {
                    notifier.setPitch(0.0);
                    notifier.setSpeed(1.0);
                  },
                  style: TextButton.styleFrom(
                    backgroundColor: Colors.white.withOpacity(0.08),
                    padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
                  ),
                  icon: const Icon(Icons.refresh, color: Colors.white54),
                  label: const Text("Reset", style: TextStyle(color: Colors.white54)),
                ),
                const SizedBox(height: 10),
              ],
            ),
          );
        }
      ),
    );
  }

  void _animateAndPop() {
    // The route owns the collapse (HydrvTransition's reverse: fade out, drift up
    // 4%). Nothing to animate here — the hand-rolled vertical drag that used to
    // need coordinating with it is gone.
    if (mounted) Navigator.of(context).pop();
  }

 @override
  Widget build(BuildContext context) {
    // Watch each field individually via select() so the page does NOT rebuild
    // on every 1-second position tick (which mutates PlayerState). Position is
    // read separately through currentPositionProvider, so it's intentionally
    // excluded here — that's what stops the whole page rebuilding every second.
    //
    // Watch ONLY what this build actually reads. `isLoading`, `contextType`,
    // `contextId` and `contextTitle` used to be watched here and never used —
    // the context trio fed the tap-to-navigate handler that the header dropped
    // when it became a purely informational badge (see _navigateToSource), and
    // isLoading is consumed inside narrower widgets. Each dead watch still
    // subscribed this build, so the ENTIRE page — blur, artwork card, gradients
    // — re-rendered whenever that field changed; isLoading alone flips on every
    // single track load. They are deliberately absent, not forgotten.
    final song           = ref.watch(playerProvider.select((p) => p.currentSong));
    // isPlaying IS DELIBERATELY NOT WATCHED HERE. Watching it at page level
    // rebuilt the whole player — artwork card, gradients, glow, the flip
    // AnimatedBuilder, every slider — on every pause and every play. It is now
    // read inside a Consumer around the transport controls, which is the only
    // part that changes. Re-adding it here undoes that.
    final repeatMode     = ref.watch(playerProvider.select((p) => p.repeatMode));
    final duration       = ref.watch(playerProvider.select((p) => p.duration));
    final playbackSource = ref.watch(playerProvider.select((p) => p.playbackSource));
    final locationName   = ref.watch(playerProvider.select((p) => p.locationName));

    ref.listen(playerProvider.select((s) => s.currentSong?.id), (prev, next) {
      if (prev != next && next != null) {
        _slideRecenterController.stop();
        _hOffset.value = 0.0;
        
        if (mounted) {
          setState(() {
            _isLoadingNewSong = true;
            
            // A new track always arrives showing its artwork. Snapped, not
            // animated — the swap animation belongs to the swipe gesture, and
            // playing it here would read as the card flipping on its own.
            _showLyrics = false;
            _flipController.value = 1.0;
          });
          ref.invalidate(lyricsProvider);
          
          _loadingCheckTimer?.cancel();
          _loadingFailsafeTimer?.cancel();
          _loadingCheckTimer = Timer.periodic(const Duration(milliseconds: 300), (timer) {
            if (!mounted) { timer.cancel(); return; }
            final currentPos = currentPositionProvider.value;
            final playerState = ref.read(playerProvider);

            if (currentPos.inMilliseconds > 100 ||
                playerState.isPlaying ||
                (!playerState.isLoading && playerState.currentSong?.id == next)) {
              setState(() { _isLoadingNewSong = false; });
              timer.cancel();
            }
          });

          // Failsafe: clear the loading overlay after 4s no matter what — and
          // stop the 300ms poll so it can't keep firing setState on a track that
          // never reaches "playing". Stored in a field so it's cancelled on the
          // next song change and on dispose (it used to leak on every skip).
          _loadingFailsafeTimer = Timer(const Duration(seconds: 4), () {
            _loadingCheckTimer?.cancel();
            if (mounted && _isLoadingNewSong) {
              setState(() { _isLoadingNewSong = false; });
            }
          });
        }
      }
    });

    // Lyrics kick off a network fetch the moment they're watched — deferred
    // until the open transition has landed so it never competes with the slide.
    final AsyncValue<LyricsData?> lyricsAsync =
        _routeSettled ? ref.watch(lyricsProvider) : const AsyncValue.loading();
    final notifier = ref.read(playerProvider.notifier);
    // NOTE: `liked` is deliberately NOT watched here — it's read inside a narrow
    // Consumer on the heart button itself (see _buildControls). Watching it at
    // this top level re-ran the ENTIRE build (re-rasterising the blurred
    // background, artwork card, etc.) on every like — the visible flicker.
    final screenWidth = MediaQuery.of(context).size.width;
    final themeColor = ref.watch(playerColorProvider);

    if (song == null) return const Scaffold(body: Center(child: CircularProgressIndicator()));

    final String displaySource = playbackSource.toUpperCase();
    // NO ALBUM-TITLE FALLBACK. It used to read `locationName ?? song.albumTitle`,
    // which put the track's ALBUM under "PLAYING FROM HOME" — two lines that
    // contradict each other, and how a bare "23" came to be shown as a place.
    // Empty means the second line is omitted entirely; see the note in playSong.
    final String displayLocation = locationName ?? '';

    return GestureDetector(
      child: RepaintBoundary(
        child: Scaffold(
          backgroundColor: Colors.transparent,
          // The player has no text fields of its own; without this, every
          // keyboard frame from sheets ABOVE it (Listen Together's join code)
          // re-laid-out this entire page beneath the transparent modal — the
          // "bloaty" keyboard feel.
          resizeToAvoidBottomInset: false,
          body: Stack(
            children: [
              // 1. BACKGROUND LAYER (Fades away cleanly)
              //
              // FULL-BLEED blurred cover art, edge to edge (Apple-Music look).
              // Earlier versions read as a blurred SQUARE floating between
              // black bands: the art sat under LOOSE constraints (inside
              // AnimatedSwitcher's internal stack) so it could size to the
              // image's own square aspect, and the blur's soft edge fringe
              // (~3×sigma) faded into the black floor at the top/bottom.
              // Bulletproofed:
              //  • SizedBox.expand forces TIGHT full-screen constraints all
              //    the way down to the image — it can never be a square;
              //  • BoxFit.cover + Transform.scale(1.6) overscan pushes the
              //    fringe far outside the visible area; ClipRect trims it;
              //  • the scrim stays light (30→70% black) so the art reads all
              //    the way down instead of dying into black bands;
              //  • opaque black floor: the route below must never show
              //    through while the page slides / drag-dismisses;
              //  • the blur rasterizes ONCE per song inside the
              //    RepaintBoundary, deferred past the open transition
              //    (_routeSettled) so it never costs animation frames.
              Positioned.fill(
                // No ValueListenableBuilder any more: the drag-dismiss that used
                // to fade this layer as your finger moved is gone, so the
                // background is simply static for the page's lifetime.
                child: Builder(
                  builder: (context) => RepaintBoundary(
                    child: Stack(
                      fit: StackFit.expand,
                      children: [
                        const ColoredBox(color: Colors.black),
                        AnimatedSwitcher(
                          duration: const Duration(milliseconds: 350),
                          child: !_routeSettled
                              ? const SizedBox.expand(key: ValueKey('bg_settling'))
                              : SizedBox.expand(
                                  key: ValueKey(song.image),
                                  child: ClipRect(
                                    // 1.35 overscan / sigma 30: the fringe is
                                    // 3×sigma≈90px, comfortably inside the
                                    // ~190px-per-side overscan, and the raster
                                    // is ~30% smaller than the 1.6/40 combo,
                                    // which made opening the player feel heavy.
                                    child: Transform.scale(
                                      scale: 1.35,
                                      child: ImageFiltered(
                                        imageFilter: ImageFilter.blur(
                                            sigmaX: 30, sigmaY: 30, tileMode: TileMode.clamp),
                                        child: AuvyImage(
                                          path: song.image,
                                          fit: BoxFit.cover,
                                          height: double.infinity,
                                          width: double.infinity,
                                          // The blur wipes out all detail, so a
                                          // small source is visually identical to
                                          // full-res, but decodes + uploads ~10×
                                          // cheaper. This is the texture that gets
                                          // evicted on background/idle and re-
                                          // decoded on the next open (the "laggy
                                          // after a while / on cold start" hitch).
                                          decodeWidth: 360,
                                        ),
                                      ),
                                    ),
                                  ),
                                ),
                        ),
                        const DecoratedBox(
                          decoration: BoxDecoration(
                            gradient: LinearGradient(
                              begin: Alignment.topCenter,
                              end: Alignment.bottomCenter,
                              colors: [
                                Color(0x4D000000), // black 30%
                                Color(0x73000000), // black 45%
                                Color(0xB3000000), // black 70%
                              ],
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),

              // 2. FOREGROUND LAYER
              //
              // Previously translate+scale+fade driven by the drag offset. With the
              // drag gone the route's own transition handles all of that, so this
              // is a plain subtree again — one less transform chain per frame.
              Builder(
                builder: (context) => SafeArea(
                  child: Column(
                    children: [
                      Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                        child: Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [
                            AuvyBounce(
                              onTap: _animateAndPop,
                              child: const Padding(
                                padding: EdgeInsets.all(8.0),
                                child: Icon(Icons.keyboard_arrow_down, color: Colors.white, size: 30),
                              ),
                            ),
                            // Sleek, purely informational context badge. While a
                            // Listen Together session is live it becomes the
                            // session badge (tap → session sheet) so the sync
                            // state is always one glance away.
                            Expanded(
                              child: Builder(builder: (context) {
                                final lt = ref.watch(listenTogetherProvider
                                    .select((s) => s.active
                                        ? (s.role == LtRole.host
                                            ? '${s.members.length} listening'
                                            : 'with ${s.hostName ?? 'Host'}')
                                        : null));
                                if (lt != null) {
                                  return GestureDetector(
                                    behavior: HitTestBehavior.opaque,
                                    onTap: () => showListenTogetherSheet(context),
                                    child: Column(
                                      children: [
                                        Row(
                                          mainAxisAlignment: MainAxisAlignment.center,
                                          children: [
                                            _LiveSessionDot(color: themeColor),
                                            const SizedBox(width: 6),
                                            Text(
                                              "LISTEN TOGETHER",
                                              style: TextStyle(color: themeColor, fontSize: 11, letterSpacing: 1.1, fontWeight: FontWeight.w800),
                                            ),
                                          ],
                                        ),
                                        const SizedBox(height: 4),
                                        Text(
                                          lt,
                                          style: const TextStyle(color: Colors.white, fontSize: 14, fontWeight: FontWeight.w700),
                                          textAlign: TextAlign.center, maxLines: 1, overflow: TextOverflow.ellipsis,
                                        ),
                                      ],
                                    ),
                                  );
                                }
                                return Column(
                                  children: [
                                    Text(
                                      "PLAYING FROM $displaySource",
                                      style: TextStyle(color: Colors.white.withOpacity(0.66), fontSize: 11, letterSpacing: 1.1, fontWeight: FontWeight.w700),
                                    ),
                                    // Both the gap and the line go when there is
                                    // nothing to say, or an empty Text leaves a
                                    // stray 14pt of space under the source.
                                    if (displayLocation.isNotEmpty) ...[
                                      SizedBox(height: (song.mediaKind == MediaKind.liveStream) ? 0 : 4),
                                      Text(
                                        displayLocation,
                                        style: const TextStyle(color: Colors.white, fontSize: 14, fontWeight: FontWeight.w700),
                                        textAlign: TextAlign.center, maxLines: 1, overflow: TextOverflow.ellipsis,
                                      ),
                                    ],
                                  ]
                                );
                              }),
                            ),
                            // OUTPUT: shown for everything, including live radio
                            // and podcasts — "where is this playing" is the same
                            // question whatever the source is. Sits beside the
                            // menu rather than in the transport row below, which
                            // is built on symmetric 44/56/72/56/44 slots that
                            // keep play/pause dead-centre.
                            const _AudioOutputButton(),
                            if (!(song.mediaKind == MediaKind.liveStream))
                              AuvyBounce(
                                onTap: () => showModalBottomSheet(
                                  context: context,
                                  backgroundColor: Colors.transparent,
                                  isScrollControlled: true,
                                  builder: (context) => PlayerMenuSheet(song: song),
                                ),
                                child: const Padding(
                                  padding: EdgeInsets.all(8.0),
                                  child: Icon(Icons.more_vert, color: Colors.white),
                                ),
                              )
                            else
                              const SizedBox(width: 48),
                          ],
                        ),
                      ),
                      
                      // Swipe affordance for the lyrics face. The gesture was
                      // completely undiscoverable — nothing on screen suggested the
                      // artwork could be swiped at all.
                      //
                      // Kept deliberately quiet so it doesn't become a UI element:
                      // 12px chevrons at 22% white, no background, no label, and it
                      // DISAPPEARS once the lyrics are showing (its job is done) and
                      // for live radio (which has no lyrics face to reach).
                      //
                      // Nudged left by exactly as much as the top bar's context
                      // badge is. That badge lives in an Expanded between the
                      // chevron and the trailing icons, so its centre is not the
                      // screen's centre — adding the output button made the
                      // trailing side heavier and pulled it further off. This hint
                      // is centred on the FULL width, so without the same nudge
                      // the two would no longer line up with each other.
                      //
                      // Derived from the icon widths rather than eyeballed, so it
                      // stays correct if a button is added or removed. See
                      // [_kTopBarCentreOffset].
                      if (!(song.mediaKind == MediaKind.liveStream))
                        Padding(
                          padding: const EdgeInsets.only(
                              right: _kTopBarCentreOffset * 2),
                          child: CoachAnchor(
                              id: 'player.lyrics',
                              child: _LyricsSwipeHint(showing: _showLyrics)),
                        ),

                      Expanded(
                        child: GestureDetector(
                          onHorizontalDragEnd: (details) {
                            final isLiveRadio = song.mediaKind == MediaKind.liveStream;
                            if (isLiveRadio) return;

                            final vel = details.primaryVelocity ?? 0;
                            if (vel.abs() > 300) _handleFlip(vel);
                          },
                          child: AnimatedBuilder(
                            animation: _flipController,
                            builder: (context, child) {
                              // THE GlobalKeys ARE LOad-BEARING — they are why
                              // the cover does not blink when you swipe.
                              //
                              // At rest the face is the DIRECT child here; mid-swap
                              // it sits inside HydrvFaceSwap. That is a move, and
                              // without a GlobalKey Flutter cannot reuse the old
                              // element across a move — it builds a fresh one and
                              // disposes the original. A fresh `Image` element has
                              // no retained frame, so `gaplessPlayback` has nothing
                              // to hold and the frameBuilder paints the PLACEHOLDER
                              // for a frame. That one placeholder frame at the
                              // start of the swap is the flicker.
                              //
                              // A GlobalKey makes it a reparent instead: same
                              // element, same State, same decoded image, nothing
                              // to re-resolve.
                              Widget artworkFace() => KeyedSubtree(
                                    key: _artworkFaceKey,
                                    child: _buildArtworkCard(song.image, song),
                                  );
                              Widget lyricsFace() => KeyedSubtree(
                                    key: _lyricsFaceKey,
                                    child: _lyricsFace(lyricsAsync, notifier),
                                  );
                              // AT REST there is exactly ONE face in the tree —
                              // no transform, no opacity layer, and (when showing
                              // artwork) no lyrics subtree built just to be
                              // hidden. The controller stops before its last
                              // notification, so this branch also paints the
                              // settled frame of every swap.
                              if (!_flipController.isAnimating) {
                                return _showLyrics ? lyricsFace() : artworkFace();
                              }
                              return HydrvFaceSwap(
                                animation: _flipController,
                                direction: _swapDirection,
                                incoming:
                                    _showLyrics ? lyricsFace() : artworkFace(),
                                outgoing:
                                    _showLyrics ? artworkFace() : lyricsFace(),
                              );
                            },
                          ),
                        ),
                      ),
                      
                    // Controls: THE ONLY PART THAT REBUILDS ON PAUSE/PLAY
                    //
                    // isPlaying IS READ HERE, NOT AT THE TOP OF build().
                    //
                    // It used to be watched in build() (see the note there), so
                    // every pause and every play rebuilt this ENTIRE page — the
                    // artwork card, the gradients, the glow, the flip
                    // AnimatedBuilder, every slider style — to change a play icon
                    // and let two sliders stop animating. That is a lot of work
                    // inside one frame for a state change the user makes
                    // constantly, and it is the leading suspect for the flicker
                    // reported when pausing and resuming.
                    //
                    // Scoped to a Consumer, the transport state rebuilds the
                    // transport controls and nothing above them.
                    Consumer(builder: (context, ref, _) {
                      final playing =
                          ref.watch(playerProvider.select((p) => p.isPlaying));
                      return _buildControls(context, song, notifier, playing,
                          repeatMode, screenWidth, themeColor, duration);
                    }),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildControls(BuildContext context, Song song, PlayerNotifier notifier, bool isPlaying, pp.RepeatMode repeatMode, double screenWidth, Color themeColor, Duration duration) {
    final bool isLiveRadio = song.mediaKind == MediaKind.liveStream;
    final bool isPodcast = song.mediaKind == MediaKind.podcast;
    // Feed-declared chapters for the playing episode (sponsor segments get
    // shaded on the seek bar + a skip pill). Empty while loading / not found.
    final chapters = isPodcast
        ? (ref.watch(podcastChaptersProvider).valueOrNull ?? const <PodcastChapter>[])
        : const <PodcastChapter>[];
    
    return Container(
      padding: EdgeInsets.only(bottom: isLiveRadio ? 80 : 65, left: 20, right: 20),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // 1. HEADER ROW: Title, Artist, & Like Button 
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    GestureDetector(
                      onTap: () {
                        HapticService.light();
                        final bool isPodcast = song.mediaKind == MediaKind.podcast;
                        final bool isRadio = song.mediaKind == MediaKind.liveStream;
                        if (isPodcast) {
                          // Episode title → the show page (episode list, notes and
                          // listening progress), not a meaningless album page for a
                          // fake "Podcast" album.
                          _openPodcastShowPage(context, song);
                          return;
                        }
                        if (isRadio) {
                          // Station name → back to the stations browser.
                          Navigator.pop(context);
                          AppNavigation.pushOnActiveTab(const RadioPage(),
                              name: AppNavigation.radioTag);
                          return;
                        }
                        Navigator.pop(context); // 1. Close the PlayerPage
                        final album = Album(
                          id: song.albumId.isNotEmpty ? song.albumId : song.id,
                          title: song.albumTitle.isNotEmpty ? song.albumTitle : song.title,
                          image: song.image,
                          releaseDate: song.releaseDate.isNotEmpty ? song.releaseDate : 'Unknown Date',
                          recordType: 'album'
                        );
                        AppNavigation.pushOnActiveTab(
                          AlbumPage(album: album, artistName: song.artist, fallbackTrack: song),
                          name: AppNavigation.albumTag(album),
                        );
                      },
                      child: Hero(
                        tag: 'player_title_${song.id}',
                        child: Material(
                          color: Colors.transparent,
                          child: MarqueeText(
                            text: song.title,
                            style: const TextStyle(color: Colors.white, fontSize: 24, fontWeight: FontWeight.w800, letterSpacing: -0.5),
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(height: 4),
                    _buildArtistLine(context, song),
                  ],
                ),
              ),
              const SizedBox(width: 12),
              
              // Watch `liked` in a NARROW Consumer so tapping the heart rebuilds
              // ONLY this icon — not the whole player page. Reading it at the
              // top-level build re-ran everything (incl. re-rasterising the
              // blurred background) on every like → the visible flicker.
              Consumer(
                builder: (context, ref, _) {
                  final isLiked = ref.watch(libraryProvider
                      .select((s) => s.likedSongIds.contains(song.id)));
                  return AuvyBounce(
                    onTap: () {
                      HapticService.light();
                      ref.read(libraryProvider.notifier).toggleSongLike(song);
                    },
                    child: Padding(
                      padding: const EdgeInsets.all(8.0),
                      child: Icon(
                        isLiked ? Icons.favorite_rounded : Icons.favorite_border_rounded,
                        color: isLiked ? themeColor : Colors.white,
                        size: 32,
                      ),
                    ),
                  );
                },
              ),
            ],
          ),
          
          const SizedBox(height: 8), 
          
          // 2. SLIDER & TIMESTAMPS
          ValueListenableBuilder<Duration>(
            valueListenable: currentPositionProvider, 
            builder: (context, currentPos, _) {
              if (isLiveRadio) {
                // Radio has no timeline to scrub, so the seek bar is replaced by
                // a status bar that tells the truth about where the listener is
                // relative to the broadcast. See [_RadioLiveBar].
                return _RadioLiveBar(
                  isPlaying: isPlaying,
                  onAir: currentPos,
                  themeColor: themeColor,
                  onGoLive: notifier.goLiveRadio,
                );
              }
              
              final liveProgress = (duration.inMilliseconds > 0) ? (currentPos.inMilliseconds / duration.inMilliseconds).clamp(0.0, 1.0) : 0.0;
              final currentSliderStyle = ref.watch(sliderStyleProvider);
              return ValueListenableBuilder<double?>(
                valueListenable: _seekPreview,
                builder: (context, preview, ___) {
                  final progress = preview ?? liveProgress;
                  final shownPos = preview != null
                      ? Duration(milliseconds: (duration.inMilliseconds * preview).round())
                      : currentPos;
                  Widget activeSlider;
              
              switch (currentSliderStyle) {
                // Instantiates your custom fluid seek controls gracefully side-by-side with your existing styles
                case SliderStyle.liquid:
                  activeSlider = AuvyFluidSlider(
                    value: progress,
                    isPlaying: isPlaying,
                    activeColor: themeColor,
                    inactiveColor: Colors.white24,
                    onChanged: _onSeekScrub,
                  );
                  break;
                case SliderStyle.waveform:
                  // Same SoundCloud-style bar waveform as the settings preview.
                  activeSlider = WaveformSlider(progress: progress, themeColor: themeColor, onChanged: _onSeekScrub);
                  break;
                case SliderStyle.material: activeSlider = MaterialThumbSlider(progress: progress, themeColor: themeColor, onChanged: _onSeekScrub); break;
                case SliderStyle.minimal: activeSlider = MinimalSlider(progress: progress, themeColor: themeColor, onChanged: _onSeekScrub); break;
                // These three take isPlaying: their motion is meant to STOP when
                // audio does, so the slider itself reports the transport state.
                case SliderStyle.comet: activeSlider = CometSlider(progress: progress, themeColor: themeColor, isPlaying: isPlaying, onChanged: _onSeekScrub); break;
                case SliderStyle.elastic: activeSlider = ElasticSlider(progress: progress, themeColor: themeColor, onChanged: _onSeekScrub); break;
                case SliderStyle.pulse: activeSlider = PulseSlider(progress: progress, themeColor: themeColor, isPlaying: isPlaying, onChanged: _onSeekScrub); break;
                case SliderStyle.flow: activeSlider = FlowSlider(progress: progress, themeColor: themeColor, isPlaying: isPlaying, onChanged: _onSeekScrub); break;
                case SliderStyle.segmented: activeSlider = SegmentedSlider(progress: progress, themeColor: themeColor, onChanged: _onSeekScrub); break;
                case SliderStyle.timeline: activeSlider = TimelineSlider(progress: progress, themeColor: themeColor, onChanged: _onSeekScrub); break;
              }

              const timeStyle = TextStyle(color: Colors.white70, fontSize: 12, fontWeight: FontWeight.w600, fontFeatures: [FontFeature.tabularFigures()]);

              // Sponsor segments as fractions of the episode, shaded over the
              // seek bar (style-agnostic: painted on top of whichever slider
              // widget is active).
              final adRanges = <List<double>>[];
              final tickFracs = <double>[];
              PodcastChapter? adNow;
              if (isPodcast && duration.inMilliseconds > 0 && chapters.isNotEmpty) {
                for (final c in chapters) {
                  final s = (c.start.inMilliseconds / duration.inMilliseconds).clamp(0.0, 1.0).toDouble();
                  if (s > 0.001 && s < 0.999) tickFracs.add(s);
                  if (!c.isAd) continue;
                  final e = ((c.end ?? duration).inMilliseconds / duration.inMilliseconds).clamp(0.0, 1.0).toDouble();
                  if (e > s) adRanges.add([s, e]);
                  if (currentPos >= c.start && currentPos < (c.end ?? duration)) adNow = c;
                }
              }
              final Duration? adEnd = adNow == null ? null : (adNow.end ?? duration);

              return Column(
                children: [
                  if (adNow != null)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 8),
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          AuvyBounce(
                            onTap: () {
                              HapticService.light();
                              if (adEnd != null) notifier.seek(adEnd);
                            },
                            child: Container(
                              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 7),
                              decoration: BoxDecoration(
                                color: Colors.redAccent.withOpacity(0.14),
                                borderRadius: BorderRadius.circular(30),
                                border: Border.all(color: Colors.redAccent.withOpacity(0.4), width: 1),
                              ),
                              child: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: const [
                                  Icon(Icons.fast_forward_rounded, color: Colors.redAccent, size: 15),
                                  SizedBox(width: 5),
                                  Text('Skip sponsor',
                                      style: TextStyle(
                                          color: Colors.redAccent,
                                          fontSize: 12,
                                          fontWeight: FontWeight.w800,
                                          letterSpacing: 0.4)),
                                ],
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  adRanges.isEmpty && tickFracs.isEmpty
                      ? activeSlider
                      : Stack(
                          alignment: Alignment.center,
                          children: [
                            activeSlider,
                            Positioned.fill(
                              child: IgnorePointer(
                                child: CustomPaint(
                                  painter: _ChapterMarkPainter(adRanges: adRanges, ticks: tickFracs),
                                ),
                              ),
                            ),
                          ],
                        ),
                  const SizedBox(height: 10),
                  AuvyBounce(
                    onLongPressStart: (_) { HapticService.medium(); _showPitchTempoSheet(context, notifier, themeColor); },
                    child: Container(
                      color: Colors.transparent,
                      padding: const EdgeInsets.symmetric(vertical: 4),
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          Text(shownPos.toMmSs(), style: timeStyle),
                          // Say something when no audio is coming out.
                          //
                          // A stalled track used to look identical to a playing
                          // one: the transport said PLAYING, the clock sat still,
                          // and nothing was heard. Measured live at twelve seconds
                          // of that during a network-path flap. Silence with no
                          // explanation reads as a broken app, and the natural
                          // response — skip — restarts the load and makes it worse.
                          //
                          // Only shown once the stall has persisted (see the
                          // onBuffering listener), so ordinary track starts stay
                          // quiet. It sits between the two timestamps, which is
                          // exactly where the eye already is when nothing moves.
                          // The reason matters, so say which one it is.
                          //
                          // One "Reconnecting…" for every stall told the user
                          // nothing they could act on: a dropped connection is
                          // theirs to fix (or to wait out), while a stall on a
                          // perfectly good network is ours and waiting is the
                          // only sensible response. The distinction is free —
                          // the connectivity state is already tracked.
                          if (ref.watch(playerProvider
                              .select((p) => p.isStalled)))
                            Text(
                              ref.watch(connectivityProvider
                                      .select((c) => c.isOffline))
                                  ? 'Offline — waiting for connection'
                                  : 'Reconnecting…',
                              style: timeStyle.copyWith(
                                color: themeColor.withOpacity(0.9),
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                          Text(duration.toMmSs(), style: timeStyle),
                        ],
                      ),
                    ),
                  )
                ]
              );
                },
              );
            }
          ),

          // 3. MAIN MEDIA CONTROLS ROW
          // Symmetric 44/56 | 72 | 56/44 slots keep play/pause dead-center.
          // Shuffle deliberately lives ONLY in the queue sheet header.
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
            // 3b. LOOP (Hidden in Radio Mode; podcasts with chapters show the
            // chapter list here instead — looping an episode is a non-goal).
            SizedBox(
              width: 44,
              child: isLiveRadio
                  ? const SizedBox.shrink()
                  : isPodcast && chapters.isNotEmpty
                      ? AuvyBounce(
                          onTap: () {
                            HapticService.light();
                            _showChaptersSheet(context, chapters, themeColor, notifier);
                          },
                          child: const Icon(Icons.toc_rounded, color: Colors.white70, size: 27),
                        )
                      : AuvyBounce(
                          onTap: () => notifier.cycleRepeatMode(),
                          child: _buildRepeatButton(repeatMode, notifier, themeColor),
                        ),
            ),

            // 3c. PREVIOUS (Hidden in Radio Mode)
            if (!isLiveRadio)
              AuvyBounce(
                key: CoachAnchor.keyFor('player.prev'),
                onTap: () {
                  HapticService.light();
                  if (ref
                      .read(listenTogetherProvider.notifier)
                      .requestSkip(next: false)) {
                    return;
                  }
                  notifier.playPrevious();
                },
                onDoubleTap: () { notifier.seekBackward(); _triggerFeedback(true); },
                onLongPressStart: (_) { notifier.setSpeed(0.5); setState(() => _isSlowingDown = true); HapticService.light(); },
                onLongPressEnd: (_) { notifier.setSpeed(1.0); setState(() => _isSlowingDown = false); },
                child: Container(
                  height: 60, width: 56, alignment: Alignment.center,
                  child: _showLeftFeedback
                      ? const _FeedbackIcon(icon: Icons.replay_5, text: "-5s")
                      : (_isSlowingDown ? const _FeedbackIcon(icon: Icons.slow_motion_video, text: "0.5x") : const Icon(Icons.skip_previous_rounded, color: Colors.white, size: 42)),
                ),
              ),

            // 3d. PLAY / PAUSE
            AuvyBounce(
              onTap: () {
                HapticService.selection();
                if (isLiveRadio && !isPlaying) {
                    notifier.playSong(song, isManual: true, source: "Live Radio");
                } else {
                    // In a session the press becomes a SCHEDULE both devices
                    // execute on the same server tick. See scheduleToggle.
                    if (ref
                        .read(listenTogetherProvider.notifier)
                        .scheduleToggle()) {
                      return;
                    }
                    notifier.togglePlay();
                }
              },
              child: Container(
                height: 72, width: 72,
                decoration: BoxDecoration(
                  color: themeColor, shape: BoxShape.circle,
                  boxShadow: [BoxShadow(color: themeColor.withOpacity(0.3), blurRadius: 20, offset: const Offset(0, 8))],
                ),
                child: Icon(isPlaying ? Icons.pause_rounded : Icons.play_arrow_rounded, color: Colors.black, size: 42),
              ),
            ),

            // 3e. NEXT (Hidden in Radio Mode)
            if (!isLiveRadio)
              AuvyBounce(
                key: CoachAnchor.keyFor('player.next'),
                onTap: () {
                  HapticService.light();
                  if (ref
                      .read(listenTogetherProvider.notifier)
                      .requestSkip(next: true)) {
                    return;
                  }
                  notifier.playNext();
                },
                onDoubleTap: () { notifier.seekForward(); _triggerFeedback(false); },
                onLongPressStart: (_) { notifier.setSpeed(2.0); setState(() => _isSpeedingUp = true); HapticService.light(); },
                onLongPressEnd: (_) { notifier.setSpeed(1.0); setState(() => _isSpeedingUp = false); },
                child: Container(
                  height: 60, width: 56, alignment: Alignment.center,
                  child: _showRightFeedback
                      ? const _FeedbackIcon(icon: Icons.forward_5, text: "+5s")
                      : (_isSpeedingUp ? const _FeedbackIcon(icon: Icons.fast_forward, text: "2x") : const Icon(Icons.skip_next_rounded, color: Colors.white, size: 42)),
                ),
              ),

            // 3f. QUEUE (Hidden in Radio Mode)
            SizedBox(
              width: 44,
              child: isLiveRadio ? const SizedBox.shrink() : AuvyBounce(
                onTap: () { HapticService.light(); _showQueueSheet(context); },
                child: const Icon(Icons.queue_music_rounded, color: Colors.white70, size: 28),
              ),
            ),
          ],
          ),
        ],
      ),
    );
  }

  /// Chapter list for the playing episode — sponsor rows tinted red; tapping
  /// a chapter seeks to it.
  void _showChaptersSheet(BuildContext context, List<PodcastChapter> chapters,
      Color themeColor, PlayerNotifier notifier) {
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      builder: (ctx) => ClipRRect(
        borderRadius: const BorderRadius.vertical(top: Radius.circular(28)),
        child: Container(
          constraints: BoxConstraints(maxHeight: MediaQuery.of(ctx).size.height * 0.7),
          decoration: BoxDecoration(
            color: const Color(0xFF141418).withOpacity(0.98),
            border: Border(
              top: BorderSide(color: Colors.white.withOpacity(0.09), width: 0.5),
            ),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const SizedBox(height: 10),
              Container(
                width: 42, height: 4,
                decoration: BoxDecoration(
                    color: Colors.white24, borderRadius: BorderRadius.circular(2)),
              ),
              const Padding(
                padding: EdgeInsets.fromLTRB(24, 16, 24, 6),
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: Text('Chapters',
                      style: TextStyle(
                          color: Colors.white, fontSize: 19, fontWeight: FontWeight.w800)),
                ),
              ),
              Flexible(
                child: ListView.builder(
                  shrinkWrap: true,
                  padding: const EdgeInsets.only(bottom: 30, top: 4),
                  itemCount: chapters.length,
                  itemBuilder: (_, i) {
                    final c = chapters[i];
                    final accent = c.isAd ? Colors.redAccent : themeColor;
                    return ListTile(
                      dense: true,
                      contentPadding: EdgeInsets.symmetric(
                          horizontal: 24,
                          vertical: densityNow.rowVerticalPadding),
                      leading: Text(c.start.toMmSs(),
                          style: TextStyle(
                              color: accent,
                              fontSize: 12.5,
                              fontWeight: FontWeight.w800,
                              fontFeatures: const [FontFeature.tabularFigures()])),
                      title: Text(c.title,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                              color: c.isAd ? Colors.white54 : Colors.white,
                              fontSize: 14.5,
                              fontWeight: FontWeight.w600)),
                      trailing: c.isAd
                          ? Container(
                              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                              decoration: BoxDecoration(
                                color: Colors.redAccent.withOpacity(0.14),
                                borderRadius: BorderRadius.circular(20),
                              ),
                              child: const Text('SPONSOR',
                                  style: TextStyle(
                                      color: Colors.redAccent,
                                      fontSize: 9.5,
                                      fontWeight: FontWeight.w900,
                                      letterSpacing: 0.8)),
                            )
                          : null,
                      onTap: () {
                        HapticService.light();
                        notifier.seek(c.start);
                        Navigator.pop(ctx);
                      },
                    );
                  },
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildRepeatButton(pp.RepeatMode repeatMode, PlayerNotifier notifier, Color themeColor) {
    IconData iconData = Icons.repeat;
    Color iconColor = Colors.white54;
    
    if (repeatMode == pp.RepeatMode.all) {
      iconColor = themeColor;
    } else if (repeatMode == pp.RepeatMode.one) { 
      iconData = Icons.repeat_one; 
      iconColor = themeColor; 
    }
    
    // Return just the icon, since AuvyBounce handles the tap now!
    return Icon(iconData, color: iconColor, size: 26);
  }

  Widget _buildArtworkCard(String rawImageUrl, Song song) {
    final themeColor = ref.watch(playerColorProvider);
    final bool showLoading = _isLoadingNewSong;
    // A user-set cover wins here too. The player reads the playing song straight
    // from `playerProvider`, so it never passes through `conformedForDisplay` —
    // without this hook a corrected cover would appear in every list and still be
    // wrong on the one screen the user was looking at when they fixed it.
    final String imageUrl = overriddenArtwork(ref, song);
    // Radio mode: the reactive artwork glow broadcasts in red ("on air"),
    // with a floor so the halo breathes even while intensity data is quiet.
    final bool isRadioGlow =
        song.mediaKind == MediaKind.liveStream;
    
    return Padding(
      padding: const EdgeInsets.all(24.0),
      child: Center(
        child: AspectRatio(
          aspectRatio: 1,
          child: ValueListenableBuilder<double>(
            valueListenable: audioIntensityProvider,
            child: Hero(
              tag: 'player_artwork_${song.id}',
              child: ClipRRect(
                borderRadius: BorderRadius.circular(ListeningPolicy.playerArtworkRadius),
                child: ColorFiltered(
                  colorFilter: showLoading
                      ? ColorFilter.mode(Colors.black.withOpacity(0.5), BlendMode.darken)
                      : const ColorFilter.mode(Colors.transparent, BlendMode.multiply),
                  child: AuvyImage(
                    // Key on the URL so switching tracks builds a fresh image
                    // element instead of reusing the old one (prevents the
                    // previous cover art bleeding onto the next track).
                    key: ValueKey(imageUrl),
                    path: imageUrl,
                    // EXPLICIT DECODE SIZE — this is the 194MB fix.
                    //
                    // This widget passes no width/height (an AspectRatio sizes
                    // it), so _decodeDim returned null and the FULL SOURCE was
                    // decoded: a 1200px cover is ~5.8MB of ARGB, held per track
                    // by the image cache. dumpsys meminfo showed 194MB of GPU
                    // textures.
                    //
                    // 720 is the top of _sizeLadder, so it is also the largest
                    // the CDN is ever asked for by any other call site — this
                    // just stops the player being the one exception. On a 1080p
                    // screen the downscale is imperceptible for album art.
                    //
                    // Done here rather than with a LayoutBuilder inside
                    // AuvyImage: that adds an element level and made artwork
                    // flash its placeholder on rebuild. See the note in
                    // auvy_image.dart.
                    decodeWidth: 720,
                    borderRadius: 0,
                    fit: BoxFit.cover,
                  ),
                ),
              ),
            ),
            builder: (context, intensity, cachedArtwork) {
              return Stack(
                alignment: Alignment.center,
                children: [
                  Positioned.fill(
                    child: AnimatedContainer(
                      duration: const Duration(milliseconds: 150),
                      curve: Curves.easeOut,
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(ListeningPolicy.playerArtworkRadius),
                        boxShadow: [
                          BoxShadow(
                            color: Colors.black.withOpacity(0.6),
                            blurRadius: 35, 
                            spreadRadius: 5, 
                            offset: const Offset(0, 15), 
                          ),
                          BoxShadow(
                            color: isRadioGlow
                                ? Colors.redAccent.withOpacity(
                                    (0.22 + intensity * 0.5).clamp(0.0, 0.7))
                                : intensity > 0.01
                                    ? themeColor.withOpacity((intensity * 0.6).clamp(0.0, 1.0))
                                    : Colors.transparent,
                            blurRadius: 40 + (intensity * 40),
                            spreadRadius: 10 + (intensity * 25),
                            offset: Offset.zero,
                          ),
                        ],
                      ),
                      child: cachedArtwork, 
                    ),
                  ),
                  
                  if (showLoading)
                    IgnorePointer(
                      child: Center(
                        child: SizedBox(
                          width: 80,
                          height: 80,
                          child: CircularProgressIndicator(
                            strokeWidth: 4,
                            valueColor: AlwaysStoppedAnimation<Color>(themeColor),
                          ),
                        ),
                      ),
                    ),
                ],
              );
            }
          ),
        ),
      ),
    );
  }
  
  /// The lyrics face, with its own position subscription.
  ///
  /// Kept separate so the position listener lives INSIDE the face: at rest on the
  /// artwork the whole thing — listener included — is out of the tree, and the
  /// per-tick rebuild costs nothing.
  Widget _lyricsFace(AsyncValue<LyricsData?> lyricsAsync, PlayerNotifier notifier) {
    return ValueListenableBuilder<Duration>(
      valueListenable: currentPositionProvider,
      builder: (context, currentPos, _) =>
          _buildLyricsCard(lyricsAsync, currentPos, notifier),
    );
  }

  Widget _buildLyricsCard(AsyncValue<LyricsData?> lyricsAsync, Duration pos, PlayerNotifier n) {
    final song = ref.watch(playerProvider.select((s) => s.currentSong));
    final themeColor = ref.watch(playerColorProvider);
    
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [Colors.black.withOpacity(0.4), Colors.black.withOpacity(0.2)]
        ),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: Colors.white.withOpacity(0.1), width: 1),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.3),
            blurRadius: 20,
            offset: const Offset(0, 10)
          )
        ]
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(20),
        child: lyricsAsync.when(
          data: (l) {
            if (l == null) {
              // Fetch failed — show message + refetch button
              return _buildNoLyricsView(song, themeColor, fetchFailed: true);
            }
            if (l.instrumental) {
              // Confirmed instrumental — no button, clear message
              return _buildNoLyricsView(song, themeColor, fetchFailed: false);
            }
            if (l.lines.isEmpty) {
              // Has metadata but no synced lines — treat as failed
              return _buildNoLyricsView(song, themeColor, fetchFailed: true);
            }
            // Podcast transcripts swap the translation selector for a sync
            // nudge: dynamically-inserted ads shift the delivered audio
            // relative to the feed transcript, and only the listener can hear
            // by how much.
            final bool isPodcastTranscript = song?.mediaKind == MediaKind.podcast;
            return Column(
              children: [
                isPodcastTranscript
                    ? const _TranscriptSyncBar()
                    : const LyricsTranslationSelector(), //  Selector widget added
                Expanded(
                  child: LyricsViewer(
                    lyrics: l,
                    currentPosition: pos,
                    onLineTapped: (t) => n.seek(t)
                  ),
                ),
              ],
            );
          },
          loading: () => Center(
            child: CircularProgressIndicator(color: Colors.white.withOpacity(0.7))
          ),
          error: (e, s) => _buildNoLyricsView(song, themeColor),
        )
      ),
    );
  }

  Widget _buildNoLyricsView(Song? song, Color themeColor, {bool fetchFailed = true}) {
    if (song == null) return const Center(child: CircularProgressIndicator());

    // Hoisted OUT of the builder: declared inside, every setLocalState rebuild
    // re-initialized it to false — the spinner never appeared and the button
    // could be spammed mid-refetch.
    bool isRefetching = false;
    return StatefulBuilder(
      builder: (context, setLocalState) {
        return Center(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(
                fetchFailed ? Icons.lyrics_outlined : Icons.music_note_outlined,
                size: 64, color: Colors.white.withOpacity(0.3)
              ),
              const SizedBox(height: 16),
              Text(
                fetchFailed
                    ? 'Couldn\'t retrieve lyrics'
                    : 'This track is instrumental',
                style: TextStyle(color: Colors.white.withOpacity(0.72), fontSize: 16),
              ),
              if (fetchFailed) ...[
                const SizedBox(height: 24),
                ElevatedButton.icon(
                  onPressed: isRefetching ? null : () async {
                    setLocalState(() => isRefetching = true);
                    await LyricsService().clearCacheForSong(song.id, title: song.title, artist: song.artist);
                    LyricsTranslationService().clearCache();
                    ref.read(lyricsRefreshTriggerProvider.notifier).state++;
                    ref.invalidate(lyricsProvider);
                  },
                  icon: isRefetching
                      ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                      : const Icon(Icons.refresh_rounded),
                  label: Text(isRefetching ? 'Refetching...' : 'Refetch Lyrics'),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Colors.white.withOpacity(0.1),
                    foregroundColor: Colors.white,
                    padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(24),
                      side: BorderSide(color: Colors.white.withOpacity(0.2)),
                    ),
                  ),
                ),
              ],
            ],
          ),
        );
      }
    );
  }
}

class _FeedbackIcon extends StatelessWidget { final IconData icon; final String text; const _FeedbackIcon({required this.icon, required this.text}); @override Widget build(BuildContext context) { return Container(padding: const EdgeInsets.all(8), decoration: BoxDecoration(color: Colors.black.withOpacity(0.6), borderRadius: BorderRadius.circular(50)), child: Column(mainAxisSize: MainAxisSize.min, children: [Icon(icon, color: Colors.white, size: 24), Text(text, style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 10))])); } }
class MarqueeText extends StatefulWidget { final String text; final TextStyle style; const MarqueeText({super.key, required this.text, required this.style}); @override State<MarqueeText> createState() => _MarqueeTextState(); }

class _MarqueeTextState extends State<MarqueeText> with SingleTickerProviderStateMixin {
  late ScrollController _sc;
  late AnimationController _ac;

  @override
  void initState() {
    super.initState();
    _sc = ScrollController();
    _ac = AnimationController(vsync: this, duration: const Duration(seconds: 10))
      ..addListener(() {
        if (_sc.hasClients) _sc.jumpTo(_sc.position.maxScrollExtent * _ac.value);
      });
    _syncAnimation();
  }

  // Animate ONLY when the text actually overflows. The old version ran the
  // ticker unconditionally — a 60fps animation for every title, forever,
  // while the player was open.
  void _syncAnimation() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_sc.hasClients) return;
      final bool overflows = _sc.position.maxScrollExtent > 0;
      if (overflows && !_ac.isAnimating) {
        _ac.repeat(reverse: true);
      } else if (!overflows && _ac.isAnimating) {
        _ac.stop();
        _ac.value = 0;
      }
    });
  }

  @override
  void didUpdateWidget(MarqueeText oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.text != widget.text) {
      _ac.stop();
      _ac.value = 0;
      if (_sc.hasClients) _sc.jumpTo(0);
      _syncAnimation();
    }
  }

  @override
  void dispose() {
    _ac.dispose();
    _sc.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(scrollDirection: Axis.horizontal, controller: _sc, physics: const NeverScrollableScrollPhysics(), child: Text(widget.text, style: widget.style));
  }
}

class LyricsViewer extends ConsumerStatefulWidget {
  final LyricsData lyrics;
  final Duration currentPosition;
  final Function(Duration) onLineTapped;

  const LyricsViewer({
    super.key,
    required this.lyrics,
    required this.currentPosition,
    required this.onLineTapped,
  });

  @override
  ConsumerState<LyricsViewer> createState() => _LyricsViewerState();
}

class _LyricsViewerState extends ConsumerState<LyricsViewer> {

  @override
  void initState() {
    super.initState();
    // Initialize the index based on starting position
    WidgetsBinding.instance.addPostFrameCallback((_) => _updateIndex());
  }

  @override
  void didUpdateWidget(LyricsViewer oldWidget) {
    super.didUpdateWidget(oldWidget);
    // Sync index when position updates from the parent ValueListenableBuilder
    _updateIndex();
  }

  void _updateIndex() {
    // MUST use the same shifted lines the list renders (displayedLyricsProvider
    // applies the 200ms advance + podcast transcript offset). Computing this
    // from the raw widget.lyrics.lines made the highlight ignore the offset —
    // nudges/pins visibly "didn't work" or looked inverted.
    final lines = ref.read(displayedLyricsProvider) ?? widget.lyrics.lines;
    // −1 MEANS "NOTHING SUNG YET", AND THAT IS A HIGHLIGHT STATE, NOT A
    // SCROLL STATE. Must match `liveIndex` in build() — the two used to
    // disagree (0 here, −1 there) and that is how the next bug gets written.
    //
    // The list SCROLLS to line one during an intro (SyncedLyricsList clamps this
    // to 0 for its anchor) but HIGHLIGHTS nothing until the first line is
    // actually sung. Two behaviours, one number: keep them separate by leaving
    // this at −1 and letting the widget do the clamping.
    int newIndex = -1;
    for (int i = 0; i < lines.length; i++) {
      if (widget.currentPosition >= lines[i].startTime) {
        newIndex = i;
      } else {
        break;
      }
    }

    final currentIndex = ref.read(activeLyricIndexProvider);
    if (newIndex != currentIndex) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) {
          ref.read(activeLyricIndexProvider.notifier).state = newIndex;
        }
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final displayedLines = ref.watch(displayedLyricsProvider);
    // Re-run the highlight immediately when the lines shift (offset nudge /
    // long-press pin) instead of waiting for the next 1s position tick.
    ref.listen(displayedLyricsProvider, (_, __) => _updateIndex());
    final linesToDisplay = displayedLines ?? widget.lyrics.lines;
    // Live line computed synchronously (activeLyricIndexProvider can be stale
    // here: this whole subtree is disposed while the card rests on artwork, so
    // on flip-back the provider still holds the pre-flip value and no change
    // event fires if the line number happens to match). Passing the real
    // current line lets the list spawn already synced to it.
    // −1 while the song is still BEFORE its first line. See the matching
    // note in the provider above. The pane sits ON line one during the intro
    // (the widget clamps the anchor to 0) and highlights it only once it is
    // sung.
    int liveIndex = -1;
    for (int i = 0; i < linesToDisplay.length; i++) {
      if (widget.currentPosition >= linesToDisplay[i].startTime) {
        liveIndex = i;
      } else {
        break;
      }
    }
    return SyncedLyricsList(
      linesToDisplay: linesToDisplay,
      activeIndex: liveIndex,
      onLineTapped: (time) => widget.onLineTapped(time),
    );
  }
}

class StardustParticle {
  Offset position, velocity; Color color; double size, life = 1.0; 
  StardustParticle({required this.position, required this.velocity, required this.color, required this.size});
  void update() { position += velocity; velocity += const Offset(0, 0.005); life -= 0.005; size *= 0.99; }
}

class StardustPainter extends CustomPainter {
  final List<StardustParticle> particles;
  StardustPainter(this.particles);
  
  @override
  void paint(Canvas canvas, Size size) {
    for (var p in particles) { 
      final paint = Paint()
        ..color = p.color.withOpacity(p.life.clamp(0.0, 1.0)); 
      
      canvas.drawCircle(p.position, p.size, paint); 
    }
  }
  
  @override
  bool shouldRepaint(covariant StardustPainter oldDelegate) => true;
}

class AuvyBounce extends StatefulWidget {
  final Widget child;
  final VoidCallback? onTap;
  final VoidCallback? onDoubleTap;
  final Function(LongPressStartDetails)? onLongPressStart;
  final Function(LongPressEndDetails)? onLongPressEnd;

  const AuvyBounce({
    super.key, 
    required this.child, 
    this.onTap, 
    this.onDoubleTap,
    this.onLongPressStart,
    this.onLongPressEnd,
  });

  @override
  State<AuvyBounce> createState() => _AuvyBounceState();
}

class _AuvyBounceState extends State<AuvyBounce> with SingleTickerProviderStateMixin {
  late AnimationController _controller;
  late Animation<double> _scaleAnimation;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 75), // Extremely fast instant shrink
      reverseDuration: const Duration(milliseconds: 150), // FASTER, snappier pop back
    );

    _scaleAnimation = Tween<double>(begin: 1.0, end: 0.90).animate( // Less shrink for a tighter, premium feel
      CurvedAnimation(
        parent: _controller,
        curve: Curves.easeOutCubic,
        reverseCurve: Curves.easeOutBack, 
      ),
    );
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _shrink() {
    if (mounted) _controller.forward();
  }

  void _restore() {
    if (mounted) {
      // Guarantee the animation finishes the 'down' state before popping up on a very quick tap
      if (_controller.isAnimating && _controller.status == AnimationStatus.forward) {
        _controller.forward().then((_) {
          if (mounted) _controller.reverse();
        });
      } else {
        _controller.reverse();
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    // Listener catches the RAW touch instantly, ignoring any double-tap delays!
    return Listener(
      onPointerDown: (_) => _shrink(),
      onPointerUp: (_) => _restore(),
      onPointerCancel: (_) => _restore(),
      child: GestureDetector(
        behavior: HitTestBehavior.translucent,
        onTap: widget.onTap,
        onDoubleTap: widget.onDoubleTap,
        onLongPressStart: widget.onLongPressStart,
        onLongPressEnd: widget.onLongPressEnd,
        child: ScaleTransition(
          scale: _scaleAnimation,
          child: widget.child,
        ),
      ),
    );
  }
}

/// Podcast transcript sync controls: tap ±5s (long-press ±30s) until the
/// highlighted line matches what's being said; tap the label to reset.
class _TranscriptSyncBar extends ConsumerWidget {
  const _TranscriptSyncBar();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final offset = ref.watch(podcastLyricsOffsetProvider);
    final secs = offset.inSeconds;
    final label = secs == 0
        ? 'Transcript sync'
        : 'Shifted ${secs > 0 ? '+' : ''}$secs s • tap to reset';

    void nudge(int s) {
      HapticService.light();
      ref.read(podcastLyricsOffsetProvider.notifier).state =
          offset + Duration(seconds: s);
    }

    Widget chip(String text, int tapSecs, int longSecs) => AuvyBounce(
          onTap: () => nudge(tapSecs),
          onLongPressStart: (_) => nudge(longSecs),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 6),
            decoration: BoxDecoration(
              color: Colors.white.withOpacity(0.08),
              borderRadius: BorderRadius.circular(20),
              border: Border.all(color: Colors.white.withOpacity(0.08)),
            ),
            child: Text(text,
                style: const TextStyle(
                    color: Colors.white70,
                    fontSize: 12,
                    fontWeight: FontWeight.w800)),
          ),
        );

    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 10, 14, 2),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          chip('−5s', -5, -30),
          const SizedBox(width: 10),
          AuvyBounce(
            onTap: () {
              HapticService.light();
              ref.read(podcastLyricsOffsetProvider.notifier).state =
                  Duration.zero;
            },
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 6),
              child: Text(label,
                  style: TextStyle(
                      color: Colors.white.withOpacity(0.66),
                      fontSize: 11.5,
                      fontWeight: FontWeight.w600)),
            ),
          ),
          const SizedBox(width: 10),
          chip('+5s', 5, 30),
        ],
      ),
    );
  }
}

/// Radio's replacement for the seek bar.
///
/// Three honest states instead of one permanent "LIVE":
///   • at the live edge, playing → LIVE + how long you've been on air
///   • paused                    → PAUSED + the gap growing in real time
///   • playing, but behind       → BEHIND m:ss + a GO LIVE action
///
/// The old bar said LIVE unconditionally, including while paused, which is the
/// one moment it is definitely false. The gap itself is owned by the player (see
/// radioBehindLiveProvider) so it survives closing this page.
class _RadioLiveBar extends StatefulWidget {
  final bool isPlaying;
  final Duration onAir;
  final Color themeColor;
  final Future<void> Function() onGoLive;

  const _RadioLiveBar({
    required this.isPlaying,
    required this.onAir,
    required this.themeColor,
    required this.onGoLive,
  });

  @override
  State<_RadioLiveBar> createState() => _RadioLiveBarState();
}

class _RadioLiveBarState extends State<_RadioLiveBar> {
  Timer? _tick;

  @override
  void initState() {
    super.initState();
    // While paused the engine stops reporting positions, so nothing else would
    // drive a repaint — the growing gap needs its own second hand.
    _tick = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted && radioPausedAtProvider.value != null) setState(() {});
    });
  }

  @override
  void dispose() {
    _tick?.cancel();
    super.dispose();
  }

  Widget _pill({
    required Widget child,
    required Color color,
    double opacity = 0.12,
    VoidCallback? onTap,
  }) {
    final content = Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
      decoration: BoxDecoration(
        color: color.withOpacity(opacity),
        borderRadius: BorderRadius.circular(30),
        border: Border.all(color: color.withOpacity(0.35), width: 1),
      ),
      child: child,
    );
    if (onTap == null) return content;
    return AuvyBounce(onTap: onTap, child: content);
  }

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<Duration>(
      valueListenable: radioBehindLiveProvider,
      builder: (context, behind, _) {
        final pausedAt = radioPausedAtProvider.value;
        // Paused: the standing gap PLUS however long this pause has run.
        final Duration gap = pausedAt == null
            ? behind
            : behind + DateTime.now().difference(pausedAt);
        final bool atLiveEdge = gap.inSeconds < 1;

        final children = <Widget>[];

        if (pausedAt != null) {
          children.add(_pill(
            color: Colors.white,
            opacity: 0.07,
            child: const Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.pause_rounded, size: 15, color: Colors.white70),
                SizedBox(width: 6),
                Text('PAUSED',
                    style: TextStyle(
                        color: Colors.white70,
                        fontSize: 12.5,
                        fontWeight: FontWeight.w900,
                        letterSpacing: 1.6)),
              ],
            ),
          ));
        } else if (atLiveEdge) {
          children.add(_pill(
            color: Colors.redAccent,
            child: const Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                _LivePulseDot(),
                SizedBox(width: 8),
                Text('LIVE',
                    style: TextStyle(
                        color: Colors.redAccent,
                        fontSize: 13,
                        fontWeight: FontWeight.w900,
                        letterSpacing: 2.0)),
              ],
            ),
          ));
        }

        // The gap, once there is one. Deliberately not rendered at 0:00 — an
        // always-present "behind 00:00" is noise.
        if (!atLiveEdge) {
          children.add(_pill(
            color: widget.themeColor,
            opacity: 0.14,
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.history_rounded, size: 14, color: widget.themeColor),
                const SizedBox(width: 6),
                Text(
                  '${gap.toMmSs()} behind',
                  style: TextStyle(
                      color: widget.themeColor,
                      fontSize: 12.5,
                      fontWeight: FontWeight.w800,
                      fontFeatures: const [FontFeature.tabularFigures()]),
                ),
              ],
            ),
          ));
          children.add(_pill(
            color: Colors.redAccent,
            opacity: 0.16,
            onTap: () => widget.onGoLive(),
            child: const Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.sensors_rounded, size: 15, color: Colors.redAccent),
                SizedBox(width: 5),
                Text('GO LIVE',
                    style: TextStyle(
                        color: Colors.redAccent,
                        fontSize: 12,
                        fontWeight: FontWeight.w900,
                        letterSpacing: 1.2)),
              ],
            ),
          ));
        } else if (pausedAt == null) {
          children.add(_pill(
            color: Colors.white,
            opacity: 0.06,
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.graphic_eq_rounded,
                    size: 14, color: Colors.white.withOpacity(0.55)),
                const SizedBox(width: 6),
                Text('On air ${widget.onAir.toMmSs()}',
                    style: const TextStyle(
                        color: Colors.white70,
                        fontSize: 12.5,
                        fontWeight: FontWeight.w700,
                        fontFeatures: [FontFeature.tabularFigures()])),
              ],
            ),
          ));
        }

        return Padding(
          padding: const EdgeInsets.symmetric(vertical: 12.0),
          child: Wrap(
            alignment: WrapAlignment.center,
            spacing: 10,
            runSpacing: 8,
            children: children,
          ),
        );
      },
    );
  }
}

/// Pulsing red "on air" dot inside the radio LIVE pill.
class _LivePulseDot extends StatefulWidget {
  const _LivePulseDot();
  @override
  State<_LivePulseDot> createState() => _LivePulseDotState();
}

/// Shades sponsor segments (red bands) and marks chapter starts (ticks) over
/// whatever seek-bar style is active. Painted as an IgnorePointer overlay so
/// scrubbing still hits the slider beneath.
class _ChapterMarkPainter extends CustomPainter {
  final List<List<double>> adRanges; // [startFrac, endFrac]
  final List<double> ticks; // chapter-start fractions
  _ChapterMarkPainter({required this.adRanges, required this.ticks});

  @override
  void paint(Canvas canvas, Size size) {
    final cy = size.height / 2;
    final band = Paint()..color = Colors.redAccent.withOpacity(0.85);
    // A MINIMUM WIDTH is what makes these visible at all.
    //
    // Drawn as a pure fraction of the bar, a real sponsor break is invisible: a
    // 2-minute ad inside a 2h20m episode is 1.4% of the width — about 5px, 5px
    // tall, at 45% opacity. The marks WERE being painted correctly; they just
    // could not be seen, which reads as "the feature never got applied".
    //
    // So: floor the width, raise the opacity, and stand the band slightly proud
    // of the track so it reads as a marker rather than a smudge on it.
    const double minW = 7.0;
    for (final r in adRanges) {
      double left = r[0] * size.width;
      double right = r[1] * size.width;
      if (right - left < minW) {
        final mid = (left + right) / 2;
        left = mid - minW / 2;
        right = mid + minW / 2;
      }
      // Keep a widened band inside the track instead of overhanging the ends.
      if (left < 0) {
        right -= left;
        left = 0;
      }
      if (right > size.width) {
        left -= (right - size.width);
        right = size.width;
      }
      canvas.drawRRect(
        RRect.fromRectAndRadius(
          Rect.fromLTRB(left, cy - 4.5, right, cy + 4.5),
          const Radius.circular(3),
        ),
        band,
      );
    }
    final tick = Paint()
      ..color = Colors.white.withOpacity(0.35)
      ..strokeWidth = 2;
    for (final t in ticks) {
      final x = t * size.width;
      canvas.drawLine(Offset(x, cy - 5), Offset(x, cy + 5), tick);
    }
  }

  @override
  bool shouldRepaint(_ChapterMarkPainter old) =>
      old.adRanges != adRanges || old.ticks != ticks;
}

/// Pulsing dot for the Listen Together header badge — same breathing idiom as
/// [_LivePulseDot], but in the session's accent color.
/// The player's output button: shows where audio is going, taps through to the
/// system output picker.
///
/// The icon is READ FROM THE PLATFORM, not inferred from app state — a Bluetooth
/// glyph means media audio is genuinely routed to a Bluetooth device, and an
/// undeterminable route falls back to a neutral speaker rather than a guess.
///
/// Refreshed on app RESUME rather than on a timer. A route only changes when a
/// device is connected, disconnected or switched, and all of those take the user
/// out of the app or send it to the background, so resume catches every case
/// with nothing polling behind a screen no one is looking at.
class _AudioOutputButton extends StatefulWidget {
  const _AudioOutputButton();

  @override
  State<_AudioOutputButton> createState() => _AudioOutputButtonState();
}

class _AudioOutputButtonState extends State<_AudioOutputButton>
    with WidgetsBindingObserver {
  String? _route;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _refresh();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) _refresh();
  }

  Future<void> _refresh() async {
    final r = await AudioOutputService.currentRoute();
    if (!mounted || r == _route) return;
    setState(() => _route = r);
  }

  @override
  Widget build(BuildContext context) {
    return AuvyBounce(
      onTap: () async {
        HapticService.light();
        await showAudioOutputSheet(context);
        // Picking inside the sheet, or in the system dialog it links to, can both
        // change where audio is going, so re-read rather than assume.
        _refresh();
      },
      child: Padding(
        padding: const EdgeInsets.all(8.0),
        child: Icon(AudioOutputService.iconFor(_route),
            color: Colors.white70, size: 24),
      ),
    );
  }
}

class _LiveSessionDot extends StatefulWidget {
  final Color color;
  const _LiveSessionDot({required this.color});

  @override
  State<_LiveSessionDot> createState() => _LiveSessionDotState();
}

class _LiveSessionDotState extends State<_LiveSessionDot>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
      vsync: this, duration: const Duration(milliseconds: 1200))
    ..repeat(reverse: true);

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // FadeTransition inside a RepaintBoundary: the pulse runs entirely on the
    // compositor (layer opacity), repainting NOTHING. The first version
    // animated the boxShadow blur each frame, which invalidated the whole
    // player-page layer at 60fps — the "laggy while session is live" report.
    return RepaintBoundary(
      child: FadeTransition(
        opacity:
            Tween(begin: 0.45, end: 1.0).chain(CurveTween(curve: Curves.easeInOut)).animate(_c),
        child: Container(
          width: 8,
          height: 8,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: widget.color,
            boxShadow: [
              BoxShadow(
                color: widget.color.withOpacity(0.6),
                blurRadius: 8,
                spreadRadius: 1.5,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _LivePulseDotState extends State<_LivePulseDot>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c =
      AnimationController(vsync: this, duration: const Duration(milliseconds: 1200))
        ..repeat(reverse: true);

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _c,
      builder: (context, _) {
        final t = Curves.easeInOut.transform(_c.value);
        return Container(
          width: 9,
          height: 9,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: Colors.redAccent,
            boxShadow: [
              BoxShadow(
                color: Colors.redAccent.withOpacity(0.35 + t * 0.4),
                blurRadius: 4 + t * 8,
                spreadRadius: 0.5 + t * 2.5,
              ),
            ],
          ),
        );
      },
    );
  }
}
/// The quiet "you can swipe this" hint above the artwork.
///
/// The artwork⇄lyrics swipe had NO affordance at all — nothing on the page
/// suggested the card could be swiped, so the feature only existed for people who
/// found it by accident or read the tutorial.
///
/// Quiet, but NOT invisible — the first attempt (11px chevrons at 22% white, 3px
/// of drift) was reported as "basically invisible", which is a failed hint rather
/// than a subtle one. A hint nobody sees teaches nobody the gesture.
///
/// Now legible while still staying out of the way:
///  • 16px chevrons at 55% white, with the word LYRICS between them in small caps
///    — the word is what makes it self-explanatory; arrows alone only say
///    "something is over there", not what;
///  • 7px of travel over 1.9s, so the movement actually reads as sliding;
///  • still no background, border or ripple — it must not look like a BUTTON,
///    because tapping it does nothing (the gesture is a swipe);
///  • it FADES OUT once the lyrics are showing — the hint has done its job, and
///    leaving it up would suggest a further gesture that isn't there.
class _LyricsSwipeHint extends StatefulWidget {
  final bool showing;
  const _LyricsSwipeHint({required this.showing});

  @override
  State<_LyricsSwipeHint> createState() => _LyricsSwipeHintState();
}

class _LyricsSwipeHintState extends State<_LyricsSwipeHint>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c;

  @override
  void initState() {
    super.initState();
    // 1.9s reversing: brisk enough to register as movement (2.6s read as static),
    // slow enough not to nag.
    _c = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1900),
    )..repeat(reverse: true);
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return IgnorePointer(
      child: AnimatedOpacity(
        opacity: widget.showing ? 0.0 : 1.0,
        duration: const Duration(milliseconds: 260),
        child: Padding(
          padding: const EdgeInsets.only(top: 4, bottom: 2),
          child: AnimatedBuilder(
            animation: _c,
            builder: (context, _) {
              final t = Curves.easeInOut.transform(_c.value);
              return Transform.translate(
                offset: Offset(-3.5 + 7.0 * t, 0),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Icon(Icons.chevron_left_rounded,
                        size: 16, color: Colors.white.withOpacity(0.55)),
                    const SizedBox(width: 7),
                    // The WORD is what makes this self-explanatory. Arrows alone
                    // say "something is over there" without saying what, so the
                    // user still has to guess, which is how the gesture stayed
                    // undiscovered in the first place.
                    Text(
                      'LYRICS',
                      style: TextStyle(
                        color: Colors.white.withOpacity(0.72),
                        fontSize: 9.5,
                        letterSpacing: 2.0,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(width: 7),
                    Icon(Icons.chevron_right_rounded,
                        size: 16, color: Colors.white.withOpacity(0.55)),
                  ],
                ),
              );
            },
          ),
        ),
      ),
    );
  }
}
