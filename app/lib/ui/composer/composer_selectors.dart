import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:phosphoricons_flutter/phosphoricons_flutter.dart';

import '../../store/models.dart';
import '../../store/store.dart';
import '../home/repo_chips.dart' show AgentAvatar;
import '../widgets/sheet_header.dart';
import 'client_commands.dart';

/// Small rounded pill used in the composer footer: a leading widget (agent
/// avatar or icon) + a short label, tappable to open a picker. Kept visually
/// low-key so it reads as an inline control, not a primary button.
class _ComposerPill extends StatelessWidget {
  const _ComposerPill({
    required this.leading,
    required this.label,
    required this.onTap,
    this.tooltip,
  });

  final Widget leading;
  final String label;
  final VoidCallback onTap;
  final String? tooltip;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final pill = InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(14),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            leading,
            const SizedBox(width: 6),
            Flexible(
              child: Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.labelMedium?.copyWith(
                  color: cs.onSurfaceVariant,
                ),
              ),
            ),
          ],
        ),
      ),
    );
    return tooltip == null ? pill : Tooltip(message: tooltip!, child: pill);
  }
}

/// Composer-footer control that shows the session's current model and, on tap,
/// opens the model picker (reusing the `/model` client command). Renders
/// nothing until `session.meta` has arrived with a non-empty models list — the
/// client fetches the selectable models asynchronously, so there is simply no
/// selector to show in the meantime.
class ComposerModelSelector extends ConsumerWidget {
  /// Creates the model selector for [sessionId].
  const ComposerModelSelector({super.key, required this.sessionId});

  /// The session whose model this selector reads and switches.
  final String sessionId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final meta = ref.watch(sessionMetaProvider(sessionId));
    if (meta == null || meta.models.isEmpty) return const SizedBox.shrink();
    final agent = ref.watch(sessionsProvider).byId(sessionId)?.agent ?? '';
    return _ComposerPill(
      leading: AgentAvatar(agent: agent, size: 16),
      label: meta.model?.name ?? 'model',
      tooltip: 'Model',
      onTap: () => handleClientCommand(
        '/model',
        context: context,
        ref: ref,
        sessionId: sessionId,
      ),
    );
  }
}

/// Composer-footer control that shows the session's current thinking
/// (reasoning) effort and, on tap, opens the thinking-level picker (reusing the
/// `/thinking` client command). Hidden entirely when the agent reports no
/// thinking support (an empty thinking level).
class ComposerThinkingSelector extends ConsumerWidget {
  /// Creates the thinking-effort selector for [sessionId].
  const ComposerThinkingSelector({super.key, required this.sessionId});

  /// The session whose thinking level this selector reads and changes.
  final String sessionId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final meta = ref.watch(sessionMetaProvider(sessionId));
    if (meta == null || meta.thinking.isEmpty) return const SizedBox.shrink();
    return _ComposerPill(
      leading: Icon(
        PhosphorIconsLight.cellSignalFull,
        size: 16,
        color: Theme.of(context).colorScheme.onSurfaceVariant,
      ),
      label: meta.thinking,
      tooltip: 'Thinking effort',
      onTap: () => handleClientCommand(
        '/thinking',
        context: context,
        ref: ref,
        sessionId: sessionId,
      ),
    );
  }
}

/// Composer-footer control that shows the session's current agent *mode* and,
/// on tap, lets the user switch it. Only ACP agents advertise modes (native pi
/// has none), so this is hidden unless `session.meta` carries a non-empty
/// mode list. Switching sends the `mode` session action, mapped server-side to
/// ACP's `session/set_session_mode`.
class ComposerModeSelector extends ConsumerWidget {
  /// Creates the mode selector for [sessionId].
  const ComposerModeSelector({super.key, required this.sessionId});

  /// The session whose mode this selector reads and switches.
  final String sessionId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final modes = ref.watch(sessionMetaProvider(sessionId))?.modes;
    if (modes == null || modes.available.isEmpty) {
      return const SizedBox.shrink();
    }
    final current = modes.available.firstWhere(
      (m) => m.id == modes.current,
      orElse: () => modes.available.first,
    );
    return _ComposerPill(
      leading: Icon(
        PhosphorIconsLight.slidersHorizontal,
        size: 16,
        color: Theme.of(context).colorScheme.onSurfaceVariant,
      ),
      label: current.name,
      tooltip: 'Mode',
      onTap: () => _pickMode(context, ref, modes),
    );
  }

  Future<void> _pickMode(
    BuildContext context,
    WidgetRef ref,
    SessionModes modes,
  ) async {
    final picked = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (sheetContext) => SafeArea(
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const SheetHeader(title: 'Mode'),
              for (final m in modes.available)
                ListTile(
                  title: Text(m.name),
                  trailing: m.id == modes.current
                      ? const Icon(PhosphorIconsLight.check)
                      : null,
                  onTap: () => Navigator.pop(sheetContext, m.id),
                ),
            ],
          ),
        ),
      ),
    );
    if (picked == null || picked == modes.current) return;
    ref
        .read(storeControllerProvider.notifier)
        .sendSessionAction(sessionId, 'mode', args: {'id': picked});
  }
}
