import 'dart:async';
import 'dart:io';

import '../models/conversion_type.dart';
import '../models/file_record.dart';
import '../services/preview/thumbnail_service.dart';
import '../services/storage/file_storage.dart';
import '../services/storage/local_database.dart';
import 'library_manager.dart';

enum LibrarySortField { fileName, createdAt, fileSize, extension }

class LibraryDocumentDetails {
  const LibraryDocumentDetails({
    required this.record,
    required this.fileExists,
  });

  final FileRecord record;
  final bool fileExists;
}

class LibrarySummary {
  const LibrarySummary({required this.totalCount, required this.extensions});

  final int totalCount;
  final Set<String> extensions;
}

class LibraryOperationException implements Exception {
  const LibraryOperationException(this.message);

  final String message;

  @override
  String toString() => 'LibraryOperationException: $message';
}

/// SQLite-backed implementation of [LibraryManager]. File bytes remain on disk.
class SqliteLibraryManager implements LibraryManager {
  SqliteLibraryManager(
    this.localDatabase, {
    this.fileStorage,
    this.thumbnailService,
  });

  final LocalDatabase localDatabase;
  final FileStorage? fileStorage;
  final ThumbnailService? thumbnailService;
  final Map<String, Future<void>> _recordLocks = {};

  static const int maxPageSize = 500;

  @override
  Future<List<FileRecord>> getAllRecords() async {
    final db = await localDatabase.getDatabase();
    final rows = await db.query(
      'documents',
      orderBy: 'created_at DESC, id ASC',
    );
    return rows.map(_recordFromRow).toList(growable: false);
  }

  /// Reads Library count and filter facets without materializing every record.
  Future<LibrarySummary> getSummary() async {
    final db = await localDatabase.getDatabase();
    final rows = await db.rawQuery('''
      SELECT (SELECT COUNT(*) FROM documents) AS total_count, extension
      FROM (SELECT DISTINCT extension FROM documents ORDER BY extension COLLATE NOCASE)
    ''');
    if (rows.isEmpty) {
      return const LibrarySummary(totalCount: 0, extensions: {});
    }
    return LibrarySummary(
      totalCount: rows.first['total_count']! as int,
      extensions: rows
          .map((row) => (row['extension']! as String).toLowerCase())
          .toSet(),
    );
  }

  @override
  Future<FileRecord?> getRecordById(String id) async {
    final db = await localDatabase.getDatabase();
    final rows = await db.query(
      'documents',
      where: 'id = ?',
      whereArgs: [id],
      limit: 1,
    );
    return rows.isEmpty ? null : _recordFromRow(rows.single);
  }

  @override
  Future<void> addRecord(FileRecord record) async {
    final db = await localDatabase.getDatabase();
    try {
      await db.insert('documents', _recordToRow(record));
    } catch (_) {
      if (await getRecordById(record.id) != null) {
        throw StateError('FileRecord with id "${record.id}" already exists.');
      }
      rethrow;
    }
  }

  @override
  Future<bool> updateRecord(FileRecord record) async {
    final db = await localDatabase.getDatabase();
    return await db.update(
          'documents',
          _recordToRow(record),
          where: 'id = ?',
          whereArgs: [record.id],
        ) >
        0;
  }

  @override
  Future<bool> removeRecord(String id) async {
    final db = await localDatabase.getDatabase();
    return await db.delete('documents', where: 'id = ?', whereArgs: [id]) > 0;
  }

  @override
  Future<List<FileRecord>> searchRecords(String query) async {
    final db = await localDatabase.getDatabase();
    final trimmed = query.trim();
    if (trimmed.isEmpty) return getAllRecords();
    final escaped = trimmed
        .replaceAll(r'\', r'\\')
        .replaceAll('%', r'\%')
        .replaceAll('_', r'\_');
    final rows = await db.rawQuery(
      "SELECT * FROM documents WHERE file_name LIKE ? ESCAPE '\\' COLLATE NOCASE ORDER BY created_at DESC, id ASC",
      ['%$escaped%'],
    );
    return rows.map(_recordFromRow).toList(growable: false);
  }

  @override
  Future<List<FileRecord>> getRecordsByExtension(String extension) async {
    final cleanExtension = extension.toLowerCase().replaceAll('.', '').trim();
    if (cleanExtension.isEmpty) return const [];
    final db = await localDatabase.getDatabase();
    final rows = await db.query(
      'documents',
      where: 'extension = ? COLLATE NOCASE',
      whereArgs: [cleanExtension],
      orderBy: 'created_at DESC, id ASC',
    );
    return rows.map(_recordFromRow).toList(growable: false);
  }

  /// Filters library records by their stable conversion type key.
  Future<List<FileRecord>> getRecordsByConversionType(
    ConversionType conversionType,
  ) async {
    final db = await localDatabase.getDatabase();
    final rows = await db.query(
      'documents',
      where: 'conversion_type = ?',
      whereArgs: [_conversionTypeKey(conversionType)],
      orderBy: 'created_at DESC, id ASC',
    );
    return rows.map(_recordFromRow).toList(growable: false);
  }

  /// Searches and filters documents with validated ordering and pagination.
  /// Equal sort values are ordered by stable document ID.
  Future<List<FileRecord>> getDocuments({
    String? searchQuery,
    String? extension,
    ConversionType? conversionType,
    LibrarySortField sortBy = LibrarySortField.createdAt,
    bool ascending = false,
    int? limit,
    int offset = 0,
  }) async {
    if (limit != null && (limit < 0 || limit > maxPageSize)) {
      throw ArgumentError.value(
        limit,
        'limit',
        'Limit must be between 0 and $maxPageSize.',
      );
    }
    if (offset < 0) {
      throw ArgumentError.value(offset, 'offset', 'Offset cannot be negative.');
    }

    final where = <String>[];
    final whereArgs = <Object?>[];
    final query = searchQuery?.trim() ?? '';
    if (query.isNotEmpty) {
      final escaped = query
          .replaceAll(r'\', r'\\')
          .replaceAll('%', r'\%')
          .replaceAll('_', r'\_');
      where.add("file_name LIKE ? ESCAPE '\\' COLLATE NOCASE");
      whereArgs.add('%$escaped%');
    }
    final cleanExtension = extension?.toLowerCase().replaceAll('.', '').trim();
    if (cleanExtension != null && cleanExtension.isNotEmpty) {
      where.add('extension = ? COLLATE NOCASE');
      whereArgs.add(cleanExtension);
    }
    if (conversionType != null) {
      where.add('conversion_type = ?');
      whereArgs.add(_conversionTypeKey(conversionType));
    }

    final sortColumn = switch (sortBy) {
      LibrarySortField.fileName => 'file_name COLLATE NOCASE',
      LibrarySortField.createdAt => 'created_at',
      LibrarySortField.fileSize => 'size_in_bytes',
      LibrarySortField.extension => 'extension COLLATE NOCASE',
    };
    final direction = ascending ? 'ASC' : 'DESC';
    final sql = StringBuffer('SELECT * FROM documents');
    if (where.isNotEmpty) sql.write(' WHERE ${where.join(' AND ')}');
    sql.write(' ORDER BY $sortColumn $direction, id ASC');
    if (limit != null || offset > 0) {
      sql.write(' LIMIT ? OFFSET ?');
      whereArgs.add(limit ?? -1);
      whereArgs.add(offset);
    }

    final db = await localDatabase.getDatabase();
    final rows = await db.rawQuery(sql.toString(), whereArgs);
    return rows.map(_recordFromRow).toList(growable: false);
  }

  /// Returns stored metadata plus an existence check limited to managed files.
  Future<LibraryDocumentDetails?> getDocumentDetails(String id) async {
    final record = await getRecordById(id);
    if (record == null) return null;
    final exists = await _requireFileStorage().fileExists(
      File(record.localPath),
    );
    return LibraryDocumentDetails(record: record, fileExists: exists);
  }

  /// Renames a managed document while preserving its format and record ID.
  /// Provide a basename, or a basename followed by the existing extension.
  Future<FileRecord> renameDocument(String id, String requestedName) async =>
      _withRecordLock(id, () async {
        final existing = await getRecordById(id);
        if (existing == null) {
          throw const LibraryOperationException('Document was not found.');
        }
        if (requestedName.trim().isEmpty ||
            requestedName.contains('/') ||
            requestedName.contains(r'\') ||
            requestedName.contains('..')) {
          throw const LibraryOperationException('The new filename is invalid.');
        }
        final newName = _nameWithPreservedExtension(existing, requestedName);
        final storage = _requireFileStorage();
        final source = File(existing.localPath);
        await storage.getMetadata(source);
        final record = await _invalidateThumbnail(existing);
        final renamed = await storage.renameStoredFileTo(source, newName);
        final updated = record.copyWith(
          fileName: newName,
          localPath: renamed.path,
        );
        try {
          if (!await updateRecord(updated)) {
            throw const LibraryOperationException(
              'Document metadata changed before the rename completed.',
            );
          }
          return updated;
        } catch (error) {
          try {
            await storage.renameStoredFileTo(renamed, record.fileName);
          } catch (_) {
            throw const LibraryOperationException(
              'Rename metadata update failed and the original filename could not be restored.',
            );
          }
          if (error is LibraryOperationException) rethrow;
          throw const LibraryOperationException(
            'Rename metadata update failed; the original file was restored.',
          );
        }
      });

  /// Deletes the physical file first, then its database metadata.
  /// If the database deletion fails, the row remains as a recovery reference
  /// and an exception is reported; the missing file is never hidden as success.
  Future<bool> deleteDocument(String id) async => _withRecordLock(id, () async {
    final existing = await getRecordById(id);
    if (existing == null) return false;
    final record = await _invalidateThumbnail(existing);
    await _requireFileStorage().deleteStoredFile(File(record.localPath));
    try {
      final removed = await removeRecord(id);
      if (!removed) {
        throw const LibraryOperationException(
          'The file was deleted but its metadata row could not be removed.',
        );
      }
      return true;
    } catch (error) {
      if (error is LibraryOperationException) rethrow;
      throw const LibraryOperationException(
        'The file was deleted but its metadata row could not be removed.',
      );
    }
  });

  FileStorage _requireFileStorage() =>
      fileStorage ??
      (throw StateError('FileStorage is required for filesystem operations.'));

  Future<FileRecord> _invalidateThumbnail(FileRecord record) async {
    if (record.thumbnailPath == null || thumbnailService == null) {
      return record;
    }
    final updated = record.copyWith(clearThumbnailPath: true);
    if (!await updateRecord(updated)) {
      throw const LibraryOperationException(
        'Document metadata changed before its preview could be cleared.',
      );
    }
    try {
      await thumbnailService!.deleteThumbnailForDocument(record);
    } on FileStorageException {
      throw const LibraryOperationException(
        'The preview reference was cleared, but its cached file could not be removed.',
      );
    } on FileSystemException {
      throw const LibraryOperationException(
        'The preview reference was cleared, but its cached file could not be removed.',
      );
    }
    return updated;
  }

  Future<T> _withRecordLock<T>(String id, Future<T> Function() action) async {
    final previous = _recordLocks[id] ?? Future<void>.value();
    final release = Completer<void>();
    _recordLocks[id] = release.future;
    await previous;
    try {
      return await action();
    } finally {
      release.complete();
      if (identical(_recordLocks[id], release.future)) _recordLocks.remove(id);
    }
  }

  String _nameWithPreservedExtension(FileRecord record, String requestedName) {
    final extension = record.extension;
    final suffix = '.$extension';
    if (requestedName.toLowerCase().endsWith(suffix.toLowerCase())) {
      final base = requestedName.substring(
        0,
        requestedName.length - suffix.length,
      );
      if (base.isEmpty) {
        throw const LibraryOperationException('The new filename is invalid.');
      }
      return '$base$suffix';
    }
    if (requestedName.lastIndexOf('.') > 0) {
      throw const LibraryOperationException(
        'Renaming cannot change the document extension.',
      );
    }
    return '$requestedName$suffix';
  }

  Map<String, Object?> _recordToRow(FileRecord record) => {
    'id': record.id,
    'file_name': record.fileName,
    'extension': record.extension.toLowerCase(),
    'size_in_bytes': record.sizeInBytes,
    'created_at': record.createdAt.toUtc().toIso8601String(),
    'local_path': record.localPath,
    'thumbnail_path': record.thumbnailPath,
    'conversion_type': record.conversionType == null
        ? null
        : _conversionTypeKey(record.conversionType!),
    'storage_location': _storageLocationKey(record.storageLocation),
  };

  FileRecord _recordFromRow(Map<String, Object?> row) => FileRecord(
    id: row['id']! as String,
    fileName: row['file_name']! as String,
    extension: row['extension']! as String,
    sizeInBytes: row['size_in_bytes']! as int,
    createdAt: DateTime.parse(row['created_at']! as String).toLocal(),
    localPath: row['local_path']! as String,
    thumbnailPath: row['thumbnail_path'] as String?,
    conversionType: _conversionTypeFromKey(row['conversion_type'] as String?),
    storageLocation: _storageLocationFromKey(
      row['storage_location']! as String,
    ),
  );

  static String _conversionTypeKey(ConversionType value) => switch (value) {
    ConversionType.jpgToPng => 'jpg_to_png',
    ConversionType.pngToJpg => 'png_to_jpg',
    ConversionType.singleImageToPdf => 'single_image_to_pdf',
    ConversionType.multipleImagesToPdf => 'multiple_images_to_pdf',
    ConversionType.pdfToImages => 'pdf_to_images',
    ConversionType.txtToPdf => 'txt_to_pdf',
    ConversionType.pdfToTxt => 'pdf_to_txt',
  };

  static ConversionType? _conversionTypeFromKey(String? value) =>
      switch (value) {
        null => null,
        'jpg_to_png' => ConversionType.jpgToPng,
        'png_to_jpg' => ConversionType.pngToJpg,
        'single_image_to_pdf' => ConversionType.singleImageToPdf,
        'multiple_images_to_pdf' => ConversionType.multipleImagesToPdf,
        'pdf_to_images' => ConversionType.pdfToImages,
        'txt_to_pdf' => ConversionType.txtToPdf,
        'pdf_to_txt' => ConversionType.pdfToTxt,
        _ => throw const LocalDatabaseException(
          'Database contains an unknown conversion type.',
        ),
      };

  static String _storageLocationKey(StorageLocation value) => switch (value) {
    StorageLocation.internalDocuments => 'internal_documents',
    StorageLocation.temporaryCache => 'temporary_cache',
    StorageLocation.externalShared => 'external_shared',
  };

  static StorageLocation _storageLocationFromKey(String value) =>
      switch (value) {
        'internal_documents' => StorageLocation.internalDocuments,
        'temporary_cache' => StorageLocation.temporaryCache,
        'external_shared' => StorageLocation.externalShared,
        _ => throw const LocalDatabaseException(
          'Database contains an unknown storage location.',
        ),
      };
}
