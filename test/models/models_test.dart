import 'package:flutter_test/flutter_test.dart';
import 'package:filo/models/conversion_type.dart';
import 'package:filo/models/file_record.dart';
import 'package:filo/models/conversion_job.dart';
import 'package:filo/models/conversion_result.dart';

void main() {
  group('ConversionType', () {
    test('contains all 7 required conversion types', () {
      expect(ConversionType.values, hasLength(7));
      expect(
        ConversionType.values,
        containsAll([
          ConversionType.jpgToPng,
          ConversionType.pngToJpg,
          ConversionType.singleImageToPdf,
          ConversionType.multipleImagesToPdf,
          ConversionType.pdfToImages,
          ConversionType.txtToPdf,
          ConversionType.pdfToTxt,
        ]),
      );
    });

    test('displayName and defaultOutputExtension return valid values', () {
      expect(ConversionType.jpgToPng.displayName, 'JPG to PNG');
      expect(ConversionType.jpgToPng.defaultOutputExtension, 'png');

      expect(ConversionType.pngToJpg.displayName, 'PNG to JPG');
      expect(ConversionType.pngToJpg.defaultOutputExtension, 'jpg');

      expect(ConversionType.singleImageToPdf.defaultOutputExtension, 'pdf');
      expect(ConversionType.multipleImagesToPdf.defaultOutputExtension, 'pdf');
      expect(ConversionType.txtToPdf.defaultOutputExtension, 'pdf');
      expect(ConversionType.pdfToTxt.defaultOutputExtension, 'txt');
      expect(ConversionType.pdfToImages.defaultOutputExtension, 'png');

      expect(ConversionType.multipleImagesToPdf.requiresMultipleInputs, isTrue);
      expect(ConversionType.singleImageToPdf.requiresMultipleInputs, isFalse);
    });
  });

  group('FileRecord', () {
    test('creates valid FileRecord with required fields', () {
      final now = DateTime.now();
      final record = FileRecord(
        id: 'rec_123',
        fileName: 'receipt.pdf',
        extension: 'pdf',
        sizeInBytes: 2048,
        createdAt: now,
        localPath: '/data/user/0/filo/documents/receipt.pdf',
        storageLocation: StorageLocation.internalDocuments,
        conversionType: ConversionType.singleImageToPdf,
      );

      expect(record.id, 'rec_123');
      expect(record.fileName, 'receipt.pdf');
      expect(record.extension, 'pdf');
      expect(record.sizeInBytes, 2048);
      expect(record.createdAt, now);
      expect(record.localPath, '/data/user/0/filo/documents/receipt.pdf');
      expect(record.thumbnailPath, isNull);
      expect(record.conversionType, ConversionType.singleImageToPdf);
      expect(record.storageLocation, StorageLocation.internalDocuments);
    });

    test('validates invalid empty or negative arguments', () {
      final now = DateTime.now();

      expect(
        () => FileRecord(
          id: '',
          fileName: 'test.pdf',
          extension: 'pdf',
          sizeInBytes: 100,
          createdAt: now,
          localPath: '/test.pdf',
        ),
        throwsArgumentError,
      );

      expect(
        () => FileRecord(
          id: '1',
          fileName: '   ',
          extension: 'pdf',
          sizeInBytes: 100,
          createdAt: now,
          localPath: '/test.pdf',
        ),
        throwsArgumentError,
      );

      expect(
        () => FileRecord(
          id: '1',
          fileName: 'test.pdf',
          extension: '',
          sizeInBytes: 100,
          createdAt: now,
          localPath: '/test.pdf',
        ),
        throwsArgumentError,
      );

      expect(
        () => FileRecord(
          id: '1',
          fileName: 'test.pdf',
          extension: 'pdf',
          sizeInBytes: -1,
          createdAt: now,
          localPath: '/test.pdf',
        ),
        throwsArgumentError,
      );

      expect(
        () => FileRecord(
          id: '1',
          fileName: 'test.pdf',
          extension: 'pdf',
          sizeInBytes: 100,
          createdAt: now,
          localPath: '  ',
        ),
        throwsArgumentError,
      );
    });

    test('copyWith updates specified fields correctly', () {
      final now = DateTime.now();
      final record = FileRecord(
        id: '1',
        fileName: 'old.pdf',
        extension: 'pdf',
        sizeInBytes: 100,
        createdAt: now,
        localPath: '/old.pdf',
      );

      final updated = record.copyWith(fileName: 'new.pdf', sizeInBytes: 250);
      expect(updated.id, '1');
      expect(updated.fileName, 'new.pdf');
      expect(updated.sizeInBytes, 250);
      expect(updated.localPath, '/old.pdf');
    });
  });

  group('ConversionJob', () {
    test('supports single input for single-file conversions', () {
      final job = ConversionJob(
        id: 'job_1',
        inputPaths: ['/storage/image.jpg'],
        conversionType: ConversionType.jpgToPng,
        requestedOutputName: 'converted_image',
      );

      expect(job.id, 'job_1');
      expect(job.inputPaths, ['/storage/image.jpg']);
      expect(job.primaryInputPath, '/storage/image.jpg');
      expect(job.conversionType, ConversionType.jpgToPng);
      expect(job.requestedOutputName, 'converted_image');
    });

    test('supports multiple inputs for multipleImagesToPdf', () {
      final job = ConversionJob(
        id: 'job_2',
        inputPaths: [
          '/storage/page1.jpg',
          '/storage/page2.png',
          '/storage/page3.jpg',
        ],
        conversionType: ConversionType.multipleImagesToPdf,
      );

      expect(job.inputPaths.length, 3);
      expect(job.primaryInputPath, '/storage/page1.jpg');
    });

    test('rejects multiple inputs for single-input conversion types', () {
      expect(
        () => ConversionJob(
          id: 'job_invalid',
          inputPaths: ['/storage/file1.png', '/storage/file2.png'],
          conversionType: ConversionType.pngToJpg,
        ),
        throwsArgumentError,
      );
    });

    test('rejects empty input paths or blank job ID', () {
      expect(
        () => ConversionJob(
          id: '',
          inputPaths: ['/storage/file1.png'],
          conversionType: ConversionType.singleImageToPdf,
        ),
        throwsArgumentError,
      );

      expect(
        () => ConversionJob(
          id: 'job_empty_paths',
          inputPaths: [],
          conversionType: ConversionType.singleImageToPdf,
        ),
        throwsArgumentError,
      );

      expect(
        () => ConversionJob(
          id: 'job_blank_path',
          inputPaths: ['   '],
          conversionType: ConversionType.singleImageToPdf,
        ),
        throwsArgumentError,
      );
    });
  });

  group('ConversionResult', () {
    test('success factory creates verified success result', () {
      final result = ConversionResult.success(
        jobId: 'job_10',
        outputPath: '/storage/output.pdf',
        duration: const Duration(milliseconds: 150),
      );

      expect(result.jobId, 'job_10');
      expect(result.isSuccess, isTrue);
      expect(result.outputPath, '/storage/output.pdf');
      expect(result.outputPaths, ['/storage/output.pdf']);
      expect(result.errorMessage, isNull);
      expect(result.duration, const Duration(milliseconds: 150));
    });

    test('multipleSuccess factory creates result with multiple outputs', () {
      final result = ConversionResult.multipleSuccess(
        jobId: 'job_multi',
        outputPaths: ['/page_1.png', '/page_2.png'],
      );

      expect(result.isSuccess, isTrue);
      expect(result.outputPath, '/page_1.png');
      expect(result.outputPaths, ['/page_1.png', '/page_2.png']);
      expect(result.errorMessage, isNull);
    });

    test('failure factory creates failure result with error message', () {
      final result = ConversionResult.failure(
        jobId: 'job_err',
        errorMessage: 'Source file corrupt or unreadable',
      );

      expect(result.isSuccess, isFalse);
      expect(result.outputPath, isNull);
      expect(result.outputPaths, isEmpty);
      expect(result.errorMessage, 'Source file corrupt or unreadable');
    });

    test('rejects invalid parameters for success and failure', () {
      expect(
        () => ConversionResult.success(jobId: 'job_1', outputPath: '  '),
        throwsArgumentError,
      );

      expect(
        () => ConversionResult.failure(jobId: 'job_1', errorMessage: ''),
        throwsArgumentError,
      );

      expect(
        () => ConversionResult.multipleSuccess(jobId: 'job_1', outputPaths: []),
        throwsArgumentError,
      );
    });
  });
}
