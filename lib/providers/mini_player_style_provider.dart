import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Shapes the mini-player can take.
///
/// A PROVIDER rather than a `ListeningPolicy` static (which is where the other
/// appearance preferences live) for one reason: the mini-player is on screen
/// while you change this. A static would need the widget to be manually rebuilt
/// to show the new shape, so the setting would appear to do nothing until you
/// navigated away and back. Persisted BY NAME, like [SliderStyle]. See that
/// enum for why index storage made the list un-prunable.
enum MiniPlayerStyle { card, bar, compact, spotlight }

/// Where a style draws playback progress.
enum MiniProgress {
  /// Hairline along the bottom edge (the original).
  bottomLine,

  /// Hairline along the TOP edge — for the docked bar, whose bottom edge is the
  /// screen edge, so a line there is half-hidden by the gesture inset.
  topLine,

  /// A ring around the play button. Frees the edges entirely and puts the
  /// information where the thumb already is.
  ring,
}

/// What each style IS, not just how big it is.
///
/// THE FIRST VERSION OF THIS ONLY VARIED PROPORTION — height, margin, radius,
/// artwork size, and the four options were rightly reported as looking the same:
/// scaling a row by 15% is not a different design, it is the same design at a
/// different size. Each style now differs STRUCTURALLY: which controls it shows,
/// whether the artist line exists at all, and where progress is drawn. Those are
/// the things the eye actually reads as "a different player".
///
/// Still one widget tree rather than four, driven by this data — four copies
/// would drift apart on the next change.
class MiniPlayerMetrics {
  final double height;
  final double horizontalMargin;
  final double radius;
  final double artwork;

  /// Bar mode sits flush against the bottom edge, so it keeps its corners only
  /// on top and drops the border and shadow that a floating card needs.
  final bool docked;

  /// Heart button. Dropped by the styles whose point is fewer things.
  final bool showLike;

  /// Previous/next buttons. The swipe gesture still works in every style — these
  /// are for people who would rather aim than swipe.
  final bool showSkip;

  /// Artist under the title. A single-line row is a genuinely different object
  /// from a two-line one, and it is what lets Compact be as short as it is.
  final bool showArtist;

  final MiniProgress progress;

  /// SURFACE, NOT JUST PROPORTION — round two of the same lesson.
  ///
  /// The structural pass (which controls, which lines) made the four styles
  /// behave differently but they still LOOKED identical: every one of them was
  /// matte black, hairline border, black drop shadow, 10px artwork corners. Two
  /// styles side by side read as the same component resized. These four fields
  /// are what give each one a material of its own.

  /// Cover corner radius. Square-ish reads as chrome, a full circle reads as a
  /// token, generous corners read as a piece of artwork.
  final double artworkRadius;

  /// Corner radius comes from the HEIGHT, making a true lozenge. Only Compact
  /// does this, and it is most of why Compact stops looking like a short Card.
  final bool pill;

  /// A faint accent gradient across the surface instead of flat black. Reserved
  /// for the styles meant to have presence; on the quiet ones it would just be
  /// noise behind the text.
  final bool accentWash;

  /// Tints the drop shadow with the accent so the panel appears lit rather than
  /// merely raised. Costs nothing extra: it replaces the black shadow.
  final bool accentGlow;

  const MiniPlayerMetrics({
    required this.height,
    required this.horizontalMargin,
    required this.radius,
    required this.artwork,
    required this.progress,
    this.docked = false,
    this.showLike = true,
    this.showSkip = false,
    this.showArtist = true,
    this.artworkRadius = 10,
    this.pill = false,
    this.accentWash = false,
    this.accentGlow = false,
  });

  static MiniPlayerMetrics of(MiniPlayerStyle s) => switch (s) {
        // CARD — a floating panel. Title + artist, heart, edge hairline, and an
        // accent-tinted shadow so it reads as LIT rather than merely raised.
        // That glow is the whole difference between a card and a rectangle.
        MiniPlayerStyle.card => const MiniPlayerMetrics(
            height: 64,
            horizontalMargin: 12,
            radius: 18,
            artwork: 46,
            artworkRadius: 10,
            accentGlow: true,
            progress: MiniProgress.bottomLine),
        // BAR — chrome, not an object on top of the page. Trades the heart for
        // prev/next (a transport bar should transport), and moves progress to the
        // TOP edge, because its bottom edge is the screen edge.
        //
        // Deliberately the PLAINEST of the four: no wash, no glow, and nearly
        // square artwork. Anything that made it float would undo the point.
        MiniPlayerStyle.bar => const MiniPlayerMetrics(
            height: 60,
            horizontalMargin: 0,
            radius: 16,
            artwork: 44,
            artworkRadius: 6,
            docked: true,
            showLike: false,
            showSkip: true,
            progress: MiniProgress.topLine),
        // COMPACT — the fewest things that still work. TITLE ONLY, play/pause
        // only, and now a true PILL with a circular cover.
        //
        // The pill is doing real work. At 52px with square corners this was just
        // a shorter Card; as a lozenge with a round cover it reads as a different
        // object entirely. Wider side margins sell it — a pill that touches both
        // edges is a bar.
        MiniPlayerStyle.compact => const MiniPlayerMetrics(
            height: 52,
            horizontalMargin: 26,
            radius: 14,
            artwork: 38,
            artworkRadius: 19,
            pill: true,
            showLike: false,
            showArtist: false,
            progress: MiniProgress.bottomLine),
        // SPOTLIGHT — the full transport. Big cover, heart AND skips, and
        // progress as a RING around play, so no line competes with the artwork.
        //
        // The only style with BOTH wash and glow. It is the one whose stated
        // purpose is presence, so it is the one allowed to be loud; giving the
        // treatment to more than one would flatten the set again.
        MiniPlayerStyle.spotlight => const MiniPlayerMetrics(
            height: 76,
            horizontalMargin: 10,
            radius: 22,
            artwork: 60,
            artworkRadius: 14,
            accentWash: true,
            accentGlow: true,
            showSkip: true,
            progress: MiniProgress.ring),
      };
}

extension MiniPlayerStyleLabel on MiniPlayerStyle {
  String get label => switch (this) {
        MiniPlayerStyle.card => 'Card',
        MiniPlayerStyle.bar => 'Bar',
        MiniPlayerStyle.compact => 'Compact',
        MiniPlayerStyle.spotlight => 'Spotlight',
      };

  String get blurb => switch (this) {
        MiniPlayerStyle.card => 'Floating panel, lit edge, title and artist',
        MiniPlayerStyle.bar => 'Flush to the bottom, with skip buttons',
        MiniPlayerStyle.compact => 'A pill. Title and play, nothing else',
        MiniPlayerStyle.spotlight => 'Big cover, full transport, ring progress',
      };
}

class MiniPlayerStyleNotifier extends StateNotifier<MiniPlayerStyle> {
  MiniPlayerStyleNotifier() : super(MiniPlayerStyle.card) {
    _load();
  }

  static const String _kName = 'mini_player_style_name';

  Future<void> _load() async {
    final prefs = await SharedPreferences.getInstance();
    final name = prefs.getString(_kName);
    if (name == null) return;
    state = MiniPlayerStyle.values
        .firstWhere((s) => s.name == name, orElse: () => MiniPlayerStyle.card);
  }

  Future<void> setStyle(MiniPlayerStyle s) async {
    state = s;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_kName, s.name);
  }
}

final miniPlayerStyleProvider =
    StateNotifierProvider<MiniPlayerStyleNotifier, MiniPlayerStyle>((ref) {
  return MiniPlayerStyleNotifier();
});
