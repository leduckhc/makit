import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:phosphoricons_flutter/phosphoricons_flutter.dart';

import '../../app/theme.dart';
import '../../store/models.dart';
import '../../store/store.dart';
import '../home/repo_chips.dart' show AgentAvatar;
import '../widgets/searchable_list_sheet.dart';
import '../widgets/sheet_header.dart';
import '../../store/recent_models.dart';
import 'client_commands.dart';
import 'model_picker_menu.dart';

/// The `category` values (SPEC-31, Makit UX policy — *not* ACP semantics) whose
/// options are folded into the model picker as flyout segments. `model` itself
/// is the picker's list; everything else stays a standalone pill. Conservative
/// on purpose: unknown/`_`-prefixed categories are never folded.
const Set<String> kModelScopedCategories = {'model_config', 'thought_level'};

/// Every choice across a select option's flat `options` plus all grouped
/// `options`, in order.
List<ConfigOptionValue> allConfigValues(SessionConfigOption option) => [
  ...option.options,
  for (final g in option.groups) ...g.options,
];

/// Human label for [value] within [option]: the matching choice's name, else
/// the raw value (or the option name when [value] is empty).
String configValueName(SessionConfigOption option, String value) {
  for (final v in allConfigValues(option)) {
    if (v.value == value) return v.name;
  }
  return value.isEmpty ? option.name : value;
}

/// Splits an ordered [SessionConfigOption] list into the single `model` option
/// (or null when the session advertises none), the model-scoped options folded
/// into the picker's flyout ([kModelScopedCategories], in agent order), and the
/// standalone options rendered as their own pills (everything else, in agent
/// order). Pure — the footer + menu are built from this partition (SPEC-31).
({
  SessionConfigOption? model,
  List<SessionConfigOption> modelScoped,
  List<SessionConfigOption> standalone,
})
partitionConfigOptions(List<SessionConfigOption> options) {
  SessionConfigOption? model;
  final modelScoped = <SessionConfigOption>[];
  final standalone = <SessionConfigOption>[];
  for (final option in options) {
    if (option.category == 'model') {
      model ??= option;
    } else if (kModelScopedCategories.contains(option.category)) {
      modelScoped.add(option);
    } else {
      standalone.add(option);
    }
  }
  return (model: model, modelScoped: modelScoped, standalone: standalone);
}

/// Small rounded pill used in the composer footer: a leading widget (agent
/// avatar or icon) + a short label, tappable to open a picker. Kept visually
/// low-key so it reads as an inline control, not a primary button.
class _ComposerPill extends StatelessWidget {
  const _ComposerPill({
    required this.leading,
    required this.label,
    required this.onTap,
    this.tooltip,
  });

  final Widget leading;
  final String label;
  final VoidCallback onTap;
  final String? tooltip;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final pill = InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(14),
      child: Padding(
        padding: const EdgeInsets.symmetric(
          horizontal: kSpace8,
          vertical: kSpace4,
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            leading,
            const SizedBox(width: kSpace6),
            Flexible(
              child: Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.labelMedium?.copyWith(
                  color: cs.onSurfaceVariant,
                ),
              ),
            ),
          ],
        ),
      ),
    );
    return tooltip == null ? pill : Tooltip(message: tooltip!, child: pill);
  }
}

/// Composer-footer control that shows the session's current model and, on tap,
/// opens the model picker (reusing the `/model` client command). Renders
/// nothing until `session.meta` has arrived with a non-empty models list — the
/// client fetches the selectable models asynchronously, so there is simply no
/// selector to show in the meantime.
class ComposerModelSelector extends ConsumerWidget {
  /// Creates the model selector for [sessionId].
  const ComposerModelSelector({super.key, required this.sessionId});

  /// The session whose model this selector reads and switches.
  final String sessionId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final meta = ref.watch(sessionMetaProvider(sessionId));
    if (meta == null || meta.models.isEmpty) return const SizedBox.shrink();
    final agent = ref.watch(sessionsProvider).byId(sessionId)?.agent ?? '';
    return _ComposerPill(
      leading: AgentAvatar(agent: agent, size: 16),
      label: meta.model?.name ?? 'model',
      tooltip: 'Model',
      onTap: () => handleClientCommand(
        '/model',
        context: context,
        ref: ref,
        sessionId: sessionId,
      ),
    );
  }
}

/// Ascending signal-bar indicator for the reasoning-effort level. One bar per
/// entry in [thinkingLevels] (off → xhigh): bars at or below [level] paint in
/// the strong accent, bars above it fade to show the remaining headroom. An
/// unrecognised [level] leaves every bar faded.
class ThinkingSignal extends StatelessWidget {
  /// Creates the indicator for the current [level] (e.g. `'high'`).
  const ThinkingSignal({super.key, required this.level, this.size = 16});

  /// The active thinking level; matched against [thinkingLevels] by name.
  final String level;

  /// The overall height of the tallest bar (the box is [size] tall).
  final double size;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final current = thinkingLevels.indexOf(level);
    // Neutral "ink" from the theme (near-black in light, near-white in dark) so
    // the indicator adapts to both themes without a colour accent. Bars above
    // the current level drop to a low-alpha version of the same ink.
    final strong = cs.onSurface;
    final faded = cs.onSurface.withValues(alpha: 0.28);
    final n = thinkingLevels.length;
    // Keep the whole indicator within a [size]-square footprint (matching the
    // single icon it replaces) so it never widens the composer-footer pills
    // enough to overflow a narrow split pane: n bars + (n-1) gaps == size.
    const barWidth = 2.0;
    final gap = (size - n * barWidth) / (n - 1);
    return SizedBox(
      height: size,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          for (var i = 0; i < n; i++) ...[
            if (i > 0) SizedBox(width: gap),
            Container(
              width: barWidth,
              // Shortest bar 40% tall, tallest full height, linearly stepped.
              height: size * (0.4 + 0.6 * (i / (n - 1))),
              decoration: BoxDecoration(
                color: i <= current ? strong : faded,
                borderRadius: BorderRadius.circular(1),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

/// Composer-footer control that shows the session's current thinking
/// (reasoning) effort and, on tap, opens the thinking-level picker (reusing the
/// `/thinking` client command). Hidden entirely when the agent reports no
/// thinking support (an empty thinking level).
class ComposerThinkingSelector extends ConsumerWidget {
  /// Creates the thinking-effort selector for [sessionId].
  const ComposerThinkingSelector({super.key, required this.sessionId});

  /// The session whose thinking level this selector reads and changes.
  final String sessionId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final meta = ref.watch(sessionMetaProvider(sessionId));
    if (meta == null || meta.thinking.isEmpty) return const SizedBox.shrink();
    return _ComposerPill(
      leading: ThinkingSignal(level: meta.thinking),
      label: meta.thinking,
      tooltip: 'Thinking effort',
      onTap: () => handleClientCommand(
        '/thinking',
        context: context,
        ref: ref,
        sessionId: sessionId,
      ),
    );
  }
}

/// Composer-footer control that shows the session's current agent *mode* and,
/// on tap, lets the user switch it. Only ACP agents advertise modes (native pi
/// has none), so this is hidden unless `session.meta` carries a non-empty
/// mode list. Switching sends the `mode` session action, mapped server-side to
/// ACP's `session/set_session_mode`.
class ComposerModeSelector extends ConsumerWidget {
  /// Creates the mode selector for [sessionId].
  const ComposerModeSelector({super.key, required this.sessionId});

  /// The session whose mode this selector reads and switches.
  final String sessionId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final modes = ref.watch(sessionMetaProvider(sessionId))?.modes;
    if (modes == null || modes.available.isEmpty) {
      return const SizedBox.shrink();
    }
    final current = modes.available.firstWhere(
      (m) => m.id == modes.current,
      orElse: () => modes.available.first,
    );
    return _ComposerPill(
      leading: Icon(
        PhosphorIconsLight.slidersHorizontal,
        size: 16,
        color: Theme.of(context).colorScheme.onSurfaceVariant,
      ),
      label: current.name,
      tooltip: 'Mode',
      onTap: () => _pickMode(context, ref, modes),
    );
  }

  Future<void> _pickMode(
    BuildContext context,
    WidgetRef ref,
    SessionModes modes,
  ) async {
    final picked = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (sheetContext) => SafeArea(
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const SheetHeader(title: 'Mode'),
              for (final m in modes.available)
                ListTile(
                  title: Text(m.name),
                  trailing: m.id == modes.current
                      ? const Icon(PhosphorIconsLight.check)
                      : null,
                  onTap: () => Navigator.pop(sheetContext, m.id),
                ),
            ],
          ),
        ),
      ),
    );
    if (picked == null || picked == modes.current) return;
    ref
        .read(storeControllerProvider.notifier)
        .sendSessionAction(sessionId, 'mode', args: {'id': picked});
  }
}

/// SPEC-26 — the unified, category-driven composer config renderer. Reads the
/// session's ordered [SessionConfigOption] list off `session.meta` and renders
/// a pill per option (reusing the [_ComposerPill] look), in the exact order the
/// agent sent them. Each pill dispatches the single `configOption {id, value}`
/// session action; the composer re-renders wholly from the refreshed list the
/// agent returns (never merging locally), so dependent options stay correct.
///
/// Renders nothing when the session advertises no `configOptions` — the legacy
/// [ComposerModelSelector]/[ComposerThinkingSelector]/[ComposerModeSelector]
/// triple is shown by the call site in that case (native pi, until SPEC-27).
class ComposerConfigOptions extends ConsumerWidget {
  /// Creates the unified config-option renderer for [sessionId].
  const ComposerConfigOptions({super.key, required this.sessionId});

  /// The session whose config options this widget reads and sets.
  final String sessionId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final options = ref.watch(sessionMetaProvider(sessionId))?.configOptions;
    if (options == null || options.isEmpty) return const SizedBox.shrink();
    final agent = ref.watch(sessionsProvider).byId(sessionId)?.agent ?? '';
    // The live session is authoritative: each pill's current value comes from
    // the option itself, and a pick dispatches the single `configOption`
    // session action (never merging locally — the agent re-emits the full
    // list, keeping dependent options correct).
    return ModelConfigFooter(
      options: options,
      values: {for (final o in options) o.id: o.currentValue},
      agent: agent,
      onPick: (id, value) => ref
          .read(storeControllerProvider.notifier)
          .sendSessionAction(
            sessionId,
            'configOption',
            args: {'id': id, 'value': value},
          ),
      onOpenModelMenu: () => showModelPickerSheet(
        context,
        builder: (_) => _LiveModelPickerSheet(sessionId: sessionId),
      ),
    );
  }
}

/// SPEC-31 — the live model picker sheet content. A [ConsumerWidget] so it
/// re-reads `session.meta` on every re-emit: the agent returns the **complete**
/// configOptions list on each set, so the flyout stays correct (and an option
/// disappearing does not crash — [ModelFlyoutColumn] renders wholly from the
/// list). Selecting a model records it into recents **optimistically** on the
/// gesture (actions are fire-and-forget, no ack) and dispatches the `model`
/// `configOption`; tuning a segment dispatches its `configOption`.
class _LiveModelPickerSheet extends ConsumerWidget {
  const _LiveModelPickerSheet({required this.sessionId});

  final String sessionId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final options =
        ref.watch(sessionMetaProvider(sessionId))?.configOptions ??
        const <SessionConfigOption>[];
    final partition = partitionConfigOptions(options);
    final model = partition.model;
    if (model == null) return const SizedBox.shrink();
    final agent = ref.watch(sessionsProvider).byId(sessionId)?.agent ?? '';
    // Rebuild when the recents change so a fresh select shows immediately.
    ref.watch(recentModelsControllerProvider);
    final recent = ref
        .read(recentModelsControllerProvider.notifier)
        .recentModels(agent);
    final activeValue = model.currentValue is String
        ? model.currentValue as String
        : '';
    final store = ref.read(storeControllerProvider.notifier);
    return ModelPickerMenu(
      modelOption: model,
      activeValue: activeValue,
      recent: recent,
      modelScoped: partition.modelScoped,
      values: {for (final o in options) o.id: o.currentValue},
      agent: agent,
      onSelectModel: (value) {
        ref
            .read(recentModelsControllerProvider.notifier)
            .recordSelect(agent, value);
        store.sendSessionAction(
          sessionId,
          'configOption',
          args: {'id': model.id, 'value': value},
        );
        // SPEC-31 (decision a): keep the sheet open — the ConsumerWidget
        // re-reads the re-emitted `session.meta`, so the now-active row updates
        // in place (its `✓`+`›` flyout caret revealed). No pop.
      },
      onPickOption: (id, value) => store.sendSessionAction(
        sessionId,
        'configOption',
        args: {'id': id, 'value': value},
      ),
    );
  }
}

/// SPEC-27 — the reusable config-option pill row shared by the live composer
/// ([ComposerConfigOptions]) and the pre-session New-session dialog. The caller
/// supplies the ordered [options], the current [values] (id → String/bool), the
/// owning [agent] (for the model pill's avatar), and an [onPick] callback
/// invoked with `(id, value)` when a pill is changed. This decouples the pill
/// visuals/pickers from where the value lives (session meta vs. local pending
/// picks) and how a pick is applied (session action vs. local state).
class ConfigOptionPickRow extends StatelessWidget {
  /// Creates a pill row for [options], reading current [values] and reporting
  /// changes via [onPick].
  const ConfigOptionPickRow({
    super.key,
    required this.options,
    required this.values,
    required this.agent,
    required this.onPick,
  });

  /// The config options to render, in agent (display) order.
  final List<SessionConfigOption> options;

  /// Current value per option id: a [String] for a select, a [bool] for a
  /// boolean. A missing id falls back to the option's own `currentValue`.
  final Map<String, Object> values;

  /// The owning agent id — the model pill uses it for the agent avatar.
  final String agent;

  /// Invoked with `(optionId, value)` when a pill's value changes.
  final void Function(String id, Object value) onPick;

  @override
  Widget build(BuildContext context) {
    if (options.isEmpty) return const SizedBox.shrink();
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        for (final option in options)
          Flexible(
            child: Padding(
              padding: const EdgeInsets.only(right: 6),
              child: ConfigOptionPill(
                option: option,
                currentValue: values[option.id] ?? option.currentValue,
                agent: agent,
                onPick: (value) => onPick(option.id, value),
              ),
            ),
          ),
      ],
    );
  }
}

/// A single config-option pill, rendered by [SessionConfigOption.category] and
/// [SessionConfigOption.type]. Boolean options toggle in place; select options
/// open a picker (searchable for `model`, labeled sections for grouped lists).
/// The [currentValue] and the [onPick] callback are supplied by the caller so
/// the same pill serves both a live session and a pre-session draft.
class ConfigOptionPill extends StatelessWidget {
  /// Creates a pill for [option] showing [currentValue], reporting picks via
  /// [onPick].
  const ConfigOptionPill({
    super.key,
    required this.option,
    required this.currentValue,
    required this.agent,
    required this.onPick,
  });

  final SessionConfigOption option;

  /// The active value: a [String] for a select, a [bool] for a boolean.
  final Object currentValue;
  final String agent;

  /// Invoked with the chosen value (a [String] or [bool]) on a change.
  final void Function(Object value) onPick;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    if (option.type == ConfigOptionType.boolean) {
      final on = currentValue == true;
      return _ComposerPill(
        leading: Icon(
          on ? PhosphorIconsFill.checkSquare : PhosphorIconsLight.square,
          size: 16,
          color: cs.onSurfaceVariant,
        ),
        label: option.name,
        tooltip: option.description ?? option.name,
        onTap: () => onPick(!on),
      );
    }

    final current = currentValue is String ? currentValue as String : '';
    final label = _displayName(current);
    return _ComposerPill(
      leading: _leadingFor(context),
      label: label,
      tooltip: option.description ?? option.name,
      onTap: () => _pick(context, current),
    );
  }

  /// The pill's leading widget, chosen by semantic category: the agent avatar
  /// for a model picker, the reasoning signal bars for a thinking level, and a
  /// neutral sliders glyph for modes / model config / unknown categories.
  Widget _leadingFor(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return switch (option.category) {
      'model' => AgentAvatar(agent: agent, size: 16),
      'thought_level' => ThinkingSignal(
        level: currentValue is String ? currentValue as String : '',
      ),
      _ => Icon(
        PhosphorIconsLight.slidersHorizontal,
        size: 16,
        color: cs.onSurfaceVariant,
      ),
    };
  }

  /// Open the appropriate picker and dispatch the pick. The `model` category
  /// gets the searchable sheet (mirroring [ComposerModelSelector]); every other
  /// select opens a plain sheet with grouped choices rendered as sections.
  Future<void> _pick(BuildContext context, String current) async {
    final picked = option.category == 'model'
        ? await _pickSearchable(context, current)
        : await _pickFromSheet(context, current);
    if (picked == null || picked == current) return;
    onPick(picked);
  }

  /// Every choice across a flat `options` list plus all grouped `options`.
  List<ConfigOptionValue> get _allValues => [
    ...option.options,
    for (final g in option.groups) ...g.options,
  ];

  /// Human label for [value]: the matching choice's name, else the raw value.
  String _displayName(String value) {
    for (final v in _allValues) {
      if (v.value == value) return v.name;
    }
    return value.isEmpty ? option.name : value;
  }

  Future<String?> _pickSearchable(BuildContext context, String current) {
    bool matches(ConfigOptionValue v, String q) =>
        v.name.toLowerCase().contains(q.toLowerCase());
    return showSearchableListSheet<String>(
      context: context,
      title: option.name,
      items: _allValues.map((v) => v.value).toList(),
      matches: (value, q) {
        final v = _allValues.firstWhere((e) => e.value == value);
        return matches(v, q);
      },
      tileBuilder: (ctx, value) {
        final v = _allValues.firstWhere((e) => e.value == value);
        return ListTile(
          title: Text(v.name),
          subtitle: v.description == null ? null : Text(v.description!),
          trailing: value == current
              ? const Icon(PhosphorIconsLight.check)
              : null,
          onTap: () => Navigator.of(ctx).pop(value),
        );
      },
    );
  }

  Future<String?> _pickFromSheet(BuildContext context, String current) {
    return showModalBottomSheet<String>(
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
  }
}

/// SPEC-31 — the composer footer for a session whose config options include a
/// `model` category. Renders the model pill (avatar + active model name +
/// read-only chips summarising the model-scoped options) first, then any
/// standalone options as today's [ConfigOptionPill]s. When there is **no**
/// `model` option it degrades to today's flat [ConfigOptionPickRow] (full
/// back-compat). Tapping the model pill invokes [onOpenModelMenu]; [onPick]
/// applies a standalone pill's change (id, value).
class ModelConfigFooter extends StatelessWidget {
  /// Creates the footer for [options], reading current [values].
  const ModelConfigFooter({
    super.key,
    required this.options,
    required this.values,
    required this.agent,
    required this.onPick,
    required this.onOpenModelMenu,
  });

  /// The config options to render, in agent (display) order.
  final List<SessionConfigOption> options;

  /// Current value per option id: a [String] for a select, a [bool] for a
  /// boolean. A missing id falls back to the option's own `currentValue`.
  final Map<String, Object> values;

  /// The owning agent id — the model pill uses it for the agent avatar.
  final String agent;

  /// Invoked with `(optionId, value)` when a standalone pill changes.
  final void Function(String id, Object value) onPick;

  /// Invoked when the model pill is tapped (opens the model picker menu).
  final VoidCallback onOpenModelMenu;

  @override
  Widget build(BuildContext context) {
    final partition = partitionConfigOptions(options);
    final model = partition.model;
    // No model category → render exactly today's flat pill row (back-compat:
    // native/legacy sessions, agents without a model selector).
    if (model == null) {
      return ConfigOptionPickRow(
        options: options,
        values: values,
        agent: agent,
        onPick: onPick,
      );
    }
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Flexible(
          child: ModelConfigPill(
            model: model,
            modelScoped: partition.modelScoped,
            values: values,
            agent: agent,
            onTap: onOpenModelMenu,
          ),
        ),
        for (final option in partition.standalone)
          Flexible(
            child: Padding(
              padding: const EdgeInsets.only(left: 6),
              child: ConfigOptionPill(
                option: option,
                currentValue: values[option.id] ?? option.currentValue,
                agent: agent,
                onPick: (value) => onPick(option.id, value),
              ),
            ),
          ),
      ],
    );
  }
}

/// SPEC-31 — the composer-footer model pill: the agent avatar, the active
/// model's name, and faint **read-only** chips summarising the model-scoped
/// options ([kModelScopedCategories]). Reasoning (`thought_level`) renders as
/// the [ThinkingSignal] bars; each `model_config` select shows its current
/// value's short name; a boolean shows its name only when on. The chips are
/// labels — tapping anywhere opens the menu via [onTap].
class ModelConfigPill extends StatelessWidget {
  /// Creates the model pill for [model], summarising [modelScoped] via [values].
  const ModelConfigPill({
    super.key,
    required this.model,
    required this.modelScoped,
    required this.values,
    required this.agent,
    required this.onTap,
  });

  final SessionConfigOption model;
  final List<SessionConfigOption> modelScoped;
  final Map<String, Object> values;
  final String agent;
  final VoidCallback onTap;

  String get _modelValue {
    final v = values[model.id] ?? model.currentValue;
    return v is String ? v : '';
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    return Tooltip(
      message: 'Model',
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(14),
        child: Padding(
          padding: const EdgeInsets.symmetric(
            horizontal: kSpace8,
            vertical: kSpace4,
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              AgentAvatar(agent: agent, size: 16),
              const SizedBox(width: kSpace6),
              Flexible(
                child: Text(
                  configValueName(model, _modelValue),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.labelMedium?.copyWith(
                    color: cs.onSurfaceVariant,
                  ),
                ),
              ),
              for (final chip in _chips(context)) ...[
                const SizedBox(width: kSpace6),
                chip,
              ],
            ],
          ),
        ),
      ),
    );
  }

  /// One read-only chip per model-scoped option, in agent order. Booleans that
  /// are off contribute nothing. Text chips are wrapped in [Flexible] so they
  /// shrink (ellipsis) instead of overflowing a narrow pane; the fixed-width
  /// [ThinkingSignal] glyph stays intrinsic (it is already sized to the avatar).
  List<Widget> _chips(BuildContext context) {
    final chips = <Widget>[];
    for (final option in modelScoped) {
      final value = values[option.id] ?? option.currentValue;
      if (option.type == ConfigOptionType.boolean) {
        if (value == true) {
          chips.add(Flexible(child: _textChip(context, option.name, on: true)));
        }
      } else if (option.category == 'thought_level') {
        chips.add(ThinkingSignal(level: value is String ? value : ''));
      } else {
        chips.add(
          Flexible(
            child: _textChip(
              context,
              configValueName(option, value is String ? value : ''),
            ),
          ),
        );
      }
    }
    return chips;
  }

  Widget _textChip(BuildContext context, String text, {bool on = false}) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
      decoration: BoxDecoration(
        color: cs.onSurface.withValues(alpha: 0.05),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Text(
        text,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: theme.textTheme.labelSmall?.copyWith(
          color: on ? kMakitAccent : cs.onSurfaceVariant,
        ),
      ),
    );
  }
}
