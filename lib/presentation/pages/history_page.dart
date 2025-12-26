import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:auvy/logic/player_provider.dart';
import 'package:auvy/presentation/widgets/dynamic_background.dart';

// Screen that displays a list of recently played tracks.
class HistoryPage extends ConsumerWidget {
  const HistoryPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // Retrieves the playback history from the player provider.
    final history = ref.watch(playerProvider.select((s) => s.history));
    final notifier = ref.read(playerProvider.notifier);

    return DynamicBackground(
      child: Scaffold(
        backgroundColor: Colors.transparent,
        appBar: AppBar(
          backgroundColor: Colors.transparent,
          title: const Text("Listening History"),
          centerTitle: true,
          leading: IconButton(
            icon: const Icon(Icons.arrow_back, color: Colors.white),
            onPressed: () => Navigator.pop(context),
          ),
        ),
        body: history.isEmpty
            ? const Center(
                child: Text("No history yet. Play some music!", style: TextStyle(color: Colors.white70)),
              )
            : ListView.builder(
                itemCount: history.length,
                itemBuilder: (context, index) {
                  final song = history[index];
                  return ListTile(
                    leading: ClipRRect(
                      borderRadius: BorderRadius.circular(4),
                      child: Image.network(
                        song.image,
                        width: 50, height: 50, fit: BoxFit.cover,
                        errorBuilder: (c, e, s) => Container(color: Colors.grey, width: 50, height: 50),
                      ),
                    ),
                    title: Text(song.title, style: const TextStyle(color: Colors.white)),
                    subtitle: Text(song.artist, style: const TextStyle(color: Colors.white70)),
                    trailing: const Icon(Icons.play_arrow_rounded, color: Colors.white),
                    onTap: () {
                      notifier.playSong(song);
                    },
                  );
                },
              ),
      ),
    );
  }
}