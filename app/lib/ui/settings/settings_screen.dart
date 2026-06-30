import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../store/connection.dart';

class SettingsScreen extends ConsumerWidget {
  const SettingsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final conn = ref.watch(connectionProvider);
    return Scaffold(
      appBar: AppBar(
        title: const Text('Settings'),
        leading: IconButton(icon: const Icon(Icons.arrow_back), onPressed: () => context.go('/')),
      ),
      body: ListView(
        children: [
          const ListTile(
            leading: Icon(Icons.devices_other),
            title: Text('Paired devices'),
            subtitle: Text('Manage which devices can connect to your server'),
          ),
          ListTile(
            leading: const Icon(Icons.dns_outlined),
            title: const Text('Server'),
            subtitle: Text(conn.useFake ? 'Dev fake server (in-process)' : conn.server?.host ?? 'not paired'),
          ),
          const ListTile(
            leading: Icon(Icons.notifications_outlined),
            title: Text('Notifications'),
            subtitle: Text('Awaiting input · Approval · Long task · Errors'),
          ),
          const ListTile(
            leading: Icon(Icons.security_outlined),
            title: Text('Default approval policy'),
            subtitle: Text('Ask on risky'),
          ),
          const Divider(),
          ListTile(
            leading: const Icon(Icons.logout, color: Colors.red),
            title: const Text('Unpair this device', style: TextStyle(color: Colors.red)),
            onTap: () async {
              await ref.read(connectionControllerProvider.notifier).unpair();
              if (context.mounted) context.go('/pair');
            },
          ),
        ],
      ),
    );
  }
}
