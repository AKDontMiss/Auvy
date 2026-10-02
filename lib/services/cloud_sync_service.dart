import 'dart:async';
import 'package:auvy/services/event_log.dart';
import 'dart:convert';
import 'dart:io' show gzip;
import 'dart:math';
import 'dart:typed_data';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:auvy/services/set_log.dart';
import 'package:auvy/services/play_tally.dart';
import 'package:crypto/crypto.dart';
import 'package:encrypt/encrypt.dart' as enc;
import 'package:flutter/foundation.dart' show compute, visibleForTesting;
import 'package:auvy/services/device_info_service.dart';

import 'package:auvy/logic/library_sync_split.dart';
import 'package:auvy/logic/stall_watchdog.dart';


/// What a caller of [CloudSyncService.scheduleBackup] would lose if the push
/// waited.
///
/// Not a priority ranking — a statement about the nature of the data, which is
/// what decides how long it may sit locally. See
/// [CloudSyncService._minListeningPushInterval].
enum BackupUrgency {
  /// Something the user did and expects to survive a reinstall: a playlist, a
  /// like, a download, a setting. Keeps the short rate floor.
  userEdit,

  /// A by-product of playback: play counts, listening history, taste
  /// affinities, artist transitions, day-part weights. It regenerates itself
  /// simply by using the app, so it can wait for the next real opportunity.
  listening,
}

/// Account-based cloud backup and restore of the user's data (listening
/// history, stats, taste profile, library and playlists), so reinstalling and
/// signing in with the same account restores everything.
///
/// It mirrors the local persistence as is: user data lives in a known set of
/// SharedPreferences values (the `intel_*` keys from IntelligenceProvider and
/// `auvy_library_data` from LibraryProvider). Downloaded audio isn't synced.
///
/// Storage format (v2, chunked): Firestore limits a document to 1 MiB, so each
/// string blob is split into part documents `user_backups/{uid}/blobs/{key}.{i}`,
/// and `user_backups/{uid}` holds a small manifest (scalar keys, `backup_ms`,
/// and a `blobs` index of key → part count). The manifest is written with a
/// full set() (no merge), which also strips legacy single-document fields.
/// Restore still reads the legacy single-document format.
///
/// Firestore rules must cover the subcollection, e.g.
/// `match /user_backups/{userId}/{document=**} { allow read, write:
/// if request.auth != null && request.auth.uid == userId; }`.
///
/// Guarded by [_firebaseReady]: without a configured Firebase project every
/// method is a safe no-op.
class CloudSyncService {
  CloudSyncService._();
  static final CloudSyncService instance = CloudSyncService._();

  /// Set once `Firebase.initializeApp()` succeeds in main(). Until then the
  /// service stays dormant.
  static bool _firebaseReady = false;

  /// Completes when Firebase finishes initialising. Startup callers must await
  /// this rather than test [isAvailable]: main() initialises Firebase
  /// asynchronously, and the account provider can run first on a slower device,
  /// which would leave the whole session without backup or restore.
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
  String? get currentUserId => _userId;
  Timer? _debounce;
  bool _restoring = false;

  /// True from the start of an account wipe until activation finishes.
  ///
  /// A wipe's own writes aren't user work. Its side effects (e.g. the library being
  /// saved again) can re-arm the pending marker, and the conflict guard in
  /// [activateAndRestore] would then refuse to restore the incoming account and
  /// push the emptied library over its backup instead. While this is set nothing
  /// arms the marker and the guard stands down. Signing back into the same account
  /// doesn't wipe, so genuine unpushed work is still protected.
  bool _accountResetting = false;

  /// Called at the START of an account wipe, before anything can re-dirty prefs.
  void beginAccountReset() {
    _accountResetting = true;
    _debounce?.cancel();
    _debounce = null;
    logEvent('cloud: account reset window OPEN — local writes from here are the '
        "wipe's own, not user work, and will not block a restore");
  }

  /// Called once activation has decided what to do. MUST run on every exit
  /// path, including a plain logout that never restores — a window left open
  /// would silently suppress real backups for the rest of the process.
  void endAccountReset() {
    if (!_accountResetting) return;
    _accountResetting = false;
    logEvent('cloud: account reset window CLOSED');
  }

  // Local marker holding the backup timestamp we last pushed/restored, so we
  // don't needlessly re-restore our own data but DO pick up a newer backup made
  // on another device (or after a reinstall, where this is absent → 0).
  static const String _localMarkerKey = 'cloud_last_backup_ms';

  /// When this device first had a change the cloud hasn't accepted yet.
  ///
  /// A persisted flag rather than an in-memory timer: timers die with the process,
  /// so a change scheduled for later could be lost if the app closed and something
  /// then restored over it. A flag on disk lets the next launch settle the debt
  /// before anything else touches the data.
  static const String _pendingKey = 'cloud_pending_since_ms';

  /// The library blob. Named because it gets special handling in three places:
  /// the incremental split, the restore reassembly, and the destructive-restore
  /// guard.
  static const String _kLibraryKey = 'auvy_library_data';

  static const int _formatVersion = 2;

  /// The blob-name set the last "backup contains" line reported. The list is
  /// long and rarely changes, so it's logged only when the set changes; the PUSHED
  /// line already reports `changed/total` every time.
  static String? _loggedBlobSet;
  // Parts are capped at 200k UTF-16 code units: even if every char needed 4
  // UTF-8 bytes that's 800 KB — comfortably under the 1 MiB doc limit.
  static const int _chunkChars = 200000;
  // Keep one batch commit well under Firestore's 10 MiB request limit. The limit
  // is in bytes but this counts UTF-16 code units, and characters outside Latin-1
  // (CJK titles, world radio) can be 3 UTF-8 bytes each, so 3M code units caps a
  // batch at ~9 MB.
  static const int _maxBatchChars = 3000000;

  /// Last push failure (null when the most recent push succeeded) and last
  /// successful push time — surfaced so sync problems are visible instead of
  /// silently freezing the backup.
  static String? lastPushError;

  static const String kHandoffKey = 'auvy_handoff_v1';

  /// What this device is playing, as `PlaybackHandoff.toJson()` without the
  /// device fields, or null when nothing is loaded. Set by the player and read
  /// just before each push, so carrying it costs nothing between pushes.
  static Future<Map<String, dynamic>?> Function()? handoffSnapshot;

  /// Called with another device's playing state when a restore brings one in.
  /// The player decides whether to take it.
  static void Function(Map<String, dynamic> handoff)? onHandoff;

  /// Called once per held push (a newer backup from another device is in the
  /// cloud), after the push has returned, so the app can merge it in and the
  /// held changes go up. Without it, two phones both left open stayed apart
  /// until one was reopened.
  static void Function()? onHeld;

  /// This device's sync id for the signed-in account (its history shard id).
  Future<String> deviceId() => _deviceShardId();

  /// Whether another device has pushed since this one last restored or pushed.
  /// One document read, so it is cheap enough to ask on every return to the app.
  Future<bool> hasNewerBackup() async {
    if (!_active || _doc == null) return false;
    try {
      final snap = await _doc!.get();
      final cloudMs = snap.data()?['backup_ms'];
      if (cloudMs is! int) return false;
      final prefs = await SharedPreferences.getInstance();
      final localMs = prefs.getInt(_localMarkerKey) ?? 0;
      return cloudMs > localMs && cloudMs > _knownCloudMs;
    } catch (_) {
      return false;
    }
  }
  static DateTime? lastPushSuccess;

  // key → part count currently in the cloud, used to delete stale part docs when
  // a blob shrinks. Loaded lazily from the manifest.
  Map<String, int> _cloudPartCounts = {};
  bool _partCountsLoaded = false;
  /// key → the push generation the cloud's parts for that key belong to.
  ///
  /// This makes a torn blob detectable. Parts in the original layout are
  /// overwritten in place with the manifest committed last, so a push that fails
  /// between batches leaves new part bytes under the previous manifest; part counts
  /// can't reveal that, a per-key stamp can. Parts are now written under
  /// generation ids ([_partId]), which a failed push can't disturb, but blobs still
  /// in the original layout, and ones written by an older build, rely on this
  /// check. Per key because unchanged blobs aren't re-uploaded and keep the
  /// generation of the push that last wrote them.
  Map<String, int> _cloudPartGens = {};

  /// key → 2 when that key's parts are stored under generation ids (see
  /// [_partId]). A key without an entry uses the original `'$k.$i'` ids.
  Map<String, int> _cloudPartLayout = {};

  /// Parts a push uploaded but never referenced, because its manifest write failed
  /// or lost to another device. The next successful push deletes them. In memory
  /// only: after a relaunch they stay as unreferenced documents, which restore
  /// ignores.
  final List<_PartSet> _unreferencedParts = [];

  /// The document id of part [i] of [key].
  ///
  /// Layout 2 names the push generation, so a push writes BESIDE the parts the
  /// current manifest points at rather than over them. With the original ids, a
  /// push that fails before its manifest write (Firestore unavailable, or another
  /// device pushed first) has already overwritten the referenced parts, and every
  /// restore then rejects those blobs as torn. The replaced parts are deleted only
  /// after the new manifest is written.
  static String _partId(String key, int i, {int? gen, int? layout}) =>
      layout == 2 && gen != null ? '$key@$gen.$i' : '$key.$i';

  static Map<String, int> _layoutFrom(Object? raw) => (raw is Map)
      ? {
          for (final e in raw.entries)
            if (e.value is int) e.key.toString(): e.value as int,
        }
      : {};

  /// Deletes [sets]. A failure only leaves unreferenced documents, which restore
  /// ignores, so it is logged and not retried.
  Future<void> _deleteParts(List<_PartSet> sets) async {
    final blobs = _blobs;
    if (blobs == null || sets.isEmpty) return;
    var batch = FirebaseFirestore.instance.batch();
    var ops = 0;
    var total = 0;
    try {
      for (final p in sets) {
        for (var i = 0; i < p.count; i++) {
          batch.delete(blobs.doc(_partId(p.key, i, gen: p.gen, layout: p.layout)));
          ops++;
          total++;
          if (ops >= 450) {
            await batch.commit();
            batch = FirebaseFirestore.instance.batch();
            ops = 0;
          }
        }
      }
      if (ops > 0) await batch.commit();
    } catch (e) {
      print('WARN: backup: could not delete $total replaced part(s) ($e) — they '
          'stay as unreferenced documents');
    }
  }

  /// The cloud `backup_ms` this session may overwrite: what it restored from, or
  /// what it last pushed itself. Checked before every push: a newer stamp can only
  /// come from another device on the same account, and overwriting it would
  /// destroy that device's changes.
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

  /// Signatures of blobs already pushed, persisted so the first push after a
  /// launch doesn't re-upload (and re-encrypt) everything.
  ///
  /// A persisted signature alone never authorises skipping an upload: it means
  /// "these bytes were pushed once", not "they're still readable in Firestore".
  /// The skip also requires a known cloud part count from the manifest (see the
  /// note at the skip). Scoped by uid, since another account has another backup.
  ///
  /// Bump the version whenever [_sig] changes: signatures from a different
  /// algorithm are meaningless. (v2: _sig no longer uses the per-process-seeded
  /// `Object.hash`.)
  static const String _kPushedSigPrefix = 'cloud_pushed_sigs_v2_';
  String get _pushedSigKey => '$_kPushedSigPrefix$_userId';

  /// Which key the persisted signatures were written under. After the server
  /// secret changes, every plaintext signature still matches, so without this
  /// nothing would be re-uploaded and the backup would stay sealed under the old
  /// key. A changed key id triggers exactly one full re-upload.
  String get _pushedSigKeyIdKey => '$_kPushedSigPrefix${_userId}_keyid';

  /// Read the persisted signatures for this user into [_pushedSig].
  Future<void> _loadPushedSigs(SharedPreferences prefs) async {
    if (_pushedSig.isNotEmpty) return; // already warm this session
    try {
      // Only a known, different id discards signatures. A missing id means the
      // install predates recording it, not that the key changed; discarding then
      // would force a full re-upload on every existing install.
      final storedId = prefs.getString(_pushedSigKeyIdKey);
      final currentId = _keyId;
      if (storedId != null && currentId != null && storedId != currentId) {
        logEvent('cloud: the backup key changed ($storedId → $currentId) — '
            'dropping the push signatures so every blob is re-encrypted under '
            'the new key. Expect one full re-upload, once.');
        await prefs.remove(_pushedSigKey);
        await prefs.setString(_pushedSigKeyIdKey, currentId);
        return;
      }
      if (currentId != null && storedId != currentId) {
        await prefs.setString(_pushedSigKeyIdKey, currentId);
      }
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

  /// v1 envelope: `enc:v1:<iv>:<ciphertext>`. No longer written, but must always
  /// stay readable: backups written before v2 use it, and a reader that dropped it
  /// would silently restore "no data".
  static const String _encMarker = 'enc:v1:';

  /// v2 envelope: `enc:v2:<keyId>:<iv>:<ciphertext>`. Two additions over v1:
  ///
  /// 1. It names the key it used. The key is derived server-side from the account
  ///    id under a secret; if that secret changes, a key mismatch now reports
  ///    itself by name (instead of looking like corruption), and the push path can
  ///    re-encrypt blobs written under a superseded key.
  ///
  /// 2. It binds the ciphertext to its slot. The blob key is the GCM associated
  ///    data, so a ciphertext moved into another slot fails authentication instead
  ///    of decrypting into the wrong place.
  ///
  /// The uid isn't in the associated data: the key is already per account and
  /// Firestore rules scope the path, and `_userId` is only set while sync is
  /// active, so including it could mismatch between encode and decode.
  static const String _encMarkerV2 = 'enc:v2:';

  /// v3: the v2 envelope over compressed bytes instead of a string.
  ///
  /// `enc:v3:<keyId>:<iv>:<base64( AES-GCM( gzip( utf8(json) ) ) )>`
  ///
  /// Changed blobs are re-uploaded whole, and history/play-count blobs are long
  /// repetitive JSON, so gzip cuts upload size about 3.5x. v3 also encrypts the
  /// compressed bytes directly instead of base64-encoding the plaintext first.
  ///
  /// The crypto is unchanged: same AES-GCM, fresh random 96-bit nonce per blob,
  /// key id in the envelope, same [aadFor] slot binding.
  ///
  /// Written only when it's actually smaller; otherwise the encoder falls back to
  /// v2. Reading supports v1, v2 and v3, so existing data needs no migration.
  /// Writing isn't backward compatible: a build without v3 can't read it, so every
  /// device on the account needs a build that has it.
  static const String _encMarkerV3 = 'enc:v3:';

  /// Short id for the current key: the first 8 hex characters of its SHA-256.
  /// Derived from the key (the service issues no version), so a changed server
  /// secret produces a new id automatically. 32 bits: a label for telling keys
  /// apart in a log, not a credential, and it reveals nothing about the key.
  String? _keyId;

  static String _computeKeyId(List<int> keyBytes) =>
      sha256.convert(keyBytes).toString().substring(0, 8);

  /// The associated data for [blobKey], binding a ciphertext to its slot. One
  /// function used by both encrypt and decrypt, because the AAD must be
  /// byte-identical or the blob becomes unreadable. Public so the isolate
  /// functions at the bottom can use it.
  static Uint8List aadFor(String blobKey) =>
      Uint8List.fromList(utf8.encode(blobKey));

  /// Set (base64url) the per-user backup encryption key, or null/'' to disable.
  void setBackupEncKey(String? base64UrlKey) {
    // Log when no key is available. Blobs are then uploaded unencrypted (so a
    // backup still happens), which must not go unnoticed; it can happen without a
    // code change, e.g. a Worker deployed without its secret. The key itself is
    // never logged, only whether there is one.
    if (base64UrlKey == null || base64UrlKey.isEmpty) {
      if (_encrypter != null) {
        logEvent('cloud: backup encryption key CLEARED — pushes from now on '
            'are PLAINTEXT until a key is issued again');
      } else {
        logEvent('cloud: no backup encryption key issued — pushes are '
            'PLAINTEXT (the service did not return one)');
      }
      _encrypter = null;
      _keyBytes = null;
      return;
    }
    try {
      var s = base64UrlKey.replaceAll('-', '+').replaceAll('_', '/');
      while (s.length % 4 != 0) {
        s += '=';
      }
      final keyBytes = base64.decode(s); // 32 bytes → AES-256
      if (keyBytes.length != 32) {
        // Wrong length is not a usable AES-256 key. Named separately from a
        // decode failure because the causes differ: this one means the service
        // is deriving the key differently than this app expects.
        logEvent('cloud: backup key is ${keyBytes.length} bytes, not 32 — '
            'unusable, pushes are PLAINTEXT');
        _encrypter = null;
        _keyBytes = null;
        return;
      }
      _encrypter = enc.Encrypter(enc.AES(enc.Key(keyBytes), mode: enc.AESMode.gcm));
      // Kept for the off-isolate encode. See [_encodeChunkOffThread].
      _keyBytes = keyBytes;
      _keyId = _computeKeyId(keyBytes);
    } catch (e) {
      logEvent('cloud: backup key could not be decoded ($e) — pushes are '
          'PLAINTEXT');
      _encrypter = null;
      _keyBytes = null;
      _keyId = null;
    }
  }

  // Encryption and decryption both run in a background isolate (see
  // [_encodeAndChunkIsolate] at the bottom and [_decodeAllOffThread]); there is no
  // main-isolate path for either.

  /// The AES key as raw bytes, kept so the encode can run in another isolate.
  ///
  /// An [enc.Encrypter] is not worth sending across an isolate boundary, so the
  /// key travels instead and the Encrypter is rebuilt on the far side. Held in
  /// memory only, exactly like [_encrypter] — it is never written anywhere.
  List<int>? _keyBytes;

  /// [_encode] + [_chunk] on a background isolate. Encrypting, base64-encoding
  /// and chunking every changed blob on the main isolate froze the UI for seconds
  /// (a blocked isolate draws no frames). One `compute` per key keeps the push
  /// loop's bookkeeping (manifest indices, part generations, stale-part deletion)
  /// exactly as it was; the spawn cost is paid off the UI thread.
  Future<List<String>> _encodeChunkOffThread(String blobKey, String plain) {
    return compute(
      _encodeAndChunkIsolate,
      _EncodeRequest(
        plain,
        _encrypter == null ? null : _keyBytes,
        blobKey,
        _encrypter == null ? null : _keyId,
      ),
    );
  }

  /// Decrypts a whole restore off the main isolate, in one hop. Restore runs
  /// during login, and decrypting the whole backup on the main isolate froze the
  /// UI mid-login. One `compute` for all blobs, since spawning costs more than
  /// decrypting a small value and restore has no per-blob bookkeeping.
  Future<Map<String, String?>> _decodeAllOffThread(
      Map<String, String> joined) async {
    if (joined.isEmpty) return const {};
    final res = await compute(
      _decodeAllIsolate,
      _DecodeRequest(
        joined,
        _encrypter == null ? null : _keyBytes,
        _encrypter == null ? null : _keyId,
      ),
    );
    // Name the unreadable blobs, split into "written under a different key"
    // (recoverable) and "damaged".
    if (res.foreignKeyIds.isNotEmpty) {
      final ids = res.foreignKeyIds.values.toSet().join(', ');
      logEvent('cloud: ${res.foreignKeyIds.length} blob(s) were encrypted under '
          'key(s) [$ids] and this device holds [${_keyId ?? "none"}] — the data '
          'is INTACT but not readable with the current key. It re-encrypts on '
          'the next push of each blob. Affected: '
          '${res.foreignKeyIds.keys.take(8).join(", ")}'
          '${res.foreignKeyIds.length > 8 ? ", …" : ""}');
    }
    if (res.undecryptable.isNotEmpty) {
      logEvent('cloud: ${res.undecryptable.length} blob(s) failed to '
          'authenticate under the CURRENT key — damaged or truncated, not a key '
          'mismatch: ${res.undecryptable.take(8).join(", ")}'
          '${res.undecryptable.length > 8 ? ", …" : ""}');
    }
    return res.values;
  }

  // User-data string blobs to mirror. Transient CDN page caches
  // (cached_home_data, artist_*, album_*) are deliberately excluded.
  static const List<String> _stringKeys = [
    // A skipped release is a real decision worth carrying to a new device.
    // `last_checked_at` / `last_seen_tag` deliberately are NOT backed up — they
    // describe this install's history, not a preference.
    'auvy_update_skipped_tag',
    // Keep fresh playlists and Weekly Discovery's week (one JSON document), so a
    // second phone sees a refresh already happened instead of repeating it.
    'auvy_keep_fresh_v1',
    'auvy_audiobooks_v1', // saved audiobooks and listening progress
    // What this device is playing, composed just before each push, so the
    // account's other devices can pick up where it left off (see
    // playback_handoff.dart). Applied by the player, never written over prefs.
    kHandoffKey,
    // Plain string settings (one enum name each), unlike the string-list
    // romanization key above. These lists are grouped by type, never by feature:
    // a key in the wrong list fails its typed read and is never backed up. The two
    // style pickers are stored by name, so pruning a style can't repoint an index.
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
    // Capped at 2000 artists (see IntelligenceNotifier._cappedGenres), which makes
    // it safe to carry; rebuilding it costs one Last.fm request per artist.
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
    // Recently played tracks, with absolute play times. v2 only: v1 is a bare song
    // list without times. Entries with unknown time (from a v1 backup) carry 0.
    // Capped at 50 entries (_kHistoryCap), roughly 25–30 KB; the full listening
    // history is `intel_history` / `intel_play_counts` / `intel_timestamps` above.
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
    // The wake-up alarm's WHEN (on/off, time, repeat days) is not backed up: it
    // belongs to the phone by the bed, and synced it made both phones ring, or
    // turned one off from the other. What it plays and how it sounds still sync.
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
    // Songs identified by listening. The one list a user can't rebuild, since it
    // records moments. Capped at 100 entries (RecognitionHistory._maxEntries).
    'auvy_recognition_history',
    // Not backed up on purpose: `auvy_alarm_track_path` and its id/title/artist
    // siblings describe a file in this install's private storage. The alarm
    // prepares its own audio again on the next resume (see
    // AlarmService.needsPreparation).
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
    // The alarm's volume, fade length and snooze length, so the alarm sounds
    // the same on every phone (its time and on/off are per phone; see
    // 'auvy_alarm_source' above).
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
    // 'auvy_lyrics_centered' and 'auvy_romanize_as_main' are bools and
    // 'auvy_romanize_scripts' is a string list, so they live in those lists, not
    // here. A key in the wrong typed list fails its read and silently never syncs.
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
    // Settings (bools)
    'auvy_normalization', // normalize volume
    'auvy_crossfade', // crossfade on/off
    'auvy_gapless', // gapless playback
    'auvy_eq_enabled', // equalizer on/off
    'auvy_process_videos', // audio-only vs process-videos toggle
    'auvy_silence_skipping', // skip silence
    'auvy_autoplay_on_connect', // autoplay on device connect
    'auvy_haptics_enabled', // haptic feedback
    'auvy_update_check_on_launch', // Updates: check on launch
    'auvy_update_announce', // Updates: show the once-per-release banner
    'auvy_autoplay_similar', // keep playing similar music when the queue ends
    'auvy_offline_mode', // user-forced offline (cached/downloaded only)
    'auvy_reduce_motion', // Appearance: cross-fade instead of sliding
    'auvy_pause_listen_history', // privacy: don't credit plays
    'auvy_pause_search_history', // privacy: don't store queries
    'auvy_auto_download_on_like', // download liked tracks for offline
    // The alarm's on-switch and fade-in preference travel with its time and days;
    // a half-restored alarm that looks set but is off is worse than none.
    // Bools only: these are read with `prefs.getBool`, and a key of another type
    // throws. Int keys go in _intKeys, strings in _stringKeys; group by type, not
    // feature.
    'auvy_pause_on_mute',         // pause when volume hits zero
    'auvy_keep_screen_on',        // keep the screen awake in-app
    'auvy_block_screenshots',     // privacy: FLAG_SECURE on the window
    'auvy_pure_black',            // Appearance: AMOLED backdrop
    'auvy_dynamic_accent',        // Appearance: accent follows the artwork
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

  /// One document per device, merged on read instead of overwritten.
  ///
  /// The main backup is a whole-snapshot `set()`, so two devices on one account are
  /// last-writer-wins. A device writes only its own shard, so it can never overwrite
  /// another's contribution; reading merges them.
  ///
  /// The merge must be idempotent (a device restores, re-pushes what it restored,
  /// and restores again), which decides what can live here:
  ///   * History: a union keyed by song id, newest timestamp wins. Converges.
  ///   * Play counts: a sum, which isn't idempotent. Each shard holds only that
  ///     device's own plays (see PlayTally).
  ///   * Likes and other sets: need removals, so they use a per-item timestamped
  ///     log (see SetLog).
  ///
  /// Cost scales with device count, not item count.
  CollectionReference<Map<String, dynamic>>? get _shards =>
      _doc?.collection('shards');

  /// This device's shard id. Random per install, cached after first use.
  ///
  /// Not a hardware identifier: those are stable cross-app identifiers for a
  /// person, and they survive a reinstall, so a stale shard would linger
  /// forever under an id the device no longer considers itself.
  String? _shardId;

  Future<String> _deviceShardId() async {
    final cached = _shardId;
    if (cached != null) return cached;
    final prefs = await SharedPreferences.getInstance();
    var id = prefs.getString(shardIdKey) ?? '';
    if (id.isEmpty) {
      final r = Random.secure();
      id = List.generate(16, (_) => r.nextInt(16).toRadixString(16)).join();
      await prefs.setString(shardIdKey, id);
    }
    _shardId = id;
    return id;
  }

  /// Listed in account_provider's _userDataKeys: a shard is per (account,
  /// device), so a new account on this device must claim a NEW slot rather
  /// than writing into the one the previous account used.
  static const String shardIdKey = 'cloud_shard_id';

  /// Merges every device's history shard with this device's history. Returns the
  /// merged JSON, or null when nothing was added (so the caller can skip a write).
  ///
  /// Union by song id, newest play wins. Entries without a time (t == 0, from a v1
  /// backup) lose to any dated entry and are kept only if nothing better exists.
  Future<String?> mergeHistoryShards(String? localHistoryJson) async {
    final shards = _shards;
    if (shards == null) return null;
    try {
      final snap = await shards.get();
      // Best time seen per song id, and the record that carried it.
      final bestAt = <String, int>{};
      final bestRec = <String, Map<String, dynamic>>{};
      var sawForeign = false;

      void ingest(String? raw, {required bool foreign, String? fallbackDevice}) {
        if (raw == null || raw.isEmpty) return;
        try {
          for (final r in jsonDecode(raw) as List) {
            if (r is! Map) continue;
            final s = r['s'];
            if (s is! Map) continue;
            final id = (s['id'] ?? '').toString();
            if (id.isEmpty) continue;
            final t = (r['t'] as num?)?.toInt() ?? 0;
            final known = bestAt[id];
            if (known == null || t > known) {
              bestAt[id] = t;
              final rec = Map<String, dynamic>.from(r);
              final existingDevice = (rec['d'] as String?)?.trim() ?? '';
              if (existingDevice.isEmpty && fallbackDevice != null && fallbackDevice.isNotEmpty) {
                rec['d'] = fallbackDevice;
              }
              bestRec[id] = rec;
              if (foreign && known != null) sawForeign = true;
              if (foreign && known == null) sawForeign = true;
            }
          }
        } catch (_) {
          // A corrupt shard must not poison the merge — skip it and keep the
          // rest. This is exactly the case where losing one device's history is
          // better than losing everybody's.
        }
      }

      final localDevice = DeviceInfoService.currentDeviceName;
      ingest(localHistoryJson, foreign: false, fallbackDevice: localDevice);
      final mine = await _deviceShardId();
      var foreignShards = 0;
      for (final d in snap.docs) {
        if (d.id == mine) continue; // our own contribution is already local
        foreignShards++;
        final foreignDevice = ((d.data()['deviceName'] ?? d.data()['deviceModel'] ?? '') as String).trim();
        ingest(d.data()['history'] as String?, foreign: true, fallbackDevice: foreignDevice);
      }
      if (!sawForeign) {
        // Log the outcome even when nothing came from other devices, so "nothing to
        // merge" is distinguishable from "didn't run".
        logEvent('cloud: history shards — $foreignShards from other device(s), '
            'nothing newer than what this device already has');
        return null;
      }

      final merged = bestRec.entries.toList()
        ..sort((a, b) => (bestAt[b.key] ?? 0).compareTo(bestAt[a.key] ?? 0));
      final capped = merged.take(_kHistoryShardCap).map((e) => e.value).toList();
      logEvent('cloud: merged history from ${snap.docs.length} device shard(s) '
          '→ ${capped.length} entries');
      return jsonEncode(capped);
    } catch (e) {
      logEvent('cloud: history shard merge skipped ($e)');
      return null;
    }
  }

  /// Write this device's history into its own shard.
  ///
  /// Its own document, so it cannot overwrite another device's. Unawaited by
  /// callers: a failed shard write costs a merge, not data.
  Future<void> pushHistoryShard(String? historyJson) async {
    final shards = _shards;
    if (shards == null) return;
    try {
      final id = await _deviceShardId();
      final deviceName = DeviceInfoService.currentDeviceName;
      await shards.doc(id).set({
        if (historyJson != null && historyJson.isNotEmpty) 'history': historyJson,
        if (deviceName.isNotEmpty) 'deviceName': deviceName,
        // This device's like decisions, each with the moment it was made, so a
        // removal on one phone outranks an older like on another. See LikeLog.
        'setLog': await SetLog.instance.exportJson(),
        // Only what THIS device played. Disjoint from every other device's
        // tally, so the totals sum exactly and keep summing exactly however
        // often they are recomputed. See PlayTally for why the cumulative
        // total could not be shared instead.
        'playTally': await PlayTally.instance.exportJson(),
        'atMs': DateTime.now().millisecondsSinceEpoch,
      });
    } catch (e) {
      logEvent('cloud: shard push failed ($e)');
    }
  }

  /// Merges every device's set log (likes, follows, saved playlists, hidden tracks
  /// and per-playlist membership) in one pass: they share the same timestamp rule,
  /// and one read of the shards is cheaper than five. Returns null when no other
  /// device had any decisions. Callers pick their collection with SetLog.resolve.
  Future<Map<String, Map<String, ({bool member, int atMs})>>?> mergeSetShards(
      String? localLogJson) async {
    final shards = _shards;
    if (shards == null) return null;
    try {
      final snap = await shards.get();
      final mine = await _deviceShardId();
      final logs = <Map<String, Map<String, ({bool member, int atMs})>>>[
        SetLog.decode(localLogJson),
      ];
      var foreign = 0;
      for (final d in snap.docs) {
        if (d.id == mine) continue;
        final raw = d.data()['setLog'] as String?;
        if (raw == null || raw.isEmpty) continue;
        // A present but empty log ("{}") isn't a decision, so count decoded decisions,
        // not raw fields.
        final decoded = SetLog.decode(raw);
        if (decoded.isEmpty) continue;
        foreign++;
        logs.add(decoded);
      }
      if (foreign == 0) return null;
      return SetLog.merge(logs);
    } catch (e) {
      logEvent('cloud: set shard merge skipped ($e)');
      return null;
    }
  }

  /// baseline + every device's own tally.
  ///
  /// Returns null when this device is the only one that has tallied, so nothing
  /// is recomputed for no reason.
  Future<Map<String, int>?> mergePlayTallies(
      Map<String, int> currentTotal) async {
    final shards = _shards;
    if (shards == null) return null;
    try {
      final snap = await shards.get();
      final mine = await _deviceShardId();
      final tallies = <Map<String, int>>[
        PlayTally.decode(await PlayTally.instance.exportJson()),
      ];
      var foreign = 0;
      for (final d in snap.docs) {
        if (d.id == mine) continue;
        final raw = d.data()['playTally'] as String?;
        if (raw == null || raw.isEmpty) continue;
        // "{}" is a device that has published a shard but played nothing —
        // no plays to add, so not a reason to recompute. Same reasoning as the
        // set log above.
        final decoded = PlayTally.decode(raw);
        if (decoded.isEmpty) continue;
        foreign++;
        tallies.add(decoded);
      }
      if (foreign == 0) return null;

      // The play-count baseline belongs to the account, not the device: kept in its
      // own document, written once by whichever device migrates first and adopted by
      // the rest (see PlayTally.baseline). Create-if-absent, never overwrite; racing
      // devices all end up with whichever value landed first, which is all that
      // matters.
      final baseRef = _doc!.collection('meta').doc('playBaseline');
      Map<String, int>? cloudBase;
      final baseSnap = await baseRef.get();
      final raw = baseSnap.data()?['counts'];
      if (raw is String && raw.isNotEmpty) {
        cloudBase = PlayTally.decode(raw);
      }
      final base = await PlayTally.instance
          .baseline(currentTotal, cloudBaseline: cloudBase);
      if (cloudBase == null && base.isNotEmpty) {
        // First migration for this account: publish our baseline so no other device
        // derives one from an already-merged number. An empty baseline is never
        // published (PlayTally.baseline refuses to freeze one).
        unawaited(baseRef.set({
          'counts': PlayTally.encode(base),
          'atMs': DateTime.now().millisecondsSinceEpoch,
        }).catchError((Object e) {
          logEvent('cloud: play baseline publish failed ($e)');
        }));
      }
      return PlayTally.total(baseline: base, deviceTallies: tallies);
    } catch (e) {
      logEvent('cloud: play tally merge skipped ($e)');
      return null;
    }
  }

  /// Matches the in-app history cap. A merged list longer than the app will
  /// ever show is just storage.
  static const int _kHistoryShardCap = 200;

  /// Called after a merge writes new prefs, so live state picks them up. The
  /// merge writes `auvy_history_v2` to disk, but the player keeps history in
  /// memory and saves it on every track change, which would overwrite the merged
  /// file. Set by the player provider, which owns that in-memory copy.
  static Future<void> Function()? onMergedIntoPrefs;

  /// Applies a merged set log to the live library (likes, saved albums and
  /// playlists, followed artists, per-playlist membership). One named hook per
  /// owner rather than a listener list, so a provider rebuild just overwrites its
  /// own registration.
  static Future<void> Function(
      Map<String, Map<String, ({bool member, int atMs})>> mergedLog)?
      onLibrarySetsMerged;

  /// Apply the merged blacklist. Owned by the intelligence notifier, which is
  /// why it is not folded into [onLibrarySetsMerged].
  static Future<void> Function(
      Map<String, Map<String, ({bool member, int atMs})>> mergedLog)?
      onBlacklistMerged;

  /// This device's current play totals, needed to freeze the historical baseline
  /// (see PlayTally.baseline). Async so the owner can finish loading first; an
  /// empty "not loaded yet" answer would freeze an empty baseline for the whole
  /// account.
  static Future<Map<String, int>> Function()? readPlayCounts;

  /// Apply merged play totals. Separate from [readPlayCounts] because the
  /// merge needs the current value before it can produce the new one.
  static Future<void> Function(Map<String, int> mergedCounts)?
      onPlayCountsMerged;

  /// Pulls every device's shard in, writes the merged result locally, and
  /// publishes this device's own contribution. Merges first and then pushes
  /// the merged value, so all devices converge on the same history.
  Future<void> _mergeShardsIntoLocal() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final localHistory = prefs.getString('auvy_history_v2');
      final merged = await mergeHistoryShards(localHistory);
      var changedPrefs = false;
      if (merged != null && merged != localHistory) {
        await prefs.setString('auvy_history_v2', merged);
        changedPrefs = true;
      }
      // Pull merged data into live state before anything can save over it. Awaited
      // for the same reason.
      if (changedPrefs) {
        final hook = onMergedIntoPrefs;
        if (hook != null) {
          await hook();
          logEvent('cloud: merged history pulled into live state');
        } else {
          // Says so rather than leaving a merge that will be quietly reverted.
          logEvent('WARN: history merged on disk but nothing is registered to '
              'reload it — the next save will overwrite it');
        }
      }

      // Each in its own try, inside their own methods: one of the three
      // failing must not cost the other two, and none of them may cost the
      // history merge that already succeeded above.
      await _mergeSetsIntoLive();
      await _mergeCountsIntoLive();

      // Publish last. The shard carries the merged history and set log, so a device
      // that never returns still has its decisions honoured. Safe to republish
      // because both merges are idempotent. The play tally isn't merged into it (see
      // SetLog.absorb for why sums can't be republished).
      unawaited(pushHistoryShard(merged ?? localHistory));
    } catch (e) {
      // A shard failure must never break the ordinary restore. Losing a merge
      // costs one device's recent history until the next launch; throwing here
      // would cost the whole activation.
      logEvent('cloud: shard merge skipped ($e)');
    }
  }

  /// Reconciles likes, saved albums and playlists, follows, hidden tracks and
  /// per-playlist membership across devices, then hands the result to the
  /// notifiers that hold them. Writing straight to prefs would be undone by their
  /// next save.
  Future<void> _mergeSetsIntoLive() async {
    try {
      final mergedLog = await mergeSetShards(await SetLog.instance.exportJson());
      if (mergedLog == null) {
        // Distinguishes "no other device has an opinion yet" from "the merge
        // never ran", which was indistinguishable for the history merge and
        // cost an evening working out which had happened.
        logEvent('cloud: set log — no other device has recorded a like, follow '
            'or hide yet');
        return;
      }
      // Adopt it before publishing, so this device's shard carries every
      // device's decisions. Idempotent — see SetLog.absorb.
      await SetLog.instance.absorb(mergedLog);

      final lib = onLibrarySetsMerged;
      final intel = onBlacklistMerged;
      if (lib == null && intel == null) {
        logEvent('WARN: set log merged but nothing is registered to apply it — '
            'likes and hides will not cross-sync');
        return;
      }
      if (lib != null) await lib(mergedLog);
      if (intel != null) await intel(mergedLog);

      final decisions =
          mergedLog.values.fold<int>(0, (s, m) => s + m.length);
      logEvent('cloud: merged set log → $decisions decision(s) across '
          '${mergedLog.length} collection(s)');
    } catch (e) {
      logEvent('cloud: set merge skipped ($e)');
    }
  }

  /// Sum every device's play tally onto the account's frozen baseline.
  ///
  /// Reads the current total first because the baseline is whatever this
  /// account had counted BEFORE per-device tallies existed, and it can only be
  /// derived from an unmerged number. See PlayTally.baseline.
  Future<void> _mergeCountsIntoLive() async {
    try {
      final read = readPlayCounts;
      final apply = onPlayCountsMerged;
      if (read == null || apply == null) {
        logEvent('WARN: play tallies not registered — per-device play counts '
            'will not cross-sync');
        return;
      }
      final merged = await mergePlayTallies(await read());
      if (merged == null) return; // only this device has tallied anything
      await apply(merged);
      logEvent('cloud: merged play counts → ${merged.length} track(s) with plays');
    } catch (e) {
      logEvent('cloud: play count merge skipped ($e)');
    }
  }

  /// Change-detection signature for one blob. Must be stable across runs, because
  /// it's persisted and compared on a later launch. `Object.hash` is seeded
  /// randomly per process, so it can't be used; `String.hashCode` and plain
  /// arithmetic are stable. Not cryptographic, and doesn't need to be: a wrong
  /// answer costs one redundant upload. If a Dart SDK update changes
  /// `String.hashCode`, signatures mismatch once and everything re-uploads once.
  static int _sig(String s) => (s.length * 0x1f1f1f1f) ^ s.hashCode;

  /// Where a setting's last-pushed value is remembered in [_pushedSig]. Prefixed
  /// so it can never collide with a blob key.
  static String _scalarSigKey(String k) => '=$k';

  /// Whether this device changed blob [k] since its last push. Unknown (it never
  /// pushed it) counts as changed, so a merge never overwrites local work it
  /// can't account for.
  bool _changedSinceLastPush(String k, String? local, String incoming) =>
      blobChangedSinceLastPush(_pushedSig[k], local, incoming);

  /// The same for a setting; see [settingChangedSinceLastPush].
  bool _scalarChangedSinceLastPush(String k, Object? local) =>
      settingChangedSinceLastPush(_pushedSig[_scalarSigKey(k)], local);

  /// [base] is the signature of what this device last pushed for the key.
  @visibleForTesting
  static bool blobChangedSinceLastPush(int? base, String? local, String incoming) {
    if (local == null || local == incoming) return false;
    return base == null || base != _sig(local);
  }

  /// With no recorded base (pushed by an older build) the cloud copy is taken: a
  /// setting is cheap to set again, and leaving the devices apart is the problem
  /// the merge exists to fix.
  @visibleForTesting
  static bool settingChangedSinceLastPush(int? base, Object? local) {
    if (local == null) return false;
    return base != null && base != _sig(jsonEncode(local));
  }

  @visibleForTesting
  static int signatureOf(Object value) =>
      _sig(value is String ? value : jsonEncode(value));

  /// Blobs where "the cloud says empty" is more likely a bug than a fact, and where
  /// being wrong costs the user something they can't rebuild. Kept short: most keys
  /// are caches or derived data where an empty restore is harmless.
  static const Set<String> _irreplaceableKeys = {
    'auvy_library_data', // playlists, likes, followed artists
    'auvy_recognition_history', // songs identified in a moment that has passed
  };

  /// Keys whose "absent locally, carried from the cloud" notice was already logged
  /// this session. The carry happens on every push; only the log line is once, since
  /// a feature the user never opened stays absent for good.
  final Set<String> _carriedCloudCopyAnnounced = <String>{};

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

  /// Whether this JSON blob carries no user content: counts the entries of every
  /// list at the top level and one level down, so it works for the library map, a
  /// bare history array and similar shapes without knowing their schemas.
  /// Unparseable counts as not empty, so an unreadable blob is never grounds to
  /// overwrite anything.
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
  Future<bool> activateAndRestore(String userId, {bool force = false}) async {
    _userId = userId;
    if (!_active) {
      endAccountReset();
      return false;
    }
    // try/finally so the reset window closes on every exit (early returns, the
    // conflict branch, a throw). A window left open would silently suppress every
    // backup for the rest of the process.
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
      _cloudPartLayout = _layoutFrom(data['blob_layout']);
      _partCountsLoaded = true;

      // Shards merge regardless of the watermark. Two devices that have both pushed
      // can have equal watermarks and still hold different history, so the merge runs
      // first, unconditionally. It's additive and idempotent and only ever writes our
      // own shard.
      await _mergeShardsIntoLocal();

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

      // A newer cloud copy isn't automatically the right one. The cloud moved on while
      // this device also has edits it never uploaded, and restoring wholesale would
      // overwrite them. So the two are MERGED: the cloud copy fills in everything
      // this device did not change since its last push (judged against what that
      // push uploaded, see _pushedSig), the local edits are kept, and then they go
      // up. Skipping the restore instead used to leave this device on its own old
      // settings and then push them over the other device's newer ones.
      //
      // Except during an account reset: after a wipe there is nothing local worth
      // keeping, and the wipe's own side effects can re-arm the pending marker. The
      // reset window wins, so the incoming account's backup is restored rather than
      // overwritten. Signing back into the same account doesn't wipe, so real unpushed
      // work is still protected.
      final unpushed = await pendingAgeMs();
      // The merge judges "changed here" against what the last push uploaded, so
      // that record must be loaded first; on a cold start nothing has read it yet,
      // and an empty one would make every local blob look changed.
      await _loadPushedSigs(prefs);
      final mergeOnly =
          unpushed > 0 && !_accountResetting && !force && !_onlyListeningPending;
      if (mergeOnly) {
        logEvent('cloud: MERGING — the cloud backup is newer (backup_ms=$cloudMs vs '
            'local $localMs) and this device has '
            '${(unpushed / 60000).toStringAsFixed(1)} min of changes never '
            'uploaded. Taking the cloud copy of everything not changed here, '
            'keeping the local changes, then uploading them.');
      } else if (unpushed > 0) {
        // Says so out loud, because silently ignoring a conflict guard is
        // exactly the kind of decision that should never be invisible.
        logEvent('cloud: ${unpushed}ms of local writes are '
            '${_onlyListeningPending ? "listening telemetry (preserved in shards)" : "post-wipe defaults or forced sync"} — '
            'restoring the incoming account over them');
        await _clearPending();
      }

      _restoring = true;
      // Tracks whether we actually pulled real user data (history/library/taste)
      // down. Its truth is what proves "this account has used Auvy before", so a
      // reinstall + same-account login can skip onboarding/tutorial even when an
      // OLDER backup predates the flag-syncing below.
      var restoredAnyData = false;
      // Merge bookkeeping and the other device's playing state; see above.
      final keptLocal = <String>[];
      String? incomingHandoff;
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

        // Fetch every key concurrently, then process them in order. Fetching is pure
        // I/O, so up to six keys are in flight at once (more could get the client
        // throttled). Processing stays sequential in key order, because the torn-write
        // check, the destructive-restore guards and library reassembly depend on it.
        //
        // One key failing must not abort the whole restore: a key that can't be read is
        // skipped and named, and every other key restores.
        // Where part i of k is stored: the layout the manifest records first. A
        // manifest written by an older build has no layout map, though its parts may
        // still be under generation ids from an earlier push, so those come second.
        List<String> partIds(String k, int i) {
          final g = _cloudPartGens[k];
          final layout = _cloudPartLayout[k];
          final primary = _partId(k, i, gen: g, layout: layout);
          final other = _partId(k, i, gen: g, layout: layout == 2 ? 1 : 2);
          return [primary, if (other != primary && layout != 2) other];
        }

        Future<List<dynamic>?> fetchKey(String k) async {
          try {
            final n = _cloudPartCounts[k] ?? 0;
            var snaps = await Future.wait([
              for (var i = 0; i < n; i++) _blobs!.doc(partIds(k, i).first).get()
            ]);
            final alt = [for (var i = 0; i < n; i++) partIds(k, i)];
            if (snaps.any((d) => !d.exists) && alt.every((ids) => ids.length > 1)) {
              final second = await Future.wait(
                  [for (final ids in alt) _blobs!.doc(ids[1]).get()]);
              if (second.every((d) => d.exists)) snaps = second;
            }
            return snaps;
          } catch (e) {
            print('WARN: backup blob "$k" could not be fetched ($e) — '
                'keeping the local copy');
            return null;
          }
        }

        final fetchStarted = DateTime.now();
        final Map<String, List<dynamic>> fetched = {};

        // One collection query for all parts instead of one request per part; latency,
        // not bytes, was the cost. It also returns orphaned part docs, which are ignored
        // below: the manifest index still decides what counts.
        try {
          final all = await _blobs!.get();
          final byId = {for (final d in all.docs) d.id: d};
          for (final k in keysToFetch) {
            final n = _cloudPartCounts[k] ?? 0;
            final wantGen = _cloudPartGens[k];
            final parts = <dynamic>[];
            var complete = true;
            for (var i = 0; i < n; i++) {
              // The candidate from the manifest's generation wins; one from another
              // generation is kept only so the torn check below names the blob.
              QueryDocumentSnapshot<Map<String, dynamic>>? match, any;
              for (final id in partIds(k, i)) {
                final d = byId[id];
                if (d == null) continue;
                any ??= d;
                final g = d.data()['g'];
                if (wantGen == null || g is! int || g == wantGen) {
                  match = d;
                  break;
                }
              }
              final d = match ?? any;
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

        // Three phases: join the parts (cheap), decrypt everything in one isolate hop
        // (see [_decodeAllOffThread]), then apply sequentially in key order, since the
        // restore guards and library reassembly depend on the order.
        final joinedByKey = <String, String>{};
        for (final k in keysToFetch) {
          final snaps = fetched[k];
          if (snaps == null) continue;
          final sb = StringBuffer();
          var complete = true;
          // Every part must come from the same push (see the generation note in
          // _pushBody). A push that died between batches can leave new bytes under an old
          // part count; joined, they look complete but are corrupt, and a corrupt library
          // blob would read as an empty library.
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
          // Whether this blob is already in the form this build writes. Decides whether a
          // restored blob may be marked as already pushed, so the next push can skip it.
          // Named for its meaning, so the next envelope version has one obvious place to
          // update.
          final isCurrentStorageForm = _encrypter == null
              // No key: plaintext IS the current form, and anything encrypted
              // is not readable as one anyway.
              ? !joined.startsWith(_encMarker) &&
                  !joined.startsWith(_encMarkerV2) &&
                  !joined.startsWith(_encMarkerV3)
              // With a key, only the newest envelope counts. A v1 or v2 blob
              // is left unmarked ON PURPOSE so the next push rewrites it as
              // v3 — that is the compression migration, and it costs one
              // upload per blob, once.
              : joined.startsWith(_encMarkerV3);
          final plain = decoded[k];
          if (plain == null) continue; // encrypted but no key → keep local copy

          // Another device's playing state goes to the player, not over this
          // device's own (which the next push replaces anyway).
          if (k == kHandoffKey) {
            incomingHandoff = plain;
            continue;
          }

          if (mergeOnly) {
            // The library's sets were already merged from every device's log
            // (_mergeShardsIntoLocal above), so the local library is kept whole.
            if (k.startsWith(kLibraryPartPrefix)) continue;
            final local = prefs.getString(k);
            if (_changedSinceLastPush(k, local, plain)) {
              keptLocal.add(k);
              continue;
            }
          }

          // A newer backup isn't automatically better: refuse to replace local content
          // with an empty cloud copy. A fresh install is unaffected (no local content),
          // and a real "I cleared my library" propagates once anything else changes in it.
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
            if (isCurrentStorageForm) {
              _pushedSig[k] = _sig(plain);
            }
            continue;
          }

          await prefs.setString(k, plain);
          if (plain.isNotEmpty && plain != '{}' && plain != '[]') {
            restoredAnyData = true;
          }
          // Only mark "already pushed" when the cloud copy is ALREADY in the
          // form this build writes. Otherwise leave it unset so the next push
          // rewrites it — the lazy migration, which now carries plaintext to
          // encrypted AND older envelopes to the compressed one.
          if (isCurrentStorageForm) _pushedSig[k] = _sig(plain);
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
      } else if (!mergeOnly) {
        // Legacy single-doc format (pre-chunking): blobs inline on the doc.
        for (final k in _stringKeys) {
          final v = data[k];
          if (v is String) {
            await prefs.setString(k, v);
            if (v.isNotEmpty && v != '{}' && v != '[]') restoredAnyData = true;
          }
        }
      }
      // Settings: when merging, one changed here since the last push keeps its
      // local value. Each applied one records its base for the next merge.
      Future<void> applyScalar(String k, Object value, Future<void> Function() write) async {
        if (mergeOnly && _scalarChangedSinceLastPush(k, prefs.get(k))) {
          keptLocal.add(k);
          return;
        }
        await write();
        _pushedSig[_scalarSigKey(k)] = _sig(jsonEncode(value));
      }
      for (final k in _intKeys) {
        final v = data[k];
        if (v is int) await applyScalar(k, v, () => prefs.setInt(k, v));
      }
      for (final k in _stringListKeys) {
        final v = data[k];
        if (v is List) {
          final list = v.map((e) => e.toString()).toList();
          await applyScalar(k, list, () => prefs.setStringList(k, list));
        }
      }
      for (final k in _doubleKeys) {
        final v = data[k];
        if (v is num) {
          final d = v.toDouble();
          await applyScalar(k, d, () => prefs.setDouble(k, d));
        }
      }
      for (final k in _boolKeys) {
        final v = data[k];
        if (v is bool) await applyScalar(k, v, () => prefs.setBool(k, v));
      }
      // If any real user data was restored, this account has used the app before, so
      // mark onboarding done even if the backup (written by an older build) lacked the
      // flag.
      if (restoredAnyData) {
        await prefs.setBool('has_onboarded', true);
        // The tutorial flags aren't forced here: nothing starts the tutorial
        // automatically any more, so they gate nothing.
      }
      await prefs.setInt(_localMarkerKey, cloudMs);
      // What was just restored IS what the cloud holds, so it is the base for the
      // next push's skips and the next merge, and must survive this process.
      await _savePushedSigs(prefs);
      _needsRemoteMergeBeforePush = false;
      _heldAnnouncedForMs = 0;
      lastPushError = null;
      _restoring = false;
      logEvent('Cloud restore applied (backup_ms=$cloudMs, '
          '${data['format'] == _formatVersion ? "v2" : "legacy"}, '
          'realData=$restoredAnyData, onboardedForced=$restoredAnyData) for $_userId');
      if (mergeOnly) {
        logEvent('cloud: merged — kept ${keptLocal.length} local change(s)'
            '${keptLocal.isEmpty ? "" : " (${keptLocal.take(8).join(", ")}${keptLocal.length > 8 ? ", …" : ""})"}'
            ', took the rest from the cloud; uploading the local ones now');
        unawaited(flushPendingNow(reason: 'merged with a newer backup'));
      }
      final h = incomingHandoff;
      if (h != null) {
        try {
          final decoded = jsonDecode(h);
          if (decoded is Map) onHandoff?.call(Map<String, dynamic>.from(decoded));
        } catch (_) {}
      }
      return true;
    } catch (e) {
      _restoring = false;
      // Logged, not swallowed: a locked Firestore, missing database or permission
      // error here is the usual reason a reinstall loses its data.
      print('ERROR: Cloud restore FAILED for $_userId: $e');
      return false;
    } finally {
      endAccountReset();
    }
  }

  // Backup throttling. A long debounce batches bursts (a short one pushes on
  // almost every track while listening, draining mobile data), and a hard
  // minimum interval caps how often a push reaches the network however many
  // saves fire.
  static const Duration _debounceDelay = Duration(seconds: 30);
  static const Duration _minPushInterval = Duration(minutes: 5);

  /// The rate floor when the only pending change is listening telemetry (play
  /// counts, history, affinities), which every finished track produces. It
  /// rebuilds itself through use, so it can wait; user edits keep the short floor.
  /// Nothing is stranded: [flushPendingNow] pushes when the app goes to the
  /// background, which is usually when a listening session ends.
  static const Duration _minListeningPushInterval = Duration(minutes: 30);

  /// True while every change since the last push was listening telemetry.
  ///
  /// Starts true because a fresh process has nothing pending at all; any
  /// [BackupUrgency.userEdit] clears it and a completed push restores it.
  bool _onlyListeningPending = true;

  /// Whether the current waiting period has already said so. See the refusal
  /// branch in [_pushBody] for why this is once-per-period.
  bool _deferLogged = false;

  /// The remote stamp the "backup HELD" warning was last announced for.
  ///
  /// A stamp rather than a flag: the hold is ABOUT that specific cloud copy, so
  /// a new one from the other device deserves to be said again while the same
  /// one repeating does not.
  int _heldAnnouncedForMs = 0;

  DateTime? _lastPushAt;

  /// The floor that currently applies. Telemetry alone waits; anything the user
  /// actually did does not.
  Duration get _effectivePushInterval =>
      _onlyListeningPending ? _minListeningPushInterval : _minPushInterval;

  /// Debounced push of the current local user-data to the cloud. Call after any
  /// save in IntelligenceProvider / LibraryProvider.
  ///
  /// [urgency] says what would be lost if this push waited — see
  /// [BackupUrgency]. It only ever relaxes the rate floor for telemetry; it
  /// never makes a push more frequent than [_minPushInterval].
  void scheduleBackup({BackupUrgency urgency = BackupUrgency.userEdit}) {
    if (!_active || _restoring || _accountResetting) return;
    if (urgency == BackupUrgency.userEdit) _onlyListeningPending = false;
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

  /// Pushes now, ignoring the debounce and rate floor. Called when the app goes to
  /// the background, the last moment the process is sure to get.
  ///
  /// Issuing the write is enough even if the process dies right after: Firestore
  /// keeps an on-disk write queue (offline persistence is on by default on
  /// Android) and replays it on the next launch or reconnect.
  Future<void> flushPendingNow({String reason = 'background'}) async {
    if (!_active || _restoring) return;
    if (await pendingAgeMs() <= 0) return;
    _debounce?.cancel();
    _debounce = null;
    print('flushing unpushed changes ($reason) rather than waiting out '
        'the rate floor — a timer does not survive the app closing');
    await _pushNow(force: true);
  }

  /// The serialising entry point for [_pushBody]; every push goes through here.
  ///
  /// It prevents two ways the backup could corrupt itself:
  ///
  /// 1. Pushing during a restore. Local state mid-restore is half-written, and
  ///    pushing it would overwrite the copy being restored from. This applies to
  ///    manual "Back up now" too, not just the automatic path.
  ///
  /// 2. Two pushes at once. Backups are chunked (part docs plus a manifest of
  ///    part counts), and both runs share `_cloudPartCounts`, so interleaved runs
  ///    could leave a manifest describing the other run's parts or delete parts
  ///    the other just wrote.
  ///
  /// An automatic push joins a running one. A manual push waits for it and then
  /// runs fresh, so "Back up now" always uploads current state. Nothing awaits its
  /// own future (the re-entrancy trap from the catalogue client): `running` always
  /// comes from another invocation, and the recheck after awaiting stops callers
  /// piling up.
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
      final floor = _effectivePushInterval;
      if (since < floor) {
        // Logged once per waiting period, naming which floor applies; every finished
        // track triggers this check.
        if (!_deferLogged) {
          _deferLogged = true;
          logEvent('backup deferred ${(floor - since).inMinutes}m more — '
              '${_onlyListeningPending ? "listening telemetry only" : "user edit waiting"}'
              ' (floor ${floor.inMinutes}m). A backgrounding pushes immediately.');
        }
        _debounce?.cancel();
        _debounce = Timer(floor - since, () => _pushNow());
        return;
      }
    }
    try {
      final prefs = await SharedPreferences.getInstance();

      // The overwrite check, done before anything is uploaded. Two devices on one
      // account write the same backup document (it's keyed by a hash of the YouTube
      // identity), so an unconditional manifest write meant the last pusher wins.
      // Checking first costs one read and leaves nothing half-written; the
      // transaction at the end re-checks atomically for a device that starts pushing
      // meanwhile.
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
          // Read the part generations from the same document, or unchanged blobs would
          // carry no generation into the manifest and the torn-write check would stop
          // working for them.
          final rawGens = snap.data()?['blob_gens'];
          _cloudPartGens = (rawGens is Map)
              ? rawGens.map((k, v) => MapEntry(k.toString(), (v is int) ? v : 0))
              : {};
          // And the layout, or the next push would delete replaced parts under the
          // wrong ids.
          _cloudPartLayout = _layoutFrom(snap.data()?['blob_layout']);
          _partCountsLoaded = true;
        }
      } catch (_) {
        // Non-fatal: worst case some orphan part docs linger (they're ignored —
        // the manifest index defines what restore reads).
      }

      // Don't adopt the remote stamp here, or the next push would pass the check and
      // overwrite the remote copy anyway. Only a restore, which brings that copy onto
      // this device, earns the right to overwrite it.
      if (remoteMs > _knownCloudMs) {
        _needsRemoteMergeBeforePush = true;
        lastPushError =
            'Backup held: a newer backup exists in the cloud from another device.';
        // Logged once per hold (keyed on the remote stamp), not on every attempt; a
        // further push from the other device is new information and is logged again.
        if (_heldAnnouncedForMs != remoteMs) {
          _heldAnnouncedForMs = remoteMs;
          logEvent('WARN: backup HELD — the cloud copy (backup_ms=$remoteMs) is '
              'newer than what this session restored from ($_knownCloudMs): '
              'another device on this account pushed. Nothing uploaded, nothing '
              'overwritten, and this will stay held until a restore runs. '
              'Further attempts stay silent until the cloud copy changes again.');
          // After this push has returned, not inside it: the catch-up's own
          // push would otherwise wait on this one.
          final hook = onHeld;
          if (hook != null) Timer.run(hook);
        }
        return;
      }
      // Signatures from the last session, so a cold start pushes only what
      // changed instead of re-encrypting and re-uploading every blob. Loaded
      // AFTER the part-index fetch above on purpose: the skip needs BOTH a
      // matching signature and a cloud part count, and loading these first would
      // invite reading them as sufficient on their own. See _kPushedSigPrefix.
      await _loadPushedSigs(prefs);

      final manifest = <String, dynamic>{};
      // What each setting was when it went up: the base a later merge compares
      // against to tell "changed here" from "changed on the other device".
      final scalarSigs = <String, int>{};
      // Each typed read is guarded separately. shared_preferences casts, so a key in
      // the wrong type list throws; unguarded, one bad key would abort the whole push.
      // A mistyped key is simply not backed up, and everything else still goes.
      void collect(String k, dynamic Function() read) {
        try {
          final v = read();
          if (v != null) {
            manifest[k] = v;
            scalarSigs[_scalarSigKey(k)] = _sig(jsonEncode(v));
          }
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

      // Chunked blob writes, split across batches to stay under Firestore's request
      // size limit. The manifest goes in the last batch, so if anything fails the old
      // manifest still points at a complete set of parts.
      final index = <String, int>{};
      final newSigs = <String, int>{...scalarSigs};
      final changed = <String>[];
      // Identifies THIS push. Every part written below carries it, and the
      // manifest records which generation each key's parts belong to, so a
      // restore can reject a blob whose parts came from two different pushes —
      // see _cloudPartGens.
      final gens = <String, int>{};
      final pushGen = DateTime.now().millisecondsSinceEpoch;
      // Which keys' parts are under generation ids (all that this push uploads).
      final layouts = <String, int>{};
      // Parts this push replaces, deleted once the new manifest no longer points at
      // them, and the parts it writes, recorded as unreferenced if it never lands.
      final retire = <_PartSet>[];
      final uploaded = <_PartSet>[];
      var batch = FirebaseFirestore.instance.batch();
      var batchChars = 0;
      // Whole-push total. See the write loop for why this is not batchChars.
      var pushedChars = 0;
      // The uncompressed size of the same blobs, so the push line can state
      // what the compression actually bought on THIS data rather than on an
      // estimate. A ratio nobody can check is a claim, not a measurement.
      var plainChars = 0;
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

      // The playing state, composed now rather than on every tick.
      try {
        final h = await handoffSnapshot?.call();
        if (h != null) {
          await prefs.setString(kHandoffKey, jsonEncode({
            ...h,
            'device': await _deviceShardId(),
            'name': DeviceInfoService.currentDeviceName,
          }));
        }
      } catch (e) {
        print('WARN: backup: playing state not included ($e)');
      }

      // The library goes up in pieces (per section and per playlist), each with its
      // own signature, so liking a song uploads the likes and nothing else. The parts
      // use the same push machinery as every other blob; only the key list differs.
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
        // A key that is missing locally leaves its cloud part docs orphaned, and that is
        // intentional. Deleting cloud parts for any key absent locally would let one
        // spurious local null erase that key (possibly the library) from the backup. A
        // few KB of dead documents is the far smaller, recoverable harm. A value that
        // is re-uploaded has its old parts retired after the manifest write, because
        // there it is known what replaces them.
        if (v == null) continue;
        hasAnyBlob = true;
        // Dedup on the PLAINTEXT (AES-GCM is non-deterministic, so ciphertext
        // can't be signature-compared). Unchanged + already-in-the-right-form
        // blobs keep their existing cloud parts and aren't re-uploaded.
        final sig = _sig(v);
        newSigs[k] = sig;
        // Skipping an unchanged blob is only safe when we know where its old bytes are.
        // With an unknown part count, the manifest would record zero parts and restore
        // would skip the key, silently dropping the blob from the backup. So not
        // knowing means re-uploading.
        final knownParts = _cloudPartCounts[k] ?? 0;
        if (_pushedSig[k] == sig && knownParts > 0) {
          index[k] = knownParts;
          // Not re-uploaded, so its parts still belong to whichever push wrote
          // them — carry that generation forward rather than claiming this one.
          final keptGen = _cloudPartGens[k];
          if (keptGen != null) gens[k] = keptGen;
          final keptLayout = _cloudPartLayout[k];
          if (keptLayout != null) layouts[k] = keptLayout;
          continue;
        }
        changed.add(k);
        plainChars += v.length;
        // Encrypt, base64 and chunk on a background isolate (see
        // [_encodeChunkOffThread]).
        final parts = await StallWatchdog.timeAsync(
            'cloudSync.encode[$k]', () => _encodeChunkOffThread(k, v));
        index[k] = parts.length;
        gens[k] = pushGen;
        layouts[k] = 2;
        for (var i = 0; i < parts.length; i++) {
          if (batchChars + parts[i].length > _maxBatchChars ||
              batchOps >= 450) {
            sealBatch();
          }
          // 'g' stamps which push these bytes came from, so a restore can tell a
          // whole blob from the wreckage of one that died mid-way. See
          // _cloudPartGens.
          batch.set(_blobs!.doc(_partId(k, i, gen: pushGen, layout: 2)),
              {'v': parts[i], 'g': pushGen});
          batchChars += parts[i].length;
          // Tracked separately from batchChars, which sealBatch() resets. Firestore
          // traffic doesn't pass through the app's HTTP pool, so this is the only record
          // of what a backup costs. Base64 characters, within a few percent of bytes on
          // the wire.
          pushedChars += parts[i].length;
          batchOps++;
        }
        // The parts these replace stay until the new manifest is written (see the
        // cleanup after it): deleting them first would tear the current backup if
        // this push never lands.
        final old = _cloudPartCounts[k] ?? 0;
        if (old > 0) {
          retire.add((
            key: k,
            gen: _cloudPartGens[k],
            count: old,
            layout: _cloudPartLayout[k],
          ));
        }
        uploaded.add((key: k, gen: pushGen, count: parts.length, layout: 2));
      }
      // Don't drop a key from the manifest without evidence. Restore only reads keys
      // the manifest names, so dropping an entry orphans its parts as surely as
      // deleting them.
      //
      // The condition is "the library was unreadable", not "empty". A user who
      // deleted a playlist still has a library that parses, so `splitLibrary` returns
      // the remaining sections and the deletion propagates. `libraryParts` is empty
      // only when there was no readable library at all (e.g. after a failed restore),
      // which says nothing about what the user owns, so the cloud's existing entries
      // are carried forward.
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
          final l = _cloudPartLayout[entry.key];
          if (l != null) layouts[entry.key] = l;
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
        final l = _cloudPartLayout[k];
        if (l != null) layouts[k] = l;
        // See [_carriedCloudCopyAnnounced]: the carry above runs on every push,
        // the notice does not.
        if (_carriedCloudCopyAnnounced.add(k)) {
          print('WARN: "$k" is absent locally — kept its existing cloud copy in '
              'the manifest (said once; the carry repeats silently)');
        }
      }

      if (manifest.isEmpty && !hasAnyBlob) return;

      final nowMs = DateTime.now().millisecondsSinceEpoch;
      manifest['format'] = _formatVersion;
      manifest['blobs'] = index;
      manifest['blob_gens'] = gens;
      manifest['blob_layout'] = layouts;
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
      Object? writeError;
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
        writeError = e;
        print('ERROR: backup: manifest transaction failed ($e)');
        return false;
      });

      // Parts written under this push's generation that no manifest references.
      if (!wrote) _unreferencedParts.addAll(uploaded);
      if (!wrote && writeError != null) {
        // A write that failed (offline, Firestore briefly unavailable) is not a
        // conflict: nothing says another device pushed, so this device isn't held.
        // The pending debt is kept, so the next save retries.
        lastPushError = 'Backup failed: the cloud could not be reached. It will retry.';
        print('WARN: backup NOT written — the manifest write failed; the next save '
            'retries. The parts just written are unreferenced and restore ignores '
            'them.');
        return;
      }
      if (!wrote) {
        _needsRemoteMergeBeforePush = true;
        lastPushError =
            'Backup aborted: another device pushed while this one was uploading.';
        print('WARN: backup ABORTED at the manifest write — another device '
            'pushed while this one was uploading. Nothing was overwritten; the '
            'parts just written are unreferenced and restore ignores them.');
        return;
      }
      _knownCloudMs = nowMs;
      // A write that passed the check proves nothing newer is in the cloud, so any
      // earlier hold no longer applies.
      _needsRemoteMergeBeforePush = false;
      _heldAnnouncedForMs = 0;

      _pushedSig
        ..clear()
        ..addAll(newSigs);
      _cloudPartCounts = Map<String, int>.from(index);
      _cloudPartGens = Map<String, int>.from(gens);
      _cloudPartLayout = Map<String, int>.from(layouts);
      // Only now, with the new manifest in place, is nothing pointing at them. Except
      // what that manifest still names: a write reported as failed can have landed
      // (a lost reply), and its parts are then carried forward, not unreferenced.
      await _deleteParts([
        for (final p in [...retire, ..._unreferencedParts])
          if (!(gens[p.key] == p.gen && layouts[p.key] == p.layout)) p,
      ]);
      _unreferencedParts.clear();
      // Written only AFTER every commit succeeded. A signature saved before the
      // upload landed would tell the next launch "already pushed" about bytes
      // that never arrived.
      await _savePushedSigs(prefs);
      await prefs.setInt(_localMarkerKey, nowMs);
      // Cleared here and only here: after the manifest write, inside the try, so a
      // push that fails on the way up keeps the debt recorded.
      await _clearPending();
      _lastPushAt = DateTime.now();
      // Which floor this push had been waiting behind, read BEFORE the reset
      // below so the log line describes the wait that just ended rather than
      // the next one.
      final waitedOn = _onlyListeningPending ? 'telemetry' : 'user-edit';
      // Back to the relaxed floor. The cloud now matches, so the next wait can
      // only be for changes that have not happened yet — and the next
      // user edit re-arms the short floor itself.
      _onlyListeningPending = true;
      _deferLogged = false;
      // Say whether this push was forced (background or manual button) or waited for
      // a floor, so push cadence reads correctly in an export.
      logEvent(force
          ? 'backup cadence: pushed WITHOUT waiting for the '
              '${_minListeningPushInterval.inMinutes}m floor — the app is '
              'closing or the user asked, and a timer does not survive either'
          : 'backup cadence: pushed on the $waitedOn floor '
              '(${_minPushInterval.inMinutes}m user-edit / '
              '${_minListeningPushInterval.inMinutes}m telemetry)');
      lastPushError = null;
      lastPushSuccess = DateTime.now();
      // Log the key names, not just a count, so a missing key can be spotted. Release
      // builds drop print(); with --dart-define=AUVY_DEBUG_LOG=true it confirms a newly
      // added key is being backed up.
      final blobNames = index.keys.toList()..sort();
      // WHICH ones changed. The full list answers "is this key backed up";
      // only the changed set answers "did the edit I just made get uploaded",
      // which is the question asked when something did not survive.
      final changedNames = changed.toList()..sort();
      logEvent('uploaded this push: '
          '${changedNames.isEmpty ? "nothing new" : changedNames.join(", ")}');
      logEvent('Cloud backup PUSHED (v$_formatVersion, backup_ms=$nowMs, '
          '${changed.length}/${index.length} blob(s) uploaded, '
          '≈${(pushedChars / 1024).toStringAsFixed(0)}KB from '
          '${(plainChars / 1024).toStringAsFixed(0)}KB of data'
          '${plainChars > 0 ? ' — ${(plainChars / pushedChars.clamp(1, 1 << 30)).toStringAsFixed(1)}x' : ''}) '
          'for $_userId');
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
    if (_needsRemoteMergeBeforePush) {
      lastPushError ??=
          'Backup held: a newer backup exists in the cloud from another device.';
      return false;
    }
    return lastPushError == null;
  }

  /// Erases this user's cloud backup (the manifest and all part docs; deleting a
  /// document doesn't delete its subcollections). Used by "Delete account". Returns
  /// true only when nothing provably remains.
  ///
  /// The backup is keyed by a hash of the YouTube identity, which is stable, so
  /// signing in again with the same Google account would find any leftover data.
  /// Every key that could hold this user's data is deleted, the result is verified
  /// by reading back, and the caller is told the truth so it can warn the user.
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

        // Verified, not assumed: the user can't see or undo a failed erase, so the state
        // is read back.
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
        // The persisted signatures must go too; otherwise the next push would skip every
        // unchanged blob and build an empty backup that reports success.
        await prefs.remove('$_kPushedSigPrefix$uid');
        // And the key id those signatures were recorded under. Left behind, the
        // next account on this device could find an id from a deleted one and
        // read it as a rotation — a pointless full re-upload, and a log line
        // that names a key change that never happened.
        await prefs.remove('$_kPushedSigPrefix${uid}_keyid');
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
    _cloudPartLayout = {};
    _unreferencedParts.clear();
    return allGone;
  }

  /// Whether cloud sync is currently active (Firebase ready + an account uid
  /// resolved). Surfaced so the UI can show a "cloud connected" state.
  bool get isActive => _active;

  /// Stop syncing (on logout / account switch). Does NOT delete cloud data.
  void deactivate() {
    // A logout wipes without ever restoring, so nothing else would close the
    // window on that path.
    endAccountReset();
    _debounce?.cancel();
    _userId = null;
    _pushedSig.clear();
    _cloudPartCounts = {};
    _cloudPartGens = {};
    _cloudPartLayout = {};
    _unreferencedParts.clear();
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

  /// The blob key. Travels because it is the associated data — see
  /// [CloudSyncService._encMarkerV2].
  final String blobKey;

  /// Short id of [keyBytes], computed on the main isolate so the hash is not
  /// recomputed per blob.
  final String? keyId;
  const _EncodeRequest(this.plain, this.keyBytes, this.blobKey, this.keyId);
}

/// A restore to decrypt in a background isolate: the joined blobs, the key and
/// its id.
class _DecodeRequest {
  final Map<String, String> joined;
  final List<int>? keyBytes;

  /// Short id of the key in hand, so a v2 blob written under a DIFFERENT key
  /// can be named as such instead of failing as corrupt.
  final String? keyId;
  const _DecodeRequest(this.joined, this.keyBytes, this.keyId);
}

/// What a decode produced, plus why anything failed. An unreadable blob maps to
/// null so the rest of the restore still lands, but there are three different
/// causes: no key (sign in), a key other than the one the blob was written under
/// (the server secret changed; the data is intact), and bytes that won't
/// authenticate (damaged).
class _DecodeResult {
  final Map<String, String?> values;

  /// Blob keys whose envelope named a key id other than the one in hand,
  /// mapped to the id they were written under.
  final Map<String, String> foreignKeyIds;

  /// Blob keys that failed to authenticate under the RIGHT key id.
  final List<String> undecryptable;
  const _DecodeResult(this.values, this.foreignKeyIds, this.undecryptable);
}

/// Decrypts every blob of a restore in a background isolate. See
/// [CloudSyncService._decodeAllOffThread].
///
/// A value that cannot be decrypted maps to NULL rather than throwing, so one
/// unreadable blob costs that blob and the rest of the restore still lands —
/// the same rule the fetch and the part-join already follow.
_DecodeResult _decodeAllIsolate(_DecodeRequest r) {
  final keyBytes = r.keyBytes;
  final e = keyBytes == null
      ? null
      : enc.Encrypter(
          enc.AES(enc.Key(Uint8List.fromList(keyBytes)), mode: enc.AESMode.gcm));
  final out = <String, String?>{};
  final foreign = <String, String>{};
  final bad = <String>[];
  for (final entry in r.joined.entries) {
    final k = entry.key;
    final stored = entry.value;
    final isV1 = stored.startsWith(CloudSyncService._encMarker);
    final isV2 = stored.startsWith(CloudSyncService._encMarkerV2);
    final isV3 = stored.startsWith(CloudSyncService._encMarkerV3);
    if (!isV1 && !isV2 && !isV3) {
      // An unknown `enc:` envelope is unreadable, not plaintext. Treating it as legacy
      // plaintext would write ciphertext into prefs in place of real data. Returning
      // null makes restore keep the local copy. Matched on the `enc:` prefix so future
      // versions are handled safely too.
      if (stored.startsWith('enc:')) {
        bad.add(k);
        out[k] = null;
        continue;
      }
      out[k] = stored; // genuinely legacy plaintext, from before encryption
      continue;
    }
    if (e == null) {
      out[k] = null; // encrypted but we hold no key
      continue;
    }
    try {
      if (isV1) {
        // v1: no key id, no associated data. Read exactly as it was written —
        // adding AAD here would fail the tag on every pre-v2 backup.
        final rest = stored.substring(CloudSyncService._encMarker.length);
        final sep = rest.indexOf(':');
        final iv = enc.IV.fromBase64(rest.substring(0, sep));
        out[k] =
            e.decrypt(enc.Encrypted.fromBase64(rest.substring(sep + 1)), iv: iv);
        continue;
      }
      // v2 and v3 share an envelope: <keyId>:<iv>:<ciphertext>. They differ
      // only in what the ciphertext holds — a string for v2, gzipped bytes for
      // v3 — so the parsing is deliberately one path with one branch at the
      // end. Two copies of this parse is how they would drift.
      final rest = stored.substring((isV3
              ? CloudSyncService._encMarkerV3
              : CloudSyncService._encMarkerV2)
          .length);
      final idEnd = rest.indexOf(':');
      final ivEnd = rest.indexOf(':', idEnd + 1);
      if (idEnd < 0 || ivEnd < 0) {
        bad.add(k);
        out[k] = null;
        continue;
      }
      final storedId = rest.substring(0, idEnd);
      if (r.keyId != null && storedId != r.keyId) {
        // Do not even attempt it. The attempt would fail anyway, and the
        // distinction is the whole reason the id is in the envelope.
        foreign[k] = storedId;
        out[k] = null;
        continue;
      }
      final iv = enc.IV.fromBase64(rest.substring(idEnd + 1, ivEnd));
      final ct = enc.Encrypted.fromBase64(rest.substring(ivEnd + 1));
      final aad = CloudSyncService.aadFor(k);
      out[k] = isV3
          // Decrypt the bytes, then decompress. An authentication failure throws here as
          // it does for v2, so a tampered or wrong-key v3 blob is reported as
          // undecryptable, not as corrupt JSON.
          ? utf8.decode(
              gzip.decode(e.decryptBytes(ct, iv: iv, associatedData: aad)))
          : e.decrypt(ct, iv: iv, associatedData: aad);
    } catch (_) {
      bad.add(k);
      out[k] = null;
    }
  }
  return _DecodeResult(out, foreign, bad);
}

/// Encrypts and chunks one blob in a background isolate. Must stay free of
/// plugins and main-isolate state: it gets the key and the payload, nothing
/// else. The Encrypter is rebuilt here from the raw key, and the IV is
/// generated here per blob from the platform CSPRNG.
List<String> _encodeAndChunkIsolate(_EncodeRequest r) {
  final keyBytes = r.keyBytes;
  final keyId = r.keyId;
  var out = r.plain;
  if (keyBytes != null && keyId != null) {
    final e = enc.Encrypter(
        enc.AES(enc.Key(Uint8List.fromList(keyBytes)), mode: enc.AESMode.gcm));
    final aad = CloudSyncService.aadFor(r.blobKey);

    // v3 first (compressed bytes; see [CloudSyncService._encMarkerV3]). Each attempt
    // draws its own nonce: reusing a GCM nonce under the same key for two plaintexts
    // leaks their XOR and breaks authentication, so the v2 fallback gets a fresh one.
    String? v3;
    try {
      final packed = gzip.encode(utf8.encode(r.plain));
      final iv3 = enc.IV.fromSecureRandom(12);
      v3 = '${CloudSyncService._encMarkerV3}$keyId:${iv3.base64}:'
          '${e.encryptBytes(packed, iv: iv3, associatedData: aad).base64}';
    } catch (_) {
      // Compression is an optimisation, never a reason to lose a backup.
      v3 = null;
    }

    final iv = enc.IV.fromSecureRandom(12); // GCM 96-bit nonce
    final v2 = '${CloudSyncService._encMarkerV2}$keyId:${iv.base64}:'
        '${e.encrypt(
              r.plain,
              iv: iv,
              associatedData: aad,
            ).base64}';

    // Smaller wins. A short or already-dense value can come out LARGER
    // compressed, and a format that exists to save bytes must not be used when
    // it costs them.
    out = (v3 != null && v3.length < v2.length) ? v3 : v2;
  }
  return CloudSyncService._chunk(out);
}

/// One blob's parts in the cloud: the key, the push that wrote them (null for a
/// backup older than generations), how many, and the id layout
/// (see CloudSyncService._partId).
typedef _PartSet = ({String key, int? gen, int count, int? layout});
