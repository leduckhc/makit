/// Running-sessions list for the desktop control app.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../control/control_contract.dart';
import 'providers.dart';
import 'time_format.dart';

/// Lists sessions known to the daemon with a colored status chip each.
///
/// Reads the [ControlClient] from [controlClientProvider], rendering loading,
/// error, empty, and data states. Tapping a tile logs the target route; real
/// navigation is wired in Phase 4.
class SessionsScreen extends ConsumerStatefulWidget {
  /// Creates the sessions list.
  const SessionsScreen({super.key});

  @override
  ConsumerState<SessionsScreen> createState() => _SessionsScreenState();
}

class _SessionsScreenState extends ConsumerState<SessionsScreen> {
  late Future<List<SessionDto>> _future;

  @override
  void initState() {
    super.initState();
    _future = ref.read(controlClientProvider).sessionsList();
  }

  void _refresh() {
    setState(() {
      _future = ref.read(controlClientProvider).sessionsList();
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Sessions'),
        actions: [
          IconButton(
            tooltip: 'Refresh',
            icon: const Icon(Icons.refresh),
            onPressed: _refresh,
          ),
        ],
      ),
      body: FutureBuilder<List<SessionDto>>(
        future: _future,
        builder: (context, snapshot) {
          if (snapshot.connectionState == ConnectionState.waiting) {
            return const Center(child: CircularProgressIndicator());
          }
          if (snapshot.hasError) {
            return _SessionsError(onRetry: _refresh, error: snapshot.error);
          }
          final sessions = snapshot.requireData;
          if (sessions.isEmpty) {
            return const Center(child: Text('No running sessions'));
          }
          return ListView.builder(
            itemCount: sessions.length,
            itemBuilder: (context, i) => _SessionTile(session: sessions[i]),
          );
        },
      ),
    );
  }
}

class _SessionTile extends StatelessWidget {
  const _SessionTile({required this.session});

  final SessionDto session;

  @override
  Widget build(BuildContext context) {
    return ListTile(
      title: Text(session.title),
      subtitle: Text(
        '${session.projectId} · ${formatRelative(session.lastActivityAt)}',
      ),
      trailing: _StatusChip(status: session.status),
      // Phase 4 wires real navigation; for now surface the intended route.
      onTap: () => debugPrint('/sessions/${session.id}'),
    );
  }
}

/// A small colored chip conveying a session's lifecycle state.
class _StatusChip extends StatelessWidget {
  const _StatusChip({required this.status});

  final String status;

  @override
  Widget build(BuildContext context) {
    final color = switch (status) {
      'running' => Colors.green,
      'error' => Colors.red,
      'done' => Colors.grey,
      _ => Colors.grey,
    };
    return Chip(
      label: Text(status),
      backgroundColor: color.withValues(alpha: 0.15),
      side: BorderSide(color: color),
      labelStyle: TextStyle(color: color),
      visualDensity: VisualDensity.compact,
    );
  }
}

class _SessionsError extends StatelessWidget {
  const _SessionsError({required this.onRetry, required this.error});

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
            'Could not load sessions',
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
