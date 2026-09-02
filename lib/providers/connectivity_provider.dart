import 'dart:async';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Whether the network is usable, and what the app is allowed to spend on it.
///
/// This is a POLICY object, not just a connectivity reading. Every gate that
/// costs data — preload, prefetch, autoplay top-up, search breadth, feed
/// sections, audio quality — asks here rather than deciding for itself, so the
/// data-saver rules live in exactly one place.
///
/// [DataSaverMode] is the user setting; [ConnectivityState.isInOfflineMode] is
/// the manual offline switch. Both fold into [ConnectivityState.isOffline],
/// which is why every gate below starts by consulting that one getter: a manual
/// switch has to bind the same code paths a real disconnection does, or half the
/// app carries on using the network.
///
/// A caution the getters encode: connectivity_plus reports the LINK, not whether
/// packets flow. [ConnectivityState.isConnected] can be true on a captive portal
/// or a half-open cell handover, so code that waits for a reconnect EVENT also
/// needs a timeout under it.

enum DataSaverMode { off, wifi, always, mobileOnly }

class ConnectivityState {
  final bool isConnected;
  final bool isWifi;
  final DataSaverMode dataSaverMode;
  final DateTime? lastDisconnected;
  final bool isInOfflineMode;

  ConnectivityState({
    this.isConnected = true,
    this.isWifi = true,
    this.dataSaverMode = DataSaverMode.off,
    this.lastDisconnected,
    this.isInOfflineMode = false,
  });

  ConnectivityState copyWith({
    bool? isConnected,
    bool? isWifi,
    DataSaverMode? dataSaverMode,
    DateTime? lastDisconnected,
    bool? isInOfflineMode,
  }) {
    return ConnectivityState(
      isConnected: isConnected ?? this.isConnected,
      isWifi: isWifi ?? this.isWifi,
      dataSaverMode: dataSaverMode ?? this.dataSaverMode,
      lastDisconnected: lastDisconnected ?? this.lastDisconnected,
      isInOfflineMode: isInOfflineMode ?? this.isInOfflineMode,
    );
  }

  // Offline detection
  // Manual "Offline mode" toggle now actually takes effect: it was written by
  // toggleOfflineMode() but read nowhere, so turning it on did nothing. Folding
  // it in here makes every gate (shouldPreload/shouldPrefetch/allowAutoplay/…)
  // that keys off isOffline respect the manual switch.
  bool get isOffline => !isConnected || isInOfflineMode;
  bool get hasInternet => isConnected && !isInOfflineMode;

  // Helper: Should we preload?
  bool get shouldPreload {
    if (isOffline) return false; // Don't preload offline
    if (dataSaverMode == DataSaverMode.always) return false;
    if (dataSaverMode == DataSaverMode.wifi && !isWifi) return false;
    return true;
  }

  // Helper: Should we load high-res images?
  bool get shouldLoadHighResImages {
    if (isOffline) return false;
    if (dataSaverMode == DataSaverMode.always) return false;
    if (dataSaverMode == DataSaverMode.wifi && !isWifi) return false;
    return true;
  }

  bool get shouldUseLowQualityAudio {
    if (isOffline) return false; // Offline means cached only
    if (dataSaverMode == DataSaverMode.always) return true;
    if (dataSaverMode == DataSaverMode.wifi && !isWifi) return true;
    return false;
  }

  // Should we reduce search results?
  int get maxSearchResults {
    if (isOffline) return 0; // No search offline
    if (dataSaverMode == DataSaverMode.always) return 8;
    if (dataSaverMode == DataSaverMode.wifi && !isWifi) return 12;
    return 20;
  }

  bool get shouldPrefetch {
    if (isOffline) return false;
    if (dataSaverMode == DataSaverMode.always) return false;
    if (dataSaverMode == DataSaverMode.mobileOnly && !isWifi) return false;
    return true;
  }

  int get maxPrefetchTracks {
    if (!shouldPrefetch) return 0;
    if (isWifi) return 5;
    if (dataSaverMode == DataSaverMode.off) return 2;
    return 0;
  }

  // Should we reduce home feed sections?
  int get maxHomeSections {
    if (isOffline) return 0; // No feed offline
    if (dataSaverMode == DataSaverMode.always) return 30;
    if (dataSaverMode == DataSaverMode.wifi && !isWifi) return 40;
    return 50;
  }

  // Cache strategy
  String get cacheStrategy {
    if (isOffline) return 'offline-only';
    if (dataSaverMode == DataSaverMode.always) return 'aggressive';
    if (dataSaverMode == DataSaverMode.wifi && !isWifi) return 'balanced';
    return 'performance';
  }

  // Download quality
  String get downloadQuality {
    if (dataSaverMode == DataSaverMode.always) return 'low';
    if (dataSaverMode == DataSaverMode.wifi && !isWifi) return 'medium';
    return 'high';
  }

  // Autoplay behavior
  bool get allowAutoplay {
    if (isOffline) return false;
    if (dataSaverMode == DataSaverMode.always) return false;
    return true;
  }
}

class ConnectivityNotifier extends StateNotifier<ConnectivityState> {
  final Connectivity _connectivity = Connectivity();
  StreamSubscription<List<ConnectivityResult>>? _connectivitySub;

  ConnectivityNotifier() : super(ConnectivityState()) {
    _init();
  }

  void _init() async {
    // 1. Load saved data saver settings
    final prefs = await SharedPreferences.getInstance();
    final savedMode = prefs.getInt('data_saver_mode') ?? 0;
    state = state.copyWith(
      dataSaverMode: DataSaverMode.values[savedMode],
      isInOfflineMode: prefs.getBool(kOfflineMode) ?? false,
    );

    // 2. Monitor connectivity changes (v5.x API returns a single value)
    // FIXED: connectivity_plus v5+ emits List<ConnectivityResult>, not a single value.
    // Previously `result != ConnectivityResult.none` compared a List against an enum
    // constant which is always true, so the app never registered going offline.
    _connectivitySub = _connectivity.onConnectivityChanged.listen((List<ConnectivityResult> results) {
      // Take the first (most relevant) result; fall back to none if list is empty.
      final result = results.isNotEmpty ? results.first : ConnectivityResult.none;
      final isConnected = result != ConnectivityResult.none;
      final isWifi = result == ConnectivityResult.wifi;
      
      state = state.copyWith(
        isConnected: isConnected,
        isWifi: isWifi,
        lastDisconnected: !isConnected ? DateTime.now() : state.lastDisconnected,
      );

      if (isConnected) {
        print(" Back online: ${isWifi ? 'WiFi' : 'Mobile Data'}");
      } else {
        print("WARN: Gone offline");
      }
    });

    // 3. Initial check. connectivity_plus v5+ returns List<ConnectivityResult>
    //    here too, same as the stream above — the old `results is List ? … :
    //    results` ternary was left over from the v4 shape and its else branch
    //    was unreachable.
    final results = await _connectivity.checkConnectivity();
    final result =
        results.isNotEmpty ? results.first : ConnectivityResult.none;
    state = state.copyWith(
      isConnected: result != ConnectivityResult.none,
      isWifi: result == ConnectivityResult.wifi,
    );
  }

  Future<void> setDataSaverMode(DataSaverMode mode) async {
    state = state.copyWith(dataSaverMode: mode);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt('data_saver_mode', mode.index);
    print("Data Saver Mode: ${mode.name}");
  }

  static const String kOfflineMode = 'auvy_offline_mode';

  /// Persisted, like Spotify's offline mode: it is an explicit choice about how
  /// the app may use the network, and silently clearing it on restart would spend
  /// data the user asked it not to. Settings → Data & Storage shows the state, so
  /// it can't get stuck on invisibly.
  Future<void> toggleOfflineMode() async {
    final next = !state.isInOfflineMode;
    state = state.copyWith(isInOfflineMode: next);
    print("Offline Mode: ${next ? 'ON' : 'OFF'}");
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(kOfflineMode, next);
  }

  @override
  void dispose() {
    _connectivitySub?.cancel();
    super.dispose();
  }
}

final connectivityProvider = StateNotifierProvider<ConnectivityNotifier, ConnectivityState>(
  (ref) => ConnectivityNotifier(),
);