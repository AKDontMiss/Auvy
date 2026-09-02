// Functional verification of RomanizationService against real lyric lines.
//
// The service is pure Dart (no Flutter imports), so it can be executed directly
// rather than only read. Expectations are the standard romanizations: Revised
// Romanization for Hangul, Hepburn for kana, BGN/PCGN-ish for Cyrillic.
import 'package:auvy/services/romanization_service.dart';

const all = {
  RomanizableScript.cyrillic,
  RomanizableScript.hangul,
  RomanizableScript.kana,
};

int failures = 0;

void check(String label, String input, String expected,
    {Set<RomanizableScript> enabled = all}) {
  final got = RomanizationService.romanize(input, enabled);
  final ok = got.toLowerCase() == expected.toLowerCase();
  if (!ok) failures++;
  print('${ok ? "PASS" : "FAIL"}  $label\n'
      '      in:  $input\n'
      '      got: $got\n'
      '      exp: $expected');
}

void main() {
  print('=== HANGUL (Unicode syllable arithmetic) ===');
  // Plain open syllables.
  check('hangul: 사랑 (love)', '사랑', 'sarang');
  check('hangul: 안녕', '안녕', 'annyeong');
  // Final consonant (jongseong) present.
  check('hangul: 한국', '한국', 'hanguk');
  // Compound/complex vowels.
  check('hangul: 예쁘다', '예쁘다', 'yeppeuda');
  // Mixed with latin — latin must pass through untouched.
  check('hangul+latin: 나의 Love', '나의 Love', 'naui Love');

  print('\n=== KANA (digraphs before single chars, small-tsu doubling) ===');
  check('kana: こんにちは', 'こんにちは', 'konnichiha');
  // Digraph: きょ must be "kyo", not "kiyo".
  check('kana digraph: きょう', 'きょう', 'kyou');
  // Small tsu must double the FOLLOWING consonant.
  check('kana small-tsu: がっこう', 'がっこう', 'gakkou');
  // Katakana.
  check('katakana: サクラ', 'サクラ', 'sakura');
  check('katakana digraph: ジャズ', 'ジャズ', 'jazu');

  print('\n=== CYRILLIC ===');
  check('cyrillic: Москва', 'Москва', 'Moskva');
  check('cyrillic: привет', 'привет', 'privet');
  check('cyrillic: Ялта (ya/ja)', 'Ялта', 'Yalta');

  print('\n=== TOGGLES: a disabled script must be left ALONE ===');
  check('hangul disabled', '사랑',
      '사랑', enabled: {RomanizableScript.kana});
  check('kana disabled', 'サクラ',
      'サクラ', enabled: {RomanizableScript.cyrillic});
  check('all disabled', 'Москва 사랑 サクラ',
      'Москва 사랑 サクラ', enabled: {});

  print('\n=== DELIBERATELY UNTOUCHED: kanji / Chinese ===');
  check('kanji passthrough', '愛してる', '愛shiteru');
  check('chinese passthrough', '我爱你', '我爱你');

  print('\n=== canRomanize gating ===');
  for (final e in [
    ['사랑', true],
    ['サクラ', true],
    ['Москва', true],
    ['Hello world', false],
    ['我爱你', false],
    ['', false],
  ]) {
    final got = RomanizationService.canRomanize(e[0] as String);
    final ok = got == e[1];
    if (!ok) failures++;
    print('${ok ? "PASS" : "FAIL"}  canRomanize("${e[0]}") = $got '
        '(expected ${e[1]})');
  }

  print('\n${failures == 0 ? "ALL PASSED" : "$failures FAILURE(S)"}');
}
