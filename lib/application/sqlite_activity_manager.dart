import 'dart:convert';

import '../services/storage/local_database.dart';
import '../models/conversion_type.dart';
import 'activity_manager.dart';

/// SQLite-backed conversion history. It stores display names and safe summaries,
/// not document contents or full input/output paths.
class SqliteActivityManager implements ActivityManager {
  SqliteActivityManager(this.localDatabase);

  final LocalDatabase localDatabase;

  @override
  Future<List<ActivityRecord>> getActivities() async {
    final db = await localDatabase.getDatabase();
    final rows = await db.query(
      'activities',
      orderBy: 'timestamp DESC, id ASC',
    );
    return rows.map(_recordFromRow).toList(growable: false);
  }

  @override
  Future<void> logActivity(ActivityRecord record) async {
    final db = await localDatabase.getDatabase();
    final outputNames = record.outputNames.isNotEmpty
        ? record.outputNames
        : record.outputName == null
        ? const <String>[]
        : [record.outputName!];
    final outputName = outputNames.isEmpty
        ? (record.outputPath == null ? null : _basename(record.outputPath!))
        : outputNames.length == 1
        ? outputNames.single
        : 'filo_names:${jsonEncode(outputNames)}';
    await db.insert('activities', {
      'id': record.id,
      'job_id': record.jobId,
      'conversion_type': _conversionTypeKey(record.conversionType),
      'is_success': record.isSuccess ? 1 : 0,
      'output_name': outputName,
      'error_summary': record.isSuccess
          ? null
          : _safeError(record.errorMessage),
      'timestamp': record.timestamp.toUtc().toIso8601String(),
      'duration_millis': record.duration?.inMilliseconds,
    });
  }

  @override
  Future<void> clearHistory() async {
    final db = await localDatabase.getDatabase();
    await db.delete('activities');
  }

  ActivityRecord _recordFromRow(Map<String, Object?> row) {
    final conversionType = _conversionTypeFromKey(
      row['conversion_type']! as String,
    );
    final success = row['is_success']! as int == 1;
    final duration = row['duration_millis'] as int?;
    final storedOutputName = row['output_name'] as String?;
    final outputNames = _decodeOutputNames(storedOutputName);
    return ActivityRecord(
      id: row['id']! as String,
      jobId: row['job_id']! as String,
      conversionType: conversionType,
      isSuccess: success,
      outputName: outputNames.isEmpty ? null : outputNames.first,
      outputNames: outputNames,
      errorMessage: success ? null : row['error_summary'] as String?,
      timestamp: DateTime.parse(row['timestamp']! as String).toLocal(),
      duration: duration == null ? null : Duration(milliseconds: duration),
    );
  }

  static List<String> _decodeOutputNames(String? value) {
    if (value == null || value.isEmpty) return const [];
    const prefix = 'filo_names:';
    if (value.startsWith(prefix)) {
      try {
        final decoded = jsonDecode(value.substring(prefix.length));
        if (decoded is List && decoded.every((item) => item is String)) {
          return decoded.cast<String>();
        }
      } on FormatException {
        // Preserve the stored value as a legacy display name if malformed.
      }
    }
    return [value];
  }

  static String _basename(String path) =>
      path.replaceAll(r'\', '/').split('/').last;

  static String? _safeError(String? message) {
    if (message == null || message.trim().isEmpty) return null;
    final noPaths = message.replaceAll(
      RegExp(r'(?:[A-Za-z]:)?[/\\][^\s,;]+'),
      '[path]',
    );
    final oneLine = noPaths.replaceAll(RegExp(r'\s+'), ' ').trim();
    return oneLine.length <= 240 ? oneLine : '${oneLine.substring(0, 237)}...';
  }

  static String _conversionTypeKey(ConversionType value) => switch (value) {
    ConversionType.jpgToPng => 'jpg_to_png',
    ConversionType.pngToJpg => 'png_to_jpg',
    ConversionType.singleImageToPdf => 'single_image_to_pdf',
    ConversionType.multipleImagesToPdf => 'multiple_images_to_pdf',
    ConversionType.pdfToImages => 'pdf_to_images',
    ConversionType.txtToPdf => 'txt_to_pdf',
    ConversionType.pdfToTxt => 'pdf_to_txt',
  };

  static ConversionType _conversionTypeFromKey(String value) => switch (value) {
    'jpg_to_png' => ConversionType.jpgToPng,
    'png_to_jpg' => ConversionType.pngToJpg,
    'single_image_to_pdf' => ConversionType.singleImageToPdf,
    'multiple_images_to_pdf' => ConversionType.multipleImagesToPdf,
    'pdf_to_images' => ConversionType.pdfToImages,
    'txt_to_pdf' => ConversionType.txtToPdf,
    'pdf_to_txt' => ConversionType.pdfToTxt,
    _ => throw const LocalDatabaseException(
      'Database contains an unknown conversion type.',
    ),
  };
}
