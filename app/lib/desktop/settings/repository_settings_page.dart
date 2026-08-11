import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../store/models.dart';
import '../../store/store.dart';
import '../../ui/home/repo_monogram.dart';
import 'sections/repository_section.dart';

/// One repository's Settings page, connected to the live repo snapshot.
///
/// Thin on purpose: it resolves the repo by **id** (never by index or path, so a
/// reordered or moved repo keeps working), maps it to a view, and hands the writes
/// to the server. All the rendering lives in [RepositorySettingsSection] and all
/// the mapping in `repoSettingsViewFor`, so this file has nothing to get wrong
/// except the wiring.
class RepositorySettingsPage extends ConsumerWidget {
  const RepositorySettingsPage({required this.repoId, super.key});

  final String repoId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final repos = ref.watch(reposProvider).repos;
    final repo = repos.where((r) => r.id == repoId).firstOrNull;

    // The repo went away while its section was open — removed, or the snapshot has
    // not arrived yet. Say so rather than rendering an empty shell.
    if (repo == null) {
      return _Notice(
        text: repos.isEmpty
            ? 'Waiting for the repository list…'
            : 'This repository is no longer open in makit.',
      );
    }

    final view = repoSettingsViewFor(repo);
    // An older server sends no settings. Rendering fabricated defaults would be
    // worse than saying nothing, because every value shown would be a guess.
    if (view == null) {
      return const _Notice(
        text: 'This server does not report per-repository settings yet.',
      );
    }

    return RepositorySettingsSection(
      view: view,
      onChooseProvider: (choice) => _write(ref, {
        // `auto` clears the override; absent means "believe detection".
        'provider': choice == ForgeChoice.auto ? null : choice.name,
      }),
      onResetWorktreeRoot: () => _write(ref, {'worktreeRoot': null}),
      onEditWorktreeRoot: () => _promptWorktreeRoot(context, ref, view),
      onChooseDefaultBranch: () => _pickBranch(context, ref, view),
      onEditLogo: () => _pickHue(context, ref, repo),
      onChangeRootPath: () => _showRootPathHelp(context),
    );
  }

  void _write(WidgetRef ref, Map<String, Object?> patch) {
    // Fire-and-forget: the server persists, then re-broadcasts the repos snapshot,
    // and this page re-renders from that. No optimistic local state, so what is on
    // screen is always what the daemon actually stored — and a refusal (a
    // non-loopback client) cannot leave the UI showing a value that was rejected.
    ref.read(storeControllerProvider.notifier).setRepoSettings(repoId, patch);
  }

  Future<void> _promptWorktreeRoot(
    BuildContext context,
    WidgetRef ref,
    RepoSettingsView view,
  ) async {
    final controller = TextEditingController(text: view.worktreeRoot);
    final value = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Worktree root'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            TextField(
              controller: controller,
              autofocus: true,
              decoration: const InputDecoration(hintText: '/Users/you/.worktrees'),
            ),
            const SizedBox(height: 10),
            Text(
              'Must be an absolute path inside your home directory. '
              'It does not have to exist yet.',
              style: Theme.of(ctx).textTheme.bodySmall,
            ),
          ],
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          TextButton(
            onPressed: () => Navigator.pop(ctx, controller.text.trim()),
            child: const Text('Set'),
          ),
        ],
      ),
    );
    if (value == null || value.isEmpty) return;
    // Not validated here: the server owns the rules (absolute, no `..`, inside
    // $HOME, canonicalised) and re-implementing them in Dart would give two
    // answers that could disagree. A refusal comes back as an `err` frame.
    _write(ref, {'worktreeRoot': value});
  }

  Future<void> _pickBranch(
    BuildContext context,
    WidgetRef ref,
    RepoSettingsView view,
  ) async {
    if (view.branches.isEmpty) return;
    final picked = await showDialog<String>(
      context: context,
      builder: (ctx) => SimpleDialog(
        title: const Text('Default branch'),
        children: [
          for (final b in view.branches)
            SimpleDialogOption(
              onPressed: () => Navigator.pop(ctx, b),
              child: Text(b),
            ),
          SimpleDialogOption(
            onPressed: () => Navigator.pop(ctx, ''),
            child: const Text('Use the branch git reports'),
          ),
        ],
      ),
    );
    if (picked == null) return;
    _write(ref, {'defaultBranch': picked.isEmpty ? null : picked});
  }

  Future<void> _pickHue(BuildContext context, WidgetRef ref, RepoInfo repo) async {
    final picked = await showDialog<int>(
      context: context,
      builder: (ctx) => SimpleDialog(
        title: const Text('Logo colour'),
        children: [
          for (var i = 0; i < 6; i++)
            SimpleDialogOption(
              onPressed: () => Navigator.pop(ctx, i),
              child: Row(
                children: [
                  Container(
                    width: 18,
                    height: 18,
                    decoration: BoxDecoration(
                      color: RepoMonogram.paletteAt(i),
                      borderRadius: BorderRadius.circular(5),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Text('Colour ${i + 1}'),
                ],
              ),
            ),
          SimpleDialogOption(
            onPressed: () => Navigator.pop(ctx, -1),
            child: const Text('Derive from the name'),
          ),
        ],
      ),
    );
    if (picked == null) return;
    _write(ref, {'logoHue': picked < 0 ? null : picked});
  }

  void _showRootPathHelp(BuildContext context) {
    // Deliberately not an inline text field. Re-pointing a repo means the daemon
    // must re-check it is a git repo and re-run forge detection, and getting that
    // wrong silently detaches a project from its sessions. Until that path exists
    // server-side, say what to do rather than offering an edit that cannot work.
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text(
          'Changing a repository path is not supported yet — remove it and add it '
          'again from its new location.',
        ),
      ),
    );
  }
}

class _Notice extends StatelessWidget {
  const _Notice({required this.text});
  final String text;
  @override
  Widget build(BuildContext context) => Center(
    child: Padding(
      padding: const EdgeInsets.all(32),
      child: Text(text, style: Theme.of(context).textTheme.bodyMedium),
    ),
  );
}
