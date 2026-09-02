import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:auvy/data/audiobook_model.dart';
import 'package:auvy/services/audiobook_service.dart';

/// The browse selection: either the newest additions, or one LibriVox genre.
///
/// A single provider keyed on this rather than one per genre, so switching chips
/// reuses the same subscription and the service's own cache answers instantly on
/// the way back.
final audiobookGenreProvider = StateProvider<String?>((_) => null);

/// The current browse list. Null genre = the most-listened books.
///
/// POPULAR, NOT NEWEST. Browsing by catalogue date showed whatever a volunteer
/// finished last week — obscure by definition. Ranking by download count leads
/// with the books people actually come for.
final audiobookListProvider = FutureProvider<List<Audiobook>>((ref) async {
  final genre = ref.watch(audiobookGenreProvider);
  if (genre == null || genre.isEmpty) return AudiobookService.popular();
  return AudiobookService.byGenre(genre);
});

/// Search results, empty query = no request.
///
/// autoDispose so a search the user has moved on from stops being held, but the
/// SERVICE cache survives it — going back to the same term is free without
/// keeping every past query's widgets alive.
final audiobookSearchProvider =
    FutureProvider.autoDispose.family<List<Audiobook>, String>((ref, query) {
  final q = query.trim();
  if (q.length < 2) return Future.value(const []);
  return AudiobookService.search(q);
});

/// One book's chapters, fetched only when its page is opened — the listing
/// endpoints carry no file list, and fetching one per row would be dozens of
/// requests for rows nobody has scrolled to.
final audiobookChaptersProvider =
    FutureProvider.autoDispose.family<List<AudiobookChapter>, Audiobook>(
        (ref, book) => AudiobookService.chaptersFor(book));
