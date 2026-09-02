import 'dart:collection';

/// A generic in-memory Least-Recently-Used cache with optional per-entry TTL.
///
/// This is the on-device equivalent of a "hot" cache layer (the role Redis would
/// play on a server): it keeps the most recently used [maxEntries] values in RAM
/// and evicts the oldest when full. Each entry may carry its own expiry, so
/// volatile values (e.g. stream URLs that expire after a few hours) fall out
/// automatically without manual bookkeeping.
///
/// Note: values are assumed non-null. [get] returns null for both "missing" and
/// "expired", which is exactly what callers want here.
class LruCache<K, V> {
  LruCache({this.maxEntries = 128, this.defaultTtl});

  final int maxEntries;
  final Duration? defaultTtl;

  // LinkedHashMap preserves insertion order, which we use as the LRU order.
  final LinkedHashMap<K, _Entry<V>> _store = LinkedHashMap<K, _Entry<V>>();

  V? get(K key) {
    final entry = _store.remove(key);
    if (entry == null) return null;
    if (entry.isExpired) return null; // already removed above
    _store[key] = entry; // re-insert -> marks as most-recently-used
    return entry.value;
  }

  void put(K key, V value, {Duration? ttl}) {
    _store.remove(key);
    final effectiveTtl = ttl ?? defaultTtl;
    _store[key] = _Entry<V>(
      value,
      effectiveTtl == null ? null : DateTime.now().add(effectiveTtl),
    );
    while (_store.length > maxEntries) {
      _store.remove(_store.keys.first); // oldest entry
    }
  }

  // getOrAdd was removed: nothing called it, and its own doc admitted it does
  // NOT de-duplicate concurrent callers, which is the one thing a caller would
  // reach for it to do. That job now lives in CatalogApiClient._dedupe, next to
  // the requests it protects. A cache should cache.

  void remove(K key) => _store.remove(key);
  void clear() => _store.clear();
  int get length => _store.length;
  bool containsKey(K key) => get(key) != null;

  /// Eagerly drop expired entries (otherwise they expire lazily on access).
  void purgeExpired() => _store.removeWhere((_, e) => e.isExpired);
}

class _Entry<V> {
  _Entry(this.value, this.expiry);
  final V value;
  final DateTime? expiry;
  bool get isExpired => expiry != null && DateTime.now().isAfter(expiry!);
}
