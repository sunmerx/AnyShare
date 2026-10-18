import 'package:flutter/material.dart';
import 'package:localsend_app/gen/strings.g.dart';
import 'package:localsend_isolates/model/device.dart';

/// Rounded platform icon used as the leading widget of a [DeviceCard].
Widget deviceIcon({DeviceType? deviceType, bool self = false}) {
  final icon = self
      ? Icons.computer
      : switch (deviceType) {
          DeviceType.mobile => Icons.smartphone,
          DeviceType.desktop => Icons.computer,
          DeviceType.headless => Icons.dns,
          DeviceType.server => Icons.dns,
          _ => Icons.devices_other,
        };
  return Builder(
    builder: (context) {
      final scheme = Theme.of(context).colorScheme;
      return Container(
        width: 42,
        height: 42,
        decoration: BoxDecoration(
          color: scheme.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(12),
        ),
        child: Icon(icon, size: 23, color: scheme.primary),
      );
    },
  );
}

/// AnyShare modification (2026-10-18): unified device card for the redesigned
/// home (UI-1). Actions are injected by the caller.
class DeviceCard extends StatelessWidget {
  final Widget leading;
  final String title;
  final String subtitle;

  /// Small chips next to the title (本机 / 我的 / 信任等级).
  final List<Widget> badges;

  /// Online status widget on the right.
  final Widget? status;
  final List<Widget> actions;
  final VoidCallback? onTap;

  /// Multi-send mode: live transfer info of the session targeting this device.
  final String? infoLine;
  final double? progress;

  const DeviceCard({
    required this.leading,
    required this.title,
    required this.subtitle,
    this.badges = const [],
    this.status,
    this.actions = const [],
    this.onTap,
    this.infoLine,
    this.progress,
    super.key,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      margin: EdgeInsets.zero,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(12),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  leading,
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Flexible(
                              child: Text(
                                title,
                                style: theme.textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w600),
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                            ...badges,
                          ],
                        ),
                        const SizedBox(height: 2),
                        Text(
                          subtitle,
                          style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                          overflow: TextOverflow.ellipsis,
                        ),
                        if (infoLine != null || progress != null) ...[
                          const SizedBox(height: 4),
                          if (infoLine != null)
                            Text(
                              infoLine!,
                              style: theme.textTheme.labelSmall?.copyWith(color: theme.colorScheme.primary),
                              overflow: TextOverflow.ellipsis,
                            ),
                          if (progress != null)
                            Padding(
                              padding: const EdgeInsets.only(top: 4),
                              child: ClipRRect(
                                borderRadius: BorderRadius.circular(999),
                                child: LinearProgressIndicator(value: progress, minHeight: 4),
                              ),
                            ),
                        ],
                      ],
                    ),
                  ),
                  if (status != null) ...[
                    const SizedBox(width: 8),
                    status!,
                  ],
                ],
              ),
              if (actions.isNotEmpty) ...[
                const SizedBox(height: 10),
                Wrap(spacing: 8, runSpacing: 8, children: actions),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

/// A pill action button used inside [DeviceCard].
class DeviceActionButton extends StatelessWidget {
  final IconData icon;
  final String label;
  final VoidCallback? onTap;
  final bool primary;

  /// Shown as tooltip when [onTap] is null (disabled).
  final String? disabledTooltip;

  const DeviceActionButton({
    required this.icon,
    required this.label,
    this.onTap,
    this.primary = false,
    this.disabledTooltip,
    super.key,
  });

  @override
  Widget build(BuildContext context) {
    final enabled = onTap != null;
    final button = primary
        ? FilledButton.icon(
            onPressed: onTap,
            icon: Icon(icon, size: 18),
            label: Text(label),
            style: FilledButton.styleFrom(
              visualDensity: VisualDensity.compact,
              padding: const EdgeInsets.symmetric(horizontal: 16),
            ),
          )
        : OutlinedButton.icon(
            onPressed: onTap,
            icon: Icon(icon, size: 18),
            label: Text(label),
            style: OutlinedButton.styleFrom(
              visualDensity: VisualDensity.compact,
              padding: const EdgeInsets.symmetric(horizontal: 16),
            ),
          );
    if (!enabled && disabledTooltip != null) {
      return Tooltip(message: disabledTooltip!, child: button);
    }
    return button;
  }
}

/// Badge chip (本机 / 我的 / 信任等级 / 实验性).
class DeviceBadge extends StatelessWidget {
  final String label;
  final DeviceBadgeKind kind;

  const DeviceBadge(this.label, {this.kind = DeviceBadgeKind.neutral, super.key});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final (bg, fg) = switch (kind) {
      DeviceBadgeKind.self || DeviceBadgeKind.mine => (scheme.secondaryContainer, scheme.onSecondaryContainer),
      DeviceBadgeKind.full => (Colors.green.shade100, Colors.green.shade900),
      DeviceBadgeKind.limited => (Colors.blue.shade100, Colors.blue.shade900),
      DeviceBadgeKind.temp => (Colors.amber.shade100, Colors.amber.shade900),
      DeviceBadgeKind.experimental => (Colors.purple.shade100, Colors.purple.shade900),
      DeviceBadgeKind.neutral => (scheme.surfaceContainerHighest, scheme.onSurfaceVariant),
    };
    return Padding(
      padding: const EdgeInsets.only(left: 6),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
        decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(999)),
        child: Text(label, style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: fg)),
      ),
    );
  }
}

enum DeviceBadgeKind { self, mine, full, limited, temp, experimental, neutral }

/// Online / offline status chip.
class DeviceStatusChip extends StatelessWidget {
  final bool online;

  /// e.g. "2 小时前" when offline (optional).
  final String? lastSeen;

  const DeviceStatusChip({required this.online, this.lastSeen, super.key});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 8,
          height: 8,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: online ? Colors.green.shade600 : scheme.outlineVariant,
          ),
        ),
        const SizedBox(width: 5),
        Text(
          online ? t.ui2.online : (lastSeen ?? t.ui2.offline),
          style: Theme.of(context).textTheme.labelSmall?.copyWith(color: scheme.onSurfaceVariant),
        ),
      ],
    );
  }
}
