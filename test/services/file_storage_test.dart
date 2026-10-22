import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:filo/services/storage/file_storage.dart';

void main() {
  late Directory root;
  late FileStorage storage;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('filo_storage_test_');
    storage = FileStorage(
      documentsDirectoryProvider: () async => Directory('${root.path}/appdocs'),
      temporaryDirectoryProvider: () async =>
          Directory('${root.path}/platformtmp'),
    );
  });

  tearDown(() async {
    if (await root.exists()) await root.delete(recursive: true);
  });

  test(
    'initializes private documents, thumbnails and temporary directories',
    () async {
      final directories = await storage.initialize();

      expect(await directories.documents.exists(), isTrue);
      expect(await directories.thumbnails.exists(), isTrue);
      expect(await directories.temporary.exists(), isTrue);
      expect(
        directories.documents.path,
        endsWith('Filo${Platform.pathSeparator}documents'),
      );
      expect(
        directories.temporary.path,
        endsWith('Filo${Platform.pathSeparator}temp'),
      );
    },
  );

  test(
    'imports a copy, preserves its source, and resolves collisions safely',
    () async {
      await storage.initialize();
      final source = File('${root.path}/source.txt');
      await source.writeAsString('original');

      final first = await storage.importFile(source);
      final second = await storage.copyToLibrary(source);

      expect(first.path, endsWith('source.txt'));
      expect(second.path, endsWith('source_1.txt'));
      expect(await source.readAsString(), 'original');
      expect(await first.readAsString(), 'original');
      expect(await second.readAsString(), 'original');
    },
  );

  test('reads metadata and checks existence for managed files', () async {
    await storage.initialize();
    final source = File('${root.path}/note.txt')..writeAsStringSync('hello');
    final stored = await storage.copyToLibrary(source);

    expect(await storage.fileExists(stored), isTrue);
    final metadata = await storage.getMetadata(stored);
    expect(metadata.fileName, 'note.txt');
    expect(metadata.sizeInBytes, 5);
    expect(metadata.modifiedAt, isA<DateTime>());
  });

  test('measures nested managed storage asynchronously and exactly', () async {
    final directories = await storage.initialize();
    File('${directories.documents.path}/saved.txt').writeAsBytesSync([1, 2, 3]);
    final nested = Directory(
      '${directories.temporary.path}${Platform.pathSeparator}work',
    );
    await nested.create();
    File('${nested.path}${Platform.pathSeparator}part.bin')
        .writeAsBytesSync([4, 5]);
    File('${directories.thumbnails.path}${Platform.pathSeparator}thumb.png')
        .writeAsBytesSync([6]);

    final usage = await storage.getManagedStorageUsage();

    expect(usage.documentsBytes, 3);
    expect(usage.temporaryBytes, 2);
    expect(usage.thumbnailBytes, 1);
  });

  test('renames without overwriting existing files', () async {
    await storage.initialize();
    final source = File('${root.path}/source.txt')..writeAsStringSync('source');
    final existing = File('${root.path}/existing.txt')
      ..writeAsStringSync('keep');
    final stored = await storage.copyToLibrary(source);
    final keep = await storage.copyToLibrary(existing);

    final renamed = await storage.renameStoredFile(stored, 'existing.txt');

    expect(renamed.path, endsWith('existing_1.txt'));
    expect(await renamed.readAsString(), 'source');
    expect(await keep.readAsString(), 'keep');
    expect(await stored.exists(), isFalse);
  });

  test(
    'deletes managed files and rejects missing or unmanaged files',
    () async {
      await storage.initialize();
      final source = File('${root.path}/source.txt')
        ..writeAsStringSync('source');
      final stored = await storage.copyToLibrary(source);
      await storage.deleteStoredFile(stored);
      expect(await stored.exists(), isFalse);
      expect(await storage.fileExists(stored), isFalse);
      await expectLater(
        storage.getMetadata(stored),
        throwsA(isA<FileStorageException>()),
      );
      await expectLater(
        storage.deleteStoredFile(source),
        throwsA(isA<FileStorageException>()),
      );
    },
  );

  test('rejects path traversal and invalid filenames', () async {
    await storage.initialize();
    final source = File('${root.path}/source.txt')..writeAsStringSync('safe');

    for (final name in [
      '../escape.txt',
      r'..\escape.txt',
      '/absolute.txt',
      '',
    ]) {
      await expectLater(
        storage.copyToLibrary(source, fileName: name),
        throwsA(isA<FileStorageException>()),
      );
    }
    expect(await File('${root.parent.path}/escape.txt').exists(), isFalse);
    expect(await source.readAsString(), 'safe');
  });

  test(
    'cleans only Filo temporary files and leaves permanent files alone',
    () async {
      final directories = await storage.initialize();
      final source = File('${root.path}/source.txt')
        ..writeAsStringSync('library');
      final permanent = await storage.copyToLibrary(source);
      final temporary = await storage.saveTemporaryFile([
        1,
        2,
        3,
      ], fileName: 'work.bin');
      final unrelated = File('${directories.temporary.path}/other.tmp')
        ..writeAsStringSync('keep');

      expect(await storage.cleanTemporaryFiles(), 1);
      expect(await temporary.exists(), isFalse);
      expect(await unrelated.exists(), isTrue);
      expect(await permanent.readAsString(), 'library');
    },
  );

  test('reports a missing source without creating a stored output', () async {
    final directories = await storage.initialize();
    final missing = File('${root.path}/missing.pdf');

    await expectLater(
      storage.copyToLibrary(missing),
      throwsA(isA<FileStorageException>()),
    );
    expect(await directories.documents.list().isEmpty, isTrue);
  });
}
