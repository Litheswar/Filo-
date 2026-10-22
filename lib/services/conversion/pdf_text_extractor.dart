import 'dart:convert';
import 'dart:io';

import 'package:pdfrx/pdfrx.dart' as pdfrx;

import '../../application/file_manager.dart';
import '../../models/conversion_job.dart';
import '../../models/conversion_result.dart';
import '../../models/conversion_type.dart';
import 'converter_interface.dart';

typedef PdfDocumentOpener = Future<pdfrx.PdfDocument> Function(String path);

/// Extracts selectable text from local PDF files into UTF-8 text files.
///
/// Text within each page is ordered and line-formatted by pdfrx. Page sections
/// are separated by a form feed surrounded by newlines. This converter does
/// not recognize text embedded in page images.
class PdfTextExtractor implements ConverterInterface {
  final FileManager _fileManager;
  final PdfDocumentOpener _documentOpener;

  PdfTextExtractor({
    FileManager? fileManager,
    PdfDocumentOpener? documentOpener,
  }) : _fileManager = fileManager ?? BaseFileManager(),
       _documentOpener = documentOpener ?? pdfrx.PdfDocument.openFile;

  @override
  String get name => 'PdfTextExtractor';

  @override
  Set<ConversionType> get supportedTypes => {ConversionType.pdfToTxt};

  @override
  bool canConvert(ConversionType conversionType) =>
      supportedTypes.contains(conversionType);

  @override
  Future<ConversionResult> convert(ConversionJob job) async {
    final stopwatch = Stopwatch()..start();
    if (!canConvert(job.conversionType)) {
      return ConversionResult.failure(
        jobId: job.id,
        errorMessage:
            'PdfTextExtractor does not support ${job.conversionType.name}',
        duration: stopwatch.elapsed,
      );
    }

    final inputFile = File(job.primaryInputPath);
    try {
      if (!await inputFile.exists()) {
        return ConversionResult.failure(
          jobId: job.id,
          errorMessage: 'Source PDF file does not exist',
          duration: stopwatch.elapsed,
        );
      }
      if (await inputFile.length() == 0) {
        return ConversionResult.failure(
          jobId: job.id,
          errorMessage: 'Source PDF file is empty (0 bytes)',
          duration: stopwatch.elapsed,
        );
      }
    } catch (_) {
      return ConversionResult.failure(
        jobId: job.id,
        errorMessage: 'Could not read the source PDF file',
        duration: stopwatch.elapsed,
      );
    }

    pdfrx.PdfDocument? document;
    try {
      try {
        document = await _documentOpener(job.primaryInputPath);
      } on pdfrx.PdfPasswordException {
        return ConversionResult.failure(
          jobId: job.id,
          errorMessage: 'PDF is password-protected and cannot be opened',
          duration: stopwatch.elapsed,
        );
      } catch (_) {
        return ConversionResult.failure(
          jobId: job.id,
          errorMessage: 'Could not open the PDF; it may be corrupt or invalid',
          duration: stopwatch.elapsed,
        );
      }

      if (document.pages.isEmpty) {
        return ConversionResult.failure(
          jobId: job.id,
          errorMessage: 'PDF document contains no pages',
          duration: stopwatch.elapsed,
        );
      }

      final pageTexts = <String>[];
      var hasExtractableText = false;
      try {
        for (final page in document.pages) {
          // Structured text uses pdfrx's reading-order and line-break logic.
          final pageText = (await page.loadStructuredText()).fullText;
          pageTexts.add(pageText);
          if (pageText.trim().isNotEmpty) {
            hasExtractableText = true;
          }
        }
      } catch (_) {
        return ConversionResult.failure(
          jobId: job.id,
          errorMessage: 'Failed to extract text from the PDF',
          duration: stopwatch.elapsed,
        );
      }

      if (!hasExtractableText) {
        return ConversionResult.failure(
          jobId: job.id,
          errorMessage: 'No extractable text found. This PDF may contain scanned pages; OCR is not available in this version.',
          duration: stopwatch.elapsed,
        );
      }

      final text = pageTexts.map((page) => page.trim()).join('\n\f\n');
      final outputFile = await _createOutputFile(job);
      if (outputFile == null) {
        return ConversionResult.failure(
          jobId: job.id,
          errorMessage: 'Could not create a safe output filename',
          duration: stopwatch.elapsed,
        );
      }

      try {
        // The output was reserved with exclusive creation, so existing files
        // are never overwritten. Track it before writing for failure cleanup.
        final sink = await outputFile.open(mode: FileMode.writeOnly);
        try {
          await sink.writeFrom(utf8.encode(text));
          await sink.flush();
        } finally {
          await sink.close();
        }

        final writtenBytes = await outputFile.readAsBytes();
        if (writtenBytes.isEmpty || utf8.decode(writtenBytes) != text) {
          throw const FormatException('Output text verification failed');
        }
      } catch (_) {
        await _deleteIncompleteOutput(outputFile);
        return ConversionResult.failure(
          jobId: job.id,
          errorMessage: 'Failed to write or verify the extracted text file',
          duration: stopwatch.elapsed,
        );
      }

      stopwatch.stop();
      return ConversionResult.success(
        jobId: job.id,
        outputPath: outputFile.path,
        duration: stopwatch.elapsed,
      );
    } finally {
      try {
        await document?.dispose();
      } catch (_) {
        // Preserve the conversion result if native resource cleanup fails.
      }
    }
  }

  /// Finds and exclusively reserves a non-colliding .txt output path.
  Future<File?> _createOutputFile(ConversionJob job) async {
    final directory =
        job.outputDirectory ?? File(job.primaryInputPath).parent.path;
    final baseName = job.requestedOutputName?.trim().isNotEmpty == true
        ? _fileManager.extractBaseName(job.requestedOutputName!)
        : '${_fileManager.extractBaseName(job.primaryInputPath)}_extracted';
    final inputPath = File(job.primaryInputPath).absolute.path.toLowerCase();

    try {
      final outputDirectory = Directory(directory);
      if (!await outputDirectory.exists()) {
        await outputDirectory.create(recursive: true);
      }

      for (var suffix = 0; ; suffix++) {
        final candidateBase = suffix == 0 ? baseName : '${baseName}_$suffix';
        final path = _fileManager.buildOutputPath(
          directory: directory,
          baseName: candidateBase,
          extension: 'txt',
        );
        final candidate = File(path);
        if (candidate.absolute.path.toLowerCase() == inputPath ||
            await candidate.exists()) {
          continue;
        }

        try {
          await candidate.create(exclusive: true);
          return candidate;
        } on FileSystemException {
          // If another process reserved this name, try the next suffix.
          if (await candidate.exists()) continue;
          return null;
        }
      }
    } catch (_) {
      return null;
    }
  }

  Future<void> _deleteIncompleteOutput(File file) async {
    try {
      if (await file.exists()) await file.delete();
    } catch (_) {
      // Best-effort cleanup; never delete a path that was not reserved above.
    }
  }
}
