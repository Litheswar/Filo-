import 'dart:io';
import 'dart:math';

import '../models/conversion_job.dart';
import '../models/conversion_result.dart';
import '../models/file_record.dart';
import '../services/preview/thumbnail_service.dart';
import '../services/storage/file_storage.dart';
import 'activity_manager.dart';
import 'conversion_manager.dart';
import 'library_manager.dart';

enum ConversionWorkflowStatus { success, conversionFailed, persistenceFailed }

/// Result of conversion plus managed storage and library registration.
class ConversionWorkflowOutcome {
  ConversionWorkflowOutcome({
    required this.status,
    required this.conversionResult,
    Iterable<FileRecord> documents = const [],
    this.errorMessage,
    Iterable<String> compensationFailures = const [],
    Iterable<String> retainedFiles = const [],
  }) : documents = List.unmodifiable(documents),
       compensationFailures = List.unmodifiable(compensationFailures),
       retainedFiles = List.unmodifiable(retainedFiles);

  final ConversionWorkflowStatus status;
  final ConversionResult conversionResult;
  final List<FileRecord> documents;
  final String? errorMessage;
  final List<String> compensationFailures;
  final List<String> retainedFiles;
  bool get isSuccess => status == ConversionWorkflowStatus.success;
}

/// Coordinates one conversion and imports its complete output set into Filo.
/// Files and SQLite cannot share a transaction: failures roll back only records
/// and files created by this invocation, reporting any cleanup that fails.
class ConversionWorkflow {
  ConversionWorkflow({
    required this.conversionManager,
    required this.fileStorage,
    required this.libraryManager,
    required this.activityManager,
    this.thumbnailService,
    this.onLibraryChanged,
    this.onActivityChanged,
    String Function()? idGenerator,
    DateTime Function()? clock,
  }) : _idGenerator = idGenerator ?? _newId,
       _clock = clock ?? DateTime.now;

  final ConversionManager conversionManager;
  final FileStorage fileStorage;
  final LibraryManager libraryManager;
  final ActivityManager activityManager;
  final ThumbnailService? thumbnailService;
  final void Function()? onLibraryChanged;
  final void Function()? onActivityChanged;
  final String Function() _idGenerator;
  final DateTime Function() _clock;

  Future<ConversionWorkflowOutcome> run(ConversionJob job) async {
    ConversionResult result;
    try {
      result = await conversionManager.processJob(job);
    } catch (error) {
      result = ConversionResult.failure(
        jobId: job.id,
        errorMessage: _safeSummary(error),
      );
    }
    if (!result.isSuccess) {
      final error = _safeSummary(result.errorMessage ?? 'Conversion failed.');
      final activityFailure = await _logActivity(job, result, [], false, error);
      return ConversionWorkflowOutcome(
        status: ConversionWorkflowStatus.conversionFailed,
        conversionResult: result,
        errorMessage: activityFailure == null
            ? error
            : '$error Activity history could not be saved.',
        compensationFailures: activityFailure == null ? [] : [activityFailure],
      );
    }

    final createdFiles = <File>[];
    final createdRecords = <FileRecord>[];
    final seenOutputs = <String>{};
    final outputNames = <String>[];
    final createdAt = _clock();
    try {
      final outputPaths = result.outputPaths.isNotEmpty
          ? result.outputPaths
          : (result.outputPath == null ? <String>[] : [result.outputPath!]);
      if (result.jobId != job.id) {
        throw const _WorkflowException(
          'Conversion returned a result for a different job.',
        );
      }
      if (outputPaths.isEmpty) {
        throw const _WorkflowException(
          'Conversion reported success without outputs.',
        );
      }
      final inputPaths = job.inputPaths.map(_pathKey).toSet();
      for (final outputPath in outputPaths) {
        final output = File(outputPath);
        final absolutePath = output.absolute.path;
        final key = _pathKey(absolutePath);
        if (!seenOutputs.add(key)) continue;
        if (inputPaths.contains(key)) {
          throw const _WorkflowException(
            'A conversion output points to an input file.',
          );
        }
        if (await FileSystemEntity.type(absolutePath, followLinks: false) !=
            FileSystemEntityType.file) {
          throw const _WorkflowException(
            'A conversion output is missing or is not a regular file.',
          );
        }
        if (await output.length() <= 0) {
          throw const _WorkflowException('A conversion output is empty.');
        }
        final originalName = _basename(outputPath);
        final managed = await fileStorage.copyToLibrary(
          output,
          fileName: originalName,
        );
        createdFiles.add(managed);
        final metadata = await fileStorage.getMetadata(managed);
        if (metadata.sizeInBytes <= 0) {
          throw const _WorkflowException(
            'A managed output could not be verified.',
          );
        }
        final extension = _extension(metadata.fileName);
        if (extension.isEmpty) {
          throw const _WorkflowException(
            'A conversion output has no file extension.',
          );
        }
        final record = FileRecord(
          id: _idGenerator(),
          fileName: metadata.fileName,
          extension: extension,
          sizeInBytes: metadata.sizeInBytes,
          // The Library sorts newest first. Add a tiny offset so a renderer's
          // ordered multi-page outputs retain their source order there too.
          createdAt: createdAt.add(
            Duration(microseconds: outputPaths.length - createdFiles.length),
          ),
          localPath: metadata.path,
          conversionType: job.conversionType,
          storageLocation: StorageLocation.internalDocuments,
        );
        await libraryManager.addRecord(record);
        createdRecords.add(record);
        var finalRecord = record;
        if (thumbnailService != null) {
          final thumbnail = await thumbnailService!.generate(
            record,
            updateRecord: libraryManager.updateRecord,
          );
          if (thumbnail.isSuccess && thumbnail.path != null) {
            finalRecord = record.copyWith(thumbnailPath: thumbnail.path);
          }
        }
        createdRecords[createdRecords.length - 1] = finalRecord;
        outputNames.add(metadata.fileName);
      }
      if (createdFiles.isEmpty) {
        throw const _WorkflowException(
          'Conversion produced no distinct outputs.',
        );
      }

      final activityFailure = await _logActivity(
        job,
        result,
        outputNames,
        true,
        null,
      );
      if (activityFailure != null) {
        throw _WorkflowException(
          'Activity history could not be saved. $activityFailure',
        );
      }
      onLibraryChanged?.call();
      return ConversionWorkflowOutcome(
        status: ConversionWorkflowStatus.success,
        conversionResult: result,
        documents: createdRecords,
      );
    } catch (error) {
      final summary = error is _WorkflowException
          ? error.message
          : 'Conversion output could not be saved to the library.';
      final cleanupFailures = <String>[];
      for (final record in createdRecords.reversed) {
        try {
          if (!await libraryManager.removeRecord(record.id)) {
            cleanupFailures.add('Library record ${record.fileName} remains.');
          }
        } catch (_) {
          cleanupFailures.add(
            'Library record ${record.fileName} could not be removed.',
          );
        }
        if (record.thumbnailPath != null && thumbnailService != null) {
          try {
            await thumbnailService!.deleteThumbnailForDocument(record);
          } catch (_) {
            cleanupFailures.add(
              'Thumbnail for ${record.fileName} could not be removed.',
            );
          }
        }
      }
      for (final file in createdFiles.reversed) {
        try {
          await fileStorage.deleteStoredFile(file);
        } catch (_) {
          cleanupFailures.add(
            'Managed file ${_basename(file.path)} could not be removed.',
          );
        }
      }
      final activityFailure = await _logActivity(
        job,
        result,
        outputNames,
        false,
        summary,
      );
      if (activityFailure != null) cleanupFailures.add(activityFailure);
      final remaining = <String>[];
      for (final file in createdFiles) {
        try {
          if (await file.exists()) remaining.add(file.path);
        } catch (_) {
          remaining.add(file.path);
        }
      }
      return ConversionWorkflowOutcome(
        status: ConversionWorkflowStatus.persistenceFailed,
        conversionResult: result,
        errorMessage: summary,
        compensationFailures: cleanupFailures,
        retainedFiles: remaining,
      );
    }
  }

  Future<String?> _logActivity(
    ConversionJob job,
    ConversionResult result,
    List<String> outputNames,
    bool success,
    String? error,
  ) async {
    try {
      await activityManager.logActivity(
        ActivityRecord(
          id: _idGenerator(),
          jobId: job.id,
          conversionType: job.conversionType,
          isSuccess: success,
          outputPath: null,
          outputName: outputNames.isEmpty ? null : outputNames.first,
          outputNames: outputNames,
          errorMessage: success
              ? null
              : _safeSummary(error ?? 'Conversion failed.'),
          timestamp: _clock(),
          duration: result.duration,
        ),
      );
      onActivityChanged?.call();
      return null;
    } catch (_) {
      return 'Conversion activity could not be recorded.';
    }
  }

  static String _safeSummary(Object error) {
    final value = error
        .toString()
        .replaceAll(RegExp(r'(?:[A-Za-z]:)?[/\\][^\s,;]+'), '[path]')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
    return value.isEmpty
        ? 'Conversion failed.'
        : value.substring(0, min(value.length, 240));
  }

  static String _pathKey(String path) =>
      File(path).absolute.path.replaceAll('\\', '/').toLowerCase();
  static String _basename(String path) =>
      path.replaceAll('\\', '/').split('/').last;
  static String _extension(String name) {
    final dot = name.lastIndexOf('.');
    return dot < 0 ? '' : name.substring(dot + 1).toLowerCase();
  }

  static String _newId() =>
      '${DateTime.now().microsecondsSinceEpoch}_${Random.secure().nextInt(1 << 32).toRadixString(16)}';
}

class _WorkflowException implements Exception {
  const _WorkflowException(this.message);
  final String message;
}
