import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../notifications/notification_observer.dart';
import '../../pairing/readiness.dart';
import '../../store/connection.dart';
import '../../transport/transport.dart';

/// GitHub docs base for in-app links (opens in browser).
const kNotificationsDocsUrl =
    'https://github.com/leduckhc/makit/blob/main/docs/NOTIFICATIONS.md';
const kPushSetupDocsUrl =
    'https://github.com/leduckhc/makit/blob/main/docs/PUSH.md';

/// Settings rows for notification permission and background-wake status.
class NotificationSettingsSection extends ConsumerWidget {
  const NotificationSettingsSection({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final conn = ref.watch(connectionProvider);
    final permissionAsync = ref.watch(_notificationPermissionProvider);

    return permissionAsync.when(
      data: (permission) => Column(
        children: [
          ListTile(
            leading: _leadingIcon(Icons.notifications_active_outlined),
            title: const Text('Local notifications'),
            subtitle: Text(_permissionLabel(permission)),
            trailing: permission == NotificationPermission.denied
                ? TextButton(
                    onPressed: () => _openOsSettings(),
                    child: const Text('Settings'),
                  )
                : permission == NotificationPermission.notDetermined
                ? TextButton(
                    onPressed: () => _requestPermission(ref),
                    child: const Text('Enable'),
                  )
                : null,
          ),
          ListTile(
            leading: _leadingIcon(Icons.cloud_upload_outlined),
            title: const Text('Background wake'),
            subtitle: Text(_wakeLabel(conn, permission)),
            trailing: IconButton(
              tooltip: 'Setup guide',
              icon: const Icon(Icons.help_outline, size: 20),
              onPressed: () => _openUrl(kPushSetupDocsUrl),
            ),
          ),
          ListTile(
            leading: _leadingIcon(Icons.menu_book_outlined),
            title: const Text('Notification guide'),
            subtitle: const Text('On-device checklists & troubleshooting'),
            trailing: const Icon(Icons.open_in_new, size: 18),
            onTap: () => _openUrl(kNotificationsDocsUrl),
          ),
        ],
      ),
      loading: () => const ListTile(
        leading: SizedBox(
          width: 24,
          height: 24,
          child: CircularProgressIndicator(strokeWidth: 2),
        ),
        title: Text('Loading notification status…'),
      ),
      error: (_, _) => ListTile(
        leading: _leadingIcon(Icons.notifications_off_outlined),
        title: const Text('Notifications'),
        subtitle: const Text('Status unavailable'),
      ),
    );
  }

  static String _permissionLabel(NotificationPermission p) => switch (p) {
    NotificationPermission.granted => 'Enabled — status alerts & lock-screen actions',
    NotificationPermission.denied =>
      'Disabled in iOS Settings — enable for alerts',
    NotificationPermission.notDetermined => 'Not yet enabled — tap Enable',
    NotificationPermission.unsupported => 'Not available on this platform',
  };

  static String _wakeLabel(MakitConnState conn, NotificationPermission p) {
    if (p != NotificationPermission.granted) {
      return 'Requires local notification permission';
    }
    if (conn.wsState != WsState.connected) {
      return 'Connect to register for background wake';
    }
    if (conn.pushRegistered) {
      return 'Registered — force-quit wake via APNs when server has push.json';
    }
    return 'Not registered — configure APNs on the server (see guide)';
  }

  Future<void> _requestPermission(WidgetRef ref) async {
    await ref.read(notificationServiceProvider).requestPermission();
    ref.invalidate(_notificationPermissionProvider);
  }

  Future<void> _openOsSettings() async {
    final uri = Uri.parse('app-settings:');
    if (await canLaunchUrl(uri)) {
      await launchUrl(uri);
    }
  }

  Future<void> _openUrl(String url) async {
    final uri = Uri.parse(url);
    if (await canLaunchUrl(uri)) {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    }
  }
}

final _notificationPermissionProvider = FutureProvider<NotificationPermission>(
  (ref) => ref.watch(notificationServiceProvider).permissionStatus(),
);

Widget _leadingIcon(IconData icon, {double size = 24.0, Color? color}) =>
    SizedBox(
      width: 24,
      child: Center(child: Icon(icon, size: size, color: color)),
    );
