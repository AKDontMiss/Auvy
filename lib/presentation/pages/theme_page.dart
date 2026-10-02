import 'package:flutter/material.dart';
import 'package:auvy/presentation/widgets/auvy_pill.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:auvy/presentation/widgets/settings_kit.dart';
import 'package:auvy/providers/theme_provider.dart';
import 'package:auvy/providers/haptics_provider.dart';
import 'package:auvy/providers/mini_player_style_provider.dart';
import 'package:auvy/providers/density_provider.dart';
import 'package:auvy/presentation/pages/settings_page.dart';
import 'package:auvy/services/haptic_service.dart';
import 'package:auvy/services/listening_policy.dart';

// Theme: accent, pure black, artwork shape and the rest of Appearance.
//
// The live mockup is the key idea: a miniature of the app that repaints as you
// choose, so a colour is judged against the places it appears (nav pill,
// progress, section accents).
//
// Not offered:
//  • Light / system mode. Auvy paints white-on-dark everywhere, so a light theme
//    would be a repaint of the whole app, not a setting.
//  • An artwork-derived accent here. The accent chosen on this page also sets the
//    launcher icon (AppIconService.applyForAccent); following the artwork is a
//    separate setting that doesn't touch the icon.

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
              const SizedBox(height: 16),
              _ColorGrid(
                colors: [for (final o in kAccentOptions) (color: o.color, label: o.name)],
                perRow: kAccentOptions.length,
                isSelected: (c) =>
                    !ref.watch(dynamicAccentProvider) && accent.value == c.value,
                onPick: (c) {
                  if (ref.read(dynamicAccentProvider)) {
                    ref.read(dynamicAccentProvider.notifier).set(false);
                  }
                  ref.read(themeProvider.notifier).setThemeColor(c);
                },
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

        // Appearance-only settings (the progress-bar style and haptics) live here rather
        // than in Settings, which holds the functional switches; this page can show the
        // slider style as a live preview grid.
        // Pure black sits with the switches, not in the colour grid: it's a mode that
        // overrides whichever colour is selected.
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
        // The player's own look first, then what reaches every list and cover.
        const _PlayerControlsColorBlock(),
        const SliderStyleBlock(),
        const _ArtworkShapeBlock(),
        const _ArtworkGlowBlock(),
        const _PlayerBackgroundStyleBlock(),
        const _MiniPlayerStyleBlock(),
        const _ArtworkRoundnessBlock(),
        const _DensityBlock(),

        // Lyrics appearance: size, centring, romanisation and the share-line count.
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

/// List spacing. Labelled "lists" rather than "UI" because that is honestly what
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
                  const Text('List spacing',
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

/// Mini-player style: four looks for the same bar (see [MiniPlayerMetrics]).
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
                  const Text('Mini-player style',
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
          // Miniatures rather than names alone: each is drawn from the same
          // metrics as the real bar, so a preview can't drift from what tapping
          // it produces.
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

/// A ~1/3-scale sketch of the mini-player: surface, cover, two text bars, the
/// controls and where progress goes, all read from the same [MiniPlayerMetrics]
/// the real bar uses.
class _MiniPreview extends StatelessWidget {
  final MiniPlayerMetrics metrics;
  final Color accent;
  const _MiniPreview({required this.metrics, required this.accent});

  @override
  Widget build(BuildContext context) {
    const scale = 0.36;
    final m = metrics;
    final h = m.height * scale;
    final art = m.artwork * scale;
    final radius = (m.pill ? m.height / 2 : m.radius) * scale;
    final onCover = m.surface == MiniSurface.cover;
    // A sample cover colour for the preview: the accent's opposite hue, dark,
    // so it reads as "some other colour" next to the accent.
    final hsl = HSLColor.fromColor(accent);
    final sample = hsl.withHue((hsl.hue + 150) % 360).withLightness(0.24).toColor();
    final ink = onCover ? Colors.white : accent;
    Widget dot(double size, Color color, {bool ring = false}) => Container(
          width: size,
          height: size,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: ring ? Colors.transparent : color,
            border: ring ? Border.all(color: accent, width: 1.1) : null,
          ),
        );
    return SizedBox(
      width: 44,
      height: 28,
      child: Center(
        child: Container(
          width: 44 - m.horizontalMargin * scale * 2,
          height: h,
          clipBehavior: Clip.antiAlias,
          decoration: BoxDecoration(
            color: onCover ? sample : Colors.white.withOpacity(0.10),
            borderRadius: BorderRadius.circular(radius),
            border: Border.all(
                color: m.surface == MiniSurface.lit
                    ? accent.withOpacity(0.55)
                    : Colors.white.withOpacity(0.16),
                width: 0.6),
          ),
          child: Stack(
            children: [
              if (m.progress == MiniProgress.fill)
                FractionallySizedBox(
                  widthFactor: 0.45,
                  heightFactor: 1,
                  alignment: Alignment.centerLeft,
                  child: ColoredBox(color: accent.withOpacity(0.35)),
                ),
              Row(
                children: [
                  SizedBox(width: (h - art) / 2 + 0.5),
                  Container(
                    width: art,
                    height: art,
                    decoration: BoxDecoration(
                      color: accent.withOpacity(0.85),
                      borderRadius: BorderRadius.circular(m.artworkRadius * scale),
                    ),
                  ),
                  const SizedBox(width: 2.5),
                  Expanded(
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Container(height: 1.8, width: 12, color: Colors.white.withOpacity(0.55)),
                        const SizedBox(height: 2),
                        Container(height: 1.4, width: 8, color: Colors.white.withOpacity(0.28)),
                      ],
                    ),
                  ),
                  if (m.showLike) ...[dot(2.6, ink.withOpacity(0.9)), const SizedBox(width: 1.6)],
                  m.progress == MiniProgress.ring
                      ? dot(5.5, accent, ring: true)
                      : dot(5, Colors.white.withOpacity(0.8)),
                  if (m.showNext) ...[const SizedBox(width: 1.6), dot(2.4, Colors.white.withOpacity(0.5))],
                  SizedBox(width: m.pill ? 4 : 3),
                ],
              ),
              if (m.progress == MiniProgress.bottomLine)
                Positioned(
                  left: 4,
                  bottom: 0,
                  child: Container(width: 12, height: 1, color: ink),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Global cover-art roundness, applied everywhere artwork appears because it's
/// applied inside `AuvyImage`. A multiplier on each surface's own radius (see
/// [ListeningPolicy.artworkRoundness]).
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
        ? 'Square'
        : (v < 0.85
            ? 'Less rounded'
            : (v <= 1.15 ? 'Default' : (v < 1.7 ? 'More rounded' : 'Very rounded')));

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
                  const Text('Cover corners',
                      style: TextStyle(
                          color: Colors.white,
                          fontWeight: FontWeight.w600,
                          fontSize: 14.5)),
                  const SizedBox(height: 2),
                  // The player's cover is the one exception: it has its own
                  // shape setting.
                  Text('$label · covers in lists, grids and the mini-player',
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
                  const Text('Cover shape in the player',
                      style: TextStyle(
                          color: Colors.white,
                          fontWeight: FontWeight.w600,
                          fontSize: 14.5)),
                  const SizedBox(height: 2),
                  Text('${_labels[current]} · the big cover on the Now Playing screen',
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

/// Colour circles in even rows, [perRow] to a row and named underneath. Each
/// takes an equal share of the width (up to [_maxSize]), so a row always fits a
/// narrow phone without wrapping unevenly.
class _ColorGrid extends StatelessWidget {
  final List<({Color color, String label})> colors;
  final int perRow;
  final bool Function(Color) isSelected;
  final ValueChanged<Color> onPick;

  const _ColorGrid({
    required this.colors,
    required this.perRow,
    required this.isSelected,
    required this.onPick,
  });

  static const double _maxSize = 46;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(builder: (context, box) {
      final size = (box.maxWidth / perRow - 12).clamp(28.0, _maxSize);
      return Column(
        children: [
          for (int start = 0; start < colors.length; start += perRow) ...[
            if (start > 0) const SizedBox(height: 12),
            Row(
              children: [
                for (int i = start; i < start + perRow; i++)
                  Expanded(
                    child: i < colors.length
                        ? _swatch(colors[i], isSelected(colors[i].color), size)
                        : const SizedBox.shrink(),
                  ),
              ],
            ),
          ],
        ],
      );
    });
  }

  Widget _swatch(({Color color, String label}) c, bool selected, double size) {
    final dark = c.color.computeLuminance() < 0.05;
    final light = ThemeData.estimateBrightnessForColor(c.color) == Brightness.light;
    return Semantics(
      label: c.label,
      selected: selected,
      button: true,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () {
          HapticService.selection();
          onPick(c.color);
        },
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            AnimatedContainer(
              duration: const Duration(milliseconds: 200),
              width: size,
              height: size,
              padding: const EdgeInsets.all(3),
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                border: Border.all(
                    color: selected ? Colors.white : Colors.transparent, width: 2.5),
              ),
              child: Container(
                decoration: BoxDecoration(
                  color: c.color,
                  shape: BoxShape.circle,
                  // Black needs an outline to be seen on the dark card at all.
                  border: dark && !selected ? Border.all(color: Colors.white24) : null,
                  boxShadow: selected
                      ? [
                          BoxShadow(
                              color: (dark ? Colors.white : c.color).withOpacity(0.45),
                              blurRadius: 12)
                        ]
                      : const [],
                ),
                child: selected
                    ? Icon(Icons.check_rounded,
                        color: light ? Colors.black : Colors.white, size: size * 0.4)
                    : null,
              ),
            ),
            const SizedBox(height: 5),
            Text(c.label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                    color: selected ? Colors.white : Colors.white.withOpacity(0.66),
                    fontSize: 10.5,
                    fontWeight: selected ? FontWeight.w800 : FontWeight.w600)),
          ],
        ),
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

class _PlayerControlsColorBlock extends ConsumerWidget {
  const _PlayerControlsColorBlock();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final themeColor = ref.watch(themeProvider);
    final controlsState = ref.watch(playerControlsColorProvider);
    final resolvedColor = ref.watch(resolvedControlsColorProvider);
    final notifier = ref.read(playerControlsColorProvider.notifier);

    final List<({String label, String mode})> modes = [
      (label: 'Pure White (Default)', mode: 'white'),
      (label: 'App Accent', mode: 'accent'),
      (label: 'Song Artwork', mode: 'artwork'),
      (label: 'Custom Colour', mode: 'custom'),
    ];

    // Ten, so they sit in two even rows of five at a size that is easy to tap.
    const List<({Color color, String name, String tag})> swatches = [
      (color: Color(0xFFFF1744), name: 'Ruby Flame', tag: 'Ruby'),
      (color: Color(0xFFFF6D00), name: 'Amber Orange', tag: 'Orange'),
      (color: Color(0xFFFFD600), name: 'Solar Gold', tag: 'Gold'),
      (color: Color(0xFFAEEA00), name: 'Acid Lime', tag: 'Lime'),
      (color: Color(0xFF00C853), name: 'Botanical Emerald', tag: 'Emerald'),
      (color: Color(0xFF00E5FF), name: 'Electric Cyan', tag: 'Cyan'),
      (color: Color(0xFF2979FF), name: 'Cobalt Royal', tag: 'Royal'),
      (color: Color(0xFF7C4DFF), name: 'Amethyst Violet', tag: 'Violet'),
      (color: Color(0xFFFF007F), name: 'Hot Magenta', tag: 'Magenta'),
      (color: Color(0xFF000000), name: 'Pitch Black', tag: 'Black'),
    ];

    final bool isControlsBlack =
        resolvedColor.toARGB32() == 0xFF000000 || resolvedColor.computeLuminance() < 0.05;
    final bool isLight =
        ThemeData.estimateBrightnessForColor(resolvedColor) == Brightness.light;
    final Color playIconColor = isLight ? Colors.black : Colors.white;
    final Color previewPeripheralColor = isControlsBlack ? Colors.white : resolvedColor;

    final matchedSwatch = swatches
        .where((s) => s.color.toARGB32() == controlsState.customColor.toARGB32())
        .firstOrNull;
    final customName = matchedSwatch != null ? matchedSwatch.name : 'Custom';

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              SettingsIconChip(
                  icon: Icons.play_circle_filled_rounded,
                  tint: isControlsBlack ? Colors.white : resolvedColor),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text('Player controls colour',
                        style: TextStyle(
                            color: Colors.white,
                            fontWeight: FontWeight.w600,
                            fontSize: 14.5)),
                    const SizedBox(height: 2),
                    Text(
                      controlsState.mode == 'custom'
                          ? '$customName · your own colour'
                          : 'Play, skip, repeat, queue and like buttons',
                      style: TextStyle(
                          color: Colors.white.withValues(alpha: 0.66),
                          fontSize: 11.5),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 14),

          // Live mini preview row
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            decoration: BoxDecoration(
              color: Colors.white.withValues(alpha: 0.05),
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: Colors.white.withValues(alpha: 0.08)),
            ),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceEvenly,
              children: [
                Icon(Icons.repeat_rounded,
                    color: previewPeripheralColor.withValues(alpha: 0.8), size: 20),
                Icon(Icons.skip_previous_rounded, color: previewPeripheralColor, size: 26),
                Container(
                  width: 38,
                  height: 38,
                  decoration: BoxDecoration(
                    color: resolvedColor,
                    shape: BoxShape.circle,
                    border: isControlsBlack
                        ? Border.all(color: Colors.white.withValues(alpha: 0.35), width: 1.2)
                        : null,
                    boxShadow: [
                      BoxShadow(
                        color: isControlsBlack
                            ? Colors.white.withValues(alpha: 0.16)
                            : resolvedColor.withValues(alpha: 0.4),
                        blurRadius: 12,
                        spreadRadius: 1,
                      ),
                    ],
                  ),
                  child: Icon(Icons.play_arrow_rounded,
                      color: playIconColor, size: 24),
                ),
                Icon(Icons.skip_next_rounded, color: previewPeripheralColor, size: 26),
                Icon(Icons.queue_music_rounded,
                    color: previewPeripheralColor.withValues(alpha: 0.8), size: 20),
                Icon(Icons.favorite_rounded, color: previewPeripheralColor, size: 20),
              ],
            ),
          ),
          const SizedBox(height: 14),

          // Primary mode chips
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: modes.map((m) {
              final selected = controlsState.mode == m.mode;
              return AuvyPill(
                label: m.label,
                selected: selected,
                accent: themeColor,
                onTap: () => notifier.setMode(m.mode),
              );
            }).toList(),
          ),
          const SizedBox(height: 14),

          Text(
            'OR PICK YOUR OWN COLOUR',
            style: TextStyle(
              color: Colors.white.withValues(alpha: 0.5),
              fontSize: 10,
              fontWeight: FontWeight.w700,
              letterSpacing: 1.2,
            ),
          ),
          const SizedBox(height: 10),
          // Picking a colour switches to Custom, so no separate step is needed.
          _ColorGrid(
            colors: [for (final c in swatches) (color: c.color, label: c.tag)],
            perRow: 5,
            isSelected: (c) =>
                controlsState.mode == 'custom' &&
                controlsState.customColor.toARGB32() == c.toARGB32(),
            onPick: notifier.setCustomColor,
          ),
        ],
      ),
    );
  }
}


class _ArtworkGlowBlock extends ConsumerWidget {
  const _ArtworkGlowBlock();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final accent = ref.watch(themeProvider);
    final glowMode = ref.watch(artworkGlowModeProvider);
    final notifier = ref.read(artworkGlowModeProvider.notifier);

    // A light in the cover's colour behind the player's cover art. The names say
    // what it does, not what it is called in the code.
    final options = [
      (mode: 'reactive', label: 'With the music', desc: 'Lights up and pulses only while sound plays'),
      (mode: 'vibrant', label: 'Bright', desc: 'Always on, and swells with the music'),
      (mode: 'subtle', label: 'Soft', desc: 'A faint, steady glow that never moves'),
      (mode: 'off', label: 'Off', desc: 'Just a shadow, no colour'),
    ];

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              SettingsIconChip(icon: Icons.blur_on_rounded, tint: accent),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text('Glow around the player cover',
                        style: TextStyle(
                            color: Colors.white,
                            fontWeight: FontWeight.w600,
                            fontSize: 14.5)),
                    const SizedBox(height: 2),
                    Text(
                      options.firstWhere((o) => o.mode == glowMode, orElse: () => options[0]).desc,
                      style: TextStyle(
                          color: Colors.white.withValues(alpha: 0.66),
                          fontSize: 11.5),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 14),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: options.map((opt) {
              final selected = glowMode == opt.mode;
              return AuvyPill(
                label: opt.label,
                selected: selected,
                accent: accent,
                onTap: () => notifier.setGlow(opt.mode),
              );
            }).toList(),
          ),
        ],
      ),
    );
  }
}

class _PlayerBackgroundStyleBlock extends ConsumerWidget {
  const _PlayerBackgroundStyleBlock();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final accent = ref.watch(themeProvider);
    final bgStyle = ref.watch(playerBackgroundStyleProvider);
    final notifier = ref.read(playerBackgroundStyleProvider.notifier);

    final pureBlack = ref.watch(pureBlackProvider);
    // What fills the Now Playing screen behind the cover and controls.
    final options = [
      (style: 'blurred', label: 'Blurred cover', desc: "The song's cover, blurred, fills the screen"),
      (style: 'radial', label: 'Soft glow', desc: "The cover's colour glows softly behind it"),
      (style: 'aurora', label: 'Two-tone', desc: "Two shades of the cover's colour, corner to corner"),
      (style: 'black', label: 'Black', desc: 'Plain black, which saves battery on an OLED screen'),
    ];

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              SettingsIconChip(icon: Icons.wallpaper_rounded, tint: accent),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text('Player background',
                        style: TextStyle(
                            color: Colors.white,
                            fontWeight: FontWeight.w600,
                            fontSize: 14.5)),
                    const SizedBox(height: 2),
                    // Pure black overrides this, so say so instead of offering
                    // choices that would silently do nothing.
                    Text(
                      pureBlack
                          ? 'Black while Pure black is on'
                          : options.firstWhere((o) => o.style == bgStyle, orElse: () => options[0]).desc,
                      style: TextStyle(
                          color: Colors.white.withValues(alpha: 0.66),
                          fontSize: 11.5),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 14),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: options.map((opt) {
              final selected = bgStyle == opt.style;
              return AuvyPill(
                label: opt.label,
                selected: selected,
                accent: accent,
                onTap: () => notifier.setStyle(opt.style),
              );
            }).toList(),
          ),
        ],
      ),
    );
  }
}
