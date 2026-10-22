import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:image/image.dart' as img;
import 'package:pdfrx/pdfrx.dart' as pdfrx;

import '../../models/file_record.dart';
import '../storage/file_storage.dart';

class ThumbnailResult {
  const ThumbnailResult._({
    required this.isSuccess,
    this.path,
    this.errorMessage,
    this.reused = false,
  });

  factory ThumbnailResult.success(String path, {bool reused = false}) =>
      ThumbnailResult._(isSuccess: true, path: path, reused: reused);

  factory ThumbnailResult.failure(String message) =>
      ThumbnailResult._(isSuccess: false, errorMessage: message);

  final bool isSuccess;
  final String? path;
  final String? errorMessage;
  final bool reused;
}

/// Generates small local PNG previews for managed JPG, PNG, and PDF documents.
///
/// Pass the library manager's [updateRecord] as the optional persistence
/// callback to keep [FileRecord.thumbnailPath] current. The service has no
/// database dependency and never changes documents.
class ThumbnailService {
  ThumbnailService({
    required this.fileStorage,
    this.maxDimension = 320,
    this.maxSourceBytes = 64 * 1024 * 1024,
  }) {
    if (maxDimension < 32 || maxDimension > 2048) {
      throw ArgumentError.value(maxDimension, 'maxDimension');
    }
    if (maxSourceBytes < 1) {
      throw ArgumentError.value(maxSourceBytes, 'maxSourceBytes');
    }
  }

  final FileStorage fileStorage;
  final int maxDimension;
  final int maxSourceBytes;
  final Map<String, Future<ThumbnailResult>> _inFlight = {};

  /// Uses a safe identity/stat-based cache key and only renders a PDF's first page.
  Future<ThumbnailResult> generate(
    FileRecord record, {
    Future<bool> Function(FileRecord updatedRecord)? updateRecord,
  }) async {
    final extension = record.extension.toLowerCase();
    if (!const {'jpg', 'jpeg', 'png', 'pdf'}.contains(extension)) {
      return ThumbnailResult.failure(
        'Thumbnails are unsupported for this file type.',
      );
    }

    final source = File(record.localPath);
    final StoredFileMetadata sourceMetadata;
    try {
      sourceMetadata = await fileStorage.getMetadata(source);
    } on FileStorageException {
      return ThumbnailResult.failure(
        'The document is missing or is not managed by Filo.',
      );
    }
    if (sourceMetadata.sizeInBytes == 0) {
      return ThumbnailResult.failure('The document is empty.');
    }
    if (sourceMetadata.sizeInBytes > maxSourceBytes) {
      return ThumbnailResult.failure(
        'The document exceeds the thumbnail input size limit.',
      );
    }

    final key = _cacheKey(record.id, sourceMetadata, extension);
    final cachedPath = record.thumbnailPath;
    if (cachedPath != null && _cacheNameMatches(cachedPath, key)) {
      try {
        if (await fileStorage.thumbnailExists(File(cachedPath))) {
          if (await _isValidThumbnail(File(cachedPath))) {
            return await _persistThumbnailPath(
              record,
              ThumbnailResult.success(cachedPath, reused: true),
              updateRecord,
            );
          }
          await fileStorage.deleteThumbnail(File(cachedPath));
        }
      } on FileSystemException {
        // A stale cache entry is regenerated below.
      } on FileStorageException {
        // A cache pointer outside thumbnail storage is never trusted or deleted.
      }
    }
    if (cachedPath != null && !_cacheNameMatches(cachedPath, key)) {
      try {
        await deleteThumbnailForDocument(record);
      } on FileStorageException {
        // Ignore stale or foreign pointers; never remove an unverified path.
      } on FileSystemException {
        // Treat an inaccessible stale cache as unavailable.
      }
    }

    try {
      final existing = await _findExpectedThumbnail(key);
      if (existing != null) {
        if (await _isValidThumbnail(existing)) {
          return await _persistThumbnailPath(
            record,
            ThumbnailResult.success(existing.path, reused: true),
            updateRecord,
          );
        }
        await fileStorage.deleteThumbnail(existing);
      }
    } on FileStorageException {
      return ThumbnailResult.failure('Filo thumbnail storage is unavailable.');
    } on FileSystemException {
      return ThumbnailResult.failure('Filo thumbnail storage is unavailable.');
    }

    final pending = _inFlight[key];
    if (pending != null) {
      return _persistThumbnailPath(record, await pending, updateRecord);
    }
    final generation = _generate(source, sourceMetadata, key, extension);
    _inFlight[key] = generation;
    try {
      return await _persistThumbnailPath(
        record,
        await generation,
        updateRecord,
      );
    } finally {
      if (identical(_inFlight[key], generation)) _inFlight.remove(key);
    }
  }

  /// Removes this document's referenced thumbnail without touching another
  /// document's cache entry or any path outside Filo's thumbnail folder.
  /// Call before deleting the document record/file when a thumbnail path is set.
  Future<bool> deleteThumbnailForDocument(FileRecord record) async {
    final path = record.thumbnailPath;
    if (path == null) return false;
    final documentPrefix = 'thumb_${_documentIdKey(record.id)}_';
    final basename = File(path).uri.pathSegments.last;
    if (!basename.startsWith(documentPrefix) ||
        !basename.toLowerCase().endsWith('.png')) {
      return false;
    }
    final file = File(path);
    if (!await fileStorage.thumbnailExists(file)) return false;
    await fileStorage.deleteThumbnail(file);
    return true;
  }

  Future<ThumbnailResult> _generate(
    File source,
    StoredFileMetadata originalMetadata,
    String key,
    String extension,
  ) async {
    File? output;
    var completed = false;
    pdfrx.PdfDocument? document;
    pdfrx.PdfImage? renderedPage;
    try {
      Uint8List pngBytes;
      if (extension == 'pdf') {
        document = await pdfrx.PdfDocument.openFile(source.path);
        if (document.pages.isEmpty) {
          return ThumbnailResult.failure('PDF contains no pages.');
        }
        final page = document.pages.first;
        final scale = math.min(
          1.0,
          math.min(
            maxDimension / math.max(1.0, page.width),
            maxDimension / math.max(1.0, page.height),
          ),
        );
        final width = math.max(1, (page.width * scale).round());
        final height = math.max(1, (page.height * scale).round());
        renderedPage = await page.render(width: width, height: height);
        if (renderedPage == null || renderedPage.pixels.isEmpty) {
          return ThumbnailResult.failure(
            'The first PDF page could not be rendered.',
          );
        }
        final preview = img.Image.fromBytes(
          width: renderedPage.width,
          height: renderedPage.height,
          bytes: renderedPage.pixels.buffer,
          order: img.ChannelOrder.rgba,
          numChannels: 4,
        );
        pngBytes = Uint8List.fromList(img.encodePng(preview));
      } else {
        final bytes = await source.readAsBytes();
        if (!_matchesImageSignature(bytes, extension)) {
          return ThumbnailResult.failure(
            'Image content does not match its filename extension.',
          );
        }
        final decoded = img.decodeImage(bytes);
        if (decoded == null) {
          return ThumbnailResult.failure(
            'Image data is invalid or unsupported.',
          );
        }
        final largestSide = math.max(decoded.width, decoded.height);
        final preview = largestSide <= maxDimension
            ? decoded
            : img.copyResize(
                decoded,
                width: (decoded.width * maxDimension / largestSide)
                    .round()
                    .clamp(1, maxDimension)
                    .toInt(),
                height: (decoded.height * maxDimension / largestSide)
                    .round()
                    .clamp(1, maxDimension)
                    .toInt(),
              );
        pngBytes = Uint8List.fromList(img.encodePng(preview));
      }

      final currentMetadata = await fileStorage.getMetadata(source);
      if (currentMetadata.sizeInBytes != originalMetadata.sizeInBytes ||
          currentMetadata.modifiedAt != originalMetadata.modifiedAt) {
        return ThumbnailResult.failure(
          'The document changed during thumbnail generation.',
        );
      }

      output = await fileStorage.createThumbnailFile('thumb_$key.png');
      await output.writeAsBytes(pngBytes, flush: true);
      final verificationBytes = await output.readAsBytes();
      final verificationImage = img.decodePng(verificationBytes);
      if (verificationImage == null ||
          verificationImage.width > maxDimension ||
          verificationImage.height > maxDimension ||
          verificationImage.width < 1 ||
          verificationImage.height < 1) {
        throw const FormatException('Thumbnail verification failed.');
      }
      completed = true;
      return ThumbnailResult.success(output.path);
    } on pdfrx.PdfPasswordException {
      return ThumbnailResult.failure(
        'Password-protected PDFs cannot be previewed.',
      );
    } catch (_) {
      return ThumbnailResult.failure('Thumbnail generation failed.');
    } finally {
      renderedPage?.dispose();
      try {
        await document?.dispose();
      } catch (_) {
        // Resource cleanup is best-effort; generated output has been verified.
      }
      if (output != null && !completed) {
        try {
          await fileStorage.deleteThumbnail(output);
        } on FileStorageException {
          // Best-effort cleanup of an output reserved by this request.
        }
      }
    }
  }

  Future<File?> _findExpectedThumbnail(String key) async {
    final directories = await fileStorage.initialize();
    final file = File(
      '${directories.thumbnails.path}${Platform.pathSeparator}thumb_$key.png',
    );
    return await fileStorage.thumbnailExists(file) ? file : null;
  }

  Future<bool> _isValidThumbnail(File file) async {
    try {
      final length = await file.length();
      if (length == 0 || length > 8 * 1024 * 1024) return false;
      final decoded = img.decodePng(await file.readAsBytes());
      return decoded != null &&
          decoded.width > 0 &&
          decoded.height > 0 &&
          decoded.width <= maxDimension &&
          decoded.height <= maxDimension;
    } on FileSystemException {
      return false;
    } catch (_) {
      return false;
    }
  }

  Future<ThumbnailResult> _persistThumbnailPath(
    FileRecord record,
    ThumbnailResult result,
    Future<bool> Function(FileRecord updatedRecord)? updateRecord,
  ) async {
    if (!result.isSuccess ||
        updateRecord == null ||
        record.thumbnailPath == result.path) {
      return result;
    }
    try {
      final updated = record.copyWith(thumbnailPath: result.path);
      if (await updateRecord(updated)) return result;
    } catch (_) {
      // Report the persistence failure without claiming the record was updated.
    }
    return ThumbnailResult.failure(
      'Thumbnail was generated but its library metadata could not be updated.',
    );
  }

  String _cacheKey(String id, StoredFileMetadata metadata, String extension) {
    final idKey = _documentIdKey(id);
    final modified = metadata.modifiedAt.microsecondsSinceEpoch;
    return '${idKey}_${extension}_${metadata.sizeInBytes}_$modified';
  }

  String _documentIdKey(String id) {
    var hash = 0xcbf29ce484222325;
    for (final byte in utf8.encode(id)) {
      hash = ((hash ^ byte) * 0x100000001b3) & 0xffffffffffffffff;
    }
    return hash.toRadixString(16).padLeft(16, '0');
  }

  bool _matchesImageSignature(List<int> bytes, String extension) {
    if (extension == 'png') {
      const signature = [137, 80, 78, 71, 13, 10, 26, 10];
      return bytes.length >= signature.length &&
          List.generate(signature.length, (index) => bytes[index]).toString() ==
              signature.toString();
    }
    return bytes.length >= 3 &&
        bytes[0] == 0xff &&
        bytes[1] == 0xd8 &&
        bytes[2] == 0xff;
  }

  bool _cacheNameMatches(String path, String key) =>
      File(path).uri.pathSegments.last.startsWith('thumb_$key') &&
      path.toLowerCase().endsWith('.png');
}
