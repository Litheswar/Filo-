import 'dart:io';

import 'package:image/image.dart' as img;

import '../../application/file_manager.dart';
import '../../models/conversion_job.dart';
import '../../models/conversion_result.dart';
import '../../models/conversion_type.dart';
import 'converter_interface.dart';

/// Strategy policy for handling alpha/transparency when converting transparent images (e.g. PNG)
/// to formats without alpha support (e.g. JPEG).
enum AlphaChannelPolicy {
  /// Blends transparent pixels over a solid white background (default for print and standard docs).
  compositeWhite,

  /// Blends transparent pixels over a solid black background.
  compositeBlack,
}

/// Pure Dart local image converter handling JPG <-> PNG conversions.
///
/// Implements [ConverterInterface] without platform-specific dependencies or network calls.
class ImageConverter implements ConverterInterface {
  final FileManager _fileManager;
  final int jpegQuality;
  final AlphaChannelPolicy alphaPolicy;

  ImageConverter({
    FileManager? fileManager,
    this.jpegQuality = 90,
    this.alphaPolicy = AlphaChannelPolicy.compositeWhite,
  }) : _fileManager = fileManager ?? BaseFileManager() {
    if (jpegQuality < 1 || jpegQuality > 100) {
      throw ArgumentError.value(
        jpegQuality,
        'jpegQuality',
        'JPEG quality must be between 1 and 100',
      );
    }
  }

  @override
  String get name => 'ImageConverter';

  @override
  Set<ConversionType> get supportedTypes => {
    ConversionType.jpgToPng,
    ConversionType.pngToJpg,
  };

  @override
  bool canConvert(ConversionType conversionType) =>
      supportedTypes.contains(conversionType);

  @override
  Future<ConversionResult> convert(ConversionJob job) async {
    final stopwatch = Stopwatch()..start();

    // 1. Verify conversion type is supported
    if (!canConvert(job.conversionType)) {
      return ConversionResult.failure(
        jobId: job.id,
        errorMessage:
            'ImageConverter does not support ${job.conversionType.name}',
        duration: stopwatch.elapsed,
      );
    }

    // 2. Validate input path existence
    final inputPath = job.primaryInputPath;
    final inputFile = File(inputPath);
    if (!await inputFile.exists()) {
      return ConversionResult.failure(
        jobId: job.id,
        errorMessage: 'Source file does not exist at path: $inputPath',
        duration: stopwatch.elapsed,
      );
    }

    // 3. Read input bytes safely
    final List<int> sourceBytes;
    try {
      sourceBytes = await inputFile.readAsBytes();
      if (sourceBytes.isEmpty) {
        return ConversionResult.failure(
          jobId: job.id,
          errorMessage: 'Source file is empty (0 bytes)',
          duration: stopwatch.elapsed,
        );
      }
    } catch (e) {
      return ConversionResult.failure(
        jobId: job.id,
        errorMessage: 'Failed to read input file: $e',
        duration: stopwatch.elapsed,
      );
    }

    // 4. Decode input image
    img.Image? decodedImage;
    try {
      decodedImage = img.decodeImage(sourceBytes as dynamic);
    } catch (e) {
      return ConversionResult.failure(
        jobId: job.id,
        errorMessage: 'Failed to decode input image data: $e',
        duration: stopwatch.elapsed,
      );
    }

    if (decodedImage == null) {
      return ConversionResult.failure(
        jobId: job.id,
        errorMessage: 'Invalid or unsupported image data format',
        duration: stopwatch.elapsed,
      );
    }

    // 5. Determine target extension and output path
    final targetExtension = job.conversionType.defaultOutputExtension;
    final outputPath = _resolveOutputPath(job, targetExtension);

    // Guard against overwriting input file directly
    if (_isSameFilePath(inputPath, outputPath)) {
      return ConversionResult.failure(
        jobId: job.id,
        errorMessage: 'Output path cannot be identical to source path',
        duration: stopwatch.elapsed,
      );
    }

    // 6. Encode image to target format
    final List<int> encodedBytes;
    try {
      switch (job.conversionType) {
        case ConversionType.jpgToPng:
          encodedBytes = img.encodePng(decodedImage);
          break;

        case ConversionType.pngToJpg:
          // Handle transparency for JPEG: composite onto chosen background color
          final imageForJpeg = _prepareImageForJpeg(decodedImage);
          encodedBytes = img.encodeJpg(imageForJpeg, quality: jpegQuality);
          break;

        default:
          return ConversionResult.failure(
            jobId: job.id,
            errorMessage:
                'Unsupported conversion type: ${job.conversionType.name}',
            duration: stopwatch.elapsed,
          );
      }
    } catch (e) {
      return ConversionResult.failure(
        jobId: job.id,
        errorMessage: 'Failed to encode image to $targetExtension: $e',
        duration: stopwatch.elapsed,
      );
    }

    // 7. Write to output file
    final outputFile = File(outputPath);
    try {
      // Ensure target directory exists
      final parentDir = outputFile.parent;
      if (!await parentDir.exists()) {
        await parentDir.create(recursive: true);
      }

      await outputFile.writeAsBytes(encodedBytes, flush: true);
    } catch (e) {
      return ConversionResult.failure(
        jobId: job.id,
        errorMessage: 'Failed to write output file: $e',
        duration: stopwatch.elapsed,
      );
    }

    // 8. Strict post-conversion verification: exists, non-empty, and decodable
    final verificationError = await _verifyOutputFile(
      outputFile,
      job.conversionType,
    );
    if (verificationError != null) {
      // Clean up potentially corrupt output file
      try {
        if (await outputFile.exists()) {
          await outputFile.delete();
        }
      } catch (_) {}

      return ConversionResult.failure(
        jobId: job.id,
        errorMessage: verificationError,
        duration: stopwatch.elapsed,
      );
    }

    stopwatch.stop();
    return ConversionResult.success(
      jobId: job.id,
      outputPath: outputFile.path,
      duration: stopwatch.elapsed,
    );
  }

  /// Prepares an image for JPEG encoding by flattening any alpha/transparency channels.
  img.Image _prepareImageForJpeg(img.Image source) {
    if (!source.hasAlpha) {
      return source;
    }

    // Create a solid background image with identical dimensions
    final background = img.Image(
      width: source.width,
      height: source.height,
      numChannels: 3, // RGB without alpha
    );

    final bgFillColor = alphaPolicy == AlphaChannelPolicy.compositeWhite
        ? img.ColorRgb8(255, 255, 255)
        : img.ColorRgb8(0, 0, 0);

    img.fill(background, color: bgFillColor);

    // Composite source image onto solid background
    return img.compositeImage(background, source);
  }

  /// Verifies that output file exists, is non-empty, and can be properly decoded as expected format.
  Future<String?> _verifyOutputFile(
    File outputFile,
    ConversionType conversionType,
  ) async {
    if (!await outputFile.exists()) {
      return 'Verification failed: Output file was not created on disk';
    }

    final length = await outputFile.length();
    if (length == 0) {
      return 'Verification failed: Output file is empty (0 bytes)';
    }

    try {
      final bytes = await outputFile.readAsBytes();
      final decoded = img.decodeImage(bytes);
      if (decoded == null) {
        return 'Verification failed: Produced output file could not be decoded as an image';
      }

      // Check format-specific decoders
      if (conversionType == ConversionType.jpgToPng) {
        final pngDecoded = img.decodePng(bytes);
        if (pngDecoded == null) {
          return 'Verification failed: Output is not a valid PNG image';
        }
      } else if (conversionType == ConversionType.pngToJpg) {
        final jpgDecoded = img.decodeJpg(bytes);
        if (jpgDecoded == null) {
          return 'Verification failed: Output is not a valid JPG image';
        }
      }
    } catch (e) {
      return 'Verification failed: Output file is corrupt or unreadable: $e';
    }

    return null; // Verification succeeded
  }

  /// Resolves the destination output file path.
  String _resolveOutputPath(ConversionJob job, String targetExtension) {
    final inputPath = job.primaryInputPath;
    final parentDir = job.outputDirectory ?? File(inputPath).parent.path;

    final baseName = job.requestedOutputName?.trim().isNotEmpty == true
        ? _fileManager.extractBaseName(job.requestedOutputName!)
        : '${_fileManager.extractBaseName(inputPath)}_converted';

    return _fileManager.buildOutputPath(
      directory: parentDir,
      baseName: baseName,
      extension: targetExtension,
    );
  }

  bool _isSameFilePath(String path1, String path2) {
    return File(path1).absolute.path.toLowerCase() ==
        File(path2).absolute.path.toLowerCase();
  }
}
