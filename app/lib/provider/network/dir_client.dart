import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

/// AnyShare modification (2026-10-18): client-side directory API for the
/// 53318 `/dir/*` endpoints (E3-3). One instance per browsing device.

class DirClientException implements Exception {
  /// Server error code (unknown / ip_mismatch / blocked / temp_not_allowed /
  /// read_only / not_found / conflict / invalid_path / too_large /
  /// rate_limited / bad_request / internal) or a transport-level code
  /// (unreachable / protocol / source_error).
  final String code;
  final int? status;

  const DirClientException(this.code, [this.status]);

  @override
  String toString() => 'DirClientException($code${status == null ? '' : ', status: $status'})';
}

class DirRoot {
  final String id;
  final String name;
  final bool writable;

  const DirRoot({required this.id, required this.name, required this.writable});
}

class DirEntry {
  final String name;
  final bool isDir;
  final bool isLink;
  final int? size;
  final int? modified;

  const DirEntry({required this.name, required this.isDir, required this.isLink, this.size, this.modified});
}

class DirListing {
  final List<DirEntry> entries;
  final bool writable;
  final bool truncated;

  const DirListing({required this.entries, required this.writable, required this.truncated});
}

class DirClient {
  final String host;
  final int extPort;
  final String fingerprint;
  final Duration timeout;

  const DirClient({
    required this.host,
    this.extPort = 53318,
    required this.fingerprint,
    this.timeout = const Duration(seconds: 10),
  });

  String get _hostPart => host.contains(':') ? '[${host.replaceAll('%', '%25')}]' : host;

  Uri _uri(String endpoint, [Map<String, String>? query]) {
    return Uri.parse('http://$_hostPart:$extPort/api/anyshare/v1/dir/$endpoint').replace(queryParameters: query);
  }

  Future<HttpClient> _open() async => HttpClient()..connectionTimeout = timeout;

  Never _throwFromBody(int status, List<int> bytes) {
    try {
      final data = bytes.isEmpty ? null : (const Utf8Decoder().convert(bytes));
      final map = data == null ? null : (jsonDecode(data) as Map);
      final code = map?['error'] as String? ?? 'internal';
      throw DirClientException(code, status);
    } on DirClientException {
      rethrow;
    } catch (_) {
      throw DirClientException('internal', status);
    }
  }

  /// Decodes a JSON object body or maps a malformed payload to `protocol`.
  Map<String, dynamic> _decodeObject(List<int> bytes) {
    try {
      final data = jsonDecode(const Utf8Decoder().convert(bytes));
      if (data is! Map<String, dynamic>) {
        throw const FormatException('not an object');
      }
      return data;
    } catch (_) {
      throw const DirClientException('protocol');
    }
  }

  Future<Map<String, dynamic>> _postJson(String endpoint, Map<String, dynamic> body) async {
    final client = await _open();
    try {
      final request = await client.postUrl(_uri(endpoint));
      request.headers.contentType = ContentType.json;
      request.write(jsonEncode({...body, 'fingerprint': fingerprint}));
      final response = await request.close().timeout(timeout);
      final bytes = <int>[];
      await for (final chunk in response) {
        bytes.addAll(chunk);
      }
      if (response.statusCode != 200) {
        _throwFromBody(response.statusCode, bytes);
      }
      return _decodeObject(bytes);
    } on DirClientException {
      rethrow;
    } catch (_) {
      throw const DirClientException('unreachable');
    } finally {
      client.close(force: true);
    }
  }

  Future<List<DirRoot>> roots() async {
    final data = await _postJson('roots', {});
    try {
      return [
        for (final root in (data['roots'] as List? ?? []))
          DirRoot(
            id: root['id'] as String,
            name: root['name'] as String? ?? '',
            writable: root['writable'] == true,
          ),
      ];
    } catch (_) {
      throw const DirClientException('protocol');
    }
  }

  Future<DirListing> list({required String root, required String path}) async {
    final data = await _postJson('list', {'root': root, 'path': path});
    try {
      return DirListing(
        entries: [
          for (final entry in (data['entries'] as List? ?? []))
            DirEntry(
              name: entry['name'] as String,
              isDir: entry['isDir'] == true,
              isLink: entry['isLink'] == true,
              size: (entry['size'] as num?)?.toInt(),
              modified: (entry['modified'] as num?)?.toInt(),
            ),
        ],
        writable: data['writable'] == true,
        truncated: data['truncated'] == true,
      );
    } catch (_) {
      throw const DirClientException('protocol');
    }
  }

  /// Downloads [path] into [target]. The transfer is written to a `.part`
  /// sibling first and atomically renamed on success; on any failure the
  /// partial file is removed and [target] is left untouched.
  Future<void> downloadToFile({required String root, required String path, required File target}) async {
    final part = File('${target.path}.part');
    final client = await _open();
    try {
      final request = await client.postUrl(_uri('download', {'root': root, 'path': path, 'fingerprint': fingerprint}));
      final response = await request.close().timeout(timeout);
      if (response.statusCode != 200) {
        final bytes = <int>[];
        await for (final chunk in response) {
          bytes.addAll(chunk);
        }
        _throwFromBody(response.statusCode, bytes);
      }
      final sink = part.openWrite();
      try {
        await sink.addStream(response);
      } finally {
        try {
          await sink.close();
        } catch (_) {
          // Reported through the outer catch; the sink must not mask it.
        }
      }
      await part.rename(target.path);
    } on DirClientException {
      _cleanupPart(part);
      rethrow;
    } catch (_) {
      _cleanupPart(part);
      throw const DirClientException('unreachable');
    } finally {
      client.close(force: true);
    }
  }

  void _cleanupPart(File part) {
    try {
      if (part.existsSync()) {
        part.deleteSync();
      }
    } catch (_) {}
  }

  Future<Uint8List> downloadBytes({required String root, required String path}) async {
    final client = await _open();
    try {
      final request = await client.postUrl(_uri('download', {'root': root, 'path': path, 'fingerprint': fingerprint}));
      final response = await request.close().timeout(timeout);
      final bytes = <int>[];
      await for (final chunk in response) {
        bytes.addAll(chunk);
      }
      if (response.statusCode != 200) {
        _throwFromBody(response.statusCode, bytes);
      }
      return Uint8List.fromList(bytes);
    } on DirClientException {
      rethrow;
    } catch (_) {
      throw const DirClientException('unreachable');
    } finally {
      client.close(force: true);
    }
  }

  /// Uploads [source] as [name] into [path]. Returns the final name on the
  /// host (may differ when the rename conflict policy applied). The header
  /// timeout of [timeout] applies to the connection; [uploadTimeout] bounds
  /// the whole request because the server only responds after the body has
  /// been fully received and committed.
  Future<String> uploadFile({
    required String root,
    required String path,
    required File source,
    required String name,
    String onConflict = 'rename',
    Duration? uploadTimeout,
  }) async {
    final client = await _open();
    try {
      final int length;
      try {
        length = await source.length();
      } catch (_) {
        throw const DirClientException('source_error');
      }
      final request = await client.postUrl(
        _uri('upload', {
          'root': root,
          'fingerprint': fingerprint,
          'path': path,
          'name': name,
          'onConflict': onConflict,
          'size': '$length',
        }),
      );
      request.contentLength = length;
      await request.addStream(source.openRead());
      final response = await request.close().timeout(uploadTimeout ?? const Duration(minutes: 30));
      final bytes = <int>[];
      await for (final chunk in response) {
        bytes.addAll(chunk);
      }
      if (response.statusCode != 200) {
        _throwFromBody(response.statusCode, bytes);
      }
      final data = _decodeObject(bytes);
      final finalName = data['finalName'];
      return finalName is String ? finalName : name;
    } on DirClientException {
      rethrow;
    } catch (_) {
      throw const DirClientException('unreachable');
    } finally {
      client.close(force: true);
    }
  }

  Future<void> mkdir({required String root, required String path, required String name}) {
    return _postJson('mkdir', {'root': root, 'path': path, 'name': name});
  }

  Future<String> rename({required String root, required String path, required String newName}) async {
    final data = await _postJson('rename', {'root': root, 'path': path, 'newName': newName});
    final finalName = data['finalName'];
    return finalName is String ? finalName : newName;
  }

  Future<void> delete({required String root, required String path, bool trash = true}) {
    return _postJson('delete', {'root': root, 'path': path, 'trash': trash});
  }
}
