import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:image/image.dart' as img;
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;

import '../../application/file_manager.dart';
import '../../models/conversion_job.dart';
import '../../models/conversion_result.dart';
import '../../models/conversion_type.dart';
import 'converter_interface.dart';

/// Pure Dart local PDF creator handling singleImageToPdf, multipleImagesToPdf, and txtToPdf.
///
/// Implements [ConverterInterface] without backend or external cloud services.
class PdfCreator implements ConverterInterface {
  final FileManager _fileManager;
  final double pageMargin;

  PdfCreator({FileManager? fileManager, this.pageMargin = 20.0})
    : _fileManager = fileManager ?? BaseFileManager();

  @override
  String get name => 'PdfCreator';

  @override
  Set<ConversionType> get supportedTypes => {
    ConversionType.singleImageToPdf,
    ConversionType.multipleImagesToPdf,
    ConversionType.txtToPdf,
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
        errorMessage: 'PdfCreator does not support ${job.conversionType.name}',
        duration: stopwatch.elapsed,
      );
    }

    // 2. Dispatch to dedicated generation handler
    final Uint8List pdfBytes;
    try {
      switch (job.conversionType) {
        case ConversionType.singleImageToPdf:
          pdfBytes = await _generateSingleImagePdf(job);
          break;
        case ConversionType.multipleImagesToPdf:
          pdfBytes = await _generateMultipleImagesPdf(job);
          break;
        case ConversionType.txtToPdf:
          pdfBytes = await _generateTxtPdf(job);
          break;
        default:
          return ConversionResult.failure(
            jobId: job.id,
            errorMessage:
                'Unsupported conversion type ${job.conversionType.name}',
            duration: stopwatch.elapsed,
          );
      }
    } catch (e) {
      return ConversionResult.failure(
        jobId: job.id,
        errorMessage: e.toString().replaceFirst(RegExp(r'^Exception:\s*'), ''),
        duration: stopwatch.elapsed,
      );
    }

    // 3. Resolve destination path with collision avoidance
    final targetExtension = job.conversionType.defaultOutputExtension; // 'pdf'
    final outputPath = await _resolveSafeOutputPath(job, targetExtension);

    // 4. Write PDF bytes to output file
    final outputFile = File(outputPath);
    try {
      final parentDir = outputFile.parent;
      if (!await parentDir.exists()) {
        await parentDir.create(recursive: true);
      }
      await outputFile.writeAsBytes(pdfBytes, flush: true);
    } catch (e) {
      return ConversionResult.failure(
        jobId: job.id,
        errorMessage: 'Failed to write PDF to disk: $e',
        duration: stopwatch.elapsed,
      );
    }

    // 5. Verification: file exists, is non-empty, and has valid PDF header & EOF
    final verificationError = await _verifyPdfFile(outputFile);
    if (verificationError != null) {
      // Clean up invalid or corrupted output file
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

  /// Builds a PDF document containing a single image fitted to the page.
  Future<Uint8List> _generateSingleImagePdf(ConversionJob job) async {
    final imagePath = job.primaryInputPath;
    final imageFile = File(imagePath);
    if (!await imageFile.exists()) {
      throw Exception('Source image does not exist: $imagePath');
    }

    final rawBytes = await _readNonEmptyFileBytes(imageFile);
    final decoded = _decodeAndValidateImage(rawBytes);

    final pdf = pw.Document();
    final pwImage = pw.MemoryImage(rawBytes);

    // Dynamic orientation: if image is wider than tall, use landscape page format
    final pageFormat = decoded.width > decoded.height
        ? PdfPageFormat.a4.landscape
        : PdfPageFormat.a4.portrait;

    pdf.addPage(
      pw.Page(
        pageFormat: pageFormat,
        margin: pw.EdgeInsets.all(pageMargin),
        build: (pw.Context context) {
          return pw.Center(child: pw.Image(pwImage, fit: pw.BoxFit.contain));
        },
      ),
    );

    return pdf.save();
  }

  /// Builds a single multi-page PDF document containing all input images in order.
  Future<Uint8List> _generateMultipleImagesPdf(ConversionJob job) async {
    if (job.inputPaths.isEmpty) {
      throw Exception(
        'Multiple images to PDF requires at least one image input',
      );
    }

    // Read and validate all images first. If any image fails, fail fast before writing partial output.
    final preparedPages = <_PreparedImagePage>[];
    for (var i = 0; i < job.inputPaths.length; i++) {
      final path = job.inputPaths[i];
      final file = File(path);
      if (!await file.exists()) {
        throw Exception('Input image at index $i does not exist: $path');
      }

      final rawBytes = await _readNonEmptyFileBytes(file);
      final decoded = _decodeAndValidateImage(rawBytes);
      preparedPages.add(
        _PreparedImagePage(
          pwImage: pw.MemoryImage(rawBytes),
          isLandscape: decoded.width > decoded.height,
        ),
      );
    }

    final pdf = pw.Document();
    for (final page in preparedPages) {
      final pageFormat = page.isLandscape
          ? PdfPageFormat.a4.landscape
          : PdfPageFormat.a4.portrait;

      pdf.addPage(
        pw.Page(
          pageFormat: pageFormat,
          margin: pw.EdgeInsets.all(pageMargin),
          build: (pw.Context context) {
            return pw.Center(
              child: pw.Image(page.pwImage, fit: pw.BoxFit.contain),
            );
          },
        ),
      );
    }

    return pdf.save();
  }

  /// Reads a UTF-8 text file and converts it into a formatted, multi-page PDF document.
  Future<Uint8List> _generateTxtPdf(ConversionJob job) async {
    final textPath = job.primaryInputPath;
    final textFile = File(textPath);
    if (!await textFile.exists()) {
      throw Exception('Source text file does not exist: $textPath');
    }

    final String textContent;
    try {
      final rawBytes = await textFile.readAsBytes();
      // Decode with replacement for any non-conforming byte sequences
      textContent = utf8.decode(rawBytes, allowMalformed: false);
    } on FormatException catch (e) {
      throw Exception('Invalid UTF-8 text encoding in file: ${e.message}');
    } catch (e) {
      throw Exception('Failed to read text file: $e');
    }

    final pdf = pw.Document();

    // Policy: Empty text file produces a valid one-page PDF with empty content
    if (textContent.trim().isEmpty) {
      pdf.addPage(
        pw.Page(
          pageFormat: PdfPageFormat.a4,
          margin: pw.EdgeInsets.all(pageMargin),
          build: (pw.Context context) => pw.SizedBox.shrink(),
        ),
      );
      return pdf.save();
    }

    // Split text into paragraphs to allow clean pagination and wrapping
    final paragraphs = textContent.split(RegExp(r'\r?\n'));

    pdf.addPage(
      pw.MultiPage(
        pageFormat: PdfPageFormat.a4,
        margin: pw.EdgeInsets.all(pageMargin),
        build: (pw.Context context) {
          final widgets = <pw.Widget>[];
          for (final paragraph in paragraphs) {
            if (paragraph.isEmpty) {
              widgets.add(pw.SizedBox(height: 8));
            } else {
              widgets.add(
                pw.Padding(
                  padding: const pw.EdgeInsets.only(bottom: 4),
                  child: pw.Text(
                    paragraph,
                    style: const pw.TextStyle(fontSize: 11, lineSpacing: 2),
                  ),
                ),
              );
            }
          }
          return widgets;
        },
      ),
    );

    return pdf.save();
  }

  /// Validates raw bytes and decodes image dimensions.
  img.Image _decodeAndValidateImage(Uint8List rawBytes) {
    final decoded = img.decodeImage(rawBytes);
    if (decoded == null) {
      throw Exception('Input file is not a valid or decodable image');
    }
    return decoded;
  }

  /// Reads file bytes and ensures it is not a 0-byte file.
  Future<Uint8List> _readNonEmptyFileBytes(File file) async {
    final bytes = await file.readAsBytes();
    if (bytes.isEmpty) {
      throw Exception('Source file is empty (0 bytes): ${file.path}');
    }
    return bytes;
  }

  /// Resolves the destination output file path with collision avoidance.
  /// If the destination file already exists or matches a source input, a numeric suffix is appended.
  Future<String> _resolveSafeOutputPath(
    ConversionJob job,
    String targetExtension,
  ) async {
    final parentDir =
        job.outputDirectory ?? File(job.primaryInputPath).parent.path;

    final initialBase = job.requestedOutputName?.trim().isNotEmpty == true
        ? _fileManager.extractBaseName(job.requestedOutputName!)
        : '${_fileManager.extractBaseName(job.primaryInputPath)}_converted';

    var candidate = _fileManager.buildOutputPath(
      directory: parentDir,
      baseName: initialBase,
      extension: targetExtension,
    );

    // Collision detection: ensure candidate is not one of the input files and does not already exist
    var counter = 1;
    while (_isInputCollision(job, candidate) ||
        await File(candidate).exists()) {
      candidate = _fileManager.buildOutputPath(
        directory: parentDir,
        baseName: '${initialBase}_$counter',
        extension: targetExtension,
      );
      counter++;
    }

    return candidate;
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

  /// Verifies PDF magic number and valid structure.
  Future<String?> _verifyPdfFile(File outputFile) async {
    if (!await outputFile.exists()) {
      return 'Verification failed: PDF output file was not created on disk';
    }

    final length = await outputFile.length();
    if (length < 8) {
      return 'Verification failed: PDF output file is too small or empty';
    }

    try {
      final bytes = await outputFile.readAsBytes();

      // Check PDF header signature '%PDF-'
      final header = String.fromCharCodes(bytes.take(5));
      if (!header.startsWith('%PDF-')) {
        return 'Verification failed: Output file missing valid %PDF- header signature';
      }

      // Check EOF marker near the end of the file
      final trailingBytes = bytes.sublist(
        bytes.length > 128 ? bytes.length - 128 : 0,
      );
      final trailingString = String.fromCharCodes(trailingBytes);
      if (!trailingString.contains('%%EOF')) {
        return 'Verification failed: Output file is incomplete or missing %%EOF marker';
      }
    } catch (e) {
      return 'Verification failed: Could not read or verify PDF output file: $e';
    }

    return null;
  }
}

class _PreparedImagePage {
  final pw.MemoryImage pwImage;
  final bool isLandscape;

  _PreparedImagePage({required this.pwImage, required this.isLandscape});
}
