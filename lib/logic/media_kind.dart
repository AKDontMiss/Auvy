import 'package:auvy/data/dummy_data.dart';

/// What kind of media is playing, decided in one place.
///
/// Radio, podcast episodes and audiobook chapters all have `http` ids, so the id
/// alone cannot tell them apart. Only a live stream has no meaningful position;
/// music, podcasts and audiobooks are finite recordings with a seek bar.
enum MediaKind { music, podcast, audiobook, liveStream }

/// Marker stored in [Song.albumId] for audiobook chapters. albumId is used
/// because it is invisible to the user and saved with the queue, so the marker
/// survives a restart.
const String kAudiobookMarker = 'audiobook';

extension SongMediaKind on Song {
  MediaKind get mediaKind {
    // Most specific first: audiobook chapters and podcast episodes also have http
    // ids, so the live-stream fallback comes last.
    // The marker alone (older saved queues) or with the book's id after it.
    if (albumId == kAudiobookMarker || albumId.startsWith('$kAudiobookMarker:')) {
      return MediaKind.audiobook;
    }
    if (albumTitle == 'Podcast') return MediaKind.podcast;
    if (id.startsWith('http')) return MediaKind.liveStream;
    return MediaKind.music;
  }

  /// A finite recording with a real position (everything but a live stream). Use
  /// this to decide whether to show a seek bar, duration or speed control.
  bool get hasSeekablePosition => mediaKind != MediaKind.liveStream;

  /// Podcast episodes and audiobook chapters. They share features (speed,
  /// skip-back, resume) and a loudness target, so code should usually ask this.
  bool get isSpokenWord =>
      mediaKind == MediaKind.podcast || mediaKind == MediaKind.audiobook;
}

/// Hooks the player calls for spoken word, so it needn't depend on the features
/// that listen.
class SpokenWordHooks {
  /// An audiobook chapter played to its end (AudiobookLibraryNotifier marks the
  /// book finished after its last chapter).
  static void Function(Song song)? chapterFinished;
}
