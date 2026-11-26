import 'dart:async';
import 'dart:io';

import 'package:filo/screens/settings_screen.dart';
import 'package:filo/application/activity_manager.dart';
import 'package:filo/models/conversion_type.dart';
import 'package:filo/services/storage/file_storage.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late Directory root;
  late FileStorage storage;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('filo_settings_test_');
    storage = FileStorage(
      documentsDirectoryProvider: () async => Directory('${root.path}/docs'),
      temporaryDirectoryProvider: () async => Directory('${root.path}/temp'),
    );
    final directories = await storage.initialize();
    await File('${directories.documents.path}/sample.pdf').writeAsBytes([1, 2]);
    await File('${directories.temporary.path}/filo_tmp_source')
        .writeAsBytes([3]);
    await File('${directories.thumbnails.path}/thumb.png')
        .writeAsBytes([4, 5, 6]);
  });

  tearDown(() async {
    if (await root.exists()) await root.delete(recursive: true);
  });

  testWidgets('shows privacy, guidance, app info, and managed storage totals', (
    tester,
  ) async {
    await tester.pumpWidget(
      _app(
        SettingsScreen(
          fileStorage: storage,
          loadStorageUsage: () async => const ManagedStorageUsage(
            documentsBytes: 2,
            temporaryBytes: 1,
            thumbnailBytes: 3,
            documentCount: 1,
            documentBytesByType: {'pdf': 2},
            metadataBytes: 4,
          ),
          loadAppVersion: () async => '1.0.1',
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Privacy'), findsOneWidget);
    expect(find.text('Local by default'), findsOneWidget);
    expect(
      find.text(
        'Your files stay on this device unless you export or share them.',
      ),
      findsOneWidget,
    );
    expect(find.text('How Filo handles files'), findsOneWidget);
    expect(find.text('Full privacy details'), findsOneWidget);
    await tester.tap(find.text('Full privacy details'));
    await tester.pumpAndSettle();
    expect(find.textContaining('designed to happen locally'), findsOneWidget);
    expect(find.textContaining('destination you choose'), findsOneWidget);
    expect(
      find.textContaining('does not automatically upload'),
      findsOneWidget,
    );
    expect(find.textContaining('does not require an account'), findsOneWidget);
    expect(find.textContaining('not the same as encryption'), findsOneWidget);
    expect(find.text('Converted documents'), findsOneWidget);
    expect(find.text('2 B'), findsNWidgets(2));
    expect(find.text('Temporary files'), findsOneWidget);
    expect(find.text('1 B'), findsOneWidget);
    expect(find.text('Thumbnails'), findsOneWidget);
    expect(find.text('3 B'), findsOneWidget);
    expect(find.text('1 managed Library outputs'), findsOneWidget);
    expect(find.text('By file type'), findsOneWidget);
    expect(find.text('PDF'), findsOneWidget);
    expect(find.text('Database and settings'), findsOneWidget);
    expect(find.text('Total Filo-managed storage'), findsOneWidget);
    expect(find.text('10 B'), findsOneWidget);
    expect(
      find.textContaining('inside Filo-managed folders only'),
      findsOneWidget,
    );
    expect(
      find.text('Convert, read and manage documents locally on your device.'),
      findsOneWidget,
    );
    expect(find.text('Version 1.0.1'), findsOneWidget);
    expect(find.text('Getting started with Filo'), findsOneWidget);
    expect(find.text('Appearance'), findsOneWidget);
    expect(find.text('Supported formats'), findsOneWidget);
    expect(find.text('JPG → PNG'), findsOneWidget);
    expect(find.text('PDF → TXT'), findsOneWidget);
    expect(find.textContaining('DOCX'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('explains when managed storage sizes cannot be read', (
    tester,
  ) async {
    await tester.pumpWidget(
      _app(
        SettingsScreen(
          fileStorage: storage,
          loadStorageUsage: () =>
              throw const FileStorageException('storage unavailable'),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(
      find.textContaining('Storage sizes are currently unavailable'),
      findsOneWidget,
    );
  });

  testWidgets(
    'refreshes on activation and storage changes, retaining data on error',
    (tester) async {
      final changes = ValueNotifier<int>(0);
      var calls = 0;
      var fail = false;
      Future<ManagedStorageUsage> load() async {
        calls++;
        if (fail) throw const FileStorageException('temporarily unavailable');
        return ManagedStorageUsage(
          documentsBytes: calls,
          temporaryBytes: calls + 1,
          thumbnailBytes: calls + 2,
        );
      }

      Widget screen(bool active) => _app(
        SettingsScreen(
          fileStorage: storage,
          loadStorageUsage: load,
          isActive: active,
          managedStorageChanges: changes,
        ),
      );

      await tester.pumpWidget(screen(false));
      await tester.pumpAndSettle();
      expect(calls, 0);

      await tester.pumpWidget(screen(true));
      await tester.pumpAndSettle();
      expect(calls, 1);
      expect(find.text('1 B'), findsOneWidget);

      changes.value++;
      await tester.pumpAndSettle();
      expect(calls, 2);
      expect(find.text('2 B'), findsOneWidget);

      fail = true;
      changes.value++;
      await tester.pumpAndSettle();
      expect(calls, 3);
      expect(find.text('2 B'), findsOneWidget);
      expect(
        find.text('Storage sizes could not be refreshed. Try again.'),
        findsOneWidget,
      );

      fail = false;
      await tester.pumpWidget(screen(false));
      await tester.pumpAndSettle();
      changes.value++;
      await tester.pumpAndSettle();
      expect(calls, 3, reason: 'inactive Settings must not scan storage');

      await tester.pumpWidget(screen(true));
      await tester.pumpAndSettle();
      expect(calls, 4, reason: 'activation refreshes missed file changes');

      await tester.pumpWidget(screen(false));
      await tester.pumpAndSettle();
      await tester.pumpWidget(screen(true));
      await tester.pumpAndSettle();
      expect(calls, 4, reason: 'unchanged storage measurements are reused');
      changes.dispose();
    },
  );

  testWidgets('coalesces storage changes while a scan is in flight', (
    tester,
  ) async {
    final changes = ValueNotifier<int>(0);
    final firstScan = Completer<ManagedStorageUsage>();
    var calls = 0;
    Future<ManagedStorageUsage> load() {
      calls++;
      if (calls == 1) return firstScan.future;
      return Future.value(
        const ManagedStorageUsage(
          documentsBytes: 5,
          temporaryBytes: 6,
          thumbnailBytes: 7,
        ),
      );
    }

    await tester.pumpWidget(
      _app(
        SettingsScreen(
          fileStorage: storage,
          loadStorageUsage: load,
          managedStorageChanges: changes,
        ),
      ),
    );
    expect(calls, 1);
    changes.value++;
    changes.value++;
    firstScan.complete(
      const ManagedStorageUsage(
        documentsBytes: 1,
        temporaryBytes: 2,
        thumbnailBytes: 3,
      ),
    );
    await tester.pumpAndSettle();

    expect(calls, 2);
    expect(find.text('5 B'), findsOneWidget);
    changes.dispose();
  });

  testWidgets('cleanup confirms reclaimed space and keeps Library documents', (
    tester,
  ) async {
    final cleanupStorage = _CleanupFileStorage();

    await tester.pumpWidget(
      _app(
        SettingsScreen(
          fileStorage: cleanupStorage,
          loadStorageUsage: () async => const ManagedStorageUsage(
            documentsBytes: 3,
            temporaryBytes: 2,
            thumbnailBytes: 3,
            documentCount: 1,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await _scrollIntoView(tester, find.text('Clear staged temporary files'));
    await tester.tap(find.text('Clear staged temporary files'));
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsOneWidget);
    expect(find.textContaining('remove 2 B'), findsOneWidget);
    expect(
      find.textContaining('Library documents will not be deleted'),
      findsOneWidget,
    );
    expect(find.textContaining('Active conversion folders'), findsOneWidget);
    await tester.tap(find.text('Clear').last);
    await tester.pumpAndSettle();
    expect(cleanupStorage.temporaryCleanupCalls, 1);

    await _scrollIntoView(tester, find.text('Clear thumbnail cache'));
    await tester.tap(find.text('Clear thumbnail cache'));
    await tester.pumpAndSettle();
    expect(find.textContaining('remove 3 B'), findsOneWidget);
    await tester.tap(find.text('Clear').last);
    await tester.pumpAndSettle();
    expect(cleanupStorage.cacheCleanupCalls, 1);
  });

  testWidgets('clears Activity history separately and preserves documents', (
    tester,
  ) async {
    final directories = await storage.initialize();
    final document = File('${directories.documents.path}/library.pdf')
      ..writeAsBytesSync([1, 2, 3]);
    final history = InMemoryActivityManager([
      ActivityRecord(
        id: 'activity-1',
        jobId: 'job-1',
        conversionType: ConversionType.jpgToPng,
        isSuccess: true,
      ),
    ]);
    var refreshed = false;

    await tester.pumpWidget(
      _app(
        SettingsScreen(
          fileStorage: storage,
          loadStorageUsage: () async => const ManagedStorageUsage(
            documentsBytes: 3,
            temporaryBytes: 0,
            thumbnailBytes: 0,
            documentCount: 1,
          ),
          activityManager: history,
          onActivityHistoryChanged: () => refreshed = true,
        ),
      ),
    );
    await tester.pumpAndSettle();
    await _scrollIntoView(tester, find.text('Clear Activity history'));
    await tester.tap(find.text('Clear Activity history'));
    await tester.pumpAndSettle();
    expect(
      find.textContaining('does not delete Library documents'),
      findsOneWidget,
    );
    await tester.tap(find.text('Clear history'));
    await tester.pumpAndSettle();

    expect(await history.getActivities(), isEmpty);
    expect(refreshed, isTrue);
    expect(await tester.runAsync(document.readAsBytes), [1, 2, 3]);
  });

  testWidgets('appearance selector reports selected theme changes', (
    tester,
  ) async {
    ThemeMode? selected;
    await tester.pumpWidget(
      _app(
        SettingsScreen(
          fileStorage: storage,
          loadStorageUsage: () async => const ManagedStorageUsage(
            documentsBytes: 2,
            temporaryBytes: 0,
            thumbnailBytes: 0,
            documentCount: 1,
          ),
          onThemeModeChanged: (mode) => selected = mode,
        ),
      ),
    );
    await tester.pumpAndSettle();
    await _scrollIntoView(tester, find.text('Dark'));
    await tester.tap(find.text('Dark'));
    await tester.pumpAndSettle();
    expect(selected, ThemeMode.dark);
  });
}

Widget _app(Widget child) => MaterialApp(home: Scaffold(body: child));

Future<void> _scrollIntoView(WidgetTester tester, Finder target) async {
  final scrollable = find.byType(SingleChildScrollView).first;
  final viewportHeight =
      tester.view.physicalSize.height / tester.view.devicePixelRatio;
  for (var attempt = 0; attempt < 12; attempt++) {
    final rect = tester.getRect(target);
    if (rect.top >= 0 && rect.bottom <= viewportHeight) return;
    await tester.drag(
      scrollable,
      Offset(0, rect.bottom > viewportHeight ? -260 : 260),
    );
    await tester.pumpAndSettle();
  }
  fail('Could not bring $target into the Settings viewport.');
}

class _CleanupFileStorage extends FileStorage {
  int temporaryCleanupCalls = 0;
  int cacheCleanupCalls = 0;

  @override
  Future<int> getClearableTemporaryBytes() async => 2;

  @override
  Future<int> cleanTemporaryFiles() async {
    temporaryCleanupCalls++;
    return 1;
  }

  @override
  Future<int> clearThumbnailCache() async {
    cacheCleanupCalls++;
    return 3;
  }
}
