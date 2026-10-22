import 'dart:io';
import 'dart:math';

import '../models/conversion_job.dart';
import '../models/conversion_type.dart';
import '../services/platform/file_picker_service.dart';
import 'conversion_workflow.dart';

enum DocumentConversionStatus {
  success,
  cancelled,
  selectionFailed,
  conversionFailed,
  persistenceFailed,
}

/// Structured result from picking, staging, converting, and importing a file.
class DocumentConversionOutcome {
  const DocumentConversionOutcome({
    required this.status,
    this.workflowOutcome,
    this.errorDescription,
    this.cleanupWarning,
  });

  final DocumentConversionStatus status;
  final ConversionWorkflowOutcome? workflowOutcome;
  final String? errorDescription;
  final String? cleanupWarning;

  bool get isSuccess => status == DocumentConversionStatus.success;
  bool get isCancelled => status == DocumentConversionStatus.cancelled;
}

/// Composes file selection with [ConversionWorkflow] without owning conversion,
/// storage, or database logic. Picker-staged inputs are disposed on every path
/// after a valid selection, including exceptions from the workflow.
class DocumentConversionService {
  DocumentConversionService({
    required this.filePickerService,
    required this.conversionWorkflow,
    String Function()? jobIdGenerator,
  }) : _jobIdGenerator = jobIdGenerator ?? _newJobId;

  final FilePickerService filePickerService;
  final ConversionWorkflow conversionWorkflow;
  final String Function() _jobIdGenerator;

  /// Selects and stages inputs without starting the conversion. The returned
  /// selection must be passed to [convertSelection] or disposed by its owner.
  Future<FileSelectionResult> selectInputs(ConversionType conversionType) =>
      filePickerService.selectForConversion(conversionType);

  Future<DocumentConversionOutcome> convert(
    ConversionType conversionType, {
    String? requestedOutputName,
    String? outputDirectory,
  }) async {
    final selectionResult = await selectInputs(conversionType);
    if (selectionResult.isCancelled) {
      return const DocumentConversionOutcome(
        status: DocumentConversionStatus.cancelled,
      );
    }
    final selection = selectionResult.selection;
    if (selection == null) {
      return DocumentConversionOutcome(
        status: DocumentConversionStatus.selectionFailed,
        errorDescription:
            selectionResult.errorDescription ??
            'The selected document could not be prepared.',
      );
    }

    return convertSelection(
      selection,
      requestedOutputName: requestedOutputName,
      outputDirectory: outputDirectory,
    );
  }

  /// Runs an already staged selection without opening the picker again.
  /// This lets the UI show selected filenames and wait for explicit consent.
  Future<DocumentConversionOutcome> convertSelection(
    PickedInputSelection selection, {
    List<String>? inputPaths,
    String? requestedOutputName,
    String? outputDirectory,
  }) async {
    ConversionWorkflowOutcome? workflowOutcome;
    String? errorDescription;
    final cleanupWarnings = <String>[];
    Directory? ownedOutputDirectory;
    try {
      var effectiveOutputDirectory = outputDirectory;
      if (effectiveOutputDirectory == null) {
        ownedOutputDirectory = await conversionWorkflow.fileStorage
            .createConversionTemporaryDirectory();
        effectiveOutputDirectory = ownedOutputDirectory.path;
      }
      final selectedPaths = inputPaths ?? selection.inputPaths;
      final availablePaths = selection.inputPaths.toSet();
      if (selectedPaths.length < selection.conversionType.minimumInputCount ||
          selectedPaths.toSet().length != selectedPaths.length ||
          selectedPaths.any((path) => !availablePaths.contains(path))) {
        throw const FormatException('Invalid staged input selection.');
      }
      final job = ConversionJob(
        id: _jobIdGenerator(),
        inputPaths: selectedPaths,
        conversionType: selection.conversionType,
        requestedOutputName: requestedOutputName,
        outputDirectory: effectiveOutputDirectory,
      );
      workflowOutcome = await conversionWorkflow.run(job);
    } catch (_) {
      errorDescription = 'The conversion could not be completed.';
    } finally {
      try {
        await selection.dispose();
      } catch (_) {
        cleanupWarnings.add(
          'Temporary input cleanup failed; Filo may retry it on a later cleanup pass.',
        );
      }
      final outputDirectory = ownedOutputDirectory;
      if (outputDirectory != null) {
        try {
          await conversionWorkflow.fileStorage
              .deleteConversionTemporaryDirectory(outputDirectory);
        } catch (_) {
          cleanupWarnings.add(
            'Temporary conversion outputs could not be cleaned.',
          );
        }
      }
    }
    final cleanupWarning = cleanupWarnings.isEmpty
        ? null
        : cleanupWarnings.join(' ');

    if (workflowOutcome == null) {
      return DocumentConversionOutcome(
        status: DocumentConversionStatus.conversionFailed,
        errorDescription: errorDescription,
        cleanupWarning: cleanupWarning,
      );
    }

    final status = switch (workflowOutcome.status) {
      ConversionWorkflowStatus.success => DocumentConversionStatus.success,
      ConversionWorkflowStatus.conversionFailed =>
        DocumentConversionStatus.conversionFailed,
      ConversionWorkflowStatus.persistenceFailed =>
        DocumentConversionStatus.persistenceFailed,
    };
    return DocumentConversionOutcome(
      status: status,
      workflowOutcome: workflowOutcome,
      errorDescription: workflowOutcome.errorMessage,
      cleanupWarning: cleanupWarning,
    );
  }

  static String _newJobId() =>
      '${DateTime.now().microsecondsSinceEpoch}_${Random.secure().nextInt(1 << 32).toRadixString(16)}';
}
