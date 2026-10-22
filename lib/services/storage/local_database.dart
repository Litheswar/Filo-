import 'dart:io';

import 'package:path_provider/path_provider.dart';
import 'package:sqflite/sqflite.dart' as sqflite;
import 'package:sqflite_common/sqlite_api.dart' show Database, DatabaseFactory;

/// Database-level error with a concise message safe to show in diagnostics.
class LocalDatabaseException implements Exception {
  const LocalDatabaseException(this.message);

  final String message;

  @override
  String toString() => 'LocalDatabaseException: $message';
}

/// Opens Filo's metadata-only SQLite database in app-private documents storage.
class LocalDatabase {
  LocalDatabase({
    Future<Directory> Function()? documentsDirectoryProvider,
    DatabaseFactory? databaseFactory,
    this.appDirectoryName = 'Filo',
    this.databaseName = 'filo.sqlite',
  }) : _documentsDirectoryProvider =
           documentsDirectoryProvider ?? getApplicationDocumentsDirectory,
       _databaseFactory = databaseFactory ?? sqflite.databaseFactory {
    if (appDirectoryName.isEmpty ||
        appDirectoryName.contains('/') ||
        appDirectoryName.contains(r'\') ||
        appDirectoryName == '.' ||
        appDirectoryName == '..' ||
        databaseName.isEmpty ||
        databaseName.contains('/') ||
        databaseName.contains(r'\') ||
        databaseName == '.' ||
        databaseName == '..') {
      throw ArgumentError('Database directory and filename must be basenames.');
    }
  }

  static const int schemaVersion = 1;

  final Future<Directory> Function() _documentsDirectoryProvider;
  final DatabaseFactory _databaseFactory;
  final String appDirectoryName;
  final String databaseName;
  Database? _database;

  /// The open connection, or null before initialization/after close.
  Database? get databaseOrNull => _database;

  /// Creates the private database directory, opens the database, and applies
  /// schema migrations. Repeated calls return the same open connection.
  Future<Database> initialize() async {
    if (_database != null && _database!.isOpen) return _database!;
    try {
      final platformDocuments = await _documentsDirectoryProvider();
      final directory = Directory(
        '${platformDocuments.path}${Platform.pathSeparator}$appDirectoryName${Platform.pathSeparator}database',
      );
      await directory.create(recursive: true);
      final path = '${directory.path}${Platform.pathSeparator}$databaseName';
      _database = await _databaseFactory.openDatabase(
        path,
        options: sqflite.OpenDatabaseOptions(
          version: schemaVersion,
          onConfigure: (db) async => db.execute('PRAGMA foreign_keys = ON'),
          onCreate: _createSchema,
          onUpgrade: _upgradeSchema,
        ),
      );
      return _database!;
    } on LocalDatabaseException {
      rethrow;
    } catch (_) {
      _database = null;
      throw const LocalDatabaseException(
        'Filo metadata database could not be initialized.',
      );
    }
  }

  /// Closes the connection. Calling close more than once is safe.
  Future<void> close() async {
    final database = _database;
    _database = null;
    if (database == null || !database.isOpen) return;
    try {
      await database.close();
    } catch (_) {
      throw const LocalDatabaseException(
        'Filo metadata database could not be closed.',
      );
    }
  }

  /// Returns the current connection, initializing it if necessary.
  Future<Database> getDatabase() async =>
      _database != null && _database!.isOpen ? _database! : initialize();

  Future<void> _createSchema(Database db, int version) async {
    await db.execute('''
      CREATE TABLE documents (
        id TEXT PRIMARY KEY NOT NULL,
        file_name TEXT NOT NULL,
        extension TEXT NOT NULL,
        size_in_bytes INTEGER NOT NULL CHECK (size_in_bytes >= 0),
        created_at TEXT NOT NULL,
        local_path TEXT NOT NULL,
        thumbnail_path TEXT,
        conversion_type TEXT,
        storage_location TEXT NOT NULL
      )
    ''');
    await db.execute(
      'CREATE INDEX documents_file_name_idx ON documents(file_name COLLATE NOCASE)',
    );
    await db.execute(
      'CREATE INDEX documents_created_at_idx ON documents(created_at DESC)',
    );
    await db.execute(
      'CREATE INDEX documents_extension_idx ON documents(extension COLLATE NOCASE)',
    );
    await db.execute('''
      CREATE TABLE activities (
        id TEXT PRIMARY KEY NOT NULL,
        job_id TEXT NOT NULL,
        conversion_type TEXT NOT NULL,
        is_success INTEGER NOT NULL CHECK (is_success IN (0, 1)),
        output_name TEXT,
        error_summary TEXT,
        timestamp TEXT NOT NULL,
        duration_millis INTEGER
      )
    ''');
    await db.execute(
      'CREATE INDEX activities_timestamp_idx ON activities(timestamp DESC)',
    );
  }

  Future<void> _upgradeSchema(
    Database db,
    int oldVersion,
    int newVersion,
  ) async {
    // Future schema changes belong here, applied incrementally in transactions
    // managed by sqflite. The v1 schema is the initial released schema.
    if (oldVersion > newVersion) {
      throw const LocalDatabaseException(
        'Database downgrade is not supported.',
      );
    }
  }
}
