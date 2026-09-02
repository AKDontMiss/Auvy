// lib/services/database_service.dart

import 'dart:convert';
import 'dart:async';
import 'package:sqflite/sqflite.dart';
import 'package:path/path.dart';

class DatabaseService {
  static final DatabaseService _instance = DatabaseService._internal();
  factory DatabaseService() => _instance;
  DatabaseService._internal();

  Database? _database;

  Future<Database> get database async {
    if (_database != null) return _database!;
    _database = await _initDatabase();
    return _database!;
  }

  Future<Database> _initDatabase() async {
    final dbPath = await getDatabasesPath();
    final path = join(dbPath, 'auvy_internal.db');

    return await openDatabase(
      path,
      version: 1,
      // SQLite defaults foreign_keys OFF per connection, which silently made
      // every declared `ON DELETE CASCADE` inert — deleting a playlist/song left
      // orphaned playlist_songs / play_counts / listen_history rows forever.
      // Enable it so the cascades actually enforce.
      onConfigure: (db) async {
        await db.execute('PRAGMA foreign_keys = ON');
      },
      onCreate: (db, version) async {
        // 1. Core Tracks/Songs Persistent Ledger
        await db.execute('''
          CREATE TABLE songs (
            id TEXT PRIMARY KEY,
            title TEXT NOT NULL,
            artist TEXT NOT NULL,
            album TEXT,
            thumbnail TEXT,
            durationMs INTEGER,
            isExplicit INTEGER DEFAULT 0,
            source TEXT NOT NULL
          )
        ''');

        // 2. Artists Metric Entity Mapping Table
        await db.execute('''
          CREATE TABLE artists (
            id TEXT PRIMARY KEY,
            name TEXT NOT NULL,
            thumbnail TEXT,
            banner TEXT
          )
        ''');

        // 3. Central Relational Playlists Registry
        await db.execute('''
          CREATE TABLE playlists (
            id TEXT PRIMARY KEY,
            name TEXT NOT NULL,
            description TEXT,
            thumbnail TEXT,
            createdAt INTEGER NOT NULL,
            isLocal INTEGER DEFAULT 1
          )
        ''');

        // 4. Junction Table for Many-to-Many Playlist-to-Song Mappings
        await db.execute('''
          CREATE TABLE playlist_songs (
            playlistId TEXT,
            songId TEXT,
            sequenceIndex INTEGER,
            addedAt INTEGER NOT NULL,
            PRIMARY KEY (playlistId, songId),
            FOREIGN KEY (playlistId) REFERENCES playlists (id) ON DELETE CASCADE,
            FOREIGN KEY (songId) REFERENCES songs (id) ON DELETE CASCADE
          )
        ''');

        // 5. Incremental Play Counts Tracking System
        await db.execute('''
          CREATE TABLE play_counts (
            songId TEXT PRIMARY KEY,
            count INTEGER DEFAULT 0,
            lastPlayed INTEGER NOT NULL,
            FOREIGN KEY (songId) REFERENCES songs (id) ON DELETE CASCADE
          )
        ''');

        // 6. Granular Listen Event History Logging Ledger
        await db.execute('''
          CREATE TABLE listen_history (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            songId TEXT NOT NULL,
            timestamp INTEGER NOT NULL,
            FOREIGN KEY (songId) REFERENCES songs (id) ON DELETE CASCADE
          )
        ''');

        // 7. Nested JSON InnerTube Layout Canvas Page Cache
        await db.execute('''
          CREATE TABLE page_caches (
            cacheKey TEXT PRIMARY KEY,
            jsonPayload TEXT NOT NULL,
            timestamp INTEGER NOT NULL
          )
        ''');

        // Establish operational performance indexing matrix targets
        await db.execute('CREATE INDEX idx_history_timestamp ON listen_history (timestamp)');
        await db.execute('CREATE INDEX idx_playlist_sequence ON playlist_songs (sequenceIndex)');
      },
    );
  }

  // Track and Cache Management Methods

  Future<void> cacheSong(Map<String, dynamic> song) async {
    final db = await database;
    await db.insert(
      'songs',
      {
        'id': song['id'],
        'title': song['title'],
        'artist': song['artist'],
        'album': song['album'] ?? '',
        'thumbnail': song['thumbnail'] ?? '',
        'durationMs': song['durationMs'] ?? 0,
        'isExplicit': (song['isExplicit'] == true) ? 1 : 0,
        'source': song['source'] ?? 'youtube',
      },
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  Future<void> logPlayEvent(String songId) async {
    final db = await database;
    final now = DateTime.now().millisecondsSinceEpoch;

    await db.transaction((txn) async {
      // Append incremental event registry rows
      await txn.insert('listen_history', {
        'songId': songId,
        'timestamp': now,
      });

      // Update structural play frequency metrics
      final List<Map<String, dynamic>> maps = await txn.query(
        'play_counts',
        where: 'songId = ?',
        whereArgs: [songId],
      );

      if (maps.isEmpty) {
        await txn.insert('play_counts', {
          'songId': songId,
          'count': 1,
          'lastPlayed': now,
        });
      } else {
        final currentCount = maps.first['count'] as int;
        await txn.update(
          'play_counts',
          {
            'count': currentCount + 1,
            'lastPlayed': now,
          },
          where: 'songId = ?',
          whereArgs: [songId],
        );
      }
    });
  }

  Future<List<Map<String, dynamic>>> fetchRecentHistory({int limit = 40}) async {
    final db = await database;
    return await db.rawQuery('''
      SELECT s.*, h.timestamp FROM listen_history h
      JOIN songs s ON h.songId = s.id
      ORDER BY h.timestamp DESC
      LIMIT ?
    ''', [limit]);
  }

  // JSON Response Frame Layout Cache Operations

  Future<void> writePageCache(String key, Map<String, dynamic> rawJson) async {
    final db = await database;
    await db.insert(
      'page_caches',
      {
        'cacheKey': key,
        'jsonPayload': jsonEncode(rawJson),
        'timestamp': DateTime.now().millisecondsSinceEpoch,
      },
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  Future<Map<String, dynamic>?> readPageCache(String key, {Duration maxAge = const Duration(hours: 4)}) async {
    final db = await database;
    final List<Map<String, dynamic>> maps = await db.query(
      'page_caches',
      where: 'cacheKey = ?',
      whereArgs: [key],
    );

    if (maps.isEmpty) return null;

    final cachedTime = maps.first['timestamp'] as int;
    final ageDifference = DateTime.now().millisecondsSinceEpoch - cachedTime;
    
    if (ageDifference > maxAge.inMilliseconds) {
      await db.delete('page_caches', where: 'cacheKey = ?', whereArgs: [key]);
      return null;
    }

    return jsonDecode(maps.first['jsonPayload'] as String) as Map<String, dynamic>;
  }

  Future<void> clearAllCacheTables() async {
    final db = await database;
    await db.delete('page_caches');
    print("Database service memory allocations purged seamlessly.");
  }

  /// Drops the timestamped play LOG for Settings → Privacy → "Clear listening
  /// history".
  ///
  /// Only `listen_history`. `play_counts` is deliberately left alone: it is what
  /// Top 50, stats and Wrapped are built from, and someone clearing a browsing
  /// record is not asking for their year of listening to be deleted. The Privacy
  /// screen says so rather than quietly taking both.
  ///
  /// Nothing currently READS this table, which is exactly why it needs clearing
  /// on request — an unread log is still a record of what the user played.
  Future<void> clearListenHistoryTable() async {
    final db = await database;
    await db.delete('listen_history');
  }

  /// Full wipe for "Delete Account": empties EVERY table (songs, artists,
  /// playlists + junction rows, play counts, listen history, page caches) so no
  /// listening data survives the reset. Children first so the delete order
  /// never trips the foreign keys.
  Future<void> wipeAllData() async {
    final db = await database;
    await db.transaction((txn) async {
      for (final table in [
        'listen_history',
        'play_counts',
        'playlist_songs',
        'playlists',
        'songs',
        'artists',
        'page_caches',
      ]) {
        await txn.delete(table);
      }
    });
    print("Local database wiped (all tables emptied).");
  }
}