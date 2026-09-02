import 'package:flutter_test/flutter_test.dart';

import 'package:auvy/services/romanization_service.dart';

import 'helpers/source_text.dart';

/// Selectable romanization standards.
///
/// The feature started as "romanization doesn't work". Investigation on device
/// showed the toggles persisting correctly (`romanize loaded: stored=[kana,
/// hangul, cyrillic] active=[...] asMain=true`) and the converter running — so
/// the complaint was about the OUTPUT, not the plumbing. Two real problems:
///
///  * a Japanese lyric came back as `君no声ga聞koeru`, a kana/kanji hybrid that is
///    harder to read than the original;
///  * there was exactly one standard per script, and which one is correct
///    depends on why you are reading it.
///
/// This file covers the second. Each standard is pinned by an example whose
/// spelling is the whole point of choosing it.
void main() {
  group('Japanese', () {
    const line = 'しんじつをちかう';

    test('Hepburn spells it the way an English speaker would say it', () {
      expect(
        RomanizationService.romanize(line, {RomanizableScript.kana}),
        'shinjitsuwochikau',
      );
    });

    test('Kunrei-shiki keeps the kana columns regular', () {
      // し/ち/つ are one series each in Japanese even though English hears three
      // different sounds. That regularity is the reason to pick this.
      expect(
        RomanizationService.romanize(line, {RomanizableScript.kana},
            kana: KanaSystem.kunrei),
        'sinzituwotikau',
      );
    });

    test('Kunrei falls back to Hepburn for kana it does not override', () {
      // The Kunrei table is deliberately a small override map, not a full
      // duplicate — a second complete table would drift from the first.
      expect(
        RomanizationService.romanize('かきくけこ', {RomanizableScript.kana},
            kana: KanaSystem.kunrei),
        'kakikukeko',
      );
    });

    test('the small-tsu rule survives the system switch', () {
      // きって is "kitte", never "kitsute". It is computed from the FOLLOWING
      // kana, so it has to be re-derived under whichever table is active.
      expect(RomanizationService.romanize('きって', {RomanizableScript.kana}),
          'kitte');
      expect(
        RomanizationService.romanize('きって', {RomanizableScript.kana},
            kana: KanaSystem.kunrei),
        'kitte',
      );
    });
  });

  group('Korean', () {
    const line = '부산 전주 거리';

    test('Revised Romanization is the South Korean official spelling', () {
      expect(
        RomanizationService.romanize(line, {RomanizableScript.hangul}),
        'busan jeonju geori',
      );
    });

    test('McCune-Reischauer devoices the onsets and uses breves', () {
      // Busan/Pusan is the recognisable difference between the two systems.
      expect(
        RomanizationService.romanize(line, {RomanizableScript.hangul},
            hangul: HangulSystem.mccune),
        'pusan chŏnchu kŏri',
      );
    });

    test('both systems share one finals table', () {
      // The coda inventory collapses to the same seven sounds either way, so a
      // second table would only be a chance to disagree.
      final svc = codeOf('lib/services/romanization_service.dart');
      expect(svc.contains('_hangulFinalMr'), isFalse,
          reason: 'A separate MR finals table appeared. The codas are identical '
              'in both systems — two tables can only drift apart.');
    });
  });

  group('Cyrillic', () {
    const line = 'Живу щедро, чужой';

    test('practical stays readable without diacritics', () {
      expect(
        RomanizationService.romanize(line, {RomanizableScript.cyrillic}),
        'Zhivu shchedro, chuzhoy',
      );
    });

    test('ISO 9 is one sign per letter, so it is reversible', () {
      expect(
        RomanizationService.romanize(line, {RomanizableScript.cyrillic},
            cyrillic: CyrillicSystem.scientific),
        'Živu ŝedro, čužoj',
      );
    });

    test('ISO 9 falls back for letters it does not redefine', () {
      // а/б/в are the same in both, and only the differences are listed.
      expect(
        RomanizationService.romanize('абв', {RomanizableScript.cyrillic},
            cyrillic: CyrillicSystem.scientific),
        'abv',
      );
    });
  });

  group('the defaults are the ones the UI claims', () {
    test('omitting a system gives the documented default', () {
      // romanize() defaults all three parameters. Any call site that forgets one
      // must still render what the settings screen previews.
      expect(
        RomanizationService.romanize('しちつ', {RomanizableScript.kana}),
        RomanizationService.romanize('しちつ', {RomanizableScript.kana},
            kana: KanaSystem.hepburn),
      );
      expect(KanaSystem.values.first, KanaSystem.hepburn);
      expect(HangulSystem.values.first, HangulSystem.revised);
      expect(CyrillicSystem.values.first, CyrillicSystem.practical);
    });

    test('the render goes through the policy, not the service', () {
      // THE TRAP THIS GUARDS. romanize() defaults its three systems, so calling
      // the service directly compiles, runs, and silently renders Hepburn while
      // the settings screen previews Kunrei. Every render path must go through
      // ListeningPolicy.romanizeLine, which supplies the user's choices.
      final list = codeOf('lib/presentation/widgets/synced_lyrics_list.dart');
      expect(list.contains('ListeningPolicy.romanizeLine('), isTrue,
          reason: 'The lyrics list no longer romanises through the policy.');
      expect(list.contains('RomanizationService.romanize('), isFalse,
          reason: 'A direct service call came back in the render path. It will '
              'ignore the chosen standard without failing.');
    });

    test('every choice is persisted by NAME', () {
      // An index would repoint at a different system the moment one is added.
      final policy = codeOf('lib/services/listening_policy.dart');
      for (final k in [
        'auvy_romanize_kana_system',
        'auvy_romanize_hangul_system',
        'auvy_romanize_cyrillic_system',
      ]) {
        expect(policy.contains("'$k'"), isTrue, reason: '$k is not persisted.');
      }
      expect(policy.contains('setString(kKanaSystem, v.key)'), isTrue,
          reason: 'The kana system is stored as something other than its name.');
    });

    test('the choices are in the cloud backup set', () {
      final sync = codeOf('lib/services/cloud_sync_service.dart');
      expect(sync.contains('auvy_romanize_kana_system'), isTrue);
      expect(sync.contains('auvy_romanize_hangul_system'), isTrue);
      expect(sync.contains('auvy_romanize_cyrillic_system'), isTrue);
    });
  });
  group('a line with kanji is left entirely alone', () {
    // THE OTHER HALF OF "romanisation does not work", and not about standards
    // at all. Kanji readings are context-dependent, so the service converted
    // the kana around them and left the kanji — on real lyrics that produces a
    // string readable as neither language.

    test('a real Japanese lyric comes back untouched', () {
      const line = '君の声が聞こえる 夜空に';
      expect(
        RomanizationService.romanize(line, {RomanizableScript.kana}),
        line,
        reason: 'It produced 君no声ga聞koeru again — the hybrid this rule exists '
            'to prevent.',
      );
    });

    test('katakana next to a single kanji is still suppressed', () {
      // ラーメンを食べたい: mostly kana, one kanji. Converting around it gives
      // 'ramenwo食betai', which is the same failure in miniature.
      const line = 'ラーメンを食べたい';
      expect(RomanizationService.romanize(line, {RomanizableScript.kana}), line);
    });

    test('a kana-only line still converts', () {
      // Choruses and titles are often pure kana, and those are exactly the
      // lines this can handle correctly. The rule must not cost them.
      expect(
        RomanizationService.romanize('きみのこえがきこえる', {RomanizableScript.kana}),
        'kiminokoegakikoeru',
      );
    });

    test('Chinese comes back untouched rather than mangled', () {
      // Never attempted (no pinyin table shipped), and it falls under the same
      // ideograph rule, so it cannot be half-converted by an enabled kana
      // toggle either.
      const line = '我爱你 这是我的心';
      expect(
        RomanizationService.romanize(line, {
          RomanizableScript.kana,
          RomanizableScript.hangul,
          RomanizableScript.cyrillic,
        }),
        line,
      );
    });

    test('ONLY kana is suppressed, not the other scripts', () {
      // A line mixing Cyrillic with an ideograph must still romanise the
      // Cyrillic: neither Cyrillic nor Hangul is ambiguous, so there is no
      // reason for a stray kanji to disable them.
      expect(
        RomanizationService.romanize('Привет 世界', {
          RomanizableScript.kana,
          RomanizableScript.cyrillic,
        }),
        'Privet 世界',
      );
    });

    test('canRomanize does not promise what romanize will refuse', () {
      // canRomanize gates whether the feature is offered at all. It reports on
      // the SCRIPTS present, so a kanji line with kana in it still says true —
      // correct, because the same lyric may well have kana-only lines that do
      // convert. Pinned so the two are changed together deliberately.
      expect(RomanizationService.canRomanize('君の声'), isTrue);
      expect(RomanizationService.canRomanize('我爱你'), isFalse,
          reason: 'Chinese has no convertible script, so romanisation should '
              'not be offered for it at all.');
    });
  });
  group('the decision is made once for the SONG, not per line', () {
    // Caught on device, not in a test. The per-line rule is right for the line
    // and wrong for the page:
    //
    //   LT romanize: lines=33 detected=kana applied=kana changedLines=6/33
    //
    // Six lines happened to be pure kana and became romaji; the other 27 kept
    // their kanji. With "show romanization as the main line" on, that is a page
    // of Japanese with six romaji lines scattered through it.

    test('hasIdeograph sees a kanji anywhere in the text', () {
      expect(RomanizationService.hasIdeograph('きみのこえ'), isFalse);
      expect(RomanizationService.hasIdeograph('きみの声'), isTrue);
      expect(RomanizationService.hasIdeograph('我爱你'), isTrue);
      expect(RomanizationService.hasIdeograph('Hello there'), isFalse);
    });

    test('one kanji anywhere drops kana for the whole lyric', () {
      // The lyric as the widget joins it: mostly kana lines, one with a kanji.
      const whole = 'きみのこえ きみの声 こえがきこえる';
      expect(RomanizationService.hasIdeograph(whole), isTrue,
          reason: 'the fixture must contain a kanji for this to mean anything');

      // A pure-kana LINE from that lyric must now be left alone too, because
      // the song it belongs to is going to stay in Japanese.
      final scripts = <RomanizableScript>{RomanizableScript.kana}
          .where((s) => !RomanizationService.hasIdeograph(whole))
          .toSet();
      expect(RomanizationService.romanize('きみのこえ', scripts), 'きみのこえ',
          reason: 'A kana-only line still converted while the rest of the song '
              'did not, which is the jumble this rule removes.');
    });

    test('an all-kana lyric still converts', () {
      // The rule must not cost the songs it can actually handle.
      const whole = 'きみのこえ こえがきこえる';
      expect(RomanizationService.hasIdeograph(whole), isFalse);
      expect(
        RomanizationService.romanize('きみのこえ', {RomanizableScript.kana}),
        'kiminokoe',
      );
    });

    test('only KANA is dropped — Cyrillic and Hangul are unaffected', () {
      // Neither is ambiguous, so a stray CJK character in a Russian or Korean
      // lyric must not stop those converting.
      expect(
        RomanizationService.romanize('Привет 世界', {
          RomanizableScript.cyrillic,
          RomanizableScript.hangul,
        }),
        'Privet 世界',
      );
    });

    test('the widget decides once and reuses it', () {
      // Recomputing per line would walk the whole lyric for every visible row,
      // several times a second.
      final list = codeOf('lib/presentation/widgets/synced_lyrics_list.dart');
      expect(list.contains('_scriptsForCurrentLyric()'), isTrue);
      expect(list.contains('scripts: lyricScripts'), isTrue,
          reason: 'Lines are romanised without the song-wide decision again.');
    });

    test('the policy exposes the song-wide decision', () {
      final policy = codeOf('lib/services/listening_policy.dart');
      expect(policy.contains('scriptsForLyric(String wholeText)'), isTrue);
    });
  });
}
