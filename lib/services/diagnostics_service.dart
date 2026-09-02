import 'dart:io';

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
import 'package:auvy/services/listening_policy.dart';
import 'package:auvy/services/stream_resolver.dart';
import 'package:auvy/services/update_state.dart';

// EXPORT DIAGNOSTICS — ported from HYDRV.
//
// A bug report that says "music stopped working" is unactionable; the same
// report with the build, the Android version, which stream sources are enabled
// and whether the resolver's circuit breaker is open usually answers itself.
//
// REDACTION IS BY ALLOWLIST, NOT BY FILTER. Nothing here iterates
// SharedPreferences and prints what it finds — every line is a field this file
// names explicitly. That is the only design that stays safe as the app grows: a
// denylist would silently start leaking the next credential someone adds.
// Specifically NEVER included: cookies and the YouTube session, the Discord
// gateway token, Firebase/account identifiers, email addresses, playlist and
// track contents, search queries, listening history.
//
// The report is shown to the user in full BEFORE it can be shared. A diagnostic
// export the user can't read first is just an upload.

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
      final android = await DeviceInfoPlugin().androidInfo;
      b.writeln('Device:       ${android.manufacturer} ${android.model}');
      b.writeln('Android:      ${android.version.release} (SDK ${android.version.sdkInt})');
      b.writeln('ABIs:         ${android.supportedAbis.join(", ")}');
      b.writeln('Physical:     ${android.isPhysicalDevice}');
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
      // THE LIMIT BELONGS ON THIS LINE, NOT THE TOTAL. It governs the auto
      // cache alone — downloads are exempt and never evicted, so printing the
      // total "of N MB limit" described a rule that does not exist, and read as
      // over-limit the moment downloads outgrew it.
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
    b.writeln('Discord RPC:     ${_yesNo(prefs.getBool('auvy_discord_rpc_enabled') ?? false)}');
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

    b.writeln('── Notes ──');
    b.writeln('This report contains no accounts, tokens, cookies, queries or');
    b.writeln('library contents. Every line above is a field Auvy names');
    b.writeln('explicitly (see DiagnosticsService).');

    return b.toString();
  }

  /// Writes the report to a temp file and opens the share sheet.
  ///
  /// A FILE rather than share text: reports run past what most share targets
  /// will accept inline, and a `.txt` attachment survives being forwarded into
  /// an issue tracker intact.
  static Future<void> share(String report) async {
    try {
      final dir = await getTemporaryDirectory();
      // Fixed name: re-exporting overwrites rather than littering the temp
      // directory with a file per attempt.
      final file = File('${dir.path}/auvy-diagnostics.txt');
      await file.writeAsString(report);
      await Share.shareXFiles(
        [XFile(file.path, mimeType: 'text/plain')],
        subject: 'Auvy diagnostics',
      );
    } catch (_) {
      // Sharing the file failed (no temp dir, no share target) — fall back to
      // plain text so the report is never trapped in the app.
      await Share.share(report, subject: 'Auvy diagnostics');
    }
  }

  /// The exception TYPE only, never its message.
  ///
  /// This is a real leak channel, not defensiveness. A failure inside the
  /// storage breakdown throws `FileSystemException`, whose message embeds the
  /// PATH it choked on, and Auvy's download paths contain the artist and track
  /// name. Interpolating `$e` would put a song title into a report the user is
  /// about to hand to a stranger, on exactly the code path nobody tests.
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
