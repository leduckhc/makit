/// Server & Devices section body (SPEC-13 migration map).
///
/// Consolidates the desktop control surfaces — server endpoint, daemon
/// lifecycle, CLI, paired devices, pairing QR, running sessions, and the TLS
/// fingerprint — into one immediate-effect settings section. Existing widgets
/// and providers are reused (embedded), not rewritten.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show Clipboard, ClipboardData;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_symbols_icons/symbols.dart';

import '../../../store/connection.dart'
    show connectionControllerProvider, connectionProvider;
import '../../desktop_app.dart'
    show desktopControllerProvider, makitInstallCommand;
import '../../screens/devices_screen.dart';
import '../../screens/qr_screen.dart';
import '../../screens/sessions_screen.dart';
import '../../tray/tray_controller.dart' show DaemonState;
import '../server_config.dart';
import '../settings_item_anchor.dart';
import 'section_header.dart';
import 'settings_group.dart';
import 'settings_reset_button.dart';

/// Lowest valid TCP port (inclusive).
const int _kMinPort = 1;

/// Highest valid TCP port (inclusive).
const int _kMaxPort = 65535;

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
        const SettingsGroup(
          children: [
            SettingsItemAnchor(
              itemId: 'server_devices.endpoint',
              child: _EndpointRow(),
            ),
            _LifecycleRow(),
            _CliRow(),
            _FingerprintRow(),
          ],
        ),
        const SettingsSectionHeader(title: 'Devices'),
        SettingsGroup(
          children: [
            _ExpandableRow(
              icon: Symbols.devices,
              title: 'Paired devices',
              help: 'List and revoke the devices paired with this server.',
              expanded: _openRow == 'paired',
              onToggle: () => _toggle('paired'),
              child: const DevicesScreen(),
            ),
            _ExpandableRow(
              icon: Symbols.qr_code_2,
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
              icon: Symbols.list_alt,
              title: 'Running sessions',
              help: 'Live agent sessions known to the daemon.',
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

/// Endpoint (host + port). Applies on field commit (Enter) with the same port
/// validation as the retired `ServerSettingsScreen` (1–65535) — no Save button
/// (SPEC-13 #8). A "Save & restart server" action applies to a running daemon.
class _EndpointRow extends ConsumerStatefulWidget {
  const _EndpointRow();

  @override
  ConsumerState<_EndpointRow> createState() => _EndpointRowState();
}

class _EndpointRowState extends ConsumerState<_EndpointRow> {
  late final TextEditingController _host;
  late final TextEditingController _port;
  String? _portError;

  @override
  void initState() {
    super.initState();
    final cfg = ref.read(serverConfigProvider);
    _host = TextEditingController(text: cfg.host);
    _port = TextEditingController(text: '${cfg.port}');
  }

  @override
  void dispose() {
    _host.dispose();
    _port.dispose();
    super.dispose();
  }

  void _applyHost(String value) {
    // Blank collapses to the default host (mirrors ServerConfigController).
    unawaited(ref.read(serverConfigProvider.notifier).setHost(value));
  }

  /// Validates and applies the port. Rejects out-of-range values (keeping the
  /// stored config unchanged) and surfaces an inline error.
  void _applyPort(String value) {
    final port = int.tryParse(value.trim());
    if (port == null || port < _kMinPort || port > _kMaxPort) {
      setState(() {
        _portError = 'Port must be a number between $_kMinPort and $_kMaxPort.';
      });
      return;
    }
    setState(() => _portError = null);
    unawaited(ref.read(serverConfigProvider.notifier).setPort(port));
  }

  Future<void> _restart() async {
    _applyHost(_host.text);
    _applyPort(_port.text);
    if (_portError != null) return;
    await ref.read(desktopControllerProvider).restart();
  }

  void _reset() {
    _host.text = kDefaultServerHost;
    _port.text = '$kDefaultServerPort';
    setState(() => _portError = null);
    final notifier = ref.read(serverConfigProvider.notifier);
    unawaited(notifier.setHost(kDefaultServerHost));
    unawaited(notifier.setPort(kDefaultServerPort));
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final cfg = ref.watch(serverConfigProvider);
    final modified =
        cfg.host != kDefaultServerHost || cfg.port != kDefaultServerPort;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        ListTile(
          title: const Text('Endpoint'),
          subtitle: const Text(
            'Where the makit server listens. Press Enter to apply. Default: '
            '$kDefaultServerHost:$kDefaultServerPort.',
          ),
          trailing: modified
              ? SettingsResetButton(visible: true, onPressed: _reset)
              : null,
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(24, 0, 24, 8),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: TextField(
                  controller: _host,
                  decoration: const InputDecoration(
                    labelText: 'Host',
                    hintText: kDefaultServerHost,
                    border: OutlineInputBorder(),
                    isDense: true,
                  ),
                  onSubmitted: _applyHost,
                ),
              ),
              const SizedBox(width: 12),
              SizedBox(
                width: 140,
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
                  onSubmitted: _applyPort,
                ),
              ),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(24, 0, 24, 8),
          child: OutlinedButton.icon(
            onPressed: _restart,
            icon: const Icon(Symbols.restart_alt, weight: 200, size: 18),
            label: const Text('Save & restart server'),
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(24, 0, 24, 12),
          child: Text(
            'A running server keeps its current port until restarted.',
            style: TextStyle(color: cs.outline, fontSize: 12),
          ),
        ),
      ],
    );
  }
}

/// Lifecycle: a live status line plus Start / Stop / Restart actions driven by
/// the polled [desktopControllerProvider] (replaces the old daemon header).
class _LifecycleRow extends ConsumerWidget {
  const _LifecycleRow();

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
          leading: Icon(Symbols.circle, fill: 1, size: 12, color: dot),
          title: const Text('Lifecycle'),
          subtitle: Text(label),
          trailing: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (!running)
                FilledButton.icon(
                  onPressed: starting ? null : () => controller.start(),
                  icon: const Icon(Symbols.play_arrow, weight: 200, size: 18),
                  label: const Text('Start'),
                ),
              if (running) ...[
                OutlinedButton.icon(
                  onPressed: () => controller.restart(),
                  icon: const Icon(Symbols.restart_alt, weight: 200, size: 18),
                  label: const Text('Restart'),
                ),
                const SizedBox(width: 8),
                OutlinedButton.icon(
                  onPressed: () => controller.stop(),
                  icon: const Icon(Symbols.stop, weight: 200, size: 18),
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
/// "Copy install command" action (reuses [makitInstallCommand]).
class _CliRow extends ConsumerStatefulWidget {
  const _CliRow();

  @override
  ConsumerState<_CliRow> createState() => _CliRowState();
}

class _CliRowState extends ConsumerState<_CliRow> {
  Future<String?>? _resolved;

  @override
  void initState() {
    super.initState();
    _resolved = ref
        .read(desktopControllerProvider)
        .lifecycle
        .resolver
        .resolve();
  }

  void _copyInstallCommand() {
    unawaited(
      Clipboard.setData(const ClipboardData(text: makitInstallCommand)),
    );
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Install command copied to clipboard')),
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
                  'The makit CLI was not found. Install it to control '
                      'the server from here.');
        return ListTile(
          leading: Icon(Symbols.terminal, weight: 200, color: cs.outline),
          title: const Text('CLI'),
          subtitle: Text(subtitle),
          trailing: IconButton(
            tooltip: 'Copy install command',
            icon: const Icon(Symbols.content_copy, weight: 200, size: 18),
            onPressed: _copyInstallCommand,
          ),
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
      leading: Icon(Symbols.fingerprint, weight: 200, color: cs.outline),
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
              icon: const Icon(Symbols.content_copy, weight: 200, size: 18),
              onPressed: () {
                final messenger = ScaffoldMessenger.of(context);
                unawaited(Clipboard.setData(ClipboardData(text: fingerprint)));
                messenger.showSnackBar(
                  const SnackBar(content: Text('Fingerprint copied')),
                );
              },
            ),
    );
  }

  static String _shorten(String fingerprint) => fingerprint.length <= 24
      ? fingerprint
      : '${fingerprint.substring(0, 24)}…';
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
          leading: Icon(icon, weight: 200, color: cs.outline),
          title: Text(title),
          subtitle: Text(help),
          trailing: Icon(
            expanded ? Symbols.expand_less : Symbols.expand_more,
            weight: 200,
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
    final messenger = ScaffoldMessenger.of(context);
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
        messenger.showSnackBar(
          const SnackBar(content: Text('Device unpaired')),
        );
      } catch (error) {
        messenger.showSnackBar(
          SnackBar(content: Text('Unpair failed: $error')),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final cs = Theme.of(context).colorScheme;
    return ListTile(
      leading: Icon(Symbols.link_off, weight: 200, color: cs.error),
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
