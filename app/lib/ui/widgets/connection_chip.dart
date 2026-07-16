import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../store/connection.dart';
import '../../transport/ws_client.dart';

/// Small AppBar chip showing live WS connection state.
///
/// - `connected`         → hidden (zero chrome on the happy path)
/// - `connecting`        → spinner
/// - `reconnecting`      → orange dot + "Reconnecting"
/// - `closed` / error    → red dot + "Offline" — tap to retry
class ConnectionChip extends ConsumerWidget {
  const ConnectionChip({super.key, this.circular = false});

  /// When true, render as a round icon-only button (label moves to a tooltip)
  /// to match the circular glass-bar buttons. Otherwise a labelled pill.
  final bool circular;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final conn = ref.watch(connectionProvider);
    final cs = Theme.of(context).colorScheme;

    // Fake/demo mode is always shown so the bar signals seeded data.
    if (conn.useFake) {
      return _chip(
        context,
        color: cs.tertiary,
        icon: Icons.science_outlined,
        label: 'Demo',
      );
    }
    // Hide entirely on the happy path so the bar stays clean.
    if (conn.wsState == WsState.connected && conn.lastError == null) {
      return const SizedBox.shrink();
    }

    switch (conn.wsState) {
      case WsState.connecting:
        return _chip(
          context,
          color: cs.primary,
          spinner: true,
          label: 'Connecting',
        );
      case WsState.reconnecting:
        return _chip(
          context,
          color: Colors.orange,
          icon: Icons.sync_problem_outlined,
          label: 'Reconnecting',
          onTap: () => ref.read(connectionControllerProvider.notifier).retry(),
        );
      case WsState.closed:
      case WsState.idle:
        return _chip(
          context,
          color: cs.error,
          icon: Icons.cloud_off_outlined,
          label: 'Offline',
          onTap: () => ref.read(connectionControllerProvider.notifier).retry(),
        );
      case WsState.connected:
        // Connected but lastError is set (e.g. mDNS rediscovery failed
        // earlier). Show a soft warning until the user dismisses by tapping.
        return _chip(
          context,
          color: Colors.orange,
          icon: Icons.warning_amber_outlined,
          label: 'Issue',
          onTap: () => _showError(context, conn.lastError ?? 'Unknown error'),
        );
    }
  }

  Widget _chip(
    BuildContext context, {
    required Color color,
    IconData? icon,
    bool spinner = false,
    required String label,
    VoidCallback? onTap,
  }) {
    if (circular) {
      return _circle(
        color: color,
        icon: icon,
        spinner: spinner,
        label: label,
        onTap: onTap,
      );
    }

    final child = Padding(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (spinner)
            SizedBox(
              width: 12,
              height: 12,
              child: CircularProgressIndicator(strokeWidth: 2, color: color),
            )
          else
            Icon(icon, size: 14, color: color),
          const SizedBox(width: 6),
          Text(
            label,
            style: TextStyle(
              fontSize: 12,
              color: color,
              fontWeight: FontWeight.w500,
            ),
          ),
        ],
      ),
    );
    return Center(
      child: Padding(
        padding: const EdgeInsets.only(right: 4),
        child: Material(
          color: color.withValues(alpha: 0.12),
          borderRadius: BorderRadius.circular(16),
          child: onTap == null
              ? child
              : InkWell(
                  borderRadius: BorderRadius.circular(16),
                  onTap: onTap,
                  child: child,
                ),
        ),
      ),
    );
  }

  /// Round icon-only variant for the glass bar; label becomes a tooltip.
  Widget _circle({
    required Color color,
    IconData? icon,
    bool spinner = false,
    required String label,
    VoidCallback? onTap,
  }) {
    final content = spinner
        ? SizedBox(
            width: 18,
            height: 18,
            child: CircularProgressIndicator(strokeWidth: 2, color: color),
          )
        : Icon(icon, size: 20, color: color);
    return Tooltip(
      message: label,
      child: Material(
        color: color.withValues(alpha: 0.18),
        shape: const CircleBorder(),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          child: SizedBox(width: 40, height: 40, child: Center(child: content)),
        ),
      ),
    );
  }

  void _showError(BuildContext context, String msg) {
    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Connection issue'),
        content: Text(msg),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('OK'),
          ),
        ],
      ),
    );
  }
}
