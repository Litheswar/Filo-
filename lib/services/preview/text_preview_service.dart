import 'dart:convert';
import 'dart:io';

class TextPreviewResult {
  const TextPreviewResult({
    required this.isSuccess,
    this.text = '',
    this.truncated = false,
    this.errorMessage,
  });

  final bool isSuccess;
  final String text;
  final bool truncated;
  final String? errorMessage;

  /// Ready-to-display text with an explicit marker when the read was bounded.
  String get displayText => truncated ? '$text\n… (preview truncated)' : text;
}

/// Reads a bounded UTF-8 preview from local TXT files without invoking PDF conversion.
class TextPreviewService {
  TextPreviewService({this.maxBytes = 64 * 1024}) {
    if (maxBytes < 1) throw ArgumentError.value(maxBytes, 'maxBytes');
  }

  final int maxBytes;

  Future<TextPreviewResult> preview(File file) async {
    if (_extension(file.path) != 'txt') {
      return const TextPreviewResult(
        isSuccess: false,
        errorMessage: 'Text previews support TXT files only.',
      );
    }

    try {
      if (!await file.exists()) {
        return const TextPreviewResult(
          isSuccess: false,
          errorMessage: 'Text file was not found.',
        );
      }
      final bytes = <int>[];
      await for (final chunk in file.openRead(0, maxBytes + 1)) {
        final remaining = maxBytes + 1 - bytes.length;
        bytes.addAll(chunk.take(remaining));
        if (bytes.length > maxBytes) break;
      }
      final truncated = bytes.length > maxBytes;
      if (truncated) bytes.removeRange(maxBytes, bytes.length);
      return TextPreviewResult(
        isSuccess: true,
        text: utf8.decode(bytes, allowMalformed: true),
        truncated: truncated,
      );
    } on FileSystemException {
      return const TextPreviewResult(
        isSuccess: false,
        errorMessage: 'Text file could not be read.',
      );
    } on FormatException {
      // allowMalformed should prevent decode errors; retain an explicit fallback.
      return const TextPreviewResult(
        isSuccess: false,
        errorMessage: 'Text file encoding could not be decoded.',
      );
    }
  }

  String _extension(String path) {
    final basename = path.replaceAll(r'\', '/').split('/').last;
    final dot = basename.lastIndexOf('.');
    return dot < 0 ? '' : basename.substring(dot + 1).toLowerCase();
  }
}
