import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/theme.dart';
import '../../shortcuts/keymap_controller.dart';
import '../../shortcuts/shortcut_action.dart';
import '../../store/models.dart';
import '../../store/store.dart';
import '../../ui/composer/composer.dart';
import '../../ui/composer/composer_selectors.dart' show ConfigOptionPickRow;
import '../../ui/home/repo_chips.dart'
    show branchOptionsForRepo, sortWorktreesForDisplay;
import '../../ui/home/new_session_sheet.dart' show WorktreeSource;
import 'harness_picker.dart' show HarnessCard;
import 'selected_session.dart';

/// Opens the New-session dialog (SPEC-27): configure the worktree, harness, and
/// the harness's cached config options, then start the session with the first
/// message. [projectId] preselects a repo; [worktree] pre-fills the Worktree
/// field to an existing worktree (e.g. the active pane's) when known.
Future<void> showNewSessionDialog(
  BuildContext context,
  WidgetRef ref, {
  String? projectId,
  SelectedWorktree? worktree,
}) {
  return showDialog<void>(
    context: context,
    builder: (_) => _NewSessionDialog(
      initialProjectId: projectId ?? worktree?.projectId,
      initialWorktree: worktree,
    ),
  );
}

class _NewSessionDialog extends ConsumerStatefulWidget {
  const _NewSessionDialog({this.initialProjectId, this.initialWorktree});

  final String? initialProjectId;
  final SelectedWorktree? initialWorktree;

  @override
  ConsumerState<_NewSessionDialog> createState() => _NewSessionDialogState();
}

class _NewSessionDialogState extends ConsumerState<_NewSessionDialog> {
  String? _projectId;
  WorktreeSource _source = WorktreeSource.existing;
  String? _baseBranch;
  String? _existingPath;
  int? _prNumber;
  Future<List<OpenPr>>? _prsFuture;

  /// Optional name for the branch a `newBranch` spawn forks (SPEC-27 follow-up).
  /// Empty means the server auto-generates one.
  final TextEditingController _branchNameCtrl = TextEditingController();

  /// The user-picked harness id; null falls back to the first available agent.
  String? _chosenAgentId;

  /// Pending config-option picks, keyed by option id (SPEC-27). Held locally —
  /// there is no session yet — and forwarded to `spawnSession` on send. Cleared
  /// when the harness changes (its catalog + defaults differ).
  final Map<String, Object> _picks = {};

  final TextEditingController _composerCtrl = TextEditingController();
  bool _spawning = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    final repos = ref.read(reposProvider).repos;
    _projectId =
        widget.initialProjectId ?? (repos.isNotEmpty ? repos.first.id : null);
    _baseBranch = _defaultBranchFor(_projectId);
    final worktrees = _worktreesFor(_projectId);
    _existingPath =
        widget.initialWorktree?.path ??
        (worktrees.isEmpty ? null : worktrees.first.path);
  }

  @override
  void dispose() {
    _composerCtrl.dispose();
    _branchNameCtrl.dispose();
    super.dispose();
  }

  /// Lazily fetch the open-PR list the first time the "From PR" source is
  /// selected — no network call while the dialog only shows Existing/New
  /// branch.
  void _loadPrs() {
    if (_prsFuture != null) return;
    final projectId = _projectId;
    final future = projectId == null
        ? Future.value(const <OpenPr>[])
        : ref.read(storeControllerProvider.notifier).listOpenPrs(projectId);
    // The PR panel builds its FutureBuilder lazily, so mark the request handled
    // to avoid an unhandled async error if it rejects before the panel shows.
    future.ignore();
    _prsFuture = future;
  }

  List<Worktree> _worktreesFor(String? projectId) {
    for (final r in ref.read(reposProvider).repos) {
      if (r.id == projectId) return sortWorktreesForDisplay(r.worktrees);
    }
    return const [];
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

  /// The effective harness id: the user's pick, else the first available agent,
  /// else the first listed, else null (host default).
  String? _effectiveAgentId(List<AgentDescriptor> agents) {
    if (_chosenAgentId != null) return _chosenAgentId;
    for (final a in agents) {
      if (a.available) return a.id;
    }
    return agents.isEmpty ? null : agents.first.id;
  }

  AgentDescriptor? _agentById(List<AgentDescriptor> agents, String? id) {
    for (final a in agents) {
      if (a.id == id) return a;
    }
    return null;
  }

  void _close() {
    if (_spawning) return;
    Navigator.of(context).pop();
  }

  /// Resolve (creating when needed) the worktree the session lands in.
  Future<({String? path, String? branch})> _resolveWorktree(
    String projectId,
  ) async {
    final store = ref.read(storeControllerProvider.notifier);
    switch (_source) {
      case WorktreeSource.existing:
        final wt = _selectedExistingWorktree();
        return (path: wt?.path ?? _existingPath, branch: wt?.branch);
      case WorktreeSource.newBranch:
        final name = _branchNameCtrl.text.trim();
        final r = await store.createWorktree(
          projectId,
          baseBranch: _effectiveBaseBranch(projectId),
          branchName: name.isEmpty ? null : name,
        );
        return (path: r.path, branch: r.branch);
      case WorktreeSource.fromPr:
        final pr = _prNumber;
        if (pr == null) throw StateError('Select a pull request first.');
        final r = await store.createWorktreeFromPr(projectId, pr);
        return (path: r.path, branch: r.branch);
    }
  }

  Worktree? _selectedExistingWorktree() {
    final worktrees = _worktreesFor(_projectId);
    for (final w in worktrees) {
      if (w.path == _existingPath) return w;
    }
    // Fall back to the first worktree — the value the dropdown displays when
    // _existingPath isn't among the current options — so the spawned worktree
    // always matches what the user sees.
    return worktrees.isEmpty ? null : worktrees.first;
  }

  /// The base branch actually used for a new-branch spawn: [_baseBranch] when it
  /// is a live option, else the first option (what [_newBranchPanel] displays).
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

  /// The single start action: resolve/create the worktree, spawn the session
  /// with the pending picks, send the first message, select it in the active
  /// pane, then close. Errors surface inline; a worktree created for this spawn
  /// (newBranch/fromPr) is removed on failure so a retry doesn't orphan it.
  Future<void> _start(String text) async {
    if (_spawning) return;
    final projectId = _projectId;
    if (projectId == null) return;
    final agents = ref.read(agentsProvider).value ?? const <AgentDescriptor>[];
    final agentId = _effectiveAgentId(agents);
    setState(() {
      _spawning = true;
      _error = null;
    });
    final store = ref.read(storeControllerProvider.notifier);
    // A newBranch/fromPr source CREATES a worktree in _resolveWorktree; track it
    // so a failed spawn can remove it (an `existing` source reuses one).
    String? createdWorktree;
    try {
      final (:path, :branch) = await _resolveWorktree(projectId);
      createdWorktree = _source == WorktreeSource.existing ? null : path;
      final picks = [
        for (final e in _picks.entries)
          ConfigOptionPick(id: e.key, value: e.value),
      ];
      final sid = await store.spawnSession(
        projectId,
        agent: agentId,
        worktreePath: path,
        branch: branch,
        configOptions: picks.isEmpty ? null : picks,
      );
      createdWorktree = null; // spawned — the worktree now hosts a session.
      if (!mounted) return;
      store.appendOptimisticMessage(sid, text);
      store.sendMessage(sid, text);
      selectSessionExclusive(ref, sid);
      Navigator.of(context).pop();
    } catch (e) {
      if (createdWorktree != null) {
        await store
            .removeWorktree(projectId, createdWorktree)
            .catchError((_) {});
      }
      if (!mounted) return;
      setState(() {
        _spawning = false;
        _error = '$e';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final agentsAsync = ref.watch(agentsProvider);
    final agents = agentsAsync.value ?? const <AgentDescriptor>[];
    final selectedAgentId = _effectiveAgentId(agents);
    final selectedAgent = _agentById(agents, selectedAgentId);

    return CallbackShortcuts(
      bindings: {const SingleActivator(LogicalKeyboardKey.escape): _close},
      child: Dialog(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 480, maxHeight: 640),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Header: title + ✕ (cancel). No footer button row (decision).
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 16, 12, 0),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        'New session',
                        style: theme.textTheme.titleLarge,
                      ),
                    ),
                    IconButton(
                      tooltip: 'Cancel',
                      icon: const Icon(Icons.close),
                      onPressed: _spawning ? null : _close,
                    ),
                  ],
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
                child: Text(
                  'Configure the session, then start it with your first '
                  'message.',
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
                      _worktreeField(theme),
                      const SizedBox(height: kSpace16),
                      _harnessField(theme, agentsAsync, selectedAgentId),
                      const SizedBox(height: kSpace16),
                      _firstMessageField(theme, selectedAgent, selectedAgentId),
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

  /// A worktree-panel row: a fixed-width inline label (e.g. "Open", "From",
  /// "Name") followed by its control, so the panels read as short sentences.
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

  Widget _worktreeField(ThemeData theme) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _fieldLabel(theme, 'Worktree'),
        SegmentedButton<WorktreeSource>(
          showSelectedIcon: false,
          segments: const [
            ButtonSegment(
              value: WorktreeSource.existing,
              label: Text('Existing'),
            ),
            ButtonSegment(
              value: WorktreeSource.newBranch,
              label: Text('New branch'),
            ),
            ButtonSegment(value: WorktreeSource.fromPr, label: Text('From PR')),
          ],
          selected: {_source},
          onSelectionChanged: _spawning
              ? null
              : (s) => setState(() {
                  _source = s.first;
                  if (_source == WorktreeSource.fromPr) _loadPrs();
                }),
        ),
        const SizedBox(height: kSpace10),
        switch (_source) {
          WorktreeSource.existing => _existingPanel(theme),
          WorktreeSource.newBranch => _newBranchPanel(theme),
          WorktreeSource.fromPr => _fromPrPanel(theme),
        },
      ],
    );
  }

  Widget _existingPanel(ThemeData theme) {
    final worktrees = _worktreesFor(_projectId);
    if (worktrees.isEmpty) {
      return Text(
        'No existing worktrees — pick “New branch” or “From PR”.',
        style: theme.textTheme.bodySmall?.copyWith(
          color: theme.colorScheme.outline,
        ),
      );
    }
    final value = worktrees.any((w) => w.path == _existingPath)
        ? _existingPath
        : worktrees.first.path;
    // Sync stale _existingPath to the fallback on first render when path was
    // not found in the list (e.g., worktree was deleted after pairing).
    if (value != _existingPath) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) setState(() => _existingPath = value);
      });
    }
    return _labeledRow(
      theme,
      'Open',
      DropdownButtonFormField<String>(
        key: ValueKey('existing-$_projectId'),
        initialValue: value,
        isExpanded: true,
        items: [
          for (final w in worktrees)
            DropdownMenuItem(
              value: w.path,
              child: Text(w.branch ?? w.path, overflow: TextOverflow.ellipsis),
            ),
        ],
        onChanged: _spawning ? null : (v) => setState(() => _existingPath = v),
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
            onChanged: _spawning
                ? null
                : (v) => setState(() => _baseBranch = v),
          );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _labeledRow(theme, 'From', fromControl),
        const SizedBox(height: kSpace10),
        _labeledRow(
          theme,
          'Branch',
          TextField(
            controller: _branchNameCtrl,
            enabled: !_spawning,
            // Mirror the server's slugifyBranch length cap (80) so the field
            // can't hold more than will survive, avoiding surprise truncation.
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
          key: const ValueKey('pr-picker'),
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
          onChanged: _spawning ? null : (v) => setState(() => _prNumber = v),
        );
      },
    );
  }

  Widget _harnessField(
    ThemeData theme,
    AsyncValue<List<AgentDescriptor>> agentsAsync,
    String? selectedAgentId,
  ) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _fieldLabel(theme, 'Harness'),
        agentsAsync.when(
          loading: () => const Center(
            child: Padding(
              padding: EdgeInsets.all(kSpace8),
              child: CircularProgressIndicator(),
            ),
          ),
          error: (e, _) => Text(
            'Could not load harnesses: $e',
            style: TextStyle(color: theme.colorScheme.error),
          ),
          data: (agents) {
            if (agents.isEmpty) {
              return Text(
                'Using the host default harness.',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.outline,
                ),
              );
            }
            return Wrap(
              spacing: 10,
              runSpacing: 10,
              children: [
                for (final a in agents)
                  HarnessCard(
                    agent: a,
                    selected: a.id == selectedAgentId,
                    onTap: (a.available && !_spawning)
                        ? () => setState(() {
                            _chosenAgentId = a.id;
                            // A new harness has its own catalog + defaults.
                            _picks.clear();
                          })
                        : null,
                  ),
              ],
            );
          },
        ),
      ],
    );
  }

  Widget _firstMessageField(
    ThemeData theme,
    AgentDescriptor? selectedAgent,
    String? selectedAgentId,
  ) {
    final options =
        selectedAgent?.configOptions ?? const <SessionConfigOption>[];
    final keymap = ref.watch(keymapProvider);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _fieldLabel(theme, 'First message'),
        // The composer sits directly inside the dialog surface. We drop its own
        // opaque backdrop (glass: true) and wrap it in a single bordered panel
        // so it reads as one clean input box instead of the composer's default
        // surface frame, which looked like an ugly white border in the dialog.
        DecoratedBox(
          decoration: BoxDecoration(
            color: theme.colorScheme.surfaceContainerHighest,
            borderRadius: BorderRadius.circular(kRadius12),
            border: Border.all(color: theme.colorScheme.outlineVariant),
          ),
          child: Composer(
            controller: _composerCtrl,
            onSend: _start,
            running: _spawning,
            alwaysExpanded: true,
            glass: true,
            sendChord: keymap.chordFor(ShortcutAction.sendMessage),
            newlineChord: keymap.chordFor(ShortcutAction.composerNewline),
            footerActions: [
              if (options.isNotEmpty)
                ConfigOptionPickRow(
                  options: options,
                  values: _picks,
                  agent: selectedAgentId ?? '',
                  onPick: (id, value) => setState(() => _picks[id] = value),
                ),
            ],
          ),
        ),
      ],
    );
  }
}
