import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:auvy/data/artist_model.dart';
import 'package:auvy/data/dummy_data.dart';
import 'package:auvy/logic/artist_provider.dart';
import 'package:auvy/logic/library_provider.dart';
import 'package:auvy/logic/player_provider.dart';
import 'package:auvy/presentation/pages/album_page.dart'; 
import 'package:auvy/presentation/widgets/content_menus.dart'; 
import 'package:auvy/presentation/widgets/mini_player.dart'; 

// Screen for viewing detailed artist information including top songs, discography, and fans.
class ArtistPage extends ConsumerWidget {
  final Song artist;

  const ArtistPage({super.key, required this.artist});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final artistDataAsync = ref.watch(artistProvider(artist));
    final hasSong = ref.watch(playerProvider.select((s) => s.currentSong != null));
    final isSubscribed = ref.watch(libraryProvider.select((s) => 
        ref.read(libraryProvider.notifier).isSubscribed(artist.title)
    ));

    return Scaffold(
      backgroundColor: const Color(0xFF121212),
      body: Stack(
        children: [
          artistDataAsync.when(
            loading: () => const Center(child: CircularProgressIndicator(color: Colors.white)),
            error: (err, stack) => Center(child: Text("Error: $err", style: const TextStyle(color: Colors.white))),
            data: (data) {
              if (data == null) return const Center(child: Text("Artist not found"));

              return CustomScrollView(
                slivers: [
                  // Collapsible AppBar featuring a large artist image and name.
                  SliverAppBar(
                    expandedHeight: 340,
                    backgroundColor: const Color(0xFF121212),
                    pinned: true,
                    stretch: true,
                    leading: IconButton(
                      icon: const Icon(Icons.arrow_back, color: Colors.white),
                      onPressed: () => Navigator.pop(context),
                    ),
                    flexibleSpace: FlexibleSpaceBar(
                      title: Text(data.name, style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
                      centerTitle: true,
                      background: Stack(
                        fit: StackFit.expand,
                        children: [
                          Image.network(data.image, fit: BoxFit.cover),
                          const DecoratedBox(
                            decoration: BoxDecoration(
                              gradient: LinearGradient(
                                begin: Alignment.topCenter,
                                end: Alignment.bottomCenter,
                                colors: [Colors.transparent, Color(0xFF121212)],
                                stops: [0.6, 1.0],
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                    actions: [IconButton(icon: const Icon(Icons.share, color: Colors.white), onPressed: () {})],
                  ),

                  SliverToBoxAdapter(
                    child: Padding(
                      padding: const EdgeInsets.all(16),
                      child: Row(
                        children: [
                          // Button to subscribe to or unsubscribe from the artist.
                          OutlinedButton(
                            onPressed: () {
                              ref.read(libraryProvider.notifier).toggleArtistSubscription(data.name, data.image, artist.id);
                            },
                            style: OutlinedButton.styleFrom(
                              foregroundColor: isSubscribed ? Colors.black : Colors.white,
                              backgroundColor: isSubscribed ? Colors.white : Colors.transparent,
                              side: const BorderSide(color: Colors.white38),
                              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
                            ),
                            child: Text(isSubscribed ? "Subscribed" : "Subscribe"),
                          ),
                          const Spacer(),
                          FloatingActionButton.small(
                            onPressed: () {
                              if (data.topTracks.isNotEmpty) {
                                final shuffledList = data.topTracks.toList()..shuffle();
                                ref.read(playerProvider.notifier).playSong(shuffledList.first, newQueue: shuffledList);
                              }
                            },
                            backgroundColor: const Color(0xFF53B1E1),
                            child: const Icon(Icons.shuffle, color: Colors.black),
                          ),
                        ],
                      ),
                    ),
                  ),

                  _buildSectionHeader(context, "Top songs", null),
                  SliverList(
                    delegate: SliverChildBuilderDelegate(
                      (context, index) {
                        final song = data.topTracks[index];
                        return ListTile(
                          contentPadding: const EdgeInsets.symmetric(horizontal: 16),
                          leading: ClipRRect(
                            borderRadius: BorderRadius.circular(4),
                            child: Image.network(song.image, width: 50, height: 50, fit: BoxFit.cover, errorBuilder: (c,e,s)=>Container(color:Colors.grey)),
                          ),
                          title: Text(song.title, style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w500)),
                          subtitle: Text(song.artist, style: const TextStyle(color: Colors.white54, fontSize: 12)),
                          trailing: IconButton(
                            icon: const Icon(Icons.more_vert, color: Colors.white54),
                            onPressed: () => ContentMenus.showSongMenu(context, song),
                          ),
                          onTap: () => ref.read(playerProvider.notifier).playSong(song, newQueue: data.topTracks, index: index, source: "Artist"),
                        );
                      },
                      childCount: data.topTracks.length > 5 ? 5 : data.topTracks.length,
                    ),
                  ),

                  if (data.albums.isNotEmpty) ...[
                    _buildSectionHeader(context, "Albums", 
                      () => _navigateToViewAll(context, "Albums", data.albums, data.name)),
                    _buildHorizontalList(context, data.albums, data.name),
                  ],

                  if (data.singles.isNotEmpty) ...[
                    _buildSectionHeader(context, "Singles & EPs", 
                      () => _navigateToViewAll(context, "Singles & EPs", data.singles, data.name)),
                    _buildHorizontalList(context, data.singles, data.name),
                  ],

                  if (data.liveAlbums.isNotEmpty) ...[
                    _buildSectionHeader(context, "Live performances", 
                      () => _navigateToViewAll(context, "Live performances", data.liveAlbums, data.name)),
                    _buildHorizontalList(context, data.liveAlbums, data.name),
                  ],

                  if (data.relatedArtists.isNotEmpty) ...[
                    _buildSectionHeader(context, "Fans might also like", null),
                    SliverToBoxAdapter(
                      child: SizedBox(
                        height: 200,
                        child: ListView.builder(
                          scrollDirection: Axis.horizontal,
                          padding: const EdgeInsets.symmetric(horizontal: 16),
                          itemCount: data.relatedArtists.length,
                          itemBuilder: (context, index) {
                            final artist = data.relatedArtists[index];
                            return GestureDetector(
                              onTap: () {
                                Navigator.push(context, MaterialPageRoute(builder: (_) => ArtistPage(artist: artist)));
                              },
                              child: Container(
                                width: 140,
                                margin: const EdgeInsets.only(right: 16),
                                child: Column(
                                  children: [
                                    ClipOval(
                                      child: Image.network(artist.image, width: 140, height: 140, fit: BoxFit.cover, errorBuilder: (c,e,s)=>Container(color:Colors.grey)),
                                    ),
                                    const SizedBox(height: 8),
                                    Text(artist.title, style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold), maxLines: 1, overflow: TextOverflow.ellipsis, textAlign: TextAlign.center),
                                  ],
                                ),
                              ),
                            );
                          },
                        ),
                      ),
                    ),
                  ],

                  const SliverToBoxAdapter(child: SizedBox(height: 120)),
                ],
              );
            },
          ),

          if (hasSong) Align(alignment: Alignment.bottomCenter, child: Container(color: const Color(0xFF121212), child: const MiniPlayer())),
        ],
      ),
    );
  }

  // Helper widget to build a section header with an optional "View All" button.
  Widget _buildSectionHeader(BuildContext context, String title, VoidCallback? onViewAll) {
    return SliverToBoxAdapter(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 32, 16, 16),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Expanded(child: Text(title, style: const TextStyle(color: Colors.white, fontSize: 22, fontWeight: FontWeight.bold), maxLines: 1, overflow: TextOverflow.ellipsis)),
            if (onViewAll != null) IconButton(icon: const Icon(Icons.arrow_forward, color: Colors.white70), onPressed: onViewAll),
          ],
        ),
      ),
    );
  }

  // Generates a horizontal scrolling list of albums or singles.
  Widget _buildHorizontalList(BuildContext context, List<Album> items, String artistName) {
    return SliverToBoxAdapter(
      child: SizedBox(
        height: 210,
        child: ListView.builder(
          scrollDirection: Axis.horizontal,
          padding: const EdgeInsets.symmetric(horizontal: 16),
          itemCount: items.length > 10 ? 10 : items.length,
          itemBuilder: (context, index) {
            final item = items[index];
            return GestureDetector(
              onTap: () { Navigator.push(context, MaterialPageRoute(builder: (_) => AlbumPage(album: item, artistName: artistName))); },
              child: Container(
                width: 140,
                margin: const EdgeInsets.only(right: 16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    ClipRRect(borderRadius: BorderRadius.circular(8), child: Image.network(item.image, width: 140, height: 140, fit: BoxFit.cover, errorBuilder: (c,e,s)=>Container(color:Colors.grey))),
                    const SizedBox(height: 8),
                    Text(item.title, style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold), maxLines: 1, overflow: TextOverflow.ellipsis),
                    Text(item.releaseDate.split('-')[0], style: const TextStyle(color: Colors.white54, fontSize: 12)),
                  ],
                ),
              ),
            );
          },
        ),
      ),
    );
  }

  // Opens a separate page displaying all items within a specific discography section.
  void _navigateToViewAll(BuildContext context, String title, List<Album> items, String artistName) {
    Navigator.push(context, MaterialPageRoute(builder: (context) => _SectionViewAllPage(title: title, items: items, artistName: artistName)));
  }
}

// Widget representing the full-list view for a specific discography section.
class _SectionViewAllPage extends StatelessWidget {
  final String title;
  final List<Album> items;
  final String artistName;

  const _SectionViewAllPage({required this.title, required this.items, required this.artistName});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF121212),
      appBar: AppBar(
        backgroundColor: const Color(0xFF121212),
        title: Text(title, style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
        iconTheme: const IconThemeData(color: Colors.white),
      ),
      body: ListView.builder(
        padding: const EdgeInsets.all(16),
        itemCount: items.length,
        itemBuilder: (context, index) {
          final item = items[index];
          return ListTile(
            contentPadding: const EdgeInsets.only(bottom: 16),
            leading: ClipRRect(borderRadius: BorderRadius.circular(4), child: Image.network(item.image, width: 56, height: 56, fit: BoxFit.cover, errorBuilder: (c,e,s)=>Container(color:Colors.grey))),
            title: Text(item.title, style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w500)),
            subtitle: Text("Album • ${item.releaseDate.split('-')[0]}", style: const TextStyle(color: Colors.white54)),
            onTap: () {
               Navigator.push(context, MaterialPageRoute(builder: (_) => AlbumPage(album: item, artistName: artistName)));
            },
          );
        },
      ),
    );
  }
}