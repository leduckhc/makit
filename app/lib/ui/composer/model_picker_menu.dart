import 'package:flutter/material.dart';
import 'package:phosphoricons_flutter/phosphoricons_flutter.dart';

import '../../app/theme.dart';
import '../../store/models.dart';
import '../home/repo_chips.dart' show AgentAvatar;
import 'composer_selectors.dart'
    show ThinkingSignal, allConfigValues, configValueName;

/// The `✓` glyph marking the active model in the picker's Recent list.
const IconData kModelActiveCheckIcon = PhosphorIconsLight.check;

/// The `›` glyph on the active model's row, opening its config flyout.
const IconData kModelFlyoutCaretIcon = PhosphorIconsLight.caretRight;

/// The `‹` back glyph on the flyout page, returning to the model list.
const IconData kModelFlyoutBackIcon = PhosphorIconsLight.caretLeft;

/// Fraction of the screen height the picker sheet may grow to (mirrors
/// `showSearchableListSheet`), keeping a sliver of background visible.
const double _kMaxHeightFraction = 0.85;

/// Presents [builder]'s content (a [ModelPickerMenu]) in a modal bottom sheet
/// capped at [_kMaxHeightFraction] of the screen height. SPEC-31 takes the
/// plan's sanctioned fallback of using the sheet on **every** host (the shared
/// composer already opens bottom sheets on desktop today), so a single
/// presentation serves mobile and desktop; the content widget stays
/// host-agnostic for a future desktop overlay.
Future<void> showModelPickerSheet(
  BuildContext context, {
  required WidgetBuilder builder,
}) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (ctx) => SafeArea(
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxHeight: MediaQuery.sizeOf(ctx).height * _kMaxHeightFraction,
        ),
        child: builder(ctx),
      ),
    ),
  );
}

/// SPEC-31 — the host-agnostic model picker menu content. Empty query shows the
/// **Recent** models (intersected with the catalog, active model always shown
/// and marked); typing filters the **full** catalog (selection only). Only the
/// **active** model's row is expandable — tapping it reveals the vertical config
/// [ModelFlyoutColumn] as a second page (`‹` back); non-active rows are
/// select-only ([onSelectModel]). Selecting the already-active value is a no-op.
///
/// The menu owns no session knowledge: the caller injects [activeValue],
/// [recent], the model-scoped options + [values], and the
/// [onSelectModel]/[onPickOption] callbacks — mirroring how `ConfigOptionPickRow`
/// injects `values`/`onPick`. This lets the same widget serve the live composer
/// (re-emitted `session.meta` + session actions) and the new-session draft
/// (local pending picks).
class ModelPickerMenu extends StatefulWidget {
  /// Creates the picker for [modelOption] with the injected state + callbacks.
  const ModelPickerMenu({
    super.key,
    required this.modelOption,
    required this.activeValue,
    required this.recent,
    required this.modelScoped,
    required this.values,
    required this.agent,
    required this.onSelectModel,
    required this.onPickOption,
  });

  /// The `model` category option — its `options`/`groups` are the catalog.
  final SessionConfigOption modelOption;

  /// The currently active model value.
  final String activeValue;

  /// Recently selected model values for this agent, most-recent-first.
  final List<String> recent;

  /// The active model's model-scoped options (flyout segments), in agent order.
  final List<SessionConfigOption> modelScoped;

  /// Current value per option id (model-scoped ids for the flyout).
  final Map<String, Object> values;

  /// The owning agent id — used for row avatars.
  final String agent;

  /// Invoked with a chosen model value (never with [activeValue] — that is a
  /// no-op). The caller records the recent + applies the change.
  final void Function(String value) onSelectModel;

  /// Invoked with `(optionId, value)` when a flyout segment changes.
  final void Function(String id, Object value) onPickOption;

  @override
  State<ModelPickerMenu> createState() => _ModelPickerMenuState();
}

class _ModelPickerMenuState extends State<ModelPickerMenu> {
  final TextEditingController _search = TextEditingController();
  String _query = '';
  bool _flyoutOpen = false;

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  List<ConfigOptionValue> get _catalog => allConfigValues(widget.modelOption);

  /// Recent values present in the catalog, active-first, deduped. The active
  /// model is always shown so its flyout stays reachable.
  List<String> get _recentRows {
    final inCatalog = _catalog.map((v) => v.value).toSet();
    final rows = <String>[];
    if (inCatalog.contains(widget.activeValue)) rows.add(widget.activeValue);
    for (final value in widget.recent) {
      if (value == widget.activeValue) continue;
      if (inCatalog.contains(value) && !rows.contains(value)) rows.add(value);
    }
    return rows;
  }

  void _select(String value) {
    if (value == widget.activeValue) return; // selecting active is a no-op
    widget.onSelectModel(value);
  }

  @override
  Widget build(BuildContext context) {
    if (_flyoutOpen) return _buildFlyoutPage(context);
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(
            kSpace16,
            kSpace8,
            kSpace16,
            kSpace8,
          ),
          child: TextField(
            controller: _search,
            textInputAction: TextInputAction.search,
            decoration: const InputDecoration(
              isDense: true,
              prefixIcon: Icon(PhosphorIconsLight.magnifyingGlass, size: 20),
              hintText: 'Search models…',
            ),
            onChanged: (v) => setState(() => _query = v),
          ),
        ),
        Flexible(
          child: _query.isEmpty
              ? _buildRecent(context)
              : _buildResults(context),
        ),
      ],
    );
  }

  Widget _buildRecent(BuildContext context) {
    final rows = _recentRows;
    // A header row at index 0, then one row per recent model. `.builder` keeps
    // the list lazy (the catalog can be ~300 entries).
    return ListView.builder(
      shrinkWrap: true,
      padding: EdgeInsets.zero,
      itemCount: rows.length + 1,
      itemBuilder: (context, index) {
        if (index == 0) return _sectionLabel(context, 'Recent');
        return _recentRow(context, rows[index - 1]);
      },
    );
  }

  Widget _buildResults(BuildContext context) {
    final q = _query.toLowerCase();
    final results = _catalog
        .where((v) => v.name.toLowerCase().contains(q))
        .toList();
    final label = _sectionLabel(
      context,
      'Results · ${results.length} of ${_catalog.length}',
    );
    if (results.isEmpty) {
      // Header + a single empty-state row (no builder needed for two items,
      // but keep the lazy list to avoid a second code path).
      return ListView.builder(
        shrinkWrap: true,
        padding: EdgeInsets.zero,
        itemCount: 2,
        itemBuilder: (context, index) {
          if (index == 0) return label;
          return Padding(
            padding: const EdgeInsets.all(kSpace24),
            child: Text(
              'No matches for “$_query”',
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.bodySmall,
            ),
          );
        },
      );
    }
    return ListView.builder(
      shrinkWrap: true,
      padding: EdgeInsets.zero,
      itemCount: results.length + 1,
      itemBuilder: (context, index) {
        if (index == 0) return label;
        return _resultRow(context, results[index - 1]);
      },
    );
  }

  /// A search-result row. The active model is marked with a `✓` and is a no-op
  /// on tap (selecting the already-active model does nothing); every other row
  /// selects on tap.
  Widget _resultRow(BuildContext context, ConfigOptionValue v) {
    final cs = Theme.of(context).colorScheme;
    final active = v.value == widget.activeValue;
    return ListTile(
      dense: true,
      leading: AgentAvatar(agent: widget.agent, size: 16),
      title: Text(v.name),
      trailing: active
          ? Icon(kModelActiveCheckIcon, size: 16, color: cs.primary)
          : null,
      onTap: active ? null : () => _select(v.value),
    );
  }

  /// A Recent-list row. The active model shows a `✓` + the `›` flyout caret and
  /// opens the flyout on tap; a non-active model is select-only.
  Widget _recentRow(BuildContext context, String value) {
    final cs = Theme.of(context).colorScheme;
    final active = value == widget.activeValue;
    final name = configValueName(widget.modelOption, value);
    return ListTile(
      dense: true,
      leading: AgentAvatar(agent: widget.agent, size: 16),
      title: Text(name),
      trailing: active
          ? Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(kModelActiveCheckIcon, size: 16, color: cs.primary),
                const SizedBox(width: kSpace4),
                Icon(
                  kModelFlyoutCaretIcon,
                  size: 16,
                  color: cs.onSurfaceVariant,
                ),
              ],
            )
          : null,
      onTap: active
          ? () => setState(() => _flyoutOpen = true)
          : () => _select(value),
    );
  }

  Widget _buildFlyoutPage(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(
            kSpace8,
            kSpace8,
            kSpace16,
            kSpace4,
          ),
          child: Row(
            children: [
              IconButton(
                icon: const Icon(kModelFlyoutBackIcon),
                tooltip: 'Back',
                onPressed: () => setState(() => _flyoutOpen = false),
              ),
              AgentAvatar(agent: widget.agent, size: 16),
              const SizedBox(width: kSpace8),
              Flexible(
                child: Text(
                  configValueName(widget.modelOption, widget.activeValue),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.titleSmall,
                ),
              ),
            ],
          ),
        ),
        Flexible(
          child: SingleChildScrollView(
            child: ModelFlyoutColumn(
              options: widget.modelScoped,
              values: widget.values,
              onPickOption: widget.onPickOption,
            ),
          ),
        ),
      ],
    );
  }

  Widget _sectionLabel(BuildContext context, String text) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(kSpace16, kSpace8, kSpace16, kSpace4),
      child: Text(
        text.toUpperCase(),
        style: theme.textTheme.labelSmall?.copyWith(
          color: theme.colorScheme.onSurfaceVariant,
          letterSpacing: 0.8,
        ),
      ),
    );
  }
}

/// SPEC-31 — the narrow vertical config column for the active model: one
/// segment per model-scoped option ([partitionConfigOptions]'s `modelScoped`),
/// in agent order. A `select` stacks its values vertically with the current one
/// marked; a `thought_level` header carries the [ThinkingSignal] glyph; a
/// `boolean` renders a single toggle row. Every change reports via
/// [onPickOption]; the column re-renders wholly from [options] (never merges),
/// so an option disappearing from a re-emitted list simply vanishes — no crash.
class ModelFlyoutColumn extends StatelessWidget {
  /// Creates the column for [options], reading current [values].
  const ModelFlyoutColumn({
    super.key,
    required this.options,
    required this.values,
    required this.onPickOption,
  });

  /// The model-scoped options to render, in agent order.
  final List<SessionConfigOption> options;

  /// Current value per option id.
  final Map<String, Object> values;

  /// Invoked with `(optionId, value)` when a segment changes.
  final void Function(String id, Object value) onPickOption;

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [for (final option in options) ..._segment(context, option)],
    );
  }

  List<Widget> _segment(BuildContext context, SessionConfigOption option) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final current = values[option.id] ?? option.currentValue;

    if (option.type == ConfigOptionType.boolean) {
      final on = current == true;
      return [
        Padding(
          padding: const EdgeInsets.fromLTRB(
            kSpace16,
            kSpace8,
            kSpace16,
            kSpace8,
          ),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  option.name.toUpperCase(),
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: cs.onSurfaceVariant,
                    letterSpacing: 0.8,
                  ),
                ),
              ),
              Switch(value: on, onChanged: (v) => onPickOption(option.id, v)),
            ],
          ),
        ),
      ];
    }

    final currentValue = current is String ? current : '';
    return [
      Padding(
        padding: const EdgeInsets.fromLTRB(
          kSpace16,
          kSpace8,
          kSpace16,
          kSpace4,
        ),
        child: Row(
          children: [
            if (option.category == 'thought_level') ...[
              ThinkingSignal(level: currentValue),
              const SizedBox(width: kSpace6),
            ],
            Text(
              option.name,
              style: theme.textTheme.labelSmall?.copyWith(
                color: cs.onSurfaceVariant,
                letterSpacing: 0.8,
              ),
            ),
          ],
        ),
      ),
      for (final v in allConfigValues(option))
        _valueRow(context, option.id, v, v.value == currentValue),
    ];
  }

  Widget _valueRow(
    BuildContext context,
    String optionId,
    ConfigOptionValue value,
    bool current,
  ) {
    final cs = Theme.of(context).colorScheme;
    return ListTile(
      dense: true,
      visualDensity: VisualDensity.compact,
      leading: Icon(
        kModelActiveCheckIcon,
        size: 16,
        color: current ? cs.primary : Colors.transparent,
      ),
      title: Text(
        value.name,
        style: current ? TextStyle(color: cs.primary) : null,
      ),
      onTap: current ? null : () => onPickOption(optionId, value.value),
    );
  }
}
