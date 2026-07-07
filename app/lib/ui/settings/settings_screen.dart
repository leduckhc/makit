import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../store/connection.dart';
import '../../store/store.dart';
import '../../transport/protocol.dart';
import '../../transport/transport.dart';

class SettingsScreen extends ConsumerWidget {
  const SettingsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final conn = ref.watch(connectionProvider);
    final projects = ref.watch(projectsProvider).projects;
    final sessions = ref.watch(sessionsProvider).sessions;
    final server = conn.server;
    final (statusLabel, statusColor) = _status(conn);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Settings'),
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          onPressed: () => context.go('/'),
        ),
      ),
      body: ListView(
        children: [
          const _SectionHeader('Connection'),
          ListTile(
            leading: _leadingIcon(Icons.circle, size: 14, color: statusColor),
            title: const Text('Status'),
            subtitle: Text(
              conn.lastError == null
                  ? statusLabel
                  : '$statusLabel · ${conn.lastError}',
            ),
          ),
          ListTile(
            leading: _leadingIcon(Icons.dns_outlined),
            title: const Text('Server'),
            subtitle: Text(
              conn.useFake
                  ? 'Dev fake server (in-process)'
                  : server == null
                  ? 'Not paired'
                  : '${server.host}:${server.port}'
                        '${server.mdnsName == null ? '' : ' · mDNS'}',
            ),
          ),
          if (server != null)
            ListTile(
              leading: _leadingIcon(Icons.fingerprint),
              title: const Text('Fingerprint'),
              subtitle: Text(
                '${server.fingerprint.substring(0, 24)}…',
                style: const TextStyle(
                  fontFeatures: [FontFeature.tabularFigures()],
                ),
              ),
              trailing: const Icon(Icons.copy, size: 18),
              onTap: () async {
                final messenger = ScaffoldMessenger.of(context);
                await Clipboard.setData(
                  ClipboardData(text: server.fingerprint),
                );
                messenger.showSnackBar(
                  const SnackBar(content: Text('Fingerprint copied')),
                );
              },
            ),
          if (server != null && !conn.useFake)
            ListTile(
              leading: _leadingIcon(Icons.refresh),
              title: const Text('Reconnect'),
              subtitle: const Text('Re-establish the connection'),
              onTap: () async {
                final messenger = ScaffoldMessenger.of(context);
                await ref
                    .read(connectionControllerProvider.notifier)
                    .reconnect();
                messenger.showSnackBar(
                  const SnackBar(content: Text('Reconnecting…')),
                );
              },
            ),

          const Divider(),
          const _SectionHeader('Workspace'),
          ListTile(
            leading: _leadingIcon(Icons.folder_outlined),
            title: const Text('Projects & sessions'),
            subtitle: Text(
              '${projects.length} project${projects.length == 1 ? '' : 's'} · '
              '${sessions.length} session${sessions.length == 1 ? '' : 's'}',
            ),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => context.go('/'),
          ),

          const Divider(),
          const _SectionHeader('Coming soon'),
          ListTile(
            enabled: false,
            leading: _leadingIcon(Icons.notifications_outlined),
            title: const Text('Notifications'),
            subtitle: const Text(
              'Awaiting input · Approval · Long task · Errors',
            ),
          ),
          ListTile(
            enabled: false,
            leading: _leadingIcon(Icons.security_outlined),
            title: const Text('Default approval policy'),
            subtitle: const Text('Ask on risky'),
          ),

          const Divider(),
          const _SectionHeader('About'),
          ListTile(
            leading: _leadingIcon(Icons.info_outline),
            title: const Text('pino'),
            subtitle: const Text('Mobile client · Protocol v$protocolVersion'),
          ),

          const Divider(),
          ListTile(
            leading: _leadingIcon(Icons.logout, color: Colors.red),
            title: const Text(
              'Unpair this device',
              style: TextStyle(color: Colors.red),
            ),
            onTap: () async {
              await ref.read(connectionControllerProvider.notifier).unpair();
              if (context.mounted) context.go('/pair');
            },
          ),
        ],
      ),
    );
  }

  (String, Color) _status(PinoConnState conn) {
    if (conn.useFake) return ('Dev fake server', Colors.orange);
    return switch (conn.wsState) {
      WsState.connected => ('Connected', Colors.green),
      WsState.connecting => ('Connecting…', Colors.blue),
      WsState.reconnecting => ('Reconnecting…', Colors.orange),
      WsState.idle => ('Idle', Colors.grey),
      WsState.closed => ('Offline', Colors.red),
    };
  }
}

/// Leading icon for a settings [ListTile].
///
/// ListTile left-aligns its `leading` widget and sizes the leading column to
/// the icon's own width, so a small icon (e.g. the 14px Status dot) ends up
/// shifted left of the 24px icons. Wrapping in a fixed 24px [Center]ed box
/// keeps every row's icon centered in the same column.
Widget _leadingIcon(IconData icon, {double size = 24.0, Color? color}) =>
    SizedBox(
      width: 24,
      child: Center(
        child: Icon(icon, size: size, color: color),
      ),
    );

class _SectionHeader extends StatelessWidget {
  const _SectionHeader(this.label);
  final String label;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
      child: Text(
        label.toUpperCase(),
        style: TextStyle(
          color: cs.primary,
          fontSize: 12,
          fontWeight: FontWeight.w700,
          letterSpacing: 0.8,
        ),
      ),
    );
  }
}
