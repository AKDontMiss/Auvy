import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;

import 'package:auvy/presentation/widgets/auvy_search_field.dart';
import 'package:auvy/presentation/widgets/skeleton_loader.dart';
import 'package:auvy/providers/theme_provider.dart';
import 'package:auvy/services/haptic_service.dart';
import 'package:auvy/services/updater_service.dart';

/// One ready-made cover.
class CoverArt {
  final String name;
  final String url;
  const CoverArt({required this.name, required this.url});
}

/// The cover library, fetched once per app run.
///
/// SERVED, NOT BUNDLED. These live in the private repo and are handed over by
/// the Worker (`GET /covers`). Shipping ~19MB of artwork as Flutter assets would
/// put every image inside the APK forever — paid for by every user on every
/// install, including the ones they never pick. Served, the APK does not grow,
/// the set can change without a release, and only a chosen image is downloaded.
///
/// `keepAlive` by default for a FutureProvider without autoDispose: opening the
/// picker twice should not re-fetch a list that cannot change mid-session.
final coverLibraryProvider = FutureProvider<List<CoverArt>>((ref) async {
  final res = await http
      .get(Uri.parse('https://${UpdaterService.updateHost}/covers'))
      .timeout(const Duration(seconds: 15));
  if (res.statusCode != 200) return const [];
  final body = jsonDecode(res.body) as Map<String, dynamic>;
  final list = (body['covers'] as List?) ?? const [];
  return list
      .map((e) => CoverArt(
            name: (e['name'] ?? '').toString(),
            url: (e['url'] ?? '').toString(),
          ))
      .where((c) => c.url.isNotEmpty)
      .toList();
});

/// Pick a cover from the library. Returns the chosen image URL, or null.
///
/// The caller downloads and stores it — this sheet only chooses, so it stays
/// usable from anywhere (playlist creation, the playlist menu, elsewhere later)
/// without knowing how that screen persists artwork.
Future<String?> showCoverPickerSheet(BuildContext context) {
  return showModalBottomSheet<String>(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    elevation: 0,
    // ROOT navigator. The mini player is painted ABOVE the tab navigator, so
    // a sheet pushed on the inner one leaves it tappable — you could open the
    // player or an album page WHILE this modal was up, and the sheet then sat
    // orphaned on top of wherever you landed. On the root navigator the barrier
    // covers the mini player too, which is what modal means.
    useRootNavigator: true,
    builder: (_) => const _CoverPickerSheet(),
  );
}

class _CoverPickerSheet extends ConsumerStatefulWidget {
  const _CoverPickerSheet();

  @override
  ConsumerState<_CoverPickerSheet> createState() => _CoverPickerSheetState();
}

class _CoverPickerSheetState extends ConsumerState<_CoverPickerSheet> {
  String _query = '';
  String? _selected;

  /// Match on the FILENAME, which is the only label these images carry.
  ///
  /// Split on whitespace and require every term, so "blue car" narrows rather
  /// than widening — with ~180 covers an OR search returns most of the library
  /// and helps nobody. Hyphens count as spaces because the names are slugs:
  /// typing "breaking news" has to find `breaking-news`.
  bool _matches(CoverArt c, List<String> terms) {
    if (terms.isEmpty) return true;
    final hay = c.name.replaceAll('-', ' ');
    return terms.every(hay.contains);
  }

  @override
  Widget build(BuildContext context) {
    final themeColor = ref.watch(themeProvider);
    final async = ref.watch(coverLibraryProvider);
    final terms = _query
        .toLowerCase()
        .split(RegExp(r'\s+'))
        .where((t) => t.isNotEmpty)
        .toList();

    return DraggableScrollableSheet(
      initialChildSize: 0.85,
      minChildSize: 0.5,
      maxChildSize: 0.95,
      expand: false,
      builder: (context, scrollController) => Container(
        decoration: const BoxDecoration(
          color: Color(0xFF141418),
          borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
        ),
        child: Column(
          children: [
            const SizedBox(height: 10),
            Container(
              width: 38,
              height: 4,
              decoration: BoxDecoration(
                color: Colors.white24,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 14, 20, 6),
              child: Row(
                children: [
                  const Expanded(
                    child: Text(
                      'Choose a cover',
                      style: TextStyle(
                        color: Colors.white,
                        fontSize: 19,
                        fontWeight: FontWeight.w800,
                        letterSpacing: -0.2,
                      ),
                    ),
                  ),
                  IconButton(
                    icon: const Icon(Icons.close_rounded, color: Colors.white54),
                    onPressed: () => Navigator.pop(context),
                  ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 12),
              child: AuvySearchField(
                hint: 'Search covers',
                height: 46,
                radius: 23,
                fontSize: 14.5,
                onChanged: (v) => setState(() => _query = v),
              ),
            ),
            Expanded(
              child: async.when(
                loading: () => GridView.builder(
                  controller: scrollController,
                  padding: const EdgeInsets.fromLTRB(20, 4, 20, 24),
                  gridDelegate:
                      const SliverGridDelegateWithFixedCrossAxisCount(
                    crossAxisCount: 3,
                    crossAxisSpacing: 10,
                    mainAxisSpacing: 10,
                  ),
                  itemCount: 12,
                  itemBuilder: (_, __) => const SkeletonLoader(
                      width: double.infinity,
                      height: double.infinity,
                      borderRadius: 14),
                ),
                error: (e, _) => _empty(
                  Icons.cloud_off_rounded,
                  "Couldn't load covers",
                  'Check your connection and try again.',
                ),
                data: (covers) {
                  final shown =
                      covers.where((c) => _matches(c, terms)).toList();
                  if (covers.isEmpty) {
                    return _empty(
                      Icons.image_not_supported_rounded,
                      'No covers available',
                      'The cover library is empty right now.',
                    );
                  }
                  if (shown.isEmpty) {
                    return _empty(
                      Icons.search_off_rounded,
                      'Nothing matches “$_query”',
                      'Try a single word — the names are short.',
                    );
                  }
                  return GridView.builder(
                    controller: scrollController,
                    padding: const EdgeInsets.fromLTRB(20, 4, 20, 28),
                    gridDelegate:
                        const SliverGridDelegateWithFixedCrossAxisCount(
                      crossAxisCount: 3,
                      crossAxisSpacing: 10,
                      mainAxisSpacing: 10,
                    ),
                    itemCount: shown.length,
                    itemBuilder: (context, i) {
                      final c = shown[i];
                      final picked = _selected == c.url;
                      return _CoverTile(
                        cover: c,
                        selected: picked,
                        themeColor: themeColor,
                        onTap: () {
                          HapticService.selection();
                          setState(() => _selected = c.url);
                        },
                      );
                    },
                  );
                },
              ),
            ),
            // Confirm rather than pick-and-close: tapping a thumbnail by accident
            // should not silently replace artwork the user already had.
            SafeArea(
              top: false,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(20, 4, 20, 12),
                child: SizedBox(
                  width: double.infinity,
                  height: 50,
                  child: ElevatedButton(
                    onPressed: _selected == null
                        ? null
                        : () {
                            HapticService.medium();
                            Navigator.pop(context, _selected);
                          },
                    style: ElevatedButton.styleFrom(
                      backgroundColor: themeColor,
                      disabledBackgroundColor: Colors.white10,
                      shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(25)),
                    ),
                    child: Text(
                      _selected == null ? 'Select a cover' : 'Use this cover',
                      style: TextStyle(
                        color: _selected == null ? Colors.white38 : Colors.white,
                        fontWeight: FontWeight.w800,
                        fontSize: 15,
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _empty(IconData icon, String title, String subtitle) => Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: 42, color: Colors.white.withOpacity(0.25)),
              const SizedBox(height: 12),
              Text(title,
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                      color: Colors.white,
                      fontSize: 15,
                      fontWeight: FontWeight.w700)),
              const SizedBox(height: 6),
              Text(subtitle,
                  textAlign: TextAlign.center,
                  style: TextStyle(
                      color: Colors.white.withOpacity(0.66), fontSize: 12.5)),
            ],
          ),
        ),
      );
}

class _CoverTile extends StatelessWidget {
  final CoverArt cover;
  final bool selected;
  final Color themeColor;
  final VoidCallback onTap;

  const _CoverTile({
    required this.cover,
    required this.selected,
    required this.themeColor,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 150),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(14),
          border: Border.all(
            color: selected ? themeColor : Colors.white.withOpacity(0.07),
            width: selected ? 2.4 : 1,
          ),
        ),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(12),
          child: Stack(
            fit: StackFit.expand,
            children: [
              // Plain Image.network, not AuvyImage: these are remote thumbnails
              // with no local-file or override semantics, and the Worker already
              // serves them with a long cache header.
              Image.network(
                cover.url,
                fit: BoxFit.cover,
                // ~370px covers a third-width tile on a 3x screen without
                // decoding the full 1000px source for a thumbnail.
                cacheWidth: 370,
                loadingBuilder: (context, child, progress) => progress == null
                    ? child
                    : Container(color: Colors.white.withOpacity(0.04)),
                errorBuilder: (_, __, ___) => Container(
                  color: Colors.white.withOpacity(0.04),
                  child: const Icon(Icons.broken_image_rounded,
                      color: Colors.white24, size: 20),
                ),
              ),
              if (selected)
                Container(
                  color: themeColor.withOpacity(0.22),
                  child: Center(
                    child: Container(
                      padding: const EdgeInsets.all(5),
                      decoration:
                          BoxDecoration(color: themeColor, shape: BoxShape.circle),
                      child: const Icon(Icons.check_rounded,
                          color: Colors.white, size: 17),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}
