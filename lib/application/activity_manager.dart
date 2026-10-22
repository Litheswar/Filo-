import '../models/conversion_result.dart';
import '../models/conversion_type.dart';

/// Represents a recorded entry in the user's conversion activity/history log.
class ActivityRecord {
  /// Unique identifier for this activity log entry.
  final String id;

  /// Associated job ID.
  final String jobId;

  /// Conversion type executed.
  final ConversionType conversionType;

  /// Whether the conversion was successful.
  final bool isSuccess;

  /// Primary output file path if successful.
  final String? outputPath;

  /// Display-only output filename for persisted activity history.
  final String? outputName;

  /// Display-only output filenames in conversion order.
  final List<String> outputNames;

  /// Error message if failed.
  final String? errorMessage;

  /// Timestamp when the activity was logged.
  final DateTime timestamp;

  /// Processing duration if known.
  final Duration? duration;

  ActivityRecord({
    required this.id,
    required this.jobId,
    required this.conversionType,
    required this.isSuccess,
    this.outputPath,
    this.outputName,
    List<String>? outputNames,
    this.errorMessage,
    DateTime? timestamp,
    this.duration,
  }) : timestamp = timestamp ?? DateTime.now(),
       outputNames = List.unmodifiable(
         outputNames ?? (outputName == null ? const [] : [outputName]),
       ) {
    if (id.trim().isEmpty) {
      throw ArgumentError.value(id, 'id', 'Activity record ID cannot be empty');
    }
    if (jobId.trim().isEmpty) {
      throw ArgumentError.value(jobId, 'jobId', 'Job ID cannot be empty');
    }
  }

  /// Convenience factory to create an [ActivityRecord] directly from a completed [ConversionResult].
  factory ActivityRecord.fromResult({
    required String id,
    required ConversionResult result,
    required ConversionType conversionType,
    DateTime? timestamp,
  }) {
    return ActivityRecord(
      id: id,
      jobId: result.jobId,
      conversionType: conversionType,
      isSuccess: result.isSuccess,
      outputPath: result.outputPath,
      outputName: result.outputPath?.replaceAll(r'\', '/').split('/').last,
      outputNames: result.outputPaths
          .map((path) => path.replaceAll(r'\', '/').split('/').last)
          .toList(growable: false),
      errorMessage: result.errorMessage,
      timestamp: timestamp,
      duration: result.duration,
    );
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    return other is ActivityRecord &&
        other.id == id &&
        other.jobId == jobId &&
        other.conversionType == conversionType &&
        other.isSuccess == isSuccess &&
        other.outputPath == outputPath &&
        other.outputName == outputName &&
        _sameNames(other.outputNames, outputNames) &&
        other.errorMessage == errorMessage &&
        other.timestamp == timestamp &&
        other.duration == duration;
  }

  @override
  int get hashCode => Object.hash(
    id,
    jobId,
    conversionType,
    isSuccess,
    outputPath,
    outputName,
    Object.hashAll(outputNames),
    errorMessage,
    timestamp,
    duration,
  );
}

bool _sameNames(List<String> left, List<String> right) {
  if (left.length != right.length) return false;
  for (var index = 0; index < left.length; index++) {
    if (left[index] != right[index]) return false;
  }
  return true;
}

/// Contract for managing conversion history and activity logs.
abstract class ActivityManager {
  /// Retrieves all recorded activities, typically sorted newest first.
  Future<List<ActivityRecord>> getActivities();

  /// Logs a new activity entry.
  Future<void> logActivity(ActivityRecord record);

  /// Clears all recorded activity history.
  Future<void> clearHistory();
}

/// In-memory implementation of [ActivityManager] for testing and runtime tracking.
class InMemoryActivityManager implements ActivityManager {
  final List<ActivityRecord> _records = [];

  InMemoryActivityManager([List<ActivityRecord>? initialRecords]) {
    if (initialRecords != null) {
      _records.addAll(initialRecords);
    }
  }

  @override
  Future<List<ActivityRecord>> getActivities() async {
    final list = List<ActivityRecord>.from(_records);
    list.sort((a, b) {
      final byTimestamp = b.timestamp.compareTo(a.timestamp);
      return byTimestamp == 0 ? a.id.compareTo(b.id) : byTimestamp;
    });
    return List.unmodifiable(list);
  }

  @override
  Future<void> logActivity(ActivityRecord record) async {
    _records.add(record);
  }

  @override
  Future<void> clearHistory() async {
    _records.clear();
  }
}
