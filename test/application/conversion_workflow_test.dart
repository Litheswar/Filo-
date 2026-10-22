import 'dart:io';

import 'package:filo/application/conversion_manager.dart';
import 'package:filo/application/conversion_workflow.dart';
import 'package:filo/application/sqlite_activity_manager.dart';
import 'package:filo/application/sqlite_library_manager.dart';
import 'package:filo/models/conversion_job.dart';
import 'package:filo/models/conversion_result.dart';
import 'package:filo/models/conversion_type.dart';
import 'package:filo/services/conversion/converter_interface.dart';
import 'package:filo/services/preview/thumbnail_service.dart';
import 'package:filo/services/storage/file_storage.dart';
import 'package:filo/services/storage/local_database.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

class _Converter implements ConverterInterface {
  _Converter(this.produce);
  final Future<ConversionResult> Function(ConversionJob) produce;
  @override
  String get name => 'workflow-test';
  @override
  Set<ConversionType> get supportedTypes => {ConversionType.pdfToImages};
  @override
  bool canConvert(ConversionType type) => supportedTypes.contains(type);
  @override
  Future<ConversionResult> convert(ConversionJob job) => produce(job);
}

void main() {
  setUpAll(sqfliteFfiInit);

  group('ConversionWorkflow', () {
    late Directory root;
    late FileStorage storage;
    late LocalDatabase database;
    late SqliteLibraryManager library;
    late SqliteActivityManager activities;
    var id = 0;

    setUp(() async {
      root = await Directory.systemTemp.createTemp('filo_workflow_');
      storage = FileStorage(
        documentsDirectoryProvider: () async => root,
        temporaryDirectoryProvider: () async => root,
      );
      database = LocalDatabase(
        documentsDirectoryProvider: () async => root,
        databaseFactory: databaseFactoryFfi,
      );
      library = SqliteLibraryManager(database, fileStorage: storage);
      activities = SqliteActivityManager(database);
      id = 0;
    });

    tearDown(() async {
      await database.close();
      if (await root.exists()) await root.delete(recursive: true);
    });

    ConversionJob job(String input) => ConversionJob(
      id: 'job-1',
      inputPaths: [input],
      conversionType: ConversionType.pdfToImages,
    );

    ConversionWorkflow workflow(
      ConversionResult Function(ConversionJob) result,
    ) => ConversionWorkflow(
      conversionManager: DefaultConversionManager([
        _Converter((request) async => result(request)),
      ]),
      fileStorage: storage,
      libraryManager: library,
      activityManager: activities,
      thumbnailService: ThumbnailService(fileStorage: storage),
      idGenerator: () => 'id-${id++}',
      clock: () => DateTime.utc(2026, 1, 2),
    );

    test(
      'imports ordered multi-output results with metadata and one activity',
      () async {
        final input = File('${root.path}/input.pdf')..writeAsStringSync('pdf');
        final first = File('${root.path}/page-1.png')
          ..writeAsBytesSync([1, 2, 3]);
        final second = File('${root.path}/page-2.png')
          ..writeAsBytesSync([4, 5]);
        final runner = workflow(
          (request) => ConversionResult.multipleSuccess(
            jobId: request.id,
            outputPaths: [first.path, second.path, first.path],
          ),
        );

        final outcome = await runner.run(job(input.path));
        expect(outcome.isSuccess, isTrue);
        expect(outcome.documents.map((record) => record.fileName), [
          'page-1.png',
          'page-2.png',
        ]);
        expect(
          outcome.documents.map((record) => record.localPath),
          everyElement(contains('Filo${Platform.pathSeparator}documents')),
        );
        expect(outcome.documents.map((record) => record.sizeInBytes), [3, 2]);
        expect(
          outcome.documents.map((record) => record.conversionType),
          everyElement(ConversionType.pdfToImages),
        );
        expect(await input.readAsString(), 'pdf');
        final records = await library.getAllRecords();
        expect(records.map((record) => record.fileName), [
          'page-1.png',
          'page-2.png',
        ]);
        final history = await activities.getActivities();
        expect(history, hasLength(1));
        expect(history.single.isSuccess, isTrue);
        expect(history.single.outputNames, ['page-1.png', 'page-2.png']);
      },
    );

    test(
      'resolves collisions and preserves existing managed documents',
      () async {
        final input = File('${root.path}/input.pdf')..writeAsStringSync('pdf');
        final old = File('${root.path}/page.png')..writeAsStringSync('old');
        await storage.copyToLibrary(old);
        final output = File('${root.path}/page.png')..writeAsStringSync('new');
        final outcome = await workflow(
          (request) => ConversionResult.success(
            jobId: request.id,
            outputPath: output.path,
          ),
        ).run(job(input.path));
        expect(outcome.isSuccess, isTrue);
        expect(outcome.documents.single.fileName, 'page_1.png');
        expect(
          await File('${root.path}/Filo/documents/page.png').readAsString(),
          'old',
        );
      },
    );

    test(
      'missing output fails and records one safe failure activity',
      () async {
        final input = File('${root.path}/input.pdf')..writeAsStringSync('pdf');
        final absent = '${root.path}/private/missing.png';
        final outcome = await workflow(
          (request) =>
              ConversionResult.success(jobId: request.id, outputPath: absent),
        ).run(job(input.path));
        expect(outcome.isSuccess, isFalse);
        expect(outcome.errorMessage, contains('missing'));
        expect(outcome.compensationFailures, isEmpty);
        final history = await activities.getActivities();
        expect(history, hasLength(1));
        expect(history.single.isSuccess, isFalse);
        expect(history.single.errorMessage, isNot(contains(root.path)));
      },
    );

    test(
      'later import validation failure rolls back prior records and files',
      () async {
        final input = File('${root.path}/input.pdf')..writeAsStringSync('pdf');
        final valid = File('${root.path}/one.png')..writeAsBytesSync([1]);
        final missing = '${root.path}/missing.png';
        final outcome = await workflow(
          (request) => ConversionResult.multipleSuccess(
            jobId: request.id,
            outputPaths: [valid.path, missing],
          ),
        ).run(job(input.path));
        expect(outcome.isSuccess, isFalse);
        expect(await library.getAllRecords(), isEmpty);
        expect(
          await File('${root.path}/Filo/documents/one.png').exists(),
          isFalse,
        );
        expect(outcome.retainedFiles, isEmpty);
      },
    );

    test('empty output is rejected and source remains untouched', () async {
      final input = File('${root.path}/input.pdf')..writeAsStringSync('pdf');
      final empty = File('${root.path}/empty.png')..writeAsBytesSync([]);
      final outcome = await workflow(
        (request) =>
            ConversionResult.success(jobId: request.id, outputPath: empty.path),
      ).run(job(input.path));
      expect(outcome.isSuccess, isFalse);
      expect(await input.readAsString(), 'pdf');
      expect(await library.getAllRecords(), isEmpty);
    });

    test('library insertion failure removes its imported file', () async {
      final input = File('${root.path}/input.pdf')..writeAsStringSync('pdf');
      final output = File('${root.path}/result.txt')..writeAsStringSync('text');
      final db = await database.getDatabase();
      await db.execute(
        "CREATE TRIGGER reject_document BEFORE INSERT ON documents BEGIN SELECT RAISE(FAIL, 'no document'); END",
      );
      final outcome = await workflow(
        (request) => ConversionResult.success(
          jobId: request.id,
          outputPath: output.path,
        ),
      ).run(job(input.path));
      expect(outcome.isSuccess, isFalse);
      expect(
        await File('${root.path}/Filo/documents/result.txt').exists(),
        isFalse,
      );
      expect(outcome.compensationFailures, isEmpty);
    });

    test('activity store failure compensates imported output', () async {
      final input = File('${root.path}/input.pdf')..writeAsStringSync('pdf');
      final output = File('${root.path}/result.txt')..writeAsStringSync('text');
      final db = await database.getDatabase();
      await db.execute(
        "CREATE TRIGGER reject_activity BEFORE INSERT ON activities BEGIN SELECT RAISE(FAIL, 'no activity'); END",
      );
      final outcome = await workflow(
        (request) => ConversionResult.success(
          jobId: request.id,
          outputPath: output.path,
        ),
      ).run(job(input.path));
      expect(outcome.isSuccess, isFalse);
      expect(await library.getAllRecords(), isEmpty);
      expect(
        await File('${root.path}/Filo/documents/result.txt').exists(),
        isFalse,
      );
      expect(outcome.compensationFailures, isNotEmpty);
    });
  });
}
