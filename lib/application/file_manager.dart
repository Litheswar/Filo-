/// High-level contract for safe local file operations (deletions, exists checks, file size).
///
/// Keeps file-system boundary decoupled from Flutter widgets or platform packages.
/// Concrete file system adapters in Phase 2 can wrap `dart:io` or Android Storage Access Framework.
abstract class FileManager {
  /// Checks whether a file exists at [path].
  Future<bool> fileExists(String path);

  /// Retrieves the file size in bytes for a file at [path].
  /// Returns null or throws if file does not exist.
  Future<int?> getFileSize(String path);

  /// Deletes a file at [path].
  /// Returns `true` if successfully deleted, `false` otherwise.
  Future<bool> deleteFile(String path);

  /// Generates a standardized sanitized output path in [directory] given a [baseName] and [extension].
  String buildOutputPath({
    required String directory,
    required String baseName,
    required String extension,
  });

  /// Extracts the clean base name of a file without its extension.
  String extractBaseName(String filePath);

  /// Extracts the file extension (without dot) in lowercase.
  String extractExtension(String filePath);
}

/// Base pure Dart implementation of path utility logic in [FileManager].
class BaseFileManager implements FileManager {
  @override
  Future<bool> fileExists(String path) {
    throw UnimplementedError(
      'Filesystem access is not implemented in Phase 1. Will be bound in Phase 2.',
    );
  }

  @override
  Future<int?> getFileSize(String path) {
    throw UnimplementedError(
      'Filesystem access is not implemented in Phase 1. Will be bound in Phase 2.',
    );
  }

  @override
  Future<bool> deleteFile(String path) {
    throw UnimplementedError(
      'Filesystem access is not implemented in Phase 1. Will be bound in Phase 2.',
    );
  }

  @override
  String buildOutputPath({
    required String directory,
    required String baseName,
    required String extension,
  }) {
    final cleanExt = extension.replaceAll('.', '').trim();
    final sanitizedBase = sanitizeFileName(baseName);
    final normalizedDir = directory.endsWith('/') || directory.endsWith(r'\')
        ? directory.substring(0, directory.length - 1)
        : directory;
    return '$normalizedDir/$sanitizedBase.$cleanExt';
  }

  @override
  String extractBaseName(String filePath) {
    final fileName = _getFileName(filePath);
    final lastDotIndex = fileName.lastIndexOf('.');
    if (lastDotIndex <= 0) {
      return fileName;
    }
    return fileName.substring(0, lastDotIndex);
  }

  @override
  String extractExtension(String filePath) {
    final fileName = _getFileName(filePath);
    final lastDotIndex = fileName.lastIndexOf('.');
    if (lastDotIndex == -1 || lastDotIndex == fileName.length - 1) {
      return '';
    }
    return fileName.substring(lastDotIndex + 1).toLowerCase();
  }

  /// Helper to sanitize file names by removing invalid characters.
  String sanitizeFileName(String name) {
    final trimmed = name.trim();
    if (trimmed.isEmpty) {
      return 'filo_output';
    }
    // Remove characters illegal in most filesystems
    return trimmed.replaceAll(RegExp(r'[\\/:*?"<>|]'), '_');
  }

  String _getFileName(String path) {
    final normalized = path.replaceAll(r'\', '/');
    final segments = normalized.split('/');
    return segments.isNotEmpty ? segments.last : path;
  }
}
