import 'dart:io' show Platform;

import 'package:flutter/foundation.dart' show kIsWeb;
import 'dart:ui';
import 'dart:async';
import 'package:auvy/core/utils/duration_ext.dart';
import 'package:flutter/material.dart';
import 'package:auvy/providers/podcast_provider.dart' show showForEpisodeSong;
import 'package:flutter/services.dart';
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
import 'package:auvy/services/event_log.dart';
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
import 'package:auvy/data/podcast_model.dart';
import 'package:auvy/providers/podcast_extras_provider.dart';
import 'package:auvy/presentation/widgets/listen_together_sheet.dart';
import 'package:auvy/presentation/widgets/animated_toast.dart';
import 'package:auvy/providers/listen_together_provider.dart';
import 'package:auvy/providers/connectivity_provider.dart';
import 'package:auvy/presentation/widgets/ab_looper_sheet.dart';
import 'package:auvy/providers/density_provider.dart';
import 'package:auvy/services/radio_schedule_service.dart';
import 'package:auvy/providers/radio_provider.dart';

/// How far left of the screen's centre the top bar's context badge sits. The
/// badge is an Expanded between a leading chevron and the trailing icons, so it
/// centres on the leftover space, not the screen, and anything that should line up
/// with it needs the same offset.
///
/// Both tap targets are an 8 px-padded icon, so each is the icon size plus 16:
///
///   leading  — chevron_down at 30 → 46
///   trailing — output speaker at 24 → 40, plus the overflow menu at 24 → 40
///
/// The badge's centre lands (trailing − leading) / 2 = (80 − 46) / 2 to the left.
/// Written out from its parts so adding or resizing a button visibly changes it.
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
  double _horizontalDragDelta = 0;


  late AnimationController _slideRecenterController;
  late Animation<double> _slideAnimation;

  late AnimationController _heartBurstController;
  late Animation<double> _heartScaleAnimation;
  late Animation<double> _heartOpacityAnimation;
  bool _showHeartBurst = false;

  void _triggerHeartBurst() {
    setState(() => _showHeartBurst = true);
    _heartBurstController.forward(from: 0.0).then((_) {
      if (mounted) setState(() => _showHeartBurst = false);
    });
  }

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
    // 240 ms (HydrvMotion.faceDuration), so the card doesn't keep moving long after
    // the finger has left.
    _flipController = AnimationController(vsync: this, duration: HydrvMotion.faceDuration);
    _slideRecenterController = AnimationController(vsync: this, duration: const Duration(milliseconds: 300));
    _slideRecenterController.addListener(() {
      _hOffset.value = _slideAnimation.value;
    });

    _heartBurstController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 650),
    );
    _heartScaleAnimation = TweenSequence<double>([
      TweenSequenceItem(
        tween: Tween<double>(begin: 0.2, end: 1.25)
            .chain(CurveTween(curve: Curves.easeOutBack)),
        weight: 60,
      ),
      TweenSequenceItem(
        tween: Tween<double>(begin: 1.25, end: 1.0)
            .chain(CurveTween(curve: Curves.easeInOut)),
        weight: 40,
      ),
    ]).animate(_heartBurstController);
    _heartOpacityAnimation = TweenSequence<double>([
      TweenSequenceItem(
        tween: Tween<double>(begin: 0.0, end: 1.0)
            .chain(CurveTween(curve: Curves.easeIn)),
        weight: 25,
      ),
      TweenSequenceItem(
        tween: ConstantTween<double>(1.0),
        weight: 45,
      ),
      TweenSequenceItem(
        tween: Tween<double>(begin: 1.0, end: 0.0)
            .chain(CurveTween(curve: Curves.easeOut)),
        weight: 30,
      ),
    ]).animate(_heartBurstController);

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
  /// The show comes from the feed URL the episode carries (no request), or for an
  /// older episode, a small name search (see showForEpisodeSong).
  Future<void> _openPodcastShowPage(BuildContext context, Song episode) async {
    final show = await showForEpisodeSong(episode);
    if (!context.mounted || show == null) return;
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
    // Each browse hub owns its kind of media, so the title returns to the one this
    // came from (see media_kind.dart).
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
    _heartBurstController.dispose();
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

  /// Flips between the artwork and the lyrics face, carrying the content in the
  /// direction of the swipe. [velocity] gives the direction: negative for
  /// right-to-left, positive for left-to-right; a tap control passes the direction it
  /// wants.
  ///
  /// One direction per face: swipe left to reveal the lyrics, swipe right to return
  /// to the artwork. A left-to-right swipe on the artwork face does nothing, because
  /// that's the iOS back gesture (main_layout gives it a left-edge strip) and the two
  /// would otherwise fight.
  void _handleFlip(double velocity) {
    // Input during a swap is dropped rather than queued.
    if (_flipController.isAnimating) return;
    final bool wantsLyrics = velocity < 0;
    // Already on the face this gesture asks for — i.e. it was swiped the wrong
    // way. Ignored rather than toggled, so the stroke stays available to
    // whatever else wants it.
    if (wantsLyrics == _showLyrics) return;
    setState(() {
      _showLyrics = wantsLyrics;
      _swapDirection = wantsLyrics ? -1 : 1;
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
        // A draggable sheet that can be pulled up to cover the page, after which the list
        // scrolls. QueueSheet drives its list with the controller the sheet hands out,
        // which is what lets one gesture resize the sheet while short and scroll the queue
        // while full.
        return DraggableScrollableSheet(
          controller: sheetController,
          // Opens full from the player page, since the queue is what you came for. Still
          // draggable: collapsedSize remains a snap point.
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

  /// Left-edge swipe to close the player, iOS only. The player is pushed on the root
  /// navigator, so MainLayout's edge strip (`_withIosBackGesture`) sits underneath and
  /// never sees the gesture, and this PageRouteBuilder has no Cupertino back gesture
  /// of its own. Calls exactly what the chevron calls. Rightward flick only, in the
  /// 22 px strip, so it doesn't take the artwork's horizontal drag (which opens lyrics
  /// with a leftward swipe; see [_handleFlip]). Android keeps its system back
  /// gesture.
  Widget _withEdgeBackGesture(Widget child) {
    if (kIsWeb || !Platform.isIOS) return child;
    return Stack(
      children: [
        child,
        Positioned(
          left: 0,
          top: 0,
          bottom: 0,
          width: 22,
          child: GestureDetector(
            behavior: HitTestBehavior.translucent,
            onHorizontalDragEnd: (details) {
              if ((details.primaryVelocity ?? 0) > 150) _animateAndPop();
            },
          ),
        ),
      ],
    );
  }

  void _animateAndPop() {
    // The route handles the collapse animation (HydrvTransition in reverse).
    if (mounted) Navigator.of(context).pop();
  }

 @override
  Widget build(BuildContext context) {
    // Watch each field separately via select(), so the page doesn't rebuild on every
    // position update. Position is read through currentPositionProvider instead. Only
    // fields this build actually reads are watched; each extra watch would re-render
    // the whole page (blur, artwork card, gradients) when that field changed.
    final song           = ref.watch(playerProvider.select((p) => p.currentSong));
    // isPlaying is deliberately not watched here: it's read in a Consumer around the
    // transport controls (the only part that changes on play/pause), so the whole page
    // doesn't rebuild.
    final repeatMode     = ref.watch(playerProvider.select((p) => p.repeatMode));
    final duration       = ref.watch(playerProvider.select((p) => p.duration));
    final playbackSource = ref.watch(playerProvider.select((p) => p.playbackSource));
    // locationName is deliberately NOT watched here any more. The header stopped
    // displaying it (see the source line below), and this page was the only
    // reader — so watching it just rebuilt the whole player whenever a
    // collection label changed. The field itself stays on PlayerState for the
    // home mosaic.

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

          // Failsafe: clear the loading overlay after 4 s regardless, and stop the 300 ms
          // poll. Stored in a field so it's cancelled on the next song change and on
          // dispose.
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
    // `liked` is deliberately not watched here; it's read in a narrow Consumer on the
    // heart button (see _buildControls), so a like doesn't re-run the whole build.
    final screenWidth = MediaQuery.of(context).size.width;
    final themeColor = ref.watch(playerColorProvider);

    if (song == null) return const Scaffold(body: Center(child: CircularProgressIndicator()));

    final String displaySource = playbackSource.toUpperCase();

    return GestureDetector(
      child: RepaintBoundary(
        child: _withEdgeBackGesture(Scaffold(
          backgroundColor: Colors.transparent,
          // The player has no text fields of its own; without this, every
          // keyboard frame from sheets ABOVE it (Listen Together's join code)
          // re-laid-out this entire page beneath the transparent modal — the
          // "bloaty" keyboard feel.
          resizeToAvoidBottomInset: false,
          body: Stack(
            children: [
              // 1. Background layer: full-bleed blurred cover art, edge to edge.
              //    • SizedBox.expand forces tight full-screen constraints down to the image, so
              //      it can never be a floating square;
              //    • BoxFit.cover plus Transform.scale(1.6) pushes the blur's soft edge off
              //      screen, and ClipRect trims it;
              //    • a light scrim (30→70% black) keeps the art visible all the way down;
              //    • an opaque black floor, so the route below never shows through while the
              //      page slides or is dragged away;
              //    • the blur is rasterised once per song in a RepaintBoundary, deferred until
              //      the open transition finishes (_routeSettled) so it never costs animation
              //      frames.
              Positioned.fill(
                // No ValueListenableBuilder any more: the drag-dismiss that used
                // to fade this layer as your finger moved is gone, so the
                // background is simply static for the page's lifetime.
                child: Builder(
                  builder: (context) {
                    final isOled = ref.watch(pureBlackProvider) ||
                        ref.watch(playerBackgroundStyleProvider) == 'black';
                    final bgStyle = ref.watch(playerBackgroundStyleProvider);
                    if (isOled) {
                      return const ColoredBox(color: Colors.black);
                    }
                    if (bgStyle == 'radial') {
                      return DecoratedBox(
                        decoration: BoxDecoration(
                          gradient: RadialGradient(
                            center: const Alignment(0.0, -0.35),
                            radius: 1.15,
                            colors: [
                              themeColor.withValues(alpha: 0.25),
                              const Color(0xFF060606),
                              Colors.black,
                            ],
                          ),
                        ),
                      );
                    }
                    if (bgStyle == 'aurora') {
                      final HSLColor hsl = HSLColor.fromColor(themeColor);
                      final Color secondaryColor = hsl
                          .withHue((hsl.hue + 48) % 360)
                          .withLightness((hsl.lightness * 0.85).clamp(0.2, 0.7))
                          .toColor();
                      return DecoratedBox(
                        decoration: BoxDecoration(
                          gradient: LinearGradient(
                            begin: Alignment.topLeft,
                            end: Alignment.bottomRight,
                            colors: [
                              themeColor.withValues(alpha: 0.32),
                              secondaryColor.withValues(alpha: 0.18),
                              const Color(0xFF07090E),
                              Colors.black,
                            ],
                            stops: const [0.0, 0.45, 0.8, 1.0],
                          ),
                        ),
                      );
                    }
                    return RepaintBoundary(
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
                    );
                  },
                ),
              ),

              // 2. FOREGROUND LAYER
              //
              // A plain subtree: the route's own transition handles the movement.
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
                            // "Playing from" badge (informational). During a
                            // Listen Together session it becomes the session
                            // badge (tap → session sheet).
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
                                // The source line only: the collection name under it isn't shown (the track title
                                // and artist sit right below). `locationName` still exists on PlayerState and is
                                // carried through playSong, since the home mosaic uses it.
                                return Text(
                                  "PLAYING FROM $displaySource",
                                  // Centred in the gap between the icons: the surrounding Expanded spans exactly the
                                  // space between the chevron and the output/menu pair.
                                  textAlign: TextAlign.center,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(color: Colors.white.withOpacity(0.66), fontSize: 11, letterSpacing: 1.1, fontWeight: FontWeight.w700),
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
                            ),
                          ],
                        ),
                      ),
                      
                      // Swipe hint for the lyrics face; otherwise nothing suggests the artwork can be
                      // swiped. Deliberately quiet (a small chevron and faint label, no background), and
                      // hidden once lyrics are showing and for live radio (no lyrics face).
                      //
                      // Offset left by the same amount as the top bar's context badge
                      // ([_kTopBarCentreOffset]) so the two line up.
                      Padding(
                        padding: const EdgeInsets.only(
                            right: _kTopBarCentreOffset * 2),
                        child: CoachAnchor(
                            id: 'player.lyrics',
                            child: _LyricsSwipeHint(
                              showing: _showLyrics,
                              isRadio: song.mediaKind == MediaKind.liveStream,
                            )),
                      ),

                      Expanded(
                        child: GestureDetector(
                          // The tour spotlights the swipe surface itself, since an action step only passes
                          // touches through the spotlit rect, and this widget handles the drag.
                          key: CoachAnchor.keyFor('player.artwork'),
                          behavior: HitTestBehavior.translucent,
                          onHorizontalDragStart: (_) {
                            _horizontalDragDelta = 0;
                          },
                          onHorizontalDragUpdate: (details) {
                            _horizontalDragDelta += details.primaryDelta ?? 0;
                          },
                          onHorizontalDragEnd: (details) {
                            final vel = details.primaryVelocity ?? 0;
                            if (vel.abs() > 160) {
                              _handleFlip(vel);
                            } else if (_horizontalDragDelta.abs() > 36) {
                              _handleFlip(_horizontalDragDelta);
                            }
                            _horizontalDragDelta = 0;
                          },
                          child: AnimatedBuilder(
                            animation: _flipController,
                            builder: (context, child) {
                              // The GlobalKeys keep the cover from blinking during a swipe. At rest the face is
                              // the direct child here; mid-swap it sits inside HydrvFaceSwap. Without a
                              // GlobalKey that move creates a fresh Image element with no retained frame, which
                              // paints the placeholder for a frame. With it, the element is reparented and keeps
                              // its decoded image.
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
                      
                    // Controls: the only part that rebuilds on play/pause, since isPlaying is read
                    // here rather than in build().
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
        )),
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
    final controlsColor = ref.watch(resolvedControlsColorProvider);
    final bool isControlsBlack =
        controlsColor.toARGB32() == 0xFF000000 || controlsColor.computeLuminance() < 0.05;
    final Color peripheralControlsColor = isControlsBlack ? Colors.white : controlsColor;
    final bool isControlsLight =
        ThemeData.estimateBrightnessForColor(controlsColor) == Brightness.light;
    final Color playIconColor = isControlsLight ? Colors.black : Colors.white;
    
    return Container(
      // Bottom padding under the transport: a SafeArea already wraps this column, so
      // this is only visual spacing. Radio keeps a little more because its live/schedule
      // strip sits inside this container.
      padding: EdgeInsets.only(bottom: isLiveRadio ? 52 : 44, left: 20, right: 20),
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
                        if (song.mediaKind == MediaKind.audiobook) {
                          // Chapter title → its book's page, not an album page for
                          // the audiobook marker.
                          Navigator.pop(context);
                          openAudiobookOfSong(ref, song);
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
                        color: isLiked ? peripheralControlsColor : peripheralControlsColor.withValues(alpha: 0.65),
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
                // The liquid style (AuvyFluidSlider).
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
                          // Say something when no audio is coming out: a stall otherwise looks like normal
                          // playback with a frozen clock. Only shown once the stall has persisted (see the
                          // onBuffering listener), placed between the timestamps where the eye already is.
                          // It says which kind: a dropped connection (the user's to fix or wait out) or a
                          // stall on a working network (ours; waiting is the right response).
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

          // 3. Main media controls row. Symmetric 44/56 | 72 | 56/44 slots keep play/pause
          // centred. Shuffle lives only in the queue sheet header.
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
            // 3b. Slot 1 (44px): Loop for track / Chapters for podcast / Pin Station for radio
            SizedBox(
              width: 44,
              child: isLiveRadio
                  ? AuvyBounce(
                      onTap: () {
                        HapticService.selection();
                        ref.read(pinnedRadioStationsProvider.notifier).togglePinFromSong(song);
                        final isPinned = ref.read(pinnedRadioStationsProvider.notifier).isSongPinned(song);
                        AnimatedToast.show(
                          context,
                          text: isPinned ? 'Pinned ${song.title}' : 'Unpinned ${song.title}',
                          icon: isPinned ? Icons.push_pin_rounded : Icons.push_pin_outlined,
                          color: themeColor,
                        );
                      },
                      child: Builder(builder: (context) {
                        final isPinned = ref.watch(pinnedRadioStationsProvider.select(
                            (list) => list.any((s) => s.id == song.id || (s.urlResolved.isNotEmpty && s.urlResolved == song.id))));
                        return Icon(
                          isPinned ? Icons.push_pin_rounded : Icons.push_pin_outlined,
                          color: isPinned ? themeColor : peripheralControlsColor.withValues(alpha: 0.75),
                          size: 26,
                        );
                      }),
                    )
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
                          onLongPress: () {
                            HapticService.selection();
                            showABLooperSheet(context, ref, themeColor);
                          },
                          child: _buildRepeatButton(repeatMode, notifier, controlsColor, isControlsBlack: isControlsBlack),
                        ),
            ),

            // 3c. Slot 2 (56px): PREVIOUS for track / Snap to Live for radio (only when behind)
            if (isLiveRadio)
              ValueListenableBuilder<Duration>(
                valueListenable: radioBehindLiveProvider,
                builder: (context, behind, _) {
                  return ValueListenableBuilder<DateTime?>(
                    valueListenable: radioPausedAtProvider,
                    builder: (context, pausedAt, _) {
                      final isBehind = behind.inSeconds >= 2 || pausedAt != null;
                      if (!isBehind) {
                        return const SizedBox(width: 56, height: 60);
                      }
                      return AuvyBounce(
                        onTap: () async {
                          HapticService.selection();
                          await notifier.goLiveRadio();
                          if (context.mounted) {
                            AnimatedToast.show(
                              context,
                              text: 'Snapped to live broadcast',
                              icon: Icons.sensors_rounded,
                              color: themeColor,
                            );
                          }
                        },
                        child: Container(
                          height: 60,
                          width: 56,
                          alignment: Alignment.center,
                          child: const Icon(Icons.fast_forward_rounded, color: Colors.redAccent, size: 30),
                        ),
                      );
                    },
                  );
                },
              )
            else
              Consumer(
                builder: (context, ref, _) {
                  final seekSec = ref.watch(playerProvider.select((s) => s.seekJumpSeconds));
                  return AuvyBounce(
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
                          ? _FeedbackIcon(icon: Icons.replay_rounded, text: "-${seekSec}s")
                          : (_isSlowingDown ? const _FeedbackIcon(icon: Icons.slow_motion_video, text: "0.5x") : Icon(Icons.skip_previous_rounded, color: peripheralControlsColor, size: 42)),
                    ),
                  );
                },
              ),

            // 3d. Slot 3 (72px): PLAY / PAUSE
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
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 200),
                width: 72, 
                height: 72,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: controlsColor,
                  border: isControlsBlack
                      ? Border.all(color: Colors.white.withValues(alpha: 0.28), width: 1.5)
                      : null,
                  boxShadow: [
                    BoxShadow(
                      color: isControlsBlack
                          ? Colors.white.withValues(alpha: isPlaying ? 0.16 : 0.08)
                          : controlsColor.withValues(alpha: isPlaying ? 0.38 : 0.22),
                      blurRadius: isPlaying ? 18 : 12,
                      spreadRadius: isPlaying ? 2 : 1,
                    )
                  ]
                ),
                child: Icon(
                  isPlaying ? Icons.pause_rounded : Icons.play_arrow_rounded,
                  color: playIconColor,
                  size: 44,
                ),
              ),
            ),

            // 3e. Slot 4 (56px): NEXT for track / Schedule Toggle for radio
            if (isLiveRadio)
              AuvyBounce(
                onTap: () {
                  HapticService.selection();
                  _handleFlip(_showLyrics ? 1.0 : -1.0);
                },
                child: Container(
                  height: 60,
                  width: 56,
                  alignment: Alignment.center,
                  child: Icon(
                    _showLyrics ? Icons.album_rounded : Icons.schedule_rounded,
                    color: _showLyrics ? themeColor : peripheralControlsColor.withValues(alpha: 0.9),
                    size: 28,
                  ),
                ),
              )
            else
              Consumer(
                builder: (context, ref, _) {
                  final seekSec = ref.watch(playerProvider.select((s) => s.seekJumpSeconds));
                  return AuvyBounce(
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
                          ? _FeedbackIcon(icon: Icons.forward_rounded, text: "+${seekSec}s")
                          : (_isSpeedingUp ? const _FeedbackIcon(icon: Icons.fast_forward, text: "2x") : Icon(Icons.skip_next_rounded, color: peripheralControlsColor, size: 42)),
                    ),
                  );
                },
              ),

            // 3f. Slot 5 (44px): QUEUE for track / Stream Info for radio
            SizedBox(
              width: 44,
              child: isLiveRadio
                  ? AuvyBounce(
                      onTap: () {
                        HapticService.selection();
                        final schedule = RadioScheduleService.getScheduleForStation(song);
                        final liveProgram = schedule.firstWhere((p) => p.isLiveNow, orElse: () => schedule.first);
                        _showRadioTechnicalSheet(context, song, liveProgram, themeColor);
                      },
                      child: Icon(Icons.tune_rounded, color: peripheralControlsColor.withValues(alpha: 0.85), size: 26),
                    )
                  : AuvyBounce(
                      onTap: () { HapticService.light(); _showQueueSheet(context); },
                      child: Icon(Icons.queue_music_rounded, color: peripheralControlsColor.withValues(alpha: 0.85), size: 28),
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

  Widget _buildRepeatButton(pp.RepeatMode repeatMode, PlayerNotifier notifier, Color controlsColor, {bool isControlsBlack = false}) {
    final bool isLoopActive = ref.watch(playerProvider.select((s) => s.isLoopActive));
    final bool isActive = isLoopActive || repeatMode != pp.RepeatMode.off;
    final bool isRepeatOne = repeatMode == pp.RepeatMode.one;
    final IconData iconData = isLoopActive
        ? Icons.repeat_on_rounded
        : (isRepeatOne ? Icons.repeat_one_rounded : Icons.repeat_rounded);

    final Color effectiveColor = isControlsBlack ? Colors.white : controlsColor;

    // Ultra-clean, subtle translucent wash so artwork is never clouded
    final Color activeBg = isLoopActive
        ? effectiveColor.withValues(alpha: 0.18)
        : effectiveColor.withValues(alpha: 0.10);
    final Color activeBorder = isLoopActive
        ? effectiveColor.withValues(alpha: 0.45)
        : effectiveColor.withValues(alpha: 0.25);
    final Color iconColor = isActive ? effectiveColor : effectiveColor.withValues(alpha: 0.38);
    final bool isEffectiveLight = ThemeData.estimateBrightnessForColor(effectiveColor) == Brightness.light;

    final String semanticLabel;
    if (isLoopActive) {
      semanticLabel = 'A-B loop active. Long press to configure';
    } else {
      switch (repeatMode) {
        case pp.RepeatMode.off:
          semanticLabel = 'Repeat off. Tap to repeat all. Long press for A-B looper';
        case pp.RepeatMode.all:
          semanticLabel = 'Repeat all. Tap to repeat one. Long press for A-B looper';
        case pp.RepeatMode.one:
          semanticLabel = 'Repeat one. Tap to turn repeat off. Long press for A-B looper';
      }
    }

    return Semantics(
      label: semanticLabel,
      button: true,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        curve: Curves.easeOutCubic,
        width: 38,
        height: 38,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: isActive ? activeBg : Colors.transparent,
          borderRadius: BorderRadius.circular(10),
          border: isActive ? Border.all(color: activeBorder, width: 1.0) : null,
        ),
        child: Stack(
          alignment: Alignment.center,
          children: [
            Icon(
              iconData,
              color: iconColor,
              size: 26,
              shadows: isActive
                  ? const [
                      Shadow(
                        color: Colors.black45,
                        blurRadius: 3,
                        offset: Offset(0, 1),
                      ),
                    ]
                  : null,
            ),
            if (isLoopActive)
              Positioned(
                bottom: 1,
                right: 1,
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 2.5, vertical: 0.5),
                  decoration: BoxDecoration(
                    color: effectiveColor,
                    borderRadius: BorderRadius.circular(3),
                  ),
                  child: Text(
                    'AB',
                    style: TextStyle(
                      color: isEffectiveLight ? Colors.black : Colors.white,
                      fontSize: 7.5,
                      fontWeight: FontWeight.w900,
                      height: 1.0,
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
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
    final glowMode = ref.watch(artworkGlowModeProvider);
    final isLiked = ref.watch(
        libraryProvider.select((s) => s.likedSongIds.contains(song.id)));
    
    return Padding(
      // Asymmetric on purpose, so the cover sits a little above centre. The artwork and
      // the lyrics/schedule card share one Expanded; moving padding from the top to the
      // bottom shifts the square up (16 px here) without changing its size. The card's
      // own spacing comes from its margins (see _buildLyricsCard).
      padding: const EdgeInsets.fromLTRB(24, 8, 24, 40),
      child: Center(
        child: AspectRatio(
          aspectRatio: 1,
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onDoubleTap: () {
              HapticService.medium();
              ref.read(libraryProvider.notifier).toggleSongLike(song);
              _triggerHeartBurst();
            },
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
                      // Keyed on the URL, so a new track builds a fresh image element and the previous
                      // cover can't bleed onto the next track.
                      key: ValueKey(imageUrl),
                      path: imageUrl,
                      // An explicit decode width: with no width/height (an AspectRatio sizes this),
                      // the full source image would be decoded and cached per track (a 1200 px cover is
                      // about 5.8 MB of pixels). ≥ 600 also opts this cover into the sharp CDN variant
                      // (see AuvyImage). Done here rather than with a LayoutBuilder inside AuvyImage (see
                      // the note there).
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
                              color: Colors.black.withValues(alpha: 0.6),
                              blurRadius: 35, 
                              spreadRadius: 5, 
                              offset: const Offset(0, 15), 
                            ),
                            if (glowMode != 'off')
                              BoxShadow(
                                color: isRadioGlow
                                    ? Colors.redAccent.withValues(
                                        alpha: (0.22 + intensity * 0.5).clamp(0.0, 0.7))
                                    : glowMode == 'subtle'
                                        ? themeColor.withValues(alpha: 0.22)
                                        : glowMode == 'vibrant'
                                            ? themeColor.withValues(
                                                alpha: (0.35 + intensity * 0.45).clamp(0.0, 0.85))
                                            : intensity > 0.01
                                                ? themeColor.withValues(
                                                    alpha: (intensity * 0.6).clamp(0.0, 1.0))
                                                : Colors.transparent,
                                blurRadius: glowMode == 'subtle'
                                    ? 28.0
                                    : glowMode == 'vibrant'
                                        ? 45.0 + (intensity * 45)
                                        : 40.0 + (intensity * 40),
                                spreadRadius: glowMode == 'subtle'
                                    ? 6.0
                                    : glowMode == 'vibrant'
                                        ? 14.0 + (intensity * 25)
                                        : 10.0 + (intensity * 25),
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

                    if (_showHeartBurst)
                      IgnorePointer(
                        child: AnimatedBuilder(
                          animation: _heartBurstController,
                          builder: (context, _) {
                            return Opacity(
                              opacity: _heartOpacityAnimation.value,
                              child: Transform.scale(
                                scale: _heartScaleAnimation.value,
                                child: Container(
                                  padding: const EdgeInsets.all(18),
                                  decoration: BoxDecoration(
                                    shape: BoxShape.circle,
                                    color: Colors.black.withValues(alpha: 0.50),
                                    boxShadow: [
                                      BoxShadow(
                                        color: (isLiked ? themeColor : Colors.white)
                                            .withValues(alpha: 0.5),
                                        blurRadius: 32,
                                        spreadRadius: 10,
                                      ),
                                    ],
                                  ),
                                  child: Icon(
                                    isLiked
                                        ? Icons.favorite_rounded
                                        : Icons.favorite_border_rounded,
                                    color: isLiked
                                        ? (themeColor.computeLuminance() < 0.2
                                            ? Colors.pinkAccent
                                            : themeColor)
                                        : Colors.white,
                                    size: 72,
                                  ),
                                ),
                              ),
                            );
                          },
                        ),
                      ),
                  ],
                );
              }
            ),
          ),
        ),
      ),
    );
  }
  
  /// How far the lyrics / schedule card sits above where the slot would centre it.
  /// Applied as a paint-time translation of the lyrics face only: the card and cover
  /// share one Expanded, so layout changes would move both or resize the card. A
  /// translation moves the card without resizing it and costs no relayout.
  static const double _kCardLift = 22.0;

  Widget _lyricsFace(AsyncValue<LyricsData?> lyricsAsync, PlayerNotifier notifier) {
    final song = ref.watch(playerProvider.select((s) => s.currentSong));
    if (song != null && song.mediaKind == MediaKind.liveStream) {
      final themeColor = ref.watch(playerColorProvider);
      return Transform.translate(
        offset: const Offset(0, -_kCardLift),
        child: _RadioScheduleCard(song: song, themeColor: themeColor),
      );
    }

    // Wrapped OUTSIDE the ValueListenableBuilder so the transform is built once
    // rather than rebuilt twice a second with the position.
    return Transform.translate(
      offset: const Offset(0, -_kCardLift),
      child: ValueListenableBuilder<Duration>(
        valueListenable: currentPositionProvider,
        builder: (context, currentPos, _) =>
            _buildLyricsCard(lyricsAsync, currentPos, notifier),
      ),
    );
  }

  Widget _buildLyricsCard(AsyncValue<LyricsData?> lyricsAsync, Duration pos, PlayerNotifier n) {
    final song = ref.watch(playerProvider.select((s) => s.currentSong));
    final themeColor = ref.watch(playerColorProvider);
    
    return Container(
      // Wider and taller margins than the cover's, since a lyrics card reads better with
      // more room (about one more line and fewer wraps). The radio schedule card uses the
      // same numbers. Moving the card up is done by [_kCardLift], not these margins
      // (shifting margins would change its height).
      margin: const EdgeInsets.symmetric(horizontal: 14, vertical: 4),
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
            // Podcast transcripts replace the translation selector with a sync nudge:
            // dynamically inserted ads shift the audio relative to the feed transcript, and
            // only the listener can hear by how much.
            final bool isPodcastTranscript = song?.mediaKind == MediaKind.podcast;
            return Column(
              children: [
                // Music gets the sync control too, because a song's LRC can be timed to a
                // different release of the recording. The offset is stored per track id and
                // restored on the next play (see loadLyricOffsetForSong). The stepper sits at the
                // end of the language row rather than in its own row; a podcast has no language
                // row, so it keeps the full bar with coarser ±5 s/±30 s steps.
                isPodcastTranscript
                    ? const _LyricSyncBar(transcript: true)
                    : const LyricsTranslationSelector(
                        trailing: _LyricSyncBar(compact: true),
                      ), //  Selector widget added
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
                    // Keep the rotation memory: this button's whole purpose is
                    // to land on a DIFFERENT source, and clearing what the last
                    // attempt picked is what made seven taps return the same
                    // answer. See clearCacheForSong.
                    await LyricsService().clearCacheForSong(song.id,
                        title: song.title,
                        artist: song.artist,
                        keepSourceRotation: true);
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
      },
    );
  }
}

class _RadioScheduleCard extends ConsumerStatefulWidget {
  final Song song;
  final Color themeColor;

  const _RadioScheduleCard({
    required this.song,
    required this.themeColor,
  });

  @override
  ConsumerState<_RadioScheduleCard> createState() => _RadioScheduleCardState();
}

class _RadioScheduleCardState extends ConsumerState<_RadioScheduleCard> {
  Timer? _tickerTimer;
  bool _isRefreshing = false;

  @override
  void initState() {
    super.initState();
    // Read live stream metadata from cache or lightweight check (never touches playing socket)
    _fetchMetadata(force: false);
    RadioScheduleService.liveIcyUpdateNotifier.addListener(_onLiveIcyUpdate);
    // 30-second smooth ticker to advance elapsed/remaining countdowns in real-time
    _tickerTimer = Timer.periodic(const Duration(seconds: 30), (_) {
      if (mounted) setState(() {});
    });
  }

  void _onLiveIcyUpdate() {
    if (mounted) setState(() {});
  }

  @override
  void didUpdateWidget(covariant _RadioScheduleCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.song.id != widget.song.id) {
      _fetchMetadata(force: false);
    }
  }

  @override
  void dispose() {
    RadioScheduleService.liveIcyUpdateNotifier.removeListener(_onLiveIcyUpdate);
    _tickerTimer?.cancel();
    super.dispose();
  }

  Future<void> _fetchMetadata({bool force = false}) async {
    RadioScheduleService.refreshLiveMetadata(
      widget.song,
      () {
        if (mounted) setState(() {});
      },
      force: force,
      isCurrentlyPlaying: true,
    );
  }

  Future<void> _handleManualRefresh() async {
    if (_isRefreshing) return;
    HapticService.selection();
    setState(() => _isRefreshing = true);
    await RadioScheduleService.refreshLiveMetadata(
      widget.song,
      () {
        if (mounted) setState(() {});
      },
      force: true,
      isCurrentlyPlaying: true,
    );
    if (mounted) {
      setState(() => _isRefreshing = false);
    }
  }

  void _openStreamInspector(RadioProgram liveProgram) {
    HapticService.selection();
    _showRadioTechnicalSheet(context, widget.song, liveProgram, widget.themeColor);
  }

  @override
  Widget build(BuildContext context) {
    final schedule = RadioScheduleService.getScheduleForStation(widget.song);
    final liveProgram =
        schedule.firstWhere((p) => p.isLiveNow, orElse: () => schedule.first);
    final upcoming = schedule.where((p) => p != liveProgram).toList();
    final themeColor = widget.themeColor;

    return Container(
      // Same numbers as the lyrics card, and lifted by the same constant — see
      // the notes there. Two views of one slot that must not disagree.
      margin: const EdgeInsets.symmetric(horizontal: 14, vertical: 4),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            Colors.black.withValues(alpha: 0.6),
            Colors.black.withValues(alpha: 0.38),
          ],
        ),
        borderRadius: BorderRadius.circular(22),
        border: Border.all(
          color: themeColor.withValues(alpha: 0.3),
          width: 1.2,
        ),
        boxShadow: [
          BoxShadow(
            color: themeColor.withValues(alpha: 0.12),
            blurRadius: 24,
            offset: const Offset(0, 8),
          ),
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.4),
            blurRadius: 18,
            offset: const Offset(0, 10),
          ),
        ],
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(22),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // Header with live station indicator, inspector and refresh
            Container(
              padding: const EdgeInsets.fromLTRB(16, 12, 12, 10),
              decoration: BoxDecoration(
                border: Border(
                  bottom: BorderSide(
                    color: Colors.white.withValues(alpha: 0.08),
                    width: 1,
                  ),
                ),
              ),
              child: Row(
                children: [
                  Container(
                    width: 8,
                    height: 8,
                    decoration: BoxDecoration(
                      color: Colors.redAccent,
                      shape: BoxShape.circle,
                      boxShadow: [
                        BoxShadow(
                          color: Colors.redAccent.withValues(alpha: 0.8),
                          blurRadius: 6,
                          spreadRadius: 1,
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 8),
                  Text(
                    // "On air" rather than "broadcast schedule" when there's no official schedule:
                    // non-official stations get a single live entry from the station record and ICY
                    // metadata (see RadioScheduleService).
                    liveProgram.isOfficialSchedule
                        ? 'BROADCAST SCHEDULE'
                        : 'ON AIR',
                    style: TextStyle(
                      color: Colors.white.withValues(alpha: 0.9),
                      fontSize: 11,
                      fontWeight: FontWeight.w700,
                      letterSpacing: 1.4,
                    ),
                  ),
                  if (liveProgram.isOfficialSchedule) ...[
                    const SizedBox(width: 8),
                    Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 6, vertical: 2),
                      decoration: BoxDecoration(
                        color: themeColor.withValues(alpha: 0.18),
                        borderRadius: BorderRadius.circular(5),
                        border: Border.all(
                          color: themeColor.withValues(alpha: 0.45),
                          width: 0.8,
                        ),
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(Icons.verified_rounded, size: 10, color: themeColor),
                          const SizedBox(width: 3),
                          Text(
                            'OFFICIAL',
                            style: TextStyle(
                              color: themeColor,
                              fontSize: 9,
                              fontWeight: FontWeight.w800,
                              letterSpacing: 0.6,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                  const Spacer(),
                  // Technical inspector button
                  GestureDetector(
                    onTap: () => _openStreamInspector(liveProgram),
                    behavior: HitTestBehavior.opaque,
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
                      margin: const EdgeInsets.only(right: 6),
                      decoration: BoxDecoration(
                        color: Colors.white.withValues(alpha: 0.08),
                        borderRadius: BorderRadius.circular(7),
                        border: Border.all(
                          color: Colors.white.withValues(alpha: 0.12),
                          width: 0.8,
                        ),
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(Icons.tune_rounded, size: 12, color: themeColor),
                          const SizedBox(width: 4),
                          Text(
                            'INFO',
                            style: TextStyle(
                              color: themeColor,
                              fontSize: 9.5,
                              fontWeight: FontWeight.w800,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                  // Force refresh button
                  Semantics(
                    label: 'Refresh lyrics',
                    button: true,
                    child: GestureDetector(
                      onTap: _handleManualRefresh,
                      behavior: HitTestBehavior.opaque,
                      child: Container(
                        padding: const EdgeInsets.all(4),
                        decoration: BoxDecoration(
                          color: Colors.white.withValues(alpha: 0.08),
                          borderRadius: BorderRadius.circular(7),
                        ),
                        child: _isRefreshing
                            ? SizedBox(
                                width: 14,
                                height: 14,
                                child: CircularProgressIndicator(
                                  strokeWidth: 1.8,
                                  color: themeColor,
                                ),
                              )
                            : Icon(
                                Icons.refresh_rounded,
                                size: 15,
                                color: Colors.white.withValues(alpha: 0.75),
                              ),
                      ),
                    ),
                  ),
                ],
              ),
            ),

            // Content: Live on-air card & upcoming guide
            Expanded(
              child: ListView(
                physics: const BouncingScrollPhysics(),
                padding: const EdgeInsets.fromLTRB(16, 14, 16, 16),
                children: [
                  // Live Now Banner Card
                  Container(
                    padding: const EdgeInsets.all(14),
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        colors: [
                          themeColor.withValues(alpha: 0.24),
                          themeColor.withValues(alpha: 0.08),
                        ],
                        begin: Alignment.topLeft,
                        end: Alignment.bottomRight,
                      ),
                      borderRadius: BorderRadius.circular(16),
                      border: Border.all(
                        color: themeColor.withValues(alpha: 0.4),
                        width: 1,
                      ),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Container(
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 7, vertical: 2.5),
                              decoration: BoxDecoration(
                                color: Colors.redAccent.withValues(alpha: 0.85),
                                borderRadius: BorderRadius.circular(6),
                              ),
                              child: const Text(
                                'ON AIR NOW',
                                style: TextStyle(
                                  color: Colors.white,
                                  fontSize: 9,
                                  fontWeight: FontWeight.w900,
                                  letterSpacing: 1.2,
                                ),
                              ),
                            ),
                            if (liveProgram.streamBitrate != null) ...[
                              const SizedBox(width: 8),
                              Container(
                                padding: const EdgeInsets.symmetric(
                                    horizontal: 6, vertical: 2),
                                decoration: BoxDecoration(
                                  color: Colors.white.withValues(alpha: 0.12),
                                  borderRadius: BorderRadius.circular(5),
                                ),
                                child: Text(
                                  liveProgram.streamBitrate!,
                                  style: const TextStyle(
                                    color: Colors.white,
                                    fontSize: 9.5,
                                    fontWeight: FontWeight.w700,
                                  ),
                                ),
                              ),
                            ],
                            const Spacer(),
                            Icon(Icons.access_time_rounded,
                                size: 13,
                                color: Colors.white.withValues(alpha: 0.6)),
                            const SizedBox(width: 4),
                            Text(
                              liveProgram.timeRange,
                              style: TextStyle(
                                color: Colors.white.withValues(alpha: 0.85),
                                fontSize: 11,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                          ],
                        ),
                        if (liveProgram.liveStreamTitle != null &&
                            liveProgram.liveStreamTitle!.isNotEmpty) ...[
                          const SizedBox(height: 8),
                          Container(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 10, vertical: 6),
                            decoration: BoxDecoration(
                              color: Colors.black.withValues(alpha: 0.35),
                              borderRadius: BorderRadius.circular(8),
                              border: Border.all(
                                color: themeColor.withValues(alpha: 0.35),
                                width: 0.8,
                              ),
                            ),
                            child: Row(
                              children: [
                                Icon(Icons.graphic_eq_rounded,
                                    size: 13, color: themeColor),
                                const SizedBox(width: 6),
                                Expanded(
                                  child: Text(
                                    'PLAYING: ${liveProgram.liveStreamTitle!}',
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: TextStyle(
                                      color: Colors.white.withValues(alpha: 0.95),
                                      fontSize: 11,
                                      fontWeight: FontWeight.w700,
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ],
                        const SizedBox(height: 8),
                        Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            if (liveProgram.imageUrl != null &&
                                liveProgram.imageUrl!.isNotEmpty) ...[
                              ClipRRect(
                                borderRadius: BorderRadius.circular(8),
                                child: Image.network(
                                  liveProgram.imageUrl!,
                                  width: 48,
                                  height: 48,
                                  fit: BoxFit.cover,
                                  errorBuilder: (ctx, err, stack) =>
                                      const SizedBox.shrink(),
                                ),
                              ),
                              const SizedBox(width: 10),
                            ],
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    liveProgram.title,
                                    style: const TextStyle(
                                      color: Colors.white,
                                      fontSize: 16,
                                      fontWeight: FontWeight.w800,
                                      letterSpacing: -0.2,
                                    ),
                                  ),
                                  if (liveProgram.host.isNotEmpty) ...[
                                    const SizedBox(height: 3),
                                    Text(
                                      'Hosted by ${liveProgram.host}',
                                      style: TextStyle(
                                        color: themeColor.withValues(alpha: 0.95),
                                        fontSize: 12,
                                        fontWeight: FontWeight.w600,
                                      ),
                                    ),
                                  ],
                                ],
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 6),
                        Text(
                          liveProgram.description,
                          style: TextStyle(
                            color: Colors.white.withValues(alpha: 0.7),
                            fontSize: 11.5,
                            height: 1.35,
                          ),
                        ),
                        const SizedBox(height: 10),
                        // Live progress indicator
                        ClipRRect(
                          borderRadius: BorderRadius.circular(3),
                          child: LinearProgressIndicator(
                            value: liveProgram.progress.clamp(0.0, 1.0),
                            backgroundColor:
                                Colors.white.withValues(alpha: 0.12),
                            valueColor:
                                AlwaysStoppedAnimation<Color>(themeColor),
                            minHeight: 4,
                          ),
                        ),
                        const SizedBox(height: 5),
                        Row(
                          children: [
                            Text(
                              '${liveProgram.elapsedMinutes}m elapsed',
                              style: TextStyle(
                                color: Colors.white.withValues(alpha: 0.6),
                                fontSize: 10.5,
                                fontWeight: FontWeight.w500,
                              ),
                            ),
                            const Spacer(),
                            Text(
                              '${liveProgram.remainingMinutes}m remaining',
                              style: TextStyle(
                                color: themeColor,
                                fontSize: 10.5,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 16),
                  // Upcoming header
                  Row(
                    children: [
                      Icon(Icons.schedule_rounded,
                          size: 14, color: Colors.white.withValues(alpha: 0.55)),
                      const SizedBox(width: 6),
                      Text(
                        'UPCOMING BROADCASTS',
                        style: TextStyle(
                          color: Colors.white.withValues(alpha: 0.55),
                          fontSize: 10,
                          fontWeight: FontWeight.w700,
                          letterSpacing: 1.3,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 10),
                  // Upcoming items
                  ...upcoming.map((prog) {
                    return Padding(
                      padding: const EdgeInsets.only(bottom: 10),
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 13, vertical: 10),
                        decoration: BoxDecoration(
                          color: Colors.white.withValues(alpha: 0.04),
                          borderRadius: BorderRadius.circular(12),
                          border: Border.all(
                            color: Colors.white.withValues(alpha: 0.06),
                            width: 0.8,
                          ),
                        ),
                        child: Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Container(
                                  padding: const EdgeInsets.symmetric(
                                      horizontal: 6, vertical: 3),
                                  decoration: BoxDecoration(
                                    color: Colors.white.withValues(alpha: 0.07),
                                    borderRadius: BorderRadius.circular(6),
                                  ),
                                  child: Text(
                                    prog.timeRange,
                                    style: TextStyle(
                                      color: Colors.white.withValues(alpha: 0.8),
                                      fontSize: 10,
                                      fontWeight: FontWeight.w700,
                                    ),
                                  ),
                                ),
                                const SizedBox(height: 4),
                                Text(
                                  '${prog.durationMinutes} min',
                                  style: TextStyle(
                                    color: Colors.white.withValues(alpha: 0.6),
                                    fontSize: 9.5,
                                    fontWeight: FontWeight.w500,
                                  ),
                                ),
                              ],
                            ),
                            if (prog.imageUrl != null &&
                                prog.imageUrl!.isNotEmpty) ...[
                              const SizedBox(width: 8),
                              ClipRRect(
                                borderRadius: BorderRadius.circular(6),
                                child: Image.network(
                                  prog.imageUrl!,
                                  width: 36,
                                  height: 36,
                                  fit: BoxFit.cover,
                                  errorBuilder: (ctx, err, stack) =>
                                      const SizedBox.shrink(),
                                ),
                              ),
                            ],
                            const SizedBox(width: 10),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    prog.title,
                                    style: const TextStyle(
                                      color: Colors.white,
                                      fontSize: 13,
                                      fontWeight: FontWeight.w700,
                                    ),
                                  ),
                                  if (prog.host.isNotEmpty) ...[
                                    const SizedBox(height: 2),
                                    Text(
                                      prog.host,
                                      style: TextStyle(
                                        color: Colors.white.withValues(alpha: 0.5),
                                        fontSize: 11,
                                        fontWeight: FontWeight.w500,
                                      ),
                                    ),
                                  ],
                                  const SizedBox(height: 3),
                                  Text(
                                    prog.description,
                                    maxLines: 2,
                                    overflow: TextOverflow.ellipsis,
                                    style: TextStyle(
                                      color: Colors.white.withValues(alpha: 0.6),
                                      fontSize: 10.5,
                                      height: 1.3,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ],
                        ),
                      ),
                    );
                  }),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

void _showRadioTechnicalSheet(
  BuildContext context,
  Song song,
  RadioProgram liveProgram,
  Color themeColor,
) {
  showModalBottomSheet(
    context: context,
    backgroundColor: Colors.transparent,
    isScrollControlled: true,
    builder: (ctx) {
      return Container(
        padding: const EdgeInsets.fromLTRB(20, 12, 20, 28),
        decoration: BoxDecoration(
          color: const Color(0xFF141416),
          borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
          border: Border.all(
            color: Colors.white.withValues(alpha: 0.1),
            width: 1,
          ),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.7),
              blurRadius: 32,
              offset: const Offset(0, -8),
            ),
          ],
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Center(
              child: Container(
                width: 38,
                height: 4,
                decoration: BoxDecoration(
                  color: Colors.white.withValues(alpha: 0.25),
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
            const SizedBox(height: 16),
            Row(
              children: [
                Icon(Icons.cell_tower_rounded, color: themeColor, size: 22),
                const SizedBox(width: 10),
                const Text(
                  'Broadcast Stream Details',
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 16,
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 16),

            // Station info card
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: Colors.white.withValues(alpha: 0.05),
                borderRadius: BorderRadius.circular(14),
                border: Border.all(color: Colors.white.withValues(alpha: 0.08)),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    song.title,
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 14,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    song.artist,
                    style: TextStyle(
                      color: Colors.white.withValues(alpha: 0.6),
                      fontSize: 12,
                    ),
                  ),
                  if (liveProgram.liveStreamTitle != null &&
                      liveProgram.liveStreamTitle!.isNotEmpty) ...[
                    const SizedBox(height: 8),
                    Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 8, vertical: 4),
                      decoration: BoxDecoration(
                        color: themeColor.withValues(alpha: 0.15),
                        borderRadius: BorderRadius.circular(6),
                      ),
                      child: Text(
                        'Live ICY: ${liveProgram.liveStreamTitle!}',
                        style: TextStyle(
                          color: themeColor,
                          fontSize: 11,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                  ],
                ],
              ),
            ),
            const SizedBox(height: 14),

            // Stream stats
            Row(
              children: [
                Expanded(
                  child: _StreamStatChip(
                    label: 'BITRATE',
                    value: liveProgram.streamBitrate ?? '128 kbps',
                    icon: Icons.speed_rounded,
                    accent: themeColor,
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: _StreamStatChip(
                    label: 'FORMAT',
                    value: 'MP3 / AAC Stream',
                    icon: Icons.audio_file_rounded,
                    accent: themeColor,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 14),

            // Stream URL with Copy Link
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              decoration: BoxDecoration(
                color: Colors.black.withValues(alpha: 0.4),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: Colors.white.withValues(alpha: 0.07)),
              ),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      song.id,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: Colors.white.withValues(alpha: 0.7),
                        fontSize: 11,
                        fontFamily: 'monospace',
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  GestureDetector(
                    onTap: () {
                      HapticService.selection();
                      Clipboard.setData(ClipboardData(text: song.id));
                      AnimatedToast.message('Stream URL copied to clipboard');
                    },
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 10, vertical: 6),
                      decoration: BoxDecoration(
                        color: themeColor.withValues(alpha: 0.2),
                        borderRadius: BorderRadius.circular(8),
                        border: Border.all(
                          color: themeColor.withValues(alpha: 0.4),
                        ),
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(Icons.copy_rounded, size: 12, color: themeColor),
                          const SizedBox(width: 4),
                          Text(
                            'Copy',
                            style: TextStyle(
                              color: themeColor,
                              fontSize: 11,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      );
    },
  );
}

class _StreamStatChip extends StatelessWidget {
  final String label;
  final String value;
  final IconData icon;
  final Color accent;

  const _StreamStatChip({
    required this.label,
    required this.value,
    required this.icon,
    required this.accent,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.05),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.white.withValues(alpha: 0.08)),
      ),
      child: Row(
        children: [
          Icon(icon, size: 16, color: accent),
          const SizedBox(width: 8),
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                label,
                style: TextStyle(
                  color: Colors.white.withValues(alpha: 0.45),
                  fontSize: 9,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 0.8,
                ),
              ),
              const SizedBox(height: 1),
              Text(
                value,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 11.5,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _FeedbackIcon extends StatelessWidget { final IconData icon; final String text; const _FeedbackIcon({required this.icon, required this.text}); @override Widget build(BuildContext context) { return Container(padding: const EdgeInsets.all(8), decoration: BoxDecoration(color: Colors.black.withOpacity(0.6), borderRadius: BorderRadius.circular(50)), child: Column(mainAxisSize: MainAxisSize.min, children: [Icon(icon, color: Colors.white, size: 24), Text(text, style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 10))])); } }
/// The player-page title, sliding sideways when it's too long to fit.
///
///   * **Paint, don't lay out.** The text is measured once per build with a
///     TextPainter and slid with a `Transform.translate` inside a RepaintBoundary,
///     so sliding is a paint-time offset with no layout. (Driving it with a
///     ScrollController dirtied layout every frame.)
///   * **Stop when the music stops.** Only animates while playing and when the
///     title actually overflows, so a paused player renders nothing.
class MarqueeText extends ConsumerStatefulWidget {
  final String text;
  final TextStyle style;
  const MarqueeText({super.key, required this.text, required this.style});
  @override
  ConsumerState<MarqueeText> createState() => _MarqueeTextState();
}

class _MarqueeTextState extends ConsumerState<MarqueeText>
    with SingleTickerProviderStateMixin {
  /// Created in initState, not lazily: a lazy `late final` controller for a title that
  /// fits would first be created in dispose(), when the element is already defunct.
  /// An idle controller costs nothing; [_sync] decides whether it runs.
  late final AnimationController _ac;

  @override
  void initState() {
    super.initState();
    _ac = AnimationController(vsync: this, duration: const Duration(seconds: 10));
  }

  /// How far the text exceeds its box, in logical pixels. 0 means it fits.
  double _overflow = 0;

  /// Last playing state acted on, so [_sync] is not re-run on every rebuild.
  bool _playing = false;

  /// Start or stop the slide.
  ///
  /// Deliberately idempotent and safe to call from anywhere: it compares
  /// against `_ac.isAnimating` rather than tracking state of its own, which is
  /// what stops a rebuild storm from stacking up tickers.
  void _sync() {
    final bool shouldRun = _playing && _overflow > 0.5;
    if (shouldRun && !_ac.isAnimating) {
      _ac.repeat(reverse: true);
    } else if (!shouldRun && _ac.isAnimating) {
      // Parks where it is rather than snapping home: a title that jumped back
      // to the start on pause would read as a glitch, and the position it
      // stopped at is the one the listener was reading.
      _ac.stop();
    }
  }

  @override
  void didUpdateWidget(MarqueeText oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.text != widget.text) {
      // A new track: back to the start, and re-measure on the coming build.
      _ac.stop();
      _ac.value = 0;
      _overflow = 0;
    }
  }

  @override
  void dispose() {
    _ac.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // select() so a position tick does not rebuild the title twice a second.
    // Without it this widget would rebuild on every PlayerState change, which
    // for a 2Hz position feed is the very cost being removed.
    final playing = ref.watch(playerProvider.select((s) => s.isPlaying));

    return LayoutBuilder(builder: (context, constraints) {
      // Measured here rather than from scroll metrics, which is the whole
      // point: this runs on layout changes and text changes, not per frame.
      final tp = TextPainter(
        text: TextSpan(text: widget.text, style: widget.style),
        maxLines: 1,
        textDirection: Directionality.of(context),
      )..layout();

      final double overflow =
          (tp.width - constraints.maxWidth).clamp(0.0, double.infinity);

      // State the ticker depends on changed → reconcile after this frame.
      // Deferred because starting a controller during build is illegal.
      if (overflow != _overflow || playing != _playing) {
        _overflow = overflow;
        _playing = playing;
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) _sync();
        });
      }

      // Fits: a plain Text, no clip, no transform, no ticker. The common case
      // for most titles, and it must stay free.
      if (overflow <= 0.5) {
        return Text(widget.text,
            style: widget.style, maxLines: 1, softWrap: false);
      }

      return SizedBox(
        height: tp.height,
        child: ClipRect(
          child: OverflowBox(
            // Lets the text lay itself out at natural width inside a narrower
            // box. A plain Text here would be constrained and would ellipsize
            // instead of overflowing, leaving nothing to slide.
            maxWidth: double.infinity,
            alignment: Alignment.centerLeft,
            child: AnimatedBuilder(
              animation: _ac,
              // `child` is passed in, so the Text is built ONCE and only the
              // Transform is rebuilt per frame — and the RepaintBoundary keeps
              // it a cached layer, so a frame costs a matrix, not a raster.
              child: RepaintBoundary(
                child: Text(widget.text,
                    style: widget.style, maxLines: 1, softWrap: false),
              ),
              builder: (context, child) => Transform.translate(
                offset: Offset(-overflow * _ac.value, 0),
                // The text is wider than the clip in every position, so hit
                // testing does not need to follow the slide — and leaving it
                // untransformed keeps the title's tap target (album) still.
                transformHitTests: false,
                child: child,
              ),
            ),
          ),
        ),
      );
    });
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
  // Timed line changes. Position arrives about twice a second, so highlighting only
  // on samples would be up to half a second late. On each sample we know when the
  // next line is due, so a single timer is armed for that moment, landing line
  // changes within a few ms. Every sample re-arms it, so a seek, pause or speed
  // change can't leave it firing on a stale prediction.
  Timer? _nextLineTimer;
  DateTime? _positionSampledAt;

  /// The index this state has decided on but not yet published. See the note in
  /// [_updateIndex] — the publish is a frame late, and without claiming it a
  /// second pass in the same frame re-does the whole line change.
  int? _claimedIndex;

  @override
  void initState() {
    super.initState();
    // Initialize the index based on starting position
    WidgetsBinding.instance.addPostFrameCallback((_) => _updateIndex());
  }

  @override
  void didUpdateWidget(LyricsViewer oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.currentPosition != widget.currentPosition) {
      _positionSampledAt = DateTime.now();
    }
    // Sync index when position updates from the parent ValueListenableBuilder
    _updateIndex();
  }

  @override
  void dispose() {
    _nextLineTimer?.cancel();
    super.dispose();
  }

  /// Where playback actually is now, rather than where it was at the last
  /// sample. Extrapolated from the sample and the wall clock, at the current
  /// speed, and only while playing — a paused track does not advance.
  Duration _livePosition() {
    final at = _positionSampledAt;
    if (at == null) return widget.currentPosition;
    final st = ref.read(playerProvider);
    if (!st.isPlaying) return widget.currentPosition;
    final elapsed = DateTime.now().difference(at).inMilliseconds * st.speed;
    // Never extrapolate past one sample interval: if samples stop arriving
    // (buffering, a stall, the app backgrounded) the guess must not run away
    // from the audio.
    final capped = elapsed.clamp(0, 600).toDouble();
    return widget.currentPosition + Duration(milliseconds: capped.round());
  }

  /// Arm a one-shot timer for the moment [lines] reaches its next line.
  void _armNextLine(List<LyricLine> lines, int currentIndex) {
    _nextLineTimer?.cancel();
    final next = currentIndex + 1;
    if (next < 0 || next >= lines.length) return;
    final st = ref.read(playerProvider);
    if (!st.isPlaying) return;
    // A stale sample must not arm a timer: _livePosition stops extrapolating after
    // 600 ms, so without fresh samples the gap would stop shrinking and the timer
    // would re-arm itself continuously. The next sample re-arms it.
    final sampledAt = _positionSampledAt;
    if (sampledAt == null) return;
    if (DateTime.now().difference(sampledAt).inMilliseconds > 700) return;

    final speed = st.speed <= 0 ? 1.0 : st.speed;
    final untilMs =
        (lines[next].startTime - _livePosition()).inMilliseconds / speed;
    // Always re-armed, at least a frame ahead. A line due within a few ms (two
    // lines 10 ms apart, a timer that fired a hair early, a seek to a line's exact
    // start) was otherwise left to the next position sample, and the highlight
    // sat on the previous line for up to seconds.
    final delayMs = untilMs < 16 ? 16 : untilMs.round();
    _nextLineTimer = Timer(Duration(milliseconds: delayMs), () {
      if (mounted) _updateIndex();
    });
  }

  void _updateIndex() {
    // Use the same shifted lines the list renders (displayedLyricsProvider applies the
    // 200 ms advance and any offset), so the highlight respects the offset.
    final lines = ref.read(displayedLyricsProvider) ?? widget.lyrics.lines;
    // −1 means nothing has been sung yet; must match `liveIndex` in build(). The list
    // still scrolls to line one during an intro (SyncedLyricsList clamps its anchor to
    // 0) but highlights nothing until the first line starts. Uses the live
    // (extrapolated) position, not the last sample (see _livePosition).
    final pos = _livePosition();
    int newIndex = -1;
    for (int i = 0; i < lines.length; i++) {
      if (pos >= lines[i].startTime) {
        newIndex = i;
      } else {
        break;
      }
    }

    // Re-armed on every pass, not only on a line change: a seek, pause or speed change
    // arrives as a sample with the same index.
    _armNextLine(lines, newIndex);

    // The new index is published in a post-frame callback (provider state can't change
    // during build), but this can run more than once before then, so claim the index
    // synchronously to make repeat passes no-ops.
    final currentIndex = _claimedIndex ?? ref.read(activeLyricIndexProvider);
    if (newIndex != currentIndex) {
      _claimedIndex = newIndex;
      // Log each line change with its skew: `+Nms` means highlighted late, `-Nms` early.
      // Within a couple of hundred ms is the intended advance; a steady second or more
      // suggests the position source is wrong. Logged on transitions only.
      if (newIndex >= 0 && newIndex < lines.length) {
        final start = lines[newIndex].startTime;
        final skew = pos.inMilliseconds - start.inMilliseconds;
        final text = lines[newIndex].words.trim();
        // Only large skews (> 400 ms, beyond the intended advance) go to the event log,
        // since a track has dozens of lines and the ring holds 300. Such a line suggests
        // lyrics timed to a different recording.
        if (skew.abs() > 400) {
          final nowPlaying =
              ref.read(playerProvider.select((s) => s.currentSong?.title));
          EventLog.add('lyric skew ${skew >= 0 ? "+" : ""}${skew}ms on line '
              '$newIndex/${lines.length} of "${nowPlaying ?? "?"}"');
        }
        print('lyric line $newIndex/${lines.length} at '
            '${pos.inMilliseconds}ms '
            '(line starts ${start.inMilliseconds}ms, '
            '${skew >= 0 ? "+" : ""}${skew}ms) '
            '"${text.length > 40 ? '${text.substring(0, 40)}…' : text}"');
      } else if (newIndex == -1 && currentIndex != -1) {
        print('lyric highlight cleared at '
            '${pos.inMilliseconds}ms (before the first line)');
      }
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
    // Live line computed synchronously: this subtree is disposed while the card shows
    // artwork, so on flip-back activeLyricIndexProvider can still hold an old value.
    // Passing the real line lets the list start in sync. −1 before the first line (the
    // list parks on line one and highlights nothing until it's sung).
    int liveIndex = -1;
    final pos = _livePosition();
    for (int i = 0; i < linesToDisplay.length; i++) {
      if (pos >= linesToDisplay[i].startTime) {
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
  final VoidCallback? onLongPress;
  final Function(LongPressStartDetails)? onLongPressStart;
  final Function(LongPressEndDetails)? onLongPressEnd;

  const AuvyBounce({
    super.key, 
    required this.child, 
    this.onTap, 
    this.onDoubleTap,
    this.onLongPress,
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
        onLongPress: widget.onLongPress,
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

/// Lyric and transcript sync controls: nudge until the highlighted line matches what
/// you hear; tap the label to reset.
///
/// Two step sizes: podcast transcripts drift by tens of seconds (inserted ads), so
/// ±5 s / ±30 s; songs are usually a fixed fraction of a second off (lyrics timed to
/// a different release), so 250 ms steps. The correction is saved per song
/// (saveLyricOffsetForSong), the same as long-pressing a line.
class _LyricSyncBar extends ConsumerWidget {
  /// A podcast transcript rather than song lyrics: coarser steps and "transcript"
  /// wording.
  final bool transcript;

  /// Sits at the end of the translation row instead of its own row: no outer padding
  /// or label, just the two steppers and the current shift when non-zero.
  final bool compact;

  const _LyricSyncBar({this.transcript = false, this.compact = false});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final offset = ref.watch(podcastLyricsOffsetProvider);
    final songId = ref.watch(playerProvider.select((s) => s.currentSong?.id));

    final int tapMs = transcript ? 5000 : 250;
    final int longMs = transcript ? 30000 : 1000;
    final String noun = transcript ? 'Transcript' : 'Lyrics';

    // Seconds to one decimal for music (a 250 ms step needs it), whole seconds for a
    // transcript.
    String fmt(Duration d) {
      final ms = d.inMilliseconds;
      final sign = ms > 0 ? '+' : '-';
      final abs = ms.abs();
      if (transcript) return '$sign${(abs / 1000).round()} s';
      return '$sign${(abs / 1000).toStringAsFixed(2)} s';
    }

    final label = offset == Duration.zero
        ? '$noun sync'
        : 'Shifted ${fmt(offset)} • tap to reset';

    // Persisted on every change, so the nudge survives the track change that
    // resets the provider. Saving under the CURRENT song id, which is what
    // loadLyricOffsetForSong reads back.
    void apply(Duration next) {
      HapticService.light();
      ref.read(podcastLyricsOffsetProvider.notifier).state = next;
      if (songId != null) saveLyricOffsetForSong(songId, next);
      print('lyrics offset: ${next.inMilliseconds}ms (nudged)');
    }

    void nudge(int ms) => apply(offset + Duration(milliseconds: ms));

    Widget chip(String text, int tap, int long) => AuvyBounce(
          onTap: () => nudge(tap),
          onLongPressStart: (_) => nudge(long),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 6),
            decoration: BoxDecoration(
              color: Colors.white.withValues(alpha: 0.08),
              borderRadius: BorderRadius.circular(20),
              border: Border.all(color: Colors.white.withValues(alpha: 0.08)),
            ),
            child: Text(text,
                style: const TextStyle(
                    color: Colors.white70,
                    fontSize: 12,
                    fontWeight: FontWeight.w800)),
          ),
        );

    // Earlier lyrics = NEGATIVE offset. Left chip pulls them earlier, which is
    // the direction wanted when the words arrive late.
    final String minusLabel = transcript ? '−5s' : '−0.25s';
    final String plusLabel = transcript ? '+5s' : '+0.25s';

    if (compact) {
      Widget step(IconData icon, int tap, int long) => AuvyBounce(
            onTap: () => nudge(tap),
            onLongPressStart: (_) => nudge(long),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 5),
              decoration: BoxDecoration(
                color: Colors.white.withValues(alpha: 0.08),
                borderRadius: BorderRadius.circular(14),
              ),
              child: Icon(icon, size: 14, color: Colors.white70),
            ),
          );

      return Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          step(Icons.remove_rounded, -tapMs, -longMs),
          // The shift is shown ONLY when it is not zero, and tapping it resets.
          // The owner asked to keep seeing how far they had nudged, so it
          // appears the moment it means something and costs nothing before
          // then — which is what stops this being a third permanent label.
          if (offset != Duration.zero) ...[
            const SizedBox(width: 4),
            AuvyBounce(
              onTap: () => apply(Duration.zero),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 2, vertical: 4),
                child: Text(
                  fmt(offset),
                  style: TextStyle(
                      color: Colors.white.withValues(alpha: 0.75),
                      fontSize: 11,
                      fontWeight: FontWeight.w700,
                      fontFeatures: const [FontFeature.tabularFigures()]),
                ),
              ),
            ),
          ],
          const SizedBox(width: 4),
          step(Icons.add_rounded, tapMs, longMs),
        ],
      );
    }

    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 10, 14, 2),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          chip(minusLabel, -tapMs, -longMs),
          const SizedBox(width: 10),
          AuvyBounce(
            onTap: () => apply(Duration.zero),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 6),
              child: Text(label,
                  style: TextStyle(
                      color: Colors.white.withValues(alpha: 0.66),
                      fontSize: 11.5,
                      fontWeight: FontWeight.w600)),
            ),
          ),
          const SizedBox(width: 10),
          chip(plusLabel, tapMs, longMs),
        ],
      ),
    );
  }
}

/// Radio's replacement for the seek bar, with three states:
///   • at the live edge, playing → LIVE + how long you've been on air
///   • paused                    → PAUSED + the gap growing in real time
///   • playing, but behind       → BEHIND m:ss + a GO LIVE action
/// The gap is owned by the player (see radioBehindLiveProvider), so it survives
/// closing this page.
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

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<Duration>(
      valueListenable: radioBehindLiveProvider,
      builder: (context, behind, _) {
        final pausedAt = radioPausedAtProvider.value;
        final Duration gap = pausedAt == null
            ? behind
            : behind + DateTime.now().difference(pausedAt);
        final bool isBehind = gap.inSeconds >= 2 || pausedAt != null;

        return Padding(
          padding: const EdgeInsets.symmetric(vertical: 10.0),
          child: AnimatedSwitcher(
            duration: const Duration(milliseconds: 250),
            child: isBehind
                ? AuvyBounce(
                    key: const ValueKey('radio_behind_banner'),
                    onTap: () async {
                      HapticService.selection();
                      await widget.onGoLive();
                    },
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                      decoration: BoxDecoration(
                        color: Colors.redAccent.withValues(alpha: 0.14),
                        borderRadius: BorderRadius.circular(30),
                        border: Border.all(
                          color: Colors.redAccent.withValues(alpha: 0.45),
                          width: 1.2,
                        ),
                        boxShadow: [
                          BoxShadow(
                            color: Colors.redAccent.withValues(alpha: 0.15),
                            blurRadius: 14,
                            spreadRadius: 1,
                          ),
                        ],
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(
                            pausedAt != null
                                ? Icons.pause_circle_filled_rounded
                                : Icons.history_rounded,
                            size: 16,
                            color: Colors.redAccent,
                          ),
                          const SizedBox(width: 8),
                          Text(
                            pausedAt != null
                                ? 'Paused · -${gap.toMmSs()}'
                                : '-${gap.toMmSs()} behind live',
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 13,
                              fontWeight: FontWeight.w800,
                              fontFeatures: [FontFeature.tabularFigures()],
                            ),
                          ),
                          // No separate "go live" chip here: the transport already has that button. The whole
                          // pill is still tappable as a shortcut to it.
                        ],
                      ),
                    ),
                  )
                : Container(
                    key: const ValueKey('radio_live_banner'),
                    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                    decoration: BoxDecoration(
                      color: Colors.white.withValues(alpha: 0.06),
                      borderRadius: BorderRadius.circular(30),
                      border: Border.all(
                        color: Colors.white.withValues(alpha: 0.12),
                        width: 1,
                      ),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const _LivePulseDot(),
                        const SizedBox(width: 8),
                        const Text(
                          'LIVE BROADCAST',
                          style: TextStyle(
                            color: Colors.redAccent,
                            fontSize: 12.5,
                            fontWeight: FontWeight.w900,
                            letterSpacing: 1.8,
                          ),
                        ),
                        if (widget.onAir > Duration.zero) ...[
                          const SizedBox(width: 10),
                          Container(
                            width: 3,
                            height: 3,
                            decoration: const BoxDecoration(
                              shape: BoxShape.circle,
                              color: Colors.white38,
                            ),
                          ),
                          const SizedBox(width: 10),
                          Text(
                            widget.onAir.toMmSs(),
                            style: const TextStyle(
                              color: Colors.white70,
                              fontSize: 12,
                              fontWeight: FontWeight.w600,
                              fontFeatures: [FontFeature.tabularFigures()],
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),
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
    // A minimum width so sponsor-break marks are visible (a 2-minute ad in a long
    // episode is only a few pixels), plus higher opacity and standing slightly proud of
    // the track.
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

/// The player's output button: shows where audio is going and opens the output
/// picker. The icon comes from the platform's actual route (a neutral speaker when
/// it can't be determined), refreshed on app resume, since routes change when
/// devices connect or switch, which takes the user out of the app.
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
    // FadeTransition inside a RepaintBoundary, so the pulse runs on the
    // compositor (layer opacity) and repaints nothing. Animating the boxShadow
    // blur instead would repaint the whole player page every frame.
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
    return RepaintBoundary(
      child: FadeTransition(
        opacity: Tween(begin: 0.45, end: 1.0)
            .chain(CurveTween(curve: Curves.easeInOut))
            .animate(_c),
        child: Container(
          width: 9,
          height: 9,
          decoration: const BoxDecoration(
            shape: BoxShape.circle,
            color: Colors.redAccent,
            boxShadow: [
              BoxShadow(
                color: Color(0x99FF5252),
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
/// The quiet "you can swipe this" hint above the artwork: legible but not a button
/// (a 16 px chevron at 55% white with the word LYRICS, no background, since tapping
/// does nothing). Fades out once lyrics are showing.
class _LyricsSwipeHint extends StatefulWidget {
  final bool showing;
  final bool isRadio;
  const _LyricsSwipeHint({required this.showing, this.isRadio = false});

  @override
  State<_LyricsSwipeHint> createState() => _LyricsSwipeHintState();
}

class _LyricsSwipeHintState extends State<_LyricsSwipeHint>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c;

  @override
  void initState() {
    super.initState();
    _c = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1900),
    );
    if (!widget.showing) _play();
  }

  /// Which run of [_play] is current, so a finished old run doesn't act.
  int _run = 0;

  /// A few drifts, then rest in view at mid-cycle (fully visible). Looping forever
  /// would keep the player drawing at the display's full rate for as long as it is
  /// open (120 fps, about a CPU core on a 120 Hz Android phone).
  void _play() {
    final run = ++_run;
    // NOT reverse: the drift is one-directional now — see the builder.
    _c.repeat(count: 3).whenCompleteOrCancel(() {
      if (!mounted || run != _run || widget.showing) return;
      _c.value = 0;
      _c.animateTo(0.5, duration: const Duration(milliseconds: 950));
    });
  }

  @override
  void didUpdateWidget(covariant _LyricsSwipeHint oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.showing != oldWidget.showing) {
      if (widget.showing) {
        _c.stop();
      } else {
        _play();
      }
    }
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
        child: RepaintBoundary(
          child: Padding(
            padding: const EdgeInsets.only(top: 4, bottom: 2),
            child: AnimatedBuilder(
            animation: _c,
            builder: (context, _) {
              // One arrow, drifting left, the direction that opens lyrics (see _handleFlip). The
              // cycle doesn't reverse; it fades in and out at the ends.
              final t = _c.value;
              final slide = -7.0 * Curves.easeInOut.transform(t);
              const edge = 0.25;
              final fade = t < edge
                  ? t / edge
                  : (t > 1 - edge ? (1 - t) / edge : 1.0);
              return Opacity(
                opacity: fade,
                child: Transform.translate(
                  offset: Offset(3.5 + slide, 0),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(Icons.chevron_left_rounded,
                          size: 16, color: Colors.white.withOpacity(0.55)),
                      const SizedBox(width: 6),
                      if (widget.isRadio) ...[
                        Icon(Icons.schedule_rounded,
                            size: 12, color: Colors.white.withOpacity(0.65)),
                        const SizedBox(width: 4),
                      ],
                      Text(
                        widget.isRadio ? 'SCHEDULE' : 'LYRICS',
                        style: TextStyle(
                          color: Colors.white.withOpacity(0.72),
                          fontSize: 9.5,
                          letterSpacing: 2.0,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ],
                  ),
                ),
              );
            },
          ),
        ),
      ),
      ),
    );
  }
}
