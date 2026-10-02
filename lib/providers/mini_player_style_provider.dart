import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Styles the mini-player can take. A provider rather than a `ListeningPolicy`
/// static (where other appearance settings live) because the mini-player is on
/// screen while this is changed and must rebuild immediately. Saved by name, like
/// [SliderStyle], so a retired style's stored name falls back to [card].
enum MiniPlayerStyle { card, cover, capsule, fill }

/// Where a style draws playback progress.
enum MiniProgress {
  /// Hairline along the bottom edge.
  bottomLine,

  /// A ring around the play button: a pill's round ends would clip an edge
  /// line, and the ring puts progress where the thumb already is.
  ring,

  /// The whole surface fills from the left as the song plays.
  fill,
}

/// What the surface is made of.
enum MiniSurface {
  /// Matte black with an accent-tinted edge and shadow, so it reads as lit.
  lit,

  /// The colour of the playing song's cover, darkened until white text reads.
  cover,

  /// Matte black with a grey edge and a plain shadow.
  plain,
}

/// What each style is: its proportions, surface, controls and where progress
/// goes. One widget tree driven by this data, rather than four copies that
/// would drift apart.
class MiniPlayerMetrics {
  final double height;
  final double horizontalMargin;
  final double radius;
  final double artwork;

  /// Cover corner radius, before the user's cover corners setting scales it.
  final double artworkRadius;

  /// Corner radius comes from the height, making a true capsule.
  final bool pill;

  final MiniSurface surface;
  final MiniProgress progress;

  /// Heart button.
  final bool showLike;

  /// A next button beside play. Swiping still skips in every style.
  final bool showNext;

  const MiniPlayerMetrics({
    required this.height,
    required this.horizontalMargin,
    required this.radius,
    required this.artwork,
    required this.artworkRadius,
    required this.surface,
    required this.progress,
    this.pill = false,
    this.showLike = true,
    this.showNext = false,
  });

  static MiniPlayerMetrics of(MiniPlayerStyle s) => switch (s) {
        // CARD, the default: a floating panel lit by the accent.
        MiniPlayerStyle.card => const MiniPlayerMetrics(
            height: 64,
            horizontalMargin: 12,
            radius: 18,
            artwork: 46,
            artworkRadius: 10,
            surface: MiniSurface.lit,
            progress: MiniProgress.bottomLine),
        // COVER COLOUR: the card's shape in the colour of what is playing, so
        // the bar changes with every song.
        MiniPlayerStyle.cover => const MiniPlayerMetrics(
            height: 64,
            horizontalMargin: 12,
            radius: 18,
            artwork: 46,
            artworkRadius: 10,
            surface: MiniSurface.cover,
            progress: MiniProgress.bottomLine),
        // CAPSULE: slimmer and rounder, with a round cover and next beside play,
        // and progress as a ring around play.
        MiniPlayerStyle.capsule => const MiniPlayerMetrics(
            height: 58,
            horizontalMargin: 16,
            radius: 29,
            artwork: 42,
            artworkRadius: 21,
            pill: true,
            surface: MiniSurface.plain,
            progress: MiniProgress.ring,
            showLike: false,
            showNext: true),
        // PROGRESS FILL: the card's shape, with the accent filling the whole
        // bar as the song plays instead of a hairline.
        MiniPlayerStyle.fill => const MiniPlayerMetrics(
            height: 64,
            horizontalMargin: 12,
            radius: 18,
            artwork: 46,
            artworkRadius: 10,
            surface: MiniSurface.plain,
            progress: MiniProgress.fill),
      };
}

extension MiniPlayerStyleLabel on MiniPlayerStyle {
  String get label => switch (this) {
        MiniPlayerStyle.card => 'Card',
        MiniPlayerStyle.cover => 'Cover colour',
        MiniPlayerStyle.capsule => 'Capsule',
        MiniPlayerStyle.fill => 'Fill',
      };

  String get blurb => switch (this) {
        MiniPlayerStyle.card => 'A floating panel with a glow in your accent',
        MiniPlayerStyle.cover => "Takes the colour of each song's cover",
        MiniPlayerStyle.capsule => 'Slim and round, with play and next',
        MiniPlayerStyle.fill => 'The whole bar fills up as the song plays',
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
    // The constructor starts this and does not await it, so the notifier
    // can be disposed while this is still suspended — a provider rebuild
    // on sign-in or restore does exactly that. Writing state then throws
    // "Tried to use X after `dispose` was called" out of an async gap,
    // where nothing is there to catch it.
    if (!mounted) return;
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
