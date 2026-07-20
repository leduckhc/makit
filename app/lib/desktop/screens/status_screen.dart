/// Daemon status dashboard for the desktop control app.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:phosphoricons_flutter/phosphoricons_flutter.dart';

import '../../control/control_contract.dart';
import 'providers.dart';
import 'time_format.dart';

/// Shows a live snapshot of daemon status with a manual refresh action.
///
/// Reads the [ControlClient] from [controlClientProvider] and re-fetches on
/// demand, rendering distinct loading, error, and data states.
class StatusScreen extends ConsumerStatefulWidget {
  /// Creates the status dashboard.
  const StatusScreen({super.key});

  @override
  ConsumerState<StatusScreen> createState() => _StatusScreenState();
}

class _StatusScreenState extends ConsumerState<StatusScreen> {
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
    return Scaffold(
      appBar: AppBar(
        title: const Text('Status'),
        actions: [
          IconButton(
            tooltip: 'Refresh',
            icon: const Icon(PhosphorIconsLight.arrowClockwise),
            onPressed: _refresh,
          ),
        ],
      ),
      body: FutureBuilder<StatusData>(
        future: _future,
        builder: (context, snapshot) {
          if (snapshot.connectionState == ConnectionState.waiting) {
            return const Center(child: CircularProgressIndicator());
          }
          if (snapshot.hasError) {
            return _StatusError(onRetry: _refresh, error: snapshot.error);
          }
          return _StatusBody(status: snapshot.requireData);
        },
      ),
    );
  }
}

class _StatusError extends StatelessWidget {
  const _StatusError({required this.onRetry, required this.error});

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
            'Could not load status',
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

class _StatusBody extends StatelessWidget {
  const _StatusBody({required this.status});

  final StatusData status;

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Card(
          child: Column(
            children: [
              _StatusRow(label: 'PID', value: '${status.pid}'),
              _StatusRow(label: 'Uptime', value: formatUptime(status.uptimeMs)),
              _StatusRow(
                label: 'Address',
                value: '${status.host}:${status.port}',
              ),
              _StatusRow(
                label: 'Fingerprint',
                value: status.fingerprint,
                monospace: true,
                selectable: true,
              ),
              _StatusRow(label: 'Advertise host', value: status.advertiseHost),
              _StatusRow(
                label: 'Paired devices',
                value: '${status.pairedDevices}',
              ),
              _StatusRow(
                label: 'Running sessions',
                value: '${status.runningSessions}',
              ),
              _StatusRow(label: 'Version', value: status.version),
            ],
          ),
        ),
      ],
    );
  }
}

class _StatusRow extends StatelessWidget {
  const _StatusRow({
    required this.label,
    required this.value,
    this.monospace = false,
    this.selectable = false,
  });

  final String label;
  final String value;
  final bool monospace;
  final bool selectable;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final valueStyle = monospace
        ? theme.textTheme.bodyMedium?.copyWith(fontFamily: 'monospace')
        : theme.textTheme.bodyMedium;
    return ListTile(
      title: Text(label, style: theme.textTheme.labelLarge),
      trailing: selectable
          ? SelectableText(value, style: valueStyle)
          : Text(value, style: valueStyle),
    );
  }
}
