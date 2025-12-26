import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:auvy/data/lyrics_model.dart';
import 'package:auvy/logic/lyrics_service.dart';
import 'package:auvy/logic/player_provider.dart';

// Provider that manages fetching and updating lyrics based on the current song.
final lyricsProvider = FutureProvider<LyricsData?>((ref) async {
  // Watches only the current song to avoid unnecessary re-fetches when playback position changes.
  final currentSong = ref.watch(playerProvider.select((state) => state.currentSong));

  if (currentSong == null) return null;

  print("🎵 Fetching Lyrics for: ${currentSong.title}"); 
  
  final service = LyricsService();
  return await service.getLyrics(currentSong.title, currentSong.artist);
});