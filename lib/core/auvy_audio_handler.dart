import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:flutter/widgets.dart'
    show WidgetsBinding, AppLifecycleState;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:audio_service/audio_service.dart';
import 'package:auvy/providers/player_provider.dart';
import 'package:auvy/core/native_audio_engine.dart';
import 'package:auvy/providers/library_provider.dart';
import 'package:auvy/providers/theme_provider.dart';
import 'package:auvy/data/dummy_data.dart' show Song;
import 'package:auvy/services/widget_service.dart';
import 'package:auvy/presentation/widgets/auvy_image.dart';
import 'package:auvy/services/app_commands.dart';
import 'package:auvy/services/device_presence_service.dart';
import 'package:auvy/services/music_link_resolver.dart';
import 'package:auvy/logic/music_link.dart';
import 'package:auvy/services/listening_policy.dart';
import 'package:auvy/services/audio_output_service.dart';
import 'package:auvy/logic/library_integrity.dart'
    show kSystemLibraryTitles, kWeeklyDiscoveryTitle, isFreshReserveKey;
import 'package:auvy/logic/track_identity.dart';
import 'package:auvy/services/search_service.dart';
import 'package:auvy/logic/media_kind.dart';

/// Handles every playback control from outside the app: notification and lock
/// screen, headset buttons, Android Auto, Bluetooth devices, voice search, and the
/// commands Siri, Shortcuts, widgets and tiles send (see [AppCommands]).
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

  // Where the last broadcast put the track, when, and whether it was moving: the
  // system (lock screen, notification, watch, Bluetooth) moves the progress on
  // from these by itself, so a playing track needs a new broadcast only when the
  // position jumps (see [positionJumped]).
  int _lastBroadcastPosMs = 0;
  int _lastBroadcastAtMs = 0;
  bool _lastBroadcastMoving = false;

  /// Whether [posMs] is off from where the system thinks the track is by more
  /// than a normal tick's drift: a seek, a restart, a heal. The progress itself
  /// is extrapolated by the system from the last broadcast, so the per-second
  /// broadcasts the position used to force (four media-session calls a second,
  /// fanned out to the lock screen, watches and Bluetooth headphones) only
  /// repeated what it already knew.
  @visibleForTesting
  static bool positionJumped({required int lastPosMs, required int lastAtMs, required bool moving,
      required double speed, required int posMs, required int nowMs}) {
    final expected = lastPosMs + (moving ? ((nowMs - lastAtMs) * speed).round() : 0);
    return (posMs - expected).abs() > 2500;
  }

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

  /// When playback last stopped for a reason other than the listener pausing in
  /// the app: a headset or lock-screen pause, Android taking audio focus, a
  /// device change. See [isEarbudBounce].
  DateTime? _autoPausedAt;

  /// When [pause] last ran (headset, lock screen, Siri, a widget). Its toggle
  /// stamps the in-app "deliberate" pause too, so this is what tells them apart.
  DateTime? _externalPauseAt;

  AuvyAudioHandler(this._playerNotifier) {
    // Push player state changes to the lock screen and notification.
    _playerNotifier.addListener((state) {
       // Record real listening activity on both play and pause; pausing then pressing
       // play on headphones is the case the resume window exists for.
       if (state.isPlaying != _wasPlaying) {
         _wasPlaying = state.isPlaying;
         if (state.isPlaying) _playedInThisProcess = true;
         if (!state.isPlaying) {
           // A pause from inside the app stamps lastDeliberatePauseAt a moment
           // before isPlaying turns false; anything else is a pause the
           // listener didn't make here.
           final now = DateTime.now();
           bool recent(DateTime? t) => t != null && now.difference(t) < const Duration(seconds: 2);
           final byTap = !recent(_externalPauseAt) && recent(_playerNotifier.lastDeliberatePauseAt);
           _autoPausedAt = byTap ? null : now;
         }
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
    // Siri, Shortcuts, widgets, Control Center, the Quick Settings tile and the
    // icon's shortcuts. See AppCommands.
    AppCommands.attachPlayback(_runCommand);
    // Your other phones' controls (the output sheet's "Your other devices").
    // Only the commands DevicePresenceService lets through reach here; a
    // take-over never comes from AppCommands.
    DevicePresenceService.instance.onCommand = (name, args) async {
      if (name == 'takeOver') {
        final h = args['handoff'];
        if (h is Map) await _playerNotifier.takeOverHandoff(Map<String, dynamic>.from(h));
        return;
      }
      await _runCommand(name, args);
    };
    _publishPlaylists();
    try {
      _playerNotifier.ref.listen(
        libraryProvider.select((l) => l.playlistSongs.keys.join('\n')),
        (_, __) => _publishPlaylists(),
      );
      // A new accent repaints the widgets' play button straight away.
      _playerNotifier.ref.listen(themeProvider, (_, __) {
        _lastBroadcastSig = null;
        broadcastState();
      });
    } catch (_) {
      // No live library to follow (a test container); the startup list stands.
    }
  }

  /// Where the song is playing from, for the widgets' small label: the
  /// playlist or album, or what the autoplay picked it for ("Based on …").
  String _widgetContext(PlayerState state) {
    final title = (state.contextTitle ?? '').trim();
    if (title.isNotEmpty) return title;
    return (state.locationName ?? '').trim();
  }

  /// The accent the widgets draw their play button in: the user's chosen
  /// colour, as an ARGB int.
  int? _widgetAccent() {
    try {
      return _playerNotifier.ref.read(themeProvider).toARGB32();
    } catch (_) {
      return null;
    }
  }

  // --- Commands from outside the app's screens (AppCommands) ---

  String? _lastPublishedPlaylists;

  /// Sends the playlist names to native when they change, for Siri's playlist
  /// picker and Android's pinned shortcuts.
  void _publishPlaylists() {
    final names = _playlistNames();
    final sig = names.join('\n');
    if (sig == _lastPublishedPlaylists) return;
    _lastPublishedPlaylists = sig;
    AppCommands.publishPlaylists(names);
  }

  /// Runs a playback command and returns what Siri should say (null: nothing,
  /// the system's now-playing speaks for itself).
  Future<String?> _runCommand(String name, Map<String, dynamic> args) async {
    final source = switch ((args['from'] ?? '').toString()) {
      'siri' => 'Siri',
      'widget' => 'Widget',
      'control' => 'Control Center',
      'tile' => 'Quick Settings',
      'voice' => 'Voice search',
      'connect' => 'Another device',
      _ => 'Shortcut',
    };
    final current = _playerNotifier.currentState.currentSong;
    switch (name) {
      case 'togglePlay':
        if (_playerNotifier.currentState.isPlaying) {
          _pauseFrom = source;
          await pause();
          return 'Paused';
        }
        return _resumeOnRequest();
      case 'play':
        if (_playerNotifier.currentState.isPlaying) return null;
        return _resumeOnRequest();
      case 'pause':
        if (!_playerNotifier.currentState.isPlaying) return null;
        _pauseFrom = source;
        await pause();
        return 'Paused';
      case 'next':
        if (current == null) return 'Nothing is playing';
        await skipToNext();
        return null;
      case 'previous':
        if (current == null) return 'Nothing is playing';
        await skipToPrevious();
        return null;
      case 'toggleLike':
        if (current == null) return 'Nothing is playing';
        _toggleLikeFromSystem();
        return _isSongLiked(current.id)
            ? 'Added ${current.title} to Liked Songs'
            : 'Removed ${current.title} from Liked Songs';
      case 'playCollection':
        return _playCollection((args['id'] ?? '').toString(),
            shuffle: args['shuffle'] == true, source: source);
      case 'playPlaylist':
        final wanted = (args['name'] ?? '').toString();
        // The library's own lists by their shown names (a pinned shortcut for
        // "Downloads" carries that name, not the folder key).
        final builtIn = switch (wanted.trim().toLowerCase()) {
          'downloads' => 'downloads',
          'weekly discovery' => 'weekly',
          'my top 50' => 'top50',
          _ => null,
        };
        if (builtIn != null) {
          return _playCollection(builtIn, shuffle: args['shuffle'] == true, source: source);
        }
        final key = _findPlaylistKey(wanted);
        if (key == null) return "Couldn't find a playlist called $wanted";
        if (key == _folderLiked) {
          return _playCollection('liked', shuffle: args['shuffle'] == true, source: source);
        }
        return _playList(key, _songsForFolder(key), shuffle: args['shuffle'] == true, source: source);
      case 'searchPlay':
        final query = (args['query'] ?? '').toString().trim();
        if (query.isEmpty) return 'What should I play?';
        return await _playFromQuery(query, source: source) ?? "Couldn't find $query";
      case 'openLink':
        return _openLinkInBackground((args['url'] ?? '').toString());
    }
    return null;
  }

  /// Resumes because the listener asked (Siri, a widget, a tile): no
  /// stray-press guard, since none of these can be pressed by accident from
  /// another device. With nothing loaded, picks up the last song played.
  Future<String?> _resumeOnRequest() async {
    _cancelIdleKillTimer();
    _stopped = false;
    final state = _playerNotifier.currentState;
    if (state.currentSong == null) {
      await playFromMediaId(_resumeMediaId);
      final now = _playerNotifier.currentState.currentSong;
      return now == null ? 'Nothing to resume yet' : 'Playing ${now.title}';
    }
    if (!state.isPlaying) _playerNotifier.togglePlay(haptic: false);
    broadcastState();
    return null;
  }

  Future<String> _playCollection(String id, {required bool shuffle, required String source}) async {
    switch (id) {
      case 'liked':
        return _playList('Liked Songs', _songsForFolder(_folderLiked), shuffle: shuffle, source: source);
      case 'weekly':
        return _playList(kWeeklyDiscoveryTitle, _songsForFolder(kWeeklyDiscoveryTitle),
            shuffle: shuffle, source: source);
      case 'top50':
        return _playList('My Top 50', _songsForFolder(_folderTop50), shuffle: shuffle, source: source);
      case 'downloads':
        // The library's own name as the context, so "playing from" matches
        // the Downloads row.
        return _playList('Downloads', _songsForFolder(_folderDownloads),
            shuffle: shuffle, source: source);
      case 'recent':
        return _playList('Recently played', _songsForFolder(_folderRecent),
            shuffle: shuffle, source: source, contextKey: 'Recently played');
      case 'library':
        // Everything saved, once each, always shuffled: in order it would just be
        // Liked Songs followed by the first playlist.
        final seen = <String>{};
        final all = <Song>[
          for (final s in _songsForFolder(_folderLiked)) if (seen.add(s.id)) s,
          for (final name in _playlistNames())
            for (final s in _songsForFolder(name)) if (seen.add(s.id)) s,
        ];
        return _playList('your library', all, shuffle: true, source: source, contextKey: 'Library');
    }
    return "Auvy doesn't have that list";
  }

  /// Plays [songs] the way the playlist page does, so the queue context (and
  /// what "playing from" says) is the same whichever way it was started.
  Future<String> _playList(String label, List<Song> songs,
      {required bool shuffle, required String source, String? contextKey}) async {
    if (songs.isEmpty) {
      return label == 'your library' ? 'Your library is empty' : '$label is empty';
    }
    final queue = List<Song>.from(songs);
    if (shuffle) queue.shuffle();
    _cancelIdleKillTimer();
    _stopped = false;
    final key = contextKey ?? label;
    await _playerNotifier.playSong(queue.first,
        newQueue: queue,
        index: 0,
        source: source,
        locationName: label,
        contextId: key,
        contextType: 'playlist',
        contextTitle: label);
    return shuffle ? 'Shuffling $label' : 'Playing $label';
  }

  /// The library key for a playlist the listener named: exact (ignoring case)
  /// first, then the closest one containing it.
  String? _findPlaylistKey(String wanted) {
    final w = wanted.trim().toLowerCase();
    if (w.isEmpty) return null;
    if (w == 'liked songs' || w == 'liked' || w == 'my likes') return _folderLiked;
    final names = [..._playlistNames(), kWeeklyDiscoveryTitle, 'My Top 50'];
    for (final n in names) {
      if (n.toLowerCase() == w) return n;
    }
    final partial = names.where((n) => n.toLowerCase().contains(w) || w.contains(n.toLowerCase())).toList()
      ..sort((a, b) => a.length.compareTo(b.length));
    return partial.isEmpty ? null : partial.first;
  }

  Future<String> _openLinkInBackground(String text) async {
    final link = MusicLink.find(text);
    if (link == null) return "That isn't a Spotify, Apple Music or YouTube link";
    try {
      final library = _playerNotifier.ref.read(libraryProvider.notifier);
      final resolver = MusicLinkResolver(library);
      final resolved = await resolver.resolve(link);
      final played = await MusicLinkPlayer(resolver, _playerNotifier, library).play(resolved);
      return played ? 'Playing ${resolved.title}' : "Couldn't find those songs on YouTube Music";
    } on MusicLinkException catch (e) {
      return e.message;
    }
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
        print('media controls: repeated ${button.name} click within 1 s ignored');
        return; // swallow the spurious repeated click
      }
    }
    print('media controls: ${button.name} button click (headset or accessory)');
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

  /// How soon after a pause nobody made in the app a headset PLAY is taken for
  /// the earbud's own doing. Galaxy Buds sent theirs 2.7 to 5.9 s after the
  /// pause, on iPhone and Android alike.
  static const Duration kEarbudBounceWindow = Duration(seconds: 7);

  /// Whether a headset PLAY now is an earbud sensor rather than a press: the
  /// setting is on, headphones are the output, and playback stopped less than
  /// [kEarbudBounceWindow] ago for a reason other than the listener pausing in
  /// the app. A deliberate re-tap that soon is caught too; the setting turns it off.
  static bool isEarbudBounce({
    required bool enabled,
    required DateTime? autoPausedAt,
    required DateTime now,
    required String? route,
  }) {
    if (!enabled || autoPausedAt == null) return false;
    if (route != 'bluetooth' && route != 'headphones' && route != 'usb') return false;
    final since = now.difference(autoPausedAt);
    return !since.isNegative && since < kEarbudBounceWindow;
  }

  Future<bool> _isEarbudBounceNow() async {
    final pausedAt = _autoPausedAt;
    if (pausedAt == null || !ListeningPolicy.ignoreEarbudBounce) return false;
    final route = await AudioOutputService.currentRoute();
    final now = DateTime.now();
    if (!isEarbudBounce(
        enabled: ListeningPolicy.ignoreEarbudBounce, autoPausedAt: pausedAt, now: now, route: route)) {
      return false;
    }
    print('STOP: Ignoring headset PLAY ${now.difference(pausedAt).inMilliseconds} ms after a pause '
        "nobody made in the app (an earbud going into its case or back in, not a press). "
        'Settings → Playback → "Ignore earbud play after a pause" turns this off.');
    // Said once: a second press after this one is honoured.
    _autoPausedAt = null;
    broadcastState();
    return true;
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
    if (await _isEarbudBounceNow()) return;
    // Logged like pause() below: without it, music an earbud started looked the
    // same in the activity log as music that started by itself.
    if (!_playerNotifier.currentState.isPlaying) {
      print('media controls: play (headset, notification, lock screen or watch)');
    }
    _cancelIdleKillTimer();
    _stopped = false;
    // Only resume when actually paused. togglePlay() flips the state, so calling it
    // while already playing would pause instead.
    if (!_playerNotifier.currentState.isPlaying) {
      _playerNotifier.togglePlay();
    }
    broadcastState();
  }

  /// Who is pausing, for the log line in [pause]: set by [_runCommand] for Siri
  /// and the widgets, which reach [pause] the same way a headset does.
  String _pauseFrom = 'headset, notification, lock screen or watch';

  @override
  Future<void> pause() async {
    _externalPauseAt = DateTime.now();
    final from = _pauseFrom;
    _pauseFrom = 'headset, notification, lock screen or watch';
    if (_playerNotifier.currentState.isPlaying) {
      // Only external controls reach here, so this line tells a pause the listener
      // asked for from one that "happened by itself".
      print('media controls: pause ($from)');
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
        // The library's folder is 'Downloads'; 'Downloaded' is only this
        // folder's id in the browse tree. Looked up under the id, the car's
        // Downloads and "play my downloads" were always empty (fixed
        // 2026-10-17).
        case _folderDownloads:
          return lib.playlistSongs['Downloads'] ?? const [];
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

  /// Android's voice search ("play … on Auvy"), from whichever assistant or car
  /// system supports the media session's play-from-search.
  ///
  /// Looks in the library first (what people ask for in the car is usually already
  /// saved, and a local match plays instantly or with no signal), then searches
  /// the catalogue. Matching uses the same normalisation as [isSameTrack], so
  /// "play dandelions" finds "Dandelions (Official Video)".
  @override
  Future<void> playFromSearch(String query,
      [Map<String, dynamic>? extras]) async {
    await _playFromQuery(query, source: 'Voice search');
  }

  /// Plays what [query] asks for and says what that was, or null when nothing
  /// matched. A list first ("liked songs", "weekly discovery", a playlist's
  /// name), then the library, then the catalogue. Shared by Android's voice
  /// search and Siri's "Search Auvy".
  Future<String?> _playFromQuery(String query, {required String source}) async {
    final lower = query.toLowerCase().trim();
    final asked = lower.replaceFirst(RegExp(r'^(my |the )'), '').replaceFirst(RegExp(r' playlist$'), '').trim();
    if (asked == 'liked songs' || asked == 'likes' || asked == 'liked' || asked == 'favourites' ||
        asked == 'favorites') {
      return _playCollection('liked', shuffle: false, source: source);
    }
    if (asked == 'weekly discovery' || asked == 'discovery') {
      return _playCollection('weekly', shuffle: false, source: source);
    }
    if (asked == 'top 50' || asked == 'top fifty') {
      return _playCollection('top50', shuffle: false, source: source);
    }
    for (final name in _playlistNames()) {
      if (name.toLowerCase() == asked) {
        return _playList(name, _songsForFolder(name), shuffle: false, source: source);
      }
    }

    final q = normalizedTrackTitle(query);
    if (q.isEmpty) return null;

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
          source: source);
      return bestScore < 0.9 ? 'Playing ${best.artist}' : 'Playing ${best.title}';
    }

    // Nothing in the library: search the catalogue. A failure here means the
    // assistant reports it found nothing.
    try {
      final results = await SearchService().search(query, 'song');
      if (results.isEmpty) return null;
      _cancelIdleKillTimer();
      _stopped = false;
      await _playerNotifier.playSong(results.first,
          newQueue: results.take(25).toList(),
          index: 0,
          source: source);
      return 'Playing ${results.first.title} by ${results.first.artist}';
    } catch (_) {
      return null;
    }
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

    // Nothing the system cares about changed: skip the platform call. The position
    // isn't in the signature: the system moves the progress on by itself, so only a
    // jump (a seek) is news.
    final sig = '$isPlaying|$isLiked|${state.isLoading}|${state.repeatMode}|'
        '${state.isShuffle}|${state.speed}|'
        '${state.duration.inSeconds}|${state.currentSong?.id}';
    final nowMs = DateTime.now().millisecondsSinceEpoch;
    final posMs = state.position.inMilliseconds;
    final jumped = positionJumped(
        lastPosMs: _lastBroadcastPosMs, lastAtMs: _lastBroadcastAtMs, moving: _lastBroadcastMoving,
        speed: state.speed, posMs: posMs, nowMs: nowMs);
    if (sig == _lastBroadcastSig && !jumped) return;
    _lastBroadcastSig = sig;
    _lastBroadcastPosMs = posMs;
    _lastBroadcastAtMs = nowMs;
    _lastBroadcastMoving = isPlaying && !state.isLoading;

    // Mirror into the home-screen widget (it has its own dedupe).
    WidgetService.push(
      title: state.currentSong?.title ?? '',
      artist: state.currentSong?.displayArtist ?? '',
      // The widgets draw the cover at 200-300 px and fetch it themselves,
      // outside the image cache: the full-size original was ~250 KB per song,
      // whether or not a widget was on the home screen.
      imageUrl: AuvyImage.sizedUrl(state.currentSong?.image ?? '', 360),
      isPlaying: isPlaying,
      isLiked: isLiked,
      hasSong: state.currentSong != null,
      accent: _widgetAccent(),
      context: _widgetContext(state),
      positionMs: state.position.inMilliseconds,
      durationMs: state.duration.inMilliseconds,
      upNext: [
        for (final s in state.queue.skip(1).take(3))
          s.displayArtist.isEmpty ? s.title : '${s.title} — ${s.displayArtist}',
      ],
    );

    // Your other phones' output sheets (it has its own dedupe and throttle).
    DevicePresenceService.instance.publish(
      hasSong: state.currentSong != null,
      playing: isPlaying,
      songId: state.currentSong?.id ?? '',
      title: state.currentSong?.title ?? '',
      artist: state.currentSong?.displayArtist ?? '',
      image: state.currentSong?.image ?? '',
      positionMs: state.position.inMilliseconds,
      durationMs: state.duration.inMilliseconds,
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