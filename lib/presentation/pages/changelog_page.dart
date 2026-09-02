import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;
import 'package:package_info_plus/package_info_plus.dart';

import 'package:auvy/providers/theme_provider.dart';
import 'package:auvy/services/updater_service.dart';

/// In-app changelog: every published release, with the installed one marked.
///
/// Before this, release notes existed only inside the update dialog, so once
/// you'd installed, there was no way to find out what had actually changed, and
/// no way to read the notes for a release you'd skipped. This lists every
/// published release, marks the one you're running, and reuses
/// [UpdaterService.parseReleaseNotes] so the Markdown renders the same way in
/// both places.
class ChangelogPage extends ConsumerStatefulWidget {
  const ChangelogPage({super.key});

  @override
  ConsumerState<ChangelogPage> createState() => _ChangelogPageState();
}

class _ChangelogPageState extends ConsumerState<ChangelogPage> {
  List<_Release>? _releases;
  String? _error;
  String _currentVersion = '';

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _error = null;
      _releases = null;
    });
    try {
      final info = await PackageInfo.fromPlatform();
      // Through the Worker, not api.github.com. The repo is public, so this is
      // no longer about access — it is the 60-req/hour-per-IP unauthenticated
      // limit, which users behind one carrier NAT would share. The Worker's
      // token raises that to 5,000 and caches the answer. Same JSON shape,
      // trimmed. See UpdaterService for the full reasoning.
      final res = await http.get(
        Uri.parse('https://${UpdaterService.updateHost}/release/list'),
        headers: const {'User-Agent': 'Auvy-App'},
      ).timeout(const Duration(seconds: 10),
              onTimeout: () => http.Response('', 408));
      if (!mounted) return;
      if (res.statusCode == 403 || res.statusCode == 429) {
        setState(() => _error = 'GitHub rate limit reached. Try again shortly.');
        return;
      }
      // 404 MEANS SOMETHING DIFFERENT NOW THAT THE RELEASES REPO IS PUBLIC.
      //
      // This used to read "the update service could not read <repo>. Its access
      // token may be missing or expired" — correct while releases lived in a
      // PRIVATE repo, where a 404 is what GitHub returns for a repo the caller
      // cannot see, so a token problem was the likely cause.
      //
      // Against a public repo that message is actively misleading: a 404 there
      // just means no releases have been published yet, and telling the user to
      // suspect an expired token sends them chasing a fault that does not exist.
      if (res.statusCode == 404) {
        setState(() => _error = 'No releases published yet.');
        return;
      }
      if (res.statusCode != 200) {
        setState(() => _error = 'Could not load releases (HTTP ${res.statusCode}).');
        return;
      }
      final list = (jsonDecode(res.body) as List)
          .whereType<Map<String, dynamic>>()
          .where((r) => r['draft'] != true)
          .map((r) => _Release(
                // Anchored, not replaceAll('v'): the old form stripped every 'v'
                // anywhere in the tag, so `v1.2.4-preview` became `1.2.4-preiew`.
                tag: (r['tag_name'] as String? ?? '')
                    .replaceFirst(RegExp(r'^[vV]'), ''),
                name: r['name'] as String? ?? '',
                body: r['body'] as String? ?? '',
                publishedAt: DateTime.tryParse(r['published_at'] as String? ?? ''),
                prerelease: r['prerelease'] == true,
              ))
          .toList();
      setState(() {
        _currentVersion = info.version;
        _releases = list;
      });
    } catch (_) {
      if (mounted) setState(() => _error = 'Network error. Could not load releases.');
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = ref.watch(themeProvider);
    return Scaffold(
      backgroundColor: const Color(0xFF0E0E12),
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        title: const Text("What's new",
            style: TextStyle(
                color: Colors.white, fontWeight: FontWeight.w800, fontSize: 18)),
        iconTheme: const IconThemeData(color: Colors.white),
        actions: [
          IconButton(
            tooltip: 'Reload',
            icon: const Icon(Icons.refresh_rounded),
            onPressed: _load,
          ),
        ],
      ),
      body: _buildBody(theme),
    );
  }

  Widget _buildBody(Color theme) {
    if (_error != null) {
      return _CenteredNote(
        icon: Icons.cloud_off_rounded,
        text: _error!,
        actionLabel: 'Retry',
        onAction: _load,
        theme: theme,
      );
    }
    final releases = _releases;
    if (releases == null) {
      return Center(
        child: SizedBox(
          width: 26,
          height: 26,
          child: CircularProgressIndicator(strokeWidth: 2.4, color: theme),
        ),
      );
    }
    if (releases.isEmpty) {
      return _CenteredNote(
        icon: Icons.inbox_rounded,
        text: 'No releases published yet.',
        theme: theme,
      );
    }

    return ListView.separated(
      padding: const EdgeInsets.fromLTRB(18, 8, 18, 32),
      itemCount: releases.length,
      separatorBuilder: (_, __) => const SizedBox(height: 18),
      itemBuilder: (ctx, i) =>
          _ReleaseCard(release: releases[i], current: _currentVersion, theme: theme),
    );
  }
}

class _Release {
  final String tag;
  final String name;
  final String body;
  final DateTime? publishedAt;
  final bool prerelease;
  const _Release({
    required this.tag,
    required this.name,
    required this.body,
    required this.publishedAt,
    required this.prerelease,
  });
}

class _ReleaseCard extends StatelessWidget {
  final _Release release;
  final String current;
  final Color theme;
  const _ReleaseCard(
      {required this.release, required this.current, required this.theme});

  String _date() {
    final d = release.publishedAt;
    if (d == null) return '';
    const months = [
      'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
      'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'
    ];
    return '${months[d.month - 1]} ${d.day}, ${d.year}';
  }

  @override
  Widget build(BuildContext context) {
    final isCurrent = release.tag == current;
    final lines = UpdaterService.parseReleaseNotes(release.body);

    return Container(
      decoration: BoxDecoration(
        color: Colors.white.withOpacity(0.045),
        borderRadius: BorderRadius.circular(18),
        border: Border.all(
            color: isCurrent ? theme.withOpacity(0.55) : Colors.white.withOpacity(0.06),
            width: isCurrent ? 1.4 : 1),
      ),
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text('v${release.tag}',
                  style: TextStyle(
                      color: isCurrent ? theme : Colors.white,
                      fontSize: 17,
                      fontWeight: FontWeight.w900)),
              const SizedBox(width: 8),
              if (isCurrent) _Pill(text: 'INSTALLED', color: theme),
              if (release.prerelease) ...[
                const SizedBox(width: 6),
                const _Pill(text: 'BETA', color: Color(0xFFFFB300)),
              ],
              const Spacer(),
              Text(_date(),
                  style: TextStyle(
                      color: Colors.white.withOpacity(0.66),
                      fontSize: 11.5,
                      fontWeight: FontWeight.w600)),
            ],
          ),
          if (release.name.isNotEmpty && release.name != release.tag) ...[
            const SizedBox(height: 4),
            Text(release.name,
                style: TextStyle(
                    color: Colors.white.withOpacity(0.78),
                    fontSize: 12.5,
                    fontWeight: FontWeight.w600)),
          ],
          const SizedBox(height: 12),
          if (lines.isEmpty)
            Text('No notes for this release.',
                style: TextStyle(
                    color: Colors.white.withOpacity(0.66), fontSize: 13))
          else
            for (final line in lines)
              Padding(
                padding: EdgeInsets.only(
                    bottom: 5, top: line.isHeader ? 8 : 0, left: line.isBullet ? 2 : 0),
                child: line.isHeader
                    ? Text(line.text.toUpperCase(),
                        style: TextStyle(
                            color: theme.withOpacity(0.85),
                            fontSize: 11,
                            fontWeight: FontWeight.w900,
                            letterSpacing: 1.1))
                    : Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          if (line.isBullet)
                            Padding(
                              padding: const EdgeInsets.only(top: 6, right: 8),
                              child: Container(
                                width: 4,
                                height: 4,
                                decoration: BoxDecoration(
                                    color: theme.withOpacity(0.7),
                                    shape: BoxShape.circle),
                              ),
                            ),
                          Expanded(
                            child: Text(line.text,
                                style: TextStyle(
                                    color: Colors.white.withOpacity(0.78),
                                    fontSize: 13,
                                    height: 1.42)),
                          ),
                        ],
                      ),
              ),
        ],
      ),
    );
  }
}

class _Pill extends StatelessWidget {
  final String text;
  final Color color;
  const _Pill({required this.text, required this.color});

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
        decoration: BoxDecoration(
          color: color.withOpacity(0.16),
          borderRadius: BorderRadius.circular(6),
          border: Border.all(color: color.withOpacity(0.5)),
        ),
        child: Text(text,
            style: TextStyle(
                color: color,
                fontSize: 8.5,
                fontWeight: FontWeight.w900,
                letterSpacing: 0.8)),
      );
}

class _CenteredNote extends StatelessWidget {
  final IconData icon;
  final String text;
  final String? actionLabel;
  final VoidCallback? onAction;
  final Color theme;
  const _CenteredNote({
    required this.icon,
    required this.text,
    this.actionLabel,
    this.onAction,
    required this.theme,
  });

  @override
  Widget build(BuildContext context) => Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(icon, size: 42, color: Colors.white.withOpacity(0.22)),
              const SizedBox(height: 14),
              Text(text,
                  textAlign: TextAlign.center,
                  style: TextStyle(
                      color: Colors.white.withOpacity(0.72), fontSize: 13.5)),
              if (actionLabel != null) ...[
                const SizedBox(height: 16),
                TextButton(
                  onPressed: onAction,
                  child: Text(actionLabel!,
                      style: TextStyle(
                          color: theme, fontWeight: FontWeight.w800)),
                ),
              ],
            ],
          ),
        ),
      );
}
