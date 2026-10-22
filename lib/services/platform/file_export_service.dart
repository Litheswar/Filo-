import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_file_dialog/flutter_file_dialog.dart';

import '../../models/file_record.dart';
import '../storage/file_storage.dart';

enum FileExportStatus { success, cancelled, failure }

/// Platform-neutral interface for the native save operation.
abstract interface class FileExportAdapter {
  Future<String?> saveFile({
    required String sourcePath,
    required String fileName,
    required String mimeType,
  });
}

/// Android SAF implementation backed by ACTION_CREATE_DOCUMENT.
class NativeFileExportAdapter implements FileExportAdapter {
  const NativeFileExportAdapter();

  @override
  Future<String?> saveFile({
    required String sourcePath,
    required String fileName,
    required String mimeType,
  }) => FlutterFileDialog.saveFile(
    params: SaveFileDialogParams(
      sourceFilePath: sourcePath,
      fileName: fileName,
      mimeTypesFilter: [mimeType],
    ),
  );
}

class FileExportResult {
  const FileExportResult._({
    required this.status,
    this.destinationReference,
    this.errorDescription,
    this.partialDestinationMayRemain = false,
  });

  const FileExportResult.success(String destinationReference)
    : this._(
        status: FileExportStatus.success,
        destinationReference: destinationReference,
      );

  const FileExportResult.cancelled()
    : this._(status: FileExportStatus.cancelled);

  const FileExportResult.failure(
    String description, {
    bool partialDestinationMayRemain = false,
  }) : this._(
         status: FileExportStatus.failure,
         errorDescription: description,
         partialDestinationMayRemain: partialDestinationMayRemain,
       );

  final FileExportStatus status;

  /// Opaque result returned by the platform plugin. Do not treat it as a local
  /// path or persist it as managed document metadata.
  final String? destinationReference;
  final String? errorDescription;

  /// The SAF provider owns the new destination; the plugin cannot safely
  /// delete it if a copy is interrupted after the user confirms the location.
  final bool partialDestinationMayRemain;

  bool get isSuccess => status == FileExportStatus.success;
  bool get isCancelled => status == FileExportStatus.cancelled;
}

/// Exports a validated Filo document through the platform's save interface.
/// Export is a copy operation and never adds or changes library records.
class FileExportService {
  FileExportService({
    required this.fileStorage,
    this._adapter = const NativeFileExportAdapter(),
  });

  final FileStorage fileStorage;
  final FileExportAdapter _adapter;

  Future<FileExportResult> exportDocument(FileRecord record) async {
    final File source = File(record.localPath);
    try {
      final directories = await fileStorage.initialize();
      if (await FileSystemEntity.type(source.path, followLinks: false) !=
          FileSystemEntityType.file) {
        return const FileExportResult.failure(
          'The managed document is missing or is not a regular file.',
        );
      }

      // FileStorage verifies that the file is within Filo-managed storage. The
      // second check narrows that to permanent documents, not thumbnails/temp.
      final metadata = await fileStorage.getMetadata(source);
      final canonicalRoot = await directories.documents.resolveSymbolicLinks();
      final canonicalSource = await source.resolveSymbolicLinks();
      if (!_isWithin(canonicalSource, canonicalRoot)) {
        return const FileExportResult.failure(
          'Only files in Filo document storage can be exported.',
        );
      }
      final destination = await _adapter.saveFile(
        sourcePath: canonicalSource,
        fileName: metadata.fileName,
        mimeType: _mimeType(metadata.fileName),
      );
      if (destination == null) return const FileExportResult.cancelled();
      return FileExportResult.success(destination);
    } on PlatformException catch (error) {
      final message = switch (error.code) {
        'activity_not_found' =>
          'No Android document provider is available to save this file.',
        'file_not_found' => 'The managed document could not be read.',
        'security_exception' =>
          'The selected destination is not accessible for writing.',
        _ => 'The document could not be exported. Check the destination and try again.',
      };
      return FileExportResult.failure(
        message,
        partialDestinationMayRemain:
            error.code != 'activity_not_found' &&
            error.code != 'file_not_found' &&
            error.code != 'invalid_arguments',
      );
    } on FileStorageException {
      return const FileExportResult.failure(
        'Only existing files in Filo document storage can be exported.',
      );
    } on FileSystemException {
      return const FileExportResult.failure(
        'The managed document could not be read.',
      );
    } catch (_) {
      return const FileExportResult.failure(
        'The document could not be exported. Check the destination and try again.',
        partialDestinationMayRemain: true,
      );
    }
  }

  static bool _isWithin(String path, String root) {
    final separator = Platform.pathSeparator;
    final normalizedPath = Platform.isWindows ? path.toLowerCase() : path;
    final normalizedRoot = (Platform.isWindows ? root.toLowerCase() : root)
        .replaceFirst(RegExp(r'[/\\]+$'), '');
    return normalizedPath.startsWith('$normalizedRoot$separator');
  }

  static String _mimeType(String fileName) {
    final dot = fileName.lastIndexOf('.');
    final extension = dot < 0 ? '' : fileName.substring(dot + 1).toLowerCase();
    return switch (extension) {
      'pdf' => 'application/pdf',
      'jpg' || 'jpeg' => 'image/jpeg',
      'png' => 'image/png',
      'txt' => 'text/plain',
      _ => 'application/octet-stream',
    };
  }
}
