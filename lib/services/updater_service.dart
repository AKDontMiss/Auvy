import 'dart:convert';
import 'dart:io';
import 'package:path_provider/path_provider.dart';
import 'package:open_filex/open_filex.dart';
import 'package:flutter/material.dart';
import 'package:auvy/logic/session_cookie_manager.dart';
import 'package:http/http.dart' as http;
import 'package:package_info_plus/package_info_plus.dart';
import 'package:auvy/presentation/widgets/animated_toast.dart';
import 'package:auvy/services/update_state.dart';
import 'package:auvy/core/backend_config.dart';

class UpdaterService {
  // NO repoOwner/repoName CONSTANTS HERE ANY MORE, and their absence is the
  // honest state of things.
  //
  // They existed to build api.github.com URLs, then survived as decoration once
  // the Worker took over the calls — the last consumer was one 404 error message,
  // and when that message was rewritten they became dead code carrying a comment
  // that claimed they were still used. A constant that drives nothing but reads
  // like configuration is worse than no constant: the next person to change where
  // releases live would edit it and see no effect.
  //
  // The single source of truth is RELEASE_OWNER / RELEASE_REPO in
  // server/c1-auth-worker/worker.js. Note they are SEPARATE from COVERS_REPO
  // there: releases come from the public repo, the cover library from the private
  // one.



  /// Why the check goes through the Worker, not api.github.com
  ///
  /// The original reason no longer applies, AND the proxy still earns its keep.
  ///
  /// It was built so the releases repo could be PRIVATE: GitHub answers 404 to an
  /// unauthenticated caller for a private repo, so the update check would have
  /// broken for everyone, and shipping a token in the APK was never an option —
  /// anyone can unzip it and read the string out.
  ///
  /// Adopting GPL-3.0 ended that: the licence obliges the source to be available
  /// to whoever receives the APK, so releases and source now live together in a
  /// PUBLIC repo and there is nothing left to hide.
  ///
  /// What still justifies the proxy is rate limiting. Unauthenticated GitHub API
  /// calls are capped at 60/hour PER IP — a handful of users behind one mobile
  /// carrier NAT share that between them — while the Worker's token raises it to
  /// 5,000 and caches the answer for everybody. It also keeps the download path
  /// unchanged: `/release/latest` returns the same shape parsed below, with each
  /// APK's `browser_download_url` pointing at `/release/asset/{id}`, which 302s to
  /// GitHub's short-lived signed URL. The bytes go straight from GitHub to the
  /// device; the Worker only ever passes a redirect.
  static String get updateHost => BackendConfig.workerHost;

  /// SECURITY — the only hosts an update APK may be downloaded from.
  ///
  /// The download URL arrives inside the GitHub API's JSON response, so it is
  /// remote input: without this check, a tampered/spoofed response could point
  /// the in-app installer at an arbitrary APK (the app holds
  /// REQUEST_INSTALL_PACKAGES). GitHub serves release assets from these hosts
  /// and redirects between them.
  /// A getter, not a `const` set: [updateHost] now comes from a `--dart-define`
  /// (see BackendConfig) so it is not a compile-time constant, and a const set
  /// cannot contain it. Built per call, which is fine — this runs a handful of
  /// times per update check, not per frame.
  static Set<String> get _releaseHosts => {
        'github.com',
        'api.github.com',
        'objects.githubusercontent.com',
        'release-assets.githubusercontent.com',
        'codeload.github.com',
        // The Worker's asset route, which 302s to one of the GitHub hosts above.
        //
        // THIS IS WHY THE ALLOWLIST HAD TO FOLLOW THE CONFIG. With the host
        // hardcoded, a fork's build would have trusted the UPSTREAM Worker's
        // domain and not its own, so its update downloads would have been
        // rejected as untrusted. Deriving it from the same source keeps the
        // security check and the configuration in agreement.
        updateHost,
      };

  /// True only for an https URL on a GitHub release host.
  static bool isTrustedReleaseUrl(String url) {
    final uri = Uri.tryParse(url);
    if (uri == null || uri.scheme != 'https') return false;
    final host = uri.host.toLowerCase();
    return _releaseHosts.any((h) => host == h || host.endsWith('.$h'));
  }

  /// Trusted host AND actually a package — the bar for anything handed to the
  /// installer.
  ///
  /// A trusted host is not enough on its own. When no APK asset is attached to a
  /// release, the check below falls back to the release's `html_url`, which is
  /// on github.com and therefore "trusted", but it is a WEB PAGE. Downloading
  /// it writes HTML to `auvy_update.apk` and hands that to the package
  /// installer. With the releases repo private that page is a login screen, so
  /// the fallback would fail every single time instead of occasionally.
  static bool isApkDownloadUrl(String url) {
    if (!isTrustedReleaseUrl(url)) return false;
    // Path only — the signed GitHub URL carries a long query string, and the
    // Worker's asset route keeps the filename as the last path segment for
    // exactly this check.
    return Uri.parse(url).path.toLowerCase().endsWith('.apk');
  }

  /// [manualCheck]: user tapped "Check for Updates" in Settings — shows status
  /// toasts and, if an update exists, the full update dialog.
  /// [reminderMode]: silent background check (gated by the Settings toggle) —
  /// shows a DISMISSIBLE banner if an update exists, never a blocking popup.
  static Future<void> checkForUpdates(BuildContext context, Color themeColor,
      {bool manualCheck = false, bool reminderMode = false}) async {
    if (manualCheck) {
      AnimatedToast.show(context, text: "Checking for updates...", icon: Icons.sync, color: themeColor);
    }

    try {
      // A manual check must bypass the edge cache.
      //
      // The Worker caches this response so that a launch stampede costs one
      // GitHub call rather than thousands. That is right for the automatic
      // check, and wrong for the button, which is what someone taps precisely
      // BECAUSE they believe something has changed. It shipped without the
      // distinction and produced the obvious bug: v1.2.4 was published, the app
      // kept reporting "already on the latest version" from a cached v1.2.3, and
      // tapping check again re-read the same cache.
      //
      // The Worker throttles the bypass on its side, so hammering the button
      // cannot turn into hammering GitHub.
      final response = await http.get(
        Uri.parse('https://$updateHost/release/latest'
            '${manualCheck ? '?fresh=1' : ''}'),
        headers: {'User-Agent': 'Auvy-App'},
      ).timeout(const Duration(seconds: 10),
              onTimeout: () => http.Response('', 408));

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);

        final tagName = data['tag_name'] as String?;
        if (tagName == null) {
          if (manualCheck && context.mounted) {
            AnimatedToast.show(context, text: "No releases found on GitHub yet.", icon: Icons.info_outline, color: Colors.orange);
          }
          return;
        }

        // replaceFirst on an ANCHORED pattern, not replaceAll('v'): the old form
        // stripped every 'v' anywhere in the tag, so `v1.2.3-preview` became
        // `1.2.3-preiew`.
        final latestVersion = tagName.trim().replaceFirst(RegExp(r'^[vV]'), '');
        final changelog = data['body'] ?? "Minor bug fixes and improvements.";

        String releaseUrl = data['html_url'] ?? '';
        final assets = data['assets'] as List? ?? [];
        for (final asset in assets) {
          final name = (asset['name'] as String? ?? '').toLowerCase();
          if (name.endsWith('.apk')) {
            final candidate = asset['browser_download_url'] as String? ?? '';
            // Only accept an asset URL that really points at GitHub — see
            // [isTrustedReleaseUrl]. Anything else falls back to opening the
            // release page rather than being fed to the installer.
            if (isApkDownloadUrl(candidate)) releaseUrl = candidate;
            break;
          }
        }
        // Not isTrustedReleaseUrl: html_url passes that and is a web page.
        if (!isApkDownloadUrl(releaseUrl)) releaseUrl = '';

        final packageInfo = await PackageInfo.fromPlatform();
        //`packageInfo.version` is the version NAME only ("1.2.3"); the build
        // number lives separately in `buildNumber`. Recomposing them is required
        // for the build-number tiebreaker in [_isNewerVersion] — without it the
        // local build always read as 0, so ANY remote tag carrying a `+build`
        // would have looked newer and prompted forever.
        final currentVersion = packageInfo.buildNumber.isEmpty
            ? packageInfo.version
            : '${packageInfo.version}+${packageInfo.buildNumber}';

        // Record the check regardless of outcome — Settings shows "Checked N
        // minutes ago" from this, and it must be truthful even when there's
        // nothing new.
        await UpdateState.markChecked();
        await UpdateState.setLastSeenTag(latestVersion);

        if (_isNewerVersion(currentVersion, latestVersion)) {
          if (!context.mounted) return;
          // Reminder mode: a non-blocking banner, NOT a popup.
          if (reminderMode) {
            // HYDRV's rule: announce a given release ONCE. Previously this
            // banner reappeared on every single launch until you installed,
            // which is exactly the nagging that trains people to switch update
            // checks off. Skipped versions are suppressed here too.
            if (!await UpdateState.shouldAnnounce(latestVersion)) return;
            await UpdateState.setLastNotifiedTag(latestVersion);
            if (!context.mounted) return;
            _showUpdateBanner(context, currentVersion, latestVersion, releaseUrl, changelog, themeColor);
            return;
          }
          if (manualCheck) {
            AnimatedToast.show(context, text: "Update found!", icon: Icons.download_rounded, color: themeColor);
          }
          _showUpdateDialog(context, currentVersion, latestVersion, releaseUrl, changelog, themeColor);
        } else {
          if (!context.mounted) return;
          if (manualCheck) {
            AnimatedToast.show(context, text: "You are already on the latest version.", icon: Icons.check_circle, color: Colors.green);
          }
        }
      } else if (response.statusCode == 404) {
        // 404 CHANGED MEANING WHEN THE RELEASES REPO BECAME PUBLIC.
        //
        // It used to say "No public releases — the repo is private", which was
        // right while releases lived in a private repo: GitHub answers 404 (not
        // 403) for a repo the caller cannot see, because a private repo must not
        // leak its own existence.
        //
        // Against a public repo that wording is simply untrue, and it points the
        // user at a permissions problem that does not exist. Now the only way to
        // get here is that no release has been published yet.
        if (manualCheck && context.mounted) {
          AnimatedToast.show(context,
              text: "No releases published yet.",
              icon: Icons.inbox_rounded,
              color: Colors.orange);
        }
      } else if (response.statusCode == 403 || response.statusCode == 429) {
        // Do NOT auto-retry: the previous `await delay(5s); return checkForUpdates(...)`
        // self-recursed forever while the page was open, hammering GitHub's
        // unauthenticated API (60 req/hr) and keeping it rate-limited. Just
        // inform the user; they can tap check again later.
        if (manualCheck && context.mounted) {
          AnimatedToast.show(context, text: "Rate limited. Try again in a few minutes.", icon: Icons.timer_outlined, color: Colors.orange);
        }
      } else {
        if (!context.mounted) return;
        if (manualCheck) {
          AnimatedToast.show(context, text: "Could not fetch updates (HTTP ${response.statusCode}).", icon: Icons.error_outline, color: Colors.red);
        }
      }
    } catch (e) {
      print("Update check failed: $e");
      if (!context.mounted) return;
      if (manualCheck) {
        AnimatedToast.show(context, text: "Network error. Could not check for updates.", icon: Icons.wifi_off, color: Colors.red);
      }
    }
  }

  /// Numeric-prefix version compare, modelled on HYDRV's
  /// `ReleaseVersionComparator`.
  ///
  /// The old version fed every dot-separated chunk straight to `int.parse` and
  /// swallowed the throw as "no update". Any real-world tag with a suffix —
  /// `1.2.4-beta`, `v1.2.4+2040`, `1.2.4 (hotfix)` — therefore silently reported
  /// NO update available, which is the worst possible failure direction for an
  /// updater. Now each segment contributes its leading digits and anything
  /// non-numeric is ignored rather than fatal.
  static bool _isNewerVersion(String current, String latest) {
    final c = _versionParts(current);
    final l = _versionParts(latest);
    if (l.isEmpty) return false; // unparseable remote tag → never prompt

    for (var i = 0; i < 3; i++) {
      final cv = i < c.length ? c[i] : 0;
      final lv = i < l.length ? l[i] : 0;
      if (lv > cv) return true;
      if (lv < cv) return false;
    }

    // Version names identical → fall back to the BUILD NUMBER as a tiebreaker.
    //
    // Strict semver treats build metadata as having no precedence, and comparing
    // it as a peer of the version name would be wrong: 1.2.3+2033 must never
    // outrank 1.2.4+9. But for a sideloaded app, shipping 1.2.3+2034 over
    // 1.2.3+2033 is a completely normal release, and ignoring the build number
    // outright meant that update was invisible. Using it ONLY when the three
    // numeric segments tie gives both: correct precedence, and build-only
    // releases still detected.
    final cb = _buildNumber(current);
    final lb = _buildNumber(latest);
    return lb > cb;
  }

  /// Digits after `+` in a version string, or 0 when absent/non-numeric.
  static int _buildNumber(String raw) {
    final plus = raw.indexOf('+');
    if (plus < 0 || plus == raw.length - 1) return 0;
    final digits = RegExp(r'^\d+').firstMatch(raw.substring(plus + 1).trim());
    return digits == null ? 0 : int.parse(digits.group(0)!);
  }

  /// `"v1.2.4-beta+2040"` → `[1, 2, 4]`. Build metadata after `+` is dropped:
  /// it is not part of precedence, and comparing it would make 1.2.3+2033 look
  /// newer than 1.2.4+9.
  static List<int> _versionParts(String raw) {
    final trimmed = raw.trim().replaceFirst(RegExp(r'^[vV]'), '').split('+').first;
    final parts = <int>[];
    for (final seg in trimmed.split('.')) {
      final digits = RegExp(r'^\d+').firstMatch(seg.trim())?.group(0);
      if (digits == null) break; // stop at the first non-numeric segment
      parts.add(int.parse(digits));
    }
    return parts;
  }

  // Release-notes cleanup
  // GitHub release bodies are written in Markdown; showing them raw filled the
  // notes box with literal ##, **, and - noise. Convert to structured lines:
  // headers become section labels, list items become bullet rows, and inline
  // markers (bold/italic/code/links/images) are stripped to plain text.

  static List<UpdateNoteLine> parseReleaseNotes(String raw) {
    final lines =
        raw.replaceAll('\r\n', '\n').replaceAll('\r', '\n').split('\n');
    final out = <UpdateNoteLine>[];
    for (final line in lines) {
      final t = line.trim();
      if (t.isEmpty) continue;
      // Separators / HTML comments are pure noise.
      if (t == '---' || t == '***' || t == '___' || t.startsWith('<!--')) continue;

      final header = RegExp(r'^#{1,6}\s+(.*)$').firstMatch(t);
      if (header != null) {
        final text = _stripInline(header.group(1)!);
        if (text.isNotEmpty) out.add(UpdateNoteLine(text, isHeader: true));
        continue;
      }
      final bullet = RegExp(r'^[-*+]\s+(.*)$').firstMatch(t);
      if (bullet != null) {
        final text = _stripInline(bullet.group(1)!);
        if (text.isNotEmpty) out.add(UpdateNoteLine(text, isBullet: true));
        continue;
      }
      final numbered = RegExp(r'^\d+[.)]\s+(.*)$').firstMatch(t);
      if (numbered != null) {
        final text = _stripInline(numbered.group(1)!);
        if (text.isNotEmpty) out.add(UpdateNoteLine(text, isBullet: true));
        continue;
      }
      final text = _stripInline(t);
      if (text.isNotEmpty) out.add(UpdateNoteLine(text));
    }
    return out;
  }

  static String _stripInline(String s) {
    var t = s;
    // Images → their alt text; links → their label.
    t = t.replaceAllMapped(RegExp(r'!\[([^\]]*)\]\([^)]*\)'), (m) => m.group(1) ?? '');
    t = t.replaceAllMapped(RegExp(r'\[([^\]]+)\]\([^)]*\)'), (m) => m.group(1)!);
    // Bold / italic / strikethrough / inline code markers.
    t = t.replaceAll(RegExp(r'\*\*|__|~~'), '');
    t = t.replaceAllMapped(RegExp(r'(?<![\w*_])[*_]([^*_]+)[*_](?![\w*_])'), (m) => m.group(1)!);
    t = t.replaceAll('`', '');
    return t.trim();
  }

  /// Non-blocking, dismissible "update available" reminder (the toggleable
  /// notification-style nudge) — shown at the top instead of a popup. Tapping
  /// "VIEW" opens the full update dialog; "DISMISS" just hides it.
  static void _showUpdateBanner(BuildContext context, String currentVersion,
      String newVersion, String url, String changelog, Color themeColor) {
    final messenger = ScaffoldMessenger.of(context);
    messenger.clearMaterialBanners();
    Widget pill(String label, VoidCallback onTap,
        {bool filled = false, Color? textColor}) {
      return GestureDetector(
        onTap: onTap,
        behavior: HitTestBehavior.opaque,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
          decoration: BoxDecoration(
            color: filled ? themeColor : Colors.white.withOpacity(0.06),
            borderRadius: BorderRadius.circular(20),
            border:
                filled ? null : Border.all(color: Colors.white.withOpacity(0.10)),
          ),
          child: Text(
            label,
            style: TextStyle(
              color: filled ? Colors.black : (textColor ?? Colors.white70),
              fontSize: 12.5,
              fontWeight: FontWeight.w800,
              letterSpacing: 0.2,
            ),
          ),
        ),
      );
    }

    messenger.showMaterialBanner(
      MaterialBanner(
        // The stock MaterialBanner is stripped to a transparent, padding-less
        // shell and the whole announcement is drawn as our own card below.
        //
        // Left as-is it was the one square, edge-to-edge, M3-default surface in an
        // app whose every other panel is a rounded dark card — it read like a
        // system message from a different program rather than something Auvy said.
        // `actions` cannot be empty, so it takes a zero-size child and the real
        // buttons live inside the card where they can be styled.
        backgroundColor: Colors.transparent,
        surfaceTintColor: Colors.transparent,
        shadowColor: Colors.transparent,
        dividerColor: Colors.transparent,
        elevation: 0,
        padding: EdgeInsets.zero,
        content: Container(
          margin: const EdgeInsets.fromLTRB(12, 8, 12, 0),
          padding: const EdgeInsets.fromLTRB(14, 13, 14, 13),
          decoration: BoxDecoration(
            color: const Color(0xFF17171C),
            borderRadius: BorderRadius.circular(22),
            border: Border.all(color: Colors.white.withOpacity(0.08)),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withOpacity(0.55),
                blurRadius: 30,
                offset: const Offset(0, 12),
              ),
              // The same accent bloom the full update dialog carries, so the
              // nudge and the dialog it opens read as one thing.
              BoxShadow(
                color: themeColor.withOpacity(0.10),
                blurRadius: 30,
                spreadRadius: -10,
                offset: const Offset(0, -8),
              ),
            ],
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(
                children: [
                  Container(
                    width: 38,
                    height: 38,
                    decoration: BoxDecoration(
                      color: themeColor.withOpacity(0.14),
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(color: themeColor.withOpacity(0.25)),
                    ),
                    child: Icon(Icons.system_update_rounded,
                        color: themeColor, size: 20),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text(
                          'Update available',
                          style: TextStyle(
                              color: Colors.white,
                              fontSize: 14.5,
                              fontWeight: FontWeight.w800),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          'Version $newVersion — you have $currentVersion',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                              color: Colors.white.withOpacity(0.72),
                              fontSize: 12,
                              fontWeight: FontWeight.w600),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 13),
              Row(
                children: [
                  // SKIP is stronger than dismiss: it records the tag so this
                  // release is never announced again. Without it the only way to
                  // silence a version you don't want was to turn update checks
                  // off entirely.
                  pill('Skip', () {
                    messenger.hideCurrentMaterialBanner();
                    UpdateState.setSkippedTag(newVersion);
                  }, textColor: Colors.white38),
                  const SizedBox(width: 8),
                  pill('Later', () => messenger.hideCurrentMaterialBanner()),
                  const Spacer(),
                  pill('What changed', () {
                    messenger.hideCurrentMaterialBanner();
                    _showUpdateDialog(context, currentVersion, newVersion, url,
                        changelog, themeColor);
                  }, filled: true),
                ],
              ),
            ],
          ),
        ),
        actions: const [SizedBox.shrink()],
      ),
    );
  }
  static void _showUpdateDialog(BuildContext context, String currentVersion,
      String newVersion, String url, String changelog, Color themeColor) {
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => _UpdateDialog(
        currentVersion: currentVersion,
        newVersion: newVersion,
        downloadUrl: url,
        changelog: changelog,
        themeColor: themeColor,
      ),
    );
  }
}

/// One cleaned-up line of release notes (see UpdaterService.parseReleaseNotes).
class UpdateNoteLine {
  final String text;
  final bool isHeader;
  final bool isBullet;
  const UpdateNoteLine(this.text, {this.isHeader = false, this.isBullet = false});
}

class _UpdateDialog extends StatefulWidget {
  final String currentVersion, newVersion, downloadUrl, changelog;
  final Color themeColor;
  const _UpdateDialog({
    required this.currentVersion,
    required this.newVersion,
    required this.downloadUrl,
    required this.changelog,
    required this.themeColor,
  });
  @override
  State<_UpdateDialog> createState() => _UpdateDialogState();
}

class _UpdateDialogState extends State<_UpdateDialog> {
  double _progress = 0;
  bool _isDownloading = false;
  bool _isDone = false;
  String? _apkPath;
  http.Client? _client;
  bool _cancelled = false;

  /// Abort an in-progress download (the user pressed Cancel — NOT the back
  /// button). Closes the connection and resets to the pre-download state.
  void _cancelDownload() {
    _cancelled = true;
    try { _client?.close(); } catch (_) {}
    if (mounted) setState(() { _isDownloading = false; _progress = 0; });
  }

  @override
  void dispose() {
    _cancelled = true;
    try { _client?.close(); } catch (_) {}
    super.dispose();
  }

  Future<void> _startDownload() async {
    _cancelled = false;
    // SECURITY: never hand the installer a URL that isn't a GitHub release
    // asset. The URL came from a network response, and this app can install
    // packages, so it is checked again here, at the point of use.
    if (!UpdaterService.isApkDownloadUrl(widget.downloadUrl)) {
      AnimatedToast.show(context,
          text: 'This update link is not a verified Auvy release.',
          icon: Icons.gpp_bad_rounded,
          color: Colors.red);
      return;
    }
    setState(() { _isDownloading = true; _progress = 0; });
    try {
      final dir = await getExternalStorageDirectory() ?? await getTemporaryDirectory();
      final path = '${dir.path}/auvy_update.apk';
      // Never install over a leftover from a failed/cancelled run.
      try {
        final stale = File(path);
        if (await stale.exists()) await stale.delete();
      } catch (_) {}

      // Close the last one before taking another.
      //
      // Cancel and dispose both close `_client`, so an abandoned download is
      // covered, but a download that FAILED is not. The catch below shows a
      // toast and leaves the dialog open, so the obvious next move is to press
      // Retry, and that used to overwrite `_client` and orphan the previous
      // one: an http.Client with a live connection pool that nothing could
      // reach any more. Three failed attempts, three open sockets, until the
      // dialog was dismissed.
      try { _client?.close(); } catch (_) {}
      final client = http.Client();
      _client = client;

      // EVERY HOP IS CHECKED, not just the first.
      //
      // The URL above is verified, but `followRedirects` (the default) then
      // chases 302s blindly, and this download ends up in a package installer.
      // The chain is real, not hypothetical: the Worker's asset route redirects
      // to GitHub's signed storage host. So redirects are followed by hand and
      // each Location is run through the same allowlist, which means a hijacked
      // or misconfigured hop cannot walk the installer onto a foreign host.
      http.StreamedResponse response;
      var url = widget.downloadUrl;
      var hops = 0;
      while (true) {
        final request = http.Request('GET', Uri.parse(url))
          ..followRedirects = false;
        // Identify ourselves to OUR Worker, and only to it.
        //
        // The asset route now requires an approved account (the APK used to be
        // downloadable by anyone who knew the hostname). The cookie goes in a
        // header, not the URL, and ONLY on the first hop: after the Worker
        // answers 302 the next hop is a signed GitHub URL on a different host,
        // and forwarding a YouTube credential there would be a real leak.
        if (Uri.parse(url).host == UpdaterService.updateHost) {
          final cookie = await SessionCookieManager().getCookieHeader();
          if (cookie != null && cookie.isNotEmpty) {
            request.headers['X-Auvy-Cookie'] = cookie;
          }
        }
        response = await client.send(request).timeout(
          const Duration(minutes: 2),
          onTimeout: () =>
              throw Exception('Download timed out. Check your connection.'),
        );
        if (response.statusCode < 300 || response.statusCode >= 400) break;
        // Drain the redirect's (empty) body, or the socket stays open for the
        // whole download — five leaked connections per update otherwise.
        try {
          await response.stream.drain();
        } catch (_) {}
        final next = response.headers['location'];
        if (next == null || next.isEmpty) {
          throw Exception('Update server returned a redirect with no target.');
        }
        // Relative Locations are legal; resolve before validating, or a relative
        // hop would fail the host check for the wrong reason.
        final resolved = Uri.parse(url).resolve(next).toString();
        if (!UpdaterService.isTrustedReleaseUrl(resolved)) {
          throw Exception('Update redirected to an untrusted host.');
        }
        if (++hops > 5) throw Exception('Too many update redirects.');
        url = resolved;
      }
      if (response.statusCode != 200) {
        throw Exception('Download failed (HTTP ${response.statusCode}).');
      }

      final total = response.contentLength ?? 0;
      int received = 0;
      final file = File(path);
      final sink = file.openWrite();

      await for (final chunk in response.stream) {
        if (_cancelled) { await sink.close(); return; } // user cancelled
        sink.add(chunk);
        received += chunk.length;
        if (total > 0 && mounted) {
          setState(() => _progress = received / total);
        }
      }
      await sink.close();
      if (_cancelled) return;

      final fileSize = await file.length();
      if (fileSize < 1024 * 100) {
        throw Exception('Downloaded file appears corrupt (${fileSize}B)');
      }
      // Verify it really is an APK before offering to install it. An APK is a
      // ZIP, so it must start with the local-file-header magic "PK\x03\x04";
      // an HTML error page or a redirect body never will. (Android itself then
      // refuses any APK not signed with the installed app's key, which is the
      // real barrier — this just stops a pointless installer prompt on junk.)
      final head = await file.openRead(0, 4).first;
      final isZip = head.length >= 4 &&
          head[0] == 0x50 && head[1] == 0x4B && head[2] == 0x03 && head[3] == 0x04;
      if (!isZip) {
        try { await file.delete(); } catch (_) {}
        throw Exception('That download is not a valid APK');
      }

      if (mounted) setState(() { _isDone = true; _apkPath = path; });
    } catch (e) {
      if (_cancelled) return;
      print('WARN: update download failed: $e');
      if (mounted) {
        setState(() { _isDownloading = false; _progress = 0; });
        AnimatedToast.show(
          context,
          text: 'Download failed: ${e.toString().replaceAll('Exception: ', '')}',
          icon: Icons.error,
          color: Colors.red
        );
      }
    } finally {
      // Every exit — success, throw, or an early return from a cancel — gives
      // the socket back. A timeout or an untrusted-redirect throw used to skip
      // the close entirely.
      try { _client?.close(); } catch (_) {}
      _client = null;
    }
  }

  Widget _buildNotes() {
    final notes = UpdaterService.parseReleaseNotes(
        widget.changelog.isEmpty ? 'Performance improvements and bug fixes.' : widget.changelog);
    if (notes.isEmpty) {
      return const Text('Performance improvements and bug fixes.',
          style: TextStyle(color: Colors.white70, fontSize: 13.5, height: 1.5));
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (final n in notes)
          if (n.isHeader)
            Padding(
              padding: const EdgeInsets.only(top: 12, bottom: 6),
              child: Text(
                n.text.toUpperCase(),
                style: TextStyle(
                    color: widget.themeColor,
                    fontSize: 11,
                    fontWeight: FontWeight.w900,
                    letterSpacing: 1.6),
              ),
            )
          else if (n.isBullet)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 4),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Padding(
                    padding: const EdgeInsets.only(top: 6),
                    child: Container(
                      width: 5,
                      height: 5,
                      decoration: BoxDecoration(
                          color: widget.themeColor.withOpacity(0.8),
                          shape: BoxShape.circle),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(n.text,
                        style: const TextStyle(
                            color: Colors.white70,
                            fontSize: 13.5,
                            height: 1.45,
                            fontWeight: FontWeight.w500)),
                  ),
                ],
              ),
            )
          else
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 4),
              child: Text(n.text,
                  style: const TextStyle(
                      color: Colors.white70,
                      fontSize: 13.5,
                      height: 1.45,
                      fontWeight: FontWeight.w500)),
            ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final tc = widget.themeColor;
    // Block the phone's back button — the dialog can only be dismissed via its
    // own LATER / Cancel buttons (so a download isn't accidentally abandoned).
    return PopScope(
      canPop: false,
      child: Dialog(
        backgroundColor: Colors.transparent,
        insetPadding: const EdgeInsets.symmetric(horizontal: 22, vertical: 24),
        child: ConstrainedBox(
          constraints: BoxConstraints(
            maxHeight: MediaQuery.of(context).size.height * 0.8,
          ),
          child: Container(
            padding: const EdgeInsets.fromLTRB(24, 26, 24, 22),
            decoration: BoxDecoration(
              color: const Color(0xFF17171C),
              borderRadius: BorderRadius.circular(28),
              border: Border.all(color: Colors.white.withOpacity(0.07), width: 1),
              boxShadow: [
                BoxShadow(
                    color: Colors.black.withOpacity(0.7),
                    blurRadius: 60,
                    spreadRadius: 10,
                    offset: const Offset(0, 18)),
                BoxShadow(
                    color: tc.withOpacity(0.10),
                    blurRadius: 40,
                    spreadRadius: -8,
                    offset: const Offset(0, -14)),
              ],
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // Header
                Row(
                  children: [
                    Container(
                      width: 52,
                      height: 52,
                      decoration: BoxDecoration(
                        color: tc.withOpacity(0.14),
                        borderRadius: BorderRadius.circular(16),
                        border: Border.all(color: tc.withOpacity(0.25)),
                      ),
                      child: Icon(Icons.system_update_rounded, color: tc, size: 26),
                    ),
                    const SizedBox(width: 14),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Text('Update available',
                              style: TextStyle(
                                  color: Colors.white,
                                  fontSize: 20,
                                  fontWeight: FontWeight.w900,
                                  letterSpacing: -0.4)),
                          const SizedBox(height: 6),
                          // Version transition pill: v1.1.2 → v1.1.3
                          Container(
                            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                            decoration: BoxDecoration(
                              color: Colors.white.withOpacity(0.05),
                              borderRadius: BorderRadius.circular(9),
                            ),
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Text('v${widget.currentVersion}',
                                    style: const TextStyle(
                                        color: Colors.white38,
                                        fontSize: 12,
                                        fontWeight: FontWeight.w700)),
                                const Padding(
                                  padding: EdgeInsets.symmetric(horizontal: 6),
                                  child: Icon(Icons.arrow_forward_rounded,
                                      color: Colors.white38, size: 12),
                                ),
                                Text('v${widget.newVersion}',
                                    style: TextStyle(
                                        color: tc,
                                        fontSize: 12,
                                        fontWeight: FontWeight.w900)),
                              ],
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 22),

                // What's new
                Text("WHAT'S NEW",
                    style: TextStyle(
                        color: Colors.white.withOpacity(0.66),
                        fontSize: 10.5,
                        fontWeight: FontWeight.w900,
                        letterSpacing: 1.8)),
                const SizedBox(height: 10),
                Flexible(
                  child: Container(
                    width: double.infinity,
                    constraints: const BoxConstraints(minHeight: 120),
                    padding: const EdgeInsets.fromLTRB(16, 12, 16, 14),
                    decoration: BoxDecoration(
                      color: Colors.black.withOpacity(0.3),
                      borderRadius: BorderRadius.circular(16),
                      border: Border.all(color: Colors.white.withOpacity(0.05)),
                    ),
                    child: SingleChildScrollView(
                      physics: const BouncingScrollPhysics(),
                      child: _buildNotes(),
                    ),
                  ),
                ),
                const SizedBox(height: 20),

                // Progress / actions
                if (_isDownloading && !_isDone) ...[
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Text('Downloading…',
                          style: TextStyle(
                              color: tc, fontWeight: FontWeight.w800, fontSize: 13.5)),
                      Text('${(_progress * 100).toStringAsFixed(0)}%',
                          style: const TextStyle(
                              color: Colors.white,
                              fontWeight: FontWeight.w900,
                              fontSize: 13.5)),
                    ],
                  ),
                  const SizedBox(height: 10),
                  ClipRRect(
                    borderRadius: BorderRadius.circular(8),
                    child: LinearProgressIndicator(
                      value: _progress,
                      minHeight: 7,
                      backgroundColor: Colors.black45,
                      valueColor: AlwaysStoppedAnimation(tc),
                    ),
                  ),
                  const SizedBox(height: 14),
                  // Cancel the in-progress download (aborts the connection) — the
                  // only way out mid-download since the back button is blocked.
                  SizedBox(
                    width: double.infinity,
                    height: 48,
                    child: TextButton(
                      style: TextButton.styleFrom(
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(24),
                          side: BorderSide(color: Colors.white.withOpacity(0.1)),
                        ),
                      ),
                      onPressed: () { _cancelDownload(); Navigator.pop(context); },
                      child: const Text('Cancel',
                          style: TextStyle(
                              color: Colors.white54,
                              fontWeight: FontWeight.w800,
                              fontSize: 14)),
                    ),
                  ),
                ] else ...[
                  if (_isDone)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 14),
                      child: Row(children: [
                        Icon(Icons.check_circle_rounded, color: tc, size: 18),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text('Downloaded — ready to install.',
                              style: TextStyle(
                                  color: tc,
                                  fontSize: 13.5,
                                  fontWeight: FontWeight.w700)),
                        ),
                      ]),
                    ),
                  Row(children: [
                    if (!_isDone) ...[
                      Expanded(
                        child: SizedBox(
                          height: 52,
                          child: TextButton(
                            style: TextButton.styleFrom(
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(26),
                                side: BorderSide(color: Colors.white.withOpacity(0.1)),
                              ),
                            ),
                            onPressed: () => Navigator.pop(context),
                            child: const Text('Later',
                                style: TextStyle(
                                    color: Colors.white54,
                                    fontWeight: FontWeight.w800,
                                    fontSize: 14)),
                          ),
                        ),
                      ),
                      const SizedBox(width: 10),
                    ],
                    Expanded(
                      flex: 2,
                      child: SizedBox(
                        height: 52,
                        child: ElevatedButton.icon(
                          style: ElevatedButton.styleFrom(
                            backgroundColor: tc,
                            foregroundColor: Colors.black,
                            elevation: 0,
                            shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(26)),
                          ),
                          onPressed: _isDownloading && !_isDone
                              ? null
                              : () async {
                                  if (_isDone && _apkPath != null) {
                                    final result = await OpenFilex.open(_apkPath!,
                                        type: 'application/vnd.android.package-archive');
                                    // context.mounted, not mounted: identical
                                    // here (this IS the State's build context),
                                    // but the analyzer cannot prove that through
                                    // the closure and the warning it raised would
                                    // otherwise sit in the noise hiding a real one.
                                    if (result.type != ResultType.done &&
                                        context.mounted) {
                                      ScaffoldMessenger.of(context).showSnackBar(
                                          SnackBar(
                                              content: Text('Install failed: ${result.message}'),
                                              backgroundColor: Colors.red));
                                    }
                                  } else {
                                    _startDownload();
                                  }
                                },
                          icon: Icon(
                              _isDone
                                  ? Icons.install_mobile_rounded
                                  : Icons.download_rounded,
                              size: 19),
                          label: Text(_isDone ? 'Install now' : 'Download',
                              style: const TextStyle(
                                  fontWeight: FontWeight.w900, fontSize: 14.5)),
                        ),
                      ),
                    ),
                  ]),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}
