import 'dart:io';

import 'package:flutter/services.dart';
import 'package:share_plus/share_plus.dart';

import '../../models/file_record.dart';
import '../storage/file_storage.dart';

enum FileShareStatus {
  /// Android reported that the user selected a share action. Delivery is not
  /// confirmed: the receiving app may still fail or be abandoned.
  actionSelected,

  /// The user dismissed the Android sharesheet without selecting an action.
  dismissed,

  /// The plugin could not determine the user's action on this platform.
  outcomeUnavailable,

  failure,
}

/// Best available outcome of a native file-share request.
class FileShareResult {
  const FileShareResult._({required this.status, this.errorDescription});

  const FileShareResult.actionSelected()
    : this._(status: FileShareStatus.actionSelected);

  const FileShareResult.dismissed() : this._(status: FileShareStatus.dismissed);

  const FileShareResult.outcomeUnavailable()
    : this._(status: FileShareStatus.outcomeUnavailable);

  const FileShareResult.failure(String description)
    : this._(status: FileShareStatus.failure, errorDescription: description);

  final FileShareStatus status;
  final String? errorDescription;

  bool get isFailure => status == FileShareStatus.failure;
}

/// Platform boundary for opening the native share interface with a file path.
abstract interface class FileShareAdapter {
  Future<ShareResultStatus> shareFile({
    required String sourcePath,
    required String fileName,
    required String mimeType,
  });
}

/// Android sharesheet adapter. `share_plus` copies the path to its own cache
/// and shares it using a FileProvider content URI with temporary read grants.
/// Its cache lifecycle is owned by the plugin; this service does not remove
/// those files while another app may still be reading them.
class NativeFileShareAdapter implements FileShareAdapter {
  const NativeFileShareAdapter();

  @override
  Future<ShareResultStatus> shareFile({
    required String sourcePath,
    required String fileName,
    required String mimeType,
  }) async {
    final result = await SharePlus.instance.share(
      ShareParams(
        files: [XFile(sourcePath, mimeType: mimeType)],
        fileNameOverrides: [fileName],
        title: fileName,
      ),
    );
    return result.status;
  }
}

/// Shares an existing, permanent Filo document without changing its library
/// record or source file.
class FileShareService {
  FileShareService({
    required this.fileStorage,
    this.adapter = const NativeFileShareAdapter(),
  });

  final FileStorage fileStorage;
  final FileShareAdapter adapter;

  Future<FileShareResult> shareDocument(FileRecord record) async {
    final source = File(record.localPath);
    try {
      final directories = await fileStorage.initialize();
      if (await FileSystemEntity.type(source.path, followLinks: false) !=
          FileSystemEntityType.file) {
        return const FileShareResult.failure(
          'The managed document is missing or is not a regular file.',
        );
      }

      // FileStorage checks Filo ownership. Restrict sharing further to the
      // permanent documents folder, excluding thumbnail and temporary files.
      final metadata = await fileStorage.getMetadata(source);
      final canonicalRoot = await directories.documents.resolveSymbolicLinks();
      final canonicalSource = await source.resolveSymbolicLinks();
      if (!_isWithin(canonicalSource, canonicalRoot)) {
        return const FileShareResult.failure(
          'Only files in Filo document storage can be shared.',
        );
      }

      final pluginStatus = await adapter.shareFile(
        sourcePath: canonicalSource,
        fileName: metadata.fileName,
        mimeType: _mimeType(metadata.fileName),
      );
      return switch (pluginStatus) {
        ShareResultStatus.success => const FileShareResult.actionSelected(),
        ShareResultStatus.dismissed => const FileShareResult.dismissed(),
        ShareResultStatus.unavailable =>
          const FileShareResult.outcomeUnavailable(),
      };
    } on PlatformException catch (error) {
      final message = switch (error.code) {
        'activity_not_found' =>
          'No Android app is available to receive this document.',
        'file_not_found' => 'The managed document could not be read.',
        _ => 'The document could not be shared. Try again.',
      };
      return FileShareResult.failure(message);
    } on FileStorageException {
      return const FileShareResult.failure(
        'Only existing files in Filo document storage can be shared.',
      );
    } on FileSystemException {
      return const FileShareResult.failure(
        'The managed document could not be read.',
      );
    } catch (_) {
      return const FileShareResult.failure(
        'The document could not be shared. Try again.',
      );
    }
  }

  static bool _isWithin(String path, String root) {
    final normalizedPath = Platform.isWindows ? path.toLowerCase() : path;
    final normalizedRoot = (Platform.isWindows ? root.toLowerCase() : root)
        .replaceFirst(RegExp(r'[/\\]+$'), '');
    return normalizedPath.startsWith(
      '$normalizedRoot${Platform.pathSeparator}',
    );
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
