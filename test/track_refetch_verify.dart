import 'package:flutter_test/flutter_test.dart';
import 'package:auvy/data/dummy_data.dart';
import 'package:auvy/logic/track_refetch.dart';

Song s({
  String id = 'abcdefghijk',
  String title = 'Song',
  String artist = 'Artist',
  String image = '',
  String albumId = '',
  String albumTitle = '',
  String releaseDate = '',
  String duration = '0:00',
  bool? isExplicit,
  String musicVideoType = '',
}) =>
    Song(
      id: id,
      title: title,
      artist: artist,
      image: image,
      albumId: albumId,
      albumTitle: albumTitle,
      releaseDate: releaseDate,
      duration: duration,
      isExplicit: isExplicit,
      musicVideoType: musicVideoType,
    );

const albumArt = 'https://lh3.googleusercontent.com/aaaa=s800';
const albumArt2 = 'https://lh3.googleusercontent.com/bbbb=s800';
const videoStill = 'https://i.ytimg.com/vi/abcdefghijk/maxresdefault.jpg';

void main() {
  group('mergeRefetched', () {
    test('never changes the id, even when the candidate is better', () {
      final before = s(id: 'video123456', title: 'X (Official Video)');
      final after = mergeRefetched(before, s(id: 'audio7890ab', title: 'X'));
      expect(after.id, 'video123456');
      expect(after.title, 'X');
    });

    test('takes a fresh album cover', () {
      final after = mergeRefetched(s(image: albumArt), s(image: albumArt2));
      expect(after.image, albumArt2);
    });

    test('refuses to trade a square sleeve for a video still', () {
      final after = mergeRefetched(s(image: albumArt), s(image: videoStill));
      expect(after.image, albumArt);
    });

    test('accepts a video still when there was no cover at all', () {
      final after = mergeRefetched(s(image: ''), s(image: videoStill));
      expect(after.image, videoStill);
    });

    test('upgrades a video still to a real sleeve', () {
      final after = mergeRefetched(s(image: videoStill), s(image: albumArt));
      expect(after.image, albumArt);
    });

    test('empty candidate fields never erase what we had', () {
      final before = s(
          title: 'Real Title',
          artist: 'Real Artist',
          albumTitle: 'Real Album',
          image: albumArt,
          duration: '3:45');
      final after = mergeRefetched(before, s(title: '', artist: '', image: '', duration: ''));
      expect(after.title, 'Real Title');
      expect(after.artist, 'Real Artist');
      expect(after.albumTitle, 'Real Album');
      expect(after.image, albumArt);
      expect(after.duration, '3:45');
    });

    test('"Unknown Artist" is a placeholder and must not win', () {
      final after = mergeRefetched(s(artist: 'Queen'), s(artist: 'Unknown Artist'));
      expect(after.artist, 'Queen');
    });

    test('"0:00" is the default duration, not a measurement', () {
      final after = mergeRefetched(s(duration: '5:55'), s(duration: '0:00'));
      expect(after.duration, '5:55');
    });

    test('a real duration replaces the placeholder', () {
      final after = mergeRefetched(s(duration: '0:00'), s(duration: '5:55'));
      expect(after.duration, '5:55');
    });

    test('explicit flag comes across; a null candidate keeps the old one', () {
      expect(mergeRefetched(s(), s(isExplicit: true)).isExplicit, true);
      expect(mergeRefetched(s(isExplicit: true), s()).isExplicit, true);
    });
  });

  group('describeRefetch', () {
    test('reports nothing when nothing changed', () {
      final a = s(image: albumArt, title: 'T');
      expect(describeRefetch(a, a).any, isFalse);
      expect(describeRefetch(a, a).summary, '');
    });

    test('names exactly what moved', () {
      final before = s(image: albumArt, title: 'Old', albumTitle: 'A');
      final after = before.copyWith(image: albumArt2, albumTitle: 'B');
      final d = describeRefetch(before, after);
      expect(d.cover, isTrue);
      expect(d.album, isTrue);
      expect(d.title, isFalse);
      expect(d.summary, 'cover art and album');
    });

    test('summary reads as a list for three or more', () {
      final before = s(image: albumArt, title: 'Old', artist: 'A');
      final after = before.copyWith(image: albumArt2, title: 'New', artist: 'B');
      expect(describeRefetch(before, after).summary, 'cover art, title and artist');
    });
  });

  group('refetchQuery', () {
    test('strips the YouTube video furniture that finds the wrong row again', () {
      expect(refetchQuery(s(title: 'Numb (Official Video)', artist: 'Linkin Park')),
          'Numb Linkin Park');
      expect(refetchQuery(s(title: 'Numb [4K Remaster]', artist: 'Linkin Park')),
          'Numb Linkin Park');
      expect(refetchQuery(s(title: 'Numb | Official Music Video', artist: 'Linkin Park')),
          'Numb Linkin Park');
    });

    test('keeps meaningful parentheses', () {
      expect(refetchQuery(s(title: 'Hurt (feat. Someone)', artist: 'X')),
          'Hurt (feat. Someone) X');
    });

    test('uses only the primary artist', () {
      expect(refetchQuery(s(title: 'T', artist: 'A, B & C')), 'T A');
      expect(refetchQuery(s(title: 'T', artist: 'A feat. B')), 'T A');
    });

    test('drops the Unknown Artist placeholder from the query', () {
      expect(refetchQuery(s(title: 'T', artist: 'Unknown Artist')), 'T');
    });

    test('never returns an empty query when there is a title', () {
      expect(refetchQuery(s(title: '(Official Video)', artist: '')),
          '(Official Video)');
    });
  });

  group('isPlausibleRefetch', () {
    test('accepts the same recording described differently', () {
      expect(
          isPlausibleRefetch(s(title: 'Numb (Official Video)', artist: 'Linkin Park'),
              s(title: 'Numb', artist: 'Linkin Park')),
          isTrue);
    });

    test('rejects a different song by the same artist', () {
      expect(
          isPlausibleRefetch(s(title: 'Numb', artist: 'Linkin Park'),
              s(title: 'In The End', artist: 'Linkin Park')),
          isFalse);
    });

    test('rejects the same title by a different artist (the cover-band trap)', () {
      expect(
          isPlausibleRefetch(s(title: 'Numb', artist: 'Linkin Park'),
              s(title: 'Numb', artist: 'Tribute Players')),
          isFalse);
    });

    test('a missing artist on either side cannot contradict the match', () {
      expect(isPlausibleRefetch(s(title: 'Numb', artist: ''), s(title: 'Numb', artist: 'X')),
          isTrue);
    });

    test('an empty title is never plausible', () {
      expect(isPlausibleRefetch(s(title: '', artist: 'X'), s(title: 'Y', artist: 'X')),
          isFalse);
    });
  });

  group('isVideoThumbnail', () {
    test('recognises ytimg stills and album sleeves', () {
      expect(isVideoThumbnail(videoStill), isTrue);
      expect(isVideoThumbnail(albumArt), isFalse);
      expect(isVideoThumbnail(''), isFalse);
    });
  });
}
