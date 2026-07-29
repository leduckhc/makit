import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/theme.dart';
import '../../shortcuts/keymap_controller.dart';
import '../../shortcuts/shortcut_action.dart';
import '../../store/models.dart';
import '../../store/store.dart';
import '../../ui/composer/composer.dart';
import '../../ui/composer/composer_selectors.dart' show ConfigOptionPickRow;
import '../../ui/session/tool_renderers.dart' show kReadableContentMaxWidth;
import 'harness_picker.dart' show HarnessCard;
import 'selected_worktree.dart';
import 'start_session.dart';

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
              Composer(
                onSend: _start,
                running: _spawning,
                alwaysExpanded: true,
                sendChord: keymap.chordFor(ShortcutAction.sendMessage),
                newlineChord: keymap.chordFor(ShortcutAction.composerNewline),
                footerActions: [
                  if (options.isNotEmpty)
                    ConfigOptionPickRow(
                      options: options,
                      values: _picks,
                      agent: selectedId ?? '',
                      onPick: (id, value) => setState(() => _picks[id] = value),
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
