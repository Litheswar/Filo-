import 'dart:async';
import 'dart:io';

import 'package:filo/screens/settings_screen.dart';
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
          ),
          loadAppVersion: () async => '1.0.1 · Build 2',
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Privacy'), findsOneWidget);
    expect(find.textContaining('designed to happen locally'), findsOneWidget);
    expect(find.textContaining('destination you choose'), findsOneWidget);
    expect(
      find.textContaining('does not automatically upload'),
      findsOneWidget,
    );
    expect(find.text('Documents'), findsOneWidget);
    expect(find.text('2 B'), findsOneWidget);
    expect(find.text('Temporary files'), findsOneWidget);
    expect(find.text('1 B'), findsOneWidget);
    expect(find.text('Thumbnails'), findsOneWidget);
    expect(find.text('3 B'), findsOneWidget);
    expect(
      find.textContaining('inside Filo-managed folders only'),
      findsOneWidget,
    );
    expect(find.text('Filo'), findsOneWidget);
    expect(find.text('Version 1.0.1 · Build 2'), findsOneWidget);
    expect(find.textContaining('Library'), findsOneWidget);
    expect(find.textContaining('Convert'), findsOneWidget);
    expect(find.textContaining('Activity'), findsOneWidget);
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
}

Widget _app(Widget child) => MaterialApp(home: Scaffold(body: child));
