import 'package:dart_mappable/dart_mappable.dart';
import 'package:flutter/widgets.dart';
import 'package:localsend_app/util/system_date_time_formatter.dart';
import 'package:localsend_isolates/model/file_type.dart';

part 'receive_history_entry.mapper.dart';

@MappableClass()
class ReceiveHistoryEntry with ReceiveHistoryEntryMappable {
  final String id;

  /// The name of the file.
  /// If [isMessage] is true, this is the message content.
  final String fileName;

  final FileType fileType;
  final String? path;
  final bool savedToGallery;

  @MappableField(hook: IsMessageHook())
  final bool isMessage;

  final int fileSize;
  final String senderAlias;
  final DateTime timestamp;

  /// AnyShare modification (2026-10-12): mTLS certificate fingerprint of the
  /// sender; the per-device receive quota is summed over history entries with
  /// a matching fingerprint. Null in entries persisted before this change
  /// (they are excluded from quota sums).
  final String? senderFingerprint;

  const ReceiveHistoryEntry({
    required this.id,
    required this.fileName,
    required this.fileType,
    required this.path,
    required this.savedToGallery,
    required this.isMessage,
    required this.fileSize,
    required this.senderAlias,
    required this.timestamp,
    this.senderFingerprint,
  });

  /// Format string using the system date and time format.
  /// Because the raw timestamp is saved in UTC, we need to transform it to local time zone first.
  String timestampString(BuildContext context) {
    return SystemDateTimeFormatter.dateTime(context, timestamp.toLocal());
  }

  static const fromJson = ReceiveHistoryEntryMapper.fromJson;
}

class IsMessageHook extends MappingHook {
  const IsMessageHook();

  @override
  Object? beforeDecode(Object? value) {
    return value == true;
  }
}
