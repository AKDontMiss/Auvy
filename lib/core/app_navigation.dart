import 'package:flutter/material.dart';
import 'package:auvy/presentation/pages/player_page.dart';
import 'package:auvy/presentation/main_layout.dart';
import 'package:auvy/presentation/widgets/hydrv_transitions.dart';
import 'package:auvy/data/dummy_data.dart';
import 'package:auvy/data/artist_model.dart';

/// Navigation helpers for an app whose screens live inside bottom-nav tabs.
///
/// Each tab keeps its own history, so "push a page" is ambiguous: pushed onto
/// which stack? pushOnActiveTab() puts the page inside the tab the user is
/// looking at, so the bottom bar stays visible and Back returns to that tab.
/// pushRoot() puts it above everything, which is what a full-screen page like
/// the player wants.
///
/// It also tracks whether the player is open (markPlayerOpened/Closed). The
/// player is a root route covering the tabs, and a Back press while it is open
/// has to close it rather than pop the tab underneath.
///
/// The artistTag/albumTag helpers name routes consistently, so the app can ask
/// "am I already on this artist's page?" and avoid pushing a duplicate when a
/// user taps the same artist twice.
class AppNavigation {
  /// The single route name for the now-playing screen. Every code path that
  /// opens the PlayerPage tags its route with this so duplicates can be detected
  /// and de-duplicated.
  static const String playerRouteName = '/player';

  /// True while a PlayerPage is mounted. PlayerPage flips this in its
  /// initState/dispose, so it reflects reality regardless of WHICH path opened
  /// it (mini-player tap or media-notification tap). Both open paths check it so
  /// we never stack a second PlayerPage on top of an existing one.
  static bool _playerOpen = false;
  static bool get isPlayerOpen => _playerOpen;
  static void markPlayerOpened() => _playerOpen = true;
  static void markPlayerClosed() => _playerOpen = false;


  // Detail-page navigation
  //
  // The ONE sanctioned way to open a detail page in Auvy (Artist, Album,
  // Playlist, Podcast, Radio, Section, …). It mirrors how Spotify and Apple
  // Music behave so the app feels familiar:
  //
  //   • Home / Search / Library are the three top-level tabs. Each keeps its
  //     OWN back stack, so backing out of a detail page returns you exactly the
  //     way you came in that tab — never a foreign stack from another tab.
  //   • Detail pages push onto the CURRENT tab's navigator (via [context]), so
  //     the bottom nav bar and the mini-player stay put the whole time.
  //   • A page is never stacked on top of an identical copy of itself. Tapping
  //     the artist you are already viewing, or hopping Artist → Album → same
  //     Artist, no longer grows a confusing "A → B → A → B" loop — the reason
  //     deep navigation used to feel circular. Pass a stable [name] (see the
  //     tag helpers below) to enable this de-duplication.
  //
  // Every navigation call site should go through push()/pushOnActiveTab() so the
  // rules above hold everywhere, instead of scattering raw Navigator.push calls.

  /// Push [page] onto the current tab's navigator using the shared premium
  /// transition. If [name] matches the page the user is already on, this is a
  /// no-op (prevents duplicate/circular stacking).
  static Future<T?> push<T>(BuildContext context, Widget page, {String? name}) {
    if (name != null && ModalRoute.of(context)?.settings.name == name) {
      // Already viewing this exact page — don't stack a duplicate.
      return Future<T?>.value(null);
    }
    return Navigator.of(context).push<T>(MainLayout.smoothRoute<T>(page, name: name));
  }

  /// Same standard, but for a caller that is NOT inside a tab navigator — most
  /// notably the full-screen [PlayerPage], which lives on the ROOT navigator.
  /// Routes the page onto the active tab so it lands in the correct back stack.
  static Future<T?> pushOnActiveTab<T>(Widget page, {String? name}) {
    final nav = MainLayout.activeTabNavigator?.currentState;
    if (nav == null) return Future<T?>.value(null);
    if (name != null && _topRouteName(nav) == name) {
      // The active tab is already showing this exact page — don't duplicate it.
      return Future<T?>.value(null);
    }
    return nav.push<T>(MainLayout.smoothRoute<T>(page, name: name));
  }

  /// Push [page] onto the ROOT navigator (above the whole MainLayout — tabs,
  /// nav bar and mini-player included), using the shared premium transition.
  /// Use this for app-GLOBAL pages that are not owned by any single tab —
  /// notably Settings. Because it lives on the root stack (not a tab's stack),
  /// it can never get "stuck" as a leftover sub-page of the Library tab: closing
  /// it always returns the user exactly where they were, whatever tab that was.
  /// (Mirrors how Spotify/Apple Music present Settings — full-screen over
  /// everything, reached from the profile menu.)
  static Future<T?> pushRoot<T>(BuildContext context, Widget page,
      {String? name, bool opaque = false}) {
    return Navigator.of(context, rootNavigator: true)
        .push<T>(MainLayout.smoothRoute<T>(page, name: name, opaque: opaque));
  }

  /// The name of a navigator's current (top) route, read without popping it.
  /// `popUntil` invokes its predicate on the top route first; returning true
  /// immediately stops it, so nothing is actually popped.
  static String? _topRouteName(NavigatorState nav) {
    String? topName;
    nav.popUntil((route) {
      topName = route.settings.name;
      return true;
    });
    return topName;
  }

  // Stable route names used for the de-duplication above. Same destination →
  // same tag, so revisiting it is recognised. Falls back to the title when an id
  // is missing so distinct items with blank ids don't collapse into one tag.
  static String artistTag(Song artist) =>
      'artist:${artist.id.isNotEmpty ? artist.id : artist.title.toLowerCase().trim()}';
  static String albumTag(Album album) =>
      'album:${album.id.isNotEmpty ? album.id : album.title.toLowerCase().trim()}';
  static String playlistTag(String id) => 'playlist:${id.toLowerCase().trim()}';
  static const String podcastTag = 'podcast';
  static const String radioTag = 'radio';
  static const String audiobooksTag = 'audiobooks';

  /// The PlayerPage transition, shared by both open paths (mini-player tap and
  /// media-notification tap).
  ///
  /// HYDRV's short rise-and-fade ([HydrvTransition]), on the VERTICAL axis it
  /// shares with tab switches. Page pushes moved to horizontal (see
  /// [MainLayout.smoothRoute]) because a push goes somewhere; the player is a
  /// sheet over what you were doing, and a sheet rises.
  ///
  /// It replaced a full-height sheet slide plus
  /// a hand-rolled vertical drag-dismiss, which were removed wholesale — the drag
  /// was unreliable (it fought the page's own gestures and its dismissal distance
  /// depended on how far you'd dragged) and a 100%-of-screen travel can't feel as
  /// composed as an 8% one no matter how it's curved.
  ///
  /// The player is dismissed by the chevron-down button or the system back
  /// gesture. There is no swipe-down any more, by design.
  static Route playerRoute() {
    return PageRouteBuilder(
      settings: const RouteSettings(name: playerRouteName),
      // OPAQUE: once the slide completes, the navigator stops painting the
      // routes underneath (home + mini-player kept animating below the player
      // for its whole lifetime — wasted frames on a screen nobody could see).
      // The app-wide DynamicBackground lives BEHIND the navigator, so the
      // player's transparent scaffold still shows the ambient backdrop, and
      // during the slide/drag-dismiss the previous route paints as usual.
      opaque: true,
      fullscreenDialog: true,
      barrierColor: Colors.transparent,
      barrierDismissible: false,
      // The SHEET variant of HYDRV's motion — same curves and ratios, scaled up
      // for a surface that replaces the whole screen. At the page-sized 180/160ms
      // the player appeared too fast to follow, which read as a hard cut rather
      // than as quick.
      transitionDuration: HydrvMotion.sheetEnterDuration,
      reverseTransitionDuration: HydrvMotion.sheetExitDuration,
      pageBuilder: (context, animation, secondaryAnimation) => const PlayerPage(),
      // Exactly the transition tab switches use, scaled up: rise, fade in; drift
      // up, fade out.
      //
      // The fade is SAFE here, despite the earlier warning against putting one on
      // this subtree. PlayerPage's build wraps its whole Scaffold in a
      // `RepaintBoundary`, so the page rasterises once and opacity becomes a
      // compositor OpacityLayer over that cached layer — not a per-frame
      // saveLayer over live content. That is the same property the old
      // drag-dismiss relied on. If that RepaintBoundary is ever removed, this
      // becomes expensive again.
      //
      // What made the previous versions lag was never the fade: it was animating a
      // ClipRRect radius (an offscreen saveLayer per frame) inside an
      // AnimatedBuilder that rebuilt the entire artwork + blur subtree on every
      // tick. Neither happens here — HydrvTransition only composites.
      transitionsBuilder: (context, animation, secondaryAnimation, child) =>
          HydrvTransition(animation: animation, sheet: true, child: child),
    );
  }
}
