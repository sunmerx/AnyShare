import 'package:localsend_app/provider/network/dir_client.dart';
import 'package:localsend_app/provider/network/extension_server_provider.dart' show kExtensionPort;
import 'package:localsend_app/provider/security_provider.dart';
import 'package:localsend_app/util/dir_browse.dart';
import 'package:refena_flutter/refena_flutter.dart';

/// AnyShare modification (2026-10-18): browse sessions for shared directories
/// (E3-3c). One session per browsing device; state lives until the browse
/// page is closed.

class DirBrowseSession {
  final String fingerprint;
  final String host;
  final List<DirRoot> roots;
  final String rootId;
  final String path;
  final List<DirEntry> entries;
  final bool writable;
  final bool truncated;

  /// Monotonic request id of the action that produced this state. Responses
  /// from older in-flight requests are discarded (see the actions below).
  final int requestId;

  /// Null when healthy, otherwise a [DirClientException] code or 'unreachable'.
  final String? error;

  const DirBrowseSession({
    required this.fingerprint,
    required this.host,
    this.roots = const [],
    this.rootId = '',
    this.path = '',
    this.entries = const [],
    this.writable = false,
    this.truncated = false,
    this.requestId = 0,
    this.error,
  });

  static const _unset = Object();

  DirBrowseSession copyWith({
    List<DirRoot>? roots,
    String? rootId,
    String? path,
    List<DirEntry>? entries,
    bool? writable,
    bool? truncated,
    int? requestId,
    Object? error = _unset,
  }) {
    return DirBrowseSession(
      fingerprint: fingerprint,
      host: host,
      roots: roots ?? this.roots,
      rootId: rootId ?? this.rootId,
      path: path ?? this.path,
      entries: entries ?? this.entries,
      writable: writable ?? this.writable,
      truncated: truncated ?? this.truncated,
      requestId: requestId ?? this.requestId,
      error: identical(error, _unset) ? this.error : error as String?,
    );
  }

  DirRoot? get currentRoot {
    for (final root in roots) {
      if (root.id == rootId) {
        return root;
      }
    }
    return null;
  }
}

final dirBrowseProvider = ReduxProvider<DirBrowseService, Map<String, DirBrowseSession>>((ref) {
  return DirBrowseService(ref);
});

/// Control plane port (the extension server). Tests override this to point at
/// a random-port server.
final dirBrowsePortProvider = Provider<int>((ref) => kExtensionPort);

class DirBrowseService extends ReduxNotifier<Map<String, DirBrowseSession>> {
  final Ref ref;

  DirBrowseService(this.ref);

  @override
  Map<String, DirBrowseSession> init() => {};

  int get port => ref.read(dirBrowsePortProvider);

  /// The /dir/* access gate identifies the requester by its self-reported
  /// fingerprint: always present the LOCAL device identity, never the browsed
  /// device's (the host's favorites contain the requester, not itself).
  String get localFingerprint => ref.read(securityProvider).certificateHash;
}

/// Probes the device roots and loads the first root's listing. Errors are
/// stored in the session (never thrown) so the page can render them.
///
/// [requestId] comes from a page-owned monotonic counter: a response is only
/// written when no newer request has already been applied. Refena has no
/// serial queue for async actions, so without this a slow response could
/// overwrite the directory the user just navigated to.
class OpenDirBrowseAction extends AsyncReduxAction<DirBrowseService, Map<String, DirBrowseSession>> {
  final String fingerprint;
  final String host;
  final int requestId;

  OpenDirBrowseAction({required this.fingerprint, required this.host, required this.requestId});

  @override
  Future<Map<String, DirBrowseSession>> reduce() async {
    var session = DirBrowseSession(fingerprint: fingerprint, host: host);
    if (host.isNotEmpty) {
      final client = DirClient(host: host, extPort: notifier.port, fingerprint: notifier.localFingerprint);
      try {
        final roots = await client.roots();
        session = session.copyWith(roots: roots);
        if (roots.isNotEmpty) {
          final root = roots.first;
          final listing = await client.list(root: root.id, path: '');
          session = session.copyWith(
            rootId: root.id,
            path: '',
            entries: sortDirEntries(listing.entries),
            writable: listing.writable,
            truncated: listing.truncated,
          );
        }
      } on DirClientException catch (e) {
        session = session.copyWith(error: e.code);
      }
    } else {
      session = session.copyWith(error: 'unreachable');
    }
    final current = state[fingerprint];
    if (current != null && current.requestId > requestId) {
      return state;
    }
    return {...state, fingerprint: session.copyWith(requestId: requestId)};
  }
}

class LoadDirListingAction extends AsyncReduxAction<DirBrowseService, Map<String, DirBrowseSession>> {
  final String fingerprint;
  final String rootId;
  final String path;
  final int requestId;

  LoadDirListingAction({required this.fingerprint, required this.rootId, required this.path, required this.requestId});

  @override
  Future<Map<String, DirBrowseSession>> reduce() async {
    final current = state[fingerprint];
    if (current == null) {
      return state;
    }
    var session = current.copyWith(rootId: rootId, path: path, error: null);
    final client = DirClient(host: current.host, extPort: notifier.port, fingerprint: notifier.localFingerprint);
    try {
      final listing = await client.list(root: rootId, path: path);
      session = session.copyWith(
        entries: sortDirEntries(listing.entries),
        writable: listing.writable,
        truncated: listing.truncated,
      );
    } on DirClientException catch (e) {
      // The target path may belong to a different root: reset derived flags
      // instead of leaving stale writable/truncated values from the old one.
      session = session.copyWith(entries: const [], writable: false, truncated: false, error: e.code);
    }
    if (state[fingerprint] != null && state[fingerprint]!.requestId > requestId) {
      return state;
    }
    return {...state, fingerprint: session.copyWith(requestId: requestId)};
  }
}

class CloseDirBrowseAction extends ReduxAction<DirBrowseService, Map<String, DirBrowseSession>> {
  final String fingerprint;

  CloseDirBrowseAction({required this.fingerprint});

  @override
  Map<String, DirBrowseSession> reduce() {
    final updated = {...state}..remove(fingerprint);
    return updated;
  }
}
