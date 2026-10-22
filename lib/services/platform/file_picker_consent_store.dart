import 'dart:io';

import 'package:path_provider/path_provider.dart';

/// Stores Filo's app-level consent to open the Android system document picker.
/// This does not grant access to files; the picker still controls selection.
abstract interface class FilePickerConsentPreference {
  Future<bool> getAllowAlways();
  Future<void> setAllowAlways(bool allowed);
}

class FilePickerConsentStore implements FilePickerConsentPreference {
  FilePickerConsentStore({
    Future<Directory> Function()? supportDirectoryProvider,
  }) : _supportDirectoryProvider =
           supportDirectoryProvider ?? getApplicationSupportDirectory;

  static const _fileName = 'file_picker_consent';
  final Future<Directory> Function() _supportDirectoryProvider;

  @override
  Future<bool> getAllowAlways() async {
    try {
      final file = await _file();
      return await file.exists() &&
          (await file.readAsString()).trim() == 'allow';
    } on FileSystemException {
      return false;
    }
  }

  @override
  Future<void> setAllowAlways(bool allowed) async {
    final file = await _file();
    if (allowed) {
      await file.writeAsString('allow', flush: true);
    } else if (await file.exists()) {
      await file.delete();
    }
  }

  Future<File> _file() async {
    final directory = await _supportDirectoryProvider();
    await directory.create(recursive: true);
    return File('${directory.path}${Platform.pathSeparator}$_fileName');
  }
}
