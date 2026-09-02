import 'package:flutter/material.dart';
import 'package:auvy/presentation/widgets/dynamic_background.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:auvy/providers/player_provider.dart';
import 'package:auvy/providers/theme_provider.dart';
import 'package:auvy/services/updater_service.dart';
import 'package:auvy/presentation/main_layout.dart';
import 'package:auvy/logic/audio_cache_manager.dart';
import 'package:auvy/providers/data_usage_provider.dart';
import 'package:auvy/presentation/widgets/animated_toast.dart';
import 'package:auvy/providers/connectivity_provider.dart';
import 'package:auvy/providers/slider_provider.dart';
import 'package:auvy/presentation/widgets/custom_sliders.dart';
import 'package:auvy/presentation/widgets/squiggly_wavy_slider.dart';
import 'package:auvy/services/haptic_service.dart';
import 'package:auvy/services/app_icon_service.dart';
import 'package:auvy/services/library_export_service.dart';
import 'dart:io';
import 'package:auvy/services/foreign_backup_reader.dart';
import 'package:auvy/services/track_list_file_parser.dart';
import 'package:auvy/providers/home_provider.dart' show homeProvider;
import 'package:auvy/providers/search_provider.dart' show searchServiceProvider;
import 'package:auvy/services/recognition_history.dart';
import 'package:auvy/data/artist_model.dart';
import 'package:auvy/data/dummy_data.dart';
import 'package:auvy/services/update_state.dart';
import 'package:auvy/providers/intelligence_provider.dart';
import 'package:auvy/presentation/pages/changelog_page.dart';
import 'package:auvy/services/scrobble_service.dart';
import 'package:auvy/services/listening_policy.dart';
import 'package:auvy/providers/account_provider.dart';
import 'package:auvy/providers/library_provider.dart';
import 'package:auvy/presentation/widgets/splash_screen.dart';
import 'package:auvy/services/cloud_sync_service.dart';
import 'package:auvy/services/rich_presence_service.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:auvy/presentation/widgets/coach_marks.dart';
import 'package:auvy/presentation/widgets/alarm_settings_block.dart';
import 'package:auvy/presentation/widgets/info_hint.dart';
import 'package:auvy/presentation/widgets/settings_kit.dart';
import 'package:auvy/presentation/pages/privacy_page.dart';
import 'package:auvy/presentation/pages/romanization_page.dart';
import 'package:auvy/presentation/pages/onboarding_page.dart';
import 'package:auvy/presentation/pages/stream_sources_page.dart';
import 'package:auvy/presentation/widgets/diagnostics_sheet.dart';
import 'package:auvy/services/activity_log.dart';

// SETTINGS — premium, lightweight makeover.
//  • Sections are rounded cards with tinted icon chips (Apple-Settings feel).
//  • Every player-state read is select()-scoped: the old page watched the whole
//    playerProvider from four builders, so EVERY periodic state write rebuilt
//    the entire ListView. Now only the row that changed rebuilds.
//  • All controls/flows from the previous page are preserved 1:1.

class SettingsPage extends ConsumerStatefulWidget {
  const SettingsPage({super.key});

  @override
  ConsumerState<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends ConsumerState<SettingsPage> {
  /// Live filter text. Empty means "show everything", which is the normal state —
  /// the field is an accelerator, not a mode.
  String _query = '';

  /// Words that should match a section beyond its own title.
  ///
  /// Needed because the thing people search for is rarely the heading it lives
  /// under: "equalizer" is in Sound, "crossfade" is in Playback, "backup" is in
  /// Account. Matching titles alone would make the box look broken for exactly
  /// the queries someone bothers to type.
  static const Map<String, String> _sectionKeywords = {
    'Motion': 'animation reduce transition',
    'Playback': 'crossfade gapless normalize normalise volume skip silence '
        'autoplay similar connect audio quality video',
    'Sound': 'equalizer eq bass treble pitch speed stream sources clients '
        'loudness normalisation',
    'Intelligence': 'recommendations taste discovery bias smart mix',
    'Listening data': 'history privacy pause scrobble last.fm lastfm '
        'discord presence',
    'Data & Storage': 'cache size downloads storage offline data saver',
    'Account': 'sign out login backup sync cloud delete account profile',
    'About': 'version licence license build info',
    'Updates': 'update check announce release apk',
  };

  bool _matches(String label) {
    final q = _query.trim().toLowerCase();
    if (q.isEmpty) return true;
    if (label.toLowerCase().contains(q)) return true;
    return (_sectionKeywords[label] ?? '').contains(q);
  }

  @override
  Widget build(BuildContext context) {
    // Subscribed on purpose even though nothing here reads the value: the
    // accent is consumed by child widgets, but this page paints its own
    // backdrop and must repaint when the colour changes.
    ref.watch(themeProvider);

    // force:true — Settings is pushed on the ROOT navigator (over MainLayout),
    // so unlike a tab sub-page it has no shared app backdrop beneath it. Paint
    // our OWN backdrop here (instead of passing through to the global one that
    // lives under MainLayout) so the library page never shows through. Paired
    // with the opaque route in AppNavigation.pushRoot(..., opaque: true).
    return DynamicBackground(
      force: true,
      child: Scaffold(
        backgroundColor: Colors.transparent,
        body: CustomScrollView(
          physics: const BouncingScrollPhysics(),
          slivers: [
            _buildHeaderBar(context),

            // Filter
            // Settings is nine sections long; finding one setting meant
            // remembering which heading someone else filed it under. Typing
            // narrows to the section that contains it, matching keywords as well
            // as titles (see _sectionKeywords) — "equalizer" finds Sound,
            // "backup" finds Account.
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(24, 8, 24, 0),
                child: TextField(
                  onChanged: (v) => setState(() => _query = v),
                  style: const TextStyle(color: Colors.white, fontSize: 14),
                  decoration: InputDecoration(
                    isDense: true,
                    hintText: 'Search settings',
                    hintStyle:
                        const TextStyle(color: Colors.white38, fontSize: 14),
                    prefixIcon: const Icon(Icons.search_rounded,
                        color: Colors.white38, size: 20),
                    suffixIcon: _query.isEmpty
                        ? null
                        : IconButton(
                            icon: const Icon(Icons.close_rounded,
                                color: Colors.white38, size: 18),
                            onPressed: () => setState(() => _query = ''),
                          ),
                    filled: true,
                    fillColor: Colors.white.withOpacity(0.06),
                    contentPadding: const EdgeInsets.symmetric(vertical: 12),
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(14),
                      borderSide: BorderSide.none,
                    ),
                  ),
                ),
              ),
            ),

            // No separate "App icon" row: the launcher icon follows the accent
            // colour (see AppIconService.applyForAccent), so picking purple here
            // also turns the home-screen icon purple. One decision, not two.
            //
            // The accent swatches moved to ThemePage so they can be judged
            // against a live preview of the app instead of as bare circles.
            // The "Appearance" ENTRY POINT is NOT here — it lives in the
            // library-page side panel, alongside Privacy and About. Those three
            // are app-level destinations you visit occasionally, and having them
            // in both places meant two routes to the same page and a Settings
            // screen padded with rows that only forwarded elsewhere.
            //
            // Reduce motion stays: it is a behavioural setting, not a
            // destination, and it belongs next to the other playback/behaviour
            // switches rather than inside the colour picker.
            _section("Motion", [
              const _ReduceMotionRow(),
            ]),

            _section("Playback", [
              const _PlaybackToggles(),
              // Sleep timer MOVED to the library side panel → Tools, where it
              // opens the timer sheet in one tap. It is an act-now control, not a
              // preference, so a settings row was the wrong home for it, and two
              // doorways to the same sheet is the duplication this app keeps
              // pruning. (The player menu keeps its own entry: that is the other
              // place you reach for it mid-listen.)
            ]),

            _section("Sound", [
              const _AudioQualityBlock(),
              const _SectionDivider(),
              const _EqBlock(),
              const _SectionDivider(),
              _NavRow(
                icon: Icons.cloud_download_rounded,
                tint: const Color(0xFF80DEEA),
                title: "Stream sources",
                subtitle: "Which YouTube clients Auvy resolves audio from",
                onTap: () => Navigator.push(
                    context, MainLayout.smoothRoute(const StreamSourcesPage())),
              ),
            ]),


            // Intelligence sits next to Listening data on purpose: one governs
            // what Auvy records, the other what it concludes from it.
            _section("Intelligence", [
              const _DiscoveryBiasBlock(),
              const _SectionDivider(),
              // "Identified songs" MOVED to the side panel → Tools. It is a
              // DESTINATION (a list you browse), and destinations belong in the
              // panel; Settings keeps the switches. `_CaptureArmRow` below stays,
              // because that IS a switch.
              const _SectionDivider(),
              const _ResetTasteRow(),
              const _SectionDivider(),
              // The counterpart to onboarding's "Quick start": if the taste
              // questions were skipped (or answered badly years ago), this is
              // the way back to them. Before this, the flow ran exactly once and
              // `has_onboarded` locked it away — the same trap the tutorial was
              // in until "Replay tutorial" was added below.
              _NavRow(
                icon: Icons.tune_rounded,
                tint: const Color(0xFFFFD180),
                title: "Personalise your taste",
                subtitle: "Re-answer the languages, genres and artists questions",
                onTap: () => Navigator.push(context,
                    MainLayout.smoothRoute(const OnboardingPage(isRedo: true))),
              ),
            ]),

            // Privacy is its own destination. The
            // two pause switches used to sit inside "Listening data" next to
            // "Keep screen on" and "Open on", and the matching CLEAR actions
            // lived on two other screens entirely, so nothing answered "what
            // does Auvy keep about me?" in one place.
            // The "Privacy" ENTRY POINT moved to the library side panel too, so
            // this section is gone, but the SWITCHES it summarised (pause
            // listening history, pause search history) are still right below in
            // "Listening data", where they always were. Nothing became
            // unreachable; only the duplicate doorway went.
            _section("Listening data", [
              const _ListeningPolicyBlock(),
              const _SectionDivider(),
              // Placed inside Listening data, and last: it is the only feature
              // that sends this history OFF the device, so it reads after the
              // switches that decide what is recorded, and it obeys them.
              const _ScrobbleRow(),
            ]),

            //"Wake up" LIVES IN LIBRARY → TOOLS NOW, not here. It sat beside
            // the sleep timer's old home, and both belong where you reach for them
            // — in bed, not several sections down a settings scroll. Keeping a copy
            // here would mean two surfaces editing the same statics and
            // disagreeing about what they show.

            // Data & Storage and Account used to inline their full blocks —
            // sliders, live stats, profile pickers, backup status and the
            // delete-account flow all stacked in the main scroll. That's a lot of
            // machinery to scroll past to reach About, and none of it is a
            // one-tap decision. Both now open dedicated screens (the pattern
            // Spotify and Apple Music use) with a compact summary here. The
            // blocks themselves are UNCHANGED — just rendered one level deeper.
            _section("Data & Storage", [
              // Data saver stays inline: it's a genuine one-tap toggle people
              // flip when they're on cellular, not something to go hunting for.
              const _DataSaverBlock(),
              const _SectionDivider(),
              const _OfflineModeRow(),
              const _SectionDivider(),
              const _StorageSummaryRow(),
            ]),

            _section("Account", [
              const _AccountSummaryRow(),
              // "Hidden Content" MOVED to the side panel → Tools. Same reasoning:
              // it is a list you go and manage, and it was the most buried
              // destination in the app — several sections down a long settings
              // scroll, which is a poor home for the only way to UNDO a "don't
              // recommend this".
            ]),

            _section("About", [
              // The hands-on tutorial used to be reachable EXACTLY ONCE, from
              // onboarding — after that `has_seen_tutorial` locked it away with
              // no way back in. Anyone who skipped it (or forgot a gesture)
              // could never see it again, so it lives here now too.
              _NavRow(
                icon: Icons.school_rounded,
                tint: const Color(0xFFFFD54F),
                title: "Replay tutorial",
                subtitle: "Practise Auvy's gestures again, hands-on",
                // The walkthrough spotlights the REAL tabs and mini-player, all
                // of which Settings is currently covering, so step out to the
                // app first, then arm it. MainLayout listens for that and starts
                // the tour (see CoachTour.armedSignal).
                onTap: () {
                  Navigator.of(context).popUntil((r) => r.isFirst);
                  CoachTour.armed = true;
                },
              ),
              const _SectionDivider(),
              // "About Auvy" moved to the library side panel. See the note on
              // the Motion section above. Export diagnostics stays here because
              // it is an ACTION taken while troubleshooting, not a page you browse.

              // HYDRV's export-diagnostics. Under About because it is what you
              // reach for when reporting a problem, right beside the version
              // number the report is mostly about.
              // The flight recorder
              //
              // Beside "Export diagnostics" because it answers the same
              // question, over a longer window: that one is a snapshot of state
              // now, this one is the transcript of how it got there.
              //
              // Its own row rather than a hidden developer gesture: it records
              // what you listen to, so it should be as easy to find, turn off
              // and delete as it is to switch on.
              const _ActivityLogRow(),
              _NavRow(
                icon: Icons.bug_report_outlined,
                tint: const Color(0xFF9FA8DA),
                title: "Export diagnostics",
                subtitle: "Build, device and playback state — for bug reports",
                onTap: () => showDiagnosticsSheet(context),
              ),
            ]),

            // Updates get their own section rather than one buried row. The
            // single "Check for Updates" row gave no way to see WHEN it last
            // checked, no way to stop the launch check, and no way to read what
            // changed after installing.
            _section("Updates", [
              const _UpdateCheckRow(),
              const _SectionDivider(),
              _NavRow(
                icon: Icons.article_outlined,
                tint: const Color(0xFFCE93D8),
                title: "What's new",
                subtitle: "Release notes for this and earlier versions",
                onTap: () => Navigator.push(
                    context, MainLayout.smoothRoute(const ChangelogPage())),
              ),
              const _SectionDivider(),
              const _UpdateTogglesBlock(),
            ]),

            // Bottom padding for the mini-player.
            const SliverToBoxAdapter(child: SizedBox(height: 130)),
          ],
        ),
      ),
    );
  }

  Widget _buildHeaderBar(BuildContext context) {
    return SliverAppBar(
      pinned: true,
      backgroundColor: Colors.transparent,
      elevation: 0,
      expandedHeight: 108,
      leading: IconButton(
        icon: const Icon(Icons.arrow_back_rounded, color: Colors.white),
        onPressed: () => Navigator.of(context).maybePop(),
      ),
      flexibleSpace: LayoutBuilder(builder: (context, constraints) {
        final double topPad = MediaQuery.of(context).padding.top;
        final double collapsedH = kToolbarHeight + topPad;
        final double t =
            ((constraints.maxHeight - collapsedH) / (108 - collapsedH)).clamp(0.0, 1.0);
        return Stack(fit: StackFit.expand, children: [
          // Scrim so the pinned bar stays readable once content scrolls under.
          Opacity(
            opacity: 1.0 - t,
            child: Container(color: Colors.black.withOpacity(0.55)),
          ),
          // Large title that settles into the toolbar as you scroll.
          Padding(
            padding: EdgeInsets.only(
                left: 20 + (36 * (1 - t)), bottom: 14 + (2 * t), top: topPad),
            child: Align(
              alignment: Alignment.bottomLeft,
              child: Text(
                "Settings",
                style: TextStyle(
                  color: Colors.white,
                  fontSize: 20 + (8 * t),
                  fontWeight: FontWeight.w800,
                  letterSpacing: -0.5,
                ),
              ),
            ),
          ),
        ]);
      }),
    );
  }

  Widget _section(String label, List<Widget> children) {
    // Filtered here rather than at every call site, so a new section is
    // searchable the moment it is added instead of only if someone remembers.
    if (!_matches(label)) return const SliverToBoxAdapter(child: SizedBox.shrink());
    return SliverToBoxAdapter(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 24, 16, 0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.only(left: 8, bottom: 10),
              child: Text(
                label.toUpperCase(),
                style: TextStyle(
                  color: Colors.white.withOpacity(0.66),
                  fontSize: 11,
                  fontWeight: FontWeight.w800,
                  letterSpacing: 1.4,
                ),
              ),
            ),
            Container(
              width: double.infinity,
              decoration: BoxDecoration(
                color: Colors.white.withOpacity(0.045),
                borderRadius: BorderRadius.circular(20),
                border: Border.all(color: Colors.white.withOpacity(0.055)),
              ),
              child: Column(children: children),
            ),
          ],
        ),
      ),
    );
  }
}

// Shared building blocks
//
// The definitions now live in `widgets/settings_kit.dart` so sub-pages can be
// their own files (Privacy, Theme, Stream sources) instead of being forced into
// this one for access to private widgets. These aliases keep every existing call
// site in this file unchanged — the move is purely where the code lives.

typedef _SectionDivider = SettingsDivider;
typedef _IconChip = SettingsIconChip;
typedef _ToggleRow = SettingsToggleRow;
typedef _NavRow = SettingsNavRow;

// Appearance

// Playback

class _PlaybackToggles extends ConsumerWidget {
  const _PlaybackToggles();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // One record select — rebuilds ONLY when one of these six fields changes,
    // never on position/queue writes.
    final s = ref.watch(playerProvider.select((p) => (
          gapless: p.gaplessPlayback,
          crossfade: p.crossfadeEnabled,
          crossfadeSecs: p.crossfadeDuration.inSeconds,
          normalize: p.audioNormalizationEnabled,
          processVideos: p.processVideosEnabled,
          autoConnect: p.autoPlayOnConnect,
        )));
    final themeColor = ref.watch(themeProvider);
    final notifier = ref.read(playerProvider.notifier);

    return Column(children: [
      const _AutoplayRow(),
      const _SectionDivider(),
      _ToggleRow(
        icon: Icons.all_inclusive_rounded,
        tint: const Color(0xFF80CBC4),
        title: "Gapless Playback",
        subtitle: "No silence between tracks",
        value: s.gapless,
        onChanged: (_) => notifier.toggleGaplessPlayback(),
      ),
      const _SectionDivider(),
      _ToggleRow(
        icon: Icons.graphic_eq_rounded,
        tint: const Color(0xFFFFD54F),
        title: "Crossfade",
        subtitle: "Smooth transitions (${s.crossfadeSecs}s)",
        value: s.crossfade,
        onChanged: (_) => notifier.toggleCrossfade(),
      ),
      if (s.crossfade)
        Padding(
          padding: const EdgeInsets.only(left: 48, right: 8),
          child: SliderTheme(
            data: SliderTheme.of(context).copyWith(
              trackHeight: 3,
              thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 7),
              overlayShape: const RoundSliderOverlayShape(overlayRadius: 14),
            ),
            child: Slider(
              value: s.crossfadeSecs.toDouble(),
              min: 1,
              max: 12,
              divisions: 11,
              activeColor: themeColor,
              inactiveColor: Colors.white.withOpacity(0.12),
              label: "${s.crossfadeSecs}s",
              onChanged: (val) =>
                  notifier.setCrossfadeDuration(Duration(seconds: val.toInt())),
            ),
          ),
        ),
      const _SectionDivider(),
      _ToggleRow(
        icon: Icons.equalizer_rounded,
        tint: const Color(0xFFA5D6A7),
        title: "Normalize Volume",
        subtitle: "Consistent loudness across tracks",
        value: s.normalize,
        onChanged: (_) => notifier.toggleAudioNormalization(),
      ),
      // "Audio-Only Mode" and "Hide Shorts" were REMOVED
      //
      // Audio-only is no longer a mode, it is how the app works: every result is
      // the audio version, so there is nothing to switch and nothing to explain.
      // A setting whose only correct value is ON is not a choice, it is a
      // question the app should have answered itself.
      //
      // "Hide Shorts" went with it for the same reason it was already
      // conditional: a Short IS a video, so with videos gone it was a control
      // that provably did nothing.
      const _SectionDivider(),
      _ToggleRow(
        icon: Icons.headset_rounded,
        tint: const Color(0xFFCE93D8),
        title: "Play on Device Connect",
        // Narrowed wording. Auvy now ALWAYS resumes when a headset that
        // interrupted playback reconnects (within 10 min) — that needs no
        // setting, it is just continuity. This toggle is the stronger,
        // opt-in behaviour: start playing on ANY connection, even when you
        // paused deliberately.
        subtitle: "Always start playing on connect, even if you paused",
        value: s.autoConnect,
        onChanged: (val) => notifier.setAutoPlayOnConnect(val),
      ),
      const _SectionDivider(),
      const _ExternalPlayRow(),
      // Lyric size, centring, romanisation and share-line count MOVED to
      // Appearance. They are all about how lyrics LOOK and read, which is the
      // same kind of decision as the accent colour and the slider style — and
      // they were sitting in a Playback section next to headset behaviour, which
      // is where you look for what the app DOES.
    ]);
  }
}

/// Entry point for Settings → Lyrics → Romanization.
///
/// Stateful for the same reason the Privacy row's host is: the summary is built
/// from a STATIC on [ListeningPolicy], so it has to be refreshed when the sub-page
/// pops rather than watched.
class RomanizationNavRow extends ConsumerStatefulWidget {
  const RomanizationNavRow();

  @override
  ConsumerState<RomanizationNavRow> createState() =>
      RomanizationNavRowState();
}

class RomanizationNavRowState extends ConsumerState<RomanizationNavRow> {
  @override
  Widget build(BuildContext context) {
    final on = ListeningPolicy.romanizeScripts;
    return _NavRow(
      icon: Icons.translate_rounded,
      tint: const Color(0xFF9FA8DA),
      title: "Romanization",
      subtitle: on.isEmpty
          ? "Read non-Latin lyrics in Latin letters"
          // Name what's on rather than counting it: "2 enabled" makes you open
          // the page to find out which two.
          : on.map((s) => s.label).join(' · '),
      onTap: () async {
        await Navigator.push(
            context, MainLayout.smoothRoute(const RomanizationPage()));
        if (mounted) setState(() {});
      },
    );
  }
}

/// Lyrics alignment. Its own stateful widget for the same reason
/// [_ExternalPlayRow] is: the value lives in a STATIC on [ListeningPolicy], not
/// in a provider, so nothing would rebuild the switch and it would look stuck.
class CentreLyricsRow extends ConsumerStatefulWidget {
  const CentreLyricsRow();

  @override
  ConsumerState<CentreLyricsRow> createState() => CentreLyricsRowState();
}

class CentreLyricsRowState extends ConsumerState<CentreLyricsRow> {
  @override
  Widget build(BuildContext context) {
    return _ToggleRow(
      icon: Icons.format_align_center_rounded,
      tint: const Color(0xFF9FA8DA),
      title: "Centre lyrics",
      subtitle: "Centred like a sleeve, or left-aligned for long lines",
      value: ListeningPolicy.lyricsCentered,
      onChanged: (v) {
        setState(() => ListeningPolicy.lyricsCentered = v);
        ListeningPolicy.setLyricsCentered(v);
      },
    );
  }
}

/// How many lyric lines a shared card may carry.
///
/// Capped at 10, not unlimited: the card is a fixed 9:16, so each extra line
/// shrinks the type, and past ten a quote is unreadable at the size a story is
/// actually viewed at. The limit is a real constraint, so the control shows it
/// rather than letting you discover it by hitting a wall.
class LyricShareLinesRow extends ConsumerStatefulWidget {
  const LyricShareLinesRow();
  @override
  ConsumerState<LyricShareLinesRow> createState() =>
      LyricShareLinesRowState();
}

class LyricShareLinesRowState extends ConsumerState<LyricShareLinesRow> {
  @override
  Widget build(BuildContext context) {
    final themeColor = ref.watch(themeProvider);
    final value = ListeningPolicy.lyricShareMaxLines;
    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 8),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          const _IconChip(
              icon: Icons.format_quote_rounded, tint: Color(0xFF80DEEA)),
          const SizedBox(width: 12),
          const Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text("Lyric lines per share",
                    style: TextStyle(
                        color: Colors.white,
                        fontSize: 14.5,
                        fontWeight: FontWeight.w600)),
                SizedBox(height: 2),
                Text("Most you can select when sharing lyrics",
                    style: TextStyle(color: Colors.white38, fontSize: 11.5)),
              ],
            ),
          ),
          Text('$value',
              style: TextStyle(
                  color: themeColor,
                  fontSize: 15,
                  fontWeight: FontWeight.w800)),
        ]),
        Slider(
          value: value.toDouble(),
          min: 1,
          max: 10,
          divisions: 9,
          activeColor: themeColor,
          label: '$value',
          onChanged: (v) =>
              setState(() => ListeningPolicy.lyricShareMaxLines = v.round()),
          onChangeEnd: (v) => ListeningPolicy.setLyricShareMaxLines(v.round()),
        ),
      ]),
    );
  }
}

/// Lyric type size on the player's lyrics face.
///
/// Shown as a PERCENTAGE rather than a point size, because the control scales
/// three related sizes at once (active line, inactive lines, translation) — see
/// [ListeningPolicy.lyricTextScale]. A number like "18pt" would imply it sets one
/// of them.
class LyricTextScaleRow extends ConsumerStatefulWidget {
  const LyricTextScaleRow();

  @override
  ConsumerState<LyricTextScaleRow> createState() => LyricTextScaleRowState();
}

class LyricTextScaleRowState extends ConsumerState<LyricTextScaleRow> {
  @override
  Widget build(BuildContext context) {
    final themeColor = ref.watch(themeProvider);
    final value = ListeningPolicy.lyricTextScale;
    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 8),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          const _IconChip(
              icon: Icons.format_size_rounded, tint: Color(0xFF9FA8DA)),
          const SizedBox(width: 12),
          const Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text("Lyrics size",
                    style: TextStyle(
                        color: Colors.white,
                        fontSize: 14.5,
                        fontWeight: FontWeight.w600)),
                SizedBox(height: 2),
                Text("Type size on the player's lyrics view",
                    style: TextStyle(color: Colors.white38, fontSize: 11.5)),
              ],
            ),
          ),
          Text('${(value * 100).round()}%',
              style: TextStyle(
                  color: themeColor,
                  fontSize: 15,
                  fontWeight: FontWeight.w800)),
        ]),
        Slider(
          value: value,
          min: 0.8,
          max: 1.4,
          // 0.05 steps: finer than this and the difference between neighbouring
          // stops is invisible, so the slider would feel unresponsive.
          divisions: 12,
          activeColor: themeColor,
          label: '${(value * 100).round()}%',
          onChanged: (v) => setState(() => ListeningPolicy.lyricTextScale = v),
          onChangeEnd: (v) => ListeningPolicy.setLyricTextScale(v),
        ),
      ]),
    );
  }
}

/// The hard switch for misrouted media buttons.
///
/// A MULTIPOINT Bluetooth headset paired to a phone AND a computer forwards its
/// transport keys over both links: pressing play on the computer also tells the
/// phone to play. Android routes that to whichever app owns the most recent
/// media session, and on Android 11+ it will restart that app's service to
/// deliver it, so Auvy appears to launch and start playing by itself.
///
/// `AuvyAudioHandler` already refuses the most obvious cases (nothing loaded,
/// another app already playing here, long-idle and off-screen), but Android
/// exposes no way to know a key was misrouted, so those are heuristics. This row
/// is the certain answer for someone who knows their hardware does it.

/// The activity-log switch, plus export and delete.
///
/// Three controls, NOT one, because of what it records.
///
/// The transcript contains what you listened to and when. That is exactly the
/// data the LISTENING DATA switches elsewhere in this screen exist to govern, so
/// a recorder with only an on/off would be inconsistent with the rest of the app:
/// whoever can turn it on has to be able to read what it holds and destroy it,
/// in the same place, without hunting.
///
/// Export writes to Download/Auvy through the same MediaStore path the library
/// backup uses — a real file a file manager can see, rather than app-private
/// storage that reports success and then cannot be found (the bug that path was
/// built to fix).
class _ActivityLogRow extends ConsumerStatefulWidget {
  const _ActivityLogRow();
  @override
  ConsumerState<_ActivityLogRow> createState() => _ActivityLogRowState();
}

class _ActivityLogRowState extends ConsumerState<_ActivityLogRow> {
  int _bytes = 0;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _refreshSize();
  }

  Future<void> _refreshSize() async {
    final n = await ActivityLog.instance.sizeOnDisk();
    if (mounted) setState(() => _bytes = n);
  }

  String get _size {
    if (_bytes <= 0) return 'nothing recorded yet';
    if (_bytes < 1024) return '$_bytes B recorded';
    if (_bytes < 1024 * 1024) return '${(_bytes / 1024).toStringAsFixed(0)} KB recorded';
    return '${(_bytes / (1024 * 1024)).toStringAsFixed(1)} MB recorded';
  }

  Future<void> _export() async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      final bytes = await ActivityLog.instance.exportBytes();
      final name = ActivityLog.instance.exportFilename();
      final path = await LibraryExportService.instance.saveDiagnosticFile(name, bytes);
      if (!mounted) return;
      AnimatedToast.show(context,
          text: path == null ? "Couldn't save the log" : 'Saved to $path',
          icon: path == null ? Icons.error_outline : Icons.save_alt_rounded,
          color: path == null ? Colors.orange : ref.read(themeProvider));
    } catch (e) {
      if (!mounted) return;
      AnimatedToast.show(context,
          text: "Couldn't save the log",
          icon: Icons.error_outline,
          color: Colors.orange);
    } finally {
      if (mounted) setState(() => _busy = false);
      _refreshSize();
    }
  }

  @override
  Widget build(BuildContext context) {
    final on = ActivityLog.instance.isEnabled;
    final accent = ref.watch(themeProvider);
    return Column(
      children: [
        _ToggleRow(
          icon: Icons.timeline_rounded,
          tint: const Color(0xFF9FA8DA),
          title: 'Record activity log',
          subtitle: on
              ? 'Keeping a timestamped transcript · $_size'
              : 'Off — turn on to capture a timeline for bug reports',
          value: on,
          onChanged: (v) async {
            await ActivityLog.instance.setEnabled(v);
            if (mounted) setState(() {});
            _refreshSize();
          },
        ),
        // Only offered when there is something to act on, so the row does not
        // advertise actions that would do nothing.
        if (_bytes > 0)
          Padding(
            padding: const EdgeInsets.only(left: 56, right: 16, bottom: 10),
            child: Row(
              children: [
                TextButton.icon(
                  onPressed: _busy ? null : _export,
                  icon: const Icon(Icons.save_alt_rounded, size: 17),
                  label: Text(_busy ? 'Saving…' : 'Export'),
                  style: TextButton.styleFrom(foregroundColor: accent),
                ),
                const SizedBox(width: 4),
                TextButton.icon(
                  onPressed: _busy
                      ? null
                      : () async {
                          await ActivityLog.instance.clear();
                          // This `context` belongs to the row's builder, not to
                          // the State, so the State's `mounted` alone does not
                          // vouch for it. See the same pairing in playlist_page.
                          if (!mounted || !context.mounted) return;
                          _refreshSize();
                          AnimatedToast.show(context,
                              text: 'Activity log deleted',
                              icon: Icons.delete_outline_rounded,
                              color: accent);
                        },
                  icon: const Icon(Icons.delete_outline_rounded, size: 17),
                  label: const Text('Delete'),
                  style: TextButton.styleFrom(foregroundColor: Colors.white54),
                ),
              ],
            ),
          ),
      ],
    );
  }
}
class _ExternalPlayRow extends ConsumerStatefulWidget {
  const _ExternalPlayRow();
  @override
  ConsumerState<_ExternalPlayRow> createState() => _ExternalPlayRowState();
}

class _ExternalPlayRowState extends ConsumerState<_ExternalPlayRow> {
  @override
  Widget build(BuildContext context) {
    return _ToggleRow(
      icon: Icons.headset_mic_rounded,
      tint: const Color(0xFF9FA8DA),
      title: "Start from headset button",
      subtitle: "Off if your Bluetooth headset also starts Auvy from another device",
      value: ListeningPolicy.allowExternalPlayStart,
      onChanged: (v) async {
        await ListeningPolicy.setAllowExternalPlayStart(v);
        if (mounted) setState(() {});
      },
    );
  }
}

/// ListenBrainz scrobbling — paste a user token to switch it on.
///
/// Sits in the LISTENING DATA section, not with the streaming/account rows: it is
/// the only feature in Auvy that sends your listening history off the device, so
/// it belongs beside the switches that govern what gets recorded at all. It also
/// obeys them — pausing listening history stops scrobbling (see the submit call
/// in player_system).
///
/// The token is VALIDATED before it is stored. A silently-wrong token would look
/// identical to a working one — nothing visible happens either way, so the check
/// is the only honest way to confirm the feature is on.
class _ScrobbleRow extends ConsumerStatefulWidget {
  const _ScrobbleRow();
  @override
  ConsumerState<_ScrobbleRow> createState() => _ScrobbleRowState();
}

class _ScrobbleRowState extends ConsumerState<_ScrobbleRow> {
  String? _user;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  Future<void> _refresh() async {
    final t = await ScrobbleService.instance.readToken();
    if (!mounted) return;
    setState(() => _user = (t == null || t.isEmpty) ? null : 'Connected');
  }

  Future<void> _edit() async {
    final controller = TextEditingController(
        text: await ScrobbleService.instance.readToken() ?? '');
    if (!mounted) return;
    final action = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        // Surface/shape/typography come from ThemeData.dialogTheme. See main.dart.
        title: const Text('ListenBrainz token',
            style: TextStyle(color: Colors.white, fontSize: 17)),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Scrobble what you play to your own ListenBrainz history. '
              'Find your token at listenbrainz.org → Settings.',
              style: TextStyle(
                  color: Colors.white.withOpacity(0.72), fontSize: 12.5),
            ),
            const SizedBox(height: 14),
            TextField(
              controller: controller,
              autofocus: true,
              style: const TextStyle(color: Colors.white, fontSize: 14),
              decoration: InputDecoration(
                hintText: 'Paste token',
                hintStyle: TextStyle(color: Colors.white.withOpacity(0.55)),
                filled: true,
                fillColor: Colors.white.withOpacity(0.06),
                border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(10),
                    borderSide: BorderSide.none),
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, 'disconnect'),
              child: const Text('Disconnect',
                  style: TextStyle(color: Colors.redAccent))),
          TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: Text('Cancel',
                  style: TextStyle(color: Colors.white.withOpacity(0.78)))),
          TextButton(
              onPressed: () => Navigator.pop(ctx, controller.text),
              child: const Text('Save')),
        ],
      ),
    );
    if (action == null || !mounted) return;

    if (action == 'disconnect') {
      await ScrobbleService.instance.setToken(null);
      await _refresh();
      return;
    }

    setState(() => _busy = true);
    final name = await ScrobbleService.instance.validate(action);
    if (!mounted) return;
    if (name == null) {
      setState(() => _busy = false);
      AnimatedToast.message('That token was rejected');
      return;
    }
    await ScrobbleService.instance.setToken(action);
    if (!mounted) return;
    setState(() {
      _busy = false;
      _user = name.isEmpty ? 'Connected' : name;
    });
    AnimatedToast.message('Scrobbling as $name');
  }

  @override
  Widget build(BuildContext context) {
    return _NavRow(
      icon: Icons.cloud_upload_outlined,
      tint: const Color(0xFFEBA13F),
      title: 'ListenBrainz',
      subtitle: _busy
          ? 'Checking token…'
          : (_user == null
              ? 'Off — scrobble your listens to an open history'
              : 'Scrobbling as $_user'),
      onTap: _busy ? () {} : _edit,
    );
  }
}

// NOTE: the "Hide Shorts" row was removed with "Audio-Only Mode". A Short is a
// vertical clip under a minute — usually a snippet of the real track, not the
// track, and it is a VIDEO, so with videos no longer fetched at all one can
// never reach a listing. SearchService.hideShorts stays true by default and is
// simply never contradicted.

/// Sleep timer: music pauses after the chosen number of minutes. Armed state
/// shows the exact stop time and highlights the armed duration pill; "Off"
/// cancels. Session-only (never persisted).
/// Privacy switches for what Auvy records, plus what counts as a "play".
/// Local state mirrors the [ListeningPolicy] statics (they're deliberately not
/// a provider — they're read from hot paths like the position tick).
class _ListeningPolicyBlock extends ConsumerStatefulWidget {
  const _ListeningPolicyBlock();
  @override
  ConsumerState<_ListeningPolicyBlock> createState() =>
      _ListeningPolicyBlockState();
}

class _ListeningPolicyBlockState extends ConsumerState<_ListeningPolicyBlock> {
  /// Region chooser. Returns the ISO code, '' for "follow the device", or null
  /// when dismissed without choosing.
  Future<String?> _pickRegion(BuildContext context) async {
    return showModalBottomSheet<String>(
      context: context,
      backgroundColor: const Color(0xFF17171C),
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(22)),
      ),
      builder: (ctx) => SafeArea(
        child: ConstrainedBox(
          constraints: BoxConstraints(
              maxHeight: MediaQuery.of(ctx).size.height * 0.7),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Padding(
                padding: EdgeInsets.fromLTRB(20, 18, 20, 8),
                child: Row(children: [
                  Text('Content region',
                      style: TextStyle(
                          color: Colors.white,
                          fontSize: 17,
                          fontWeight: FontWeight.w800)),
                ]),
              ),
              const Padding(
                padding: EdgeInsets.fromLTRB(20, 0, 20, 12),
                child: Text(
                    'Charts, new releases and search ranking come from this '
                    'country.',
                    style: TextStyle(color: Colors.white38, fontSize: 12.5)),
              ),
              Flexible(
                child: ListView.builder(
                  shrinkWrap: true,
                  itemCount: kRegionOptions.length,
                  itemBuilder: (ctx, i) {
                    final (code, label) = kRegionOptions[i];
                    final selected = ListeningPolicy.contentCountry == code;
                    return ListTile(
                      dense: true,
                      onTap: () => Navigator.pop(ctx, code),
                      title: Text(label,
                          style: TextStyle(
                              color: selected ? Colors.white : Colors.white70,
                              fontSize: 14.5,
                              fontWeight: selected
                                  ? FontWeight.w800
                                  : FontWeight.w500)),
                      trailing: selected
                          ? Icon(Icons.check_rounded,
                              color: ref.read(themeProvider), size: 19)
                          : null,
                    );
                  },
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final themeColor = ref.watch(themeProvider);
    final seconds = ListeningPolicy.scrobbleSeconds;
    final percent = ListeningPolicy.scrobblePercent;

    // The two "pause history" switches moved to PrivacyPage, where they sit next
    // to the clear actions that make them honest. What is left here is what the
    // section is actually named for plus the small behavioural preferences.
    return Column(children: [
      _ToggleRow(
        icon: Icons.download_for_offline_rounded,
        tint: const Color(0xFFA5D6A7),
        title: "Auto-Download Liked Songs",
        subtitle: "Save liked tracks for offline (Wi-Fi only)",
        value: ListeningPolicy.autoDownloadOnLike,
        onChanged: (v) async {
          await ListeningPolicy.setAutoDownloadOnLike(v);
          if (mounted) setState(() {});
        },
      ),
      const _SectionDivider(),
      // ignore: unused_element
      // Content region. Decides which CHARTS, "new releases" and search ranking
      // YouTube Music returns — it was hardcoded to US for everyone.
      Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
        child: Row(children: [
          const _IconChip(icon: Icons.public_rounded, tint: Color(0xFF81D4FA)),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text("Content region",
                    style: TextStyle(
                        color: Colors.white,
                        fontSize: 14.5,
                        fontWeight: FontWeight.w600)),
                const SizedBox(height: 2),
                Text(
                    ListeningPolicy.contentCountry.isEmpty
                        ? "Following your device (${ListeningPolicy.effectiveCountry})"
                        : "Charts and releases from ${ListeningPolicy.contentCountry}",
                    style: const TextStyle(color: Colors.white38, fontSize: 12)),
              ],
            ),
          ),
          const SizedBox(width: 8),
          GestureDetector(
            onTap: () async {
              final picked = await _pickRegion(context);
              if (picked == null) return;
              // '' = follow the device locale again.
              await ListeningPolicy.setRegion(country: picked);
              if (mounted) setState(() {});
            },
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
              decoration: BoxDecoration(
                color: Colors.white.withOpacity(0.08),
                borderRadius: BorderRadius.circular(11),
              ),
              child: Text(
                  ListeningPolicy.contentCountry.isEmpty
                      ? 'Auto'
                      : ListeningPolicy.contentCountry,
                  style: const TextStyle(
                      color: Colors.white,
                      fontSize: 12,
                      fontWeight: FontWeight.w800)),
            ),
          ),
        ]),
      ),
      const _SectionDivider(),
      _ToggleRow(
        icon: Icons.volume_off_rounded,
        tint: const Color(0xFFCE93D8),
        title: "Pause when muted",
        subtitle: "Stop playback when volume reaches zero",
        value: ListeningPolicy.pauseOnMute,
        onChanged: (v) async {
          await ListeningPolicy.setPauseOnMute(v);
          if (mounted) setState(() {});
        },
      ),
      const _SectionDivider(),
      _ToggleRow(
        icon: Icons.lightbulb_outline_rounded,
        tint: const Color(0xFFFFF176),
        title: "Keep screen on",
        subtitle: "Don't let the screen sleep while Auvy is open",
        value: ListeningPolicy.keepScreenOn,
        onChanged: (v) async {
          await ListeningPolicy.setKeepScreenOn(v);
          if (mounted) setState(() {});
        },
      ),
      const _SectionDivider(),
      // Which tab the app opens on. Someone who lives in their own library
      // shouldn't have to tap past a recommendation feed every launch.
      Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
        child: Row(children: [
          const _IconChip(
              icon: Icons.launch_rounded, tint: Color(0xFF90CAF9)),
          const SizedBox(width: 12),
          const Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text("Open on",
                    style: TextStyle(
                        color: Colors.white,
                        fontSize: 14.5,
                        fontWeight: FontWeight.w600)),
                SizedBox(height: 2),
                Text("Which tab Auvy starts on",
                    style: TextStyle(color: Colors.white38, fontSize: 12)),
              ],
            ),
          ),
          for (final entry in const [(0, 'Home'), (1, 'Search'), (2, 'Library')])
            Padding(
              padding: const EdgeInsets.only(left: 6),
              child: GestureDetector(
                onTap: () async {
                  await ListeningPolicy.setDefaultOpenTab(entry.$1);
                  if (mounted) setState(() {});
                },
                child: Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                  decoration: BoxDecoration(
                    color: ListeningPolicy.defaultOpenTab == entry.$1
                        ? const Color(0xFF90CAF9)
                        : Colors.white.withOpacity(0.07),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Text(entry.$2,
                      style: TextStyle(
                          color: ListeningPolicy.defaultOpenTab == entry.$1
                              ? Colors.black
                              : Colors.white60,
                          fontSize: 11.5,
                          fontWeight: FontWeight.w800)),
                ),
              ),
            ),
        ]),
      ),
      const _SectionDivider(),
      // How much of a track must be heard before it counts. Whichever of the
      // two limits comes FIRST wins, so a 2-minute track can still count.
      Padding(
        padding: const EdgeInsets.fromLTRB(16, 14, 16, 6),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            const _IconChip(
                icon: Icons.timer_outlined, tint: Color(0xFFFFF59D)),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text("Counts As A Play",
                      style: TextStyle(
                          color: Colors.white,
                          fontSize: 15,
                          fontWeight: FontWeight.w600)),
                  const SizedBox(height: 2),
                  Text(
                    "After ${seconds}s or ${(percent * 100).round()}% of the track "
                    "— whichever is first",
                    style: TextStyle(
                        color: Colors.white.withOpacity(0.72), fontSize: 12),
                  ),
                ],
              ),
            ),
          ]),
          const SizedBox(height: 6),
          Slider(
            value: seconds.toDouble(),
            min: 5,
            max: 120,
            divisions: 23,
            activeColor: themeColor,
            label: "${seconds}s",
            onChanged: (v) => setState(() {
              ListeningPolicy.scrobbleSeconds = v.round();
            }),
            onChangeEnd: (v) => ListeningPolicy.setScrobbleSeconds(v.round()),
          ),
          Slider(
            value: percent,
            min: 0.1,
            max: 1.0,
            divisions: 9,
            activeColor: themeColor,
            label: "${(percent * 100).round()}%",
            onChanged: (v) => setState(() {
              ListeningPolicy.scrobblePercent = v;
            }),
            onChangeEnd: (v) => ListeningPolicy.setScrobblePercent(v),
          ),
        ]),
      ),
    ]);
  }
}

/// THIS WAS A FOUR-WAY PICKER. IT IS NOW A STATUS CARD, ON PURPOSE.
///
/// Auto / High / Medium / Low asked the user to predict their own network, then
/// held them to the answer — the "High" they picked at home was still High on a
/// train, which is exactly when it stalls. Now that the app measures actual
/// throughput and counts mid-track stalls (adaptive_bitrate.dart), a manual
/// choice can only ever be worse informed than the automatic one.
///
/// DATA SAVER IS NOT REDUNDANT AND STAYS ITS OWN SETTING. It optimises for a
/// different thing: a data allowance, not smoothness. Adaptive will happily
/// spend bandwidth it can see is available, which is precisely what someone on a
/// capped plan does NOT want, so that decision remains theirs to make.
class _AudioQualityBlock extends ConsumerWidget {
  const _AudioQualityBlock();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final themeColor = ref.watch(themeProvider);
    // Read, not watched: the ladder is a transport detail kept off PlayerState
    // so it doesn't rebuild every listening widget on each resolve. It is
    // therefore accurate as of opening this page, which is all a status line
    // needs to be.
    final rung = ref.read(playerProvider.notifier).bitrateDecision;
    final ceiling = rung.ceilingBps;
    final label = ceiling == 0
        ? 'Best available'
        : '${(ceiling / 1000).round()} kbps';
    final detail = ceiling == 0
        ? 'Your connection is keeping up, so Auvy is streaming the highest '
            'quality this track offers.'
        : 'Auvy stepped down to keep the music playing without stalling. It '
            'moves back up on its own when the connection recovers.';

    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 14, 14, 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(children: [
            const _IconChip(
                icon: Icons.high_quality_rounded, tint: Color(0xFF80D8FF)),
            const SizedBox(width: 12),
            const Text("Streaming Quality",
                style: TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.w600,
                    fontSize: 14.5)),
          ]),
          const SizedBox(height: 14),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
            decoration: BoxDecoration(
              color: themeColor.withOpacity(0.12),
              borderRadius: BorderRadius.circular(14),
              border: Border.all(color: themeColor.withOpacity(0.55), width: 1.2),
            ),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(Icons.auto_awesome_rounded, color: themeColor, size: 19),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          const Text("Automatic",
                              style: TextStyle(
                                color: Colors.white,
                                fontWeight: FontWeight.w700,
                                fontSize: 13.5,
                              )),
                          const Spacer(),
                          Text(label,
                              style: TextStyle(
                                color: themeColor,
                                fontWeight: FontWeight.w700,
                                fontSize: 12.5,
                              )),
                        ],
                      ),
                      const SizedBox(height: 4),
                      Text(detail,
                          style: TextStyle(
                              color: Colors.white.withOpacity(0.72),
                              fontSize: 11,
                              height: 1.35)),
                    ],
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 8),
          Text(
            "Quality now follows your measured connection speed, so there is "
            "nothing to choose. To cap data use deliberately, turn on Data Saver.",
            style: TextStyle(
                color: Colors.white.withOpacity(0.66), fontSize: 11, height: 1.35),
          ),
        ],
      ),
    );
  }
}

class _EqBlock extends ConsumerWidget {
  const _EqBlock();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final eqEnabled = ref.watch(playerProvider.select((p) => p.eqEnabled));

    return Column(children: [
      _ToggleRow(
        icon: Icons.tune_rounded,
        tint: const Color(0xFFFFAB91),
        title: "Equalizer",
        subtitle: "Adjust audio frequencies to your liking",
        value: eqEnabled,
        onChanged: (_) => ref.read(playerProvider.notifier).toggleEq(),
      ),
      if (eqEnabled) ...[
        const SizedBox(height: 4),
        const EqBandSlider(bandIndex: 0, label: '60 Hz (Bass)'),
        const EqBandSlider(bandIndex: 1, label: '230 Hz'),
        const EqBandSlider(bandIndex: 2, label: '910 Hz (Mids)'),
        const EqBandSlider(bandIndex: 3, label: '3.6 kHz'),
        const EqBandSlider(bandIndex: 4, label: '14 kHz (Treble)'),
        const SizedBox(height: 10),
      ],
    ]);
  }
}

// Interface

class SliderStyleBlock extends ConsumerWidget {
  const SliderStyleBlock();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final currentStyle = ref.watch(sliderStyleProvider);
    final themeColor = ref.watch(themeProvider);

    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 14, 14, 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(children: [
            const _IconChip(icon: Icons.linear_scale_rounded, tint: Color(0xFF80CBC4)),
            const SizedBox(width: 12),
            const Text("Player Slider Style",
                style: TextStyle(
                    color: Colors.white, fontWeight: FontWeight.w600, fontSize: 14.5)),
          ]),
          const SizedBox(height: 14),

          // Live animated preview.
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
            decoration: BoxDecoration(
              color: Colors.black.withOpacity(0.25),
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: Colors.white.withOpacity(0.06)),
            ),
            child: Column(children: [
              Text("LIVE PREVIEW",
                  style: TextStyle(
                      color: Colors.white.withOpacity(0.55),
                      fontSize: 9,
                      letterSpacing: 2.0,
                      fontWeight: FontWeight.w800)),
              const SizedBox(height: 14),
              _SliderPreviewAnimator(style: currentStyle, themeColor: themeColor),
            ]),
          ),
          const SizedBox(height: 12),

          GridView.builder(
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
              crossAxisCount: 2,
              childAspectRatio: 3.6,
              crossAxisSpacing: 10,
              mainAxisSpacing: 10,
            ),
            itemCount: SliderStyle.values.length,
            itemBuilder: (context, index) {
              final style = SliderStyle.values[index];
              final isSelected = style == currentStyle;

              return GestureDetector(
                onTap: () {
                  HapticService.selection();
                  ref.read(sliderStyleProvider.notifier).setStyle(style);
                },
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 180),
                  decoration: BoxDecoration(
                    color: isSelected ? themeColor.withOpacity(0.12) : Colors.white.withOpacity(0.04),
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(
                      color: isSelected ? themeColor : Colors.transparent,
                      width: 1.2,
                    ),
                  ),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(
                        isSelected ? Icons.check_circle_rounded : Icons.circle_outlined,
                        color: isSelected ? themeColor : Colors.white30,
                        size: 15,
                      ),
                      const SizedBox(width: 8),
                      Text(
                        style.name.toUpperCase(),
                        style: TextStyle(
                          color: isSelected ? themeColor : Colors.white70,
                          fontWeight: isSelected ? FontWeight.w800 : FontWeight.w500,
                          fontSize: 10.5,
                          letterSpacing: 1.0,
                        ),
                      ),
                    ],
                  ),
                ),
              );
            },
          ),
        ],
      ),
    );
  }
}

// Data & Storage

class _DataSaverBlock extends ConsumerWidget {
  const _DataSaverBlock();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final connectivity = ref.watch(connectivityProvider);
    final themeColor = ref.watch(themeProvider);

    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 14, 14, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const _IconChip(icon: Icons.data_saver_on_rounded, tint: Color(0xFFA5D6A7)),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text("Data Saver",
                        style: TextStyle(
                            color: Colors.white, fontWeight: FontWeight.w600, fontSize: 14.5)),
                    const SizedBox(height: 2),
                    Text(
                      connectivity.isOffline
                          ? "No internet connection"
                          : "Connected via ${connectivity.isWifi ? 'WiFi' : 'Mobile Data'}",
                      style: TextStyle(
                          color: Colors.white.withOpacity(0.66), fontSize: 11.5),
                    ),
                  ],
                ),
              ),
              Icon(
                connectivity.isOffline ? Icons.signal_wifi_off_rounded : Icons.wifi_rounded,
                color: connectivity.isOffline ? Colors.redAccent : const Color(0xFFA5D6A7),
                size: 18,
              ),
            ],
          ),
          const SizedBox(height: 12),
          _DataSaverOption(
            label: "Off",
            subtitle: "Use data freely",
            isSelected: connectivity.dataSaverMode == DataSaverMode.off,
            icon: Icons.cloud_done_rounded,
            onTap: () =>
                ref.read(connectivityProvider.notifier).setDataSaverMode(DataSaverMode.off),
            themeColor: themeColor,
          ),
          _DataSaverOption(
            label: "WiFi Only",
            subtitle: "Limit usage on mobile data",
            isSelected: connectivity.dataSaverMode == DataSaverMode.wifi,
            icon: Icons.wifi_rounded,
            onTap: () =>
                ref.read(connectivityProvider.notifier).setDataSaverMode(DataSaverMode.wifi),
            themeColor: themeColor,
          ),
          _DataSaverOption(
            label: "Always",
            subtitle: "Minimize data usage everywhere",
            isSelected: connectivity.dataSaverMode == DataSaverMode.always,
            icon: Icons.data_saver_on_rounded,
            onTap: () => ref
                .read(connectivityProvider.notifier)
                .setDataSaverMode(DataSaverMode.always),
            themeColor: themeColor,
          ),
        ],
      ),
    );
  }
}

class _UsageBlock extends ConsumerWidget {
  const _UsageBlock();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final stats = ref.watch(dataUsageProvider);
    final themeColor = ref.watch(themeProvider);

    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
      child: Column(
        children: [
          Row(children: [
            const _IconChip(icon: Icons.donut_small_rounded, tint: Color(0xFFFFCC80)),
            const SizedBox(width: 12),
            const Expanded(
              child: Text("Session Data Usage",
                  style: TextStyle(
                      color: Colors.white, fontWeight: FontWeight.w600, fontSize: 14.5)),
            ),
            TextButton(
              onPressed: () {
                ref.read(dataUsageProvider.notifier).reset();
                AnimatedToast.show(context,
                    text: "Stats reset", icon: Icons.refresh, color: themeColor);
              },
              style: TextButton.styleFrom(
                foregroundColor: themeColor,
                padding: const EdgeInsets.symmetric(horizontal: 10),
                minimumSize: const Size(0, 32),
              ),
              child: const Text("Reset", style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700)),
            ),
          ]),
          const SizedBox(height: 10),
          // Named for what it actually measures.
          //
          // It was labelled "Total Data Used", which it is not: audio streaming
          // is done by the native player and never passes through the Dart
          // client this counts, so the real figure is far higher. Cover art was
          // missing too until it was routed through the tracked client — that
          // one is fixed, streaming cannot be, so the label has to be honest
          // rather than the number pretending to be complete. A figure the user
          // can trust for what it covers beats a total that is quietly wrong.
          _RowStat("App data this session", "${stats.totalMB} MB"),
          Divider(color: Colors.white.withOpacity(0.06), height: 20),
          _RowStat(
              "Artwork",
              "${((stats.bytesByCategory['artwork'] ?? 0) / (1024 * 1024)).toStringAsFixed(2)} MB"),
          Divider(color: Colors.white.withOpacity(0.06), height: 20),
          _RowStat("Session Requests", "${stats.requestCount}"),
          const SizedBox(height: 8),
          Text(
            "Covers, lyrics and metadata. Music streaming is handled by the "
            "system player and is not included here.",
            style: TextStyle(
                color: Colors.white.withOpacity(0.45), fontSize: 10.5, height: 1.35),
          ),
        ],
      ),
    );
  }
}

class _CacheBlock extends ConsumerWidget {
  const _CacheBlock();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final cacheManager = AudioCacheManager();
    final stats = cacheManager.getCacheStats();
    final currentLimit = ref.watch(playerProvider.select((s) => s.maxCacheSizeMB));
    final themeColor = ref.watch(themeProvider);

    // The limit cannot be dragged below the space the cache already holds — that
    // setting would be violated the moment it was made, and honouring it would
    // mean deleting tracks the user never asked to lose. Kept 100 MB below the
    // ceiling so the control always has somewhere left to travel.
    final cachedFloorMB = cacheManager.autoCacheFloorMB();
    final double sliderMin =
        cachedFloorMB <= 100 ? 100 : cachedFloorMB.clamp(100, 1900).toDouble();

    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(children: [
            const _IconChip(icon: Icons.sd_storage_rounded, tint: Color(0xFF90CAF9)),
            const SizedBox(width: 12),
            const Text("Storage & Cache",
                style: TextStyle(
                    color: Colors.white, fontWeight: FontWeight.w600, fontSize: 14.5)),
          ]),
          const SizedBox(height: 12),
          _RowStat("Cached Tracks", "${stats['cachedTracks']}"),
          Divider(color: Colors.white.withOpacity(0.06), height: 20),
          _RowStat("Storage Used", "${stats['totalSizeMB']} / $currentLimit MB"),
          const SizedBox(height: 14),
          Text("Cache Size Limit",
              style: TextStyle(
                  color: Colors.white.withOpacity(0.75),
                  fontSize: 12.5,
                  fontWeight: FontWeight.w600)),
          SliderTheme(
            data: SliderTheme.of(context).copyWith(
              trackHeight: 3,
              thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 7),
              overlayShape: const RoundSliderOverlayShape(overlayRadius: 14),
            ),
            child: Slider(
              // Clamped so the thumb can't sit outside its own track after the
              // floor rises — Slider asserts on a value below `min`.
              value: currentLimit.toDouble().clamp(sliderMin, 2000),
              min: sliderMin,
              max: 2000, // 2GB
              // One stop per 100 MB across whatever range is left, so the steps
              // stay round numbers as the floor moves.
              divisions: ((2000 - sliderMin) / 100).round().clamp(1, 19),
              activeColor: themeColor,
              inactiveColor: Colors.white.withOpacity(0.12),
              label: "$currentLimit MB",
              onChanged: (val) =>
                  ref.read(playerProvider.notifier).setCacheLimit(val.toInt()),
            ),
          ),
          // Says WHY the slider stops where it does. Without this the floor just
          // reads as a broken control.
          if (sliderMin > 100)
            Padding(
              padding: const EdgeInsets.only(top: 2),
              child: Text(
                "Can't go below the ${cachedFloorMB} MB already cached — "
                "clear the cache to free it",
                style: TextStyle(
                    color: Colors.white.withOpacity(0.66), fontSize: 11.5),
              ),
            ),
          const SizedBox(height: 8),
          Row(children: [
            Expanded(
              child: _PillButton(
                icon: Icons.delete_sweep_rounded,
                label: "Clear Cache",
                onTap: () {
                  HapticService.medium();
                  cacheManager.clearAllCache();
                  AnimatedToast.show(context,
                      text: "Cache cleared (Downloads kept)",
                      icon: Icons.cleaning_services,
                      color: themeColor);
                },
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: _PillButton(
                icon: Icons.folder_open_rounded,
                label: "Scan Device",
                onTap: () async {
                  AnimatedToast.show(context,
                      text: "Scanning device…", icon: Icons.search, color: themeColor);
                  final n =
                      await ref.read(libraryProvider.notifier).importDeviceDownloads();
                  if (context.mounted) {
                    AnimatedToast.show(
                      context,
                      text: n > 0 ? "Imported $n track(s) from device" : "No new tracks found",
                      icon: n > 0 ? Icons.library_music : Icons.info_outline,
                      color: themeColor,
                    );
                  }
                },
              ),
            ),
          ]),
        ],
      ),
    );
  }
}

class _PillButton extends StatelessWidget {
  final IconData icon;
  final String label;
  final VoidCallback onTap;
  const _PillButton({required this.icon, required this.label, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        height: 44,
        decoration: BoxDecoration(
          color: Colors.white.withOpacity(0.07),
          borderRadius: BorderRadius.circular(13),
          border: Border.all(color: Colors.white.withOpacity(0.07)),
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(icon, color: Colors.white70, size: 17),
            const SizedBox(width: 7),
            Text(label,
                style: const TextStyle(
                    color: Colors.white, fontSize: 12.5, fontWeight: FontWeight.w600)),
          ],
        ),
      ),
    );
  }
}

// Account

class _AccountBlock extends ConsumerWidget {
  const _AccountBlock();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final accountState = ref.watch(accountProvider);
    final themeColor = ref.watch(themeProvider);

    if (!accountState.isLoggedIn) {
      return Padding(
        padding: const EdgeInsets.all(14),
        child: Row(children: [
          const _IconChip(icon: Icons.person_off_rounded, tint: Color(0xFFB0BEC5)),
          const SizedBox(width: 12),
          Text("No accounts connected.",
              style: TextStyle(color: Colors.white.withOpacity(0.72), fontSize: 13)),
        ]),
      );
    }

    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 14, 14, 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(children: [
            const _IconChip(icon: Icons.account_circle_rounded, tint: Color(0xFF80D8FF)),
            const SizedBox(width: 12),
            const Expanded(
              child: Text("Primary Display Profile",
                  style: TextStyle(
                      color: Colors.white, fontWeight: FontWeight.w600, fontSize: 14.5)),
            ),
          ]),
          const SizedBox(height: 4),
          Padding(
            padding: const EdgeInsets.only(left: 46),
            child: Text("Choose which profile to show as your main avatar and name.",
                style: TextStyle(color: Colors.white.withOpacity(0.66), fontSize: 11.5)),
          ),
          const SizedBox(height: 14),

          if (accountState.youtube != null)
            _ProfileOption(
              label: "YouTube",
              username: accountState.youtube!.displayName,
              icon: Icons.play_circle_fill_rounded,
              // Selected if YouTube is explicitly chosen, or if nothing is chosen and Discord isn't connected
              isSelected: accountState.preferredPrimary == AccountType.youtube ||
                  (accountState.preferredPrimary == AccountType.none &&
                      accountState.discord == null),
              onTap: () =>
                  ref.read(accountProvider.notifier).setPreferredPrimary(AccountType.youtube),
              themeColor: themeColor,
            ),

          if (accountState.youtube != null && accountState.discord != null)
            const SizedBox(height: 8),

          if (accountState.discord != null)
            _ProfileOption(
              label: "Discord",
              username: accountState.discord!.displayName,
              icon: Icons.gamepad_rounded,
              // Selected if Discord is explicitly chosen, or if nothing is chosen and YouTube isn't connected
              isSelected: accountState.preferredPrimary == AccountType.discord ||
                  (accountState.preferredPrimary == AccountType.none &&
                      accountState.youtube == null),
              onTap: () =>
                  ref.read(accountProvider.notifier).setPreferredPrimary(AccountType.discord),
              themeColor: themeColor,
            ),

          Divider(color: Colors.white.withOpacity(0.06), height: 28),

          // Cloud backup (automatic, with LIVE status)
          // Backup runs on its own after every library/history/taste change.
          // The row surfaces the real state — a silent push failure used to be
          // invisible here while backups quietly froze for months.
          _CloudBackupStatusRow(themeColor: themeColor),

          Divider(color: Colors.white.withOpacity(0.06), height: 28),

          // A copy of the library the USER owns
          // Sits beside the cloud row on purpose: that one protects against
          // Auvy's mistakes, this one protects against Auvy being unavailable.
          // See LibraryExportService.
          _LibraryExportRow(themeColor: themeColor),

          Divider(color: Colors.white.withOpacity(0.06), height: 28),

          // Discord Rich Presence ("Listening to Auvy" on the profile)
          _RichPresenceRow(themeColor: themeColor),

          Divider(color: Colors.white.withOpacity(0.06), height: 28),

          // Connect / disconnect
          // Moved here from the Library avatar's "Account & connections" panel,
          // which was removed: everything else in it (profile choice, cloud
          // backup status, Discord RPC) already lived in this section, so the
          // panel was a second place to look for the same settings. These
          // connect/disconnect actions were the only thing it uniquely had.
          Align(
            alignment: Alignment.centerLeft,
            child: Text("CONNECTIONS",
                style: TextStyle(
                    color: Colors.white.withOpacity(0.66),
                    fontSize: 10.5,
                    fontWeight: FontWeight.w900,
                    letterSpacing: 1.4)),
          ),
          const SizedBox(height: 10),
          // Import the signed-in account's YouTube Music playlists. This lived on
          // the removed Library account panel as an easily-missed ⟳ icon; it's the
          // one genuinely useful ACTION in that panel, so it gets a real labelled
          // button here.
          if (accountState.youtube != null) ...[
            SizedBox(
              width: double.infinity,
              height: 44,
              child: TextButton.icon(
                onPressed: () async {
                  final messenger = ScaffoldMessenger.of(context);
                  messenger.showSnackBar(const SnackBar(
                      content: Text('Syncing YouTube Music library…')));
                  final count = await ref
                      .read(accountProvider.notifier)
                      .importAllAccountPlaylists();
                  messenger.showSnackBar(SnackBar(
                      content: Text(count > 0
                          ? 'Imported $count YouTube Music playlist'
                              '${count == 1 ? '' : 's'} ✓'
                          : 'Nothing imported — is your YT Music library empty?')));
                },
                icon: const Icon(Icons.sync_rounded, size: 18),
                label: const Text("Sync YouTube Music playlists"),
                style: TextButton.styleFrom(
                  backgroundColor: Colors.red.withOpacity(0.14),
                  foregroundColor: Colors.white,
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12)),
                ),
              ),
            ),
            const SizedBox(height: 8),
          ],
          if (accountState.discord == null)
            SizedBox(
              width: double.infinity,
              height: 44,
              child: TextButton.icon(
                onPressed: () async {
                  final ok = await ref
                      .read(accountProvider.notifier)
                      .linkPresenceAccount();
                  if (!context.mounted) return;
                  ScaffoldMessenger.of(context).showSnackBar(SnackBar(
                      content: Text(ok
                          ? 'Connected to Discord'
                          : 'Discord connection cancelled')));
                },
                icon: const Icon(Icons.gamepad_rounded, size: 18),
                label: const Text("Connect Discord"),
                style: TextButton.styleFrom(
                  backgroundColor: const Color(0xFF5865F2).withOpacity(0.18),
                  foregroundColor: Colors.white,
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12)),
                ),
              ),
            )
          else
            SizedBox(
              width: double.infinity,
              height: 44,
              child: TextButton.icon(
                // Synchronous, and the block watches accountProvider, so the row
                // flips back to "Connect" on its own — no setState needed.
                onPressed: () =>
                    ref.read(accountProvider.notifier).unlinkPresenceAccount(),
                icon: const Icon(Icons.link_off_rounded, size: 18),
                label: Text("Disconnect ${accountState.discord!.displayName}"),
                style: TextButton.styleFrom(
                  backgroundColor: Colors.white.withOpacity(0.06),
                  foregroundColor: Colors.white70,
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12)),
                ),
              ),
            ),

          Divider(color: Colors.white.withOpacity(0.06), height: 28),

          // Danger zone: delete Auvy account
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              color: Colors.red.withOpacity(0.07),
              borderRadius: BorderRadius.circular(14),
              border: Border.all(color: Colors.redAccent.withOpacity(0.25)),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // The four-line explanation moved behind an ⓘ — it matters once,
                // then costs a quarter of the screen forever. See InfoHint.
                Row(children: [
                  const Text("Danger Zone",
                      style: TextStyle(
                          color: Colors.redAccent,
                          fontWeight: FontWeight.w700,
                          fontSize: 13)),
                  const Spacer(),
                  const InfoHint(
                    title: 'Deleting your account',
                    tint: Colors.redAccent,
                    message:
                        'Delete removes your Auvy data — library, listening '
                        'history, taste profile and downloads — from Auvy and '
                        'from this device.\n\n'
                        'Your Google/YouTube account is NOT affected: nothing is '
                        'changed or removed on YouTube itself.\n\n'
                        'Signing in again starts completely fresh, with no way to '
                        'recover the deleted data.',
                  ),
                ]),
                const SizedBox(height: 8),
                SizedBox(
                  width: double.infinity,
                  height: 44,
                  child: TextButton.icon(
                    onPressed: () => _confirmDeleteAccount(context, ref, themeColor),
                    icon: const Icon(Icons.delete_forever_rounded, size: 18),
                    label: const Text("Delete Account"),
                    style: TextButton.styleFrom(
                      backgroundColor: Colors.red.withOpacity(0.14),
                      foregroundColor: Colors.redAccent,
                      shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12)),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// Confirms and performs the "Delete Account" flow (see
  /// [AccountNotifier.deleteAuvyAccount]), then hard-resets the app to the
  /// splash/login-gate so the user starts as a brand-new user.
  void _confirmDeleteAccount(BuildContext context, WidgetRef ref, Color themeColor) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        // Surface/shape/typography come from ThemeData.dialogTheme. See main.dart.
        title: const Text("Delete Account?", style: TextStyle(color: Colors.white)),
        content: const Text(
          "This permanently deletes your Auvy data (library, playlists, listening "
          "history, recommendations and downloaded files) from Auvy's servers and "
          "this phone.\n\nThis does NOT delete your Google/YouTube account. If you "
          "sign in again with the same account, you'll start over from scratch.",
          style: TextStyle(color: Colors.white70, fontSize: 13, height: 1.4),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text("Cancel", style: TextStyle(color: Colors.white54)),
          ),
          TextButton(
            onPressed: () async {
              Navigator.pop(ctx); // close the confirm dialog
              // Non-dismissible progress spinner while we wipe everything.
              showDialog(
                context: context,
                barrierDismissible: false,
                builder: (_) => const Center(child: CircularProgressIndicator()),
              );
              final erased =
                  await ref.read(accountProvider.notifier).deleteAuvyAccount();
              if (!context.mounted) return;
              // A partial delete must NOT look like a complete one.
              //
              // The device is wiped either way, but if the CLOUD copy survived,
              // signing in again with the same account restores everything the
              // user just asked to erase — the backup is keyed by their Google
              // identity, which does not change. Being told now is the difference
              // between retrying and discovering it by accident.
              if (!erased) {
                AnimatedToast.message(
                    'Deleted on this phone, but the cloud copy could not be '
                    'erased — try again while signed in');
              }
              // Hard-reset the navigation stack back to the splash screen, which
              // re-runs the login-gate → onboarding → tutorial as a new user.
              Navigator.of(context, rootNavigator: true).pushAndRemoveUntil(
                MaterialPageRoute(builder: (_) => const SplashScreen()),
                (route) => false,
              );
            },
            child: const Text("Delete",
                style: TextStyle(color: Colors.redAccent, fontWeight: FontWeight.bold)),
          ),
        ],
      ),
    );
  }
}

class _ProfileOption extends StatelessWidget {
  final String label;
  final String username;
  final IconData icon;
  final bool isSelected;
  final VoidCallback onTap;
  final Color themeColor;

  const _ProfileOption({
    required this.label,
    required this.username,
    required this.icon,
    required this.isSelected,
    required this.onTap,
    required this.themeColor,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: () {
        HapticService.selection();
        onTap();
      },
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 180),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 11),
        decoration: BoxDecoration(
          color: isSelected ? themeColor.withOpacity(0.14) : Colors.white.withOpacity(0.04),
          borderRadius: BorderRadius.circular(14),
          border:
              Border.all(color: isSelected ? themeColor : Colors.transparent, width: 1.2),
        ),
        child: Row(
          children: [
            Icon(icon, color: isSelected ? themeColor : Colors.white54, size: 19),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(label,
                      style: TextStyle(
                        color: isSelected ? Colors.white : Colors.white70,
                        fontWeight: isSelected ? FontWeight.w700 : FontWeight.w500,
                        fontSize: 13.5,
                      )),
                  Text(username,
                      style:
                          TextStyle(color: Colors.white.withOpacity(0.66), fontSize: 11)),
                ],
              ),
            ),
            if (isSelected) Icon(Icons.check_circle_rounded, color: themeColor, size: 19),
          ],
        ),
      ),
    );
  }
}

class _RowStat extends StatelessWidget {
  final String label;
  final String value;
  const _RowStat(this.label, this.value);

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        Text(label, style: TextStyle(color: Colors.white.withOpacity(0.78), fontSize: 13)),
        Text(value,
            style: const TextStyle(
                color: Colors.white,
                fontWeight: FontWeight.w700,
                fontSize: 13,
                fontFamily: 'monospace')),
      ],
    );
  }
}

class EqBandSlider extends ConsumerStatefulWidget {
  final int bandIndex;
  final String label;

  const EqBandSlider({
    super.key,
    required this.bandIndex,
    required this.label,
  });

  @override
  ConsumerState<EqBandSlider> createState() => _EqBandSliderState();
}

class _EqBandSliderState extends ConsumerState<EqBandSlider> {
  // Holds the temporary slider value only while the user's finger is dragging
  double? _localDragValue;

  @override
  Widget build(BuildContext context) {
    // select() — the old whole-provider watch rebuilt all five band sliders on
    // every periodic PlayerState write.
    final isEqEnabled = ref.watch(playerProvider.select((p) => p.eqEnabled));
    final savedValue =
        ref.watch(playerProvider.select((p) => p.eqBands[widget.bandIndex]));
    final themeColor = ref.watch(themeProvider);

    // If dragging, use the local value for smooth UI. Otherwise, use the global saved state.
    final currentValue = _localDragValue ?? savedValue;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 24.0),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                widget.label,
                style: TextStyle(
                    color: isEqEnabled ? Colors.white.withOpacity(0.75) : Colors.grey,
                    fontSize: 12.5),
              ),
              Text(
                '${(currentValue > 0 ? '+' : '')}${currentValue.toStringAsFixed(1)} dB',
                style: TextStyle(
                  color: isEqEnabled ? themeColor : Colors.grey,
                  fontWeight: FontWeight.bold,
                  fontSize: 12.5,
                ),
              ),
            ],
          ),
        ),
        SliderTheme(
          data: SliderTheme.of(context).copyWith(
            trackHeight: 3,
            thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 7),
            overlayShape: const RoundSliderOverlayShape(overlayRadius: 14),
          ),
          child: Slider(
            min: -12.0,
            max: 12.0,
            divisions: 24, // Snaps to 1dB increments
            value: currentValue,
            activeColor: themeColor,
            inactiveColor: Colors.white.withOpacity(0.12),
            // Only enable the slider if the master EQ switch is ON
            onChanged: isEqEnabled
                ? (newValue) {
                    // 1. Update UI smoothly
                    setState(() {
                      _localDragValue = newValue;
                    });

                    // 2. Apply DSP effect in real-time to the audio layer, but DON'T persist/save yet
                    final newBands =
                        List<double>.from(ref.read(playerProvider).eqBands);
                    newBands[widget.bandIndex] = newValue;
                    ref
                        .read(playerProvider.notifier)
                        .applyEqBands(newBands, persist: false);
                  }
                : null,
            onChangeEnd: isEqEnabled
                ? (finalValue) {
                    // 3. User let go of the slider. Save to disk and update global Riverpod state.
                    final newBands =
                        List<double>.from(ref.read(playerProvider).eqBands);
                    newBands[widget.bandIndex] = finalValue;
                    ref
                        .read(playerProvider.notifier)
                        .applyEqBands(newBands, persist: true);

                    // 4. Clear local state so it goes back to safely reading from Riverpod
                    setState(() {
                      _localDragValue = null;
                    });
                  }
                : null,
          ),
        ),
      ],
    );
  }
}

class _DataSaverOption extends StatelessWidget {
  final String label;
  final String subtitle;
  final bool isSelected;
  final IconData icon;
  final VoidCallback onTap;
  final Color themeColor;

  const _DataSaverOption({
    required this.label,
    required this.subtitle,
    required this.isSelected,
    required this.icon,
    required this.onTap,
    required this.themeColor,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: () {
        HapticService.selection();
        onTap();
      },
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 180),
        margin: const EdgeInsets.only(bottom: 8),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 11),
        decoration: BoxDecoration(
          color: isSelected ? themeColor.withOpacity(0.14) : Colors.white.withOpacity(0.04),
          borderRadius: BorderRadius.circular(14),
          border:
              Border.all(color: isSelected ? themeColor : Colors.transparent, width: 1.2),
        ),
        child: Row(
          children: [
            Icon(icon, color: isSelected ? themeColor : Colors.white54, size: 19),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    label,
                    style: TextStyle(
                      color: isSelected ? Colors.white : Colors.white70,
                      fontWeight: isSelected ? FontWeight.w700 : FontWeight.w500,
                      fontSize: 13.5,
                    ),
                  ),
                  Text(
                    subtitle,
                    style: TextStyle(color: Colors.white.withOpacity(0.66), fontSize: 11),
                  ),
                ],
              ),
            ),
            if (isSelected) Icon(Icons.check_circle_rounded, color: themeColor, size: 19),
          ],
        ),
      ),
    );
  }
}

class _SliderPreviewAnimator extends StatefulWidget {
  final SliderStyle style;
  final Color themeColor;
  const _SliderPreviewAnimator({required this.style, required this.themeColor});

  @override
  State<_SliderPreviewAnimator> createState() => _SliderPreviewAnimatorState();
}

class _SliderPreviewAnimatorState extends State<_SliderPreviewAnimator>
    with SingleTickerProviderStateMixin {
  late AnimationController _controller;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(vsync: this, duration: const Duration(seconds: 4))
      ..repeat();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // RepaintBoundary: the preview animates continuously while Settings is
    // open — contain its repaints to just this slider.
    return RepaintBoundary(
      child: AnimatedBuilder(
        animation: _controller,
        builder: (context, child) {
          final progress = _controller.value;
          switch (widget.style) {
            case SliderStyle.liquid:
              // Must match the player page exactly: the squiggly fluid slider.
              return AuvyFluidSlider(
                value: progress,
                isPlaying: true,
                activeColor: widget.themeColor,
                inactiveColor: Colors.white24,
                onChanged: (_) {},
              );
            case SliderStyle.waveform:
              return WaveformSlider(progress: progress, themeColor: widget.themeColor, onChanged: (_) {});
            case SliderStyle.material:
              return MaterialThumbSlider(progress: progress, themeColor: widget.themeColor, onChanged: (_) {});
            case SliderStyle.minimal:
              return MinimalSlider(progress: progress, themeColor: widget.themeColor, onChanged: (_) {});
            // isPlaying: true in the picker — a preview that sat still would show
            // the paused look and misrepresent what the style does.
            case SliderStyle.comet:
              return CometSlider(progress: progress, themeColor: widget.themeColor, isPlaying: true, onChanged: (_) {});
            case SliderStyle.elastic:
              return ElasticSlider(progress: progress, themeColor: widget.themeColor, onChanged: (_) {});
            case SliderStyle.pulse:
              return PulseSlider(progress: progress, themeColor: widget.themeColor, isPlaying: true, onChanged: (_) {});
            case SliderStyle.flow:
              return FlowSlider(progress: progress, themeColor: widget.themeColor, isPlaying: true, onChanged: (_) {});
            case SliderStyle.segmented:
              return SegmentedSlider(progress: progress, themeColor: widget.themeColor, onChanged: (_) {});
            case SliderStyle.timeline:
              return TimelineSlider(progress: progress, themeColor: widget.themeColor, onChanged: (_) {});
          }
        },
      ),
    );
  }
}

/// Live cloud-backup status row for the account section. Shows the real sync
/// state (last successful backup / failure reason / not connected) and lets
/// the user tap to force a backup right now. Replaces a static "Automatic"
/// label that kept claiming success while pushes silently failed.
class _CloudBackupStatusRow extends ConsumerStatefulWidget {
  final Color themeColor;
  const _CloudBackupStatusRow({required this.themeColor});

  @override
  ConsumerState<_CloudBackupStatusRow> createState() =>
      _CloudBackupStatusRowState();
}

class _CloudBackupStatusRowState extends ConsumerState<_CloudBackupStatusRow> {
  bool _busy = false;
  int? _lastBackupMs;

  @override
  void initState() {
    super.initState();
    _loadMarker();
  }

  Future<void> _loadMarker() async {
    final prefs = await SharedPreferences.getInstance();
    if (mounted) {
      setState(() => _lastBackupMs = prefs.getInt('cloud_last_backup_ms'));
    }
  }

  String _ago(int ms) {
    final d =
        DateTime.now().difference(DateTime.fromMillisecondsSinceEpoch(ms));
    if (d.inMinutes < 1) return 'just now';
    if (d.inHours < 1) return '${d.inMinutes} min ago';
    if (d.inDays < 1) return '${d.inHours} h ago';
    return '${d.inDays} day${d.inDays == 1 ? '' : 's'} ago';
  }

  Future<void> _backupNow() async {
    if (_busy) return;
    HapticService.light();
    setState(() => _busy = true);
    final ok = await ref.read(accountProvider.notifier).backupNow();
    await _loadMarker();
    if (!mounted) return;
    setState(() => _busy = false);
    AnimatedToast.message(ok
        ? "Backup complete"
        : "Backup failed — ${CloudSyncService.lastPushError ?? 'not signed in'}");
  }

  @override
  Widget build(BuildContext context) {
    final active = CloudSyncService.instance.isActive;
    final error = CloudSyncService.lastPushError;
    final failed = active && error != null;

    final IconData icon;
    final Color iconColor;
    final String title;
    final String subtitle;
    if (!active) {
      icon = Icons.cloud_off_rounded;
      iconColor = Colors.white38;
      title = "Cloud Backup — Not connected";
      subtitle = "Tap to sign in and back up your library, history and taste.";
    } else if (failed) {
      icon = Icons.cloud_off_rounded;
      iconColor = Colors.redAccent;
      title = "Cloud Backup — FAILED";
      subtitle = "Last attempt didn't reach the cloud — tap to retry. ($error)";
    } else {
      icon = Icons.cloud_done_rounded;
      iconColor = widget.themeColor;
      title = "Cloud Backup — Automatic";
      //"Last synced", NOT "Last backup" — THE VALUE IS THE WATERMARK.
      //
      // `_lastBackupMs` comes from `cloud_last_backup_ms`, which a RESTORE sets
      // to the timestamp of the cloud copy it pulled — not to the moment of the
      // restore. That is deliberate (it is what decides whether a future cloud
      // backup is newer and worth pulling), but it means the figure right after a
      // restore is when that backup was MADE. Labelled "Last backup" it read as
      // "nothing has happened for three hours" on an account that was simply
      // unchanged and therefore had nothing to push. "Last synced" describes the
      // watermark honestly in both directions.
      subtitle = _lastBackupMs != null
          ? "Syncs after every change. Last synced ${_ago(_lastBackupMs!)} — tap to back up now."
          : "Your library, history and taste sync to your account after every change.";
    }

    return InkWell(
      onTap: _busy ? null : _backupNow,
      borderRadius: BorderRadius.circular(10),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 2),
        child: Row(
          children: [
            _busy
                ? SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(
                        strokeWidth: 2, color: widget.themeColor))
                : Icon(icon, color: iconColor, size: 20),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(title,
                      style: TextStyle(
                          color: failed ? Colors.redAccent : Colors.white,
                          fontWeight: FontWeight.w600,
                          fontSize: 13.5)),
                  const SizedBox(height: 2),
                  Text(
                    subtitle,
                    maxLines: 3,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                        color: Colors.white.withOpacity(0.66), fontSize: 11.5),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// Library export row (Account card)
//
// Writes a plain-JSON copy of the library, taste profile and recognition history
// into the public Music/Auvy folder, and offers to read the newest one back.
//
// It sits beside the cloud row because it answers a DIFFERENT question. The
// cloud backup protects against Auvy losing data; this protects against Auvy not
// being there — no approved account, no Worker, no install. It is the only copy
// that survives the app, which is why it is a file the user can see and move
// rather than another thing the app keeps for them.
//
// Restore is confirmed, never one tap: it describes the file first ("412 tracks,
// 11 playlists") because replacing a library is not an action to take blind. The
// service additionally refuses to trade content for emptiness — see
// LibraryExportService.import.
class _LibraryExportRow extends ConsumerStatefulWidget {
  final Color themeColor;
  const _LibraryExportRow({required this.themeColor});

  @override
  ConsumerState<_LibraryExportRow> createState() => _LibraryExportRowState();
}

class _LibraryExportRowState extends ConsumerState<_LibraryExportRow> {
  /// Stands for the "Choose a file…" row so the sheet can return one type.
  /// A File that cannot exist, so it can never be confused with a real one.
  static final File _pickSentinel = File(String.fromCharCode(0));

  bool _busy = false;
  String? _note;

  /// The folder part of a path, for telling the user where the file went.
  String _folderOf(String path) {
    final parts = path.split('/');
    return parts.length >= 2 ? parts[parts.length - 2] : path;
  }

  Future<void> _export() async {
    setState(() { _busy = true; _note = null; });
    final path = await LibraryExportService.instance.export();
    if (!mounted) return;
    // WHERE it landed matters, and it used to be reported wrongly: a MediaStore
    // save returns a DISPLAY path ("Download/Auvy/…"), not an absolute one, so a
    // '/storage/' test called the visible file private. A private save is the
    // only one that starts at the filesystem root here.
    final public = path != null && !path.startsWith('/');
    setState(() {
      _busy = false;
      _note = path == null
          ? "Couldn't write anywhere — storage is unavailable."
          : public
              ? 'Saved to $path — visible in Files under Download/Auvy.'
              : 'Saved inside the app, where no file manager can show it. '
                  'That copy also goes when Auvy is uninstalled.';
    });
    AnimatedToast.message(path == null
        ? 'Export failed'
        : public
            ? 'Saved to Download/Auvy'
            : 'Saved inside the app only');
  }

  /// Pick a backup file, then restore it — Auvy's own or another app's.
  ///
  /// The list is what the device actually holds (see
  /// LibraryExportService.findBackups), so a `.backup` copied over from another
  /// phone or another player shows up beside Auvy's own exports.
  Future<void> _restore() async {
    setState(() { _busy = true; _note = null; });
    final files = await LibraryExportService.instance.findBackups();
    if (!mounted) return;
    setState(() => _busy = false);
    final chosen = await showModalBottomSheet<File>(
      context: context,
      backgroundColor: const Color(0xFF141418),
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Padding(
              padding: EdgeInsets.fromLTRB(20, 18, 20, 6),
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text('Restore from a file',
                    style: TextStyle(
                        color: Colors.white,
                        fontSize: 16,
                        fontWeight: FontWeight.w800)),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 10),
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text(
                    'Auvy backups, other players’ backups (Metrolist and the '
                    'apps it shares a format with) and Spotify data exports.',
                    style: TextStyle(
                        color: Colors.white.withOpacity(0.66), fontSize: 12)),
              ),
            ),
            // FIRST, AND NOT A FALLBACK. Auvy holds no "all files access", so
            // the scanned list below can only ever show files Auvy itself wrote —
            // another app's backup sitting in Downloads is invisible to it. The
            // system picker is the only route to those, and it also reaches Drive,
            // an SD card and anything else the phone can see.
            ListTile(
              leading: Icon(Icons.folder_open_rounded,
                  color: widget.themeColor, size: 22),
              title: const Text('Choose a file…',
                  style: TextStyle(
                      color: Colors.white,
                      fontSize: 13.5,
                      fontWeight: FontWeight.w700)),
              subtitle: Text('Browse the phone, Drive or an SD card',
                  style: TextStyle(
                      color: Colors.white.withOpacity(0.55), fontSize: 11)),
              onTap: () => Navigator.pop(ctx, _pickSentinel),
            ),
            Divider(height: 1, color: Colors.white.withOpacity(0.06)),
            if (files.isEmpty)
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 14, 20, 18),
                child: Text(
                    'No backups saved by Auvy on this phone yet. Use “Choose a '
                    'file…” for one from another app.',
                    style: TextStyle(
                        color: Colors.white.withOpacity(0.5), fontSize: 11.5)),
              ),
            Flexible(
              child: ListView.builder(
                shrinkWrap: true,
                itemCount: files.length,
                itemBuilder: (_, i) {
                  final f = files[i];
                  final name = f.path.split('/').last;
                  var size = '';
                  var when = '';
                  try {
                    final stat = f.statSync();
                    size = '${(stat.size / 1024).toStringAsFixed(0)} KB';
                    when = stat.modified.toLocal().toString().split('.').first;
                  } catch (_) {}
                  final mine = name.startsWith('auvy-library-');
                  return ListTile(
                    leading: Icon(
                        mine
                            ? Icons.restore_rounded
                            : Icons.folder_zip_outlined,
                        color: mine
                            ? widget.themeColor
                            : Colors.white.withOpacity(0.6),
                        size: 22),
                    title: Text(name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                            color: Colors.white,
                            fontSize: 13.5,
                            fontWeight: FontWeight.w600)),
                    subtitle: Text(
                        '${_folderOf(f.path)}  ·  $size  ·  $when',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                            color: Colors.white.withOpacity(0.55),
                            fontSize: 11)),
                    onTap: () => Navigator.pop(ctx, f),
                  );
                },
              ),
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
    if (chosen == null || !mounted) return;

    // "Choose a file…" — hand off to the system picker and use what comes back.
    //
    // EVERY BRANCH BELOW READS `target`, NEVER `chosen`. When the sheet
    // returns the picker sentinel, `chosen` is a File that cannot exist, so a
    // branch still reading it fails on a path instead of on the user's backup —
    // and every one of those failures is a silent null, so the app reported
    // "can't read that file" about a file it had never opened. That was the whole
    // of the "importing Metrolist.backup doesn't work" bug.
    File target = chosen;
    // The picked file is a copy in our cache, AND it has to be deleted.
    //
    // The system picker grants access to a URI, not a path, and that grant does
    // not survive the process, so the native side copies the chosen file into
    // the app cache and Dart works with that. Leaving it there means ANOTHER
    // APP'S ENTIRE LIBRARY sits inside Auvy indefinitely, growing by one copy per
    // restore. Deleted in the finally below, whatever the outcome.
    File? pickedCopy;
    try {
      if (chosen == _pickSentinel) {
        final picked = await LibraryExportService.instance.pickBackupFile();
        if (picked == null || !mounted) return;
        target = picked.file;
        pickedCopy = picked.file;
        print('restore: picked "${picked.name}" '
            '(${await target.length()} bytes)');
      } else {
        print('restore: chosen ${target.path}');
      }
      await _dispatchRestore(target);
    } finally {
      try {
        if (pickedCopy != null && await pickedCopy.exists()) {
          await pickedCopy.delete();
        }
      } catch (_) {}
    }
  }

  /// Route one file to the importer that understands it.
  Future<void> _dispatchRestore(File target) async {

    // Auvy's own format first: it is the only one that can restore SETTINGS and
    // play history wholesale, so it must not be mistaken for a foreign archive.
    final summary = await LibraryExportService.instance.peek(target);
    if (!mounted) return;
    if (summary != null) {
      await _restoreOwn(target, summary);
      return;
    }
    // Then a foreign DATABASE backup (Metrolist and the players it shares a
    // format with) — real ids, importable as-is.
    if (await ForeignBackupReader.looksForeign(target)) {
      await _restoreForeign(target);
      return;
    }
    // Last, a file that carries only NAMES (a Spotify data export, a CSV) —
    // every track has to be matched against the catalogue first.
    print('restore: not an Auvy or database backup — trying it as a track list');
    await _importTrackListFile(target);
  }

  Future<void> _restoreOwn(File file, Map<String, int> summary) async {
    final ok = await _confirm(
      title: 'Restore this backup?',
      body: '${file.path.split('/').last}\n\n'
          '${summary['playlists'] ?? 0} playlists · '
          '${summary['likedSongs'] ?? 0} liked songs\n\n'
          'Your current library will be replaced by this copy. Anything the '
          'file does not contain is left alone.',
      action: 'Restore',
    );
    if (ok != true || !mounted) return;

    setState(() => _busy = true);
    final restored = await LibraryExportService.instance.import(file);
    // Prefs are the source of truth for these providers, so they have to be told
    // to re-read — the same reason the cloud restore reloads them.
    if (restored > 0) {
      try { await ref.read(intelligenceProvider.notifier).reloadFromStorage(); } catch (_) {}
      try { await ref.read(libraryProvider.notifier).reloadFromStorage(); } catch (_) {}
    }
    if (!mounted) return;
    setState(() {
      _busy = false;
      _note = restored < 0
          ? 'That file could not be restored.'
          : 'Restored $restored section(s).';
    });
    AnimatedToast.message(
        restored < 0 ? 'Restore failed' : 'Library restored from file');
  }

  /// Import another player's backup.
  ///
  /// MERGED, NEVER APPLIED WHOLESALE. Auvy's own backup is a snapshot of
  /// Auvy and replacing state with it is coherent; another app's library is
  /// ADDITIONAL, and overwriting with it would delete playlists the user made
  /// here. So this path only ever adds — see
  /// LibraryNotifier.mergeImportedLibrary.
  Future<void> _restoreForeign(File file) async {
    setState(() => _busy = true);
    final imported = await ForeignBackupReader.read(file);
    if (!mounted) return;
    setState(() => _busy = false);
    if (imported == null || imported.isEmpty) {
      setState(() => _note =
          "That file isn't a library backup Auvy can read.");
      AnimatedToast.message("Can't read that backup");
      return;
    }

    // Say what is in the file, including what is NOT.
    //
    // A Metrolist library whose playlists are its own generated ones (Weekly /
    // Monthly Most Played) has NO local track mappings at all, so "0 playlists"
    // is the honest count, and a user who expected their playlists needs to be
    // told that before the import, not left wondering afterwards.
    final ok = await _confirm(
      title: 'Import from ${imported.sourceApp}?',
      body: '${file.path.split('/').last}\n\n'
          '${imported.likedSongs.length} liked songs · '
          '${imported.playlists.length} playlists · '
          '${imported.librarySongs.length} in library · '
          '${imported.trackCount} tracks in total\n\n'
          '${imported.playlists.isEmpty ? 'This backup holds no playlist track '
              'lists — that app keeps its playlists on YouTube, so only the '
              'songs themselves are in the file.\n\n' : ''}'
          'Everything is ADDED to your library — nothing you already have is '
          'replaced or removed. A playlist whose name you already use is '
          'imported alongside yours, not merged into it.',
      action: 'Import',
    );
    if (ok != true || !mounted) return;

    setState(() => _busy = true);
    final lib = ref.read(libraryProvider.notifier);
    // Library-but-not-liked tracks would otherwise be read, counted and then
    // silently dropped — they land in their own playlist so nothing in the file
    // goes missing without being mentioned.
    final playlists = Map<String, List<Song>>.from(imported.playlists);
    final likedIds = imported.likedSongs.map((s) => s.id).toSet();
    final extras =
        imported.librarySongs.where((s) => !likedIds.contains(s.id)).toList();
    if (extras.isNotEmpty) {
      playlists['${imported.sourceApp} Library'] = extras;
    }
    final result = lib.mergeImportedLibrary(
      sourceApp: imported.sourceApp,
      likedSongs: imported.likedSongs,
      playlists: playlists,
      albums: [
        for (final a in imported.albums)
          Album(
            id: a.id,
            title: a.title,
            image: a.image,
            releaseDate: a.year?.toString() ?? '',
            recordType: 'album',
            subtitle: a.year != null ? 'Album • ${a.year}' : 'Album',
          ),
      ],
      artists: [
        for (final a in imported.artists)
          Song(id: a.id, title: a.name, artist: a.name, image: a.image),
      ],
    );

    // Play counts feed Top 50, Quick Picks and Wrapped. Merged with the
    // metadata for the same tracks, because a count for a track the app has no
    // metadata for cannot be rendered or recommended and is dropped.
    try {
      final meta = <String, Song>{
        // Every track the backup has a count or a play date for. Without this the
        // profile could only keep numbers for tracks that also happened to be in
        // a playlist or liked, and the rest were read and thrown away.
        ...imported.tracksWithHistory,
      };
      for (final s in [
        ...imported.likedSongs,
        ...imported.librarySongs,
        ...imported.history,
        for (final list in imported.playlists.values) ...list,
      ]) {
        meta[s.id] = s;
      }
      ref.read(intelligenceProvider.notifier).mergeImportedPlayCounts(
            imported.playCounts,
            meta,
            // The event log, so the taste profile inherits WHEN they listened —
            // not just how often. Everything time-based in stats and Wrapped
            // reads these stamps.
            playStamps: imported.playLog.stamps,
            firstPlayMs: imported.playLog.firstPlayMs,
            lastPlayMs: imported.playLog.lastPlayMs,
          );
    } catch (_) {}

    // Their searches, so the search screen does not start blank on a phone that
    // has years of history behind it.
    try {
      if (imported.searchHistory.isNotEmpty) {
        final search = ref.read(searchServiceProvider);
        for (final q in imported.searchHistory) {
          await search.addQueryToHistory(q);
        }
      }
    } catch (_) {}

    // Make the app act on what it just learned
    //
    // The taste profile is now different, and two things are DERIVED from it
    // rather than stored: My Top 50 (ranked by play count) and the home feed's
    // Quick Picks. Neither re-derives on its own — Top 50 is rebuilt when a track
    // finishes playing, and the home feed when it next initialises, so without
    // this the import would land and the app would keep recommending as if
    // nothing had been learned until some unrelated event happened to refresh it.
    try {
      final intel = ref.read(intelligenceProvider);
      ref.read(libraryProvider.notifier).refreshTop50(
          intel.playCounts, intel.trackMetadata, intel.firstPlayTimestamps);
    } catch (_) {}
    // Unawaited: it fetches over the network, and the import is already finished.
    try {
      ref.read(homeProvider.notifier).refreshHome();
    } catch (_) {}

    // Identified songs the other app logged. Appended, then the ledger is
    // re-capped by its own writer. See RecognitionHistory.
    try {
      if (imported.recognitions.isNotEmpty) {
        await RecognitionHistory.addAll([
          for (final r in imported.recognitions)
            RecognitionEntry(
              title: r.title,
              artist: r.artist,
              coverArtUrl: r.cover.isEmpty ? null : r.cover,
              at: DateTime.fromMillisecondsSinceEpoch(
                  r.atMs > 0 ? r.atMs : DateTime.now().millisecondsSinceEpoch),
            ),
        ]);
      }
    } catch (_) {}

    if (!mounted) return;
    setState(() {
      _busy = false;
      _note = result.isEmpty
          ? 'Nothing new to import — you already have all of it.'
          : 'Added ${result.playlists} playlists (${result.playlistTracks} '
              'tracks) and ${result.likedSongs} liked songs.';
    });
    AnimatedToast.message(result.isEmpty
        ? 'Already up to date'
        : 'Imported from ${imported.sourceApp}');
  }

  /// Import a file that carries only track NAMES — a Spotify "Download your
  /// data" export, an Exportify CSV, a hand-made list.
  ///
  /// One catalogue search per track, AND the user is told so before it
  /// STARTS. These files describe a different catalogue and contain nothing
  /// Auvy could play, so every row has to be matched (through the same matcher a
  /// pasted Spotify link uses). On a large export that is minutes of work, and
  /// an unexplained multi-minute spinner is how a feature gets called broken.
  Future<void> _importTrackListFile(File file) async {
    setState(() => _busy = true);
    final parsed = await TrackListFileParser.parse(file);
    if (!mounted) return;
    setState(() => _busy = false);
    if (parsed == null || parsed.trackCount == 0) {
      setState(() =>
          _note = "That file isn't a backup or a track list Auvy can read.");
      AnimatedToast.message("Can't read that file");
      return;
    }

    final ok = await _confirm(
      title: 'Import from ${parsed.sourceApp}?',
      body: '${file.path.split('/').last}\n\n'
          '${parsed.groups.length} list(s) · ${parsed.trackCount} tracks\n\n'
          'This file has no playable links in it — only song and artist names — '
          'so each track is matched against the catalogue first. That takes '
          'roughly a second per track and needs a connection. Nothing you '
          'already have is replaced.',
      action: 'Import',
    );
    if (ok != true || !mounted) return;

    final progress = ValueNotifier<String>('Starting…');
    showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (_) => AlertDialog(
        backgroundColor: const Color(0xFF1A1A1A),
        content: Row(
          children: [
            const SizedBox(
                width: 18,
                height: 18,
                child: CircularProgressIndicator(strokeWidth: 2)),
            const SizedBox(width: 14),
            Expanded(
              child: ValueListenableBuilder<String>(
                valueListenable: progress,
                builder: (_, text, __) => Text(text,
                    style: const TextStyle(color: Colors.white, fontSize: 13)),
              ),
            ),
          ],
        ),
      ),
    );

    final lib = ref.read(libraryProvider.notifier);
    final search = ref.read(searchServiceProvider);
    final playlists = <String, List<Song>>{};
    final liked = <Song>[];
    var missing = 0;

    for (final group in parsed.groups) {
      final label = group.name;
      final resolved = await lib.resolveQueriesToSongs(
        group.queries,
        search,
        onProgress: (done, total) =>
            progress.value = 'Matching “$label” — $done of $total',
      );
      missing += resolved.missing;
      if (resolved.songs.isEmpty) continue;
      if (group.kind == GroupKind.liked) {
        liked.addAll(resolved.songs);
      } else {
        playlists[label] = resolved.songs;
      }
    }

    if (mounted) Navigator.of(context, rootNavigator: true).pop();
    progress.dispose();

    final result = lib.mergeImportedLibrary(
      sourceApp: parsed.sourceApp,
      likedSongs: liked,
      playlists: playlists,
    );
    if (!mounted) return;
    setState(() {
      _busy = false;
      _note = result.isEmpty
          ? 'Nothing new to import — you already have all of it.'
          : 'Added ${result.playlists} playlists (${result.playlistTracks} '
              'tracks) and ${result.likedSongs} liked songs'
              '${missing > 0 ? ', $missing could not be matched' : ''}.';
    });
    AnimatedToast.message(result.isEmpty
        ? 'Already up to date'
        : 'Imported from ${parsed.sourceApp}');
  }

  Future<bool?> _confirm(
          {required String title,
          required String body,
          required String action}) =>
      showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          backgroundColor: const Color(0xFF1A1A1A),
          title: Text(title,
              style: const TextStyle(color: Colors.white, fontSize: 16)),
          content: Text(body,
              style: TextStyle(
                  color: Colors.white.withOpacity(0.72), fontSize: 12.5)),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: const Text('Cancel')),
            TextButton(
                onPressed: () => Navigator.pop(ctx, true),
                style: TextButton.styleFrom(foregroundColor: widget.themeColor),
                child: Text(action)),
          ],
        ),
      );

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 4),
      child: Row(
        children: [
          Icon(Icons.save_alt_rounded, color: widget.themeColor, size: 20),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('Save a copy to this phone',
                    style: TextStyle(
                        color: Colors.white,
                        fontWeight: FontWeight.w600,
                        fontSize: 13.5)),
                const SizedBox(height: 2),
                Text(
                  _note ??
                      'Writes your playlists, likes and listening history to a '
                          '.backup file you can copy anywhere. Restore reads '
                          'Auvy backups and other players’ too.',
                  maxLines: 3,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                      color: Colors.white.withOpacity(0.66), fontSize: 11.5),
                ),
              ],
            ),
          ),
          if (_busy)
            const Padding(
              padding: EdgeInsets.only(left: 8),
              child: SizedBox(
                  width: 16, height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2)),
            )
          else ...[
            TextButton(
              onPressed: _restore,
              style: TextButton.styleFrom(
                  foregroundColor: Colors.white.withOpacity(0.7)),
              child: const Text('Restore'),
            ),
            TextButton(
              onPressed: _export,
              style: TextButton.styleFrom(foregroundColor: widget.themeColor),
              child: const Text('Save'),
            ),
          ],
        ],
      ),
    );
  }
}

// Discord Rich Presence row (Account card)
// Publishes "Listening to Auvy" on the user's Discord profile while music
// plays. Needs its own gateway sign-in (WebView) — the OAuth login used for
// the display profile can't publish activities. All the heavy lifting lives
// in RichPresenceService; this row just drives connect / toggle / unlink.

class _RichPresenceRow extends StatefulWidget {
  final Color themeColor;
  const _RichPresenceRow({required this.themeColor});

  @override
  State<_RichPresenceRow> createState() => _RichPresenceRowState();
}

class _RichPresenceRowState extends State<_RichPresenceRow> {
  final RichPresenceService _svc = RichPresenceService();
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _svc.ensureLoaded().then((_) {
      if (mounted) setState(() {});
    });
  }

  Future<void> _connect() async {
    setState(() => _busy = true);
    final ok = await _svc.connectAccount();
    if (!mounted) return;
    setState(() => _busy = false);
    AnimatedToast.message(ok
        ? 'Discord connected — your profile now shows what you play'
        : 'Discord sign-in cancelled');
  }

  Future<void> _unlink() async {
    await _svc.disconnectAccount();
    if (!mounted) return;
    setState(() {});
    AnimatedToast.message('Discord Rich Presence unlinked');
  }

  @override
  Widget build(BuildContext context) {
    final bool linked = _svc.hasAccount;
    final subtitle = !linked
        ? 'Show "Listening to Auvy" with the track and cover on your Discord profile.'
        : (_svc.isEnabled
            ? 'Live — friends see what you\'re playing.'
            : 'Linked, but paused. Flip on to publish while playing.');

    return Row(
      children: [
        const _IconChip(icon: Icons.discord_rounded, tint: Color(0xFF7C87F8)),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  const Text("Discord Rich Presence",
                      style: TextStyle(
                          color: Colors.white,
                          fontWeight: FontWeight.w600,
                          fontSize: 13.5)),
                  if (linked) ...[
                    const SizedBox(width: 8),
                    GestureDetector(
                      onTap: _unlink,
                      child: Text("UNLINK",
                          style: TextStyle(
                              color: Colors.redAccent.withOpacity(0.8),
                              fontSize: 10,
                              fontWeight: FontWeight.w800,
                              letterSpacing: 1.1)),
                    ),
                  ],
                ],
              ),
              const SizedBox(height: 2),
              Text(subtitle,
                  maxLines: 3,
                  style: TextStyle(
                      color: Colors.white.withOpacity(0.66), fontSize: 11.5)),
            ],
          ),
        ),
        const SizedBox(width: 8),
        if (!linked)
          _busy
              ? SizedBox(
                  width: 20,
                  height: 20,
                  child: CircularProgressIndicator(
                      strokeWidth: 2, color: widget.themeColor))
              : GestureDetector(
                  onTap: _connect,
                  child: Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                    decoration: BoxDecoration(
                      color: widget.themeColor.withOpacity(0.15),
                      borderRadius: BorderRadius.circular(16),
                      border: Border.all(
                          color: widget.themeColor.withOpacity(0.4)),
                    ),
                    child: Text("Connect",
                        style: TextStyle(
                            color: widget.themeColor,
                            fontSize: 12,
                            fontWeight: FontWeight.w700)),
                  ),
                )
        else
          Switch(
            value: _svc.isEnabled,
            activeColor: widget.themeColor,
            onChanged: (v) async {
              await _svc.setEnabled(v);
              if (mounted) setState(() {});
            },
          ),
      ],
    );
  }
}

// Updates

/// "Check for updates" with the last-check time underneath, plus an inline
/// spinner while checking.
///
/// The time comes from [UpdateState] rather than memory, so it is still accurate
/// after a cold start — a check that ran on launch three days ago should not
/// read "Never checked". A persisted timestamp plus an in-flight flag — the
/// obvious shape for "when did this last run, and is it running now".
class _UpdateCheckRow extends ConsumerStatefulWidget {
  const _UpdateCheckRow();

  @override
  ConsumerState<_UpdateCheckRow> createState() => _UpdateCheckRowState();
}

class _UpdateCheckRowState extends ConsumerState<_UpdateCheckRow> {
  DateTime? _lastChecked;
  bool _checking = false;

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  Future<void> _refresh() async {
    final at = await UpdateState.lastCheckedAt();
    if (mounted) setState(() => _lastChecked = at);
  }

  Future<void> _check() async {
    if (_checking) return;
    setState(() => _checking = true);
    HapticService.selection();
    await UpdaterService.checkForUpdates(
        context, ref.read(themeProvider), manualCheck: true);
    if (!mounted) return;
    setState(() => _checking = false);
    await _refresh();
  }

  @override
  Widget build(BuildContext context) {
    final themeColor = ref.watch(themeProvider);
    return InkWell(
      onTap: _check,
      borderRadius: BorderRadius.circular(20),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        child: Row(
          children: [
            _IconChip(
                icon: Icons.system_update_alt_rounded,
                tint: const Color(0xFF80D8FF)),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text("Check for updates",
                      style: TextStyle(
                          color: Colors.white,
                          fontWeight: FontWeight.w600,
                          fontSize: 14.5)),
                  const SizedBox(height: 2),
                  Text(
                    _checking
                        ? "Checking…"
                        : UpdateState.formatLastChecked(_lastChecked),
                    style: TextStyle(
                        color: Colors.white.withOpacity(0.66), fontSize: 11.5),
                  ),
                ],
              ),
            ),
            if (_checking)
              SizedBox(
                width: 16,
                height: 16,
                child: CircularProgressIndicator(
                    strokeWidth: 2, color: themeColor),
              )
            else
              Icon(Icons.chevron_right_rounded,
                  color: Colors.white.withOpacity(0.30), size: 20),
          ],
        ),
      ),
    );
  }
}

/// The two update toggles, mirroring HYDRV's `UpdatePreferences`: whether to
/// check on launch at all, and whether a find should surface a banner.
///
/// Kept as two switches rather than one because they answer different
/// questions — "may Auvy talk to GitHub?" (a data/privacy choice) versus "may it
/// interrupt me?" (an attention choice). Collapsing them would force anyone who
/// dislikes the banner to also give up update checking.
class _UpdateTogglesBlock extends ConsumerStatefulWidget {
  const _UpdateTogglesBlock();

  @override
  ConsumerState<_UpdateTogglesBlock> createState() =>
      _UpdateTogglesBlockState();
}

class _UpdateTogglesBlockState extends ConsumerState<_UpdateTogglesBlock> {
  bool? _onLaunch;
  bool? _announce;
  String _skipped = '';

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final a = await UpdateState.checkOnLaunch();
    final b = await UpdateState.announceUpdates();
    final s = await UpdateState.skippedTag();
    if (mounted) {
      setState(() {
        _onLaunch = a;
        _announce = b;
        _skipped = s;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    // Nothing renders until both prefs are read — a switch that flips itself a
    // frame after you look at it reads as a bug.
    if (_onLaunch == null || _announce == null) {
      return const SizedBox(height: 8);
    }
    return Column(
      children: [
        _ToggleRow(
          icon: Icons.cloud_sync_rounded,
          tint: const Color(0xFF80CBC4),
          title: "Check on launch",
          subtitle: "Look for a new version when Auvy starts",
          value: _onLaunch!,
          onChanged: (v) async {
            setState(() => _onLaunch = v);
            await UpdateState.setCheckOnLaunch(v);
          },
        ),
        const _SectionDivider(),
        _ToggleRow(
          icon: Icons.notifications_active_outlined,
          tint: const Color(0xFFFFCC80),
          title: "Announce new versions",
          subtitle: "Show a banner once per release — never repeated",
          value: _announce!,
          onChanged: (v) async {
            setState(() => _announce = v);
            await UpdateState.setAnnounceUpdates(v);
          },
        ),
        // Only shown when there IS something skipped — otherwise it's a dead row
        // explaining a state you're not in.
        if (_skipped.isNotEmpty) ...[
          const _SectionDivider(),
          _NavRow(
            icon: Icons.undo_rounded,
            tint: const Color(0xFFB0BEC5),
            title: "Un-skip v$_skipped",
            subtitle: "You chose to skip this version — show it again",
            onTap: () async {
              await UpdateState.setSkippedTag('');
              await UpdateState.setLastNotifiedTag('');
              if (mounted) setState(() => _skipped = '');
              if (context.mounted) {
                AnimatedToast.show(context,
                    text: "v$_skipped will be offered again",
                    icon: Icons.undo_rounded,
                    color: ref.read(themeProvider));
              }
            },
          ),
        ],
      ],
    );
  }
}

// Sub-page shells (de-bloating Settings)
//
// These two live in THIS file on purpose: they render the existing private
// `_CacheBlock`/`_UsageBlock`/`_AccountBlock` widgets, which are only visible
// within this library. Keeping them here means the de-bloat is a pure move —
// no widget was rewritten, so no behaviour (including the delete-account flow)
// could change. Sub-pages that DON'T render a private block (Privacy, Theme,
// Stream sources) are separate files built on the same `SettingsSubPage` shell.

typedef _SubSettingsPage = SettingsSubPage;

class StoragePage extends StatelessWidget {
  const StoragePage({super.key});

  @override
  Widget build(BuildContext context) => const _SubSettingsPage(
        title: 'Storage & data',
        children: [_StorageBreakdownBlock(), _CacheBlock(), _UsageBlock()],
      );
}

class AccountPage extends StatelessWidget {
  const AccountPage({super.key});

  @override
  Widget build(BuildContext context) => const _SubSettingsPage(
        title: 'Account & backup',
        children: [_AccountBlock()],
      );
}

/// Compact Settings row for storage, showing live usage so the number you'd have
/// scrolled to read is still visible without opening anything.
class _StorageSummaryRow extends ConsumerWidget {
  const _StorageSummaryRow();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final stats = AudioCacheManager().getCacheStats();
    final limit = ref.watch(playerProvider.select((s) => s.maxCacheSizeMB));
    return _NavRow(
      icon: Icons.sd_storage_rounded,
      tint: const Color(0xFF90CAF9),
      title: "Storage & data",
      subtitle:
          "${stats['totalSizeMB']} of $limit MB used · ${stats['cachedTracks']} cached tracks",
      onTap: () =>
          Navigator.push(context, MainLayout.smoothRoute(const StoragePage())),
    );
  }
}

/// Compact Settings row for privacy. The subtitle names what is currently
/// switched ON rather than saying "History, screenshots" — a privacy row that
/// doesn't tell you your own state is the one row that shouldn't need opening.
class _PrivacySummaryRow extends StatefulWidget {
  const _PrivacySummaryRow();
  @override
  State<_PrivacySummaryRow> createState() => _PrivacySummaryRowState();
}

class _PrivacySummaryRowState extends State<_PrivacySummaryRow> {
  String get _summary {
    final on = <String>[
      if (ListeningPolicy.pauseListeningHistory) 'listening paused',
      if (ListeningPolicy.pauseSearchHistory) 'search paused',
      if (ListeningPolicy.blockScreenshots) 'screenshots blocked',
    ];
    if (on.isEmpty) return 'History and screenshots — nothing restricted';
    return on.join(' · ');
  }

  @override
  Widget build(BuildContext context) {
    return _NavRow(
      icon: Icons.shield_outlined,
      tint: const Color(0xFF80CBC4),
      title: 'Privacy',
      subtitle: _summary,
      // The sub-page mutates ListeningPolicy statics, not a provider, so the
      // summary is refreshed when it pops rather than watched.
      onTap: () async {
        await Navigator.push(
            context, MainLayout.smoothRoute(const PrivacyPage()));
        if (mounted) setState(() {});
      },
    );
  }
}

/// Compact Settings row for the account, surfacing WHO is signed in so the
/// common question is answered without a tap.
class _AccountSummaryRow extends ConsumerWidget {
  const _AccountSummaryRow();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final account = ref.watch(accountProvider);
    final names = <String>[
      if (account.youtube != null) account.youtube!.displayName,
      if (account.discord != null) account.discord!.displayName,
    ];
    return _NavRow(
      icon: Icons.account_circle_rounded,
      tint: const Color(0xFF80D8FF),
      title: "Account & backup",
      subtitle: names.isEmpty
          ? "No accounts connected · cloud backup off"
          : "${names.join(' · ')} · cloud backup",
      onTap: () =>
          Navigator.push(context, MainLayout.smoothRoute(const AccountPage())),
    );
  }
}

/// Spotify-style "Autoplay". Backed by [ListeningPolicy.autoplay], which
/// `_topUpQueueInner` genuinely checks — this is not a decorative switch.
class _AutoplayRow extends ConsumerStatefulWidget {
  const _AutoplayRow();

  @override
  ConsumerState<_AutoplayRow> createState() => _AutoplayRowState();
}

class _AutoplayRowState extends ConsumerState<_AutoplayRow> {
  // Mirrors the static so the switch is instant; ListeningPolicy is already
  // loaded by the time Settings can be opened.
  late bool _value = ListeningPolicy.autoplay;

  @override
  Widget build(BuildContext context) {
    return _ToggleRow(
      icon: Icons.auto_mode_rounded,
      tint: const Color(0xFFCE93D8),
      title: "Autoplay similar music",
      subtitle: "Keep playing when the queue ends — off lets albums finish",
      value: _value,
      onChanged: (v) async {
        setState(() => _value = v);
        await ListeningPolicy.setAutoplay(v);
      },
    );
  }
}

/// Offline mode. `ConnectivityState.isOffline` already folds this in, so every
/// existing gate (preload, prefetch, top-up, stream resolution) honours it —
/// the mechanism existed but had no way to be switched on.
class _OfflineModeRow extends ConsumerWidget {
  const _OfflineModeRow();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final conn = ref.watch(connectivityProvider);
    return _ToggleRow(
      icon: Icons.cloud_off_rounded,
      tint: const Color(0xFFFFAB91),
      title: "Offline mode",
      subtitle: conn.isInOfflineMode
          ? "Only downloaded and cached music will play"
          : "Play only what's already on this device",
      value: conn.isInOfflineMode,
      onChanged: (_) =>
          ref.read(connectivityProvider.notifier).toggleOfflineMode(),
    );
  }
}

/// App-icon picker (HYDRV's launcher-icon switching).
///
/// The swatches preview the Flutter assets; the launcher itself reads the
/// generated `res/mipmap-*/ic_launcher_<variant>.png` resources, since a launcher
/// can't see Flutter assets.
class _AppIconPickerRow extends ConsumerStatefulWidget {
  const _AppIconPickerRow();

  @override
  ConsumerState<_AppIconPickerRow> createState() => _AppIconPickerRowState();
}

class _AppIconPickerRowState extends ConsumerState<_AppIconPickerRow> {
  String? _current;

  @override
  void initState() {
    super.initState();
    AppIconService.current().then((v) {
      if (mounted) setState(() => _current = v);
    });
  }

  Future<void> _pick(AppIconOption opt) async {
    if (_current == opt.variant) return;
    HapticService.selection();
    final themeColor = ref.read(themeProvider);
    final ok = await AppIconService.setIcon(opt.variant);
    if (!mounted) return;
    if (ok) {
      setState(() => _current = opt.variant);
      AnimatedToast.show(context,
          text: "Icon set to ${opt.label} — your launcher may take a moment",
          icon: Icons.check_rounded,
          color: themeColor);
    } else {
      AnimatedToast.show(context,
          text: "Couldn't change the icon on this device",
          icon: Icons.error_outline_rounded,
          color: Colors.orange);
    }
  }

  @override
  Widget build(BuildContext context) {
    final themeColor = ref.watch(themeProvider);
    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 14, 14, 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(children: [
            const _IconChip(icon: Icons.apps_rounded, tint: Color(0xFFFFD54F)),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text("App icon",
                      style: TextStyle(
                          color: Colors.white,
                          fontWeight: FontWeight.w600,
                          fontSize: 14.5)),
                  const SizedBox(height: 2),
                  Text("Change how Auvy looks on your home screen",
                      style: TextStyle(
                          color: Colors.white.withOpacity(0.66), fontSize: 11.5)),
                ],
              ),
            ),
          ]),
          const SizedBox(height: 14),
          // Horizontal strip: six 56px swatches don't fit a phone width, and a
          // wrap would make the section tall again right after de-bloating it.
          SizedBox(
            height: 74,
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              itemCount: AppIconService.options.length,
              separatorBuilder: (_, _) => const SizedBox(width: 12),
              itemBuilder: (ctx, i) {
                final opt = AppIconService.options[i];
                final selected = _current == opt.variant;
                return GestureDetector(
                  onTap: () => _pick(opt),
                  child: Column(
                    children: [
                      AnimatedContainer(
                        duration: const Duration(milliseconds: 180),
                        width: 52,
                        height: 52,
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(14),
                          border: Border.all(
                              color: selected ? themeColor : Colors.white.withOpacity(0.10),
                              width: selected ? 2.2 : 1),
                        ),
                        padding: const EdgeInsets.all(3),
                        child: ClipRRect(
                          borderRadius: BorderRadius.circular(11),
                          child: Image.asset(opt.asset,
                              fit: BoxFit.cover, filterQuality: FilterQuality.medium),
                        ),
                      ),
                      const SizedBox(height: 5),
                      Text(opt.label,
                          style: TextStyle(
                              color: selected
                                  ? themeColor
                                  : Colors.white.withOpacity(0.66),
                              fontSize: 10,
                              fontWeight: selected ? FontWeight.w800 : FontWeight.w600)),
                    ],
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

/// Storage broken down by kind, with a proportional bar.
///
/// Answers the question the single "Storage Used" figure couldn't: WHY Auvy is
/// taking up space, and which part is safe to reclaim. Downloads are called out
/// as protected because the cache limit doesn't apply to them and they're never
/// auto-evicted — deleting those is a deliberate act, not housekeeping.
class _StorageBreakdownBlock extends ConsumerStatefulWidget {
  const _StorageBreakdownBlock();

  @override
  ConsumerState<_StorageBreakdownBlock> createState() =>
      _StorageBreakdownBlockState();
}

class _StorageBreakdownBlockState extends ConsumerState<_StorageBreakdownBlock> {
  Map<String, dynamic> _b = const {};

  @override
  void initState() {
    super.initState();
    _reload();
  }

  ///"RECALCULATE" HAS TO ACTUALLY RE-MEASURE. It used to re-read the index —
  /// the same bookkeeping the number already came from, so a file deleted
  /// outside the app kept being counted no matter how many times it was pressed.
  /// Reconciling against disk first is what makes the button mean what it says.
  Future<void> _reload() async {
    await AudioCacheManager().reconcileCacheSizes();
    if (!mounted) return;
    setState(() => _b = AudioCacheManager().getStorageBreakdown());
  }

  static String _mb(int bytes) {
    if (bytes <= 0) return '0 MB';
    final mb = bytes / 1024 / 1024;
    if (mb < 0.1) return '<0.1 MB';
    if (mb >= 1024) return '${(mb / 1024).toStringAsFixed(2)} GB';
    return '${mb.toStringAsFixed(mb < 10 ? 1 : 0)} MB';
  }

  @override
  Widget build(BuildContext context) {
    if (_b.isEmpty) return const SizedBox(height: 8);
    final themeColor = ref.watch(themeProvider);

    final auto = (_b['autoBytes'] as int?) ?? 0;
    final dl = (_b['downloadBytes'] as int?) ?? 0;
    final img = (_b['imageBytes'] as int?) ?? 0;
    final lyrics = (_b['lyricsBytes'] as int?) ?? 0;
    final total = (_b['totalBytes'] as int?) ?? 0;

    final segments = <({String label, int bytes, Color color, String detail})>[
      (
        label: 'Downloads',
        bytes: dl,
        color: const Color(0xFF80D8FF),
        detail: '${_b['downloadCount']} tracks · kept until you remove them',
      ),
      (
        label: 'Streaming cache',
        bytes: auto,
        color: themeColor,
        detail: '${_b['autoCount']} tracks · evicted oldest-first',
      ),
      (
        label: 'Cover art',
        bytes: img,
        color: const Color(0xFFCE93D8),
        detail: 'Re-downloaded on demand',
      ),
      (
        label: 'Lyrics',
        bytes: lyrics,
        color: const Color(0xFFA5D6A7),
        detail: 'Saved with the track · re-fetched if missing',
      ),
    ];

    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 14, 14, 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(children: [
            const _IconChip(icon: Icons.pie_chart_rounded, tint: Color(0xFFB39DDB)),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text("What's using space",
                      style: TextStyle(
                          color: Colors.white,
                          fontWeight: FontWeight.w600,
                          fontSize: 14.5)),
                  const SizedBox(height: 2),
                  Text("${_mb(total)} total on this device",
                      style: TextStyle(
                          color: Colors.white.withOpacity(0.66), fontSize: 11.5)),
                ],
              ),
            ),
            IconButton(
              tooltip: 'Recalculate',
              icon: Icon(Icons.refresh_rounded,
                  size: 18, color: Colors.white.withOpacity(0.5)),
              onPressed: _reload,
            ),
          ]),
          const SizedBox(height: 14),
          // Proportional bar. Hidden entirely at zero rather than shown as an
          // empty trough that looks broken.
          if (total > 0)
            ClipRRect(
              borderRadius: BorderRadius.circular(4),
              child: SizedBox(
                height: 7,
                child: Row(
                  children: [
                    for (final s in segments)
                      if (s.bytes > 0)
                        Expanded(
                          flex: (s.bytes / total * 1000).round().clamp(1, 1000),
                          child: ColoredBox(color: s.color),
                        ),
                  ],
                ),
              ),
            ),
          const SizedBox(height: 14),
          for (final s in segments)
            Padding(
              padding: const EdgeInsets.only(bottom: 10),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Container(
                    width: 9,
                    height: 9,
                    margin: const EdgeInsets.only(top: 4, right: 10),
                    decoration: BoxDecoration(
                        color: s.bytes > 0
                            ? s.color
                            : Colors.white.withOpacity(0.14),
                        shape: BoxShape.circle),
                  ),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(s.label,
                            style: const TextStyle(
                                color: Colors.white,
                                fontSize: 13,
                                fontWeight: FontWeight.w600)),
                        const SizedBox(height: 1),
                        Text(s.detail,
                            style: TextStyle(
                                color: Colors.white.withOpacity(0.66),
                                fontSize: 10.5)),
                      ],
                    ),
                  ),
                  Text(_mb(s.bytes),
                      style: TextStyle(
                          color: Colors.white.withOpacity(0.72),
                          fontSize: 12.5,
                          fontWeight: FontWeight.w700)),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

/// Reduce motion — drops the travel from navigation transitions, keeping a short
/// cross-fade. Writes straight through to [HydrvMotion] so it applies on the very
/// next navigation, with no restart.
class _ReduceMotionRow extends ConsumerStatefulWidget {
  const _ReduceMotionRow();

  @override
  ConsumerState<_ReduceMotionRow> createState() => _ReduceMotionRowState();
}

class _ReduceMotionRowState extends ConsumerState<_ReduceMotionRow> {
  late bool _value = ListeningPolicy.reduceMotion;

  @override
  Widget build(BuildContext context) {
    return _ToggleRow(
      icon: Icons.motion_photos_off_rounded,
      tint: const Color(0xFF9FA8DA),
      title: "Reduce motion",
      subtitle: "Pages cross-fade instead of sliding",
      value: _value,
      onChanged: (v) async {
        setState(() => _value = v);
        await ListeningPolicy.setReduceMotion(v);
      },
    );
  }
}

// Intelligence

/// Discovery balance. Genuinely wired: [ListeningPolicy.discoveryBias] is read by
/// `_scoreAndRankRecommendations`, where it scales the learned-taste terms against
/// the novelty bonus. Not a decorative slider.
class _DiscoveryBiasBlock extends ConsumerStatefulWidget {
  const _DiscoveryBiasBlock();

  @override
  ConsumerState<_DiscoveryBiasBlock> createState() =>
      _DiscoveryBiasBlockState();
}

class _DiscoveryBiasBlockState extends ConsumerState<_DiscoveryBiasBlock> {
  late double _value = ListeningPolicy.discoveryBias;

  String get _label {
    if (_value < 0.2) return 'Mostly what you know';
    if (_value < 0.4) return 'Leaning familiar';
    if (_value < 0.6) return 'Balanced';
    if (_value < 0.8) return 'Leaning new';
    return 'Mostly new music';
  }

  @override
  Widget build(BuildContext context) {
    final themeColor = ref.watch(themeProvider);
    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 14, 14, 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(children: [
            const _IconChip(
                icon: Icons.explore_rounded, tint: Color(0xFF80DEEA)),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text("Discovery",
                      style: TextStyle(
                          color: Colors.white,
                          fontWeight: FontWeight.w600,
                          fontSize: 14.5)),
                  const SizedBox(height: 2),
                  Text("How adventurous autoplay and radio should be",
                      style: TextStyle(
                          color: Colors.white.withOpacity(0.66), fontSize: 11.5)),
                ],
              ),
            ),
          ]),
          const SizedBox(height: 6),
          SliderTheme(
            data: SliderTheme.of(context).copyWith(
              trackHeight: 3,
              thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 7),
              overlayShape: const RoundSliderOverlayShape(overlayRadius: 14),
            ),
            child: Slider(
              value: _value,
              min: 0.0,
              max: 1.0,
              divisions: 10,
              activeColor: themeColor,
              inactiveColor: Colors.white.withOpacity(0.12),
              // Written on release, not on every tick: each change is a disk
              // write, and dragging would fire dozens.
              onChanged: (v) => setState(() => _value = v),
              onChangeEnd: (v) => ListeningPolicy.setDiscoveryBias(v),
            ),
          ),
          Padding(
            padding: const EdgeInsets.only(left: 4, bottom: 4),
            child: Text(_label,
                style: TextStyle(
                    color: themeColor,
                    fontSize: 11.5,
                    fontWeight: FontWeight.w700)),
          ),
        ],
      ),
    );
  }
}

/// Wipes the learned taste model. Separate from "clear listening history"
/// because they answer different questions: history is the RECORD of what you
/// played, the taste model is the CONCLUSIONS drawn from it. Someone who wants
/// better recommendations wants the conclusions gone, not their stats.
class _ResetTasteRow extends ConsumerWidget {
  const _ResetTasteRow();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return _NavRow(
      icon: Icons.psychology_rounded,
      tint: const Color(0xFFFFAB91),
      title: "Reset taste profile",
      subtitle: "Forget learned preferences and start fresh",
      onTap: () async {
        final themeColor = ref.read(themeProvider);
        final confirmed = await showDialog<bool>(
          context: context,
          builder: (ctx) => AlertDialog(
        // Surface/shape/typography come from ThemeData.dialogTheme. See main.dart.
            title: const Text('Reset taste profile?',
                style: TextStyle(color: Colors.white, fontSize: 17)),
            content: Text(
              'Auvy will forget the genres, artists and time-of-day patterns it '
              'has learned.\n\nYour playlists, downloads, liked songs, play counts, '
              'stats and hidden tracks are all kept — only the predictions are '
              'cleared.',
              style: TextStyle(
                  color: Colors.white.withOpacity(0.78), fontSize: 13.5, height: 1.5),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: const Text('Cancel',
                    style: TextStyle(color: Colors.white54)),
              ),
              TextButton(
                onPressed: () => Navigator.pop(ctx, true),
                child: Text('Reset',
                    style: TextStyle(
                        color: themeColor, fontWeight: FontWeight.w800)),
              ),
            ],
          ),
        );
        if (confirmed != true) return;
        HapticService.medium();
        await ref.read(intelligenceProvider.notifier).resetTasteModel();
        if (context.mounted) {
          AnimatedToast.show(context,
              text: "Taste profile reset",
              icon: Icons.psychology_rounded,
              color: themeColor);
        }
      },
    );
  }
}

