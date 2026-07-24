import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:phosphoricons_flutter/phosphoricons_flutter.dart';

import '../../store/models.dart';
import '../../store/store.dart';
import '../home/repo_chips.dart' show AgentAvatar;
import '../widgets/searchable_list_sheet.dart';
import '../widgets/sheet_header.dart';
import 'client_commands.dart';

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
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            leading,
            const SizedBox(width: 6),
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
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        for (final option in options)
          Flexible(
            child: Padding(
              padding: const EdgeInsets.only(right: 6),
              child: _ConfigOptionPill(
                sessionId: sessionId,
                option: option,
                agent: agent,
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
class _ConfigOptionPill extends ConsumerWidget {
  const _ConfigOptionPill({
    required this.sessionId,
    required this.option,
    required this.agent,
  });

  final String sessionId;
  final SessionConfigOption option;
  final String agent;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final cs = Theme.of(context).colorScheme;
    if (option.type == ConfigOptionType.boolean) {
      final on = option.currentValue == true;
      return _ComposerPill(
        leading: Icon(
          on ? PhosphorIconsFill.checkSquare : PhosphorIconsLight.square,
          size: 16,
          color: cs.onSurfaceVariant,
        ),
        label: option.name,
        tooltip: option.description ?? option.name,
        onTap: () => _send(ref, !on),
      );
    }

    final currentValue = option.currentValue is String
        ? option.currentValue as String
        : '';
    final label = _displayName(currentValue);
    return _ComposerPill(
      leading: _leadingFor(context),
      label: label,
      tooltip: option.description ?? option.name,
      onTap: () => _pick(context, ref, currentValue),
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
        level: option.currentValue is String
            ? option.currentValue as String
            : '',
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
  Future<void> _pick(
    BuildContext context,
    WidgetRef ref,
    String currentValue,
  ) async {
    final picked = option.category == 'model'
        ? await _pickSearchable(context, currentValue)
        : await _pickFromSheet(context, currentValue);
    if (picked == null || picked == currentValue) return;
    _send(ref, picked);
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

  void _send(WidgetRef ref, Object value) {
    ref
        .read(storeControllerProvider.notifier)
        .sendSessionAction(sessionId, 'configOption', args: {
          'id': option.id,
          'value': value,
        });
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
