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
import 'package:auvy/services/rich_presence_service.dart';
import 'package:auvy/services/widget_service.dart';
import 'package:auvy/services/listening_policy.dart';
import 'package:auvy/logic/library_integrity.dart' show kSystemLibraryTitles;
import 'package:auvy/logic/track_identity.dart';
import 'package:auvy/services/search_service.dart';

/// Everything OUTSIDE the app that can control playback talks to this class.
///
/// The notification and lock-screen controls, a headset button, a car head unit
/// over Android Auto, a Bluetooth speaker, Google Assistant. The audio_service
/// package registers this handler with the OS, and the OS then calls play(),
/// pause(), skipToNext(), setRating() and so on directly.
///
/// IT DOES NOT PLAY AUDIO. The actual player is native (media3/ExoPlayer, via
/// NativePlayerManager). This translates an outside request into a call on the
/// app's own player logic and mirrors the resulting state back out so the
/// notification shows the right thing.
///
/// The awkward part, and the reason several methods here look defensive: Android
/// will hand this class a play() request that the USER never made. A car
/// stereo connecting, a Bluetooth device waking, or media resumption after a
/// reboot all arrive as an ordinary play(). Auvy starting music on its own in
/// someone's car is a bad surprise, so _shouldIgnoreExternalPlay decides which
/// requests to honour, using markUserPlayback() to know when a human last
/// actually pressed something.
class AuvyAudioHandler extends BaseAudioHandler with QueueHandler {
  final PlayerNotifier _playerNotifier;
  Timer? _idleKillTimer;
  static const Duration _maxIdleDuration = Duration(hours: 1);

  // Timestamp of the last accepted media-button "click". Used to debounce a
  // storm of repeated play-pause clicks (see [click]).
  DateTime? _lastMediaClickAt;

  // Signature of the last broadcast. broadcastState() is wired to EVERY
  // PlayerNotifier state change — including per-frame UI writes like the
  // mini-player swipe progress, and each call crossed the platform channel.
  // Skipping identical broadcasts removes that per-frame native chatter
  // (position is folded ~1×/sec, so the system seekbar stays live).
  String? _lastBroadcastSig;

  // True after stop() tore the session down. broadcastState() is wired to
  // EVERY PlayerNotifier state change, so without this gate the very next
  // state write after a stop (a settings save, connectivity tick, position
  // fold…) re-added a playbackState and RESURRECTED the media notification —
  // the "dismiss it and it comes back" bug. Cleared when playback genuinely
  // restarts (new track staged / play command / loading).
  bool _stopped = false;

  // Android Auto browse tree
  // Folder ids under the browsable root. Song leaves are 'song/<folder>/<index>'
  // so a tap can resolve back to the exact list it was browsed from and play
  // with that list as the queue.
  static const String _folderLiked = 'liked';
  static const String _folderTop50 = 'top50';
  static const String _folderDownloads = 'Downloaded';
  static const String _folderCached = 'Cached';
  static const String _folderRecent = 'recent-played';

  /// The folder that lists the user's own playlists, and the prefix for one of
  /// them.
  ///
  /// PLAYLISTS WERE UNREACHABLE IN THE CAR. [_songsForFolder] has always
  /// resolved an unknown folder id as a playlist NAME, but nothing ever listed
  /// them at the root, so the code that could serve them had no way of being
  /// asked, and the one thing a driver most wants ("play my gym playlist") was
  /// the one thing the tree did not offer.
  static const String _folderPlaylists = 'playlists';

  /// A playlist is addressed by INDEX, never by name. Media ids are '/'-split to
  /// resolve them, and a playlist called "Chill / Focus" would split into
  /// nonsense — silently playing the wrong list, or nothing.
  static const String _playlistPrefix = 'pl';

  /// "Shuffle everything in this folder", the first row of every track list.
  /// Metrolist puts the same affordance at the top of each of its Auto lists,
  /// and in a car it matters more than anywhere else: it is one tap instead of
  /// scrolling a 300-row list at a red light.
  static const String _shufflePrefix = 'shuffle';

  /// Mirrors `isPlaying` so the listener below can stamp only on TRANSITIONS.
  /// The notifier fires on every state write (including per-frame UI values), so
  /// stamping unconditionally would mean a prefs write per frame.
  bool _wasPlaying = false;

  /// True once playback has actually STARTED in this process.
  ///
  /// Distinguishes a live app the user is controlling from a process Android
  /// resurrected to deliver a stray media key — the case the external-play guard
  /// exists for. See _shouldIgnoreExternalPlay.
  bool _playedInThisProcess = false;

  AuvyAudioHandler(this._playerNotifier) {
    // Manually broadcast state changes to the lock screen when the UI provider changes
    _playerNotifier.addListener((state) {
       // Record the user's real listening activity at both edges: starting is
       // obvious, and PAUSING is the one that matters most — "I paused, then
       // pressed play on my headphones" is the case the resume window exists to
       // keep working. See _shouldIgnoreExternalPlay.
       if (state.isPlaying != _wasPlaying) {
         _wasPlaying = state.isPlaying;
         if (state.isPlaying) _playedInThisProcess = true;
         markUserPlayback();
       }
       broadcastState();
    });
    // Home-screen widget: receive its LIKE taps; state pushes happen inside
    // broadcastState (same dedupe'd pipeline as the notification).
    WidgetService.configure();
    WidgetService.onToggleLike = _toggleLikeFromSystem;
    // Discord Rich Presence: load the saved toggle/token up-front so the very
    // first track of the session can already publish.
    RichPresenceService().ensureLoaded();
  }

  /// Toggle the current track's like from a SYSTEM surface (media notification
  /// heart / home-screen widget heart), then re-broadcast so both surfaces
  /// flip their icon immediately.
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

  /// The notification heart is declared as a setRating control
  /// (see broadcastState). Without this override it was a dead button.
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
    // The notification's repeat button. Delegates to the SAME method the player
    // page's repeat button calls, so the two can't drift into different cycles —
    // and the state broadcast that follows repaints the notification icon.
    if (name == 'cycleRepeat') {
      _playerNotifier.cycleRepeatMode();
      return null;
    }
    return super.customAction(name, extras);
  }

  // --- Background Control Overrides ---

  /// The play-pause media button. [BaseAudioHandler.click] toggles — it calls
  /// [play] when paused and [pause] when playing, so a *repeated* click stream
  /// alternates playback on every event. Some BT accessories / media controllers
  /// and Android's media-resumption re-deliver this click on a ~2s cadence,
  /// which is exactly what produced the "pauses then plays every 2 seconds" bug
  /// (the player never stopped buffering — playWhenReady was being flipped by
  /// these phantom clicks). Debounce so only the first click in a 1s window acts;
  /// no real user toggles play/pause twice within a second, let alone forever.
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

  /// Rejects a PLAY that was never meant for Auvy.
  ///
  /// EVERY call to [play] is EXTERNAL. In-app play/pause goes straight to
  /// `PlayerNotifier.togglePlay()`; this handler is only reached by the
  /// notification, a media button, AVRCP, Android Auto or the Assistant.
  ///
  /// THE FAILURE THIS FIXES. A multipoint Bluetooth headset paired to both a
  /// phone and a computer forwards its AVRCP transport keys over BOTH links.
  /// Press play on the computer and the phone receives PLAY too; Android routes
  /// it to whichever app owns the most recent media session — Auvy, and on
  /// Android 11+ media resumption it will RESTART Auvy's service just to deliver
  /// it. Auvy then plays into a headset that is busy serving the PC. That is the
  /// "the app comes alive out of nowhere, like a virus" report.
  ///
  /// AND WHY THE OBVIOUS CHECK DOESN'T WORK: `AudioManager.isMusicActive()`
  /// is per-DEVICE. When the audio is coming from the computer, the phone is
  /// playing nothing, so that call returns false and tells us nothing. It is
  /// still checked below because it catches the same-device variant (a misrouted
  /// key while another app on the phone owns the output), but it cannot be the
  /// primary defence. Android exposes no way to ask "is this headset currently
  /// streaming from its other host?".
  ///
  /// So the primary signal is RECENCY OF THE USER'S OWN INTENT. A genuine
  /// "press play on my headphones to resume" follows the user pausing Auvy a
  /// short while ago. A misrouted key arrives with no such history — often hours
  /// later, or into a process Android only just restarted. [_kResumeWindow] is
  /// the line between the two, and the timestamp is PERSISTED so a legitimate
  /// resume still works after Android kills the process.
  Future<bool> _shouldIgnoreExternalPlay() async {
    final state = _playerNotifier.currentState;

    // Already ours and playing — nothing to guard.
    if (state.isPlaying) return false;

    // Nothing staged. A PLAY with no track used to land in togglePlay() on an
    // empty player, which is how a stray key woke a never-used process.
    if (state.currentSong == null) {
      print('STOP: Ignoring external PLAY: nothing loaded to play');
      return true;
    }

    // In the foreground the user is demonstrably right here, looking at Auvy —
    // never second-guess them.
    if (WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed) {
      return false;
    }

    // The certain answer for anyone who knows their headset misroutes keys.
    // Checked after the foreground test so the in-app controls always work.
    if (!ListeningPolicy.allowExternalPlayStart) {
      print('STOP: Ignoring external PLAY: "Start from headset button" is off');
      return true;
    }

    // We are alive AND we have been playing: trust the press
    //
    // THE BUG THIS FIXES: the notification's play button did nothing, while the
    // same action inside the app worked — inconsistently, which made it look
    // like a flaky button.
    //
    // It was `isMusicActive()` below. That call is per-DEVICE and counts ANY app
    // INCLUDING US, and the audio stack does not settle the instant ExoPlayer
    // pauses. So: pause from the notification, press play a moment later, and the
    // guard read Auvy's own lingering output as "another app is already playing"
    // and dropped the press silently. Opening the app made it work only because
    // the foreground check above short-circuits first, which is exactly the
    // asymmetry that was reported.
    //
    // The misrouted-key scenario the guard exists for is a process Android
    // RESURRECTED to deliver a key, or one that never played. If this process has
    // played something and still holds that track, the notification the user just
    // touched exists BECAUSE we are alive, and the checks below cannot tell us
    // apart from the interloper they are looking for. Trusting here keeps the
    // protection where it works and stops it eating real presses.
    if (_playedInThisProcess) return false;

    // Another app on THIS device owns the output.
    if (await NativeAudioEngine.isMusicActive()) {
      print('STOP: Ignoring external PLAY: another app on this device is already '
          'playing (misrouted media button)');
      return true;
    }

    final lastUse = await _lastUserPlaybackAt();
    if (lastUse == null) {
      // No record at all: this process did not play anything, and there is no
      // persisted history. Overwhelmingly a resumption-restart triggered by a
      // stray key rather than a person.
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

  /// How long after the user's last real playback an external PLAY is still
  /// taken at face value.
  ///
  /// 30 minutes is deliberately generous for the case it protects (you paused,
  /// walked away, came back, pressed the headset button) and short enough that a
  /// stray key later in the day cannot start the app. It is NOT a guess at
  /// "session length" — it is the window in which resuming is still what a
  /// person would expect.
  static const Duration _kResumeWindow = Duration(minutes: 30);

  static const String _kLastPlaybackPref = 'auvy_last_playback_at';

  /// Persisted so it survives the process death that Android's media resumption
  /// then restarts from — an in-memory field would be null exactly when this
  /// check matters most.
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

  /// Stamped whenever playback genuinely runs, so the window above measures the
  /// user's own listening rather than app lifetime.
  static Future<void> markUserPlayback() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setInt(
          _kLastPlaybackPref, DateTime.now().millisecondsSinceEpoch);
    } catch (_) {
      // A missed stamp only costs one rejected resume, never a wrong play.
    }
  }

  @override
  Future<void> play() async {
    if (await _shouldIgnoreExternalPlay()) return;
    _cancelIdleKillTimer();
    _stopped = false;
    // IDEMPOTENT: only flip when actually paused. togglePlay() is RELATIVE
    // (it flips state + drives resume/pause natively), so calling it
    // unconditionally here meant a stray PLAY command while already playing —
    // or a storm of media-button clicks — would invert the state and fight the
    // pause() handler, producing the rapid play/pause oscillation (and haptic
    // buzzing). Guarding on the current state makes play/pause absolute.
    if (!_playerNotifier.currentState.isPlaying) {
      _playerNotifier.togglePlay();
    }
    broadcastState();
  }

  @override
  Future<void> pause() async {
    if (_playerNotifier.currentState.isPlaying) {
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
    // Through the notifier's optimistic seek (not NativeAudioEngine directly) so
    // the in-app bar AND the system seekbar jump instantly and stale pre-seek
    // ticks are suppressed — same anti-glitch path as the player page slider.
    _playerNotifier.seek(position);
  }

  /// Android Auto asks for [AudioService.browsableRootId]; SystemUI's Android
  /// 11+ MEDIA RESUMPTION probe asks for [AudioService.recentRootId].
  ///
  /// This root used to be refused, AND refusing it had a visible cost
  ///
  /// It returned an empty list so that resumption stayed permanently off: serving
  /// the recent root is what let the system resurrect the app after it had been
  /// closed, which was reported as the app "coming alive out of nowhere".
  ///
  /// But the media pill is offered by the system anyway — the MediaBrowserService
  /// intent-filter in the manifest is what makes it appear, and Android Auto needs
  /// that filter. So the pill was there, and pressing play on it after swiping
  /// Auvy out of recents produced the platform's own failure message:
  ///
  ///   "Something went wrong in Auvy. Try again in app."
  ///
  /// Empty means "there is nothing to resume", so the system had nothing to play
  /// and said so. A control that is shown and cannot work is worse than either
  /// alternative.
  ///
  /// So the root is served now, with the last track, and the thing that actually
  /// prevented the resurrection stays where it belongs, in
  /// [_shouldIgnoreExternalPlay]: a PLAY that arrives at a cold process with no
  /// recent listening behind it is still refused. The difference is that a
  /// deliberate tap now works, because a tap follows recent listening.
  ///
  /// The pill may reappear after being dismissed — that is the system caching
  /// this root, and it is the price of the pill working at all. If it becomes the
  /// bigger annoyance, returning `const []` here restores the old behaviour and
  /// the error message with it.
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
          // Auto renders this as a browsable folder rather than a track row.
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

    // The Playlists folder: the user's own playlists, addressed by index.
    if (parentMediaId == _folderPlaylists) {
      final names = _playlistNames();
      if (names.isEmpty) return const [];
      return [
        for (var i = 0; i < names.length; i++)
          MediaItem(
            id: '$_playlistPrefix/$i',
            title: names[i],
            // Track count, because a bare list of names says nothing about
            // which one is the big one you actually want.
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
      // One tap to shuffle the whole folder. See [_shufflePrefix].
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

  /// The user's own playlists, in a STABLE order — the same order the ids in the
  /// browse tree are resolved against, so a list that changes between the browse
  /// and the tap cannot play the wrong playlist. Sorted by name rather than by
  /// library order, which the user can reorder at any time.
  List<String> _playlistNames() {
    try {
      final lib = _playerNotifier.ref.read(libraryProvider);
      final names = lib.playlistSongs.keys
          .where((k) =>
              !kSystemLibraryTitles.contains(k) &&
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

  /// Resolve a browse folder id to its songs. Reads live provider state, so
  /// what the car shows always matches the phone.
  List<Song> _songsForFolder(String folderId) {
    try {
      final lib = _playerNotifier.ref.read(libraryProvider);
      // 'pl/<index>' — a user playlist, resolved through the same stable
      // ordering the browse tree used to number it.
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

  /// A track was tapped on the car display. Play it with the folder it came
  /// from as the queue, so next/previous work exactly like in the app.

  /// The media id the resumption chip plays. A constant rather than the track's
  /// own id: the id must round-trip through the system unchanged, and a raw
  /// stream URL (a podcast or audiobook chapter) is not safe to hand back as a
  /// browse id.
  static const String _resumeMediaId = 'resume/last';

  /// The last track this user played, read from the persisted history so it works
  /// in a COLD process, which is the only case resumption exists for. The live
  /// player state is empty at that point, so reading it would answer "nothing to
  /// resume" and reproduce the bug.
  Future<MediaItem?> _lastPlayedItem() async {
    // The live state wins when there is one: mid-session it is more current than
    // anything on disk.
    final live = _playerNotifier.currentState.currentSong;
    if (live != null) return _asResumeItem(live);
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString('auvy_history_v2');
      if (raw == null || raw.isEmpty) return null;
      final decoded = jsonDecode(raw);
      if (decoded is! List || decoded.isEmpty) return null;
      // History is newest-first, and each entry is {'s': <song>, 't': <stamp>}.
      final first = decoded.first;
      if (first is! Map) return null;
      final songMap = first['s'];
      if (songMap is! Map) return null;
      return _asResumeItem(Song.fromMap(Map<String, dynamic>.from(songMap)));
    } catch (_) {
      // A malformed history must not make the whole browse tree fail — Android
      // Auto shares this call path.
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
  @override
  Future<void> playFromMediaId(String mediaId,
      [Map<String, dynamic>? extras]) async {
    // The resumption chip
    //
    // Handled FIRST, and it is the half that actually makes the pill work:
    // serving the recent root only tells the system what to offer, and without
    // this the tap would resolve to nothing and fail the same way it did before.
    //
    // Routed through play() rather than starting the track directly, so the
    // misrouted-key guard in _shouldIgnoreExternalPlay still applies — a cold
    // process with no recent listening behind it is refused here too. The queue
    // is restored by the normal launch path, so resuming plays into whatever the
    // user was listening to rather than a queue of one.
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
      // Cold start: the player has nothing staged, so the persisted history entry
      // is loaded before play() has something to resume.
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
        // Nothing playable in the history — better to do nothing than to crash
        // the service the system just started.
      }
      return;
    }

    // 'shuffle/<folderId>' — play the folder in a random order.
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
    // 'song/<folderId>/<index>', and a folder id can itself contain a slash
    // ('pl/3'), so the INDEX is taken from the end rather than from position 2.
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

  /// "hey google, play … on Auvy"
  ///
  /// Without this the assistant could open the app and nothing else: Auvy had no
  /// search entry point at all, so every voice request in the car failed
  /// silently. In a car, voice IS the interface — it is the one input a driver
  /// should be using.
  ///
  /// Answered from the LIBRARY first and only then from the network:
  ///
  ///  • What someone asks for in a car is overwhelmingly something they already
  ///    have, and a local hit plays instantly instead of waiting on a search
  ///    round-trip over a phone-tethered connection at 70mph.
  ///  • It also degrades honestly: with no signal, a library match still plays.
  ///
  /// Matching goes through the app's own identity rule (see [isSameTrack]'s
  /// normalisation) rather than a raw `contains`, so "play dandelions" finds
  /// "Dandelions (Official Video)" and "play ruth b" finds the artist's tracks.
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

    // 0.5 = the artist matched but the title did not, which is a legitimate
    // "play some <artist>" request; below that it is a coincidence of a shared
    // short word and playing something would be worse than saying nothing.
    if (best != null && bestScore >= 0.5) {
      _cancelIdleKillTimer();
      _stopped = false;
      // Queue the whole matched artist when the request was artist-shaped, so
      // "play Ruth B" keeps playing rather than stopping after one track.
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

    // Nothing local — ask the catalogue. Best-effort: a failure here means the
    // assistant said it could not find anything, which is the truth.
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

  /// 1.0 exact title · 0.9 title contains the whole query · 0.5 artist match.
  ///
  /// Kept deliberately blunt. A fuzzy edit-distance ranker (Metrolist runs
  /// Jaro-Winkler here) buys accuracy on typos that voice input does not
  /// produce — the recogniser hands over well-formed words, and every point of
  /// looseness is a chance to play the wrong song, which in a car the user then
  /// has to fix while driving.
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
    // Broadcast a terminal IDLE state (no controls) so every controller —
    // notification, lock screen, BT — treats the session as ENDED rather than
    // paused-and-resumable, then let audio_service tear the service down.
    _lastBroadcastSig = null;
    playbackState.add(playbackState.value.copyWith(
      controls: const [],
      systemActions: const {},
      processingState: AudioProcessingState.idle,
      playing: false,
    ));
    await super.stop();
  }

  /// The user swiped Auvy out of the recent-apps list. Standard music-player
  /// behavior: if music is ACTIVELY PLAYING, keep playing (the foreground
  /// media service keeps the process alive and the notification stays up).
  /// Only when playback is paused/idle do we fully tear down — that still
  /// prevents the old "paused zombie service lingers forever" problem, since
  /// pause() also arms the 1-hour idle-kill timer.
  @override
  Future<void> onTaskRemoved() async {
    // isLoading counts as playing: a swipe during a track transition (the old
    // track ended, the next is resolving — isPlaying is false for those few
    // seconds) used to hit the teardown below and kill an actively-listening
    // session. Same rule the foreground-service state uses in broadcastState.
    if (_playerNotifier.currentState.isPlaying ||
        _playerNotifier.currentState.isLoading) {
      return; // playing → survive the swipe, like every other music app
    }
    _cancelIdleKillTimer();
    await NativeAudioEngine.stop();
    // The engine is empty now — make sure a later play tap reloads the track
    // instead of resuming into silence.
    _playerNotifier.markNativeUnloaded();
    await stop();
  }

  // --- State Broadcasting ---

  void broadcastState() {
    final state = _playerNotifier.currentState;

    // Torn down: stay silent until playback GENUINELY restarts. Re-adding a
    // playbackState here is exactly what re-posted the "zombie" notification
    // after the user dismissed it / swiped the app away.
    if (_stopped) {
      if (state.isPlaying || state.isLoading) {
        _stopped = false; // a real new play — revive the session
      } else {
        return;
      }
    }

    final isPlaying = state.isPlaying;
    final isLiked = _isSongLiked(state.currentSong?.id);

    // Nothing the SYSTEM cares about changed → skip the platform round-trip.
    final sig = '$isPlaying|$isLiked|${state.isLoading}|${state.repeatMode}|'
        '${state.isShuffle}|${state.speed}|${state.position.inSeconds}|'
        '${state.duration.inSeconds}|${state.currentSong?.id}';
    if (sig == _lastBroadcastSig) return;
    _lastBroadcastSig = sig;

    // Mirror into the home-screen widget (its own signature dedupe ignores
    // the per-second position churn that got us here).
    WidgetService.push(
      title: state.currentSong?.title ?? '',
      artist: state.currentSong?.displayArtist ?? '',
      imageUrl: state.currentSong?.image ?? '',
      isPlaying: isPlaying,
      isLiked: isLiked,
      hasSong: state.currentSong != null,
    );

    // Discord Rich Presence ("Listening to Auvy"). Self-deduping — only track
    // changes, play/pause flips and seeks actually cross the network.
    RichPresenceService().push(
      songId: state.currentSong?.id,
      title: state.currentSong?.title ?? '',
      artist: state.currentSong?.displayArtist ?? '',
      album: state.currentSong?.albumTitle ?? '',
      imageUrl: state.currentSong?.image ?? '',
      isPlaying: isPlaying,
      positionMs: state.position.inMilliseconds,
      durationMs: state.duration.inMilliseconds,
    );

    // Convert to AudioService constants
    final repeatMode = state.repeatMode == RepeatMode.one 
        ? AudioServiceRepeatMode.one 
        : (state.repeatMode == RepeatMode.all ? AudioServiceRepeatMode.all : AudioServiceRepeatMode.none);

    playbackState.add(playbackState.value.copyWith(
      // Five controls: Repeat · Prev · Play/Pause · Next · Like.
      //
      // Repeat leads and Like trails (they used to be Like · Prev · Play · Next).
      // The transport keeps the middle, which is where every media notification
      // puts it and where the thumb expects it; the two STATEFUL buttons sit on
      // the outside, so their changing icon never shifts play/pause around.
      //
      // Repeat is a `MediaControl.custom` rather than `MediaAction.setRepeatMode`:
      // a notification button carries no argument, and setRepeatMode needs a mode.
      // Routing it through `customAction('cycleRepeat')` lets the handler advance
      // off → all → one itself, matching the player page's own button.
      controls: [
        MediaControl.custom(
          androidIcon: switch (state.repeatMode) {
            RepeatMode.one => 'drawable/ic_repeat_one',
            RepeatMode.all => 'drawable/ic_repeat_on',
            _ => 'drawable/ic_repeat_off',
          },
          // The label is what TalkBack reads and what Android Auto shows, so it
          // states the CURRENT mode rather than the generic word "Repeat".
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
      systemActions: {
        MediaAction.play,
        MediaAction.pause,
        MediaAction.seek,
        MediaAction.skipToNext,
        MediaAction.skipToPrevious,
        // Declared so system surfaces that render repeat themselves (Android Auto,
        // Assistant) know the session supports it, not just our own button.
        MediaAction.setRepeatMode,
      },
      // COLLAPSED notification shows only 3 — the transport, not the two state
      // toggles. Indices shifted by one now that repeat took slot 0.
      androidCompactActionIndices: const [1, 2, 3],
      // Loading counts as "playing" for the SERVICE lifecycle: at a track-end
      // auto-advance isPlaying flips false while the next track resolves, and
      // with androidStopForegroundOnPause the service dropped out of foreground
      // for exactly that window — in Doze, Android cuts a non-foreground app's
      // network, so the resolve hung and playback silently stopped until the
      // app was reopened. Reporting playing through the loading window keeps
      // the foreground (Doze-exempt) status across the transition. The
      // play/pause ICON still follows the real isPlaying via `controls` above.
      playing: isPlaying || state.isLoading,
      // A loaded track is READY whether playing OR paused. Reporting `idle` while
      // paused was wrong and made media controllers / Android media-resumption
      // treat playback as ended and re-issue play — feeding the play/pause
      // oscillation. Only report `loading` while a track is actually resolving.
      processingState:
          state.isLoading ? AudioProcessingState.loading : AudioProcessingState.ready,
      // Feed live position so the system media widget (lock screen / notification)
      // shows a timestamp and a PROGRESSING slider. audio_service extrapolates the
      // position from updatePosition + (now - updateTime) * speed, so pushing this
      // ~twice a second (broadcastState fires on each position tick) keeps it live.
      // (audio_service auto-stamps updateTime=now on copyWith, then extrapolates
      // position as updatePosition + (now - updateTime) * speed for the slider.)
      updatePosition: state.position,
      bufferedPosition: state.position,
      speed: state.speed <= 0 ? 1.0 : state.speed,
      repeatMode: repeatMode,
      shuffleMode: state.isShuffle ? AudioServiceShuffleMode.all : AudioServiceShuffleMode.none,
    ));

    // The system slider also needs the MediaItem to carry a real duration. It
    // isn't known when the item is first set (it arrives via native onPosition),
    // so refresh it here once we have it.
    final mi = mediaItem.value;
    if (mi != null && state.duration > Duration.zero && mi.duration != state.duration) {
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
    final isLiveRadio = item.id.startsWith('http') && item.album != 'Podcast';
    Duration? validDuration = isLiveRadio ? const Duration(hours: 24) : item.duration;
    if (validDuration == Duration.zero) validDuration = null;

    final updatedItem = item.copyWith(duration: validDuration);
    mediaItem.add(updatedItem);
    broadcastState();
  }

  void setQueueIndex(int index) {
    broadcastState();
  }

}