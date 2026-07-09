import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:flutter_svg/flutter_svg.dart';

import '../../store/models.dart';
import '../../store/store.dart';
import '../../app/theme.dart' show kMakitAccent;
import '../project/folder_browser.dart';
import '../widgets/connection_chip.dart';
import '../widgets/glass.dart';
import '../widgets/searchable_list_sheet.dart';

/// Brand green accent used for running/active glass affordances (shared token).
const _kBrandBlue = kMakitAccent;

class HomeScreen extends ConsumerWidget {
  const HomeScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final projects = ref.watch(projectsProvider).projects;
    final sessions = ref.watch(sessionsProvider);

    return Scaffold(
      appBar: AppBar(
        title: const Text('makit'),
        actions: [
          const ConnectionChip(),
          IconButton(
            icon: const Icon(Icons.create_new_folder_outlined),
            tooltip: 'Add project',
            onPressed: () => showFolderBrowser(context),
          ),
          IconButton(
            icon: const Icon(Icons.settings_outlined),
            onPressed: () => context.go('/settings'),
          ),
        ],
      ),
      body: projects.isEmpty
          ? _EmptyState(onAdd: () => showFolderBrowser(context))
          : ListView.builder(
              padding: const EdgeInsets.symmetric(vertical: 8),
              itemCount: projects.length,
              itemBuilder: (context, i) => _ProjectSection(
                project: projects[i],
                sessions: sessions.forProject(projects[i].id),
              ),
            ),
    );
  }
}

class _EmptyState extends StatelessWidget {
  const _EmptyState({required this.onAdd});
  final VoidCallback onAdd;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: GlassSurface(
          borderRadius: 24,
          child: Padding(
            padding: const EdgeInsets.all(28),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(Icons.folder_open, size: 64),
                const SizedBox(height: 12),
                const Text(
                  'No projects yet.\nAdd a repo or folder to get started.',
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 20),
                FilledButton.icon(
                  onPressed: onAdd,
                  icon: const Icon(Icons.create_new_folder_outlined),
                  label: const Text('Add project'),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _ProjectSection extends ConsumerWidget {
  const _ProjectSection({required this.project, required this.sessions});
  final Project project;
  final List<Session> sessions;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        InkWell(
          onLongPress: () => _confirmRemove(context, ref),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(20, 20, 8, 4),
            child: Row(
              children: [
                const Icon(Icons.folder_outlined, size: 18),
                const SizedBox(width: 8),
                Text(
                  project.name,
                  style: Theme.of(context).textTheme.titleMedium,
                ),
                const SizedBox(width: 8),
                if (_workingCount(sessions) > 0)
                  _WorkingBadge(count: _workingCount(sessions)),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    project.path,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: Theme.of(context).colorScheme.outline,
                    ),
                  ),
                ),
                PopupMenuButton<String>(
                  icon: const Icon(Icons.more_vert, size: 20),
                  tooltip: 'Project actions',
                  onSelected: (value) {
                    switch (value) {
                      case 'new':
                        _spawnHere(context, ref);
                      case 'attach':
                        _attachPast(context, ref);
                      case 'remove':
                        _confirmRemove(context, ref);
                    }
                  },
                  itemBuilder: (_) => const [
                    PopupMenuItem(
                      value: 'new',
                      child: ListTile(
                        leading: Icon(Icons.add),
                        title: Text('New session'),
                        contentPadding: EdgeInsets.zero,
                      ),
                    ),
                    PopupMenuItem(
                      value: 'attach',
                      child: ListTile(
                        leading: Icon(Icons.replay),
                        title: Text('Resume session'),
                        contentPadding: EdgeInsets.zero,
                      ),
                    ),
                    PopupMenuDivider(),
                    PopupMenuItem(
                      value: 'remove',
                      child: ListTile(
                        leading: Icon(Icons.delete_outline),
                        title: Text('Remove from makit'),
                        contentPadding: EdgeInsets.zero,
                      ),
                    ),
                  ],
                ),
              ],
            ),
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

  Future<void> _confirmRemove(BuildContext context, WidgetRef ref) async {
    final messenger = ScaffoldMessenger.of(context);
    final store = ref.read(storeControllerProvider.notifier);
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Remove ${project.name}?'),
        content: const Text(
          'This removes the project from makit. Files on disk are not touched.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Remove'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    try {
      await store.removeProject(project.id);
      messenger.showSnackBar(
        SnackBar(content: Text('Removed ${project.name}')),
      );
    } catch (e) {
      messenger.showSnackBar(
        SnackBar(content: Text('Could not remove project: $e')),
      );
    }
  }

  Future<void> _spawnHere(BuildContext context, WidgetRef ref) async {
    final messenger = ScaffoldMessenger.of(context);
    try {
      final newId = await ref
          .read(storeControllerProvider.notifier)
          .spawnSession(project.id);
      if (!context.mounted) return;
      context.go('/session/$newId');
    } catch (e) {
      messenger.showSnackBar(
        SnackBar(content: Text('Could not spawn session: $e')),
      );
    }
  }

  Future<void> _attachPast(BuildContext context, WidgetRef ref) async {
    final messenger = ScaffoldMessenger.of(context);
    final store = ref.read(storeControllerProvider.notifier);
    List<PiSessionMeta> metas;
    try {
      metas = await store.listPiSessions(project.id);
    } catch (e) {
      messenger.showSnackBar(
        SnackBar(content: Text('Could not list past sessions: $e')),
      );
      return;
    }
    if (!context.mounted) return;

    final chosen = await showSearchableListSheet<PiSessionMeta>(
      context: context,
      title: 'Resume session in ${project.name}',
      items: metas,
      emptyState: const Padding(
        padding: EdgeInsets.fromLTRB(24, 8, 24, 24),
        child: Text('No past sessions.', textAlign: TextAlign.center),
      ),
      matches: (m, q) {
        final ql = q.toLowerCase();
        return m.name.toLowerCase().contains(ql) ||
            m.preview.toLowerCase().contains(ql);
      },
      tileBuilder: (ctx, m) => ListTile(
        leading: Icon(
          m.attached ? Icons.bolt : Icons.replay,
          color: m.attached ? Colors.green : null,
        ),
        title: Text(
          m.name.isEmpty ? '(untitled)' : m.name,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        subtitle: Text(
          '${m.messageCount} msgs · ${_ago(m.lastActivityAt)}'
          '${m.preview.isEmpty ? '' : ' · ${m.preview}'}',
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        trailing: m.attached
            ? Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                decoration: BoxDecoration(
                  color: Colors.green.withValues(alpha: 0.15),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: const Text(
                  'live',
                  style: TextStyle(
                    color: Colors.green,
                    fontSize: 11,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              )
            : null,
        onTap: () => Navigator.of(ctx).pop(m),
      ),
    );
    if (chosen == null || !context.mounted) return;

    try {
      final sid = await store.attachSession(project.id, chosen.piSessionId);
      if (!context.mounted) return;
      context.go('/session/$sid');
    } catch (e) {
      messenger.showSnackBar(
        SnackBar(content: Text('Could not attach session: $e')),
      );
    }
  }
}

/// Compact "x ago" from an epoch-ms timestamp.
String _ago(int epochMs) {
  if (epochMs <= 0) return 'unknown';
  final d = DateTime.now().difference(
    DateTime.fromMillisecondsSinceEpoch(epochMs),
  );
  if (d.inDays > 0) return '${d.inDays}d ago';
  if (d.inHours > 0) return '${d.inHours}h ago';
  if (d.inMinutes > 0) return '${d.inMinutes}m ago';
  return 'just now';
}

class _SessionTile extends ConsumerWidget {
  const _SessionTile({required this.session});
  final Session session;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final cs = Theme.of(context).colorScheme;
    return Dismissible(
      key: ValueKey('sess-${session.id}'),
      direction: DismissDirection.endToStart,
      background: Container(
        alignment: Alignment.centerRight,
        color: cs.errorContainer,
        padding: const EdgeInsets.symmetric(horizontal: 24),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.power_settings_new, color: cs.onErrorContainer),
            const SizedBox(width: 8),
            Text(
              'Quit',
              style: TextStyle(
                color: cs.onErrorContainer,
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        ),
      ),
      confirmDismiss: (_) => _confirmQuit(context),
      onDismissed: (_) => _quit(context, ref),
      child: ListTile(
        onTap: () => context.go('/session/${session.id}'),
        leading: _AgentAvatar(agent: session.agent),
        title: Row(
          children: [
            Expanded(
              child: Text(session.title, overflow: TextOverflow.ellipsis),
            ),
            // Idle is the resting state — no pill; only surface active/error/exited.
            if (session.status != SessionStatus.idle)
              _StatusChip(status: session.status),
          ],
        ),
        subtitle: Text(
          session.lastPreview,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
      ),
    );
  }

  /// Confirm before the swipe completes. Returns true to dismiss + quit.
  Future<bool> _confirmQuit(BuildContext context) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (dctx) => AlertDialog(
        title: const Text('Quit session?'),
        content: Text(
          'Stop “${session.title}” and remove it? '
          'The transcript stays on disk and can be re-attached.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dctx, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dctx, true),
            child: const Text('Quit'),
          ),
        ],
      ),
    );
    return ok == true;
  }

  Future<void> _quit(BuildContext context, WidgetRef ref) async {
    final messenger = ScaffoldMessenger.of(context);
    try {
      await ref.read(storeControllerProvider.notifier).killSession(session.id);
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text('Could not quit: $e')));
    }
  }
}

/// Agent avatar: shows the agent's logo for known agents, else the initial.
class _AgentAvatar extends StatelessWidget {
  const _AgentAvatar({required this.agent});
  final String agent;

  @override
  Widget build(BuildContext context) {
    final asset = _agentLogos[agent.toLowerCase()];
    if (asset == null) {
      return CircleAvatar(
        backgroundColor: Theme.of(context).colorScheme.secondaryContainer,
        child: Text(agent.substring(0, 1).toUpperCase()),
      );
    }
    return ClipOval(
      child: SvgPicture.asset(asset, width: 40, height: 40, fit: BoxFit.cover),
    );
  }
}

/// Maps an agent label to its bundled logo SVG in `assets/agents/`.
const _agentLogos = <String, String>{
  'pi': 'assets/agents/pi.svg',
  'codex': 'assets/agents/codex.svg',
  'claude': 'assets/agents/claude.svg',
};

class _StatusChip extends StatelessWidget {
  const _StatusChip({required this.status});
  final SessionStatus status;

  @override
  Widget build(BuildContext context) {
    final (label, color) = switch (status) {
      SessionStatus.running => ('running', _kBrandBlue),
      SessionStatus.awaitingInput => ('you', Colors.orange),
      SessionStatus.awaitingApproval => ('approve', Colors.deepOrange),
      SessionStatus.error => ('error', Colors.red),
      SessionStatus.exited => ('exited', Colors.grey),
      SessionStatus.idle => ('idle', Colors.grey),
    };
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.15),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Text(
        label,
        style: TextStyle(
          color: color,
          fontSize: 11,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }
}

int _workingCount(List<Session> sessions) => sessions
    .where(
      (s) =>
          s.status == SessionStatus.running ||
          s.status == SessionStatus.awaitingInput ||
          s.status == SessionStatus.awaitingApproval,
    )
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
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        color: _kBrandBlue.withValues(alpha: 0.12),
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
              decoration: const BoxDecoration(
                color: _kBrandBlue,
                shape: BoxShape.circle,
              ),
            ),
          ),
          const SizedBox(width: 6),
          Text(
            '${widget.count} working',
            style: const TextStyle(
              color: _kBrandBlue,
              fontSize: 11,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }
}
