import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/theme.dart';
import '../../shortcuts/keymap_controller.dart';
import '../../shortcuts/shortcut_action.dart';
import '../../store/cached_commands.dart';
import '../../store/composer_attachments.dart';
import '../../store/models.dart';
import '../../store/recent_models.dart';
import '../../store/store.dart';
import '../../ui/composer/attachment_controller.dart';
import '../../ui/composer/composer.dart';
import '../../ui/composer/composer_draft.dart';
import '../../ui/composer/composer_selectors.dart'
    show ModelConfigFooter, partitionConfigOptions;
import '../../ui/composer/model_picker_menu.dart';
import '../../ui/session/tool_renderers.dart' show kReadableContentMaxWidth;
import 'harness_picker.dart' show HarnessCard;
import 'pr_bar.dart';
import 'selected_worktree.dart';
import 'start_session.dart';
import 'starter_picks.dart';
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
  /// the live pane does. Mirrored into [composerDraftsProvider] under
  /// [_draftKey], because this widget does not outlive a tab switch.
  final TextEditingController _composer = TextEditingController();

  /// This starter's slot in the app-wide draft store (SPEC-45 D1) and in
  /// [starterPicksProvider] (D2). The draft store's own doc reserves this key
  /// space for "a session that hasn't started yet"; keyed by worktree path, not
  /// tab id, so both survive the tab being closed and reopened.
  String get _draftKey => 'starter:${widget.worktree.path}';

  /// The user-picked harness id; null falls back to the first available agent.
  /// Held in [starterPicksProvider], not in this State, because a tab switch
  /// disposes the pane (`split_view.dart` keys it by tab id).
  String? get _chosenAgentId =>
      ref.read(starterPicksProvider)[_draftKey]?.agentId;

  /// Pending config-option picks, keyed by option id, forwarded to the spawn.
  /// Dropped when the harness changes, since its catalog and defaults differ.
  Map<String, Object> get _picks =>
      ref.read(starterPicksProvider)[_draftKey]?.picks ?? const {};

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
    // The composer reports only the changes the *user* makes, so an injected
    // prompt has to be persisted here or a tab switch would drop it.
    ref.read(composerDraftsProvider.notifier).set(_draftKey, _composer.text);
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
            // SPEC-31 (decision a): keep the sheet open. The store write rebuilds
            // the footer chips; setSheetState rebuilds the sheet with the new
            // active value derived from the picks (revealing its flyout).
            ref
                .read(starterPicksProvider.notifier)
                .setPick(_draftKey, model.id, value);
            setSheetState(() {});
          },
          onPickOption: (id, value) {
            ref
                .read(starterPicksProvider.notifier)
                .setPick(_draftKey, id, value);
            setSheetState(() {});
          },
        );
      },
    );
  }

  Future<void> _start(String text) async {
    if (_spawning) return;
    final agents = ref.read(agentsProvider).value ?? const <AgentDescriptor>[];
    // Captured before the await: the spawn rebinds this pane to the new session,
    // so `ref` may be dead by the time the images are taken.
    final staged = ref.read(composerAttachmentsProvider.notifier);
    // Same reason: the picks are spent once the session exists, and clearing
    // them below happens after the await.
    final pending = ref.read(starterPicksProvider.notifier);
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
        // Taken after the spawn lands, so a refused spawn leaves the chips (and
        // their finished uploads) in place — SPEC-45 D6.
        takeAttachments: () => takeAttachmentsFrom(staged, _draftKey),
      );
      // The pending session is now a real one, so its harness/model picks are
      // spent — exactly as the sent message's draft text is pruned. A refused
      // spawn keeps them, so the user can fix the cause and send again.
      pending.clear(_draftKey);
    } catch (e) {
      if (!mounted) return;
      // The composer clears its field on send, so a refused spawn would take the
      // message with it. Give it back — the images are still staged (D6), and a
      // send that never happened must not cost the user their text.
      _composer.text = text;
      _composer.selection = TextSelection.collapsed(offset: text.length);
      ref.read(composerDraftsProvider.notifier).set(_draftKey, text);
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
    // Watched so a harness or model pick repaints the cards and the footer: the
    // picks live in the store now, not in this State, so `setState` no longer
    // sees them change (SPEC-45 D2).
    ref.watch(starterPicksProvider);
    final selectedId = _effectiveAgentId(agents);
    AgentDescriptor? selected;
    for (final a in agents) {
      if (a.id == selectedId) selected = a;
    }
    final options = selected?.configOptions ?? const <SessionConfigOption>[];
    final keymap = ref.watch(keymapProvider);
    final branch = widget.worktree.branch;
    // The worktree behind the next-step bar, from the poller-refreshed snapshot.
    // Watched here, not in a `Builder` around the bar: `ref.watch` registers
    // against this ConsumerState wherever it is called, so a `Builder` bought no
    // rebuild isolation — only an extra element. `desktop_chat_pane.dart` states
    // the same reason at its own call site.
    final at = ref.watch(reposProvider).locateWorktree(worktreePath);
    // Watched, not read: a live session in this project can populate the cache
    // while this pane is open, and the palette should pick it up.
    ref.watch(cachedCommandsControllerProvider);
    final cachedCommands = selectedId == null
        ? const <SlashCmd>[]
        : ref
              .read(cachedCommandsControllerProvider.notifier)
              .commandsFor(selectedId, widget.worktree.projectId);

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
                            // `chooseAgent` drops the previous harness's picks:
                            // the new one has its own catalog and defaults, so
                            // stale picks can't carry over.
                            ? () => ref
                                  .read(starterPicksProvider.notifier)
                                  .chooseAgent(_draftKey, a.id)
                            : null,
                      ),
                  ],
                ),
              const SizedBox(height: kSpace16),
              Composer(
                controller: _composer,
                // Survive the pane being recreated — a tab switch keys
                // `DesktopChatPane` by tab id — exactly as the live pane does.
                initialText: ref.read(composerDraftsProvider)[_draftKey],
                onDraftChanged: (text) => ref
                    .read(composerDraftsProvider.notifier)
                    .set(_draftKey, text),
                onSend: _start,
                running: _spawning,
                alwaysExpanded: true,
                // SPEC-45: an image can be attached to the message that *starts*
                // the session — `POST /media` is content-addressed and needs no
                // session, and the server materialises the file into the cwd this
                // spawn already resolved.
                attachments: draftAttachments(context, ref, _draftKey),
                // SPEC-45: agent commands only ever arrive on a live session, so
                // the palette offers what a session of this harness in this
                // project last advertised. Possibly stale, and unmarked: a skill
                // list changes far less often than a session starts.
                commands: cachedCommands,
                // No client commands here: `_start` spawns and sends, it does not
                // route through `handleClientCommand` (which needs a session id),
                // so `/model` would arrive at the new agent as literal text.
                clientCommands: false,
                // The same next-step bar a live session's composer carries. A
                // fresh worktree usually has *more* to say here than a running
                // one (nothing pushed, no PR yet), so omitting it made the
                // starter feel like a lesser pane.
                header: PrComposerBar(
                  // `at` is null until the repos snapshot carries the worktree
                  // this starter just created — its common state. The branch is
                  // known regardless, so pass it: without it the bar reads
                  // `detached`, and the wrap-up confirm could name no branch and
                  // send no `expectBranch`.
                  status: prStatusFor(at, fallbackBranch: branch),
                  pr: at?.worktree.pr,
                  projectId: at?.repo.id,
                  worktreePath: worktreePath,
                  branch: at?.worktree.branch ?? branch,
                  uncommittedFiles: at?.worktree.uncommittedFiles ?? 0,
                  onInsertPrompt: _insertPrompt,
                ),
                sendChord: keymap.chordFor(ShortcutAction.sendMessage),
                newlineChord: keymap.chordFor(ShortcutAction.composerNewline),
                footerActions: [
                  if (options.isNotEmpty)
                    ModelConfigFooter(
                      options: options,
                      values: _picks,
                      agent: selectedId ?? '',
                      onPick: (id, value) => ref
                          .read(starterPicksProvider.notifier)
                          .setPick(_draftKey, id, value),
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
