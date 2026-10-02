// Background "smart" playback features: autoplay recommendations, preloading
// the next track, lyrics warm-up and stream self-healing.
part of '../providers/player_provider.dart';

// Per-session cache of the per-artist recommendation seed fetch. Radio and the
// emergency refill revisit the same artists often, and each fetch is several
// MB, so repeats within a short TTL are served from memory.
final Map<String, List<Song>> _artistSeedCache = {};
final Map<String, DateTime> _artistSeedCacheAt = {};
const Duration _kArtistSeedTtl = Duration(minutes: 15);

// Lyrics are fetched only once a track is actually being listened to.
//
// A lyrics lookup queries several providers. Doing that for every track change,
// including tracks skipped within a second, made skipping expensive enough that
// YouTube started refusing requests. One shared timer means a run of skips costs
// a single lookup, for the track the listener stays on.
//
// Delaying is safe because this is only a warm-up: the lyrics view fetches on
// demand through lyricsProvider, so opening lyrics early still works.
Timer? _lyricsDwellTimer;

/// How long a track must stay current before its lyrics are fetched: long
/// enough that skipping costs nothing, short enough that lyrics are usually
/// ready when opened.
const Duration _kLyricsDwell = Duration(seconds: 3);

/// Why preloading is paused right now, or null when it is allowed. Remembers the
/// last reason so [_shouldPreloadNext] logs changes, not every position tick.
String? _preloadBlockedReason;

extension PlayerSmartController on PlayerNotifier {

  Future<void> prewarmSession() async {
    final song = currentState.currentSong;
    if (song == null) return;
 
    // Preload lyrics for the current track.
    _preloadLyrics(song);
 
    if (_cacheManager.isCached(song.id)) {
      // The current track is cached, so preload lyrics for the next one too.
      if (currentState.queue.length > 1) {
        final nextSong = currentState.queue[1];
        _preloadLyrics(nextSong);
      }
      return;
    }
  }

  Future<void> handleSmartSkipDetection(Song skippedSong, double listenPercent) async {
    final genre = currentState.contextTitle ?? currentState.contextType ?? "General";
    
    // Count skips.
    if (listenPercent < 0.3) {
      _consecutiveSkips++;
      
      // listenPercent is a 0–1 fraction; ×100 for display.
      print("Skip detected: ${skippedSong.title} (${(listenPercent * 100).toStringAsFixed(0)}% played)");
      
      // After 3 skips in a row, shift the recommendations toward other genres.
      if (_consecutiveSkips >= 3) {
        print("PIVOT: 3 consecutive skips detected! Changing recommendation strategy...");
        
        final intel = ref.read(intelligenceProvider.notifier);
        
        // Temporarily penalise the current genre.
        final newSession = Map<String, double>.from(
          ref.read(intelligenceProvider).sessionAffinities
        );
        newSession[genre] = (newSession[genre] ?? 0.0) - 15.0;
        
        // Boost alternative genres.
        final complementaryGenres = intel.getComplementaryGenres(genre);
        for (final altGenre in complementaryGenres.take(2)) {
          newSession[altGenre] = (newSession[altGenre] ?? 0.0) + 10.0;
        }
        
        // Go through the notifier's own setter, which saves the change.
        ref.read(intelligenceProvider.notifier).setSessionAffinities(newSession);
        
        // Refill in the background after a short delay instead of awaiting it.
        // playNext awaits this method before advancing, so awaiting the fetch here
        // put a whole recommendation request between the third tap and the next
        // track. The delay also lets this tap's queue rotation finish first, and
        // seeds the new picks from the track now playing rather than the rejected one.
        Timer(const Duration(milliseconds: 300), () {
          // Not under repeat: refreshAutoplay replaces the autoplay lane, which is where
          // a Repeat All loop lives, so an automatic refresh would delete the loop.
          // refreshAutoplay also re-checks before committing, in case the mode changes
          // during the fetch.
          if (mounted && currentState.repeatMode == RepeatMode.off) {
            refreshAutoplay();
          }
        });
        
        _consecutiveSkips = 0;
      }
    } else {
      // A track listened to properly resets the skip counter.
      _consecutiveSkips = 0;
    }
  }

  /// Autoplay refill. Concurrent callers share one in-flight refill and can await
  /// it, so the end-of-queue emergency path waits for a refill started elsewhere
  /// instead of giving up while tracks are still arriving.
  ///
  /// [force] is that emergency (queue empty at track end): it skips the
  /// prefetch and data-saver limits, because keeping music playing is not a
  /// background prefetch, but still respects being offline.
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

    // Radio, podcast episodes and audiobook chapters never get music appended.
    // The log names the actual kind so it doesn't send the reader looking for a
    // radio bug.
    final kind = currentState.currentSong!.mediaKind;
    if (kind != MediaKind.music) {
      print("${kind.name} active — skipping smart autoplay top-up");
      return;
    }

    // No autoplay top-up under any repeat mode: Repeat One loops the track and
    // Repeat All re-appends finished tracks, so the queue sustains itself.
    if (currentState.repeatMode != RepeatMode.off) {
      print("Skipping autoplay top-up (repeat mode active)");
      return;
    }

    // Settings → Playback → "Autoplay similar music". When off, an album or
    // playlist ends when it ends.
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

    // Only refill when the queue is actually running low.
    if (upcomingCount >= 5) {
      print("OK: Queue healthy: $upcomingCount tracks available");
      return;
    }

    _refillDebounce?.cancel();

    if (Random().nextInt(10) == 0) {
      ref.read(intelligenceProvider.notifier).logListeningStats();
    }
    
    try {
      // The state this refill was decided on, captured before any await. The fetches
      // below take seconds, and the commit replaces the queue, so the guards are
      // checked again before committing (see below).
      final seedSongId = currentState.currentSong!.id;
      final targetCount = 10 - currentState.autoplayQueue.length;
      final taste = ref.read(intelligenceProvider);
      final intelNotifier = ref.read(intelligenceProvider.notifier);
      final shouldUseContext = _shouldUseContextualRecommendations();
      
      // Log active genre boosts.
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

      // Collect ids and title+artist signatures already in the queue to prevent
      // duplicates.
      final Set<String> existingSignatures = {
        '${currentState.currentSong!.title.toLowerCase()}_${currentState.currentSong!.artist.toLowerCase()}',
        ...currentState.history.map((s) => '${s.title.toLowerCase()}_${s.artist.toLowerCase()}'),
        ...currentState.queue.map((s) => '${s.title.toLowerCase()}_${s.artist.toLowerCase()}'),
      };

      while (finalPicks.length < (targetCount / 2) && attempts < 2) {
        attempts++;
        List<Song> candidates;
        
        if (attempts == 1) {
          // Primary source: YouTube Music's radio for the current track (personalised
          // when signed in). If it comes back empty (guest throttling, network,
          // non-video id), fall back to the contextual or seeded engine.
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
        // Log the coherence context once per build, not per candidate.
        var loggedCoherence = false;
        for (final song in candidates) {
          final signature = '${song.title.toLowerCase()}_${song.artist.toLowerCase()}';
          
          // Skip anything already queued (by id or signature) or blocked.
          if (existingIds.contains(song.id) || existingSignatures.contains(signature) || taste.blacklistedIds.contains(song.id)) continue;

          // Skip placeholder junk (tracks or channels literally named "General", "Top",
          // "Unknown", etc.).
          if (isJunkMusicTerm(song.artist) || isJunkMusicTerm(song.title)) continue;

          
          // The genre of the playing song, so suggestions stay coherent with it. Comes
          // from genresFor, the app's single genre inference. (Passing the artist name to
          // getComplementaryGenres, as before, always returned the listener's all-time
          // top genre.)
          final currentGenre = currentState.contextType == 'genre'
              ? currentState.contextTitle
              : (currentState.currentSong != null
                  ? intelNotifier
                      .genresFor(currentState.currentSong!)
                      .firstOrNull
                  : null);
          
          // Apply the genre boost to the score.
          var score = intelNotifier.getSongScore(song, currentContext: currentGenre);
          if (!loggedCoherence) {
            loggedCoherence = true;
            // Log the coherence context once per build so it can be checked against the
            // playing track.
            print('   coherence context: ${currentGenre ?? "(none)"} '
                'for seed "${currentState.currentSong?.artist ?? "?"}"');
          }
          
          // Boost a candidate that belongs to a currently boosted genre. Keyed by the
          // candidate's own genres (genreBoosts is keyed by genre, not by album or
          // playlist name); the strongest matching boost wins.
          var boostMultiplier = 1.0;
          for (final g in intelNotifier.genresFor(song)) {
            final m = intelNotifier.getGenreBoostMultiplier(g);
            if (m > boostMultiplier) boostMultiplier = m;
          }
          if (boostMultiplier > 1.0) {
            // Additive, not multiplicative: getSongScore returns roughly -1..+1, and
            // multiplying a negative score would push it further down. The strongest boost
            // (2.5x) adds +0.15, enough to lift a track above its neighbours but not to
            // override taste.
            score += (boostMultiplier - 1.0) * 0.1;
            print("    Boosted: ${song.title} (${boostMultiplier.toStringAsFixed(1)}x)");
          }

          // Penalise artists that already appear in the queue.
          final artistCountInQueue = currentState.queue
              .where((q) => q.artist == song.artist)
              .length;
          score -= (artistCountInQueue * 30.0);

          // Leave `song.image` as it is; AuvyImage renders its own fallback for missing
          // art, and a better-sourced copy of the song can supply real art later.
          scoredRecs.add((song: song, score: score));
          existingIds.add(song.id);
          existingSignatures.add(signature); // Track this signature going forward
        }

        scoredRecs.sort((a, b) => b.score.compareTo(a.score));
        finalPicks.addAll(scoredRecs.take(targetCount - finalPicks.length).map((s) => s.song));
        
        if (finalPicks.length >= targetCount) break;
      }
      
      // Re-check the guards the awaits above may have invalidated. Both are hard
      // refusals:
      //
      //   * Repeat All: the queue is circular, and appending recommendations would
      //     break the loop (see the check at the top of this method).
      //   * Media kind: a podcast episode or radio stream must never get music
      //     appended.
      //
      // A changed track is deliberately not a reason to discard. The commit below
      // re-reads the queue and current song fresh, so it stays consistent; only the
      // picks are seeded from the older track. Discarding would also strand the
      // emergency refill in _handleQueueEnd, which awaits this future and then plays
      // queue[1].
      if (!mounted) return;
      if (currentState.repeatMode != RepeatMode.off) {
        print('Discarding autoplay refill: repeat became '
            '${currentState.repeatMode.name} while it was fetching — a repeat '
            'queue is circular and must not take recommendations');
        return;
      }
      final nowPlaying = currentState.currentSong;
      if (nowPlaying == null || nowPlaying.mediaKind != MediaKind.music) {
        print('Discarding autoplay refill: now playing '
            '${nowPlaying?.mediaKind.name ?? "nothing"}, which takes no music '
            'top-up');
        return;
      }
      if (nowPlaying.id != seedSongId) {
        // Kept, per the note above; logged so the stale seed is visible.
        print('Autoplay refill seeded from $seedSongId but ${nowPlaying.id} is '
            'playing now — keeping it, the queue still needs the tracks');
      }

      if (finalPicks.isNotEmpty) {
        final updatedAutoplay = [...currentState.autoplayQueue, ...finalPicks];
        final newFullQueue = [
          currentState.currentSong!,
          ...currentState.userQueue,
          ...currentState.contextQueue,
          ...updatedAutoplay,
        ];
        // The native player owns playback; here we only update the queue state.
        if (!mounted) return;
        currentState = currentState.copyWith(
          autoplayQueue: updatedAutoplay,
          queue: newFullQueue,
          // Keep the unshuffled snapshot in sync, or turning shuffle off would drop
          // tracks added while shuffled.
          originalQueue: currentState.isShuffle
              ? [...currentState.originalQueue, ...finalPicks]
              : newFullQueue,
        );

        // No prefetching here: downloading upcoming tracks while the current one
        // streams competed for bandwidth and caused stutter. The next track is warmed
        // once, near the end of the current one, in _preloadNextTrack.
        print("OK: Refilled queue with ${finalPicks.length} tracks after $attempts attempts.");
      }
    } catch (e) {
      print("ERROR: Smart Autoplay Error: $e");
    }
  }

  /// Whether to use contextual or fully personalised recommendations.
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

  /// Primary autoplay source: YouTube Music's "song radio" for the current track.
  /// Results still go through the scoring, artist penalty, dedup, junk and block
  /// filters in _topUpQueueInner. Returns [] (so the fallback runs) for radio,
  /// podcasts, non-video ids, or if the request fails.
  Future<List<Song>> _getCatalogRadioRecommendations() async {
    final seed = currentState.currentSong;
    if (seed == null || seed.id.startsWith('http') || seed.id.length != 11) {
      return const [];
    }
    return _searchService.getSongRadio(seed.id);
  }

  /// Contextual recommendations (for albums, playlists, artist pages).
  Future<List<Song>> _getContextualRecommendations({
    required int needed,
    required IntelligenceState taste,
    required IntelligenceNotifier intelNotifier,
  }) async {
    // Artist and album/playlist contexts use the same two seeds; they are fetched
    // in parallel since neither depends on the other.
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
      // Don't seed from a placeholder artist ("General", "Unknown", ...). Other seed
      // sources still run.
      if (isJunkMusicTerm(currentArtist)) return [];

      // Serve a recent cached result for this artist.
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

      // Fallback shared by "no results" and "results, but none by this artist".
      Future<List<Song>> tracksByNameInstead() async {
        print("WARN: Artist not resolved, using smart fallback");
        if (currentState.contextType == 'genre' && currentState.contextTitle != null) {
          final genreTracks = await _searchService.search(currentState.contextTitle!, 'track');
          return genreTracks.take(10).toList();
        }
        final trackResults = await _searchService.search(currentArtist, 'track');
        return trackResults
            .where((s) => SearchService.artistNameMatches(currentArtist, s.artist))
            .take(8)
            .toList();
      }

      if (artistSearchResults.isEmpty) return await tracksByNameInstead();

      // Pick the result that really is this artist (SearchService.pickArtistMatch)
      // instead of taking the first one. This result decides what autoplay queues
      // next, so a seed of "Drake" must not roll into Drake Bell's catalogue.
      // artistNameMatches also handles "Tyler, The Creator" vs "Tyler The Creator"
      // and "- Topic"/"VEVO" channels.
      final bestMatch = SearchService.pickArtistMatch<Song>(
          artistSearchResults, currentArtist, (a) => a.title);
      if (bestMatch == null) {
        print("   no artist result actually matches '$currentArtist' — "
            "not guessing at ${artistSearchResults.take(3).map((a) => a.title).toList()}");
        return await tracksByNameInstead();
      }

      final artistId = bestMatch.id;
      final topTracks = await _searchService.getArtistTopTracks(artistId);
      print("   Found ${topTracks.length} tracks by $currentArtist");

      if (topTracks.isNotEmpty) {
        // Cap the seed cache at 60 artists, evicting the oldest (entries also expire
        // by TTL).
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
      // nothing and wastes a request, so screen it here; the service itself doesn't
      // depend on intelligence_provider.
      if (isJunkMusicTerm(currentArtist)) return [];
      print("Fetching related artists to $currentArtist...");

      // YouTube Music's "Fans might also like" for the artist.
      final relatedArtists = await _searchService.getRelatedArtists(currentArtist);

      if (relatedArtists.isEmpty) {
        print("WARN: No related artists found");
        return [];
      }
      print("${relatedArtists.length} related artist(s) for $currentArtist");
      final artistsToCheck = relatedArtists.take(5).toList();
      // The five artists are fetched concurrently. CatalogApiClient already paces
      // every InnerTube request through one shared RateLimiter (220 ms interval,
      // burst 5), so an extra delay here only added latency, and getBrowse results
      // are cached anyway. The result list keeps the artists in order.
      final started = DateTime.now();
      final perArtist = await Future.wait(
        artistsToCheck.map((artist) async {
          try {
            final tracks = await _searchService.getArtistTopTracks(artist.id);
            if (tracks.isNotEmpty) return tracks.take(3).toList();
            // Only when the browse returned nothing: the id may be a name rather than a
            // channel, and a name can be searched.
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
      
      // Artists are resolved concurrently (pacing is handled by the shared
      // RateLimiter). The two calls per artist stay sequential because the browse
      // needs the search's id.
      final started = DateTime.now();
      final perArtist = await Future.wait(
        selectedArtists.where((a) => !isJunkMusicTerm(a)).map((artistName) async {
          try {
            final artistResults =
                await _searchService.search(artistName, 'artist');
            // Require an identity match (SearchService.artistNameMatches): a failed resolve
            // contributes nothing rather than tracks by the wrong artist.
            final artistMatch = SearchService.pickArtistMatch(
                artistResults, artistName, (s) => s.title);
            if (artistMatch == null) {
              // Log it: a name that never resolves quietly shrinks the pool.
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
      
      // Exclude placeholder genres ("General" etc.), or they become the literal
      // search query.
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

    // ref.read, not watch: watching here would make playerProvider depend on
    // connectivity and recreate the whole PlayerNotifier on a Wi-Fi/mobile switch
    // mid-playback.
    final connectivity = ref.read(connectivityProvider);
    if (connectivity.isOffline || !connectivity.shouldPreload) {
      print("Offline or data saver active - skipping autoplay refresh");
      return;
    }

    // Drive the queue sheet's refresh spinner.
    ref.read(autoplayRefreshingProvider.notifier).state = true;
    // Keep the spinner visible for at least [minBusy]. With a warm cache this
    // finishes in ~20 ms, so the spinner would never appear and the button would
    // look dead. This doesn't delay the queue; the tracks are already in place.
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

      // Seed from the current artist unless it's a placeholder. getSmartSeeds drops
      // junk seeds and falls back to the user's own affinities.
      final seeds = intelNotifier.getSmartSeeds(
        currentArtist: currentSong.artist,
        count: 6,
      );

      // Seeds resolve concurrently, and artwork is resolved lazily by AuvyImage at
      // display time rather than with a search per track, so a refresh takes a
      // second or two.
      const perSeedTimeout = Duration(seconds: 6);
      final perSeed = await Future.wait(seeds.map((seed) async {
        try {
          List<Song> results = await searchService
              .search(seed, 'artist')
              .timeout(perSeedTimeout, onTimeout: () => <Song>[])
              // Same identity rule as elsewhere: a seed that resolves to the wrong artist
              // falls through to the track search below.
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

      // Selection: the current track's radio leads and taste fills the rest.
      //
      // Radio takes the first two thirds of the slots in YouTube's relevance order,
      // up to 2 per artist so closely related artists can repeat. The taste pool
      // fills the remainder, which keeps the result personal. (Scoring radio into one
      // pool with a small bonus, a one-per-artist cap and a full shuffle returned the
      // listener's general taste instead of tracks that suit this song.)
      const int kTarget = 15;
      const int kRadioSlots = 10;

      final seenScoreIds = <String>{};
      bool usable(Song song) =>
          !existingIds.contains(song.id) &&
          !intel.blacklistedIds.contains(song.id) &&
          !isJunkMusicTerm(song.artist) &&
          !isJunkMusicTerm(song.title);

      // Primary: YouTube Music's radio for the current track. Its order is
      // relevance, so it is kept.
      final radioSongs = await searchService.getSongRadio(currentSong.id);
      final radioPool = <Song>[];
      for (final song in radioSongs) {
        if (!usable(song) || !seenScoreIds.add(song.id)) continue;
        radioPool.add(song);
      }

      // Secondary: the seed/affinity pool, scored, for breadth.
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

      // If radio came back empty or thin (offline, a non-video id, a new release
      // without a feed yet), the taste pool may fill the whole target.
      if (freshTracks.length < kTarget) {
        for (final item in scored) {
          if (freshTracks.length >= kTarget) break;
          if (existingIds.contains(item.song.id)) continue;
          take(item.song, 2);
        }
      }

      // Cold start only: seed a baseline so a brand-new user doesn't get an empty
      // queue. Established users get personal picks only.
      if (freshTracks.isEmpty && intelNotifier.isInColdStart) {
        print("Cold-start autoplay: seeding baseline recommendations.");
        final generalFallback = await searchService.search("Trending Radio", 'track');
        freshTracks.addAll(generalFallback
            .where((s) => !isJunkMusicTerm(s.artist) && !isJunkMusicTerm(s.title))
            .take(5));
      }

      // Shuffle only the taste-derived tail, so repeated refreshes vary without
      // scrambling the radio's relevance order.
      if (freshTracks.length > radioTaken) {
        final tail = freshTracks.sublist(radioTaken)..shuffle();
        freshTracks.replaceRange(radioTaken, freshTracks.length, tail);
      }

      print("Autoplay refresh: $radioTaken from this track's radio, "
          "${freshTracks.length - radioTaken} from taste seeds");

      // `currentSong` was captured before the awaits above. If a different track is
      // playing now, give up rather than build the queue around a stale head; the
      // picks were seeded for the old track, and a refresh is cheap to repeat.
      final liveSong = currentState.currentSong;
      if (liveSong == null || liveSong.id != currentSong.id) {
        print('Autoplay refresh discarded: seeded from "${currentSong.title}" '
            'but "${liveSong?.title ?? "nothing"}" is playing now');
        return;
      }

      // Don't replace the autoplay lane under repeat: that lane holds the Repeat All
      // loop. The automatic caller checks too; this covers the mode changing while
      // the fetch was in flight.
      if (!mounted) return;
      if (currentState.repeatMode != RepeatMode.off) {
        print('Autoplay refresh discarded: repeat is '
            '${currentState.repeatMode.name} and its queue is circular — '
            'replacing the autoplay segment would delete the loop');
        return;
      }

      final newQueue = [
        liveSong,
        ...currentState.userQueue,
        ...currentState.contextQueue,
        ...freshTracks,
      ];

      if (!mounted) return;
      currentState = currentState.copyWith(
        autoplayQueue: freshTracks,
        queue: newQueue,
        // Keep the unshuffled snapshot consistent so unshuffling keeps the refreshed
        // tracks.
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
    // Read once, not per candidate.
    final intelForGenres = ref.read(intelligenceProvider.notifier);
    final currentSong = currentState.currentSong;
    final currentArtist = currentSong?.artist.toLowerCase();
    final currentGenre = currentState.contextTitle ?? 'General';

    // Resolve the current artist's complementary artists once, from the
    // original-case name (artistTransitions is keyed that way), and compare
    // case-insensitively per candidate. The answer doesn't depend on the
    // candidate, so computing it per candidate only repeated a full map scan.
    final currentArtistRaw = currentSong?.artist.trim() ?? '';
    final Set<String> complementaryArtists = currentArtistRaw.isEmpty
        ? const <String>{}
        : ref
            .read(intelligenceProvider.notifier)
            .getComplementaryArtists(currentArtistRaw, limit: 10)
            .map((a) => a.toLowerCase().trim())
            .toSet();

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

      // Settings → Intelligence → "Discovery". Tilts the balance between learned
      // taste (genre + artist affinity) and the novelty bonus for unheard tracks,
      // by scaling the existing terms rather than adding a new one:
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
      final isComplementary = complementaryArtists.contains(artistKey);
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

      // Genre match via genresFor, the app's single genre inference
      // (genre_signal_test guards against a second one).
      if (intelForGenres.genresFor(song).contains(currentGenre.toLowerCase())) {
        score += 10.0;
      }
      
      // Novelty: reward tracks you haven't heard and penalise ones you've heard a
      // lot, scaled by noveltyWeight. Uses the play count, not trackAffinities, which
      // is a signed taste score and would reward tracks the listener keeps skipping.
      final playCount = taste.playCounts[song.id] ?? 0;
      if (playCount == 0) {
        score += 15.0 * 0.05 * noveltyWeight;
      } else if (playCount < 3) {
        score += 8.0 * 0.05 * noveltyWeight;
      } else if (playCount > 15) {
        score -= 12.0 * 0.05 * noveltyWeight;
      }
      
      // Time-of-day relevance for this artist, capped so a raw accumulator can't
      // dominate terms that otherwise sit between 5 and 50.
      final hour = DateTime.now().hour;
      final timeContext = taste.timeOfDayAffinities[hour] ?? {};
      final timeRelevance = timeContext[song.artist] ?? 0.0;
      score += (timeRelevance * 3.0).clamp(0.0, 15.0);
      
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

  // Seconds before a track ends at which the next one is warmed, so the switch
  // is seamless.
  static const int _preloadLeadSeconds = 12;

  /// How long a new "next track" must stay next before its stream is resolved and
  /// its opening bytes fetched: long enough that skipping spends nothing, short
  /// enough to be unnoticeable.
  static const Duration _preloadSettleWindow = Duration(seconds: 3);

  /// Replaces every occurrence of [from] with [to] across the queue lanes. Used by
  /// the preload to swap a video row for its audio version before it becomes
  /// current (mirroring playSong's swap), so gapless auto-advance plays the audio.
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

  /// Call after a queue edit with the up-next id captured before the edit.
  ///
  /// With gapless playback the native player has the previous next track
  /// pre-buffered. If the edit put a different track in `queue[1]`, the player
  /// would briefly roll into the stale one at the boundary. So when the up-next
  /// changed, drop the native upcoming item synchronously and reset the preload
  /// guard so the right track is prepared on the next tick (or now, if playing).
  /// No-op when the up-next is unchanged.
  void resyncUpcomingIfChanged(String? previousNextId) {
    if (!currentState.gaplessPlayback) return;
    final newNextId =
        currentState.queue.length > 1 ? currentState.queue[1].id : null;
    if (newNextId == previousNextId) return; // up-next unchanged → still valid
    // Stale upcoming: clear it now so the boundary can't play it.
    try {
      NativeAudioEngine.clearUpcoming();
    } catch (_) {}
    _preloadedSongId = null;
    _syncCacheProtectedTracks();
    if (newNextId != null && currentState.isPlaying) _preloadNextTrack();
  }

  /// Warms the next track shortly before the current one ends so the switch
  /// is near-instant: resolves its stream, prepares it as the native upcoming
  /// item and preloads its lyrics and cover. Called from the position
  /// callback about twice a second; the `_isPreloading` / `_preloadedSongId`
  /// guards keep repeat calls cheap.
  Future<void> _preloadNextTrack() async {
    if (!_shouldPreloadNext()) return;
    if (_isPreloading ||
        currentState.queue.isEmpty ||
        currentState.repeatMode == RepeatMode.one) return;

    // "Sleep at end of track": nothing follows, so nothing to warm. Preparing a
    // next item would let the native player roll into it at the boundary, which is
    // exactly what this setting prevents.
    if (currentState.sleepAtEndOfTrack) return;

    final duration = currentState.duration;
    final position = currentState.position;
    if (duration.inMilliseconds == 0) return;

    // Skip tracks too short to be worth pre-warming.
    if (duration.inSeconds <= _preloadLeadSeconds + 3) return;
    // Fire once the current track has a few seconds of playback or enters the
    // lead window, whichever comes first, so the next track's opening bytes are
    // cached before a screen-off network blackout. _preloadedSongId keeps it to
    // one warm-up.
    final remaining = duration - position;
    // A next track that is already on disk is prepared immediately instead of
    // waiting out the first seconds of playback. After a skip the position is 0,
    // so without this nothing is prepared and a second quick skip falls back to a
    // full load. The wait exists to avoid a stream lookup and ~1 MB download for
    // tracks that get skipped; a local file costs neither.
    final nextId = currentState.queue.length > 1 ? currentState.queue[1].id : '';
    final nextIsOnDisk = nextId.isNotEmpty && _cacheManager.isCached(nextId);
    final earlyEnough = position.inSeconds >= 8 || nextIsOnDisk;
    final inLeadWindow =
        remaining.inSeconds <= _preloadLeadSeconds && remaining.inSeconds > 0;
    if (!earlyEnough && !inLeadWindow) return;

    // Next index, wrapping to 0 only when Repeat All is on.
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

    // Let a changed "next" settle before spending data on it. While the user
    // skips, "next" changes every few seconds, and warming each one (a stream
    // lookup plus ~1 MB) would be wasted. The position tick re-enters about twice
    // a second, so waiting needs no timer. Exceptions: inside the lead window there
    // is no time to wait, and a cached track costs no network.
    if (!inLeadWindow && !_cacheManager.isCached(song.id)) {
      final now = DateTime.now();
      if (_nextSettleId != song.id) {
        _nextSettleId = song.id;
        _nextSettleAt = now;
        return;
      }
      if (now.difference(_nextSettleAt ?? now) < _preloadSettleWindow) return;
    }

    // Radio and podcast streams are already playable URLs; nothing to resolve.
    // Mark as handled so this isn't re-checked every tick.
    if (song.id.startsWith('http') && song.albumTitle != 'Podcast') {
      _preloadedSongId = song.id;
      return;
    }

    _isPreloading = true;
    // Claim this song up front so repeated position callbacks don't start a second
    // warm-up while this one is in flight.
    _preloadedSongId = song.id;

    try {
      final connectivity = ref.read(connectivityProvider);

      // 1) Pre-warm the next track: resolve its URL and fetch its first ~1 MB into
      //    the native play cache, so the switch starts instantly without downloading
      //    the whole track. This also warms the Dart resolver cache for any later
      //    re-resolve. Radio and podcasts are not pre-warmed.
      if (!song.id.startsWith('http')) {
        // The track that will actually play next. With gapless on, the native
        // auto-advance bypasses playSong's audio-only swap, so a music video must be
        // swapped for its audio version here, in the queue too, so the native
        // transition's id matches queue[1].
        Song upcoming = song;
        if (currentState.gaplessPlayback &&
            !currentState.processVideosEnabled &&
            !_cacheManager.isCached(upcoming.id)) {
          // Must match playSong's audio-only swap conditions exactly: a tagged music
          // video, an untagged track inside an album/playlist, or a 16:9 video thumbnail.
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
                    // Audio from the matched twin, edition details from the queued row. See
                    // mergeConformedAudio.
                    : SearchService.mergeConformedAudio(upcoming, a));
            if (audio != null && audio.id != upcoming.id) {
              _swapInQueues(upcoming, audio);
              upcoming = audio;
              _preloadedSongId = upcoming.id;
            }
          }
        }

        // The next track is already on disk: hand the file to the native player as
        // the upcoming item so downloaded albums play gaplessly too.
        final cachedNextPath = _cacheManager.getCachedPath(upcoming.id);
        if (cachedNextPath != null) {
          if (currentState.gaplessPlayback) {
            // Re-check it is still up next: the user may have edited the queue during the
            // awaits above.
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
          // Use the same quality flag and bitrate ceiling as the main resolver. An
          // instant skip plays the warmed format as is, so if the preload picked a
          // different format, a later mid-track re-resolve would fetch a different file
          // length and be refused by the format pin.
          final warmLowQuality = connectivity.shouldUseLowQualityAudio ||
              currentState.audioQuality == AudioQuality.low;
          // Refresh the bitrate ceiling at every track boundary, where changing format is
          // free. Reading the cached value let one early decision govern playback for
          // hours.
          final ceiling = await _refreshBitrateCeiling();
          final stream = await _audioService
              .getStreamWithFallback(
                upcoming.id,
                upcoming.title,
                upcoming.artist,
                lowQuality: warmLowQuality,
                maxBitrate: ceiling,
              )
              .timeout(const Duration(seconds: 8));
          // Record it under the same pin the resolver reads, so a mid-track re-resolve of
          // this track reproduces the choice.
          _lowQualityPin[upcoming.id] = warmLowQuality;
          final url = stream?['url'];
          // The queue may have changed during the resolve. Only prepare this as the
          // native upcoming item if it is still up next; resyncUpcomingIfChanged clears
          // it on edits, and this stops an in-flight resolve from re-adding it.
          final stillNext = currentState.queue.length > nextIndex &&
              currentState.queue[nextIndex].id == upcoming.id;
          if (url != null && url.isNotEmpty && stillNext) {
            if (currentState.gaplessPlayback) {
              // Queue it as the native player's next item, which is pre-buffered and plays
              // with no gap.
              await NativeAudioEngine.setUpcoming(
                upcoming.id, url,
                userAgent: stream?['user_agent'],
                contentLength: int.tryParse(stream?['contentLength'] ?? '0'),
              );
            } else {
              // Gapless off: pre-warm the first ~1 MB and let Dart advance.
              await NativeAudioEngine.prewarmNext(
                upcoming.id, url,
                userAgent: stream?['user_agent'],
                contentLength: int.tryParse(stream?['contentLength'] ?? '0'),
              );
            }
          }
        }
      }

      // 2) Lyrics, ready when the next track starts. Best-effort.
      unawaited(Future(() async {
        try {
          // Send the catalogue duration. This preload usually runs first and its result
          // is cached, so without a duration the scorer's version check (which rejects
          // lyrics timed to a different master) would never run for most tracks.
          await _lyricsService
              .getLyrics(song.title, song.artist,
                  songId: song.id,
                  trackDurationMs:
                      LyricsService.durationMsFromDisplay(song.duration))
              .timeout(const Duration(seconds: 8));
        } catch (_) {}
      }));

      // 3) The player-page cover. Each surface requests art at the size it paints,
      // so the large player cover is a different URL from the list thumbnails and
      // would otherwise be a cold fetch. Warming it with the next track means the
      // player shows it on the first frame. Respects Data Saver via
      // shouldLoadHighResImages, as the widget does.
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
      // Stream warm-up failed; let the next tick retry.
      _preloadedSongId = null;
      print('WARN: Preload error: $e');
    } finally {
      _isPreloading = false;
    }
  }

  /// Whether the next track may be warmed right now.
  ///
  /// Logs only when the reason changes (and when preloading resumes), not on every
  /// position tick, which ran about twice a second and flooded the log while
  /// offline.
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
        // No disk-cache shortcut here. [LyricsService.getLyrics] reads the same cache
        // and is the only place that re-scores an entry chosen without a track length
        // once the length is known. Returning early here would keep the unverified
        // choice forever.
        print("Preloading lyrics: ${song.title}");
        await _lyricsService.getLyrics(
          song.title,
          song.artist,
          album: song.albumTitle.isNotEmpty && song.albumTitle != 'null' ? song.albumTitle : null,
          songId: song.id,
          // Needed so the scorer can reject lyrics timed to a different master (see
          // durationMsFromDisplay). Every caller must send it, because the first answer
          // is the one that gets cached.
          trackDurationMs: LyricsService.durationMsFromDisplay(song.duration),
        );
        print("OK: Lyrics preloaded successfully");
      } catch (e) {
        print("WARN: Lyrics preload failed: $e");
      }
    });
  }

  static bool _isHealerLoopActive = false;
  // Consecutive heals of the same song with no playback progress between them
  // (see handleStreamLeaseExpiration). Static because extensions can't hold
  // state.
  static String? _healSongId;
  static int _healCount = 0;
  static Duration _healLastPosition = Duration.zero;
  // Consecutive heal failures for the same song caused by network faults (Doze,
  // Wi-Fi power saving) rather than a dead track. Bounds the wait so an
  // unresolvable track still advances after a few attempts.
  static String? _healNetHoldSongId;
  static int _healNetHoldCount = 0;

  /// Consecutive local-copy heals of one song inside [_kLocalHealWindow]. Counted
  /// separately because the local-copy path resets [_healCount], so a corrupt
  /// file would otherwise heal, fail and heal again forever.
  static String? _localHealSongId;
  static int _localHealCount = 0;
  static int _localHealAtMs = 0;
  static const Duration _kLocalHealWindow = Duration(seconds: 10);
  static const int _kMaxLocalHeals = 2;

  /// Switches playback to [song]'s complete local copy, resuming at [from].
  ///
  /// Returns true when the file took over, false when there is no trustworthy
  /// copy and the caller should go on to the network heal. After
  /// [_kMaxLocalHeals] attempts inside [_kLocalHealWindow] the copy is no longer
  /// trusted and the network path, with its own limits, takes over.
  Future<bool> _healFromLocalCopy(
      Song song, Duration from, bool? intendedPlaying) async {
    // A radio stream has no cache entry.
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

    // Right after a heal starts, the player briefly reports position 0; an error in
    // that window must not be read as "the track is at 0:00", or it restarts the
    // song.
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

  /// Recovers a failing stream by reloading it natively.
  /// [intendedPlaying] is the native player's playWhenReady at the moment of the
  /// error, the listener's real play/pause intent. It takes priority over
  /// currentState.isPlaying, which already reads false once a dying stream starts
  /// buffering, and would reload the track paused.
  Future<void> handleStreamLeaseExpiration(
      {bool? intendedPlaying, Duration? resumeFrom}) async {
    final currentSong = currentState.currentSong;
    if (currentSong == null || _isHealerLoopActive) return;

    _isHealerLoopActive = true;
    print('[Auvy Native Engine] Stream link lease expired or dropped. Recovering natively...');

    try {
      // A complete local copy beats every branch below, including the offline check:
      // auto-cache often has the whole file by the time the network drops, so there
      // is nothing to wait for. getCachedPath only returns complete, unexpired files.
      if (await _healFromLocalCopy(
          currentSong, resumeFrom ?? currentState.position, intendedPlaying)) {
        return;
      }

      // Offline: healing needs the network, so don't blame the track. Hold the
      // position, arm a retry, and let the connectivity listener fire it as soon as
      // the network is back. The heal counters are left alone, so a genuinely broken
      // stream still gets its full retries once there is a network.
      if (!ref.read(connectivityProvider).hasInternet) {
        final holdFrom = resumeFrom ?? currentState.position;
        final wantPlaying = intendedPlaying ?? currentState.isPlaying;
        print('heal deferred — no network. Holding '
            '"${currentSong.title}" at ${holdFrom.inSeconds}s for reconnect');
        await NativeAudioEngine.pause();
        if (!mounted) return;
        currentState = currentState.copyWith(isLoading: true);
        currentPositionProvider.value = holdFrom;
        void healOnReconnect() {
          if (!mounted) return;
          if (currentState.currentSong?.id != currentSong.id) return;
          // Cached URLs belong to the network path that went away; drop them.
          _audioService.invalidateAllStreams();
          handleStreamLeaseExpiration(
            intendedPlaying: wantPlaying,
            resumeFrom: holdFrom,
          );
        }
        _pendingNetworkRetry = healOnReconnect;
        // A slow fallback in case the connectivity event never arrives (a captive
        // portal or half-open cell link can look "connected" the whole time).
        _recoveryTimer?.cancel();
        _recoveryTimer = Timer(const Duration(seconds: 20), () {
          if (_pendingNetworkRetry != healOnReconnect) return;
          _pendingNetworkRetry = null;
          healOnReconnect();
        });
        return;
      }

      // [resumeFrom] is the live position when the fault happened (the player may
      // already have jumped to the end on a premature end-of-track). Prefer it so the
      // heal resumes where audio actually stopped.
      Duration interruptionPoint = resumeFrom ?? currentState.position;
      // During a heal the player briefly reports position 0. An error then must not
      // reset the no-progress counter or seek back to 0:00; reuse the last real
      // position.
      if (_healSongId == currentSong.id &&
          interruptionPoint == Duration.zero &&
          _healLastPosition > Duration.zero) {
        interruptionPoint = _healLastPosition;
      }

      // No-progress counter. A fresh URL can still fail as soon as the player reads
      // from the current offset (CDN rate limits, IP-bound URLs after a network
      // switch). Progress since the last heal resets the counter; three heals with no
      // progress means the track is unrecoverable, so block it briefly and move on.
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
        // If heals keep failing on track after track, it's a CDN/IP-level block (often
        // after Wi-Fi reconnects under Doze), not one bad track, and skipping would
        // just eat the queue. After the first give-up, hold the current track and
        // retry with fresh URLs on a slow cadence or when connectivity returns.
        _gateFailStreak++;
        // Upper bound: if holding never works (~5 cycles), skip so the queue doesn't
        // stay stuck on an unplayable track.
        if (_gateFailStreak >= 2 &&
            _gateFailStreak <= 6 &&
            mounted &&
            currentState.currentSong?.id == currentSong.id) {
          print('STOP: Repeated cross-track heal failures — CDN/IP gate storm; '
              'holding "${currentSong.title}" instead of skipping the queue');
          await NativeAudioEngine.pause();
          if (!mounted) return;
          currentState = currentState.copyWith(isLoading: true);
          currentPositionProvider.value = interruptionPoint;
          final holdFrom = interruptionPoint;
          void reheal() {
            if (mounted && currentState.currentSong?.id == currentSong.id) {
              // Force fresh URLs; the block affects cached ones too.
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
        await _handlePersistentFailure(currentSong);
        playNext(autoAdvance: true);
        return;
      }

      // Keep the real play/pause intent across the heal. A stream can need
      // re-resolving while paused (typically the track restored at launch), and it
      // should stay paused. The native playWhenReady is authoritative;
      // currentState.isPlaying is only a fallback for native builds that don't send
      // it.
      final bool wasPlaying = intendedPlaying ?? currentState.isPlaying;

      // The local copy was already tried at the top of this method.

      // Repeated heals of the same stall: pause before retrying so a rate-limited CDN
      // isn't hammered in a tight loop.
      if (_healCount >= 2) {
        await Future.delayed(Duration(seconds: 2 * (_healCount - 1)));
        if (!mounted || currentState.currentSong?.id != currentSong.id) return;
      }

      // Heal at the session's quality. From the second no-progress heal on, flip the
      // quality tier: a different format comes from a different URL family, which
      // often avoids a block on one format.
      final bool sessionLow =
          ref.read(connectivityProvider).shouldUseLowQualityAudio ||
              currentState.audioQuality == AudioQuality.low;
      final bool healLow = _healCount >= 2 ? !sessionLow : sessionLow;
      if (_healCount >= 2) {
        print('Heal #$_healCount: switching audio format tier (low=$healLow) to dodge gating');
      }

      // Two attempts before giving up, so one flaky resolve doesn't skip the track.
      Map<String, dynamic>? stream;
      for (int attempt = 1; attempt <= 2; attempt++) {
        // Drop the stale cached URL and resolve a fresh one.
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

      // The resolve took time; if the user skipped or the queue advanced, loading
      // the old song's URL now would replace the track that is actually current.
      if (!mounted || currentState.currentSong?.id != currentSong.id) return;

      if (freshUrl != null && freshUrl.toString().isNotEmpty) {
        // Hand the fresh URL (with matching user agent and length) to the native
        // player, resuming only if it was playing before.
        await NativeAudioEngine.playTrack(
          currentSong.id, freshUrl,
          userAgent: stream?['user_agent'],
          contentLength: int.tryParse(stream?['contentLength'] ?? '0'),
          autoPlay: wasPlaying,
        );
        _nativeLoadedSongId = currentSong.id;

        // Seek back to where it dropped out.
        await NativeAudioEngine.seek(interruptionPoint);

        _healNetHoldSongId = null;
        _healNetHoldCount = 0;
        print('Playback successfully restored gaplessly. Exiting self-heal loop.');
      } else {
        throw Exception("No fresh stream available during heal (2 attempts).");
      }

    } catch (recoveryException) {
      print('ERROR: Background Stream Self-Healing failed to rescue active track: $recoveryException');
      // Tell a network outage (Doze, Wi-Fi power saving) apart from a dead track.
      // During an outage every next track would fail the same way, so advancing
      // would skip through the queue with the screen off. Under Doze the OS still
      // reports a connection (only DNS fails), so the failure itself is the signal:
      // hold this track paused and heal again when the network wakes. Bounded so a
      // truly unresolvable track still advances.
      final err = recoveryException.toString().toLowerCase();
      final looksNetwork = !ref.read(connectivityProvider).hasInternet ||
          err.contains('socket') || err.contains('host') ||
          err.contains('no address') || err.contains('timeout') ||
          err.contains('connection') || err.contains('no fresh stream') ||
          err.contains('no playable stream') || err.contains('clientexception') ||
          err.contains('empty chunk') || err.contains('ioexception') ||
          err.contains('network') || err.contains('http') ||
          err.contains('handshake') || err.contains('tls') ||
          err.contains('reset') || err.contains('broken pipe') ||
          err.contains('closed') || err.contains('unavailable') ||
          err.contains('503') || err.contains('502') || err.contains('504') || err.contains('429');
      if (looksNetwork && mounted && currentState.currentSong?.id == currentSong.id) {
        if (_healNetHoldSongId != currentSong.id) {
          _healNetHoldSongId = currentSong.id;
          _healNetHoldCount = 0;
        }
        _healNetHoldCount++;
        if (_healNetHoldCount <= 5) {
          // Drop point captured before the failed resolve.
          final holdFrom = _healLastPosition > Duration.zero
              ? _healLastPosition
              : (resumeFrom ?? currentState.position);
          print('Heal hit a network fault — holding "${currentSong.title}" '
              '(hold $_healNetHoldCount/5), waiting for connectivity to return');
          _healSongId = null;
          _healCount = 0;
          await NativeAudioEngine.pause();
          if (!mounted) return;
          currentState = currentState.copyWith(isLoading: true);
          // Keep the slider at the drop point, not frozen at the end of the track.
          currentPositionProvider.value = holdFrom;
          void reheal() {
            if (mounted && currentState.currentSong?.id == currentSong.id) {
              handleStreamLeaseExpiration(
                intendedPlaying: intendedPlaying ?? true,
                resumeFrom: holdFrom,
              );
            }
          }
          // Fires immediately when connectivity is restored; the timer is the fallback
          // for Doze, where the connection never visibly toggles but the timer runs once
          // the device wakes.
          _pendingNetworkRetry = reheal;
          _recoveryTimer?.cancel();
          _recoveryTimer = Timer(const Duration(seconds: 20), reheal);
          return;
        }
        print('STOP: Heal network-hold exhausted for "${currentSong.title}" — advancing');
        _healNetHoldSongId = null;
        _healNetHoldCount = 0;
      }
      if (_healCount < 3 && mounted && currentState.currentSong?.id == currentSong.id) {
        print('Heal encountered transient error ($recoveryException) — retrying ($_healCount/3)');
        final holdFrom = _healLastPosition > Duration.zero
            ? _healLastPosition
            : (resumeFrom ?? currentState.position);
        _recoveryTimer?.cancel();
        _recoveryTimer = Timer(const Duration(seconds: 3), () {
          if (mounted && currentState.currentSong?.id == currentSong.id) {
            handleStreamLeaseExpiration(
              intendedPlaying: intendedPlaying ?? true,
              resumeFrom: holdFrom,
            );
          }
        });
        return;
      }
      await _handlePersistentFailure(currentSong);
      playNext(autoAdvance: true);
    } finally {
      _isHealerLoopActive = false;
    }
  }
}