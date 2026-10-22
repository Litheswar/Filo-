import 'conversion_type.dart';

/// Represents where a file is physically stored or originated within the app sandbox.
enum StorageLocation {
  /// File is located in the application's internal documents directory.
  internalDocuments,

  /// File is located in the application's temporary cache directory.
  temporaryCache,

  /// File is exported or stored in an external shared storage location.
  externalShared,
}

/// Represents immutable metadata for a file managed within Filo's local library.
///
/// Keeps file binary data out of memory while tracking identifiers, file system paths,
/// sizes, and conversion lineage.
class FileRecord {
  /// Unique identifier for this record (e.g., UUID or unique timestamp key).
  final String id;

  /// File name including extension (e.g., 'document.pdf').
  final String fileName;

  /// File extension without leading dot (e.g., 'pdf', 'jpg').
  final String extension;

  /// File size in bytes.
  final int sizeInBytes;

  /// Timestamp when the file was created or recorded.
  final DateTime createdAt;

  /// Absolute local file path on device storage.
  final String localPath;

  /// Optional absolute path to a cached thumbnail image.
  final String? thumbnailPath;

  /// Optional conversion type used to produce this file, if derived from conversion.
  final ConversionType? conversionType;

  /// Storage category/location of the file.
  final StorageLocation storageLocation;

  FileRecord({
    required this.id,
    required this.fileName,
    required this.extension,
    required this.sizeInBytes,
    required this.createdAt,
    required this.localPath,
    this.thumbnailPath,
    this.conversionType,
    this.storageLocation = StorageLocation.internalDocuments,
  }) {
    if (id.trim().isEmpty) {
      throw ArgumentError.value(id, 'id', 'Record ID cannot be empty');
    }
    if (fileName.trim().isEmpty) {
      throw ArgumentError.value(
        fileName,
        'fileName',
        'File name cannot be empty',
      );
    }
    if (extension.trim().isEmpty) {
      throw ArgumentError.value(
        extension,
        'extension',
        'File extension cannot be empty',
      );
    }
    if (sizeInBytes < 0) {
      throw ArgumentError.value(
        sizeInBytes,
        'sizeInBytes',
        'File size in bytes cannot be negative',
      );
    }
    if (localPath.trim().isEmpty) {
      throw ArgumentError.value(
        localPath,
        'localPath',
        'Local path cannot be empty',
      );
    }
    if (thumbnailPath != null && thumbnailPath!.trim().isEmpty) {
      throw ArgumentError.value(
        thumbnailPath,
        'thumbnailPath',
        'Thumbnail path cannot be empty if specified',
      );
    }
  }

  /// Creates a copy of this [FileRecord] with updated fields.
  FileRecord copyWith({
    String? id,
    String? fileName,
    String? extension,
    int? sizeInBytes,
    DateTime? createdAt,
    String? localPath,
    String? thumbnailPath,
    bool clearThumbnailPath = false,
    ConversionType? conversionType,
    StorageLocation? storageLocation,
  }) {
    return FileRecord(
      id: id ?? this.id,
      fileName: fileName ?? this.fileName,
      extension: extension ?? this.extension,
      sizeInBytes: sizeInBytes ?? this.sizeInBytes,
      createdAt: createdAt ?? this.createdAt,
      localPath: localPath ?? this.localPath,
      thumbnailPath: clearThumbnailPath
          ? null
          : thumbnailPath ?? this.thumbnailPath,
      conversionType: conversionType ?? this.conversionType,
      storageLocation: storageLocation ?? this.storageLocation,
    );
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    return other is FileRecord &&
        other.id == id &&
        other.fileName == fileName &&
        other.extension == extension &&
        other.sizeInBytes == sizeInBytes &&
        other.createdAt == createdAt &&
        other.localPath == localPath &&
        other.thumbnailPath == thumbnailPath &&
        other.conversionType == conversionType &&
        other.storageLocation == storageLocation;
  }

  @override
  int get hashCode => Object.hash(
    id,
    fileName,
    extension,
    sizeInBytes,
    createdAt,
    localPath,
    thumbnailPath,
    conversionType,
    storageLocation,
  );

  @override
  String toString() {
    return 'FileRecord(id: $id, fileName: $fileName, sizeInBytes: $sizeInBytes, localPath: $localPath)';
  }
}
