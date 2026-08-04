import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:phosphoricons_flutter/phosphoricons_flutter.dart';

import '../../store/connection.dart';
import '../../app/theme.dart';
import '../../store/store.dart';
import '../../transport/protocol.dart';
import '../../transport/transport.dart';
import 'notification_settings.dart';
import 'appearance_settings.dart';

class SettingsScreen extends ConsumerWidget {
  const SettingsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final conn = ref.watch(connectionProvider);
    final projects = ref.watch(projectsProvider).projects;
    final sessions = ref.watch(sessionsProvider).sessions;
    final server = conn.server;
    final cs = Theme.of(context).colorScheme;
    final (statusLabel, statusColor) = _status(conn, cs);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Settings'),
        leading: IconButton(
          icon: const Icon(PhosphorIconsLight.arrowLeft),
          onPressed: () => context.go('/'),
        ),
      ),
      body: ListView(
        children: [
          const _SectionHeader('Connection'),
          ListTile(
            leading: _leadingIcon(
              PhosphorIconsFill.circle,
              size: 14,
              color: statusColor,
            ),
            title: const Text('Status'),
            subtitle: Text(
              conn.lastError == null
                  ? statusLabel
                  : '$statusLabel · ${conn.lastError}',
            ),
          ),
          ListTile(
            leading: _leadingIcon(PhosphorIconsLight.hardDrives),
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
              leading: _leadingIcon(PhosphorIconsLight.fingerprint),
              title: const Text('Fingerprint'),
              subtitle: Text(
                '${server.fingerprint.substring(0, 24)}…',
                style: const TextStyle(
                  fontFeatures: [FontFeature.tabularFigures()],
                ),
              ),
              trailing: const Icon(PhosphorIconsLight.copy, size: 18),
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
              leading: _leadingIcon(PhosphorIconsLight.arrowClockwise),
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
            leading: _leadingIcon(PhosphorIconsLight.folder),
            title: const Text('Projects & sessions'),
            subtitle: Text(
              '${projects.length} project${projects.length == 1 ? '' : 's'} · '
              '${sessions.length} session${sessions.length == 1 ? '' : 's'}',
            ),
            trailing: const Icon(PhosphorIconsLight.caretRight),
            onTap: () => context.go('/'),
          ),

          const Divider(),
          const _SectionHeader('Appearance'),
          const AppearanceSettingsSection(),

          const Divider(),
          const _SectionHeader('Notifications'),
          const NotificationSettingsSection(),

          const Divider(),
          const _SectionHeader('Coming soon'),
          ListTile(
            enabled: false,
            leading: _leadingIcon(PhosphorIconsLight.slidersHorizontal),
            title: const Text('Notification preferences'),
            subtitle: const Text('Per-type mute · default approval policy'),
          ),

          const Divider(),
          const _SectionHeader('About'),
          ListTile(
            leading: _leadingIcon(PhosphorIconsLight.bug),
            title: const Text('Diagnostics'),
            subtitle: const Text('View, copy, and send app logs'),
            trailing: const Icon(PhosphorIconsLight.caretRight),
            onTap: () => context.go('/diagnostics'),
          ),
          ListTile(
            leading: _leadingIcon(PhosphorIconsLight.info),
            title: const Text('Makit'),
            subtitle: const Text('Mobile client · Protocol v$protocolVersion'),
          ),

          const Divider(),
          ListTile(
            leading: _leadingIcon(
              conn.useFake ? PhosphorIconsLight.x : PhosphorIconsLight.signOut,
              color: cs.error,
            ),
            title: Text(
              conn.useFake ? 'Exit demo' : 'Unpair this device',
              style: TextStyle(color: cs.error),
            ),
            subtitle: conn.useFake
                ? const Text('Leave fake data and return to pairing')
                : null,
            onTap: () async {
              await ref.read(connectionControllerProvider.notifier).unpair();
              if (context.mounted) context.go('/pair');
            },
          ),
        ],
      ),
    );
  }

  (String, Color) _status(MakitConnState conn, ColorScheme cs) {
    if (conn.useFake) return ('Dev fake server', kStatusWarning);
    return switch (conn.wsState) {
      WsState.connected => ('Connected', cs.primary),
      WsState.connecting => ('Connecting…', cs.primary),
      WsState.reconnecting => ('Reconnecting…', kStatusWarning),
      WsState.idle => ('Idle', cs.outline),
      WsState.closed => ('Offline', cs.error),
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
        style: Theme.of(context).textTheme.labelMedium?.copyWith(
          color: cs.primary,
          fontWeight: FontWeight.w700,
          letterSpacing: 0.8,
        ),
      ),
    );
  }
}
