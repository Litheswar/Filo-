import 'dart:io';

import 'package:filo/models/file_record.dart';
import 'package:filo/services/platform/file_export_service.dart';
import 'package:filo/services/storage/file_storage.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

class _FakeExportAdapter implements FileExportAdapter {
  String? response = 'content://provider/document/123';
  Object? error;
  String? sourcePath;
  String? fileName;
  String? mimeType;
  File? destinationFile;
  bool writePartialBeforeError = false;

  @override
  Future<String?> saveFile({
    required String sourcePath,
    required String fileName,
    required String mimeType,
  }) async {
    this.sourcePath = sourcePath;
    this.fileName = fileName;
    this.mimeType = mimeType;
    final destination = destinationFile;
    if (destination != null && (error == null || writePartialBeforeError)) {
      final sink = destination.openWrite();
      final source = File(sourcePath);
      if (error != null) {
        await sink.addStream(source.openRead(0, 32));
      } else {
        await sink.addStream(source.openRead());
      }
      await sink.flush();
      await sink.close();
    }
    if (error != null) throw error!;
    return response;
  }
}

void main() {
  late Directory root;
  late FileStorage storage;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('filo_export_test_');
    storage = FileStorage(
      documentsDirectoryProvider: () async => Directory('${root.path}/appdocs'),
      temporaryDirectoryProvider: () async => Directory('${root.path}/cache'),
    );
    await storage.initialize();
  });

  tearDown(() async {
    if (await root.exists()) await root.delete(recursive: true);
  });

  FileRecord recordFor(File file, {String? id}) => FileRecord(
    id: id ?? 'doc-${file.uri.pathSegments.last}',
    fileName: file.uri.pathSegments.last,
    extension: file.uri.pathSegments.last.split('.').last,
    sizeInBytes: file.existsSync() ? file.lengthSync() : 0,
    createdAt: DateTime.utc(2026, 1),
    localPath: file.path,
  );

  Future<File> store(String name, List<int> data) async {
    final source = File('${root.path}/$name')..writeAsBytesSync(data);
    return storage.copyToLibrary(source);
  }

  test(
    'exports a managed file by stream with its original name and MIME type',
    () async {
      final managed = await store('report.pdf', [37, 80, 68, 70, 45, 49]);
      final destination = File('${root.path}/exported.pdf');
      final adapter = _FakeExportAdapter()..destinationFile = destination;

      final result = await FileExportService(
        fileStorage: storage,
        adapter: adapter,
      ).exportDocument(recordFor(managed));

      expect(result.status, FileExportStatus.success);
      expect(result.destinationReference, 'content://provider/document/123');
      expect(adapter.sourcePath, managed.resolveSymbolicLinksSync());
      expect(adapter.fileName, 'report.pdf');
      expect(adapter.mimeType, 'application/pdf');
      expect(await destination.readAsBytes(), [37, 80, 68, 70, 45, 49]);
      expect(await managed.readAsBytes(), [37, 80, 68, 70, 45, 49]);
      expect(
        result.destinationReference,
        isNot(contains(storage.appDirectoryName)),
      );
    },
  );

  test('preserves extension for image and text export suggestions', () async {
    final jpg = await store('photo.jpeg', [0xff, 0xd8, 0xff]);
    final adapter = _FakeExportAdapter();
    await FileExportService(
      fileStorage: storage,
      adapter: adapter,
    ).exportDocument(recordFor(jpg));
    expect(adapter.fileName, 'photo.jpeg');
    expect(adapter.mimeType, 'image/jpeg');

    final txt = await store('notes.txt', [110, 111, 116, 101]);
    await FileExportService(
      fileStorage: storage,
      adapter: adapter,
    ).exportDocument(recordFor(txt));
    expect(adapter.fileName, 'notes.txt');
    expect(adapter.mimeType, 'text/plain');
  });

  test('cancellation is distinct and leaves the managed file intact', () async {
    final managed = await store('keep.txt', [107, 101, 101, 112]);
    final result = await FileExportService(
      fileStorage: storage,
      adapter: _FakeExportAdapter()..response = null,
    ).exportDocument(recordFor(managed));

    expect(result.status, FileExportStatus.cancelled);
    expect(result.errorDescription, isNull);
    expect(await managed.readAsBytes(), [107, 101, 101, 112]);
  });

  test(
    'missing and unmanaged source paths are rejected before opening picker',
    () async {
      final adapter = _FakeExportAdapter();
      final service = FileExportService(fileStorage: storage, adapter: adapter);
      final absent = File('${root.path}/Filo/documents/missing.pdf');
      final missingResult = await service.exportDocument(recordFor(absent));
      expect(missingResult.status, FileExportStatus.failure);
      expect(adapter.sourcePath, isNull);

      final outside = File('${root.path}/private.txt')
        ..writeAsStringSync('private');
      final outsideResult = await service.exportDocument(recordFor(outside));
      expect(outsideResult.status, FileExportStatus.failure);
      expect(adapter.sourcePath, isNull);
    },
  );

  test(
    'temporary managed files are not exportable as library documents',
    () async {
      final temporary = await storage.saveTemporaryFile([
        1,
      ], fileName: 'filo_tmp_work.txt');
      final adapter = _FakeExportAdapter();
      final result = await FileExportService(
        fileStorage: storage,
        adapter: adapter,
      ).exportDocument(recordFor(temporary));
      expect(result.status, FileExportStatus.failure);
      expect(adapter.sourcePath, isNull);
    },
  );

  test('reports provider failure and possible partial destination without changing source', () async {
    final sourceBytes = List<int>.generate(128, (index) => index);
    final managed = await store('failure.pdf', sourceBytes);
    final partialDestination = File('${root.path}/partial.pdf');
    final adapter = _FakeExportAdapter()
      ..destinationFile = partialDestination
      ..writePartialBeforeError = true
      ..error = PlatformException(code: 'save_file_failed');
    final result = await FileExportService(
      fileStorage: storage,
      adapter: adapter,
    ).exportDocument(recordFor(managed));

    expect(result.status, FileExportStatus.failure);
    expect(result.errorDescription, isNotEmpty);
    expect(result.partialDestinationMayRemain, isTrue);
    expect(await partialDestination.length(), greaterThan(0));
    expect(await partialDestination.length(), lessThan(await managed.length()));
    expect(await managed.readAsBytes(), sourceBytes);
  });

  test(
    'streams a large document and leaves destination collision policy to SAF',
    () async {
      final data = List<int>.generate(3 * 1024 * 1024, (index) => index % 251);
      final managed = await store('large.bin', data);
      final destination = File('${root.path}/large(1).bin');
      final adapter = _FakeExportAdapter()..destinationFile = destination;
      final service = FileExportService(fileStorage: storage, adapter: adapter);

      // Simulate a provider that resolves a same-name save by choosing a new
      // destination. The service never opens or truncates a destination itself.
      final result = await service.exportDocument(recordFor(managed));

      expect(result.isSuccess, isTrue);
      expect(await destination.length(), data.length);
      expect(await managed.length(), data.length);
      expect(adapter.fileName, 'large.bin');
    },
  );
}
