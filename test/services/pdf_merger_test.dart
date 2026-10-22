import 'dart:io';

import 'package:filo/models/conversion_job.dart';
import 'package:filo/models/conversion_result.dart';
import 'package:filo/models/conversion_type.dart';
import 'package:filo/services/conversion/pdf_merger.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pdfrx/pdfrx.dart' as pdfrx;
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;

void main() {
  late Directory directory;
  late PdfMerger merger;

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('filo-pdf-merge-test-');
    merger = PdfMerger();
  });

  tearDown(() async {
    if (await directory.exists()) await directory.delete(recursive: true);
  });

  test(
    'merges two valid PDFs and preserves page content and geometry',
    () async {
      final first = await _writePdf(directory, 'first.pdf', [
        _PageFixture('FIRST_PAGE', PdfPageFormat.a4),
        _PageFixture('SECOND_PAGE', PdfPageFormat.letter),
      ]);
      final second = await _writePdf(directory, 'second.pdf', [
        _PageFixture('THIRD_PAGE', PdfPageFormat.a4.landscape),
      ]);
      final firstBytes = await first.readAsBytes();
      final secondBytes = await second.readAsBytes();

      final result = await _merge(merger, directory, [first.path, second.path]);

      expect(result.isSuccess, isTrue, reason: result.errorMessage);
      final output = File(result.outputPath!);
      expect(await output.length(), greaterThan(0));
      final pages = await _readPages(output);
      expect(pages.map((page) => page.text), [
        contains('FIRST_PAGE'),
        contains('SECOND_PAGE'),
        contains('THIRD_PAGE'),
      ]);
      expect(pages[0].width, closeTo(595.28, 1));
      expect(pages[2].width, greaterThan(pages[2].height));
      expect(await first.readAsBytes(), firstBytes);
      expect(await second.readAsBytes(), secondBytes);
    },
  );

  test('merges three or more PDFs in the requested input order', () async {
    final a = await _writePdf(directory, 'a.pdf', [_PageFixture('ORDER_A')]);
    final b = await _writePdf(directory, 'b.pdf', [_PageFixture('ORDER_B')]);
    final c = await _writePdf(directory, 'c.pdf', [_PageFixture('ORDER_C')]);

    final result = await _merge(merger, directory, [c.path, a.path, b.path]);

    expect(result.isSuccess, isTrue, reason: result.errorMessage);
    final pages = await _readPages(File(result.outputPath!));
    expect(pages.map((page) => page.text), [
      contains('ORDER_C'),
      contains('ORDER_A'),
      contains('ORDER_B'),
    ]);
  });

  test('ConversionJob rejects a single-input PDF merge', () {
    expect(
      () => ConversionJob(
        id: 'single',
        inputPaths: ['one.pdf'],
        conversionType: ConversionType.pdfMerge,
      ),
      throwsArgumentError,
    );
  });

  test('rejects empty PDFs, corrupt PDFs, and missing files', () async {
    final empty = File('${directory.path}/empty.pdf')..createSync();
    final corrupt = File('${directory.path}/corrupt.pdf')
      ..writeAsStringSync('not a PDF');
    final valid = await _writePdf(directory, 'valid.pdf', [
      _PageFixture('VALID'),
    ]);

    for (final paths in [
      [valid.path, empty.path],
      [valid.path, corrupt.path],
      [valid.path, '${directory.path}/missing.pdf'],
    ]) {
      final result = await _merge(merger, directory, paths);
      expect(result.isSuccess, isFalse);
      expect(result.errorMessage, isNotEmpty);
      expect(result.outputPath, isNull);
    }
    expect(
      directory.listSync().where(
        (entity) => entity.path.endsWith('_merged.pdf'),
      ),
      isEmpty,
    );
  });

  test(
    'uses a collision-safe name and leaves the existing file unchanged',
    () async {
      final first = await _writePdf(directory, 'first.pdf', [
        _PageFixture('FIRST'),
      ]);
      final second = await _writePdf(directory, 'second.pdf', [
        _PageFixture('SECOND'),
      ]);
      final existing = File('${directory.path}/result.pdf')
        ..writeAsStringSync('keep this file');

      final result = await _merge(merger, directory, [
        first.path,
        second.path,
      ], requestedOutputName: 'result.pdf');

      expect(result.isSuccess, isTrue, reason: result.errorMessage);
      expect(result.outputPath, endsWith('result_1.pdf'));
      expect(await existing.readAsString(), 'keep this file');
    },
  );

  test('numbers collisions for the default merged filename', () async {
    final first = await _writePdf(directory, '03-gamma.pdf', [
      _PageFixture('FIRST'),
    ]);
    final second = await _writePdf(directory, 'second.pdf', [
      _PageFixture('SECOND'),
    ]);
    final existing = File('${directory.path}/03-gamma_merged.pdf')
      ..writeAsStringSync('preserve existing output');

    final result = await _merge(merger, directory, [first.path, second.path]);

    expect(result.isSuccess, isTrue, reason: result.errorMessage);
    expect(result.outputPath, endsWith('03-gamma_merged_1.pdf'));
    expect(await existing.readAsString(), 'preserve existing output');
  });

  test('removes an incomplete output after a write failure', () async {
    final first = await _writePdf(directory, 'first.pdf', [
      _PageFixture('FIRST'),
    ]);
    final second = await _writePdf(directory, 'second.pdf', [
      _PageFixture('SECOND'),
    ]);
    final failingMerger = PdfMerger(
      outputWriter: (file, bytes) async {
        await file.writeAsBytes(bytes.take(24).toList());
        throw const FileSystemException('simulated write failure');
      },
    );

    final result = await failingMerger.convert(
      ConversionJob(
        id: 'write-failure',
        inputPaths: [first.path, second.path],
        conversionType: ConversionType.pdfMerge,
        outputDirectory: directory.path,
      ),
    );

    expect(result.isSuccess, isFalse);
    expect(
      directory.listSync().where(
        (entity) => entity.path.endsWith('_merged.pdf'),
      ),
      isEmpty,
    );
  });
}

Future<File> _writePdf(
  Directory directory,
  String name,
  List<_PageFixture> pages,
) async {
  final document = pw.Document();
  for (final page in pages) {
    document.addPage(
      pw.Page(
        pageFormat: page.format,
        build: (_) => pw.Center(
          child: pw.Text(page.text, style: const pw.TextStyle(fontSize: 24)),
        ),
      ),
    );
  }
  final file = File('${directory.path}/$name');
  await file.writeAsBytes(await document.save(), flush: true);
  return file;
}

Future<ConversionResult> _merge(
  PdfMerger merger,
  Directory directory,
  List<String> inputs, {
  String? requestedOutputName,
}) => merger.convert(
  ConversionJob(
    id: 'merge-${DateTime.now().microsecondsSinceEpoch}',
    inputPaths: inputs,
    conversionType: ConversionType.pdfMerge,
    outputDirectory: directory.path,
    requestedOutputName: requestedOutputName,
  ),
);

Future<List<_ReadPage>> _readPages(File file) async {
  final document = await pdfrx.PdfDocument.openFile(file.path);
  try {
    final pages = <_ReadPage>[];
    for (final page in document.pages) {
      pages.add(
        _ReadPage(
          text: (await page.loadStructuredText()).fullText,
          width: page.width,
          height: page.height,
        ),
      );
    }
    return pages;
  } finally {
    await document.dispose();
  }
}

class _PageFixture {
  const _PageFixture(this.text, [this.format = PdfPageFormat.a4]);
  final String text;
  final PdfPageFormat format;
}

class _ReadPage {
  const _ReadPage({
    required this.text,
    required this.width,
    required this.height,
  });
  final String text;
  final double width;
  final double height;
}
