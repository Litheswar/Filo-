import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;

import 'package:filo/application/conversion_manager.dart';
import 'package:filo/models/conversion_job.dart';
import 'package:filo/models/conversion_type.dart';
import 'package:filo/services/conversion/pdf_renderer.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tempDir;
  late PdfRenderer renderer;
  late DefaultConversionManager manager;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('filo_pdf_renderer_test_');
    renderer = PdfRenderer();
    manager = DefaultConversionManager([renderer]);
  });

  tearDown(() async {
    if (await tempDir.exists()) {
      await tempDir.delete(recursive: true);
    }
  });

  // Helper to generate test PDF files programmatically with the pdf package
  Future<File> createTestPdf(String fileName, {int pageCount = 1}) async {
    final pdf = pw.Document();
    for (var i = 1; i <= pageCount; i++) {
      pdf.addPage(
        pw.Page(
          pageFormat: PdfPageFormat.a5,
          build: (context) =>
              pw.Center(child: pw.Text('Filo Test Page $i of $pageCount')),
        ),
      );
    }
    final bytes = await pdf.save();
    final file = File('${tempDir.path}/$fileName');
    await file.writeAsBytes(bytes);
    return file;
  }

  group('PdfRenderer - Basic properties & contract', () {
    test('reports correct name and supported types', () {
      expect(renderer.name, equals('PdfRenderer'));
      expect(renderer.supportedTypes, equals({ConversionType.pdfToImages}));
      expect(renderer.canConvert(ConversionType.pdfToImages), isTrue);
      expect(renderer.canConvert(ConversionType.jpgToPng), isFalse);
      expect(renderer.canConvert(ConversionType.singleImageToPdf), isFalse);
      expect(renderer.canConvert(ConversionType.txtToPdf), isFalse);
      expect(renderer.canConvert(ConversionType.pdfToTxt), isFalse);
    });

    test('validates scale and maxDimension bounds in constructor', () {
      expect(() => PdfRenderer(scale: 0.0), throwsArgumentError);
      expect(() => PdfRenderer(scale: -1.0), throwsArgumentError);
      expect(() => PdfRenderer(scale: 6.0), throwsArgumentError);

      expect(() => PdfRenderer(maxDimension: 100), throwsArgumentError);
      expect(() => PdfRenderer(maxDimension: 10000), throwsArgumentError);

      expect(
        () => PdfRenderer(scale: 1.5, maxDimension: 2048),
        returnsNormally,
      );
    });
  });

  group('PdfRenderer - Conversions', () {
    test(
      'converts valid one-page PDF to single valid PNG and preserves source',
      () async {
        final sourcePdf = await createTestPdf('single.pdf', pageCount: 1);
        final initialSourceBytes = await sourcePdf.readAsBytes();

        final job = ConversionJob(
          id: 'job-single-page',
          inputPaths: [sourcePdf.path],
          conversionType: ConversionType.pdfToImages,
          outputDirectory: tempDir.path,
        );

        final result = await renderer.convert(job);

        expect(result.isSuccess, isTrue);
        expect(result.errorMessage, isNull);
        expect(result.outputPaths.length, equals(1));
        expect(result.outputPath, equals(result.outputPaths.first));

        final outputFile = File(result.outputPath!);
        expect(await outputFile.exists(), isTrue);
        expect(await outputFile.length(), greaterThan(0));
        expect(outputFile.path.endsWith('single_page_1.png'), isTrue);

        // Verify decodable PNG
        final decoded = img.decodePng(await outputFile.readAsBytes());
        expect(decoded, isNotNull);
        expect(decoded!.width, greaterThan(0));
        expect(decoded.height, greaterThan(0));

        // Verify source PDF was preserved unchanged
        expect(await sourcePdf.exists(), isTrue);
        final afterBytes = await sourcePdf.readAsBytes();
        expect(afterBytes, equals(initialSourceBytes));
      },
    );

    test(
      'converts valid multi-page PDF to exactly one PNG per page in order',
      () async {
        const pageCount = 3;
        final sourcePdf = await createTestPdf(
          'multipage.pdf',
          pageCount: pageCount,
        );
        final initialSourceBytes = await sourcePdf.readAsBytes();

        final job = ConversionJob(
          id: 'job-multi-page',
          inputPaths: [sourcePdf.path],
          conversionType: ConversionType.pdfToImages,
          outputDirectory: tempDir.path,
        );

        final result = await renderer.convert(job);

        expect(result.isSuccess, isTrue);
        expect(result.errorMessage, isNull);
        expect(result.outputPaths.length, equals(pageCount));
        expect(result.outputPath, equals(result.outputPaths[0]));

        for (var i = 0; i < pageCount; i++) {
          final expectedSuffix = 'multipage_page_${i + 1}.png';
          expect(result.outputPaths[i].endsWith(expectedSuffix), isTrue);

          final pageFile = File(result.outputPaths[i]);
          expect(await pageFile.exists(), isTrue);
          expect(await pageFile.length(), greaterThan(0));

          final decoded = img.decodePng(await pageFile.readAsBytes());
          expect(decoded, isNotNull);
          expect(decoded!.width, greaterThan(0));
          expect(decoded.height, greaterThan(0));
        }

        // Verify source PDF is completely untouched
        expect(await sourcePdf.readAsBytes(), equals(initialSourceBytes));
      },
    );

    test('respects requestedOutputName and custom outputDirectory', () async {
      final sourcePdf = await createTestPdf('doc.pdf', pageCount: 2);
      final customOutputDir = Directory('${tempDir.path}/custom_out');
      await customOutputDir.create(recursive: true);

      final job = ConversionJob(
        id: 'job-custom-name',
        inputPaths: [sourcePdf.path],
        conversionType: ConversionType.pdfToImages,
        requestedOutputName: 'exported_doc',
        outputDirectory: customOutputDir.path,
      );

      final result = await renderer.convert(job);

      expect(result.isSuccess, isTrue);
      expect(result.outputPaths.length, equals(2));
      expect(result.outputPaths[0].endsWith('exported_doc_page_1.png'), isTrue);
      expect(result.outputPaths[1].endsWith('exported_doc_page_2.png'), isTrue);
      expect(
        File(result.outputPaths[0]).parent.absolute.path,
        equals(customOutputDir.absolute.path),
      );
      expect(
        File(result.outputPaths[1]).parent.absolute.path,
        equals(customOutputDir.absolute.path),
      );
    });

    test('handles output filename collisions by appending safe numeric suffixes to the batch', () async {
      final sourcePdf = await createTestPdf('sample.pdf', pageCount: 2);

      // Pre-create the colliding first page file
      final collidingFile = File('${tempDir.path}/sample_page_1.png');
      await collidingFile.writeAsString('pre-existing file content');

      final job = ConversionJob(
        id: 'job-collision',
        inputPaths: [sourcePdf.path],
        conversionType: ConversionType.pdfToImages,
        outputDirectory: tempDir.path,
      );

      final result = await renderer.convert(job);

      expect(result.isSuccess, isTrue);
      expect(result.outputPaths.length, equals(2));

      // Colliding pre-existing file must remain intact
      expect(await collidingFile.exists(), isTrue);
      expect(
        await collidingFile.readAsString(),
        equals('pre-existing file content'),
      );

      // New files should have received suffix _1
      expect(result.outputPaths[0].endsWith('sample_1_page_1.png'), isTrue);
      expect(result.outputPaths[1].endsWith('sample_1_page_2.png'), isTrue);
      expect(await File(result.outputPaths[0]).exists(), isTrue);
      expect(await File(result.outputPaths[1]).exists(), isTrue);
    });
  });

  group('PdfRenderer - Error handling & validation', () {
    test('returns failure when conversion type is not supported', () async {
      final sourcePdf = await createTestPdf('unsupported.pdf', pageCount: 1);

      final job = ConversionJob(
        id: 'job-unsupported',
        inputPaths: [sourcePdf.path],
        conversionType: ConversionType.jpgToPng,
      );

      final result = await renderer.convert(job);

      expect(result.isSuccess, isFalse);
      expect(result.errorMessage, contains('does not support jpgToPng'));
    });

    test('returns failure when source PDF file does not exist', () async {
      final nonExistentPath = '${tempDir.path}/ghost.pdf';

      final job = ConversionJob(
        id: 'job-missing',
        inputPaths: [nonExistentPath],
        conversionType: ConversionType.pdfToImages,
      );

      final result = await renderer.convert(job);

      expect(result.isSuccess, isFalse);
      expect(result.errorMessage, contains('does not exist'));
    });

    test('returns failure when source PDF file is 0 bytes', () async {
      final emptyFile = File('${tempDir.path}/empty.pdf');
      await emptyFile.writeAsBytes([]);

      final job = ConversionJob(
        id: 'job-empty',
        inputPaths: [emptyFile.path],
        conversionType: ConversionType.pdfToImages,
      );

      final result = await renderer.convert(job);

      expect(result.isSuccess, isFalse);
      expect(result.errorMessage, contains('empty (0 bytes)'));
    });

    test(
      'returns failure when source PDF contains invalid/corrupt bytes',
      () async {
        final corruptFile = File('${tempDir.path}/corrupt.pdf');
        await corruptFile.writeAsString('This is not a PDF file format!');

        final job = ConversionJob(
          id: 'job-corrupt',
          inputPaths: [corruptFile.path],
          conversionType: ConversionType.pdfToImages,
        );

        final result = await renderer.convert(job);

        expect(result.isSuccess, isFalse);
        expect(result.errorMessage, contains('corrupt or invalid'));
      },
    );

    test(
      'cleans up partially created output files if failure occurs',
      () async {
        // Creating an invalid/corrupt PDF to test atomic failure without lingering files

        // Corrupt the file after reading initial checks
        // Creating an empty file to test atomic fail without lingering files
        final dummyPdf = File('${tempDir.path}/bad.pdf');
        await dummyPdf.writeAsString('random header %PDF- but corrupt stream');

        final failJob = ConversionJob(
          id: 'job-bad-cleanup',
          inputPaths: [dummyPdf.path],
          conversionType: ConversionType.pdfToImages,
          outputDirectory: tempDir.path,
        );

        final result = await renderer.convert(failJob);
        expect(result.isSuccess, isFalse);

        // Verify no orphan PNG files were left in tempDir
        final pngs = tempDir.listSync().where((f) => f.path.endsWith('.png'));
        expect(pngs, isEmpty);
      },
    );
  });

  group('PdfRenderer - ConversionManager integration', () {
    test(
      'DefaultConversionManager dispatches pdfToImages via PdfRenderer',
      () async {
        final sourcePdf = await createTestPdf('manager_test.pdf', pageCount: 2);

        final job = ConversionJob(
          id: 'job-mgr',
          inputPaths: [sourcePdf.path],
          conversionType: ConversionType.pdfToImages,
          outputDirectory: tempDir.path,
        );

        expect(manager.isTypeSupported(ConversionType.pdfToImages), isTrue);
        final matchedConverter = manager.getConverterFor(
          ConversionType.pdfToImages,
        );
        expect(matchedConverter, isNotNull);
        expect(matchedConverter!.name, equals('PdfRenderer'));

        final result = await manager.processJob(job);

        expect(result.isSuccess, isTrue);
        expect(result.outputPaths.length, equals(2));
        for (final path in result.outputPaths) {
          expect(await File(path).exists(), isTrue);
        }
      },
    );
  });
}
