import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../store/models.dart';
import '../../store/store.dart';
import '../../ui/home/repo_chips.dart';
import '../../ui/project/folder_browser.dart';
import 'selected_session.dart';

/// Opens the "New session" dialog: pick a repo + a harness, then spawn. Pass
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

class _NewSessionDialogState extends ConsumerState<_NewSessionDialog> {
  List<AgentDescriptor> _agents = const [];
  bool _loadingAgents = true;
  String? _projectId;
  String? _agentId;
  String? _baseBranch;
  bool _spawning = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _loadAgents();
    // Preselect the caller's repo, else the first one.
    final repos = ref.read(reposProvider).repos;
    _projectId =
        widget.initialProjectId ?? (repos.isNotEmpty ? repos.first.id : null);
    _baseBranch = _defaultBranchFor(_projectId);
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

  Future<void> _loadAgents() async {
    final agents = await ref
        .read(storeControllerProvider.notifier)
        .fetchAgents();
    if (!mounted) return;
    setState(() {
      _agents = agents;
      _agentId = agents
          .firstWhere(
            (a) => a.available,
            orElse: () => agents.isEmpty
                ? const AgentDescriptor(
                    id: '',
                    label: '',
                    transport: '',
                    available: false,
                  )
                : agents.first,
          )
          .id;
      if (_agentId!.isEmpty) _agentId = null;
      _loadingAgents = false;
    });
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
      final sessionId = await ref
          .read(storeControllerProvider.notifier)
          .spawnSession(projectId, agent: _agentId, baseBranch: _baseBranch);
      if (!mounted) return;
      ref.read(selectedSessionProvider.notifier).state = sessionId;
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
    final canStart = _projectId != null && !_spawning;

    return AlertDialog(
      title: const Text('New session'),
      content: SizedBox(
        width: 420,
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
                }),
              ),
            _branchField(repos),
            const SizedBox(height: 16),
            const Text('Harness'),
            const SizedBox(height: 6),
            if (_loadingAgents)
              const Padding(
                padding: EdgeInsets.all(8),
                child: SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
              )
            else if (_agents.isEmpty)
              const Text('Using the host default harness.')
            else
              DropdownButtonFormField<String>(
                initialValue: _agentId,
                isExpanded: true,
                items: [
                  for (final a in _agents)
                    DropdownMenuItem(
                      value: a.id,
                      enabled: a.available,
                      child: Text(
                        a.available ? a.label : '${a.label} (unavailable)',
                      ),
                    ),
                ],
                onChanged: (v) => setState(() => _agentId = v),
              ),
            if (_error != null) ...[
              const SizedBox(height: 12),
              Text(
                _error!,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: _spawning ? null : () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: canStart ? _start : null,
          child: _spawning
              ? const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Text('Start'),
        ),
      ],
    );
  }
}
