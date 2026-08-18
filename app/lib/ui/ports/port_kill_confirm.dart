/// The kill confirm + its outcome reporting (SPEC-ports-kill D8), shared by the desktop
/// popover and the mobile detail sheet so the two cannot drift.
///
/// D8 in one place: the dialog **names the victim** — command, pid, port and the
/// branch it serves — because "Are you sure?" is not a mitigation. The tuple the
/// dialog names is exactly the tuple the command carries (D1), which is why the
/// caller passes a [PortInfo] and this file derives the target from it: there is
/// no second path where the two could disagree.
///
/// A port whose `startedAt` is unknown is unverifiable, so [portIsKillable]
/// returns false and neither surface renders a Kill control for it.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../store/ports.dart';
import '../../status/status_event.dart';
import '../../status/status_providers.dart';
import 'ports_vocabulary.dart';

/// Whether a Kill control may be offered for [port] at all (D1).
bool portIsKillable(PortInfo port) => PortKillTarget.of(port) != null;

/// Confirm, then kill, then say what happened.
///
/// Returns the outcome, or null when the user backed out — so a caller can close
/// its own surface only on an actual attempt. Every outcome is reported through a
/// `SnackBar` carrying [portKillOutcomeMessage]'s specific sentence; a refusal is
/// never silent, because a Kill that appears to do nothing is worse than one
/// that explains itself.
Future<PortKillOutcome?> confirmAndKillPort(
  BuildContext context,
  WidgetRef ref,
  PortInfo port, {
  String? branchLabel,
}) async {
  // Resolved before the first await: `ref` throws once its widget is
  // unmounted, and the record must survive the thing that reported to it.
  final status = ref.status;
  final target = PortKillTarget.of(port);
  // Defensive, and cheap: the two call sites already hide the control, so
  // reaching here with an unverifiable port would be a bug, not user input.
  if (target == null) return null;

  // Read the provider BEFORE the dialog: `ref` belongs to the caller's widget,
  // and if that widget is disposed while the confirm is up (the sheet closed, the
  // popover unpinned, a snapshot rebuilt the row) then `ref.read` throws into a
  // button handler. The killer itself is a plain object and outlives the widget.
  final killer = ref.read(portsKillerProvider);
  final confirmed = await showDialog<bool>(
    context: context,
    builder: (dctx) => AlertDialog(
      title: Text('Kill :${port.port}?'),
      content: Text(portKillConfirmBody(port, branchLabel: branchLabel)),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(dctx, false),
          child: const Text('Cancel'),
        ),
        FilledButton(
          style: FilledButton.styleFrom(
            backgroundColor: Theme.of(dctx).colorScheme.error,
            foregroundColor: Theme.of(dctx).colorScheme.onError,
          ),
          onPressed: () => Navigator.pop(dctx, true),
          child: const Text('Kill'),
        ),
      ],
    ),
  );
  if (confirmed != true) return null;

  final outcome = await killer.kill(target);
  final message = portKillOutcomeMessage(outcome, port: port.port);
  if (outcome.releasedThePort) {
    status.success(
      message,
      source: StatusSources.ports,
      sessionId: port.sessionId,
    );
  } else {
    status.warning(
      message,
      source: StatusSources.ports,
      sessionId: port.sessionId,
    );
  }
  return outcome;
}

/// Bulk-kill every orphan (SPEC-ports-kill D5): N independent, individually re-verified
/// kills behind ONE confirm that names the count and the ports.
///
/// The confirm names the endpoints for the same reason a single kill names its
/// victim (D8) — "kill 3 things" is not something a user can check. The report
/// is a count, because the server's honest answer is one outcome per endpoint and
/// a partial success is the expected case: a wedged server that ignores SIGKILL
/// survives while its neighbours die.
Future<void> confirmAndKillOrphans(
  BuildContext context,
  WidgetRef ref,
  List<PortInfo> orphans,
) async {
  // Resolved before the first await: `ref` throws once its widget is
  // unmounted, and the record must survive the thing that reported to it.
  final status = ref.status;
  if (orphans.isEmpty) return;
  // Same rule as the single kill: resolve the provider before the confirm.
  final killer = ref.read(portsKillerProvider);
  final ports = orphans.map((p) => ':${p.port}').join(', ');
  final confirmed = await showDialog<bool>(
    context: context,
    builder: (dctx) => AlertDialog(
      title: Text(
        orphans.length == 1
            ? 'Kill 1 orphan?'
            : 'Kill ${orphans.length} orphans?',
      ),
      content: Text(
        'Sends SIGTERM (then SIGKILL if ignored) to $ports — listeners whose '
        'worktree is gone. Each one is re-checked on the server first.',
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(dctx, false),
          child: const Text('Cancel'),
        ),
        FilledButton(
          style: FilledButton.styleFrom(
            backgroundColor: Theme.of(dctx).colorScheme.error,
            foregroundColor: Theme.of(dctx).colorScheme.onError,
          ),
          onPressed: () => Navigator.pop(dctx, true),
          child: const Text('Kill all'),
        ),
      ],
    ),
  );
  if (confirmed != true) return;

  final outcomes = await killer.killOrphans();
  status.info(portKillOrphansMessage(outcomes), source: StatusSources.ports);
}
