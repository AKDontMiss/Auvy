// Manages background "smart" features like autoplay recommendations, preloading, and lyrics fetching.
part of '../providers/player_provider.dart';

// Session cache for the expensive per-artist recommendation seed fetch. Radio
// revisits the same artists constantly, and the "queue ended → emergency
// refill" path could re-request the SAME artist several times in seconds — each
// a fresh multi-MB YouTube-Music fetch. Memoizing by artist string (short TTL)
// turns those repeats into instant, zero-network hits — the main data-usage fix.
final Map<String, List<Song>> _artistSeedCache = {};
final Map<String, DateTime> _artistSeedCacheAt = {};
const Duration _kArtistSeedTtl = Duration(minutes: 15);

// Lyrics wait until a track is actually being listened to
//
// THE COST THIS REMOVES, and it is the largest per-skip cost there is. A
// lyrics lookup is a MULTI-PROVIDER scan, and playSong fired one for every
// track change — including a track skipped past in a second, whose lyrics
// nobody will ever read. Measured across the 2026-08-30 transcripts: 91 scans
// for 92 tracks, one per skip, each ~100ms after the tap.
//
// That fan-out is what makes a skip expensive. One skip is a stream resolve
// plus a whole provider sweep, and four minutes of skip-testing was enough for
// YouTube to start refusing every client — an outage that then lasted hours.
// Backing off once refused (see _maxNoStreamStreak) treats the symptom; not
// spending the requests is the fix.
//
// ONE timer, library-level because this file is an extension, so a run of
// skips collapses into a single scan for the track the listener actually lands
// on. Safe to delay at all because the preload is only a warm-up: the lyrics
// VIEW fetches on demand through lyricsProvider, so opening lyrics inside the
// dwell window still works and simply warms the same cache early.
Timer? _lyricsDwellTimer;

/// How long a track must remain current before its lyrics are worth fetching.
///
/// Long enough that skipping through a queue costs nothing, short enough that
/// a listener who settles on a track and opens lyrics finds them already
/// warm — the paint is instant either way, because the view fetches for itself.
const Duration _kLyricsDwell = Duration(seconds: 3);

/// Why preloading is currently paused, or null when it is allowed.
///
/// Library-level because this file is an extension. Holds the LAST reported
/// reason so [_shouldPreloadNext] can speak on a transition instead of on every
/// position tick. See the note there.
String? _preloadBlockedReason;

extension PlayerSmartController on PlayerNotifier {

  Future<void> prewarmSession() async {
    final song = currentState.currentSong;
    if (song == null) return;
 
    // Preload lyrics for the current track
    _preloadLyrics(song);
 
    if (_cacheManager.isCached(song.id)) {
      // Current track is cached — preload lyrics for the next one too
      if (currentState.queue.length > 1) {
        final nextSong = currentState.queue[1];
        _preloadLyrics(nextSong);
      }
      return;
    }
  }

  Future<void> handleSmartSkipDetection(Song skippedSong, double listenPercent) async {
    final genre = currentState.contextTitle ?? currentState.contextType ?? "General";
    
    // Track skips
    if (listenPercent < 0.3) {
      _consecutiveSkips++;
      
      // listenPercent is a 0–1 fraction — ×100 for display (it used to print
      // "0% played" for anything under 50%).
      print("Skip detected: ${skippedSong.title} (${(listenPercent * 100).toStringAsFixed(0)}% played)");
      
      // PIVOT STRATEGY: After 3 skips, change the vibe
      if (_consecutiveSkips >= 3) {
        print("PIVOT: 3 consecutive skips detected! Changing recommendation strategy...");
        
        final intel = ref.read(intelligenceProvider.notifier);
        
        // Temporarily penalize current genre
        final newSession = Map<String, double>.from(
          ref.read(intelligenceProvider).sessionAffinities
        );
        newSession[genre] = (newSession[genre] ?? 0.0) - 15.0;
        
        // Boost alternative genres
        final complementaryGenres = intel.getComplementaryGenres(genre);
        for (final altGenre in complementaryGenres.take(2)) {
          newSession[altGenre] = (newSession[altGenre] ?? 0.0) + 10.0;
        }
        
        // Through the notifier's own mutator, which persists. Assigning `.state`
        // from outside skipped _saveStateDebounced and lost the vibe shift.
        ref.read(intelligenceProvider.notifier).setSessionAffinities(newSession);
        
        // The pivot must NOT be in the listener's way
        //
        // THE BUG THIS FIXES: the second half of "sometimes there is a delay
        // when skipping". playNext AWAITS this method before it touches the
        // queue, so awaiting the refill here put a whole recommendation fetch —
        // plus refreshAutoplay's deliberate 550ms minimum spinner lifetime —
        // between the tap and the next track. It fired on the THIRD consecutive
        // skip, which is precisely when someone is pressing next repeatedly, so
        // the delay landed exactly where it was least wanted and nowhere else.
        // That intermittency is why it read as "sometimes".
        //
        // Unawaited and given the skip a moment to land first, so the queue
        // rotation for THIS tap finishes before the refill rewrites what comes
        // after it. The pivot still happens; it just stops being something the
        // listener sits through. Seeding a moment later also means the new
        // recommendations are drawn from the track now PLAYING rather than from
        // the one that was just rejected.
        Timer(const Duration(milliseconds: 300), () {
          if (mounted) refreshAutoplay();
        });
        
        _consecutiveSkips = 0;
      }
    } else {
      // Reset skip counter on successful listen
      _consecutiveSkips = 0;
    }
  }

  /// Autoplay refill. Concurrent callers share ONE in-flight refill and can
  /// AWAIT its completion — the old boolean flag made the track-end emergency
  /// path silently no-op against a refill started elsewhere, then give up with
  /// the queue still empty (playback just stopped even though tracks arrived a
  /// second later).
  ///
  /// [force] is the continue-playback emergency (queue fully dry at track end):
  /// it bypasses the prefetch/data-saver niceties — keeping the music going is
  /// not a background prefetch, but still respects hard offline.
  Future<void> _topUpQueue({bool force = false}) {
    final inFlight = _refillInFlight;
    if (inFlight != null) return inFlight;
    final future = _topUpQueueInner(force: force)
        .whenComplete(() => _refillInFlight = null);
    _refillInFlight = future;
    return future;
  }

  Future<void> _topUpQueueInner({bool force = false}) async {
    if (currentState.currentSong == null) {
      return;
    }

    // Radio, a podcast episode and a book chapter all have URL ids, and none of
    // them wants music appended after it. The guard is the same; the LOG is not,
    // because a transcript that calls a chapter a live stream sends the next
    // reader looking for a radio bug that was never there.
    final kind = currentState.currentSong!.mediaKind;
    if (kind != MediaKind.music) {
      print("${kind.name} active — skipping smart autoplay top-up");
      return;
    }

    // Any repeat mode → no autoplay top-up. Repeat One loops the track and
    // Repeat All is now a CIRCULAR queue (finished tracks re-append), so the
    // queue self-sustains — injecting recommendations would pollute the loop.
    if (currentState.repeatMode != RepeatMode.off) {
      print("Skipping autoplay top-up (repeat mode active)");
      return;
    }

    // Settings → Playback → "Autoplay similar music". Top-up used to be
    // unconditional, so a chosen album or playlist could never actually end —
    // there was no way to ask Auvy to stop when your record finished.
    if (!ListeningPolicy.autoplay) {
      print("Autoplay disabled in settings - queue will end naturally");
      return;
    }

    final connectivity = ref.read(connectivityProvider);
    if (connectivity.isOffline) {
      print("Offline - skipping top-up");
      return;
    }
    if (!force &&
        (!connectivity.shouldPrefetch ||
            connectivity.dataSaverMode == DataSaverMode.always)) {
      print("Data saver / prefetch off - skipping non-urgent top-up");
      return;
    }

    final upcomingCount = currentState.userQueue.length + currentState.contextQueue.length + currentState.autoplayQueue.length;

    // Only refill when the queue is genuinely running dry. The old threshold
    // (12) kept topping a healthy queue back up with recommendations — part of
    // the "queue refreshes itself after every track" bug.
    if (upcomingCount >= 5) {
      print("OK: Queue healthy: $upcomingCount tracks available");
      return;
    }

    _refillDebounce?.cancel();

    if (Random().nextInt(10) == 0) {
      ref.read(intelligenceProvider.notifier).logListeningStats();
    }
    
    try {
      final targetCount = 10 - currentState.autoplayQueue.length;
      final taste = ref.read(intelligenceProvider);
      final intelNotifier = ref.read(intelligenceProvider.notifier);
      final shouldUseContext = _shouldUseContextualRecommendations();
      
      // Log active genre boosts
      final activeBoosts = intelNotifier.getActiveBoosts();
      if (activeBoosts.isNotEmpty) {
        print("Active Genre Boosts:");
        activeBoosts.forEach((genre, boost) => print("   $genre: $boost"));
      }
      
      List<Song> finalPicks = [];
      int attempts = 0;
      final Set<String> existingIds = {
        currentState.currentSong!.id,
        ...currentState.history.map((s) => s.id),
        ...currentState.queue.map((s) => s.id),
        ...currentState.blacklistedIds,
      };

      // ALGORITHM FIX: Absolute Duplicate Prevention
      final Set<String> existingSignatures = {
        '${currentState.currentSong!.title.toLowerCase()}_${currentState.currentSong!.artist.toLowerCase()}',
        ...currentState.history.map((s) => '${s.title.toLowerCase()}_${s.artist.toLowerCase()}'),
        ...currentState.queue.map((s) => '${s.title.toLowerCase()}_${s.artist.toLowerCase()}'),
      };

      while (finalPicks.length < (targetCount / 2) && attempts < 2) {
        attempts++;
        List<Song> candidates;
        
        if (attempts == 1) {
          // PRIMARY: YouTube Music's native radio for the CURRENT track — the
          // smartest continuation there is (YouTube's own collaborative-filtering
          // recs, personalized when signed in). If it
          // comes back empty (guest throttle / network / non-videoId) fall back
          // to the contextual or Spotify-style engine.
          candidates = await _getCatalogRadioRecommendations();
          if (candidates.isEmpty) {
            candidates = (shouldUseContext && currentState.contextType != null)
                ? await _getContextualRecommendations(
                    needed: targetCount, taste: taste, intelNotifier: intelNotifier)
                : await _generateSeededRecommendations(
                    seedCount: targetCount, taste: taste, intelNotifier: intelNotifier);
          }
        } else {
          candidates = await _generateSeededRecommendations(
            seedCount: targetCount,
            taste: taste,
            intelNotifier: intelNotifier,
          );
        }

        final scoredRecs = <({Song song, double score})>[];
        for (final song in candidates) {
          final signature = '${song.title.toLowerCase()}_${song.artist.toLowerCase()}';
          
          // CRITICAL BLOCK: Reject if ID OR Signature already exists
          if (existingIds.contains(song.id) || existingSignatures.contains(signature) || taste.blacklistedIds.contains(song.id)) continue;

          // Reject placeholder/category junk (tracks/channels literally named
          // "General", "Top", "Unknown", etc.) so they never enter the queue.
          if (isJunkMusicTerm(song.artist) || isJunkMusicTerm(song.title)) continue;
          
          // Pass current song's genre so suggestions stay genre-coherent
          final currentGenre = currentState.contextType == 'genre'
              ? currentState.contextTitle
              : (currentState.currentSong != null
                  ? ref.read(intelligenceProvider.notifier)
                        .getComplementaryGenres(currentState.currentSong!.artist)
                        .firstOrNull
                  : null);
          
          // Apply genre boost multiplier to score
          var score = intelNotifier.getSongScore(song, currentContext: currentGenre);
          
          // Apply active boost if song matches boosted genre
          final songGenre = currentState.contextTitle ?? currentState.contextType ?? "General";
          final boostMultiplier = intelNotifier.getGenreBoostMultiplier(songGenre);
          if (boostMultiplier > 1.0) {
            score *= boostMultiplier;
            print("    Boosted: ${song.title} (${boostMultiplier.toStringAsFixed(1)}x)");
          }

          // ALGORITHM FIX: Aggressive Artist Penalty
          final artistCountInQueue = currentState.queue
              .where((q) => q.artist == song.artist)
              .length;
          score -= (artistCountInQueue * 30.0);

          // AN "ARTWORK UPGRADE" THAT GUARANTEED THE OPPOSITE — REMOVED.
          //
          // This used to call `getHighResImage(song.title)` for any track with a
          // weak image. But that method takes a URL, not a title: its first line
          // returns YouTube's generic grey placeholder for anything that does not
          // start with `http`. A title never does, so it ALWAYS returned the
          // placeholder, the isNotEmpty check always passed, and every track it
          // touched had its artwork overwritten with a grey square. The `await`
          // was on a plain String (the analyzer said so) and the whole thing sat
          // in `catch (_) {}`, so it never made a sound.
          //
          // Worse than a no-op: the placeholder URL was baked into the Song and
          // travelled with it into the queue, history and cache, so the track
          // could never recover real art. Leaving `song.image` alone lets
          // AuvyImage render its own fallback for an empty image and lets a
          // later, better-sourced copy of the song win.
          //
          // There is no async artwork lookup to substitute here, and a network
          // call per candidate inside this scoring loop would be the wrong place
          // for one regardless.
          scoredRecs.add((song: song, score: score));
          existingIds.add(song.id);
          existingSignatures.add(signature); // Track this signature going forward
        }

        scoredRecs.sort((a, b) => b.score.compareTo(a.score));
        finalPicks.addAll(scoredRecs.take(targetCount - finalPicks.length).map((s) => s.song));
        
        if (finalPicks.length >= targetCount) break;
      }
      
      if (finalPicks.isNotEmpty) {
        final updatedAutoplay = [...currentState.autoplayQueue, ...finalPicks];
        final newFullQueue = [
          currentState.currentSong!,
          ...currentState.userQueue,
          ...currentState.contextQueue,
          ...updatedAutoplay,
        ];
        // Dart driven queue logic
        // With the native engine owning playback, we ONLY need to update the UI state.
        // We do not manage ConcatenatingAudioSource.
        currentState = currentState.copyWith(
          autoplayQueue: updatedAutoplay,
          queue: newFullQueue,
          // Keep the unshuffled snapshot in sync, or turning shuffle OFF later
          // DROPS the recs added during a shuffled session (they weren't in the
          // pre-shuffle snapshot, so toggleShuffle's restore filtered them out).
          originalQueue: currentState.isShuffle
              ? [...currentState.originalQueue, ...finalPicks]
              : newFullQueue,
        );

        // NOTE: We deliberately do NOT prefetch tracks here (on queue refill /
        // track start). Downloading full upcoming tracks while the current one
        // is still streaming saturated bandwidth — it re-buffered the playing
        // track (audio stutter) and slowed search/page loads. Prefetch now
        // happens once, near the end of the current track, in _preloadNextTrack
        // (Spotify-style), when the current stream is already buffered.
        print("OK: Refilled queue with ${finalPicks.length} tracks after $attempts attempts.");
      }
    } catch (e) {
      print("ERROR: Smart Autoplay Error: $e");
    }
  }

  /// Determines whether to use contextual or fully personalized recommendations
  bool _shouldUseContextualRecommendations() {
    if (currentState.contextType == null || currentState.contextType!.isEmpty) {
      print("No context - using personalized recommendations");
      return false;
    }
    
    final contextType = currentState.contextType!.toLowerCase();
    
    if (contextType == 'search' || 
        contextType == 'home' || 
        contextType == 'quick picks' ||
        contextType == 'random') {
      print("Source: $contextType - using personalized recommendations");
      return false;
    }
    
    if (contextType == 'artist' || 
        contextType == 'album' || 
        contextType == 'playlist' ||
        contextType == 'genre' ||
        contextType == 'mix') {
      print("Source: $contextType - using contextual recommendations");
      return true;
    }
    
    print("Unknown context: $contextType - using personalized recommendations");
    return false;
  }

  /// PRIMARY autoplay source — YouTube Music's native "song radio" for the
  /// currently-playing track. Candidates still flow
  /// through the taste-scoring / artist-penalty / dedup / junk / blacklist
  /// pipeline in _topUpQueueInner, so YouTube's recs get personalised
  /// re-ranking on top. Returns [] (→ fallback engine) for radio / podcast /
  /// non-videoId seeds, or if the endpoint fails.
  Future<List<Song>> _getCatalogRadioRecommendations() async {
    final seed = currentState.currentSong;
    if (seed == null || seed.id.startsWith('http') || seed.id.length != 11) {
      return const [];
    }
    return _searchService.getSongRadio(seed.id);
  }

  /// Get contextual recommendations (for albums, playlists, artist pages)
  Future<List<Song>> _getContextualRecommendations({
    required int needed,
    required IntelligenceState taste,
    required IntelligenceNotifier intelNotifier,
  }) async {
    // The artist branch and the album/playlist branch were byte-identical, and
    // both ran their two seeds one after the other. Collapsed, and awaited
    // together: they share nothing, so the second was only ever waiting for the
    // first to finish talking to the network. The sibling path
    // (_generateSeededRecommendations) has always used Future.wait for its five.
    final ctx = currentState.contextType;
    final List<Song> pool = [];
    if (ctx == 'artist' || ctx == 'album' || ctx == 'playlist') {
      final seeds = await Future.wait([
        _getSeedFromCurrentArtist(),
        _getSeedFromRelatedArtists(),
      ]);
      for (final list in seeds) {
        pool.addAll(list);
      }
    } else {
      pool.addAll(await _getSeedFromContext());
    }
    
    final scored = _scoreAndRankRecommendations(pool, taste);
    final ranked = scored.map((s) => s.song).toList();
    return _selectWithDiversity(ranked, {currentState.currentSong?.id ?? ''}, {}, count: needed);
  }

  Future<List<Song>> _generateSeededRecommendations({
    required int seedCount,
    required IntelligenceState taste,
    required IntelligenceNotifier intelNotifier,
  }) async {
    final List<Song> seedPool = [];
    final currentSong = currentState.currentSong!;
    final Set<String> seenSongIds = {
      currentSong.id,
      ...currentState.history.map((s) => s.id),
      ...currentState.queue.map((s) => s.id),
      ...currentState.blacklistedIds,
    };
    
    print("Generating Spotify-style recommendations...");
    print("   Current: ${currentSong.title} by ${currentSong.artist}");
    print("   Context: ${currentState.contextType ?? 'None'}");
    
    
    final results = await Future.wait([
      _getSeedFromCurrentArtist(),              // 20%
      _getSeedFromContext(),                    // 20% - Style/genre consistency
      _getSeedFromRelatedArtists(),             // 25% - Discovery
      _getSeedFromUserAffinities(taste, intelNotifier), // 20% - Personal taste
      _getSeedFromCollaborativeFiltering(),     // 15% - Social intelligence
    ]);
    
    final weightedSeeds = <Song>[];
    weightedSeeds.addAll(results[0].take(10));  // Current artist 
    weightedSeeds.addAll(results[1].take(5));   // Context/genre 
    weightedSeeds.addAll(results[2].take(10));  // Related artists 
    weightedSeeds.addAll(results[3].take(5));   // User favorites 
    weightedSeeds.addAll(results[4].take(5));   // Collaborative filtering
    
    seedPool.addAll(weightedSeeds);
    
    print("   Seed pool: ${seedPool.length} candidates");

    final scoredItems = _scoreAndRankRecommendations(seedPool, taste);
    final rankedCandidates = scoredItems.map((item) => item.song).toList();
    
    final selection = _selectWithDiversity(
      rankedCandidates, 
      seenSongIds, 
      {}, 
      count: seedCount,
      maintainQuality: true,
    );
    
    return _intelligentShuffle(selection);
  }

  Future<List<Song>> _getSeedFromCurrentArtist() async {
    try {
      final currentArtist = currentState.currentSong!.artist;
      // Don't seed from a placeholder artist ("General"/"Unknown"/...) — it just
      // searches literal junk. Other seed sources (affinities, collaborative)
      // still run.
      if (isJunkMusicTerm(currentArtist)) return [];

      // Serve a recent memoized result for this artist (kills the repeated
      // multi-MB fetches when radio revisits an artist / the emergency-refill
      // path fires several times in a row).
      final seedKey = currentArtist.toLowerCase().trim();
      final seedAt = _artistSeedCacheAt[seedKey];
      if (seedAt != null && DateTime.now().difference(seedAt) < _kArtistSeedTtl) {
        final cached = _artistSeedCache[seedKey];
        if (cached != null && cached.isNotEmpty) {
          print("(cache) top tracks BY $currentArtist");
          return cached;
        }
      }
      print("Fetching top tracks BY $currentArtist...");

      final artistSearchResults = await _searchService.search(currentArtist, 'artist');

      if (artistSearchResults.isEmpty) {
        print("WARN: Artist not found, using smart fallback");
        if (currentState.contextType == 'genre' && currentState.contextTitle != null) {
          final genreTracks = await _searchService.search(currentState.contextTitle!, 'track');
          return genreTracks.take(10).toList();
        }
        final trackResults = await _searchService.search(currentArtist, 'track');
        return trackResults.where((s) => 
          s.artist.toLowerCase().trim() == currentArtist.toLowerCase().trim() ||
          s.artist.toLowerCase().contains(' ${currentArtist.toLowerCase()} ') ||
          s.artist.toLowerCase().startsWith('${currentArtist.toLowerCase()} ')
        ).take(8).toList();
      }

      final bestMatch = artistSearchResults.firstWhere(
        (artist) => artist.title.toLowerCase().trim() == currentArtist.toLowerCase().trim(),
        orElse: () => artistSearchResults.first,
      );

      final artistId = bestMatch.id;
      final topTracks = await _searchService.getArtistTopTracks(artistId);
      print("   Found ${topTracks.length} tracks by $currentArtist");

      if (topTracks.isNotEmpty) {
        // Bound the session seed cache — it's TTL'd but never size-capped, so a
        // long session that touches many artists grew it unbounded. Evict the
        // oldest entry once over 60 artists (LRU-ish; entries also expire by TTL).
        if (_artistSeedCache.length >= 60) {
          String? oldestKey;
          DateTime? oldestAt;
          _artistSeedCacheAt.forEach((k, t) {
            if (oldestAt == null || t.isBefore(oldestAt!)) {
              oldestAt = t;
              oldestKey = k;
            }
          });
          if (oldestKey != null) {
            _artistSeedCache.remove(oldestKey);
            _artistSeedCacheAt.remove(oldestKey);
          }
        }
        _artistSeedCache[seedKey] = topTracks;
        _artistSeedCacheAt[seedKey] = DateTime.now();
      }
      return topTracks;
    } catch (e) {
      print("ERROR: Current artist seed failed: $e");
      return [];
    }
  }

  Future<List<Song>> _getSeedFromRelatedArtists() async {
    try {
      final currentArtist = currentState.currentSong!.artist;
      // A placeholder "artist" ("General", "Unknown", "Top songs") resolves to
      // nothing and costs a wasted browse, so screen it here — the service
      // deliberately does not depend on intelligence_provider for this.
      if (isJunkMusicTerm(currentArtist)) return [];
      print("Fetching related artists to $currentArtist...");

      // THIS RETURNED EMPTY FOR EVERY TRACK UNTIL getRelatedArtists WAS
      // ACTUALLY IMPLEMENTED. It was `async => []` in SearchService, so the guard
      // below fired every time and this whole seed source — 25% of the pool at
      // the call site in _buildRecommendationPool — contributed nothing. Now it
      // returns YouTube Music's own "Fans might also like" for the artist.
      final relatedArtists = await _searchService.getRelatedArtists(currentArtist);

      if (relatedArtists.isEmpty) {
        print("WARN: No related artists found");
        return [];
      }
      print("${relatedArtists.length} related artist(s) for $currentArtist");
      final artistsToCheck = relatedArtists.take(5).toList();
      // Five round trips in a row, plus a sleep that paid for nothing
      //
      // This ran the five artists one after another with an 80 ms pause between
      // them. Two things were wrong with that.
      //
      // The pause is rate limiting at the wrong layer. CatalogApiClient already
      // funnels EVERY InnerTube post through one shared RateLimiter (220 ms
      // minimum interval, burst 5), so the pacing was already handled, correctly
      // and globally, one level down. This just added latency on top of it.
      //
      // Worse, the pause was unconditional, and getBrowse is CACHED (120 entries,
      // 30 minutes). So a top-up that fetched nothing at all still slept 400 ms
      // and still took five sequential turns to do it. On a cold run it was five
      // serialised round trips — 2 to 6 seconds — on the queue top-up path, which
      // is the path that has to finish before the next track is ready.
      //
      // Concurrently, the limiter's burst of 5 covers exactly this shape, and the
      // list result keeps the artists in order.
      final started = DateTime.now();
      final perArtist = await Future.wait(
        artistsToCheck.map((artist) async {
          try {
            final tracks = await _searchService.getArtistTopTracks(artist.id);
            if (tracks.isNotEmpty) return tracks.take(3).toList();
            // Only when the browse gave nothing: the id may be a name rather than
            // a channel, and a name is searchable.
            final byName = await _searchService.search(artist.title, 'track');
            return byName
                .where((t) =>
                    t.artist.toLowerCase().trim() ==
                    artist.title.toLowerCase().trim())
                .take(3)
                .toList();
          } catch (e) {
            print("WARN: Failed to fetch tracks for ${artist.title}: $e");
            return <Song>[];
          }
        }),
      );
      final relatedTracks = <Song>[for (final list in perArtist) ...list];
      print('   ${artistsToCheck.length} related artist(s) resolved in '
          '${DateTime.now().difference(started).inMilliseconds}ms');
      return relatedTracks;
    } catch (e) {
      print("ERROR: Related artists seed failed: $e");
      return [];
    }
  }

  Future<List<Song>> _getSeedFromUserAffinities(
    IntelligenceState taste,
    IntelligenceNotifier intelNotifier,
  ) async {
    try {
      print("Fetching tracks from user affinities...");
      
      var topArtists = intelNotifier.getWeightedTopics(
        taste.artistAffinities.keys.toList()
      );
      
      if (topArtists.length < 3) {
        final patterns = _analyzeListeningPatterns();
        topArtists = patterns.keys.toList();
        print("   Using listening patterns (${topArtists.length} artists)");
      }
      
      if (topArtists.isEmpty) return [];
      
      final selectedArtists = <String>[];
      final pickCount = min(3, topArtists.length);
      
      for (int i = 0; i < pickCount; i++) {
        final randomIndex = Random().nextInt(min(5, topArtists.length));
        if (!selectedArtists.contains(topArtists[randomIndex])) {
          selectedArtists.add(topArtists[randomIndex]);
        }
      }
      
      // Three artists, and each one needed a search THEN a browse — six round
      // trips in a row, plus 300 ms of sleep. Same reasoning as the related-
      // artists seed: the shared RateLimiter in CatalogApiClient (220 ms,
      // burst 5) is where pacing belongs, and it was already doing it. The two
      // calls per artist stay sequential because the second needs the first's
      // id; the three ARTISTS have nothing to say to each other.
      final started = DateTime.now();
      final perArtist = await Future.wait(
        selectedArtists.where((a) => !isJunkMusicTerm(a)).map((artistName) async {
          try {
            final artistResults =
                await _searchService.search(artistName, 'artist');
            // Seeding recommendations from the WRONG artist poisons the queue
            // quietly: the tracks look plausible, they are just not by anyone the
            // listener likes. Requiring an identity match (see
            // SearchService.artistNameMatches) means a failed resolve contributes
            // nothing instead of contributing noise.
            final artistMatch = SearchService.pickArtistMatch(
                artistResults, artistName, (s) => s.title);
            if (artistMatch == null) {
              // Said out loud: a name that never resolves silently removes a
              // fifth of the pool, and the queue just quietly gets worse.
              print("   no confident artist match for \"$artistName\"");
              return <Song>[];
            }
            final tracks =
                await _searchService.getArtistTopTracks(artistMatch.id);
            return tracks.take(4).toList();
          } catch (e) {
            print("WARN: Failed to fetch affinity tracks for $artistName: $e");
            return <Song>[];
          }
        }),
      );
      final affinityTracks = <Song>[for (final list in perArtist) ...list];
      print('   ${affinityTracks.length} track(s) from '
          '${selectedArtists.length} favourite artist(s) in '
          '${DateTime.now().difference(started).inMilliseconds}ms');
      return affinityTracks;
    } catch (e) {
      print("ERROR: User affinity seed failed: $e");
      return [];
    }
  }

  Future<List<Song>> _getSeedFromCollaborativeFiltering() async {
    try {
      final currentSong = currentState.currentSong!;
      final lastfm = ArtistMetadataService();

      final similarSongs = await lastfm.getSimilarTracks(
        currentSong.title,
        currentSong.artist,
        limit: 20,
      );

      if (similarSongs.isEmpty) {
        print("Collaborative filtering: 0 tracks (no Last.fm data)");
        return [];
      }

      final List<Song> results = [];
      for (final t in similarSongs.take(10)) {
        final title  = t.title;
        final artist = t.artist;
        if (title.isEmpty || artist.isEmpty) continue;

        try {
          final deezerResp = await HttpPool().getClient().get(
            Uri.parse(
              'https://api.deezer.com/search?q='
              '${Uri.encodeComponent("$title $artist")}&limit=3',
            ),
          ).timeout(const Duration(seconds: 4));

          if (deezerResp.statusCode == 200) {
            final data  = jsonDecode(deezerResp.body);
            final items = data['data'] as List? ?? [];
            if (items.isNotEmpty) {
              final d = items.first;
              results.add(Song(
                id:         'track_${d['id']}',
                title:      d['title'] as String? ?? title,
                artist:     d['artist']?['name'] as String? ?? artist,
                image:      d['album']?['cover_medium'] as String? ?? '',
                albumTitle: d['album']?['title'] as String? ?? '',
                albumId:    d['album']?['id']?.toString() ?? '',
                popularity: ((d['rank'] ?? 0 as num) / 10000).clamp(0, 100).toInt(),
              ));
            }
          }
          await Future.delayed(const Duration(milliseconds: 60));
        } catch (_) {}
      }

      print("Collaborative filtering: ${results.length} tracks via Last.fm getSimilar");
      return results;
    } catch (e) {
      print("ERROR: Collaborative filtering failed: $e");
      return [];
    }
  }

  Future<List<Song>> _getSeedFromContext() async {
    try {
      final hour = DateTime.now().hour;
      final taste = ref.read(intelligenceProvider);
      String contextQuery;
      
      // Exclude placeholder genres ("General" etc.) — otherwise the dominant
      // "General" affinity becomes the literal search query.
      final topGenres = taste.genreAffinities.entries
          .where((e) => !isJunkMusicTerm(e.key))
          .toList()
        ..sort((a, b) => b.value.compareTo(a.value));

      final userTopGenre = topGenres.isNotEmpty ? topGenres.first.key : null;
      final userSecondGenre = topGenres.length > 1 ? topGenres[1].key : null;
      
      if (hour >= 5 && hour < 12) {
        contextQuery = userTopGenre ?? 'pop';
        print("Morning Energy: $contextQuery");
      } else if (hour >= 12 && hour < 17) {
        contextQuery = userTopGenre ?? 'indie';
        print("Afternoon Focus: $contextQuery");
      } else if (hour >= 17 && hour < 22) {
        contextQuery = userTopGenre ?? 'r&b';
        print("Evening Chill: $contextQuery");
      } else {
        contextQuery = userTopGenre ?? 'electronic';
        print("Night Mood: $contextQuery");
      }
      
      if (currentState.contextType == 'genre' && currentState.contextTitle != null) {
        contextQuery = "${currentState.contextTitle!} top hits popular";
        print("Genre Override: $contextQuery");
      } else if (currentState.contextType == 'artist') {
        final currentArtist = currentState.currentSong?.artist ?? '';
        contextQuery = "$currentArtist similar artists essential";
        print("Artist Context: $contextQuery");
      } else if (userSecondGenre != null && Random().nextDouble() > 0.7) {
        contextQuery = "$userSecondGenre $userTopGenre fusion mix";
        print("Genre Fusion: $contextQuery");
      }
      
      final wildcardTracks = await _searchService.search(contextQuery, 'track');
      print("   Found ${wildcardTracks.length} context-aware tracks");
      
      return wildcardTracks.take(20).toList(); 
    } catch (e) {
      print("ERROR: Context wildcard seed failed: $e");
      return [];
    }
  }

  Future<void> refreshAutoplay() async {
    final currentSong = currentState.currentSong;
    if (currentSong == null) return;

    if (currentSong.id.startsWith('http')) {
      print("Live Stream active - cannot refresh autoplay");
      return;
    }

    // ref.READ, not watch: inside this imperative method, ref.watch registers
    // connectivityProvider as a dependency of playerProvider, so a WiFi<->mobile
    // transition would rebuild/RECREATE the whole PlayerNotifier (dispose the
    // ExoPlayer listeners + re-run _initPersistence) mid-playback. Every other
    // access site here uses ref.read.
    final connectivity = ref.read(connectivityProvider);
    if (connectivity.isOffline || !connectivity.shouldPreload) {
      print("Offline or data saver active - skipping autoplay refresh");
      return;
    }

    // Drive the queue-sheet spinner: the manual ↻ used to sit inert for the
    // whole (previously 10-30s) fetch with no feedback.
    ref.read(autoplayRefreshingProvider.notifier).state = true;
    // The busy flag needs a minimum lifetime to be seeable.
    //
    // With the radio cache warm this whole method finishes in ~20ms, so the flag
    // went true and false inside a single frame and the button never visibly
    // changed. The user concluded it was dead and pressed it four times in
    // fourteen seconds, which is worse than a slow button, because each press
    // re-ran the work.
    //
    // Held for at least [minBusy] in the finally below. This does NOT delay the
    // queue: the tracks are already in place: it only keeps the spinner on screen
    // long enough for a human to register that something happened.
    const minBusy = Duration(milliseconds: 550);
    final busySince = Stopwatch()..start();
    try {
      final searchService = ref.read(searchServiceProvider);
      final intel = ref.read(intelligenceProvider);
      final intelNotifier = ref.read(intelligenceProvider.notifier);

      final existingIds = {
        ...currentState.autoplayQueue.map((s) => s.id),
        ...currentState.contextQueue.map((s) => s.id),
        ...currentState.userQueue.map((s) => s.id),
        currentSong.id,
      };

      print("Refreshing Autoplay - Avoiding ${existingIds.length} existing tracks");

      // Seed from the current artist unless it's a placeholder. getSmartSeeds
      // filters junk seeds and falls back to the user's OWN affinities, so no
      // generic "Top Hits" injection is needed (that produced non-personal junk).
      final seeds = intelNotifier.getSmartSeeds(
        currentArtist: currentSong.artist,
        count: 6,
      );

      // PARALLEL seed resolution
      // The old loop ran the seeds SEQUENTIALLY — search(artist) →
      // getArtistTopTracks → optional search(track) — AND then did one MORE
      // network search PER candidate that lacked art. On the first manual
      // refresh (nothing warmed) that stacked into a 10-30s wait with no queue
      // change until the very end. Now every seed resolves concurrently and the
      // per-song art lookup is dropped (art is resolved lazily at display time
      // by AuvyImage), so the refresh returns in ~1-3s.
      const perSeedTimeout = Duration(seconds: 6);
      final perSeed = await Future.wait(seeds.map((seed) async {
        try {
          List<Song> results = await searchService
              .search(seed, 'artist')
              .timeout(perSeedTimeout, onTimeout: () => <Song>[])
              // Same identity rule as everywhere else — a seed that resolves
              // to the wrong artist falls through to the track search below,
              // which is a better answer than confident nonsense.
              .then((artistResults) {
                final m = SearchService.pickArtistMatch(
                    artistResults, seed, (x) => x.title);
                return m == null
                    ? <Song>[]
                    : searchService
                        .getArtistTopTracks(m.id)
                        .timeout(perSeedTimeout, onTimeout: () => <Song>[]);
              });
          if (results.isEmpty) {
            results = await searchService
                .search(seed, 'track')
                .timeout(perSeedTimeout, onTimeout: () => <Song>[]);
          }
          return results;
        } catch (e) {
          print("WARN: Error fetching from seed $seed: $e");
          return <Song>[];
        }
      }));

      // SELECTION: the current track's radio LEADS, taste tops up
      //
      // The old merge quietly selected against song similarity.
      //
      // Radio results were scored into one pool with a +15 bonus, then run
      // through a global one-track-per-artist cap and a final shuffle(). Three
      // things went wrong at once, and together they are why pressing ↻ returned
      // the user's general taste instead of tracks that go with THIS song:
      //
      //   1. +15 is a nudge, not a lead. getSongScore's range is wide enough that
      //      a high-affinity favourite outscored a genuinely related track, so
      //      the taste model won most of the 15 slots.
      //   2. Song radio is DENSE in closely-related artists, and often carries
      //      several tracks by the current artist. A one-per-artist cap deletes
      //      precisely that, while sparse-but-diverse taste picks survive it. The
      //      cap was removing the signal it was meant to protect.
      //   3. YouTube orders a radio feed by relevance. shuffle() threw that away.
      //
      // Radio now takes the first two thirds of the slots in YouTube's own order,
      // allowing up to 2 per artist so a closely-related artist can appear more
      // than once. The seed/affinity pool fills the remainder, which is what
      // keeps the result personal rather than a bare radio clone.
      const int kTarget = 15;
      const int kRadioSlots = 10;

      final seenScoreIds = <String>{};
      bool usable(Song song) =>
          !existingIds.contains(song.id) &&
          !intel.blacklistedIds.contains(song.id) &&
          !isJunkMusicTerm(song.artist) &&
          !isJunkMusicTerm(song.title);

      // PRIMARY: YouTube Music's native radio for the current track (the
      // YouTube's own collaborative filtering). Order is
      // preserved deliberately; it is relevance, not arbitrary.
      final radioSongs = await searchService.getSongRadio(currentSong.id);
      final radioPool = <Song>[];
      for (final song in radioSongs) {
        if (!usable(song) || !seenScoreIds.add(song.id)) continue;
        radioPool.add(song);
      }

      // SECONDARY: the seed/affinity pool, scored, for breadth.
      final scored = <({Song song, double score})>[];
      for (int i = 0; i < perSeed.length; i++) {
        final seed = seeds[i];
        for (final song in perSeed[i]) {
          if (!usable(song) || !seenScoreIds.add(song.id)) continue;
          scored.add((song: song, score: intelNotifier.getSongScore(song, currentContext: seed)));
        }
      }
      scored.sort((a, b) => b.score.compareTo(a.score));

      final List<Song> freshTracks = [];
      final artistTaken = <String, int>{};
      bool take(Song song, int perArtistCap) {
        final key = song.artist.toLowerCase();
        if ((artistTaken[key] ?? 0) >= perArtistCap) return false;
        artistTaken[key] = (artistTaken[key] ?? 0) + 1;
        freshTracks.add(song);
        existingIds.add(song.id);
        return true;
      }

      for (final song in radioPool) {
        if (freshTracks.length >= kRadioSlots) break;
        take(song, 2);
      }
      final int radioTaken = freshTracks.length;

      for (final item in scored) {
        if (freshTracks.length >= kTarget) break;
        take(item.song, 1);
      }

      // If radio came back empty or thin (offline, a non-11-char id, a brand new
      // release with no feed yet), the taste pool is allowed to fill the whole
      // target rather than leaving the queue short.
      if (freshTracks.length < kTarget) {
        for (final item in scored) {
          if (freshTracks.length >= kTarget) break;
          if (existingIds.contains(item.song.id)) continue;
          take(item.song, 2);
        }
      }

      // Cold-start only: seed a baseline so a brand-new user isn't stuck with an
      // empty queue. For an established user we keep the queue intelligence-only
      // (empty here just means the other seed sources will fill on the next tick)
      // rather than injecting non-personal "Trending Radio" tracks.
      if (freshTracks.isEmpty && intelNotifier.isInColdStart) {
        print("Cold-start autoplay: seeding baseline recommendations.");
        final generalFallback = await searchService.search("Trending Radio", 'track');
        freshTracks.addAll(generalFallback
            .where((s) => !isJunkMusicTerm(s.artist) && !isJunkMusicTerm(s.title))
            .take(5));
      }

      // Only the taste-derived tail is shuffled.
      //
      // This was `freshTracks.shuffle()` over everything, which discarded the
      // relevance order YouTube returns the radio feed in — the most-related
      // track was as likely to land at position 10 as position 1. Shuffling just
      // the tail keeps repeated ↻ presses feeling varied without scrambling the
      // part that carries the song similarity.
      if (freshTracks.length > radioTaken) {
        final tail = freshTracks.sublist(radioTaken)..shuffle();
        freshTracks.replaceRange(radioTaken, freshTracks.length, tail);
      }

      print("Autoplay refresh: $radioTaken from this track's radio, "
          "${freshTracks.length - radioTaken} from taste seeds");

      final newQueue = [
        currentSong,
        ...currentState.userQueue,
        ...currentState.contextQueue,
        ...freshTracks,
      ];

      currentState = currentState.copyWith(
        autoplayQueue: freshTracks,
        queue: newQueue,
        // Keep the unshuffled snapshot consistent so unshuffle doesn't drop the
        // refreshed recs.
        originalQueue: currentState.isShuffle
            ? [...currentState.originalQueue, ...freshTracks]
            : newQueue,
      );

      print("OK: Autoplay successfully populated with ${freshTracks.length} tracks");

    } catch (e) {
      print("ERROR: Autoplay refresh failed: $e");
    } finally {
      final left = minBusy - busySince.elapsed;
      if (left > Duration.zero) await Future.delayed(left);
      if (mounted) {
        ref.read(autoplayRefreshingProvider.notifier).state = false;
      }
    }
  }

  List<Song> _selectWithDiversity(
    List<Song> pool,
    Set<String> seenSongIds,
    Set<String> usedArtistIds,
    {required int count, bool maintainQuality = false}
  ) {
    final List<Song> selected = [];
    final Set<String> selectedArtists = Set.from(usedArtistIds);
    
    final highQuality = pool.take(count * 3).toList(); 
    final remaining = pool.skip(count * 3).toList();
    
    final phase1Target = (count * 0.7).ceil();
    for (final song in highQuality) {
      if (selected.length >= phase1Target) break;
      if (seenSongIds.contains(song.id)) continue;
      
      final artistKey = song.artist.toLowerCase();
      final artistCount = selected.where((s) => s.artist.toLowerCase() == artistKey).length;
      
      if (artistCount < 2 || selected.length >= phase1Target * 0.8) {
        selected.add(song);
        seenSongIds.add(song.id);
        selectedArtists.add(artistKey);
      }
    }
    
    for (final song in highQuality + remaining) {
      if (selected.length >= count) break;
      if (seenSongIds.contains(song.id)) continue;
      
      final artistKey = song.artist.toLowerCase();
      if (!selectedArtists.contains(artistKey)) {
        selected.add(song);
        seenSongIds.add(song.id);
        selectedArtists.add(artistKey);
      }
    }
    
    for (final song in pool) {
      if (selected.length >= count) break;
      if (seenSongIds.contains(song.id) || selected.contains(song)) continue;
      
      selected.add(song);
      seenSongIds.add(song.id);
    }
    
    print("Selection Stats:");
    print("   Selected: ${selected.length}");
    print("   Unique artists: ${selectedArtists.length}");
    print("   Quality tier: Top ${((highQuality.length / pool.length) * 100).toStringAsFixed(0)}%");
    
    return selected;
  }

  List<Song> _intelligentShuffle(List<Song> songs) {
    if (songs.length <= 2) {
      songs.shuffle();
      return songs;
    }
    
    final Map<String, List<Song>> artistGroups = {};
    for (final song in songs) {
      final key = song.artist.toLowerCase();
      artistGroups.putIfAbsent(key, () => []).add(song);
    }
    
    final List<Song> result = [];
    final List<String> artists = artistGroups.keys.toList()..shuffle();
    
    while (result.length < songs.length) {
      for (final artist in artists) {
        final group = artistGroups[artist];
        if (group != null && group.isNotEmpty) {
          result.add(group.removeAt(0));
          if (result.length >= songs.length) break;
        }
      }
    }
    
    return result;
  }

  List<({Song song, double score})> _scoreAndRankRecommendations(
    List<Song> candidates,
    IntelligenceState taste,
  ) {
    final List<({Song song, double score})> scored = [];
    final currentSong = currentState.currentSong;
    final currentArtist = currentSong?.artist.toLowerCase();
    final currentGenre = currentState.contextTitle ?? 'General';

    final artistInQueueCount = currentState.queue
        .where((s) => s.artist.toLowerCase() == currentArtist)
        .length;

    for (int i = 0; i < candidates.length; i++) {
      final song = candidates[i];
      double score = 0.0;
      final artistKey = song.artist.toLowerCase();
      
      final actualPop = song.popularity > 0
          ? song.popularity.toDouble()
          : 50.0 * pow(1.0 - (i / candidates.length), 2.0);
      score += actualPop * 0.40;

      // Settings → Intelligence → "Discovery". One number tilts the balance
      // between the two forces already in this function: how much LEARNED TASTE
      // pulls (genre + artist affinity) versus how much UNHEARD material is
      // rewarded (the novelty bonus below).
      //
      // Deliberately scales existing terms rather than adding a new one — a
      // separate "discovery score" would fight the weights instead of tuning
      // them, and the two would drift apart as either is adjusted.
      //   bias 0.0 → familiarWeight 1.0, noveltyWeight 0.5  (comfort)
      //   bias 0.5 → 0.7 / 1.25                             (default)
      //   bias 1.0 → 0.4 / 2.0                              (adventurous)
      final double discoveryBias = ListeningPolicy.discoveryBias;
      final double familiarWeight = 1.0 - discoveryBias * 0.6;
      final double noveltyWeight = 0.5 + discoveryBias * 1.5;

      final genreVibe = taste.sessionAffinities[currentGenre] ?? 0.0;
      final genreGlobalAffinity = taste.genreAffinities[currentGenre] ?? 0.0;
      score += ((genreVibe * 0.6) + (genreGlobalAffinity * 0.4)) *
          30.0 *
          familiarWeight;

      final artistAffinity = taste.artistAffinities[song.artist] ?? 0.0;
      final isComplementary = _isComplementaryArtist(song.artist, currentArtist ?? '');
      score += (artistAffinity + (isComplementary ? 10.0 : 0.0)) *
          0.15 *
          familiarWeight;
      
      if (currentArtist != null && artistKey == currentArtist) {
        if (artistInQueueCount == 0) {
          score -= 5.0;
        } else if (artistInQueueCount == 1) {
          score -= 20.0;
        } else {
          score -= 50.0;
        }
      }

      final songGenres = song.albumTitle.toLowerCase().split(' '); 
      if (songGenres.contains(currentGenre.toLowerCase())) {
         score += 10.0;
      }
      
      // Novelty side of the discovery balance: reward tracks you haven't heard,
      // penalise ones you've heard a lot. Scaled by noveltyWeight so the slider
      // moves both halves at once instead of only damping taste.
      final playCount = taste.trackAffinities[song.id] ?? 0.0;
      if (playCount == 0) {
        score += 15.0 * 0.05 * noveltyWeight;
      } else if (playCount < 3.0) {
        score += 8.0 * 0.05 * noveltyWeight;
      } else if (playCount > 15.0) {
        score -= 12.0 * 0.05 * noveltyWeight;
      }
      
      final hour = DateTime.now().hour;
      final timeContext = taste.timeOfDayAffinities[hour] ?? {};
      final timeRelevance = timeContext[song.artist] ?? 0.0;
      score += timeRelevance * 3.0;
      
      final recentHistory = currentState.history.take(20).map((s) => s.id).toSet();
      if (recentHistory.contains(song.id)) {
        score -= 30.0;
      }
      
      final seedTitleLower = currentSong?.title.toLowerCase() ?? '';
      final candidateTitleLower = song.title.toLowerCase();
      
      final isSeedRemix = seedTitleLower.contains('remix') || seedTitleLower.contains('vip');
      final isCandidateRemix = candidateTitleLower.contains('remix') || candidateTitleLower.contains('vip');
      
      final isSeedInstrumental = seedTitleLower.contains('instrumental') || seedTitleLower.contains('karaoke');
      final isCandidateInstrumental = candidateTitleLower.contains('instrumental') || candidateTitleLower.contains('karaoke');

      if (isSeedRemix && isCandidateRemix) {
        score += 30.0; 
      } else if (!isSeedRemix && isCandidateRemix) {
        score -= 50.0; 
      }

      if (isSeedInstrumental && isCandidateInstrumental) {
        score += 30.0; 
      } else if (!isSeedInstrumental && isCandidateInstrumental) {
        score -= 50.0; 
      }

      scored.add((song: song, score: score));
    }
    
    scored.sort((a, b) => b.score.compareTo(a.score));
    
    print("Top 3 Recommendations:");
    final minScore = scored.isNotEmpty ? scored.last.score : 0.0;
    final maxScore = scored.isNotEmpty ? scored.first.score : 1.0;
    final range = max(maxScore - minScore, 1.0); 
    
    for (int i = 0; i < min(3, scored.length); i++) {
      final normalizedScore = ((scored[i].score - minScore) / range) * 100;
      print("   ${i + 1}. ${scored[i].song.title} - Score: ${normalizedScore.toStringAsFixed(1)}/100 (Raw: ${scored[i].score.toStringAsFixed(1)})");
    }
    
    return scored;
  }

  bool _isComplementaryArtist(String artist1, String artist2) {
    final intel = ref.read(intelligenceProvider.notifier);
    final complementary = intel.getComplementaryArtists(artist2, limit: 10);
    return complementary.contains(artist1);
  }

  Map<String, int> _analyzeListeningPatterns() {
    final artistFrequency = <String, int>{};
    
    for (final song in currentState.history.take(50)) {
      final artist = song.artist.toLowerCase().trim();
      if (artist.isNotEmpty) {
        artistFrequency[artist] = (artistFrequency[artist] ?? 0) + 1;
      }
    }
    
    final sorted = artistFrequency.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));
    
    return Map.fromEntries(sorted.take(10));
  }

  // Seconds before a track ends at which we start warming the next one. Spotify
  // begins fetching the next track a few seconds out so the switch is seamless.
  static const int _preloadLeadSeconds = 12;

  /// How long a newly-changed "next track" must stay next before its stream is
  /// resolved and its opening bytes pulled. Long enough that ordinary skipping
  /// spends nothing, short enough to be invisible when you stop on a track.
  static const Duration _preloadSettleWindow = Duration(seconds: 3);

  /// Warm the next track shortly before the current one ends so the transition
  /// is near-instant: resolve (and cache) its stream URL, optionally pull it to
  /// disk, and preload its lyrics. Driven by the native position callback, so
  /// the `_isPreloading` / `_preloadedSongId` guards keep the ~2x/sec calls cheap.
  /// Replace every occurrence of [from] with [to] across all live queue
  /// segments — used by the gapless preload to swap a video row for its
  /// conformed AUDIO version BEFORE it becomes current (mirrors playSong's
  /// play-time conform swap), so native auto-advance plays audio, not the video.
  void _swapInQueues(Song from, Song to) {
    Song swap(Song s) => s.id == from.id ? to : s;
    currentState = currentState.copyWith(
      queue: currentState.queue.map(swap).toList(),
      userQueue: currentState.userQueue.map(swap).toList(),
      contextQueue: currentState.contextQueue.map(swap).toList(),
      autoplayQueue: currentState.autoplayQueue.map(swap).toList(),
      originalQueue: currentState.originalQueue.map(swap).toList(),
    );
  }

  /// A queue mutation (add / remove / reorder / play-next / re-queue-from-
  /// history) may have moved a DIFFERENT track into the "up next" slot
  /// (`queue[1]`). In gapless mode the native ExoPlayer still has the PREVIOUS
  /// next track pre-buffered as its upcoming media item, so at the track
  /// boundary it gaplessly rolls into that now-stale track for a moment before
  /// the mismatch fallback (`onNativeAutoAdvance`) reloads the correct one.
  /// That is the reported "it plays the supposed next song for ~500ms and THEN
  /// plays the one I queued" glitch.
  ///
  /// Fix: the instant the up-next changes, DROP the stale native upcoming
  /// (synchronously via `clearUpcoming`, before any async re-resolve) so a
  /// boundary can't roll into it, and reset the preload guard so the correct
  /// next track gets re-queued on the next position tick (or right now if we're
  /// already playing). Pass the [previousNextId] captured BEFORE the mutation;
  /// if the up-next is unchanged this is a no-op (the warmed upcoming is still
  /// valid, so we don't needlessly re-warm).
  void resyncUpcomingIfChanged(String? previousNextId) {
    if (!currentState.gaplessPlayback) return;
    final newNextId =
        currentState.queue.length > 1 ? currentState.queue[1].id : null;
    if (newNextId == previousNextId) return; // up-next unchanged → still valid
    // Stale upcoming → clear it NOW so the gapless boundary can't play it.
    try {
      NativeAudioEngine.clearUpcoming();
    } catch (_) {}
    _preloadedSongId = null;
    if (newNextId != null && currentState.isPlaying) _preloadNextTrack();
  }

  Future<void> _preloadNextTrack() async {
    if (!_shouldPreloadNext()) return;
    if (_isPreloading ||
        currentState.queue.isEmpty ||
        currentState.repeatMode == RepeatMode.one) return;

    final duration = currentState.duration;
    final position = currentState.position;
    if (duration.inMilliseconds == 0) return;

    // Skip tracks too short to be worth pre-warming.
    if (duration.inSeconds <= _preloadLeadSeconds + 3) return;
    // Fire once the current track has a few seconds of playback (network is
    // still up) OR inside the near-end lead window — whichever comes FIRST — so
    // the next track's opening bytes get pre-warmed into the play-cache BEFORE a
    // screen-off Doze blackout, not at the last second when the radio may
    // already be cut. The _preloadedSongId guard keeps this to one warm-up.
    final remaining = duration - position;
    // A track already on disk does NOT wait out the eight seconds
    //
    // THE GAP THIS CLOSES, seen live on device: a skip is instant only when
    // something is armed, and after a skip the position is back at 0, so for
    // the next eight seconds NOTHING is armed and every further skip fell back
    // to a full re-prepare:
    //
    //     advanceToUpcoming declined: armed='' wanted='lYBUbBu4W08'
    //     advanceToUpcoming declined: armed='' wanted='6eyCDj1s4NI'
    //
    // Which is exactly backwards: skipping repeatedly is when instant matters
    // most, and it was the one time it could not happen.
    //
    // Only for a cached next track, AND that limit is the whole safety of
    // IT. The eight seconds exist to avoid paying a stream resolve plus a ~1MB
    // pre-pull for a track the listener skips past — real money on mobile data.
    // A file already on disk costs neither: setUpcoming just hands ExoPlayer a
    // path. The settle window below already reasons this way for the same
    // reason; this applies it to the wait as well, so the two agree.
    final nextId = currentState.queue.length > 1 ? currentState.queue[1].id : '';
    final nextIsOnDisk = nextId.isNotEmpty && _cacheManager.isCached(nextId);
    final earlyEnough = position.inSeconds >= 8 || nextIsOnDisk;
    final inLeadWindow =
        remaining.inSeconds <= _preloadLeadSeconds && remaining.inSeconds > 0;
    if (!earlyEnough && !inLeadWindow) return;

    // Next index, wrapping to 0 only when repeat-all is on.
    int nextIndex = 1;
    if (nextIndex >= currentState.queue.length) {
      if (currentState.repeatMode == RepeatMode.all) {
        nextIndex = 0;
      } else {
        return;
      }
    }

    final song = currentState.queue[nextIndex];
    if (_preloadedSongId == song.id) return;

    // LET A CHANGED "NEXT" SETTLE BEFORE SPENDING DATA ON IT.
    //
    // Warming costs a stream resolve plus a ~1MB pre-pull. While the user is
    // skipping, "next" changes every few seconds and every one of those is paid
    // for a track that is never heard — measured on device as three resolves and
    // three pre-pulls in nine seconds, two of them wasted.
    //
    // A track that has just become next must therefore still be next a moment
    // later. The position tick re-enters here about twice a second, so the wait
    // costs nothing and needs no timer.
    //
    // EXCEPT NEAR THE END, where there is no time to wait — inside the lead
    // window the arm happens immediately, because a late warm is worse than a
    // slightly speculative one. Same reasoning for a track already on disk: it
    // costs no network, so there is nothing to save by delaying it.
    if (!inLeadWindow && !_cacheManager.isCached(song.id)) {
      final now = DateTime.now();
      if (_nextSettleId != song.id) {
        _nextSettleId = song.id;
        _nextSettleAt = now;
        return;
      }
      if (now.difference(_nextSettleAt ?? now) < _preloadSettleWindow) return;
    }

    // Direct HTTP streams (radio / podcast) are already playable URLs — nothing
    // to resolve. Mark handled so we don't re-check every tick.
    if (song.id.startsWith('http') && song.albumTitle != 'Podcast') {
      _preloadedSongId = song.id;
      return;
    }

    _isPreloading = true;
    // Claim this song up front so position-callback spam doesn't launch a second
    // warm-up while the async work below is still in flight.
    _preloadedSongId = song.id;

    try {
      final connectivity = ref.read(connectivityProvider);

      // 1) PRE-WARM the next track: resolve its URL and pull its first ~1 MB into
      //    the native media3 play-cache, so when the queue advances the resolving
      //    source serves the opening bytes from cache instantly (near-gapless) —
      //    WITHOUT speculatively downloading the whole track (which wastes data
      //    when the queue changes). The rest streams LIVE via the resolving
      //    source. Resolving here also warms the Dart resolver cache, so a later
      //    native re-resolve (on expiry) is fast. Radio/podcast are not pre-warmed.
      if (!song.id.startsWith('http')) {
        // GAPLESS: the track that will actually play next. In gapless mode a
        // music VIDEO must be conformed to its AUDIO equivalent FIRST — the
        // native auto-advance bypasses the play-time conform, so enqueuing a raw
        // video would play the video. Swap it into the queue NOW so the queue
        // stays consistent and the native transition's videoId matches queue[1].
        Song upcoming = song;
        if (currentState.gaplessPlayback &&
            !currentState.processVideosEnabled &&
            !_cacheManager.isCached(upcoming.id)) {
          // MUST mirror playSong's play-time conform gate EXACTLY — the gapless
          // auto-advance bypasses that gate, so anything it would have conformed
          // has to be conformed here or the VIDEO plays. That means: a confirmed
          // music video, OR an UNTAGGED video inside an album/playlist context
          // (YouTube leaves musicVideoType empty on many deluxe/album rows — e.g.
          // "Is There Someone Else?"), plus the cheap ytimg-thumbnail signal.
          final looksVideo = upcoming.isMusicVideo ||
              upcoming.image.contains('ytimg.com/vi/') ||
              (upcoming.musicVideoType.isEmpty &&
                  (currentState.contextType == 'album' ||
                      currentState.contextType == 'playlist'));
          if (looksVideo) {
            final audio = await _searchService
                .conformToAudioCached(upcoming, strict: !upcoming.isMusicVideo)
                .then((a) => a == null
                    ? null
                    // Audio identity from the twin, EDITION identity from the
                    // queued row. See mergeConformedAudio.
                    : SearchService.mergeConformedAudio(upcoming, a));
            if (audio != null && audio.id != upcoming.id) {
              _swapInQueues(upcoming, audio);
              upcoming = audio;
              _preloadedSongId = upcoming.id;
            }
          }
        }

        // The next track is already ON DISK
        //
        // This branch did NOT exist, AND it was the biggest hole in gapless.
        // Arming the native upcoming lived entirely inside the "not cached" path
        // below, because that is where a resolved URL happened to be available.
        // So a downloaded album — where the bytes are already local and a
        // seamless join is the easy case — armed nothing, fell back to the Dart
        // reload on track end, and had an audible seam between every track.
        final cachedNextPath = _cacheManager.getCachedPath(upcoming.id);
        if (cachedNextPath != null) {
          if (currentState.gaplessPlayback) {
            // Re-check it is STILL up-next: this runs after awaits above, and the
            // user may have queued or reordered in the meantime. Same guard the
            // streaming path uses.
            final stillNext = currentState.queue.length > nextIndex &&
                currentState.queue[nextIndex].id == upcoming.id;
            if (stillNext) {
              await NativeAudioEngine.setUpcoming(
                upcoming.id,
                '', // no URL needed — it plays from the file
                localPath: cachedNextPath,
              );
            }
          }
        } else if (!_cacheManager.isCached(upcoming.id)) {
          // ── ASK EXACTLY WHAT THE MAIN RESOLVER ASKS ────────────────────
          //
          // This used to pass `shouldUseLowQualityAudio || audioQuality !=
          // High` and NO bitrate ceiling, with a comment saying it matched
          // playSong. It stopped matching when the main resolver became
          // measurement-driven, and the default AudioQuality is `auto`, so
          // `!= High` was true for almost everyone: the preload warmed a low
          // rung while the main path picked whatever measured throughput
          // allowed.
          //
          // That is a real bug, not just wasted work, because of what happens
          // next. An instant skip adopts the WARMED format without resolving
          // ("already buffered, no resolve"), so native ends up playing a
          // format the main resolver would never have chosen. The first
          // mid-track re-resolve then asks its own way, gets something else,
          // and the pin correctly refuses it — three times, then a give-up and
          // a clean restart of a track that was playing fine. Caught on device
          // 2026-09-02: preload took clen 1600139 at 131kbps, the re-resolve
          // returned clen 1741731 at 155kbps.
          //
          // Same flag and the same frozen ceiling as a mid-track re-resolve, so
          // the format a skip inherits is one the resolver can reproduce.
          final warmLowQuality = connectivity.shouldUseLowQualityAudio;
          final stream = await _audioService
              .getStreamWithFallback(
                upcoming.id,
                upcoming.title,
                upcoming.artist,
                lowQuality: warmLowQuality,
                maxBitrate: bitrateDecision.ceilingBps,
              )
              .timeout(const Duration(seconds: 8));
          // Record it under the SAME pin the resolver reads, so if this track
          // is skipped into, a mid-track re-resolve reproduces this choice
          // instead of guessing from whatever the network looks like by then.
          _lowQualityPin[upcoming.id] = warmLowQuality;
          final url = stream?['url'];
          // The queue may have changed WHILE we were resolving (the user
          // queued/removed/reordered a track). Only enqueue this as the native
          // upcoming if it's STILL the up-next — otherwise we'd re-arm a track
          // that is no longer next (the stale-upcoming glitch, from the other
          // side). resyncUpcomingIfChanged clears it on edit; this guard stops
          // an in-flight resolve from re-adding it.
          final stillNext = currentState.queue.length > nextIndex &&
              currentState.queue[nextIndex].id == upcoming.id;
          if (url != null && url.isNotEmpty && stillNext) {
            if (currentState.gaplessPlayback) {
              // Queue as a 2nd ExoPlayer item → ExoPlayer pre-buffers it and
              // transitions with ZERO gap (true gapless).
              await NativeAudioEngine.setUpcoming(
                upcoming.id, url,
                userAgent: stream?['user_agent'],
                contentLength: int.tryParse(stream?['contentLength'] ?? '0'),
              );
            } else {
              // Gapless off → the old near-gapless 1MB pre-warm + Dart advance.
              await NativeAudioEngine.prewarmNext(
                upcoming.id, url,
                userAgent: stream?['user_agent'],
                contentLength: int.tryParse(stream?['contentLength'] ?? '0'),
              );
            }
          }
        }
      }

      // 2) Lyrics, ready the instant the next track appears. Best-effort too.
      unawaited(Future(() async {
        try {
          await _lyricsService
              .getLyrics(song.title, song.artist, songId: song.id)
              .timeout(const Duration(seconds: 8));
        } catch (_) {}
      }));

      // 3) THE PLAYER-PAGE COVER.
      //
      // THE ART IS ALREADY ON DISK AND STILL DOWNLOADS AGAIN. Every surface
      // asks the CDN for roughly the size it paints, so a list tile holds
      // `=s192`/`mqdefault` while the player cover requests the 720 variant —
      // different urls, different cache entries. Opening the player for a track
      // scrolled past twenty times was therefore a COLD fetch, which is the
      // "cover art loads slowly on the player page, as if something is
      // inhibiting it" report. Nothing was inhibiting it; that exact url had
      // never been fetched.
      //
      // Warmed here because this is where the NEXT track is already being
      // prepared, so by the time it starts its cover is on disk and the player
      // paints on the first frame. One request, for a url the UI is definitely
      // about to ask for, and it respects Data Saver, because
      // shouldLoadHighResImages is what the widget itself will use.
      unawaited(Future(() async {
        try {
          final allowHighRes =
              ref.read(connectivityProvider).shouldLoadHighResImages;
          final url =
              AuvyImage.playerArtUrl(song.image, allowHighRes: allowHighRes);
          if (url.isNotEmpty) {
            await CustomImageCacheManager().preloadImage(url);
          }
        } catch (_) {}
      }));

      print('OK: Preloaded next track (stream warmed): ${song.title}');
    } catch (e) {
      // Stream warm failed — let the next tick retry.
      _preloadedSongId = null;
      print('WARN: Preload error: $e');
    } finally {
      _isPreloading = false;
    }
  }

  /// Whether the next track may be warmed right now.
  ///
  /// Said once per state change, NOT twice a second
  ///
  /// Both branches printed unconditionally, and the position tick calls
  /// `_preloadNextTrack` about twice a second, so a genuinely offline stretch
  /// buried the transcript. Counted in the 2026-08-31 export: **109 identical
  /// "Offline - skipping preload" lines**, all inside one 55-second offline
  /// window, making it the single most frequent message in the whole log.
  ///
  /// Not preloading while offline is CORRECT, so this is the same fault as
  /// "Content: Clean" or a LARGE REQUEST warning on a 3MB track: a line that
  /// only ever states the obvious, often enough to hide the lines that matter.
  ///
  /// The reason is remembered instead, so a transition is reported once and the
  /// steady state is silent. Recovery says so too — without that, the transcript
  /// showed playback going quiet and never showed it coming back.
  bool _shouldPreloadNext() {
    final connectivity = ref.read(connectivityProvider);

    final String? blocked = connectivity.isOffline
        ? 'offline'
        : (!connectivity.shouldPreload ? 'data saver' : null);

    if (blocked != _preloadBlockedReason) {
      _preloadBlockedReason = blocked;
      print(blocked == null
          ? 'preload resumed — connectivity allows warming the next track again'
          : 'preload paused — $blocked');
    }
    return blocked == null;
  }

  void _preloadLyrics(Song song) {
    Future.microtask(() async {
      try {
        final localLyrics = await _cacheManager.getLyrics(song.id);
        if (localLyrics != null) {
          print("Using disk-cached lyrics for: ${song.title}");
          return; 
        }
        
        print("Fetching lyrics from web: ${song.title}");
        await _lyricsService.getLyrics(
          song.title, 
          song.artist,
          album: song.albumTitle.isNotEmpty && song.albumTitle != 'null' ? song.albumTitle : null,
          songId: song.id,
        );
        print("OK: Lyrics preloaded successfully");
      } catch (e) {
        print("WARN: Lyrics preload failed: $e");
      }
    });
  }

  static bool _isHealerLoopActive = false;
  // Consecutive heals of the same song with no playback progress between them
  // (see handleStreamLeaseExpiration). Statics — extensions can't hold state.
  static String? _healSongId;
  static int _healCount = 0;
  static Duration _healLastPosition = Duration.zero;
  // Consecutive heal failures for the same song that were NETWORK faults (Doze /
  // Wi-Fi power-save), not dead tracks. Bounds the hold-and-wait so a genuinely
  // unresolvable track still advances after a few wake-attempts instead of
  // holding forever.
  static String? _healNetHoldSongId;
  static int _healNetHoldCount = 0;

  /// Consecutive local-cache heals of ONE song inside [_kLocalHealWindow].
  ///
  /// A counter that wipes itself cannot give up
  ///
  /// The local-copy branch clears [_healCount], which is right when the swap
  /// works and fatal when it does not: a truncated or corrupt file heals, fails
  /// immediately, heals again, and the very counter that would stop it is reset
  /// on every pass. The 2026-08-31 transcript caught six of them in 184ms, each
  /// one logging a fresh "Recovering natively…" — self-terminating that time, and
  /// unbounded by anything in the code.
  ///
  /// Counted separately so the give-up survives the reset. Same shape as the
  /// pinned-format refusal count in player_system.dart.
  static String? _localHealSongId;
  static int _localHealCount = 0;
  static int _localHealAtMs = 0;
  static const Duration _kLocalHealWindow = Duration(seconds: 10);
  static const int _kMaxLocalHeals = 2;

  /// Hand playback to [song]'s complete local cache copy, resuming at [from].
  ///
  /// Returns true when the file took over, false when there is no trustworthy
  /// copy and the caller should carry on to the network heal.
  ///
  /// The swap heals instantly, needs no network, and can never 403 again, so it
  /// is the best available outcome whenever a copy exists. The guard is the
  /// interesting part: a file that is present but unplayable would otherwise heal,
  /// fail, and heal again forever, because the success path resets [_healCount].
  /// After [_kMaxLocalHeals] attempts inside [_kLocalHealWindow] this stops
  /// trusting the copy and lets the resolve path, which has its own escalation
  /// and its own give-up — take the track instead.
  Future<bool> _healFromLocalCopy(
      Song song, Duration from, bool? intendedPlaying) async {
    // A remote-url pseudo-song (a radio stream) has no cache entry by design.
    if (song.id.startsWith('http')) return false;
    final localPath = _cacheManager.getCachedPath(song.id);
    if (localPath == null) return false;

    final nowMs = DateTime.now().millisecondsSinceEpoch;
    if (_localHealSongId != song.id ||
        nowMs - _localHealAtMs > _kLocalHealWindow.inMilliseconds) {
      _localHealSongId = song.id;
      _localHealCount = 0;
    }
    _localHealAtMs = nowMs;
    if (_localHealCount >= _kMaxLocalHeals) {
      print('WARN: the local copy of "${song.title}" failed $_localHealCount '
          'time(s) inside ${_kLocalHealWindow.inSeconds}s — distrusting it and '
          'resolving a stream instead');
      return false;
    }
    _localHealCount++;

    // Same correction the network path applies: between a heal's playTrack
    // (prepare → position 0) and its seek-back the engine reports 0, and an error
    // caught in that window must not be read as "the track is at 0:00" — that is
    // the "song restarted itself" glitch.
    var at = from;
    if (_healSongId == song.id &&
        at == Duration.zero &&
        _healLastPosition > Duration.zero) {
      at = _healLastPosition;
    }

    print('Healing from the local cache copy: ${song.title} '
        '($_localHealCount/$_kMaxLocalHeals, resuming at ${at.inSeconds}s)');
    await NativeAudioEngine.playTrack(
      song.id, localPath,
      localPath: localPath,
      autoPlay: intendedPlaying ?? currentState.isPlaying,
    );
    _nativeLoadedSongId = song.id;
    await NativeAudioEngine.seek(at);
    _healSongId = null;
    _healCount = 0;
    _healNetHoldSongId = null;
    _healNetHoldCount = 0;
    return true;
  }

  /// Native self-healing: Asks ExoPlayer to reload the URI natively.
  /// [intendedPlaying] is the native engine's playWhenReady at the moment of
  /// the error — the user's true play/pause intent. It MUST be preferred over
  /// currentState.isPlaying: a dying stream underruns (isPlaying → false)
  /// 10-30s before the error surfaces, so isPlaying always reads false here
  /// and the healed track reloaded PAUSED — playback "just stopped" mid-track.
  Future<void> handleStreamLeaseExpiration(
      {bool? intendedPlaying, Duration? resumeFrom}) async {
    final currentSong = currentState.currentSong;
    if (currentSong == null || _isHealerLoopActive) return;

    _isHealerLoopActive = true;
    print('[Auvy Native Engine] Stream link lease expired or dropped. Recovering natively...');

    try {
      // A complete local copy outranks every branch below
      //
      // THIS USED TO SIT AFTER THE OFFLINE CHECK, which made the worst case the
      // exact case it exists for. The 10s auto-cache downloads the playing track
      // in parallel with the stream, so when the network drops mid-track the whole
      // file is often already on disk, and the offline branch below returns
      // first, holding for a reconnect that the audio does not need.
      //
      // Measured on 2026-08-31: "Starboy" stalled at 21:15:50 and played again at
      // 21:16:02 — three seconds of stall grace plus the twelve-second recovery
      // floor, and then healed from the local copy in 37ms. Fifteen seconds of
      // silence for a track sitting complete on the device.
      //
      // getCachedPath returns non-null ONLY for a complete, unexpired file: a
      // partial download is never promoted into the index. So there is nothing to
      // wait for and no reason to consult connectivity at all.
      if (await _healFromLocalCopy(
          currentSong, resumeFrom ?? currentState.position, intendedPlaying)) {
        return;
      }

      // With no network, healing cannot work, so do NOT blame the track
      //
      // THE BUG THIS FIXES. Cutting the network mid-track produced
      // ERROR_CODE_IO_NETWORK_CONNECTION_FAILED (confirmed on device), which
      // lands here. Every heal below re-RESOLVES the stream, which needs the
      // network, so all three attempts failed, _healCount passed 3, and the
      // first pass fell through to _handlePersistentFailure: a FIVE-MINUTE block
      // on a perfectly good track plus playNext(). The outage ate the queue and
      // poisoned tracks for being unlucky, and _pendingNetworkRetry was only
      // armed on the SECOND cross-track failure, so reconnecting had nothing to
      // fire, which is why playback never resumed by itself.
      //
      // Being offline is not a stream fault and carries no information about the
      // track. Hold position, arm the retry, and let the connectivity listener
      // fire it the instant the network is back. The heal counters are left
      // untouched on purpose: this attempt never happened as far as they are
      // concerned, so a genuinely broken stream still gets its three tries once
      // there IS a network to try on.
      if (!ref.read(connectivityProvider).hasInternet) {
        final holdFrom = resumeFrom ?? currentState.position;
        final wantPlaying = intendedPlaying ?? currentState.isPlaying;
        print('heal deferred — no network. Holding '
            '"${currentSong.title}" at ${holdFrom.inSeconds}s for reconnect');
        await NativeAudioEngine.pause();
        currentState = currentState.copyWith(isLoading: true);
        currentPositionProvider.value = holdFrom;
        void healOnReconnect() {
          if (!mounted) return;
          if (currentState.currentSong?.id != currentSong.id) return;
          // Cached URLs are bound to the network path that went away; the
          // connectivity listener drops them, and this forces the point.
          _audioService.invalidateAllStreams();
          handleStreamLeaseExpiration(
            intendedPlaying: wantPlaying,
            resumeFrom: holdFrom,
          );
        }
        _pendingNetworkRetry = healOnReconnect;
        // A slow floor under the connectivity event, for the case it never
        // arrives: connectivity_plus reports the LINK, so a captive portal or a
        // half-open cell connection can look "connected" the whole time.
        _recoveryTimer?.cancel();
        _recoveryTimer = Timer(const Duration(seconds: 20), () {
          if (_pendingNetworkRetry != healOnReconnect) return;
          _pendingNetworkRetry = null;
          healOnReconnect();
        });
        return;
      }

      // [resumeFrom] is the LIVE position captured by the caller at the instant
      // of the fault (e.g. a premature STATE_ENDED where the engine may already
      // have snapped currentState.position to the duration). Prefer it so the
      // heal resumes from where audio actually stopped, not the fake end.
      Duration interruptionPoint = resumeFrom ?? currentState.position;
      // Between a heal's playTrack (prepare → position 0) and its seek-back,
      // the engine reports position 0. An error caught in that window must not
      // read as "the track is at 0:00" — that both reset the no-progress
      // counter below (heal loop never converged) and made this heal seek back
      // to 0:00 (the "song restarted itself" glitch). Reuse the last real spot.
      if (_healSongId == currentSong.id &&
          interruptionPoint == Duration.zero &&
          _healLastPosition > Duration.zero) {
        interruptionPoint = _healLastPosition;
      }

      // No-progress heal counter
      // A fresh URL can pass resolution (and its byte-0 probe) yet still 403
      // the moment ExoPlayer reads from the playback offset (CDN rate-gating /
      // IP-bound URL after a network switch). Without this cap the heal looped
      // FOREVER — an error every ~7s, the track sitting "paused" and resume
      // doing nothing (observed live on-device). Progress since the last heal
      // resets the counter; three heals with no progress = unrecoverable →
      // temp-block the track and move on.
      if (_healSongId != currentSong.id ||
          (interruptionPoint - _healLastPosition).abs() > const Duration(seconds: 3)) {
        _healSongId = currentSong.id;
        _healCount = 0;
      }
      _healLastPosition = interruptionPoint;
      _healCount++;

      if (_healCount > 3) {
        print('STOP: Heal #$_healCount with zero progress — stream is unrecoverable');
        _healSongId = null;
        _healCount = 0;
        // Cross-track GATE detection: if heal keeps failing on track AFTER track
        // (fresh URLs all 403), it's a googlevideo CDN/IP gate — Samsung dropping
        // +reconnecting Wi-Fi under Doze poisons the whole session, not one
        // track. Skipping just eats the queue (the "it skipped through 4 songs"
        // bug). After the first give-up, HOLD the current track and back off,
        // re-resolving fresh URLs on a slow cadence / on connectivity restore,
        // until the gate clears (usually when the device wakes).
        _gateFailStreak++;
        // Upper bound: if holding never converges (~5 cycles ≈ genuinely dead
        // tracks, not a transient gate), fall through to skip so the queue isn't
        // stuck forever on an unplayable track.
        if (_gateFailStreak >= 2 &&
            _gateFailStreak <= 6 &&
            mounted &&
            currentState.currentSong?.id == currentSong.id) {
          print('STOP: Repeated cross-track heal failures — CDN/IP gate storm; '
              'holding "${currentSong.title}" instead of skipping the queue');
          await NativeAudioEngine.pause();
          currentState = currentState.copyWith(isLoading: true);
          currentPositionProvider.value = interruptionPoint;
          final holdFrom = interruptionPoint;
          void reheal() {
            if (mounted && currentState.currentSong?.id == currentSong.id) {
              // Force genuinely fresh URLs — the gate poisons cached ones.
              _audioService.invalidateAllStreams();
              handleStreamLeaseExpiration(
                intendedPlaying: intendedPlaying ?? true,
                resumeFrom: holdFrom,
              );
            }
          }
          _pendingNetworkRetry = reheal;
          _recoveryTimer?.cancel();
          _recoveryTimer = Timer(const Duration(seconds: 15), reheal);
          return;
        }
        await _handlePersistentFailure(currentSong); // 5-min block + playNext
        return;
      }

      // Preserve the real play/pause INTENT across the heal. A stream can 403
      // and need re-resolving WHILE the track is paused — most importantly the
      // track restored on app launch, which buffers paused and often trips a
      // 403 (playWhenReady=false → stays paused, no "scary" autoplay on open).
      // The native playWhenReady is authoritative; currentState.isPlaying is
      // only a fallback for older native builds that don't send it — it reads
      // false after any buffer underrun even when the user never paused.
      final bool wasPlaying = intendedPlaying ?? currentState.isPlaying;

      // The local copy was already tried at the top of this method, before the
      // offline check. See the note there for why it has to come first.

      // Repeated heals of the same stall: give the CDN a breather. Healing
      // instantly on every error hammered a rate-gated egress in a tight loop,
      // which keeps the gate CLOSED — exactly the 403 storm being healed.
      if (_healCount >= 2) {
        await Future.delayed(Duration(seconds: 2 * (_healCount - 1)));
        if (!mounted || currentState.currentSong?.id != currentSong.id) return;
      }

      // Heal at the SESSION's quality (this used to be omitted, so data-saver
      // sessions healed into the wrong cache variant). From the second
      // no-progress heal onward, FLIP the tier: a different quality resolves a
      // different audio format — a different googlevideo URL family — which
      // routinely dodges per-format/range gating that keeps 403ing one itag.
      final bool sessionLow =
          ref.read(connectivityProvider).shouldUseLowQualityAudio ||
              currentState.audioQuality == AudioQuality.low;
      final bool healLow = _healCount >= 2 ? !sessionLow : sessionLow;
      if (_healCount >= 2) {
        print('Heal #$_healCount: switching audio format tier (low=$healLow) to dodge gating');
      }

      // Two attempts before giving up: a single flaky resolve used to skip the
      // track instantly — a "song skipped out of nowhere" from the user's view.
      Map<String, dynamic>? stream;
      for (int attempt = 1; attempt <= 2; attempt++) {
        // Drop the stale cached URL and resolve a FRESH one.
        _audioService.markVideoAsFailed(currentSong.id);
        stream = await _audioService.getStreamWithFallback(
          currentSong.id, currentSong.title, currentSong.artist,
          lowQuality: healLow,
        );
        final url = stream?['url'];
        if (url != null && url.toString().isNotEmpty) break;
        stream = null;
        if (attempt == 1) {
          print('WARN: Heal attempt 1 found no stream — retrying in 2s…');
          await Future.delayed(const Duration(seconds: 2));
          // The user may have moved on while we waited.
          if (!mounted || currentState.currentSong?.id != currentSong.id) return;
        }
      }
      final freshUrl = stream?['url'];

      // The resolve took real network time — the user may have skipped away,
      // or the queue may have advanced meanwhile. Loading the OLD song's fresh
      // URL now would stomp the track that's actually current (playback
      // "randomly jumped back" / the next track never played).
      if (!mounted || currentState.currentSong?.id != currentSong.id) return;

      if (freshUrl != null && freshUrl.toString().isNotEmpty) {
        // Hand the fresh URL (+ matching UA + length) to the native engine,
        // resuming only if it was playing before the drop.
        await NativeAudioEngine.playTrack(
          currentSong.id, freshUrl,
          userAgent: stream?['user_agent'],
          contentLength: int.tryParse(stream?['contentLength'] ?? '0'),
          autoPlay: wasPlaying,
        );
        _nativeLoadedSongId = currentSong.id;

        // Gaplessly seek back to where it dropped out.
        await NativeAudioEngine.seek(interruptionPoint);

        _healNetHoldSongId = null;
        _healNetHoldCount = 0;
        print('Playback successfully restored gaplessly. Exiting self-heal loop.');
      } else {
        throw Exception("No fresh stream available during heal (2 attempts).");
      }

    } catch (recoveryException) {
      print('ERROR: Background Stream Self-Healing failed to rescue active track: $recoveryException');
      // Distinguish a NETWORK OUTAGE (Doze / Wi-Fi power-save — the re-resolve
      // itself couldn't reach the network) from a genuinely dead track. On an
      // outage, blindly advancing is exactly the "it skipped to the 2nd/3rd
      // track on its own with the screen off" bug — every one of those tracks
      // needs the same dead network to resolve, so they all fail in turn. Under
      // Doze the OS still reports isConnected=true (only DNS is dead), so the
      // signal is the FAILURE itself: hold this track paused and re-heal from
      // the drop point the instant the radio wakes (or on connectivity restore).
      // Bounded so a truly unresolvable track still advances after a few tries.
      final err = recoveryException.toString().toLowerCase();
      final looksNetwork = !ref.read(connectivityProvider).hasInternet ||
          err.contains('socket') || err.contains('host') ||
          err.contains('no address') || err.contains('timeout') ||
          err.contains('connection') || err.contains('no fresh stream') ||
          err.contains('no playable stream') || err.contains('clientexception');
      if (looksNetwork && mounted && currentState.currentSong?.id == currentSong.id) {
        if (_healNetHoldSongId != currentSong.id) {
          _healNetHoldSongId = currentSong.id;
          _healNetHoldCount = 0;
        }
        _healNetHoldCount++;
        if (_healNetHoldCount <= 5) {
          // Drop point captured before the failed resolve (survives the resets).
          final holdFrom = _healLastPosition > Duration.zero
              ? _healLastPosition
              : (resumeFrom ?? currentState.position);
          print('Heal hit a network fault — holding "${currentSong.title}" '
              '(hold $_healNetHoldCount/5), waiting for connectivity to return');
          _healSongId = null;
          _healCount = 0;
          await NativeAudioEngine.pause();
          currentState = currentState.copyWith(isLoading: true);
          // Keep the slider at the drop point, never frozen at the track's end.
          currentPositionProvider.value = holdFrom;
          void reheal() {
            if (mounted && currentState.currentSong?.id == currentSong.id) {
              handleStreamLeaseExpiration(
                intendedPlaying: intendedPlaying ?? true,
                resumeFrom: holdFrom,
              );
            }
          }
          // Fires instantly on a real connectivity-restore transition; the timer
          // is the fallback for Doze (isConnected never actually toggled, but a
          // wake lets the Dart timer finally run — exactly when the radio is up).
          _pendingNetworkRetry = reheal;
          _recoveryTimer?.cancel();
          _recoveryTimer = Timer(const Duration(seconds: 20), reheal);
          return;
        }
        print('STOP: Heal network-hold exhausted for "${currentSong.title}" — advancing');
        _healNetHoldSongId = null;
        _healNetHoldCount = 0;
      }
      playNext();
    } finally {
      _isHealerLoopActive = false;
    }
  }
}