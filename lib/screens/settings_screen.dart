import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../app/filo_theme.dart';
import '../services/platform/file_picker_consent_store.dart';
import '../services/storage/file_storage.dart';

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({
    super.key,
    required this.fileStorage,
    this.loadStorageUsage,
    this.isActive = true,
    this.managedStorageChanges,
    this.filePickerConsentStore,
    this.loadAppVersion,
  });

  final FileStorage fileStorage;
  final Future<ManagedStorageUsage> Function()? loadStorageUsage;
  final bool isActive;
  final ValueListenable<int>? managedStorageChanges;
  final FilePickerConsentPreference? filePickerConsentStore;
  final Future<String> Function()? loadAppVersion;

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
              const Text(
                'File conversion and processing of files managed by Filo are '
                'designed to happen locally on this device and do not require '
                'an internet connection after installation.',
              ),
              const SizedBox(height: FiloSpacing.sm),
              const Text(
                'System file pickers, export, and sharing may open Android or '
                'another installed app. Sharing sends the selected file to the '
                'destination you choose. Filo does not automatically upload '
                'files to Google Drive or another cloud service. Android file '
                'providers and sharing destinations may use the internet; '
                'their availability depends on those external apps and services.',
              ),
              if (widget.filePickerConsentStore != null) ...[
                const SizedBox(height: FiloSpacing.sm),
                const Text(
                  'Allow always only remembers that Filo may open the system '
                  'picker. Android still limits access to files you select.',
                ),
                TextButton(
                  onPressed: _resetPickerConsent,
                  child: const Text('Ask for file picker consent again'),
                ),
              ],
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
                      label: 'Documents',
                      description: 'Files kept in your Filo library',
                      value: _formatBytes(_storageUsage!.documentsBytes),
                    ),
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
                    const SizedBox(height: FiloSpacing.sm),
                    const Text(
                      'Totals include files inside Filo-managed folders only.',
                    ),
                  ],
                ),
            ],
          ),
          const SizedBox(height: FiloSpacing.md),
          _SettingsSection(
            icon: Icons.menu_book_rounded,
            title: 'Using Filo',
            children: const [
              _GuideRow(
                title: 'Library',
                description: 'Browse and manage documents saved in Filo.',
              ),
              SizedBox(height: FiloSpacing.sm),
              _GuideRow(
                title: 'Convert',
                description: 'Choose files and create a supported new format.',
              ),
              SizedBox(height: FiloSpacing.sm),
              _GuideRow(
                title: 'Activity',
                description: 'Review recent successful and failed operations.',
              ),
            ],
          ),
          const SizedBox(height: FiloSpacing.md),
          _SettingsSection(
            icon: Icons.info_outline_rounded,
            title: 'About Filo',
            children: [
              Text('Filo'),
              SizedBox(height: FiloSpacing.xs),
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
              Icon(icon, color: FiloColors.green),
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

class _GuideRow extends StatelessWidget {
  const _GuideRow({required this.title, required this.description});

  final String title;
  final String description;

  @override
  Widget build(BuildContext context) => Row(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      const Icon(Icons.arrow_right_rounded, color: FiloColors.green),
      const SizedBox(width: FiloSpacing.xs),
      Expanded(
        child: Text.rich(
          TextSpan(
            style: Theme.of(context).textTheme.bodyMedium,
            children: [
              TextSpan(
                text: '$title — ',
                style: const TextStyle(
                  color: FiloColors.ink,
                  fontWeight: FontWeight.w600,
                ),
              ),
              TextSpan(text: description),
            ],
          ),
        ),
      ),
    ],
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
