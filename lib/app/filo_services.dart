import 'package:flutter/foundation.dart';

import '../application/conversion_manager.dart';
import '../application/conversion_workflow.dart';
import '../application/document_conversion_service.dart';
import '../application/activity_manager.dart';
import '../application/sqlite_activity_manager.dart';
import '../application/sqlite_library_manager.dart';
import '../services/conversion/image_converter.dart';
import '../services/conversion/pdf_creator.dart';
import '../services/conversion/pdf_renderer.dart';
import '../services/conversion/pdf_merger.dart';
import '../services/conversion/pdf_text_extractor.dart';
import '../services/platform/file_export_service.dart';
import '../services/platform/file_picker_service.dart';
import '../services/platform/file_picker_consent_store.dart';
import '../services/platform/file_share_service.dart';
import '../services/preview/thumbnail_service.dart';
import '../services/storage/file_storage.dart';
import '../services/storage/local_database.dart';

/// The single application-scoped set of services used by Filo's UI.
class FiloServices {
  FiloServices({
    required this.fileStorage,
    required this.localDatabase,
    required this.libraryManager,
    required this.activityManager,
    required this.thumbnailService,
    required this.conversionManager,
    required this.conversionWorkflow,
    required this.documentConversionService,
    required this.fileExportService,
    required this.fileShareService,
    ValueNotifier<int>? libraryChanges,
    ValueNotifier<int>? activityChanges,
    ValueNotifier<int>? managedStorageChanges,
    FilePickerConsentPreference? filePickerConsentStore,
  }) : libraryChanges = libraryChanges ?? ValueNotifier<int>(0),
       activityChanges = activityChanges ?? ValueNotifier<int>(0),
       managedStorageChanges = managedStorageChanges ?? ValueNotifier<int>(0),
       filePickerConsentStore =
           filePickerConsentStore ?? FilePickerConsentStore();

  final FileStorage fileStorage;
  final LocalDatabase localDatabase;
  final SqliteLibraryManager libraryManager;
  final ActivityManager activityManager;
  final ThumbnailService thumbnailService;
  final DefaultConversionManager conversionManager;
  final ConversionWorkflow conversionWorkflow;
  final DocumentConversionService documentConversionService;
  final FileExportService fileExportService;
  final FileShareService fileShareService;
  final ValueNotifier<int> libraryChanges;
  final ValueNotifier<int> activityChanges;
  final ValueNotifier<int> managedStorageChanges;
  final FilePickerConsentPreference filePickerConsentStore;

  void notifyManagedFilesChanged() {
    notifyLibraryChanged();
    notifyManagedStorageChanged();
  }

  void notifyLibraryChanged() {
    libraryChanges.value++;
  }

  void notifyManagedStorageChanged() {
    managedStorageChanges.value++;
  }

  /// Initializes app-private storage and the existing SQLite database once,
  /// then wires the current conversion and library services around them.
  static Future<FiloServices> initialize() async {
    final storage = FileStorage();
    final database = LocalDatabase();
    await storage.initialize();
    await database.initialize();

    return compose(fileStorage: storage, localDatabase: database);
  }

  /// Wires the existing initialized storage and database objects into the
  /// shared library and conversion workflow graph.
  static FiloServices compose({
    required FileStorage fileStorage,
    required LocalDatabase localDatabase,
    FilePickerService? filePickerService,
    FileExportService? fileExportService,
    FileShareService? fileShareService,
    DefaultConversionManager? conversionManager,
    ActivityManager? activityManager,
    FilePickerConsentPreference? filePickerConsentStore,
  }) {
    final storage = fileStorage;
    final database = localDatabase;

    final thumbnails = ThumbnailService(fileStorage: storage);
    final libraryChanges = ValueNotifier<int>(0);
    final activityChanges = ValueNotifier<int>(0);
    final managedStorageChanges = ValueNotifier<int>(0);
    final library = SqliteLibraryManager(
      database,
      fileStorage: storage,
      thumbnailService: thumbnails,
    );
    final activity = activityManager ?? SqliteActivityManager(database);
    final converters =
        conversionManager ??
        DefaultConversionManager([
          ImageConverter(),
          PdfCreator(),
          PdfRenderer(),
          PdfMerger(),
          PdfTextExtractor(),
        ]);
    final workflow = ConversionWorkflow(
      conversionManager: converters,
      fileStorage: storage,
      libraryManager: library,
      activityManager: activity,
      thumbnailService: thumbnails,
      onLibraryChanged: () {
        libraryChanges.value++;
      },
      onActivityChanged: () {
        activityChanges.value++;
      },
    );
    final picker =
        filePickerService ??
        FilePickerService(
          fileStorage: storage,
          onManagedStorageChanged: () => managedStorageChanges.value++,
        );
    final exporter =
        fileExportService ?? FileExportService(fileStorage: storage);
    final sharer = fileShareService ?? FileShareService(fileStorage: storage);
    final documentConversion = DocumentConversionService(
      filePickerService: picker,
      conversionWorkflow: workflow,
    );

    return FiloServices(
      fileStorage: storage,
      localDatabase: database,
      libraryManager: library,
      activityManager: activity,
      thumbnailService: thumbnails,
      conversionManager: converters,
      conversionWorkflow: workflow,
      documentConversionService: documentConversion,
      fileExportService: exporter,
      fileShareService: sharer,
      libraryChanges: libraryChanges,
      activityChanges: activityChanges,
      managedStorageChanges: managedStorageChanges,
      filePickerConsentStore: filePickerConsentStore,
    );
  }
}
