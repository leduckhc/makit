/// SPEC-open-ports mobile sheet 1 — the port list for one worktree. 56 pt tap rows with
/// a chevron and NO buttons: nothing destructive or actionable is reachable
/// from a flick (spec §2b). Tapping a row pushes the per-port detail sheet.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:phosphoricons_flutter/phosphoricons_flutter.dart';

import '../../app/routes.dart';
import '../../app/theme.dart';
import '../../store/ports.dart';
import '../../store/store.dart';
import '../widgets/sheet_header.dart';
import 'port_detail_sheet.dart';
import 'port_token_pill.dart';
import 'ports_vocabulary.dart';

/// Height of a port list row — a comfortable single-gesture ("open") target.
const double _kPortRowHeight = 56;

/// Opens the worktree's ports sheet. The port list and the session labels are
/// read inside the sheet builder behind a [Consumer] so a later `ports.snapshot`
/// (a port removed, ownership changed, a dead server dropping to a refusal) is
/// reflected live — a one-shot `ref.read` at open time would strand the sheet on
/// stale data.
Future<void> showWorktreePortsSheet(
  BuildContext context, {
  required String worktreePath,
  required String branch,
}) {
  return showModalBottomSheet<void>(
    context: context,
    showDragHandle: true,
    isScrollControlled: true,
    builder: (sheetCtx) => SafeArea(
      child: Consumer(
        builder: (ctx, ref, _) {
          final ports = ref.watch(portsForWorktreeProvider(worktreePath));
          final sessions = ref.watch(sessionsProvider);
          String? sessionLabel(String? id) {
            if (id == null) return null;
            final s = sessions.byId(id);
            if (s == null) return null;
            final t = s.title.trim();
            return t.isNotEmpty ? t : s.agent;
          }

          return WorktreePortsSheetBody(
            branch: branch,
            ports: ports,
            nowMs: DateTime.now().millisecondsSinceEpoch,
            onOpenPort: (port) => showPortDetailSheet(
              sheetCtx,
              ref,
              port: port,
              branchLabel: branch,
              sessionLabel: sessionLabel(port.sessionId),
            ),
            // Jump to the global Ports screen (SPEC-ports-global-view P2a). Pop the sheet
            // first so backing out of the screen doesn't land on it.
            onOpenPortsScreen: () {
              Navigator.of(sheetCtx).pop();
              sheetCtx.go(kRoutePorts);
            },
          );
        },
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
    this.onOpenPortsScreen,
    this.nowMs,
  });

  final String branch;
  final List<PortInfo> ports;
  final void Function(PortInfo port) onOpenPort;

  /// Opens the global Ports screen (SPEC-ports-global-view P2a). When null the button is
  /// hidden — the pure body carries no navigation of its own.
  final VoidCallback? onOpenPortsScreen;

  /// Injected clock so the health sentence's "probed N s ago" is deterministic
  /// in tests; falls back to the wall clock in production.
  final int? nowMs;

  @override
  Widget build(BuildContext context) {
    // One reference time for the whole build: read per row, two ports could
    // land on different seconds and print inconsistent probe ages.
    final referenceNowMs = nowMs ?? DateTime.now().millisecondsSinceEpoch;
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
              nowMs: referenceNowMs,
              onTap: () => onOpenPort(port),
            ),
          if (onOpenPortsScreen != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(
                kSpace16,
                kSpace8,
                kSpace16,
                0,
              ),
              child: Align(
                alignment: Alignment.centerLeft,
                child: TextButton.icon(
                  onPressed: onOpenPortsScreen,
                  icon: const Icon(PhosphorIconsLight.plug, size: 16),
                  label: const Text('Open the Ports screen'),
                ),
              ),
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
                          portCommandToken(port.command),
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.bodySmall?.copyWith(
                            fontFamily: kMonoFontFamily,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                      const SizedBox(width: kSpace6),
                      PortTokenPill(
                        label: portHealthPill(port.health),
                        sentence: portHealthTooltip(port.health, nowMs: nowMs),
                        tone: portHealthTone(port.health),
                        showDot: true,
                      ),
                      const SizedBox(width: kSpace6),
                      PortTokenPill(
                        label: portReachPill(port.reach),
                        sentence: portReachTooltip(port.reach),
                        tone: portReachTone(port.reach),
                      ),
                    ],
                  ),
                  const SizedBox(height: kSpace2),
                  // pid, age, then the args — the age ahead of the command so
                  // the phone's truncation eats the argv tail, not the fact.
                  Text(
                    portProcessLine(
                      port.pid,
                      port.command,
                      startedAt: port.startedAt,
                      nowMs: nowMs,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: cs.onSurfaceVariant,
                      fontFamily: kMonoFontFamily,
                    ),
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
