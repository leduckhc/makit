/// Paired-devices list for the desktop control app.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../control/control_contract.dart';
import 'providers.dart';
import 'time_format.dart';

/// Lists devices paired with the daemon and lets the operator revoke them.
///
/// Reads the [ControlClient] from [controlClientProvider], rendering loading,
/// error, empty, and data states, and re-fetches after each revoke.
class DevicesScreen extends ConsumerStatefulWidget {
  /// Creates the devices list.
  const DevicesScreen({super.key});

  @override
  ConsumerState<DevicesScreen> createState() => _DevicesScreenState();
}

class _DevicesScreenState extends ConsumerState<DevicesScreen> {
  late Future<List<DeviceInfo>> _future;

  @override
  void initState() {
    super.initState();
    _future = ref.read(controlClientProvider).devicesList();
  }

  void _refresh() {
    setState(() {
      _future = ref.read(controlClientProvider).devicesList();
    });
  }

  Future<void> _revoke(String id) async {
    final messenger = ScaffoldMessenger.of(context);
    try {
      await ref.read(controlClientProvider).devicesRevoke(id);
      _refresh();
    } catch (error) {
      messenger.showSnackBar(SnackBar(content: Text('Revoke failed: $error')));
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Devices'),
        actions: [
          IconButton(
            tooltip: 'Refresh',
            icon: const Icon(Icons.refresh),
            onPressed: _refresh,
          ),
        ],
      ),
      body: FutureBuilder<List<DeviceInfo>>(
        future: _future,
        builder: (context, snapshot) {
          if (snapshot.connectionState == ConnectionState.waiting) {
            return const Center(child: CircularProgressIndicator());
          }
          if (snapshot.hasError) {
            return _DevicesError(onRetry: _refresh, error: snapshot.error);
          }
          final devices = snapshot.requireData;
          if (devices.isEmpty) {
            return const Center(child: Text('No paired devices'));
          }
          return ListView.builder(
            itemCount: devices.length,
            itemBuilder: (context, i) => _DeviceTile(
              device: devices[i],
              onRevoke: () => _revoke(devices[i].id),
            ),
          );
        },
      ),
    );
  }
}

class _DeviceTile extends StatelessWidget {
  const _DeviceTile({required this.device, required this.onRevoke});

  final DeviceInfo device;
  final VoidCallback onRevoke;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return ListTile(
      leading: Icon(
        Icons.circle,
        size: 12,
        color: device.connected ? Colors.green : cs.outline,
      ),
      title: Text(device.label),
      subtitle: Text(
        'Paired ${formatRelative(device.pairedAt)} · '
        'last seen ${formatRelative(device.lastSeenAt)}',
      ),
      trailing: OutlinedButton(
        onPressed: onRevoke,
        child: const Text('Revoke'),
      ),
    );
  }
}

class _DevicesError extends StatelessWidget {
  const _DevicesError({required this.onRetry, required this.error});

  final VoidCallback onRetry;
  final Object? error;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.error_outline, color: cs.error, size: 40),
          const SizedBox(height: 12),
          Text(
            'Could not load devices',
            style: Theme.of(context).textTheme.titleMedium,
          ),
          const SizedBox(height: 4),
          Text('$error', style: Theme.of(context).textTheme.bodySmall),
          const SizedBox(height: 16),
          FilledButton.tonal(onPressed: onRetry, child: const Text('Retry')),
        ],
      ),
    );
  }
}
