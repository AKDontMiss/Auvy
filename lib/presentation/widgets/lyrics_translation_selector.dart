import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:auvy/services/lyrics_translation_service.dart';
import 'package:auvy/providers/lyrics_provider.dart';
import 'package:auvy/providers/theme_provider.dart';
import 'package:auvy/core/app_colors.dart';
import 'package:auvy/data/lyrics_model.dart';

class LyricsTranslationSelector extends ConsumerWidget {
  const LyricsTranslationSelector({super.key});

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
        final langs = LyricsTranslationService.supportedLanguages.entries.toList()
           ..sort((a, b) => a.value.compareTo(b.value));
           
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
                    IconButton(icon: const Icon(Icons.close, color: Colors.white54), onPressed: () => Navigator.pop(context)),
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

                    return ListTile(
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

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Row(
        children: [
          Icon(Icons.translate, size: 18, color: Colors.white.withOpacity(0.5)),
          const SizedBox(width: 12),
          Expanded(
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              physics: const BouncingScrollPhysics(),
              child: Row(
                children: [
                  _LanguageChip(
                    label: 'Original',
                    isSelected: currentLang == 'original',
                    themeColor: themeColor,
                    onTap: () => ref.read(currentLyricsLanguageProvider.notifier).state = 'original',
                  ),
                  const SizedBox(width: 8),
                  
                  // Keep English & Swedish immediately reachable + currently selected cached
                  ...(() {
                    final alwaysShow = ['en', 'sv']; 
                    final otherCached = translatedCache.keys.where((k) => !alwaysShow.contains(k)).toList();
                    final languagesToShow = {...alwaysShow, ...otherCached}.toList();

                    return languagesToShow.map((langKey) {
                      final bool isCached = translatedCache.containsKey(langKey);
                      final String label = LyricsTranslationService.supportedLanguages[langKey] ?? langKey.toUpperCase();

                      return Padding(
                        padding: const EdgeInsets.only(right: 8),
                        child: _LanguageChip(
                          label: label,
                          isSelected: currentLang == langKey,
                          themeColor: themeColor,
                          isLoading: isLoadingGlobal && currentLang == langKey && !isCached,
                          onTap: () => _translateLanguage(ref, langKey, isCached, lyricsData),
                        ),
                      );
                    });
                  }()),
                  
                  // The robust solution so they don't get clustered:
                  _LanguageChip(
                    label: '+ More',
                    isSelected: false,
                    themeColor: themeColor,
                    onTap: () => _showAllLanguagesModal(context, ref, themeColor, lyricsData, translatedCache, currentLang),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _LanguageChip extends StatelessWidget {
  final String label;
  final bool isSelected;
  final bool isLoading;
  final Color themeColor;
  final VoidCallback onTap;

  const _LanguageChip({
    required this.label,
    required this.isSelected,
    required this.themeColor,
    required this.onTap,
    this.isLoading = false,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: isLoading ? null : onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 250),
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        decoration: BoxDecoration(
          color: isSelected ? themeColor : AppColors.whiteFaded08,
          borderRadius: BorderRadius.circular(20),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (isLoading)
              Padding(
                padding: const EdgeInsets.only(right: 8),
                child: SizedBox(
                  width: 14, height: 14,
                  child: CircularProgressIndicator(
                    strokeWidth: 2, 
                    color: isSelected ? Colors.black : Colors.white
                  ),
                ),
              ),
            Text(
              label,
              style: TextStyle(
                color: isSelected ? Colors.black : Colors.white70,
                fontSize: 13,
                fontWeight: isSelected ? FontWeight.w800 : FontWeight.w600,
              ),
            ),
          ],
        ),
      ),
    );
  }
}