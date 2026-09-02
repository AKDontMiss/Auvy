import 'package:auvy/data/dummy_data.dart';

/// What KIND of thing is playing, decided in one place.
///
/// This exists because the test was copied five times AND then outgrown.
///
/// The player page carried `song.id.startsWith('http') && albumTitle != 'Podcast'`
/// in five separate spots, meaning "live radio", and that was true right up to
/// the moment a third kind of `http`-id media existed. Audiobook chapters are
/// direct MP3 URLs, so every one of those five tests silently classified them as
/// a live stream, which among other things HID THE SEEK BAR: a chapter you cannot
/// scrub is not an audiobook.
///
/// A live stream is the only kind with no meaningful position, so it is the only
/// one that should ever lose the scrubber. Everything else — music, podcast
/// episodes, audiobook chapters — is a finite recording you move around inside.
enum MediaKind { music, podcast, audiobook, liveStream }

/// The marker written into [Song.albumId] for audiobook chapters.
///
/// `albumId` rather than `albumTitle`: the title is the BOOK's name and is shown
/// to the user, while albumId is invisible, is persisted with the queue, and is
/// unused for this kind of media, so it survives a restart, unlike the
/// transient `playbackSource`.
const String kAudiobookMarker = 'audiobook';

extension SongMediaKind on Song {
  MediaKind get mediaKind {
    // Ordered most specific first: an audiobook chapter and a podcast episode
    // both have http ids, so the liveStream fallback must come last.
    if (albumId == kAudiobookMarker) return MediaKind.audiobook;
    if (albumTitle == 'Podcast') return MediaKind.podcast;
    if (id.startsWith('http')) return MediaKind.liveStream;
    return MediaKind.music;
  }

  /// A finite recording with a real position — everything except a live stream.
  /// This is the test that should gate a seek bar, a duration or a speed control.
  bool get hasSeekablePosition => mediaKind != MediaKind.liveStream;

  /// Spoken-word content: podcast episodes and audiobook chapters. They want the
  /// same affordances (speed, skip-back, resume where you left off) and the same
  /// loudness target, so most code should ask this rather than naming one.
  bool get isSpokenWord =>
      mediaKind == MediaKind.podcast || mediaKind == MediaKind.audiobook;
}
