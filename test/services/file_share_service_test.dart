import 'dart:io';

import 'package:filo/models/file_record.dart';
import 'package:filo/services/platform/file_share_service.dart';
import 'package:filo/services/storage/file_storage.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:share_plus/share_plus.dart';

class _FakeShareAdapter implements FileShareAdapter {
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
  late Directory root;
  late FileStorage storage;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('filo_share_test_');
    storage = FileStorage(
      documentsDirectoryProvider: () async => Directory('${root.path}/appdocs'),
      temporaryDirectoryProvider: () async => Directory('${root.path}/cache'),
    );
    await storage.initialize();
  });

  tearDown(() async {
    if (await root.exists()) await root.delete(recursive: true);
  });

  FileRecord recordFor(File file) => FileRecord(
    id: 'doc-${file.uri.pathSegments.last}',
    fileName: file.uri.pathSegments.last,
    extension: file.uri.pathSegments.last.split('.').last,
    sizeInBytes: file.existsSync() ? file.lengthSync() : 0,
    createdAt: DateTime.utc(2026, 1),
    localPath: file.path,
  );

  Future<File> store(String name, List<int> bytes) async {
    final source = File('${root.path}/$name')..writeAsBytesSync(bytes);
    return storage.copyToLibrary(source);
  }

  test(
    'shares managed documents with correct MIME types and filenames',
    () async {
      final cases = <(String, String)>[
        ('report.pdf', 'application/pdf'),
        ('photo.jpg', 'image/jpeg'),
        ('photo.jpeg', 'image/jpeg'),
        ('scan.png', 'image/png'),
        ('notes.txt', 'text/plain'),
      ];
      final adapter = _FakeShareAdapter();
      final service = FileShareService(fileStorage: storage, adapter: adapter);

      for (final (name, mime) in cases) {
        final managed = await store(name, [1, 2, 3, 4]);
        final original = await managed.readAsBytes();
        final result = await service.shareDocument(recordFor(managed));

        expect(result.status, FileShareStatus.actionSelected);
        expect(result.errorDescription, isNull);
        expect(adapter.sourcePath, await managed.resolveSymbolicLinks());
        expect(adapter.fileName, name);
        expect(adapter.mimeType, mime);
        expect(await managed.readAsBytes(), original);
      }
    },
  );

  test(
    'rejects a missing file and a directory before invoking native share',
    () async {
      final adapter = _FakeShareAdapter();
      final service = FileShareService(fileStorage: storage, adapter: adapter);
      final missing = File('${root.path}/appdocs/documents/missing.pdf');
      final missingResult = await service.shareDocument(recordFor(missing));
      expect(missingResult.status, FileShareStatus.failure);
      expect(missingResult.errorDescription, isNot(contains(root.path)));
      expect(adapter.sourcePath, isNull);

      final directory = Directory('${root.path}/appdocs/documents/folder')
        ..createSync(recursive: true);
      final directoryResult = await service.shareDocument(
        recordFor(File(directory.path)),
      );
      expect(directoryResult.status, FileShareStatus.failure);
      expect(adapter.sourcePath, isNull);
    },
  );

  test('rejects unmanaged and temporary files', () async {
    final adapter = _FakeShareAdapter();
    final service = FileShareService(fileStorage: storage, adapter: adapter);
    final outside = File('${root.path}/private.txt')
      ..writeAsStringSync('secret');
    final outsideResult = await service.shareDocument(recordFor(outside));
    expect(outsideResult.status, FileShareStatus.failure);
    expect(adapter.sourcePath, isNull);

    final temporary = await storage.saveTemporaryFile([
      1,
    ], fileName: 'filo_tmp_work.txt');
    final temporaryResult = await service.shareDocument(recordFor(temporary));
    expect(temporaryResult.status, FileShareStatus.failure);
    expect(adapter.sourcePath, isNull);
  });

  test(
    'maps dismissal and unavailable outcomes without claiming delivery',
    () async {
      final managed = await store('report.pdf', [1, 2, 3]);
      final adapter = _FakeShareAdapter();
      final service = FileShareService(fileStorage: storage, adapter: adapter);

      adapter.status = ShareResultStatus.dismissed;
      expect(
        (await service.shareDocument(recordFor(managed))).status,
        FileShareStatus.dismissed,
      );

      adapter.status = ShareResultStatus.unavailable;
      final unavailable = await service.shareDocument(recordFor(managed));
      expect(unavailable.status, FileShareStatus.outcomeUnavailable);
      expect(unavailable.isFailure, isFalse);
    },
  );

  test('sanitizes plugin failures and preserves the source', () async {
    final bytes = [37, 80, 68, 70, 45, 49];
    final managed = await store('private-name.pdf', bytes);
    final adapter = _FakeShareAdapter()
      ..error = PlatformException(
        code: 'native_error',
        message: 'failure at ${managed.path}',
      );
    final result = await FileShareService(
      fileStorage: storage,
      adapter: adapter,
    ).shareDocument(recordFor(managed));

    expect(result.status, FileShareStatus.failure);
    expect(result.errorDescription, isNot(contains(managed.path)));
    expect(result.errorDescription, isNot(contains('native_error')));
    expect(await managed.readAsBytes(), bytes);
  });
}
