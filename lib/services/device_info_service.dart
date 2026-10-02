import 'dart:io' show Platform;
import 'package:device_info_plus/device_info_plus.dart';
import 'package:auvy/providers/account_provider.dart' show AuvyDevice;

/// Resolves and caches the current device's model and OS.
///
/// Gives consistent, readable device names ("iPhone 15 Pro", "Samsung
/// SM-S926B") for playback history, cloud shard sync and the Active devices
/// list.
class DeviceInfoService {
  DeviceInfoService._();

  static String? _cachedDeviceName;
  static String? _cachedDeviceOs;

  /// Test hook to simulate arbitrary devices in unit/widget tests.
  static String? debugOverrideDeviceName;

  /// Warm the cache early (e.g. at startup) so synchronous readers get the real name.
  static Future<void> init() async {
    await getDeviceInfo();
  }

  /// Synchronous getter for the cached device name, falling back to platform defaults
  /// if called before asynchronous resolution finishes.
  static String get currentDeviceName {
    if (debugOverrideDeviceName != null) return debugOverrideDeviceName!;
    if (_cachedDeviceName != null &&
        _cachedDeviceName!.isNotEmpty &&
        _cachedDeviceName != 'Unknown device') {
      return _cachedDeviceName!;
    }
    return _fallbackDeviceName();
  }

  static String _fallbackDeviceName() {
    try {
      if (Platform.isIOS) return 'iPhone';
      if (Platform.isAndroid) return 'Android device';
      if (Platform.isMacOS) return 'Mac';
      if (Platform.isWindows) return 'Windows PC';
      if (Platform.isLinux) return 'Linux PC';
    } catch (_) {}
    return 'Auvy Device';
  }

  /// Map Apple hardware identifiers (e.g. "iPhone16,1") to human marketing names.
  static String? lookupAppleMachine(String machine) {
    final m = machine.trim();
    if (m.isEmpty) return null;
    const map = {
      // iPhone 17 family
      'iPhone18,1': 'iPhone 17 Pro',
      'iPhone18,2': 'iPhone 17 Pro Max',
      'iPhone18,3': 'iPhone 17',
      'iPhone18,4': 'iPhone Air',
      // iPhone 16 family
      'iPhone17,1': 'iPhone 16 Pro',
      'iPhone17,2': 'iPhone 16 Pro Max',
      'iPhone17,3': 'iPhone 16',
      'iPhone17,4': 'iPhone 16 Plus',
      'iPhone17,5': 'iPhone 16e',
      // iPhone 15 family
      'iPhone16,1': 'iPhone 15 Pro',
      'iPhone16,2': 'iPhone 15 Pro Max',
      'iPhone15,4': 'iPhone 15',
      'iPhone15,5': 'iPhone 15 Plus',
      // iPhone 14 family
      'iPhone15,2': 'iPhone 14 Pro',
      'iPhone15,3': 'iPhone 14 Pro Max',
      'iPhone14,7': 'iPhone 14',
      'iPhone14,8': 'iPhone 14 Plus',
      // iPhone 13 family
      'iPhone14,2': 'iPhone 13 Pro',
      'iPhone14,3': 'iPhone 13 Pro Max',
      'iPhone14,5': 'iPhone 13',
      'iPhone14,4': 'iPhone 13 Mini',
      // iPhone 12 family
      'iPhone13,2': 'iPhone 12',
      'iPhone13,1': 'iPhone 12 Mini',
      'iPhone13,3': 'iPhone 12 Pro',
      'iPhone13,4': 'iPhone 12 Pro Max',
      // iPhone 11 family
      'iPhone12,1': 'iPhone 11',
      'iPhone12,3': 'iPhone 11 Pro',
      'iPhone12,5': 'iPhone 11 Pro Max',
      // iPhone SE
      'iPhone8,4': 'iPhone SE',
      'iPhone12,8': 'iPhone SE 2',
      'iPhone14,6': 'iPhone SE 3',
      // iPhone 8 / X / XS / XR
      'iPhone10,1': 'iPhone 8',
      'iPhone10,4': 'iPhone 8',
      'iPhone10,2': 'iPhone 8 Plus',
      'iPhone10,5': 'iPhone 8 Plus',
      'iPhone10,3': 'iPhone X',
      'iPhone10,6': 'iPhone X',
      'iPhone11,2': 'iPhone XS',
      'iPhone11,4': 'iPhone XS Max',
      'iPhone11,6': 'iPhone XS Max',
      'iPhone11,8': 'iPhone XR',
      // iPads
      'iPad16,3': 'iPad Pro 11-inch (M4)',
      'iPad16,4': 'iPad Pro 11-inch (M4)',
      'iPad16,5': 'iPad Pro 13-inch (M4)',
      'iPad16,6': 'iPad Pro 13-inch (M4)',
      'iPad14,3': 'iPad Pro 11-inch 4',
      'iPad14,4': 'iPad Pro 11-inch 4',
      'iPad14,5': 'iPad Pro 12.9-inch 6',
      'iPad14,6': 'iPad Pro 12.9-inch 6',
      'iPad13,4': 'iPad Pro 11-inch 3',
      'iPad13,5': 'iPad Pro 11-inch 3',
      'iPad13,8': 'iPad Pro 12.9-inch 5',
      'iPad13,9': 'iPad Pro 12.9-inch 5',
      'iPad13,1': 'iPad Air 4',
      'iPad13,2': 'iPad Air 4',
      'iPad13,16': 'iPad Air 5',
      'iPad13,17': 'iPad Air 5',
      'iPad14,8': 'iPad Air 11-inch (M2)',
      'iPad14,9': 'iPad Air 11-inch (M2)',
      'iPad14,10': 'iPad Air 13-inch (M2)',
      'iPad14,11': 'iPad Air 13-inch (M2)',
      'iPad14,1': 'iPad mini 6',
      'iPad14,2': 'iPad mini 6',
      'iPad16,1': 'iPad mini (A17 Pro)',
      'iPad16,2': 'iPad mini (A17 Pro)',
    };
    if (map.containsKey(m)) return map[m];
    // Already a readable name with spaces: keep it.
    if (m.contains(' ')) return m;
    // Raw hardware identifiers ("iPhone16,1") that aren't in the table fall back
    // to plain "iPhone".
    if (RegExp(r'^iPhone\d+').hasMatch(m)) return 'iPhone';
    if (RegExp(r'^iPad\d+').hasMatch(m)) return 'iPad';
    return null;
  }

  /// Resolve the device model and OS asynchronously.
  static Future<Map<String, String>> getDeviceInfo() async {
    if (debugOverrideDeviceName != null) {
      return {'model': debugOverrideDeviceName!, 'os': 'Test OS'};
    }
    if (_cachedDeviceName != null &&
        _cachedDeviceName != 'Unknown device' &&
        _cachedDeviceOs != null &&
        _cachedDeviceOs != 'Unknown OS') {
      return {'model': _cachedDeviceName!, 'os': _cachedDeviceOs!};
    }

    var model = 'Unknown device';
    var os = 'Unknown OS';

    try {
      if (Platform.isIOS) {
        final i = await DeviceInfoPlugin().iosInfo;
        os = '${i.systemName} ${i.systemVersion}'.trim();
        if (os.isEmpty) os = 'iOS';

        var candidate = lookupAppleMachine(i.utsname.machine) ?? i.modelName.trim();
        if (candidate.isEmpty || candidate.toLowerCase() == 'unknown device' || candidate == 'iPhone') {
          final mapped = lookupAppleMachine(i.utsname.machine);
          // Never use `i.name`: that's the name the owner gave the phone ("Alex's
          // iPhone"), and this label is stored on the server and in synced history.
          if (mapped != null && mapped.isNotEmpty) {
            candidate = mapped;
          } else if (i.model.trim().isNotEmpty &&
              i.model.trim().toLowerCase() != 'unknown device') {
            candidate = i.model.trim();
          } else {
            candidate = 'iPhone';
          }
        }
        model = AuvyDevice.formatDeviceModel(candidate, os);
        if (model == 'Unknown device' || model.isEmpty) model = 'iPhone';
      } else if (Platform.isAndroid) {
        final a = await DeviceInfoPlugin().androidInfo;
        final mfg = a.manufacturer.trim();
        final rawModel = a.model.trim();
        final brand = a.brand.trim();
        final capMfg = mfg.isNotEmpty
            ? '${mfg[0].toUpperCase()}${mfg.substring(1)}'
            : (brand.isNotEmpty ? '${brand[0].toUpperCase()}${brand.substring(1)}' : '');
        String m;
        if (capMfg.isNotEmpty &&
            !rawModel.toLowerCase().startsWith(capMfg.toLowerCase())) {
          m = '$capMfg $rawModel'.trim();
        } else {
          m = rawModel.isNotEmpty
              ? rawModel
              : (capMfg.isNotEmpty ? capMfg : 'Android device');
        }
        os = a.version.release.trim().isNotEmpty
            ? 'Android ${a.version.release}'.trim()
            : 'Android';
        model = AuvyDevice.formatDeviceModel(m, os);
        if (model == 'Unknown device' || model.isEmpty) model = 'Android device';
      } else {
        model = _fallbackDeviceName();
        try {
          os = Platform.operatingSystemVersion;
        } catch (_) {}
      }
    } catch (e) {
      print('DIAG: DeviceInfoService.getDeviceInfo failed ($e), falling back');
      model = _fallbackDeviceName();
      if (os == 'Unknown OS') {
        try {
          if (Platform.isIOS) {
            os = 'iOS';
          } else if (Platform.isAndroid) {
            os = 'Android';
          } else {
            os = Platform.operatingSystem;
          }
        } catch (_) {}
      }
    }

    if (model != 'Unknown device' && model.isNotEmpty) {
      _cachedDeviceName = model;
    }
    if (os != 'Unknown OS' && os.isNotEmpty) {
      _cachedDeviceOs = os;
    }
    print('DIAG: DeviceInfoService.getDeviceInfo resolved: model=$model, os=$os');
    return {'model': model, 'os': os};
  }

  /// Asynchronous getter that ensures the real device name is resolved.
  static Future<String> getDeviceName() async {
    final info = await getDeviceInfo();
    return info['model'] ?? _fallbackDeviceName();
  }

  /// Reset the cache (for tests).
  static void resetForTest() {
    _cachedDeviceName = null;
    _cachedDeviceOs = null;
    debugOverrideDeviceName = null;
  }
}
