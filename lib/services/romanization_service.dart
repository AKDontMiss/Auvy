/// Romanises non-Latin lyrics so they can be read (and sung along to) by someone
/// who doesn't read the script.
///
/// SCRIPT toggles, not LANGUAGE toggles, and that is deliberate.
///
/// A per-language list is the usual shape (Japanese, Korean, Russian, Ukrainian,
/// Serbian, Bulgarian…). It can afford to, because it ships real language
/// tooling. Auvy transliterates from the SCRIPT alone, and a line of Cyrillic
/// does not say whether it is Russian or Bulgarian — the letters are the same.
/// Offering "Bulgarian" as a switch would imply a distinction this code cannot
/// make, and the user would eventually catch it doing nothing. Three honest
/// switches beat twelve dishonest ones.
///
/// WHAT IS AND ISN'T COVERED, plainly:
///  • **Cyrillic** → Latin. Table-driven and reliable; covers Russian, Ukrainian,
///    Serbian, Bulgarian, Belarusian, Macedonian with one table.
///  • **Hangul** → Revised Romanization. Computed from Unicode's syllable
///    structure, so it works for every syllable rather than a word list. Does NOT
///    apply inter-syllable assimilation (한국말 → "hangukmal", where strict RR
///    gives "hangungmal"); within a syllable it is exact.
///  • **Kana** → romaji. Hiragana and katakana, including the small-tsu doubling
///    and the katakana long mark.
///  • **A line containing kanji is left ENTIRELY alone.** Mapping 漢字 to a
///    reading needs a morphological dictionary (kuromoji is the usual choice);
///    guessing per character would produce confident nonsense. The earlier
///    behaviour was to convert the kana anyway and call the result "honest
///    about what was understood", but 君の声が聞こえる came back as
///    君no声ga聞koeru, which cannot be read as either language. A kana-only
///    line (common in choruses and in song titles) still converts.
///  • **Chinese is not attempted at all** — every character needs a lookup, and
///    without a shipped pinyin table there is nothing to look up. It falls under
///    the same ideograph rule, so it comes back untouched rather than mangled.
library;

class RomanizationService {
  RomanizationService._();

  // Script detection
  // Ranges, not language guesses. Cheap enough to run per line while scrolling.

  static bool _isCyrillic(int c) =>
      (c >= 0x0400 && c <= 0x04FF) || (c >= 0x0500 && c <= 0x052F);

  /// Pre-composed Hangul syllables. Standalone Jamo (0x1100 block) are rare in
  /// lyrics and are left alone rather than half-handled.
  static bool _isHangulSyllable(int c) => c >= 0xAC00 && c <= 0xD7A3;

  static bool _isKana(int c) =>
      (c >= 0x3040 && c <= 0x309F) || // hiragana
      (c >= 0x30A0 && c <= 0x30FF); // katakana (incl. ー)

  /// CJK ideographs: kanji, and Chinese hanzi, which occupy the same block.
  static bool _isIdeograph(int c) =>
      (c >= 0x4E00 && c <= 0x9FFF) || (c >= 0x3400 && c <= 0x4DBF);

  /// True when [text] contains anything this service could actually convert.
  /// Used to decide whether to offer/apply romanisation at all, so a Latin-script
  /// song never pays for it.
  static bool canRomanize(String text) {
    for (final c in text.codeUnits) {
      if (_isCyrillic(c) || _isHangulSyllable(c) || _isKana(c)) return true;
    }
    return false;
  }

  /// True when [text] holds any CJK ideograph, i.e. anything the kana pass will
  /// refuse to touch.
  ///
  /// Exposed so a CALLER holding a whole lyric can make the decision once for
  /// the song instead of once per line. See the note on [romanize].
  static bool hasIdeograph(String text) {
    for (final c in text.codeUnits) {
      if (_isIdeograph(c)) return true;
    }
    return false;
  }

  /// Which of the three scripts appear in [text] — drives the "which language is
  /// this" label and lets the per-script toggles apply selectively.
  static Set<RomanizableScript> scriptsIn(String text) {
    final out = <RomanizableScript>{};
    for (final c in text.codeUnits) {
      if (_isCyrillic(c)) out.add(RomanizableScript.cyrillic);
      if (_isHangulSyllable(c)) out.add(RomanizableScript.hangul);
      if (_isKana(c)) out.add(RomanizableScript.kana);
    }
    return out;
  }

  /// Transliterate [text], converting only the scripts in [enabled].
  ///
  /// Anything not in an enabled script — Latin, punctuation, kanji, Chinese — is
  /// passed through untouched, so the result is always readable even when only
  /// part of a line could be handled.
  static String romanize(
    String text,
    Set<RomanizableScript> enabled, {
    KanaSystem kana = KanaSystem.hepburn,
    HangulSystem hangul = HangulSystem.revised,
    CyrillicSystem cyrillic = CyrillicSystem.practical,
  }) {
    if (text.isEmpty || enabled.isEmpty) return text;
    final units = text.codeUnits;

    // A half-converted japanese line is worse than an unconverted one
    //
    // Kanji cannot be romanised from the character alone — the reading depends
    // on the surrounding words, which needs a morphological dictionary this
    // does not ship. The original code romanised the kana anyway and left the
    // kanji, on the reasoning that a partly-converted line was "honest about
    // what was understood". On real lyrics that produces:
    //
    //   君の声が聞こえる 夜空に   ->   君no声ga聞koeru 夜空ni
    //
    // which is not honest, it is unreadable: you can no longer read it as
    // Japanese and you cannot read it as romaji either. It is also exactly what
    // "romanisation does not work" looked like from the outside.
    //
    // So a line containing ideographs skips the KANA pass and is left as it
    // was. Only kana is suppressed — a line mixing Cyrillic or Hangul with an
    // ideograph still converts those, because neither of them is ambiguous.
    var kanaEnabled = enabled.contains(RomanizableScript.kana);
    if (kanaEnabled) {
      for (final c in units) {
        if (_isIdeograph(c)) {
          kanaEnabled = false;
          break;
        }
      }
    }

    final sb = StringBuffer();

    for (var i = 0; i < units.length; i++) {
      final c = units[i];

      if (enabled.contains(RomanizableScript.cyrillic) && _isCyrillic(c)) {
        final table =
            cyrillic == CyrillicSystem.scientific ? _cyrillicIso9 : _cyrillic;
        sb.write(table[c] ?? _cyrillic[c] ?? String.fromCharCode(c));
        continue;
      }

      if (enabled.contains(RomanizableScript.hangul) && _isHangulSyllable(c)) {
        sb.write(_romanizeHangulSyllable(c, hangul));
        continue;
      }

      if (kanaEnabled && _isKana(c)) {
        // Try the two-character digraphs first (きゃ → kya): checking the single
        // character first would emit "ki" and strand the small ya.
        if (i + 1 < units.length) {
          final pair = String.fromCharCodes([c, units[i + 1]]);
          final digraph = kana == KanaSystem.kunrei
              ? (_kanaDigraphsKunrei[pair] ?? _kanaDigraphs[pair])
              : _kanaDigraphs[pair];
          if (digraph != null) {
            sb.write(digraph);
            i++;
            continue;
          }
        }
        // Small tsu doubles the NEXT consonant (きって → kitte). Emitting a
        // literal "tsu" here is the classic wrong answer.
        if (c == 0x3063 || c == 0x30C3) {
          final next = i + 1 < units.length
              ? _romanizeSingleKana(units[i + 1], units, i + 1, kana)
              : '';
          if (next.isNotEmpty && !_isVowel(next[0])) sb.write(next[0]);
          continue;
        }
        sb.write(_romanizeSingleKana(c, units, i, kana));
        continue;
      }

      sb.write(String.fromCharCode(c));
    }
    return sb.toString();
  }

  static bool _isVowel(String ch) => 'aeiou'.contains(ch.toLowerCase());

  static String _romanizeSingleKana(
      int c, List<int> units, int i, KanaSystem system) {
    // The katakana long mark extends the previous vowel (ラーメン → raamen).
    if (c == 0x30FC) return '';
    if (system == KanaSystem.kunrei) {
      final k = _kanaKunrei[c];
      if (k != null) return k;
    }
    return _kana[c] ?? String.fromCharCode(c);
  }

  // Hangul → Revised Romanization
  //
  // Every pre-composed syllable decomposes arithmetically:
  //   index  = code - 0xAC00
  //   final  = index % 28
  //   medial = (index / 28) % 21
  //   initial= index / (28 * 21)
  // so three small tables cover the entire script — no word list, and no gaps.

  static const List<String> _hangulInitial = [
    'g', 'kk', 'n', 'd', 'tt', 'r', 'm', 'b', 'pp', 's', 'ss', '', 'j', 'jj',
    'ch', 'k', 't', 'p', 'h'
  ];

  static const List<String> _hangulMedial = [
    'a', 'ae', 'ya', 'yae', 'eo', 'e', 'yeo', 'ye', 'o', 'wa', 'wae', 'oe',
    'yo', 'u', 'wo', 'we', 'wi', 'yu', 'eu', 'ui', 'i'
  ];

  static const List<String> _hangulFinal = [
    '', 'k', 'k', 'k', 'n', 'n', 'n', 't', 'l', 'l', 'l', 'l', 'l', 'l', 'l',
    'l', 'm', 'p', 'p', 't', 't', 'ng', 't', 't', 'k', 't', 'p', 't'
  ];

  static String _romanizeHangulSyllable(int code, HangulSystem system) {
    final index = code - 0xAC00;
    final finalIdx = index % 28;
    final medialIdx = (index ~/ 28) % 21;
    final initialIdx = index ~/ (28 * 21);
    final mr = system == HangulSystem.mccune;
    final initial = mr ? _hangulInitialMr : _hangulInitial;
    final medial = mr ? _hangulMedialMr : _hangulMedial;
    // Finals are the same in both systems: the coda inventory collapses to the
    // same seven sounds either way, so only the onsets and vowels differ.
    return '${initial[initialIdx]}${medial[medialIdx]}'
        '${_hangulFinal[finalIdx]}';
  }

  /// McCune-Reischauer onsets. The plain/aspirated split is written with an
  /// apostrophe (ch\u2019, k\u2019, t\u2019, p\u2019) and the plain series is voiceless,
  /// which is the visible difference from Revised: \ubd80\uc0b0 is "Pusan" here and
  /// "Busan" there.
  static const List<String> _hangulInitialMr = [
    'k', 'kk', 'n', 't', 'tt', 'r', 'm', 'p', 'pp', 's', 'ss', '', 'ch', 'tch',
    'ch\u2019', 'k\u2019', 't\u2019', 'p\u2019', 'h'
  ];

  /// McCune-Reischauer vowels, which is where the breves come from: \uc5b4 is \u014f
  /// and \uc73c is \u016d, against Revised\u2019s "eo" and "eu".
  static const List<String> _hangulMedialMr = [
    'a', 'ae', 'ya', 'yae', '\u014f', 'e', 'y\u014f', 'ye', 'o', 'wa', 'wae', 'oe',
    'yo', 'u', 'w\u014f', 'we', 'wi', 'yu', '\u016d', '\u016di', 'i'
  ];

  // Cyrillic → Latin
  // One table for all six languages. Where they disagree (Serbian ј vs Russian
  // й) both forms are present, since the letters themselves differ.
  static const Map<int, String> _cyrillic = {
    0x0410: 'A', 0x0430: 'a',
    0x0411: 'B', 0x0431: 'b',
    0x0412: 'V', 0x0432: 'v',
    0x0413: 'G', 0x0433: 'g',
    0x0414: 'D', 0x0434: 'd',
    0x0415: 'E', 0x0435: 'e',
    0x0401: 'Yo', 0x0451: 'yo',
    0x0416: 'Zh', 0x0436: 'zh',
    0x0417: 'Z', 0x0437: 'z',
    0x0418: 'I', 0x0438: 'i',
    0x0419: 'Y', 0x0439: 'y',
    0x041A: 'K', 0x043A: 'k',
    0x041B: 'L', 0x043B: 'l',
    0x041C: 'M', 0x043C: 'm',
    0x041D: 'N', 0x043D: 'n',
    0x041E: 'O', 0x043E: 'o',
    0x041F: 'P', 0x043F: 'p',
    0x0420: 'R', 0x0440: 'r',
    0x0421: 'S', 0x0441: 's',
    0x0422: 'T', 0x0442: 't',
    0x0423: 'U', 0x0443: 'u',
    0x0424: 'F', 0x0444: 'f',
    0x0425: 'Kh', 0x0445: 'kh',
    0x0426: 'Ts', 0x0446: 'ts',
    0x0427: 'Ch', 0x0447: 'ch',
    0x0428: 'Sh', 0x0448: 'sh',
    0x0429: 'Shch', 0x0449: 'shch',
    0x042A: '', 0x044A: '', // hard sign — silent
    0x042B: 'Y', 0x044B: 'y',
    0x042C: '', 0x044C: '', // soft sign — dropped rather than guessed
    0x042D: 'E', 0x044D: 'e',
    0x042E: 'Yu', 0x044E: 'yu',
    0x042F: 'Ya', 0x044F: 'ya',
    // Ukrainian / Belarusian / Serbian / Macedonian additions
    0x0404: 'Ye', 0x0454: 'ye',
    0x0406: 'I', 0x0456: 'i',
    0x0407: 'Yi', 0x0457: 'yi',
    0x0490: 'G', 0x0491: 'g',
    0x040E: 'U', 0x045E: 'u',
    0x0408: 'J', 0x0458: 'j',
    0x0409: 'Lj', 0x0459: 'lj',
    0x040A: 'Nj', 0x045A: 'nj',
    0x040B: 'C', 0x045B: 'c',
    0x040F: 'Dz', 0x045F: 'dz',
    0x0402: 'Dj', 0x0452: 'dj',
    0x0405: 'Dz', 0x0455: 'dz',
    0x040C: 'Kj', 0x045C: 'kj',
  };

  /// ISO 9 (scientific transliteration).
  ///
  /// One Latin sign per Cyrillic letter, using diacritics rather than digraphs,
  /// so the mapping is REVERSIBLE: \u0436 is always \u017e and never "zh", which means a
  /// reader can reconstruct the original spelling. That is the point of it, and
  /// it is why the practical table is still the default \u2014 \u017e is precise but "zh"
  /// is what an English speaker can pronounce on sight.
  ///
  /// Falls back to the practical table for any letter not listed, so the two
  /// tables need not be kept the same length.
  static const Map<int, String> _cyrillicIso9 = {
    0x0416: '\u017d', 0x0436: '\u017e',
    0x0419: 'J', 0x0439: 'j',
    0x0425: 'H', 0x0445: 'h',
    0x0426: 'C', 0x0446: 'c',
    0x0427: '\u010c', 0x0447: '\u010d',
    0x0428: '\u0160', 0x0448: '\u0161',
    0x0429: '\u015c', 0x0449: '\u015d',
    0x042A: '\u02ba', 0x044A: '\u02ba',
    0x042B: 'Y', 0x044B: 'y',
    0x042C: '\u02b9', 0x044C: '\u02b9',
    0x042D: '\u00c8', 0x044D: '\u00e8',
    0x042E: '\u00db', 0x044E: '\u00fb',
    0x042F: '\u00c2', 0x044F: '\u00e2',
    0x0401: '\u00cb', 0x0451: '\u00eb',
    0x0404: '\u00ca', 0x0454: '\u00ea',
    0x0407: '\u00cf', 0x0457: '\u00ef',
    0x0408: 'J', 0x0458: 'j',
    0x0409: 'L\u0302', 0x0459: 'l\u0302',
    0x040A: 'N\u0302', 0x045A: 'n\u0302',
    0x040B: '\u0106', 0x045B: '\u0107',
    0x040F: 'D\u0302', 0x045F: 'd\u0302',
    0x0402: '\u0110', 0x0452: '\u0111',
    0x0405: '\u1e91', 0x0455: '\u1e93',
    0x040C: '\u1e30', 0x045C: '\u1e31',
  };

  /// Kunrei-shiki overrides, applied on top of the Hepburn table.
  ///
  /// Japan\u2019s own school standard. It is SYSTEMATIC where Hepburn is phonetic:
  /// the \u305f-row is ta/ti/tu/te/to rather than ta/chi/tsu/te/to, because the
  /// column is one series in the language even though English ears hear three
  /// sounds. Someone studying Japanese often wants this; someone trying to sing
  /// along wants Hepburn, which is why both ship and Hepburn is the default.
  static const Map<int, String> _kanaKunrei = {
    0x3057: 'si', 0x30B7: 'si', // \u3057
    0x3061: 'ti', 0x30C1: 'ti', // \u3061
    0x3064: 'tu', 0x30C4: 'tu', // \u3064
    0x3075: 'hu', 0x30D5: 'hu', // \u3075
    0x3058: 'zi', 0x30B8: 'zi', // \u3058
    0x3062: 'zi', 0x30C2: 'zi', // \u3062
    0x3065: 'zu', 0x30C5: 'zu', // \u3065
  };

  /// Kunrei digraphs. Same principle: sya/tya/zya rather than sha/cha/ja.
  static const Map<String, String> _kanaDigraphsKunrei = {
    '\u3057\u3083': 'sya', '\u3057\u3085': 'syu', '\u3057\u3087': 'syo',
    '\u3061\u3083': 'tya', '\u3061\u3085': 'tyu', '\u3061\u3087': 'tyo',
    '\u3058\u3083': 'zya', '\u3058\u3085': 'zyu', '\u3058\u3087': 'zyo',
    '\u30b7\u30e3': 'sya', '\u30b7\u30e5': 'syu', '\u30b7\u30e7': 'syo',
    '\u30c1\u30e3': 'tya', '\u30c1\u30e5': 'tyu', '\u30c1\u30e7': 'tyo',
    '\u30b8\u30e3': 'zya', '\u30b8\u30e5': 'zyu', '\u30b8\u30e7': 'zyo',
  };

  // Kana → romaji
  // Digraphs are consulted FIRST (see [romanize]); a single-character lookup
  // would split きゃ into "ki" + a stranded ゃ.
  static const Map<String, String> _kanaDigraphs = {
    'きゃ': 'kya', 'きゅ': 'kyu', 'きょ': 'kyo',
    'しゃ': 'sha', 'しゅ': 'shu', 'しょ': 'sho',
    'ちゃ': 'cha', 'ちゅ': 'chu', 'ちょ': 'cho',
    'にゃ': 'nya', 'にゅ': 'nyu', 'にょ': 'nyo',
    'ひゃ': 'hya', 'ひゅ': 'hyu', 'ひょ': 'hyo',
    'みゃ': 'mya', 'みゅ': 'myu', 'みょ': 'myo',
    'りゃ': 'rya', 'りゅ': 'ryu', 'りょ': 'ryo',
    'ぎゃ': 'gya', 'ぎゅ': 'gyu', 'ぎょ': 'gyo',
    'じゃ': 'ja', 'じゅ': 'ju', 'じょ': 'jo',
    'びゃ': 'bya', 'びゅ': 'byu', 'びょ': 'byo',
    'ぴゃ': 'pya', 'ぴゅ': 'pyu', 'ぴょ': 'pyo',
    'キャ': 'kya', 'キュ': 'kyu', 'キョ': 'kyo',
    'シャ': 'sha', 'シュ': 'shu', 'ショ': 'sho',
    'チャ': 'cha', 'チュ': 'chu', 'チョ': 'cho',
    'ニャ': 'nya', 'ニュ': 'nyu', 'ニョ': 'nyo',
    'ヒャ': 'hya', 'ヒュ': 'hyu', 'ヒョ': 'hyo',
    'ミャ': 'mya', 'ミュ': 'myu', 'ミョ': 'myo',
    'リャ': 'rya', 'リュ': 'ryu', 'リョ': 'ryo',
    'ギャ': 'gya', 'ギュ': 'gyu', 'ギョ': 'gyo',
    'ジャ': 'ja', 'ジュ': 'ju', 'ジョ': 'jo',
    'ビャ': 'bya', 'ビュ': 'byu', 'ビョ': 'byo',
    'ピャ': 'pya', 'ピュ': 'pyu', 'ピョ': 'pyo',
    'ファ': 'fa', 'フィ': 'fi', 'フェ': 'fe', 'フォ': 'fo',
    'ヴァ': 'va', 'ヴィ': 'vi', 'ヴェ': 've', 'ヴォ': 'vo',
    'ティ': 'ti', 'ディ': 'di', 'トゥ': 'tu', 'ドゥ': 'du',
    'シェ': 'she', 'ジェ': 'je', 'チェ': 'che',
  };

  static const Map<int, String> _kana = {
    // hiragana
    0x3042: 'a', 0x3044: 'i', 0x3046: 'u', 0x3048: 'e', 0x304A: 'o',
    0x304B: 'ka', 0x304D: 'ki', 0x304F: 'ku', 0x3051: 'ke', 0x3053: 'ko',
    0x304C: 'ga', 0x304E: 'gi', 0x3050: 'gu', 0x3052: 'ge', 0x3054: 'go',
    0x3055: 'sa', 0x3057: 'shi', 0x3059: 'su', 0x305B: 'se', 0x305D: 'so',
    0x3056: 'za', 0x3058: 'ji', 0x305A: 'zu', 0x305C: 'ze', 0x305E: 'zo',
    0x305F: 'ta', 0x3061: 'chi', 0x3064: 'tsu', 0x3066: 'te', 0x3068: 'to',
    0x3060: 'da', 0x3062: 'ji', 0x3065: 'zu', 0x3067: 'de', 0x3069: 'do',
    0x306A: 'na', 0x306B: 'ni', 0x306C: 'nu', 0x306D: 'ne', 0x306E: 'no',
    0x306F: 'ha', 0x3072: 'hi', 0x3075: 'fu', 0x3078: 'he', 0x307B: 'ho',
    0x3070: 'ba', 0x3073: 'bi', 0x3076: 'bu', 0x3079: 'be', 0x307C: 'bo',
    0x3071: 'pa', 0x3074: 'pi', 0x3077: 'pu', 0x307A: 'pe', 0x307D: 'po',
    0x307E: 'ma', 0x307F: 'mi', 0x3080: 'mu', 0x3081: 'me', 0x3082: 'mo',
    0x3084: 'ya', 0x3086: 'yu', 0x3088: 'yo',
    0x3089: 'ra', 0x308A: 'ri', 0x308B: 'ru', 0x308C: 're', 0x308D: 'ro',
    0x308F: 'wa', 0x3090: 'wi', 0x3091: 'we', 0x3092: 'wo', 0x3093: 'n',
    0x3083: 'ya', 0x3085: 'yu', 0x3087: 'yo', // small ya/yu/yo (post-digraph)
    // katakana
    0x30A2: 'a', 0x30A4: 'i', 0x30A6: 'u', 0x30A8: 'e', 0x30AA: 'o',
    0x30AB: 'ka', 0x30AD: 'ki', 0x30AF: 'ku', 0x30B1: 'ke', 0x30B3: 'ko',
    0x30AC: 'ga', 0x30AE: 'gi', 0x30B0: 'gu', 0x30B2: 'ge', 0x30B4: 'go',
    0x30B5: 'sa', 0x30B7: 'shi', 0x30B9: 'su', 0x30BB: 'se', 0x30BD: 'so',
    0x30B6: 'za', 0x30B8: 'ji', 0x30BA: 'zu', 0x30BC: 'ze', 0x30BE: 'zo',
    0x30BF: 'ta', 0x30C1: 'chi', 0x30C4: 'tsu', 0x30C6: 'te', 0x30C8: 'to',
    0x30C0: 'da', 0x30C2: 'ji', 0x30C5: 'zu', 0x30C7: 'de', 0x30C9: 'do',
    0x30CA: 'na', 0x30CB: 'ni', 0x30CC: 'nu', 0x30CD: 'ne', 0x30CE: 'no',
    0x30CF: 'ha', 0x30D2: 'hi', 0x30D5: 'fu', 0x30D8: 'he', 0x30DB: 'ho',
    0x30D0: 'ba', 0x30D3: 'bi', 0x30D6: 'bu', 0x30D9: 'be', 0x30DC: 'bo',
    0x30D1: 'pa', 0x30D4: 'pi', 0x30D7: 'pu', 0x30DA: 'pe', 0x30DD: 'po',
    0x30DE: 'ma', 0x30DF: 'mi', 0x30E0: 'mu', 0x30E1: 'me', 0x30E2: 'mo',
    0x30E4: 'ya', 0x30E6: 'yu', 0x30E8: 'yo',
    0x30E9: 'ra', 0x30EA: 'ri', 0x30EB: 'ru', 0x30EC: 're', 0x30ED: 'ro',
    0x30EF: 'wa', 0x30F2: 'wo', 0x30F3: 'n', 0x30F4: 'vu',
    0x30E3: 'ya', 0x30E5: 'yu', 0x30E7: 'yo',
  };
}

/// Which romanization STANDARD to use for kana.
///
/// Not cosmetic: the same line comes out as "shinjitsu" or "sinzitu" depending
/// on the choice, and which one is right depends entirely on why you are reading
/// it. Hepburn is the default because singing along is the common case here.
enum KanaSystem {
  hepburn,
  kunrei;

  String get label => switch (this) {
        KanaSystem.hepburn => 'Hepburn',
        KanaSystem.kunrei => 'Kunrei-shiki',
      };

  String get detail => switch (this) {
        KanaSystem.hepburn =>
          'shi, chi, tsu, fu \u2014 spelled how it sounds in English',
        KanaSystem.kunrei =>
          'si, ti, tu, hu \u2014 Japan\u2019s own school standard',
      };

  /// Stored in prefs, so renaming a value resets the setting for everybody.
  String get key => name;
}

/// Which romanization STANDARD to use for Hangul.
enum HangulSystem {
  revised,
  mccune;

  String get label => switch (this) {
        HangulSystem.revised => 'Revised Romanization',
        HangulSystem.mccune => 'McCune\u2013Reischauer',
      };

  String get detail => switch (this) {
        HangulSystem.revised =>
          'Busan, Jeonju \u2014 South Korea\u2019s official system',
        HangulSystem.mccune =>
          'Pusan, Ch\u2019\u014fnju \u2014 older, with breves and apostrophes',
      };

  String get key => name;
}

/// Which romanization STANDARD to use for Cyrillic.
enum CyrillicSystem {
  practical,
  scientific;

  String get label => switch (this) {
        CyrillicSystem.practical => 'Practical',
        CyrillicSystem.scientific => 'Scientific (ISO 9)',
      };

  String get detail => switch (this) {
        CyrillicSystem.practical =>
          'zh, sh, ya \u2014 readable without diacritics',
        CyrillicSystem.scientific =>
          '\u017e, \u0161, \u00e2 \u2014 one sign per letter, reversible',
      };

  String get key => name;
}

/// The scripts [RomanizationService] can actually convert. See the class doc for
/// why this is a script list rather than a language list.
enum RomanizableScript {
  cyrillic,
  hangul,
  kana;

  String get label => switch (this) {
        RomanizableScript.cyrillic => 'Cyrillic',
        RomanizableScript.hangul => 'Korean',
        RomanizableScript.kana => 'Japanese kana',
      };

  String get detail => switch (this) {
        RomanizableScript.cyrillic =>
          'Russian, Ukrainian, Serbian, Bulgarian, Belarusian, Macedonian',
        RomanizableScript.hangul => 'Hangul → Revised Romanization',
        RomanizableScript.kana =>
          'Hiragana and katakana. Lines containing kanji are left alone',
      };

  /// Stored in prefs, so these strings are a persistence format: renaming one
  /// silently resets that toggle for everybody.
  String get key => name;
}
