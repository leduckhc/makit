import 'package:flutter/material.dart';
import 'package:phosphoricons_flutter/phosphoricons_flutter.dart';

import '../../app/theme.dart';
import '../../store/models.dart';
import '../widgets/sheet_header.dart';
import 'repo_chips.dart' show AgentAvatar;

/// Which worktree a new session lands on (SPEC-27, decision 2): an
/// already-checked-out worktree, a fresh fork off a base branch, or a fork on
/// an open PR's head branch. Shared by the mobile sheet and the desktop dialog.
enum WorktreeSource { existing, newBranch, fromPr }

/// Choice returned by [NewSessionSheet]: the harness, the worktree source and
/// its selection, and the pre-spawn config picks (SPEC-27). The caller
/// (`repo_card`) maps [source] to the matching `spawnSession` arguments.
class NewSessionChoice {
  const NewSessionChoice({
    this.agent,
    this.source = WorktreeSource.newBranch,
    this.worktreePath,
    this.baseBranch,
    this.prNumber,
    this.configOptions = const [],
  });

  /// The chosen harness id, or null to use the host default.
  final String? agent;

  /// Which worktree flow the user picked.
  final WorktreeSource source;

  /// The existing worktree path when [source] is [WorktreeSource.existing].
  final String? worktreePath;

  /// The base branch to fork from when [source] is [WorktreeSource.newBranch].
  final String? baseBranch;

  /// The PR number to fork from when [source] is [WorktreeSource.fromPr].
  final int? prNumber;

  /// Pre-spawn config picks for the chosen harness, forwarded through
  /// `spawnSession` and applied at launch (SPEC-27). Empty for default-only.
  final List<ConfigOptionPick> configOptions;
}

/// Bottom sheet to configure a new session on mobile (SPEC-27): a worktree
/// source toggle (Existing / New branch / From PR), a horizontally scrollable
/// row of harness cards, and tappable config rows rendering the selected
/// harness's cached [AgentDescriptor.configOptions]. Unlike desktop the
/// composer is *not* folded in — [Start] pops a [NewSessionChoice] and the app
/// then lands on the full-screen session. Pops null if dismissed.
class NewSessionSheet extends StatefulWidget {
  const NewSessionSheet({
    super.key,
    required this.agents,
    required this.branches,
    this.worktrees = const [],
    this.openPrs = const [],
    this.initialBranch,
    this.initialWorktreePath,
  });

  final List<AgentDescriptor> agents;
  final List<String> branches;
  final List<Worktree> worktrees;
  final List<OpenPr> openPrs;
  final String? initialBranch;

  /// Pre-select this existing worktree and open on the "Existing" source.
  ///
  /// Set when the sheet is opened from a worktree row's `+`: the user already
  /// said which branch they meant, so asking again would be the one question
  /// they've already answered.
  final String? initialWorktreePath;

  @override
  State<NewSessionSheet> createState() => _NewSessionSheetState();
}

class _NewSessionSheetState extends State<NewSessionSheet> {
  late WorktreeSource _source;
  String? _agent;
  String? _branch;
  String? _worktreePath;
  int? _prNumber;

  /// Local pre-spawn picks, keyed by option id. Reset whenever the harness
  /// changes since options differ per harness.
  final Map<String, Object> _picks = {};

  @override
  void initState() {
    super.initState();
    // A caller-named worktree means the worktree decision is already made.
    final targeted =
        widget.initialWorktreePath != null &&
        widget.worktrees.any((w) => w.path == widget.initialWorktreePath);
    _source = targeted ? WorktreeSource.existing : WorktreeSource.newBranch;
    _branch =
        widget.initialBranch ??
        (widget.branches.isEmpty ? null : widget.branches.first);
    _worktreePath = targeted
        ? widget.initialWorktreePath
        : (widget.worktrees.isEmpty ? null : _defaultWorktree().path);
    _agent = widget.agents.isEmpty ? null : widget.agents.first.id;
  }

  Worktree _defaultWorktree() => widget.worktrees.firstWhere(
    (w) => w.isPrimary,
    orElse: () => widget.worktrees.first,
  );

  AgentDescriptor? get _selectedDescriptor {
    for (final a in widget.agents) {
      if (a.id == _agent) return a;
    }
    return widget.agents.isEmpty ? null : widget.agents.first;
  }

  List<SessionConfigOption> get _options =>
      _selectedDescriptor?.configOptions ?? const [];

  void _selectAgent(String id) {
    if (id == _agent) return;
    setState(() {
      _agent = id;
      _picks.clear();
    });
  }

  Object _currentValue(SessionConfigOption option) =>
      _picks[option.id] ?? option.currentValue;

  List<ConfigOptionPick> get _picksList => [
    for (final entry in _picks.entries)
      ConfigOptionPick(id: entry.key, value: entry.value),
  ];

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return SafeArea(
      child: SingleChildScrollView(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 4, 20, 16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text('New session', style: theme.textTheme.titleMedium),
              const SizedBox(height: kSpace16),
              _worktreeField(theme),
              if (widget.agents.isNotEmpty) ...[
                const SizedBox(height: kSpace16),
                _fieldLabel(theme, 'Harness'),
                const SizedBox(height: kSpace8),
                _harnessRow(),
              ],
              if (_options.isNotEmpty) ...[
                const SizedBox(height: kSpace16),
                _fieldLabel(theme, 'Config'),
                const SizedBox(height: kSpace4),
                for (final option in _options)
                  ConfigRow(
                    option: option,
                    currentValue: _currentValue(option),
                    agent: _agent ?? '',
                    onChanged: (value) =>
                        setState(() => _picks[option.id] = value),
                  ),
              ],
              const SizedBox(height: kSpace20),
              FilledButton(
                onPressed: _canStart ? _onStart : null,
                child: const Text('Start'),
              ),
              const SizedBox(height: kSpace8),
              Text(
                'Opens the session; type your first message there.',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.outline,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// The active source has a valid selection to start from. Guards against
  /// spawning a plain default-branch session when the user is on "existing"
  /// with no worktree, or on "From PR" without a PR picked.
  bool get _canStart => switch (_source) {
    WorktreeSource.existing => _worktreePath != null,
    WorktreeSource.newBranch => true,
    WorktreeSource.fromPr => _prNumber != null,
  };

  void _onStart() {
    Navigator.pop(
      context,
      NewSessionChoice(
        agent: _agent,
        source: _source,
        worktreePath: _source == WorktreeSource.existing ? _worktreePath : null,
        baseBranch: _source == WorktreeSource.newBranch ? _branch : null,
        prNumber: _source == WorktreeSource.fromPr ? _prNumber : null,
        configOptions: _picksList,
      ),
    );
  }

  Widget _fieldLabel(ThemeData theme, String text) => Text(
    text,
    style: theme.textTheme.labelMedium?.copyWith(
      color: theme.colorScheme.onSurfaceVariant,
      fontWeight: FontWeight.w600,
    ),
  );

  Widget _worktreeField(ThemeData theme) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _fieldLabel(theme, 'Worktree'),
        const SizedBox(height: kSpace8),
        SegmentedButton<WorktreeSource>(
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
          showSelectedIcon: false,
          onSelectionChanged: (s) => setState(() => _source = s.first),
        ),
        const SizedBox(height: kSpace8),
        _worktreeSelector(theme),
      ],
    );
  }

  Widget _worktreeSelector(ThemeData theme) {
    switch (_source) {
      case WorktreeSource.existing:
        if (widget.worktrees.isEmpty) {
          return _emptyHint(theme, 'No existing worktrees.');
        }
        final selected = widget.worktrees.firstWhere(
          (w) => w.path == _worktreePath,
          orElse: _defaultWorktree,
        );
        return _RowSelect(
          value: selected.branch ?? selected.path,
          sub: selected.isPrimary ? 'primary' : null,
          onTap: _pickExistingWorktree,
        );
      case WorktreeSource.newBranch:
        if (widget.branches.isEmpty) {
          return _emptyHint(theme, 'No branches to fork from.');
        }
        return _RowSelect(
          value: _branch ?? widget.branches.first,
          sub: 'Branch from',
          onTap: _pickBranch,
        );
      case WorktreeSource.fromPr:
        if (widget.openPrs.isEmpty) {
          return _emptyHint(theme, 'No open PRs.');
        }
        final selected = _prNumber == null
            ? null
            : widget.openPrs.firstWhere(
                (p) => p.number == _prNumber,
                orElse: () => widget.openPrs.first,
              );
        return _RowSelect(
          value: selected?.title ?? 'Choose a PR',
          sub: selected == null ? null : '#${selected.number}',
          onTap: _pickPr,
        );
    }
  }

  Widget _emptyHint(ThemeData theme, String text) => Padding(
    padding: const EdgeInsets.symmetric(vertical: kSpace8),
    child: Text(
      text,
      style: theme.textTheme.bodySmall?.copyWith(
        color: theme.colorScheme.outline,
      ),
    ),
  );

  Widget _harnessRow() {
    return SizedBox(
      height: 92,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        itemCount: widget.agents.length,
        separatorBuilder: (_, _) => const SizedBox(width: kSpace10),
        itemBuilder: (context, i) {
          final agent = widget.agents[i];
          return _HarnessCard(
            agent: agent,
            selected: agent.id == _agent,
            onTap: agent.available ? () => _selectAgent(agent.id) : null,
          );
        },
      ),
    );
  }

  Future<void> _pickBranch() async {
    final picked = await _pickFromList<String>(
      title: 'Branch from',
      items: widget.branches,
      current: _branch,
      labelOf: (b) => b,
    );
    if (picked != null) setState(() => _branch = picked);
  }

  Future<void> _pickExistingWorktree() async {
    final picked = await _pickFromList<Worktree>(
      title: 'Worktree',
      items: widget.worktrees,
      current: _worktreePath,
      valueOf: (w) => w.path,
      labelOf: (w) => w.branch ?? w.path,
      subOf: (w) => w.isPrimary ? 'primary' : null,
    );
    if (picked != null) setState(() => _worktreePath = picked.path);
  }

  Future<void> _pickPr() async {
    final picked = await _pickFromList<OpenPr>(
      title: 'Open PRs',
      items: widget.openPrs,
      current: _prNumber,
      valueOf: (p) => p.number,
      labelOf: (p) => p.title,
      subOf: (p) => '#${p.number} · ${p.headRefName}',
    );
    if (picked != null) setState(() => _prNumber = picked.number);
  }

  /// Generic single-choice picker sheet: renders [items] as tiles and pops the
  /// tapped one. [valueOf] identifies the current selection (defaults to the
  /// item itself).
  Future<T?> _pickFromList<T>({
    required String title,
    required List<T> items,
    required Object? current,
    required String Function(T) labelOf,
    Object? Function(T)? valueOf,
    String? Function(T)? subOf,
  }) {
    Object? idOf(T item) => valueOf == null ? item : valueOf(item);
    return showModalBottomSheet<T>(
      context: context,
      showDragHandle: true,
      builder: (sheetContext) => SafeArea(
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              SheetHeader(title: title),
              for (final item in items)
                ListTile(
                  title: Text(labelOf(item)),
                  subtitle: subOf?.call(item) == null
                      ? null
                      : Text(subOf!(item)!),
                  trailing: idOf(item) == current
                      ? const Icon(PhosphorIconsLight.check)
                      : null,
                  onTap: () => Navigator.pop(sheetContext, item),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

/// A tappable value row (label + optional sub-label + caret), matching the
/// mockup's `.row-select`.
class _RowSelect extends StatelessWidget {
  const _RowSelect({required this.value, required this.onTap, this.sub});

  final String value;
  final String? sub;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(kRadius12),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: kSpace12),
        decoration: BoxDecoration(
          color: cs.surfaceContainerHighest,
          border: Border.all(color: cs.outlineVariant),
          borderRadius: BorderRadius.circular(kRadius12),
        ),
        child: Row(
          children: [
            Expanded(
              child: Text(value, maxLines: 1, overflow: TextOverflow.ellipsis),
            ),
            if (sub != null) ...[
              Text(
                sub!,
                style: theme.textTheme.bodySmall?.copyWith(color: cs.outline),
              ),
              const SizedBox(width: kSpace8),
            ],
            Icon(PhosphorIconsLight.caretDown, size: 16, color: cs.outline),
          ],
        ),
      ),
    );
  }
}

/// A selectable harness card: agent avatar + name + transport, with an accent
/// ring + check when selected and dimmed when unavailable.
class _HarnessCard extends StatelessWidget {
  const _HarnessCard({required this.agent, required this.selected, this.onTap});

  final AgentDescriptor agent;
  final bool selected;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final card = Container(
      width: 120,
      padding: const EdgeInsets.all(kSpace12),
      decoration: BoxDecoration(
        color: selected ? cs.primaryContainer : cs.surfaceContainerHighest,
        border: Border.all(
          color: selected ? cs.primary : cs.outlineVariant,
          width: selected ? 2 : 1,
        ),
        borderRadius: BorderRadius.circular(14),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              AgentAvatar(agent: agent.id, size: 20),
              if (selected)
                Icon(PhosphorIconsLight.check, size: 16, color: cs.primary),
            ],
          ),
          const SizedBox(height: kSpace8),
          Text(
            agent.label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.titleSmall?.copyWith(
              fontWeight: FontWeight.w600,
            ),
          ),
          Text(
            agent.transport,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.bodySmall?.copyWith(color: cs.outline),
          ),
        ],
      ),
    );
    final content = Opacity(opacity: agent.available ? 1 : 0.5, child: card);
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(14),
      child: content,
    );
  }
}

/// One tappable config-option row (SPEC-27 mobile): the option [name] plus its
/// current value. Boolean options render a [Switch]; select options open a
/// picker of the option's values/groups. Reports the new pick via [onChanged].
class ConfigRow extends StatelessWidget {
  const ConfigRow({
    super.key,
    required this.option,
    required this.currentValue,
    required this.agent,
    required this.onChanged,
  });

  final SessionConfigOption option;
  final Object currentValue;
  final String agent;
  final ValueChanged<Object> onChanged;

  @override
  Widget build(BuildContext context) {
    if (option.type == ConfigOptionType.boolean) {
      final on = currentValue == true;
      return SwitchListTile(
        contentPadding: EdgeInsets.zero,
        title: Text(option.name),
        subtitle: option.description == null ? null : Text(option.description!),
        value: on,
        onChanged: onChanged,
      );
    }

    final value = currentValue is String ? currentValue as String : '';
    return ListTile(
      contentPadding: EdgeInsets.zero,
      title: Text(option.name),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(_displayName(value)),
          const SizedBox(width: kSpace4),
          Icon(
            PhosphorIconsLight.caretDown,
            size: 16,
            color: Theme.of(context).colorScheme.outline,
          ),
        ],
      ),
      onTap: () => _pick(context, value),
    );
  }

  List<ConfigOptionValue> get _allValues => [
    ...option.options,
    for (final g in option.groups) ...g.options,
  ];

  String _displayName(String value) {
    for (final v in _allValues) {
      if (v.value == value) return v.name;
    }
    return value.isEmpty ? option.name : value;
  }

  Future<void> _pick(BuildContext context, String current) async {
    final picked = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (sheetContext) {
        Widget tile(ConfigOptionValue v) => ListTile(
          title: Text(v.name),
          subtitle: v.description == null ? null : Text(v.description!),
          trailing: v.value == current
              ? const Icon(PhosphorIconsLight.check)
              : null,
          onTap: () => Navigator.pop(sheetContext, v.value),
        );
        return SafeArea(
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                SheetHeader(title: option.name),
                if (option.groups.isNotEmpty)
                  for (final group in option.groups) ...[
                    Padding(
                      padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
                      child: Text(
                        group.name,
                        style: Theme.of(sheetContext).textTheme.labelSmall
                            ?.copyWith(
                              color: Theme.of(
                                sheetContext,
                              ).colorScheme.onSurfaceVariant,
                            ),
                      ),
                    ),
                    for (final v in group.options) tile(v),
                  ]
                else
                  for (final v in option.options) tile(v),
              ],
            ),
          ),
        );
      },
    );
    if (picked != null && picked != current) onChanged(picked);
  }
}
