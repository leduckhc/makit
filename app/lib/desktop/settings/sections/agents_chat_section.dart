import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../chat/pr_actions.dart';
import '../prefs/preference.dart';
import '../prefs/preferences_providers.dart';
import 'section_header.dart';
import 'settings_group.dart';
import 'settings_reset_button.dart';

/// Agents & Chat section body.
///
/// Wires the **PR actions** leaf (SPEC-23): an editable prompt per composer PR
/// action (Create PR / Fix PR / Resolve comments). A blank field means "use the
/// built-in default", so the shipped prompts can evolve without stomping a
/// user's edit. The remaining leaves are reserved `[coming soon]` placeholders.
class AgentsChatSection extends StatelessWidget {
  /// Creates the Agents & Chat section body.
  const AgentsChatSection({super.key});

  @override
  Widget build(BuildContext context) {
    return ListView(
      children: [
        const SettingsSectionHeader(title: 'PR actions'),
        const Padding(
          padding: EdgeInsets.fromLTRB(16, 0, 16, 8),
          child: Text(
            'The composer\u2019s "PR actions" button inserts these prompts (it '
            'never sends automatically). Leave a field blank to use the '
            'built-in default.',
          ),
        ),
        SettingsGroup(
          children: [
            for (final action in PrPromptAction.values)
              _PrPromptRow(action: action),
          ],
        ),
      ],
    );
  }
}

/// One editable canned-prompt row: a labelled multi-line field bound to the
/// action's override [PreferenceEntry], with a per-row reset (↺) shown when the
/// override differs from blank (i.e. the built-in default is overridden).
class _PrPromptRow extends ConsumerStatefulWidget {
  const _PrPromptRow({required this.action});

  final PrPromptAction action;

  @override
  ConsumerState<_PrPromptRow> createState() => _PrPromptRowState();
}

class _PrPromptRowState extends ConsumerState<_PrPromptRow> {
  late final TextEditingController _ctrl;
  PreferenceEntry<String> get _pref => widget.action.promptPreference;

  @override
  void initState() {
    super.initState();
    _ctrl = TextEditingController(
      text: ref.read(preferencesControllerProvider.notifier).get(_pref),
    );
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final controller = ref.read(preferencesControllerProvider.notifier);
    final modified = ref.preferenceModified(_pref);

    // Keep the field in sync when the value changes elsewhere (e.g. reset).
    final current = ref.preference(_pref);
    if (current != _ctrl.text) {
      _ctrl.value = TextEditingValue(
        text: current,
        selection: TextSelection.collapsed(offset: current.length),
      );
    }

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(widget.action.icon, size: 16),
              const SizedBox(width: 8),
              Text(
                widget.action.label,
                style: const TextStyle(fontWeight: FontWeight.w600),
              ),
              const Spacer(),
              SettingsResetButton(
                visible: modified,
                onPressed: () => controller.reset(_pref),
              ),
            ],
          ),
          const SizedBox(height: 8),
          TextField(
            controller: _ctrl,
            minLines: 2,
            maxLines: 6,
            decoration: InputDecoration(
              isDense: true,
              border: const OutlineInputBorder(),
              hintText: widget.action.defaultPrompt,
            ),
            onChanged: (text) => controller.set(_pref, text),
          ),
        ],
      ),
    );
  }
}
