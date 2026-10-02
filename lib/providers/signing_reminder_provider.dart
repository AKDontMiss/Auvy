/// iOS only: a reminder before the sideload signature runs out.
///
/// On iPhone Auvy is installed with SideStore, which signs it with the
/// listener's Apple ID; on a free one the signature lasts 7 days. SideStore
/// renews it in the background, but only while it can run with LocalDevVPN on,
/// and when a renewal is missed Auvy simply stops opening. The expiry is read
/// from the app's own provisioning profile at launch and on resume (a refresh
/// writes a new one), and local notifications are scheduled 2 days, 1 day and
/// 3 hours before it. A card on Home says the same once 2 days remain.
///
/// Nothing leaves the phone. The setting is per device and not backed up, since
/// each phone has its own signature.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io' show Platform;

import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// One scheduled reminder.
class SigningReminder {
  final String id;
  final DateTime at;
  final String title;
  final String body;
  const SigningReminder(this.id, this.at, this.title, this.body);

  Map<String, Object> toChannel() =>
      {'id': id, 'atMs': at.millisecondsSinceEpoch, 'title': title, 'body': body};
}

/// How close the expiry is, for the Home card. Each stage can be dismissed on
/// its own, so a dismissed card comes back when the next one starts.
enum SigningStage { fine, soon, tomorrow, hours, expired }

SigningStage signingStage(DateTime expiresAt, DateTime now) {
  final left = expiresAt.difference(now);
  if (left <= Duration.zero) return SigningStage.expired;
  if (left <= const Duration(hours: 3)) return SigningStage.hours;
  if (left <= const Duration(days: 1)) return SigningStage.tomorrow;
  if (left <= const Duration(days: 2)) return SigningStage.soon;
  return SigningStage.fine;
}

const _howTo = 'Turn on LocalDevVPN, open SideStore and tap Refresh All';

/// The reminders still ahead for [expiresAt]: 2 days, 1 day and 3 hours before.
/// Past ones are left out; the Home card covers the time already inside them.
List<SigningReminder> planSigningReminders(DateTime expiresAt, DateTime now) => [
      SigningReminder('2d', expiresAt.subtract(const Duration(days: 2)),
          'Auvy needs a refresh soon', 'Its signature runs out in 2 days. $_howTo.'),
      SigningReminder('1d', expiresAt.subtract(const Duration(days: 1)),
          'Auvy runs out tomorrow', '$_howTo, or Auvy will stop opening.'),
      SigningReminder('3h', expiresAt.subtract(const Duration(hours: 3)),
          'Auvy stops opening in 3 hours',
          '$_howTo now. Once it runs out, getting it back can take a computer.'),
    ].where((r) => r.at.isAfter(now)).toList();

/// "1 day 5 hours", "5 hours", "40 minutes".
String formatSigningLeft(Duration left) {
  if (left <= Duration.zero) return 'no time';
  String unit(int n, String one) => '$n $one${n == 1 ? '' : 's'}';
  final days = left.inDays;
  final hours = left.inHours % 24;
  if (days > 0) return hours > 0 ? '${unit(days, 'day')} ${unit(hours, 'hour')}' : unit(days, 'day');
  if (left.inHours > 0) return unit(left.inHours, 'hour');
  return unit(left.inMinutes < 1 ? 1 : left.inMinutes, 'minute');
}

class SigningReminderState {
  /// When this install stops opening. Null when there is no provisioning
  /// profile (App Store or TestFlight build, simulator) or before the first read.
  final DateTime? expiresAt;

  /// Null until the listener chooses; the Home card asks once.
  final bool? enabled;

  /// iOS notification permission: granted, denied or undecided.
  final String permission;

  /// The card stage dismissed, as `expiresMs:stage`.
  final String dismissed;

  const SigningReminderState({
    this.expiresAt,
    this.enabled,
    this.permission = 'undecided',
    this.dismissed = '',
  });

  SigningReminderState copyWith({
    DateTime? expiresAt,
    bool? enabled,
    String? permission,
    String? dismissed,
  }) =>
      SigningReminderState(
        expiresAt: expiresAt ?? this.expiresAt,
        enabled: enabled ?? this.enabled,
        permission: permission ?? this.permission,
        dismissed: dismissed ?? this.dismissed,
      );

  String dismissKey(SigningStage stage) =>
      '${expiresAt?.millisecondsSinceEpoch}:${stage.name}';
}

class SigningReminderNotifier extends StateNotifier<SigningReminderState> {
  SigningReminderNotifier() : super(const SigningReminderState());

  static const _channel = MethodChannel('com.auvy.app/signing');
  static const kPrefsKey = 'auvy_signing_reminder_v1';

  Future<void>? _inFlight;

  /// What the last schedule was for. Resumes are frequent, and the reminders
  /// only need replacing when the expiry or the choice changes.
  String? _scheduledFor;

  /// Re-reads the expiry and permission and reschedules if anything changed.
  /// Called at launch and on every resume; iOS only.
  Future<void> refresh() {
    if (!Platform.isIOS) return Future.value();
    return _inFlight ??= _refresh().whenComplete(() => _inFlight = null);
  }

  Future<void> _refresh() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      bool? enabled;
      var dismissed = '';
      final raw = prefs.getString(kPrefsKey);
      if (raw != null) {
        final m = jsonDecode(raw) as Map<String, dynamic>;
        enabled = m['enabled'] as bool?;
        dismissed = m['dismissed'] as String? ?? '';
      }
      final expiry = await _channel.invokeMapMethod<String, dynamic>('expiry');
      final permission = await _channel.invokeMethod<String>('permission') ?? 'undecided';
      final expiresMs = (expiry?['expiresMs'] as num?)?.toInt();
      final expiresAt =
          expiresMs == null ? null : DateTime.fromMillisecondsSinceEpoch(expiresMs);
      if (!mounted) return;
      state = SigningReminderState(
          expiresAt: expiresAt, enabled: enabled, permission: permission, dismissed: dismissed);
      await _schedule();
    } catch (e) {
      print('WARN: signing: could not read the signature ($e)');
    }
  }

  Future<void> _schedule() async {
    final s = state;
    final expiresAt = s.expiresAt;
    final on = s.enabled == true && s.permission == 'granted';
    final key = '${expiresAt?.millisecondsSinceEpoch}|$on';
    if (key == _scheduledFor) return;
    _scheduledFor = key;
    if (expiresAt == null) {
      print('signing: no provisioning profile, so no expiry to remind about');
      return;
    }
    final left = formatSigningLeft(expiresAt.difference(DateTime.now()));
    if (!on) {
      await _channel.invokeMethod('cancel');
      print('signing: runs out ${_stamp(expiresAt)} ($left left); reminders off'
          '${s.enabled == true ? ' (notifications not allowed)' : ''}');
      return;
    }
    final plan = planSigningReminders(expiresAt, DateTime.now());
    final added = await _channel.invokeMethod<int>(
        'schedule', {'reminders': [for (final r in plan) r.toChannel()]});
    print('signing: runs out ${_stamp(expiresAt)} ($left left); '
        '${added ?? 0} reminder${added == 1 ? '' : 's'} scheduled'
        '${plan.isEmpty ? '' : ' (${plan.map((r) => r.id).join(', ')} before)'}');
  }

  static String _stamp(DateTime d) =>
      '${d.year}-${_two(d.month)}-${_two(d.day)} ${_two(d.hour)}:${_two(d.minute)}';
  static String _two(int n) => n.toString().padLeft(2, '0');

  Future<void> _save() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
        kPrefsKey, jsonEncode({'enabled': state.enabled, 'dismissed': state.dismissed}));
  }

  /// Turns reminders on, asking iOS for permission the first time. Returns
  /// false when notifications are not allowed (iOS only asks once; after a
  /// "Don't Allow" the switch lives in the Settings app).
  Future<bool> enable() async {
    if (!Platform.isIOS) return false;
    if (state.permission == 'denied') {
      // Refused earlier, and iOS never asks twice: the switch is in Settings.
      // Kept on, so coming back with notifications allowed schedules them.
      state = state.copyWith(enabled: true);
      await _save();
      print('signing: reminders on, waiting for notifications in iOS Settings');
      await openSettings();
      return false;
    }
    var permission = state.permission;
    try {
      if (permission == 'undecided') {
        final granted = await _channel.invokeMethod<bool>('requestPermission') ?? false;
        permission = granted ? 'granted' : 'denied';
      }
    } catch (e) {
      print('WARN: signing: permission request failed ($e)');
      return false;
    }
    final ok = permission == 'granted';
    // A refusal just now still counts as a choice, so the card stops asking.
    state = state.copyWith(enabled: ok, permission: permission);
    await _save();
    print('signing: reminders ${ok ? 'on' : 'not allowed by iOS'}');
    await _schedule();
    return ok;
  }

  Future<void> disable() async {
    state = state.copyWith(enabled: false);
    await _save();
    print('signing: reminders off');
    await _schedule();
  }

  void dismiss(SigningStage stage) {
    state = state.copyWith(dismissed: state.dismissKey(stage));
    unawaited(_save());
  }

  Future<void> openSettings() async {
    try {
      await _channel.invokeMethod('openSettings');
    } catch (_) {}
  }
}

final signingReminderProvider =
    StateNotifierProvider<SigningReminderNotifier, SigningReminderState>(
        (ref) => SigningReminderNotifier());
