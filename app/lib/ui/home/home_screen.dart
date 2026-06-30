import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../store/models.dart';
import '../../store/store.dart';
import '../widgets/connection_chip.dart';

class HomeScreen extends ConsumerWidget {
  const HomeScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final projects = ref.watch(projectsProvider).projects;
    final sessions = ref.watch(sessionsProvider);

    return Scaffold(
      appBar: AppBar(
        title: const Text('pino'),
        actions: [
          const ConnectionChip(),
          if (projects.isNotEmpty)
            IconButton(
              icon: const Icon(Icons.add),
              tooltip: 'New session',
              onPressed: () => _spawn(context, ref, projects),
            ),
          IconButton(
            icon: const Icon(Icons.settings_outlined),
            onPressed: () => context.go('/settings'),
          ),
        ],
      ),
      body: projects.isEmpty
          ? const _EmptyState()
          : Column(
              children: [
                _GlobalRunningStrip(sessions: sessions.sessions),
                Expanded(
                  child: ListView.builder(
                    padding: const EdgeInsets.symmetric(vertical: 8),
                    itemCount: projects.length,
                    itemBuilder: (context, i) => _ProjectSection(
                      project: projects[i],
                      sessions: sessions.forProject(projects[i].id),
                    ),
                  ),
                ),
              ],
            ),
      floatingActionButton: projects.isEmpty
          ? null
          : FloatingActionButton.extended(
              onPressed: () => _spawn(context, ref, projects),
              icon: const Icon(Icons.add),
              label: const Text('New session'),
            ),
    );
  }

  Future<void> _spawn(
    BuildContext context,
    WidgetRef ref,
    List<Project> projects,
  ) async {
    // Pick project: single → use it directly; multi → bottom sheet.
    Project? target;
    if (projects.length == 1) {
      target = projects.first;
    } else {
      target = await showModalBottomSheet<Project>(
        context: context,
        builder: (ctx) => SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Padding(
                padding: EdgeInsets.fromLTRB(16, 16, 16, 8),
                child: Text(
                  'Spawn new session in…',
                  style: TextStyle(fontWeight: FontWeight.w600),
                ),
              ),
              for (final p in projects)
                ListTile(
                  leading: const Icon(Icons.folder_outlined),
                  title: Text(p.name),
                  subtitle: Text(p.path, maxLines: 1, overflow: TextOverflow.ellipsis),
                  onTap: () => Navigator.pop(ctx, p),
                ),
              const SizedBox(height: 8),
            ],
          ),
        ),
      );
    }
    if (target == null || !context.mounted) return;

    final messenger = ScaffoldMessenger.of(context);
    try {
      final newId = await ref
          .read(storeControllerProvider.notifier)
          .spawnSession(target.id);
      if (!context.mounted) return;
      context.go('/session/$newId');
    } catch (e) {
      messenger.showSnackBar(
        SnackBar(content: Text('Could not spawn session: $e')),
      );
    }
  }
}

class _EmptyState extends StatelessWidget {
  const _EmptyState();

  @override
  Widget build(BuildContext context) {
    return const Center(
      child: Padding(
        padding: EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.folder_open, size: 64),
            SizedBox(height: 12),
            Text(
              'No projects yet.\nStart an agent on the desktop server and it will appear here.',
              textAlign: TextAlign.center,
            ),
          ],
        ),
      ),
    );
  }
}

class _ProjectSection extends StatelessWidget {
  const _ProjectSection({required this.project, required this.sessions});
  final Project project;
  final List<Session> sessions;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 20, 20, 4),
          child: Row(
            children: [
              const Icon(Icons.folder_outlined, size: 18),
              const SizedBox(width: 8),
              Text(project.name, style: Theme.of(context).textTheme.titleMedium),
              const SizedBox(width: 8),
              if (_workingCount(sessions) > 0)
                _WorkingBadge(count: _workingCount(sessions)),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  project.path,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context)
                      .textTheme
                      .bodySmall
                      ?.copyWith(color: Theme.of(context).colorScheme.outline),
                ),
              ),
            ],
          ),
        ),
        ...sessions.map((s) => _SessionTile(session: s)),
        if (sessions.isEmpty)
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 4, 20, 8),
            child: Text(
              'No active sessions.',
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ),
        const Divider(height: 1),
      ],
    );
  }
}

class _SessionTile extends StatelessWidget {
  const _SessionTile({required this.session});
  final Session session;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return ListTile(
      onTap: () => context.go('/session/${session.id}'),
      leading: CircleAvatar(
        backgroundColor: cs.secondaryContainer,
        child: Text(session.agent.substring(0, 1).toUpperCase()),
      ),
      title: Row(
        children: [
          Expanded(child: Text(session.title, overflow: TextOverflow.ellipsis)),
          _StatusChip(status: session.status),
        ],
      ),
      subtitle: Text(
        session.lastPreview,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
    );
  }
}

class _StatusChip extends StatelessWidget {
  const _StatusChip({required this.status});
  final SessionStatus status;

  @override
  Widget build(BuildContext context) {
    final (label, color) = switch (status) {
      SessionStatus.idle => ('idle', Colors.grey),
      SessionStatus.running => ('running', Colors.blue),
      SessionStatus.awaitingInput => ('you', Colors.orange),
      SessionStatus.awaitingApproval => ('approve', Colors.deepOrange),
      SessionStatus.error => ('error', Colors.red),
      SessionStatus.exited => ('exited', Colors.grey),
    };
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.15),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Text(label, style: TextStyle(color: color, fontSize: 11, fontWeight: FontWeight.w600)),
    );
  }
}

int _workingCount(List<Session> sessions) => sessions
    .where((s) =>
        s.status == SessionStatus.running ||
        s.status == SessionStatus.awaitingInput ||
        s.status == SessionStatus.awaitingApproval)
    .length;

class _WorkingBadge extends StatefulWidget {
  const _WorkingBadge({required this.count});
  final int count;

  @override
  State<_WorkingBadge> createState() => _WorkingBadgeState();
}

class _WorkingBadgeState extends State<_WorkingBadge>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ctl = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 900),
  )..repeat(reverse: true);

  @override
  void dispose() {
    _ctl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        color: cs.primary.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          FadeTransition(
            opacity: Tween(begin: 0.35, end: 1.0).animate(_ctl),
            child: Container(
              width: 6,
              height: 6,
              decoration: BoxDecoration(color: cs.primary, shape: BoxShape.circle),
            ),
          ),
          const SizedBox(width: 6),
          Text(
            '${widget.count} working',
            style: TextStyle(
              color: cs.primary,
              fontSize: 11,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }
}

class _GlobalRunningStrip extends StatelessWidget {
  const _GlobalRunningStrip({required this.sessions});
  final List<Session> sessions;

  @override
  Widget build(BuildContext context) {
    final working = sessions.where((s) =>
        s.status == SessionStatus.running ||
        s.status == SessionStatus.awaitingInput ||
        s.status == SessionStatus.awaitingApproval).toList();
    if (working.isEmpty) return const SizedBox.shrink();

    final cs = Theme.of(context).colorScheme;
    return Container(
      margin: const EdgeInsets.fromLTRB(16, 12, 16, 4),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: cs.primaryContainer.withValues(alpha: 0.5),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        children: [
          Icon(Icons.bolt, size: 16, color: cs.onPrimaryContainer),
          const SizedBox(width: 6),
          Expanded(
            child: Text(
              '${working.length} running · ${_byAgent(working)}',
              style: TextStyle(
                color: cs.onPrimaryContainer,
                fontSize: 12,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ],
      ),
    );
  }

  String _byAgent(List<Session> ws) {
    final counts = <String, int>{};
    for (final s in ws) {
      counts[s.agent] = (counts[s.agent] ?? 0) + 1;
    }
    final parts = counts.entries.map((e) => '${e.value} ${e.key}').toList();
    return parts.join(', ');
  }
}
