import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/theme.dart';
import '../../store/models.dart';
import '../../store/store.dart';
import '../../ui/home/repo_chips.dart' show branchOptionsForRepo;
import 'groups/group_providers.dart';
import 'groups/groups_controller.dart';
import 'selected_worktree.dart';

/// Where a new worktree comes from (SPEC-30).
enum _WorktreeFrom { existing, newBranch, fromPr }

/// Opens the New-worktree dialog (SPEC-30): it asks **only** where the worktree
/// comes from — use an existing worktree, create a New-branch, or fork a
/// From-PR worktree. It does **not** pick a harness, adjust config pills, or
/// take a first message; those belong to the Choose-a-harness starter
/// ([WorktreeStarter]) the user lands on after.
///
/// [projectId] preselects the repository; when null it defaults to the active
/// group's repo (a worktree group knows its repo) and otherwise the first repo,
/// because a board can hold worktrees from **any** repo.
///
/// On confirm it creates the worktree (rolling it back if anything after
/// creation fails) and, when [activateGroup] is true (the default), activates
/// that worktree's group so the user lands on the harness picker. Callers that
/// want to place the worktree in a specific tab/split (the group-aware ⌘T/⌘D on
/// a board) pass `activateGroup: false` and act on the returned worktree.
///
/// Resolves with the created [SelectedWorktree], or null when dismissed.
Future<SelectedWorktree?> showNewWorktreeDialog(
  BuildContext context,
  WidgetRef ref, {
  String? projectId,
  bool activateGroup = true,
}) {
  return showDialog<SelectedWorktree>(
    context: context,
    builder: (_) => _NewWorktreeDialog(
      initialProjectId: projectId,
      activateGroup: activateGroup,
    ),
  );
}

class _NewWorktreeDialog extends ConsumerStatefulWidget {
  const _NewWorktreeDialog({
    this.initialProjectId,
    required this.activateGroup,
  });

  final String? initialProjectId;
  final bool activateGroup;

  @override
  ConsumerState<_NewWorktreeDialog> createState() => _NewWorktreeDialogState();
}

class _NewWorktreeDialogState extends ConsumerState<_NewWorktreeDialog> {
  String? _projectId;
  _WorktreeFrom _source = _WorktreeFrom.newBranch;
  String? _existingWorktreePath;
  String? _baseBranch;
  int? _prNumber;
  Future<List<OpenPr>>? _prsFuture;

  /// Optional name for the branch a `newBranch` worktree forks. Empty means the
  /// server auto-generates one.
  final TextEditingController _branchNameCtrl = TextEditingController();

  bool _creating = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    final repos = ref.read(reposProvider).repos;
    _projectId =
        widget.initialProjectId ??
        _activeGroupRepo() ??
        (repos.isNotEmpty ? repos.first.id : null);
    _baseBranch = _defaultBranchFor(_projectId);
  }

  @override
  void dispose() {
    _branchNameCtrl.dispose();
    super.dispose();
  }

  /// The active worktree group's repo, when the active group is scoped to one —
  /// a board owns no repo, so this is null there.
  String? _activeGroupRepo() => ref.read(activeGroupProvider).projectId;

  /// Lazily fetch the open-PR list the first time the "From PR" source is
  /// selected — no network call while the dialog only shows New branch.
  void _loadPrs() {
    final projectId = _projectId;
    final future = projectId == null
        ? Future.value(const <OpenPr>[])
        : ref.read(storeControllerProvider.notifier).listOpenPrs(projectId);
    future.ignore();
    _prsFuture = future;
  }

  String? _defaultBranchFor(String? projectId) {
    for (final r in ref.read(reposProvider).repos) {
      if (r.id == projectId) {
        final options = branchOptionsForRepo(r);
        return options.isEmpty ? null : options.first;
      }
    }
    return null;
  }

  /// The base branch actually used: [_baseBranch] when it is a live option,
  /// else the first option (what [_newBranchPanel] displays).
  String? _effectiveBaseBranch(String? projectId) {
    RepoInfo? repo;
    for (final r in ref.read(reposProvider).repos) {
      if (r.id == projectId) repo = r;
    }
    final options = repo == null
        ? const <String>[]
        : branchOptionsForRepo(repo);
    if (options.isEmpty) return _baseBranch;
    return options.contains(_baseBranch) ? _baseBranch : options.first;
  }

  void _close() {
    if (_creating) return;
    Navigator.of(context).pop();
  }

  /// Whether the Create button should be enabled: a From-PR worktree needs a
  /// selected PR, and an Existing worktree needs one to have been resolved.
  bool _canCreateWorktree() {
    return switch (_source) {
      _WorktreeFrom.fromPr => _prNumber != null,
      _WorktreeFrom.existing => _existingWorktreePath != null,
      _WorktreeFrom.newBranch => true,
    };
  }

  void _onRepoChanged(String? projectId) {
    if (projectId == null || projectId == _projectId) return;
    setState(() {
      _projectId = projectId;
      _baseBranch = _defaultBranchFor(projectId);
      // A different repo has a different PR list; drop the cached future so the
      // panel refetches when From PR is shown again.
      _prsFuture = null;
      _prNumber = null;
      // The old repo's worktree no longer belongs to this repo.
      _existingWorktreePath = _source == _WorktreeFrom.existing
          ? _firstExistingWorktreePath()
          : null;
      if (_source == _WorktreeFrom.fromPr) _loadPrs();
    });
  }

  /// Creates the worktree from the chosen source, activates its group when
  /// asked, then pops with it. A failure after creation removes the fresh
  /// worktree so a retry doesn't orphan it; errors surface inline.
  Future<void> _create() async {
    if (_creating) return;
    final projectId = _projectId;
    if (projectId == null) return;
    setState(() {
      _creating = true;
      _error = null;
    });
    final store = ref.read(storeControllerProvider.notifier);
    String? createdPath;
    try {
      final ({String path, String? branch}) created;
      switch (_source) {
        case _WorktreeFrom.existing:
          final path = _existingWorktreePath;
          if (path == null) return;
          created = (path: path, branch: null);
        case _WorktreeFrom.newBranch:
          final name = _branchNameCtrl.text.trim();
          created = await store.createWorktree(
            projectId,
            baseBranch: _effectiveBaseBranch(projectId),
            branchName: name.isEmpty ? null : name,
          );
        case _WorktreeFrom.fromPr:
          final pr = _prNumber;
          if (pr == null) {
            // Surfaced as UI copy, so it must not be an exception: `'$e'` on a
            // StateError renders as "Bad state: Select a pull request first."
            setState(() {
              _creating = false;
              _error = 'Select a pull request first.';
            });
            return;
          }
          created = await store.createWorktreeFromPr(projectId, pr);
      }
      createdPath = created.path;
      final worktree = SelectedWorktree(
        projectId: projectId,
        path: created.path,
        branch: created.branch,
      );
      // Hand off BEFORE activating the group: creating the worktree is the
      // side-effectful step and it has succeeded. If activation then threw, a
      // rollback would delete a worktree that is fine and that the user asked
      // for — losing work to tidy up bookkeeping.
      createdPath = null;
      if (widget.activateGroup) {
        ref
            .read(groupsControllerProvider.notifier)
            .openWorktreeGroup(
              projectId: projectId,
              worktreePath: created.path,
              label: created.branch ?? created.path.split('/').last,
            );
      }
      if (!mounted) return;
      _creating = false; // reset before popping, in case the pop is refused
      Navigator.of(context).pop(worktree);
    } catch (e) {
      if (createdPath != null) {
        await store.removeWorktree(projectId, createdPath).catchError((_) {});
      }
      if (!mounted) return;
      setState(() {
        _creating = false;
        _error = '$e';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return CallbackShortcuts(
      bindings: {const SingleActivator(LogicalKeyboardKey.escape): _close},
      child: Dialog(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 480, maxHeight: 560),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 16, 12, 0),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        'New worktree',
                        style: theme.textTheme.titleLarge,
                      ),
                    ),
                    IconButton(
                      tooltip: 'Close',
                      icon: const Icon(Icons.close),
                      onPressed: _creating ? null : _close,
                    ),
                  ],
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
                child: Text(
                  'Creates the branch and its folder. You pick the harness and '
                  'write the first message in the pane you land on.',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.outline,
                  ),
                ),
              ),
              Flexible(
                child: SingleChildScrollView(
                  padding: const EdgeInsets.fromLTRB(20, 4, 20, 16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      _repositoryField(theme),
                      const SizedBox(height: kSpace16),
                      _sourceField(theme),
                      if (_error != null) ...[
                        const SizedBox(height: kSpace12),
                        Text(
                          _error!,
                          style: TextStyle(color: theme.colorScheme.error),
                        ),
                      ],
                    ],
                  ),
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 0, 20, 16),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.end,
                  children: [
                    FilledButton(
                      onPressed: _canCreateWorktree() && !_creating ? _create : null,
                      child: const Text('Create worktree'),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _fieldLabel(ThemeData theme, String text) => Padding(
    padding: const EdgeInsets.only(bottom: 8),
    child: Text(
      text,
      style: theme.textTheme.labelLarge?.copyWith(
        color: theme.colorScheme.outline,
      ),
    ),
  );

  Widget _labeledRow(ThemeData theme, String label, Widget child) => Row(
    crossAxisAlignment: CrossAxisAlignment.center,
    children: [
      SizedBox(
        width: 52,
        child: Text(
          label,
          style: theme.textTheme.labelLarge?.copyWith(
            color: theme.colorScheme.outline,
          ),
        ),
      ),
      Expanded(child: child),
    ],
  );

  /// The repository selector — required, because a board can hold worktrees
  /// from any repo (the old dialog inferred it from the project).
  Widget _repositoryField(ThemeData theme) {
    final repos = ref.read(reposProvider).repos;
    final value = repos.any((r) => r.id == _projectId)
        ? _projectId
        : (repos.isEmpty ? null : repos.first.id);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _fieldLabel(theme, 'Repository'),
        DropdownButtonFormField<String>(
          key: const ValueKey('wt-repo-picker'),
          initialValue: value,
          isExpanded: true,
          items: [
            for (final r in repos)
              DropdownMenuItem(
                value: r.id,
                child: Text(r.name, overflow: TextOverflow.ellipsis),
              ),
          ],
          onChanged: _creating ? null : _onRepoChanged,
        ),
      ],
    );
  }

  Widget _sourceField(ThemeData theme) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _fieldLabel(theme, 'From'),
        SegmentedButton<_WorktreeFrom>(
          showSelectedIcon: false,
          segments: const [
            ButtonSegment(
              value: _WorktreeFrom.existing,
              label: Text('Existing'),
            ),
            ButtonSegment(
              value: _WorktreeFrom.newBranch,
              label: Text('New branch'),
            ),
            ButtonSegment(value: _WorktreeFrom.fromPr, label: Text('From PR')),
          ],
          selected: {_source},
          onSelectionChanged: _creating
              ? null
              : (s) => setState(() {
                  _source = s.first;
                  if (_source == _WorktreeFrom.existing) {
                    _existingWorktreePath ??= _firstExistingWorktreePath();
                  }
                  if (_source == _WorktreeFrom.fromPr && _prsFuture == null) {
                    _loadPrs();
                  }
                }),
        ),
        const SizedBox(height: kSpace10),
        switch (_source) {
          _WorktreeFrom.existing => _existingPanel(theme),
          _WorktreeFrom.newBranch => _newBranchPanel(theme),
          _WorktreeFrom.fromPr => _fromPrPanel(theme),
        },
      ],
    );
  }

  /// Live worktrees in the selected repo (the source list for Existing).
  List<Worktree> _existingWorktrees() {
    for (final r in ref.read(reposProvider).repos) {
      if (r.id == _projectId) return r.worktrees;
    }
    return const <Worktree>[];
  }

  /// The first existing worktree's path, or null when the repo has none.
  String? _firstExistingWorktreePath() {
    final worktrees = _existingWorktrees();
    return worktrees.isEmpty ? null : worktrees.first.path;
  }

  Widget _existingPanel(ThemeData theme) {
    final worktrees = _existingWorktrees();
    if (worktrees.isEmpty) {
      return Text(
        'No existing worktrees in this repo.',
        style: theme.textTheme.bodySmall?.copyWith(
          color: theme.colorScheme.outline,
        ),
      );
    }
    final selected = worktrees.any((w) => w.path == _existingWorktreePath)
        ? _existingWorktreePath
        : worktrees.first.path;
    return _labeledRow(
      theme,
      'Worktree',
      DropdownButtonFormField<String>(
        key: const ValueKey('wt-existing-picker'),
        initialValue: selected,
        isExpanded: true,
        items: [
          for (final wt in worktrees)
            DropdownMenuItem(
              value: wt.path,
              child: Text(
                wt.branch ?? 'detached',
                overflow: TextOverflow.ellipsis,
              ),
            ),
        ],
        onChanged: _creating
            ? null
            : (v) => setState(() => _existingWorktreePath = v),
      ),
    );
  }

  Widget _newBranchPanel(ThemeData theme) {
    RepoInfo? repo;
    for (final r in ref.read(reposProvider).repos) {
      if (r.id == _projectId) repo = r;
    }
    final options = repo == null
        ? const <String>[]
        : branchOptionsForRepo(repo);
    final Widget fromControl = options.isEmpty
        ? Text(
            'the repo’s default branch',
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.outline,
            ),
          )
        : DropdownButtonFormField<String>(
            key: ValueKey('wt-branch-$_projectId'),
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
            onChanged: _creating
                ? null
                : (v) => setState(() => _baseBranch = v),
          );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _labeledRow(theme, 'Base', fromControl),
        const SizedBox(height: kSpace10),
        _labeledRow(
          theme,
          'Name',
          TextField(
            controller: _branchNameCtrl,
            enabled: !_creating,
            // Mirror the server's slugifyBranch length cap (80).
            inputFormatters: [LengthLimitingTextInputFormatter(80)],
            decoration: const InputDecoration(
              isDense: true,
              border: OutlineInputBorder(),
              hintText: 'Leave blank to auto-generate',
            ),
          ),
        ),
      ],
    );
  }

  Widget _fromPrPanel(ThemeData theme) {
    return FutureBuilder<List<OpenPr>>(
      future: _prsFuture,
      builder: (context, snap) {
        if (snap.connectionState != ConnectionState.done) {
          return const Padding(
            padding: EdgeInsets.symmetric(vertical: kSpace8),
            child: LinearProgressIndicator(),
          );
        }
        if (snap.hasError) {
          return Text(
            "Couldn't load pull requests:\n${snap.error}",
            style: TextStyle(color: theme.colorScheme.error),
          );
        }
        final prs = snap.data ?? const <OpenPr>[];
        if (prs.isEmpty) {
          return Text(
            'No open pull requests (or GitHub CLI is unavailable).',
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.outline,
            ),
          );
        }
        final value = prs.any((p) => p.number == _prNumber) ? _prNumber : null;
        return DropdownButtonFormField<int>(
          key: const ValueKey('wt-pr-picker'),
          initialValue: value,
          isExpanded: true,
          hint: const Text('Select a pull request'),
          items: [
            for (final pr in prs)
              DropdownMenuItem(
                value: pr.number,
                child: Text(
                  '#${pr.number} ${pr.title.isEmpty ? pr.headRefName : pr.title}',
                  overflow: TextOverflow.ellipsis,
                ),
              ),
          ],
          onChanged: _creating ? null : (v) => setState(() => _prNumber = v),
        );
      },
    );
  }
}
