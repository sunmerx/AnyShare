import 'package:convert/convert.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:localsend_app/util/sas.dart';

void main() {
  test('X25519 shared secret agrees between both parties (RFC 7748 vector)', () async {
    // RFC 7748 section 5.2 test vector
    final aliceSeed = hex.decode('77076d0a7318a57d3c16c17251b26645df4c2f87ebc0992ab177fba51db92c2a');
    final bobPublic = hex.decode('de9edb7d7b7dc1b4d35b61c2ece435373f8343c85b78674dadfc7e146f882b4f');
    final aliceShared = hex.decode('4a5d9d5ba4ce2de1728e3bf480350f25e07e21c947d19e3376f09b3c1e161742');

    final keyPair = await SasCrypto.loadSeedKeyPair(aliceSeed);
    final secret = await SasCrypto.deriveSharedSecret(keyPair: keyPair, peerPublicKey: bobPublic);
    expect(secret, aliceShared);
  });

  test('both peers derive the same 6-digit code regardless of argument order', () async {
    final keyPairA = await SasCrypto.generateKeyPair();
    final keyPairB = await SasCrypto.generateKeyPair();
    final pubA = (await keyPairA.extractPublicKey()).bytes;
    final pubB = (await keyPairB.extractPublicKey()).bytes;

    final secretA = await SasCrypto.deriveSharedSecret(keyPair: keyPairA, peerPublicKey: pubB);
    final secretB = await SasCrypto.deriveSharedSecret(keyPair: keyPairB, peerPublicKey: pubA);
    expect(secretA, secretB);

    const sessionId = '0d7e1f3a-9c4b-4a2e-8f6d-1b2c3d4e5f60';
    final codeA = await SasCrypto.deriveCode(
      sharedSecret: secretA,
      sessionId: sessionId,
      fingerprintA: 'aaaa1111',
      fingerprintB: 'bbbb2222',
    );
    final codeB = await SasCrypto.deriveCode(
      sharedSecret: secretB,
      sessionId: sessionId,
      fingerprintA: 'bbbb2222', // reversed order must yield the same code
      fingerprintB: 'aaaa1111',
    );
    expect(codeA, codeB);
    expect(codeA, matches(RegExp(r'^\d{6}$')));
  });

  test('different session or fingerprints yield different codes', () async {
    final keyPairA = await SasCrypto.generateKeyPair();
    final keyPairB = await SasCrypto.generateKeyPair();
    final pubB = await keyPairB.extractPublicKey();
    final secret = await SasCrypto.deriveSharedSecret(keyPair: keyPairA, peerPublicKey: pubB.bytes);

    final code1 = await SasCrypto.deriveCode(sharedSecret: secret, sessionId: 's1', fingerprintA: 'a', fingerprintB: 'b');
    final code2 = await SasCrypto.deriveCode(sharedSecret: secret, sessionId: 's2', fingerprintA: 'a', fingerprintB: 'b');
    final code3 = await SasCrypto.deriveCode(sharedSecret: secret, sessionId: 's1', fingerprintA: 'a', fingerprintB: 'c');
    expect(code1, isNot(code2));
    expect(code1, isNot(code3));
  });
}
