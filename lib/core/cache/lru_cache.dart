import 'dart:collection';

/// An in-memory least-recently-used cache with an optional expiry per entry.
///
/// Keeps the [maxEntries] most recently used values and evicts the oldest when
/// full. Entries with an expiry (such as stream URLs) drop out on their own.
/// Values are assumed non-null; [get] returns null for missing or expired keys.
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
