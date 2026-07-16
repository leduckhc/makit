/// Running-sessions list for the desktop control app.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../control/control_contract.dart';
import '../../store/models.dart' show SessionStatus;
import 'providers.dart';
import 'time_format.dart';

/// Running-sessions list, embedded inline under a disclosure row in the
/// Server & Devices settings section (no Scaffold/AppBar of its own).
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
  late Future<List<ControlSession>> _future;

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

  /// Only surface sessions that are actually open/active — hide idle and
  /// exited ones, which are just noise in the control surface.
  static bool _isActive(ControlSession s) =>
      s.status != SessionStatus.idle && s.status != SessionStatus.exited;

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
            icon: const Icon(Icons.refresh, size: 18),
            onPressed: _refresh,
          ),
        ),
        FutureBuilder<List<ControlSession>>(
          future: _future,
          builder: (context, snapshot) {
            if (snapshot.connectionState == ConnectionState.waiting) {
              return const Padding(
                padding: EdgeInsets.all(24),
                child: Center(child: CircularProgressIndicator()),
              );
            }
            if (snapshot.hasError) {
              return _SessionsError(onRetry: _refresh, error: snapshot.error);
            }
            final sessions = snapshot.requireData.where(_isActive).toList();
            if (sessions.isEmpty) {
              return const Padding(
                padding: EdgeInsets.all(24),
                child: Center(child: Text('No running sessions')),
              );
            }
            return ListView.builder(
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              itemCount: sessions.length,
              itemBuilder: (context, i) => _SessionTile(session: sessions[i]),
            );
          },
        ),
      ],
    );
  }
}

class _SessionTile extends StatelessWidget {
  const _SessionTile({required this.session});

  final ControlSession session;

  @override
  Widget build(BuildContext context) {
    return ListTile(
      title: Text(session.title),
      subtitle: Text(
        '${session.projectId} · ${formatRelative(session.lastActivityAt)}',
      ),
      trailing: _StatusChip(status: session.status.name),
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
