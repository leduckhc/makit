/// Paired-devices list for the desktop control app.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:phosphoricons_flutter/phosphoricons_flutter.dart';

import '../../control/control_contract.dart';
import 'providers.dart';
import 'time_format.dart';

/// Lists devices paired with the daemon and lets the operator revoke them.
/// Embedded inline under a disclosure row in the Server & Devices settings
/// section (no Scaffold/AppBar of its own).
///
/// Reads the [ControlClient] from [controlClientProvider], rendering loading,
/// error, empty, and data states, and re-fetches after each revoke.
class DevicesScreen extends ConsumerStatefulWidget {
  /// Creates the devices list.
  const DevicesScreen({super.key});

  /// How often the list re-queries the daemon so the connected dot reflects
  /// devices coming online / going offline without a manual refresh.
  static const Duration pollInterval = Duration(seconds: 4);

  @override
  ConsumerState<DevicesScreen> createState() => _DevicesScreenState();
}

class _DevicesScreenState extends ConsumerState<DevicesScreen> {
  List<DeviceInfo>? _devices;
  Object? _error;
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _load();
    _timer = Timer.periodic(DevicesScreen.pollInterval, (_) => _load());
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  /// Fetches the current device list. Keeps the last good list visible on a
  /// transient poll error (only surfaces the error state before any data
  /// loads) and never flashes the spinner after the first load.
  Future<void> _load() async {
    try {
      final devices = await ref.read(controlClientProvider).devicesList();
      if (!mounted) return;
      setState(() {
        _devices = devices;
        _error = null;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() => _error = error);
    }
  }

  Future<void> _revoke(String id) async {
    final messenger = ScaffoldMessenger.of(context);
    try {
      await ref.read(controlClientProvider).devicesRevoke(id);
      await _load();
    } catch (error) {
      messenger.showSnackBar(SnackBar(content: Text('Revoke failed: $error')));
    }
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Align(
          alignment: Alignment.centerRight,
          child: IconButton(
            tooltip: 'Refresh',
            icon: const Icon(PhosphorIconsLight.arrowClockwise, size: 18),
            onPressed: _load,
          ),
        ),
        _buildBody(),
      ],
    );
  }

  Widget _buildBody() {
    // First load: nothing fetched yet.
    if (_devices == null && _error == null) {
      return const Padding(
        padding: EdgeInsets.all(24),
        child: Center(child: CircularProgressIndicator()),
      );
    }
    // Errored before any data arrived.
    if (_devices == null) {
      return _DevicesError(onRetry: _load, error: _error);
    }
    final devices = _devices!;
    if (devices.isEmpty) {
      return const Padding(
        padding: EdgeInsets.all(24),
        child: Center(child: Text('No paired devices')),
      );
    }
    return ListView.builder(
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      itemCount: devices.length,
      itemBuilder: (context, i) => _DeviceTile(
        device: devices[i],
        onRevoke: () => _revoke(devices[i].id),
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
        PhosphorIconsFill.circle,
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
          Icon(PhosphorIconsLight.warningCircle, color: cs.error, size: 40),
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
