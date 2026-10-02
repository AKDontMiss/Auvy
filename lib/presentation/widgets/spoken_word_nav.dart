import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:auvy/core/app_navigation.dart';
import 'package:auvy/data/dummy_data.dart';
import 'package:auvy/logic/media_kind.dart';
import 'package:auvy/presentation/pages/audiobooks_page.dart';
import 'package:auvy/presentation/pages/podcast_page.dart';
import 'package:auvy/presentation/widgets/animated_toast.dart';
import 'package:auvy/providers/podcast_provider.dart';
import 'package:auvy/providers/theme_provider.dart';

/// Where a podcast episode's or audiobook chapter's "album" really is: its
/// show's page or its book's page. Shared by the player title, the song menu and
/// the queue, which otherwise opened an album page for an id that is no album.
/// Returns false for music (the caller opens the album as usual).
Future<bool> openSpokenWordSource(WidgetRef ref, Song song) async {
  switch (song.mediaKind) {
    case MediaKind.podcast:
      final show = await showForEpisodeSong(song);
      if (show == null) {
        AnimatedToast.message("Couldn't find this show");
        return true;
      }
      AppNavigation.pushOnActiveTab(
          PodcastShowPage(show: show, themeColor: ref.read(themeProvider)),
          name: 'podcast-show:${show.collectionName}');
      return true;
    case MediaKind.audiobook:
      await openAudiobookOfSong(ref, song);
      return true;
    case MediaKind.music:
    case MediaKind.liveStream:
      return false;
  }
}
