import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:pdfrx/pdfrx.dart';

import '../app/filo_services.dart';
import '../app/filo_theme.dart';
import '../application/sqlite_library_manager.dart';
import '../models/conversion_type.dart';
import '../models/file_record.dart';
import '../services/platform/file_share_service.dart';
import '../services/preview/text_preview_service.dart';
import '../widgets/empty_state.dart';

class LibraryScreen extends StatefulWidget {
  const LibraryScreen({
    super.key,
    required this.services,
    required this.onConvert,
  });

  final FiloServices services;
  final VoidCallback onConvert;

  @override
  State<LibraryScreen> createState() => _LibraryScreenState();
}

class _LibraryScreenState extends State<LibraryScreen> {
  final _searchController = TextEditingController();
  Timer? _searchDebounce;
  List<FileRecord> _records = const [];
  int _totalCount = 0;
  Set<String> _extensions = const {};
  String? _extension;
  ConversionType? _conversionType;
  LibrarySortField _sortBy = LibrarySortField.createdAt;
  bool _ascending = false;
  bool _grid = true;
  bool _loading = true;
  bool _operating = false;
  String? _operationLabel;
  String? _error;
  Future<void>? _loadTask;
  bool _loadPending = false;

  @override
  void initState() {
    super.initState();
    widget.services.libraryChanges.addListener(_onLibraryChanged);
    _load();
  }

  void _onLibraryChanged() {
    if (mounted) _load();
  }

  @override
  void dispose() {
    _searchDebounce?.cancel();
    widget.services.libraryChanges.removeListener(_onLibraryChanged);
    _searchController.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final current = _loadTask;
    if (current != null) {
      _loadPending = true;
      return current;
    }
    final task = _performLoad();
    _loadTask = task;
    unawaited(
      task.whenComplete(() {
        if (identical(_loadTask, task)) _loadTask = null;
        if (_loadPending && mounted) {
          _loadPending = false;
          unawaited(_load());
        }
      }),
    );
    return task;
  }

  Future<void> _performLoad() async {
    setState(() {
      if (_records.isEmpty) _loading = true;
      _error = null;
    });
    try {
      final manager = widget.services.libraryManager;
      final hasFilters =
          _searchController.text.trim().isNotEmpty ||
          _extension != null ||
          _conversionType != null;
      final results = await manager.getDocuments(
        searchQuery: _searchController.text,
        extension: _extension,
        conversionType: _conversionType,
        sortBy: _sortBy,
        ascending: _ascending,
      );
      final summary = hasFilters ? await manager.getSummary() : null;
      if (!mounted) return;
      setState(() {
        _totalCount = summary?.totalCount ?? results.length;
        _extensions =
            summary?.extensions ??
            results.map((record) => record.extension.toLowerCase()).toSet();
        _records = results;
        _loading = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error =
            'Filo could not load your library. Check storage and try again.';
      });
    }
  }

  void _onSearchChanged(String _) {
    _searchDebounce?.cancel();
    _searchDebounce = Timer(const Duration(milliseconds: 300), _load);
  }

  @override
  Widget build(BuildContext context) => SafeArea(
    top: false,
    child: RefreshIndicator(
      onRefresh: _load,
      child: CustomScrollView(
        key: const ValueKey('library-scroll'),
        physics: const AlwaysScrollableScrollPhysics(),
        slivers: [
          SliverPadding(
            padding: const EdgeInsets.fromLTRB(
              FiloSpacing.page,
              12,
              FiloSpacing.page,
              FiloSpacing.md,
            ),
            sliver: SliverToBoxAdapter(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Your documents',
                    style: Theme.of(context).textTheme.headlineMedium,
                  ),
                  const SizedBox(height: FiloSpacing.xs),
                  Text(
                    '$_totalCount ${_totalCount == 1 ? 'document' : 'documents'}',
                    key: const ValueKey('library-count'),
                  ),
                  const SizedBox(height: FiloSpacing.md),
                  _PrivacyNote(
                    onAbout: () => Navigator.of(context).pushNamed('/welcome'),
                  ),
                  const SizedBox(height: FiloSpacing.md),
                  TextField(
                    controller: _searchController,
                    onChanged: _onSearchChanged,
                    textInputAction: TextInputAction.search,
                    decoration: InputDecoration(
                      labelText: 'Search documents',
                      prefixIcon: const Icon(Icons.search_rounded),
                      suffixIcon: _searchController.text.isEmpty
                          ? null
                          : IconButton(
                              tooltip: 'Clear search',
                              onPressed: () {
                                _searchController.clear();
                                _load();
                              },
                              icon: const Icon(Icons.clear_rounded),
                            ),
                    ),
                  ),
                  const SizedBox(height: FiloSpacing.sm),
                  Wrap(
                    spacing: FiloSpacing.sm,
                    runSpacing: FiloSpacing.sm,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    children: [
                      _FilterMenu<String?>(
                        label: _extension == null
                            ? 'All types'
                            : '.${_extension!}',
                        icon: Icons.filter_list_rounded,
                        value: _extension,
                        values: [null, ..._extensions.toList()..sort()],
                        title: 'File type',
                        labelFor: (value) => value == null
                            ? 'All types'
                            : '.${value.toUpperCase()}',
                        onChanged: (value) {
                          setState(() => _extension = value);
                          _load();
                        },
                      ),
                      _FilterMenu<ConversionType?>(
                        label:
                            _conversionType?.displayName ?? 'All conversions',
                        icon: Icons.swap_horiz_rounded,
                        value: _conversionType,
                        values: [null, ...ConversionType.values],
                        title: 'Conversion type',
                        labelFor: (value) =>
                            value?.displayName ?? 'All conversions',
                        onChanged: (value) {
                          setState(() => _conversionType = value);
                          _load();
                        },
                      ),
                      _FilterMenu<LibrarySortField>(
                        label: _sortLabel(_sortBy),
                        icon: Icons.sort_rounded,
                        value: _sortBy,
                        values: LibrarySortField.values,
                        title: 'Sort documents',
                        labelFor: _sortLabel,
                        onChanged: (value) {
                          setState(() => _sortBy = value);
                          _load();
                        },
                      ),
                      IconButton.filledTonal(
                        tooltip: _ascending
                            ? 'Reverse sort order'
                            : 'Reverse sort order',
                        onPressed: () {
                          setState(() => _ascending = !_ascending);
                          _load();
                        },
                        icon: Icon(
                          _ascending
                              ? Icons.arrow_upward_rounded
                              : Icons.arrow_downward_rounded,
                        ),
                      ),
                      IconButton.filledTonal(
                        tooltip: _grid
                            ? 'Switch to list view'
                            : 'Switch to grid view',
                        onPressed: () => setState(() => _grid = !_grid),
                        icon: Icon(
                          _grid
                              ? Icons.view_list_rounded
                              : Icons.grid_view_rounded,
                        ),
                      ),
                    ],
                  ),
                  if (_error != null && _records.isNotEmpty) ...[
                    const SizedBox(height: FiloSpacing.sm),
                    Row(
                      children: [
                        Expanded(child: Text(_error!)),
                        TextButton.icon(
                          onPressed: _load,
                          icon: const Icon(Icons.refresh_rounded),
                          label: const Text('Retry'),
                        ),
                      ],
                    ),
                  ],
                  if (_operating) ...[
                    const SizedBox(height: FiloSpacing.sm),
                    Row(
                      children: [
                        const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        ),
                        const SizedBox(width: FiloSpacing.sm),
                        Text(_operationLabel ?? 'Working…'),
                      ],
                    ),
                  ],
                ],
              ),
            ),
          ),
          if (_loading)
            SliverToBoxAdapter(
              child: SizedBox(
                height: 96,
                child: Center(
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Icon(Icons.folder_open_outlined, size: 24),
                      const SizedBox(width: FiloSpacing.sm),
                      Text(
                        'Loading your library…',
                        style: Theme.of(context).textTheme.bodyMedium,
                      ),
                    ],
                  ),
                ),
              ),
            )
          else if (_error != null && _records.isEmpty)
            SliverToBoxAdapter(
              child: SizedBox(
                height: 360,
                child: EmptyState(
                  icon: Icons.cloud_off_rounded,
                  title: 'Library unavailable',
                  description: _error!,
                  action: FilledButton.icon(
                    onPressed: _load,
                    icon: const Icon(Icons.refresh_rounded),
                    label: const Text('Try again'),
                  ),
                ),
              ),
            )
          else if (_records.isEmpty)
            SliverToBoxAdapter(
              child: SizedBox(
                height: 360,
                child: EmptyState(
                  icon: Icons.folder_open_rounded,
                  title: _hasFilters
                      ? 'No matching documents'
                      : 'Your library is empty',
                  description: _hasFilters
                      ? 'Try changing or clearing your search and filters.'
                      : 'Documents you save from conversions will appear here.',
                  action: _hasFilters
                      ? TextButton(
                          onPressed: _clearFilters,
                          child: const Text('Clear search and filters'),
                        )
                      : FilledButton.icon(
                          onPressed: widget.onConvert,
                          icon: const Icon(Icons.swap_horiz_rounded),
                          label: const Text('Start a conversion'),
                        ),
                ),
              ),
            )
          else if (_grid)
            SliverPadding(
              padding: const EdgeInsets.fromLTRB(
                FiloSpacing.page,
                0,
                FiloSpacing.page,
                FiloSpacing.xl,
              ),
              sliver: SliverLayoutBuilder(
                builder: (context, constraints) {
                  final width = constraints.crossAxisExtent;
                  final count = width >= 760
                      ? 4
                      : width >= 520
                      ? 3
                      : 2;
                  return SliverGrid.builder(
                    gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                      crossAxisCount: count,
                      mainAxisSpacing: FiloSpacing.md,
                      crossAxisSpacing: FiloSpacing.md,
                      childAspectRatio: width < 380 ? 0.84 : 0.92,
                    ),
                    itemCount: _records.length,
                    itemBuilder: (context, index) => _DocumentCard(
                      record: _records[index],
                      services: widget.services,
                      onOpen: () => _open(_records[index]),
                      onRename: () => _rename(_records[index]),
                      onDelete: () => _delete(_records[index]),
                      onExport: () => _export(_records[index]),
                      onShare: () => _share(_records[index]),
                    ),
                  );
                },
              ),
            )
          else
            SliverPadding(
              padding: const EdgeInsets.fromLTRB(
                FiloSpacing.page,
                0,
                FiloSpacing.page,
                FiloSpacing.xl,
              ),
              sliver: SliverList.builder(
                itemCount: _records.length,
                itemBuilder: (context, index) => Padding(
                  padding: const EdgeInsets.only(bottom: FiloSpacing.sm),
                  child: _DocumentRow(
                    record: _records[index],
                    services: widget.services,
                    onOpen: () => _open(_records[index]),
                    onRename: () => _rename(_records[index]),
                    onDelete: () => _delete(_records[index]),
                    onExport: () => _export(_records[index]),
                    onShare: () => _share(_records[index]),
                  ),
                ),
              ),
            ),
        ],
      ),
    ),
  );

  bool get _hasFilters =>
      _searchController.text.trim().isNotEmpty ||
      _extension != null ||
      _conversionType != null;

  void _clearFilters() {
    _searchDebounce?.cancel();
    _searchController.clear();
    setState(() {
      _extension = null;
      _conversionType = null;
    });
    _load();
  }

  Future<void> _open(FileRecord record) async {
    try {
      final detail = await widget.services.libraryManager.getDocumentDetails(
        record.id,
      );
      if (!mounted) return;
      if (detail == null || !detail.fileExists) {
        _message('This document is no longer available in Filo.');
        await _load();
        return;
      }
      await Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (_) => DocumentPreviewScreen(
            record: detail.record,
            services: widget.services,
            onRename: _rename,
            onDelete: _delete,
            onExport: _export,
            onShare: _share,
          ),
        ),
      );
      if (mounted) _load();
    } catch (_) {
      if (mounted) _message('Filo could not open this document.');
    }
  }

  Future<FileRecord?> _rename(FileRecord record) async {
    if (_operating) return null;
    _beginOperation('Renaming document…');
    try {
      final renamed = await showDialog<bool>(
        context: context,
        builder: (_) => _RenameDialog(
          record: record,
          onSave: (name) =>
              widget.services.libraryManager.renameDocument(record.id, name),
        ),
      );
      if (renamed == true && mounted) {
        widget.services.notifyManagedFilesChanged();
        _message('Document renamed.');
        return await widget.services.libraryManager.getRecordById(record.id);
      }
      return null;
    } finally {
      _endOperation();
    }
  }

  Future<bool?> _delete(FileRecord record) async {
    if (_operating) return null;
    _beginOperation('Waiting for confirmation…');
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete document?'),
        content: Text(
          '“${record.fileName}” will be removed from Filo storage.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) {
      _endOperation();
      return null;
    }
    setState(() => _operationLabel = 'Deleting document…');
    try {
      final deleted = await widget.services.libraryManager.deleteDocument(
        record.id,
      );
      if (deleted) widget.services.notifyManagedFilesChanged();
      if (mounted) {
        _message(
          deleted ? 'Document deleted.' : 'Document was already removed.',
        );
        if (!deleted) await _load();
        return deleted;
      }
    } catch (error) {
      if (mounted) {
        _message(_safeError(error, 'The document could not be fully deleted.'));
        await _load();
        return false;
      }
    } finally {
      _endOperation();
    }
    return null;
  }

  Future<void> _export(FileRecord record) async {
    if (_operating) return;
    _beginOperation('Exporting document…');
    try {
      final result = await widget.services.fileExportService.exportDocument(
        record,
      );
      if (!mounted || result.isCancelled) return;
      _message(
        result.isSuccess
            ? 'Document exported.'
            : (result.errorDescription ?? 'Export failed.'),
      );
    } finally {
      _endOperation();
    }
  }

  Future<void> _share(FileRecord record) async {
    if (_operating) return;
    _beginOperation('Preparing share sheet…');
    try {
      final result = await widget.services.fileShareService.shareDocument(
        record,
      );
      if (!mounted || result.status == FileShareStatus.dismissed) return;
      final message = switch (result.status) {
        FileShareStatus.actionSelected =>
          'Share action selected. Delivery is not confirmed.',
        FileShareStatus.outcomeUnavailable =>
          'The share result is unavailable on this device.',
        FileShareStatus.failure =>
          result.errorDescription ?? 'The document could not be shared.',
        FileShareStatus.dismissed => '',
      };
      if (message.isNotEmpty) _message(message);
    } finally {
      _endOperation();
    }
  }

  void _beginOperation(String label) => setState(() {
    _operating = true;
    _operationLabel = label;
  });

  void _endOperation() {
    if (!mounted) return;
    setState(() {
      _operating = false;
      _operationLabel = null;
    });
  }

  String _safeError(Object error, String fallback) =>
      error is LibraryOperationException ? error.message : fallback;

  void _message(String message) => ScaffoldMessenger.of(context)
    ..hideCurrentSnackBar()
    ..showSnackBar(SnackBar(content: Text(message)));
}

String _sortLabel(LibrarySortField value) => switch (value) {
  LibrarySortField.fileName => 'Name',
  LibrarySortField.createdAt => 'Date added',
  LibrarySortField.fileSize => 'Size',
  LibrarySortField.extension => 'Type',
};

class _FilterMenu<T> extends StatelessWidget {
  const _FilterMenu({
    required this.label,
    required this.icon,
    required this.value,
    required this.values,
    required this.title,
    required this.labelFor,
    required this.onChanged,
  });
  final String label;
  final IconData icon;
  final T value;
  final List<T> values;
  final String title;
  final String Function(T value) labelFor;
  final ValueChanged<T> onChanged;

  @override
  Widget build(BuildContext context) => PopupMenuButton<T>(
    tooltip: title,
    initialValue: value,
    onSelected: onChanged,
    itemBuilder: (context) => values
        .map(
          (item) => PopupMenuItem<T>(value: item, child: Text(labelFor(item))),
        )
        .toList(),
    child: Chip(
      avatar: Icon(icon, size: 18),
      label: Text(label),
      visualDensity: VisualDensity.compact,
    ),
  );
}

class _DocumentCard extends StatelessWidget {
  const _DocumentCard({
    required this.record,
    required this.services,
    required this.onOpen,
    required this.onRename,
    required this.onDelete,
    required this.onExport,
    required this.onShare,
  });
  final FileRecord record;
  final FiloServices services;
  final VoidCallback onOpen, onRename, onDelete, onExport, onShare;

  @override
  Widget build(BuildContext context) => Card(
    clipBehavior: Clip.antiAlias,
    child: InkWell(
      onTap: onOpen,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Expanded(
            child: _Thumbnail(record: record, services: services),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 8, 4, 10),
            child: Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        record.fileName,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context).textTheme.titleSmall,
                      ),
                      const SizedBox(height: 3),
                      Text(
                        '${_extensionLabel(record.extension)} · ${_sizeLabel(record.sizeInBytes)}',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                    ],
                  ),
                ),
                _RecordMenu(
                  onRename: onRename,
                  onDelete: onDelete,
                  onExport: onExport,
                  onShare: onShare,
                ),
              ],
            ),
          ),
        ],
      ),
    ),
  );
}

class _DocumentRow extends StatelessWidget {
  const _DocumentRow({
    required this.record,
    required this.services,
    required this.onOpen,
    required this.onRename,
    required this.onDelete,
    required this.onExport,
    required this.onShare,
  });
  final FileRecord record;
  final FiloServices services;
  final VoidCallback onOpen, onRename, onDelete, onExport, onShare;

  @override
  Widget build(BuildContext context) => Card(
    child: ListTile(
      onTap: onOpen,
      leading: SizedBox(
        width: 52,
        height: 52,
        child: _Thumbnail(record: record, services: services),
      ),
      title: Text(
        record.fileName,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      subtitle: Text(
        '${_extensionLabel(record.extension)} · ${_sizeLabel(record.sizeInBytes)} · ${_dateLabel(record.createdAt)}',
        maxLines: 2,
      ),
      trailing: _RecordMenu(
        onRename: onRename,
        onDelete: onDelete,
        onExport: onExport,
        onShare: onShare,
      ),
    ),
  );
}

class _Thumbnail extends StatefulWidget {
  const _Thumbnail({required this.record, required this.services});
  final FileRecord record;
  final FiloServices services;
  @override
  State<_Thumbnail> createState() => _ThumbnailState();
}

class _ThumbnailState extends State<_Thumbnail> {
  String? _path;
  bool _attempted = false;

  @override
  void initState() {
    super.initState();
    _resolve();
  }

  @override
  void didUpdateWidget(covariant _Thumbnail oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.record.id != widget.record.id ||
        oldWidget.record.thumbnailPath != widget.record.thumbnailPath ||
        oldWidget.record.localPath != widget.record.localPath) {
      _path = null;
      _attempted = false;
      _resolve();
    }
  }

  Future<void> _resolve() async {
    final ext = widget.record.extension.toLowerCase();
    if (!const {'jpg', 'jpeg', 'png', 'pdf'}.contains(ext)) {
      if (mounted) setState(() => _attempted = true);
      return;
    }
    var path = widget.record.thumbnailPath;
    if (path == null) {
      final result = await widget.services.thumbnailService.generate(
        widget.record,
        updateRecord: widget.services.libraryManager.updateRecord,
      );
      path = result.path;
    }
    if (!mounted) return;
    setState(() {
      _path = path;
      _attempted = true;
    });
  }

  @override
  Widget build(BuildContext context) {
    if (!_attempted) {
      return const Center(
        child: SizedBox(
          width: 22,
          height: 22,
          child: CircularProgressIndicator(strokeWidth: 2),
        ),
      );
    }
    if (_path != null) {
      return Image.file(
        File(_path!),
        fit: BoxFit.cover,
        errorBuilder: (_, _, _) =>
            _FileIcon(extension: widget.record.extension),
      );
    }
    return _FileIcon(extension: widget.record.extension);
  }
}

class _FileIcon extends StatelessWidget {
  const _FileIcon({required this.extension});
  final String extension;
  @override
  Widget build(BuildContext context) => ColoredBox(
    color: FiloColors.greenPale,
    child: Center(
      child: Icon(_fileIcon(extension), size: 38, color: FiloColors.green),
    ),
  );
}

class _RecordMenu extends StatelessWidget {
  const _RecordMenu({
    required this.onRename,
    required this.onDelete,
    required this.onExport,
    required this.onShare,
    this.onDetails,
  });
  final VoidCallback onRename, onDelete, onExport, onShare;
  final VoidCallback? onDetails;
  @override
  Widget build(BuildContext context) => PopupMenuButton<String>(
    tooltip: 'Document actions',
    onSelected: (action) => switch (action) {
      'rename' => onRename(),
      'delete' => onDelete(),
      'export' => onExport(),
      'details' => onDetails?.call(),
      _ => onShare(),
    },
    itemBuilder: (_) => [
      if (onDetails != null)
        const PopupMenuItem(
          value: 'details',
          child: ListTile(
            leading: Icon(Icons.info_outline_rounded),
            title: Text('Details'),
          ),
        ),
      const PopupMenuItem(
        value: 'rename',
        child: ListTile(
          leading: Icon(Icons.edit_outlined),
          title: Text('Rename'),
        ),
      ),
      PopupMenuItem(
        value: 'export',
        child: ListTile(
          leading: Icon(Icons.save_alt_rounded),
          title: Text('Export'),
        ),
      ),
      PopupMenuItem(
        value: 'share',
        child: ListTile(
          leading: Icon(Icons.share_outlined),
          title: Text('Share'),
        ),
      ),
      PopupMenuItem(
        value: 'delete',
        child: ListTile(
          leading: Icon(Icons.delete_outline_rounded),
          title: Text('Delete'),
        ),
      ),
    ],
  );
}

class _RenameDialog extends StatefulWidget {
  const _RenameDialog({required this.record, required this.onSave});

  final FileRecord record;
  final Future<FileRecord> Function(String name) onSave;

  @override
  State<_RenameDialog> createState() => _RenameDialogState();
}

class _RenameDialogState extends State<_RenameDialog> {
  late final TextEditingController _controller;
  String? _error;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    final record = widget.record;
    _controller = TextEditingController(
      text: record.fileName.substring(
        0,
        record.fileName.length - record.extension.length - 1,
      ),
    );
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('Rename document'),
    content: TextField(
      controller: _controller,
      autofocus: true,
      decoration: InputDecoration(
        labelText: 'Filename',
        suffixText: '.${widget.record.extension}',
        errorText: _error,
      ),
    ),
    actions: [
      TextButton(
        onPressed: _saving ? null : () => Navigator.pop(context, false),
        child: const Text('Cancel'),
      ),
      FilledButton(
        onPressed: _saving ? null : _save,
        child: _saving
            ? const SizedBox(
                width: 18,
                height: 18,
                child: CircularProgressIndicator(strokeWidth: 2),
              )
            : const Text('Save'),
      ),
    ],
  );

  Future<void> _save() async {
    if (_controller.text.trim().isEmpty) {
      setState(() => _error = 'Enter a filename.');
      return;
    }
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      await widget.onSave(_controller.text);
      if (mounted) Navigator.pop(context, true);
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _saving = false;
        _error = error is LibraryOperationException
            ? error.message
            : 'The document could not be renamed.';
      });
    }
  }
}

class DocumentPreviewScreen extends StatefulWidget {
  const DocumentPreviewScreen({
    super.key,
    required this.record,
    required this.services,
    required this.onRename,
    required this.onDelete,
    required this.onExport,
    required this.onShare,
  });
  final FileRecord record;
  final FiloServices services;
  final Future<FileRecord?> Function(FileRecord) onRename;
  final Future<bool?> Function(FileRecord) onDelete;
  final Future<void> Function(FileRecord) onExport;
  final Future<void> Function(FileRecord) onShare;
  @override
  State<DocumentPreviewScreen> createState() => _DocumentPreviewScreenState();
}

class _DocumentPreviewScreenState extends State<DocumentPreviewScreen> {
  late Future<TextPreviewResult> _textPreview;
  late FileRecord _record;
  final _textService = TextPreviewService();
  final _pdfController = PdfViewerController();
  int? _pageNumber;
  int? _pageCount;
  bool _pdfLoaded = false;
  bool? _pdfError;
  @override
  void initState() {
    super.initState();
    _record = widget.record;
    _textPreview = _textService.preview(File(_record.localPath));
  }

  Future<void> _showDetails() async {
    final details = await widget.services.libraryManager.getDocumentDetails(
      _record.id,
    );
    if (!mounted) return;
    if (details == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('This document is no longer in Filo.')),
      );
      return;
    }
    await showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (context) => _DocumentDetailsSheet(details: details),
    );
  }

  Future<void> _rename() async {
    final updated = await widget.onRename(_record);
    if (mounted && updated != null) {
      setState(() {
        _record = updated;
        _textPreview = _textService.preview(File(updated.localPath));
        _pdfLoaded = false;
        _pdfError = null;
        _pageNumber = null;
        _pageCount = null;
      });
    }
  }

  Future<void> _delete() async {
    final deleted = await widget.onDelete(_record);
    if (mounted && deleted == true) Navigator.of(context).pop();
    if (mounted && deleted == false) {
      final details = await widget.services.libraryManager.getDocumentDetails(
        _record.id,
      );
      if (!mounted) return;
      if (details != null && !details.fileExists) {
        setState(() => _pdfError = true);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final file = File(_record.localPath);
    final ext = _record.extension.toLowerCase();
    return Scaffold(
      appBar: AppBar(
        title: Text(
          _record.fileName,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        actions: [
          _RecordMenu(
            onDetails: _showDetails,
            onRename: _rename,
            onDelete: _delete,
            onExport: () => widget.onExport(_record),
            onShare: () => widget.onShare(_record),
          ),
        ],
      ),
      body: _pdfError == true
          ? const _PreviewError(
              message: 'This document is no longer available.',
            )
          : ext == 'pdf'
          ? Stack(
              children: [
                PdfViewer.file(
                  file.path,
                  key: ValueKey(file.path),
                  controller: _pdfController,
                  params: PdfViewerParams(
                    onPageChanged: (page) {
                      if (mounted) setState(() => _pageNumber = page);
                    },
                    onDocumentLoadFinished: (_, succeeded) {
                      if (mounted) {
                        setState(() {
                          _pdfLoaded = succeeded;
                          _pdfError = !succeeded;
                          if (succeeded) _pageCount = _pdfController.pageCount;
                        });
                      }
                    },
                  ),
                ),
                if (!_pdfLoaded && _pdfError != true)
                  const Positioned.fill(
                    child: IgnorePointer(
                      child: Center(child: CircularProgressIndicator()),
                    ),
                  ),
                if (_pdfLoaded && _pageNumber != null)
                  Positioned(
                    right: 12,
                    bottom: 12,
                    child: Chip(
                      label: Text(
                        'Page $_pageNumber${_pageCount == null ? '' : ' of $_pageCount'}',
                      ),
                    ),
                  ),
              ],
            )
          : ext == 'txt'
          ? FutureBuilder<TextPreviewResult>(
              future: _textPreview,
              builder: (context, snapshot) {
                if (!snapshot.hasData) {
                  return const Center(child: Text('Loading text preview…'));
                }
                final result = snapshot.data!;
                if (!result.isSuccess) {
                  return _PreviewError(
                    message: result.errorMessage ?? 'Text preview unavailable.',
                  );
                }
                return SingleChildScrollView(
                  padding: const EdgeInsets.all(FiloSpacing.page),
                  child: result.text.isEmpty
                      ? const Center(child: Text('This text file is empty.'))
                      : SelectableText(
                          result.displayText,
                          style: Theme.of(context).textTheme.bodyLarge,
                        ),
                );
              },
            )
          : FutureBuilder<bool>(
              future: file.exists(),
              builder: (context, snapshot) {
                if (!snapshot.hasData) {
                  return const Center(child: CircularProgressIndicator());
                }
                if (!snapshot.data!) {
                  return const _PreviewError(
                    message: 'This image is no longer available.',
                  );
                }
                return Center(
                  child: InteractiveViewer(
                    child: Image.file(
                      file,
                      fit: BoxFit.contain,
                      cacheWidth: 2048,
                      errorBuilder: (_, _, _) => const _PreviewError(
                        message: 'This image could not be opened.',
                      ),
                    ),
                  ),
                );
              },
            ),
    );
  }
}

class _DocumentDetailsSheet extends StatelessWidget {
  const _DocumentDetailsSheet({required this.details});
  final LibraryDocumentDetails details;

  @override
  Widget build(BuildContext context) {
    final record = details.record;
    final location = switch (record.storageLocation) {
      StorageLocation.internalDocuments => 'Filo private storage',
      StorageLocation.temporaryCache => 'Temporary storage',
      StorageLocation.externalShared => 'Shared storage',
    };
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(24, 4, 24, 28),
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      'Document details',
                      style: Theme.of(context).textTheme.titleLarge,
                    ),
                  ),
                  IconButton(
                    tooltip: 'Close document details',
                    onPressed: () => Navigator.of(context).pop(),
                    icon: const Icon(Icons.close_rounded),
                  ),
                ],
              ),
              const SizedBox(height: 16),
              _DetailRow(label: 'Filename', value: record.fileName),
              _DetailRow(
                label: 'File type',
                value: record.extension.toUpperCase(),
              ),
              _DetailRow(
                label: 'File size',
                value: _sizeLabel(record.sizeInBytes),
              ),
              _DetailRow(label: 'Created', value: _dateLabel(record.createdAt)),
              if (record.conversionType != null)
                _DetailRow(
                  label: 'Conversion',
                  value: record.conversionType!.displayName,
                ),
              _DetailRow(label: 'Storage', value: location),
              _DetailRow(
                label: 'Availability',
                value: details.fileExists ? 'Available' : 'File missing',
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _DetailRow extends StatelessWidget {
  const _DetailRow({required this.label, required this.value});
  final String label;
  final String value;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 6),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          width: 104,
          child: Text(label, style: Theme.of(context).textTheme.bodyMedium),
        ),
        Expanded(child: Text(value, textAlign: TextAlign.end)),
      ],
    ),
  );
}

class _PreviewError extends StatelessWidget {
  const _PreviewError({required this.message});
  final String message;
  @override
  Widget build(BuildContext context) => Center(
    child: Padding(
      padding: const EdgeInsets.all(FiloSpacing.page),
      child: Text(message, textAlign: TextAlign.center),
    ),
  );
}

class _PrivacyNote extends StatelessWidget {
  const _PrivacyNote({required this.onAbout});
  final VoidCallback onAbout;
  @override
  Widget build(BuildContext context) => Card(
    child: Padding(
      padding: const EdgeInsets.all(FiloSpacing.md),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Icon(Icons.lock_outline_rounded, color: FiloColors.green),
          const SizedBox(width: FiloSpacing.md),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Local by default',
                  style: Theme.of(context).textTheme.titleMedium,
                ),
                const SizedBox(height: FiloSpacing.xs),
                const Text(
                  'Your files stay on this device unless you export or share them.',
                ),
                TextButton(
                  onPressed: onAbout,
                  child: const Text('How Filo handles files'),
                ),
              ],
            ),
          ),
        ],
      ),
    ),
  );
}

IconData _fileIcon(String extension) => switch (extension.toLowerCase()) {
  'jpg' || 'jpeg' || 'png' => Icons.image_outlined,
  'pdf' => Icons.picture_as_pdf_outlined,
  'txt' => Icons.article_outlined,
  _ => Icons.insert_drive_file_outlined,
};

String _extensionLabel(String extension) => extension.toUpperCase();
String _sizeLabel(int bytes) => bytes < 1024
    ? '$bytes B'
    : bytes < 1024 * 1024
    ? '${(bytes / 1024).toStringAsFixed(1)} KB'
    : '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
String _dateLabel(DateTime date) =>
    '${date.year}-${date.month.toString().padLeft(2, '0')}-${date.day.toString().padLeft(2, '0')}';
