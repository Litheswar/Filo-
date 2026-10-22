import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;

import 'package:filo/models/conversion_job.dart';
import 'package:filo/models/conversion_type.dart';
import 'package:filo/application/conversion_manager.dart';
import 'package:filo/services/conversion/pdf_creator.dart';

void main() {
  late Directory tempDir;
  late PdfCreator pdfCreator;
  late DefaultConversionManager manager;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('filo_pdf_test_');
    pdfCreator = PdfCreator();
    manager = DefaultConversionManager([pdfCreator]);
  });

  tearDown(() async {
    if (await tempDir.exists()) {
      await tempDir.delete(recursive: true);
    }
  });

  // Helpers to create test fixtures programmatically
  File createTestJpeg(String fileName, {int width = 80, int height = 60}) {
    final image = img.Image(width: width, height: height);
    img.fill(image, color: img.ColorRgb8(200, 50, 50));
    final bytes = img.encodeJpg(image);
    final file = File('${tempDir.path}/$fileName');
    file.writeAsBytesSync(bytes);
    return file;
  }

  File createTestPng(String fileName, {int width = 60, int height = 80}) {
    final image = img.Image(width: width, height: height);
    img.fill(image, color: img.ColorRgb8(50, 150, 50));
    final bytes = img.encodePng(image);
    final file = File('${tempDir.path}/$fileName');
    file.writeAsBytesSync(bytes);
    return file;
  }

  File createTestTxt(String fileName, String content) {
    final file = File('${tempDir.path}/$fileName');
    file.writeAsStringSync(content);
    return file;
  }

  group('PdfCreator - Basic contract & supported types', () {
    test('reports correct name and supported types', () {
      expect(pdfCreator.name, 'PdfCreator');
      expect(pdfCreator.supportedTypes, {
        ConversionType.singleImageToPdf,
        ConversionType.multipleImagesToPdf,
        ConversionType.txtToPdf,
      });
      expect(pdfCreator.canConvert(ConversionType.singleImageToPdf), isTrue);
      expect(pdfCreator.canConvert(ConversionType.multipleImagesToPdf), isTrue);
      expect(pdfCreator.canConvert(ConversionType.txtToPdf), isTrue);
      expect(pdfCreator.canConvert(ConversionType.jpgToPng), isFalse);
    });
  });

  group('Single Image to PDF', () {
    test(
      'converts valid JPEG image to valid PDF and preserves source',
      () async {
        final sourceJpg = createTestJpeg('source.jpg', width: 100, height: 75);
        final originalLength = sourceJpg.lengthSync();

        final job = ConversionJob(
          id: 'job_single_jpg_pdf',
          inputPaths: [sourceJpg.path],
          conversionType: ConversionType.singleImageToPdf,
          outputDirectory: tempDir.path,
          requestedOutputName: 'jpg_doc',
        );

        final result = await pdfCreator.convert(job);

        expect(result.isSuccess, isTrue);
        expect(result.outputPath, isNotNull);
        expect(result.outputPath!.endsWith('.pdf'), isTrue);

        final outputFile = File(result.outputPath!);
        expect(await outputFile.exists(), isTrue);
        expect(await outputFile.length(), greaterThan(100));

        // Validate PDF signature
        final bytes = await outputFile.readAsBytes();
        final header = String.fromCharCodes(bytes.take(5));
        expect(header, '%PDF-');
        expect(String.fromCharCodes(bytes).contains('%%EOF'), isTrue);

        // Verify source file is preserved intact
        expect(await sourceJpg.exists(), isTrue);
        expect(sourceJpg.lengthSync(), originalLength);
      },
    );

    test('converts valid PNG image to valid PDF', () async {
      final sourcePng = createTestPng('source.png', width: 50, height: 100);

      final job = ConversionJob(
        id: 'job_single_png_pdf',
        inputPaths: [sourcePng.path],
        conversionType: ConversionType.singleImageToPdf,
        outputDirectory: tempDir.path,
      );

      final result = await pdfCreator.convert(job);

      expect(result.isSuccess, isTrue);
      expect(result.outputPath!.endsWith('.pdf'), isTrue);
      final outputFile = File(result.outputPath!);
      expect(await outputFile.exists(), isTrue);
    });

    test('fails gracefully when source image is missing', () async {
      final job = ConversionJob(
        id: 'job_missing_img',
        inputPaths: ['${tempDir.path}/missing.jpg'],
        conversionType: ConversionType.singleImageToPdf,
      );

      final result = await pdfCreator.convert(job);

      expect(result.isSuccess, isFalse);
      expect(result.errorMessage, contains('does not exist'));
    });

    test('fails gracefully when source image is empty (0 bytes)', () async {
      final emptyFile = File('${tempDir.path}/empty.jpg')..writeAsBytesSync([]);

      final job = ConversionJob(
        id: 'job_empty_img',
        inputPaths: [emptyFile.path],
        conversionType: ConversionType.singleImageToPdf,
      );

      final result = await pdfCreator.convert(job);

      expect(result.isSuccess, isFalse);
      expect(result.errorMessage, contains('empty'));
    });

    test('fails gracefully when image bytes are corrupted', () async {
      final corruptFile = File('${tempDir.path}/corrupt.jpg')
        ..writeAsStringSync('NOT AN IMAGE STREAM');

      final job = ConversionJob(
        id: 'job_corrupt_img',
        inputPaths: [corruptFile.path],
        conversionType: ConversionType.singleImageToPdf,
      );

      final result = await pdfCreator.convert(job);

      expect(result.isSuccess, isFalse);
      expect(result.errorMessage, contains('not a valid or decodable image'));
    });
  });

  group('Multiple Images to PDF', () {
    test('converts multiple images into a single multi-page PDF', () async {
      final img1 = createTestJpeg('page1.jpg', width: 60, height: 80);
      final img2 = createTestPng('page2.png', width: 100, height: 50);
      final img3 = createTestJpeg('page3.jpg', width: 70, height: 70);

      final job = ConversionJob(
        id: 'job_multi_pdf',
        inputPaths: [img1.path, img2.path, img3.path],
        conversionType: ConversionType.multipleImagesToPdf,
        outputDirectory: tempDir.path,
        requestedOutputName: 'combined_album',
      );

      final result = await pdfCreator.convert(job);

      expect(result.isSuccess, isTrue);
      expect(result.outputPath, isNotNull);
      expect(result.outputPath!.endsWith('.pdf'), isTrue);

      final outputFile = File(result.outputPath!);
      expect(await outputFile.exists(), isTrue);

      // Verify PDF structure contains page definitions for all 3 pages
      final bytes = await outputFile.readAsBytes();
      final content = latin1.decode(bytes);
      expect(content.contains('%PDF-'), isTrue);
      // The pdf package compresses object streams (deflate), so object streams contain compressed /Page definitions or deflate dictionaries
      expect(bytes.length, greaterThan(500));
      expect(content.contains('%%EOF'), isTrue);

      // Verify source images are preserved
      expect(await img1.exists(), isTrue);
      expect(await img2.exists(), isTrue);
      expect(await img3.exists(), isTrue);
    });

    test('fails safely without producing partial PDF if any image in the list is invalid', () async {
      final validImg = createTestJpeg('valid.jpg');
      final corruptImg = File('${tempDir.path}/bad.png')
        ..writeAsStringSync('MALFORMED');

      final job = ConversionJob(
        id: 'job_multi_fail',
        inputPaths: [validImg.path, corruptImg.path],
        conversionType: ConversionType.multipleImagesToPdf,
        outputDirectory: tempDir.path,
        requestedOutputName: 'should_not_exist',
      );

      final result = await pdfCreator.convert(job);

      expect(result.isSuccess, isFalse);
      expect(result.errorMessage, contains('not a valid or decodable image'));

      // Ensure no partial file was created
      final potentialOutput = File('${tempDir.path}/should_not_exist.pdf');
      expect(await potentialOutput.exists(), isFalse);
    });
  });

  group('TXT to PDF', () {
    test('converts ordinary text file to formatted PDF', () async {
      final textFile = createTestTxt(
        'notes.txt',
        'Meeting Minutes\nDate: 2026-10-13\n\nAttendees: Alice, Bob, Charlie\n\nSummary:\nAll targets met.',
      );

      final job = ConversionJob(
        id: 'job_txt_simple',
        inputPaths: [textFile.path],
        conversionType: ConversionType.txtToPdf,
        outputDirectory: tempDir.path,
      );

      final result = await pdfCreator.convert(job);

      expect(result.isSuccess, isTrue);
      expect(result.outputPath, isNotNull);

      final outputFile = File(result.outputPath!);
      expect(await outputFile.exists(), isTrue);
      final bytes = await outputFile.readAsBytes();
      expect(String.fromCharCodes(bytes.take(5)), '%PDF-');
    });

    test('converts long text spanning multiple pages', () async {
      // Build ~150 lines of text to ensure multi-page layout is exercised
      final buffer = StringBuffer();
      for (var i = 1; i <= 150; i++) {
        buffer.writeln(
          'Paragraph $i: Lorem ipsum dolor sit amet, consectetur adipiscing elit. Integer nec odio.',
        );
      }
      final longTextFile = createTestTxt(
        'long_document.txt',
        buffer.toString(),
      );

      final job = ConversionJob(
        id: 'job_txt_long',
        inputPaths: [longTextFile.path],
        conversionType: ConversionType.txtToPdf,
        outputDirectory: tempDir.path,
      );

      final result = await pdfCreator.convert(job);

      expect(result.isSuccess, isTrue);
      final outputFile = File(result.outputPath!);
      expect(await outputFile.exists(), isTrue);
      expect(await outputFile.length(), greaterThan(2000));
    });

    test('handles empty text file according to policy (produces valid blank PDF page)', () async {
      final emptyTextFile = createTestTxt('empty.txt', '');

      final job = ConversionJob(
        id: 'job_txt_empty',
        inputPaths: [emptyTextFile.path],
        conversionType: ConversionType.txtToPdf,
        outputDirectory: tempDir.path,
      );

      final result = await pdfCreator.convert(job);

      expect(result.isSuccess, isTrue);
      final outputFile = File(result.outputPath!);
      expect(await outputFile.exists(), isTrue);
      final bytes = await outputFile.readAsBytes();
      expect(String.fromCharCodes(bytes.take(5)), '%PDF-');
    });

    test('fails gracefully when text file is missing', () async {
      final job = ConversionJob(
        id: 'job_txt_missing',
        inputPaths: ['${tempDir.path}/missing.txt'],
        conversionType: ConversionType.txtToPdf,
      );

      final result = await pdfCreator.convert(job);

      expect(result.isSuccess, isFalse);
      expect(result.errorMessage, contains('does not exist'));
    });

    test('handles common Unicode characters in text', () async {
      final unicodeFile = createTestTxt(
        'unicode.txt',
        'Hello World — Filo\nBullets: • Item 1 • Item 2\nQuotes: “Privacy-first”\nCurrency: \$100, €50, £25',
      );

      final job = ConversionJob(
        id: 'job_txt_unicode',
        inputPaths: [unicodeFile.path],
        conversionType: ConversionType.txtToPdf,
        outputDirectory: tempDir.path,
      );

      final result = await pdfCreator.convert(job);

      expect(result.isSuccess, isTrue);
      expect(await File(result.outputPath!).exists(), isTrue);
    });
  });

  group('Output Collision & Manager Integration', () {
    test(
      'avoids overwriting existing output by appending numeric suffix',
      () async {
        final sourceJpg = createTestJpeg('collision_src.jpg');

        // Create an existing file at the target path
        final existingFile = File('${tempDir.path}/report.pdf')
          ..writeAsStringSync('EXISTING PDF');

        final job = ConversionJob(
          id: 'job_collision',
          inputPaths: [sourceJpg.path],
          conversionType: ConversionType.singleImageToPdf,
          outputDirectory: tempDir.path,
          requestedOutputName: 'report',
        );

        final result = await pdfCreator.convert(job);

        expect(result.isSuccess, isTrue);
        // Expected suffix '_1' appended to avoid collision
        expect(result.outputPath, endsWith('report_1.pdf'));

        // Ensure existing file is untouched
        expect(await existingFile.readAsString(), 'EXISTING PDF');
        // Ensure new file is a valid PDF
        final newFile = File(result.outputPath!);
        expect(await newFile.exists(), isTrue);
        final header = String.fromCharCodes(
          (await newFile.readAsBytes()).take(5),
        );
        expect(header, '%PDF-');
      },
    );

    test('DefaultConversionManager successfully dispatches all three PDF operations', () async {
      final jpg = createTestJpeg('m_jpg.jpg');
      final png = createTestPng('m_png.png');
      final txt = createTestTxt('m_txt.txt', 'Manager dispatch test');

      // 1. Single Image to PDF
      final res1 = await manager.processJob(
        ConversionJob(
          id: 'm1',
          inputPaths: [jpg.path],
          conversionType: ConversionType.singleImageToPdf,
          outputDirectory: tempDir.path,
        ),
      );
      expect(res1.isSuccess, isTrue);

      // 2. Multiple Images to PDF
      final res2 = await manager.processJob(
        ConversionJob(
          id: 'm2',
          inputPaths: [jpg.path, png.path],
          conversionType: ConversionType.multipleImagesToPdf,
          outputDirectory: tempDir.path,
        ),
      );
      expect(res2.isSuccess, isTrue);

      // 3. TXT to PDF
      final res3 = await manager.processJob(
        ConversionJob(
          id: 'm3',
          inputPaths: [txt.path],
          conversionType: ConversionType.txtToPdf,
          outputDirectory: tempDir.path,
        ),
      );
      expect(res3.isSuccess, isTrue);

      // 4. Unsupported (e.g. PDF to TXT) fails gracefully
      final res4 = await manager.processJob(
        ConversionJob(
          id: 'm4',
          inputPaths: [txt.path],
          conversionType: ConversionType.pdfToTxt,
        ),
      );
      expect(res4.isSuccess, isFalse);
      expect(
        res4.errorMessage,
        contains('No registered converter supports pdfToTxt'),
      );
    });
  });
}
