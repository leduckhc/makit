/// SPEC-41 mobile sheet 2 — one port, every fact spelled out, then the two P1
/// actions (Open / Copy URL), which are hidden when the port never answered
/// HTTP (`openUrl` absent) rather than guessing a URL.
///
/// SPEC-43 adds the one destructive control, and only here: `Kill this process…`
/// is the **last** row, past a danger divider, ~a whole sheet below the first
/// tap and still behind a confirm (mockup §2b). Sheet 1 stays button-free — §10
/// rejects an inline kill in a scrollable list.
library;

import 'dart:async';
import 'dart:io' show Platform;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:phosphoricons_flutter/phosphoricons_flutter.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../app/theme.dart';
import '../../status/status_event.dart';
import '../../status/status_providers.dart';
import '../../store/ports.dart';
import '../widgets/sheet_header.dart';
import 'port_forward.dart';
import 'port_kill_confirm.dart';
import 'port_token_pill.dart';
import 'ports_vocabulary.dart';

/// Height of an action row (Open / Copy URL), a comfortable touch target.
const double _kActionRowHeight = 50;

/// The divider that fences the destructive row off (SPEC-43 D8). Keyed so a test
/// can prove the fence exists, not just the label.
const Key kPortKillDivider = ValueKey('port-kill-divider');

/// The "Watch this port" switch (SPEC-44 D7/D8). Keyed for tests.
const Key kPortWatchToggle = ValueKey('port-watch-toggle');

/// True on the platforms where a host loopback port is genuinely unreachable, so
/// `Open` is a dead link and a forward is the only thing that can work.
bool get _isHandheld => Platform.isIOS || Platform.isAndroid;

/// Opens the per-port detail sheet.
///
/// [ref] is what lets the sheet own the kill: the confirm and the command both
/// live in `port_kill_confirm.dart`, so this file never builds a target itself.
Future<void> showPortDetailSheet(
  BuildContext context,
  WidgetRef ref, {
  required PortInfo port,
  required String branchLabel,
  required String? sessionLabel,
}) {
  // Resolved once, here, rather than inside the switch's callback: that callback
  // fires long after this frame, and `ref` belongs to the widget that opened the
  // sheet (the same rule `port_kill_confirm.dart` follows).
  final watcher = ref.read(portsWatchPortProvider);
  return showModalBottomSheet<void>(
    context: context,
    showDragHandle: true,
    isScrollControlled: true,
    builder: (sheetCtx) => SafeArea(
      child: PortDetailSheetBody(
        port: port,
        branchLabel: branchLabel,
        sessionLabel: sessionLabel,
        nowMs: DateTime.now().millisecondsSinceEpoch,
        // SPEC-44 D7: only an OWNED port can be watched — the identity is
        // `(worktreePath, port)`, so an unowned listener has nothing to key on.
        //
        // The sheet owns the switch's position while it is open (see
        // `_PortDetailSheetBodyState._watched`): `port` here is one immutable
        // snapshot row, so a flip could not otherwise be seen until a fresh
        // snapshot reopened the sheet. The callback reports whether the write
        // LANDED, and the body reverts the switch if it did not.
        onWatchChanged: port.worktreePath == null
            ? null
            : (on) => watcher.set(
                worktreePath: port.worktreePath!,
                port: port.port,
                on: on,
              ),
        // SPEC-44 P4b: only offered where `Open` cannot work — a loopback port
        // on a device that is not the host. On the desktop the port is local, so
        // forwarding it to yourself would be nonsense.
        onForward: _isHandheld && portIsForwardable(port)
            ? () => confirmAndForwardPort(sheetCtx, ref, port)
            : null,
        // An unverifiable port (no `startedAt`) gets NO kill row at all (D1).
        onKill: portIsKillable(port)
            ? () async {
                final outcome = await confirmAndKillPort(
                  sheetCtx,
                  ref,
                  port,
                  branchLabel: branchLabel,
                );
                // Only close on a kill that actually freed the endpoint: after a
                // refusal the facts on this sheet are what the user needs next.
                if (outcome != null &&
                    outcome.releasedThePort &&
                    sheetCtx.mounted) {
                  Navigator.of(sheetCtx).pop();
                }
              }
            : null,
      ),
    ),
  );
}

/// The body of the port detail sheet. Pure (data in, no provider read) so it is
/// directly pumpable in a widget test.
class PortDetailSheetBody extends StatefulWidget {
  const PortDetailSheetBody({
    super.key,
    required this.port,
    required this.branchLabel,
    required this.sessionLabel,
    required this.nowMs,
    this.onKill,
    this.onWatchChanged,
    this.onForward,
  });

  final PortInfo port;
  final String branchLabel;
  final String? sessionLabel;

  /// Injected so "up 41m" is deterministic in tests.
  final int nowMs;

  /// Invoked by the destructive row. **Null hides the row entirely** — which is
  /// how an unverifiable port (SPEC-43 D1) ends up with no kill affordance.
  final VoidCallback? onKill;

  /// Toggles the "stopped listening" alert (SPEC-44). Null hides the switch —
  /// an unowned port has no `(worktreePath, port)` identity to watch by.
  ///
  /// Returns whether the server accepted the write. A `Future<bool>`, not a
  /// `void`: a watch that silently failed to persist is a notification the user
  /// will wait for and never get, so the switch has to be able to go back.
  final Future<bool> Function(bool on)? onWatchChanged;

  /// Hands the port to the system browser (SPEC-44 P4b). Non-null only when this
  /// device cannot reach the port directly, which is also when it REPLACES
  /// `Open`: offering a link to this device's own `127.0.0.1` would be a button
  /// that always fails.
  final VoidCallback? onForward;

  @override
  State<PortDetailSheetBody> createState() => _PortDetailSheetBodyState();
}

class _PortDetailSheetBodyState extends State<PortDetailSheetBody> {
  /// The switch's position while this sheet is open, seeded from the snapshot row
  /// and flipped optimistically so the control responds to the tap that caused
  /// it. Reverted when the server refuses the write.
  late bool _watched = widget.port.watched;

  PortInfo get port => widget.port;
  int get nowMs => widget.nowMs;
  String get branchLabel => widget.branchLabel;
  String? get sessionLabel => widget.sessionLabel;

  Future<void> _toggleWatch(bool on) async {
    final report = widget.onWatchChanged;
    if (report == null) return;
    final status = statusOf(context);
    setState(() => _watched = on);
    final ok = await report(on);
    if (!ok) {
      // Put the switch back where the server says it is, and say so — the whole
      // point of the feature is an alert that actually arrives.
      if (mounted) {
        setState(() => _watched = !on);
      }
      status.warning(
        on
            ? 'Could not start watching the port'
            : 'Could not stop watching the port',
        detail: ':${port.port}',
        source: StatusSources.ports,
        sessionId: port.sessionId,
      );
    }
  }

  Future<void> _open(BuildContext context) async {
    final url = port.openUrl;
    if (url == null) return;
    final status = statusOf(context);
    final uri = Uri.tryParse(url);
    try {
      if (uri == null) throw const FormatException('bad url');
      final launched = await launchUrl(
        uri,
        mode: LaunchMode.externalApplication,
      );
      if (!launched) {
        status.failure(
          'Could not open the port',
          detail: url,
          source: StatusSources.ports,
          sessionId: port.sessionId,
        );
      }
    } catch (e) {
      status.failure(
        'Invalid port URL',
        error: e,
        detail: url,
        source: StatusSources.ports,
        sessionId: port.sessionId,
      );
    }
  }

  Future<void> _copy(BuildContext context) async {
    final url = port.openUrl;
    if (url == null) return;
    final status = statusOf(context);
    await Clipboard.setData(ClipboardData(text: url));
    status.info(
      'URL copied',
      detail: url,
      source: StatusSources.ports,
      sessionId: port.sessionId,
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final hasUrl = port.openUrl != null;
    final uptime = portUptimeLabel(port.startedAt, nowMs: nowMs);

    return SingleChildScrollView(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SheetHeader(title: ':${port.port} ${portRowToken(port)}'),
          Padding(
            padding: const EdgeInsets.fromLTRB(kSpace16, 0, kSpace16, kSpace8),
            child: Row(
              children: [
                PortTokenPill(
                  label: portHealthPill(port.health),
                  sentence: portHealthTooltip(port.health, nowMs: nowMs),
                  tone: portHealthTone(port.health),
                  showDot: true,
                ),
                const SizedBox(width: kSpace8),
                PortTokenPill(
                  label: portReachPill(port.reach),
                  sentence: portReachTooltip(port.reach),
                  tone: portReachTone(port.reach),
                ),
              ],
            ),
          ),
          const Divider(height: 1),
          _fact(theme, 'worktree', branchLabel),
          if (sessionLabel != null) _fact(theme, 'session', sessionLabel!),
          // D13: the container is WHO owns this port, so it sits with the other
          // ownership facts, above the process that merely proxies it.
          if (port.docker != null) ...[
            _fact(theme, 'container', port.docker!.container, mono: true),
            if (port.docker!.compose != null)
              _fact(theme, 'compose', port.docker!.compose!, mono: true),
          ],
          _fact(theme, 'command', port.command, mono: true),
          _fact(theme, 'pid', '${port.pid}', mono: true),
          if (uptime.isNotEmpty) _fact(theme, 'uptime', uptime),
          _fact(theme, 'bound', '${port.address}:${port.port}', mono: true),
          _fact(theme, 'probe', portHealthTooltip(port.health, nowMs: nowMs)),
          const Divider(height: 1),
          if (widget.onForward != null)
            _action(
              context,
              icon: PhosphorIconsLight.eye,
              label: portForwardLabel,
              primary: true,
              onTap: widget.onForward!,
            ),
          if (hasUrl) ...[
            // Hidden when a forward is on offer: this device's loopback is not
            // the host's, so `Open` could only ever load a dead page here.
            if (widget.onForward == null)
              _action(
                context,
                icon: PhosphorIconsLight.arrowSquareOut,
                label: 'Open',
                primary: true,
                onTap: () => _open(context),
              ),
            _action(
              context,
              icon: PhosphorIconsLight.copy,
              label: 'Copy URL',
              onTap: () => _copy(context),
            ),
          ],
          // Opt-in alerts (SPEC-44 D8): per port, never ambient — an always-on
          // port notification would fire on every rebuild.
          if (widget.onWatchChanged != null)
            SwitchListTile(
              key: kPortWatchToggle,
              value: _watched,
              onChanged: (on) => unawaited(_toggleWatch(on)),
              dense: true,
              title: const Text('Watch this port'),
              subtitle: const Text(
                'Notify me if it stops listening for 20 seconds',
              ),
            ),
          // The danger zone (mockup §2b): last, fenced off, and still behind a
          // confirm. Nothing destructive shares a row group with Open/Copy.
          if (widget.onKill != null) ...[
            const Divider(key: kPortKillDivider, height: 1),
            _action(
              context,
              icon: PhosphorIconsLight.stopCircle,
              label: portKillRowLabel,
              danger: true,
              onTap: widget.onKill!,
            ),
          ],
          const SizedBox(height: kSpace16),
        ],
      ),
    );
  }

  Widget _fact(ThemeData theme, String key, String value, {bool mono = false}) {
    final cs = theme.colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(
        horizontal: kSpace16,
        vertical: kSpace6,
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 96,
            child: Text(
              key,
              style: theme.textTheme.bodySmall?.copyWith(
                color: cs.onSurfaceVariant,
              ),
            ),
          ),
          Expanded(
            child: Text(
              value,
              style: mono
                  ? theme.textTheme.bodySmall?.copyWith(
                      fontFamily: kMonoFontFamily,
                    )
                  : theme.textTheme.bodySmall,
            ),
          ),
        ],
      ),
    );
  }

  Widget _action(
    BuildContext context, {
    required IconData icon,
    required String label,
    required VoidCallback onTap,
    bool primary = false,
    bool danger = false,
  }) {
    final cs = Theme.of(context).colorScheme;
    final color = danger
        ? cs.error
        : primary
        ? cs.primary
        : cs.onSurface;
    return InkWell(
      onTap: onTap,
      child: SizedBox(
        height: _kActionRowHeight,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: kSpace16),
          child: Row(
            children: [
              Icon(icon, size: 18, color: color),
              const SizedBox(width: kSpace12),
              Text(label, style: TextStyle(color: color)),
            ],
          ),
        ),
      ),
    );
  }
}
