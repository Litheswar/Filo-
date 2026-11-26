import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../app/filo_theme.dart';
import '../application/activity_manager.dart';
import '../services/platform/file_picker_consent_store.dart';
import '../services/storage/file_storage.dart';

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({
    super.key,
    required this.fileStorage,
    this.loadStorageUsage,
    this.isActive = true,
    this.managedStorageChanges,
    this.onManagedStorageChanged,
    this.filePickerConsentStore,
    this.loadAppVersion,
    this.activityManager,
    this.onActivityHistoryChanged,
    this.themeMode = ThemeMode.system,
    this.onThemeModeChanged,
  });

  final FileStorage fileStorage;
  final Future<ManagedStorageUsage> Function()? loadStorageUsage;
  final bool isActive;
  final ValueListenable<int>? managedStorageChanges;
  final VoidCallback? onManagedStorageChanged;
  final FilePickerConsentPreference? filePickerConsentStore;
  final Future<String> Function()? loadAppVersion;
  final ActivityManager? activityManager;
  final VoidCallback? onActivityHistoryChanged;
  final ThemeMode themeMode;
  final ValueChanged<ThemeMode>? onThemeModeChanged;

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen>
    with WidgetsBindingObserver {
  ManagedStorageUsage? _storageUsage;
  bool _loading = true;
  String? _storageError;
  Future<void>? _refreshTask;
  bool _refreshPending = false;
  bool _refreshFailed = false;
  int? _loadedStorageRevision;
  late final Future<String> _appVersion;

  @override
  void initState() {
    super.initState();
    _appVersion = widget.loadAppVersion?.call() ?? _loadInstalledAppVersion();
    WidgetsBinding.instance.addObserver(this);
    widget.managedStorageChanges?.addListener(_onManagedStorageChanged);
    if (widget.isActive) _refreshStorage();
  }

  @override
  void didUpdateWidget(covariant SettingsScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.managedStorageChanges != widget.managedStorageChanges) {
      oldWidget.managedStorageChanges?.removeListener(_onManagedStorageChanged);
      widget.managedStorageChanges?.addListener(_onManagedStorageChanged);
    }
    if (!oldWidget.isActive && widget.isActive) _refreshStorage();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed && widget.isActive) {
      _refreshStorage();
    }
  }

  void _onManagedStorageChanged() {
    if (widget.isActive) unawaited(_refreshStorage(force: true));
  }

  Future<void> _resetPickerConsent() async {
    try {
      await widget.filePickerConsentStore?.setAllowAlways(false);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('File picker consent will be requested again.'),
          ),
        );
      }
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('The consent preference could not be changed.'),
          ),
        );
      }
    }
  }

  Future<void> _confirmCleanup({required bool thumbnails}) async {
    int amount;
    try {
      amount = thumbnails
          ? _storageUsage?.thumbnailBytes ?? 0
          : await widget.fileStorage.getClearableTemporaryBytes();
    } on Object {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text(
              'Filo could not measure these files. Refresh storage and try again.',
            ),
          ),
        );
      }
      return;
    }
    if (!mounted) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(
          thumbnails
              ? 'Clear thumbnail cache?'
              : 'Clear staged temporary files?',
        ),
        content: Text(
          thumbnails
              ? 'This will remove ${_formatBytes(amount)} of Filo-managed thumbnail cache. Saved Library documents will not be deleted.'
              : 'This will remove ${_formatBytes(amount)} of Filo-managed staged files. Active conversion folders and saved Library documents will not be deleted. Staged selections may need to be imported again.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Clear'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    try {
      final removedBytes = thumbnails
          ? await widget.fileStorage.clearThumbnailCache()
          : null;
      final removedFiles = thumbnails
          ? null
          : await widget.fileStorage.cleanTemporaryFiles();
      widget.onManagedStorageChanged?.call();
      await _refreshStorage(force: true);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              thumbnails
                  ? 'Cleared ${_formatBytes(removedBytes!)} of thumbnail cache.'
                  : 'Cleared $removedFiles temporary files.',
            ),
          ),
        );
      }
    } on Object {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text(
              'Some managed files could not be cleared. Refresh storage and try again.',
            ),
          ),
        );
        await _refreshStorage(force: true);
      }
    }
  }

  Future<void> _confirmClearActivity() async {
    final manager = widget.activityManager;
    if (manager == null) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Clear Activity history?'),
        content: const Text(
          'Clearing Activity history does not delete Library documents. It removes conversion history only.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Clear history'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    try {
      await manager.clearHistory();
      widget.onActivityHistoryChanged?.call();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text(
              'Activity history cleared. Library documents were kept.',
            ),
          ),
        );
      }
    } on Object {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Activity history could not be cleared.'),
          ),
        );
      }
    }
  }

  Future<void> _refreshStorage({bool force = false}) {
    final notifier = widget.managedStorageChanges;
    if (!force &&
        _storageUsage != null &&
        !_refreshFailed &&
        (notifier == null || notifier.value == _loadedStorageRevision)) {
      return Future<void>.value();
    }
    final current = _refreshTask;
    if (current != null) {
      _refreshPending = true;
      return current;
    }
    final task = _performStorageRefresh();
    _refreshTask = task;
    return task;
  }

  Future<void> _performStorageRefresh() async {
    if (mounted) setState(() => _loading = true);
    try {
      final usage =
          await (widget.loadStorageUsage?.call() ??
              widget.fileStorage.getManagedStorageUsage());
      if (mounted) {
        setState(() {
          _storageUsage = usage;
          _storageError = null;
          _refreshFailed = false;
          _loadedStorageRevision = widget.managedStorageChanges?.value;
        });
      }
    } catch (_) {
      if (mounted) {
        setState(() {
          _refreshFailed = true;
          _storageError = _storageUsage == null
              ? 'Storage sizes are currently unavailable. Filo could not read '
                    'its managed storage folders.'
              : 'Storage sizes could not be refreshed. Try again.';
        });
      }
    } finally {
      _refreshTask = null;
      if (mounted) setState(() => _loading = false);
      if (mounted && _refreshPending) {
        _refreshPending = false;
        unawaited(_refreshStorage(force: true));
      }
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    widget.managedStorageChanges?.removeListener(_onManagedStorageChanged);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => SafeArea(
    top: false,
    child: SingleChildScrollView(
      padding: const EdgeInsets.all(FiloSpacing.page),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text('Settings', style: Theme.of(context).textTheme.headlineMedium),
          const SizedBox(height: FiloSpacing.md),
          _SettingsSection(
            icon: Icons.shield_outlined,
            title: 'Privacy',
            children: [
              Text(
                'Local by default',
                style: Theme.of(context).textTheme.titleSmall,
              ),
              const SizedBox(height: FiloSpacing.xs),
              const Text(
                'Your files stay on this device unless you export or share them.',
              ),
              Align(
                alignment: Alignment.centerLeft,
                child: TextButton.icon(
                  onPressed: () => Navigator.of(context).pushNamed('/welcome'),
                  icon: const Icon(Icons.menu_book_outlined),
                  label: const Text('How Filo handles files'),
                ),
              ),
              ExpansionTile(
                tilePadding: EdgeInsets.zero,
                childrenPadding: EdgeInsets.zero,
                title: const Text('Full privacy details'),
                children: [
                  const Text(
                    'File conversion and processing of files managed by Filo are designed to happen locally on this device and do not require an internet connection after installation.',
                  ),
                  const SizedBox(height: FiloSpacing.sm),
                  const Text(
                    'System file pickers, export, and sharing may open Android or another installed app. Sharing sends the selected file to the destination you choose. Filo does not automatically upload files to Google Drive or another cloud service. Android file providers and sharing destinations may use the internet; their availability depends on those external apps and services.',
                  ),
                  const SizedBox(height: FiloSpacing.sm),
                  const Text(
                    'The local workflow does not require an account. Local storage is not the same as encryption; protect your device and backups using your device settings.',
                  ),
                  if (widget.filePickerConsentStore != null) ...[
                    const SizedBox(height: FiloSpacing.sm),
                    const Text(
                      'Allow always only remembers that Filo may open the system picker. Android still limits access to files you select.',
                    ),
                    TextButton(
                      onPressed: _resetPickerConsent,
                      child: const Text('Ask for file picker consent again'),
                    ),
                  ],
                ],
              ),
            ],
          ),
          const SizedBox(height: FiloSpacing.md),
          _SettingsSection(
            icon: Icons.storage_rounded,
            title: 'Storage on this device',
            trailing: IconButton(
              tooltip: 'Refresh storage information',
              onPressed: () => _refreshStorage(force: true),
              icon: const Icon(Icons.refresh_rounded),
            ),
            children: [
              if (_loading && _storageUsage == null)
                const Padding(
                  padding: EdgeInsets.symmetric(vertical: FiloSpacing.sm),
                  child: Text('Reading Filo storage…'),
                )
              else if (_storageUsage == null)
                Text(
                  _storageError ??
                      'Storage sizes are currently unavailable. Filo could not '
                          'read its managed storage folders.',
                )
              else
                Column(
                  children: [
                    if (_loading)
                      const LinearProgressIndicator(
                        semanticsLabel: 'Refreshing storage information',
                      ),
                    if (_storageError != null)
                      Padding(
                        padding: const EdgeInsets.only(bottom: FiloSpacing.sm),
                        child: Text(_storageError!),
                      ),
                    _StorageRow(
                      label: 'Converted documents',
                      description:
                          '${_storageUsage!.documentCount} managed Library outputs',
                      value: _formatBytes(_storageUsage!.documentsBytes),
                    ),
                    const Divider(height: FiloSpacing.lg),
                    _StorageTypes(usage: _storageUsage!),
                    const Divider(height: FiloSpacing.lg),
                    _StorageRow(
                      label: 'Temporary files',
                      description: 'Files used during import and conversion',
                      value: _formatBytes(_storageUsage!.temporaryBytes),
                    ),
                    const Divider(height: FiloSpacing.lg),
                    _StorageRow(
                      label: 'Thumbnails',
                      description: 'Previews for library documents',
                      value: _formatBytes(_storageUsage!.thumbnailBytes),
                    ),
                    const Divider(height: FiloSpacing.lg),
                    _StorageRow(
                      label: 'Database and settings',
                      description: 'Filo metadata and local preferences',
                      value: _formatBytes(_storageUsage!.metadataBytes),
                    ),
                    const Divider(height: FiloSpacing.lg),
                    _StorageRow(
                      label: 'Total Filo-managed storage',
                      description:
                          'Documents, temporary files, cache, and metadata',
                      value: _formatBytes(_storageUsage!.totalBytes),
                    ),
                    const SizedBox(height: FiloSpacing.sm),
                    const SizedBox(height: FiloSpacing.sm),
                    const Text(
                      'Totals include files inside Filo-managed folders only.',
                    ),
                    const SizedBox(height: FiloSpacing.xs),
                    const Text(
                      'Phone-wide capacity and free space are unavailable here.',
                    ),
                    if (_storageUsage!.refreshedAt != null) ...[
                      const SizedBox(height: FiloSpacing.xs),
                      Text(
                        'Last refreshed ${_formatTimestamp(_storageUsage!.refreshedAt!)}',
                      ),
                    ],
                    const SizedBox(height: FiloSpacing.sm),
                    Wrap(
                      spacing: FiloSpacing.sm,
                      runSpacing: FiloSpacing.xs,
                      children: [
                        OutlinedButton.icon(
                          onPressed: _loading
                              ? null
                              : () => _confirmCleanup(thumbnails: false),
                          icon: const Icon(Icons.cleaning_services_outlined),
                          label: const Text('Clear staged temporary files'),
                        ),
                        OutlinedButton.icon(
                          onPressed: _loading
                              ? null
                              : () => _confirmCleanup(thumbnails: true),
                          icon: const Icon(Icons.image_not_supported_outlined),
                          label: const Text('Clear thumbnail cache'),
                        ),
                      ],
                    ),
                  ],
                ),
            ],
          ),
          const SizedBox(height: FiloSpacing.md),
          _SettingsSection(
            icon: Icons.menu_book_rounded,
            title: 'Using Filo',
            children: [
              const Text(
                'Learn the local file workflow and find your way around Filo.',
              ),
              const SizedBox(height: FiloSpacing.sm),
              Align(
                alignment: Alignment.centerLeft,
                child: FilledButton.tonalIcon(
                  onPressed: () => Navigator.of(context).pushNamed('/welcome'),
                  icon: const Icon(Icons.menu_book_outlined),
                  label: const Text('Getting started with Filo'),
                ),
              ),
            ],
          ),
          const SizedBox(height: FiloSpacing.md),
          _SettingsSection(
            icon: Icons.palette_outlined,
            title: 'Appearance',
            children: [
              const Text('Choose how Filo looks on this device.'),
              const SizedBox(height: FiloSpacing.sm),
              SegmentedButton<ThemeMode>(
                segments: const [
                  ButtonSegment(
                    value: ThemeMode.system,
                    label: Text('System'),
                    icon: Icon(Icons.settings_suggest_outlined),
                  ),
                  ButtonSegment(
                    value: ThemeMode.light,
                    label: Text('Light'),
                    icon: Icon(Icons.light_mode_outlined),
                  ),
                  ButtonSegment(
                    value: ThemeMode.dark,
                    label: Text('Dark'),
                    icon: Icon(Icons.dark_mode_outlined),
                  ),
                ],
                selected: {widget.themeMode},
                onSelectionChanged: widget.onThemeModeChanged == null
                    ? null
                    : (selection) =>
                          widget.onThemeModeChanged!(selection.first),
              ),
            ],
          ),
          if (widget.activityManager != null) ...[
            const SizedBox(height: FiloSpacing.md),
            _SettingsSection(
              icon: Icons.history_rounded,
              title: 'Activity and data',
              children: [
                const Text(
                  'Clear conversion history without deleting Library documents.',
                ),
                const SizedBox(height: FiloSpacing.sm),
                OutlinedButton.icon(
                  onPressed: _confirmClearActivity,
                  icon: const Icon(Icons.delete_sweep_outlined),
                  label: const Text('Clear Activity history'),
                ),
              ],
            ),
          ],
          const SizedBox(height: FiloSpacing.md),
          _SettingsSection(
            icon: Icons.info_outline_rounded,
            title: 'About Filo',
            children: [
              const Text(
                'Convert, read and manage documents locally on your device.',
              ),
              const SizedBox(height: FiloSpacing.xs),
              FutureBuilder<String>(
                future: _appVersion,
                builder: (context, snapshot) => Text(
                  snapshot.hasData
                      ? 'Version ${snapshot.data}'
                      : snapshot.hasError
                      ? 'Version information unavailable'
                      : 'Loading version information…',
                ),
              ),
            ],
          ),
          const SizedBox(height: FiloSpacing.md),
          _SettingsSection(
            icon: Icons.transform_rounded,
            title: 'Supported formats',
            children: [
              Wrap(
                spacing: FiloSpacing.xs,
                runSpacing: FiloSpacing.xs,
                children: [
                  for (final format in const [
                    'JPG → PNG',
                    'PNG → JPG',
                    'Image(s) → PDF',
                    'PDF → Images',
                    'PDF → TXT',
                    'TXT → PDF',
                    'Merge PDFs',
                  ])
                    Chip(label: Text(format)),
                ],
              ),
            ],
          ),
        ],
      ),
    ),
  );
}

Future<String> _loadInstalledAppVersion() async {
  const channel = MethodChannel('filo/app_info');
  final version = await channel.invokeMethod<String>('getVersion');
  if (version == null || version.isEmpty) {
    throw PlatformException(
      code: 'version_unavailable',
      message: 'Installed application version is unavailable.',
    );
  }
  return version;
}

class _SettingsSection extends StatelessWidget {
  const _SettingsSection({
    required this.icon,
    required this.title,
    required this.children,
    this.trailing,
  });

  final IconData icon;
  final String title;
  final List<Widget> children;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) => Card(
    child: Padding(
      padding: const EdgeInsets.all(FiloSpacing.md),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(icon, color: Theme.of(context).colorScheme.primary),
              const SizedBox(width: FiloSpacing.sm),
              Expanded(
                child: Text(
                  title,
                  style: Theme.of(context).textTheme.titleMedium,
                ),
              ),
              ?trailing,
            ],
          ),
          const SizedBox(height: FiloSpacing.md),
          ...children,
        ],
      ),
    ),
  );
}

class _StorageRow extends StatelessWidget {
  const _StorageRow({
    required this.label,
    required this.description,
    required this.value,
  });

  final String label;
  final String description;
  final String value;

  @override
  Widget build(BuildContext context) => Row(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Expanded(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(label, style: Theme.of(context).textTheme.titleSmall),
            Text(description),
          ],
        ),
      ),
      const SizedBox(width: FiloSpacing.sm),
      Text(value, style: Theme.of(context).textTheme.titleSmall),
    ],
  );
}

class _StorageTypes extends StatelessWidget {
  const _StorageTypes({required this.usage});

  final ManagedStorageUsage usage;

  @override
  Widget build(BuildContext context) {
    final groups = <String, int>{
      'PDF': _sum(['pdf']),
      'PNG': _sum(['png']),
      'JPG': _sum(['jpg', 'jpeg']),
      'TXT': _sum(['txt']),
      'Other': usage.documentBytesByType.entries
          .where(
            (entry) =>
                !{'pdf', 'png', 'jpg', 'jpeg', 'txt'}.contains(entry.key),
          )
          .fold<int>(0, (sum, entry) => sum + entry.value),
    };
    final visible = groups.entries.where((entry) => entry.value > 0).toList();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('By file type', style: Theme.of(context).textTheme.titleSmall),
        const SizedBox(height: FiloSpacing.xs),
        if (visible.isEmpty)
          const Text('No Library files yet.')
        else
          for (final entry in visible)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 2),
              child: Row(
                children: [
                  Expanded(child: Text(entry.key)),
                  Text(_formatBytes(entry.value)),
                ],
              ),
            ),
      ],
    );
  }

  int _sum(List<String> extensions) => extensions.fold<int>(
    0,
    (sum, extension) => sum + (usage.documentBytesByType[extension] ?? 0),
  );
}

String _formatBytes(int bytes) {
  if (bytes < 1024) return '$bytes B';
  if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
  if (bytes < 1024 * 1024 * 1024) {
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
  }
  return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(1)} GB';
}

String _formatTimestamp(DateTime value) {
  final local = value.toLocal();
  final date =
      '${local.year.toString().padLeft(4, '0')}-'
      '${local.month.toString().padLeft(2, '0')}-'
      '${local.day.toString().padLeft(2, '0')}';
  final time =
      '${local.hour.toString().padLeft(2, '0')}:'
      '${local.minute.toString().padLeft(2, '0')}';
  return '$date at $time';
}
