import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:auvy/services/recognition_history.dart';

/// Pins the collapse rule in [RecognitionHistory.add].
///
/// This list is the one thing in the app that CANNOT be rebuilt by using the app
/// again: every other record is derived from behaviour, but a recognition is a
/// moment that has passed, and its timestamp is most of the value. So the
/// expensive direction here is deleting — a test that lets a real encounter be
/// overwritten is worse than one that tolerates a visual duplicate.

RecognitionEntry _entry(String title, DateTime at, {String artist = 'Artist'}) =>
    RecognitionEntry(title: title, artist: artist, at: at);

void main() {
  setUp(() {
    // Each test starts from an empty store.
    SharedPreferences.setMockInitialValues({});
  });

  test('entries are newest first', () async {
    final t0 = DateTime(2026, 8, 16, 10);
    await RecognitionHistory.add(_entry('Alpha', t0));
    await RecognitionHistory.add(_entry('Bravo', t0.add(const Duration(hours: 1))));

    final all = await RecognitionHistory.load();
    expect(all.map((e) => e.title).toList(), ['Bravo', 'Alpha']);
  });

  test('an immediate repeat collapses into one entry', () async {
    // The case the rule is actually for: pressing the tile twice on one song.
    final t0 = DateTime(2026, 8, 16, 10);
    await RecognitionHistory.add(_entry('Alpha', t0));
    await RecognitionHistory.add(_entry('Alpha', t0.add(const Duration(seconds: 20))));

    final all = await RecognitionHistory.load();
    expect(all.length, 1);
    expect(all.single.at, t0.add(const Duration(seconds: 20)),
        reason: 'the newer timestamp wins');
  });

  test('the SAME song heard days later is kept as a separate encounter', () async {
    // The regression this file exists for. The old rule replaced any repeat at
    // the top regardless of when, so Tuesday's encounter was destroyed by
    // Friday's and the list claimed you had heard it once.
    final tue = DateTime(2026, 8, 11, 14);
    final fri = DateTime(2026, 8, 14, 21);
    await RecognitionHistory.add(_entry('Alpha', tue));
    await RecognitionHistory.add(_entry('Alpha', fri));

    final all = await RecognitionHistory.load();
    expect(all.length, 2);
    expect(all.map((e) => e.at).toList(), [fri, tue]);
  });

  test('a repeat just outside the window is kept', () async {
    final t0 = DateTime(2026, 8, 16, 10);
    await RecognitionHistory.add(_entry('Alpha', t0));
    await RecognitionHistory.add(_entry('Alpha', t0.add(const Duration(minutes: 5))));

    expect((await RecognitionHistory.load()).length, 2);
  });

  test('a different song never collapses, however close together', () async {
    final t0 = DateTime(2026, 8, 16, 10);
    await RecognitionHistory.add(_entry('Alpha', t0));
    await RecognitionHistory.add(_entry('Bravo', t0.add(const Duration(seconds: 5))));

    expect((await RecognitionHistory.load()).length, 2);
  });

  test('the same title by a different artist is a different song', () async {
    final t0 = DateTime(2026, 8, 16, 10);
    await RecognitionHistory.add(_entry('Alpha', t0, artist: 'One'));
    await RecognitionHistory.add(
        _entry('Alpha', t0.add(const Duration(seconds: 5)), artist: 'Two'));

    expect((await RecognitionHistory.load()).length, 2);
  });

  test('only the TOP entry can collapse, so an interleaved repeat is kept', () async {
    // A → B → A within the window. The second A must not reach past B and
    // delete the first.
    final t0 = DateTime(2026, 8, 16, 10);
    await RecognitionHistory.add(_entry('Alpha', t0));
    await RecognitionHistory.add(_entry('Bravo', t0.add(const Duration(seconds: 10))));
    await RecognitionHistory.add(_entry('Alpha', t0.add(const Duration(seconds: 20))));

    final all = await RecognitionHistory.load();
    expect(all.map((e) => e.title).toList(), ['Alpha', 'Bravo', 'Alpha']);
  });

  test('a corrupt blob reads as empty rather than throwing', () async {
    SharedPreferences.setMockInitialValues({
      'auvy_recognition_history': 'not json at all',
    });
    expect(await RecognitionHistory.load(), isEmpty);
  });

  test('clear empties the list', () async {
    await RecognitionHistory.add(_entry('Alpha', DateTime(2026, 8, 16)));
    await RecognitionHistory.clear();
    expect(await RecognitionHistory.load(), isEmpty);
  });
}
