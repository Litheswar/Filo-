import 'dart:io';
import 'dart:typed_data';

import 'package:filo/models/conversion_type.dart';
import 'package:filo/services/platform/file_picker_service.dart';
import 'package:filo/services/storage/file_storage.dart';
import 'package:flutter_test/flutter_test.dart';

class _FakePicker implements FilePickerAdapter {
  _FakePicker({this.single, this.multiple, this.error});

  PickerFileSource? single;
  List<PickerFileSource>? multiple;
  Object? error;
  List<String>? requestedExtensions;

  @override
  Future<PickerFileSource?> pickSingle(List<String> allowedExtensions) async {
    requestedExtensions = allowedExtensions;
    if (error != null) throw error!;
    return single;
  }

  @override
  Future<List<PickerFileSource>?> pickMultiple(
    List<String> allowedExtensions,
  ) async {
    requestedExtensions = allowedExtensions;
    if (error != null) throw error!;
    return multiple;
  }
}

PickerFileSource source(String name, List<int> bytes) => PickerFileSource(
  name: name,
  openRead: () => Stream.value(Uint8List.fromList(bytes)),
);

void main() {
  late Directory root;
  late FileStorage storage;
  var id = 0;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('filo_picker_test_');
    storage = FileStorage(
      documentsDirectoryProvider: () async => Directory('${root.path}/docs'),
      temporaryDirectoryProvider: () async => Directory('${root.path}/cache'),
    );
    id = 0;
  });

  tearDown(() async {
    if (await root.exists()) await root.delete(recursive: true);
  });

  FilePickerService service(_FakePicker picker) => FilePickerService(
    fileStorage: storage,
    adapter: picker,
    idGenerator: () => 'test-${id++}',
  );

  test(
    'single selection is validated, staged, and builds a ConversionJob',
    () async {
      final picker = _FakePicker(
        single: source('photo.JPG', [0xff, 0xd8, 0xff, 0x01]),
      );
      final result = await service(picker)
          .selectSingle(ConversionType.jpgToPng);

      expect(result.status, FileSelectionStatus.selected);
      expect(picker.requestedExtensions, ['jpg', 'jpeg']);
      final selection = result.selection!;
      expect(selection.files.single.name, 'photo.JPG');
      expect(await File(selection.inputPaths.single).readAsBytes(), [
        0xff,
        0xd8,
        0xff,
        1,
      ]);
      expect(selection.inputPaths.single, contains('filo_tmp_picker_'));
      final job = selection.createJob(id: 'picked-job');
      expect(job.conversionType, ConversionType.jpgToPng);
      expect(job.inputPaths, selection.inputPaths);
      await selection.dispose();
      expect(await File(selection.inputPaths.single).exists(), isFalse);
    },
  );

  test(
    'multiple image selection preserves picker order and cleans staged inputs',
    () async {
      final picker = _FakePicker(
        multiple: [
          source('first.png', [137, 80, 78, 71, 13, 10, 26, 10, 1]),
          source('second.jpeg', [0xff, 0xd8, 0xff, 2]),
        ],
      );
      final result = await service(picker)
          .selectMultiple(ConversionType.multipleImagesToPdf);
      expect(result.isSelected, isTrue);
      expect(picker.requestedExtensions, ['jpg', 'jpeg', 'png']);
      final selection = result.selection!;
      expect(selection.files.map((item) => item.name), [
        'first.png',
        'second.jpeg',
      ]);
      expect(
        selection.createJob(id: 'ordered').inputPaths,
        selection.inputPaths,
      );
      await selection.dispose();
      expect(
        await Future.wait(
          selection.inputPaths.map(File.new).map((f) => f.exists()),
        ),
        everyElement(isFalse),
      );
    },
  );

  test('conversion type mappings cover all supported operations', () {
    expect(FilePickerService.supportedExtensionsFor(ConversionType.jpgToPng), [
      'jpg',
      'jpeg',
    ]);
    expect(FilePickerService.supportedExtensionsFor(ConversionType.pngToJpg), [
      'png',
    ]);
    expect(
      FilePickerService.supportedExtensionsFor(ConversionType.singleImageToPdf),
      ['jpg', 'jpeg', 'png'],
    );
    expect(
      FilePickerService.supportedExtensionsFor(
        ConversionType.multipleImagesToPdf,
      ),
      ['jpg', 'jpeg', 'png'],
    );
    expect(FilePickerService.supportedExtensionsFor(ConversionType.txtToPdf), [
      'txt',
    ]);
    expect(
      FilePickerService.supportedExtensionsFor(ConversionType.pdfToImages),
      ['pdf'],
    );
    expect(FilePickerService.supportedExtensionsFor(ConversionType.pdfToTxt), [
      'pdf',
    ]);
    expect(FilePickerService.supportedExtensionsFor(ConversionType.pdfMerge), [
      'pdf',
    ]);
  });

  test('cancellation is distinct from failure and creates no files', () async {
    final result = await service(_FakePicker())
        .selectSingle(ConversionType.pdfToTxt);
    expect(result.status, FileSelectionStatus.cancelled);
    expect(result.errorDescription, isNull);
    expect(await Directory('${root.path}/cache/Filo/temp').exists(), isFalse);
  });

  test('picker errors, unsupported extensions, and empty results are handled safely', () async {
    final failed = await service(_FakePicker(error: StateError('secret path')))
        .selectSingle(ConversionType.pdfToTxt);
    expect(failed.status, FileSelectionStatus.failure);
    expect(failed.errorDescription, isNot(contains(root.path)));

    final unsupported = await service(
      _FakePicker(single: source('renamed.pdf', [0xff, 0xd8, 0xff])),
    ).selectSingle(ConversionType.pdfToTxt);
    expect(unsupported.status, FileSelectionStatus.failure);

    final empty = await service(_FakePicker(multiple: []))
        .selectMultiple(ConversionType.multipleImagesToPdf);
    expect(empty.status, FileSelectionStatus.cancelled);
  });

  test('renamed content and unreadable or empty inputs are rejected', () async {
    final forged = await service(
      _FakePicker(single: source('fake.png', [0xff, 0xd8, 0xff, 0x00])),
    ).selectSingle(ConversionType.pngToJpg);
    expect(forged.status, FileSelectionStatus.failure);

    final unreadable = await service(
      _FakePicker(
        single: PickerFileSource(
          name: 'broken.pdf',
          openRead: () => Stream.error(const FileSystemException('unreadable')),
        ),
      ),
    ).selectSingle(ConversionType.pdfToImages);
    expect(unreadable.status, FileSelectionStatus.failure);

    final empty = await service(_FakePicker(single: source('empty.jpg', [])))
        .selectSingle(ConversionType.jpgToPng);
    expect(empty.status, FileSelectionStatus.failure);
  });

  test('TXT inputs are checked as streaming UTF-8 without buffering', () async {
    final valid = await service(
      _FakePicker(single: source('note.txt', [104, 105, 10])),
    ).selectSingle(ConversionType.txtToPdf);
    expect(valid.isSelected, isTrue);
    await valid.selection!.dispose();

    final invalid = await service(
      _FakePicker(single: source('binary.txt', [0xff, 0xfe, 0x00])),
    ).selectSingle(ConversionType.txtToPdf);
    expect(invalid.status, FileSelectionStatus.failure);
  });

  test(
    'single and multiple operations reject mismatched conversion cardinality',
    () async {
      expect(
        (await service(_FakePicker())
                .selectSingle(ConversionType.multipleImagesToPdf))
            .status,
        FileSelectionStatus.failure,
      );
      expect(
        (await service(_FakePicker()).selectMultiple(ConversionType.pdfToTxt))
            .status,
        FileSelectionStatus.failure,
      );
      final onePdf = await service(
        _FakePicker(
          multiple: [
            source('one.pdf', [37, 80, 68, 70, 45, 49]),
          ],
        ),
      ).selectMultiple(ConversionType.pdfMerge);
      expect(onePdf.status, FileSelectionStatus.failure);
      expect(onePdf.errorDescription, contains('at least two'));
      final oneImage = await service(
        _FakePicker(
          multiple: [
            source('one.jpg', [0xff, 0xd8, 0xff]),
          ],
        ),
      ).selectMultiple(ConversionType.multipleImagesToPdf);
      expect(oneImage.status, FileSelectionStatus.failure);
      expect(oneImage.errorDescription, contains('at least two images'));
    },
  );

  test(
    'PDF merge staging validates and preserves the selected PDF order',
    () async {
      final picker = _FakePicker(
        multiple: [
          source('first.pdf', [37, 80, 68, 70, 45, 49, 1]),
          source('second.pdf', [37, 80, 68, 70, 45, 49, 2]),
        ],
      );
      final result = await service(picker)
          .selectMultiple(ConversionType.pdfMerge);

      expect(result.isSelected, isTrue);
      expect(picker.requestedExtensions, ['pdf']);
      expect(result.selection!.files.map((file) => file.name), [
        'first.pdf',
        'second.pdf',
      ]);
      await result.selection!.dispose();
    },
  );
}
