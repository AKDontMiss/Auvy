import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:auvy/presentation/widgets/settings_kit.dart';
import 'package:auvy/providers/theme_provider.dart';
import 'package:auvy/providers/haptics_provider.dart';
import 'package:auvy/providers/mini_player_style_provider.dart';
import 'package:auvy/providers/density_provider.dart';
import 'package:auvy/presentation/pages/settings_page.dart';
import 'package:auvy/services/haptic_service.dart';
import 'package:auvy/services/listening_policy.dart';

// THEME — accent, pure black, artwork shape, and the rest of Appearance.
//
// The idea worth taking from that screen is not the list of switches, it's the
// LIVE MOCKUP: a miniature of the app that repaints as you choose, so a colour
// is judged against the chrome it will actually sit in rather than as a circle
// on a card. Auvy's accent shows up in a dozen small places (nav pill, progress,
// section accents) and none of them were visible while picking.
//
// What is deliberately NOT ported:
//  • Light mode / system mode. A Compose-style theme is just a colour scheme;
//    Auvy paints white-on-dark literally everywhere, so a light theme is a
//    repaint of the whole app, not a setting. Shipping the switch without that
//    work would be the fake-feature pattern.
//  • Material You / artwork-derived global accent. The accent drives the
//    LAUNCHER ICON (AppIconService.applyForAccent), so an accent that follows
//    the artwork would rewrite launcher components on every track change.
//    The player already carries artwork colour, which is where it belongs.

/// The six accents, matching `AppIconService.variantForAccent` one-for-one so
/// the launcher icon always has a colour to follow. Adding a seventh here would
/// silently fall back to the stock icon and leave a purple app with a cyan icon.
const List<({Color color, String name})> kAccentOptions = [
  (color: Color(0xFF53B1E1), name: 'Cyan'),
  (color: Colors.purpleAccent, name: 'Purple'),
  (color: Colors.greenAccent, name: 'Green'),
  (color: Colors.orangeAccent, name: 'Orange'),
  (color: Colors.redAccent, name: 'Red'),
  (color: Colors.pinkAccent, name: 'Pink'),
];

String accentName(Color c) => kAccentOptions
    .firstWhere((o) => o.color.value == c.value,
        orElse: () => (color: c, name: 'Custom'))
    .name;

class ThemePage extends ConsumerWidget {
  const ThemePage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final accent = ref.watch(themeProvider);
    final pureBlack = ref.watch(pureBlackProvider);

    return SettingsSubPage(
      title: 'Appearance',
      header: ThemeMockup(accent: accent, pureBlack: pureBlack),
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 18),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(children: [
                SettingsIconChip(icon: Icons.palette_rounded, tint: accent),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text('Accent colour',
                          style: TextStyle(
                              color: Colors.white,
                              fontWeight: FontWeight.w600,
                              fontSize: 14.5)),
                      const SizedBox(height: 2),
                      Text('${accentName(accent)} · the launcher icon follows it',
                          style: TextStyle(
                              color: Colors.white.withOpacity(0.66), fontSize: 11.5)),
                    ],
                  ),
                ),
              ]),
              const SizedBox(height: 18),
              // A wrapping grid rather than the old single Row: it survives a
              // narrow screen or a large system font, where six fixed circles
              // spaced apart would overflow.
              Wrap(
                spacing: 14,
                runSpacing: 14,
                children: [
                  for (final option in kAccentOptions)
                    _Swatch(
                      option: option,
                      selected: accent.value == option.color.value,
                      onTap: () {
                        HapticService.selection();
                        ref.read(themeProvider.notifier).setThemeColor(option.color);
                      },
                    ),
                ],
              ),
            ],
          ),
        ),
        Column(children: [
          SettingsToggleRow(
            icon: Icons.contrast_rounded,
            tint: const Color(0xFF90A4AE),
            title: 'Pure black',
            subtitle: 'Solid black backdrop — saves power on an OLED screen',
            value: pureBlack,
            onChanged: (v) {
              HapticService.selection();
              ref.read(pureBlackProvider.notifier).set(v);
            },
          ),
        ]),

        // Moved here out of Settings → "Interface"
        //
        // Both of these are appearance choices, and Settings is where the
        // FUNCTIONAL switches live. The progress-bar style in particular is
        // purely how the player looks, so it belongs beside the accent colour and
        // Pure black rather than several screens away under its own heading —
        // and this page has the room to show it as a live preview grid.
        //
        // Haptics comes along because it is the same kind of decision: how the
        // app feels rather than what it does. "Interface" as a section is gone;
        // it held exactly these two rows.
        // Sits with the other switches rather than in the colour grid above,
        // because it is not a seventh colour — it is a mode that overrides
        // whichever of the six is selected.
        Column(children: [
          Consumer(builder: (_, ref, __) {
            final on = ref.watch(dynamicAccentProvider);
            final live = ref.watch(playerColorProvider);
            return SettingsToggleRow(
              icon: Icons.auto_awesome_rounded,
              // The one row in this page whose tint is the LIVE artwork colour,
              // so the switch previews its own effect before you flip it.
              tint: on ? live : const Color(0xFFFFB74D),
              title: "Accent follows the artwork",
              subtitle: on
                  ? "Using the colour of what is playing"
                  : "Colour the app from each song cover",
              value: on,
              onChanged: (v) => ref.read(dynamicAccentProvider.notifier).set(v),
            );
          }),
          const SettingsDivider(),
          Consumer(builder: (_, ref, __) {
            final hapticsOn = ref.watch(hapticsProvider);
            return SettingsToggleRow(
              icon: Icons.vibration_rounded,
              tint: const Color(0xFFB388FF),
              title: 'Haptic feedback',
              subtitle: 'Vibrate on taps, swipes and confirmations',
              value: hapticsOn,
              onChanged: (val) {
                ref.read(hapticsProvider.notifier).setEnabled(val);
                // Confirm the new state physically (only fires when ON).
                HapticService.medium();
              },
            );
          }),
        ]),
        const SliderStyleBlock(),
        const _ArtworkShapeBlock(),
        const _ArtworkRoundnessBlock(),
        const _MiniPlayerStyleBlock(),
        const _DensityBlock(),

        // Lyrics, MOVED from Settings → Playback
        // Size, centring, romanisation and the share-line count are all about how
        // lyrics LOOK and read — the same kind of decision as the accent colour or
        // the slider style. In Settings they sat next to headset behaviour, which
        // is where you look for what the app DOES, not how it looks.
        Column(children: const [
          LyricTextScaleRow(),
          SettingsDivider(),
          CentreLyricsRow(),
          SettingsDivider(),
          RomanizationNavRow(),
          SettingsDivider(),
          LyricShareLinesRow(),
        ]),
      ],
    );
  }
}

/// List density. Labelled "Lists" rather than "UI" because that is honestly what
/// it reaches. See [AppDensity] for the funnel and for what it deliberately
/// leaves alone.
class _DensityBlock extends ConsumerWidget {
  const _DensityBlock();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final accent = ref.watch(themeProvider);
    final current = ref.watch(densityProvider);

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 22),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(children: [
            SettingsIconChip(icon: Icons.format_line_spacing_rounded, tint: accent),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text('List density',
                      style: TextStyle(
                          color: Colors.white,
                          fontWeight: FontWeight.w600,
                          fontSize: 14.5)),
                  const SizedBox(height: 2),
                  Text('${current.label} · ${current.blurb}',
                      style: TextStyle(
                          color: Colors.white.withOpacity(0.66),
                          fontSize: 11.5)),
                ],
              ),
            ),
          ]),
          const SizedBox(height: 14),
          Row(
            children: [
              for (final d in AppDensity.values) ...[
                Expanded(
                  child: GestureDetector(
                    onTap: () {
                      HapticService.selection();
                      ref.read(densityProvider.notifier).setDensity(d);
                    },
                    child: AnimatedContainer(
                      duration: const Duration(milliseconds: 180),
                      height: 58,
                      decoration: BoxDecoration(
                        color: d == current
                            ? accent.withOpacity(0.12)
                            : Colors.white.withOpacity(0.04),
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(
                          color: d == current ? accent : Colors.transparent,
                          width: 1.2,
                        ),
                      ),
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          // Three stacked bars at the option's own spacing — the
                          // preview IS the thing being chosen.
                          for (int i = 0; i < 3; i++) ...[
                            Container(
                                height: 2.5,
                                width: 20,
                                decoration: BoxDecoration(
                                  color: Colors.white.withOpacity(0.55),
                                  borderRadius: BorderRadius.circular(1.5),
                                )),
                            if (i < 2)
                              SizedBox(
                                  height: switch (d) {
                                    AppDensity.compact => 2.0,
                                    AppDensity.comfortable => 4.0,
                                    AppDensity.spacious => 6.5,
                                  }),
                          ],
                          const SizedBox(height: 7),
                          Text(d.label,
                              style: TextStyle(
                                  color: Colors.white.withOpacity(0.75),
                                  fontSize: 9.5,
                                  fontWeight: FontWeight.w700)),
                        ],
                      ),
                    ),
                  ),
                ),
                if (d != AppDensity.values.last) const SizedBox(width: 8),
              ],
            ],
          ),
        ],
      ),
    );
  }
}

/// Mini-player shape. Four proportions of the same row, not four layouts — see
/// [MiniPlayerMetrics] for why that distinction matters.
class _MiniPlayerStyleBlock extends ConsumerWidget {
  const _MiniPlayerStyleBlock();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final accent = ref.watch(themeProvider);
    final current = ref.watch(miniPlayerStyleProvider);

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 18),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(children: [
            SettingsIconChip(
                icon: Icons.dashboard_customize_rounded, tint: accent),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text('Mini-player',
                      style: TextStyle(
                          color: Colors.white,
                          fontWeight: FontWeight.w600,
                          fontSize: 14.5)),
                  const SizedBox(height: 2),
                  Text('${current.label} · ${current.blurb}',
                      style: TextStyle(
                          color: Colors.white.withOpacity(0.66),
                          fontSize: 11.5)),
                ],
              ),
            ),
          ]),
          const SizedBox(height: 14),
          // Scale miniatures rather than names alone: the difference between
          // these IS proportion, and proportion is the one thing a label can't
          // convey. Each preview is the real metric set at 1/4 scale.
          Row(
            children: [
              for (final s in MiniPlayerStyle.values) ...[
                Expanded(
                  child: GestureDetector(
                    onTap: () {
                      HapticService.selection();
                      ref.read(miniPlayerStyleProvider.notifier).setStyle(s);
                    },
                    child: AnimatedContainer(
                      duration: const Duration(milliseconds: 180),
                      height: 60,
                      decoration: BoxDecoration(
                        color: s == current
                            ? accent.withOpacity(0.12)
                            : Colors.white.withOpacity(0.04),
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(
                          color: s == current ? accent : Colors.transparent,
                          width: 1.2,
                        ),
                      ),
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          _MiniPreview(
                              metrics: MiniPlayerMetrics.of(s), accent: accent),
                          const SizedBox(height: 7),
                          Text(s.label,
                              style: TextStyle(
                                  color: Colors.white.withOpacity(0.75),
                                  fontSize: 9.5,
                                  fontWeight: FontWeight.w700)),
                        ],
                      ),
                    ),
                  ),
                ),
                if (s != MiniPlayerStyle.values.last)
                  const SizedBox(width: 7),
              ],
            ],
          ),
        ],
      ),
    );
  }
}

/// A ~1/4-scale sketch of the mini-player: card outline, artwork block, two text
/// bars. Derived from the SAME [MiniPlayerMetrics] the real bar uses, so a
/// preview can't drift out of sync with what tapping it produces.
class _MiniPreview extends StatelessWidget {
  final MiniPlayerMetrics metrics;
  final Color accent;
  const _MiniPreview({required this.metrics, required this.accent});

  @override
  Widget build(BuildContext context) {
    const scale = 0.36;
    final h = metrics.height * scale;
    return SizedBox(
      width: 44,
      height: 28,
      child: Align(
        // Docked previews hug the bottom of the swatch, which is the one thing
        // that distinguishes Bar from Card at this size.
        alignment: metrics.docked ? Alignment.bottomCenter : Alignment.center,
        child: Container(
          // Bar runs the full swatch width; the others inset like the real card.
          width: metrics.docked ? 44 : 44 - metrics.horizontalMargin * scale * 2,
          height: h,
          decoration: BoxDecoration(
            color: Colors.white.withOpacity(0.10),
            borderRadius: metrics.docked
                ? BorderRadius.vertical(
                    top: Radius.circular(metrics.radius * scale))
                : BorderRadius.circular(metrics.radius * scale),
            border: Border.all(color: Colors.white.withOpacity(0.16), width: 0.6),
          ),
          child: Row(
            children: [
              SizedBox(width: (h - metrics.artwork * scale) / 2 + 1),
              Container(
                width: metrics.artwork * scale,
                height: metrics.artwork * scale,
                decoration: BoxDecoration(
                  color: accent.withOpacity(0.85),
                  borderRadius:
                      BorderRadius.circular(metrics.artwork * scale * 0.24),
                ),
              ),
              const SizedBox(width: 2.5),
              Expanded(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Container(
                        height: 1.8,
                        width: 14,
                        color: Colors.white.withOpacity(0.55)),
                    // Only styles that HAVE an artist line show a second bar —
                    // the previews have to show the structural difference, not
                    // just the size difference, or the options look identical.
                    if (metrics.showArtist) ...[
                      const SizedBox(height: 2),
                      Container(
                          height: 1.4,
                          width: 9,
                          color: Colors.white.withOpacity(0.28)),
                    ],
                  ],
                ),
              ),
              // Control dots: heart, skips and play, exactly as the style shows
              // them. This is what distinguishes Bar (skips, no heart) from Card
              // (heart, no skips) at swatch size.
              if (metrics.showLike)
                Container(
                    width: 2.6,
                    height: 2.6,
                    decoration: BoxDecoration(
                        color: accent.withOpacity(0.9),
                        shape: BoxShape.circle)),
              if (metrics.showSkip) ...[
                const SizedBox(width: 1.6),
                Container(
                    width: 2,
                    height: 2,
                    decoration: BoxDecoration(
                        color: Colors.white.withOpacity(0.5),
                        shape: BoxShape.circle)),
              ],
              const SizedBox(width: 1.6),
              // Play: a ring for the ring style, a filled dot otherwise.
              Container(
                width: 5,
                height: 5,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: metrics.progress == MiniProgress.ring
                      ? Colors.transparent
                      : Colors.white.withOpacity(0.8),
                  border: metrics.progress == MiniProgress.ring
                      ? Border.all(color: accent, width: 1.1)
                      : null,
                ),
              ),
              const SizedBox(width: 3),
            ],
          ),
        ),
      ),
    );
  }
}

/// Global cover-art roundness. Applies to artwork EVERYWHERE (lists, headers,
/// mini-player, sheets) because it is applied inside `AuvyImage`, which every
/// cover in Auvy already goes through.
///
/// A multiplier on each surface's designed radius, not one absolute value — see
/// [ListeningPolicy.artworkRoundness] for why a 46px thumbnail and a 300px album
/// header cannot share a corner size.
class _ArtworkRoundnessBlock extends ConsumerStatefulWidget {
  const _ArtworkRoundnessBlock();
  @override
  ConsumerState<_ArtworkRoundnessBlock> createState() =>
      _ArtworkRoundnessBlockState();
}

class _ArtworkRoundnessBlockState
    extends ConsumerState<_ArtworkRoundnessBlock> {
  @override
  Widget build(BuildContext context) {
    final accent = ref.watch(themeProvider);
    final v = ListeningPolicy.artworkRoundness;
    final String label = v <= 0.05
        ? 'Sharp'
        : (v < 0.85
            ? 'Tighter'
            : (v <= 1.15 ? 'As designed' : (v < 1.7 ? 'Softer' : 'Pill')));

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 18),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(children: [
            SettingsIconChip(
                icon: Icons.rounded_corner_rounded, tint: accent),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text('Cover art roundness',
                      style: TextStyle(
                          color: Colors.white,
                          fontWeight: FontWeight.w600,
                          fontSize: 14.5)),
                  const SizedBox(height: 2),
                  Text('$label · every cover in the app',
                      style: TextStyle(
                          color: Colors.white.withOpacity(0.66),
                          fontSize: 11.5)),
                ],
              ),
            ),
            // Live preview at a realistic tile size, so the choice is judged on
            // the thing it changes rather than on a number.
            Container(
              width: 30,
              height: 30,
              decoration: BoxDecoration(
                color: accent.withOpacity(0.85),
                borderRadius:
                    BorderRadius.circular(ListeningPolicy.roundArtwork(8)),
              ),
            ),
          ]),
          Slider(
            value: v,
            min: 0.0,
            max: 2.0,
            // 8 steps: fine enough to find a look, coarse enough that the value
            // is repeatable and a stray drag can't land somewhere unnameable.
            divisions: 8,
            activeColor: accent,
            inactiveColor: Colors.white.withOpacity(0.14),
            onChanged: (nv) {
              setState(() => ListeningPolicy.artworkRoundness = nv);
            },
            onChangeEnd: (nv) {
              HapticService.selection();
              ListeningPolicy.setArtworkRoundness(nv);
            },
          ),
        ],
      ),
    );
  }
}

/// Shape of the player's cover art. Scoped to the player and labelled that way —
/// see [ListeningPolicy.playerArtworkShape] for why this is not a global radius.
class _ArtworkShapeBlock extends ConsumerStatefulWidget {
  const _ArtworkShapeBlock();
  @override
  ConsumerState<_ArtworkShapeBlock> createState() => _ArtworkShapeBlockState();
}

class _ArtworkShapeBlockState extends ConsumerState<_ArtworkShapeBlock> {
  static const _labels = ['Square', 'Rounded', 'Soft', 'Squircle', 'Circle'];
  // Miniature preview radius per option, scaled for a 22px swatch.
  static const _miniRadii = [0.0, 4.0, 7.0, 9.5, 11.0];

  @override
  Widget build(BuildContext context) {
    final accent = ref.watch(themeProvider);
    final current = ListeningPolicy.playerArtworkShape;

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 18),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(children: [
            SettingsIconChip(icon: Icons.crop_square_rounded, tint: accent),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text('Player artwork',
                      style: TextStyle(
                          color: Colors.white,
                          fontWeight: FontWeight.w600,
                          fontSize: 14.5)),
                  const SizedBox(height: 2),
                  Text('${_labels[current]} · shape of the cover in the player',
                      style: TextStyle(
                          color: Colors.white.withOpacity(0.66),
                          fontSize: 11.5)),
                ],
              ),
            ),
          ]),
          const SizedBox(height: 14),
          Row(
            children: [
              for (int i = 0; i < _labels.length; i++) ...[
                Expanded(
                  child: GestureDetector(
                    onTap: () async {
                      HapticService.selection();
                      await ListeningPolicy.setPlayerArtworkShape(i);
                      if (mounted) setState(() {});
                    },
                    child: AnimatedContainer(
                      duration: const Duration(milliseconds: 180),
                      height: 62,
                      decoration: BoxDecoration(
                        color: i == current
                            ? accent.withOpacity(0.12)
                            : Colors.white.withOpacity(0.04),
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(
                          color: i == current ? accent : Colors.transparent,
                          width: 1.2,
                        ),
                      ),
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          // A miniature of the actual shape rather than an icon —
                          // the choice IS the shape, so showing it is clearer than
                          // naming it.
                          Container(
                            width: 22,
                            height: 22,
                            decoration: BoxDecoration(
                              color: Colors.white.withOpacity(0.85),
                              borderRadius: BorderRadius.circular(
                                  _miniRadii[i]),
                            ),
                          ),
                          const SizedBox(height: 6),
                          Text(_labels[i],
                              style: TextStyle(
                                  color: Colors.white.withOpacity(0.75),
                                  fontSize: 10.5,
                                  fontWeight: FontWeight.w700)),
                        ],
                      ),
                    ),
                  ),
                ),
                if (i < _labels.length - 1) const SizedBox(width: 7),
              ],
            ],
          ),
        ],
      ),
    );
  }
}

class _Swatch extends StatelessWidget {
  final ({Color color, String name}) option;
  final bool selected;
  final VoidCallback onTap;

  const _Swatch(
      {required this.option, required this.selected, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          AnimatedContainer(
            duration: const Duration(milliseconds: 200),
            width: 46,
            height: 46,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              border: Border.all(
                  color: selected ? Colors.white : Colors.transparent, width: 2.5),
            ),
            padding: const EdgeInsets.all(3),
            child: Container(
              decoration: BoxDecoration(
                color: option.color,
                shape: BoxShape.circle,
                boxShadow: selected
                    ? [BoxShadow(color: option.color.withOpacity(0.45), blurRadius: 12)]
                    : const [],
              ),
              child: selected
                  ? const Icon(Icons.check_rounded, color: Colors.black, size: 18)
                  : null,
            ),
          ),
          const SizedBox(height: 6),
          Text(option.name,
              style: TextStyle(
                  color: selected
                      ? Colors.white
                      : Colors.white.withOpacity(0.66),
                  fontSize: 10.5,
                  fontWeight: selected ? FontWeight.w800 : FontWeight.w600)),
        ],
      ),
    );
  }
}

/// A miniature of Auvy — backdrop, a feed of cards, the mini player and the nav
/// bar — repainted live from [accent] and [pureBlack].
///
/// Everything here is a plain sized box: no artwork is loaded and nothing is
/// blurred, so the preview costs a handful of rects to paint and can rebuild on
/// every tap of a swatch without the frame budget noticing.
class ThemeMockup extends StatelessWidget {
  final Color accent;
  final bool pureBlack;

  const ThemeMockup({super.key, required this.accent, required this.pureBlack});

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(22),
      child: Container(
        // Tall enough for the whole chrome. At 208 the fixed rows summed to more
        // than the box, so the Spacer collapsed and the mini player and nav bar
        // were silently clipped off the bottom — the two things the preview
        // exists to show, since that's where the accent actually appears.
        height: 252,
        decoration: BoxDecoration(
          border: Border.all(color: Colors.white.withOpacity(0.08)),
          borderRadius: BorderRadius.circular(22),
        ),
        child: Stack(
          fit: StackFit.expand,
          children: [
            // The same backdrop DynamicBackground paints, so the preview is not
            // an approximation of the app — it is the app's own two states.
            if (pureBlack)
              const ColoredBox(color: Colors.black)
            else
              DecoratedBox(
                decoration: BoxDecoration(
                  gradient: RadialGradient(
                    center: const Alignment(-0.8, -0.8),
                    radius: 1.5,
                    colors: [
                      accent.withOpacity(0.15),
                      const Color(0xFF050505),
                      Colors.black,
                    ],
                  ),
                ),
              ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 10),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(children: [
                    _bar(width: 68, height: 9, opacity: 0.85),
                    const Spacer(),
                    Container(
                      width: 18,
                      height: 18,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: accent.withOpacity(0.85),
                      ),
                    ),
                  ]),
                  const SizedBox(height: 14),
                  Row(children: [
                    _card(tint: accent.withOpacity(0.30)),
                    const SizedBox(width: 10),
                    _card(tint: Colors.white.withOpacity(0.09)),
                    const SizedBox(width: 10),
                    _card(tint: Colors.white.withOpacity(0.06)),
                  ]),
                  const SizedBox(height: 12),
                  _bar(width: 92, height: 7, opacity: 0.35),
                  const SizedBox(height: 9),
                  Row(children: [
                    _tile(),
                    const SizedBox(width: 8),
                    _tile(),
                    const SizedBox(width: 8),
                    _tile(),
                    const SizedBox(width: 8),
                    _tile(),
                  ]),
                  const Spacer(),
                  // Mini player.
                  Container(
                    padding: const EdgeInsets.all(7),
                    decoration: BoxDecoration(
                      color: Colors.white.withOpacity(0.07),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Column(children: [
                      Row(children: [
                        Container(
                          width: 22,
                          height: 22,
                          decoration: BoxDecoration(
                            color: accent.withOpacity(0.75),
                            borderRadius: BorderRadius.circular(6),
                          ),
                        ),
                        const SizedBox(width: 8),
                        Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            _bar(width: 56, height: 6, opacity: 0.7),
                            const SizedBox(height: 4),
                            _bar(width: 34, height: 5, opacity: 0.28),
                          ],
                        ),
                        const Spacer(),
                        Icon(Icons.pause_rounded,
                            size: 15, color: Colors.white.withOpacity(0.8)),
                      ]),
                      const SizedBox(height: 7),
                      // Progress: the accent's most visible everyday appearance.
                      Row(children: [
                        Expanded(
                          flex: 4,
                          child: Container(
                              height: 2.5,
                              decoration: BoxDecoration(
                                  color: accent,
                                  borderRadius: BorderRadius.circular(2))),
                        ),
                        Expanded(
                          flex: 6,
                          child: Container(
                              height: 2.5,
                              decoration: BoxDecoration(
                                  color: Colors.white.withOpacity(0.14),
                                  borderRadius: BorderRadius.circular(2))),
                        ),
                      ]),
                    ]),
                  ),
                  const SizedBox(height: 10),
                  // Nav bar: the active tab carries the accent.
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                    children: [
                      Icon(Icons.home_rounded, size: 16, color: accent),
                      Icon(Icons.search_rounded,
                          size: 16, color: Colors.white.withOpacity(0.30)),
                      Icon(Icons.library_music_rounded,
                          size: 16, color: Colors.white.withOpacity(0.30)),
                    ],
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _bar({required double width, required double height, required double opacity}) =>
      Container(
        width: width,
        height: height,
        decoration: BoxDecoration(
          color: Colors.white.withOpacity(opacity),
          borderRadius: BorderRadius.circular(4),
        ),
      );

  Widget _card({required Color tint}) => Expanded(
        child: Container(
          height: 34,
          decoration: BoxDecoration(
            color: tint,
            borderRadius: BorderRadius.circular(9),
          ),
        ),
      );

  // Fixed height, not AspectRatio(1): square tiles are ~78 tall at this width,
  // which is a third of the whole preview and pushed the player off the bottom.
  Widget _tile() => Expanded(
        child: Container(
          height: 42,
          decoration: BoxDecoration(
            color: Colors.white.withOpacity(0.055),
            borderRadius: BorderRadius.circular(7),
          ),
        ),
      );
}
