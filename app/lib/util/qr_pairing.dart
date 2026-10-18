import 'dart:convert';

/// AnyShare modification (2026-10-18): QR pairing payload (F-PAIR-08/13).
///
/// The displayer shows a QR containing its address, extension port,
/// fingerprint, owner identity and a one-time token; the scanner parses it,
/// optionally joins the owner and runs the regular SAS pairing flow.
class QrPairingPayload {
  final String host;
  final int extPort;
  final String fingerprint;
  final String alias;
  final String ownerId;
  final String ownerName;
  final String token;

  const QrPairingPayload({
    required this.host,
    required this.extPort,
    required this.fingerprint,
    required this.alias,
    required this.ownerId,
    required this.ownerName,
    required this.token,
  });
}

const int kQrPairingVersion = 1;

String encodeQrPairing(QrPairingPayload payload) {
  return jsonEncode({
    'v': kQrPairingVersion,
    'host': payload.host,
    'port': payload.extPort,
    'fp': payload.fingerprint,
    'alias': payload.alias,
    'ownerId': payload.ownerId,
    'ownerName': payload.ownerName,
    'token': payload.token,
  });
}

/// Returns null when [raw] is not a valid AnyShare pairing payload.
QrPairingPayload? decodeQrPairing(String raw) {
  try {
    final data = jsonDecode(raw);
    if (data is! Map) {
      return null;
    }
    if (data['v'] != kQrPairingVersion) {
      return null;
    }
    final host = data['host'];
    final port = data['port'];
    final token = data['token'];
    if (host is! String || host.isEmpty || port is! int || port <= 0 || port > 65535 || token is! String || token.isEmpty) {
      return null;
    }
    // Optional fields are type-checked: a crafted payload must never throw.
    String str(dynamic value, [String fallback = '']) => value is String ? value : fallback;
    return QrPairingPayload(
      host: host,
      extPort: port,
      fingerprint: str(data['fp']),
      alias: str(data['alias'], '???'),
      ownerId: str(data['ownerId']),
      ownerName: str(data['ownerName']),
      token: token,
    );
  } on FormatException {
    return null;
  }
}
