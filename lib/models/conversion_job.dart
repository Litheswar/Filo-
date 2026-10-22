import 'conversion_type.dart';

/// Describes an immutable request to perform a file conversion in Filo.
class ConversionJob {
  /// Unique identifier for this conversion job.
  final String id;

  /// Ordered list of input file paths to be converted.
  /// For single-file conversions, this list contains exactly one path.
  /// For multiple-image conversions (e.g. [ConversionType.multipleImagesToPdf]),
  /// this contains one or more image file paths in target sequence.
  final List<String> inputPaths;

  /// The type of conversion requested.
  final ConversionType conversionType;

  /// Requested output file name (e.g., 'converted_document' or 'result.pdf').
  /// Can be omitted or null to let the converter generate a default name.
  final String? requestedOutputName;

  /// Destination directory path where the resulting file(s) should be saved.
  /// If null, default application output directory is used.
  final String? outputDirectory;

  /// Job creation timestamp.
  final DateTime createdAt;

  ConversionJob({
    required this.id,
    required List<String> inputPaths,
    required this.conversionType,
    this.requestedOutputName,
    this.outputDirectory,
    DateTime? createdAt,
  }) : inputPaths = List.unmodifiable(inputPaths),
       createdAt = createdAt ?? DateTime.now() {
    if (id.trim().isEmpty) {
      throw ArgumentError.value(id, 'id', 'Job ID cannot be empty');
    }
    if (inputPaths.isEmpty) {
      throw ArgumentError.value(
        inputPaths,
        'inputPaths',
        'At least one input file path must be provided',
      );
    }
    for (final path in inputPaths) {
      if (path.trim().isEmpty) {
        throw ArgumentError.value(
          path,
          'inputPaths',
          'Input file path cannot be empty or whitespace',
        );
      }
    }
    if (conversionType != ConversionType.multipleImagesToPdf &&
        inputPaths.length > 1) {
      throw ArgumentError.value(
        inputPaths.length,
        'inputPaths',
        'Conversion type ${conversionType.name} only accepts a single input file',
      );
    }
    if (requestedOutputName != null && requestedOutputName!.trim().isEmpty) {
      throw ArgumentError.value(
        requestedOutputName,
        'requestedOutputName',
        'Requested output name cannot be empty if specified',
      );
    }
    if (outputDirectory != null && outputDirectory!.trim().isEmpty) {
      throw ArgumentError.value(
        outputDirectory,
        'outputDirectory',
        'Output directory cannot be empty if specified',
      );
    }
  }

  /// Convenience helper to retrieve the primary input path.
  String get primaryInputPath => inputPaths.first;

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    if (other is! ConversionJob) return false;
    if (other.id != id ||
        other.conversionType != conversionType ||
        other.requestedOutputName != requestedOutputName ||
        other.outputDirectory != outputDirectory ||
        other.createdAt != createdAt ||
        other.inputPaths.length != inputPaths.length) {
      return false;
    }
    for (var i = 0; i < inputPaths.length; i++) {
      if (inputPaths[i] != other.inputPaths[i]) return false;
    }
    return true;
  }

  @override
  int get hashCode => Object.hash(
    id,
    Object.hashAll(inputPaths),
    conversionType,
    requestedOutputName,
    outputDirectory,
    createdAt,
  );

  @override
  String toString() {
    return 'ConversionJob(id: $id, type: ${conversionType.name}, inputs: ${inputPaths.length})';
  }
}
