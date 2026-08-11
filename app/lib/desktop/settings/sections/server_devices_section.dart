/// Server & Devices section body (SPEC-13 migration map, SPEC-50 D5/D6).
///
/// The Server group is exactly four rows: the active profile, the one
/// reachability question, a pair-a-phone row, and a single collapsed
/// Diagnostics disclosure holding everything that is not a decision (lifecycle,
/// CLI, TLS fingerprint, log path, and an Advanced escape hatch). Existing
/// widgets and providers are reused (embedded), not rewritten.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show Clipboard, ClipboardData;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:phosphoricons_flutter/phosphoricons_flutter.dart';

import '../../../app/theme.dart';
import '../../../status/status_event.dart';
import '../../../status/status_providers.dart';
import '../../../store/connection.dart'
    show connectionControllerProvider, connectionProvider;
import '../../daemon/daemon_lifecycle.dart' show DaemonActionResult;
import '../../desktop_app.dart'
    show desktopControllerProvider, makitInstallCommand, serverProfileProvider;
import '../../screens/devices_screen.dart';
import '../../screens/qr_screen.dart';
import '../../screens/sessions_screen.dart';
import '../../tray/tray_controller.dart' show DaemonState;
import '../server_config.dart';
import '../settings_item_anchor.dart';
import 'section_header.dart';
import 'settings_group.dart';

/// Lowest valid TCP port (inclusive).
const int _kMinPort = 1;

/// Highest valid TCP port (inclusive).
const int _kMaxPort = 65535;

/// Restarts the daemon so a committed config change takes effect, reporting a
/// non-`ok` outcome through the status center (the immediate-effect contract
/// that replaced the old "Save & restart server" two-phase commit).
Future<void> _restartAndReport(WidgetRef ref) async {
  // Resolved before the await: `ref` throws once the widget is unmounted, and
  // the record must outlive the thing reporting to it.
  final status = ref.status;
  final result = await ref.read(desktopControllerProvider).restart();
  if (!result.ok) {
    status.failure(
      'Could not restart the server',
      source: StatusSources.settings,
      detail: result.message,
    );
  }
}

/// Server & Devices section body: the single home for endpoint config, daemon
/// lifecycle, the CLI, device pairing/management, sessions, and TLS trust.
class ServerDevicesSection extends StatefulWidget {
  /// Creates the Server & Devices section body.
  const ServerDevicesSection({super.key});

  @override
  State<ServerDevicesSection> createState() => _ServerDevicesSectionState();
}

class _ServerDevicesSectionState extends State<ServerDevicesSection> {
  /// Id of the single expanded disclosure row, or null when all are collapsed.
  /// Kept here (not per-row) so the rows behave as an accordion.
  String? _openRow;

  void _toggle(String id) =>
      setState(() => _openRow = _openRow == id ? null : id);

  @override
  Widget build(BuildContext context) {
    return ListView(
      children: [
        const SettingsSectionHeader(title: 'Server & Devices'),
        const SettingsSectionHeader(title: 'Server'),
        SettingsGroup(
          children: [
            const _ActiveProfileRow(),
            const SettingsItemAnchor(
              itemId: 'server_devices.endpoint',
              child: _ReachabilityRow(),
            ),
            _ExpandableRow(
              icon: PhosphorIconsLight.qrCode,
              title: 'Pair a phone',
              help: 'Show a QR code to pair a new device over Tailscale.',
              expanded: _openRow == 'pair_server',
              onToggle: () => _toggle('pair_server'),
              child: const QrScreen(),
            ),
            _ExpandableRow(
              icon: PhosphorIconsLight.wrench,
              title: 'Diagnostics',
              help:
                  'Lifecycle, CLI, TLS fingerprint, log path and advanced '
                  'bind options.',
              expanded: _openRow == 'diagnostics',
              onToggle: () => _toggle('diagnostics'),
              child: const _Diagnostics(),
            ),
          ],
        ),
        const SettingsSectionHeader(title: 'Devices'),
        SettingsGroup(
          children: [
            _ExpandableRow(
              icon: PhosphorIconsLight.devices,
              title: 'Paired devices',
              help: 'List and revoke the devices paired with this server.',
              expanded: _openRow == 'paired',
              onToggle: () => _toggle('paired'),
              child: const DevicesScreen(),
            ),
            _ExpandableRow(
              icon: PhosphorIconsLight.qrCode,
              title: 'Pair new device',
              help: 'Show a QR code to pair a new device.',
              expanded: _openRow == 'pair',
              onToggle: () => _toggle('pair'),
              child: const QrScreen(),
            ),
          ],
        ),
        const SettingsSectionHeader(title: 'Sessions'),
        SettingsGroup(
          children: [
            _ExpandableRow(
              icon: PhosphorIconsLight.listBullets,
              title: 'Running sessions',
              help: 'Active agent sessions (idle and exited ones are hidden).',
              expanded: _openRow == 'sessions',
              onToggle: () => _toggle('sessions'),
              child: const SessionsScreen(),
            ),
          ],
        ),
        const SettingsSectionHeader(title: 'Danger zone'),
        const SettingsGroup(children: [_UnpairRow()]),
      ],
    );
  }
}

/// Active-profile row: the profile this window runs against, with a live
/// running/stopped dot. There is deliberately no switcher here (the badge owns
/// that) and no Stop (you never stop the server you are talking to — D7).
class _ActiveProfileRow extends ConsumerWidget {
  const _ActiveProfileRow();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final cs = Theme.of(context).colorScheme;
    final profile = ref.watch(serverProfileProvider);
    final controller = ref.watch(desktopControllerProvider);
    return ListenableBuilder(
      listenable: controller,
      builder: (context, _) {
        final running = controller.summary.state == DaemonState.running;
        return ListTile(
          leading: Icon(PhosphorIconsLight.cube, color: cs.outline),
          title: Text(profile.name),
          subtitle: const Text(
            'Projects, agents, devices and sessions are separate per profile.',
          ),
          trailing: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                PhosphorIconsFill.circle,
                size: 10,
                color: running ? cs.primary : cs.outline,
              ),
              const SizedBox(width: kSpace8),
              Text(
                running ? 'Running' : 'Stopped',
                style: Theme.of(
                  context,
                ).textTheme.bodySmall?.copyWith(color: cs.outline),
              ),
            ],
          ),
        );
      },
    );
  }
}

/// The one reachability question (SPEC-50 D5): two radios that each state their
/// *consequence*, an "allow plain Wi-Fi" fallback checkbox nested under "My
/// devices", and a read-only current-address line. Committing a change applies
/// immediately and restarts the daemon.
class _ReachabilityRow extends ConsumerWidget {
  const _ReachabilityRow();

  Future<void> _setReachability(WidgetRef ref, Reachability value) async {
    await ref.read(serverConfigProvider.notifier).setReachability(value);
    await _restartAndReport(ref);
  }

  Future<void> _setFallback(WidgetRef ref, bool allow) async {
    await ref.read(serverConfigProvider.notifier).setAllowLanFallback(allow);
    await _restartAndReport(ref);
  }

  /// The current bind address, read-only. The detected-address dropdown is
  /// deferred (SPEC-50 "does not do"); this renders what the server is bound to
  /// now, or the effective intent when it is not connected.
  String _currentAddress(WidgetRef ref, ServerConfig cfg) {
    final host = ref.watch(connectionProvider).server?.host;
    if (host != null && host.isNotEmpty) return host;
    if (cfg.customHost.trim().isNotEmpty) return cfg.customHost.trim();
    return switch (cfg.reachability) {
      Reachability.thisMacOnly => '127.0.0.1',
      Reachability.myDevices => 'Your devices via Tailscale',
    };
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final cs = Theme.of(context).colorScheme;
    final cfg = ref.watch(serverConfigProvider);
    // Transparent Material so the nested RadioListTiles paint their ink on it
    // rather than on the deep-link highlight's tinted DecoratedBox (which would
    // trip ListTile's "background may be invisible" assertion).
    return Material(
      type: MaterialType.transparency,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Padding(
            padding: EdgeInsets.fromLTRB(16, 12, 16, 4),
            child: Text(
              'Who can reach this server?',
              style: TextStyle(fontWeight: FontWeight.w600),
            ),
          ),
          RadioGroup<Reachability>(
            groupValue: cfg.reachability,
            onChanged: (v) =>
                unawaited(_setReachability(ref, v ?? cfg.reachability)),
            child: const Column(
              children: [
                RadioListTile<Reachability>(
                  value: Reachability.thisMacOnly,
                  title: Text('Just this Mac'),
                  subtitle: Text('Nothing else can connect.'),
                ),
                RadioListTile<Reachability>(
                  value: Reachability.myDevices,
                  title: Text('My devices'),
                  subtitle: Text(
                    'Reachable from your phone over Tailscale. '
                    'No account needed.',
                  ),
                ),
              ],
            ),
          ),
          if (cfg.reachability == Reachability.myDevices)
            Padding(
              padding: const EdgeInsets.fromLTRB(56, 0, 24, 4),
              child: Row(
                children: [
                  Checkbox(
                    value: cfg.allowLanFallback,
                    onChanged: (v) => unawaited(_setFallback(ref, v ?? false)),
                  ),
                  const Expanded(
                    child: Text('Also allow plain Wi-Fi when Tailscale is off'),
                  ),
                ],
              ),
            ),
          Padding(
            padding: const EdgeInsets.fromLTRB(24, 4, 24, 12),
            child: Row(
              children: [
                Text(
                  'Address',
                  style: Theme.of(
                    context,
                  ).textTheme.bodySmall?.copyWith(color: cs.outline),
                ),
                const SizedBox(width: kSpace12),
                Expanded(
                  child: Text(
                    _currentAddress(ref, cfg),
                    style: const TextStyle(
                      fontFeatures: [FontFeature.tabularFigures()],
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// The Diagnostics disclosure body: everything that is not a decision, one
/// read-only/advanced block. Each moved row keeps its retired
/// [SettingsItemAnchor] id so deep links and settings search still resolve.
class _Diagnostics extends ConsumerWidget {
  const _Diagnostics();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final cs = Theme.of(context).colorScheme;
    final profile = ref.watch(serverProfileProvider);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const SettingsItemAnchor(
          itemId: 'server_devices.lifecycle',
          child: _LifecycleRow(),
        ),
        const Divider(height: 1),
        const SettingsItemAnchor(
          itemId: 'server_devices.cli',
          child: _CliRow(),
        ),
        const Divider(height: 1),
        const SettingsItemAnchor(
          itemId: 'server_devices.fingerprint',
          child: _FingerprintRow(),
        ),
        const Divider(height: 1),
        ListTile(
          leading: Icon(PhosphorIconsLight.fileText, color: cs.outline),
          title: const Text('Log'),
          subtitle: Text(
            '${profile.home}/makit.log',
            style: const TextStyle(
              fontFeatures: [FontFeature.tabularFigures()],
            ),
          ),
        ),
        const Divider(height: 1),
        const _AdvancedRow(),
      ],
    );
  }
}

/// Lifecycle: a live status line plus Start / Stop / Restart actions driven by
/// the polled [desktopControllerProvider] (replaces the old daemon header).
class _LifecycleRow extends ConsumerWidget {
  const _LifecycleRow();

  /// Runs a lifecycle [action] and reports a non-`ok` outcome.
  ///
  /// These results were previously discarded, so a daemon that refused to start
  /// -- most often because its port is already held by another build -- failed
  /// with no feedback whatsoever.
  static Future<void> _report(
    WidgetRef ref,
    String title,
    Future<DaemonActionResult> Function() action,
  ) async {
    // Captured before the await: `ref` throws once its widget is unmounted.
    final status = ref.status;
    final result = await action();
    if (result.ok) return;
    status.failure(
      title,
      source: StatusSources.settings,
      detail: result.message,
    );
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final cs = Theme.of(context).colorScheme;
    final controller = ref.watch(desktopControllerProvider);
    return ListenableBuilder(
      listenable: controller,
      builder: (context, _) {
        final summary = controller.summary;
        final running = summary.state == DaemonState.running;
        final starting = summary.state == DaemonState.starting;
        final (Color dot, String label) = switch (summary.state) {
          DaemonState.running => (
            cs.primary,
            'Running · pid ${summary.pid ?? '—'}',
          ),
          DaemonState.starting => (cs.outline, 'Starting…'),
          DaemonState.stopped => (cs.outline, 'Stopped'),
        };
        return ListTile(
          leading: Icon(PhosphorIconsFill.circle, size: 12, color: dot),
          title: const Text('Lifecycle'),
          subtitle: Text(label),
          trailing: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (!running)
                FilledButton.icon(
                  onPressed: starting
                      ? null
                      : () => unawaited(
                          _report(
                            ref,
                            'Could not start the server',
                            controller.start,
                          ),
                        ),
                  icon: const Icon(PhosphorIconsLight.play, size: 18),
                  label: const Text('Start'),
                ),
              if (running) ...[
                OutlinedButton.icon(
                  onPressed: () => unawaited(
                    _report(
                      ref,
                      'Could not restart the server',
                      controller.restart,
                    ),
                  ),
                  icon: const Icon(PhosphorIconsLight.arrowClockwise, size: 18),
                  label: const Text('Restart'),
                ),
                const SizedBox(width: kSpace8),
                OutlinedButton.icon(
                  onPressed: () => unawaited(
                    _report(ref, 'Could not stop the server', controller.stop),
                  ),
                  icon: const Icon(PhosphorIconsLight.stop, size: 18),
                  label: const Text('Stop'),
                ),
              ],
            ],
          ),
        );
      },
    );
  }
}

/// CLI: shows the resolved `makit` path (or a missing state) and offers a
/// "Copy install command" action (reuses [makitInstallCommand]). The one-time
/// `Install CLI` action lives in General; here the CLI is read-only diagnostics
/// plus an optional path override.
class _CliRow extends ConsumerStatefulWidget {
  const _CliRow();

  @override
  ConsumerState<_CliRow> createState() => _CliRowState();
}

class _CliRowState extends ConsumerState<_CliRow> {
  Future<String?>? _resolved;
  late final TextEditingController _override;

  @override
  void initState() {
    super.initState();
    _override = TextEditingController(
      text: ref.read(serverConfigProvider).cliPath,
    );
    _resolved = _refreshResolved();
  }

  Future<String?> _refreshResolved() =>
      ref.read(desktopControllerProvider).lifecycle.resolver.resolve();

  @override
  void dispose() {
    _override.dispose();
    super.dispose();
  }

  /// Persists a new CLI-path override and re-resolves so the shown path (and
  /// any "not found" state) reflects the change immediately.
  void _applyOverride(String value) {
    unawaited(ref.read(serverConfigProvider.notifier).setCliPath(value));
    setState(() {
      _resolved = _refreshResolved();
    });
  }

  void _copyInstallCommand() {
    unawaited(
      Clipboard.setData(const ClipboardData(text: makitInstallCommand)),
    );
    ref.status.info(
      'Install command copied',
      source: StatusSources.settings,
      detail: makitInstallCommand,
    );
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return FutureBuilder<String?>(
      future: _resolved,
      builder: (context, snapshot) {
        final path = snapshot.data;
        final resolving = snapshot.connectionState == ConnectionState.waiting;
        final subtitle = resolving
            ? 'Locating the makit CLI…'
            : (path ??
                  'The makit CLI was not found. Install it from General to '
                      'control the server from here.');
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            ListTile(
              leading: Icon(
                PhosphorIconsLight.terminalWindow,
                color: cs.outline,
              ),
              title: const Text('CLI'),
              subtitle: Text(subtitle),
              trailing: IconButton(
                tooltip: 'Copy install command',
                icon: const Icon(PhosphorIconsLight.copy, size: 18),
                onPressed: _copyInstallCommand,
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 0, 24, 12),
              child: TextField(
                controller: _override,
                decoration: const InputDecoration(
                  labelText: 'Override path (optional)',
                  hintText: '/path/to/makit',
                  border: OutlineInputBorder(),
                  isDense: true,
                ),
                onSubmitted: _applyOverride,
              ),
            ),
          ],
        );
      },
    );
  }
}

/// Fingerprint / TLS trust: the paired server's certificate fingerprint as a
/// read-only value with a copy action (mirrors the mobile settings row).
class _FingerprintRow extends ConsumerWidget {
  const _FingerprintRow();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final cs = Theme.of(context).colorScheme;
    final server = ref.watch(connectionProvider).server;
    final fingerprint = server?.fingerprint;

    return ListTile(
      leading: Icon(PhosphorIconsLight.fingerprint, color: cs.outline),
      title: const Text('Fingerprint / TLS trust'),
      subtitle: Text(
        fingerprint == null
            ? 'Not connected to a server.'
            : _shorten(fingerprint),
        style: fingerprint == null
            ? null
            : const TextStyle(fontFeatures: [FontFeature.tabularFigures()]),
      ),
      trailing: fingerprint == null
          ? null
          : IconButton(
              tooltip: 'Copy fingerprint',
              icon: const Icon(PhosphorIconsLight.copy, size: 18),
              onPressed: () {
                unawaited(Clipboard.setData(ClipboardData(text: fingerprint)));
                ref.status.info(
                  'Fingerprint copied',
                  source: StatusSources.settings,
                  detail: fingerprint,
                );
              },
            ),
    );
  }

  static String _shorten(String fingerprint) => fingerprint.length <= 24
      ? fingerprint
      : '${fingerprint.substring(0, 24)}…';
}

/// Advanced (Diagnostics → Advanced): the custom-host escape hatch and the
/// port. Committing either applies immediately and restarts the daemon. Kept
/// collapsed so it is not the fourth thing a new user reads.
class _AdvancedRow extends ConsumerStatefulWidget {
  const _AdvancedRow();

  @override
  ConsumerState<_AdvancedRow> createState() => _AdvancedRowState();
}

class _AdvancedRowState extends ConsumerState<_AdvancedRow> {
  late final TextEditingController _customHost;
  late final TextEditingController _port;
  String? _portError;

  @override
  void initState() {
    super.initState();
    final cfg = ref.read(serverConfigProvider);
    _customHost = TextEditingController(text: cfg.customHost);
    _port = TextEditingController(text: '${cfg.port}');
  }

  @override
  void dispose() {
    _customHost.dispose();
    _port.dispose();
    super.dispose();
  }

  Future<void> _applyHost(String value) async {
    await ref.read(serverConfigProvider.notifier).setCustomHost(value);
    await _restartAndReport(ref);
  }

  /// Validates and applies the port. Rejects out-of-range values (keeping the
  /// stored config unchanged) and surfaces an inline error.
  Future<void> _applyPort(String value) async {
    final port = int.tryParse(value.trim());
    if (port == null || port < _kMinPort || port > _kMaxPort) {
      setState(() {
        _portError = 'Port must be a number between $_kMinPort and $_kMaxPort.';
      });
      return;
    }
    setState(() => _portError = null);
    await ref.read(serverConfigProvider.notifier).setPort(port);
    await _restartAndReport(ref);
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return ExpansionTile(
      leading: Icon(PhosphorIconsLight.slidersHorizontal, color: cs.outline),
      title: const Text('Advanced'),
      subtitle: const Text('Custom bind host and port.'),
      childrenPadding: const EdgeInsets.fromLTRB(24, 0, 24, 12),
      children: [
        TextField(
          controller: _customHost,
          decoration: const InputDecoration(
            labelText: 'Host',
            hintText: '0.0.0.0',
            helperText: 'Overrides the reachability choice above.',
            border: OutlineInputBorder(),
            isDense: true,
          ),
          onSubmitted: (v) => unawaited(_applyHost(v)),
        ),
        const SizedBox(height: kSpace12),
        SizedBox(
          width: 160,
          child: TextField(
            controller: _port,
            keyboardType: TextInputType.number,
            decoration: InputDecoration(
              labelText: 'Port',
              hintText: '$kDefaultServerPort',
              border: const OutlineInputBorder(),
              isDense: true,
              errorText: _portError,
            ),
            onSubmitted: (v) => unawaited(_applyPort(v)),
          ),
        ),
      ],
    );
  }
}

/// A settings row that discloses [child] *inline* when tapped, rather than
/// pushing a new page. The toggle is instant (no expand animation) by design.
/// It is *controlled* — [expanded]/[onToggle] are owned by the section so the
/// rows act as an accordion (only one open at a time). Used for the embedded
/// control views (paired devices / pairing QR / running sessions), which render
/// themselves without a Scaffold/AppBar so they sit directly inside the card.
class _ExpandableRow extends StatelessWidget {
  const _ExpandableRow({
    required this.icon,
    required this.title,
    required this.help,
    required this.expanded,
    required this.onToggle,
    required this.child,
  });

  final IconData icon;
  final String title;
  final String help;
  final bool expanded;
  final VoidCallback onToggle;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        ListTile(
          leading: Icon(icon, color: cs.outline),
          title: Text(title),
          subtitle: Text(help),
          trailing: Icon(
            expanded
                ? PhosphorIconsLight.caretUp
                : PhosphorIconsLight.caretDown,
          ),
          onTap: onToggle,
        ),
        if (expanded) ...[const Divider(height: 1), child],
      ],
    );
  }
}

/// Unpair this device (danger): clears this app's stored server pairing via the
/// existing [connectionControllerProvider] flow, behind a confirm dialog. On
/// desktop the app re-pairs over loopback on the next launch; this still
/// clears the current pairing and disconnects, so it is a real action.
class _UnpairRow extends ConsumerWidget {
  const _UnpairRow();

  Future<void> _confirmAndUnpair(BuildContext context, WidgetRef ref) async {
    // Resolved before the first await: `ref` throws once its widget is
    // unmounted, and the record must survive the thing that reported to it.
    final status = ref.status;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Unpair this device?'),
        content: const Text(
          'This clears the stored pairing and disconnects from the server.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(context).colorScheme.error,
            ),
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Unpair'),
          ),
        ],
      ),
    );
    if (confirmed ?? false) {
      try {
        await ref.read(connectionControllerProvider.notifier).unpair();
        status.success('Device unpaired', source: StatusSources.devices);
      } catch (error) {
        status.failure(
          'Could not unpair the device',
          error: error,
          source: StatusSources.devices,
        );
      }
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final cs = Theme.of(context).colorScheme;
    return ListTile(
      leading: Icon(PhosphorIconsLight.linkBreak, color: cs.error),
      title: Text('Unpair this device', style: TextStyle(color: cs.error)),
      subtitle: const Text('Remove this device\'s pairing and disconnect.'),
      trailing: OutlinedButton(
        style: OutlinedButton.styleFrom(foregroundColor: cs.error),
        onPressed: () => unawaited(_confirmAndUnpair(context, ref)),
        child: const Text('Unpair'),
      ),
    );
  }
}
