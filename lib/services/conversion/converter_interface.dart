import '../../models/conversion_job.dart';
import '../../models/conversion_result.dart';
import '../../models/conversion_type.dart';

/// Abstract contract for a conversion engine or strategy.
///
/// Implementations of this interface handle specific conversion workflows
/// (e.g., image-to-PDF, PDF rendering, text extraction) without coupling
/// caller code to specific native or 3rd party engines.
abstract class ConverterInterface {
  /// Unique identifier or name for this converter implementation (e.g. 'StandardImageConverter').
  String get name;

  /// The set of [ConversionType]s supported by this converter.
  Set<ConversionType> get supportedTypes;

  /// Checks if this converter can handle the requested [conversionType].
  bool canConvert(ConversionType conversionType) =>
      supportedTypes.contains(conversionType);

  /// Executes a given [ConversionJob] and returns a [ConversionResult].
  ///
  /// Implementations must verify that any produced output file actually exists
  /// on disk before returning a successful result.
  Future<ConversionResult> convert(ConversionJob job);
}
