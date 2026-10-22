import 'dart:io';
import 'dart:typed_data';

import 'package:pdfrx/pdfrx.dart' as pdfrx;

import '../../application/file_manager.dart';
import '../../models/conversion_job.dart';
import '../../models/conversion_result.dart';
import '../../models/conversion_type.dart';
import 'converter_interface.dart';

typedef PdfMergeOutputWriter = Future<void> Function(
  File file,
  Uint8List bytes,
);

/// Merges complete PDF pages locally using pdfrx/PDFium.
///
/// The source documents remain open until PDFium has assembled the output.
/// Source files are never modified. Encrypted PDFs are rejected because this
/// workflow has no password-entry UI and must not silently drop permissions.
class PdfMerger implements ConverterInterface {
  PdfMerger({FileManager? fileManager, PdfMergeOutputWriter? outputWriter})
    : _fileManager = fileManager ?? BaseFileManager(),
      _outputWriter = outputWriter ?? _writeFile;

  final FileManager _fileManager;
  final PdfMergeOutputWriter _outputWriter;

  static Future<void> _writeFile(File file, Uint8List bytes) =>
      file.writeAsBytes(bytes, flush: true);

  @override
  String get name => 'PdfMerger';

  @override
  Set<ConversionType> get supportedTypes => {ConversionType.pdfMerge};

  @override
  bool canConvert(ConversionType conversionType) =>
      supportedTypes.contains(conversionType);

  @override
  Future<ConversionResult> convert(ConversionJob job) async {
    final stopwatch = Stopwatch()..start();
    if (job.conversionType != ConversionType.pdfMerge) {
      return ConversionResult.failure(
        jobId: job.id,
        errorMessage: 'PdfMerger does not support ${job.conversionType.name}',
        duration: stopwatch.elapsed,
      );
    }
    if (job.inputPaths.length < 2) {
      return ConversionResult.failure(
        jobId: job.id,
        errorMessage: 'Select at least two PDF files to merge.',
        duration: stopwatch.elapsed,
      );
    }

    final sources = <pdfrx.PdfDocument>[];
    pdfrx.PdfDocument? merged;
    File? outputFile;
    try {
      final expectedPages = <_PageGeometry>[];
      for (var index = 0; index < job.inputPaths.length; index++) {
        final input = File(job.inputPaths[index]);
        if (!await input.exists()) {
          throw _MergeFailure('PDF ${index + 1} is missing or unreadable.');
        }
        if (await input.length() == 0) {
          throw _MergeFailure('PDF ${index + 1} is empty.');
        }

        final pdfrx.PdfDocument source;
        try {
          source = await pdfrx.PdfDocument.openFile(input.path);
        } on pdfrx.PdfPasswordException {
          throw _MergeFailure(
            'PDF ${index + 1} is password-protected and cannot be merged.',
          );
        } catch (error) {
          if (error is _MergeFailure) rethrow;
          throw _MergeFailure(
            'PDF ${index + 1} is corrupt, invalid, or cannot be read.',
          );
        }
        sources.add(source);
        if (source.isEncrypted) {
          throw _MergeFailure(
            'PDF ${index + 1} is encrypted and cannot be merged.',
          );
        }
        if (source.pages.isEmpty) {
          throw _MergeFailure('PDF ${index + 1} contains no pages.');
        }
        expectedPages.addAll(
          source.pages.map(
            (page) => _PageGeometry(
              width: page.width,
              height: page.height,
              rotation: page.rotation,
            ),
          ),
        );
      }

      merged = await pdfrx.PdfDocument.createNew(
        sourceName: 'filo-merge-${job.id}',
      );
      merged.pages = sources.expand((source) => source.pages).toList();
      final bytes = await merged.encodePdf();
      await _verifyPdfBytes(bytes, expectedPages);

      final parent = Directory(
        job.outputDirectory ?? File(job.primaryInputPath).parent.path,
      );
      await parent.create(recursive: true);
      outputFile = await _reserveOutput(job, parent);
      await _outputWriter(outputFile, bytes);
      if (await outputFile.length() != bytes.length) {
        throw const _MergeFailure('The merged PDF could not be written fully.');
      }

      stopwatch.stop();
      return ConversionResult.success(
        jobId: job.id,
        outputPath: outputFile.path,
        duration: stopwatch.elapsed,
      );
    } catch (error) {
      if (outputFile != null) {
        try {
          if (await outputFile.exists()) await outputFile.delete();
        } catch (_) {}
      }
      stopwatch.stop();
      return ConversionResult.failure(
        jobId: job.id,
        errorMessage: error is _MergeFailure
            ? error.message
            : 'PDF merge failed while processing the selected files.',
        duration: stopwatch.elapsed,
      );
    } finally {
      if (merged != null) {
        try {
          await merged.dispose();
        } catch (_) {}
      }
      for (final source in sources.reversed) {
        try {
          await source.dispose();
        } catch (_) {}
      }
    }
  }

  Future<void> _verifyPdfBytes(
    Uint8List bytes,
    List<_PageGeometry> expectedPages,
  ) async {
    if (bytes.length < 12 ||
        !String.fromCharCodes(bytes.take(5)).startsWith('%PDF-') ||
        !String.fromCharCodes(
          bytes.skip(bytes.length > 128 ? bytes.length - 128 : 0),
        ).contains('%%EOF')) {
      throw const _MergeFailure('The merged PDF output is incomplete.');
    }

    pdfrx.PdfDocument? check;
    try {
      check = await pdfrx.PdfDocument.openData(
        bytes,
        sourceName: 'filo-merge-validation-${bytes.length}',
      );
      if (check.pages.length != expectedPages.length) {
        throw const _MergeFailure(
          'The merged PDF did not retain every source page.',
        );
      }
      for (var index = 0; index < expectedPages.length; index++) {
        final expected = expectedPages[index];
        final actual = check.pages[index];
        if ((actual.width - expected.width).abs() > 0.1 ||
            (actual.height - expected.height).abs() > 0.1 ||
            actual.rotation != expected.rotation) {
          throw _MergeFailure(
            'Merged page ${index + 1} did not preserve its dimensions or rotation.',
          );
        }
      }
    } on _MergeFailure {
      rethrow;
    } catch (_) {
      throw const _MergeFailure('The merged PDF output could not be reopened.');
    } finally {
      if (check != null) await check.dispose();
    }
  }

  Future<File> _reserveOutput(ConversionJob job, Directory parent) async {
    final requested = job.requestedOutputName?.trim();
    final initialBase = requested != null && requested.isNotEmpty
        ? _fileManager.extractBaseName(requested)
        : '${_fileManager.extractBaseName(job.primaryInputPath)}_merged';
    for (var index = 0; index < 10000; index++) {
      final baseName = index == 0 ? initialBase : '${initialBase}_$index';
      final candidate = File(
        _fileManager.buildOutputPath(
          directory: parent.path,
          baseName: baseName,
          extension: 'pdf',
        ),
      );
      if (_isInputPath(candidate.path, job.inputPaths)) continue;
      try {
        return await candidate.create(exclusive: true);
      } on FileSystemException {
        if (await FileSystemEntity.type(candidate.path, followLinks: false) ==
            FileSystemEntityType.notFound) {
          rethrow;
        }
      }
    }
    throw const _MergeFailure('Could not reserve a unique output filename.');
  }

  bool _isInputPath(String outputPath, List<String> inputPaths) {
    String key(String path) =>
        File(path).absolute.path.replaceAll('\\', '/').toLowerCase();
    final outputKey = key(outputPath);
    return inputPaths.any((input) => key(input) == outputKey);
  }
}

class _PageGeometry {
  const _PageGeometry({
    required this.width,
    required this.height,
    required this.rotation,
  });

  final double width;
  final double height;
  final pdfrx.PdfPageRotation rotation;
}

class _MergeFailure implements Exception {
  const _MergeFailure(this.message);
  final String message;
}
