import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:pdfrx/pdfrx.dart' as pdfrx;

import 'package:filo/application/conversion_manager.dart';
import 'package:filo/models/conversion_job.dart';
import 'package:filo/models/conversion_result.dart';
import 'package:filo/models/conversion_type.dart';
import 'package:filo/services/conversion/pdf_text_extractor.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tempDir;
  late PdfTextExtractor extractor;
  late DefaultConversionManager manager;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('filo_pdf_text_test_');
    extractor = PdfTextExtractor();
    manager = DefaultConversionManager([extractor]);
  });

  tearDown(() async {
    if (await tempDir.exists()) await tempDir.delete(recursive: true);
  });

  Future<File> createPdf(String name, List<pw.Widget> pageContents) async {
    final pdf = pw.Document();
    for (final content in pageContents) {
      pdf.addPage(
        pw.Page(
          pageFormat: PdfPageFormat.a5,
          build: (_) => pw.Center(child: content),
        ),
      );
    }
    final file = File('${tempDir.path}/$name');
    await file.writeAsBytes(await pdf.save());
    return file;
  }

  Future<File> createTextPdf(String name, List<String> pages) =>
      createPdf(name, pages.map((text) => pw.Text(text)).toList());

  Uint8List createImageBytes() {
    final bitmap = img.Image(width: 8, height: 8);
    img.fill(bitmap, color: img.ColorRgb8(20, 80, 140));
    return Uint8List.fromList(img.encodePng(bitmap));
  }

  Future<ConversionResult> convert(File input, {String? name}) =>
      extractor.convert(
        ConversionJob(
          id: 'extract-${input.uri.pathSegments.last}',
          inputPaths: [input.path],
          conversionType: ConversionType.pdfToTxt,
          outputDirectory: tempDir.path,
          requestedOutputName: name,
        ),
      );

  group('PdfTextExtractor contract', () {
    test('supports only PDF-to-TXT', () {
      expect(extractor.name, 'PdfTextExtractor');
      expect(extractor.supportedTypes, {ConversionType.pdfToTxt});
      expect(extractor.canConvert(ConversionType.pdfToTxt), isTrue);
      expect(extractor.canConvert(ConversionType.pdfToImages), isFalse);
      expect(extractor.canConvert(ConversionType.txtToPdf), isFalse);
    });

    test('returns failure for an unsupported conversion type', () async {
      final input = await createTextPdf('unsupported.pdf', ['hello']);
      final result = await extractor.convert(
        ConversionJob(
          id: 'unsupported',
          inputPaths: [input.path],
          conversionType: ConversionType.txtToPdf,
        ),
      );

      expect(result.isSuccess, isFalse);
      expect(result.errorMessage, contains('does not support txtToPdf'));
    });
  });

  group('PDF text extraction', () {
    test(
      'extracts selectable text to a verified UTF-8 TXT and preserves PDF',
      () async {
        final source = await createTextPdf('source.pdf', ['Selectable phrase']);
        final original = await source.readAsBytes();

        final result = await convert(source);

        expect(result.isSuccess, isTrue, reason: result.errorMessage);
        expect(result.outputPath, endsWith('source_extracted.txt'));
        expect(result.outputPaths, [result.outputPath]);
        final contents = await File(result.outputPath!)
            .readAsString(encoding: utf8);
        expect(contents, contains('Selectable phrase'));
        expect(await source.readAsBytes(), original);
      },
    );

    test(
      'keeps pages in document order and separates them with form feed',
      () async {
        final source = await createTextPdf('ordered.pdf', [
          'PAGE ALPHA',
          'PAGE BRAVO',
          'PAGE CHARLIE',
        ]);

        final result = await convert(source);

        expect(result.isSuccess, isTrue, reason: result.errorMessage);
        final contents = await File(result.outputPath!).readAsString();
        final alpha = contents.indexOf('PAGE ALPHA');
        final bravo = contents.indexOf('PAGE BRAVO');
        final charlie = contents.indexOf('PAGE CHARLIE');
        expect(alpha, greaterThanOrEqualTo(0));
        expect(bravo, greaterThan(alpha));
        expect(charlie, greaterThan(bravo));
        expect(contents, contains('\n\f\n'));
      },
    );

    test('preserves line breaks from structured page text', () async {
      final source = await createPdf('lines.pdf', [
        pw.Text('First line\nSecond line'),
      ]);

      final result = await convert(source);

      expect(result.isSuccess, isTrue, reason: result.errorMessage);
      final contents = await File(result.outputPath!).readAsString();
      expect(contents, contains('First line'));
      expect(contents, contains('Second line'));
      expect(
        contents.indexOf('Second line'),
        greaterThan(contents.indexOf('First line')),
      );
      expect(contents, contains('\n'));
    });

    test('preserves supported Unicode characters', () async {
      final source = await createTextPdf('unicode.pdf', ['café naïve']);

      final result = await convert(source);

      expect(result.isSuccess, isTrue, reason: result.errorMessage);
      expect(
        await File(result.outputPath!).readAsString(),
        contains('café naïve'),
      );
    });

    test('fails clearly when a valid PDF has no extractable text', () async {
      final source = await createPdf('image_only.pdf', [
        pw.Image(pw.MemoryImage(createImageBytes()), width: 40, height: 40),
      ]);

      final result = await convert(source);

      expect(result.isSuccess, isFalse);
      expect(result.errorMessage, contains('No extractable text found'));
      expect(result.errorMessage, contains('OCR is not available'));
      expect(
        Directory(tempDir.path)
            .listSync()
            .whereType<File>()
            .where((file) => file.path.endsWith('.txt')),
        isEmpty,
      );
    });

    test(
      'extracts selectable text from a page that also contains an image',
      () async {
        final imageBytes = createImageBytes();
        final source = await createPdf('mixed.pdf', [
          pw.Column(
            mainAxisSize: pw.MainAxisSize.min,
            children: [
              pw.Text('Visible selectable label'),
              pw.Image(pw.MemoryImage(imageBytes), width: 30, height: 30),
            ],
          ),
        ]);

        final result = await convert(source);

        expect(result.isSuccess, isTrue, reason: result.errorMessage);
        final contents = await File(result.outputPath!).readAsString();
        expect(contents, contains('Visible selectable label'));
        expect(contents.toLowerCase(), isNot(contains('ocr')));
      },
    );
  });

  group('Input and output safety', () {
    test('fails for missing, empty, and corrupt input files', () async {
      final missing = File('${tempDir.path}/missing.pdf');
      final missingResult = await convert(missing);
      expect(missingResult.isSuccess, isFalse);
      expect(missingResult.errorMessage, contains('does not exist'));

      final empty = File('${tempDir.path}/empty.pdf');
      await empty.writeAsBytes([]);
      final emptyResult = await convert(empty);
      expect(emptyResult.isSuccess, isFalse);
      expect(emptyResult.errorMessage, contains('empty'));

      final corrupt = File('${tempDir.path}/corrupt.pdf');
      await corrupt.writeAsString('not a PDF');
      final corruptResult = await convert(corrupt);
      expect(corruptResult.isSuccess, isFalse);
      expect(corruptResult.errorMessage, contains('corrupt or invalid'));
    });

    test('reports password-protected PDFs clearly', () async {
      final source = await createTextPdf('protected.pdf', ['secret text']);
      final passwordExtractor = PdfTextExtractor(
        documentOpener: (_) async {
          throw const pdfrx.PdfPasswordException('password required');
        },
      );

      final result = await passwordExtractor.convert(
        ConversionJob(
          id: 'password-protected',
          inputPaths: [source.path],
          conversionType: ConversionType.pdfToTxt,
          outputDirectory: tempDir.path,
        ),
      );

      expect(result.isSuccess, isFalse);
      expect(result.errorMessage, contains('password-protected'));
    });

    test(
      'uses numeric suffixes for collisions and keeps existing files intact',
      () async {
        final source = await createTextPdf('collision.pdf', ['collision text']);
        final existing = File('${tempDir.path}/chosen.txt');
        await existing.writeAsString('keep this file');

        final result = await convert(source, name: 'chosen.txt');

        expect(result.isSuccess, isTrue, reason: result.errorMessage);
        expect(result.outputPath, endsWith('chosen_1.txt'));
        expect(await existing.readAsString(), 'keep this file');
        expect(
          await File(result.outputPath!).readAsString(),
          contains('collision text'),
        );
        expect(await source.exists(), isTrue);
      },
    );

    test(
      'does not overwrite the source if its extension matches the TXT output',
      () async {
        final source = await createTextPdf('source.txt', [
          'source bytes stay safe',
        ]);
        final original = await source.readAsBytes();

        final result = await convert(source, name: 'source.txt');

        expect(result.isSuccess, isTrue, reason: result.errorMessage);
        expect(result.outputPath, isNot(source.path));
        expect(await source.readAsBytes(), original);
      },
    );

    test('fails safely when the output directory cannot be created', () async {
      final source = await createTextPdf('write_failure.pdf', [
        'must not be lost',
      ]);
      final blockedDirectory = File('${tempDir.path}/not_a_directory');
      await blockedDirectory.writeAsString('preserve this file');

      final result = await extractor.convert(
        ConversionJob(
          id: 'write-failure',
          inputPaths: [source.path],
          conversionType: ConversionType.pdfToTxt,
          outputDirectory: blockedDirectory.path,
        ),
      );

      expect(result.isSuccess, isFalse);
      expect(await blockedDirectory.readAsString(), 'preserve this file');
      expect(await source.exists(), isTrue);
      expect(
        Directory(tempDir.path)
            .listSync()
            .whereType<File>()
            .where((file) => file.path.endsWith('.txt')),
        isEmpty,
      );
    });
  });

  test(
    'DefaultConversionManager dispatches pdfToTxt to PdfTextExtractor',
    () async {
      final source = await createTextPdf('dispatch.pdf', ['manager dispatch']);
      final job = ConversionJob(
        id: 'dispatch',
        inputPaths: [source.path],
        conversionType: ConversionType.pdfToTxt,
        outputDirectory: tempDir.path,
      );

      expect(manager.isTypeSupported(ConversionType.pdfToTxt), isTrue);
      expect(
        manager.getConverterFor(ConversionType.pdfToTxt)?.name,
        'PdfTextExtractor',
      );
      final result = await manager.processJob(job);

      expect(result.isSuccess, isTrue, reason: result.errorMessage);
      expect(
        await File(result.outputPath!).readAsString(),
        contains('manager dispatch'),
      );
    },
  );
}
