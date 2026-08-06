/// SPEC-41 mobile sheet 2 — one port, every fact spelled out, then the two P1
/// actions (Open / Copy URL), which are hidden when the port never answered
/// HTTP (`openUrl` absent) rather than guessing a URL.
///
/// No destructive control exists in P1: killing a process from a phone is a
/// remote-execution surface that does not ship with the scanner (spec §Phasing).
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:phosphoricons_flutter/phosphoricons_flutter.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../app/theme.dart';
import '../../store/ports.dart';
import '../widgets/sheet_header.dart';
import 'port_token_pill.dart';
import 'ports_vocabulary.dart';

/// Height of an action row (Open / Copy URL), a comfortable touch target.
const double _kActionRowHeight = 50;

/// Opens the per-port detail sheet.
Future<void> showPortDetailSheet(
  BuildContext context, {
  required PortInfo port,
  required String branchLabel,
  required String? sessionLabel,
}) => showModalBottomSheet<void>(
  context: context,
  showDragHandle: true,
  isScrollControlled: true,
  builder: (_) => SafeArea(
    child: PortDetailSheetBody(
      port: port,
      branchLabel: branchLabel,
      sessionLabel: sessionLabel,
      nowMs: DateTime.now().millisecondsSinceEpoch,
    ),
  ),
);

/// The body of the port detail sheet. Pure (data in, no provider read) so it is
/// directly pumpable in a widget test.
class PortDetailSheetBody extends StatelessWidget {
  const PortDetailSheetBody({
    super.key,
    required this.port,
    required this.branchLabel,
    required this.sessionLabel,
    required this.nowMs,
  });

  final PortInfo port;
  final String branchLabel;
  final String? sessionLabel;

  /// Injected so "up 41m" is deterministic in tests.
  final int nowMs;

  Future<void> _open(BuildContext context) async {
    final url = port.openUrl;
    if (url == null) return;
    final messenger = ScaffoldMessenger.of(context);
    final uri = Uri.tryParse(url);
    try {
      if (uri == null) throw const FormatException('bad url');
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    } catch (_) {
      messenger.showSnackBar(
        const SnackBar(content: Text('Could not open the port')),
      );
    }
  }

  Future<void> _copy(BuildContext context) async {
    final url = port.openUrl;
    if (url == null) return;
    final messenger = ScaffoldMessenger.of(context);
    await Clipboard.setData(ClipboardData(text: url));
    messenger.showSnackBar(const SnackBar(content: Text('URL copied')));
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final hasUrl = port.openUrl != null;
    final uptime = portUptimeLabel(port.startedAt, nowMs: nowMs);

    return SingleChildScrollView(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SheetHeader(title: ':${port.port} ${port.command.split(' ').first}'),
          Padding(
            padding: const EdgeInsets.fromLTRB(kSpace16, 0, kSpace16, kSpace8),
            child: Row(
              children: [
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
          ),
          const Divider(height: 1),
          _fact(theme, 'worktree', branchLabel),
          if (sessionLabel != null) _fact(theme, 'session', sessionLabel!),
          _fact(theme, 'command', port.command, mono: true),
          _fact(theme, 'pid', '${port.pid}', mono: true),
          if (uptime.isNotEmpty) _fact(theme, 'uptime', uptime),
          _fact(theme, 'bound', '${port.address}:${port.port}', mono: true),
          _fact(theme, 'probe', portHealthTooltip(port.health, nowMs: nowMs)),
          const Divider(height: 1),
          if (hasUrl) ...[
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
  }) {
    final cs = Theme.of(context).colorScheme;
    final color = primary ? cs.primary : cs.onSurface;
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
