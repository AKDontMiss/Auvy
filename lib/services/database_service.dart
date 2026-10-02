// lib/services/database_service.dart

import 'dart:convert';
import 'dart:async';
import 'dart:io';
import 'package:path_provider/path_provider.dart';
import 'package:sqflite/sqflite.dart';
import 'package:path/path.dart';

/// On iOS the database lives in Application Support, not sqflite's default.
///
/// The default there is Documents, which UIFileSharingEnabled exposes in the
/// Files app, so the library and recent searches would be visible (and
/// deletable) under "On My iPhone → Auvy". An existing file is moved once,
/// before anything opens it. Android keeps the sqflite default.
Future<String> _databaseFilePath() async {
  const name = 'auvy_internal.db';
  if (!Platform.isIOS) return join(await getDatabasesPath(), name);
  final dir = await getApplicationSupportDirectory();
  if (!dir.existsSync()) dir.createSync(recursive: true);
  final target = join(dir.path, name);
  final legacy = join(await getDatabasesPath(), name);
  if (!File(target).existsSync() && File(legacy).existsSync()) {
    try {
      // The sidecars travel with the database: a WAL holds committed pages
      // the main file does not have yet.
      for (final suffix in const ['-wal', '-shm', '-journal', '']) {
        final f = File('$legacy$suffix');
        if (f.existsSync()) f.renameSync('$target$suffix');
      }
      print('db: moved $name out of Documents into Application Support');
    } catch (e) {
      // Whichever copy of the main file exists is the one to open — an empty
      // new database would read as a wiped library.
      print('db: move failed ($e)');
      return File(target).existsSync() ? target : legacy;
    }
  }
  return target;
}

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
    final path = await _databaseFilePath();

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
      onOpen: (db) async {
        try {
          final cutoff = DateTime.now().millisecondsSinceEpoch -
              const Duration(hours: 24).inMilliseconds;
          final count = await db.delete('page_caches',
              where: 'timestamp < ?', whereArgs: [cutoff]);
          if (count > 0) {
            print('db: purged $count expired page cache rows on open');
          }
        } catch (_) {}
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

  /// Purges expired page caches older than [maxAge] (defaults to 24 hours).
  /// Prevents unbounded database file growth from one-off search and browse queries.
  Future<int> purgeExpiredPageCaches(
      {Duration maxAge = const Duration(hours: 24)}) async {
    try {
      final db = await database;
      final cutoff =
          DateTime.now().millisecondsSinceEpoch - maxAge.inMilliseconds;
      final deleted = await db.delete(
        'page_caches',
        where: 'timestamp < ?',
        whereArgs: [cutoff],
      );
      if (deleted > 0) {
        print('db: purged $deleted expired page cache row(s)');
      }
      return deleted;
    } catch (e) {
      print('WARN: database purgeExpiredPageCaches failed: $e');
      return 0;
    }
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