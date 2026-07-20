import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:phosphoricons_flutter/phosphoricons_flutter.dart';

import '../../store/connection.dart';
import '../../store/store.dart';
import '../project/folder_browser.dart';
import '../widgets/connection_chip.dart';
import '../widgets/glass.dart';
import 'repo_card.dart';

/// Home screen — organised around **repos**. Each repo card surfaces its
/// branches (worktrees), diff size, open PRs, and the sessions running in each
/// worktree. A new session is a draft until its first message names a branch.
class HomeScreen extends ConsumerWidget {
  const HomeScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final repos = ref.watch(reposProvider).repos;
    final sessions = ref.watch(sessionsProvider);
    final useFake = ref.watch(connectionProvider).useFake;
    final cs = Theme.of(context).colorScheme;
    final topInset = MediaQuery.of(context).padding.top;

    return Scaffold(
      extendBodyBehindAppBar: true,
      extendBody: true,
      body: Stack(
        children: [
          RefreshIndicator(
            onRefresh: () =>
                ref.read(storeControllerProvider.notifier).refreshRepos(),
            child: repos.isEmpty
                ? _EmptyState(
                    onAdd: () => showFolderBrowser(context),
                    topPadding: topInset + 60,
                  )
                : ListView.builder(
                    padding: EdgeInsets.fromLTRB(12, topInset + 60, 12, 24),
                    itemCount: repos.length,
                    itemBuilder: (context, i) => RepoCard(
                      repo: repos[i],
                      sessions: sessions.forProject(repos[i].id),
                    ),
                  ),
          ),
          Positioned(
            top: 0,
            left: 0,
            right: 0,
            child: IgnorePointer(
              child: Container(
                height: topInset + 96,
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: [
                      cs.surface.withValues(alpha: 0.80),
                      cs.surface.withValues(alpha: 0.70),
                      cs.surface.withValues(alpha: 0),
                    ],
                    stops: const [0, 0.5, 1],
                  ),
                ),
              ),
            ),
          ),
          Positioned(
            top: 0,
            left: 0,
            right: 0,
            child: SafeArea(
              bottom: false,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        'makit',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context).textTheme.titleMedium
                            ?.copyWith(
                              fontWeight: FontWeight.w600,
                              shadows: [
                                Shadow(color: cs.surface, blurRadius: 6),
                                Shadow(color: cs.surface, blurRadius: 12),
                              ],
                            ),
                      ),
                    ),
                    if (useFake) ...[
                      GlassCircleButton(
                        icon: PhosphorIconsLight.x,
                        tooltip: 'Exit demo',
                        onTap: () async {
                          await ref
                              .read(connectionControllerProvider.notifier)
                              .unpair();
                          if (context.mounted) context.go('/pair');
                        },
                      ),
                      const SizedBox(width: 6),
                    ],
                    GlassCircleButton(
                      icon: PhosphorIconsLight.folderPlus,
                      tooltip: 'Add repo',
                      onTap: () => showFolderBrowser(context),
                    ),
                    const SizedBox(width: 6),
                    GlassCircleButton(
                      icon: PhosphorIconsLight.gearSix,
                      tooltip: 'Settings',
                      onTap: () => context.go('/settings'),
                    ),
                    const SizedBox(width: 6),
                    const ConnectionChip(circular: true),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _EmptyState extends StatelessWidget {
  const _EmptyState({required this.onAdd, required this.topPadding});
  final VoidCallback onAdd;
  final double topPadding;

  @override
  Widget build(BuildContext context) {
    // Wrapped in a scroll view so RefreshIndicator still works when empty.
    return ListView(
      padding: EdgeInsets.only(top: topPadding),
      children: [
        SizedBox(height: MediaQuery.of(context).size.height * 0.18),
        Center(
          child: Padding(
            padding: const EdgeInsets.all(32),
            child: GlassSurface(
              borderRadius: 24,
              child: Padding(
                padding: const EdgeInsets.all(28),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(PhosphorIconsLight.graph, size: 64),
                    const SizedBox(height: 12),
                    const Text(
                      'No repos yet.\nAdd a git repo to get started.',
                      textAlign: TextAlign.center,
                    ),
                    const SizedBox(height: 20),
                    FilledButton.icon(
                      onPressed: onAdd,
                      icon: const Icon(PhosphorIconsLight.folderPlus),
                      label: const Text('Add repo'),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}
