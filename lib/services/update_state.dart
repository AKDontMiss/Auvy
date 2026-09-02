import 'package:shared_preferences/shared_preferences.dart';

/// Persisted memory for the updater, ported from HYDRV's `ReleaseUpdateState` +
/// `UpdatePreferences`.
///
/// The point of all this is ONE behaviour: **never mention the same release
/// twice.** Auvy used to re-show its update banner on every launch until you
/// actually installed, which is the nagging that makes people disable update
/// checks entirely. HYDRV solves it by remembering the last tag it announced
/// (`lastNotifiedTag`) and staying quiet unless the tag changes. That single
/// field is the difference between "helpful" and "pestering".
///
/// Everything here is a plain pref read/write — no state held in memory, so the
/// values survive a process death mid-download.
class UpdateState {
  const UpdateState._();

  /// The newest tag the app has ever SEEN (whether or not it told the user).
  static const _kLastSeenTag = 'auvy_update_last_seen_tag';

  /// The tag the app has already ANNOUNCED. Gates the banner.
  static const _kLastNotifiedTag = 'auvy_update_last_notified_tag';

  /// A tag the user explicitly dismissed — never announce it again.
  static const _kSkippedTag = 'auvy_update_skipped_tag';

  /// Epoch ms of the last completed check, shown in Settings.
  static const _kLastCheckedAt = 'auvy_update_last_checked_at';

  /// User toggle: check automatically on launch.
  static const _kCheckOnLaunch = 'auvy_update_check_on_launch';

  /// User toggle: show the in-app banner when a check finds something.
  static const _kAnnounce = 'auvy_update_announce';

  /// The version whose "What's new" sheet has been shown post-install.
  static const _kWhatsNewShownFor = 'auvy_whats_new_shown_for';

  static Future<String> lastNotifiedTag() async =>
      (await SharedPreferences.getInstance()).getString(_kLastNotifiedTag) ?? '';

  static Future<void> setLastNotifiedTag(String tag) async =>
      (await SharedPreferences.getInstance())
          .setString(_kLastNotifiedTag, tag.trim());

  static Future<String> lastSeenTag() async =>
      (await SharedPreferences.getInstance()).getString(_kLastSeenTag) ?? '';

  static Future<void> setLastSeenTag(String tag) async =>
      (await SharedPreferences.getInstance())
          .setString(_kLastSeenTag, tag.trim());

  static Future<String> skippedTag() async =>
      (await SharedPreferences.getInstance()).getString(_kSkippedTag) ?? '';

  static Future<void> setSkippedTag(String tag) async =>
      (await SharedPreferences.getInstance())
          .setString(_kSkippedTag, tag.trim());

  static Future<DateTime?> lastCheckedAt() async {
    final ms = (await SharedPreferences.getInstance()).getInt(_kLastCheckedAt);
    if (ms == null || ms <= 0) return null;
    return DateTime.fromMillisecondsSinceEpoch(ms);
  }

  static Future<void> markChecked() async =>
      (await SharedPreferences.getInstance())
          .setInt(_kLastCheckedAt, DateTime.now().millisecondsSinceEpoch);

  static Future<bool> checkOnLaunch() async =>
      (await SharedPreferences.getInstance()).getBool(_kCheckOnLaunch) ?? true;

  static Future<void> setCheckOnLaunch(bool v) async =>
      (await SharedPreferences.getInstance()).setBool(_kCheckOnLaunch, v);

  static Future<bool> announceUpdates() async =>
      (await SharedPreferences.getInstance()).getBool(_kAnnounce) ?? true;

  static Future<void> setAnnounceUpdates(bool v) async =>
      (await SharedPreferences.getInstance()).setBool(_kAnnounce, v);

  static Future<String> whatsNewShownFor() async =>
      (await SharedPreferences.getInstance()).getString(_kWhatsNewShownFor) ??
      '';

  static Future<void> setWhatsNewShownFor(String version) async =>
      (await SharedPreferences.getInstance())
          .setString(_kWhatsNewShownFor, version.trim());

  /// Should the banner be shown for [tag]?
  ///
  /// False when it's already been announced OR the user skipped it. A manual
  /// "Check for updates" bypasses this deliberately — asking is consent.
  static Future<bool> shouldAnnounce(String tag) async {
    final clean = tag.trim();
    if (clean.isEmpty) return false;
    if (!await announceUpdates()) return false;
    if (clean == await skippedTag()) return false;
    if (clean == await lastNotifiedTag()) return false;
    return true;
  }

  /// "5 minutes ago" / "2 days ago" / "Never".
  static String formatLastChecked(DateTime? at) {
    if (at == null) return 'Never checked';
    final d = DateTime.now().difference(at);
    if (d.inSeconds < 60) return 'Checked just now';
    if (d.inMinutes < 60) {
      return 'Checked ${d.inMinutes} minute${d.inMinutes == 1 ? '' : 's'} ago';
    }
    if (d.inHours < 24) {
      return 'Checked ${d.inHours} hour${d.inHours == 1 ? '' : 's'} ago';
    }
    return 'Checked ${d.inDays} day${d.inDays == 1 ? '' : 's'} ago';
  }
}
