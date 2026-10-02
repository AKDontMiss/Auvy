import 'dart:async';
import 'dart:convert';
import 'package:flutter/widgets.dart'
    show WidgetsBinding, AppLifecycleState;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:audio_service/audio_service.dart';
import 'package:auvy/providers/player_provider.dart';
import 'package:auvy/core/native_audio_engine.dart';
import 'package:auvy/providers/library_provider.dart';
import 'package:auvy/data/dummy_data.dart' show Song;
import 'package:auvy/services/widget_service.dart';
import 'package:auvy/services/listening_policy.dart';
import 'package:auvy/logic/library_integrity.dart' show kSystemLibraryTitles, isFreshReserveKey;
import 'package:auvy/logic/track_identity.dart';
import 'package:auvy/services/search_service.dart';
import 'package:auvy/logic/media_kind.dart';

/// Handles every playback control from outside the app: notification and lock
/// screen, headset buttons, Android Auto, Bluetooth devices and Google Assistant.
///
/// audio_service registers this handler with the OS, which then calls play(),
/// pause(), skipToNext() and so on. It does not play audio itself; it forwards
/// each request to the app's player and mirrors the resulting state back to the
/// system.
///
/// Android sometimes delivers a play() the user never made (a car connecting,
/// a Bluetooth device waking, media resumption after a reboot), so
/// [_shouldIgnoreExternalPlay] decides which requests to honour.
class AuvyAudioHandler extends BaseAudioHandler with QueueHandler {
  final PlayerNotifier _playerNotifier;
  Timer? _idleKillTimer;
  static const Duration _maxIdleDuration = Duration(hours: 1);

  // When the last media-button click was accepted, to debounce repeated clicks
  // (see [click]).
  DateTime? _lastMediaClickAt;

  // Signature of the last broadcast. broadcastState() runs on every player state
  // change, so identical broadcasts are skipped to avoid needless platform calls.
  String? _lastBroadcastSig;

  // True after stop() ended the session. Without it, the next state change would
  // re-post the media notification the user just dismissed. Cleared when playback
  // really restarts.
  bool _stopped = false;

  // Android Auto browse tree. Song entries are 'song/<folder>/<index>', so a tap
  // plays the list it was browsed from as the queue.
  static const String _folderLiked = 'liked';
  static const String _folderTop50 = 'top50';
  static const String _folderDownloads = 'Downloaded';
  static const String _folderCached = 'Cached';
  static const String _folderRecent = 'recent-played';

  /// The folder listing the user's own playlists, and the prefix for one of them.
  static const String _folderPlaylists = 'playlists';

  /// Playlists are addressed by index, not name: media ids are split on '/', and a
  /// playlist named "Chill / Focus" would split wrongly.
  static const String _playlistPrefix = 'pl';

  /// "Shuffle everything in this folder", shown as the first row of each track
  /// list (one tap instead of scrolling a long list while driving).
  static const String _shufflePrefix = 'shuffle';

  /// Mirrors isPlaying so the listener below reacts only to play/pause changes,
  /// not to every state write.
  bool _wasPlaying = false;

  /// True once playback has started in this process. Distinguishes a live app from
  /// a process Android restarted just to deliver a stray media key.
  bool _playedInThisProcess = false;

  AuvyAudioHandler(this._playerNotifier) {
    // Push player state changes to the lock screen and notification.
    _playerNotifier.addListener((state) {
       // Record real listening activity on both play and pause; pausing then pressing
       // play on headphones is the case the resume window exists for.
       if (state.isPlaying != _wasPlaying) {
         _wasPlaying = state.isPlaying;
         if (state.isPlaying) _playedInThisProcess = true;
         markUserPlayback();
         // The idle shutdown timer follows the player state rather than which control
         // was used. In-app play/pause bypasses this handler, so arming and cancelling
         // the timer only in the handler's own methods could stop the service mid-track.
         // The per-method calls below remain as an earlier, harmless trigger.
         if (state.isPlaying) {
           _cancelIdleKillTimer();
         } else {
           _scheduleIdleKillTimer();
         }
       }
       broadcastState();
    });
    // Home-screen widget: receive its like taps. State pushes happen in
    // broadcastState.
    WidgetService.configure();
    WidgetService.onToggleLike = _toggleLikeFromSystem;
  }

  /// Toggles the current track's like from the notification or widget heart, then
  /// re-broadcasts so both icons update.
  void _toggleLikeFromSystem() {
    final song = _playerNotifier.currentState.currentSong;
    if (song == null) return;
    try {
      _playerNotifier.ref.read(libraryProvider.notifier).toggleSongLike(song);
    } catch (_) {
      return;
    }
    _lastBroadcastSig = null; // like isn't in the player state — force re-send
    broadcastState();
  }

  /// The notification heart is a setRating control (see broadcastState).
  @override
  Future<void> setRating(Rating rating, [Map<String, dynamic>? extras]) async {
    _toggleLikeFromSystem();
  }

  @override
  Future<dynamic> customAction(String name, [Map<String, dynamic>? extras]) async {
    if (name == 'toggleLike') {
      _toggleLikeFromSystem();
      return null;
    }
    // The notification's repeat button, using the same method as the player page.
    if (name == 'cycleRepeat') {
      _playerNotifier.cycleRepeatMode();
      return null;
    }
    return super.customAction(name, extras);
  }

  // --- Background control overrides ---

  /// The play/pause media button. The default toggles on every click, and some
  /// Bluetooth accessories re-send the click every ~2 s, which made playback flip
  /// back and forth. Only the first click in a one-second window counts.
  @override
  Future<void> click([MediaButton button = MediaButton.media]) async {
    if (button == MediaButton.media) {
      final now = DateTime.now();
      final last = _lastMediaClickAt;
      _lastMediaClickAt = now;
      if (last != null && now.difference(last) < const Duration(milliseconds: 1000)) {
        return; // swallow the spurious repeated click
      }
    }
    return super.click(button);
  }

  /// Rejects a PLAY that was not meant for Auvy.
  ///
  /// Every call to [play] comes from outside the app (in-app play/pause goes
  /// straight to `PlayerNotifier.togglePlay()`). A Bluetooth headset connected to
  /// both a phone and a computer sends its play key to both, so pressing play for
  /// the computer can start Auvy on the phone.
  ///
  /// `isMusicActive()` only knows about this device, so it cannot detect audio
  /// coming from the other host. The main signal is how recently the user was
  /// listening: a genuine "resume on my headphones" follows a recent pause, while a
  /// misrouted key arrives with no recent listening. The last-listening time is
  /// persisted so a real resume still works after Android kills the process.
  Future<bool> _shouldIgnoreExternalPlay() async {
    final state = _playerNotifier.currentState;

    // Already playing, nothing to guard.
    if (state.isPlaying) return false;

    // Nothing loaded: a play with no track would only wake an unused process.
    if (state.currentSong == null) {
      print('STOP: Ignoring external PLAY: nothing loaded to play');
      return true;
    }

    // The app is in the foreground, so the user is here: trust them.
    if (WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed) {
      return false;
    }

    // This process has been playing: trust the press.
    //
    // Checking `isMusicActive()` here would misread Auvy's own output (which lingers
    // for a moment after pausing) as another app playing, and drop a real press from
    // the notification. The misrouted-key case is a restarted or never-played
    // process, handled below.
    if (_playedInThisProcess) return false;

    // The "start from headset button" setting. Checked after the trust above,
    // because notification buttons arrive as the same media-button events as a
    // headset press and would otherwise be blocked too.
    if (!ListeningPolicy.allowExternalPlayStart) {
      print('STOP: Ignoring external PLAY: "Start from headset button" is off '
          'and nothing has played in this process');
      return true;
    }

    // Another app on this device owns the output.
    if (await NativeAudioEngine.isMusicActive()) {
      print('STOP: Ignoring external PLAY: another app on this device is already '
          'playing (misrouted media button)');
      return true;
    }

    final lastUse = await _lastUserPlaybackAt();
    if (lastUse == null) {
      // No playback in this process and no recent history: almost certainly a
      // resumption restart triggered by a stray key.
      print('STOP: Ignoring external PLAY: no recent playback by this user');
      return true;
    }
    final idle = DateTime.now().difference(lastUse);
    if (idle > _kResumeWindow) {
      print('STOP: Ignoring external PLAY: Auvy has been idle for '
          '${idle.inMinutes}m (> ${_kResumeWindow.inMinutes}m) and is not in the '
          'foreground — treating as a misrouted media button');
      return true;
    }
    return false;
  }

  /// How long after the user's last playback an external PLAY is still honoured:
  /// long enough to pause, walk away and resume from the headset; short enough that
  /// a stray key later in the day cannot start the app.
  static const Duration _kResumeWindow = Duration(minutes: 30);

  static const String _kLastPlaybackPref = 'auvy_last_playback_at';

  /// Persisted, because Android media resumption starts from a fresh process where
  /// an in-memory value would be empty.
  Future<DateTime?> _lastUserPlaybackAt() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final ms = prefs.getInt(_kLastPlaybackPref);
      if (ms == null) return null;
      return DateTime.fromMillisecondsSinceEpoch(ms);
    } catch (_) {
      return null;
    }
  }

  /// Recorded whenever playback runs, so the window measures real listening.
  static Future<void> markUserPlayback() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setInt(
          _kLastPlaybackPref, DateTime.now().millisecondsSinceEpoch);
    } catch (_) {
      // A missed stamp only costs one rejected resume, never a wrong play.
    }
  }

  /// Whether a resume nobody asked for (play when a device connects) is plausible.
  ///
  /// Stricter than [_shouldIgnoreExternalPlay]: a device connection is not a
  /// gesture aimed at Auvy, so the media-button setting does not apply here, and a
  /// live session is required rather than trusted.
  Future<bool> unsolicitedResumeIsPlausible() async {
    // Another app is already playing through the new device; don't start on top.
    // Safe to check here because it runs after the route settles and only when Auvy
    // has been paused since before the connection.
    if (await NativeAudioEngine.isMusicActive()) {
      print('STOP: not resuming on device connect: another app on this device '
          'already owns the output');
      return false;
    }

    // Requires playback in this process. Unlike a button press, a device
    // connection must not revive an app the user closed, so persisted history is
    // not accepted here.
    if (!_playedInThisProcess) {
      print('STOP: not resuming on device connect: nothing has played in this '
          'process, so there is no session to continue — a device connection is '
          'not a request aimed at Auvy');
      return false;
    }
    return true;
  }

  @override
  Future<void> play() async {
    if (await _shouldIgnoreExternalPlay()) return;
    _cancelIdleKillTimer();
    _stopped = false;
    // Only resume when actually paused. togglePlay() flips the state, so calling it
    // while already playing would pause instead.
    if (!_playerNotifier.currentState.isPlaying) {
      _playerNotifier.togglePlay();
    }
    broadcastState();
  }

  @override
  Future<void> pause() async {
    if (_playerNotifier.currentState.isPlaying) {
      // Only external controls reach here, so this line tells a pause the listener
      // asked for from one that "happened by itself".
      print('media controls: pause (headset, notification, lock screen or watch)');
      _playerNotifier.togglePlay();
    }
    _scheduleIdleKillTimer();
    broadcastState();
  }

  @override
  Future<void> skipToNext() async {
    _cancelIdleKillTimer();
    await _playerNotifier.playNext();
  }

  @override
  Future<void> skipToPrevious() async {
    _cancelIdleKillTimer();
    await _playerNotifier.playPrevious();
  }

  @override
  Future<void> seek(Duration position) async {
    // Goes through the notifier's seek so the in-app and system seek bars both jump
    // at once.
    _lastBroadcastSig = null;
    _playerNotifier.seek(position);
    broadcastState();
  }

  @override
  Future<void> setRepeatMode(AudioServiceRepeatMode repeatMode) async {
    final targetMode = switch (repeatMode) {
      AudioServiceRepeatMode.none => RepeatMode.off,
      AudioServiceRepeatMode.one => RepeatMode.one,
      AudioServiceRepeatMode.all || AudioServiceRepeatMode.group => RepeatMode.all,
    };
    print('AuvyAudioHandler: setRepeatMode $repeatMode -> $targetMode');
    _playerNotifier.setRepeatMode(targetMode);
    broadcastState();
  }

  @override
  Future<void> setShuffleMode(AudioServiceShuffleMode shuffleMode) async {
    final targetShuffle = shuffleMode != AudioServiceShuffleMode.none;
    print('AuvyAudioHandler: setShuffleMode $shuffleMode -> targetShuffle=$targetShuffle');
    if (_playerNotifier.currentState.isShuffle != targetShuffle) {
      _playerNotifier.toggleShuffle();
      broadcastState();
    }
  }

  @override
  Future<void> fastForward([Duration interval = const Duration(seconds: 15)]) async {
    final currentPos = _playerNotifier.currentState.position;
    final duration = _playerNotifier.currentState.duration;
    final newPos = currentPos + interval;
    print('AuvyAudioHandler: fastForward +$interval ($currentPos -> $newPos)');
    await seek(duration > Duration.zero && newPos > duration ? duration : newPos);
  }

  @override
  Future<void> rewind([Duration interval = const Duration(seconds: 15)]) async {
    final currentPos = _playerNotifier.currentState.position;
    final newPos = currentPos - interval;
    print('AuvyAudioHandler: rewind -$interval ($currentPos -> $newPos)');
    await seek(newPos < Duration.zero ? Duration.zero : newPos);
  }

  @override
  Future<void> setSpeed(double speed) async {
    print('AuvyAudioHandler: setSpeed $speed');
    _playerNotifier.setSpeed(speed);
    broadcastState();
  }

  /// Serves both Android Auto's browse root and the Android 11+ media-resumption
  /// root.
  ///
  /// For the resumption root the last played track is returned, so the system
  /// media control can resume Auvy after it was closed. Unwanted starts are still
  /// blocked by [_shouldIgnoreExternalPlay]: a play into a cold process with no
  /// recent listening is refused.
  @override
  Future<MediaItem?> getMediaItem(String mediaId) async {
    if (mediaId == _resumeMediaId) return await _lastPlayedItem();
    return null;
  }

  @override
  Future<List<MediaItem>> getChildren(String parentMediaId,
      [Map<String, dynamic>? options]) async {
    if (parentMediaId == AudioService.recentRootId) {
      final item = await _lastPlayedItem();
      return item == null ? const [] : [item];
    }

    MediaItem folder(String id, String title) => MediaItem(
          id: id,
          title: title,
          playable: false,
          // Shown as a browsable folder rather than a track.
          extras: const {'android.media.browse.CONTENT_STYLE_BROWSABLE_HINT': 2},
        );

    if (parentMediaId == AudioService.browsableRootId) {
      return [
        folder(_folderLiked, 'Liked Songs'),
        folder(_folderPlaylists, 'Playlists'),
        folder(_folderTop50, 'My Top 50'),
        folder(_folderDownloads, 'Downloads'),
        folder(_folderCached, 'Cached'),
        folder(_folderRecent, 'Recently Played'),
      ];
    }

    // The Playlists folder: the user's playlists, addressed by index.
    if (parentMediaId == _folderPlaylists) {
      final names = _playlistNames();
      if (names.isEmpty) return const [];
      return [
        for (var i = 0; i < names.length; i++)
          MediaItem(
            id: '$_playlistPrefix/$i',
            title: names[i],
            // Track count, to tell playlists apart at a glance.
            artist: '${_songsForFolder('$_playlistPrefix/$i').length} songs',
            playable: false,
            extras: const {
              'android.media.browse.CONTENT_STYLE_BROWSABLE_HINT': 2
            },
          ),
      ];
    }

    final songs = _songsForFolder(parentMediaId);
    if (songs.isEmpty) return const [];
    return [
      // One tap to shuffle the whole folder (see [_shufflePrefix]).
      MediaItem(
        id: '$_shufflePrefix/$parentMediaId',
        title: 'Shuffle all',
        artist: '${songs.length} songs',
        playable: true,
      ),
      for (var i = 0; i < songs.length; i++)
        MediaItem(
          id: 'song/$parentMediaId/$i',
          title: songs[i].title,
          artist: songs[i].artist,
          album: songs[i].albumTitle,
          artUri: songs[i].image.startsWith('http')
              ? Uri.tryParse(songs[i].image)
              : null,
          playable: true,
        ),
    ];
  }

  /// The user's playlists in a stable order (sorted by name), matching how the
  /// browse tree numbered them, so a tap cannot play the wrong playlist.
  List<String> _playlistNames() {
    try {
      final lib = _playerNotifier.ref.read(libraryProvider);
      final names = lib.playlistSongs.keys
          .where((k) =>
              !kSystemLibraryTitles.contains(k) &&
              !isFreshReserveKey(k) &&
              k != _folderDownloads &&
              k != _folderCached &&
              (lib.playlistSongs[k]?.isNotEmpty ?? false))
          .toList()
        ..sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));
      return names;
    } catch (_) {
      return const [];
    }
  }

  /// Resolves a browse folder id to its songs from live state, so the car always
  /// matches the phone.
  List<Song> _songsForFolder(String folderId) {
    try {
      final lib = _playerNotifier.ref.read(libraryProvider);
      // 'pl/<index>': a user playlist, using the same stable order.
      if (folderId.startsWith('$_playlistPrefix/')) {
        final idx = int.tryParse(folderId.substring(_playlistPrefix.length + 1));
        final names = _playlistNames();
        if (idx == null || idx < 0 || idx >= names.length) return const [];
        return lib.playlistSongs[names[idx]] ?? const [];
      }
      switch (folderId) {
        case _folderLiked:
          return lib.likedSongs;
        case _folderTop50:
          return lib.playlistSongs['My Top 50'] ?? const [];
        case _folderDownloads:
          return lib.playlistSongs['Downloaded'] ?? const [];
        case _folderCached:
          return lib.playlistSongs['Cached'] ?? const [];
        case _folderRecent:
          return _playerNotifier.currentState.history;
        default:
          // Any other id is a user playlist name.
          return lib.playlistSongs[folderId] ?? const [];
      }
    } catch (_) {
      return const [];
    }
  }

  /// The media id the resumption control plays. A constant, because a raw stream
  /// URL (podcast or audiobook) is not safe to round-trip as a browse id.

  static const String _resumeMediaId = 'resume/last';

  /// The last played track, read from saved history so it works in a cold process,
  /// where live player state is still empty.
  Future<MediaItem?> _lastPlayedItem() async {
    // Live state wins when there is one.
    final live = _playerNotifier.currentState.currentSong;
    if (live != null) return _asResumeItem(live);
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString('auvy_history_v2');
      if (raw == null || raw.isEmpty) return null;
      final decoded = jsonDecode(raw);
      if (decoded is! List || decoded.isEmpty) return null;
      // History is newest-first; each entry is {'s': <song>, 't': <timestamp>}.
      final first = decoded.first;
      if (first is! Map) return null;
      final songMap = first['s'];
      if (songMap is! Map) return null;
      return _asResumeItem(Song.fromMap(Map<String, dynamic>.from(songMap)));
    } catch (_) {
      // Malformed history must not break the browse tree Android Auto shares.
      return null;
    }
  }

  MediaItem _asResumeItem(Song s) => MediaItem(
        id: _resumeMediaId,
        title: s.title,
        artist: s.artist,
        album: s.albumTitle,
        artUri: s.image.startsWith('http') ? Uri.tryParse(s.image) : null,
        playable: true,
      );

  /// Plays an item chosen on a car display or the resumption control. A track
  /// plays with the folder it came from as its queue, so next and previous
  /// behave as they do in the app.
  @override
  Future<void> playFromMediaId(String mediaId,
      [Map<String, dynamic>? extras]) async {
    // The resumption control. Routed through play() so the misrouted-key guard
    // still applies; the normal launch path restores the queue.
    if (mediaId == _resumeMediaId) {
      _cancelIdleKillTimer();
      _stopped = false;
      final live = _playerNotifier.currentState.currentSong;
      if (live != null) {
        await play();
        return;
      }
      final item = await _lastPlayedItem();
      if (item == null) return;
      // Cold start: load the saved history entry so play() has something to resume.
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString('auvy_history_v2');
      if (raw == null || raw.isEmpty) return;
      try {
        final decoded = jsonDecode(raw);
        if (decoded is! List || decoded.isEmpty) return;
        final first = decoded.first;
        if (first is! Map) return;
        final songMap = first['s'];
        if (songMap is! Map) return;
        await _playerNotifier.playSong(
          Song.fromMap(Map<String, dynamic>.from(songMap)),
          source: 'Resumed',
        );
      } catch (_) {
        // Nothing playable in history: do nothing rather than crash the service.
      }
      return;
    }

    // 'shuffle/<folderId>': play the folder in random order.
    if (mediaId.startsWith('$_shufflePrefix/')) {
      final folderId = mediaId.substring(_shufflePrefix.length + 1);
      final songs = List<Song>.from(_songsForFolder(folderId))..shuffle();
      if (songs.isEmpty) return;
      _cancelIdleKillTimer();
      _stopped = false;
      await _playerNotifier.playSong(songs.first,
          newQueue: songs, index: 0, source: 'Android Auto');
      return;
    }

    if (!mediaId.startsWith('song/')) return;
    // 'song/<folderId>/<index>'. A folder id can contain a slash ('pl/3'), so the
    // index is taken from the end.
    final parts = mediaId.split('/');
    if (parts.length < 3) return;
    final index = int.tryParse(parts.last) ?? -1;
    final folderId = parts.sublist(1, parts.length - 1).join('/');
    final songs = _songsForFolder(folderId);
    if (index < 0 || index >= songs.length) return;
    _cancelIdleKillTimer();
    _stopped = false;
    await _playerNotifier.playSong(
      songs[index],
      newQueue: songs,
      index: index,
      source: 'Android Auto',
    );
  }

  /// Voice search: "Hey Google, play … on Auvy".
  ///
  /// Looks in the library first (what people ask for in the car is usually already
  /// saved, and a local match plays instantly or with no signal), then searches
  /// the catalogue. Matching uses the same normalisation as [isSameTrack], so
  /// "play dandelions" finds "Dandelions (Official Video)".
  @override
  Future<void> playFromSearch(String query,
      [Map<String, dynamic>? extras]) async {
    final q = normalizedTrackTitle(query);
    if (q.isEmpty) return;

    final candidates = <Song>[];
    try {
      final lib = _playerNotifier.ref.read(libraryProvider);
      candidates
        ..addAll(lib.likedSongs)
        ..addAll(_playerNotifier.currentState.history);
      for (final list in lib.playlistSongs.values) {
        candidates.addAll(list);
      }
    } catch (_) {}

    Song? best;
    var bestScore = 0.0;
    final seen = <String>{};
    for (final song in candidates) {
      if (!seen.add(song.id)) continue;
      final score = _voiceScore(q, song);
      if (score > bestScore) {
        bestScore = score;
        best = song;
      }
    }

    // 0.5 means the artist matched but not the title, a valid "play some <artist>"
    // request; anything lower is a coincidence and would play the wrong thing.
    if (best != null && bestScore >= 0.5) {
      _cancelIdleKillTimer();
      _stopped = false;
      // For an artist-shaped request, queue the artist's tracks so playback continues.
      final queue = bestScore < 0.9
          ? candidates
              .where((s) =>
                  normalizedPrimaryArtist(s.artist) ==
                  normalizedPrimaryArtist(best!.artist))
              .toList()
          : <Song>[best];
      final index = queue.indexWhere((s) => s.id == best!.id);
      await _playerNotifier.playSong(best,
          newQueue: queue.isEmpty ? [best] : queue,
          index: index < 0 ? 0 : index,
          source: 'Voice search');
      return;
    }

    // Nothing in the library: search the catalogue. A failure here means the
    // assistant reports it found nothing.
    try {
      final results = await SearchService().search(query, 'song');
      if (results.isEmpty) return;
      _cancelIdleKillTimer();
      _stopped = false;
      await _playerNotifier.playSong(results.first,
          newQueue: results.take(25).toList(),
          index: 0,
          source: 'Voice search');
    } catch (_) {}
  }

  /// 1.0 exact title · 0.9 title contains the query · 0.5 artist match.
  /// Deliberately simple: voice input produces well-formed words, so fuzzy
  /// matching would only add chances to play the wrong song.
  double _voiceScore(String normalizedQuery, Song song) {
    final title = normalizedTrackTitle(song.title);
    if (title.isEmpty) return 0;
    if (title == normalizedQuery) return 1.0;
    if (title.contains(normalizedQuery) || normalizedQuery.contains(title)) {
      return 0.9;
    }
    final artist = normalizedPrimaryArtist(song.artist);
    if (artist.isNotEmpty &&
        (normalizedQuery.contains(artist) || artist == normalizedQuery)) {
      return 0.5;
    }
    return 0;
  }

  @override
  Future<void> stop() async {
    _cancelIdleKillTimer();
    _stopped = true;
    await NativeAudioEngine.pause();
    // Broadcast a final idle state with no controls, so every controller treats
    // the session as ended, then let audio_service stop the service.
    _lastBroadcastSig = null;
    playbackState.add(playbackState.value.copyWith(
      controls: const [],
      systemActions: const {},
      processingState: AudioProcessingState.idle,
      playing: false,
    ));
    await super.stop();
  }

  /// The app was swiped out of recents. If music is playing, keep playing (the
  /// foreground service keeps the process alive); only tear down when paused or
  /// idle.
  @override
  Future<void> onTaskRemoved() async {
    // Loading counts as playing: during a track transition isPlaying is briefly
    // false, and a swipe then must not end the session.
    if (_playerNotifier.currentState.isPlaying ||
        _playerNotifier.currentState.isLoading) {
      return; // playing → survive the swipe, like every other music app
    }
    _cancelIdleKillTimer();
    await NativeAudioEngine.stop();
    // The engine is now empty, so a later play reloads the track.
    _playerNotifier.markNativeUnloaded();
    await stop();
  }

  // --- State broadcasting ---

  void broadcastState() {
    final state = _playerNotifier.currentState;

    // Session ended: stay silent until playback really restarts, or the dismissed
    // notification would reappear.
    if (_stopped) {
      if (state.isPlaying || state.isLoading) {
        _stopped = false; // a real new play — revive the session
      } else {
        return;
      }
    }

    final isPlaying = state.isPlaying;
    final isLiked = _isSongLiked(state.currentSong?.id);

    // Nothing the system cares about changed: skip the platform call.
    final sig = '$isPlaying|$isLiked|${state.isLoading}|${state.repeatMode}|'
        '${state.isShuffle}|${state.speed}|${state.position.inSeconds}|'
        '${state.duration.inSeconds}|${state.currentSong?.id}';
    if (sig == _lastBroadcastSig) return;
    _lastBroadcastSig = sig;

    // Mirror into the home-screen widget (it has its own dedupe).
    WidgetService.push(
      title: state.currentSong?.title ?? '',
      artist: state.currentSong?.displayArtist ?? '',
      imageUrl: state.currentSong?.image ?? '',
      isPlaying: isPlaying,
      isLiked: isLiked,
      hasSong: state.currentSong != null,
    );

    final isRadio = state.currentSong?.mediaKind == MediaKind.liveStream;

    // Convert to audio_service constants.
    final repeatMode = state.repeatMode == RepeatMode.one 
        ? AudioServiceRepeatMode.one 
        : (state.repeatMode == RepeatMode.all ? AudioServiceRepeatMode.all : AudioServiceRepeatMode.none);

    playbackState.add(playbackState.value.copyWith(
      // Live radio: next, previous and repeat do nothing, so show only play/pause.
      controls: isRadio
          ? [
              isPlaying ? MediaControl.pause : MediaControl.play,
            ]
          : [
              MediaControl.custom(
                androidIcon: switch (state.repeatMode) {
                  RepeatMode.one => 'drawable/ic_repeat_one',
                  RepeatMode.all => 'drawable/ic_repeat_on',
                  _ => 'drawable/ic_repeat_off',
                },
                // The label is read by TalkBack and shown by Android Auto, so it names the
                // current mode.
                label: switch (state.repeatMode) {
                  RepeatMode.one => 'Repeat one',
                  RepeatMode.all => 'Repeat all',
                  _ => 'Repeat off',
                },
                name: 'cycleRepeat',
              ),
              MediaControl.skipToPrevious,
              isPlaying ? MediaControl.pause : MediaControl.play,
              MediaControl.skipToNext,
              MediaControl(
                androidIcon: isLiked ? 'drawable/ic_liked' : 'drawable/ic_notliked',
                label: isLiked ? 'Unlike' : 'Like',
                action: MediaAction.setRating,
              ),
            ],
      systemActions: isRadio
          ? {
              MediaAction.play,
              MediaAction.pause,
              MediaAction.stop,
            }
          : {
              MediaAction.play,
              MediaAction.pause,
              MediaAction.seek,
              MediaAction.skipToNext,
              MediaAction.skipToPrevious,
              MediaAction.setRepeatMode,
              MediaAction.setShuffleMode,
              MediaAction.fastForward,
              MediaAction.rewind,
              MediaAction.setRating,
            },
      // Collapsed notification: one button for radio, three transport buttons
      // otherwise.
      androidCompactActionIndices: isRadio ? const [0] : const [1, 2, 3],
      // Loading counts as playing for the service: during an auto-advance isPlaying
      // is briefly false, and dropping out of the foreground then would let Doze cut
      // the network mid-resolve. The play/pause icon still follows the real isPlaying.
      playing: isPlaying || state.isLoading,
      // A loaded track is ready whether playing or paused. Reporting idle while paused
      // made controllers treat playback as ended and re-issue play.
      processingState:
          state.isLoading ? AudioProcessingState.loading : AudioProcessingState.ready,
      // Live position for the system seek bar; zero for live radio, which has none.
      updatePosition: isRadio ? Duration.zero : state.position,
      bufferedPosition: isRadio ? Duration.zero : state.position,
      speed: state.speed <= 0 ? 1.0 : state.speed,
      repeatMode: repeatMode,
      shuffleMode: state.isShuffle ? AudioServiceShuffleMode.all : AudioServiceShuffleMode.none,
    ));

    // The system seek bar also needs the item's duration, which arrives after the
    // item is set, so refresh it here. Radio keeps a null duration (live broadcast).
    final mi = mediaItem.value;
    if (mi != null && !isRadio && state.duration > Duration.zero && mi.duration != state.duration) {
      mediaItem.add(mi.copyWith(duration: state.duration));
    }
  }

  bool _isSongLiked(String? songId) {
    if (songId == null || songId.isEmpty) return false;
    try {
      return _playerNotifier.ref.read(libraryProvider).likedSongIds.contains(songId);
    } catch (e) {
      return false;
    }
  }

  void _scheduleIdleKillTimer() {
    _cancelIdleKillTimer();
    _idleKillTimer = Timer(_maxIdleDuration, () {
      print('1 hour idle — stopping background service');
      _playerNotifier.stopAndDismiss();
    });
  }

  void _cancelIdleKillTimer() {
    _idleKillTimer?.cancel();
    _idleKillTimer = null;
  }

  void setCurrentMediaItem(MediaItem item) {
    _stopped = false; // a new track is being staged — session is live again
    final currentSong = _playerNotifier.currentState.currentSong;
    final isLiveRadio = currentSong?.mediaKind == MediaKind.liveStream ||
        (item.id.startsWith('http') && item.album != 'Podcast' && currentSong?.mediaKind != MediaKind.audiobook);
    // A null duration tells Android this is a live broadcast with no seek bar.
    Duration? validDuration = isLiveRadio ? null : item.duration;
    if (validDuration == Duration.zero) validDuration = null;

    final updatedItem = item.copyWith(duration: validDuration);
    mediaItem.add(updatedItem);
    broadcastState();
  }

  void setQueueIndex(int index) {
    broadcastState();
  }

}