import 'dart:convert';

/// AnyShare modification (2026-10-18): E-3 host-side shared directory config
/// (F-DIR-01). Persisted as JSON strings under `ls_shared_dirs`.
class SharedDirConfig {
  /// Stable identifier used in `/dir/*` requests.
  final String id;

  /// Absolute path on the host.
  final String path;

  /// Display name (shown in the browser's device tree).
  final String name;

  /// Directory-level writability (F-DIR-08). Effective write also requires
  /// the requester to be same-owner or hold a per-device write grant.
  final bool writable;

  const SharedDirConfig({
    required this.id,
    required this.path,
    required this.name,
    this.writable = false,
  });

  Map<String, dynamic> toJson() => {
    'id': id,
    'path': path,
    'name': name,
    'writable': writable,
  };

  factory SharedDirConfig.fromJson(Map<String, dynamic> json) {
    return SharedDirConfig(
      id: json['id'] as String,
      path: json['path'] as String,
      name: json['name'] as String? ?? '',
      writable: json['writable'] == true,
    );
  }

  static SharedDirConfig decode(String raw) => SharedDirConfig.fromJson(jsonDecode(raw) as Map<String, dynamic>);

  SharedDirConfig copyWith({String? name, bool? writable}) {
    return SharedDirConfig(
      id: id,
      path: path,
      name: name ?? this.name,
      writable: writable ?? this.writable,
    );
  }
}
