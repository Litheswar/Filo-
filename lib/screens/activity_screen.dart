import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';

import '../application/activity_manager.dart';
import '../app/filo_theme.dart';
import '../models/conversion_type.dart';
import '../widgets/empty_state.dart';

class ActivityScreen extends StatefulWidget {
  const ActivityScreen({
    super.key,
    required this.activityManager,
    this.activityChanges,
    this.isActive = true,
  });

  final ActivityManager activityManager;
  final ValueListenable<int>? activityChanges;
  final bool isActive;

  @override
  State<ActivityScreen> createState() => _ActivityScreenState();
}

class _ActivityScreenState extends State<ActivityScreen> {
  Future<List<ActivityRecord>>? _activities;
  Future<List<ActivityRecord>>? _inFlight;
  bool _refreshPending = false;
  int? _loadedRevision;

  @override
  void initState() {
    super.initState();
    widget.activityChanges?.addListener(_onActivityChanged);
    _activities = widget.isActive ? _load() : Future.value(const []);
  }

  @override
  void didUpdateWidget(covariant ActivityScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.activityChanges != widget.activityChanges) {
      oldWidget.activityChanges?.removeListener(_onActivityChanged);
      widget.activityChanges?.addListener(_onActivityChanged);
    }
    final revisionChanged =
        widget.activityChanges != null &&
        _loadedRevision != widget.activityChanges!.value;
    final sourceChanged =
        oldWidget.activityManager != widget.activityManager ||
        oldWidget.activityChanges != widget.activityChanges;
    if (widget.isActive &&
        (_activities == null ||
            revisionChanged ||
            sourceChanged ||
            (widget.activityChanges == null && !oldWidget.isActive))) {
      _reload();
    }
  }

  void _onActivityChanged() {
    if (widget.isActive) _reload();
  }

  void _reload() {
    final next = _load(forceRefresh: true);
    setState(() {
      _activities = next;
    });
  }

  Future<List<ActivityRecord>> _load({bool forceRefresh = false}) {
    final current = _inFlight;
    if (current != null) {
      if (forceRefresh) _refreshPending = true;
      return current;
    }
    // The ActivityManager contract returns records newest first. Keeping its
    // ordering avoids mutating immutable lists returned by persistent stores.
    final task = Future<List<ActivityRecord>>.sync(
      widget.activityManager.getActivities,
    );
    _inFlight = task;
    unawaited(
      task
          .then<void>(
            (_) => _loadedRevision = widget.activityChanges?.value,
            onError: (Object _, StackTrace _) {},
          )
          .whenComplete(() {
            if (identical(_inFlight, task)) _inFlight = null;
            if (_refreshPending && mounted && widget.isActive) {
              _refreshPending = false;
              final latest = _load();
              setState(() {
                _activities = latest;
              });
            }
          }),
    );
    return task;
  }

  Future<void> _refresh() async {
    final next = _load(forceRefresh: true);
    setState(() {
      _activities = next;
    });
    try {
      await next;
    } on Object {
      // The FutureBuilder renders the recoverable error state.
    }
  }

  @override
  void dispose() {
    widget.activityChanges?.removeListener(_onActivityChanged);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => SafeArea(
    top: false,
    child: FutureBuilder<List<ActivityRecord>>(
      future: _activities ?? Future.value(const []),
      builder: (context, snapshot) {
        if (snapshot.connectionState != ConnectionState.done) {
          return const Center(child: Text('Loading activity…'));
        }
        if (snapshot.hasError) {
          return _MessageState(
            icon: Icons.history_toggle_off_rounded,
            title: 'Activity unavailable',
            description: 'Your saved activity could not be loaded.',
            action: OutlinedButton.icon(
              onPressed: _refresh,
              icon: const Icon(Icons.refresh_rounded),
              label: const Text('Try again'),
            ),
          );
        }
        final records = snapshot.data ?? const <ActivityRecord>[];
        if (records.isEmpty) {
          return RefreshIndicator(
            onRefresh: _refresh,
            child: ListView(
              physics: const AlwaysScrollableScrollPhysics(),
              padding: const EdgeInsets.all(FiloSpacing.page),
              children: const [
                SizedBox(height: 100),
                EmptyState(
                  icon: Icons.history_rounded,
                  title: 'No recent activity',
                  description: 'Your completed conversions will appear here.',
                ),
              ],
            ),
          );
        }
        return RefreshIndicator(
          onRefresh: _refresh,
          child: ListView.separated(
            physics: const AlwaysScrollableScrollPhysics(),
            padding: const EdgeInsets.all(FiloSpacing.page),
            itemCount: records.length + 1,
            separatorBuilder: (_, _) => const SizedBox(height: FiloSpacing.sm),
            itemBuilder: (context, index) {
              if (index == 0) {
                return Padding(
                  padding: const EdgeInsets.only(bottom: FiloSpacing.sm),
                  child: Text(
                    'Recent operations',
                    style: Theme.of(context).textTheme.titleLarge,
                  ),
                );
              }
              return _ActivityCard(record: records[index - 1]);
            },
          ),
        );
      },
    ),
  );
}

class _ActivityCard extends StatelessWidget {
  const _ActivityCard({required this.record});

  final ActivityRecord record;

  @override
  Widget build(BuildContext context) {
    final title = _conversionLabel(record.conversionType);
    final status = record.isSuccess ? 'Completed' : 'Failed';
    final names = record.outputNames.isNotEmpty
        ? record.outputNames
        : record.outputName == null
        ? const <String>[]
        : [record.outputName!];
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
                  record.isSuccess
                      ? Icons.check_circle_outline_rounded
                      : Icons.error_outline_rounded,
                  semanticLabel: status,
                  color: record.isSuccess
                      ? FiloColors.green
                      : FiloColors.warning,
                ),
                const SizedBox(width: FiloSpacing.sm),
                Expanded(
                  child: Text(
                    title,
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                ),
                const SizedBox(width: FiloSpacing.sm),
                Text(status, style: Theme.of(context).textTheme.labelLarge),
              ],
            ),
            const SizedBox(height: FiloSpacing.sm),
            Text(_formatTimestamp(record.timestamp)),
            if (names.isNotEmpty) ...[
              const SizedBox(height: FiloSpacing.sm),
              Text(names.length == 1 ? 'Output' : 'Outputs (${names.length})'),
              const SizedBox(height: FiloSpacing.xs),
              ...names.map(
                (name) => Padding(
                  padding: const EdgeInsets.only(bottom: FiloSpacing.xs),
                  child: Text(
                    name,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    softWrap: true,
                  ),
                ),
              ),
            ],
            if (!record.isSuccess &&
                _safeError(record.errorMessage) != null) ...[
              const SizedBox(height: FiloSpacing.sm),
              Text(
                _safeError(record.errorMessage)!,
                maxLines: 3,
                overflow: TextOverflow.ellipsis,
              ),
            ],
          ],
        ),
      ),
    );
  }
}

String _conversionLabel(ConversionType type) => switch (type) {
  ConversionType.jpgToPng => 'JPG to PNG',
  ConversionType.pngToJpg => 'PNG to JPG',
  ConversionType.singleImageToPdf => 'Image to PDF',
  ConversionType.multipleImagesToPdf => 'Images to PDF',
  ConversionType.pdfToImages => 'PDF to images',
  ConversionType.txtToPdf => 'Text to PDF',
  ConversionType.pdfToTxt => 'PDF to text',
};

String _formatTimestamp(DateTime value) {
  final local = value.toLocal();
  final hour = local.hour % 12 == 0 ? 12 : local.hour % 12;
  final minute = local.minute.toString().padLeft(2, '0');
  final period = local.hour < 12 ? 'AM' : 'PM';
  return '${local.year}-${local.month.toString().padLeft(2, '0')}-'
      '${local.day.toString().padLeft(2, '0')} · $hour:$minute $period';
}

String? _safeError(String? message) {
  if (message == null || message.trim().isEmpty) return null;
  final noPaths = message.replaceAll(
    RegExp(r'(?:[A-Za-z]:)?[/\\][^\s,;]+'),
    '[file]',
  );
  final concise = noPaths.replaceAll(RegExp(r'\s+'), ' ').trim();
  return concise.length <= 180 ? concise : '${concise.substring(0, 177)}…';
}

class _MessageState extends StatelessWidget {
  const _MessageState({
    required this.icon,
    required this.title,
    required this.description,
    this.action,
  });

  final IconData icon;
  final String title;
  final String description;
  final Widget? action;

  @override
  Widget build(BuildContext context) => Center(
    child: Padding(
      padding: const EdgeInsets.all(FiloSpacing.page),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 48, color: FiloColors.mutedInk),
          const SizedBox(height: FiloSpacing.md),
          Text(title, style: Theme.of(context).textTheme.titleLarge),
          const SizedBox(height: FiloSpacing.sm),
          Text(description, textAlign: TextAlign.center),
          if (action != null) ...[
            const SizedBox(height: FiloSpacing.md),
            action!,
          ],
        ],
      ),
    ),
  );
}
