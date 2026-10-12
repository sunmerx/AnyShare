import 'package:dart_mappable/dart_mappable.dart';
import 'package:flutter/widgets.dart';
import 'package:localsend_app/util/system_date_time_formatter.dart';
import 'package:localsend_isolates/model/file_type.dart';

part 'send_history_entry.mapper.dart';

@MappableClass()
class SendHistoryEntry with SendHistoryEntryMappable {
  final String id; // sessionId + receiver fingerprint + timestamp, unique
  final String fileName;
  final FileType fileType;
  final int fileSize;
  final String receiverAlias;
  final String receiverFingerprint;
  final bool success; // false = finished with errors / declined / canceled
  final int timestamp; // milliseconds since epoch

  const SendHistoryEntry({
    required this.id,
    required this.fileName,
    required this.fileType,
    required this.fileSize,
    required this.receiverAlias,
    required this.receiverFingerprint,
    required this.success,
    required this.timestamp,
  });

  String timestampString(BuildContext context) => SystemDateTimeFormatter.dateTime(context, DateTime.fromMillisecondsSinceEpoch(timestamp));

  static const fromJson = SendHistoryEntryMapper.fromJson;
}
