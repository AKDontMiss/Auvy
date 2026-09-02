import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:auvy/providers/data_usage_provider.dart';
import 'package:auvy/providers/library_provider.dart';

/// Tests for the 2026-08-30 fixes.
///
/// ── WHY SOME OF THESE READ SOURCE INSTEAD OF CALLING CODE ────────────────
///
/// The skip fast path lives inside a Riverpod StateNotifier that owns an
/// ExoPlayer, a method channel and eleven other extensions; standing one up in a
/// unit test would test the harness, not the rule. Those tests assert the SHAPE
/// the fix depends on — the same approach `documented_invariants_test.dart`
/// already takes, and for the same reason: the failures being guarded against
/// are edits that look reasonable in isolation and change behaviour nobody can
/// see from the outside.
///
/// Everything that CAN be called directly is called directly.
void main() {
  group('leaving the app is one event, however many the OS sends', () {
    // Android delivers `hidden` and then `paused` when the app goes to the
    // background, and can add `detached` on the way out. All three used to run
    // onPause, so every backgrounding issued two Firestore pushes — 22 of one
    // day's 97 uploaded nothing at all.
    late int resumes;
    late int pauses;
    late LibraryLifecycleHook hook;

    setUp(() {
      resumes = 0;
      pauses = 0;
      hook = LibraryLifecycleHook(
        onResume: () => resumes++,
        onPause: () => pauses++,
      );
    });

    test('hidden then paused is a single pause', () {
      hook.didChangeAppLifecycleState(AppLifecycleState.hidden);
      hook.didChangeAppLifecycleState(AppLifecycleState.paused);
      expect(pauses, 1,
          reason: 'Both events ran the pause work. That is the duplicate cloud '
              'push this collapse exists to stop.');
    });

    test('detached after paused adds nothing', () {
      hook.didChangeAppLifecycleState(AppLifecycleState.hidden);
      hook.didChangeAppLifecycleState(AppLifecycleState.paused);
      hook.didChangeAppLifecycleState(AppLifecycleState.detached);
      expect(pauses, 1);
    });

    test('coming back re-arms it, so the NEXT departure still fires', () {
      // The failure mode of a latch that is never cleared is worse than the bug
      // it fixes: the app would flush once and then never again for the rest of
      // the session, and the change meant to be saved on the way out is exactly
      // the one that would be lost.
      hook.didChangeAppLifecycleState(AppLifecycleState.paused);
      hook.didChangeAppLifecycleState(AppLifecycleState.resumed);
      hook.didChangeAppLifecycleState(AppLifecycleState.hidden);
      hook.didChangeAppLifecycleState(AppLifecycleState.paused);
      expect(pauses, 2, reason: 'The second departure was swallowed.');
      expect(resumes, 1);
    });

    test('repeated resumes do not fabricate pauses', () {
      hook.didChangeAppLifecycleState(AppLifecycleState.resumed);
      hook.didChangeAppLifecycleState(AppLifecycleState.resumed);
      expect(pauses, 0);
      expect(resumes, 2);
    });
  });

  group('podcast audio is recognised by its file, not its host', () {
    // Every other category branch names a host Auvy talks to. Podcast enclosures
    // come from wherever the show is hosted, so they all fell to 'other' —
    // 12.22 MB in one day, the biggest category on the screen and the least
    // meaningful.
    test('common enclosure extensions count as media', () {
      for (final p in const [
        '/e/traffic.megaphone.fm/ABC123.mp3',
        '/audio/episode-42.m4a',
        '/chapter01.m4b',
        '/f/x.aac',
        '/f/x.ogg',
        '/f/x.opus',
        '/f/x.flac',
        '/f/x.wav',
        '/f/x.mp4',
      ]) {
        expect(DataTrackingHttpClient.looksLikeMediaFile(p), isTrue,
            reason: '$p should be filed as podcast audio, not "other".');
      }
    });

    test('case does not matter — CDNs serve .MP3 too', () {
      expect(DataTrackingHttpClient.looksLikeMediaFile('/Show/EP1.MP3'), isTrue);
    });

    test('a metadata path is not media', () {
      for (final p in const [
        '/youtubei/v1/browse',
        '/rss',
        '/feed.xml',
        '/api/episodes.json',
        '/vi/abc/hqdefault.jpg',
        '',
        '/',
      ]) {
        expect(DataTrackingHttpClient.looksLikeMediaFile(p), isFalse,
            reason: '$p is not an audio file.');
      }
    });

    test('a query parameter mentioning mp3 does not count', () {
      // THE WHOLE REASON THIS TAKES A PATH AND NOT A URL. Tracking parameters
      // routinely carry a filename, and matching the full url would file an
      // ordinary API call as podcast audio.
      final u = Uri.parse('https://api.example.com/v1/track?file=song.mp3');
      expect(DataTrackingHttpClient.looksLikeMediaFile(u.path), isFalse);
    });

    test('an extension in the middle of a path is not the file', () {
      expect(
          DataTrackingHttpClient.looksLikeMediaFile('/mp3/list/index'), isFalse);
    });
  });

  group('the instant skip cannot become a double advance', () {
    final queue = File('lib/logic/player_queue.dart').readAsStringSync();
    final system = File('lib/logic/player_system.dart').readAsStringSync();
    final native =
        File('android/app/src/main/kotlin/com/auvy/app/NativePlayerManager.kt')
            .readAsStringSync();

    test('native refuses to jump unless the armed item IS the one asked for',
        () {
      // Dart keeps no record of what setUpcoming armed, and the queue can be
      // reordered between a check there and the call landing here. Seeking
      // without comparing would silently play whatever happened to be queued.
      final block = native.substring(native.indexOf('"advanceToUpcoming"'));
      final body = block.substring(0, block.indexOf('"clearUpcoming"'));
      expect(body.contains('armed != want'), isTrue,
          reason: 'The id comparison is gone — the fast path would now seek to '
              'whatever is armed, not to the track the queue says is next.');
      expect(body.indexOf('armed != want') < body.indexOf('seekToNextMediaItem'),
          isTrue,
          reason: 'The seek happens before the check.');
      expect(body.contains('result.success(false)'), isTrue,
          reason: 'A mismatch must report false so Dart falls back to the '
              'ordinary path instead of assuming the jump happened.');
    });

    test('the SEEK transition is forwarded, or Dart never learns it moved', () {
      expect(native.contains('MEDIA_ITEM_TRANSITION_REASON_SEEK'), isTrue,
          reason: 'Only AUTO is forwarded again, so a deliberate jump leaves '
              'currentSong disagreeing with what is audible.');
    });

    test('the skip arms the suppression BEFORE the call, not after', () {
      final armed = queue.indexOf('_skipConsumesNextAdvance = true');
      final called = queue.indexOf('NativeAudioEngine.advanceToUpcoming');
      expect(armed > 0, isTrue);
      expect(armed < called, isTrue,
          reason: 'The transition can be delivered while the await is still '
              'settling, so a flag set afterwards arrives too late and the '
              'skipped track is credited a full play.');
      final fast = queue.substring(armed);
      expect(fast.contains('_skipConsumesNextAdvance = false'), isTrue,
          reason: 'A refused jump must release the flag, or it swallows the '
              'next genuine gapless advance.');
    });

    test('a transition that never arrives cannot strand the flag', () {
      final fast = queue.substring(queue.indexOf('advanceToUpcoming'));
      expect(fast.contains('Timer(const Duration(milliseconds: 1500)'), isTrue,
          reason: 'The safety timer is gone. One lost event would then turn '
              'into a queue that silently stops following the music.');
    });

    test('the handler consumes it before ANY side effect', () {
      // THE ORDER IS THE WHOLE FIX. Everything below the suppression treats
      // the transition as a track that FINISHED: it promotes the old track's
      // bytes into the cache, and it calls playNext(autoAdvance: true), which
      // credits a full play at percent 1.0 and advances the queue a second time.
      // A skipped track recorded as listened-to end-to-end teaches the taste
      // model the opposite of what the user just told it.
      final handler = system.substring(system.indexOf('onNativeAutoAdvance:'));
      final consume = handler.indexOf('if (_skipConsumesNextAdvance) {');
      expect(consume > 0, isTrue,
          reason: 'The handler no longer recognises its own skip, so a fast '
              'skip advances the queue twice for one tap.');
      for (final effect in const [
        '_cacheManager.cacheTrack(',
        'playNext(autoAdvance: true',
        '_loadAndPlay(',
      ]) {
        final at = handler.indexOf(effect);
        expect(at > 0, isTrue, reason: 'lost track of $effect');
        expect(consume < at, isTrue,
            reason: 'The suppression runs AFTER `$effect`, so a manual skip '
                'still triggers it.');
      }
    });

    test('the fast path will not make a blocked track audible', () {
      // Anchored on CODE, not on the comment above it. This used to quote the
      // comment header, so a reword broke the test for no real reason.
      final fast = queue.substring(queue.indexOf('final nextSong = currentState.queue[1];'));
      expect(fast.contains('effectiveBlacklist.contains(nextSong.id)'), isTrue,
          reason: 'playSong auto-skips a disliked or temp-failed queue[1]. '
              'Playing it first and retracting it is the wrong order.');
    });

    test('the pivot refill is not awaited on the skip path', () {
      // playNext awaits handleSmartSkipDetection before it touches the queue, so
      // awaiting a recommendation fetch here put the whole thing — plus
      // refreshAutoplay's 550ms minimum spinner — between the tap and the music.
      final smart = File('lib/logic/player_smart.dart').readAsStringSync();
      final pivot = smart.substring(smart.indexOf('PIVOT STRATEGY'));
      final body = pivot.substring(0, pivot.indexOf('_consecutiveSkips = 0'));
      expect(body.contains('await refreshAutoplay()'), isFalse,
          reason: 'The third consecutive skip once again waits out a whole '
              'recommendation fetch before the next track can start.');
      expect(body.contains('refreshAutoplay()'), isTrue,
          reason: 'The pivot no longer happens at all — the skip is fast '
              'because the recommendation strategy stopped changing.');
    });
  });

  group('a mid-track re-resolve asks the client that pinned the format', () {
    final system = File('lib/logic/player_system.dart').readAsStringSync();

    test('it uses the sticky rotation, never a literal 0', () {
      expect(system.contains('final rot = midTrack ? 0 :'), isFalse,
          reason: 'Back to asking client 0 mid-track. Rotation is STICKY, so a '
              'track that escalated was pinned by client 1 or 2 — asking client '
              '0 for "the same format" returns a different one by construction, '
              'and the pin then refuses every attempt forever (the 4/3, 5/3, '
              '6/3 loop).');
      expect(system.contains('_streamClientRotation[videoId] ?? 0'), isTrue,
          reason: 'The mid-track branch no longer reads the sticky index.');
    });

    test('reading the rotation must not ALSO bump it', () {
      // _nextStreamClientRotation escalates on a rapid repeat, and a mid-track
      // 403 storm is exactly that shape — so calling it here would step the
      // ladder during the one operation that must not change format.
      final at = system.indexOf('final rot = midTrack');
      expect(at > 0, isTrue);
      final decl = system.substring(at, system.indexOf(';', at));
      expect(decl.contains('_nextStreamClientRotation(videoId)'), isTrue,
          reason: 'A fresh resolve must still escalate.');
      final midBranch = decl.substring(0, decl.indexOf(':'));
      expect(midBranch.contains('_nextStreamClientRotation'), isFalse,
          reason: 'The mid-track branch calls the escalating helper, which '
              'steps the format ladder during a re-resolve that exists to keep '
              'the format identical.');
    });

    test('a lapsed cooldown restarts the refusal count', () {
      // Counting on from the previous run made the log report a cap it had
      // already passed (4/3, 5/3, 6/3) and, worse, meant the next single
      // mismatch tripped give-up immediately instead of allowing the two
      // transient retries the cap exists to permit.
      final free = system.substring(system.indexOf('THE FREE "NO"'));
      final upTo = free.substring(0, free.indexOf('final rot ='));
      expect(upTo.contains('_pinFailCount = 0'), isTrue,
          reason: 'The counter is never reset when the cooldown lapses.');
      // And the other half, which is what the first attempt at this got wrong:
      // the reset has to be GUARDED. _pinCooldownUntilMs starts at zero, so an
      // unguarded reset fires on every matching re-resolve and the give-up cap
      // can never be reached — seven "(1/3)" refusals in 24s, then a dead
      // resolve. Removing the guard is the regression; removing the reset is the
      // over-correction. Both are failures here.
      expect(upTo.contains('_pinCooldownUntilMs != 0'), isTrue,
          reason: 'The reset is unguarded, so the give-up cap is unreachable.');
    });
  });

  group('a skipped track costs no lyrics scan', () {
    // THIS IS THE FIX FOR THE THROTTLE, NOT THE BACKOFF BELOW. A lyrics
    // lookup is a MULTI-PROVIDER scan, and playSong fired one per track change —
    // 91 scans for 92 tracks across the transcripts, including every track
    // skipped past in a second. That fan-out is what makes four minutes of
    // skip-testing enough for YouTube to start refusing every client.
    final playback = File('lib/logic/player_playback.dart').readAsStringSync();
    final smart = File('lib/logic/player_smart.dart').readAsStringSync();

    test('the scan is behind a dwell, not a microtask', () {
      expect(playback.contains('Future.microtask(() => _preloadLyrics(song))'),
          isFalse,
          reason: 'Lyrics are fetched immediately on every track change again, '
              'so a run of skips pays a provider sweep per skip.');
      expect(playback.contains('Timer(_kLyricsDwell'), isTrue,
          reason: 'The dwell timer is gone.');
      expect(smart.contains('_kLyricsDwell = Duration(seconds: 3)'), isTrue,
          reason: 'The dwell changed. At 0 this is the old behaviour.');
    });

    test('a run of skips collapses to ONE scan', () {
      // Superseding the timer is the whole mechanism: without the cancel each
      // skip arms its own, and ten skips still cost ten scans, just later.
      final at = playback.indexOf('_lyricsDwellTimer?.cancel();');
      final arm = playback.indexOf('_lyricsDwellTimer = Timer(');
      expect(at > 0, isTrue, reason: 'The previous dwell is never cancelled.');
      expect(at < arm, isTrue,
          reason: 'The cancel runs after the arm, so it kills the timer it just '
              'created and lyrics are never warmed at all.');
    });

    test('a late timer will not warm lyrics for a track that moved on', () {
      final body = playback.substring(playback.indexOf('_lyricsDwellTimer = Timer('));
      final guard = body.substring(0, body.indexOf('_preloadLyrics(song)'));
      expect(guard.contains('currentState.currentSong?.id != song.id'), isTrue,
          reason: 'The timer no longer checks it is still the same track, so it '
              'warms lyrics for whatever was playing 3 seconds ago.');
    });

    test('the dwell timer is cancelled on dispose', () {
      final provider =
          File('lib/providers/player_provider.dart').readAsStringSync();
      final dispose = provider.substring(provider.indexOf('void dispose()'));
      expect(dispose.substring(0, 900).contains('_lyricsDwellTimer?.cancel()'),
          isTrue,
          reason: 'A pending dwell outlives the notifier.');
    });
  });

  group('a refusal is not retried like a network fault', () {
    // On 2026-08-30 every InnerTube client began answering LOGIN_REQUIRED /
    // UNPLAYABLE at once, and the signed-in pass returned 400 — while
    // verifyAccess kept returning 200 on the same cookie, so neither the session
    // nor the network was at fault. Native then re-asked every five seconds
    // forever, sweeping the whole client chain each time: about one request per
    // second that could not possibly succeed.
    final system = File('lib/logic/player_system.dart').readAsStringSync();
    final resolver =
        system.substring(system.indexOf('NativeAudioEngine.setStreamResolver'));

    test('the cooldown is checked before any network work', () {
      final free = resolver.indexOf('_resolveCooldownUntilMs >');
      final fetch = resolver.indexOf('getStreamWithFallback');
      expect(free > 0, isTrue, reason: 'The free "no" is gone.');
      expect(free < fetch, isTrue,
          reason: 'The cooldown is consulted after the fetch, so a suppressed '
              'resolve still costs a full sweep of the client chain — which is '
              'the entire cost this exists to avoid.');
    });

    test('a single unavailable track still skips fast', () {
      // Region-locked, pulled or age-gated tracks are normal, and one of them
      // must not put the whole resolver to sleep.
      expect(system.contains('_maxNoStreamStreak = 3'), isTrue,
          reason: 'The streak threshold changed. At 1 a single unavailable '
              'track would silence playback for 30 seconds instead of skipping '
              'to the next one.');
    });

    test('the backoff is bounded at both ends', () {
      expect(system.contains('_resolveCooldownBaseMs = 30000'), isTrue);
      expect(system.contains('_resolveCooldownMaxMs = 300000'), isTrue);
      expect(resolver.contains('.clamp(_resolveCooldownBaseMs, _resolveCooldownMaxMs)'),
          isTrue,
          reason: 'An unclamped shift overflows into a cooldown measured in '
              'days, which would look exactly like the app being broken.');
    });

    test('one success clears the streak AND the cooldown', () {
      // Without both, the first track to play after a throttle lifts would still
      // be followed by suppressed resolves.
      final ok = resolver.substring(resolver.indexOf('_noStreamStreak > 0'));
      final body = ok.substring(0, ok.indexOf('return {'));
      expect(body.contains('_noStreamStreak = 0'), isTrue);
      expect(body.contains('_resolveCooldownUntilMs = 0'), isTrue,
          reason: 'The cooldown outlives the recovery that ended it.');
    });
  });

  group('the topic memos may trust map identity', () {
    // SAME CONTRACT AS THE LIBRARY SAVE, DIFFERENT MAPS. _getArtistTopics and
    // _getGenreTopics return a cached list when the maps they read are the same
    // instances as last time. An in-place write keeps the instance while changing
    // the answer, and the symptom would be topics that quietly stop tracking the
    // listener — no error, just a home feed that stops learning.
    const maps = ['artistAffinities', 'genreAffinities', 'genreBoosts'];
    const mutators = [
      'add',
      'addAll',
      'remove',
      'removeWhere',
      'clear',
      'update',
      'updateAll',
      'putIfAbsent',
    ];

    final dart = Directory('lib')
        .listSync(recursive: true)
        .whereType<File>()
        .where((f) => f.path.endsWith('.dart'))
        .toList();

    test('no intelligence map behind a memo is written in place', () {
      final offenders = <String>[];
      for (final f in dart) {
        final lines = f.readAsStringSync().split('\n');
        for (var i = 0; i < lines.length; i++) {
          final line = lines[i];
          if (line.trimLeft().startsWith('//')) continue;
          for (final m in maps) {
            for (final mut in mutators) {
              if (line.contains('state.$m.$mut(')) {
                offenders.add('${f.path}:${i + 1}: state.$m.$mut(');
              }
            }
            // An index ASSIGNMENT only — `state.x[k] = v`. Plain `state.x[k]`
            // reads are everywhere and are fine.
            if (RegExp('state\\.$m\\[[^\\]]*\\]\\s*=[^=]').hasMatch(line)) {
              offenders.add('${f.path}:${i + 1}: state.$m[...] =');
            }
          }
        }
      }
      expect(offenders, isEmpty,
          reason: 'These write an intelligence map in place, so a memo keyed on '
              'its identity returns a stale list:\n${offenders.join('\n')}');
    });

    test('the genre memo bounds how stale a boost expiry can make it', () {
      // getGenreBoostMultiplier turns 1.0 when a boost EXPIRES, and expiry is a
      // clock reading — the map is unchanged when it happens, so identity alone
      // would pin a stale ordering until some unrelated write.
      final home =
          File('lib/providers/home_provider.dart').readAsStringSync();
      expect(home.contains('_genreTopicsMaxAge'), isTrue,
          reason: 'The time bound is gone, so an expired genre boost can no '
              'longer reorder the topics until something else changes.');
      final check = home.substring(home.indexOf('_genreTopicsMemo != null &&'));
      expect(check.substring(0, check.indexOf('return')).contains('_genreTopicsMaxAge'),
          isTrue,
          reason: 'The max-age is declared but not consulted by the memo check.');
    });
  });

  group('the audio-only conform cannot loop', () {
    // THIS ONE FROZE THE APP. On 2026-08-30 two recordings of "willow" each
    // conformed to the other, and playSong recursed between them inside a single
    // millisecond until Android offered "Auvy isn't responding". The only guard
    // was `audio.id != inputSong.id`, which stops A→A and says nothing about
    // A→B→A.
    final playback = File('lib/logic/player_playback.dart').readAsStringSync();
    final conform = playback.substring(
        playback.indexOf('AUDIO-ONLY: conform a music VIDEO'),
        playback.indexOf('final song = inputSong.copyWith('));

    test('playSong carries a chain of visited ids', () {
      expect(playback.contains('Set<String>? conformChain'), isTrue,
          reason: 'The conform chain parameter is gone, so nothing remembers '
              'which ids this chain has already been through.');
      expect(conform.contains('{...?conformChain, inputSong.id}'), isTrue,
          reason: 'The current id is no longer added to the chain, so a two-step '
              'cycle is invisible again.');
    });

    test('the recursion passes the chain on', () {
      // Without this the chain is always a single id and the guard can only ever
      // catch A→A — which the old code already did.
      final recursion = conform.substring(conform.indexOf('return playSong('));
      expect(recursion.contains('conformChain: chain'), isTrue,
          reason: 'The recursive playSong drops the chain, so every level starts '
              'over and the loop comes back.');
    });

    test('a revisited id refuses the swap instead of recursing', () {
      final guard = conform.indexOf('chain.contains(audio.id)');
      final swap = conform.indexOf('return playSong(');
      expect(guard > 0, isTrue, reason: 'The cycle check is gone.');
      expect(guard < swap, isTrue,
          reason: 'The cycle check runs after the swap, so the queue is still '
              'rewritten and the recursion still happens.');
    });

    test('the chain is not shared state on the notifier', () {
      // Plays overlap (the transition debounce), so a field would let one chain
      // terminate another — a track silently refusing a conform it never made.
      expect(playback.contains('_conformChain ='), isFalse,
          reason: 'The chain became notifier state. It belongs to the call: '
              'concurrent plays would interfere with each other.');
    });
  });

  group('the library save may trust object identity', () {
    // THIS GUARDS A DATA-LOSS RISK, NOT A PERFORMANCE ONE.
    //
    // _saveToDisk returns early when the state object is the same instance it
    // last encoded. That is sound ONLY while every mutation replaces the state
    // via copyWith — if anything edits a state collection in place, the instance
    // stays identical while the content changes, and the save that was supposed
    // to persist it is skipped. In this file that means losing a playlist.
    //
    // So the assumption is checked here rather than trusted. Anything this test
    // catches must be turned into a copyWith, not worked around in the save.
    const fields = [
      'allItems',
      'likedSongs',
      'likedAlbums',
      'likedPlaylists',
      'subscribedArtists',
      'playlistSongs',
      'downloadProgressMap',
    ];
    const mutators = [
      'add',
      'addAll',
      'remove',
      'removeAt',
      'removeWhere',
      'removeLast',
      'clear',
      'insert',
      'insertAll',
      'sort',
      'shuffle',
      'putIfAbsent',
      'update',
      'updateAll',
    ];

    final dart = Directory('lib')
        .listSync(recursive: true)
        .whereType<File>()
        .where((f) => f.path.endsWith('.dart'))
        .toList();

    test('no state collection is mutated in place', () {
      final offenders = <String>[];
      for (final f in dart) {
        final lines = f.readAsStringSync().split('\n');
        for (var i = 0; i < lines.length; i++) {
          final line = lines[i];
          if (line.trimLeft().startsWith('//')) continue;
          for (final field in fields) {
            for (final m in mutators) {
              if (line.contains('state.$field.$m(')) {
                offenders.add('${f.path}:${i + 1}: state.$field.$m(');
              }
            }
            // `state.playlistSongs['x'] = …` — an index assignment is an
            // in-place write too, and reads nothing like one.
            if (RegExp('state\\.$field\\[[^\\]]*\\]\\s*=[^=]').hasMatch(line)) {
              offenders.add('${f.path}:${i + 1}: state.$field[...] =');
            }
          }
        }
      }
      expect(offenders, isEmpty,
          reason: 'These mutate library state IN PLACE, so the state object '
              'stays identical while its content changes — and _saveToDisk '
              'skips a save it should have made:\n${offenders.join('\n')}');
    });

    test('no state collection is aliased and then written through', () {
      // `final items = state.allItems;` hands out the LIVE list. The alias can
      // then be mutated somewhere the check above cannot see it.
      final offenders = <String>[];
      for (final f in dart) {
        final lines = f.readAsStringSync().split('\n');
        for (var i = 0; i < lines.length; i++) {
          final line = lines[i];
          if (line.trimLeft().startsWith('//')) continue;
          for (final field in fields) {
            if (RegExp('=\\s*state\\.$field\\s*;').hasMatch(line)) {
              offenders.add('${f.path}:${i + 1}: ${line.trim()}');
            }
          }
        }
      }
      expect(offenders, isEmpty,
          reason: 'A live state collection is aliased here. Copy it '
              '(List.from / Map.from) so it cannot be written through:\n'
              '${offenders.join('\n')}');
    });

    test('the save records the snapshot on BOTH of its exits', () {
      // Recorded only on the write path, the cheap check would keep missing
      // after a byte-identical skip and every later call would re-encode the
      // whole library to reach the same conclusion.
      final source =
          File('lib/providers/library_provider.dart').readAsStringSync();
      final save = source.substring(source.indexOf('Future<void> _saveToDisk'));
      expect(save.contains('identical(snapshot, _lastEncodedState)'), isTrue,
          reason: 'The O(1) pre-check is gone.');
      final skip = save.indexOf('byte-identical to the last write');
      final written = save.indexOf('_lastSavedSig = sig;');
      expect(save.lastIndexOf('_lastEncodedState = snapshot;', skip) > 0, isTrue,
          reason: 'The byte-identical exit does not record the snapshot.');
      expect(save.indexOf('_lastEncodedState = snapshot;', written) > 0, isTrue,
          reason: 'The successful write does not record the snapshot.');
    });
  });

  group('the share card cannot print its link over the kind label', () {
    final card =
        File('lib/presentation/widgets/share_postcard.dart').readAsStringSync();
    final row = card
        .substring(card.indexOf('if (_universalLink(song, kind).isNotEmpty)'));
    final block = row.substring(0, row.indexOf('],'));

    test('the url is width-constrained and clips', () {
      expect(block.contains('Expanded('), isTrue,
          reason: 'A Spacer leaves the Text unbounded, so a long song.link id '
              'grows past its share of the row and prints over ALBUM/PLAYLIST. '
              'The card is rasterised at 3x, so the overlap is baked into the '
              'image someone keeps.');
      expect(block.contains('maxLines: 1'), isTrue);
      expect(block.contains('overflow: TextOverflow.ellipsis'), isTrue);
    });

    test('the tap target adds no pixels to the exported image', () {
      // The same widget is both the live preview and the thing the
      // RepaintBoundary rasterises, so anything that PAINTS shows up in the png.
      expect(block.contains('GestureDetector('), isTrue,
          reason: 'The link is no longer tappable.');
      expect(block.contains('InkWell') || block.contains('TextButton'), isFalse,
          reason: 'An inking or padded widget would change what the exported '
              'card looks like.');
    });
  });

  group('the mosaic tile follows a cover change without a reload', () {
    final home =
        File('lib/presentation/pages/home_page.dart').readAsStringSync();

    test('a collection tile watches the override map', () {
      expect(home.contains('artworkOverrideProvider.select('), isTrue,
          reason: 'Album and playlist tiles are back to the recorded snapshot, '
              'so a chosen cover waits for the recents row to be rewritten — '
              'which reads as "I have to reload the home page".');
    });

    test('it watches ONE key, not the whole map', () {
      // The narrow watch is what keeps this from being a cost: the map is local
      // and only changes when someone picks or clears a cover, and select()
      // limits the rebuild to the one tile whose key moved.
      final fn = home.substring(home.indexOf('String _entryImage('));
      final body = fn.substring(0, fn.indexOf('\n}'));
      expect(body.contains("m['playlist:\${title.trim()}']"), isTrue,
          reason: 'The selector no longer narrows to this tile key.');
    });

    test('the resolver runs inside a widget build, not a lazy item builder', () {
      // ref.watch outside a build scope does not register a dependency. The
      // tiles are laid out by PageView/GridView builders, so this only works
      // because _MosaicTile is itself a ConsumerWidget.
      expect(home.contains('class _MosaicTile extends ConsumerWidget'), isTrue,
          reason: '_MosaicTile is no longer a ConsumerWidget, so the override '
              'watch inside it is registered on the wrong element (or on none).');
      final tile = home.substring(home.indexOf('class _MosaicTile'));
      expect(tile.contains('_entryImage(ref, entry)'), isTrue,
          reason: 'The tile no longer resolves its image through the override.');
    });
  });

  group('identical lyrics are not rewritten to disk', () {
    // Two or three saves per play — the mid-track auto-cache timer and the
    // track-end promotion both hand over the bytes the first one wrote. 159
    // saves across 92 tracks in one day.
    final cache =
        File('lib/logic/audio_cache_manager.dart').readAsStringSync();

    test('saveLyrics compares before it writes', () {
      final fn = cache.substring(cache.indexOf('Future<void> saveLyrics('));
      // Bounded by the NEXT declaration rather than by the comment that used to
      // sit between them. Prose moves; a method signature does not.
      final body = fn.substring(0, fn.indexOf('getLyrics(String songId)'));
      final compare = body.indexOf('await file.readAsString() == encoded');
      final write = body.indexOf('await file.writeAsString(encoded)');
      expect(compare > 0, isTrue,
          reason: 'The read-before-write check is gone, so every auto-cache '
              'attempt rewrites the same lyrics file again.');
      expect(compare < write, isTrue);
    });

    test('a promotion with nothing to promote is not reported as a failure', () {
      // A promotion-only caller passes an empty url deliberately: it is asking
      // whether the play-cache holds the track whole, and "no" is an ordinary
      // answer for anything played from a local file.
      // Code anchor, for the same reason as above. The comment it used to
      // quote was reworded in the 2026-09-02 pass.
      final note = cache.indexOf(
          'if (filePath.isNotEmpty && await partial.exists())');
      expect(note > 0, isTrue,
          reason: 'The note explaining why two outcomes share this exit is '
              'gone, which is usually a sign the split went with it.');
      final body = cache.substring(note, cache.indexOf('return false;', note));
      expect(body.contains('if (streamUrl.isEmpty) {'), isTrue,
          reason: 'Both outcomes share one warning again. A warning that fires '
              'on a normal outcome trains the reader to skip it.');
    });
  });
}
