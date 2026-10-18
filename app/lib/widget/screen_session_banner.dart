import 'package:flutter/material.dart';
import 'package:localsend_app/gen/strings.g.dart';
import 'package:localsend_app/provider/screen/screen_provider.dart';
import 'package:refena_flutter/refena_flutter.dart';

/// AnyShare modification (2026-10-18): global screen-session status banner
/// (UI-2/W3, D4). Mounted above the navigator so it is visible on every page.
///
/// Covers: pending incoming offer (fallback when the dialog could not be
/// shown), outgoing waiting state, active sessions and errors. Active and
/// error banners can stack so a mid-session error is never hidden.
class ScreenSessionBanner extends StatelessWidget {
  const ScreenSessionBanner({super.key});

  @override
  Widget build(BuildContext context) {
    final ref = context.ref;
    final state = ref.watch(screenProvider);
    final theme = Theme.of(context);
    final banners = <Widget>[];

    if (state.pendingOffer != null && state.active == null) {
      final pending = state.pendingOffer!;
      banners.add(
        _banner(
          context,
          icon: Icons.screen_share,
          text: t.ui2.screen.requestBody(alias: pending.peerAlias),
          actionLabel: t.ui2.screen.accept,
          onAction: () => ref
              .redux(screenProvider)
              .dispatchAsync(
                AcceptPendingScreenOfferAction(sessionId: pending.sessionId),
              ),
          secondaryLabel: t.ui2.screen.reject,
          onSecondary: () => ref
              .redux(screenProvider)
              .dispatchAsync(
                AbortPendingScreenOfferAction(sessionId: pending.sessionId),
              ),
          background: theme.colorScheme.tertiaryContainer,
          foreground: theme.colorScheme.onTertiaryContainer,
        ),
      );
    }

    if (state.waiting != null) {
      final waiting = state.waiting!;
      banners.add(
        _banner(
          context,
          icon: Icons.hourglass_top,
          text: t.ui2.screen.waiting(alias: waiting.peerAlias),
          actionLabel: t.ui2.cancel,
          onAction: () => ref.redux(screenProvider).dispatchAsync(StopScreenShareAction()),
          background: theme.colorScheme.secondaryContainer,
          foreground: theme.colorScheme.onSecondaryContainer,
        ),
      );
    } else if (state.active != null) {
      final active = state.active!;
      final stats = active.lastStats;
      // The receiver never reports a bitrate; only the sender has Mbps.
      final statsLabel = stats == null
          ? ''
          : active.role == ScreenRole.sender
          ? ' · ${stats.fps.toStringAsFixed(0)} fps · ${stats.mbps.toStringAsFixed(1)} Mbps'
          : ' · ${stats.fps.toStringAsFixed(0)} fps';
      banners.add(
        _banner(
          context,
          icon: active.role == ScreenRole.sender ? Icons.screen_share : Icons.cast_connected,
          text: active.role == ScreenRole.sender
              ? '${t.ui2.screen.sending(alias: active.peerAlias)}$statsLabel'
              : '${t.ui2.screen.receiving(alias: active.peerAlias)}$statsLabel',
          actionLabel: t.ui2.screen.stop,
          onAction: () => ref.redux(screenProvider).dispatchAsync(StopScreenShareAction()),
          background: theme.colorScheme.secondaryContainer,
          foreground: theme.colorScheme.onSecondaryContainer,
        ),
      );
    }

    if (state.lastError != null) {
      banners.add(
        _banner(
          context,
          icon: Icons.error_outline,
          text: state.lastError!,
          actionLabel: t.general.close,
          onAction: () => ref.redux(screenProvider).dispatch(ClearScreenErrorAction()),
          background: theme.colorScheme.errorContainer,
          foreground: theme.colorScheme.onErrorContainer,
        ),
      );
    }

    if (banners.isEmpty) {
      return const SizedBox.shrink();
    }
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        for (final banner in banners)
          Padding(
            padding: const EdgeInsets.fromLTRB(15, 6, 15, 0),
            child: banner,
          ),
      ],
    );
  }

  Widget _banner(
    BuildContext context, {
    required IconData icon,
    required String text,
    required String actionLabel,
    required VoidCallback onAction,
    String? secondaryLabel,
    VoidCallback? onSecondary,
    required Color background,
    required Color foreground,
  }) {
    return Card(
      margin: EdgeInsets.zero,
      color: background,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 4),
        child: Row(
          children: [
            Icon(icon, size: 18, color: foreground),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                text,
                style: Theme.of(context).textTheme.bodySmall?.copyWith(color: foreground),
                overflow: TextOverflow.ellipsis,
              ),
            ),
            if (secondaryLabel != null && onSecondary != null) TextButton(onPressed: onSecondary, child: Text(secondaryLabel)),
            TextButton(onPressed: onAction, child: Text(actionLabel)),
          ],
        ),
      ),
    );
  }
}
