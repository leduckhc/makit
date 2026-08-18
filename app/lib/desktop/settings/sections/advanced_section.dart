/// Advanced section body (SPEC-desktop-settings-rework migration map).
///
/// Surfaces developer/diagnostic affordances that drive real behavior today:
/// a read-only **Status** snapshot (pid / uptime / protocol version), a
/// **Developer** fake-server indicator, and a **Reset all settings** action.
/// Telemetry stays a reserved `[future]` placeholder.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:phosphoricons_flutter/phosphoricons_flutter.dart';

import '../../../control/control_types.dart' show StatusData;
import '../../../diagnostics/diagnostics_screen.dart' show DiagnosticsScreen;
import '../../../store/connection.dart' show connectionProvider;
import '../../../transport/protocol.dart' show protocolVersion;
import '../../chat/sidebar_layout.dart' show resetSidebarLayoutToDefaults;
import '../../screens/providers.dart' show controlClientProvider;
import '../../screens/time_format.dart' show formatUptime;
import '../../../store/prefs/preferences_providers.dart';
import 'coming_soon.dart';
import 'section_header.dart';
import 'settings_group.dart';

/// Advanced section body.
class AdvancedSection extends StatelessWidget {
  /// Creates the Advanced section body.
  const AdvancedSection({super.key});

  @override
  Widget build(BuildContext context) {
    return ListView(
      children: const [
        SettingsSectionHeader(title: 'Advanced'),
        SettingsSectionHeader(title: 'Developer'),
        SettingsGroup(children: [_FakeServerRow(), _DiagnosticsRow()]),
        SettingsSectionHeader(title: 'Status'),
        SettingsGroup(
          children: [
            _StatusRows(),
            ComingSoonRow(
              icon: PhosphorIconsLight.chartLine,
              title: 'Telemetry',
              subtitle: 'Anonymous usage telemetry.',
            ),
          ],
        ),
        SettingsSectionHeader(title: 'Reset'),
        SettingsGroup(children: [_ResetAllRow()]),
      ],
    );
  }
}

/// Read-only daemon status: pid, uptime, and protocol version. Reuses the
/// control client's one-shot `status()` (the same source as the retired
/// `StatusScreen`); the protocol version is the compile-time constant.
class _StatusRows extends ConsumerStatefulWidget {
  const _StatusRows();

  @override
  ConsumerState<_StatusRows> createState() => _StatusRowsState();
}

class _StatusRowsState extends ConsumerState<_StatusRows> {
  late Future<StatusData> _future;

  @override
  void initState() {
    super.initState();
    _future = ref.read(controlClientProvider).status();
  }

  void _refresh() {
    setState(() {
      _future = ref.read(controlClientProvider).status();
    });
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return FutureBuilder<StatusData>(
      future: _future,
      builder: (context, snapshot) {
        final waiting = snapshot.connectionState == ConnectionState.waiting;
        final status = snapshot.data;
        return Column(
          children: [
            ListTile(
              leading: Icon(PhosphorIconsLight.memory, color: cs.outline),
              title: const Text('Process id'),
              subtitle: Text(switch ((waiting, status)) {
                (true, _) => 'Loading…',
                (_, final s?) => '${s.pid}',
                _ => 'Server not reachable',
              }),
              trailing: IconButton(
                tooltip: 'Refresh',
                icon: const Icon(PhosphorIconsLight.arrowClockwise, size: 18),
                onPressed: _refresh,
              ),
            ),
            ListTile(
              leading: Icon(PhosphorIconsLight.clock, color: cs.outline),
              title: const Text('Uptime'),
              subtitle: Text(
                status == null ? '—' : formatUptime(status.uptimeMs),
              ),
            ),
            ListTile(
              leading: Icon(PhosphorIconsLight.network, color: cs.outline),
              title: const Text('Protocol version'),
              subtitle: const Text('v$protocolVersion'),
            ),
          ],
        );
      },
    );
  }
}

/// Developer → Diagnostics. Opens the on-device log viewer for the control
/// app's own logs (framework/uncaught errors captured at startup). The
/// "send to server" affordance is hidden here: the desktop app runs beside the
/// server, and the daemon log already has its own live tail.
class _DiagnosticsRow extends StatelessWidget {
  const _DiagnosticsRow();

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return ListTile(
      leading: Icon(PhosphorIconsLight.bug, color: cs.outline),
      title: const Text('Diagnostics'),
      subtitle: const Text('View and copy this app\'s logs.'),
      trailing: const Icon(PhosphorIconsLight.caretRight, size: 18),
      onTap: () => Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (_) => const DiagnosticsScreen(showSendToServer: false),
        ),
      ),
    );
  }
}

/// Developer → Fake server. There is no clean runtime toggle for the fake
/// server (it is attached at bootstrap via `useFakeServer()` with no supported
/// "turn off"), so per SPEC-desktop-settings-rework's YAGNI rule this is a read-only indicator of
/// the current connection mode rather than a non-functional switch.
class _FakeServerRow extends ConsumerWidget {
  const _FakeServerRow();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final cs = Theme.of(context).colorScheme;
    final useFake = ref.watch(connectionProvider).useFake;
    return ListTile(
      leading: Icon(PhosphorIconsLight.hardDrives, color: cs.outline),
      title: const Text('Fake server'),
      subtitle: Text(
        useFake
            ? 'On — the app is using an in-memory dev server.'
            : 'Off — connected to the real daemon.',
      ),
      trailing: Text(
        useFake ? 'On' : 'Off',
        style: Theme.of(context).textTheme.bodySmall?.copyWith(
          color: useFake ? cs.primary : cs.outline,
        ),
      ),
    );
  }
}

/// Telemetry — reserved `[future]` placeholder (SPEC-desktop-settings-rework §7): no backend.
/// Reset all settings: clears every stored preference override after a confirm
/// dialog. Shows the current count of changed settings when non-zero.
class _ResetAllRow extends ConsumerWidget {
  const _ResetAllRow();

  Future<void> _confirmAndReset(BuildContext context, WidgetRef ref) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Reset all settings?'),
        content: const Text(
          'Every changed preference returns to its default. This cannot be '
          'undone.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Reset all'),
          ),
        ],
      ),
    );
    if (confirmed ?? false) {
      await ref.read(preferencesControllerProvider.notifier).resetAll();
      // The sidebar providers seed from prefs only at startup, so clearing the
      // stored overrides isn't enough — re-seed the live values to their
      // defaults so the reset is visible immediately (theme / text scale react
      // via their own providers). Kept next to the provider definitions so the
      // reset invariant lives in one place.
      resetSidebarLayoutToDefaults(ref);
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final cs = Theme.of(context).colorScheme;
    // Watch the overrides map so the count refreshes on change, but derive the
    // user-facing count (internal bookkeeping entries don't count).
    ref.watch(preferencesControllerProvider);
    final changed = ref
        .read(preferencesControllerProvider.notifier)
        .modifiedUserFacingCount;
    return ListTile(
      leading: Icon(
        PhosphorIconsLight.clockCounterClockwise,
        color: cs.outline,
      ),
      title: const Text('Reset all settings'),
      subtitle: Text(
        changed == 0
            ? 'All settings are at their defaults.'
            : '$changed setting${changed == 1 ? '' : 's'} changed from '
                  'default.',
      ),
      trailing: OutlinedButton(
        onPressed: changed == 0 ? null : () => _confirmAndReset(context, ref),
        child: const Text('Reset all'),
      ),
    );
  }
}
