import 'package:flutter_test/flutter_test.dart';
import 'package:localsend_app/model/persistence/receive_history_entry.dart';
import 'package:localsend_app/model/persistence/send_history_entry.dart';
import 'package:localsend_app/model/state/send/send_session_state.dart';
import 'package:localsend_app/model/state/send/sending_file.dart';
import 'package:localsend_app/model/state/server/receive_session_state.dart';
import 'package:localsend_app/model/state/server/receiving_file.dart';
import 'package:localsend_app/model/state/server/server_state.dart';
import 'package:localsend_app/util/transfer_overview.dart';
import 'package:localsend_isolates/model/device.dart';
import 'package:localsend_isolates/model/dto/file_dto.dart';
import 'package:localsend_isolates/model/file_type.dart';
import 'package:localsend_isolates/model/session_status.dart';

void main() {
  Device dev(String alias) {
    return Device(
      signalingId: null,
      ip: '10.0.0.1',
      version: '2.2',
      port: 53317,
      https: false,
      fingerprint: 'FP-$alias',
      alias: alias,
      deviceModel: 'Model',
      deviceType: DeviceType.desktop,
      download: false,
      channels: const [],
    );
  }

  FileDto file(String id, int size) {
    return FileDto(id: id, fileName: '$id.bin', size: size, fileType: FileType.other, hash: null, preview: null, metadata: null);
  }

  SendingFile sending(String id, {String? token}) {
    return SendingFile(file: file(id, 100), token: token, thumbnail: null, asset: null, path: null, bytes: null, errorMessage: null);
  }

  ReceivingFile receiving(String id, {String? desiredName}) {
    return ReceivingFile(
      file: file(id, 100),
      token: null,
      desiredName: desiredName,
      path: null,
      savedToGallery: false,
      errorMessage: null,
    );
  }

  SendSessionState sendSession({
    required SessionStatus status,
    required Map<String, SendingFile> files,
    int hashedFileCount = 99,
  }) {
    return SendSessionState(
      sessionId: 'S1',
      remoteSessionId: null,
      background: false,
      status: status,
      target: dev('Peer'),
      files: files,
      hashedFileCount: hashedFileCount,
      startTime: null,
      endTime: null,
      sendingTasks: null,
      errorMessage: null,
    );
  }

  ReceiveSessionState receiveSession({required Map<String, ReceivingFile> files}) {
    return ReceiveSessionState(
      sessionId: 'R1',
      status: SessionStatus.sending,
      sender: dev('Sender'),
      senderAlias: 'Sender',
      files: files,
      startTime: null,
      endTime: null,
      destinationDirectory: '/tmp',
      cacheDirectory: '/tmp',
      saveToGallery: false,
      createdDirectories: {},
    );
  }

  ServerState serverWith(ReceiveSessionState? session) {
    return ServerState(alias: 'Me', port: 53317, https: false, session: session, web: null);
  }

  test('outgoing progress aggregates token files and shows hash phase', () {
    final files = {
      'a': sending('a', token: 't'),
      'b': sending('b', token: 't'),
    };
    final views = activeTransfers(
      sendSessions: {'S1': sendSession(status: SessionStatus.sending, files: files)},
      server: null,
      progressOf: (sessionId, fileId) => fileId == 'a' ? 1.0 : 0.0,
    );
    expect(views, hasLength(1));
    expect(views.single.progress, 0.5);
    expect(views.single.fileCount, 2);

    // Checksum phase: hashedFileCount < files.length.
    final hashing = activeTransfers(
      sendSessions: {'S1': sendSession(status: SessionStatus.sending, files: files, hashedFileCount: 1)},
      server: null,
      progressOf: (_, _) => 0,
    );
    expect(hashing.single.progress, 0.5);
  });

  test('recipientBusy sessions are not active', () {
    final views = activeTransfers(
      sendSessions: {
        'S1': sendSession(status: SessionStatus.recipientBusy, files: {'a': sending('a', token: 't')}),
      },
      server: null,
      progressOf: (_, _) => 0,
    );
    expect(views, isEmpty);
  });

  test('incoming progress uses accepted files (desiredName), not tokens', () {
    final files = {
      'a': receiving('a', desiredName: 'a.bin'),
      'b': receiving('b'),
    };
    final views = activeTransfers(
      sendSessions: const {},
      server: serverWith(receiveSession(files: files)),
      progressOf: (sessionId, fileId) => fileId == 'a' ? 1.0 : 0.0,
    );
    expect(views, hasLength(1));
    expect(views.single.outgoing, isFalse);
    expect(views.single.fileCount, 1, reason: 'only the accepted file counts');
    expect(views.single.progress, 1.0, reason: 'accepted file is complete');
  });

  test('merged history is sorted newest first and limited', () {
    final now = DateTime.now().millisecondsSinceEpoch;
    final history = mergedHistory(
      sendHistory: [
        SendHistoryEntry(
          id: 's1',
          fileName: 'old.txt',
          fileType: FileType.text,
          fileSize: 1,
          receiverAlias: 'Peer',
          receiverFingerprint: 'FP',
          success: true,
          timestamp: now - 10000,
        ),
      ],
      receiveHistory: [
        ReceiveHistoryEntry(
          id: 'r1',
          fileName: 'new.txt',
          fileType: FileType.text,
          path: '/tmp/new.txt',
          savedToGallery: false,
          isMessage: false,
          fileSize: 1,
          senderAlias: 'Sender',
          timestamp: DateTime.fromMillisecondsSinceEpoch(now - 1000),
        ),
      ],
      limit: 1,
    );
    expect(history, hasLength(1));
    expect(history.single.fileName, 'new.txt');
    expect(history.single.outgoing, isFalse);
  });
}
