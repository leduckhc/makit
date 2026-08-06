import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/theme.dart';
import '../../shortcuts/keymap_controller.dart';
import '../../shortcuts/shortcut_action.dart';
import '../../store/models.dart';
import '../../store/recent_models.dart';
import '../../store/store.dart';
import '../../ui/composer/composer.dart';
import '../../ui/composer/composer_selectors.dart'
    show ModelConfigFooter, partitionConfigOptions;
import '../../ui/composer/model_picker_menu.dart';
import '../../ui/session/tool_renderers.dart' show kReadableContentMaxWidth;
import 'harness_picker.dart' show HarnessCard;
import 'pr_bar.dart';
import 'selected_worktree.dart';
import 'start_session.dart';
import '../../ui/widgets/pr_signals.dart';

/// The in-pane start surface for a sessionless pane that already knows its
/// [worktree] (a worktree row, a split tab, or ⌘T): pick the harness, adjust its
/// model / reasoning pills, and type the first message — sending spawns the
/// session in that worktree. The pills read the harness's cached catalog
/// ([AgentDescriptor.configOptions]) because there is no live session to read
/// them off yet; the picks ride the spawn and apply at launch (SPEC-27).
class WorktreeStarter extends ConsumerStatefulWidget {
  /// Creates the starter for [worktree].
  const WorktreeStarter({super.key, required this.worktree});

  /// The worktree the session will start in.
  final SelectedWorktree worktree;

  @override
  ConsumerState<WorktreeStarter> createState() => _WorktreeStarterState();
}

class _WorktreeStarterState extends ConsumerState<WorktreeStarter> {
  /// The composer's text, so a canned PR prompt can be dropped into it the way
  /// the live pane does.
  final TextEditingController _composer = TextEditingController();

  /// The user-picked harness id; null falls back to the first available agent.
  String? _chosenAgentId;

  /// Pending config-option picks, keyed by option id. Held locally (no session
  /// yet) and forwarded to the spawn. Cleared when the harness changes, since
  /// its catalog and defaults differ.
  final Map<String, Object> _picks = {};

  bool _spawning = false;
  String? _error;

  /// The harness that will launch: the picked one, else the first available.
  String? _effectiveAgentId(List<AgentDescriptor> agents) {
    if (_chosenAgentId != null) return _chosenAgentId;
    for (final a in agents) {
      if (a.available) return a.id;
    }
    return agents.isEmpty ? null : agents.first.id;
  }

  /// Appends a canned PR prompt to the composer rather than sending it: the
  /// worktree has no agent yet, so there is nothing to send it to.
  void _insertPrompt(String prompt) {
    final existing = _composer.text.trimRight();
    _composer.text = existing.isEmpty ? prompt : '$existing\n\n$prompt';
    _composer.selection = TextSelection.collapsed(
      offset: _composer.text.length,
    );
  }

  @override
  void dispose() {
    _composer.dispose();
    super.dispose();
  }

  /// The active harness's config options (its catalog), or empty when none is
  /// resolved yet.
  List<SessionConfigOption> get _currentOptions {
    final agents = ref.read(agentsProvider).value ?? const <AgentDescriptor>[];
    final id = _effectiveAgentId(agents);
    for (final a in agents) {
      if (a.id == id) return a.configOptions;
    }
    return const <SessionConfigOption>[];
  }

  /// The active harness id (empty when none resolved).
  String get _currentAgent {
    final agents = ref.read(agentsProvider).value ?? const <AgentDescriptor>[];
    return _effectiveAgentId(agents) ?? '';
  }

  /// Builds the model picker menu for the draft (SPEC-31). Backed by the local
  /// pending [_picks] (fallback to each option's `currentValue`) — there is no
  /// live session, so a model select updates the draft only: it never records
  /// recents (a live-session gesture) or dispatches an action (the picks ride
  /// the spawn and apply at launch, SPEC-27). Surfaces the user's existing
  /// Recent models read-only.
  Widget _buildDraftModelPicker(BuildContext context) {
    final partition = partitionConfigOptions(_currentOptions);
    final model = partition.model;
    if (model == null) return const SizedBox.shrink();
    final recent = ref
        .read(recentModelsControllerProvider.notifier)
        .recentModels(_currentAgent);
    return StatefulBuilder(
      builder: (ctx, setSheetState) {
        final values = {
          for (final o in _currentOptions) o.id: _picks[o.id] ?? o.currentValue,
        };
        final active = values[model.id];
        return ModelPickerMenu(
          modelOption: model,
          activeValue: active is String ? active : '',
          recent: recent,
          modelScoped: partition.modelScoped,
          values: values,
          agent: _currentAgent,
          onSelectModel: (value) {
            // SPEC-31 (decision a): keep the sheet open. The outer setState
            // updates the footer chips; setSheetState rebuilds the sheet with
            // the new active value derived from _picks (revealing its flyout).
            setState(() => _picks[model.id] = value);
            setSheetState(() {});
          },
          onPickOption: (id, value) {
            setState(() => _picks[id] = value);
            setSheetState(() {});
          },
        );
      },
    );
  }

  Future<void> _start(String text) async {
    if (_spawning) return;
    final agents = ref.read(agentsProvider).value ?? const <AgentDescriptor>[];
    setState(() {
      _spawning = true;
      _error = null;
    });
    try {
      await startSessionInWorktree(
        ref,
        projectId: widget.worktree.projectId,
        text: text,
        agent: _effectiveAgentId(agents),
        worktreePath: widget.worktree.path,
        branch: widget.worktree.branch,
        picks: _picks,
      );
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
    final theme = Theme.of(context);
    final worktreePath = widget.worktree.path;
    final agentsAsync = ref.watch(agentsProvider);
    final agents = agentsAsync.value ?? const <AgentDescriptor>[];
    final selectedId = _effectiveAgentId(agents);
    AgentDescriptor? selected;
    for (final a in agents) {
      if (a.id == selectedId) selected = a;
    }
    final options = selected?.configOptions ?? const <SessionConfigOption>[];
    final keymap = ref.watch(keymapProvider);
    final branch = widget.worktree.branch;

    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: kReadableContentMaxWidth),
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(kSpace24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('Choose a harness', style: theme.textTheme.titleMedium),
              const SizedBox(height: kSpace4),
              Text(
                branch == null
                    ? 'Then send a message to start the session.'
                    : 'Then send a message to start the session on $branch.',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.outline,
                ),
              ),
              const SizedBox(height: kSpace16),
              if (agentsAsync.isLoading && agents.isEmpty)
                const Center(child: CircularProgressIndicator())
              else if (agents.isEmpty)
                Text(
                  'Using the host default harness.',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.outline,
                  ),
                )
              else
                Wrap(
                  spacing: 12,
                  runSpacing: 12,
                  children: [
                    for (final a in agents)
                      HarnessCard(
                        agent: a,
                        selected: a.id == selectedId,
                        onTap: a.available
                            ? () => setState(() {
                                _chosenAgentId = a.id;
                                // The new harness has its own catalog and
                                // defaults, so stale picks can't carry over.
                                _picks.clear();
                              })
                            : null,
                      ),
                  ],
                ),
              const SizedBox(height: kSpace16),
              // The same next-step bar a live session gets. A fresh worktree
              // usually has *more* to say here than a running one (nothing
              // pushed, no PR yet), so omitting it made the starter feel like a
              // lesser pane.
              Builder(
                builder: (context) {
                  final at = ref
                      .watch(reposProvider)
                      .locateWorktree(worktreePath);
                  return PrComposerBar(
                    status: prStatusFor(at),
                    pr: at?.worktree.pr,
                    projectId: at?.repo.id,
                    worktreePath: worktreePath,
                    branch: at?.worktree.branch,
                    uncommittedFiles: at?.worktree.uncommittedFiles ?? 0,
                    onInsertPrompt: _insertPrompt,
                  );
                },
              ),
              const SizedBox(height: kSpace8),
              Composer(
                controller: _composer,
                onSend: _start,
                running: _spawning,
                alwaysExpanded: true,
                sendChord: keymap.chordFor(ShortcutAction.sendMessage),
                newlineChord: keymap.chordFor(ShortcutAction.composerNewline),
                footerActions: [
                  if (options.isNotEmpty)
                    ModelConfigFooter(
                      options: options,
                      values: _picks,
                      agent: selectedId ?? '',
                      onPick: (id, value) => setState(() => _picks[id] = value),
                      desktop: true,
                      menuBuilder: _buildDraftModelPicker,
                    ),
                ],
              ),
              if (_error != null) ...[
                const SizedBox(height: kSpace8),
                Text(
                  _error!,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.error,
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
