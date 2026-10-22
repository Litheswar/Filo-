import 'dart:io';

import 'package:filo/application/activity_manager.dart';
import 'package:filo/application/sqlite_activity_manager.dart';
import 'package:filo/application/sqlite_library_manager.dart';
import 'package:filo/models/conversion_type.dart';
import 'package:filo/models/file_record.dart';
import 'package:filo/services/storage/local_database.dart';
import 'package:filo/services/storage/file_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  late Directory root;
  late LocalDatabase localDatabase;
  late SqliteLibraryManager library;
  late SqliteActivityManager activities;
  late FileStorage fileStorage;

  setUpAll(() => sqfliteFfiInit());

  setUp(() async {
    root = await Directory.systemTemp.createTemp('filo_db_test_');
    localDatabase = LocalDatabase(
      documentsDirectoryProvider: () async => root,
      databaseFactory: databaseFactoryFfi,
    );
    fileStorage = FileStorage(
      documentsDirectoryProvider: () async => root,
      temporaryDirectoryProvider: () async => root,
    );
    library = SqliteLibraryManager(localDatabase, fileStorage: fileStorage);
    activities = SqliteActivityManager(localDatabase);
  });

  tearDown(() async {
    await localDatabase.close();
    if (await root.exists()) await root.delete(recursive: true);
  });

  FileRecord record({
    String id = 'doc-1',
    String fileName = 'report.pdf',
    DateTime? createdAt,
    ConversionType? conversionType = ConversionType.txtToPdf,
  }) => FileRecord(
    id: id,
    fileName: fileName,
    extension: fileName.split('.').last,
    sizeInBytes: 1234,
    createdAt: createdAt ?? DateTime.utc(2025, 4, 5, 6, 7, 8),
    localPath: '/private/Filo/documents/$fileName',
    thumbnailPath: '/private/Filo/thumbnails/$id.png',
    conversionType: conversionType,
    storageLocation: StorageLocation.internalDocuments,
  );

  ActivityRecord activity({
    required String id,
    required DateTime timestamp,
    ConversionType conversionType = ConversionType.pdfToTxt,
    bool success = true,
    String? outputPath,
    String? errorMessage,
  }) => ActivityRecord(
    id: id,
    jobId: 'job-$id',
    conversionType: conversionType,
    isSuccess: success,
    outputPath: outputPath,
    errorMessage: errorMessage,
    timestamp: timestamp,
    duration: const Duration(milliseconds: 125),
  );

  test('initializes schema, enables foreign keys, and closes/reopens', () async {
    final db = await localDatabase.initialize();
    expect(db.isOpen, isTrue);
    expect(await db.getVersion(), LocalDatabase.schemaVersion);
    expect((await db.rawQuery('PRAGMA foreign_keys')).single.values.single, 1);
    expect(
      await db.query('sqlite_master', where: 'type = ?', whereArgs: ['table']),
      hasLength(2),
    );
    final path = db.path;
    expect(
      path,
      contains(
        '${Platform.pathSeparator}Filo${Platform.pathSeparator}database${Platform.pathSeparator}',
      ),
    );

    await localDatabase.close();
    expect(db.isOpen, isFalse);
    final reopened = await localDatabase.initialize();
    expect(reopened.isOpen, isTrue);
    expect(reopened.path, path);
  });

  test('stores records with stable enum keys and UTC timestamps', () async {
    final originalTime = DateTime(2024, 2, 3, 4, 5, 6, 7, 8);
    final original = record(createdAt: originalTime);
    await library.addRecord(original);

    final restored = await library.getRecordById(original.id);
    expect(restored, original);
    final raw = (await (await localDatabase.getDatabase()).query('documents'))
        .single;
    expect(raw['conversion_type'], 'txt_to_pdf');
    expect(raw['storage_location'], 'internal_documents');
    expect(raw['created_at'], originalTime.toUtc().toIso8601String());
  });

  test('adds, retrieves, updates, and removes library metadata only', () async {
    final original = record();
    await library.addRecord(original);
    expect((await library.getAllRecords()).map((item) => item.id), [
      original.id,
    ]);

    final updated = record(fileName: 'renamed.pdf').copyWith(
      id: original.id,
      localPath: original.localPath,
      thumbnailPath: original.thumbnailPath,
    );
    expect(await library.updateRecord(updated), isTrue);
    final fetched = await library.getRecordById(original.id);
    expect(fetched?.fileName, updated.fileName);
    expect(fetched?.localPath, updated.localPath);
    expect(await library.removeRecord(original.id), isTrue);
    expect(await library.getRecordById(original.id), isNull);
    expect(await library.removeRecord(original.id), isFalse);
  });

  test(
    'library summary reads count and unique extensions without records',
    () async {
      await library.addRecord(record(id: 'pdf-one', fileName: 'one.pdf'));
      await library.addRecord(record(id: 'pdf-two', fileName: 'two.pdf'));
      await library.addRecord(record(id: 'png', fileName: 'photo.PNG'));

      final summary = await library.getSummary();

      expect(summary.totalCount, 3);
      expect(summary.extensions, {'pdf', 'png'});
    },
  );

  test(
    'rejects duplicate IDs and returns false for updates to missing rows',
    () async {
      final item = record();
      await library.addRecord(item);
      await expectLater(library.addRecord(item), throwsA(isA<StateError>()));
      expect(await library.updateRecord(record(id: 'missing')), isFalse);
    },
  );

  test(
    'search is literal for percent and underscore; filters extensions',
    () async {
      final percent = record(id: 'percent', fileName: '100%_complete.pdf');
      final falsePositive = record(id: 'other', fileName: '100xxcomplete.pdf');
      final image = record(
        id: 'image',
        fileName: 'photo.png',
        conversionType: null,
      );
      await library.addRecord(percent);
      await library.addRecord(falsePositive);
      await library.addRecord(image);

      expect(
        (await library.searchRecords('%_complete')).map((item) => item.id),
        [percent.id],
      );
      expect((await library.searchRecords('100')).map((item) => item.id), [
        falsePositive.id,
        percent.id,
      ]);
      expect(
        (await library.getRecordsByExtension('.PNG')).map((item) => item.id),
        [image.id],
      );
      expect(
        (await library.getRecordsByConversionType(ConversionType.txtToPdf))
            .map((item) => item.id),
        [falsePositive.id, percent.id],
      );
      expect(await library.searchRecords('not-found'), isEmpty);
      expect(await library.getRecordsByExtension('xyz'), isEmpty);
    },
  );

  test(
    'library and activity data persist after reopening the database',
    () async {
      await library.addRecord(record());
      await activities.logActivity(
        activity(id: 'success', timestamp: DateTime.utc(2025, 1, 1)),
      );
      await localDatabase.close();

      expect(await library.getRecordById('doc-1'), isNotNull);
      expect((await activities.getActivities()).single.id, 'success');
    },
  );

  test(
    'activity history is newest first and persists display-only metadata',
    () async {
      await activities.logActivity(
        activity(
          id: 'older',
          timestamp: DateTime.utc(2025, 1, 1),
          outputPath: r'C:\private\secret.txt',
        ),
      );
      await activities.logActivity(
        activity(
          id: 'failed',
          timestamp: DateTime.utc(2025, 1, 2),
          success: false,
          errorMessage: r'Could not read C:\private\secret.pdf: denied',
        ),
      );
      await activities.logActivity(
        activity(
          id: 'merged',
          conversionType: ConversionType.pdfMerge,
          timestamp: DateTime.utc(2025, 1, 3),
          outputPath: '/private/merged.pdf',
        ),
      );

      final records = await activities.getActivities();
      expect(records.map((item) => item.id), ['merged', 'failed', 'older']);
      expect(records.first.conversionType, ConversionType.pdfMerge);
      expect(records[1].errorMessage, contains('[path]'));
      expect(records.last.outputName, 'secret.txt');
      expect(records.last.outputPath, isNull);
      final raw = await (await localDatabase.getDatabase()).query('activities');
      expect(raw.map((row) => row['output_name']), contains('secret.txt'));
      expect(
        raw.map((row) => row['error_summary']).join(),
        isNot(contains('C:\\private')),
      );

      await activities.clearHistory();
      expect(await activities.getActivities(), isEmpty);
    },
  );

  test('database errors do not report false initialization success', () async {
    final broken = LocalDatabase(
      documentsDirectoryProvider: () async =>
          throw const FileSystemException('denied'),
      databaseFactory: databaseFactoryFfi,
    );
    await expectLater(
      broken.initialize(),
      throwsA(isA<LocalDatabaseException>()),
    );
  });

  test(
    'combined filters and pagination use the requested stable sorting',
    () async {
      final rows = [
        record(
          id: 'c',
          fileName: 'Charlie.png',
          createdAt: DateTime.utc(2025, 1, 2),
          conversionType: ConversionType.pdfToImages,
        ).copyWith(sizeInBytes: 300),
        record(
          id: 'a',
          fileName: 'Alpha.pdf',
          createdAt: DateTime.utc(2025, 1, 1),
        ).copyWith(sizeInBytes: 100),
        record(
          id: 'b',
          fileName: 'Bravo.pdf',
          createdAt: DateTime.utc(2025, 1, 1),
        ).copyWith(sizeInBytes: 100),
        record(
          id: 'd',
          fileName: 'Delta.pdf',
          createdAt: DateTime.utc(2025, 1, 3),
        ).copyWith(sizeInBytes: 200),
      ];
      for (final row in rows) {
        await library.addRecord(row);
      }

      for (final field in LibrarySortField.values) {
        final ascending = await library.getDocuments(
          sortBy: field,
          ascending: true,
        );
        final descending = await library.getDocuments(
          sortBy: field,
          ascending: false,
        );
        expect(ascending, hasLength(rows.length));
        expect(descending, hasLength(rows.length));
        expect(ascending.first.id, isNot(descending.first.id));
      }
      expect(
        (await library.getDocuments(
          sortBy: LibrarySortField.fileSize,
          ascending: true,
        )).take(2).map((row) => row.id),
        ['a', 'b'],
      );
      expect(
        (await library.getDocuments(
          sortBy: LibrarySortField.fileName,
          ascending: true,
          limit: 2,
          offset: 1,
        )).map((row) => row.id),
        ['b', 'c'],
      );
      expect(
        (await library.getDocuments(
          searchQuery: 'a',
          extension: 'pdf',
          conversionType: ConversionType.txtToPdf,
        )).map((row) => row.id),
        ['d', 'a', 'b'],
      );
      await expectLater(
        library.getDocuments(limit: SqliteLibraryManager.maxPageSize + 1),
        throwsArgumentError,
      );
      await expectLater(library.getDocuments(offset: -1), throwsArgumentError);
    },
  );

  test(
    'document details report managed file availability without reading bytes',
    () async {
      final directories = await fileStorage.initialize();
      final physical = File(
        '${directories.documents.path}${Platform.pathSeparator}details.pdf',
      )..writeAsStringSync('document');
      await library.addRecord(record().copyWith(localPath: physical.path));

      final details = await library.getDocumentDetails('doc-1');
      expect(details?.record.fileName, 'report.pdf');
      expect(details?.fileExists, isTrue);
      await physical.delete();
      expect((await library.getDocumentDetails('doc-1'))?.fileExists, isFalse);
      expect(await library.getDocumentDetails('missing'), isNull);
    },
  );

  test('rename preserves extension and metadata and rejects invalid names/collisions', () async {
    final directories = await fileStorage.initialize();
    final physical = File(
      '${directories.documents.path}${Platform.pathSeparator}report.pdf',
    )..writeAsStringSync('pdf-bytes');
    await library.addRecord(record().copyWith(localPath: physical.path));

    final renamed = await library.renameDocument('doc-1', 'renamed');
    expect(renamed.fileName, 'renamed.pdf');
    expect(renamed.localPath, endsWith('renamed.pdf'));
    expect(renamed.id, 'doc-1');
    expect(renamed.conversionType, ConversionType.txtToPdf);
    expect(await File(renamed.localPath).readAsString(), 'pdf-bytes');
    expect(await physical.exists(), isFalse);

    final collision = File(
      '${directories.documents.path}${Platform.pathSeparator}taken.pdf',
    )..writeAsStringSync('keep');
    await expectLater(
      library.renameDocument('doc-1', 'taken.pdf'),
      throwsA(isA<FileStorageException>()),
    );
    await expectLater(
      library.renameDocument('doc-1', '../escape'),
      throwsA(isA<LibraryOperationException>()),
    );
    await expectLater(
      library.renameDocument('doc-1', 'wrong.txt'),
      throwsA(isA<LibraryOperationException>()),
    );
    expect(await collision.readAsString(), 'keep');
    expect((await library.getRecordById('doc-1'))?.fileName, 'renamed.pdf');
  });

  test(
    'rename rolls the physical file back when metadata update fails',
    () async {
      final directories = await fileStorage.initialize();
      final physical = File(
        '${directories.documents.path}${Platform.pathSeparator}report.pdf',
      )..writeAsStringSync('rollback');
      await library.addRecord(record().copyWith(localPath: physical.path));
      final db = await localDatabase.getDatabase();
      await db.execute('''
      CREATE TRIGGER reject_document_update BEFORE UPDATE ON documents
      BEGIN SELECT RAISE(ABORT, 'test failure'); END
    ''');

      await expectLater(
        library.renameDocument('doc-1', 'renamed'),
        throwsA(isA<LibraryOperationException>()),
      );
      expect(await physical.readAsString(), 'rollback');
      expect((await library.getRecordById('doc-1'))?.fileName, 'report.pdf');
      expect(
        await File(
          '${directories.documents.path}${Platform.pathSeparator}renamed.pdf',
        ).exists(),
        isFalse,
      );
    },
  );

  test('delete coordinates managed file and metadata and preserves rows on failure', () async {
    final directories = await fileStorage.initialize();
    final physical = File(
      '${directories.documents.path}${Platform.pathSeparator}report.pdf',
    )..writeAsStringSync('delete-me');
    await library.addRecord(record().copyWith(localPath: physical.path));
    expect(await library.deleteDocument('doc-1'), isTrue);
    expect(await physical.exists(), isFalse);
    expect(await library.getRecordById('doc-1'), isNull);

    final missingRecord = record(id: 'missing-file').copyWith(
      localPath:
          '${directories.documents.path}${Platform.pathSeparator}gone.pdf',
    );
    await library.addRecord(missingRecord);
    await expectLater(
      library.deleteDocument('missing-file'),
      throwsA(isA<FileStorageException>()),
    );
    expect(await library.getRecordById('missing-file'), isNotNull);

    final external = File('${root.path}${Platform.pathSeparator}external.pdf')
      ..writeAsStringSync('keep');
    await library.addRecord(
      record(id: 'external').copyWith(localPath: external.path),
    );
    await expectLater(
      library.deleteDocument('external'),
      throwsA(isA<FileStorageException>()),
    );
    expect(await external.readAsString(), 'keep');
    expect(await library.getRecordById('external'), isNotNull);

    final second = File(
      '${directories.documents.path}${Platform.pathSeparator}second.pdf',
    )..writeAsStringSync('keep-row');
    await library.addRecord(
      record(id: 'db-failure').copyWith(localPath: second.path),
    );
    final db = await localDatabase.getDatabase();
    await db.execute('''
      CREATE TRIGGER reject_document_delete BEFORE DELETE ON documents
      WHEN OLD.id = 'db-failure'
      BEGIN SELECT RAISE(ABORT, 'test failure'); END
    ''');
    await expectLater(
      library.deleteDocument('db-failure'),
      throwsA(isA<LibraryOperationException>()),
    );
    expect(await second.exists(), isFalse);
    expect(await library.getRecordById('db-failure'), isNotNull);
  });
}
