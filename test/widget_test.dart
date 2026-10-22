import 'dart:async';
import 'dart:io';

import 'package:filo/app/filo_app.dart';
import 'package:filo/app/filo_services.dart';
import 'package:filo/app/filo_theme.dart';
import 'package:filo/application/activity_manager.dart';
import 'package:filo/services/storage/file_storage.dart';
import 'package:filo/services/storage/local_database.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  late FiloServices services;
  late Directory testRoot;

  setUp(() async {
    final setup = await _createTestServices();
    services = setup.$1;
    testRoot = setup.$2;
  });

  tearDown(() async {
    await services.localDatabase.close();
    if (await testRoot.exists()) await testRoot.delete(recursive: true);
  });

  test('light theme uses Material 3 and Filo brand tokens', () {
    final theme = FiloTheme.light;
    expect(theme.useMaterial3, isTrue);
    expect(theme.colorScheme.primary, FiloColors.green);
    expect(theme.navigationBarTheme.height, 72);
  });

  test('application services share the configured storage and database', () {
    expect(services.libraryManager.localDatabase, same(services.localDatabase));
    expect(services.activityManager, isA<InMemoryActivityManager>());
    expect(services.libraryManager.fileStorage, same(services.fileStorage));
    expect(
      services.libraryManager.thumbnailService,
      same(services.thumbnailService),
    );
    expect(services.conversionWorkflow.fileStorage, same(services.fileStorage));
    expect(
      services.conversionWorkflow.libraryManager,
      same(services.libraryManager),
    );
    expect(
      services.conversionWorkflow.activityManager,
      same(services.activityManager),
    );
    expect(
      services.conversionWorkflow.conversionManager,
      same(services.conversionManager),
    );
    expect(
      services.documentConversionService.conversionWorkflow,
      same(services.conversionWorkflow),
    );
    expect(services.conversionManager.registeredConverters, hasLength(4));
  });

  testWidgets('initializes once and shows the library shell', (tester) async {
    var initializationCount = 0;
    await tester.pumpWidget(
      FiloApp(
        initializeServices: () async {
          initializationCount++;
          return services;
        },
      ),
    );
    await tester.pumpAndSettle();

    expect(initializationCount, 1);
    expect(find.text('Your documents'), findsOneWidget);
    expect(find.byType(NavigationBar), findsOneWidget);
  });

  testWidgets('defers Activity until first visit and reuses loaded state', (
    tester,
  ) async {
    final activity = _CountingActivityManager();
    final appServices = FiloServices.compose(
      fileStorage: services.fileStorage,
      localDatabase: services.localDatabase,
      activityManager: activity,
    );
    var initializes = 0;
    await tester.pumpWidget(
      FiloApp(
        initializeServices: () async {
          initializes++;
          return appServices;
        },
      ),
    );
    await tester.pumpAndSettle();
    expect(initializes, 1);
    expect(activity.readCount, 0);

    await tester.tap(find.text('Activity').last);
    await tester.pumpAndSettle();
    expect(activity.readCount, 1);
    await tester.tap(find.text('Library').last);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Activity').last);
    await tester.pumpAndSettle();
    expect(activity.readCount, 1);
    expect(initializes, 1);
  });

  testWidgets(
    'navigation switches between all destinations and back returns to library',
    (tester) async {
      await tester.pumpWidget(
        FiloApp(initializeServices: () async => services),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.text('Convert').last);
      await tester.pumpAndSettle();
      expect(find.text('Choose a conversion'), findsWidgets);

      await tester.tap(find.text('Activity').last);
      await tester.pumpAndSettle();
      expect(find.text('No recent activity'), findsOneWidget);

      await tester.tap(find.text('Settings').last);
      await tester.pumpAndSettle();
      expect(find.text('Storage on this device'), findsOneWidget);

      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(find.text('Your documents'), findsOneWidget);
    },
  );

  testWidgets('welcome privacy route continues back to the app', (
    tester,
  ) async {
    await tester.pumpWidget(FiloApp(initializeServices: () async => services));
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('About local privacy'));
    await tester.pumpAndSettle();
    expect(find.text('Documents, on your terms.'), findsOneWidget);
    expect(
      find.textContaining('Local storage is not the same as encryption.'),
      findsOneWidget,
    );

    await tester.ensureVisible(find.text('Continue to Filo'));
    await tester.tap(find.text('Continue to Filo'));
    await tester.pumpAndSettle();
    expect(find.text('Your documents'), findsOneWidget);
  });

  testWidgets('shows a loading state during service initialization', (
    tester,
  ) async {
    final completer = Completer<FiloServices>();
    await tester.pumpWidget(
      FiloApp(initializeServices: () => completer.future),
    );
    expect(find.text('Getting Filo ready…'), findsOneWidget);

    completer.complete(services);
    await tester.pumpAndSettle();
    expect(find.text('Your documents'), findsOneWidget);
  });

  testWidgets('shows a recoverable initialization error and retries', (
    tester,
  ) async {
    var attempts = 0;
    await tester.pumpWidget(
      FiloApp(
        initializeServices: () async {
          attempts++;
          if (attempts == 1) throw StateError('storage unavailable');
          return services;
        },
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Filo couldn’t start'), findsOneWidget);
    expect(
      find.textContaining('Your existing data has not been replaced.'),
      findsOneWidget,
    );

    await tester.tap(find.text('Try again'));
    await tester.pumpAndSettle();
    expect(attempts, 2);
    expect(find.text('Your documents'), findsOneWidget);
  });

  testWidgets('error is shown without replacing data', (tester) async {
    final completer = Completer<FiloServices>();
    await tester.pumpWidget(
      FiloApp(initializeServices: () => completer.future),
    );
    expect(find.text('Getting Filo ready…'), findsOneWidget);
    completer.completeError(StateError('storage unavailable'));
    await tester.pumpAndSettle();
    expect(find.text('Filo couldn’t start'), findsOneWidget);
    expect(
      find.textContaining('Your existing data has not been replaced.'),
      findsOneWidget,
    );
  });

  for (final size in const [Size(320, 640), Size(393, 852), Size(480, 900)]) {
    testWidgets('renders without overflow at ${size.width}x${size.height}', (
      tester,
    ) async {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      await tester.pumpWidget(
        FiloApp(initializeServices: () async => services),
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      for (final label in ['Convert', 'Activity', 'Settings']) {
        await tester.tap(find.text(label).last);
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
      }
    });
  }
}

Future<(FiloServices, Directory)> _createTestServices() async {
  final root = await Directory.systemTemp.createTemp('filo_app_test_');
  Future<Directory> directory(String name) async =>
      Directory('${root.path}/$name');
  final storage = FileStorage(
    documentsDirectoryProvider: () => directory('files'),
    temporaryDirectoryProvider: () => directory('temporary'),
  );
  final database = LocalDatabase(
    documentsDirectoryProvider: () => directory('database'),
    databaseFactory: databaseFactoryFfi,
  );
  await storage.initialize();
  await database.initialize();
  return (
    FiloServices.compose(
      fileStorage: storage,
      localDatabase: database,
      activityManager: InMemoryActivityManager(),
    ),
    root,
  );
}

class _CountingActivityManager extends InMemoryActivityManager {
  int readCount = 0;

  @override
  Future<List<ActivityRecord>> getActivities() {
    readCount++;
    return super.getActivities();
  }
}
