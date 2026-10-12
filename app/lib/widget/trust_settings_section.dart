import 'package:collection/collection.dart';
import 'package:flutter/material.dart';
import 'package:localsend_app/gen/strings.g.dart';
import 'package:localsend_app/model/persistence/favorite_device.dart';
import 'package:localsend_app/provider/favorites_provider.dart';
import 'package:localsend_app/provider/trust_provider.dart';
import 'package:refena_flutter/refena_flutter.dart';
import 'package:routerino/routerino.dart';

/// AnyShare modification (2026-10-12): trust level + limits editor for a
/// paired device (PRD F-PAIR-10~12, docs/扩展协议设计.md §3.3).
class TrustSettingsSection extends StatefulWidget {
  final FavoriteDevice entry;

  const TrustSettingsSection({required this.entry, super.key});

  @override
  State<TrustSettingsSection> createState() => _TrustSettingsSectionState();
}

class _TrustSettingsSectionState extends State<TrustSettingsSection> with Refena {
  Future<void> _update(FavoriteDevice updated) async {
    await ref.redux(favoritesProvider).dispatchAsync(UpdateFavoriteAction(updated));
  }

  @override
  Widget build(BuildContext context) {
    final FavoriteDevice entry = ref.watch(favoritesProvider).firstWhereOrNull((e) => e.id == widget.entry.id) ?? widget.entry;
    final t2 = t.deviceDetailsPage.trust;
    final int usage = ref.watch(trustUsageProvider)[entry.fingerprint] ?? 0;
    final bool limited = entry.trustLevel == TrustLevel.limited;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(t2.title, style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: 10),
        SegmentedButton<TrustLevel>(
          segments: [
            ButtonSegment(value: TrustLevel.temp, label: Text(t2.levelTemp), icon: const Icon(Icons.help_outline)),
            ButtonSegment(value: TrustLevel.limited, label: Text(t2.levelLimited), icon: const Icon(Icons.tune)),
            ButtonSegment(value: TrustLevel.full, label: Text(t2.levelFull), icon: const Icon(Icons.verified_user)),
          ],
          selected: {entry.trustLevel},
          showSelectedIcon: false,
          onSelectionChanged: (selection) => _update(entry.copyWith(trustLevel: selection.first)),
        ),
        const SizedBox(height: 8),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: Text(t2.blocked),
          subtitle: Text(t2.blockedHint, style: const TextStyle(fontSize: 12)),
          value: entry.blocked,
          onChanged: (value) => _update(entry.copyWith(blocked: value)),
        ),
        if (limited) ...[
          const Divider(),
          ListTile(
            contentPadding: EdgeInsets.zero,
            title: Text(t2.maxFileSize),
            subtitle: Text(entry.maxFileSize > 0 ? _formatBytes(entry.maxFileSize) : t2.maxFileSizeUnlimited),
            trailing: const Icon(Icons.edit),
            onTap: () async {
              final int? result = await _promptSize(context, title: t2.maxFileSize, current: entry.maxFileSize);
              if (result != null) {
                await _update(entry.copyWith(maxFileSize: result));
              }
            },
          ),
          ListTile(
            contentPadding: EdgeInsets.zero,
            title: Text(t2.quota),
            subtitle: Text(_quotaLabel(entry)),
            trailing: const Icon(Icons.edit),
            onTap: () async {
              final QuotaSpec? result = await _promptQuota(context, entry);
              if (result != null) {
                await _update(entry.copyWith(quotaMode: result.mode, quotaValue: result.value));
              }
            },
          ),
        ],
        if (limited || entry.quotaMode != QuotaMode.none || usage > 0) ...[
          const SizedBox(height: 4),
          ListTile(
            contentPadding: EdgeInsets.zero,
            leading: const Icon(Icons.data_usage),
            title: Text(t2.usage),
            subtitle: Text(t2.quotaUsed(used: _formatBytes(usage))),
            trailing: TextButton(
              onPressed: usage == 0
                  ? null
                  : () async {
                      final bool? confirmed = await showDialog<bool>(
                        context: context,
                        builder: (context) => AlertDialog(
                          content: Text(t2.resetUsageConfirm),
                          actions: [
                            TextButton(onPressed: () => context.pop(false), child: Text(t.general.cancel)),
                            FilledButton(onPressed: () => context.pop(true), child: Text(t.general.confirm)),
                          ],
                        ),
                      );
                      if (confirmed == true) {
                        ref.redux(trustUsageProvider).dispatch(ResetTrustUsageAction(fingerprint: entry.fingerprint));
                      }
                    },
              child: Text(t2.resetUsage),
            ),
          ),
        ],
      ],
    );
  }

  String _quotaLabel(FavoriteDevice entry) {
    final t2 = t.deviceDetailsPage.trust;
    return switch (entry.quotaMode) {
      QuotaMode.none => t2.quotaNone,
      QuotaMode.absolute => '${t2.quotaAbsolute}: ${_formatBytes(entry.quotaValue)}',
      QuotaMode.percent => '${t2.quotaPercent}: ${(entry.quotaValue / 100).toStringAsFixed(1)}%',
    };
  }

  /// Prompts for a byte size (0 = unlimited). Returns null when cancelled.
  Future<int?> _promptSize(BuildContext context, {required String title, required int current}) async {
    final controller = TextEditingController(text: current > 0 ? (current ~/ (1 << 20)).toString() : '');
    final result = await showDialog<int>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(title),
        content: TextField(
          controller: controller,
          keyboardType: TextInputType.number,
          decoration: InputDecoration(hintText: t.deviceDetailsPage.trust.maxFileSizeUnlimited, suffixText: 'MB'),
        ),
        actions: [
          TextButton(onPressed: () => context.pop(), child: Text(t.general.cancel)),
          FilledButton(
            onPressed: () {
              final text = controller.text.trim();
              context.pop(text.isEmpty ? 0 : (int.tryParse(text) ?? 0) * (1 << 20));
            },
            child: Text(t.general.confirm),
          ),
        ],
      ),
    );
    controller.dispose();
    return result;
  }

  /// Prompts for quota mode + value. Returns null when cancelled.
  Future<QuotaSpec?> _promptQuota(BuildContext context, FavoriteDevice entry) async {
    final controller = TextEditingController(
      text: switch (entry.quotaMode) {
        QuotaMode.absolute => entry.quotaValue > 0 ? (entry.quotaValue ~/ (1 << 30)).toString() : '',
        QuotaMode.percent => entry.quotaValue > 0 ? (entry.quotaValue / 100).toStringAsFixed(0) : '',
        QuotaMode.none => '',
      },
    );
    QuotaMode mode = entry.quotaMode;

    return showDialog<QuotaSpec>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setState) => AlertDialog(
          title: Text(t.deviceDetailsPage.trust.quota),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              SegmentedButton<QuotaMode>(
                segments: [
                  ButtonSegment(value: QuotaMode.none, label: Text(t.deviceDetailsPage.trust.quotaNone)),
                  ButtonSegment(value: QuotaMode.absolute, label: Text(t.deviceDetailsPage.trust.quotaAbsolute)),
                  ButtonSegment(value: QuotaMode.percent, label: Text(t.deviceDetailsPage.trust.quotaPercent)),
                ],
                selected: {mode},
                showSelectedIcon: false,
                onSelectionChanged: (selection) => setState(() => mode = selection.first),
              ),
              if (mode != QuotaMode.none) ...[
                const SizedBox(height: 12),
                TextField(
                  controller: controller,
                  keyboardType: TextInputType.number,
                  decoration: InputDecoration(
                    hintText: mode == QuotaMode.absolute ? t.deviceDetailsPage.trust.quotaNone : t.deviceDetailsPage.trust.percentHint,
                    suffixText: mode == QuotaMode.absolute ? 'GB' : '%',
                  ),
                ),
              ],
            ],
          ),
          actions: [
            TextButton(onPressed: () => context.pop(), child: Text(t.general.cancel)),
            FilledButton(
              onPressed: () {
                final text = controller.text.trim();
                final int value = switch (mode) {
                  QuotaMode.none => 0,
                  QuotaMode.absolute => (int.tryParse(text) ?? 0) * (1 << 30),
                  QuotaMode.percent => (int.tryParse(text) ?? 0) * 100,
                };
                context.pop(QuotaSpec(mode: mode, value: value));
              },
              child: Text(t.general.confirm),
            ),
          ],
        ),
      ),
    ).then((value) {
      controller.dispose();
      return value;
    });
  }
}

class QuotaSpec {
  final QuotaMode mode;
  final int value;

  const QuotaSpec({required this.mode, required this.value});
}

String _formatBytes(int bytes) {
  if (bytes <= 0) {
    return '0 B';
  }
  const units = ['B', 'KB', 'MB', 'GB', 'TB'];
  int index = 0;
  double value = bytes.toDouble();
  while (value >= 1024 && index < units.length - 1) {
    value /= 1024;
    index++;
  }
  return '${value.toStringAsFixed(value >= 100 || index == 0 ? 0 : 1)} ${units[index]}';
}
