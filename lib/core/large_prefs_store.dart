import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_platform_interface.dart';
import 'package:shared_preferences_platform_interface/types.dart';

/// Keeps large preference values out of iOS's settings store.
///
/// iOS's settings store (NSUserDefaults) is meant for small values and has a
/// 4 MB limit. Auvy kept its library (twice: live and last-known-good), its
/// taste data and its listening history there, and past 4 MB iOS logs
/// "Attempting to store >= 4194304 bytes of data in CFPreferences/NSUserDefaults
/// on this platform is invalid" and puts the store in "direct mode", where the
/// app writes the whole file itself, later. Seen on device (2026-10-15): a cloud
/// restore's settings (the accent colour, the onboarding flag) were never
/// written before the app was closed, and the next launch showed onboarding in
/// the default colours.
///
/// This store sits between SharedPreferences and the platform store. Strings
/// and string lists above [largeThreshold] go to their own files in Application
/// Support; everything else passes through unchanged. Every caller keeps using
/// SharedPreferences exactly as before, and native code, which only ever reads
/// small values (the alarm, the icon), still finds them where it did.
///
/// iOS only for now: Android's preferences file has no such limit.
class LargePrefsStore extends SharedPreferencesStorePlatform {
  LargePrefsStore(this._inner, this._dir);

  final SharedPreferencesStorePlatform _inner;
  final Directory _dir;

  /// Above this many characters a value lives in a file.
  static const int largeThreshold = 32 * 1024;

  static const String _defaultPrefix = 'flutter.';

  /// Installs the store and moves existing large values into files. Must run
  /// before the first SharedPreferences.getInstance(), which caches everything
  /// it reads. Any failure leaves the platform store in charge, as before.
  static Future<void> install() async {
    if (kIsWeb || !Platform.isIOS) return;
    try {
      final support = await getApplicationSupportDirectory();
      final dir = Directory('${support.path}/prefs_large');
      if (!dir.existsSync()) dir.createSync(recursive: true);
      final store = LargePrefsStore(SharedPreferencesStorePlatform.instance, dir);
      final moved = await store.migrate();
      SharedPreferencesStorePlatform.instance = store;
      startupNote = moved > 0
          ? 'prefs: moved $moved large value(s) out of the iOS settings store into files'
          : null;
    } catch (e) {
      startupNote =
          'WARN: prefs: large-value store not installed ($e) — the iOS settings store keeps everything';
    }
  }

  /// What [install] did, logged by main() once the activity log is running
  /// (install runs first, before anything can be recorded).
  static String? startupNote;

  /// Moves every large value the platform store holds into a file, then removes
  /// it from the platform store, in that order, so an interruption at any point
  /// leaves the value readable. Returns how many moved.
  Future<int> migrate() async {
    final all = await _inner.getAll();
    var moved = 0;
    for (final entry in all.entries) {
      if (!_isLarge(entry.value)) continue;
      // A file already there is newer than this copy: files are written only
      // after the platform store, so this is a removal that didn't reach disk
      // last time (iOS's direct mode loses writes when the app is closed).
      // Overwriting the file would bring an old library back.
      if (_fileFor(entry.key).existsSync()) {
        await _inner.remove(entry.key);
        continue;
      }
      if (await _writeFile(entry.key, entry.value)) {
        await _inner.remove(entry.key);
        moved++;
      }
    }
    return moved;
  }

  // ── The platform interface ──

  /// The last operation on each key. Writes to one key run strictly in order
  /// (the library is saved several times in quick succession), so the file and
  /// the platform store always end up holding the newest value.
  final Map<String, Future<bool>> _queues = {};

  Future<bool> _serial(String key, Future<bool> Function() op) {
    final previous = _queues[key] ?? Future.value(true);
    final next = previous.then((_) => op(), onError: (_) => op());
    _queues[key] = next;
    next.whenComplete(() {
      if (identical(_queues[key], next)) _queues.remove(key);
    });
    return next;
  }

  @override
  Future<bool> setValue(String valueType, String key, Object value) => _serial(key, () async {
        if ((valueType == 'String' || valueType == 'StringList') && _isLarge(value)) {
          if (await _writeFile(key, value)) {
            // A copy in the platform store would be read back as well; it goes.
            await _inner.remove(key);
            return true;
          }
          // The file couldn't be written (no space?): keep the old behaviour
          // rather than lose the value.
          return _inner.setValue(valueType, key, value);
        }
        _deleteFile(key);
        return _inner.setValue(valueType, key, value);
      });

  @override
  Future<bool> remove(String key) => _serial(key, () async {
        _deleteFile(key);
        return _inner.remove(key);
      });

  /// Waits for every write still in flight. For tests and orderly shutdown.
  Future<void> flush() async {
    while (_queues.isNotEmpty) {
      await Future.wait(_queues.values.toList());
    }
  }

  @override
  Future<bool> clear() => clearWithParameters(
      ClearParameters(filter: PreferencesFilter(prefix: _defaultPrefix)));

  @override
  Future<bool> clearWithPrefix(String prefix) =>
      clearWithParameters(ClearParameters(filter: PreferencesFilter(prefix: prefix)));

  @override
  Future<bool> clearWithParameters(ClearParameters parameters) async {
    final filter = parameters.filter;
    for (final key in _fileKeys()) {
      if (_matches(key, filter)) _deleteFile(key);
    }
    try {
      return await _inner.clearWithParameters(parameters);
    } on UnimplementedError {
      return _inner.clear();
    }
  }

  @override
  Future<Map<String, Object>> getAll() => getAllWithParameters(
      GetAllParameters(filter: PreferencesFilter(prefix: _defaultPrefix)));

  @override
  Future<Map<String, Object>> getAllWithPrefix(String prefix) =>
      getAllWithParameters(GetAllParameters(filter: PreferencesFilter(prefix: prefix)));

  @override
  Future<Map<String, Object>> getAllWithParameters(GetAllParameters parameters) async {
    Map<String, Object> fromPlatform;
    try {
      fromPlatform = await _inner.getAllWithParameters(parameters);
    } on UnimplementedError {
      fromPlatform = await _inner.getAll();
    }
    final out = <String, Object>{...fromPlatform};
    for (final key in _fileKeys()) {
      if (!_matches(key, parameters.filter)) continue;
      final value = _readFile(key);
      if (value != null) out[key] = value;
    }
    return out;
  }

  // ── Files ──

  static bool _isLarge(Object value) {
    if (value is String) return value.length > largeThreshold;
    if (value is List) {
      var n = 0;
      for (final v in value) {
        n += v.toString().length;
        if (n > largeThreshold) return true;
      }
    }
    return false;
  }

  static bool _matches(String key, PreferencesFilter filter) =>
      key.startsWith(filter.prefix) && (filter.allowList == null || filter.allowList!.contains(key));

  /// File names are the key in URL-safe base64, so any key is a valid name.
  File _fileFor(String key) =>
      File('${_dir.path}/${base64Url.encode(utf8.encode(key)).replaceAll('=', '')}.json');

  String? _keyOf(String fileName) {
    if (!fileName.endsWith('.json')) return null;
    var b64 = fileName.substring(0, fileName.length - 5);
    while (b64.length % 4 != 0) {
      b64 += '=';
    }
    try {
      return utf8.decode(base64Url.decode(b64));
    } catch (_) {
      return null;
    }
  }

  Iterable<String> _fileKeys() sync* {
    if (!_dir.existsSync()) return;
    for (final f in _dir.listSync()) {
      if (f is! File || f.path.endsWith('.tmp')) continue;
      final key = _keyOf(f.uri.pathSegments.last);
      if (key != null) yield key;
    }
  }

  /// Written to a temporary file and renamed over the old one, so a crash
  /// mid-write leaves the previous value, never half of the new one.
  int _tmpCounter = 0;

  Future<bool> _writeFile(String key, Object value) async {
    try {
      final file = _fileFor(key);
      final tmp = File('${file.path}.${_tmpCounter++}.tmp');
      final body = jsonEncode({
        't': value is String ? 'String' : 'StringList',
        'v': value is String ? value : (value as List).map((e) => e.toString()).toList(),
      });
      await tmp.writeAsString(body, flush: true);
      await tmp.rename(file.path);
      return true;
    } catch (e) {
      print('WARN: prefs: could not write the file for a large value ($e)');
      return false;
    }
  }

  Object? _readFile(String key) {
    try {
      final file = _fileFor(key);
      if (!file.existsSync()) return null;
      final decoded = jsonDecode(file.readAsStringSync());
      if (decoded is! Map) return null;
      final v = decoded['v'];
      if (decoded['t'] == 'StringList' && v is List) return v.map((e) => e.toString()).toList();
      if (v is String) return v;
    } catch (e) {
      print('WARN: prefs: unreadable file for a large value ($e)');
    }
    return null;
  }

  void _deleteFile(String key) {
    try {
      final file = _fileFor(key);
      if (file.existsSync()) file.deleteSync();
    } catch (_) {}
  }
}
