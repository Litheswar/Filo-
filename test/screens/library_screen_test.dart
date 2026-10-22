import 'dart:async';
import 'dart:io';

import 'package:filo/app/filo_services.dart';
import 'package:filo/application/sqlite_library_manager.dart';
import 'package:filo/models/conversion_type.dart';
import 'package:filo/models/file_record.dart';
import 'package:filo/screens/library_screen.dart';
import 'package:filo/services/platform/file_export_service.dart';
import 'package:filo/services/platform/file_share_service.dart';
import 'package:filo/services/preview/thumbnail_service.dart';
import 'package:filo/services/storage/file_storage.dart';
import 'package:filo/services/storage/local_database.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  setUpAll(sqfliteFfiInit);

  late Directory root;
  late FileStorage storage;
  late LocalDatabase database;
  late FiloServices services;
  late SqliteLibraryManager persistedLibrary;
  late _ImmediateLibraryManager screenLibrary;
  late ThumbnailService screenThumbnails;
  late _FakeExportService exporter;
  late _FakeShareService sharer;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('filo_library_ui_');
    storage = FileStorage(
      documentsDirectoryProvider: () async => root,
      temporaryDirectoryProvider: () async => root,
    );
    database = LocalDatabase(
      documentsDirectoryProvider: () async => root,
      databaseFactory: databaseFactoryFfi,
    );
    await storage.initialize();
    await database.initialize();
    exporter = _FakeExportService(storage);
    sharer = _FakeShareService(storage);
    final base = FiloServices.compose(
      fileStorage: storage,
      localDatabase: database,
      fileExportService: exporter,
      fileShareService: sharer,
    );
    persistedLibrary = base.libraryManager;
    screenThumbnails = _ImmediateThumbnailService(storage);
    screenLibrary = _ImmediateLibraryManager(
      database,
      fileStorage: storage,
      thumbnailService: screenThumbnails,
    );
    services = FiloServices(
      fileStorage: base.fileStorage,
      localDatabase: base.localDatabase,
      libraryManager: screenLibrary,
      activityManager: base.activityManager,
      thumbnailService: screenThumbnails,
      conversionManager: base.conversionManager,
      conversionWorkflow: base.conversionWorkflow,
      documentConversionService: base.documentConversionService,
      fileExportService: exporter,
      fileShareService: sharer,
      libraryChanges: base.libraryChanges,
      activityChanges: base.activityChanges,
      managedStorageChanges: base.managedStorageChanges,
    );
  });

  tearDown(() async {
    await database.close();
    if (await root.exists()) await root.delete(recursive: true);
  });

  Future<FileRecord> addDocument(
    WidgetTester tester,
    String name, {
    String contents = 'Filo test document',
    DateTime? createdAt,
    ConversionType? conversionType,
    String? thumbnailPath,
  }) async {
    final record = await tester.runAsync(() async {
      final directories = await storage.initialize();
      final file = File(
        '${directories.documents.path}${Platform.pathSeparator}$name',
      );
      await file.writeAsString(contents);
      final record = FileRecord(
        id: 'id-$name',
        fileName: name,
        extension: name.split('.').last,
        sizeInBytes: await file.length(),
        createdAt: createdAt ?? DateTime.utc(2026, 1, 1),
        localPath: file.path,
        thumbnailPath: thumbnailPath,
        conversionType: conversionType,
      );
      await persistedLibrary.addRecord(record);
      return record;
    });
    screenLibrary.records.add(record!);
    services.notifyManagedFilesChanged();
    return record;
  }

  Future<void> mount(WidgetTester tester) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(useMaterial3: true),
        home: Scaffold(
          body: LibraryScreen(services: services, onConvert: () {}),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('shows persisted documents and a real empty state', (
    tester,
  ) async {
    await mount(tester);
    expect(screenLibrary.documentQueryCount, 1);
    expect(find.text('Your library is empty'), findsOneWidget);
    expect(find.textContaining('No matching'), findsNothing);
    expect(find.text('sample.pdf'), findsNothing);

    await addDocument(tester, 'saved.txt');
    await tester.pumpAndSettle();
    expect(screenLibrary.documentQueryCount, 2);
    expect(find.text('saved.txt'), findsOneWidget);
    expect(find.text('1 document'), findsOneWidget);
  });

  testWidgets('coalesces overlapping invalidations into one follow-up load', (
    tester,
  ) async {
    final gate = Completer<void>();
    screenLibrary.loadGate = gate.future;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: LibraryScreen(services: services, onConvert: () {}),
        ),
      ),
    );
    expect(screenLibrary.documentQueryCount, 1);

    services.notifyLibraryChanged();
    services.notifyLibraryChanged();
    await tester.pump();
    gate.complete();
    await tester.pumpAndSettle();

    expect(screenLibrary.documentQueryCount, 2);
    expect(tester.takeException(), isNull);
  });

  testWidgets('search, filters, sorting and layout use SQLite query options', (
    tester,
  ) async {
    final image = await addDocument(
      tester,
      'alpha.png',
      createdAt: DateTime.utc(2026, 2),
      conversionType: ConversionType.jpgToPng,
    );
    await addDocument(tester, 'beta.txt', createdAt: DateTime.utc(2026, 1));
    await mount(tester);

    expect(find.text('alpha.png'), findsOneWidget);
    expect(find.text('beta.txt'), findsOneWidget);
    await tester.enterText(find.byType(TextField).first, 'alpha');
    await tester.pump(const Duration(milliseconds: 350));
    await tester.pumpAndSettle();
    expect(find.text('alpha.png'), findsOneWidget);
    expect(find.text('beta.txt'), findsNothing);

    await tester.tap(find.byTooltip('Clear search'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Sort documents'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Name'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Switch to list view'));
    await tester.pumpAndSettle();
    expect(
      tester.getTopLeft(find.text('beta.txt')).dy,
      lessThan(tester.getTopLeft(find.text('alpha.png')).dy),
    );
    await tester.tap(find.byTooltip('File type'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('.PNG'));
    await tester.pumpAndSettle();
    expect(find.text('alpha.png'), findsOneWidget);
    expect(find.text('beta.txt'), findsNothing);

    await tester.tap(find.byTooltip('File type'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('All types'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Conversion type'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('JPG to PNG'));
    await tester.pumpAndSettle();
    expect(find.text('alpha.png'), findsOneWidget);
    expect(find.text('beta.txt'), findsNothing);

    expect(find.byType(ListTile), findsOneWidget);
    await tester.tap(find.byTooltip('Switch to grid view'));
    await tester.pumpAndSettle();
    expect(image.conversionType, ConversionType.jpgToPng);
  });

  testWidgets('opens bounded TXT preview and provides missing-thumbnail icon', (
    tester,
  ) async {
    await addDocument(tester, 'note.txt', contents: 'Preview text from file');
    await addDocument(tester, 'broken.png', contents: 'not image data');
    await mount(tester);

    expect(find.byIcon(Icons.article_outlined), findsOneWidget);
    expect(find.byIcon(Icons.image_outlined), findsOneWidget);
    await tester.ensureVisible(find.text('note.txt'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('note.txt'));
    await tester.pumpAndSettle();
    expect(find.text('Loading text preview…'), findsOneWidget);
    await tester.pageBack();
    await tester.pumpAndSettle();
    expect(find.text('note.txt'), findsOneWidget);
  });

  testWidgets('preview exposes details and the shared document actions', (
    tester,
  ) async {
    await addDocument(
      tester,
      'details.txt',
      conversionType: ConversionType.pdfToTxt,
    );
    await mount(tester);
    await tester.ensureVisible(find.text('details.txt'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('details.txt'));
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('Document actions'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Details'));
    await tester.pumpAndSettle();
    expect(find.text('Document details'), findsOneWidget);
    expect(find.text('details.txt'), findsNWidgets(2));
    expect(find.text('TXT'), findsOneWidget);
    expect(find.text('PDF to TXT'), findsOneWidget);
    expect(find.text('Available'), findsOneWidget);
    await tester.tap(find.byTooltip('Close document details'));
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('Document actions'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Rename'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 350));
    await tester.enterText(find.byType(TextField).last, 'renamed-preview');
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();
    expect(find.text('renamed-preview.txt'), findsOneWidget);

    await tester.tap(find.byTooltip('Document actions'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Delete'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 350));
    await tester.tap(find.text('Delete').last);
    await tester.pumpAndSettle();
    expect(find.text('Your library is empty'), findsOneWidget);
    expect(find.byTooltip('Document details'), findsNothing);
  });

  testWidgets('rename and delete refresh persisted records', (tester) async {
    await addDocument(tester, 'before.txt');
    await mount(tester);

    await _openActions(tester, 'before.txt');
    await tester.tap(find.text('Rename'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 350));
    await tester.enterText(find.byType(TextField).last, 'after');
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();
    expect(find.text('after.txt'), findsOneWidget);
    expect(
      await services.libraryManager.getRecordById('id-before.txt'),
      isNotNull,
    );

    await _openActions(tester, 'after.txt');
    await tester.tap(find.text('Delete'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 350));
    expect(find.text('Delete document?'), findsOneWidget);
    await tester.tap(find.text('Delete').last);
    await tester.pumpAndSettle();
    expect(find.text('Your library is empty'), findsOneWidget);
    expect(
      await services.libraryManager.getRecordById('id-before.txt'),
      isNull,
    );
  });

  testWidgets('rename validation keeps the dialog input available', (
    tester,
  ) async {
    await addDocument(tester, 'validation.txt');
    screenLibrary.failRename = true;
    await mount(tester);
    await _openActions(tester, 'validation.txt');
    await tester.tap(find.text('Rename'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 350));
    await tester.enterText(find.byType(TextField).last, 'bad/name');
    await tester.tap(find.text('Save'));
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.text('The new filename is invalid.'), findsOneWidget);
    expect(find.text('bad/name'), findsOneWidget);
  });

  testWidgets('database failure shows an error and no fake records', (
    tester,
  ) async {
    screenLibrary.failLoad = true;
    await mount(tester);
    expect(find.text('Library unavailable'), findsOneWidget);
    expect(find.text('sample.pdf'), findsNothing);
  });

  testWidgets('export and share pass persisted records and report outcomes', (
    tester,
  ) async {
    final record = await addDocument(tester, 'share-me.txt');
    await mount(tester);

    await _openActions(tester, 'share-me.txt');
    await tester.tap(find.text('Export'));
    await tester.pumpAndSettle();
    expect(exporter.lastRecord?.id, record.id);
    expect(find.text('Export cancelled'), findsNothing);

    await _openActions(tester, 'share-me.txt');
    await tester.tap(find.text('Share'));
    await tester.pumpAndSettle();
    expect(sharer.lastRecord?.id, record.id);
    expect(find.textContaining('Delivery is not confirmed'), findsOneWidget);
  });

  testWidgets('renders on a compact phone width without overflow', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(320, 640);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await addDocument(tester, 'small.txt');
    await mount(tester);
    expect(tester.takeException(), isNull);
  });
}

Future<void> _openActions(WidgetTester tester, String fileName) async {
  final label = find.text(fileName);
  await tester.ensureVisible(label);
  await tester.pumpAndSettle();
  final card = find.ancestor(of: label, matching: find.byType(Card)).first;
  await tester.tap(
    find.descendant(of: card, matching: find.byTooltip('Document actions')),
  );
  await tester.pumpAndSettle();
}

class _FakeExportService extends FileExportService {
  _FakeExportService(FileStorage storage) : super(fileStorage: storage);
  FileRecord? lastRecord;
  @override
  Future<FileExportResult> exportDocument(FileRecord record) async {
    lastRecord = record;
    return const FileExportResult.cancelled();
  }
}

class _FakeShareService extends FileShareService {
  _FakeShareService(FileStorage storage) : super(fileStorage: storage);
  FileRecord? lastRecord;
  bool fail = false;
  @override
  Future<FileShareResult> shareDocument(FileRecord record) async {
    lastRecord = record;
    if (fail) return const FileShareResult.failure('Share failed.');
    return const FileShareResult.actionSelected();
  }
}

class _ImmediateThumbnailService extends ThumbnailService {
  _ImmediateThumbnailService(FileStorage storage) : super(fileStorage: storage);

  @override
  Future<ThumbnailResult> generate(
    FileRecord record, {
    Future<bool> Function(FileRecord updatedRecord)? updateRecord,
  }) async => ThumbnailResult.failure('No test thumbnail.');
}

class _ImmediateLibraryManager extends SqliteLibraryManager {
  _ImmediateLibraryManager(
    super.localDatabase, {
    super.fileStorage,
    super.thumbnailService,
  });

  final List<FileRecord> records = [];
  bool failRename = false;
  bool failLoad = false;
  int documentQueryCount = 0;
  Future<void>? loadGate;

  @override
  Future<List<FileRecord>> getDocuments({
    String? searchQuery,
    String? extension,
    ConversionType? conversionType,
    LibrarySortField sortBy = LibrarySortField.createdAt,
    bool ascending = false,
    int? limit,
    int offset = 0,
  }) async {
    documentQueryCount++;
    await loadGate;
    if (failLoad) throw StateError('test database failure');
    var result = records.where((record) {
      final query = searchQuery?.trim().toLowerCase() ?? '';
      return (query.isEmpty || record.fileName.toLowerCase().contains(query)) &&
          (extension == null || record.extension == extension) &&
          (conversionType == null || record.conversionType == conversionType);
    }).toList();
    int compare(FileRecord a, FileRecord b) {
      final order = switch (sortBy) {
        LibrarySortField.fileName => a.fileName.toLowerCase().compareTo(
          b.fileName.toLowerCase(),
        ),
        LibrarySortField.createdAt => a.createdAt.compareTo(b.createdAt),
        LibrarySortField.fileSize => a.sizeInBytes.compareTo(b.sizeInBytes),
        LibrarySortField.extension => a.extension.compareTo(b.extension),
      };
      final stable = order == 0 ? a.id.compareTo(b.id) : order;
      return ascending ? stable : -stable;
    }

    result.sort(compare);
    if (offset >= result.length) return const [];
    result = result.skip(offset).take(limit ?? result.length).toList();
    return result;
  }

  @override
  Future<LibrarySummary> getSummary() async => LibrarySummary(
    totalCount: records.length,
    extensions: records.map((record) => record.extension.toLowerCase()).toSet(),
  );

  @override
  Future<List<FileRecord>> getAllRecords() async => List.of(records);

  @override
  Future<FileRecord?> getRecordById(String id) async {
    for (final record in records) {
      if (record.id == id) return record;
    }
    return null;
  }

  @override
  Future<void> addRecord(FileRecord record) async {
    records.add(record);
    await super.addRecord(record);
  }

  @override
  Future<LibraryDocumentDetails?> getDocumentDetails(String id) async {
    final record = await getRecordById(id);
    if (record == null) return null;
    return LibraryDocumentDetails(record: record, fileExists: true);
  }

  @override
  Future<FileRecord> renameDocument(String id, String requestedName) async {
    if (failRename) {
      throw const LibraryOperationException('The new filename is invalid.');
    }
    final index = records.indexWhere((record) => record.id == id);
    if (index < 0) throw const LibraryOperationException('Document not found.');
    final old = records[index];
    final basename = requestedName.endsWith('.${old.extension}')
        ? requestedName
        : '$requestedName.${old.extension}';
    final renamed = old.copyWith(fileName: basename);
    records[index] = renamed;
    return renamed;
  }

  @override
  Future<bool> deleteDocument(String id) async {
    final count = records.length;
    records.removeWhere((record) => record.id == id);
    return records.length < count;
  }
}
