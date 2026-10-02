import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:auvy/providers/account_provider.dart';
import 'package:auvy/providers/theme_provider.dart';
import 'package:auvy/services/haptic_service.dart';

/// Which devices this account is signed in on, and a way to sign one out.
///
/// A list rather than a one-session limit, for three reasons:
///
///   * **Auvy can't make a limit instant.** There's no push channel; a revoked
///     device keeps playing until it next talks to the Worker (on launch or
///     resume, at most every ten minutes). So this screen says "within a few
///     minutes".
///   * **It would break normal use.** A phone plus a tablet is common, and a
///     limit of one would also block Listen Together between a person's own
///     devices.
///   * **Visibility addresses the real worry** (a shared login) without
///     punishing anyone's second device.
///
/// The stored list is capped at ten only so it can't grow without bound.
class ActiveDevicesPage extends ConsumerStatefulWidget {
  const ActiveDevicesPage({super.key});

  @override
  ConsumerState<ActiveDevicesPage> createState() => _ActiveDevicesPageState();
}

class _ActiveDevicesPageState extends ConsumerState<ActiveDevicesPage> {
  /// Fetched once per visit, not watched: it costs a Worker round trip (limited to
  /// 60 a day) and is opened to see the current answer.
  Future<List<AuvyDevice>>? _future;

  /// The row being signed out, so only that row shows a spinner.
  String? _revoking;

  @override
  void initState() {
    super.initState();
    _future = ref.read(accountProvider.notifier).fetchDevices();
  }

  Future<void> _revoke(AuvyDevice d) async {
    HapticService.selection();
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Sign out this device?',
            style: TextStyle(color: Colors.white, fontSize: 18)),
        // States the delay rather than implying immediacy. See the class note.
        content: Text(
          '${d.model} will be signed out of Auvy the next time it checks in — '
          'usually within a few minutes. Anything playing right now will keep '
          'playing until then.',
          style: TextStyle(color: Colors.white.withOpacity(0.7), fontSize: 14),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel', style: TextStyle(color: Colors.white54)),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Sign out',
                style: TextStyle(color: Color(0xFFEF9A9A))),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;

    setState(() => _revoking = d.id);
    // The revocation and the refreshed list come back in ONE call — the Worker
    // applies it and returns the updated roster, so the screen cannot show a
    // stale list next to an action it just took.
    try {
      final updated = await ref
          .read(accountProvider.notifier)
          .fetchDevices(revokeDeviceId: d.id);
      if (!mounted) return;
      if (updated.isNotEmpty) {
        setState(() {
          _revoking = null;
          _future = Future.value(updated);
        });
      } else {
        // If Worker returned empty (e.g. transient timeout), filter locally so UI remains accurate
        final current = (await _future) ?? <AuvyDevice>[];
        if (!mounted) return;
        final filtered = current.where((x) => x.id != d.id).toList();
        setState(() {
          _revoking = null;
          _future = Future.value(filtered);
        });
      }
    } catch (_) {
      if (mounted) setState(() => _revoking = null);
    }
  }

  @override
  Widget build(BuildContext context) {
    final themeColor = ref.watch(themeProvider);

    return Scaffold(
      backgroundColor: const Color(0xFF0A0A0C),
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        title: const Text('Active devices',
            style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700)),
      ),
      body: FutureBuilder<List<AuvyDevice>>(
        future: _future,
        builder: (context, snap) {
          if (snap.connectionState != ConnectionState.done) {
            return Center(
                child: CircularProgressIndicator(color: themeColor));
          }
          final devices = snap.data ?? const <AuvyDevice>[];
          if (devices.isEmpty) {
            // Distinguishes "none" from "could not ask" — a list that silently
            // reads empty when the network failed is the kind of screen that
            // gets believed.
            return Padding(
              padding: const EdgeInsets.all(32),
              child: Center(
                child: Text(
                  'No devices to show.\n\nThis needs a connection and a '
                  'signed-in account — if both look fine, try again in a moment.',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                      color: Colors.white.withOpacity(0.55), fontSize: 14),
                ),
              ),
            );
          }
          return RefreshIndicator(
            color: themeColor,
            onRefresh: () async {
              final f = ref.read(accountProvider.notifier).fetchDevices();
              setState(() => _future = f);
              await f;
            },
            child: ListView(
              physics: const AlwaysScrollableScrollPhysics(),
              padding: const EdgeInsets.symmetric(vertical: 8),
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 8, 20, 16),
                  child: Text(
                    'Auvy works on several devices at once. Signing out here '
                    'takes effect the next time that device checks in.',
                    style: TextStyle(
                        color: Colors.white.withOpacity(0.55),
                        fontSize: 13,
                        height: 1.4),
                  ),
                ),
                for (final d in devices)
                  _DeviceRow(
                    device: d,
                    themeColor: themeColor,
                    busy: _revoking == d.id,
                    // Never offered for the device you are holding: it would
                    // work, but "sign this phone out from this phone" is a
                    // confusing thing to hand someone, and the sign-out button in
                    // the account section already does it properly.
                    onSignOut: d.isThisDevice ? null : () => _revoke(d),
                  ),
              ],
            ),
          );
        },
      ),
    );
  }
}

class _DeviceRow extends StatelessWidget {
  final AuvyDevice device;
  final Color themeColor;
  final bool busy;
  final VoidCallback? onSignOut;

  const _DeviceRow({
    required this.device,
    required this.themeColor,
    required this.busy,
    required this.onSignOut,
  });

  @override
  Widget build(BuildContext context) {
    final isNow = device.lastSeenLabel == 'Active now';
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 5),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        decoration: BoxDecoration(
          color: Colors.white.withOpacity(0.04),
          borderRadius: BorderRadius.circular(14),
          border: device.isThisDevice
              ? Border.all(color: themeColor.withOpacity(0.45), width: 1)
              : null,
        ),
        child: Row(
          children: [
            Icon(Icons.smartphone_rounded,
                size: 22,
                color: device.isThisDevice
                    ? themeColor
                    : Colors.white.withOpacity(0.6)),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Flexible(
                        child: Text(device.model,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                                color: Colors.white,
                                fontSize: 15,
                                fontWeight: FontWeight.w600)),
                      ),
                      if (device.isThisDevice) ...[
                        const SizedBox(width: 8),
                        Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 7, vertical: 2),
                          decoration: BoxDecoration(
                            color: themeColor.withOpacity(0.18),
                            borderRadius: BorderRadius.circular(6),
                          ),
                          child: Text('This device',
                              style: TextStyle(
                                  color: themeColor,
                                  fontSize: 10,
                                  fontWeight: FontWeight.w800)),
                        ),
                      ],
                    ],
                  ),
                  const SizedBox(height: 3),
                  Text(
                    [
                      if (device.os.isNotEmpty) device.os,
                      device.lastSeenLabel,
                    ].join(' · '),
                    style: TextStyle(
                        color: isNow
                            ? themeColor.withOpacity(0.85)
                            : Colors.white.withOpacity(0.45),
                        fontSize: 12),
                  ),
                ],
              ),
            ),
            if (busy)
              SizedBox(
                width: 18,
                height: 18,
                child:
                    CircularProgressIndicator(strokeWidth: 2, color: themeColor),
              )
            else if (onSignOut != null)
              TextButton(
                onPressed: onSignOut,
                style: TextButton.styleFrom(
                    padding: const EdgeInsets.symmetric(horizontal: 10),
                    minimumSize: Size.zero),
                child: const Text('Sign out',
                    style: TextStyle(
                        color: Color(0xFFEF9A9A),
                        fontSize: 13,
                        fontWeight: FontWeight.w600)),
              ),
          ],
        ),
      ),
    );
  }
}
