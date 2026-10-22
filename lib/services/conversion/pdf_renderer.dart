import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:image/image.dart' as img;
import 'package:pdfrx/pdfrx.dart' as pdfrx;

import '../../application/file_manager.dart';
import '../../models/conversion_job.dart';
import '../../models/conversion_result.dart';
import '../../models/conversion_type.dart';
import 'converter_interface.dart';

/// Local PDF-to-images converter rendering PDF document pages into individual PNG images.
///
/// Implements [ConverterInterface] using [pdfrx] (backed by PDFium) for local,
/// on-device rasterization without cloud or server dependencies.
class PdfRenderer implements ConverterInterface {
  final FileManager _fileManager;

  /// Rendering scale multiplier relative to 72 DPI PDF point size (e.g. 2.0 = ~144 DPI).
  final double scale;

  /// Upper bound on rendered page width or height in pixels to avoid excessive memory usage.
  final int maxDimension;

  PdfRenderer({
    FileManager? fileManager,
    this.scale = 2.0,
    this.maxDimension = 4096,
  }) : _fileManager = fileManager ?? BaseFileManager() {
    if (scale <= 0.0 || scale > 5.0) {
      throw ArgumentError.value(
        scale,
        'scale',
        'Scale multiplier must be between 0.1 and 5.0',
      );
    }
    if (maxDimension < 256 || maxDimension > 8192) {
      throw ArgumentError.value(
        maxDimension,
        'maxDimension',
        'Max dimension must be between 256 and 8192 pixels',
      );
    }
  }

  @override
  String get name => 'PdfRenderer';

  @override
  Set<ConversionType> get supportedTypes => {ConversionType.pdfToImages};

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
        errorMessage: 'PdfRenderer does not support ${job.conversionType.name}',
        duration: stopwatch.elapsed,
      );
    }

    // 2. Validate input path existence
    final inputPath = job.primaryInputPath;
    final inputFile = File(inputPath);
    if (!await inputFile.exists()) {
      return ConversionResult.failure(
        jobId: job.id,
        errorMessage: 'Source PDF file does not exist',
        duration: stopwatch.elapsed,
      );
    }

    // 3. Validate input file is not empty
    try {
      final length = await inputFile.length();
      if (length == 0) {
        return ConversionResult.failure(
          jobId: job.id,
          errorMessage: 'Source PDF file is empty (0 bytes)',
          duration: stopwatch.elapsed,
        );
      }
    } catch (e) {
      return ConversionResult.failure(
        jobId: job.id,
        errorMessage: 'Failed to access source PDF file: $e',
        duration: stopwatch.elapsed,
      );
    }

    // 4. Open PDF document with error handling
    pdfrx.PdfDocument? doc;
    try {
      doc = await pdfrx.PdfDocument.openFile(inputPath);
    } on pdfrx.PdfPasswordException {
      return ConversionResult.failure(
        jobId: job.id,
        errorMessage: 'PDF document is password-protected and cannot be opened',
        duration: stopwatch.elapsed,
      );
    } catch (e) {
      final msg = e.toString().toLowerCase();
      if (msg.contains('password')) {
        return ConversionResult.failure(
          jobId: job.id,
          errorMessage:
              'PDF document is password-protected and cannot be opened',
          duration: stopwatch.elapsed,
        );
      }
      return ConversionResult.failure(
        jobId: job.id,
        errorMessage:
            'Failed to open PDF document: corrupt or invalid file ($e)',
        duration: stopwatch.elapsed,
      );
    }

    if (doc.pages.isEmpty) {
      await doc.dispose();
      return ConversionResult.failure(
        jobId: job.id,
        errorMessage: 'PDF document contains no renderable pages',
        duration: stopwatch.elapsed,
      );
    }

    final pageCount = doc.pages.length;
    final createdFiles = <File>[];

    try {
      // 5. Pre-resolve deterministic, collision-free output paths for all pages
      final targetPaths = await _resolveSafeOutputPaths(
        job: job,
        pageCount: pageCount,
      );

      // 6. Render each page individually to keep memory bounded
      for (var pageIndex = 0; pageIndex < pageCount; pageIndex++) {
        final page = doc.pages[pageIndex];
        final outputPath = targetPaths[pageIndex];
        final outputFile = File(outputPath);

        // Calculate bounded pixel dimensions
        final rawWidth = (page.width * scale).round();
        final rawHeight = (page.height * scale).round();

        final double dimScale = math.min(
          1.0,
          math.min(
            maxDimension / math.max(1, rawWidth),
            maxDimension / math.max(1, rawHeight),
          ),
        );

        final targetWidth = math.max(1, (rawWidth * dimScale).round());
        final targetHeight = math.max(1, (rawHeight * dimScale).round());

        // Render page to raw bitmap
        pdfrx.PdfImage? pageImage;
        try {
          pageImage = await page.render(
            width: targetWidth,
            height: targetHeight,
          );
        } catch (e) {
          throw Exception(
            'Failed to render page ${pageIndex + 1} of $pageCount: $e',
          );
        }

        if (pageImage == null || pageImage.pixels.isEmpty) {
          throw Exception(
            'Rendering page ${pageIndex + 1} produced empty pixel data',
          );
        }

        Uint8List pngBytes;
        try {
          // Convert raw RGBA buffer into PNG using image package
          final dartImage = img.Image.fromBytes(
            width: pageImage.width,
            height: pageImage.height,
            bytes: pageImage.pixels.buffer,
            order: img.ChannelOrder.rgba,
            numChannels: 4,
          );
          pngBytes = Uint8List.fromList(img.encodePng(dartImage));
        } catch (e) {
          throw Exception('Failed to encode page ${pageIndex + 1} as PNG: $e');
        } finally {
          // Immediately dispose raw native pixel buffer
          pageImage.dispose();
        }

        // Write PNG to disk atomically
        try {
          final parentDir = outputFile.parent;
          if (!await parentDir.exists()) {
            await parentDir.create(recursive: true);
          }
          // Reserve the path exclusively so an existing file is never replaced.
          await outputFile.create(exclusive: true);
          createdFiles.add(outputFile);
          final sink = await outputFile.open(mode: FileMode.writeOnly);
          try {
            await sink.writeFrom(pngBytes);
            await sink.flush();
          } finally {
            await sink.close();
          }
        } catch (e) {
          throw Exception(
            'Failed to write image for page ${pageIndex + 1}: $e',
          );
        }

        // Strict post-write verification: exists, non-empty, and valid decodable PNG
        final verifyError = await _verifyPngFile(outputFile);
        if (verifyError != null) {
          throw Exception(
            'Verification failed for page ${pageIndex + 1}: $verifyError',
          );
        }
      }

      stopwatch.stop();
      return ConversionResult.multipleSuccess(
        jobId: job.id,
        outputPaths: createdFiles.map((f) => f.path).toList(),
        duration: stopwatch.elapsed,
      );
    } catch (e) {
      // Rollback: Clean up any partial files created during this failed job
      for (final file in createdFiles) {
        try {
          if (await file.exists()) {
            await file.delete();
          }
        } catch (_) {}
      }

      final errorMsg = e.toString().replaceFirst(RegExp(r'^Exception:\s*'), '');
      return ConversionResult.failure(
        jobId: job.id,
        errorMessage: errorMsg,
        duration: stopwatch.elapsed,
      );
    } finally {
      // Always safely dispose PDF document resources
      try {
        await doc.dispose();
      } catch (_) {}
    }
  }

  /// Verifies that output file exists, is non-empty, and can be decoded as a valid PNG image.
  Future<String?> _verifyPngFile(File outputFile) async {
    if (!await outputFile.exists()) {
      return 'Output file does not exist on disk';
    }

    final length = await outputFile.length();
    if (length == 0) {
      return 'Output file is 0 bytes';
    }

    try {
      final bytes = await outputFile.readAsBytes();
      final decoded = img.decodePng(bytes);
      if (decoded == null) {
        return 'Output file is not a valid PNG image';
      }
    } catch (e) {
      return 'Output PNG verification error: $e';
    }

    return null;
  }

  /// Resolves collision-free, deterministic output paths for all pages.
  ///
  /// Naming pattern:
  /// - Without collision: `{baseName}_page_1.png`, `{baseName}_page_2.png`, ...
  /// - With collision: `{baseName}_1_page_1.png`, `{baseName}_1_page_2.png`, ...
  Future<List<String>> _resolveSafeOutputPaths({
    required ConversionJob job,
    required int pageCount,
  }) async {
    final parentDir =
        job.outputDirectory ?? File(job.primaryInputPath).parent.path;

    final baseName = job.requestedOutputName?.trim().isNotEmpty == true
        ? _fileManager.extractBaseName(job.requestedOutputName!)
        : _fileManager.extractBaseName(job.primaryInputPath);

    var candidateBase = baseName;
    var suffixCounter = 1;

    while (true) {
      final candidatePaths = <String>[];
      var hasCollision = false;

      for (var pageNum = 1; pageNum <= pageCount; pageNum++) {
        final fullPath = _fileManager.buildOutputPath(
          directory: parentDir,
          baseName: '${candidateBase}_page_$pageNum',
          extension: 'png',
        );

        if (_isInputCollision(job, fullPath) || await File(fullPath).exists()) {
          hasCollision = true;
          break;
        }
        candidatePaths.add(fullPath);
      }

      if (!hasCollision) {
        return candidatePaths;
      }

      // Suffix the entire batch to keep page names consistent
      candidateBase = '${baseName}_$suffixCounter';
      suffixCounter++;
    }
  }

  bool _isInputCollision(ConversionJob job, String outputPath) {
    final outAbs = File(outputPath).absolute.path.toLowerCase();
    for (final inPath in job.inputPaths) {
      if (File(inPath).absolute.path.toLowerCase() == outAbs) {
        return true;
      }
    }
    return false;
  }
}
