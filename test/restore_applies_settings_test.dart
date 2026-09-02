import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// A restored setting that does not take effect until the next cold start.
///
/// ── THE SHAPE ───────────────────────────────────────────────────────────────
///
/// Several notifiers read their preference exactly once, in their constructor,
/// and never again. A cloud restore writes prefs directly — so for those, the
/// restored value sits on disk doing nothing while the app keeps showing the old
/// one. There is no error and nothing in a log; on a new device it simply reads
/// as "my settings did not come across".
///
/// `_applyRestoredSettings` already handles this by invalidating the affected
/// providers, and its own comment says so: "These read their pref only in their
/// constructor — recreate so the restored value takes effect now". Three had
/// been missed — density, mini-player style, and the accent-follows-artwork
/// toggle — which are among the most visible settings in the app.
///
/// This test makes the rule mechanical instead of remembered.
void main() {
  late final String restore;
  late final Set<String> backedUpKeys;

  setUpAll(() {
    restore = File('lib/providers/account_provider.dart').readAsStringSync();
    final sync = File('lib/services/cloud_sync_service.dart').readAsStringSync();
    // Strip comments so keys merely DISCUSSED in prose are not mistaken for
    // entries — the lists carry a lot of explanation.
    final code = sync
        .split('\n')
        .map((l) => l.replaceAll(RegExp(r'//.*$'), ''))
        .where((l) => !l.trimLeft().startsWith('//'))
        .join('\n');
    backedUpKeys = RegExp("'([a-z0-9_:.]+)'")
        .allMatches(code)
        .map((m) => m.group(1)!)
        .toSet();
  });

  /// Providers handled by something other than an invalidate, with the reason.
  ///
  /// An allowlist rather than a looser rule, because "mentioned somewhere in
  /// account_provider.dart" would pass a provider that is only ever CLEARED on
  /// account switch — which is exactly how recentPlaylistsProvider hid.
  const handledAnotherWay = {
    // The routine re-applies it explicitly with setThemeColor(), which is
    // better than invalidating: it also puts the launcher icon back in step.
    'themeProvider': 'setThemeColor() inside _applyRestoredSettings',
    // reloadFromStorage() is awaited at the call site, immediately before
    // _applyRestoredSettings runs.
    'artworkOverrideProvider': 'reloadFromStorage() at the call site',
  };

  test('every constructor-loading provider whose pref is backed up is invalidated',
      () {
    final missing = <String>[];

    for (final file in Directory('lib/providers')
        .listSync()
        .whereType<File>()
        .where((f) => f.path.endsWith('.dart'))) {
      final src = file.readAsStringSync();

      // The idiom: `SomeNotifier() : super(x) { _load(); }` — a constructor that
      // kicks off a one-shot pref read.
      final ctor = RegExp(r'(\w+Notifier)\(\)\s*:\s*super\([^)]*\)\s*\{')
          .allMatches(src)
          .map((m) => m.group(1)!)
          .toSet();
      if (ctor.isEmpty) continue;

      for (final notifier in ctor) {
        // The provider that exposes it.
        final decl = RegExp('final (\\w+Provider) =[\\s\\S]{0,200}?$notifier')
            .firstMatch(src);
        if (decl == null) continue;
        final providerName = decl.group(1)!;

        // Which pref key does it read? Only keys that are BACKED UP matter — a
        // local-only preference cannot be changed by a restore.
        final keys = RegExp("'([a-z0-9_]+(?:_[a-z0-9]+)*)'")
            .allMatches(src)
            .map((m) => m.group(1)!)
            .where(backedUpKeys.contains)
            .toSet();
        if (keys.isEmpty) continue;

        if (handledAnotherWay.containsKey(providerName)) continue;
        if (!restore.contains('invalidate($providerName)')) {
          missing.add(
              '$providerName (${file.path.split(RegExp(r"[\\/]")).last}) '
              'loads ${keys.join(", ")} in its constructor but is never '
              'invalidated after a restore');
        }
      }
    }

    expect(missing, isEmpty,
        reason: 'A restored value for these sits in prefs and does not apply '
            'until the app is restarted. Add an _ref.invalidate(...) beside the '
            'others in _applyRestoredSettings:\n${missing.join('\n')}');
  });

  test('the three that were missed are covered', () {
    // Pinned by name as well as by the scan above, because the scan depends on
    // the constructor idiom and a notifier written differently would slip past
    // it silently.
    for (final p in const [
      'densityProvider',
      'miniPlayerStyleProvider',
      'dynamicAccentProvider',
      // Only ever cleared on account switch, never reloaded — so the Home
      // "recently played" shelf came up empty on a restored device.
      'recentPlaylistsProvider',
    ]) {
      expect(restore.contains('invalidate($p)'), isTrue,
          reason: '$p is no longer invalidated after a cloud restore.');
    }
  });

  test('the allowlist still describes reality', () {
    // An allowlist that quietly stops being true is worse than no allowlist.
    expect(restore.contains('themeProvider.notifier).setThemeColor('), isTrue,
        reason: 'themeProvider is allowlisted as being re-applied explicitly, '
            'but the routine no longer calls setThemeColor.');
    expect(restore.contains('artworkOverrideProvider.notifier).reloadFromStorage('),
        isTrue,
        reason: 'artworkOverrideProvider is allowlisted as reloading itself, '
            'but nothing calls reloadFromStorage any more.');
  });

  test('an invalidate on restore implies the pref is actually backed up', () {
    // THE INVERSE RULE, and the one that catches the subtler mistake.
    //
    // Invalidating a provider after a restore says "there is a new value in
    // prefs, go and read it". If that key was never uploaded there is no new
    // value, the invalidate is a no-op, and the setting appears to be handled
    // while doing nothing at all. slider_style_name sat exactly like that: the
    // invalidate had been written, the backup entry never was.
    final invalidated = RegExp(r"invalidate\((\w+Provider)\)")
        .allMatches(restore)
        .map((m) => m.group(1)!)
        .toSet();

    // Provider -> the pref it loads. Only providers backed by a single
    // user-facing preference; the rest are derived or device-local.
    const prefFor = {
      'sliderStyleProvider': 'slider_style_name',
      'miniPlayerStyleProvider': 'mini_player_style_name',
      'densityProvider': 'app_density_name',
      'dynamicAccentProvider': 'auvy_dynamic_accent',
      'pureBlackProvider': 'auvy_pure_black',
    };

    final noOps = <String>[];
    prefFor.forEach((provider, key) {
      if (!invalidated.contains(provider)) return;
      if (!backedUpKeys.contains(key)) {
        noOps.add('$provider is invalidated after a restore, but $key is not '
            'in the backup set — nothing can have changed for it to read');
      }
    });

    expect(noOps, isEmpty, reason: noOps.join('\n'));
  });
}
