import 'dart:convert';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

/// AnyShare modification (2026-10-12): SAS (short authentication string)
/// derivation for pairing — docs/扩展协议设计.md §2, DDD 4.4.1.
///
/// Both peers exchange ephemeral X25519 public keys, then derive the same
/// 6-digit code from the shared secret bound to the transcript
/// (`session || fingerprintA || fingerprintB`, sorted for symmetry).
/// An active MITM produces different codes on both screens; the users see
/// the mismatch and abort. This is why the pairing server can run over
/// plain HTTP on the LAN (TLS deferred, design amendment 2026-10-12).
class SasCrypto {
  const SasCrypto._();

  static const String infoPrefix = 'anyshare-sas-v1';

  static final X25519 _x25519 = X25519();
  static final Hkdf _hkdf = Hkdf(hmac: Hmac.sha256(), outputLength: 32);

  /// Generates a fresh ephemeral X25519 key pair.
  static Future<SimpleKeyPair> generateKeyPair() {
    return _x25519.newKeyPair();
  }

  /// Deterministic key pair from a 32-byte seed (test vectors).
  static Future<SimpleKeyPair> loadSeedKeyPair(List<int> seed) {
    return _x25519.newKeyPairFromSeed(seed);
  }

  /// Derives the shared secret with the peer's ephemeral public key.
  static Future<Uint8List> deriveSharedSecret({
    required SimpleKeyPair keyPair,
    required List<int> peerPublicKey,
  }) async {
    final SecretKey secret = await _x25519.sharedSecretKey(
      keyPair: keyPair,
      remotePublicKey: SimplePublicKey(peerPublicKey, type: KeyPairType.x25519),
    );
    final List<int> bytes = await secret.extractBytes();
    return Uint8List.fromList(bytes);
  }

  /// Derives the 6-digit SAS code from the shared secret and transcript.
  /// [fingerprintA]/[fingerprintB] are sorted internally, so both peers can
  /// pass the pair in their own order.
  static Future<String> deriveCode({
    required List<int> sharedSecret,
    required String sessionId,
    required String fingerprintA,
    required String fingerprintB,
  }) async {
    final List<String> fingerprints = [fingerprintA, fingerprintB]..sort();
    final List<int> transcript = [
      ...sessionId.codeUnits,
      ...fingerprints[0].codeUnits,
      ...fingerprints[1].codeUnits,
    ];
    final SecretKeyData ikm = SecretKeyData(sharedSecret);
    final SecretKey okm = await _hkdf.deriveKey(
      secretKey: ikm,
      nonce: transcript, // salt (package:cryptography naming)
      info: utf8.encode(infoPrefix),
    );
    final List<int> okmBytes = await okm.extractBytes();
    // Big-endian unsigned integer of the 32-byte output, modulo 10^6.
    BigInt value = BigInt.zero;
    for (final int b in okmBytes) {
      value = (value << 8) | BigInt.from(b);
    }
    final BigInt code = value % BigInt.from(1000000);
    return code.toString().padLeft(6, '0');
  }
}
