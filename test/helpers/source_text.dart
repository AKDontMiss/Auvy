/// Helpers for tests that assert things about SOURCE TEXT.
///
/// ── A SENTINEL MUST NOT BE ABLE TO MATCH ITS OWN EXPLANATION ─────────────
///
/// Several tests here guard a rule by scanning the file that implements it —
/// the right tool when the rule lives in a private member of a large stateful
/// class and standing one up would test the harness. But a source-scanning
/// assertion has a failure mode of its own, and it caught me three times in one
/// day:
///
///   1. A check for the phrase "Mirrors the implementation exactly" failed
///      immediately, because the new doc comment QUOTES that phrase while
///      explaining what was wrong with it.
///   2. A check that listed the forbidden function signatures as literal strings
///      failed because the list itself put those strings in the file.
///   3. A check for `IV.fromLength` failed because the source's own comment
///      explains the bug that constructor caused.
///
/// Every one of those was a test failing on PROSE rather than on a regression.
/// The two ways out are collected here so the next such test does not re-derive
/// them — and so there is one copy of the rule rather than four, which is the
/// same discipline these tests are enforcing elsewhere.
///
/// These are DELIBERATELY crude. They are not a Dart parser: a `//` inside a
/// string literal is treated as a comment. That is acceptable for asking "does
/// this file still call X" and unacceptable for anything that needs real
/// analysis — if a check needs more than this, it wants a different approach,
/// not a smarter regex.
library;

import 'dart:io';

/// [path]'s source with whole-line comments removed.
///
/// Use when the thing being forbidden may legitimately be NAMED in a comment —
/// which, for anything worth a sentinel, it usually is: the comment explaining
/// why a construct is banned tends to contain the construct.
String codeOf(String path) => File(path)
    .readAsStringSync()
    .split('\n')
    .where((l) {
      final t = l.trimLeft();
      return !t.startsWith('//') && !t.startsWith('///') && !t.startsWith('*');
    })
    .join('\n');

/// [path]'s COMMENT lines only — the inverse of [codeOf].
///
/// Exists because the obvious mistake is to assert on comment text while reading
/// [codeOf]'s output, which has removed exactly that text. The failure is
/// confusing rather than informative: a `contains` check simply reads false, and
/// an `indexOf` anchor returns -1 and throws a RangeError from `substring`
/// instead of failing with its reason. That happened three times in one day
/// before this existed.
///
/// Use it when the thing being guarded IS the prose — a doc comment that has to
/// keep warning about something, a note that must not be quietly deleted.
String docsOf(String path) => File(path)
    .readAsStringSync()
    .split('\n')
    .where((l) {
      final t = l.trimLeft();
      return t.startsWith('//') || t.startsWith('*') || t.startsWith('/*');
    })
    .join('\n');

/// Whether [path] declares anything at COLUMN 0 matching [returnTypes].
///
/// The positional trick, and the more robust of the two: a check written inside
/// `main()` is indented, so a column-0 anchor cannot see it. That is what makes
/// this immune to describing itself — unlike a list of forbidden names, which
/// necessarily contains them.
///
/// Used to catch a test file that has re-declared a local MIRROR of the rule it
/// is supposed to be verifying, which is how one file came to test a copy and
/// therefore could never fail when the real rule drifted.
bool hasTopLevelDeclaration(String path, Iterable<String> returnTypes) {
  final pattern = RegExp(
    '^(?:${returnTypes.map(RegExp.escape).join('|')})\\s+_?\\w+\\s*\\(',
    multiLine: true,
  );
  return pattern.hasMatch(File(path).readAsStringSync());
}
