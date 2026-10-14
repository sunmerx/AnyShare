import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:cryptography/cryptography.dart';

import 'package:localsend_app/gen/strings.g.dart';
import 'package:localsend_app/model/persistence/favorite_device.dart';
import 'package:localsend_app/provider/favorites_provider.dart';
import 'package:localsend_app/provider/network/server/server_provider.dart';
import 'package:localsend_app/provider/owner_provider.dart';
import 'package:localsend_app/provider/security_provider.dart';
import 'package:localsend_app/util/sas.dart';
import 'package:refena_flutter/refena_flutter.dart';

/// AnyShare modification (2026-10-12): pairing initiator (docs/扩展协议设计.md §2).
final _timeout = Duration(seconds: 3);

class PeerCapabilities {
  final String fingerprint;
  final String alias;
  final String ownerName;

  const PeerCapabilities({required this.fingerprint, required this.alias, required this.ownerName});
}

class PeerTrustPolicy {
  final bool known;
  final bool blocked;
  final String trustLevel; // temp | limited | full
  final int maxFileSize; // 0 = unlimited
  final String quotaMode; // none | absolute | percent
  final int quotaValue;

  const PeerTrustPolicy({
    required this.known,
    required this.blocked,
    required this.trustLevel,
    required this.maxFileSize,
    required this.quotaMode,
    required this.quotaValue,
  });

  bool get hasLimits => trustLevel == 'limited' || maxFileSize > 0 || quotaMode != 'none';
}

extension PeerTrustPolicyParsing on PeerTrustPolicy {
  static PeerTrustPolicy fromMap(Map data) {
    return PeerTrustPolicy(
      known: data['known'] == true,
      blocked: data['blocked'] == true,
      trustLevel: data['trustLevel'] as String? ?? 'temp',
      maxFileSize: (data['maxFileSize'] as num?)?.toInt() ?? 0,
      quotaMode: data['quotaMode'] as String? ?? 'none',
      quotaValue: (data['quotaValue'] as num?)?.toInt() ?? 0,
    );
  }
}

class PairingException implements Exception {
  final PairingError error;
  final String? detail;

  const PairingException(this.error, [this.detail]);

  @override
  String toString() => 'PairingException(${error.name}: $detail)';
}

enum PairingError { notAnyShare, unreachable, busy, rejected, protocol }

class PairingSession {
  final String sessionId;
  final String code; // SAS shown to the local user
  final String peerAlias;
  final String peerFingerprint;
  final SimpleKeyPair ephKeyPair;
  final List<int> peerEphPub;

  const PairingSession({
    required this.sessionId,
    required this.code,
    required this.peerAlias,
    required this.peerFingerprint,
    required this.ephKeyPair,
    required this.peerEphPub,
  });
}

class PairingResult {
  final FavoriteDevice device; // to be added locally (trust level chosen by user)
  final String peerOwnerId;
  final String peerOwnerName;

  const PairingResult({required this.device, required this.peerOwnerId, required this.peerOwnerName});
}

/// HTTP helpers for the extension protocol. Plain HTTP by design (SAS binds
/// the key exchange; see sas.dart docs).
extension PairingClient on Ref {
  Uri _extUri(String host, int port, String path) {
    // IPv6 (incl. link-local with %scope) must be bracketed; '%' escapes to %25.
    final String hostPart = host.contains(':') ? '[${host.replaceAll('%', '%25')}]' : host;
    return Uri.parse('http://$hostPart:$port/api/anyshare/v1/$path');
  }

  Future<dynamic> _post(String host, int port, String path, Map<String, dynamic> body, {Duration? timeout}) async {
    final Duration wait = timeout ?? _timeout;
    try {
      final client = HttpClient()..connectionTimeout = _timeout;
      final request = await client.postUrl(_extUri(host, port, path));
      request.headers.contentType = ContentType.json;
      request.write(jsonEncode(body));
      final response = await request.close().timeout(wait);
      final text = await response.transform(utf8.decoder).join().timeout(wait);
      if (response.statusCode != 200) {
        throw const PairingException(PairingError.rejected);
      }
      return jsonDecode(text);
    } on SocketException catch (e) {
      throw PairingException(PairingError.unreachable, e.message);
    } on TimeoutException {
      throw const PairingException(PairingError.unreachable);
    } on FormatException catch (e) {
      throw PairingException(PairingError.protocol, e.message);
    }
  }

  /// Asks the receiver how it would treat a transfer from us
  /// (auto-accept / limited / blocked). Returns null when the peer is not
  /// an AnyShare app or is unreachable — senders stay silent then.
  Future<PeerTrustPolicy?> queryTrustPolicy({
    required String host,
    required int extPort,
    required String myFingerprint,
  }) async {
    try {
      final client = HttpClient()..connectionTimeout = _timeout;
      final request = await client.postUrl(_extUri(host, extPort, 'trust/query'));
      request.headers.contentType = ContentType.json;
      request.write(jsonEncode({'fingerprint': myFingerprint}));
      final response = await request.close().timeout(const Duration(seconds: 3));
      if (response.statusCode != 200) {
        return null;
      }
      final data = jsonDecode(await response.transform(utf8.decoder).join().timeout(const Duration(seconds: 3))) as Map;
      if (data['known'] != true) {
        return null;
      }
      return PeerTrustPolicyParsing.fromMap(data);
    } on Exception {
      return null;
    }
  }

  /// Probes a device for AnyShare extension capabilities.
  Future<PeerCapabilities?> probeCapabilities(String host, int port) async {
    try {
      final client = HttpClient()..connectionTimeout = _timeout;
      final request = await client.getUrl(_extUri(host, port, 'capabilities'));
      final response = await request.close().timeout(_timeout);
      if (response.statusCode != 200) {
        return null;
      }
      final data = jsonDecode(await response.transform(utf8.decoder).join().timeout(_timeout)) as Map;
      if (data['ext'] != 1 || data['sas'] != true) {
        return null;
      }
      return PeerCapabilities(
        fingerprint: data['fingerprint'] as String? ?? '',
        alias: data['alias'] as String? ?? '',
        ownerName: data['ownerName'] as String? ?? '',
      );
    } on Exception {
      return null; // not AnyShare (or offline)
    }
  }

  /// Registers a pairing request; returns the session with the SAS code.
  Future<PairingSession> pairRegister({required String host, required int extPort, required String peerFingerprint}) async {
    final keyPair = await SasCrypto.generateKeyPair();
    final localPub = await keyPair.extractPublicKey();
    final server = read(serverProvider);
    final response =
        await _post(host, extPort, 'pair/register', {
              'alias': server?.alias ?? '',
              'fingerprint': read(securityProvider).certificateHash,
              'eph': base64Encode(localPub.bytes),
              'port': server?.port ?? 53317,
              'https': server?.https ?? true,
            })
            as Map;
    if (response['session'] is! String || response['eph'] is! String || response['code'] is! String) {
      throw const PairingException(PairingError.protocol);
    }
    // The transcript MUST use the peer fingerprint from the register
    // response — a stale/empty one yields a different SAS code on both
    // sides (the mismatch is then correctly treated as an attack indicator).
    return PairingSession(
      sessionId: response['session'] as String,
      code: response['code'] as String,
      peerAlias: response['alias'] as String? ?? '???',
      peerFingerprint: (response['fingerprint'] as String?) ?? peerFingerprint,
      ephKeyPair: keyPair,
      peerEphPub: base64Decode(response['eph'] as String),
    );
  }

  /// Confirms the pairing (after the user verified the codes on both screens).
  Future<PairingResult> pairConfirm({required String host, required int extPort, required PairingSession session, required String peerIp}) async {
    final owner = read(ownerProvider);
    final server = read(serverProvider);
    // The server long-polls until the responder accepts the SAS comparison
    // (60s) — allow for it.
    final response =
        await _post(host, extPort, 'pair/confirm', {
              'session': session.sessionId,
              'ownerId': owner.id,
              'ownerName': owner.name,
              'alias': server?.alias ?? '',
            }, timeout: const Duration(seconds: 75))
            as Map;
    if (response['ok'] != true || response['ownerId'] is! String) {
      throw const PairingException(PairingError.rejected);
    }
    return PairingResult(
      device: FavoriteDevice.fromValues(
        fingerprint: response['fingerprint'] as String? ?? session.peerFingerprint,
        ip: peerIp,
        port: 53317, // corrected from the next discovery round (upstream updates favorites automatically)
        alias: response['alias'] as String? ?? session.peerAlias,
      ),
      peerOwnerId: response['ownerId'] as String,
      peerOwnerName: response['ownerName'] as String? ?? '',
    );
  }

  /// Derives the local SAS code for the initiator side (must equal the code
  /// the responder shows).
  Future<String> deriveLocalCode({required PairingSession session}) async {
    final shared = await SasCrypto.deriveSharedSecret(keyPair: session.ephKeyPair, peerPublicKey: session.peerEphPub);
    return SasCrypto.deriveCode(
      sharedSecret: shared,
      sessionId: session.sessionId,
      fingerprintA: read(securityProvider).certificateHash,
      fingerprintB: session.peerFingerprint,
    );
  }
}

/// Completes pairing on the initiator side: persists the peer + owner link.
Future<void> finishPairing(Ref ref, PairingResult result) async {
  final updated = result.device.copyWith(
    ownerId: result.peerOwnerId,
    ownerName: result.peerOwnerName,
    // Product decision (2026-10-14): pairing IS the receiver's confirmation.
    // Paired devices never get per-transfer prompts, even at `temp` — the
    // level only controls whether limits apply (see TrustEvaluator).
  );
  await ref.redux(favoritesProvider).dispatchAsync(AddFavoriteAction(updated));
}

/// i18n helper for pairing errors.
String pairingErrorMessage(PairingError error) {
  return switch (error) {
    PairingError.notAnyShare => t.deviceDetailsPage.pairing.errorNotAnyShare,
    PairingError.unreachable => t.deviceDetailsPage.pairing.errorUnreachable,
    PairingError.busy => t.deviceDetailsPage.pairing.errorBusy,
    PairingError.rejected => t.deviceDetailsPage.pairing.errorRejected,
    PairingError.protocol => t.deviceDetailsPage.pairing.errorProtocol,
  };
}
