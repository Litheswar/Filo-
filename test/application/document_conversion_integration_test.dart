import 'dart:io';

import 'package:filo/application/conversion_manager.dart';
import 'package:filo/app/filo_services.dart';
import 'package:filo/application/conversion_workflow.dart';
import 'package:filo/application/document_conversion_service.dart';
import 'package:filo/application/sqlite_activity_manager.dart';
import 'package:filo/application/sqlite_library_manager.dart';
import 'package:filo/models/conversion_job.dart';
import 'package:filo/models/conversion_result.dart';
import 'package:filo/models/conversion_type.dart';
import 'package:filo/models/file_record.dart';
import 'package:filo/services/conversion/converter_interface.dart';
import 'package:filo/services/conversion/pdf_creator.dart';
import 'package:filo/services/conversion/pdf_text_extractor.dart';
import 'package:filo/services/platform/file_export_service.dart';
import 'package:filo/services/platform/file_picker_service.dart';
import 'package:filo/services/platform/file_share_service.dart';
import 'package:filo/services/preview/text_preview_service.dart';
import 'package:filo/services/preview/thumbnail_service.dart';
import 'package:filo/services/storage/file_storage.dart';
import 'package:filo/services/storage/local_database.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:pdf/widgets.dart' as pw;
import 'package:share_plus/share_plus.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

class _PickerAdapter implements FilePickerAdapter {
  List<PickerFileSource>? sources;
  int pickCount = 0;

  @override
  Future<PickerFileSource?> pickSingle(List<String> allowedExtensions) async {
    pickCount++;
    final selected = sources;
    return selected == null || selected.isEmpty ? null : selected.first;
  }

  @override
  Future<List<PickerFileSource>?> pickMultiple(
    List<String> allowedExtensions,
  ) async {
    pickCount++;
    return sources;
  }
}

class _FixtureConverter implements ConverterInterface {
  _FixtureConverter({this.fail = false});

  final bool fail;

  @override
  String get name => 'integration-fixture';

  @override
  Set<ConversionType> get supportedTypes => ConversionType.values.toSet();

  @override
  bool canConvert(ConversionType conversionType) => true;

  @override
  Future<ConversionResult> convert(ConversionJob job) async {
    if (fail) {
      return ConversionResult.failure(
        jobId: job.id,
        errorMessage: 'Fixture conversion failed.',
      );
    }
    final directory = Directory(job.outputDirectory!)
      ..createSync(recursive: true);
    switch (job.conversionType) {
      case ConversionType.pdfToImages:
        final second = File(
          '${directory.path}${Platform.pathSeparator}page-2.png',
        )..writeAsBytesSync(_png(2, 1, 30));
        final first = File(
          '${directory.path}${Platform.pathSeparator}page-1.png',
        )..writeAsBytesSync(_png(1, 2, 220));
        return ConversionResult.multipleSuccess(
          jobId: job.id,
          outputPaths: [second.path, first.path],
        );
      case ConversionType.pdfToTxt:
        final output = File(
          '${directory.path}${Platform.pathSeparator}extracted.txt',
        )..writeAsStringSync('Extracted text from a managed PDF.');
        return ConversionResult.success(jobId: job.id, outputPath: output.path);
      case ConversionType.txtToPdf:
        final document = pw.Document()
          ..addPage(
            pw.Page(
              build: (_) => pw.Center(child: pw.Text('Managed PDF preview')),
            ),
          );
        final output = File(
          '${directory.path}${Platform.pathSeparator}created.pdf',
        )..writeAsBytesSync(await document.save());
        return ConversionResult.success(jobId: job.id, outputPath: output.path);
      default:
        final output = File(
          '${directory.path}${Platform.pathSeparator}output.png',
        )..writeAsBytesSync(_png(2, 2, 100));
        return ConversionResult.success(jobId: job.id, outputPath: output.path);
    }
  }

  static List<int> _png(int width, int height, int red) {
    final image = img.Image(width: width, height: height);
    img.fill(image, color: img.ColorRgb8(red, 80, 140));
    return img.encodePng(image);
  }
}

class _ExportAdapter implements FileExportAdapter {
  String? response = 'content://provider/exported';
  Object? error;
  String? sourcePath;
  String? fileName;
  String? mimeType;

  @override
  Future<String?> saveFile({
    required String sourcePath,
    required String fileName,
    required String mimeType,
  }) async {
    this.sourcePath = sourcePath;
    this.fileName = fileName;
    this.mimeType = mimeType;
    if (error != null) throw error!;
    return response;
  }
}

class _ShareAdapter implements FileShareAdapter {
  ShareResultStatus status = ShareResultStatus.success;
  Object? error;
  String? sourcePath;
  String? fileName;
  String? mimeType;

  @override
  Future<ShareResultStatus> shareFile({
    required String sourcePath,
    required String fileName,
    required String mimeType,
  }) async {
    this.sourcePath = sourcePath;
    this.fileName = fileName;
    this.mimeType = mimeType;
    if (error != null) throw error!;
    return status;
  }
}

void main() {
  setUpAll(sqfliteFfiInit);

  late Directory root;
  late FileStorage storage;
  late LocalDatabase database;
  late SqliteLibraryManager library;
  late SqliteActivityManager activities;
  late ThumbnailService thumbnails;
  late _PickerAdapter pickerAdapter;
  var identifier = 0;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('filo_e2e_');
    storage = FileStorage(
      documentsDirectoryProvider: () async => root,
      temporaryDirectoryProvider: () async => root,
    );
    database = LocalDatabase(
      documentsDirectoryProvider: () async => root,
      databaseFactory: databaseFactoryFfi,
    );
    thumbnails = ThumbnailService(fileStorage: storage);
    library = SqliteLibraryManager(
      database,
      fileStorage: storage,
      thumbnailService: thumbnails,
    );
    activities = SqliteActivityManager(database);
    pickerAdapter = _PickerAdapter();
    identifier = 0;
    await storage.initialize();
  });

  tearDown(() async {
    await database.close();
    if (await root.exists()) await root.delete(recursive: true);
  });

  DocumentConversionService service({
    bool fail = false,
    List<ConverterInterface>? converters,
  }) {
    final picker = FilePickerService(
      fileStorage: storage,
      adapter: pickerAdapter,
      idGenerator: () => 'picked-${identifier++}',
    );
    final workflow = ConversionWorkflow(
      conversionManager: DefaultConversionManager(
        converters ?? [_FixtureConverter(fail: fail)],
      ),
      fileStorage: storage,
      libraryManager: library,
      activityManager: activities,
      thumbnailService: thumbnails,
      idGenerator: () => 'record-${identifier++}',
      clock: () => DateTime.utc(2026, 2, 3),
    );
    return DocumentConversionService(
      filePickerService: picker,
      conversionWorkflow: workflow,
      jobIdGenerator: () => 'job-${identifier++}',
    );
  }

  PickerFileSource source(String name, List<int> bytes) => PickerFileSource(
    name: name,
    openRead: () => Stream.value(Uint8List.fromList(bytes)),
  );

  test('picker-to-library multi-output persists ordered records and supports preview, export, and share', () async {
    pickerAdapter.sources = [
      source('input.pdf', [37, 80, 68, 70, 45, 49]),
    ];
    final before = await storage.initialize();
    final outcome = await service().convert(ConversionType.pdfToImages);

    expect(outcome.status, DocumentConversionStatus.success);
    final records = outcome.workflowOutcome!.documents;
    expect(records.map((record) => record.fileName), [
      'page-2.png',
      'page-1.png',
    ]);
    expect(records.map((record) => record.conversionType), [
      ConversionType.pdfToImages,
      ConversionType.pdfToImages,
    ]);
    expect(records.every((record) => record.id.isNotEmpty), isTrue);
    expect(records.every((record) => record.sizeInBytes > 0), isTrue);
    expect(
      records.every(
        (record) => record.localPath.startsWith(before.documents.path),
      ),
      isTrue,
    );
    expect(records.every((record) => record.thumbnailPath != null), isTrue);
    expect(
      await Future.wait(
        records.map((record) => File(record.thumbnailPath!).exists()),
      ),
      everyElement(isTrue),
    );

    final stored = <FileRecord>[];
    for (final record in records) {
      stored.add((await library.getRecordById(record.id))!);
    }
    final historyBefore = await activities.getActivities();
    expect(historyBefore, hasLength(1));
    expect(historyBefore.single.isSuccess, isTrue);
    expect(historyBefore.single.outputNames, ['page-2.png', 'page-1.png']);

    await database.close();
    final reopened = <FileRecord>[];
    for (final record in records) {
      reopened.add((await library.getRecordById(record.id))!);
    }
    expect(
      reopened.map((record) => record.localPath),
      records.map((record) => record.localPath),
    );
    expect(
      reopened.map((record) => record.sizeInBytes),
      records.map((record) => record.sizeInBytes),
    );
    expect(
      (await activities.getActivities()).single.id,
      historyBefore.single.id,
    );

    final sourceBytes = await File(records.first.localPath).readAsBytes();
    final exportAdapter = _ExportAdapter();
    final exporter = FileExportService(
      fileStorage: storage,
      adapter: exportAdapter,
    );
    final exported = await exporter.exportDocument(records.first);
    expect(exported.isSuccess, isTrue);
    expect(
      exportAdapter.sourcePath,
      await File(records.first.localPath).resolveSymbolicLinks(),
    );
    expect(exportAdapter.fileName, records.first.fileName);
    expect(exportAdapter.mimeType, 'image/png');
    expect(await File(records.first.localPath).readAsBytes(), sourceBytes);

    exportAdapter.response = null;
    expect(
      (await exporter.exportDocument(records.first)).status,
      FileExportStatus.cancelled,
    );
    exportAdapter.error = PlatformException(code: 'provider_failed');
    expect(
      (await exporter.exportDocument(records.first)).status,
      FileExportStatus.failure,
    );

    final shareAdapter = _ShareAdapter();
    final sharer = FileShareService(
      fileStorage: storage,
      adapter: shareAdapter,
    );
    expect(
      (await sharer.shareDocument(records.first)).status,
      FileShareStatus.actionSelected,
    );
    expect(shareAdapter.fileName, records.first.fileName);
    expect(shareAdapter.mimeType, 'image/png');
    shareAdapter.status = ShareResultStatus.dismissed;
    expect(
      (await sharer.shareDocument(records.first)).status,
      FileShareStatus.dismissed,
    );
    shareAdapter.error = PlatformException(code: 'share_failed');
    expect(
      (await sharer.shareDocument(records.first)).status,
      FileShareStatus.failure,
    );
    expect(await File(records.first.localPath).readAsBytes(), sourceBytes);
    expect(await activities.getActivities(), hasLength(1));

    final temporaryEntries = await before.temporary.list().toList();
    expect(temporaryEntries, isEmpty);
  });

  test(
    'composed services notify mounted screens after successful persistence',
    () async {
      pickerAdapter.sources = [
        source('input.pdf', [37, 80, 68, 70, 45, 49]),
      ];
      var storageNotifications = 0;
      final composed = FiloServices.compose(
        fileStorage: storage,
        localDatabase: database,
        filePickerService: FilePickerService(
          fileStorage: storage,
          adapter: pickerAdapter,
          onManagedStorageChanged: () => storageNotifications++,
        ),
        conversionManager: DefaultConversionManager([_FixtureConverter()]),
        activityManager: activities,
      );

      final outcome = await composed.documentConversionService.convert(
        ConversionType.pdfToImages,
      );

      expect(outcome.isSuccess, isTrue);
      expect(composed.libraryChanges.value, 1);
      expect(composed.activityChanges.value, 1);
      expect(storageNotifications, 2);
      expect(await composed.libraryManager.getDocuments(), hasLength(2));
    },
  );

  test(
    'staged selection can be shown before conversion without picking twice',
    () async {
      pickerAdapter.sources = [
        source('input.pdf', [37, 80, 68, 70, 45, 49]),
      ];
      final conversion = service();
      final selected = await conversion.selectInputs(
        ConversionType.pdfToImages,
      );

      expect(selected.isSelected, isTrue);
      expect(selected.selection!.files.single.name, 'input.pdf');
      expect(pickerAdapter.pickCount, 1);

      final outcome = await conversion.convertSelection(selected.selection!);
      expect(outcome.status, DocumentConversionStatus.success);
      expect(
        outcome.workflowOutcome!.documents.map((record) => record.fileName),
        ['page-2.png', 'page-1.png'],
      );
      expect(pickerAdapter.pickCount, 1);
      expect(
        await File(selected.selection!.inputPaths.single).exists(),
        isFalse,
      );
    },
  );

  test('managed PDF and TXT outputs support real local previews', () async {
    pickerAdapter.sources = [source('note.txt', 'A local note'.codeUnits)];
    final engines = service(converters: [PdfCreator(), PdfTextExtractor()]);
    final pdfOutcome = await engines.convert(
      ConversionType.txtToPdf,
      requestedOutputName: 'created.pdf',
    );
    expect(pdfOutcome.isSuccess, isTrue);
    final pdfRecord = pdfOutcome.workflowOutcome!.documents.single;
    expect(pdfRecord.extension, 'pdf');
    expect(pdfRecord.thumbnailPath, isNotNull);
    expect(await File(pdfRecord.thumbnailPath!).exists(), isTrue);

    pickerAdapter.sources = [
      source('created.pdf', await File(pdfRecord.localPath).readAsBytes()),
    ];
    final textOutcome = await engines.convert(
      ConversionType.pdfToTxt,
      requestedOutputName: 'extracted.txt',
    );
    expect(textOutcome.isSuccess, isTrue);
    final textRecord = textOutcome.workflowOutcome!.documents.single;
    final preview = await TextPreviewService().preview(
      File(textRecord.localPath),
    );
    expect(preview.isSuccess, isTrue);
    expect(preview.text, contains('A local note'));
    expect(await activities.getActivities(), hasLength(2));
  });

  test('cancellation, conversion failure, and persistence failure clean staged inputs', () async {
    final noSelection = await service().convert(ConversionType.pdfToImages);
    expect(noSelection.status, DocumentConversionStatus.cancelled);
    expect(await activities.getActivities(), isEmpty);

    pickerAdapter.sources = [
      source('input.pdf', [37, 80, 68, 70, 45, 49]),
    ];
    final failed = await service(fail: true)
        .convert(ConversionType.pdfToImages);
    expect(failed.status, DocumentConversionStatus.conversionFailed);
    expect(
      await FileStorage(
        documentsDirectoryProvider: () async => root,
        temporaryDirectoryProvider: () async => root,
      ).initialize().then((dirs) => dirs.temporary.list().toList()),
      isEmpty,
    );
    expect((await activities.getActivities()).single.isSuccess, isFalse);

    final db = await database.getDatabase();
    await db.execute(
      "CREATE TRIGGER reject_document BEFORE INSERT ON documents BEGIN SELECT RAISE(FAIL, 'injected failure'); END",
    );
    pickerAdapter.sources = [
      source('input.pdf', [37, 80, 68, 70, 45, 49]),
    ];
    final persistence = await service().convert(ConversionType.pdfToImages);
    expect(persistence.status, DocumentConversionStatus.persistenceFailed);
    expect(persistence.isSuccess, isFalse);
    expect(await library.getAllRecords(), isEmpty);
    final directories = await storage.initialize();
    expect(await directories.documents.list().toList(), isEmpty);
    expect(await directories.temporary.list().toList(), isEmpty);
    expect(
      (await activities.getActivities()).where((item) => item.isSuccess),
      isEmpty,
    );
  });

  test(
    'rename and delete invalidate and remove managed thumbnail files',
    () async {
      pickerAdapter.sources = [
        source('input.pdf', [37, 80, 68, 70, 45, 49]),
      ];
      final outcome = await service().convert(ConversionType.pdfToImages);
      final original = outcome.workflowOutcome!.documents.first;
      final oldThumbnail = File(original.thumbnailPath!);
      expect(await oldThumbnail.exists(), isTrue);

      final renamed = await library.renameDocument(original.id, 'renamed');
      expect(renamed.fileName, 'renamed.png');
      expect(renamed.thumbnailPath, isNull);
      expect(await oldThumbnail.exists(), isFalse);

      final preview = await thumbnails.generate(
        renamed,
        updateRecord: library.updateRecord,
      );
      expect(preview.isSuccess, isTrue);
      final newThumbnail = File(preview.path!);
      expect(await newThumbnail.exists(), isTrue);
      expect(await library.deleteDocument(original.id), isTrue);
      expect(await newThumbnail.exists(), isFalse);
      expect(await library.getRecordById(original.id), isNull);
    },
  );
}
