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
      onChangeRootPath: () => _promptRootPath(context, ref, view),
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

  /// Re-point the repository (SPEC-48 D4\u2032).
  ///
  /// Distinct from the settings writes in two ways, both deliberate:
  ///
  ///  - it **says what it will do** before doing it. The other rows change a
  ///    preference; this one changes which directory every session in this project
  ///    runs its git commands in, and the daemon re-runs forge detection as a
  ///    result. A confirmation is proportionate to that.
  ///  - it **surfaces the refusal**. "Not a git repository" and "already open as X"
  ///    are the whole point of the server-side check, and a fire-and-forget write
  ///    would leave the path unchanged with no explanation.
  Future<void> _promptRootPath(
    BuildContext context,
    WidgetRef ref,
    RepoSettingsView view,
  ) async {
    final controller = TextEditingController(text: view.path);
    final value = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Repository path'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            TextField(
              controller: controller,
              autofocus: true,
              decoration: const InputDecoration(hintText: '/Users/you/Work/project'),
            ),
            const SizedBox(height: 10),
            Text(
              'Use this when the repository has moved on disk. It keeps this '
              'project\u2019s settings and session history, which removing and '
              're-adding it would not.\n\n'
              'It must be an existing git repository. Sessions already bound to a '
              'worktree keep the path they were created with.',
              style: Theme.of(ctx).textTheme.bodySmall,
            ),
          ],
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          // Disabled until the value is both non-empty and actually different. The
          // guard below still returns early, but a button that closes the dialog and
          // does nothing is the failure this feature already refuses elsewhere: a
          // control that appears to act and does not is worse than one that says it
          // cannot.
          ValueListenableBuilder<TextEditingValue>(
            valueListenable: controller,
            builder: (ctx, field, _) {
              final next = field.text.trim();
              return TextButton(
                onPressed: next.isEmpty || next == view.path
                    ? null
                    : () => Navigator.pop(ctx, next),
                child: const Text('Re-point'),
              );
            },
          ),
        ],
      ),
    );
    // Kept as a guard even though the button is disabled: dismissing the dialog and
    // the disabled state are two different mechanisms, and only one of them is
    // enforced by the widget tree.
    if (value == null || value.isEmpty || value == view.path) return;
    // Not validated here: the server owns the rules (absolute, no `..`, exists, is a
    // git repo, not already open) and re-implementing them in Dart would give two
    // answers that could disagree.
    if (!context.mounted) return;
    final messenger = ScaffoldMessenger.of(context);
    try {
      await ref.read(storeControllerProvider.notifier).setRepoPath(repoId, value);
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text(_reasonFrom(e))));
    }
  }

  /// The server's own wording where there is one, so an actionable refusal is not
  /// replaced by a generic failure.
  static String _reasonFrom(Object error) {
    final text = error.toString();
    final marker = text.indexOf(': ');
    return marker >= 0 && marker + 2 < text.length ? text.substring(marker + 2) : text;
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
