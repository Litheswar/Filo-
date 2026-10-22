import 'package:flutter_test/flutter_test.dart';
import 'package:filo/models/conversion_type.dart';
import 'package:filo/models/conversion_job.dart';
import 'package:filo/models/conversion_result.dart';
import 'package:filo/models/file_record.dart';
import 'package:filo/services/conversion/converter_interface.dart';
import 'package:filo/application/conversion_manager.dart';
import 'package:filo/application/library_manager.dart';
import 'package:filo/application/file_manager.dart';
import 'package:filo/application/activity_manager.dart';

// Test mock converter implementing ConverterInterface
class MockImageConverter implements ConverterInterface {
  @override
  String get name => 'MockImageConverter';

  @override
  Set<ConversionType> get supportedTypes => {
    ConversionType.jpgToPng,
    ConversionType.pngToJpg,
  };

  @override
  bool canConvert(ConversionType conversionType) =>
      supportedTypes.contains(conversionType);

  @override
  Future<ConversionResult> convert(ConversionJob job) async {
    if (job.primaryInputPath.contains('fail')) {
      return ConversionResult.failure(
        jobId: job.id,
        errorMessage: 'Mock conversion failed intentionally',
      );
    }
    return ConversionResult.success(
      jobId: job.id,
      outputPath: '${job.primaryInputPath}.converted',
    );
  }
}

void main() {
  group('ConversionManager', () {
    late DefaultConversionManager manager;
    late MockImageConverter converter;

    setUp(() {
      manager = DefaultConversionManager();
      converter = MockImageConverter();
    });

    test('registers and unregisters converters correctly', () {
      expect(manager.registeredConverters, isEmpty);
      expect(manager.isTypeSupported(ConversionType.jpgToPng), isFalse);

      manager.registerConverter(converter);
      expect(manager.registeredConverters, contains(converter));
      expect(manager.isTypeSupported(ConversionType.jpgToPng), isTrue);
      expect(manager.isTypeSupported(ConversionType.txtToPdf), isFalse);

      manager.unregisterConverter(converter.name);
      expect(manager.registeredConverters, isEmpty);
      expect(manager.isTypeSupported(ConversionType.jpgToPng), isFalse);
    });

    test('returns failure result when no matching converter exists', () async {
      final job = ConversionJob(
        id: 'job_unsupported',
        inputPaths: ['/test.txt'],
        conversionType: ConversionType.txtToPdf,
      );

      final result = await manager.processJob(job);
      expect(result.isSuccess, isFalse);
      expect(
        result.errorMessage,
        contains('No registered converter supports txtToPdf'),
      );
    });

    test('dispatches job successfully to registered converter', () async {
      manager.registerConverter(converter);
      final job = ConversionJob(
        id: 'job_ok',
        inputPaths: ['/image.jpg'],
        conversionType: ConversionType.jpgToPng,
      );

      final result = await manager.processJob(job);
      expect(result.isSuccess, isTrue);
      expect(result.outputPath, '/image.jpg.converted');
    });

    test('handles converter failure gracefully', () async {
      manager.registerConverter(converter);
      final job = ConversionJob(
        id: 'job_fail',
        inputPaths: ['/fail_image.jpg'],
        conversionType: ConversionType.jpgToPng,
      );

      final result = await manager.processJob(job);
      expect(result.isSuccess, isFalse);
      expect(result.errorMessage, 'Mock conversion failed intentionally');
    });
  });

  group('LibraryManager (InMemoryLibraryManager)', () {
    late InMemoryLibraryManager libraryManager;

    setUp(() {
      libraryManager = InMemoryLibraryManager();
    });

    test('adds, retrieves, updates, and deletes records', () async {
      final record = FileRecord(
        id: 'rec_1',
        fileName: 'doc.pdf',
        extension: 'pdf',
        sizeInBytes: 1024,
        createdAt: DateTime.now(),
        localPath: '/doc.pdf',
      );

      await libraryManager.addRecord(record);
      expect(await libraryManager.getAllRecords(), hasLength(1));

      final retrieved = await libraryManager.getRecordById('rec_1');
      expect(retrieved, equals(record));

      // Duplicate add throws StateError
      expect(() => libraryManager.addRecord(record), throwsStateError);

      // Update record
      final updated = record.copyWith(fileName: 'renamed.pdf');
      final updateSuccess = await libraryManager.updateRecord(updated);
      expect(updateSuccess, isTrue);
      expect(
        (await libraryManager.getRecordById('rec_1'))?.fileName,
        'renamed.pdf',
      );

      // Remove record
      final removeSuccess = await libraryManager.removeRecord('rec_1');
      expect(removeSuccess, isTrue);
      expect(await libraryManager.getAllRecords(), isEmpty);
    });

    test('searches and filters records by extension and name', () async {
      final now = DateTime.now();
      await libraryManager.addRecord(
        FileRecord(
          id: '1',
          fileName: 'Annual Report.pdf',
          extension: 'pdf',
          sizeInBytes: 500,
          createdAt: now,
          localPath: '/annual.pdf',
        ),
      );
      await libraryManager.addRecord(
        FileRecord(
          id: '2',
          fileName: 'Profile Photo.png',
          extension: 'png',
          sizeInBytes: 300,
          createdAt: now.add(const Duration(seconds: 1)),
          localPath: '/photo.png',
        ),
      );

      final searchReport = await libraryManager.searchRecords('report');
      expect(searchReport, hasLength(1));
      expect(searchReport.first.id, '1');

      final pdfs = await libraryManager.getRecordsByExtension('pdf');
      expect(pdfs, hasLength(1));
      expect(pdfs.first.fileName, 'Annual Report.pdf');

      final pngs = await libraryManager.getRecordsByExtension('.PNG');
      expect(pngs, hasLength(1));
      expect(pngs.first.fileName, 'Profile Photo.png');
    });
  });

  group('FileManager (BaseFileManager)', () {
    final fileManager = BaseFileManager();

    test('extracts clean base names and extensions', () {
      expect(
        fileManager.extractBaseName('/storage/documents/my_file.pdf'),
        'my_file',
      );
      expect(fileManager.extractBaseName(r'C:\Users\Docs\image.jpeg'), 'image');
      expect(fileManager.extractExtension('/path/to/archive.tar.gz'), 'gz');
      expect(fileManager.extractExtension('/path/to/file_without_ext'), '');
    });

    test('builds sanitized output path', () {
      final path = fileManager.buildOutputPath(
        directory: '/storage/emulated/0/Download',
        baseName: 'Report: 2026/01*',
        extension: 'pdf',
      );
      expect(path, '/storage/emulated/0/Download/Report_ 2026_01_.pdf');
    });

    test(
      'unimplemented file I/O methods throw UnimplementedError in Phase 1',
      () {
        expect(
          () => fileManager.fileExists('/dummy'),
          throwsUnimplementedError,
        );
        expect(
          () => fileManager.getFileSize('/dummy'),
          throwsUnimplementedError,
        );
        expect(
          () => fileManager.deleteFile('/dummy'),
          throwsUnimplementedError,
        );
      },
    );
  });

  group('ActivityManager (InMemoryActivityManager)', () {
    late InMemoryActivityManager activityManager;

    setUp(() {
      activityManager = InMemoryActivityManager();
    });

    test('logs, retrieves, and clears activities', () async {
      final record1 = ActivityRecord(
        id: 'act_1',
        jobId: 'job_1',
        conversionType: ConversionType.jpgToPng,
        isSuccess: true,
        outputPath: '/out.png',
        timestamp: DateTime.utc(2026, 1, 2),
      );

      final record2 = ActivityRecord(
        id: 'act_2',
        jobId: 'job_2',
        conversionType: ConversionType.pdfToTxt,
        isSuccess: false,
        errorMessage: 'Extraction failed',
        timestamp: DateTime.utc(2026, 1, 1),
      );

      await activityManager.logActivity(record1);
      await activityManager.logActivity(record2);

      final activities = await activityManager.getActivities();
      expect(activities, hasLength(2));
      expect(activities.first.id, 'act_1');

      await activityManager.clearHistory();
      expect(await activityManager.getActivities(), isEmpty);
    });

    test('creates ActivityRecord from ConversionResult', () {
      final result = ConversionResult.success(
        jobId: 'job_99',
        outputPath: '/finished.pdf',
        duration: const Duration(seconds: 2),
      );

      final activity = ActivityRecord.fromResult(
        id: 'act_from_res',
        result: result,
        conversionType: ConversionType.txtToPdf,
      );

      expect(activity.id, 'act_from_res');
      expect(activity.jobId, 'job_99');
      expect(activity.isSuccess, isTrue);
      expect(activity.outputPath, '/finished.pdf');
      expect(activity.duration, const Duration(seconds: 2));
    });
  });
}
