/// SPEC-41 mobile sheet 1 — the port list for one worktree. 56 pt tap rows with
/// a chevron and NO buttons: nothing destructive or actionable is reachable
/// from a flick (spec §2b). Tapping a row pushes the per-port detail sheet.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:phosphoricons_flutter/phosphoricons_flutter.dart';

import '../../app/theme.dart';
import '../../store/ports.dart';
import '../../store/store.dart';
import '../widgets/sheet_header.dart';
import 'port_detail_sheet.dart';
import 'port_token_pill.dart';
import 'ports_vocabulary.dart';

/// Height of a port list row — a comfortable single-gesture ("open") target.
const double _kPortRowHeight = 56;

/// Opens the worktree's ports sheet, resolving each port's session label from
/// the store so the detail sheet can name it.
Future<void> showWorktreePortsSheet(
  BuildContext context,
  WidgetRef ref, {
  required String worktreePath,
  required String branch,
}) {
  final ports = ref.read(portsForWorktreeProvider(worktreePath));
  final sessions = ref.read(sessionsProvider);
  String? sessionLabel(String? id) {
    if (id == null) return null;
    final s = sessions.byId(id);
    if (s == null) return null;
    final t = s.title.trim();
    return t.isNotEmpty ? t : s.agent;
  }

  return showModalBottomSheet<void>(
    context: context,
    showDragHandle: true,
    isScrollControlled: true,
    builder: (sheetCtx) => SafeArea(
      child: WorktreePortsSheetBody(
        branch: branch,
        ports: ports,
        nowMs: DateTime.now().millisecondsSinceEpoch,
        onOpenPort: (port) => showPortDetailSheet(
          sheetCtx,
          port: port,
          branchLabel: branch,
          sessionLabel: sessionLabel(port.sessionId),
        ),
      ),
    ),
  );
}

/// The body of sheet 1. Pure (data + callback in) so it is directly pumpable.
class WorktreePortsSheetBody extends StatelessWidget {
  const WorktreePortsSheetBody({
    super.key,
    required this.branch,
    required this.ports,
    required this.onOpenPort,
    this.nowMs,
  });

  final String branch;
  final List<PortInfo> ports;
  final void Function(PortInfo port) onOpenPort;

  /// Injected clock so the health sentence's "probed N s ago" is deterministic
  /// in tests; falls back to the wall clock in production.
  final int? nowMs;

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SheetHeader(title: 'Ports · $branch'),
          for (final port in ports)
            _PortListRow(
              key: ValueKey('ports-list-row-${port.port}'),
              port: port,
              nowMs: nowMs ?? DateTime.now().millisecondsSinceEpoch,
              onTap: () => onOpenPort(port),
            ),
          const SizedBox(height: kSpace8),
        ],
      ),
    );
  }
}

/// One 56 pt tappable port row: port number, command, a health pill + reach,
/// and a trailing chevron. Its only gesture is "open".
class _PortListRow extends StatelessWidget {
  const _PortListRow({
    super.key,
    required this.port,
    required this.onTap,
    required this.nowMs,
  });

  final PortInfo port;
  final VoidCallback onTap;
  final int nowMs;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    return InkWell(
      onTap: onTap,
      child: Container(
        constraints: const BoxConstraints(minHeight: _kPortRowHeight),
        padding: const EdgeInsets.symmetric(
          horizontal: kSpace16,
          vertical: kSpace8,
        ),
        child: Row(
          children: [
            SizedBox(
              width: 44,
              child: Text(
                '${port.port}',
                style: theme.textTheme.bodyMedium?.copyWith(
                  fontFamily: kMonoFontFamily,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
            const SizedBox(width: kSpace8),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Row(
                    children: [
                      Flexible(
                        child: Text(
                          port.command.split(' ').first,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.bodySmall?.copyWith(
                            fontFamily: kMonoFontFamily,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                      const SizedBox(width: kSpace8),
                      PortTokenPill(
                        label: portHealthPill(port.health),
                        sentence: portHealthTooltip(port.health, nowMs: nowMs),
                      ),
                      const SizedBox(width: kSpace8),
                      PortTokenPill(
                        label: portReachPill(port.reach),
                        sentence: portReachTooltip(port.reach),
                        color: cs.onSurfaceVariant,
                      ),
                    ],
                  ),
                ],
              ),
            ),
            Icon(
              PhosphorIconsLight.caretRight,
              size: 16,
              color: cs.onSurfaceVariant,
            ),
          ],
        ),
      ),
    );
  }
}
