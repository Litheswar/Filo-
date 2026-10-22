import 'package:filo/application/activity_manager.dart';
import 'package:filo/models/conversion_type.dart';
import 'package:filo/screens/activity_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('loads newest activities, statuses, outputs, and safe errors', (
    tester,
  ) async {
    final manager = _ActivityManager([
      ActivityRecord(
        id: 'older',
        jobId: 'job-1',
        conversionType: ConversionType.jpgToPng,
        isSuccess: true,
        outputNames: ['converted.png'],
        timestamp: DateTime(2024),
      ),
      ActivityRecord(
        id: 'newer',
        jobId: 'job-2',
        conversionType: ConversionType.pdfToImages,
        isSuccess: true,
        outputNames: [
          'a_very_long_output_filename_that_should_wrap_without_overflow.png',
          'page_2.png',
        ],
        timestamp: DateTime(2025),
      ),
      ActivityRecord(
        id: 'failed',
        jobId: 'job-3',
        conversionType: ConversionType.pdfToTxt,
        isSuccess: false,
        errorMessage: r'Could not read C:\private\secret.pdf',
        timestamp: DateTime(2023),
      ),
    ]);
    await tester.pumpWidget(_app(ActivityScreen(activityManager: manager)));
    await tester.pumpAndSettle();

    expect(find.text('PDF to images'), findsOneWidget);
    expect(find.text('Outputs (2)'), findsOneWidget);
    expect(find.text('page_2.png'), findsOneWidget);
    expect(find.text('Completed'), findsNWidgets(2));
    expect(find.text('Failed'), findsOneWidget);
    expect(find.textContaining('Could not read [file]'), findsOneWidget);
    expect(find.textContaining('C:\\private'), findsNothing);
    expect(tester.takeException(), isNull);
    final order = tester.getTopLeft(find.text('PDF to images')).dy;
    expect(order, lessThan(tester.getTopLeft(find.text('JPG to PNG')).dy));
  });

  testWidgets('shows empty state and refresh loads new records once', (
    tester,
  ) async {
    final manager = _ActivityManager([]);
    await tester.pumpWidget(_app(ActivityScreen(activityManager: manager)));
    await tester.pumpAndSettle();
    expect(find.text('No recent activity'), findsOneWidget);

    manager.records.add(
      ActivityRecord(
        id: 'one',
        jobId: 'job-1',
        conversionType: ConversionType.pngToJpg,
        isSuccess: true,
        outputName: 'one.jpg',
      ),
    );
    await tester.drag(find.byType(ListView), const Offset(0, 300));
    await tester.pumpAndSettle();
    expect(find.text('PNG to JPG'), findsOneWidget);
    expect(manager.readCount, 2);
  });

  testWidgets('shows a recoverable activity load error', (tester) async {
    final manager = _ActivityManager([], fail: true);
    await tester.pumpWidget(_app(ActivityScreen(activityManager: manager)));
    await tester.pumpAndSettle();
    expect(find.text('Activity unavailable'), findsOneWidget);
    expect(
      find.text('Your saved activity could not be loaded.'),
      findsOneWidget,
    );
    await tester.tap(find.text('Try again'));
    await tester.pumpAndSettle();
    expect(manager.readCount, 2);
  });

  testWidgets('loads on activation and refreshes on activity changes', (
    tester,
  ) async {
    final manager = _ActivityManager([]);
    final changes = ValueNotifier<int>(0);
    Widget screen(bool active) => _app(
      ActivityScreen(
        activityManager: manager,
        activityChanges: changes,
        isActive: active,
      ),
    );

    await tester.pumpWidget(screen(false));
    await tester.pumpAndSettle();
    changes.value++;
    await tester.pumpAndSettle();
    expect(manager.readCount, 0);

    await tester.pumpWidget(screen(true));
    await tester.pumpAndSettle();
    expect(manager.readCount, 1);
    manager.records.add(
      ActivityRecord(
        id: 'latest',
        jobId: 'latest-job',
        conversionType: ConversionType.pdfToTxt,
        isSuccess: true,
        outputName: 'latest.txt',
      ),
    );
    changes.value++;
    await tester.pumpAndSettle();

    expect(manager.readCount, 2);
    expect(find.text('PDF to text'), findsOneWidget);
    expect(tester.takeException(), isNull);
    changes.dispose();
  });
}

Widget _app(Widget child) => MaterialApp(home: Scaffold(body: child));

class _ActivityManager implements ActivityManager {
  _ActivityManager(this.records, {this.fail = false});

  final bool fail;
  final List<ActivityRecord> records;
  int readCount = 0;

  @override
  Future<List<ActivityRecord>> getActivities() async {
    readCount++;
    if (fail) throw StateError('private internal database details');
    final result = List<ActivityRecord>.of(records)
      ..sort((a, b) => b.timestamp.compareTo(a.timestamp));
    return result;
  }

  @override
  Future<void> logActivity(ActivityRecord record) async => records.add(record);

  @override
  Future<void> clearHistory() async => records.clear();
}
