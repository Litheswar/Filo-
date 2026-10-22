/// Represents the outcome of an attempted conversion job.
class ConversionResult {
  /// Unique identifier of the job that produced this result.
  final String jobId;

  /// Whether the conversion succeeded.
  final bool isSuccess;

  /// Primary output file path if successful.
  final String? outputPath;

  /// Optional list of all generated output paths. Useful for operations
  /// like PDF to Images that produce multiple files.
  final List<String> outputPaths;

  /// Detailed human-readable error message if the conversion failed.
  final String? errorMessage;

  /// Time taken to process the conversion, if measured.
  final Duration? duration;

  ConversionResult._({
    required this.jobId,
    required this.isSuccess,
    this.outputPath,
    required this.outputPaths,
    this.errorMessage,
    this.duration,
  });

  /// Factory constructor for a verified successful conversion result.
  ///
  /// Requires at least one valid non-empty output path.
  factory ConversionResult.success({
    required String jobId,
    required String outputPath,
    List<String>? additionalOutputPaths,
    Duration? duration,
  }) {
    if (jobId.trim().isEmpty) {
      throw ArgumentError.value(jobId, 'jobId', 'Job ID cannot be empty');
    }
    if (outputPath.trim().isEmpty) {
      throw ArgumentError.value(
        outputPath,
        'outputPath',
        'Successful result requires a non-empty output file path',
      );
    }

    final allPaths = <String>[outputPath];
    if (additionalOutputPaths != null) {
      for (final p in additionalOutputPaths) {
        if (p.trim().isNotEmpty && !allPaths.contains(p)) {
          allPaths.add(p);
        }
      }
    }

    return ConversionResult._(
      jobId: jobId,
      isSuccess: true,
      outputPath: outputPath,
      outputPaths: List.unmodifiable(allPaths),
      errorMessage: null,
      duration: duration,
    );
  }

  /// Factory constructor for a successful conversion result with multiple output files
  /// (e.g. PDF to images).
  factory ConversionResult.multipleSuccess({
    required String jobId,
    required List<String> outputPaths,
    Duration? duration,
  }) {
    if (jobId.trim().isEmpty) {
      throw ArgumentError.value(jobId, 'jobId', 'Job ID cannot be empty');
    }
    if (outputPaths.isEmpty) {
      throw ArgumentError.value(
        outputPaths,
        'outputPaths',
        'Successful result must provide at least one output path',
      );
    }
    for (final p in outputPaths) {
      if (p.trim().isEmpty) {
        throw ArgumentError.value(
          p,
          'outputPaths',
          'Output path cannot be empty or whitespace',
        );
      }
    }

    return ConversionResult._(
      jobId: jobId,
      isSuccess: true,
      outputPath: outputPaths.first,
      outputPaths: List.unmodifiable(outputPaths),
      errorMessage: null,
      duration: duration,
    );
  }

  /// Factory constructor for a failed conversion.
  factory ConversionResult.failure({
    required String jobId,
    required String errorMessage,
    Duration? duration,
  }) {
    if (jobId.trim().isEmpty) {
      throw ArgumentError.value(jobId, 'jobId', 'Job ID cannot be empty');
    }
    if (errorMessage.trim().isEmpty) {
      throw ArgumentError.value(
        errorMessage,
        'errorMessage',
        'Failed conversion must provide a descriptive error message',
      );
    }

    return ConversionResult._(
      jobId: jobId,
      isSuccess: false,
      outputPath: null,
      outputPaths: const [],
      errorMessage: errorMessage,
      duration: duration,
    );
  }

  @override
  String toString() {
    if (isSuccess) {
      return 'ConversionResult.success(jobId: $jobId, outputPath: $outputPath, files: ${outputPaths.length})';
    }
    return 'ConversionResult.failure(jobId: $jobId, error: $errorMessage)';
  }
}
