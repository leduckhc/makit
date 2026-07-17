import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../store/models.dart';
import '../../store/store.dart';
import '../../ui/home/repo_chips.dart';
import '../../ui/project/folder_browser.dart';
import 'selected_session.dart';

/// Opens the "New worktree" dialog: pick a repo + base branch, then spawn a
/// draft. The harness is chosen afterwards from cards in the chat pane. Pass
/// [projectId] to preselect a repo (e.g. from a repo row's + button).
Future<void> showNewSessionDialog(
  BuildContext context,
  WidgetRef ref, {
  String? projectId,
}) {
  return showDialog<void>(
    context: context,
    builder: (_) => _NewSessionDialog(initialProjectId: projectId),
  );
}

class _NewSessionDialog extends ConsumerStatefulWidget {
  const _NewSessionDialog({this.initialProjectId});

  final String? initialProjectId;

  @override
  ConsumerState<_NewSessionDialog> createState() => _NewSessionDialogState();
}

class _NewSessionDialogState extends ConsumerState<_NewSessionDialog>
    with SingleTickerProviderStateMixin {
  String? _projectId;
  String? _baseBranch;
  bool _spawning = false;
  String? _error;
  late final TabController _tabs;
  Future<List<OpenPr>>? _prsFuture;

  @override
  void initState() {
    super.initState();
    _tabs = TabController(length: 3, initialIndex: 1, vsync: this);
    // Preselect the caller's repo, else the first one.
    final repos = ref.read(reposProvider).repos;
    _projectId =
        widget.initialProjectId ?? (repos.isNotEmpty ? repos.first.id : null);
    _baseBranch = _defaultBranchFor(_projectId);
    _loadPrs();
  }

  @override
  void dispose() {
    _tabs.dispose();
    super.dispose();
  }

  /// (Re)fetch the open-PR list for the selected repo. Called on open and
  /// whenever the repo changes so the PR tab reflects the current repo.
  void _loadPrs() {
    final projectId = _projectId;
    _prsFuture = projectId == null
        ? Future.value(const <OpenPr>[])
        : ref.read(storeControllerProvider.notifier).listOpenPrs(projectId);
  }

  /// The repo's default fork point: its default branch, else current, else the
  /// first known branch. Null when the repo has no branches (fresh repo).
  String? _defaultBranchFor(String? projectId) {
    if (projectId == null) return null;
    final repos = ref.read(reposProvider).repos;
    RepoInfo? repo;
    for (final r in repos) {
      if (r.id == projectId) {
        repo = r;
        break;
      }
    }
    if (repo == null) return null;
    final options = branchOptionsForRepo(repo);
    return options.isEmpty ? null : options.first;
  }

  /// "Branch from" dropdown: pick the base branch the worktree forks off.
  /// Hidden when the selected repo exposes no branches (nothing to choose).
  Widget _branchField(List<RepoInfo> repos) {
    RepoInfo? repo;
    for (final r in repos) {
      if (r.id == _projectId) {
        repo = r;
        break;
      }
    }
    final options = repo == null
        ? const <String>[]
        : branchOptionsForRepo(repo);
    if (options.isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(top: 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('Branch from'),
          const SizedBox(height: 6),
          DropdownButtonFormField<String>(
            // Key by repo so switching to a repo with a disjoint branch set
            // rebuilds fresh FormField state — otherwise the retained value
            // is no longer among `items` and trips DropdownButton's
            // "exactly one item" assertion.
            key: ValueKey('branch-$_projectId'),
            initialValue: options.contains(_baseBranch)
                ? _baseBranch
                : options.first,
            isExpanded: true,
            items: [
              for (final b in options)
                DropdownMenuItem(
                  value: b,
                  child: Text(b, overflow: TextOverflow.ellipsis),
                ),
            ],
            onChanged: (v) => setState(() => _baseBranch = v),
          ),
        ],
      ),
    );
  }

  Future<void> _addProject() async {
    final id = await showFolderBrowser(context);
    if (!mounted || id == null) return;
    setState(() => _projectId = id);
  }

  Future<void> _start() async {
    final projectId = _projectId;
    if (projectId == null) return;
    setState(() {
      _spawning = true;
      _error = null;
    });
    try {
      final result = await ref
          .read(storeControllerProvider.notifier)
          .createWorktree(projectId, baseBranch: _baseBranch);
      if (!mounted) return;
      // Land on the new (sessionless) worktree — the pane shows the harness
      // cards; the session starts in it on the first message.
      selectWorktree(
        ref,
        SelectedWorktree(
          projectId: projectId,
          path: result.path,
          branch: result.branch,
        ),
      );
      Navigator.of(context).pop();
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _spawning = false;
        _error = '$e';
      });
    }
  }

  /// Create a worktree that checks out the selected PR's head branch, then land
  /// on it (same as the branch flow).
  Future<void> _createFromPr(int prNumber) async {
    final projectId = _projectId;
    if (projectId == null) return;
    setState(() {
      _spawning = true;
      _error = null;
    });
    try {
      final result = await ref
          .read(storeControllerProvider.notifier)
          .createWorktreeFromPr(projectId, prNumber);
      if (!mounted) return;
      selectWorktree(
        ref,
        SelectedWorktree(
          projectId: projectId,
          path: result.path,
          branch: result.branch,
        ),
      );
      Navigator.of(context).pop();
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _spawning = false;
        _error = '$e';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final repos = ref.watch(reposProvider).repos;
    final theme = Theme.of(context);

    return AlertDialog(
      title: const Text('New worktree from…'),
      content: SizedBox(
        width: 460,
        height: 380,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('Repo'),
            const SizedBox(height: 6),
            if (repos.isEmpty)
              OutlinedButton.icon(
                onPressed: _addProject,
                icon: const Icon(Icons.create_new_folder_outlined),
                label: const Text('Add a repo'),
              )
            else
              DropdownButtonFormField<String>(
                initialValue: _projectId,
                isExpanded: true,
                items: [
                  for (final r in repos)
                    DropdownMenuItem(
                      value: r.id,
                      child: Text(
                        r.currentBranch == null
                            ? r.name
                            : '${r.name} · ${r.currentBranch}',
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                ],
                onChanged: (v) => setState(() {
                  _projectId = v;
                  _baseBranch = _defaultBranchFor(v);
                  _loadPrs();
                }),
              ),
            const SizedBox(height: 12),
            TabBar(
              controller: _tabs,
              tabs: const [
                Tab(text: 'PR'),
                Tab(text: 'Branch'),
                Tab(text: 'Issue'),
              ],
            ),
            Expanded(
              child: TabBarView(
                controller: _tabs,
                children: [_prTab(theme), _branchTab(repos), _issueTab(theme)],
              ),
            ),
            if (_error != null) ...[
              const SizedBox(height: 8),
              Text(_error!, style: TextStyle(color: theme.colorScheme.error)),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: _spawning ? null : () => Navigator.of(context).pop(),
          child: const Text('Close'),
        ),
      ],
    );
  }

  /// PR tab: the open-PR list; tapping one forks a worktree on its head branch.
  Widget _prTab(ThemeData theme) {
    return FutureBuilder<List<OpenPr>>(
      future: _prsFuture,
      builder: (context, snap) {
        if (snap.connectionState != ConnectionState.done) {
          return const Center(child: CircularProgressIndicator());
        }
        final prs = snap.data ?? const <OpenPr>[];
        if (prs.isEmpty) {
          return Center(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Text(
                'No open pull requests\n(or GitHub CLI is unavailable).',
                textAlign: TextAlign.center,
                style: TextStyle(color: theme.colorScheme.outline),
              ),
            ),
          );
        }
        return ListView.builder(
          itemCount: prs.length,
          itemBuilder: (context, i) {
            final pr = prs[i];
            return ListTile(
              dense: true,
              enabled: !_spawning,
              leading: Text('#${pr.number}'),
              title: Text(
                pr.title.isEmpty ? pr.headRefName : pr.title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              subtitle: Text(
                pr.headRefName,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              onTap: () => _createFromPr(pr.number),
            );
          },
        );
      },
    );
  }

  /// Branch tab: pick a base branch and fork a fresh worktree off it.
  Widget _branchTab(List<RepoInfo> repos) {
    final canStart = _projectId != null && !_spawning;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _branchField(repos),
        const SizedBox(height: 16),
        FilledButton(
          onPressed: canStart ? _start : null,
          child: _spawning
              ? const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Text('Create worktree'),
        ),
      ],
    );
  }

  /// Issue tab: placeholder for the future "start working on an issue" flow.
  Widget _issueTab(ThemeData theme) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Text(
          'Starting a worktree from a GitHub issue\nis coming soon.',
          textAlign: TextAlign.center,
          style: TextStyle(color: theme.colorScheme.outline),
        ),
      ),
    );
  }
}
