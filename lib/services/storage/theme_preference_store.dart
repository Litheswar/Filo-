import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';

/// Keeps the selected appearance in Filo's private support directory.
class ThemePreferenceStore {
  ThemePreferenceStore({Future<Directory> Function()? directoryProvider})
    : _directoryProvider = directoryProvider ?? getApplicationSupportDirectory;

  final Future<Directory> Function() _directoryProvider;

  Future<ThemeMode> read() async {
    try {
      final file = await _file();
      if (!await file.exists()) return ThemeMode.system;
      return switch ((await file.readAsString()).trim()) {
        'light' => ThemeMode.light,
        'dark' => ThemeMode.dark,
        _ => ThemeMode.system,
      };
    } on Object {
      return ThemeMode.system;
    }
  }

  Future<void> write(ThemeMode mode) async {
    final file = await _file();
    final value = switch (mode) {
      ThemeMode.light => 'light',
      ThemeMode.dark => 'dark',
      ThemeMode.system => 'system',
    };
    await file.writeAsString(value, flush: true);
  }

  Future<File> _file() async {
    final directory = await _directoryProvider();
    final preferences = Directory(
      '${directory.path}${Platform.pathSeparator}Filo${Platform.pathSeparator}preferences',
    );
    await preferences.create(recursive: true);
    return File('${preferences.path}${Platform.pathSeparator}theme_mode');
  }
}
