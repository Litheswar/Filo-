import 'dart:convert';
import 'dart:io';

import 'package:filo/models/conversion_type.dart';
import 'package:filo/models/file_record.dart';
import 'package:filo/services/preview/text_preview_service.dart';
import 'package:filo/services/preview/thumbnail_service.dart';
import 'package:filo/services/storage/file_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;

void main() {
  late Directory root;
  late FileStorage storage;
  late ThumbnailService thumbnails;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('filo_preview_test_');
    storage = FileStorage(
      documentsDirectoryProvider: () async => Directory('${root.path}/appdocs'),
      temporaryDirectoryProvider: () async => Directory('${root.path}/temp'),
    );
    thumbnails = ThumbnailService(fileStorage: storage, maxDimension: 320);
  });

  tearDown(() async {
    if (await root.exists()) await root.delete(recursive: true);
  });

  Future<(FileRecord, File)> storeBytes(
    String id,
    String name,
    List<int> bytes,
  ) async {
    final directories = await storage.initialize();
    final file = File(
      '${directories.documents.path}${Platform.pathSeparator}$name',
    );
    await file.writeAsBytes(bytes);
    return (
      FileRecord(
        id: id,
        fileName: name,
        extension: name.split('.').last,
        sizeInBytes: bytes.length,
        createdAt: DateTime.utc(2025),
        localPath: file.path,
        conversionType: ConversionType.pngToJpg,
      ),
      file,
    );
  }

  List<int> pngBytes(int width, int height) {
    final image = img.Image(width: width, height: height);
    img.fill(image, color: img.ColorRgb8(40, 120, 200));
    return img.encodePng(image);
  }

  test('creates bounded aspect-preserving JPG and PNG thumbnails without changing originals', () async {
    final wideImage = img.Image(width: 640, height: 320);
    img.fill(wideImage, color: img.ColorRgb8(220, 20, 20));
    final jpg = img.encodeJpg(wideImage);
    final (record, file) = await storeBytes('wide', 'wide.jpg', jpg);

    final result = await thumbnails.generate(record);
    expect(result.isSuccess, isTrue);
    final decoded = img.decodePng(await File(result.path!).readAsBytes())!;
    expect(decoded.width, 320);
    expect(decoded.height, 160);
    expect(await file.readAsBytes(), jpg);

    final (pngRecord, pngFile) = await storeBytes(
      'png',
      'image.png',
      pngBytes(120, 80),
    );
    final pngOriginal = await pngFile.readAsBytes();
    final pngResult = await thumbnails.generate(pngRecord);
    final small = img.decodePng(await File(pngResult.path!).readAsBytes())!;
    expect(small.width, 120);
    expect(small.height, 80);
    expect(await pngFile.readAsBytes(), pngOriginal);
  });

  test('rejects invalid image bytes and unsupported extensions', () async {
    final (invalid, _) = await storeBytes('invalid', 'bad.png', [1, 2, 3, 4]);
    expect((await thumbnails.generate(invalid)).isSuccess, isFalse);
    final (txt, _) = await storeBytes('txt', 'note.txt', utf8.encode('hello'));
    expect(
      (await thumbnails.generate(txt)).errorMessage,
      contains('unsupported'),
    );
  });

  test(
    'PDF thumbnail renders only the first page within the dimension limit',
    () async {
      final pdf = pw.Document();
      pdf.addPage(
        pw.Page(
          pageFormat: PdfPageFormat.a4,
          build: (_) => pw.Container(
            color: PdfColors.red,
            child: pw.Center(child: pw.Text('FIRST_PAGE_MARKER')),
          ),
        ),
      );
      pdf.addPage(
        pw.Page(
          pageFormat: PdfPageFormat.a4.landscape,
          build: (_) => pw.Container(
            color: PdfColors.blue,
            child: pw.Center(child: pw.Text('SECOND_PAGE_MARKER')),
          ),
        ),
      );
      final (record, _) = await storeBytes(
        'multi',
        'two-pages.pdf',
        await pdf.save(),
      );

      final result = await thumbnails.generate(record);
      expect(result.isSuccess, isTrue, reason: result.errorMessage);
      final image = img.decodePng(await File(result.path!).readAsBytes())!;
      expect(image.width, lessThanOrEqualTo(320));
      expect(image.height, lessThanOrEqualTo(320));
      expect(image.height, greaterThan(image.width));
    },
  );

  test('empty, invalid, and missing PDFs fail gracefully', () async {
    final (empty, _) = await storeBytes('empty', 'empty.pdf', []);
    final (invalid, _) = await storeBytes('invalid-pdf', 'broken.pdf', [
      1,
      2,
      3,
    ]);
    expect((await thumbnails.generate(empty)).isSuccess, isFalse);
    expect((await thumbnails.generate(invalid)).isSuccess, isFalse);
    final (missing, source) = await storeBytes('missing', 'missing.pdf', [1]);
    await source.delete();
    expect((await thumbnails.generate(missing)).isSuccess, isFalse);
  });

  test('cache reuses valid images and invalidates on size changes or missing output', () async {
    final (record, source) = await storeBytes(
      'cache-doc',
      'cache.png',
      pngBytes(400, 200),
    );
    final first = await thumbnails.generate(record);
    expect(first.isSuccess, isTrue);
    final cachedRecord = record.copyWith(thumbnailPath: first.path);
    final reused = await thumbnails.generate(cachedRecord);
    expect(reused.reused, isTrue);
    expect(reused.path, first.path);

    await File(first.path!).delete();
    final regenerated = await thumbnails.generate(cachedRecord);
    expect(regenerated.isSuccess, isTrue);
    expect(regenerated.reused, isFalse);

    await File(regenerated.path!).writeAsBytes([1, 2, 3]);
    final repaired = await thumbnails.generate(
      cachedRecord.copyWith(thumbnailPath: regenerated.path),
    );
    expect(repaired.isSuccess, isTrue);
    expect(repaired.reused, isFalse);

    await source.writeAsBytes(pngBytes(50, 50));
    final stale = await thumbnails.generate(
      cachedRecord.copyWith(thumbnailPath: repaired.path),
    );
    expect(stale.isSuccess, isTrue);
    expect(stale.path, isNot(regenerated.path));
    expect(await File(repaired.path!).exists(), isFalse);
  });

  test(
    'different documents never share identity-keyed thumbnail paths',
    () async {
      final bytes = pngBytes(40, 30);
      final (first, _) = await storeBytes('first-id', 'one.png', bytes);
      final (second, _) = await storeBytes('second-id', 'two.png', bytes);
      final firstResult = await thumbnails.generate(first);
      final secondResult = await thumbnails.generate(second);
      expect(firstResult.path, isNot(secondResult.path));
    },
  );

  test(
    'can persist the generated path through a caller-supplied library update',
    () async {
      final (record, _) = await storeBytes(
        'persisted',
        'persisted.png',
        pngBytes(20, 20),
      );
      FileRecord? persisted;
      final result = await thumbnails.generate(
        record,
        updateRecord: (updated) async {
          persisted = updated;
          return true;
        },
      );
      expect(result.isSuccess, isTrue);
      expect(persisted?.id, record.id);
      expect(persisted?.thumbnailPath, result.path);
    },
  );

  test('same-key concurrent requests share a single generation', () async {
    final (record, _) = await storeBytes(
      'concurrent',
      'same.png',
      pngBytes(400, 200),
    );
    final results = await Future.wait([
      thumbnails.generate(record),
      thumbnails.generate(record),
    ]);
    expect(results.every((result) => result.isSuccess), isTrue);
    expect(results[0].path, results[1].path);
  });

  test(
    'thumbnail deletion refuses files outside the managed thumbnail directory',
    () async {
      final outside = File('${root.path}${Platform.pathSeparator}outside.png')
        ..writeAsBytesSync(pngBytes(2, 2));
      await expectLater(
        storage.deleteThumbnail(outside),
        throwsA(isA<FileStorageException>()),
      );
      expect(await outside.exists(), isTrue);
    },
  );

  test(
    'document cache cleanup removes only that document identity thumbnail',
    () async {
      final (first, _) = await storeBytes(
        'cleanup-one',
        'one.png',
        pngBytes(30, 20),
      );
      final (second, _) = await storeBytes(
        'cleanup-two',
        'two.png',
        pngBytes(30, 20),
      );
      final firstResult = await thumbnails.generate(first);
      final secondResult = await thumbnails.generate(second);
      final firstWithThumbnail = first.copyWith(
        thumbnailPath: firstResult.path,
      );

      expect(
        await thumbnails.deleteThumbnailForDocument(firstWithThumbnail),
        isTrue,
      );
      expect(await File(firstResult.path!).exists(), isFalse);
      expect(await File(secondResult.path!).exists(), isTrue);
      expect(await thumbnails.deleteThumbnailForDocument(first), isFalse);
    },
  );

  test('text preview reads bounded UTF-8, marks truncation, and handles malformed bytes', () async {
    final file = File('${root.path}${Platform.pathSeparator}text.txt')
      ..writeAsBytesSync(utf8.encode('A😀Z and more content'));
    final service = TextPreviewService(maxBytes: 3);
    final result = await service.preview(file);
    expect(result.isSuccess, isTrue);
    expect(result.truncated, isTrue);
    expect(result.text, contains('�'));
    expect(result.displayText, contains('preview truncated'));

    final full = await TextPreviewService(maxBytes: 100).preview(file);
    expect(full.text, 'A😀Z and more content');
    expect(full.truncated, isFalse);
  });

  test(
    'text preview handles empty, large, missing, and unsupported files',
    () async {
      final empty = File('${root.path}${Platform.pathSeparator}empty.txt')
        ..writeAsBytesSync([]);
      final preview = TextPreviewService(maxBytes: 32);
      final emptyResult = await preview.preview(empty);
      expect(emptyResult.isSuccess, isTrue);
      expect(emptyResult.text, isEmpty);

      final large = File('${root.path}${Platform.pathSeparator}large.txt')
        ..writeAsStringSync('x' * 1000000);
      final largeResult = await preview.preview(large);
      expect(largeResult.truncated, isTrue);
      expect(utf8.encode(largeResult.text).length, lessThanOrEqualTo(32));

      expect(
        (await preview.preview(File('${root.path}/absent.txt'))).errorMessage,
        contains('not found'),
      );
      expect(
        (await preview.preview(File('${root.path}/document.pdf'))).errorMessage,
        contains('TXT'),
      );
    },
  );
}
