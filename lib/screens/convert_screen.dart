import 'dart:async';

import 'package:flutter/material.dart';

import '../app/filo_services.dart';
import '../app/filo_theme.dart';
import '../application/document_conversion_service.dart';
import '../models/conversion_type.dart';
import '../models/file_record.dart';
import '../services/platform/file_export_service.dart';
import '../services/platform/file_picker_service.dart';
import '../services/platform/file_share_service.dart';

class ConvertScreen extends StatefulWidget {
  const ConvertScreen({
    super.key,
    required this.services,
    required this.onOpenLibrary,
  });

  final FiloServices services;
  final VoidCallback onOpenLibrary;

  @override
  State<ConvertScreen> createState() => _ConvertScreenState();
}

class _ConvertScreenState extends State<ConvertScreen> {
  late final List<ConversionType> _availableTypes;
  ConversionType? _selectedType;
  PickedInputSelection? _selection;
  List<PickedInputFile> _orderedSelection = [];
  DocumentConversionOutcome? _outcome;
  String? _selectionError;
  String? _actionMessage;
  bool _isPicking = false;
  bool _isConverting = false;
  String? _activeAction;

  @override
  void initState() {
    super.initState();
    _availableTypes = ConversionType.values
        .where(widget.services.conversionManager.isTypeSupported)
        .toList(growable: false);
    if (_availableTypes.isNotEmpty) _selectedType = _availableTypes.first;
  }

  @override
  void dispose() {
    final selection = _selection;
    if (selection != null) unawaited(_disposeQuietly(selection));
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_availableTypes.isEmpty) {
      return const Center(child: Text('No conversion tools are available.'));
    }
    final running = _isPicking || _isConverting || _activeAction != null;
    return SafeArea(
      top: false,
      child: LayoutBuilder(
        builder: (context, constraints) {
          final columns = constraints.maxWidth >= 700
              ? 3
              : constraints.maxWidth >= 440
              ? 2
              : 1;
          return ListView(
            key: const ValueKey('convert-scroll'),
            padding: const EdgeInsets.fromLTRB(
              FiloSpacing.page,
              FiloSpacing.md,
              FiloSpacing.page,
              FiloSpacing.xl,
            ),
            children: [
              Text(
                'Make more of your files.',
                style: Theme.of(context).textTheme.headlineMedium,
              ),
              const SizedBox(height: FiloSpacing.sm),
              const Text(
                'Choose a conversion. Your original files are left untouched.',
              ),
              const SizedBox(height: FiloSpacing.lg),
              _SectionLabel(
                title: 'Choose a conversion',
                detail: '${_availableTypes.length} formats',
              ),
              const SizedBox(height: FiloSpacing.sm),
              _ConversionChoices(
                types: _availableTypes,
                selected: _selectedType,
                columns: columns,
                enabled: !running,
                onSelected: _selectType,
              ),
              const SizedBox(height: FiloSpacing.lg),
              _buildInputSection(context, running),
              if (_selectionError != null) ...[
                const SizedBox(height: FiloSpacing.sm),
                _InlineMessage(
                  icon: Icons.error_outline_rounded,
                  message: _selectionError!,
                  isError: true,
                ),
              ],
              if (_isConverting) ...[
                const SizedBox(height: FiloSpacing.md),
                const _ProgressCard(
                  label: 'Converting and saving to your library…',
                ),
              ],
              if (_outcome != null) ...[
                const SizedBox(height: FiloSpacing.lg),
                _buildOutcome(context, _outcome!),
              ],
              if (_actionMessage != null) ...[
                const SizedBox(height: FiloSpacing.sm),
                _InlineMessage(
                  icon: Icons.info_outline_rounded,
                  message: _actionMessage!,
                  isError: false,
                ),
              ],
            ],
          );
        },
      ),
    );
  }

  Widget _buildInputSection(BuildContext context, bool running) {
    final type = _selectedType!;
    final selection = _selection;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(FiloSpacing.md),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _SectionLabel(
              title: 'Choose files',
              detail: type.requiresMultipleInputs
                  ? type == ConversionType.pdfMerge
                        ? 'Select at least two PDFs'
                        : 'Select multiple images'
                  : 'One file',
            ),
            const SizedBox(height: FiloSpacing.xs),
            Text(
              selection == null
                  ? _selectionGuidance(type)
                  : '${_orderedSelection.length} ${_orderedSelection.length == 1 ? 'file' : 'files'} selected',
            ),
            if (selection != null) ...[
              const SizedBox(height: FiloSpacing.sm),
              ..._orderedSelection.indexed.map((entry) {
                final (index, file) = entry;
                return Padding(
                  padding: const EdgeInsets.only(top: FiloSpacing.xs),
                  child: Row(
                    children: [
                      SizedBox(width: 24, child: Text('${index + 1}.')),
                      const Icon(Icons.insert_drive_file_outlined, size: 20),
                      const SizedBox(width: FiloSpacing.sm),
                      Expanded(
                        child: Text(
                          file.name,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      if (type == ConversionType.pdfMerge) ...[
                        IconButton(
                          tooltip: 'Move ${file.name} up',
                          visualDensity: VisualDensity.compact,
                          onPressed: running || index == 0
                              ? null
                              : () => _moveSelectedFile(index, index - 1),
                          icon: const Icon(Icons.arrow_upward_rounded),
                        ),
                        IconButton(
                          tooltip: 'Move ${file.name} down',
                          visualDensity: VisualDensity.compact,
                          onPressed:
                              running || index == _orderedSelection.length - 1
                              ? null
                              : () => _moveSelectedFile(index, index + 1),
                          icon: const Icon(Icons.arrow_downward_rounded),
                        ),
                        IconButton(
                          tooltip: 'Remove ${file.name}',
                          visualDensity: VisualDensity.compact,
                          onPressed: running
                              ? null
                              : () => _removeSelectedFile(index),
                          icon: const Icon(Icons.close_rounded),
                        ),
                      ],
                    ],
                  ),
                );
              }),
            ],
            const SizedBox(height: FiloSpacing.md),
            SizedBox(
              width: double.infinity,
              child: OutlinedButton.icon(
                onPressed: running ? null : _selectFiles,
                icon: _isPicking
                    ? const SizedBox.square(
                        dimension: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : Icon(
                        selection == null
                            ? Icons.attach_file_rounded
                            : Icons.edit_outlined,
                      ),
                label: Text(
                  _isPicking
                      ? 'Opening files…'
                      : selection == null
                      ? 'Select files'
                      : 'Change files',
                ),
              ),
            ),
            if (selection != null) ...[
              const SizedBox(height: FiloSpacing.sm),
              SizedBox(
                width: double.infinity,
                child: FilledButton.icon(
                  onPressed: running ? null : _convert,
                  icon: const Icon(Icons.swap_horiz_rounded),
                  label: const Text('Convert and save'),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildOutcome(
    BuildContext context,
    DocumentConversionOutcome outcome,
  ) {
    final workflow = outcome.workflowOutcome;
    final records = workflow?.documents ?? const <FileRecord>[];
    final successful =
        outcome.status == DocumentConversionStatus.success &&
        workflow?.isSuccess == true &&
        records.isNotEmpty;
    final partial = !successful && records.isNotEmpty;
    final title = successful
        ? 'Conversion complete'
        : partial
        ? 'Partially complete'
        : 'Conversion wasn’t completed';
    final message = successful
        ? '${records.length} ${records.length == 1 ? 'file was' : 'files were'} saved in your Filo library.'
        : partial
        ? 'Some outputs were saved. Review the available files below and the message that follows.'
        : _outcomeMessage(outcome);

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(FiloSpacing.md),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(
                  successful
                      ? Icons.check_circle_rounded
                      : partial
                      ? Icons.warning_amber_rounded
                      : Icons.error_outline_rounded,
                  color: successful ? FiloColors.green : FiloColors.warning,
                ),
                const SizedBox(width: FiloSpacing.sm),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        title,
                        style: Theme.of(context).textTheme.titleMedium,
                      ),
                      const SizedBox(height: FiloSpacing.xs),
                      Text(message),
                    ],
                  ),
                ),
              ],
            ),
            if (records.isNotEmpty) ...[
              const SizedBox(height: FiloSpacing.md),
              for (var index = 0; index < records.length; index++)
                _OutputRow(
                  record: records[index],
                  index: index,
                  activeAction: _activeAction,
                  onExport: () => _export(records[index]),
                  onShare: () => _share(records[index]),
                ),
            ],
            if (partial && outcome.errorDescription != null) ...[
              const SizedBox(height: FiloSpacing.sm),
              Text(outcome.errorDescription!),
            ],
            if (!successful && !partial) ...[
              if (workflow?.retainedFiles.isNotEmpty == true) ...[
                const SizedBox(height: FiloSpacing.sm),
                const Text(
                  'Temporary output files could not be fully cleaned up.',
                ),
              ],
              if (workflow?.compensationFailures.isNotEmpty == true) ...[
                const SizedBox(height: FiloSpacing.sm),
                const Text(
                  'Some failed outputs may need cleanup before retrying.',
                ),
              ],
            ],
            if (outcome.cleanupWarning != null) ...[
              const SizedBox(height: FiloSpacing.sm),
              Text(outcome.cleanupWarning!),
            ],
            const SizedBox(height: FiloSpacing.md),
            Wrap(
              spacing: FiloSpacing.sm,
              runSpacing: FiloSpacing.sm,
              children: [
                if (successful || partial)
                  OutlinedButton.icon(
                    onPressed: _activeAction == null
                        ? widget.onOpenLibrary
                        : null,
                    icon: const Icon(Icons.folder_open_rounded),
                    label: const Text('Open library'),
                  ),
                FilledButton.icon(
                  onPressed: _activeAction == null ? _startAnother : null,
                  icon: const Icon(Icons.add_rounded),
                  label: const Text('Another conversion'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _selectType(ConversionType type) async {
    if (_selectedType == type || _isPicking || _isConverting) return;
    final selection = _selection;
    setState(() {
      _selectedType = type;
      _selection = null;
      _orderedSelection = [];
      _outcome = null;
      _selectionError = null;
      _actionMessage = null;
    });
    if (selection != null) await _disposeQuietly(selection);
  }

  Future<void> _selectFiles() async {
    final type = _selectedType;
    if (type == null || _isPicking || _isConverting || _activeAction != null) {
      return;
    }
    final previous = _selection;
    setState(() {
      _isPicking = true;
      _selection = null;
      _selectionError = null;
      _actionMessage = null;
    });
    if (previous != null) await _disposeQuietly(previous);
    if (!mounted) return;
    final allowAlways = await widget.services.filePickerConsentStore
        .getAllowAlways()
        .catchError((_) => false);
    if (!mounted) return;
    if (!allowAlways) {
      final choice = await showDialog<_PickerConsentChoice>(
        context: context,
        barrierDismissible: false,
        builder: (context) => AlertDialog(
          title: const Text('Allow file access?'),
          content: const Text(
            'Filo needs your permission to open the system file picker so you '
            'can select files to convert. The picker only provides access to '
            'the files you choose.',
          ),
          actions: [
            TextButton(
              onPressed: () =>
                  Navigator.pop(context, _PickerConsentChoice.deny),
              child: const Text('Don’t allow'),
            ),
            TextButton(
              onPressed: () =>
                  Navigator.pop(context, _PickerConsentChoice.once),
              child: const Text('Allow once'),
            ),
            FilledButton(
              onPressed: () =>
                  Navigator.pop(context, _PickerConsentChoice.always),
              child: const Text('Allow always'),
            ),
          ],
        ),
      );
      if (!mounted) return;
      if (choice == _PickerConsentChoice.always) {
        try {
          await widget.services.filePickerConsentStore.setAllowAlways(true);
        } catch (_) {
          setState(() {
            _isPicking = false;
            _selectionError = 'Your preference could not be saved. Try again.';
          });
          return;
        }
      }
      if (choice == null || choice == _PickerConsentChoice.deny) {
        setState(() {
          _isPicking = false;
          _actionMessage = 'File selection was cancelled. You can try again whenever you’re ready.';
        });
        return;
      }
    }
    FileSelectionResult result;
    try {
      result = await widget.services.documentConversionService.selectInputs(
        type,
      );
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _isPicking = false;
        _selectionError = 'The file picker could not be opened. Try again.';
      });
      return;
    }
    if (!mounted) {
      final unclaimed = result.selection;
      if (unclaimed != null) await _disposeQuietly(unclaimed);
      return;
    }
    setState(() {
      _isPicking = false;
      if (result.isSelected && result.selection != null) {
        _selection = result.selection;
        _orderedSelection = List.of(result.selection!.files);
        _outcome = null;
      } else if (result.isCancelled) {
        _actionMessage = 'No file was selected.';
      } else if (!result.isCancelled) {
        _selectionError =
            result.errorDescription ??
            'Those files could not be selected. Try a supported file.';
      }
    });
  }

  Future<void> _convert() async {
    final selection = _selection;
    if (selection == null || _isPicking || _isConverting) return;
    if (_orderedSelection.length < selection.conversionType.minimumInputCount) {
      setState(() {
        _selectionError = selection.conversionType == ConversionType.pdfMerge
            ? 'Keep at least two PDF files selected to merge.'
            : 'Keep at least two images selected to create a PDF.';
      });
      return;
    }
    final inputPaths = List<String>.unmodifiable(
      _orderedSelection.map((file) => file.path),
    );
    setState(() {
      _isConverting = true;
      _selection = null;
      _selectionError = null;
      _actionMessage = null;
      _outcome = null;
    });
    try {
      final result = await widget.services.documentConversionService
          .convertSelection(
            selection,
            inputPaths: selection.conversionType.requiresMultipleInputs
                ? inputPaths
                : null,
          );
      if (!mounted) return;
      setState(() {
        _isConverting = false;
        _outcome = result;
      });
    } catch (_) {
      await _disposeQuietly(selection);
      if (!mounted) return;
      setState(() {
        _isConverting = false;
        _outcome = const DocumentConversionOutcome(
          status: DocumentConversionStatus.conversionFailed,
          errorDescription: 'The conversion could not be completed. Try again.',
        );
      });
    }
  }

  void _moveSelectedFile(int from, int to) {
    if (from < 0 ||
        to < 0 ||
        from >= _orderedSelection.length ||
        to >= _orderedSelection.length) {
      return;
    }
    setState(() {
      final file = _orderedSelection.removeAt(from);
      _orderedSelection.insert(to, file);
      _selectionError = null;
    });
  }

  void _removeSelectedFile(int index) {
    if (index < 0 || index >= _orderedSelection.length) return;
    setState(() {
      _orderedSelection.removeAt(index);
      _selectionError = null;
    });
  }

  Future<void> _export(FileRecord record) async {
    if (_activeAction != null) return;
    final action = 'export:${record.id}';
    setState(() {
      _activeAction = action;
      _actionMessage = null;
    });
    FileExportResult result;
    try {
      result = await widget.services.fileExportService.exportDocument(record);
    } catch (_) {
      result = const FileExportResult.failure(
        'The document could not be exported. Try again.',
      );
    }
    if (!mounted) return;
    setState(() {
      _activeAction = null;
      _actionMessage = switch (result.status) {
        FileExportStatus.success => 'Saved a copy to the location you chose.',
        FileExportStatus.cancelled => null,
        FileExportStatus.failure =>
          result.errorDescription ?? 'The document could not be exported.',
      };
    });
  }

  Future<void> _share(FileRecord record) async {
    if (_activeAction != null) return;
    final action = 'share:${record.id}';
    setState(() {
      _activeAction = action;
      _actionMessage = null;
    });
    FileShareResult result;
    try {
      result = await widget.services.fileShareService.shareDocument(record);
    } catch (_) {
      result = const FileShareResult.failure(
        'The document could not be shared. Try again.',
      );
    }
    if (!mounted) return;
    setState(() {
      _activeAction = null;
      _actionMessage = switch (result.status) {
        FileShareStatus.actionSelected =>
          'The share action was selected. Delivery is not confirmed.',
        FileShareStatus.dismissed => null,
        FileShareStatus.outcomeUnavailable =>
          'The share sheet closed; Filo could not determine the outcome.',
        FileShareStatus.failure =>
          result.errorDescription ?? 'The document could not be shared.',
      };
    });
  }

  Future<void> _startAnother() async {
    if (_activeAction != null) return;
    final selection = _selection;
    setState(() {
      _selection = null;
      _outcome = null;
      _selectionError = null;
      _actionMessage = null;
    });
    if (selection != null) await _disposeQuietly(selection);
  }

  Future<void> _disposeQuietly(PickedInputSelection selection) async {
    try {
      await selection.dispose();
    } catch (_) {
      // FileStorage retries stale temporary-input cleanup during initialization.
    }
  }

  String _selectionGuidance(ConversionType type) => type.requiresMultipleInputs
      ? type == ConversionType.pdfMerge
            ? 'Choose two or more PDFs. You can change their order before merging.'
            : 'Choose two or more JPG or PNG images. Their picker order becomes the PDF page order.'
      : 'Choose one ${_acceptedFormat(type)} file. It will be copied into temporary app storage before conversion.';

  String _acceptedFormat(ConversionType type) => switch (type) {
    ConversionType.jpgToPng => 'JPG',
    ConversionType.pngToJpg => 'PNG',
    ConversionType.singleImageToPdf => 'JPG or PNG image',
    ConversionType.multipleImagesToPdf => 'JPG or PNG image',
    ConversionType.pdfToImages ||
    ConversionType.pdfToTxt ||
    ConversionType.pdfMerge => 'PDF',
    ConversionType.txtToPdf => 'TXT',
  };

  String _outcomeMessage(DocumentConversionOutcome outcome) {
    if (outcome.status == DocumentConversionStatus.cancelled) {
      return 'The conversion was cancelled.';
    }
    return outcome.errorDescription ??
        switch (outcome.status) {
          DocumentConversionStatus.success => 'No saved document was returned.',
          DocumentConversionStatus.cancelled => 'The conversion was cancelled.',
          DocumentConversionStatus.selectionFailed =>
            'The selected file could not be prepared.',
          DocumentConversionStatus.conversionFailed =>
            'The file could not be converted.',
          DocumentConversionStatus.persistenceFailed =>
            'The converted file could not be saved in your library.',
        };
  }
}

enum _PickerConsentChoice { once, always, deny }

class _ConversionChoices extends StatelessWidget {
  const _ConversionChoices({
    required this.types,
    required this.selected,
    required this.columns,
    required this.enabled,
    required this.onSelected,
  });

  final List<ConversionType> types;
  final ConversionType? selected;
  final int columns;
  final bool enabled;
  final ValueChanged<ConversionType> onSelected;

  @override
  Widget build(BuildContext context) {
    const gap = FiloSpacing.sm;
    return LayoutBuilder(
      builder: (context, constraints) {
        final width = (constraints.maxWidth - gap * (columns - 1)) / columns;
        return Wrap(
          spacing: gap,
          runSpacing: gap,
          children: [
            for (final type in types)
              SizedBox(
                width: width,
                child: _ConversionChoice(
                  type: type,
                  selected: selected == type,
                  enabled: enabled,
                  onTap: () => onSelected(type),
                ),
              ),
          ],
        );
      },
    );
  }
}

class _ConversionChoice extends StatelessWidget {
  const _ConversionChoice({
    required this.type,
    required this.selected,
    required this.enabled,
    required this.onTap,
  });

  final ConversionType type;
  final bool selected;
  final bool enabled;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Semantics(
    button: true,
    selected: selected,
    label: '${type.displayName}. ${_description(type)}',
    child: Card(
      key: ValueKey('choice-${type.name}'),
      color: selected ? FiloColors.greenPale : null,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(FiloRadii.control),
        side: BorderSide(
          color: selected ? FiloColors.green : FiloColors.border,
          width: selected ? 1.5 : 1,
        ),
      ),
      child: InkWell(
        onTap: enabled ? onTap : null,
        borderRadius: BorderRadius.circular(FiloRadii.control),
        child: Padding(
          padding: const EdgeInsets.all(FiloSpacing.md),
          child: Row(
            children: [
              Icon(
                _icon(type),
                color: selected ? FiloColors.green : FiloColors.mutedInk,
              ),
              const SizedBox(width: FiloSpacing.sm),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      type.displayName,
                      style: Theme.of(context).textTheme.titleSmall,
                    ),
                    const SizedBox(height: FiloSpacing.xs),
                    Text(
                      _description(type),
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ],
                ),
              ),
              if (selected)
                const Icon(
                  Icons.check_circle_rounded,
                  color: FiloColors.green,
                  size: 20,
                ),
            ],
          ),
        ),
      ),
    ),
  );

  static IconData _icon(ConversionType type) => switch (type) {
    ConversionType.jpgToPng || ConversionType.pngToJpg => Icons.image_outlined,
    ConversionType.singleImageToPdf ||
    ConversionType.multipleImagesToPdf => Icons.picture_as_pdf_outlined,
    ConversionType.pdfToImages => Icons.photo_library_outlined,
    ConversionType.pdfMerge => Icons.merge_type_rounded,
    ConversionType.txtToPdf => Icons.description_outlined,
    ConversionType.pdfToTxt => Icons.text_snippet_outlined,
  };

  static String _description(ConversionType type) => switch (type) {
    ConversionType.jpgToPng => 'Convert one JPG image to PNG.',
    ConversionType.pngToJpg => 'Convert one PNG image to JPG.',
    ConversionType.singleImageToPdf => 'Create a PDF from one image.',
    ConversionType.multipleImagesToPdf => 'Combine images into a PDF.',
    ConversionType.pdfToImages => 'Render each PDF page as an image.',
    ConversionType.pdfMerge => 'Combine two or more PDFs in your chosen order.',
    ConversionType.txtToPdf => 'Turn a text file into a PDF.',
    ConversionType.pdfToTxt => 'Extract selectable text from a PDF.',
  };
}

class _SectionLabel extends StatelessWidget {
  const _SectionLabel({required this.title, this.detail});

  final String title;
  final String? detail;

  @override
  Widget build(BuildContext context) => Row(
    children: [
      Expanded(
        child: Text(title, style: Theme.of(context).textTheme.titleMedium),
      ),
      if (detail != null)
        Text(detail!, style: Theme.of(context).textTheme.bodySmall),
    ],
  );
}

class _ProgressCard extends StatelessWidget {
  const _ProgressCard({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) => Card(
    child: Padding(
      padding: const EdgeInsets.all(FiloSpacing.md),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label),
          const SizedBox(height: FiloSpacing.md),
          const LinearProgressIndicator(),
        ],
      ),
    ),
  );
}

class _OutputRow extends StatelessWidget {
  const _OutputRow({
    required this.record,
    required this.index,
    required this.activeAction,
    required this.onExport,
    required this.onShare,
  });

  final FileRecord record;
  final int index;
  final String? activeAction;
  final VoidCallback onExport;
  final VoidCallback onShare;

  @override
  Widget build(BuildContext context) {
    final busy = activeAction != null;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(FiloSpacing.md),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                CircleAvatar(
                  radius: 17,
                  backgroundColor: FiloColors.greenPale,
                  foregroundColor: FiloColors.greenDark,
                  child: Text('${index + 1}'),
                ),
                const SizedBox(width: FiloSpacing.sm),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        record.fileName,
                        style: Theme.of(context).textTheme.titleSmall,
                      ),
                      Text(
                        '${record.extension.toUpperCase()} · ${_formatSize(record.sizeInBytes)}',
                      ),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: FiloSpacing.sm),
            Wrap(
              spacing: FiloSpacing.sm,
              children: [
                OutlinedButton.icon(
                  onPressed: busy ? null : onExport,
                  icon: activeAction == 'export:${record.id}'
                      ? const SizedBox.square(
                          dimension: 16,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.save_alt_rounded),
                  label: const Text('Export'),
                ),
                OutlinedButton.icon(
                  onPressed: busy ? null : onShare,
                  icon: activeAction == 'share:${record.id}'
                      ? const SizedBox.square(
                          dimension: 16,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.ios_share_rounded),
                  label: const Text('Share'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  static String _formatSize(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
  }
}

class _InlineMessage extends StatelessWidget {
  const _InlineMessage({
    required this.icon,
    required this.message,
    required this.isError,
  });

  final IconData icon;
  final String message;
  final bool isError;

  @override
  Widget build(BuildContext context) => Semantics(
    liveRegion: true,
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(
          icon,
          size: 20,
          color: isError
              ? Theme.of(context).colorScheme.error
              : FiloColors.mutedInk,
        ),
        const SizedBox(width: FiloSpacing.sm),
        Expanded(child: Text(message)),
      ],
    ),
  );
}
