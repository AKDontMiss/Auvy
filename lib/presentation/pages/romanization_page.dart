import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:auvy/presentation/widgets/settings_kit.dart';
import 'package:auvy/providers/theme_provider.dart';
import 'package:auvy/services/listening_policy.dart';
import 'package:auvy/services/romanization_service.dart';

/// Settings → Lyrics → Romanization.
///
/// SCRIPTS, NOT LANGUAGES, and the page says so, because the difference is
/// the honest limit of what this can do.
///
/// Twelve languages are commonly offered (Japanese, Korean, Russian, Ukrainian,
/// Serbian, Bulgarian, Belarusian, Macedonian…). It can, because it ships real
/// language tooling. Auvy transliterates from the script alone, and a line of
/// Cyrillic does not carry whether it is Russian or Bulgarian — the letters are
/// identical. Twelve switches where nine do nothing distinguishable would be a
/// lie the user eventually catches; three that each map to real behaviour is the
/// truthful version, and the subtitle names the languages each one covers so
/// nothing is lost in discoverability.
class RomanizationPage extends ConsumerStatefulWidget {
  const RomanizationPage({super.key});

  @override
  ConsumerState<RomanizationPage> createState() => _RomanizationPageState();
}

class _RomanizationPageState extends ConsumerState<RomanizationPage> {
  /// A short sample per script, so the toggle's effect is visible on the spot
  /// rather than only inside a song that happens to be in that script.
  static const Map<RomanizableScript, String> _samples = {
    RomanizableScript.cyrillic: 'Я люблю музыку',
    RomanizableScript.hangul: '음악을 사랑해',
    RomanizableScript.kana: 'おんがくがすき',
  };

  /// The sample line converted with the standard currently chosen for [s].
  ///
  /// Only [s] is enabled for the preview, so each row shows its own effect
  /// rather than the combined result of every switch that happens to be on.
  String _previewFor(RomanizableScript s) => RomanizationService.romanize(
        _samples[s]!,
        {s},
        kana: ListeningPolicy.kanaSystem,
        hangul: ListeningPolicy.hangulSystem,
        cyrillic: ListeningPolicy.cyrillicSystem,
      );

  void _toggle(RomanizableScript s, bool on) {
    final next = {...ListeningPolicy.romanizeScripts};
    if (on) {
      next.add(s);
    } else {
      next.remove(s);
    }
    setState(() => ListeningPolicy.romanizeScripts = next);
    ListeningPolicy.setRomanizeScripts(next);
  }

  @override
  Widget build(BuildContext context) {
    final themeColor = ref.watch(themeProvider);
    final enabled = ListeningPolicy.romanizeScripts;

    return SettingsSubPage(
      title: 'Romanization',
      header: Padding(
        padding: const EdgeInsets.fromLTRB(20, 4, 20, 16),
        child: Text(
          'Writes non-Latin lyrics in Latin letters so you can read along. '
          'Grouped by writing system, because that is what the conversion '
          'actually works from — a line of Cyrillic looks the same in Russian '
          'and Bulgarian.',
          style: TextStyle(
              color: Colors.white.withOpacity(0.72), fontSize: 12.5, height: 1.45),
        ),
      ),
      children: [
        for (final s in RomanizableScript.values) ...[
          SettingsToggleRow(
            icon: switch (s) {
              RomanizableScript.cyrillic => Icons.translate_rounded,
              RomanizableScript.hangul => Icons.language_rounded,
              RomanizableScript.kana => Icons.brush_rounded,
            },
            tint: const Color(0xFF9FA8DA),
            title: s.label,
            subtitle: s.detail,
            value: enabled.contains(s),
            onChanged: (v) => _toggle(s, v),
          ),
          // Live sample of exactly what this toggle produces. Shown only while ON
          // — a preview under an off switch invites the reading that it is
          // already doing something.
          if (enabled.contains(s)) ...[
            Padding(
              padding: const EdgeInsets.fromLTRB(62, 0, 20, 10),
              child: Row(
                children: [
                  Flexible(
                    child: Text(
                      _samples[s]!,
                      style: TextStyle(
                          color: Colors.white.withOpacity(0.66), fontSize: 13),
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 8),
                    child: Icon(Icons.arrow_forward_rounded,
                        size: 14, color: Colors.white.withOpacity(0.3)),
                  ),
                  Flexible(
                    child: Text(
                      // Through the POLICY, so the preview is literally the same
                      // code path the lyrics use. Calling the service directly
                      // here would default the standards and preview Hepburn
                      // while the song rendered Kunrei.
                      _previewFor(s),
                      style: TextStyle(
                          color: themeColor,
                          fontSize: 13,
                          fontWeight: FontWeight.w600),
                    ),
                  ),
                ],
              ),
            ),
            _SystemPicker(script: s, onChanged: () => setState(() {})),
          ],
          const SettingsDivider(),
        ],

        // Only meaningful once something is being romanised, so it stays out of
        // the way until then rather than sitting there inert.
        if (enabled.isNotEmpty)
          _AsMainRow(),

        Padding(
          padding: const EdgeInsets.fromLTRB(20, 18, 20, 8),
          child: Text(
            'A line containing kanji or Chinese characters is left exactly as it '
            'is. Reading them needs a dictionary per word rather than per '
            'character, and converting only the kana around them produces '
            'something you can read as neither language. Japanese lines written '
            'purely in kana still convert.',
            style: TextStyle(
                color: Colors.white.withOpacity(0.66),
                fontSize: 11.5,
                height: 1.45),
          ),
        ),
      ],
    );
  }
}

/// Choose the romanization STANDARD for one script.
///
/// Two chips rather than a dropdown: there are exactly two options per script,
/// both need their difference explained, and a dropdown hides the alternative
/// behind a tap, which for a setting most people have never heard of is the
/// difference between discovering it and not.
///
/// Rebuilds the PARENT through [onChanged] as well as itself, because the
/// sample line above it is what makes the choice legible and it would otherwise
/// keep showing the old standard.
class _SystemPicker extends StatelessWidget {
  const _SystemPicker({required this.script, required this.onChanged});

  final RomanizableScript script;
  final VoidCallback onChanged;

  @override
  Widget build(BuildContext context) {
    final (options, current, apply) = switch (script) {
      RomanizableScript.kana => (
          KanaSystem.values
              .map((v) => (v.label, v.detail, v == ListeningPolicy.kanaSystem, v))
              .toList(),
          ListeningPolicy.kanaSystem.label,
          (Object v) => ListeningPolicy.setKanaSystem(v as KanaSystem),
        ),
      RomanizableScript.hangul => (
          HangulSystem.values
              .map((v) =>
                  (v.label, v.detail, v == ListeningPolicy.hangulSystem, v))
              .toList(),
          ListeningPolicy.hangulSystem.label,
          (Object v) => ListeningPolicy.setHangulSystem(v as HangulSystem),
        ),
      RomanizableScript.cyrillic => (
          CyrillicSystem.values
              .map((v) =>
                  (v.label, v.detail, v == ListeningPolicy.cyrillicSystem, v))
              .toList(),
          ListeningPolicy.cyrillicSystem.label,
          (Object v) => ListeningPolicy.setCyrillicSystem(v as CyrillicSystem),
        ),
    };
    // `current` is read for its side of the record pattern only; the selected
    // flag inside each option is what drives the chips.
    assert(current.isNotEmpty);

    return Consumer(builder: (_, ref, __) {
      final themeColor = ref.watch(themeProvider);
      return Padding(
        padding: const EdgeInsets.fromLTRB(62, 0, 20, 14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            for (final (label, detail, selected, value) in options)
              Padding(
                padding: const EdgeInsets.only(bottom: 6),
                child: InkWell(
                  borderRadius: BorderRadius.circular(10),
                  onTap: selected
                      ? null
                      : () {
                          apply(value);
                          onChanged();
                        },
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 10, vertical: 7),
                    child: Row(
                      children: [
                        Icon(
                          selected
                              ? Icons.radio_button_checked_rounded
                              : Icons.radio_button_unchecked_rounded,
                          size: 16,
                          color: selected
                              ? themeColor
                              : Colors.white.withOpacity(0.32),
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(label,
                                  style: TextStyle(
                                    color: selected
                                        ? Colors.white
                                        : Colors.white.withOpacity(0.75),
                                    fontSize: 12.5,
                                    fontWeight: selected
                                        ? FontWeight.w700
                                        : FontWeight.w500,
                                  )),
                              const SizedBox(height: 1),
                              Text(detail,
                                  style: TextStyle(
                                      color: Colors.white.withOpacity(0.45),
                                      fontSize: 11,
                                      height: 1.3)),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
          ],
        ),
      );
    });
  }
}

/// "Replace the original line" — its own stateful row because the value lives in
/// a static on [ListeningPolicy], so nothing else would rebuild the switch.
class _AsMainRow extends ConsumerStatefulWidget {
  @override
  ConsumerState<_AsMainRow> createState() => _AsMainRowState();
}

class _AsMainRowState extends ConsumerState<_AsMainRow> {
  @override
  Widget build(BuildContext context) {
    return SettingsToggleRow(
      icon: Icons.swap_vert_rounded,
      tint: const Color(0xFF80DEEA),
      title: 'Show romanization as the main line',
      // Both modes are genuinely wanted: under-the-line lets you follow the
      // original while checking pronunciation; replacing it is what you want when
      // the script is unreadable to you and the original is just noise.
      subtitle: 'Off: shown underneath the original',
      value: ListeningPolicy.romanizeAsMain,
      onChanged: (v) {
        setState(() => ListeningPolicy.romanizeAsMain = v);
        ListeningPolicy.setRomanizeAsMain(v);
      },
    );
  }
}
