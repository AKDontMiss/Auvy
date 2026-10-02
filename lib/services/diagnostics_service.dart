import 'dart:io';
import 'dart:ui' show Rect;

import 'package:device_info_plus/device_info_plus.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:auvy/core/net/circuit_breaker.dart';
import 'package:auvy/logic/audio_cache_manager.dart';
import 'package:auvy/providers/connectivity_provider.dart';
import 'package:auvy/services/cloud_sync_service.dart';
import 'package:auvy/services/catalog_api_clients.dart';
import 'package:auvy/services/event_log.dart';
import 'package:auvy/services/listening_policy.dart';
import 'package:auvy/services/stream_resolver.dart';
import 'package:auvy/services/update_state.dart';

// Export diagnostics (ported from HYDRV).
//
// "Music stopped working" is hard to act on; the same report with the build,
// OS version, enabled stream sources and the resolver's circuit-breaker state
// often answers itself.
//
// Redaction by allowlist: nothing iterates SharedPreferences; every line is a
// field named here, so a newly added credential can't leak by default. Never
// included: cookies and the YouTube session, the app token, Firebase/account
// ids, email addresses, playlist and track contents, search queries, listening
// history. (The event log section below does name recently played tracks, and
// the report says so.)
//
// The user sees the full report before it can be shared.

class DiagnosticsService {
  const DiagnosticsService._();

  /// Builds the report. Every step is individually guarded: a diagnostics
  /// export exists for the case where something is already broken, so one
  /// unreadable value must degrade to "unavailable" rather than produce nothing.
  static Future<String> build() async {
    final b = StringBuffer();
    final prefs = await SharedPreferences.getInstance();

    b.writeln('AUVY DIAGNOSTICS');
    // Local time with the offset spelled out — a bare local timestamp from an
    // unknown timezone is worse than useless when correlating logs.
    final now = DateTime.now();
    b.writeln('Generated: ${now.toIso8601String()} (UTC${_offset(now)})');
    b.writeln();

    b.writeln('── App ──');
    try {
      final info = await PackageInfo.fromPlatform();
      b.writeln('Version:      ${info.version}+${info.buildNumber}');
      b.writeln('Package:      ${info.packageName}');
    } catch (e) {
      b.writeln('Version:      unavailable (${_why(e)})');
    }
    // Compile-time, so it can't be wrong: a "release" report from a debug build
    // would send every subsequent conclusion the wrong way.
    b.writeln('Build mode:   ${_buildMode()}');
    b.writeln();

    b.writeln('── Device ──');
    try {
      if (Platform.isIOS) {
        final ios = await DeviceInfoPlugin().iosInfo;
        final raw = ios.modelName.isNotEmpty ? ios.modelName : ios.model;
        b.writeln('Device:       Apple $raw (${ios.utsname.machine})');
        b.writeln('iOS:          ${ios.systemName} ${ios.systemVersion}');
        b.writeln('Physical:     ${ios.isPhysicalDevice}');
      } else if (Platform.isAndroid) {
        final android = await DeviceInfoPlugin().androidInfo;
        b.writeln('Device:       ${android.manufacturer} ${android.model}');
        b.writeln('Android:      ${android.version.release} (SDK ${android.version.sdkInt})');
        b.writeln('ABIs:         ${android.supportedAbis.join(", ")}');
        b.writeln('Physical:     ${android.isPhysicalDevice}');
      } else {
        b.writeln('Device:       ${Platform.operatingSystem}');
        b.writeln('OS:           ${Platform.operatingSystemVersion}');
      }
    } catch (e) {
      b.writeln('Device:       unavailable (${_why(e)})');
    }
    b.writeln('Locale:       ${Platform.localeName}');
    b.writeln();

    b.writeln('── Playback & catalogue ──');
    b.writeln('Content region:   ${ListeningPolicy.effectiveCountry}'
        '${ListeningPolicy.contentCountry.isEmpty ? " (from device)" : " (chosen)"}');
    b.writeln('Content language: ${ListeningPolicy.effectiveLanguage}');
    b.writeln('Stream sources:   ${CatalogApiClients.streamOrder.map((c) => "${c.clientName} ${c.clientVersion}").join(" → ")}');
    final disabled = CatalogApiClients.disabledStreamSources;
    b.writeln('Sources off:      ${disabled.isEmpty ? "none" : disabled.join(", ")}');
    // An OPEN breaker is the single most explanatory line in the whole report:
    // it means resolution has been failing repeatedly and Auvy is backing off.
    b.writeln('Resolver circuit: ${_circuit(StreamResolver().circuitState)}');
    b.writeln('Autoplay:         ${ListeningPolicy.autoplay}');
    b.writeln('Offline mode:     ${prefs.getBool(ConnectivityNotifier.kOfflineMode) ?? false}');
    b.writeln('Data saver:       ${_dataSaver(prefs.getInt('data_saver_mode'))}');
    b.writeln();

    b.writeln('── Storage ──');
    try {
      final s = AudioCacheManager().getStorageBreakdown();
      b.writeln('Downloads:    ${_mb(s['downloadBytes'])} (${s['downloadCount']} tracks)');
      // The limit belongs on the auto-cache line: it governs the auto-cache only
      // (downloads are exempt).
      b.writeln('Auto cache:   ${_mb(s['autoBytes'])} (${s['autoCount']} tracks)'
          ' of ${s['maxSizeMB']} MB limit');
      b.writeln('Cover art:    ${_mb(s['imageBytes'])}');
      b.writeln('Lyrics:       ${_mb(s['lyricsBytes'])}');
      b.writeln('Total:        ${_mb(s['totalBytes'])}');
    } catch (e) {
      b.writeln('Storage:      unavailable (${_why(e)})');
    }
    b.writeln();

    // Presence only — whether a connection EXISTS, never who it belongs to.
    b.writeln('── Connections (presence only) ──');
    b.writeln('YouTube session: ${_yesNo(prefs.getBool('yt_session_active') ?? false)}');
    b.writeln('Cloud backup:    ${_yesNo(CloudSyncService.instance.isActive)}'
        '${CloudSyncService.isAvailable ? "" : " (Firebase unavailable)"}');
    b.writeln();

    b.writeln('── Privacy switches ──');
    b.writeln('Listening history paused: ${ListeningPolicy.pauseListeningHistory}');
    b.writeln('Search history paused:    ${ListeningPolicy.pauseSearchHistory}');
    b.writeln('Screenshots blocked:      ${ListeningPolicy.blockScreenshots}');
    b.writeln();

    b.writeln('── Updates ──');
    try {
      final at = await UpdateState.lastCheckedAt();
      b.writeln('Last checked: ${at == null ? "never" : at.toIso8601String()}');
      final seen = await UpdateState.lastSeenTag();
      b.writeln('Newest seen:  ${seen.isEmpty ? "none" : seen}');
      b.writeln('Check on launch: ${await UpdateState.checkOnLaunch()}');
    } catch (e) {
      b.writeln('Updates:      unavailable (${_why(e)})');
    }
    b.writeln();

    // The event log. Everything above is a snapshot of now; the event log records
    // how things got that way: decisions rather than ticks (which lyrics source won
    // and whether it was version-checked, which audio a track was swapped to, what
    // a cloud merge did, why a gate answered as it did). Release builds drop
    // print(), so this is what an ordinary build can say about itself.
    final events = EventLog.entries;
    b.writeln();
    b.writeln('── Recent events (newest last, ${events.length}) ──');
    if (events.isEmpty) {
      b.writeln('Nothing recorded yet this session.');
    } else {
      b.writeln('Session started ${EventLog.startedAt.toIso8601String()}; '
          'stamps below are mm:ss.mmm from then.');
      for (final e in events) {
        b.writeln(e);
      }
    }
    b.writeln();

    b.writeln('── Notes ──');
    b.writeln('This report contains no accounts, tokens, cookies or search');
    b.writeln('queries. Every field above the event log is one Auvy names');
    b.writeln('explicitly (see DiagnosticsService).');
    // Say plainly that the event log names tracks and playlists, so the user can
    // decide what to share based on an accurate description.
    b.writeln('The event log DOES name tracks and playlists you played, so');
    b.writeln('that a problem can be tied to a specific song. Read it before');
    b.writeln('sharing if that matters to you.');

    return b.toString();
  }

  /// Writes the report to a temp file and opens the share sheet. A file rather
  /// than share text, because reports exceed what many targets accept inline and a
  /// `.txt` survives being forwarded.
  ///
  /// [origin] is the iPad share-sheet anchor, supplied by the caller (see
  /// `shareOriginOf`). Without it share_plus can't present on iPad, and the text
  /// fallback below would fail the same way.
  static Future<void> share(String report, {Rect? origin}) async {
    try {
      final dir = await getTemporaryDirectory();
      // Fixed name: re-exporting overwrites rather than littering the temp
      // directory with a file per attempt.
      final file = File('${dir.path}/auvy-diagnostics.txt');
      await file.writeAsString(report);

      // iOS only: keep a second copy in Documents ("On My iPhone → Auvy"). The temp
      // directory isn't visible in Files, so a report whose share sheet was dismissed
      // would otherwise be unreachable.
      if (Platform.isIOS) {
        try {
          final docs = await getApplicationDocumentsDirectory();
          await File('${docs.path}/auvy-diagnostics.txt').writeAsString(report);
        } catch (_) {
          // Best effort: the share below is still the primary route out.
        }
      }

      await Share.shareXFiles(
        [XFile(file.path, mimeType: 'text/plain')],
        subject: 'Auvy diagnostics',
        sharePositionOrigin: origin,
      );
    } catch (_) {
      // Sharing the file failed: fall back to plain text so the report isn't trapped.
      // Swallowed, because on iOS the Documents copy above is still a valid way out.
      try {
        await Share.share(report,
            subject: 'Auvy diagnostics', sharePositionOrigin: origin);
      } catch (_) {}
    }
  }

  /// The exception type only, never its message: a FileSystemException embeds the
  /// path, and download paths contain artist and track names.
  static String _why(Object e) => e.runtimeType.toString();

  static String _buildMode() {
    if (const bool.fromEnvironment('dart.vm.product')) return 'release';
    if (const bool.fromEnvironment('dart.vm.profile')) return 'profile';
    return 'debug';
  }

  static String _offset(DateTime t) {
    final d = t.timeZoneOffset;
    final sign = d.isNegative ? '-' : '+';
    final h = d.inHours.abs().toString().padLeft(2, '0');
    final m = (d.inMinutes.abs() % 60).toString().padLeft(2, '0');
    return '$sign$h:$m';
  }

  static String _mb(Object? bytes) {
    final v = bytes is int ? bytes : 0;
    return '${(v / 1024 / 1024).toStringAsFixed(1)} MB';
  }

  static String _yesNo(bool v) => v ? 'yes' : 'no';

  static String _dataSaver(int? index) {
    if (index == null || index < 0 || index >= DataSaverMode.values.length) {
      return 'off';
    }
    return DataSaverMode.values[index].name;
  }

  static String _circuit(CircuitState s) {
    switch (s) {
      case CircuitState.open:
        return 'OPEN — resolution is failing, requests are being short-circuited';
      case CircuitState.halfOpen:
        return 'half-open — recovering';
      case CircuitState.closed:
        return 'closed (healthy)';
    }
  }
}
