import 'dart:io';

import 'package:filo/services/storage/theme_preference_store.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'persists supported theme choices locally and defaults to system',
    () async {
      final root = await Directory.systemTemp.createTemp('filo_theme_test_');
      addTearDown(() async {
        if (await root.exists()) await root.delete(recursive: true);
      });
      final store = ThemePreferenceStore(directoryProvider: () async => root);

      expect(await store.read(), ThemeMode.system);
      await store.write(ThemeMode.dark);
      expect(await store.read(), ThemeMode.dark);
      await store.write(ThemeMode.light);
      expect(await store.read(), ThemeMode.light);
      await store.write(ThemeMode.system);
      expect(await store.read(), ThemeMode.system);
    },
  );
}
