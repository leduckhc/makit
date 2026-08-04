import 'package:flutter/material.dart';
import 'package:phosphoricons_flutter/phosphoricons_flutter.dart';

import '../app/theme.dart';
import '../store/connection.dart';
import '../transport/ws_client.dart';
import '../ui/widgets/menu_item.dart';

/// One paired server in the connect screen's list.
///
/// The list is a *radio group*, not a set of toggles — makit keeps one live
/// socket, so tapping a row moves the connection. The active row states its
/// live connection status rather than a generic check, because "selected" and
/// "actually connected" come apart exactly when the user needs to know (server
/// asleep, wrong Wi-Fi).
class ServerRow extends StatelessWidget {
  const ServerRow({
    super.key,
    required this.server,
    required this.isActive,
    required this.wsState,
    required this.onSelect,
    required this.onRename,
    required this.onForget,
  });

  final PairedServer server;
  final bool isActive;
  final WsState wsState;
  final VoidCallback onSelect;
  final VoidCallback onRename;
  final VoidCallback onForget;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final (statusLabel, statusColor) = _status(cs);

    return Card(
      elevation: 0,
      margin: const EdgeInsets.only(bottom: kSpace8),
      color: isActive
          ? cs.primary.withValues(alpha: 0.08)
          : cs.surfaceContainer,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(kRadius12),
        side: BorderSide(
          color: isActive
              ? cs.primary.withValues(alpha: 0.5)
              : cs.outlineVariant,
        ),
      ),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: isActive ? null : onSelect,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(
            kSpace12,
            kSpace10,
            kSpace4,
            kSpace10,
          ),
          child: Row(
            children: [
              Icon(
                isActive
                    ? PhosphorIconsFill.hardDrives
                    : PhosphorIconsLight.hardDrives,
                size: 22,
                color: isActive ? cs.primary : cs.outline,
              ),
              const SizedBox(width: kSpace12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      server.label,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: kSpace2),
                    Text(
                      '${server.host}:${server.port}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(
                        context,
                      ).textTheme.bodySmall?.copyWith(color: cs.outline),
                    ),
                    if (statusLabel != null) ...[
                      const SizedBox(height: kSpace4),
                      Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Container(
                            width: 7,
                            height: 7,
                            decoration: BoxDecoration(
                              color: statusColor,
                              shape: BoxShape.circle,
                            ),
                          ),
                          const SizedBox(width: kSpace6),
                          Text(
                            statusLabel,
                            style: Theme.of(context).textTheme.labelSmall
                                ?.copyWith(
                                  color: statusColor,
                                  fontWeight: FontWeight.w600,
                                ),
                          ),
                        ],
                      ),
                    ],
                  ],
                ),
              ),
              PopupMenuButton<String>(
                key: Key('serverMenu-${server.fingerprint}'),
                icon: Icon(
                  PhosphorIconsRegular.dotsThree,
                  size: 20,
                  color: cs.onSurface,
                ),
                tooltip: 'Server actions',
                popUpAnimationStyle: AnimationStyle.noAnimation,
                onSelected: (v) => switch (v) {
                  'rename' => onRename(),
                  'forget' => onForget(),
                  _ => null,
                },
                itemBuilder: (_) => [
                  themedMenuItem(
                    value: 'rename',
                    icon: PhosphorIconsLight.pencilSimple,
                    label: 'Rename',
                  ),
                  const PopupMenuDivider(),
                  themedMenuItem(
                    value: 'forget',
                    icon: PhosphorIconsLight.trash,
                    label: 'Forget',
                    color: cs.error,
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// Live status, shown only on the active row — an inactive server has no
  /// socket, so any claim about its reachability would be a guess.
  (String?, Color) _status(ColorScheme cs) {
    if (!isActive) return (null, cs.outline);
    return switch (wsState) {
      WsState.connected => ('Connected', cs.primary),
      WsState.connecting => ('Connecting…', cs.primary),
      WsState.reconnecting => ('Reconnecting…', kStatusWarning),
      WsState.closed || WsState.idle => ('Offline', cs.error),
    };
  }
}

/// Prompt for a new display label. Credentials and the live socket are
/// untouched, so renaming the active server never drops the connection.
Future<void> renameServerDialog(
  BuildContext context,
  ConnectionController controller,
  PairedServer server,
) async {
  final ctrl = TextEditingController(text: server.label);
  final label = await showDialog<String>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: const Text('Rename server'),
      content: TextField(
        controller: ctrl,
        autofocus: true,
        decoration: const InputDecoration(hintText: 'e.g. work mac'),
        onSubmitted: (v) => Navigator.pop(ctx, v.trim()),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(ctx),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(ctx, ctrl.text.trim()),
          child: const Text('Save'),
        ),
      ],
    ),
  );
  if (label == null || label.isEmpty) return;
  await controller.renameServer(server.id, label);
}

/// Confirm before dropping a server's stored credentials — re-pairing needs
/// physical access to that Mac's QR code, so this is not cheaply undone.
Future<void> forgetServerDialog(
  BuildContext context,
  ConnectionController controller,
  PairedServer server,
) async {
  final confirmed = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text('Forget ${server.label}?'),
      content: const Text(
        'This phone will need to scan that server\'s QR code again to '
        'reconnect. Sessions on the server are not affected.',
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(ctx, false),
          child: const Text('Cancel'),
        ),
        FilledButton(
          style: FilledButton.styleFrom(
            backgroundColor: Theme.of(ctx).colorScheme.error,
          ),
          onPressed: () => Navigator.pop(ctx, true),
          child: const Text('Forget'),
        ),
      ],
    ),
  );
  if (confirmed != true) return;
  await controller.forget(server.id);
}
