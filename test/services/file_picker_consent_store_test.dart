import 'dart:io';

import 'package:filo/services/platform/file_picker_consent_store.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late Directory root;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('filo_picker_consent_');
  });

  tearDown(() async {
    if (await root.exists()) await root.delete(recursive: true);
  });

  test('allow always persists in app-private support storage', () async {
    final first = FilePickerConsentStore(
      supportDirectoryProvider: () async => root,
    );
    expect(await first.getAllowAlways(), isFalse);

    await first.setAllowAlways(true);

    final nextSession = FilePickerConsentStore(
      supportDirectoryProvider: () async => root,
    );
    expect(await nextSession.getAllowAlways(), isTrue);

    await nextSession.setAllowAlways(false);
    expect(await first.getAllowAlways(), isFalse);
  });
}
