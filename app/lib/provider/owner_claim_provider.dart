import 'dart:convert';
import 'dart:io';

import 'package:localsend_app/model/persistence/favorite_device.dart';
import 'package:localsend_app/provider/favorites_provider.dart';
import 'package:localsend_app/provider/network/extension_server_provider.dart';
import 'package:localsend_app/provider/owner_provider.dart';
import 'package:localsend_app/provider/security_provider.dart';
import 'package:logging/logging.dart';
import 'package:refena_flutter/refena_flutter.dart';

final _logger = Logger('OwnerClaim');

/// Asks [entry] to join this device's owner group. The peer shows a local
/// confirmation; on success both sides share this device's owner identity.
///
/// Returns null on success, otherwise a short error code.
Future<String?> claimDeviceOwner(Ref ref, FavoriteDevice entry, String host, {int port = kExtensionPort}) async {
  final owner = ref.read(ownerProvider);
  final fingerprint = ref.read(securityProvider).certificateHash;
  final authority = host.contains(':') ? '[${host.replaceAll('%', '%25')}]' : host;
  final client = HttpClient()..connectionTimeout = const Duration(seconds: 5);
  try {
    final request = await client.postUrl(Uri.parse('http://$authority:$port/api/anyshare/v1/owner/claim'));
    request.headers.contentType = ContentType.json;
    request.write(
      jsonEncode({
        'fingerprint': fingerprint,
        'ownerId': owner.id,
        'ownerName': owner.name,
        'alias': entry.alias,
      }),
    );
    final response = await request.close().timeout(const Duration(seconds: 70));
    final text = await response.transform(utf8.decoder).join();
    final body = text.isEmpty ? null : jsonDecode(text);
    if (response.statusCode != 200 || body is! Map || body['ok'] != true) {
      return body is Map ? (body['error'] as String?) ?? 'failed' : 'failed';
    }
    await ref
        .redux(favoritesProvider)
        .dispatchAsync(
          UpdateFavoriteAction(entry.copyWith(ownerId: owner.id, ownerName: owner.name)),
        );
    return null;
  } catch (e) {
    _logger.fine('owner claim to ${entry.alias} failed: $e');
    return 'offline';
  } finally {
    client.close(force: true);
  }
}
