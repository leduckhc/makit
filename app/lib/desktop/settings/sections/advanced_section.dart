/// Advanced section body (SPEC-13 migration map).
///
/// Surfaces developer/diagnostic affordances that drive real behavior today:
/// a read-only **Status** snapshot (pid / uptime / protocol version), a
/// **Developer** fake-server indicator, and a **Reset all settings** action.
/// Telemetry stays a reserved `[future]` placeholder.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_symbols_icons/symbols.dart';

import '../../../control/control_types.dart' show StatusData;
import '../../../store/connection.dart' show connectionProvider;
import '../../../transport/protocol.dart' show protocolVersion;
import '../../screens/providers.dart' show controlClientProvider;
import '../../screens/time_format.dart' show formatUptime;
import '../prefs/preferences_providers.dart';
import 'section_header.dart';

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
        _FakeServerRow(),
        SettingsSectionHeader(title: 'Status'),
        _StatusRows(),
        _TelemetryRow(),
        SettingsSectionHeader(title: 'Reset'),
        _ResetAllRow(),
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
              leading: Icon(Symbols.memory, weight: 200, color: cs.outline),
              title: const Text('Process id'),
              subtitle: Text(
                switch ((waiting, status)) {
                  (true, _) => 'Loading…',
                  (_, final s?) => '${s.pid}',
                  _ => 'Server not reachable',
                },
              ),
              trailing: IconButton(
                tooltip: 'Refresh',
                icon: const Icon(Symbols.refresh, weight: 200, size: 18),
                onPressed: _refresh,
              ),
            ),
            ListTile(
              leading: Icon(Symbols.schedule, weight: 200, color: cs.outline),
              title: const Text('Uptime'),
              subtitle: Text(
                status == null ? '—' : formatUptime(status.uptimeMs),
              ),
            ),
            ListTile(
              leading: Icon(Symbols.lan, weight: 200, color: cs.outline),
              title: const Text('Protocol version'),
              subtitle: const Text('v$protocolVersion'),
            ),
          ],
        );
      },
    );
  }
}

/// Developer → Fake server. There is no clean runtime toggle for the fake
/// server (it is attached at bootstrap via `useFakeServer()` with no supported
/// "turn off"), so per SPEC-13's YAGNI rule this is a read-only indicator of
/// the current connection mode rather than a non-functional switch.
class _FakeServerRow extends ConsumerWidget {
  const _FakeServerRow();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final cs = Theme.of(context).colorScheme;
    final useFake = ref.watch(connectionProvider).useFake;
    return ListTile(
      leading: Icon(Symbols.dns, weight: 200, color: cs.outline),
      title: const Text('Fake server'),
      subtitle: Text(
        useFake
            ? 'On — the app is using an in-memory dev server.'
            : 'Off — connected to the real daemon.',
      ),
      trailing: Text(
        useFake ? 'On' : 'Off',
        style: TextStyle(
          color: useFake ? cs.primary : cs.outline,
          fontSize: 12,
        ),
      ),
    );
  }
}

/// Telemetry — reserved `[future]` placeholder (SPEC-13 §7): no backend.
class _TelemetryRow extends StatelessWidget {
  const _TelemetryRow();

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return ListTile(
      enabled: false,
      leading: Icon(Symbols.analytics, weight: 200, color: cs.outline),
      title: const Text('Telemetry'),
      subtitle: const Text('Anonymous usage telemetry.'),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Symbols.schedule, weight: 200, size: 16, color: cs.outline),
          const SizedBox(width: 6),
          Text('Coming soon', style: TextStyle(color: cs.outline, fontSize: 12)),
        ],
      ),
    );
  }
}

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
        Symbols.settings_backup_restore,
        weight: 200,
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
