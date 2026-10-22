import 'dart:io';

import 'package:path_provider/path_provider.dart';

/// The app-private directories used by Filo for durable and temporary files.
class FileStorageDirectories {
  const FileStorageDirectories({
    required this.documents,
    required this.thumbnails,
    required this.temporary,
  });

  final Directory documents;
  final Directory thumbnails;
  final Directory temporary;
}

/// Basic metadata for a file that belongs to Filo's managed storage.
class StoredFileMetadata {
  const StoredFileMetadata({
    required this.path,
    required this.fileName,
    required this.sizeInBytes,
    required this.modifiedAt,
  });

  final String path;
  final String fileName;
  final int sizeInBytes;
  final DateTime modifiedAt;
}

/// Byte totals for Filo-owned directories only.
class ManagedStorageUsage {
  const ManagedStorageUsage({
    required this.documentsBytes,
    required this.temporaryBytes,
    required this.thumbnailBytes,
  });

  final int documentsBytes;
  final int temporaryBytes;
  final int thumbnailBytes;
}

/// Error raised when a storage operation cannot safely complete.
class FileStorageException implements Exception {
  const FileStorageException(this.message);

  final String message;

  @override
  String toString() => 'FileStorageException: $message';
}

/// Manages Filo-owned files in app-private directories.
///
/// Directory providers are injectable so filesystem behavior can be tested
/// without depending on platform channels or a real device's directories.
class FileStorage {
  FileStorage({
    Future<Directory> Function()? documentsDirectoryProvider,
    Future<Directory> Function()? temporaryDirectoryProvider,
    this.appDirectoryName = 'Filo',
  }) : _documentsDirectoryProvider =
           documentsDirectoryProvider ?? getApplicationDocumentsDirectory,
       _temporaryDirectoryProvider =
           temporaryDirectoryProvider ?? getTemporaryDirectory {
    _validateDirectoryName(appDirectoryName);
  }

  final Future<Directory> Function() _documentsDirectoryProvider;
  final Future<Directory> Function() _temporaryDirectoryProvider;
  final String appDirectoryName;

  FileStorageDirectories? _directories;

  /// Creates and returns Filo's documents, thumbnails, and temporary folders.
  Future<FileStorageDirectories> initialize() async {
    try {
      final docsBase = await _documentsDirectoryProvider();
      final tempBase = await _temporaryDirectoryProvider();
      final root = Directory(_join(docsBase.path, appDirectoryName));
      final tempRoot = Directory(_join(tempBase.path, appDirectoryName));
      final directories = FileStorageDirectories(
        documents: Directory(_join(root.path, 'documents')),
        thumbnails: Directory(_join(root.path, 'thumbnails')),
        temporary: Directory(_join(tempRoot.path, 'temp')),
      );
      for (final directory in [
        directories.documents,
        directories.thumbnails,
        directories.temporary,
      ]) {
        await directory.create(recursive: true);
      }
      _directories = directories;
      return directories;
    } on FileStorageException {
      rethrow;
    } on FileSystemException {
      throw const FileStorageException(
        'Filo storage directories could not be prepared.',
      );
    } catch (_) {
      throw const FileStorageException(
        'Filo storage directories are unavailable.',
      );
    }
  }

  /// Measures files under Filo's three managed directories, without traversing
  /// outside them or following symbolic links.
  Future<ManagedStorageUsage> getManagedStorageUsage() async {
    final directories = await _requireDirectories();
    try {
      return ManagedStorageUsage(
        documentsBytes: await _directorySize(directories.documents),
        temporaryBytes: await _directorySize(directories.temporary),
        thumbnailBytes: await _directorySize(directories.thumbnails),
      );
    } on FileSystemException {
      throw const FileStorageException(
        'Managed storage information could not be read.',
      );
    }
  }

  Future<int> _directorySize(Directory directory) async {
    // Keep directory enumeration and stat calls off the synchronous UI path.
    var total = 0;
    final pendingFiles = <Future<int>>[];
    Future<void> flushFiles() async {
      if (pendingFiles.isEmpty) return;
      final sizes = await Future.wait(pendingFiles);
      total += sizes.fold<int>(0, (sum, size) => sum + size);
      pendingFiles.clear();
    }

    await for (final entity in directory.list(followLinks: false)) {
      if (entity is File) {
        pendingFiles.add(entity.stat().then((stat) => stat.size));
        if (pendingFiles.length >= 64) await flushFiles();
      } else if (entity is Directory) {
        await flushFiles();
        total += await _directorySize(Directory(entity.path));
      }
    }
    await flushFiles();
    return total;
  }

  /// Saves a source file into Filo's permanent documents folder.
  /// The source is preserved and an existing destination is never replaced.
  Future<File> importFile(File source, {String? fileName}) =>
      copyToLibrary(source, fileName: fileName);

  /// Copies a generated output into Filo's permanent documents folder.
  Future<File> copyToLibrary(File source, {String? fileName}) async {
    final directories = await _requireDirectories();
    return _copyWithUniqueName(
      source,
      directories.documents,
      fileName ?? _basename(source.path),
    );
  }

  /// Copies a file into Filo's temporary folder using a managed filename.
  Future<File> saveTemporaryFile(
    List<int> bytes, {
    required String fileName,
  }) async {
    final directories = await _requireDirectories();
    final safeName = _validateFileName(fileName);
    final destination = await _reserveUniqueFile(
      directories.temporary,
      'filo_tmp_$safeName',
    );
    try {
      await destination.writeAsBytes(bytes, flush: true);
      return destination;
    } catch (_) {
      await _deleteQuietly(destination);
      throw const FileStorageException('Temporary file could not be saved.');
    }
  }

  /// Creates an isolated conversion-output directory in Filo's temp folder.
  /// The conversion coordinator that creates it is responsible for deletion.
  Future<Directory> createConversionTemporaryDirectory() async {
    final directories = await _requireDirectories();
    try {
      return await directories.temporary.createTemp('filo_tmp_conversion_');
    } on FileSystemException {
      throw const FileStorageException(
        'A temporary conversion directory could not be created.',
      );
    }
  }

  /// Recursively removes only a conversion directory created by
  /// [createConversionTemporaryDirectory].
  Future<void> deleteConversionTemporaryDirectory(Directory directory) async {
    final directories = await _requireDirectories();
    final canonicalRoot = await directories.temporary.resolveSymbolicLinks();
    final canonicalDirectory = await directory.resolveSymbolicLinks();
    if (!directory.path
            .replaceAll(r'\', '/')
            .split('/')
            .last
            .startsWith('filo_tmp_conversion_') ||
        await FileSystemEntity.type(directory.path, followLinks: false) !=
            FileSystemEntityType.directory ||
        !_isImmediateChild(canonicalDirectory, canonicalRoot)) {
      throw const FileStorageException(
        'Conversion directory is missing or outside Filo temporary storage.',
      );
    }
    try {
      await directory.delete(recursive: true);
    } on FileSystemException {
      throw const FileStorageException(
        'Temporary conversion files could not be cleaned.',
      );
    }
  }

  /// Returns a safe, currently unused path in Filo's documents folder.
  /// This reserves the file exclusively; callers should write and verify it.
  Future<File> createUniqueDestination(String fileName) async {
    final directories = await _requireDirectories();
    return _reserveUniqueFile(
      directories.documents,
      _validateFileName(fileName),
    );
  }

  /// Reads metadata for a regular file inside Filo's managed folders.
  Future<StoredFileMetadata> getMetadata(File file) async {
    final ownedFile = await _requireManagedFile(file);
    try {
      final stat = await ownedFile.stat();
      return StoredFileMetadata(
        path: ownedFile.path,
        fileName: _basename(ownedFile.path),
        sizeInBytes: stat.size,
        modifiedAt: stat.modified,
      );
    } on FileSystemException {
      throw const FileStorageException('File metadata could not be read.');
    }
  }

  /// Exclusively reserves a collision-safe filename in Filo's thumbnail folder.
  Future<File> createThumbnailFile(String fileName) async {
    final directories = await _requireDirectories();
    return _reserveUniqueFile(
      directories.thumbnails,
      _validateFileName(fileName),
    );
  }

  /// Returns whether [file] is a regular file inside Filo's thumbnail folder.
  Future<bool> thumbnailExists(File file) async {
    final directories = await _requireDirectories();
    if (!_isWithinRoot(file.absolute.path, directories.thumbnails.path)) {
      return false;
    }
    return await FileSystemEntity.type(file.path, followLinks: false) ==
        FileSystemEntityType.file;
  }

  /// Deletes a regular file only when it is inside Filo's thumbnail folder.
  Future<void> deleteThumbnail(File file) async {
    final directories = await _requireDirectories();
    if (!_isWithinRoot(file.absolute.path, directories.thumbnails.path) ||
        await FileSystemEntity.type(file.path, followLinks: false) !=
            FileSystemEntityType.file) {
      throw const FileStorageException(
        'Thumbnail is missing or outside Filo thumbnail storage.',
      );
    }
    try {
      await file.delete();
    } on FileSystemException {
      throw const FileStorageException('Thumbnail could not be deleted.');
    }
  }

  /// Deletes one regular file only when it is inside Filo's temporary folder.
  ///
  /// This is intended for callers that own the temporary file's lifecycle;
  /// picker-staged inputs should instead be removed by their selection handle.
  Future<void> deleteTemporaryFile(File file) async {
    final directories = await _requireDirectories();
    if (!_isWithinRoot(file.absolute.path, directories.temporary.path) ||
        await FileSystemEntity.type(file.path, followLinks: false) !=
            FileSystemEntityType.file) {
      throw const FileStorageException(
        'Temporary file is missing or outside Filo temporary storage.',
      );
    }
    try {
      await file.delete();
    } on FileSystemException {
      throw const FileStorageException('Temporary file could not be deleted.');
    }
  }

  /// Checks for an existing regular file inside Filo's managed folders.
  Future<bool> fileExists(File file) async {
    final directories = await _requireDirectories();
    if (!_isWithin(file.absolute.path, directories)) return false;
    try {
      return await FileSystemEntity.type(file.path, followLinks: false) ==
          FileSystemEntityType.file;
    } on FileSystemException {
      throw const FileStorageException('File existence could not be checked.');
    }
  }

  /// Renames a managed permanent file without replacing an existing file.
  ///
  /// The operation copies and verifies bytes before removing the original so
  /// it has the same no-overwrite behavior on Windows and Unix filesystems.
  Future<File> renameStoredFile(File file, String newFileName) async {
    final source = await _requireManagedFile(file, permanentOnly: true);
    final safeName = _validateFileName(newFileName);
    final destination = await _reserveUniqueFile(source.parent, safeName);
    return _copyAndRemoveSource(source, destination);
  }

  /// Renames a managed permanent file to exactly [newFileName].
  /// Fails if that destination already exists; it never chooses a suffix.
  Future<File> renameStoredFileTo(File file, String newFileName) async {
    final source = await _requireManagedFile(file, permanentOnly: true);
    final safeName = _validateFileName(newFileName);
    final destination = File(_join(source.parent.path, safeName));
    try {
      await destination.create(exclusive: true);
    } on FileSystemException {
      if (await FileSystemEntity.type(destination.path, followLinks: false) !=
          FileSystemEntityType.notFound) {
        throw const FileStorageException(
          'A file with that name already exists.',
        );
      }
      throw const FileStorageException(
        'Rename destination could not be created.',
      );
    }
    return _copyAndRemoveSource(source, destination);
  }

  Future<File> _copyAndRemoveSource(File source, File destination) async {
    try {
      await _copyContents(source, destination);
      if (await source.length() != await destination.length()) {
        throw const FileStorageException('Renamed file could not be verified.');
      }
      await source.delete();
      return destination;
    } catch (error) {
      await _deleteQuietly(destination);
      if (error is FileStorageException) rethrow;
      throw const FileStorageException('File could not be renamed safely.');
    }
  }

  /// Deletes a managed permanent file. Temporary files are cleaned separately.
  Future<void> deleteStoredFile(File file) async {
    final managed = await _requireManagedFile(file, permanentOnly: true);
    try {
      await managed.delete();
    } on FileSystemException {
      throw const FileStorageException('Stored file could not be deleted.');
    }
  }

  /// Deletes only regular files with Filo's reserved temp prefix.
  /// Permanent documents and unrelated files in the platform temp folder stay.
  Future<int> cleanTemporaryFiles() async {
    final directories = await _requireDirectories();
    var removed = 0;
    try {
      await for (final entity in directories.temporary.list(
        followLinks: false,
      )) {
        if (entity is File &&
            _basename(entity.path).startsWith('filo_tmp_') &&
            await FileSystemEntity.type(entity.path, followLinks: false) ==
                FileSystemEntityType.file) {
          await entity.delete();
          removed++;
        }
      }
      return removed;
    } on FileSystemException {
      throw const FileStorageException(
        'Filo temporary files could not be cleaned.',
      );
    }
  }

  Future<FileStorageDirectories> _requireDirectories() async =>
      _directories ?? await initialize();

  Future<File> _requireManagedFile(
    File file, {
    bool permanentOnly = false,
  }) async {
    final directories = await _requireDirectories();
    final type = await FileSystemEntity.type(file.path, followLinks: false);
    if (type != FileSystemEntityType.file ||
        !_isWithin(
          file.absolute.path,
          directories,
          permanentOnly: permanentOnly,
        )) {
      throw const FileStorageException(
        'File is missing or outside Filo storage.',
      );
    }
    return file;
  }

  bool _isWithin(
    String path,
    FileStorageDirectories directories, {
    bool permanentOnly = false,
  }) {
    final roots = permanentOnly
        ? [directories.documents.path, directories.thumbnails.path]
        : [
            directories.documents.path,
            directories.thumbnails.path,
            directories.temporary.path,
          ];
    final candidate = _normalize(path);
    return roots.any((root) {
      final normalizedRoot = _normalize(root)
          .replaceFirst(RegExp(r'[/\\]+$'), '');
      return candidate.startsWith('$normalizedRoot/') ||
          candidate == normalizedRoot;
    });
  }

  bool _isWithinRoot(String path, String root) {
    final candidate = _normalize(path);
    final normalizedRoot = _normalize(root)
        .replaceFirst(RegExp(r'[/\\]+$'), '');
    return candidate.startsWith('$normalizedRoot/') ||
        candidate == normalizedRoot;
  }

  bool _isImmediateChild(String path, String root) {
    final canonicalPath = _normalize(path).replaceFirst(RegExp(r'[/\\]+$'), '');
    final canonicalRoot = _normalize(root).replaceFirst(RegExp(r'[/\\]+$'), '');
    final parent = canonicalPath.substring(0, canonicalPath.lastIndexOf('/'));
    return parent == canonicalRoot;
  }

  Future<File> _copyWithUniqueName(
    File source,
    Directory directory,
    String requestedName,
  ) async {
    final safeName = _validateFileName(requestedName);
    if (await FileSystemEntity.type(source.path, followLinks: false) !=
        FileSystemEntityType.file) {
      throw const FileStorageException(
        'Source file is missing or is not a regular file.',
      );
    }
    final destination = await _reserveUniqueFile(directory, safeName);
    try {
      await _copyContents(source, destination);
      if (await source.length() != await destination.length()) {
        throw const FileStorageException('Copied file could not be verified.');
      }
      return destination;
    } catch (error) {
      await _deleteQuietly(destination);
      if (error is FileStorageException) rethrow;
      throw const FileStorageException(
        'File could not be copied into Filo storage.',
      );
    }
  }

  Future<File> _reserveUniqueFile(Directory directory, String name) async {
    final dot = name.lastIndexOf('.');
    final stem = dot > 0 ? name.substring(0, dot) : name;
    final extension = dot > 0 ? name.substring(dot) : '';
    for (var index = 0; index < 10000; index++) {
      final candidateName = index == 0 ? name : '${stem}_$index$extension';
      final candidate = File(_join(directory.path, candidateName));
      try {
        return await candidate.create(exclusive: true);
      } on FileSystemException {
        if (await FileSystemEntity.type(candidate.path, followLinks: false) !=
            FileSystemEntityType.notFound) {
          continue;
        }
        throw const FileStorageException(
          'Destination file could not be created.',
        );
      }
    }
    throw const FileStorageException(
      'No unique destination filename is available.',
    );
  }

  Future<void> _copyContents(File source, File destination) async {
    try {
      final sink = destination.openWrite();
      await sink.addStream(source.openRead());
      await sink.flush();
      await sink.close();
    } on FileSystemException {
      throw const FileStorageException('File contents could not be copied.');
    }
  }

  Future<void> _deleteQuietly(File file) async {
    try {
      if (await file.exists()) await file.delete();
    } on FileSystemException {
      // Preserve the original operation error; no success is reported.
    }
  }

  String _validateFileName(String fileName) {
    final trimmed = fileName.trim();
    if (trimmed.isEmpty ||
        trimmed == '.' ||
        trimmed == '..' ||
        trimmed.contains('..') ||
        trimmed.contains('/') ||
        trimmed.contains(r'\') ||
        trimmed.contains(':') ||
        trimmed.contains('\u0000') ||
        trimmed != fileName) {
      throw const FileStorageException(
        'Filename is invalid or contains a path.',
      );
    }
    final sanitized = trimmed.replaceAll(RegExp(r'[*?"<>|]'), '_');
    if (sanitized == '.' || sanitized == '..' || sanitized.isEmpty) {
      throw const FileStorageException('Filename is invalid.');
    }
    return sanitized;
  }

  static void _validateDirectoryName(String value) {
    if (value.isEmpty ||
        value == '.' ||
        value == '..' ||
        value.contains('/') ||
        value.contains(r'\') ||
        value.contains(':')) {
      throw ArgumentError.value(value, 'appDirectoryName');
    }
  }

  static String _basename(String path) =>
      path.replaceAll(r'\', '/').split('/').last;

  static String _join(String directory, String name) =>
      '$directory${directory.endsWith('/') || directory.endsWith(r'\') ? '' : Platform.pathSeparator}$name';

  static String _normalize(String path) =>
      path.replaceAll(r'\', '/').replaceAll(RegExp('/+'), '/').toLowerCase();
}
