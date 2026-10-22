import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:filo/app/filo_app.dart';
import 'package:filo/app/filo_services.dart';
import 'package:filo/application/conversion_workflow.dart';
import 'package:filo/application/document_conversion_service.dart';
import 'package:filo/models/conversion_result.dart';
import 'package:filo/models/conversion_type.dart';
import 'package:filo/models/file_record.dart';
import 'package:filo/services/platform/file_export_service.dart';
import 'package:filo/services/platform/file_picker_service.dart';
import 'package:filo/services/platform/file_picker_consent_store.dart';
import 'package:filo/services/platform/file_share_service.dart';
import 'package:filo/services/storage/file_storage.dart';
import 'package:filo/services/storage/local_database.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  late Directory root;
  late FileStorage storage;
  late _FakePicker pickerAdapter;
  late _FakeDocumentConversionService conversionService;
  late _FakeExportService exportService;
  late _FakeShareService shareService;
  late _MemoryConsentStore consentStore;
  late FiloServices services;

  setUpAll(sqfliteFfiInit);

  setUp(() async {
    root = await Directory.systemTemp.createTemp('filo_convert_ui_');
    storage = FileStorage(
      documentsDirectoryProvider: () async => Directory('${root.path}/docs'),
      temporaryDirectoryProvider: () async => Directory('${root.path}/cache'),
    );
    final database = LocalDatabase(
      documentsDirectoryProvider: () async => Directory('${root.path}/db'),
      databaseFactory: databaseFactoryFfi,
    );
    pickerAdapter = _FakePicker();
    consentStore = _MemoryConsentStore();
    final pickerService = FilePickerService(
      fileStorage: storage,
      adapter: pickerAdapter,
      idGenerator: () => 'widget-picker-${pickerAdapter.pickCount}',
    );
    exportService = _FakeExportService(storage);
    shareService = _FakeShareService(storage);
    final base = FiloServices.compose(
      fileStorage: storage,
      localDatabase: database,
      filePickerService: pickerService,
      fileExportService: exportService,
      fileShareService: shareService,
      filePickerConsentStore: consentStore,
    );
    conversionService = _FakeDocumentConversionService(
      filePickerService: pickerService,
      conversionWorkflow: base.conversionWorkflow,
    );
    services = FiloServices(
      fileStorage: base.fileStorage,
      localDatabase: base.localDatabase,
      libraryManager: base.libraryManager,
      activityManager: base.activityManager,
      thumbnailService: base.thumbnailService,
      conversionManager: base.conversionManager,
      conversionWorkflow: base.conversionWorkflow,
      documentConversionService: conversionService,
      fileExportService: exportService,
      fileShareService: shareService,
      libraryChanges: base.libraryChanges,
      activityChanges: base.activityChanges,
      managedStorageChanges: base.managedStorageChanges,
      filePickerConsentStore: consentStore,
    );
  });

  tearDown(() async {
    if (await root.exists()) await root.delete(recursive: true);
  });

  testWidgets('shows each supported conversion and marks the selection', (
    tester,
  ) async {
    await _openConvert(tester, services);
    for (final type in ConversionType.values) {
      await _show(tester, find.text(type.displayName));
      expect(find.text(type.displayName), findsOneWidget);
    }

    final initial = ConversionType.values.first;
    expect(
      tester.widget<Card>(find.byKey(ValueKey('choice-${initial.name}'))).color,
      const Color(0xFFE8F2ED),
    );
    final next = ConversionType.values[1];
    await _show(tester, find.text(next.displayName));
    await tester.tap(find.text(next.displayName));
    await tester.pumpAndSettle();
    expect(
      tester.widget<Card>(find.byKey(ValueKey('choice-${next.name}'))).color,
      const Color(0xFFE8F2ED),
    );
  });

  testWidgets(
    'stages selected files, shows names, and waits for explicit start',
    (tester) async {
      await _chooseFiles(tester, services, ConversionType.multipleImagesToPdf);

      expect(pickerAdapter.requestedExtensions, ['jpg', 'jpeg', 'png']);
      expect(pickerAdapter.pickCount, 1);
      expect(conversionService.selectedTypes, [
        ConversionType.multipleImagesToPdf,
      ]);
      expect(conversionService.convertCount, 0);
      expect(find.text('first.png'), findsOneWidget);
      expect(find.text('second.jpg'), findsOneWidget);

      await _show(tester, find.text('Convert and save'));
      await tester.tap(find.text('Convert and save'));
      await tester.pumpAndSettle();
      expect(conversionService.convertCount, 1);
      expect(
        pickerAdapter.pickCount,
        1,
        reason: 'submission must not reopen the picker',
      );
      expect(find.text('Conversion complete'), findsOneWidget);
    },
  );

  testWidgets('picker cancellation is distinct and does not run conversion', (
    tester,
  ) async {
    pickerAdapter.cancelNext = true;
    conversionService.queueSelections.add(
      await _prepareSelection(tester, services, ConversionType.jpgToPng),
    );
    await _openConvert(tester, services);
    await _show(tester, find.text('Select files'));
    await tester.tap(find.text('Select files'));
    await tester.pump();
    await tester.tap(find.text('Allow once'));
    await tester.pumpAndSettle();

    expect(conversionService.convertCount, 0);
    expect(find.textContaining('could not be selected'), findsNothing);
    expect(find.text('No file was selected.'), findsOneWidget);
    expect(find.textContaining('Choose one JPG file.'), findsOneWidget);
  });

  testWidgets('picker consent is one-time, persistent, and reconsiderable', (
    tester,
  ) async {
    await _openConvert(tester, services);

    await _show(tester, find.text('Select files'));

    await tester.tap(find.text('Select files'));
    await tester.pump();
    expect(find.text('Allow once'), findsOneWidget);
    expect(find.byType(AlertDialog), findsOneWidget);
    await tester.tap(find.text('Allow once'));
    await tester.pumpAndSettle();
    expect(conversionService.selectedTypes.length, 1);
    expect(await consentStore.getAllowAlways(), isFalse);
    expect(
      find.text('The selected files could not be selected.'),
      findsNothing,
    );

    await _show(tester, find.text('Select files'));
    await tester.tap(find.text('Select files'));
    await tester.pump();
    expect(find.text('Allow always'), findsOneWidget);
    await tester.tap(find.text('Don’t allow'));
    await tester.pumpAndSettle();
    expect(conversionService.selectedTypes.length, 1);
    expect(
      find.textContaining('File selection was cancelled.'),
      findsOneWidget,
    );

    await _show(tester, find.text('Select files'));
    await tester.tap(find.text('Select files'));
    await tester.pump();
    expect(find.byType(AlertDialog), findsOneWidget);
    await tester.tap(find.text('Allow always'));
    await tester.pumpAndSettle();
    expect(await consentStore.getAllowAlways(), isTrue);
    expect(conversionService.selectedTypes.length, 2);

    await _show(tester, find.text('Select files'));
    await tester.tap(find.text('Select files'));
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsNothing);
    expect(conversionService.selectedTypes.length, 3);
  });

  testWidgets('rapid picker taps keep one consent request and picker', (
    tester,
  ) async {
    final consentGate = Completer<bool>();
    consentStore.readGate = consentGate;
    await _openConvert(tester, services);
    await _show(tester, find.text('Select files'));

    await tester.tap(find.text('Select files'));
    await tester.pump();
    final pendingPickerButton = tester.widget<OutlinedButton>(
      find.widgetWithText(OutlinedButton, 'Opening files…'),
    );
    expect(pendingPickerButton.onPressed, isNull);
    await tester.tap(find.text('Opening files…'), warnIfMissed: false);
    await tester.pump();
    expect(consentStore.readCount, 1);
    expect(find.byType(AlertDialog), findsNothing);

    consentGate.complete(false);
    await tester.pump();
    await tester.pump();
    expect(find.byType(AlertDialog), findsOneWidget);
    await tester.tap(find.text('Allow once'));
    await tester.pumpAndSettle();
    expect(conversionService.selectedTypes.length, 1);
  });

  testWidgets('invalid selected content displays the picker validation error', (
    tester,
  ) async {
    pickerAdapter.invalidNext = true;
    conversionService.queueSelections.add(
      await _prepareSelection(tester, services, ConversionType.jpgToPng),
    );
    await _openConvert(tester, services);
    await _show(tester, find.text('Select files'));
    await tester.tap(find.text('Select files'));
    await tester.pump();
    await tester.tap(find.text('Allow once'));
    await tester.pumpAndSettle();
    expect(
      find.text('The selected file could not be read or validated.'),
      findsOneWidget,
    );
    expect(conversionService.convertCount, 0);
  });

  testWidgets('conversion progress blocks duplicate submissions', (
    tester,
  ) async {
    conversionService.conversionGate = Completer<DocumentConversionOutcome>();
    await _chooseFiles(tester, services, ConversionType.jpgToPng);
    await _show(tester, find.text('Convert and save'));
    await tester.tap(find.text('Convert and save'));
    await tester.pump();

    expect(find.text('Converting and saving to your library…'), findsOneWidget);
    expect(conversionService.convertCount, 1);
    final pickerButton = tester.widget<OutlinedButton>(
      find.widgetWithText(OutlinedButton, 'Select files'),
    );
    expect(pickerButton.onPressed, isNull);

    conversionService.conversionGate!.complete(_success([_record('done.png')]));
    await tester.pumpAndSettle();
    expect(find.text('Conversion complete'), findsOneWidget);
  });

  testWidgets('successful multi-output records preserve workflow order', (
    tester,
  ) async {
    conversionService.nextOutcome = _success([
      _record('page-2.png'),
      _record('page-1.png'),
    ]);
    await _chooseFiles(tester, services, ConversionType.pdfToImages);
    await _show(tester, find.text('Convert and save'));
    await tester.tap(find.text('Convert and save'));
    await tester.pumpAndSettle();

    await _show(tester, find.text('page-2.png'));
    await _show(tester, find.text('page-1.png'));
    expect(find.text('page-2.png'), findsOneWidget);
    expect(find.text('page-1.png'), findsOneWidget);
    expect(
      tester.getTopLeft(find.text('page-2.png')).dy,
      lessThan(tester.getTopLeft(find.text('page-1.png')).dy),
    );
    expect(find.text('PNG · 4.0 KB'), findsNWidgets(2));
  });

  testWidgets('conversion failure has no success state and can restart', (
    tester,
  ) async {
    conversionService.nextOutcome = _failure('The image could not be read.');
    await _chooseFiles(tester, services, ConversionType.jpgToPng);
    await _show(tester, find.text('Convert and save'));
    await tester.tap(find.text('Convert and save'));
    await tester.pumpAndSettle();

    expect(find.text('Conversion wasn’t completed'), findsOneWidget);
    expect(find.text('Conversion complete'), findsNothing);
    expect(find.text('The image could not be read.'), findsOneWidget);
    await _show(tester, find.text('Another conversion'));
    await tester.tap(find.text('Another conversion'));
    await tester.pumpAndSettle();
    expect(find.text('Conversion wasn’t completed'), findsNothing);
    expect(find.text('Select files'), findsOneWidget);
  });

  testWidgets('partial outcomes show persisted outputs and their failure', (
    tester,
  ) async {
    conversionService.nextOutcome = _partial([
      _record('saved.png'),
    ], 'One output could not be saved.');
    await _chooseFiles(tester, services, ConversionType.pdfToImages);
    await _show(tester, find.text('Convert and save'));
    await tester.tap(find.text('Convert and save'));
    await tester.pumpAndSettle();

    await _show(tester, find.text('Partially complete'));
    expect(find.text('saved.png'), findsOneWidget);
    expect(find.text('One output could not be saved.'), findsOneWidget);
    expect(find.text('Conversion complete'), findsNothing);
  });

  testWidgets(
    'export/share handle cancellation, failures and delivery limits',
    (tester) async {
      final record = _record('result.png');
      conversionService.nextOutcome = _success([record]);
      await _chooseFiles(tester, services, ConversionType.jpgToPng);
      await _show(tester, find.text('Convert and save'));
      await tester.tap(find.text('Convert and save'));
      await tester.pumpAndSettle();

      await _show(tester, find.text('Export'));
      exportService.nextResult = const FileExportResult.cancelled();
      await tester.tap(find.text('Export').first);
      await tester.pumpAndSettle();
      expect(exportService.lastRecord, same(record));
      expect(find.textContaining('exported'), findsNothing);

      exportService.nextResult = const FileExportResult.failure(
        'Choose another location.',
      );
      await tester.tap(find.text('Export').first);
      await tester.pumpAndSettle();
      expect(find.text('Choose another location.'), findsOneWidget);

      shareService.nextResult = const FileShareResult.actionSelected();
      await tester.tap(find.text('Share').first);
      await tester.pumpAndSettle();
      expect(shareService.lastRecord, same(record));
      expect(find.textContaining('Delivery is not confirmed.'), findsOneWidget);

      shareService.nextResult = const FileShareResult.dismissed();
      await tester.tap(find.text('Share').first);
      await tester.pumpAndSettle();
      expect(find.textContaining('Delivery is not confirmed.'), findsNothing);
    },
  );

  testWidgets('result can navigate to the Library destination', (tester) async {
    conversionService.nextOutcome = _success([_record('result.png')]);
    await _chooseFiles(tester, services, ConversionType.jpgToPng);
    await _show(tester, find.text('Convert and save'));
    await tester.tap(find.text('Convert and save'));
    await tester.pumpAndSettle();
    await _show(tester, find.text('Open library'));
    await tester.tap(find.text('Open library'));
    await tester.pumpAndSettle();
    expect(find.text('Your documents'), findsOneWidget);
  });

  testWidgets('convert screen stays usable on a compact phone width', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(320, 640);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await _openConvert(tester, services);
    expect(tester.takeException(), isNull);
    await _show(tester, find.text('PDF to TXT'));
    expect(tester.takeException(), isNull);
    expect(find.byType(NavigationBar), findsOneWidget);
  });
}

Future<void> _openConvert(WidgetTester tester, FiloServices services) async {
  await tester.pumpWidget(FiloApp(initializeServices: () async => services));
  await tester.pumpAndSettle();
  await tester.tap(find.text('Convert').last);
  await tester.pumpAndSettle();
}

Future<void> _show(WidgetTester tester, Finder target) async {
  final scrollable = find.descendant(
    of: find.byKey(const ValueKey('convert-scroll')),
    matching: find.byType(Scrollable),
  );
  await tester.scrollUntilVisible(target, 240, scrollable: scrollable);
  await tester.ensureVisible(target);
  await tester.pumpAndSettle();
}

Future<void> _chooseFiles(
  WidgetTester tester,
  FiloServices services,
  ConversionType type,
) async {
  _conversionServiceFor(services).queueSelections
      .add(await _prepareSelection(tester, services, type));
  await _openConvert(tester, services);
  await _show(tester, find.text(type.displayName));
  await tester.tap(find.text(type.displayName));
  await tester.pumpAndSettle();
  await _show(tester, find.text('Select files'));
  await tester.tap(find.text('Select files'));
  await tester.pump();
  await tester.tap(find.text('Allow once'));
  await tester.pumpAndSettle();
}

_FakeDocumentConversionService _conversionServiceFor(FiloServices services) =>
    services.documentConversionService as _FakeDocumentConversionService;

Future<FileSelectionResult> _prepareSelection(
  WidgetTester tester,
  FiloServices services,
  ConversionType type,
) async => (await tester.runAsync(
  () => services.documentConversionService.filePickerService
      .selectForConversion(type),
))!;

FileRecord _record(String name) => FileRecord(
  id: 'record-$name',
  fileName: name,
  extension: name.split('.').last,
  sizeInBytes: 4096,
  createdAt: DateTime.utc(2026),
  localPath: '/managed/$name',
  conversionType: ConversionType.jpgToPng,
);

DocumentConversionOutcome _success(List<FileRecord> records) {
  final result = ConversionResult.multipleSuccess(
    jobId: 'job-ui',
    outputPaths: records.map((record) => record.localPath).toList(),
  );
  return DocumentConversionOutcome(
    status: DocumentConversionStatus.success,
    workflowOutcome: ConversionWorkflowOutcome(
      status: ConversionWorkflowStatus.success,
      conversionResult: result,
      documents: records,
    ),
  );
}

DocumentConversionOutcome _failure(String message) => DocumentConversionOutcome(
  status: DocumentConversionStatus.conversionFailed,
  errorDescription: message,
  workflowOutcome: ConversionWorkflowOutcome(
    status: ConversionWorkflowStatus.conversionFailed,
    conversionResult: ConversionResult.failure(
      jobId: 'job-ui',
      errorMessage: message,
    ),
    errorMessage: message,
  ),
);

DocumentConversionOutcome _partial(List<FileRecord> records, String message) =>
    DocumentConversionOutcome(
      status: DocumentConversionStatus.persistenceFailed,
      errorDescription: message,
      workflowOutcome: ConversionWorkflowOutcome(
        status: ConversionWorkflowStatus.persistenceFailed,
        conversionResult: ConversionResult.multipleSuccess(
          jobId: 'job-ui',
          outputPaths: records.map((record) => record.localPath).toList(),
        ),
        documents: records,
        errorMessage: message,
      ),
    );

class _MemoryConsentStore implements FilePickerConsentPreference {
  bool allowAlways = false;
  int readCount = 0;
  Completer<bool>? readGate;

  @override
  Future<bool> getAllowAlways() async {
    readCount++;
    final gate = readGate;
    return gate == null ? allowAlways : gate.future;
  }

  @override
  Future<void> setAllowAlways(bool allowed) async {
    allowAlways = allowed;
  }
}

class _FakePicker implements FilePickerAdapter {
  bool cancelNext = false;
  bool invalidNext = false;
  List<String>? requestedExtensions;
  int pickCount = 0;

  @override
  Future<PickerFileSource?> pickSingle(List<String> allowedExtensions) async {
    pickCount++;
    requestedExtensions = allowedExtensions;
    if (cancelNext) {
      cancelNext = false;
      return null;
    }
    final extension = allowedExtensions.first;
    final bytes = invalidNext ? <int>[0] : _bytesFor(extension);
    invalidNext = false;
    return _source('source.$extension', bytes);
  }

  @override
  Future<List<PickerFileSource>?> pickMultiple(
    List<String> allowedExtensions,
  ) async {
    pickCount++;
    requestedExtensions = allowedExtensions;
    if (cancelNext) {
      cancelNext = false;
      return null;
    }
    return [
      _source('first.png', _bytesFor('png')),
      _source('second.jpg', _bytesFor('jpg')),
    ];
  }

  PickerFileSource _source(String name, List<int> bytes) => PickerFileSource(
    name: name,
    openRead: () => Stream.value(Uint8List.fromList(bytes)),
  );

  List<int> _bytesFor(String extension) => switch (extension) {
    'jpg' || 'jpeg' => [0xff, 0xd8, 0xff, 1],
    'png' => [137, 80, 78, 71, 13, 10, 26, 10, 1],
    'pdf' => [37, 80, 68, 70, 45, 49],
    _ => 'fixture text'.codeUnits,
  };
}

class _FakeDocumentConversionService extends DocumentConversionService {
  _FakeDocumentConversionService({
    required super.filePickerService,
    required super.conversionWorkflow,
  });

  int convertCount = 0;
  final List<FileSelectionResult> queueSelections = [];
  final List<ConversionType> selectedTypes = [];
  DocumentConversionOutcome? nextOutcome;
  Completer<DocumentConversionOutcome>? conversionGate;

  @override
  Future<FileSelectionResult> selectInputs(
    ConversionType conversionType,
  ) async {
    selectedTypes.add(conversionType);
    if (queueSelections.isEmpty) return const FileSelectionResult.cancelled();
    return queueSelections.removeAt(0);
  }

  @override
  Future<DocumentConversionOutcome> convertSelection(
    PickedInputSelection selection, {
    String? requestedOutputName,
    String? outputDirectory,
  }) {
    convertCount++;
    final gate = conversionGate;
    if (gate != null) return gate.future;
    final result = nextOutcome ?? _success([_record('converted.png')]);
    return Future.value(result);
  }
}

class _FakeExportService extends FileExportService {
  _FakeExportService(FileStorage storage) : super(fileStorage: storage);

  FileRecord? lastRecord;
  FileExportResult nextResult = const FileExportResult.success('saved');

  @override
  Future<FileExportResult> exportDocument(FileRecord record) async {
    lastRecord = record;
    return nextResult;
  }
}

class _FakeShareService extends FileShareService {
  _FakeShareService(FileStorage storage) : super(fileStorage: storage);

  FileRecord? lastRecord;
  FileShareResult nextResult = const FileShareResult.actionSelected();

  @override
  Future<FileShareResult> shareDocument(FileRecord record) async {
    lastRecord = record;
    return nextResult;
  }
}
