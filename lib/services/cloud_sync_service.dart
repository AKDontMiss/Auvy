import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:encrypt/encrypt.dart' as enc;
import 'package:flutter/foundation.dart' show compute;

import 'package:auvy/logic/library_sync_split.dart';
import 'package:auvy/logic/stall_watchdog.dart';

/// Account-based cloud backup/restore of the user's data (listening history,
/// stats, intelligence/taste, library & playlists) so a reinstall + login with
/// the SAME account restores everything — Spotify-style.
///
/// Strategy: instead of refactoring every provider, we mirror the existing local
/// persistence verbatim. All user-data lives in a known set of SharedPreferences
/// blobs (the `intel_*` keys written by IntelligenceProvider and the
/// `auvy_library_data` blob written by LibraryProvider). Downloaded audio files
/// are intentionally NOT synced (they're disk cache and re-download on demand).
///
/// Storage format (v2, chunked)
/// Firestore hard-caps a document at 1 MiB. The original format packed every
/// blob into the ONE `user_backups/{uid}` document; an active library outgrows
/// that within weeks, after which every set() throws INVALID_ARGUMENT and
/// backups silently die while restore keeps serving the last under-limit push
/// (observed in the field: backups frozen months in the past). v2 therefore
/// stores each string blob split into part documents
/// `user_backups/{uid}/blobs/{key}.{i}`, each well under the limit, and keeps
/// only a small manifest on `user_backups/{uid}`: scalar keys, `backup_ms`,
/// and a `blobs` index of `key → part count`. The manifest is written with a
/// full set() (no merge) so pushing v2 also strips the legacy giant fields.
/// Restore still understands the legacy single-doc format, so pre-v2 backups
/// are picked up once and upgraded on the next push.
///
/// NOTE (Firestore security rules): the rules must cover the subcollection,
/// e.g. `match /user_backups/{userId}/{document=**} { allow read, write:
/// if request.auth != null && request.auth.uid == userId; }`.
///
/// Everything here is guarded by [_firebaseReady]: until a Firebase project is
/// configured (see setup notes in main.dart), every method is a safe no-op so
/// the app builds and runs exactly as before.
class CloudSyncService {
  CloudSyncService._();
  static final CloudSyncService instance = CloudSyncService._();

  /// Set once `Firebase.initializeApp()` succeeds in main(). Until then the
  /// service stays dormant.
  static bool _firebaseReady = false;

  /// Completes the moment Firebase finishes initialising.
  ///
  /// CALLERS THAT RUN AT STARTUP MUST AWAIT THIS, NOT TEST [isAvailable].
  ///
  /// `main()` initialises Firebase asynchronously and calls [markAvailable] when
  /// it lands; the account provider's own init fires as soon as the widget tree
  /// builds. Those race, and on a slower device the provider loses. Measured on a
  /// Tab S8:
  ///
  ///   22:55:35.157 enableCloudBackup: Firebase NOT available — staying local-only
  ///   22:55:35.434 Firebase ready — cloud sync enabled
  ///
  /// 277 ms apart, and because nothing retried, that device had NO cloud backup
  /// and no restore for the entire session, silently, on a perfectly healthy
  /// install. A boolean cannot express "not yet"; this future can.
  static final Completer<void> _readyCompleter = Completer<void>();

  /// Resolves when Firebase is ready. Never throws; pair it with a timeout if the
  /// caller cannot wait forever (a build with no Firebase project never
  /// completes, which is correct — it is not ready and never will be).
  static Future<void> get ready => _readyCompleter.future;

  static void markAvailable() {
    _firebaseReady = true;
    if (!_readyCompleter.isCompleted) _readyCompleter.complete();
  }

  static bool get isAvailable => _firebaseReady;

  String? _userId;
  Timer? _debounce;
  bool _restoring = false;

  // Local marker holding the backup timestamp we last pushed/restored, so we
  // don't needlessly re-restore our own data but DO pick up a newer backup made
  // on another device (or after a reinstall, where this is absent → 0).
  static const String _localMarkerKey = 'cloud_last_backup_ms';

  /// When this device first had a change the cloud has not accepted yet.
  ///
  /// Why a persisted flag AND NOT a timer
  ///
  /// THE BUG THIS FIXES. A change scheduled a push on an in-memory Timer: 30s
  /// of debounce, and then, if the 5-minute floor had not elapsed, ANOTHER
  /// Timer for the remainder. Closing the app killed the process and both
  /// timers with it, so the write was never issued at all. The change stayed
  /// in local prefs looking fine — until anything restored over it (a second
  /// device pushing, a reinstall, signing in again), at which point it was
  /// gone and had never existed anywhere else.
  ///
  /// A flag on disk outlives the process, so the next launch knows there is
  /// something owed and can settle it before anything else touches the data.
  static const String _pendingKey = 'cloud_pending_since_ms';

  /// The library blob. Named because it gets special handling in three places:
  /// the incremental split, the restore reassembly, and the destructive-restore
  /// guard.
  static const String _kLibraryKey = 'auvy_library_data';

  static const int _formatVersion = 2;

  /// The blob-name set the last "backup contains" line reported.
  ///
  /// A line that never changes carries information once
  ///
  /// That list is ~50 keys and 1.4KB, it is byte-identical on almost every push,
  /// and it was printed on every push: 89KB of one 264KB transcript, a third of
  /// the flight recorder given to a constant. It answers "is this key backed up",
  /// which is a question about the SET, so it is worth printing when the set
  /// changes and worth nothing when it does not.
  ///
  /// The per-push trail is not lost: the PUSHED line above it already reports
  /// `changed/total`, and "uploaded this push" still names what moved.
  static String? _loggedBlobSet;
  // Parts are capped at 200k UTF-16 code units: even if every char needed 4
  // UTF-8 bytes that's 800 KB — comfortably under the 1 MiB doc limit.
  static const int _chunkChars = 200000;
  // Keep a single batch commit well under Firestore's 10 MiB request limit.
  //
  // 3M, not 6M. The limit is on BYTES and this counts UTF-16 CODE UNITS. A
  // BMP character outside Latin-1 — any CJK title, and this app browses global
  // catalogues and 240 countries of radio — is 3 UTF-8 bytes per code unit. At
  // 6M that is up to 18 MB in a single commit, comfortably OVER the 10 MiB cap,
  // and the failure mode is a rejected batch mid-backup.
  //
  // 3M caps the worst case at ~9 MB. Latin-1 content simply seals a batch
  // sooner, which costs one extra round trip and nothing else.
  static const int _maxBatchChars = 3000000;

  /// Last push failure (null when the most recent push succeeded) and last
  /// successful push time — surfaced so sync problems are visible instead of
  /// silently freezing the backup.
  static String? lastPushError;
  static DateTime? lastPushSuccess;

  // key → part count currently in the cloud, used to delete stale part docs
  // when a blob shrinks. Loaded lazily from the manifest.
  Map<String, int> _cloudPartCounts = {};
  bool _partCountsLoaded = false;
  /// key → the push generation the cloud's parts for that key belong to.
  ///
  /// THIS IS WHAT MAKES A TORN PUSH DETECTABLE. Part docs are overwritten in
  /// place and the manifest is committed LAST, so a push that fails between
  /// batches leaves new part bytes indexed by the previous manifest. Counting
  /// parts cannot tell that apart from a good backup; a per-key stamp can.
  ///
  /// Per-KEY rather than one global generation because unchanged blobs are
  /// deliberately not re-uploaded — their parts keep the generation of whichever
  /// push last wrote them, and a global stamp would flag every one of them.
  Map<String, int> _cloudPartGens = {};

  /// The cloud `backup_ms` this session is entitled to overwrite: what it
  /// restored from, or what it last pushed itself.
  ///
  /// PRECONDITION FOR EVERY PUSH. A stamp newer than this can only have been
  /// written by another device on the same account, and overwriting it would
  /// destroy that device's library.
  int _knownCloudMs = 0;

  /// Set when a push was refused because the cloud had moved on. The next save
  /// restores first, so two devices converge instead of taking turns clobbering.
  bool _needsRemoteMergeBeforePush = false;

  /// True once a push has been held because the cloud copy is newer than what
  /// this session restored from. Cleared by a restore, which is the only thing
  /// that legitimately earns the right to overwrite that copy.
  bool get needsRemoteMerge => _needsRemoteMergeBeforePush;
  // key → signature of the last successfully pushed value, so unchanged blobs
  // (e.g. the heavy metadata ledger) aren't re-uploaded on every save.
  final Map<String, int> _pushedSig = {};

  /// Why the signatures are persisted
  ///
  /// This map used to live only in RAM, so it was EMPTY at every cold start and
  /// the first push of every launch re-uploaded everything. Measured on device
  /// (2026-08-18): `41/41 blob(s) uploaded` on a launch where nothing had
  /// changed, and, because `_sig`, `_encode` (AES-GCM + base64) and `_chunk` all
  /// run synchronously on the main isolate over every blob, `auvy_artwork_overrides_v2`
  /// and its base64 PNGs included — the stall watchdog caught the isolate blocked
  /// for **4614 ms** immediately before that line. That is the "UI freezes for a
  /// second and comes back" report: a blocked isolate submits no frame, which is
  /// why `dumpsys gfxinfo` showed no slow frames at all (worst 57 ms).
  ///
  /// Incremental sync was working WITHIN a session (36/36 → 0/36 → 2/37) which is
  /// exactly why this went unnoticed — it was only ever broken across launches.
  ///
  /// SAFE ONLY BECAUSE THE CLOUD SIDE IS CROSS-CHECKED. A persisted signature
  /// alone must never authorise skipping an upload: it says "these bytes were
  /// pushed once", not "those bytes are still readable in Firestore". The skip
  /// below additionally requires `knownParts > 0`, and that count comes from the
  /// CLOUD manifest, not from here. See the long note at the skip. Not knowing
  /// still means re-uploading.
  ///
  /// Scoped by uid: a different account has a different backup, and reusing
  /// signatures across accounts would skip uploads the new account never made.
  /// BUMP THIS WHENEVER [_sig] CHANGES. A stored value is only meaningful
  /// under the algorithm that produced it, and comparing across algorithms is
  /// how a blob gets skipped that should have been uploaded — silent staleness in
  /// the backup, which is the worst failure this class has.
  ///
  /// v1 → v2: _sig moved off `Object.hash`, which was randomly seeded per process
  /// and therefore never matched after a restart. Every v1 entry is noise now.
  static const String _kPushedSigPrefix = 'cloud_pushed_sigs_v2_';
  String get _pushedSigKey => '$_kPushedSigPrefix$_userId';

  /// Read the persisted signatures for this user into [_pushedSig].
  Future<void> _loadPushedSigs(SharedPreferences prefs) async {
    if (_pushedSig.isNotEmpty) return; // already warm this session
    try {
      final raw = prefs.getString(_pushedSigKey);
      if (raw == null || raw.isEmpty) return;
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return;
      decoded.forEach((k, v) {
        if (k is String && v is int) _pushedSig[k] = v;
      });
    } catch (_) {
      // A corrupt map simply means "sign nothing off" — the next push re-uploads,
      // which is the safe direction.
    }
  }

  Future<void> _savePushedSigs(SharedPreferences prefs) async {
    try {
      await prefs.setString(_pushedSigKey, jsonEncode(_pushedSig));
    } catch (_) {}
  }

  // C1 (Option 3) — per-user AES-GCM encrypter, set by account_provider from the
  // Cloudflare Worker's encKey. When present, blob values are ENCRYPTED at rest
  // in Firestore (only the authenticated account can obtain the key). Null → the
  // legacy plaintext path (unchanged) so nothing breaks until C1 is activated.
  enc.Encrypter? _encrypter;
  static const String _encMarker = 'enc:v1:';

  /// Set (base64url) the per-user backup encryption key, or null/'' to disable.
  void setBackupEncKey(String? base64UrlKey) {
    if (base64UrlKey == null || base64UrlKey.isEmpty) {
      _encrypter = null;
      return;
    }
    try {
      var s = base64UrlKey.replaceAll('-', '+').replaceAll('_', '/');
      while (s.length % 4 != 0) {
        s += '=';
      }
      final keyBytes = base64.decode(s); // 32 bytes → AES-256
      _encrypter = enc.Encrypter(enc.AES(enc.Key(keyBytes), mode: enc.AESMode.gcm));
      // Kept for the off-isolate encode. See [_encodeChunkOffThread].
      _keyBytes = keyBytes;
    } catch (_) {
      _encrypter = null;
      _keyBytes = null;
    }
  }

  // Encrypt a blob value for storage when a key is set; plaintext otherwise.
  // The encrypt-side counterpart of [_decode] used to live here. It now runs in
  // a background isolate instead. See [_encodeAndChunkIsolate] at the bottom of
  // this file, so there is deliberately no main-isolate encode path left to
  // call by accident. [_decode] stays: restore is not the hot path, and it runs
  // once per launch rather than on every save.

  /// The AES key as raw bytes, kept so the encode can run in another isolate.
  ///
  /// An [enc.Encrypter] is not worth sending across an isolate boundary, so the
  /// key travels instead and the Encrypter is rebuilt on the far side. Held in
  /// memory only, exactly like [_encrypter] — it is never written anywhere.
  List<int>? _keyBytes;

  /// [_encode] + [_chunk] on a BACKGROUND ISOLATE.
  ///
  /// THIS IS THE 6.4-SECOND FREEZE. AES-GCM over the whole backup, then
  /// base64, then chunking, all of it synchronous on the main isolate. Measured
  /// on device:
  ///
  /// STALL 3907ms (worst 6370ms) ← cloudSync.encode[intel_first_timestamps]
  ///        + cloudSync.encode[intel_play_counts] + …
  ///
  /// No single key is slow; there are just many of them and they add up. A
  /// blocked isolate submits no frame at all, so this never appeared in frame
  /// stats — it only showed up once StallWatchdog was watching for it.
  ///
  /// One `compute` PER KEY rather than one for the whole set. That is a handful
  /// of extra isolate spawns, and it is the right trade twice over: the spawn
  /// cost is paid off the UI thread where nobody can see it, and it keeps the
  /// surrounding push loop — manifest indices, part generations, leftover-part
  /// deletion — exactly as it was. This function writes the cloud backup, and
  /// restructuring it for a marginally cheaper spawn is how a backup bug gets
  /// introduced. Wall-clock is slightly worse; the UI no longer freezes.
  Future<List<String>> _encodeChunkOffThread(String plain) {
    return compute(
      _encodeAndChunkIsolate,
      _EncodeRequest(plain, _encrypter == null ? null : _keyBytes),
    );
  }

  /// Decrypt a whole restore off the main isolate, in ONE hop.
  ///
  /// THE COMMENT ON [_decode] SAID "RESTORE IS NOT THE HOT PATH". IT IS.
  /// Restore runs during login, and doing AES-GCM + base64 over the entire
  /// backup synchronously froze the UI. Caught by the watchdog on device:
  ///
  ///   restore: fetched 39/39 blob(s) in 8131ms
  /// STALL 3823ms (worst 3823ms, #1)
  /// library restored: 17 part(s), 11 playlist(s), 440000 bytes
  ///
  /// A blocked isolate submits no frames, so this was not merely a wait — it was
  /// the app hung mid-login. Exactly the fault already documented for the PUSH
  /// side (blocked up to 6370 ms), which is why the fix is the same shape.
  ///
  /// ONE `compute` for every blob rather than one per blob: spawning an isolate
  /// costs more than decrypting a small value, and the push side pays per-blob
  /// only because its loop has to interleave manifest bookkeeping. Restore has no
  /// such constraint — it just needs the plaintext.
  Future<Map<String, String?>> _decodeAllOffThread(
      Map<String, String> joined) {
    if (joined.isEmpty) return Future.value(const {});
    return compute(
      _decodeAllIsolate,
      _DecodeRequest(joined, _encrypter == null ? null : _keyBytes),
    );
  }

  // User-data string blobs to mirror. Transient CDN page caches
  // (cached_home_data, artist_*, album_*) are deliberately excluded.
  static const List<String> _stringKeys = [
    // A skipped release is a real decision worth carrying to a new device.
    // `last_checked_at` / `last_seen_tag` deliberately are NOT backed up — they
    // describe this install's history, not a preference.
    'auvy_update_skipped_tag',
    // THE ROMANIZATION SET IS A STRING LIST; THESE THREE ARE PLAIN STRINGS.
    //
    // They were first added next to auvy_romanize_scripts, which reads as the
    // obvious home for anything romanization-shaped and is the wrong one: the
    // scripts key stores a List<String>, these store one enum name each. The
    // backup cast every one of them to List<dynamic> and skipped it, so the
    // three settings never reached the cloud — 210 warnings in a single day of
    // logs, three per backup, silently doing nothing.
    //
    // Group by TYPE, never by feature. That is what these lists are for, and it
    // is the same mistake the auvy_romanize_scripts comment above records.
    // The two style pickers, both missed when they were added.
    //
    // Every other appearance choice is carried to a new device. The slider one
    // is the clearer miss of the two: _applyRestoredSettings already invalidates
    // sliderStyleProvider so a restored value takes effect immediately — an
    // invalidate that could never do anything, because the value it was waiting
    // for was never uploaded.
    //
    // Both stored by NAME, like the romanization standards, so pruning a style
    // cannot repoint an index at a different one.
    'mini_player_style_name',
    'slider_style_name',
    'auvy_romanize_kana_system',
    'auvy_romanize_hangul_system',
    'auvy_romanize_cyrillic_system',
    'intel_first_timestamps',
    'intel_play_counts',
    'intel_play_history',
    'intel_artists',
    'intel_history',
    'intel_tracks',
    'intel_timestamps',
    'intel_genres',
    // Bounded to 2000 artists (see IntelligenceNotifier._cappedGenres), which is
    // what makes it safe to carry. Rebuilding it costs one Last.fm request per
    // artist, and the 2026-09-01 log shows those timing out and degrading
    // silently to empty - so a new device would score on guesses for a while.
    'intel_artist_genres',
    // The migration stamp travels with the data it describes; separating them
    // would re-run the v2 prune against restored v2 data.
    'intel_metadata',
    'intel_time_context',
    'intel_genre_boosts',
    'intel_genre_streaks',
    // Scary-smart signals: Markov transitions, per-artist momentum, day-part.
    'intel_artist_transitions',
    'intel_artist_ts',
    'intel_daypart',
    'auvy_library_data',
    // Recently-played albums/playlists behind the Home mosaic — was NOT synced,
    // so the mosaic came back empty after a reinstall (user: "backup history").
    'recent_playlists_v1',
    // Recently played TRACKS, with absolute play times
    //
    // Was never synced: `auvy_history` existed on disk but appeared in none of
    // these lists, so the trail died with the install even though the taste data
    // derived from it survived.
    //
    // v2 ONLY. The v1 key is a bare song list with no times, and a relative
    // "N minutes ago" cannot survive a restore on another device days later — it
    // would be re-anchored to the wrong "now". v2 carries epoch milliseconds per
    // entry, so a restored trail reads correctly whenever it lands. Entries whose
    // time is unknown (restored from a v1 backup) carry 0 rather than a
    // fabricated timestamp.
    //
    // Bounded at 50 entries by _kHistoryCap — roughly 25–30KB. This is the
    // "Recently played" strip, not an archive: the analytical history is
    // `intel_history` / `intel_play_counts` / `intel_timestamps` above.
    'auvy_history_v2',
    // User preferences / data (JSON string blobs)
    'auvy_lyric_offsets', // per-song lyric-sync nudges
    // Manually-set cover art, stored as base64 PNG so the IMAGE travels — a path
    // is meaningless on another device (and after clearing data). See
    // ArtworkOverrideNotifier for why v1's path map silently lost every cover.
    'auvy_artwork_overrides_v2',
    'auvy_podcast_positions', // podcast resume bookmarks
    'auvy_podcast_taste_genres', // learned podcast taste
    // Small setting STRINGS. They're chunked like the blobs above (one part doc
    // each, well under the limit) — slightly heavyweight for a 2-char country
    // code, but correctness beats packing them into a scalar of the wrong type.
    'auvy_content_country', // YouTube Music region (gl)
    'auvy_content_language', // YouTube Music language (hl)
    // Appearance choices that outlive an install as much as the accent colour
    // and slider style already listed under _intKeys.
    'app_density_name', // compact / comfortable list density
    'auvy_app_icon_variant', // which launcher icon is installed
    'auvy_alarm_days', // alarm repeat days, CSV
    'auvy_alarm_source', // liked / top / recent / song
    // The COLLECTION the alarm draws from, beside the song it picked. Only one
    // of the pair was ever synced, so a restore kept the chosen track and
    // forgot which playlist it came from.
    'auvy_alarm_picked_collection',
    'auvy_alarm_background', // the alarm screen's backdrop
    // The specific track chosen for the wake-up alarm. Stored as JSON so the
    // alarm can name it without a lookup; carried so a reinstall does not
    // silently swap the song someone deliberately picked to wake up to.
    'auvy_alarm_picked_song',
    // Songs identified by listening
    //
    // Was in NO backup list. Every "what was that song?" the user ever caught
    // died with the install, and this is the one list they cannot reconstruct,
    // because it records a moment that has passed. Everything else here can be
    // re-derived by using the app again; a song heard once in a café cannot.
    //
    // Capped at 100 entries by RecognitionHistory._maxEntries, so a few KB.
    'auvy_recognition_history',
    // NOT BACKED UP, DELIBERATELY: `auvy_alarm_track_path` and its id/title/
    // artist siblings. Those describe a FILE in this install's private storage,
    // so restoring them onto another device would point the alarm at a path that
    // does not exist. The alarm re-prepares its own audio on the next resume —
    // see AlarmService.needsPreparation.
  ];
  static const List<String> _intKeys = [
    'intel_last_save_time',
    'intel_first_use_date',
    'intel_artist_genres_v', // stamp for the key above; see _stringKeys
    // Settings (ints)
    'auvy_audio_quality', // streaming / audio quality
    'auvy_crossfade_duration', // crossfade seconds
    'auvy_max_cache_size', // max cache size (MB)
    'data_saver_mode', // data-saver mode
    'app_theme_color', // accent / theme color
    'slider_style_index', // player slider style
    'auvy_scrobble_seconds', // how long counts as a play
    'auvy_default_open_tab', // which tab the app opens on (0/1/2)
    'auvy_alarm_hour', // wake-up alarm time
    'auvy_alarm_minute',
    // THE ALARM WAS STILL HALF-RESTORED. See the note on
    // 'auvy_alarm_enabled' below, which fixed exactly this for two keys and
    // left six behind. Time, days, source, the on-switch and the fade-in FLAG
    // all travelled; how LOUD it is, how LONG the fade runs, and how long
    // snooze lasts did not. A restored alarm went off at the right minute at a
    // volume nobody chose, and syncing 'fade_in: true' while leaving the fade
    // LENGTH behind is the clearest sign these were an oversight.
    'auvy_alarm_volume_pct',
    'auvy_alarm_fade_seconds',
    'auvy_alarm_snooze_min',
    'auvy_player_artwork_shape', // Appearance: square / rounded / circle
    'auvy_lyric_share_max_lines', // Lyrics: lines per shared image
  ];
  static const List<String> _doubleKeys = [
    'auvy_pitch', // pitch preference
    'auvy_podcast_speed', // podcast playback speed
    'auvy_scrobble_percent', // fraction of a track that counts as a play
    'auvy_discovery_bias', // Intelligence: familiar ↔ new balance
    'auvy_lyric_text_scale', // Lyrics: type size multiplier
    'auvy_artwork_roundness', // Appearance: corner radius on cover art
    // Three keys were removed from this list, NOT added to it.
    //
    // 'auvy_lyrics_centered' and 'auvy_romanize_as_main' are BOOLS, and
    // 'auvy_romanize_scripts' is a STRING LIST — its own trailing comment said
    // so. All three were grouped here by FEATURE (they are Lyrics settings)
    // when these lists are grouped by TYPE, which is precisely the mistake the
    // warning on _boolKeys describes.
    //
    // It never broke a push, because each typed read is individually guarded
    // (see `collect`). It did something quieter: prefs.getDouble threw on all
    // three, they were skipped, and those settings never reached the cloud at
    // all. Dormant on the current install — the 2026-08-28 transcript carries
    // no "skipping … wrong type list?" line, because none had ever been set.
    // Setting one would have silently stopped it syncing from then on.
  ];
  static const List<String> _stringListKeys = [
    'intel_blacklist',
    'auvy_eq_bands', // equalizer band values
    'auvy_blacklist', // player-layer "don't play this" set
    'auvy_disabled_stream_sources', // Sound: stream clients switched off
    'auvy_romanize_scripts', // Lyrics: scripts to romanise — was in _doubleKeys
  ];
  // Bool flags that also define "who this account is". Syncing these means a
  // returning user (reinstall + same account) is NOT forced back through
  // onboarding/tutorial — the app knows they've already completed them. The
  // rest are user SETTINGS restored on reinstall.
  static const List<String> _boolKeys = [
    'has_onboarded',
    'has_seen_tutorial',
    // Settings (bools)
    'auvy_normalization', // normalize volume
    'auvy_crossfade', // crossfade on/off
    'auvy_gapless', // gapless playback
    'auvy_eq_enabled', // equalizer on/off
    'auvy_process_videos', // audio-only vs process-videos toggle
    'auvy_silence_skipping', // skip silence
    'auvy_autoplay_on_connect', // autoplay on device connect
    'auvy_haptics_enabled', // haptic feedback
    'auvy_discord_rpc_enabled', // Discord rich presence (token stays device-local)
    'auvy_update_check_on_launch', // Updates: check on launch
    'auvy_update_announce', // Updates: show the once-per-release banner
    'auvy_autoplay_similar', // keep playing similar music when the queue ends
    'auvy_offline_mode', // user-forced offline (cached/downloaded only)
    'auvy_reduce_motion', // Appearance: cross-fade instead of sliding
    'auvy_pause_listen_history', // privacy: don't credit plays
    'auvy_pause_search_history', // privacy: don't store queries
    'auvy_auto_download_on_like', // download liked tracks for offline
    // THE ALARM CAME BACK OFF. Its hour, minute, days and source were all
    // synced, but the switch that ARMS it and the fade-in preference were not —
    // so a restored device knew exactly when to wake you and had the alarm
    // disabled. A half-restored alarm is worse than none, because it looks set.
    // BOOLS ONLY. These lists are read with the matching typed getter
    // (`prefs.getBool` here), and shared_preferences casts, so a String or int
    // key listed here throws "type 'int' is not a subtype of type 'bool?'" and
    // kills the whole backup push. Int keys go in _intKeys, strings in
    // _stringKeys. (Exactly this mistake broke backups once; keep them sorted by
    // TYPE, not by feature.)
    'auvy_pause_on_mute',         // pause when volume hits zero
    'auvy_keep_screen_on',        // keep the screen awake in-app
    'auvy_block_screenshots',     // privacy: FLAG_SECURE on the window
    'auvy_pure_black',            // Appearance: AMOLED backdrop
    'auvy_dynamic_accent',        // Appearance: accent follows the artwork
    'auvy_alarm_enabled',         // wake-up alarm on/off
    'auvy_alarm_fade_in',         // ramp the alarm volume up
    'auvy_alarm_pulse',           // vibrate alongside the alarm
    'auvy_allow_external_play',   // let other apps start playback
    'auvy_lyrics_centered',       // was in _doubleKeys; it is a bool
    'auvy_romanize_as_main',      // was in _doubleKeys; it is a bool
  ];

  bool get _active => _firebaseReady && _userId != null && _userId!.isNotEmpty;

  DocumentReference<Map<String, dynamic>>? get _doc => _active
      ? FirebaseFirestore.instance.collection('user_backups').doc(_userId)
      : null;

  CollectionReference<Map<String, dynamic>>? get _blobs =>
      _doc?.collection('blobs');

  /// Change-detection signature for one blob. MUST be stable across process
  /// runs, because it is persisted and compared against a later launch.
  ///
  /// THIS WAS `Object.hash(s.length, s.hashCode)`, AND `Object.hash` IS
  /// RANDOMLY SEEDED PER PROCESS. Measured, same input, three separate runs:
  ///
  ///     String.hashCode :  1045060183   1045060183   1045060183   (stable)
  ///     Object.hash(...):    30887069    500783999    534873868   (differs!)
  ///
  /// Dart seeds it that way deliberately, to stop code depending on hash
  /// stability, which is exactly what persisting it does. The effect was that
  /// incremental sync worked WITHIN a session (in-memory values were computed
  /// under one seed: observed 5/40 and 16/40 uploaded) and failed on EVERY cold
  /// start, where a signature saved under the old seed could never match. Result:
  /// `40/40 blob(s) uploaded` on every launch, re-encrypting and re-uploading the
  /// entire backup — the thing persisting the signatures was added to prevent.
  ///
  /// Both inputs here are stable: `String.hashCode` is derived from the
  /// characters, and the combination is plain arithmetic. Not cryptographic, and
  /// it does not need to be — it answers "did these bytes change?", where the
  /// wrong answer costs one redundant upload, not correctness.
  ///
  /// A DART SDK UPGRADE MAY CHANGE `String.hashCode`. That is fine and
  /// self-correcting: every signature mismatches once, one full re-upload
  /// happens, and the new values persist. It must never be "fixed" by going back
  /// to a per-run seed.
  static int _sig(String s) => (s.length * 0x1f1f1f1f) ^ s.hashCode;

  /// Blobs where "the cloud says empty" is more likely to be a bug than a fact,
  /// and where being wrong costs the user something they cannot rebuild.
  ///
  /// Kept deliberately short. Most keys are caches or derived data where an
  /// empty restore is harmless, and a blanket rule would block legitimate
  /// clearing everywhere.
  static const Set<String> _irreplaceableKeys = {
    'auvy_library_data', // playlists, likes, followed artists
    'auvy_recognition_history', // songs identified in a moment that has passed
  };

  /// Would writing [incoming] over [local] destroy content for one of the keys
  /// above? True only when the incoming copy is empty and the local one is not.
  ///
  /// "Empty" is judged structurally rather than by string length, because an
  /// empty library still serializes to a few hundred bytes of system folders.
  static bool _isDestructiveRestore(String key, String? local, String incoming) {
    if (!_irreplaceableKeys.contains(key)) return false;
    if (local == null || local.isEmpty) return false;
    return _countsAsEmpty(incoming) && !_countsAsEmpty(local);
  }

  /// Does this JSON blob carry no user content at all?
  ///
  /// Counts the entries of every list it can find, at the top level and one
  /// level down. That is deliberately generic: it works for the library map, a
  /// bare history array, and anything shaped like either, without this service
  /// needing to know their schemas. Unparseable → NOT empty, so a blob we can't
  /// read is never used as grounds to overwrite something.
  static bool _countsAsEmpty(String blob) {
    if (blob.isEmpty) return true;
    try {
      final decoded = jsonDecode(blob);
      if (decoded is List) return decoded.isEmpty;
      if (decoded is! Map) return false;
      for (final v in decoded.values) {
        if (v is List && v.isNotEmpty) return false;
        if (v is Map) {
          for (final inner in v.values) {
            if (inner is List && inner.isNotEmpty) return false;
          }
        }
      }
      return true;
    } catch (_) {
      return false;
    }
  }

  /// Split [s] into parts that each fit a Firestore document. Never splits a
  /// surrogate pair (a lone surrogate is invalid UTF-8 and the write fails).
  static List<String> _chunk(String s) {
    if (s.length <= _chunkChars) return [s];
    final parts = <String>[];
    var start = 0;
    while (start < s.length) {
      var end =
          (start + _chunkChars < s.length) ? start + _chunkChars : s.length;
      if (end < s.length) {
        final c = s.codeUnitAt(end - 1);
        if (c >= 0xD800 && c <= 0xDBFF) end -= 1; // high surrogate: back off
      }
      parts.add(s.substring(start, end));
      start = end;
    }
    return parts;
  }

  /// Begin syncing for [userId] and pull a newer cloud backup into local prefs.
  /// Returns true when local data was overwritten (the caller should then reload
  /// the affected providers so the UI reflects the restored data). Safe no-op
  /// when Firebase isn't configured or there's nothing newer to restore.
  Future<bool> activateAndRestore(String userId) async {
    _userId = userId;
    if (!_active) return false;
    try {
      final snap = await _doc!.get();
      if (!snap.exists) return false;
      final data = snap.data();
      if (data == null) return false;

      final cloudMs = (data['backup_ms'] is int) ? data['backup_ms'] as int : 0;
      // Everything this session may later overwrite. See _knownCloudMs.
      _knownCloudMs = cloudMs;
      final prefs = await SharedPreferences.getInstance();
      final localMs = prefs.getInt(_localMarkerKey) ?? 0;

      // Cache the cloud part index for the next push's stale-part cleanup —
      // even when nothing needs restoring.
      final rawIdx = data['blobs'];
      _cloudPartCounts = (rawIdx is Map)
          ? rawIdx.map((k, v) => MapEntry(k.toString(), (v is int) ? v : 0))
          : {};
      final rawGens = data['blob_gens'];
      _cloudPartGens = (rawGens is Map)
          ? {
              for (final e in rawGens.entries)
                if (e.value is int) e.key.toString(): e.value as int,
            }
          : {};
      _partCountsLoaded = true;

      // Only restore a strictly-newer backup. On a fresh install localMs is 0,
      // so any existing cloud backup is pulled down.
      if (cloudMs <= localMs) {
        // Nothing to pull, but this device may still OWE the cloud a push
        // that a previous run never got to issue. Settle it now, while the
        // data is certainly intact, rather than waiting for the next change
        // to start another debounce.
        final owed = await pendingAgeMs();
        if (owed > 0) {
          print('${(owed / 60000).toStringAsFixed(1)} min of local '
              'changes were never pushed (the app closed before the timer '
              'fired) — uploading them now');
          unawaited(flushPendingNow(reason: 'startup backlog'));
        }
        return false;
      }

      // A newer cloud copy is NOT automatically the right one
      //
      // Reaching here means the cloud moved on while this device also has
      // edits it never managed to upload. Restoring would overwrite them with
      // no trace — the loss is silent, total, and looks like the app forgot.
      //
      // The other device's copy is not more correct; it is just more recent.
      // So this device's unpushed work is kept and sent up, and the restore is
      // skipped. That is last-writer-wins pointed at the writer who actually
      // has unsaved work, which is the only side that can still lose anything:
      // the cloud copy is safe on a server and on whichever device wrote it.
      final unpushed = await pendingAgeMs();
      if (unpushed > 0) {
        print('WARN: CONFLICT: the cloud backup is newer (backup_ms=$cloudMs vs '
            'local $localMs) but this device has '
            '${(unpushed / 60000).toStringAsFixed(1)} min of changes that were '
            'never uploaded. NOT restoring — that would erase them. Pushing '
            'the local copy instead.');
        unawaited(flushPendingNow(reason: 'conflict — local work would be lost'));
        return false;
      }

      _restoring = true;
      // Tracks whether we actually pulled real user data (history/library/taste)
      // down. Its truth is what proves "this account has used Auvy before", so a
      // reinstall + same-account login can skip onboarding/tutorial even when an
      // OLDER backup predates the flag-syncing below.
      var restoredAnyData = false;
      if (data['format'] == _formatVersion) {
        // What to pull
        // The manifest, not our own key list, decides. A backup written by the
        // incremental build carries `auvy_lib::…` parts that _stringKeys has
        // never heard of, and a backup written before it carries the monolith;
        // reading the index means both are understood without a version flag.
        final libraryPartKeys = _cloudPartCounts.keys
            .where((k) => k.startsWith(kLibraryPartPrefix))
            .toList();
        // Collected rather than written straight to prefs: the library is only
        // valid once its parts are joined, and half a library in prefs is the
        // failure mode this whole design exists to prevent.
        final restoredParts = <String, String>{};

        // v2: string blobs live in chunked part docs listed by the manifest.
        final keysToFetch = [..._stringKeys, ...libraryPartKeys]
            .where((k) => (_cloudPartCounts[k] ?? 0) > 0)
            .toList();

        // Fetch every key concurrently, process them in order
        //
        // THE CHUNKS OF ONE KEY WERE ALREADY PARALLEL; THE KEYS WERE NOT.
        //
        // The await sat inside a loop over keys, so a library split into 17
        // incremental parts meant 17 sequential round trips, each waiting for the
        // one before. Measured on device: about 27 seconds from the Worker replying
        // to the library appearing — long enough that a returning user was offered
        // onboarding, because the answer arrived after the app had already decided
        // where to send them.
        //
        // Fetching is pure I/O with no ordering requirement, so it all goes at once.
        // PROCESSING stays strictly sequential and in the original key order: the
        // torn-write generation check, the destructive-restore guards and the
        // library reassembly all depend on it, and this file exists because of a
        // data-loss bug. Nothing about those decisions changes — only when the
        // bytes arrive.
        //
        // Bounded at six keys in flight. Unbounded would open a request per part
        // the instant a big library lands, which is the kind of burst that gets a
        // client throttled, and a throttled restore is slower than a serial one.
        // One key's fetch must NOT abort the whole restore.
        //
        // Fetching every key BEFORE writing any of them moved the failure line:
        // a single throwing part doc used to end the loop with the keys already
        // processed safely in prefs, but with the fetch hoisted out it reached
        // the outer catch before ANYTHING was written — losing the library to a
        // dropped request for one unrelated blob. Running more requests at once
        // makes that throw likelier, not rarer, so the granularity has to come
        // back: a key that cannot be read is skipped and named, and every other
        // key restores.
        Future<List<dynamic>?> fetchKey(String k) async {
          try {
            return await Future.wait([
              for (var i = 0; i < (_cloudPartCounts[k] ?? 0); i++)
                _blobs!.doc('$k.$i').get()
            ]);
          } catch (e) {
            print('WARN: backup blob "$k" could not be fetched ($e) — '
                'keeping the local copy');
            return null;
          }
        }

        final fetchStarted = DateTime.now();
        final Map<String, List<dynamic>> fetched = {};

        // One collection query, NOT one request per part
        //
        // THE ROUND TRIPS WERE THE ENTIRE LOGIN DELAY. Measured on device:
        // `activateAndRestore took 14598ms` against `worker replied in 373ms`.
        // Batching six keys at a time still meant SEVEN sequential barriers over
        // ~41 keys, each one waiting on its slowest member, and latency, not
        // bytes, is what 468 KB across 17 parts costs.
        //
        // Every part lives in the same subcollection, so one `get()` brings all of
        // them back together. Same data, same rules, same decrypt path — one
        // network wait instead of dozens. It also reads any orphaned part docs
        // (deliberately left behind when a key vanishes), which are ignored below:
        // the manifest index still decides what counts, so a stale document cannot
        // re-enter a restore.
        try {
          final all = await _blobs!.get();
          final byId = {for (final d in all.docs) d.id: d};
          for (final k in keysToFetch) {
            final n = _cloudPartCounts[k] ?? 0;
            final parts = <dynamic>[];
            var complete = true;
            for (var i = 0; i < n; i++) {
              final d = byId['$k.$i'];
              if (d == null) {
                complete = false;
                break;
              }
              parts.add(d);
            }
            // A key the query did not fully cover falls through to the per-key
            // path below rather than being written off as torn.
            if (complete) fetched[k] = parts;
          }
        } catch (e) {
          // Non-fatal by design: a rules setup that allows reading a document but
          // not listing the collection would fail here, and the per-key path is
          // the same correctness with more round trips.
          print('WARN: bulk blob read failed ($e) — falling back to per-key reads');
        }

        // Whatever the bulk read did not cover, fetched key by key. Bounded at six
        // in flight: unbounded would open a request per part the instant a big
        // library lands, and a throttled restore is slower than a serial one.
        final missing = keysToFetch.where((k) => !fetched.containsKey(k)).toList();
        for (var start = 0; start < missing.length; start += 6) {
          final batch = missing.skip(start).take(6).toList();
          final results = await Future.wait(batch.map(fetchKey));
          for (var i = 0; i < batch.length; i++) {
            final r = results[i];
            if (r != null) fetched[batch[i]] = r;
          }
        }
        print('restore: fetched ${fetched.length}/${keysToFetch.length} blob(s) '
            'in ${DateTime.now().difference(fetchStarted).inMilliseconds}ms '
            '(${missing.length} needed a per-key read)');

        // Join the parts, then decrypt everything in one isolate hop
        //
        // Three phases, kept apart on purpose: joining is cheap string work,
        // decrypting is the expensive CPU work that must not run here (see
        // [_decodeAllOffThread] and the 3823 ms stall it fixes), and APPLYING
        // stays strictly sequential in the original key order because the
        // destructive-restore guards and the library reassembly depend on it.
        final joinedByKey = <String, String>{};
        for (final k in keysToFetch) {
          final snaps = fetched[k];
          if (snaps == null) continue;
          final sb = StringBuffer();
          var complete = true;
          // EVERY PART MUST COME FROM THE SAME PUSH. See the generation note
          // in _pushBody. Existence was not enough: part docs are overwritten in
          // place while the manifest is written last, so a push that died between
          // batches could leave NEW bytes indexed by an OLD part count. Joining
          // those produces a blob that is complete-looking and corrupt, and for
          // `auvy_library_data` a corrupt blob means the whole library —
          // playlists included — fails to parse and silently reads as empty.
          final wantGen = _cloudPartGens[k];
          for (final s in snaps) {
            final d = s.data();
            final v = d?['v'];
            if (v is! String) {
              complete = false;
              break;
            }
            // `g` absent → a backup written before generations existed. Accept it:
            // there is nothing better to compare against, and rejecting every
            // pre-existing backup would be a far worse failure than the torn-write
            // race this guards.
            final g = d?['g'];
            if (wantGen != null && g is int && g != wantGen) {
              complete = false;
              break;
            }
            sb.write(v);
          }
          if (!complete) {
            // Keep whatever is local. Louder than a silent `continue` because a
            // skipped blob is exactly what "I think I lost some playlists" looks
            // like from the outside.
            print('WARN: backup blob "$k" is torn or partial — keeping the local copy');
            continue;
          }
          joinedByKey[k] = sb.toString();
        }

        // Phase 2: the whole backup decrypted on a background isolate.
        final decodeStarted = DateTime.now();
        final decoded = await _decodeAllOffThread(joinedByKey);
        print('restore: decrypted ${joinedByKey.length} blob(s) off-thread '
            'in ${DateTime.now().difference(decodeStarted).inMilliseconds}ms');

        // Phase 3: apply, sequentially, in the original key order.
        for (final k in keysToFetch) {
          final joined = joinedByKey[k];
          if (joined == null) continue;
          final wasEncrypted = joined.startsWith(_encMarker);
          final plain = decoded[k];
          if (plain == null) continue; // encrypted but no key → keep local copy

          // A newer backup is NOT automatically a better one.
          //
          // The only test applied here was the timestamp, so an empty library
          // that got pushed by mistake would replace a full local one purely for
          // being more recent, and the local copy is gone the moment it is
          // overwritten. Content is worth one check before that happens: refuse
          // the swap when the cloud copy holds nothing and the local copy holds
          // something. Restoring onto a fresh install is unaffected (there is no
          // local content to lose), and a genuine "I cleared my library"
          // propagates as soon as anything else lands in it.
          if (_isDestructiveRestore(k, prefs.getString(k), plain)) {
            print('WARN: SKIPPED restoring "$k": the cloud copy is empty and the '
                'local one is not. Keeping the local copy.');
            continue;
          }

          // Library parts are held back and joined below. See restoredParts.
          if (k.startsWith(kLibraryPartPrefix)) {
            restoredParts[k] = plain;
            if (plain.isNotEmpty && plain != '{}' && plain != '[]') {
              restoredAnyData = true;
            }
            if ((_encrypter == null) ? !wasEncrypted : wasEncrypted) {
              _pushedSig[k] = _sig(plain);
            }
            continue;
          }

          await prefs.setString(k, plain);
          if (plain.isNotEmpty && plain != '{}' && plain != '[]') {
            restoredAnyData = true;
          }
          // Only mark "already pushed" when the cloud copy is ALREADY in the
          // current storage form (encrypted iff we hold a key). Otherwise leave
          // it unset so the next push re-uploads it in the right form — the lazy
          // plaintext→encrypted migration the first time C1 is activated.
          final formMatches = (_encrypter == null) ? !wasEncrypted : wasEncrypted;
          if (formMatches) _pushedSig[k] = _sig(plain);
        }

        // Reassemble the library, once, from whole parts
        // Written only after every part has been fetched and decrypted, so a
        // restore that dies half way leaves the local library untouched rather
        // than replaced by a fragment. The same destructive-restore guard is
        // applied to the JOINED result, because emptiness is a property of the
        // whole library and cannot be judged from one section.
        if (restoredParts.isNotEmpty) {
          final joined = joinLibrary(restoredParts);
          if (joined == null) {
            print('WARN: library parts restored but none were readable — '
                'keeping the local library');
          } else if (_isDestructiveRestore(
              _kLibraryKey, prefs.getString(_kLibraryKey), joined)) {
            print('WARN: SKIPPED the restored library: it is empty and the local '
                'one is not. Keeping the local copy.');
          } else {
            await prefs.setString(_kLibraryKey, joined);
            // Playlists counted separately from the section parts: "restored 12
            // parts" cannot distinguish a full library from one that got its
            // likes back and none of its playlists, which is the exact
            // complaint this line has to be able to answer.
            final plParts = restoredParts.keys
                .where((k) => k.startsWith('${kLibraryPartPrefix}pl.'))
                .length;
            print('library restored: ${restoredParts.length} part(s), '
                '$plParts playlist(s), ${joined.length} bytes');
          }
        }
      } else {
        // Legacy single-doc format (pre-chunking): blobs inline on the doc.
        for (final k in _stringKeys) {
          final v = data[k];
          if (v is String) {
            await prefs.setString(k, v);
            if (v.isNotEmpty && v != '{}' && v != '[]') restoredAnyData = true;
          }
        }
      }
      for (final k in _intKeys) {
        final v = data[k];
        if (v is int) await prefs.setInt(k, v);
      }
      for (final k in _stringListKeys) {
        final v = data[k];
        if (v is List) {
          await prefs.setStringList(k, v.map((e) => e.toString()).toList());
        }
      }
      for (final k in _doubleKeys) {
        final v = data[k];
        if (v is num) await prefs.setDouble(k, v.toDouble());
      }
      for (final k in _boolKeys) {
        final v = data[k];
        if (v is bool) await prefs.setBool(k, v);
      }
      // "Reinstall forgets me" hard fix
      // The onboarding/tutorial gates (has_onboarded / has_seen_tutorial) were
      // only added to the synced key set recently, so an account whose backup
      // was written by an older build has real history/library data in the cloud
      // but NO flag to restore — the returning user was dumped back into
      // onboarding. If we pulled ANY real user data down, this account has
      // demonstrably used the app before, so force both gates true regardless of
      // whether the flags were in the manifest.
      if (restoredAnyData) {
        await prefs.setBool('has_onboarded', true);
        await prefs.setBool('has_seen_tutorial', true);
      }
      await prefs.setInt(_localMarkerKey, cloudMs);
      _restoring = false;
      print('Cloud restore applied (backup_ms=$cloudMs, '
          '${data['format'] == _formatVersion ? "v2" : "legacy"}, '
          'realData=$restoredAnyData, onboardedForced=$restoredAnyData) for $_userId');
      return true;
    } catch (e) {
      _restoring = false;
      // Surfaced (was silently swallowed): a locked Firestore / missing database
      // / permission error here is the usual reason "reinstall forgets me".
      print('ERROR: Cloud restore FAILED for $_userId: $e');
      return false;
    }
  }

  // Backup throttling — the old 5 s debounce pushed on almost every track while
  // listening (observed ~1 push / 5-10 s), needlessly draining mobile data. Now
  // a longer debounce batches bursts, and a hard minimum interval caps how often
  // a push can actually hit the network regardless of how many saves fire.
  static const Duration _debounceDelay = Duration(seconds: 30);
  static const Duration _minPushInterval = Duration(minutes: 5);
  DateTime? _lastPushAt;

  /// Debounced push of the current local user-data to the cloud. Call after any
  /// save in IntelligenceProvider / LibraryProvider.
  void scheduleBackup() {
    if (!_active || _restoring) return;
    _markPending();
    _debounce?.cancel();
    _debounce = Timer(_debounceDelay, () => _pushNow());
  }

  /// Record that local data has moved ahead of the cloud. Written once per
  /// dirty period, not per change — the value is WHEN it started, so a single
  /// int write covers a whole listening session's worth of edits.
  Future<void> _markPending() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      if ((prefs.getInt(_pendingKey) ?? 0) > 0) return;
      await prefs.setInt(_pendingKey, DateTime.now().millisecondsSinceEpoch);
    } catch (_) {}
  }

  Future<void> _clearPending() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove(_pendingKey);
    } catch (_) {}
  }

  /// Milliseconds of unpushed local work, or 0 when the cloud is up to date.
  Future<int> pendingAgeMs() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final since = prefs.getInt(_pendingKey) ?? 0;
      if (since <= 0) return 0;
      return DateTime.now().millisecondsSinceEpoch - since;
    } catch (_) {
      return 0;
    }
  }

  /// Push now, ignoring the debounce and the rate floor.
  ///
  /// Called when the app goes to background, which is the whole point.
  ///
  /// The rate floor exists so a long listening session does not upload every
  /// few seconds. It was also, accidentally, the thing that stranded changes:
  /// it did not skip a push, it RESCHEDULED one onto a timer that a closing
  /// app destroys. Backgrounding is the last moment this device is certain to
  /// get, so the write is issued there.
  ///
  /// Issuing it is enough even if the process dies a moment later: Firestore
  /// keeps an on-disk write queue (offline persistence is on by default on
  /// Android) and replays it on the next launch or reconnect. That durable
  /// queue is exactly the local buffer this problem calls for — the app simply
  /// never handed it anything, because the write was still sitting behind a
  /// Dart timer.
  Future<void> flushPendingNow({String reason = 'background'}) async {
    if (!_active || _restoring) return;
    if (await pendingAgeMs() <= 0) return;
    _debounce?.cancel();
    _debounce = null;
    print('flushing unpushed changes ($reason) rather than waiting out '
        'the rate floor — a timer does not survive the app closing');
    await _pushNow(force: true);
  }

  /// Serialising front door for [_pushBody]. Every push goes through here.
  ///
  /// Two ways the backup could corrupt itself, both fixed here.
  ///
  /// 1. PUSHING DURING A RESTORE. `_restoring` was checked in [scheduleBackup]
  ///    only, so the automatic path respected it and the MANUAL "Back up now"
  ///    walked straight past it. Local state mid-restore is half-written, and
  ///    pushing it overwrites the cloud copy being restored FROM — destroying the
  ///    backup as it is being read.
  ///
  /// 2. TWO PUSHES AT ONCE. There was no in-flight guard at all, and the entry
  ///    points make it easy: the 30s debounce can fire while the user taps "Back
  ///    up now", and the two UI buttons (Library and Settings) each track their
  ///    own `_busy`. Backups are CHUNKED — part docs in a subcollection plus a
  ///    manifest indexing how many parts each blob has, so interleaved runs can
  ///    leave run A's manifest describing run B's parts. Worse, both share
  ///    `_cloudPartCounts`, so one run's stale-part cleanup can delete parts the
  ///    other just wrote. The result restores partially, or wrong.
  ///
  /// An automatic push coalesces onto a running one. A manual push waits for it
  /// and then runs fresh, so "Back up now" always ends with current state
  /// uploaded rather than silently doing nothing.
  ///
  /// Nothing here awaits its OWN future — that is the re-entrancy trap that
  /// froze the catalog client earlier. `running` is always a future created by a
  /// different invocation, and the post-await recheck stops callers piling up.
  Future<void> _pushNow({bool force = false}) async {
    if (!_active) return;
    if (_restoring) return;

    if (_pushInFlight != null) {
      if (!force) return; // the running push already covers roughly this state
      final running = _pushInFlight;
      if (running != null) {
        try {
          await running;
        } catch (_) {
          // A failed push is still a finished push; carry on and run ours.
        }
      }
      // Someone else queued a fresh run while we waited. Wait for THAT one too
      // rather than returning: a manual "Back up now" reports success to the
      // user, so it must not quietly become a no-op because a second push
      // happened to start in the gap. One extra wait, then we run ours.
      final queued = _pushInFlight;
      if (queued != null) {
        try {
          await queued;
        } catch (_) {}
      }
      // Give up only if a THIRD run appeared — at that point the state is being
      // pushed continuously anyway and stacking further waits gains nothing.
      if (_pushInFlight != null) return;
      if (!_active || _restoring) return; // state may have changed while waiting
    }

    final fut = _pushBody(force: force);
    _pushInFlight = fut;
    try {
      await fut;
    } finally {
      if (_pushInFlight == fut) _pushInFlight = null;
    }
  }

  /// Non-null exactly while a push body is running. See [_pushNow].
  Future<void>? _pushInFlight;

  Future<void> _pushBody({bool force = false}) async {
    if (!_active) return;
    // Rate-limit automatic pushes so a long listening session doesn't upload
    // every few seconds. A manual "Back up now" (force) always goes through.
    if (!force && _lastPushAt != null) {
      final since = DateTime.now().difference(_lastPushAt!);
      if (since < _minPushInterval) {
        _debounce?.cancel();
        _debounce = Timer(_minPushInterval - since, () => _pushNow());
        return;
      }
    }
    try {
      final prefs = await SharedPreferences.getInstance();

      // The overwrite precondition, checked before anything is uploaded
      //
      // Two devices on one account used to overwrite each other silently.
      // The backup is keyed by a hash of the YouTube identity, so a phone and a
      // tablet on the same account write the SAME document, and the manifest
      // write was an unconditional `set`: whoever pushed last defined the cloud.
      // `libraryHasUserContent` does not catch it — a smaller real library is
      // still real content, just less of it.
      //
      // Checked here, before the first blob goes up, so a conflict costs one
      // read and leaves nothing half-written. The transaction at the end of this
      // method re-checks atomically, covering a device that starts pushing while
      // this one is still uploading.
      var remoteMs = 0;
      try {
        final snap = await _doc!.get();
        final seenMs = snap.data()?['backup_ms'];
        if (seenMs is int) remoteMs = seenMs;
        if (!_partCountsLoaded) {
          final rawIdx = snap.data()?['blobs'];
          _cloudPartCounts = (rawIdx is Map)
              ? rawIdx.map((k, v) => MapEntry(k.toString(), (v is int) ? v : 0))
              : {};
          // THE GENERATIONS COME FROM THE SAME DOCUMENT — READ THEM TOO.
          //
          // Only `blobs` was read here, so on any push where no restore had run
          // this session `_cloudPartGens` stayed empty. An unchanged blob then
          // carried NO generation into the manifest, and a restore with no
          // generation to compare accepts whatever it finds — quietly disabling
          // the torn-write detection this file was built around, for exactly the
          // blobs that are never re-uploaded.
          final rawGens = snap.data()?['blob_gens'];
          _cloudPartGens = (rawGens is Map)
              ? rawGens.map((k, v) => MapEntry(k.toString(), (v is int) ? v : 0))
              : {};
          _partCountsLoaded = true;
        }
      } catch (_) {
        // Non-fatal: worst case some orphan part docs linger (they're ignored —
        // the manifest index defines what restore reads).
      }

      // THE REMOTE STAMP IS DELIBERATELY NOT ADOPTED INTO _knownCloudMs HERE.
      //
      // Adopting it would let the very next push sail through the precondition
      // and overwrite the remote copy anyway, one cycle later. Only a RESTORE —
      // which actually brings that copy down onto this device — earns the right
      // to overwrite it, so the hold stands until one runs.
      if (remoteMs > _knownCloudMs) {
        _needsRemoteMergeBeforePush = true;
        print('WARN: backup HELD — the cloud copy (backup_ms=$remoteMs) is newer '
            'than what this session restored from ($_knownCloudMs): another '
            'device on this account pushed. Nothing uploaded, nothing '
            'overwritten. Restore to take the newer copy and resume backing up.');
        return;
      }
      // Signatures from the last session, so a cold start pushes only what
      // changed instead of re-encrypting and re-uploading every blob. Loaded
      // AFTER the part-index fetch above on purpose: the skip needs BOTH a
      // matching signature and a cloud part count, and loading these first would
      // invite reading them as sufficient on their own. See _kPushedSigPrefix.
      await _loadPushedSigs(prefs);

      final manifest = <String, dynamic>{};
      // Each typed read is individually guarded. shared_preferences CASTS, so
      // a key listed under the wrong type list throws (e.g. an int key in
      // _boolKeys → "type 'int' is not a subtype of type 'bool?'"). Unguarded,
      // that one bad key aborted the ENTIRE push and froze the user's backup —
      // which is exactly what happened when the alarm/region keys were first
      // added to the wrong list. Now a mistyped key simply isn't backed up, and
      // everything else still goes.
      void collect(String k, dynamic Function() read) {
        try {
          final v = read();
          if (v != null) manifest[k] = v;
        } catch (e) {
          print('WARN: backup: skipping "$k" — wrong type list? ($e)');
        }
      }

      for (final k in _intKeys) {
        collect(k, () => prefs.getInt(k));
      }
      for (final k in _stringListKeys) {
        collect(k, () => prefs.getStringList(k));
      }
      for (final k in _doubleKeys) {
        collect(k, () => prefs.getDouble(k));
      }
      for (final k in _boolKeys) {
        if (prefs.containsKey(k)) collect(k, () => prefs.getBool(k));
      }

      // Chunked blob writes, split across batches so one commit stays well
      // under Firestore's request-size limit. The manifest goes in the LAST
      // batch: if anything fails mid-way, the old manifest still points at a
      // complete set of parts.
      final index = <String, int>{};
      final newSigs = <String, int>{};
      final changed = <String>[];
      // Identifies THIS push. Every part written below carries it, and the
      // manifest records which generation each key's parts belong to, so a
      // restore can reject a blob whose parts came from two different pushes —
      // see _cloudPartGens.
      final gens = <String, int>{};
      final pushGen = DateTime.now().millisecondsSinceEpoch;
      var batch = FirebaseFirestore.instance.batch();
      var batchChars = 0;
      var batchOps = 0;
      final commits = <Future<void> Function()>[];

      void sealBatch() {
        if (batchOps == 0) return;
        final b = batch;
        commits.add(() => b.commit());
        batch = FirebaseFirestore.instance.batch();
        batchChars = 0;
        batchOps = 0;
      }

      // INCREMENTAL: the library goes up in PIECES, not as one blob
      //
      // `auvy_library_data` used to be a single value in _stringKeys, so its
      // signature changed whenever ANY part of the library changed and the whole
      // thing was re-uploaded — liking one song re-sent every playlist. Split
      // into per-section (and per-playlist) parts, each gets its own signature
      // below, so a like uploads the likes and nothing else.
      //
      // The parts join the same push machinery as every other blob: same
      // chunking, same generation stamp, same stale-part cleanup. Only the KEY
      // LIST is different, which keeps this change to composition rather than a
      // second code path that could rot.
      final libraryParts = splitLibrary(prefs.getString(_kLibraryKey));
      final pushKeys = <String>[
        for (final k in _stringKeys)
          // Skip the monolith when the split succeeded. If splitting failed
          // (unreadable JSON) libraryParts is empty and the whole blob is pushed
          // as before — a library we cannot parse must still be backed up.
          if (!(k == _kLibraryKey && libraryParts.isNotEmpty)) k,
        ...libraryParts.keys,
      ];

      var hasAnyBlob = false;
      for (final k in pushKeys) {
        final v = libraryParts[k] ?? prefs.getString(k);
        // A vanished key leaves orphaned part docs, AND that is the right
        // TRADE — DO NOT "FIX" IT.
        //
        // Skipping here means the key drops out of `index`, so the manifest stops
        // referencing it while its `blobs/{k}.{i}` documents remain. They are
        // harmless on restore (the manifest index defines what is read) but they
        // do sit in Firestore forever.
        //
        // The obvious cleanup — delete cloud parts for any key absent locally — is
        // a data-loss path wearing a tidy-up costume. It makes "a local read
        // returned null" sufficient to erase the cloud copy of that key, and
        // `auvy_library_data` is in this list: one spurious null and the user's
        // library is gone from the backup. A few KB of dead documents is a very
        // much smaller harm than that, and unlike that, it is recoverable.
        //
        // A shrinking value IS cleaned up (see the delete loop below) because
        // there the key is present and its new part count is known, which is the
        // difference between "this is smaller now" and "this might not exist".
        if (v == null) continue;
        hasAnyBlob = true;
        // Dedup on the PLAINTEXT (AES-GCM is non-deterministic, so ciphertext
        // can't be signature-compared). Unchanged + already-in-the-right-form
        // blobs keep their existing cloud parts and aren't re-uploaded.
        final sig = _sig(v);
        newSigs[k] = sig;
        //"UNCHANGED" IS ONLY SAFE IF WE KNOW WHERE THE OLD BYTES ARE.
        //
        // This skipped the upload whenever the signature matched and wrote
        // `_cloudPartCounts[k] ?? 0` into the manifest. When the count is
        // UNKNOWN that records the blob as having ZERO parts, and restore skips
        // any key with `n <= 0`. So the blob was neither uploaded nor readable:
        // it silently vanished from the backup while every log line said the
        // push succeeded.
        //
        // Reachable through the part-count prefetch below, whose failure is
        // swallowed as "non-fatal": one bad `_doc.get()` leaves the map empty
        // while `_pushedSig` is still populated from a restore, and every
        // unchanged blob is then dropped. `auvy_library_data`'s sections are in
        // this list, which is what "my liked songs came back empty but the
        // playlists survived" looks like from the outside.
        //
        // A count of zero is not evidence of absence, it is absence of evidence.
        // Not knowing means RE-UPLOADING — a few KB against losing the blob.
        final knownParts = _cloudPartCounts[k] ?? 0;
        if (_pushedSig[k] == sig && knownParts > 0) {
          index[k] = knownParts;
          // Not re-uploaded, so its parts still belong to whichever push wrote
          // them — carry that generation forward rather than claiming this one.
          final keptGen = _cloudPartGens[k];
          if (keptGen != null) gens[k] = keptGen;
          continue;
        }
        changed.add(k);
        // AES-GCM encrypt + base64 + chunk. Runs on a BACKGROUND ISOLATE — see
        // [_encodeChunkOffThread] for the measurements that forced the move.
        //
        // Persisting the signatures cut this to a handful of changed keys instead
        // of all 41, which helped but did not fix it: a real editing session still
        // changes a dozen blobs, and the watchdog still caught the main isolate
        // blocked for up to 6370 ms doing this work. Fewer expensive synchronous
        // steps is not the same as none.
        final parts = await StallWatchdog.timeAsync(
            'cloudSync.encode[$k]', () => _encodeChunkOffThread(v));
        index[k] = parts.length;
        gens[k] = pushGen;
        for (var i = 0; i < parts.length; i++) {
          if (batchChars + parts[i].length > _maxBatchChars ||
              batchOps >= 450) {
            sealBatch();
          }
          // 'g' stamps which push these bytes came from, so a restore can tell a
          // whole blob from the wreckage of one that died mid-way. See
          // _cloudPartGens.
          batch.set(_blobs!.doc('$k.$i'), {'v': parts[i], 'g': pushGen});
          batchChars += parts[i].length;
          batchOps++;
        }
        // Parts beyond the new count are leftovers from a larger old value.
        final old = _cloudPartCounts[k] ?? 0;
        for (var i = parts.length; i < old; i++) {
          if (batchOps >= 450) sealBatch();
          batch.delete(_blobs!.doc('$k.$i'));
          batchOps++;
        }
      }
      // Do NOT drop a key from the manifest on no evidence
      //
      // THE MANIFEST IS WHAT MAKES A BLOB READABLE. Restore only fetches keys
      // the index names, so removing an entry orphans its part documents just as
      // completely as deleting them — the bytes sit in Firestore where nothing
      // can ever reach them again.
      //
      // The note above ("a vanished key leaves orphaned part docs, and that is the
      // right trade") protects the DOCUMENTS from a spurious local null, but the
      // index entry was still dropped in the same breath, so the protection did
      // nothing. Concretely: a restore that fails leaves the library empty, the
      // next save pushes 30s later, `splitLibrary` finds nothing and produces no
      // `auvy_lib::pl.*` parts, and every playlist silently leaves the manifest.
      // From then on every restore honestly reports success and returns no
      // playlists.
      //
      // THE CONDITION MUST BE "UNREADABLE", NOT "EMPTY". A user who really
      // deleted a playlist still has a library that PARSES, so `splitLibrary`
      // returns its remaining sections and the deletion propagates as it should.
      // `libraryParts` is empty only when there was no readable library at all —
      // absent, or JSON we could not decode, and that is a state that says
      // nothing about what the user owns. Carrying the cloud's own entries
      // forward is then strictly better than erasing them.
      if (libraryParts.isEmpty) {
        var carried = 0;
        for (final entry in _cloudPartCounts.entries) {
          if (!entry.key.startsWith(kLibraryPartPrefix)) continue;
          if (entry.value <= 0 || index.containsKey(entry.key)) continue;
          index[entry.key] = entry.value;
          // Carried with its ORIGINAL generation: those parts belong to whichever
          // push wrote them, and claiming this push would make the restore's
          // torn-write check reject every one of them.
          final g = _cloudPartGens[entry.key];
          if (g != null) gens[entry.key] = g;
          carried++;
        }
        if (carried > 0) {
          print('WARN: no readable local library — kept $carried existing cloud '
              'library part(s) in the manifest rather than dropping them');
        }
      }
      // Same reasoning for the other blob whose loss cannot be undone: absent
      // locally is not evidence it should stop being backed up.
      for (final k in _irreplaceableKeys) {
        final n = _cloudPartCounts[k] ?? 0;
        if (n <= 0 || index.containsKey(k)) continue;
        index[k] = n;
        final g = _cloudPartGens[k];
        if (g != null) gens[k] = g;
        print('WARN: "$k" is absent locally — kept its existing cloud copy in '
            'the manifest');
      }

      if (manifest.isEmpty && !hasAnyBlob) return;

      final nowMs = DateTime.now().millisecondsSinceEpoch;
      manifest['format'] = _formatVersion;
      manifest['blobs'] = index;
      manifest['blob_gens'] = gens;
      manifest['backup_ms'] = nowMs;
      manifest['updatedAt'] = FieldValue.serverTimestamp();
      sealBatch();

      // Blob parts first, manifest last — the manifest is what makes them
      // readable, so this order means a failure leaves unreferenced parts rather
      // than a manifest pointing at bytes that never arrived.
      for (final commit in commits) {
        await commit();
      }

      // The same precondition, re-checked atomically: the guard at the top of
      // this method ran before the uploads, so a device that started pushing
      // during them would still slip past it. Losing here costs orphan parts,
      // which restore already ignores — the manifest index defines what counts.
      final wrote = await FirebaseFirestore.instance
          .runTransaction<bool>((tx) async {
        final snap = await tx.get(_doc!);
        final cloudMs =
            (snap.data()?['backup_ms'] is int) ? snap.data()!['backup_ms'] as int : 0;
        // `_knownCloudMs` is what we restored from, or what we last pushed. A
        // cloud stamp NEWER than that can only have come from another device.
        if (cloudMs > _knownCloudMs) {
          return false;
        }
        tx.set(_doc!, manifest);
        return true;
      }).catchError((Object e) {
        print('ERROR: backup: manifest transaction failed ($e)');
        return false;
      });

      if (!wrote) {
        _needsRemoteMergeBeforePush = true;
        print('WARN: backup ABORTED at the manifest write — another device '
            'pushed while this one was uploading. Nothing was overwritten; the '
            'parts just written are unreferenced and restore ignores them.');
        return;
      }
      _knownCloudMs = nowMs;

      _pushedSig
        ..clear()
        ..addAll(newSigs);
      _cloudPartCounts = Map<String, int>.from(index);
      _cloudPartGens = Map<String, int>.from(gens);
      // Written only AFTER every commit succeeded. A signature saved before the
      // upload landed would tell the next launch "already pushed" about bytes
      // that never arrived.
      await _savePushedSigs(prefs);
      await prefs.setInt(_localMarkerKey, nowMs);
      // CLEARED HERE AND ONLY HERE — after the manifest write, inside the
      // try, so a push that throws on the way up leaves the debt recorded.
      // Clearing it optimistically when the push STARTED would recreate the
      // original bug with extra steps.
      await _clearPending();
      _lastPushAt = DateTime.now();
      lastPushError = null;
      lastPushSuccess = DateTime.now();
      // NAMES, not just a count. "20/20 blob(s)" cannot answer the only
      // question that matters when something is missing from a restore — WHICH
      // keys actually made it. The count is also smaller than the key list on
      // purpose (a key with nothing stored yet produces no blob), so the number
      // alone is un-diagnosable. Release swallows print(), so this costs nothing
      // in a shipped build; with --dart-define=AUVY_DEBUG_LOG=true it is the
      // fastest way to confirm a newly-added key is genuinely being backed up.
      final blobNames = index.keys.toList()..sort();
      // WHICH ones changed. The full list answers "is this key backed up";
      // only the changed set answers "did the edit I just made get uploaded",
      // which is the question asked when something did not survive.
      final changedNames = changed.toList()..sort();
      print('uploaded this push: '
          '${changedNames.isEmpty ? "nothing new" : changedNames.join(", ")}');
      print('Cloud backup PUSHED (v$_formatVersion, backup_ms=$nowMs, '
          '${changed.length}/${index.length} blob(s) uploaded) for $_userId');
      // Only when the SET changes. See [_loggedBlobSet]. A newly-added key still
      // announces itself on the first push after it appears, which is exactly
      // when the question is asked.
      final blobSet = blobNames.join(',');
      if (blobSet != _loggedBlobSet) {
        final added = _loggedBlobSet == null
            ? ''
            : ' (changed from ${_loggedBlobSet!.split(',').length} key(s))';
        _loggedBlobSet = blobSet;
        print('backup contains ${blobNames.length} key(s)$added: '
            '${blobNames.join(', ')}');
      }
    } catch (e) {
      lastPushError = e.toString();
      print('ERROR: Cloud backup push FAILED for $_userId: $e');
      // A failed push retries once on a timer (transient network blip) and
      // again on the next save. Sigs were NOT updated, so nothing is skipped.
      _debounce?.cancel();
      _debounce = Timer(const Duration(seconds: 60), () => _pushNow());
    }
  }

  /// Force an immediate (non-debounced) push of the current local data. Returns
  /// true if a push was attempted (i.e. sync is active). Used by the manual
  /// "Back up & sync now" control so the user can verify sync works.
  Future<bool> pushNow() async {
    if (!_active) return false;
    // Refuse rather than quietly overwrite: a restore is mid-flight, so local
    // state is half-written and pushing it would clobber the cloud copy being
    // restored from. Reporting false lets the UI say so instead of claiming a
    // backup that would have destroyed data.
    if (_restoring) {
      lastPushError = 'A restore is in progress — try again once it finishes.';
      return false;
    }
    _debounce?.cancel();
    await _pushNow(force: true); // manual backup bypasses the rate limit
    return true;
  }

  /// Permanently delete this account's cloud backup (manifest + all blob part
  /// docs — deleting a document does NOT delete its subcollections). Used by
  /// "Delete Account". Best-effort + surfaced.
  /// Erase this user's cloud backup. Returns true only when there is provably
  /// nothing left.
  ///
  /// The old version could delete nothing AND say it had succeeded, AND that
  /// Is how deleted data came back.
  ///
  /// The backup is keyed by a hash of the YOUTUBE IDENTITY (see
  /// `_backupKeyFor`), which is stable: deleting the Auvy account and signing in
  /// again with the same Google account computes the SAME key. So a restore after
  /// "Delete Account" is not a leak between accounts — it is the user's own data
  /// still sitting in the cloud because the delete missed it.
  ///
  /// It missed it two ways. `_userId` is only set while sync is ACTIVE, and the
  /// fallback was `FirebaseAuth.currentUser.uid` — the ANONYMOUS uid, which has
  /// never keyed a backup, so a delete before activation removed a document
  /// that had never existed and printed "Cloud backup deleted" for it. And
  /// both early returns were silent, so "Firebase not ready" was indistinguishable
  /// from a completed erase.
  ///
  /// Now: every key that could hold this user's data is deleted, the result is
  /// VERIFIED by reading back, and the caller is told the truth so it can warn
  /// the user rather than wiping the device and leaving the cloud copy behind.
  Future<bool> deleteBackup({String? identityKey}) async {
    if (!_firebaseReady) {
      print('ERROR: delete: Firebase not ready — the cloud copy was NOT deleted');
      return false;
    }
    // Every candidate, because which one holds the data depends on when in the
    // session the delete was asked for. Deleting a key that was never used costs
    // one no-op write.
    final keys = <String>{
      if (_userId != null && _userId!.isNotEmpty) _userId!,
      if (identityKey != null && identityKey.isNotEmpty) identityKey,
      // Legacy: builds before the identity key wrote under the Firebase uid.
      if (FirebaseAuth.instance.currentUser?.uid.isNotEmpty ?? false)
        FirebaseAuth.instance.currentUser!.uid,
    };
    if (keys.isEmpty) {
      print('ERROR: delete: no backup key to delete under — nothing was erased');
      return false;
    }

    var allGone = true;
    for (final uid in keys) {
      try {
        final docRef =
            FirebaseFirestore.instance.collection('user_backups').doc(uid);
        final parts = await docRef.collection('blobs').get();
        // Chunked: a Firestore batch is capped at 500 writes, and a large
        // library's blob count plus the manifest can approach it.
        const chunk = 400;
        for (var i = 0; i < parts.docs.length; i += chunk) {
          final batch = FirebaseFirestore.instance.batch();
          for (final d in parts.docs.skip(i).take(chunk)) {
            batch.delete(d.reference);
          }
          await batch.commit();
        }
        await docRef.delete();

        // VERIFIED, NOT ASSUMED. This is the one operation in the app whose
        // failure the user cannot see and cannot undo, so it reads the state back
        // instead of trusting that the writes landed.
        final leftover = await docRef.collection('blobs').limit(1).get();
        final stillThere = await docRef.get();
        if (leftover.docs.isNotEmpty || stillThere.exists) {
          allGone = false;
          print('ERROR: delete: data REMAINS under ${uid.substring(0, 12)}… '
              '(${leftover.docs.length} blob(s), manifest=${stillThere.exists})');
        } else {
          print('delete: erased ${parts.docs.length} blob(s) + manifest for '
              '${uid.substring(0, 12)}…');
        }

        final prefs = await SharedPreferences.getInstance();
        // THE PERSISTED SIGNATURES MUST GO WITH THE BACKUP. They are the record
        // of "these bytes are already in the cloud"; leaving them behind after the
        // cloud copy is deleted would make the next push skip every unchanged blob
        // and rebuild an EMPTY backup that reported success.
        await prefs.remove('$_kPushedSigPrefix$uid');
      } catch (e) {
        allGone = false;
        print('ERROR: delete failed for ${uid.substring(0, 12)}…: $e');
      }
    }

    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_localMarkerKey);
    _pushedSig.clear();
    _cloudPartCounts = {};
    _cloudPartGens = {};
    return allGone;
  }

  /// Whether cloud sync is currently active (Firebase ready + an account uid
  /// resolved). Surfaced so the UI can show a "cloud connected" state.
  bool get isActive => _active;

  /// Stop syncing (on logout / account switch). Does NOT delete cloud data.
  void deactivate() {
    _debounce?.cancel();
    _userId = null;
    _pushedSig.clear();
    _cloudPartCounts = {};
      _cloudPartGens = {};
    _partCountsLoaded = false;
  }
}

// Off-isolate encode
//
// Top-level on purpose: `compute` can only take a top-level or static function,
// and its argument has to be sendable across an isolate boundary. Both live here
// rather than inside CloudSyncService for that reason alone.

/// One blob to encrypt and chunk. [keyBytes] null means store as plaintext,
/// which is what an unencrypted (legacy / no-key) backup does.
class _EncodeRequest {
  final String plain;
  final List<int>? keyBytes;
  const _EncodeRequest(this.plain, this.keyBytes);
}

/// Runs in a background isolate. Must stay free of plugins and of anything
/// touching the main isolate's state — it gets the key and the payload, nothing
/// else.
///
/// The Encrypter is rebuilt here from the raw key rather than being sent over.
/// The IV is generated HERE, per blob, which is correct: it must be unique per
/// encryption, and `fromSecureRandom` seeds from the platform CSPRNG in whichever
/// isolate it runs in.
class _DecodeRequest {
  final Map<String, String> joined;
  final List<int>? keyBytes;
  const _DecodeRequest(this.joined, this.keyBytes);
}

/// Decrypts every blob of a restore in a background isolate. See
/// [CloudSyncService._decodeAllOffThread].
///
/// A value that cannot be decrypted maps to NULL rather than throwing, so one
/// unreadable blob costs that blob and the rest of the restore still lands —
/// the same rule the fetch and the part-join already follow.
Map<String, String?> _decodeAllIsolate(_DecodeRequest r) {
  final keyBytes = r.keyBytes;
  final e = keyBytes == null
      ? null
      : enc.Encrypter(
          enc.AES(enc.Key(Uint8List.fromList(keyBytes)), mode: enc.AESMode.gcm));
  final out = <String, String?>{};
  for (final entry in r.joined.entries) {
    final stored = entry.value;
    if (!stored.startsWith(CloudSyncService._encMarker)) {
      out[entry.key] = stored; // legacy plaintext
      continue;
    }
    if (e == null) {
      out[entry.key] = null; // encrypted but we hold no key
      continue;
    }
    try {
      final rest = stored.substring(CloudSyncService._encMarker.length);
      final sep = rest.indexOf(':');
      final iv = enc.IV.fromBase64(rest.substring(0, sep));
      out[entry.key] =
          e.decrypt(enc.Encrypted.fromBase64(rest.substring(sep + 1)), iv: iv);
    } catch (_) {
      out[entry.key] = null;
    }
  }
  return out;
}

List<String> _encodeAndChunkIsolate(_EncodeRequest r) {
  final keyBytes = r.keyBytes;
  var out = r.plain;
  if (keyBytes != null) {
    final e = enc.Encrypter(
        enc.AES(enc.Key(Uint8List.fromList(keyBytes)), mode: enc.AESMode.gcm));
    final iv = enc.IV.fromSecureRandom(12); // GCM 96-bit nonce
    out = '${CloudSyncService._encMarker}${iv.base64}:'
        '${e.encrypt(r.plain, iv: iv).base64}';
  }
  return CloudSyncService._chunk(out);
}
