import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';

import '../../models/conversion_job.dart';
import '../../models/conversion_type.dart';
import '../storage/file_storage.dart';

enum FileSelectionStatus { selected, cancelled, failure }

/// A picker-neutral file source. Its stream may be backed by an SAF grant or a
/// plugin-managed cache file; callers should consume it while the picker result
/// is valid. The service stages it before returning a workflow-ready path.
class PickerFileSource {
  const PickerFileSource({required this.name, required this.openRead});

  final String name;
  final Stream<Uint8List> Function() openRead;
}

abstract interface class FilePickerAdapter {
  Future<PickerFileSource?> pickSingle(List<String> allowedExtensions);
  Future<List<PickerFileSource>?> pickMultiple(List<String> allowedExtensions);
}

class NativeFilePickerAdapter implements FilePickerAdapter {
  const NativeFilePickerAdapter();

  @override
  Future<PickerFileSource?> pickSingle(List<String> allowedExtensions) async {
    final file = await FilePicker.pickFile(
      type: FileType.custom,
      allowedExtensions: allowedExtensions,
    );
    return file == null ? null : _source(file);
  }

  @override
  Future<List<PickerFileSource>?> pickMultiple(
    List<String> allowedExtensions,
  ) async {
    final files = await FilePicker.pickFiles(
      type: FileType.custom,
      allowedExtensions: allowedExtensions,
    );
    if (files.isEmpty) return null;
    return files.map(_source).toList(growable: false);
  }

  PickerFileSource _source(PlatformFile file) =>
      PickerFileSource(name: file.name, openRead: file.readAsByteStream);
}

/// A validated selection staged in Filo's private temporary input directory.
/// Dispose after the workflow has finished; temporary files are also eligible
/// for FileStorage's reserved-prefix cleanup on a later app launch.
class PickedInputSelection {
  PickedInputSelection._({
    required this.conversionType,
    required this.files,
    required this._cleanup,
  });

  final ConversionType conversionType;
  final List<PickedInputFile> files;
  final Future<void> Function() _cleanup;
  bool _disposed = false;

  List<String> get inputPaths =>
      List.unmodifiable(files.map((file) => file.path));

  ConversionJob createJob({
    required String id,
    String? requestedOutputName,
    String? outputDirectory,
  }) => ConversionJob(
    id: id,
    inputPaths: inputPaths,
    conversionType: conversionType,
    requestedOutputName: requestedOutputName,
    outputDirectory: outputDirectory,
  );

  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    await _cleanup();
  }
}

class PickedInputFile {
  const PickedInputFile({required this.name, required this.path});

  final String name;
  final String path;
}

class FileSelectionResult {
  const FileSelectionResult._({
    required this.status,
    this.selection,
    this.errorDescription,
  });

  factory FileSelectionResult.selected(PickedInputSelection selection) =>
      FileSelectionResult._(
        status: FileSelectionStatus.selected,
        selection: selection,
      );

  const FileSelectionResult.cancelled()
    : this._(status: FileSelectionStatus.cancelled);

  const FileSelectionResult.failure(String description)
    : this._(
        status: FileSelectionStatus.failure,
        errorDescription: description,
      );

  final FileSelectionStatus status;
  final PickedInputSelection? selection;
  final String? errorDescription;
  bool get isSelected => status == FileSelectionStatus.selected;
  bool get isCancelled => status == FileSelectionStatus.cancelled;
}

/// Android system document picker with conversion-aware filters and staged,
/// content-validated temporary inputs. It never registers or deletes sources.
class FilePickerService {
  FilePickerService({
    required this.fileStorage,
    this._adapter = const NativeFilePickerAdapter(),
    this.onManagedStorageChanged,
    String Function()? idGenerator,
  }) : _idGenerator = idGenerator ?? _newId;

  final FileStorage fileStorage;
  final FilePickerAdapter _adapter;
  final void Function()? onManagedStorageChanged;
  final String Function() _idGenerator;

  static List<String> supportedExtensionsFor(ConversionType type) =>
      switch (type) {
        ConversionType.jpgToPng => const ['jpg', 'jpeg'],
        ConversionType.pngToJpg => const ['png'],
        ConversionType.singleImageToPdf ||
        ConversionType.multipleImagesToPdf => const ['jpg', 'jpeg', 'png'],
        ConversionType.txtToPdf => const ['txt'],
        ConversionType.pdfToImages ||
        ConversionType.pdfToTxt ||
        ConversionType.pdfMerge => const ['pdf'],
      };

  Future<FileSelectionResult> selectSingle(ConversionType type) async {
    if (type.requiresMultipleInputs) {
      return FileSelectionResult.failure(
        type == ConversionType.pdfMerge
            ? 'This conversion requires selecting multiple PDF files.'
            : 'This conversion requires selecting multiple images.',
      );
    }
    try {
      final source = await _adapter.pickSingle(supportedExtensionsFor(type));
      if (source == null) return const FileSelectionResult.cancelled();
      return FileSelectionResult.selected(await _stageSources(type, [source]));
    } catch (_) {
      return const FileSelectionResult.failure(
        'The selected file could not be read or validated.',
      );
    }
  }

  Future<FileSelectionResult> selectMultiple(ConversionType type) async {
    if (!type.requiresMultipleInputs) {
      return const FileSelectionResult.failure(
        'This conversion accepts one input file.',
      );
    }
    try {
      final sources = await _adapter.pickMultiple(supportedExtensionsFor(type));
      if (sources == null || sources.isEmpty) {
        return const FileSelectionResult.cancelled();
      }
      if (sources.length < type.minimumInputCount) {
        return FileSelectionResult.failure(
          type == ConversionType.pdfMerge
              ? 'Select at least two PDF files to merge.'
              : 'Select at least two images to create a PDF.',
        );
      }
      return FileSelectionResult.selected(await _stageSources(type, sources));
    } catch (_) {
      return const FileSelectionResult.failure(
        'The selected files could not be read or validated.',
      );
    }
  }

  Future<FileSelectionResult> selectForConversion(ConversionType type) =>
      type.requiresMultipleInputs ? selectMultiple(type) : selectSingle(type);

  Future<PickedInputSelection> _stageSources(
    ConversionType type,
    List<PickerFileSource> sources,
  ) async {
    if (sources.length < type.minimumInputCount) {
      throw const _InvalidSelection();
    }
    final allowed = supportedExtensionsFor(type).toSet();
    final directories = await fileStorage.initialize();
    final staged = <File>[];
    final picked = <PickedInputFile>[];
    try {
      for (final source in sources) {
        final extension = _extension(source.name);
        if (!allowed.contains(extension)) throw const _InvalidSelection();
        final stagedFile = await _copyToTemporary(
          directories.temporary,
          source,
          extension,
        );
        staged.add(stagedFile);
        await _validateContent(stagedFile, extension);
        picked.add(
          PickedInputFile(name: _basename(source.name), path: stagedFile.path),
        );
      }
    } catch (_) {
      await _removeStaged(staged);
      rethrow;
    }
    onManagedStorageChanged?.call();
    return PickedInputSelection._(
      conversionType: type,
      files: List.unmodifiable(picked),
      cleanup: () async {
        try {
          await _removeStaged(staged);
        } finally {
          onManagedStorageChanged?.call();
        }
      },
    );
  }

  Future<File> _copyToTemporary(
    Directory directory,
    PickerFileSource source,
    String extension,
  ) async {
    final name = _safeName(_basename(source.name));
    final stem = name.substring(0, name.length - extension.length - 1);
    final reserved = await _reserve(
      directory,
      'filo_tmp_picker_${_idGenerator()}_$stem.$extension',
    );
    var complete = false;
    final prefix = <int>[];
    try {
      final sink = reserved.openWrite();
      try {
        await for (final chunk in source.openRead()) {
          if (prefix.length < 1024) {
            prefix.addAll(chunk.take(1024 - prefix.length));
          }
          sink.add(chunk);
        }
        await sink.flush();
        await sink.close();
      } catch (_) {
        await sink.close();
        rethrow;
      }
      if (await reserved.length() <= 0) throw const _InvalidSelection();
      await _validateSignature(extension, prefix);
      complete = true;
      return reserved;
    } finally {
      if (!complete) await _deleteOne(reserved);
    }
  }

  Future<void> _validateContent(File file, String extension) async {
    if (extension != 'txt') return;
    // Match TXT-to-PDF's strict UTF-8 expectation without buffering the file.
    await file.openRead().transform(utf8.decoder).drain<void>();
    await for (final chunk in file.openRead()) {
      if (chunk.contains(0)) throw const _InvalidSelection();
    }
  }

  Future<void> _validateSignature(String extension, List<int> prefix) async {
    final valid = switch (extension) {
      'jpg' || 'jpeg' =>
        prefix.length >= 3 &&
            prefix[0] == 0xff &&
            prefix[1] == 0xd8 &&
            prefix[2] == 0xff,
      'png' =>
        prefix.length >= 8 &&
            _bytesEqual(prefix, const [137, 80, 78, 71, 13, 10, 26, 10]),
      'pdf' => _containsBytes(prefix, const [37, 80, 68, 70, 45]),
      'txt' => prefix.isNotEmpty,
      _ => false,
    };
    if (!valid) throw const _InvalidSelection();
  }

  Future<File> _reserve(Directory directory, String requestedName) async {
    final safeName = _safeName(requestedName);
    for (var attempt = 0; attempt < 10000; attempt++) {
      final candidateName = attempt == 0 ? safeName : '${safeName}_$attempt';
      final file = File(
        '${directory.path}${Platform.pathSeparator}$candidateName',
      );
      try {
        return await file.create(exclusive: true);
      } on FileSystemException {
        if (await FileSystemEntity.type(file.path, followLinks: false) ==
            FileSystemEntityType.notFound) {
          rethrow;
        }
      }
    }
    throw const FileSystemException('Temporary input name unavailable.');
  }

  Future<void> _removeStaged(List<File> files) async {
    for (final file in files.reversed) {
      await _deleteOne(file);
    }
  }

  Future<void> _deleteOne(File file) async {
    if (await FileSystemEntity.type(file.path, followLinks: false) ==
        FileSystemEntityType.file) {
      await file.delete();
    }
  }

  static bool _bytesEqual(List<int> bytes, List<int> signature) {
    for (var index = 0; index < signature.length; index++) {
      if (bytes[index] != signature[index]) return false;
    }
    return true;
  }

  static bool _containsBytes(List<int> bytes, List<int> signature) {
    for (var start = 0; start <= bytes.length - signature.length; start++) {
      if (_bytesEqual(bytes.sublist(start), signature)) return true;
    }
    return false;
  }

  static String _extension(String name) {
    final basename = _basename(name);
    final dot = basename.lastIndexOf('.');
    return dot < 1 ? '' : basename.substring(dot + 1).toLowerCase();
  }

  static String _basename(String path) =>
      path.replaceAll('\\', '/').split('/').last;

  static String _safeName(String value) {
    final safe = _basename(value)
        .replaceAll(RegExp(r'[<>:"/\\|?*\x00-\x1f]'), '_')
        .replaceAll(RegExp(r'[. ]+$'), '')
        .trim();
    if (safe.isEmpty || safe == '.' || safe == '..') {
      throw const _InvalidSelection();
    }
    return safe.length <= 120 ? safe : safe.substring(safe.length - 120);
  }

  static String _newId() =>
      '${DateTime.now().microsecondsSinceEpoch}_${Random.secure().nextInt(1 << 32).toRadixString(16)}';
}

class _InvalidSelection implements Exception {
  const _InvalidSelection();
}
