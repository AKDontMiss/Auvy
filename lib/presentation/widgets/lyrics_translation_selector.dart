import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:auvy/services/lyrics_translation_service.dart';
import 'package:auvy/providers/lyrics_provider.dart';
import 'package:auvy/providers/theme_provider.dart';
import 'package:auvy/core/app_colors.dart';
import 'package:auvy/data/lyrics_model.dart';

class LyricsTranslationSelector extends ConsumerWidget {
  /// Rendered at the right-hand end of the row, opposite the language button.
  ///
  /// Exists so the lyric sync stepper can share this row instead of taking one
  /// of its own — see the note at the call site. Optional, because the podcast
  /// path shows a sync bar and no language button at all.
  final Widget? trailing;

  const LyricsTranslationSelector({super.key, this.trailing});

  void _translateLanguage(WidgetRef ref, String langKey, bool isCached, LyricsData lyricsData) async {
    if (isCached || langKey == 'original') {
      ref.read(currentLyricsLanguageProvider.notifier).state = langKey;
    } else {
      ref.read(currentLyricsLanguageProvider.notifier).state = langKey;
      ref.read(lyricsTranslationLoadingProvider.notifier).state = true;
      
      final lines = lyricsData.lines.map((l) => l.words).toList();
      final translated = await LyricsTranslationService().translateLyricsBatch(lines, langKey);
      
      if (translated != null) {
        ref.read(translatedLyricsProvider.notifier).update((s) => {...s, langKey: translated});
      }
      ref.read(lyricsTranslationLoadingProvider.notifier).state = false;
    }
  }

  void _showAllLanguagesModal(BuildContext context, WidgetRef ref, Color themeColor, LyricsData lyricsData, Map<String, dynamic> cache, String currentLang) {
    showModalBottomSheet(
      context: context,
      backgroundColor: const Color(0xFF181818),
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(24))),
      builder: (context) {
        // Original is the first row, pinned above the divider: this sheet is the route
        // back to the untranslated lyrics, and it isn't one of the languages.
        final langs = <MapEntry<String, String>>[
          const MapEntry('original', 'Original'),
          ...LyricsTranslationService.supportedLanguages.entries.toList()
            ..sort((a, b) => a.value.compareTo(b.value)),
        ];

        return SizedBox(
          height: MediaQuery.of(context).size.height * 0.6,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(24, 24, 24, 12),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    const Text("Translate Lyrics", style: TextStyle(color: Colors.white, fontSize: 20, fontWeight: FontWeight.bold)),
                    IconButton(tooltip: 'Close', icon: const Icon(Icons.close, color: Colors.white54), onPressed: () => Navigator.pop(context)),
                  ],
                ),
              ),
              const Divider(color: Colors.white10),
              Expanded(
                child: ListView.builder(
                  physics: const BouncingScrollPhysics(),
                  itemCount: langs.length,
                  itemBuilder: (context, index) {
                    final lang = langs[index];
                    final isCached = cache.containsKey(lang.key);
                    final isSelected = currentLang == lang.key;

                    final tile = ListTile(
                      contentPadding: const EdgeInsets.symmetric(horizontal: 24),
                      title: Text(lang.value, style: TextStyle(color: isSelected ? themeColor : Colors.white, fontWeight: isSelected ? FontWeight.w700 : FontWeight.w500)),
                      trailing: isCached && !isSelected
                          ? Icon(Icons.offline_pin, color: themeColor.withOpacity(0.5), size: 18)
                          : (isSelected ? Icon(Icons.check_circle, color: themeColor, size: 22) : null),
                      onTap: () {
                        Navigator.pop(context);
                        _translateLanguage(ref, lang.key, isCached, lyricsData);
                      }
                    );

                    // Keeps "Original" visually apart from the languages it is
                    // listed above, so the first row does not read as one more
                    // translation choice.
                    if (lang.key == 'original') {
                      return Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [tile, const Divider(color: Colors.white10, height: 1)],
                      );
                    }
                    return tile;
                  }
                ),
              ),
            ],
          ),
        );
      }
    );
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final currentLang = ref.watch(currentLyricsLanguageProvider);
    final lyricsData = ref.watch(lyricsProvider).value;
    final themeColor = ref.watch(themeProvider);
    final translatedCache = ref.watch(translatedLyricsProvider);
    final isLoadingGlobal = ref.watch(lyricsTranslationLoadingProvider);

    if (lyricsData == null) return const SizedBox.shrink();

    final isOriginal = currentLang == 'original';
    final label = isOriginal
        ? 'Translate'
        : (LyricsTranslationService.supportedLanguages[currentLang] ??
            currentLang.toUpperCase());

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Row(
        children: [
          // One button that names the current language and opens the full list, instead of
          // a scrolling strip of pills that could hide the active choice.
          _TranslateButton(
            label: label,
            isActive: !isOriginal,
            isLoading: isLoadingGlobal,
            themeColor: themeColor,
            onTap: () => _showAllLanguagesModal(
                context, ref, themeColor, lyricsData, translatedCache, currentLang),
          ),
          const Spacer(),
          // One row: the language button on the left and the sync stepper on the right,
          // both about how these lyrics are presented.
          if (trailing != null) ...[
            const SizedBox(width: 8),
            trailing!,
          ],
        ],
      ),
    );
  }
}

/// The single control that replaced the pill strip.
///
/// Reads as its own state: faded and captioned "Translate" while the original
/// lyrics are showing, tinted with the theme colour and captioned with the
/// language once a translation is active.
class _TranslateButton extends StatelessWidget {
  final String label;
  final bool isActive;
  final bool isLoading;
  final Color themeColor;
  final VoidCallback onTap;

  const _TranslateButton({
    required this.label,
    required this.isActive,
    required this.isLoading,
    required this.themeColor,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final fg = isActive ? Colors.black : Colors.white70;
    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 250),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
        decoration: BoxDecoration(
          color: isActive ? themeColor : AppColors.whiteFaded08,
          borderRadius: BorderRadius.circular(20),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (isLoading)
              Padding(
                padding: const EdgeInsets.only(right: 8),
                child: SizedBox(
                  width: 14,
                  height: 14,
                  child: CircularProgressIndicator(strokeWidth: 2, color: fg),
                ),
              )
            else
              Padding(
                padding: const EdgeInsets.only(right: 8),
                child: Icon(Icons.translate, size: 16, color: fg),
              ),
            Text(
              label,
              style: TextStyle(
                color: fg,
                fontSize: 13,
                fontWeight: isActive ? FontWeight.w800 : FontWeight.w600,
              ),
            ),
            Padding(
              padding: const EdgeInsets.only(left: 4),
              child: Icon(Icons.expand_more, size: 16, color: fg),
            ),
          ],
        ),
      ),
    );
  }
}
