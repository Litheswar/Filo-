import '../models/file_record.dart';

/// Contract for managing user library records (cataloging saved documents and converted files).
///
/// This manager tracks file metadata and library collections without directly tying
/// business logic to databases (like SQLite or Hive) or Flutter UI state.
abstract class LibraryManager {
  /// Retrieves all records currently in the library.
  Future<List<FileRecord>> getAllRecords();

  /// Retrieves a specific file record by its unique [id], or null if not found.
  Future<FileRecord?> getRecordById(String id);

  /// Adds a new [FileRecord] to the library index.
  /// Throws [ArgumentError] or [StateError] if a record with the same ID already exists.
  Future<void> addRecord(FileRecord record);

  /// Updates an existing [FileRecord] in the library index.
  /// Returns `true` if updated, `false` if not found.
  Future<bool> updateRecord(FileRecord record);

  /// Removes a file record by its [id] from the library.
  /// Returns `true` if removed, `false` if not found.
  Future<bool> removeRecord(String id);

  /// Searches records whose file names contain [query] (case-insensitive).
  Future<List<FileRecord>> searchRecords(String query);

  /// Filters library records by extension (e.g., 'pdf', 'png').
  Future<List<FileRecord>> getRecordsByExtension(String extension);
}

/// In-memory implementation of [LibraryManager] for testing and early development.
class InMemoryLibraryManager implements LibraryManager {
  final Map<String, FileRecord> _storage = {};

  InMemoryLibraryManager([List<FileRecord>? initialRecords]) {
    if (initialRecords != null) {
      for (final record in initialRecords) {
        _storage[record.id] = record;
      }
    }
  }

  @override
  Future<List<FileRecord>> getAllRecords() async {
    final list = _storage.values.toList();
    list.sort((a, b) => b.createdAt.compareTo(a.createdAt));
    return List.unmodifiable(list);
  }

  @override
  Future<FileRecord?> getRecordById(String id) async {
    return _storage[id];
  }

  @override
  Future<void> addRecord(FileRecord record) async {
    if (_storage.containsKey(record.id)) {
      throw StateError('FileRecord with id "${record.id}" already exists.');
    }
    _storage[record.id] = record;
  }

  @override
  Future<bool> updateRecord(FileRecord record) async {
    if (!_storage.containsKey(record.id)) {
      return false;
    }
    _storage[record.id] = record;
    return true;
  }

  @override
  Future<bool> removeRecord(String id) async {
    return _storage.remove(id) != null;
  }

  @override
  Future<List<FileRecord>> searchRecords(String query) async {
    final trimmed = query.trim().toLowerCase();
    if (trimmed.isEmpty) {
      return getAllRecords();
    }
    final matches = _storage.values
        .where((r) => r.fileName.toLowerCase().contains(trimmed))
        .toList();
    matches.sort((a, b) => b.createdAt.compareTo(a.createdAt));
    return List.unmodifiable(matches);
  }

  @override
  Future<List<FileRecord>> getRecordsByExtension(String extension) async {
    final cleanExt = extension.toLowerCase().replaceAll('.', '').trim();
    final matches = _storage.values
        .where((r) => r.extension.toLowerCase() == cleanExt)
        .toList();
    matches.sort((a, b) => b.createdAt.compareTo(a.createdAt));
    return List.unmodifiable(matches);
  }
}
