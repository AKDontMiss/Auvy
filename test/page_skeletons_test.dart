import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:auvy/presentation/widgets/page_skeletons.dart';

import 'helpers/source_text.dart';

/// The loading state of the album and artist pages.
///
/// Both open INSTANTLY from the player with only a name, so the first second of
/// a first visit is spent here. It used to be a centred CircularProgressIndicator
/// in 50-60px of padding — no hint of what was coming, and a layout jump when it
/// arrived.
///
/// These are widget tests rather than source scans because a skeleton either
/// builds and animates or it does not, and that is cheap to actually run.
void main() {
  Widget host(Widget sliver) => MaterialApp(
        home: Scaffold(
          body: CustomScrollView(slivers: [sliver]),
        ),
      );

  group('the skeletons build and animate', () {
    testWidgets('the album track list renders rows', (tester) async {
      await tester.pumpWidget(host(const AlbumTracksSkeleton(rows: 6)));
      // 6 rows, each an artwork square plus two text lines.
      expect(find.byType(ShimmerBox), findsNWidgets(6 * 3));
      expect(tester.takeException(), isNull);
    });

    testWidgets('the artist body renders a shelf and a track list', (tester) async {
      await tester.pumpWidget(host(const ArtistBodySkeleton()));
      // 2 section headings + 4 shelf tiles (3 boxes each) + 5 rows (3 each).
      expect(find.byType(ShimmerBox), findsNWidgets(2 + 4 * 3 + 5 * 3));
      expect(tester.takeException(), isNull);
    });

    testWidgets('the shimmer advances over time without throwing', (tester) async {
      await tester.pumpWidget(host(const AlbumTracksSkeleton(rows: 3)));
      // A repeating controller never settles, so pumpAndSettle would time out —
      // step the clock explicitly instead.
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pump(const Duration(milliseconds: 400));
      expect(tester.takeException(), isNull);
      // Let the controller be disposed with the tree; an undisposed ticker fails
      // the test binding, which is exactly the leak worth catching here.
      await tester.pumpWidget(const SizedBox());
      expect(tester.takeException(), isNull);
    });

    testWidgets('a ShimmerBox outside a Shimmer renders instead of throwing',
        (tester) async {
      // A skeleton is decoration. It must not be able to crash a page that is
      // already struggling to load.
      await tester.pumpWidget(
        const MaterialApp(home: Scaffold(body: Center(child: ShimmerBox(width: 40)))),
      );
      expect(tester.takeException(), isNull);
      expect(find.byType(ShimmerBox), findsOneWidget);
    });
  });

  group('one ticker per page, not one per box', () {
    test('the page skeletons do not use the per-instance SkeletonLoader', () {
      final code = codeOf('lib/presentation/widgets/page_skeletons.dart');
      expect(code.contains('SkeletonLoader'), isFalse,
          reason: 'SkeletonLoader owns an AnimationController per instance. A '
              'page skeleton is ~20 boxes, so that is ~20 tickers driving ~20 '
              'rebuilds a frame for one visual effect — and independent '
              'controllers drift, so the sweep goes ragged.');
      // Exactly one controller in the file.
      final controllers = RegExp(r'AnimationController\(').allMatches(code).length;
      expect(controllers, 1,
          reason: 'Expected a single shared AnimationController, found '
              '$controllers.');
    });
  });

  group('the header does not assert a guess', () {
    final album = codeOf('lib/presentation/pages/album_page.dart');

    test('the album title is skeletoned while it is still the track name', () {
      // Opened from the player, `album.title` IS the track name — it is only
      // used to resolve the album BY name. The header therefore showed the
      // song's title (in "ALBUM" type) for a second and then swapped to the real
      // one. A shimmer bar says "coming" instead of asserting something wrong.
      expect(album.contains('final titleIsGuess ='), isTrue,
          reason: 'The header is back to displaying album.title unconditionally, '
              'which is the entry TRACK name when opened from the player.');
      expect(album.contains('if (titleIsGuess) ...const ['), isTrue,
          reason: 'The guessed title is rendered as text again rather than as a '
              'placeholder.');
    });

    test('LOADING is what makes it a guess — nothing narrower', () {
      // An earlier version only skeletoned when it could PROVE the title was
      // wrong (passed title == entry track title). That missed every other way
      // of being unconfirmed and the wrong text still flashed on screen.
      // [resolvedTitle] prefers the album name carried by the resolved tracks,
      // so until those land the header is showing an unverified value, full stop.
      final decl = album.substring(album.indexOf('final titleIsGuess ='));
      final expr = decl.substring(0, decl.indexOf(';'));
      expect(expr.contains('resolvedTracks == null'), isTrue,
          reason: 'It must stop being a guess once the tracklist lands.');
      expect(expr.contains('widget.fallbackTrack'), isFalse,
          reason: 'Narrowed again to "only when we can prove it is the track '
              'name". Unconfirmed is unconfirmed — skeleton it.');
    });

    test('the meta line shimmers instead of showing a tiny spinner', () {
      expect(album.contains('loading: () => const ShimmerBox('), isTrue,
          reason: 'The date/track-count/duration line is back to an 11px '
              'CircularProgressIndicator sitting in a text slot.');
    });

    test('the shimmer host is only mounted while something is loading', () {
      // A permanent Shimmer would leave a repeating controller running for the
      // life of every album page, for an effect visible in the first second.
      expect(album.contains('MaybeShimmer('), isTrue);
      final skeletons = codeOf('lib/presentation/widgets/page_skeletons.dart');
      expect(skeletons.contains('active ? Shimmer(child: child) : child'), isTrue,
          reason: 'MaybeShimmer now always builds a Shimmer, so the ticker runs '
              'even after the data has arrived.');
    });
  });

  group('the artist portrait is fetched at most once', () {
    final artist = codeOf('lib/presentation/pages/artist_page.dart');

    test('the fallback waits for the primary to settle', () {
      // Watched inside a ternary on headerData?.image, the Deezer request went
      // out on EVERY artist page open — headerData is null on the first frame —
      // and was thrown away the moment YouTube answered with a picture. The
      // family key also changed when the resolved name arrived, so the same
      // artist could produce two requests under two keys.
      expect(artist.contains('headerAsync.isLoading'), isTrue,
          reason: 'The fallback no longer checks whether the primary is still '
              'in flight, so it fires on every artist page open again.');
      final body = artist.substring(artist.indexOf('var portraitPending = false;'));
      final beforeSettleCheck = body.substring(0, body.indexOf('} else {'));
      expect(beforeSettleCheck.contains('artistPortraitProvider'), isFalse,
          reason: 'The fallback is watched before the settle check, which is '
              'exactly the ordering that made it fire and be discarded.');
    });

    test('the pending state drives a shimmer, not a silhouette', () {
      expect(artist.contains('portraitPending'), isTrue);
      expect(artist.contains('shape: BoxShape.circle'), isTrue,
          reason: 'The portrait falls back to AuvyImage\'s static placeholder '
              'again, which reads as "this artist has no picture" and then '
              'swaps when one arrives.');
    });

    test('a real request announces itself', () {
      final svc = codeOf('lib/services/artist_info_service.dart');
      expect(svc.contains('artist portrait: asking Deezer for'), isTrue,
          reason: 'Without this line a wasted request is indistinguishable '
              'from no request at all — which is why the double fetch survived '
              'until someone watched the network by eye.');
    });
  });

  group('the pages actually use them', () {
    test('album and artist no longer show a bare spinner while loading', () {
      final album = codeOf('lib/presentation/pages/album_page.dart');
      final artist = codeOf('lib/presentation/pages/artist_page.dart');
      expect(album.contains('loading: () => const AlbumTracksSkeleton()'), isTrue,
          reason: 'The album track list is back to a CircularProgressIndicator.');
      expect(artist.contains('const ArtistBodySkeleton()'), isTrue,
          reason: 'The artist body is back to a CircularProgressIndicator.');
    });
  });
}
