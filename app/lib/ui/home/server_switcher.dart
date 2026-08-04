import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:phosphoricons_flutter/phosphoricons_flutter.dart';

import '../../app/theme.dart';
import '../../store/connection.dart';
import '../widgets/sheet_header.dart';

/// The home screen's title: the server you're looking at.
///
/// With one server this is just a label — the same information the old static
/// "Makit" title carried, but naming the machine whose repos are on screen.
/// With several it becomes the switcher, because on a phone the title bar is
/// the only place a global context control fits.
class ServerSwitcher extends ConsumerWidget {
  const ServerSwitcher({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final conn = ref.watch(connectionProvider);
    final cs = Theme.of(context).colorScheme;
    final active = conn.activeServer;

    // Demo mode and the dev --dart-define override have no server record to
    // name, so they keep the app name.
    final title = conn.useFake ? 'Makit' : (active?.label ?? 'Makit');
    final canSwitch = conn.hasMultipleServers;

    final label = Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Flexible(
          child: Text(
            title,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: Theme.of(context).textTheme.titleMedium?.copyWith(
              fontWeight: FontWeight.w600,
              // The title floats over scrolling content behind a scrim; the
              // shadows keep it legible against a light card edge.
              shadows: [
                Shadow(color: cs.surface, blurRadius: 6),
                Shadow(color: cs.surface, blurRadius: 12),
              ],
            ),
          ),
        ),
        if (canSwitch) ...[
          const SizedBox(width: kSpace4),
          Icon(
            key: const Key('serverSwitcherCaret'),
            PhosphorIconsLight.caretUpDown,
            size: 15,
            color: cs.outline,
          ),
        ],
      ],
    );

    if (!canSwitch) return label;

    return InkWell(
      borderRadius: BorderRadius.circular(kRadius8),
      onTap: () => _showPicker(context, ref),
      child: Padding(
        padding: const EdgeInsets.symmetric(
          horizontal: kSpace4,
          vertical: kSpace4,
        ),
        child: label,
      ),
    );
  }

  Future<void> _showPicker(BuildContext context, WidgetRef ref) async {
    final conn = ref.read(connectionProvider);
    final controller = ref.read(connectionControllerProvider.notifier);
    final activeId = conn.activeServer?.id;

    final chosen = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (sheetContext) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const SheetHeader(title: 'Switch server'),
            for (final s in conn.servers)
              ListTile(
                leading: Icon(
                  s.id == activeId
                      ? PhosphorIconsFill.hardDrives
                      : PhosphorIconsLight.hardDrives,
                  color: s.id == activeId
                      ? Theme.of(sheetContext).colorScheme.primary
                      : Theme.of(sheetContext).colorScheme.outline,
                ),
                title: Text(s.label),
                subtitle: Text('${s.host}:${s.port}'),
                trailing: s.id == activeId
                    ? Icon(
                        PhosphorIconsBold.check,
                        size: 16,
                        color: Theme.of(sheetContext).colorScheme.primary,
                      )
                    : null,
                onTap: () => Navigator.pop(sheetContext, s.id),
              ),
            const Divider(height: 1),
            ListTile(
              leading: const Icon(PhosphorIconsLight.gearSix),
              title: const Text('Manage servers'),
              onTap: () {
                Navigator.pop(sheetContext);
                context.go('/servers');
              },
            ),
          ],
        ),
      ),
    );
    if (chosen == null || chosen == activeId) return;
    await controller.switchTo(chosen);
  }
}
