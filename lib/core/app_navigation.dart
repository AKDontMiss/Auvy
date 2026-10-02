import 'package:flutter/material.dart';
import 'package:auvy/presentation/pages/player_page.dart';
import 'package:auvy/presentation/main_layout.dart';
import 'package:auvy/presentation/widgets/hydrv_transitions.dart';
import 'package:auvy/data/dummy_data.dart';
import 'package:auvy/data/artist_model.dart';

/// Navigation helpers for an app whose screens live inside bottom-nav tabs.
///
/// Each tab keeps its own history. [pushOnActiveTab] opens a page inside the
/// current tab (nav bar stays, Back returns within the tab); [pushRoot] opens a
/// page above everything, as the full-screen player needs.
///
/// Also tracks whether the player is open, so Back closes it first, and provides
/// route-name helpers used to avoid pushing a duplicate of the current page.
class AppNavigation {
  /// Route name for the now-playing screen, so duplicates can be detected.
  static const String playerRouteName = '/player';

  /// True while a PlayerPage is mounted (set in its initState/dispose), so no open
  /// path stacks a second player on top of an existing one.
  static bool _playerOpen = false;
  static bool get isPlayerOpen => _playerOpen;

  /// Bumped every time a PlayerPage mounts, for work that must run once per
  /// opening. Fired from PlayerPage.initState because every open path passes
  /// through it.
  static final ValueNotifier<int> playerOpenedSignal = ValueNotifier<int>(0);

  static void markPlayerOpened() {
    _playerOpen = true;
    playerOpenedSignal.value++;
  }

  static void markPlayerClosed() => _playerOpen = false;


  // Detail-page navigation
  //
  // The standard way to open a detail page (artist, album, playlist, podcast,
  // radio, section):
  //   • Home, Search and Library each keep their own back stack.
  //   • Detail pages push onto the current tab's navigator, so the nav bar and
  //     mini-player stay visible.
  //   • A page is never stacked on an identical copy of itself; pass a stable
  //     [name] (see the tag helpers below) to enable that check.

  /// Pushes [page] onto the current tab's navigator. Does nothing if [name]
  /// matches the page already on top.
  static Future<T?> push<T>(BuildContext context, Widget page, {String? name}) {
    if (name != null && ModalRoute.of(context)?.settings.name == name) {
      // Already on this exact page.
      return Future<T?>.value(null);
    }
    return Navigator.of(context).push<T>(MainLayout.smoothRoute<T>(page, name: name));
  }

  /// Like [push], for callers outside a tab navigator (such as the player, which
  /// lives on the root navigator): the page lands on the active tab's stack.
  static Future<T?> pushOnActiveTab<T>(Widget page, {String? name}) {
    final nav = MainLayout.activeTabNavigator?.currentState;
    if (nav == null) return Future<T?>.value(null);
    if (name != null && _topRouteName(nav) == name) {
      // The active tab already shows this exact page.
      return Future<T?>.value(null);
    }
    return nav.push<T>(MainLayout.smoothRoute<T>(page, name: name));
  }

  /// Pushes [page] onto the root navigator, above the tabs, nav bar and
  /// mini-player. Used for app-wide pages such as Settings, so closing them always
  /// returns to wherever the user was.
  static Future<T?> pushRoot<T>(BuildContext context, Widget page,
      {String? name, bool opaque = false}) {
    return Navigator.of(context, rootNavigator: true)
        .push<T>(MainLayout.smoothRoute<T>(page, name: name, opaque: opaque));
  }

  /// The name of a navigator's top route. `popUntil` checks the top route first,
  /// and returning true stops it immediately, so nothing is popped.
  static String? _topRouteName(NavigatorState nav) {
    String? topName;
    nav.popUntil((route) {
      topName = route.settings.name;
      return true;
    });
    return topName;
  }

  // Stable route names for the de-duplication above. Falls back to the title when
  // an id is missing, so different items with blank ids don't share a tag.
  static String artistTag(Song artist) =>
      'artist:${artist.id.isNotEmpty ? artist.id : artist.title.toLowerCase().trim()}';
  static String albumTag(Album album) =>
      'album:${album.id.isNotEmpty ? album.id : album.title.toLowerCase().trim()}';
  static String playlistTag(String id) => 'playlist:${id.toLowerCase().trim()}';
  static const String podcastTag = 'podcast';
  static const String radioTag = 'radio';
  static const String audiobooksTag = 'audiobooks';

  /// The player's open transition, shared by every path that opens it.
  ///
  /// A short rise-and-fade on the vertical axis, the same motion as tab switches.
  /// The player is dismissed with the chevron button or the system back gesture.
  static Route playerRoute() {
    return PageRouteBuilder(
      settings: const RouteSettings(name: playerRouteName),
      // Opaque: once the transition finishes, the routes underneath stop painting.
      // The app background sits behind the navigator, so it still shows through.
      opaque: true,
      fullscreenDialog: true,
      barrierColor: Colors.transparent,
      barrierDismissible: false,
      // The larger "sheet" timing, since the player replaces the whole screen.
      transitionDuration: HydrvMotion.sheetEnterDuration,
      reverseTransitionDuration: HydrvMotion.sheetExitDuration,
      pageBuilder: (context, animation, secondaryAnimation) => const PlayerPage(),
      // Rise and fade in; drift up and fade out. The fade is cheap because PlayerPage
      // wraps its scaffold in a RepaintBoundary, so opacity composites a cached layer.
      transitionsBuilder: (context, animation, secondaryAnimation, child) =>
          HydrvTransition(animation: animation, sheet: true, child: child),
    );
  }
}
