import 'dart:convert';

/// AnyShare modification (2026-10-18): local (per-browser) annotation for a
/// file/folder in a shared directory (F-DIR-07). Keyed by
/// `<deviceFingerprint>:<rootId>:<path>`; never uploaded.
class DirAnnotation {
  final List<String> tags;
  final String note;

  const DirAnnotation({this.tags = const [], this.note = ''});

  bool get isEmpty => tags.isEmpty && note.isEmpty;

  Map<String, dynamic> toJson() => {'tags': tags, 'note': note};

  factory DirAnnotation.fromJson(Map<String, dynamic> json) {
    return DirAnnotation(
      tags: [
        for (final tag in (json['tags'] as List? ?? []))
          if (tag is String) tag,
      ],
      note: json['note'] as String? ?? '',
    );
  }

  static String encodeMap(Map<String, DirAnnotation> map) {
    return jsonEncode({for (final entry in map.entries) entry.key: entry.value.toJson()});
  }

  static Map<String, DirAnnotation> decodeMap(String raw) {
    final result = <String, DirAnnotation>{};
    try {
      final data = jsonDecode(raw);
      if (data is! Map) {
        return {};
      }
      for (final entry in data.entries) {
        try {
          final value = entry.value;
          if (value is Map) {
            result[entry.key as String] = DirAnnotation.fromJson(value.cast<String, dynamic>());
          }
        } catch (_) {
          // Skip a single corrupt entry instead of dropping everything.
        }
      }
      return result;
    } catch (_) {
      return {};
    }
  }

  static String key({required String fingerprint, required String rootId, required String path}) {
    return '$fingerprint:$rootId:$path';
  }
}
