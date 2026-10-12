import 'package:localsend_app/provider/persistence_provider.dart';
import 'package:refena_flutter/refena_flutter.dart';
import 'package:uuid/uuid.dart';

/// AnyShare modification (2026-10-12): the local owner identity.
/// The id is a random UUID generated on first access and never broadcast in
/// discovery (LAN privacy); it is exchanged inside pairing only and used for
/// the same-owner trust rule (PRD F-PAIR-09).
final ownerProvider = ReduxProvider<OwnerService, OwnerIdentity>((ref) {
  return OwnerService(ref.read(persistenceProvider));
});

class OwnerIdentity {
  final String id;
  final String name;

  const OwnerIdentity({required this.id, required this.name});
}

class OwnerService extends ReduxNotifier<OwnerIdentity> {
  final PersistenceService _persistence;

  OwnerService(this._persistence);

  @override
  OwnerIdentity init() {
    String? id = _persistence.getOwnerId();
    if (id == null || id.isEmpty) {
      id = const Uuid().v4();
      // ignore: discarded_futures
      _persistence.setOwnerId(id);
    }
    return OwnerIdentity(id: id, name: _persistence.getOwnerName());
  }
}

/// Renames the local owner (settings).
class SetOwnerNameAction extends ReduxAction<OwnerService, OwnerIdentity> {
  final String name;

  SetOwnerNameAction(this.name);

  @override
  OwnerIdentity reduce() {
    final updated = OwnerIdentity(id: state.id, name: name);
    // ignore: discarded_futures
    notifier._persistence.setOwnerName(name);
    return updated;
  }
}
