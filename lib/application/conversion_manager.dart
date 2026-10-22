import '../models/conversion_job.dart';
import '../models/conversion_result.dart';
import '../models/conversion_type.dart';
import '../services/conversion/converter_interface.dart';

/// Orchestrates conversion requests by dispatching jobs to appropriate registered converters.
///
/// Keeps high-level application flows independent from concrete converter implementations.
abstract class ConversionManager {
  /// Currently registered converters available to handle conversions.
  List<ConverterInterface> get registeredConverters;

  /// Registers a converter strategy into the manager.
  void registerConverter(ConverterInterface converter);

  /// Unregisters a converter by its name.
  void unregisterConverter(String converterName);

  /// Returns whether any registered converter supports the given [type].
  bool isTypeSupported(ConversionType type);

  /// Resolves the best-matching converter for the specified [type], or null if unsupported.
  ConverterInterface? getConverterFor(ConversionType type);

  /// Executes a [ConversionJob] using the registered converter matching [job.conversionType].
  ///
  /// Fails gracefully with a [ConversionResult.failure] if no converter is registered for the type
  /// or if job validation fails.
  Future<ConversionResult> processJob(ConversionJob job);
}

/// Default in-memory implementation of [ConversionManager].
class DefaultConversionManager implements ConversionManager {
  final List<ConverterInterface> _converters = [];

  DefaultConversionManager([List<ConverterInterface>? initialConverters]) {
    if (initialConverters != null) {
      _converters.addAll(initialConverters);
    }
  }

  @override
  List<ConverterInterface> get registeredConverters =>
      List.unmodifiable(_converters);

  @override
  void registerConverter(ConverterInterface converter) {
    if (!_converters.contains(converter)) {
      _converters.add(converter);
    }
  }

  @override
  void unregisterConverter(String converterName) {
    _converters.removeWhere((c) => c.name == converterName);
  }

  @override
  bool isTypeSupported(ConversionType type) {
    return _converters.any((c) => c.canConvert(type));
  }

  @override
  ConverterInterface? getConverterFor(ConversionType type) {
    for (final converter in _converters) {
      if (converter.canConvert(type)) {
        return converter;
      }
    }
    return null;
  }

  @override
  Future<ConversionResult> processJob(ConversionJob job) async {
    final converter = getConverterFor(job.conversionType);
    if (converter == null) {
      return ConversionResult.failure(
        jobId: job.id,
        errorMessage:
            'No registered converter supports ${job.conversionType.name}',
      );
    }

    try {
      return await converter.convert(job);
    } catch (e) {
      return ConversionResult.failure(
        jobId: job.id,
        errorMessage:
            'Converter ${converter.name} threw an unexpected error: $e',
      );
    }
  }
}
