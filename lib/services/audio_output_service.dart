import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// One attached audio output.
class AudioOutput {
  /// Android's AudioDeviceInfo id, stable only while the device stays attached.
  final int id;

  /// The name the hardware reports. Empty when it gives none, and for the
  /// built-in speaker, whose reported name is the phone's model number.
  final String name;

  /// `bluetooth`, `headphones`, `usb`, `hdmi`, `speaker` or `other`.
  final String kind;

  /// Auvy is pinned to this output.
  final bool isPreferred;

  /// Where audio goes when nothing is pinned.
  final bool isDefault;

  /// A dock or automotive bus. A car stereo on plain Bluetooth is NOT flagged —
  /// telling it apart from headphones needs BLUETOOTH_CONNECT, which Auvy does
  /// not ask for, so it appears as an ordinary Bluetooth device by its own name.
  final bool isCar;

  const AudioOutput({
    required this.id,
    required this.name,
    required this.kind,
    required this.isPreferred,
    required this.isDefault,
    required this.isCar,
  });

  factory AudioOutput.fromMap(Map<Object?, Object?> m) => AudioOutput(
        id: (m['id'] as num?)?.toInt() ?? -1,
        name: (m['name'] as String?) ?? '',
        kind: (m['kind'] as String?) ?? 'speaker',
        isPreferred: m['isPreferred'] == true,
        isDefault: m['isDefault'] == true,
        isCar: m['isCar'] == true,
      );

  String get displayName {
    if (name.trim().isNotEmpty) return name.trim();
    switch (kind) {
      case 'bluetooth':
        return 'Bluetooth device';
      case 'headphones':
        return 'Wired headphones';
      case 'usb':
        return 'USB audio';
      case 'hdmi':
        return 'HDMI';
      case 'other':
        return 'Connected device';
      default:
        return 'Phone speaker';
    }
  }

  IconData get icon => AudioOutputService.iconFor(kind);

  /// Same device with its pinned flag replaced, for painting a selection before
  /// the platform round trip has finished.
  AudioOutput withPreferred(bool preferred) => AudioOutput(
        id: id,
        name: name,
        kind: kind,
        isPreferred: preferred,
        isDefault: isDefault,
        isCar: isCar,
      );
}

/// Where Auvy's audio goes, and how to move it.
///
/// Choosing an output moves AUVY'S audio via media3's `preferredAudioDevice`. It
/// does not change the device's routing — no Android app can, which is also what
/// you want here: sending music to headphones must not drag a call along too.
///
/// Only already-attached outputs can be offered; anything else is the system's
/// job, which the sheet links out to.
class AudioOutputService {
  static const MethodChannel _player =
      MethodChannel('com.auvy.app/native_player');
  static const MethodChannel _system = MethodChannel('com.auvy.app/output');

  /// Outputs attached right now. Empty on failure.
  static Future<List<AudioOutput>> list() async {
    try {
      final raw = await _player.invokeMethod<List<Object?>>('listOutputs');
      if (raw == null) return const [];
      return raw
          .whereType<Map<Object?, Object?>>()
          .map(AudioOutput.fromMap)
          .where((d) => d.id >= 0)
          .toList();
    } on PlatformException {
      return const [];
    } on MissingPluginException {
      return const [];
    }
  }

  /// Sends Auvy's audio to [id]; null hands routing back to the system. False
  /// when the device was detached between listing and tapping.
  static Future<bool> select(int? id) async {
    try {
      return await _player.invokeMethod<bool>('setOutput', {'id': id ?? -1}) ??
          false;
    } on PlatformException {
      return false;
    } on MissingPluginException {
      return false;
    }
  }

  /// True while the phone is driving a car display — Android Auto projection or a
  /// built-in head unit.
  static Future<bool> isCarMode() async {
    try {
      return await _system.invokeMethod<bool>('carMode') ?? false;
    } on PlatformException {
      return false;
    } on MissingPluginException {
      return false;
    }
  }

  /// Starts or stops watching for outputs appearing and disappearing.
  ///
  /// ONLY WHILE THE PICKER IS VISIBLE. A permanent listener would keep a
  /// callback alive all session and wake work on every plug event for a sheet
  /// that is open for seconds, so the sheet turns it on when it opens and off
  /// when it closes, and a closed picker costs nothing.
  ///
  /// THE HANDLER GOES ON _system, NEVER ON _player. native_audio_engine owns
  /// the call handler for com.auvy.app/native_player; setting one there would
  /// replace it and silence position, state and track-end callbacks — playback
  /// would break outright.
  static Future<void> watch(bool enable, {VoidCallback? onChanged}) async {
    _onChanged = onChanged;
    _system.setMethodCallHandler(enable
        ? (call) async {
            if (call.method == 'outputsChanged') _onChanged?.call();
          }
        : null);
    try {
      await _system.invokeMethod('watchOutputs', {'enable': enable});
    } on PlatformException {
      // Not fatal: the sheet still shows the list it already loaded.
    } on MissingPluginException {
      // Same.
    }
  }

  static VoidCallback? _onChanged;

  /// Opens the system sound/output settings.
  static Future<bool> openSystemPicker() async {
    try {
      return await _system.invokeMethod<bool>('open') ?? false;
    } on PlatformException {
      return false;
    } on MissingPluginException {
      return false;
    }
  }

  /// The kind of output audio is going to, for the button's icon. See the native
  /// `currentAudioRoute` — it is the highest-priority attached output, not a read
  /// of the actual route, which Android does not expose to apps.
  static Future<String?> currentRoute() async {
    try {
      return await _system.invokeMethod<String>('route');
    } on PlatformException {
      return null;
    } on MissingPluginException {
      return null;
    }
  }

  /// Neutral speaker for null/unknown, so the button never claims a device that
  /// isn't there.
  static IconData iconFor(String? kind) {
    switch (kind) {
      case 'bluetooth':
        return Icons.bluetooth_audio_rounded;
      case 'headphones':
        return Icons.headphones_rounded;
      case 'usb':
        return Icons.usb_rounded;
      case 'hdmi':
        return Icons.tv_rounded;
      case 'other':
        return Icons.speaker_group_rounded;
      default:
        return Icons.speaker_rounded;
    }
  }
}
