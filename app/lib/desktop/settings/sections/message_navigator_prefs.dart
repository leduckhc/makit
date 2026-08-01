/// The `Message navigator` settings leaf (SPEC-34): a style picker whose
/// selected row expands its own options.
///
/// Presentation is an **expanding radio list**, not a `SegmentedButton`: five
/// styles with two or three options each is thirteen controls, so progressive
/// disclosure is mandatory — and a radio list lets the user read what "Outline"
/// means without selecting it. This is a choice made once, so informed beats
/// compact.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/theme.dart';
import '../../../ui/session/navigator/navigator_style.dart';
import '../prefs/preference.dart';
import '../prefs/preference_entries.dart';
import '../prefs/preferences_providers.dart';
import 'section_header.dart';
import 'settings_group.dart';

/// Human-facing copy for each style, plus which styles are actually built.
@immutable
class _StyleCopy {
  const _StyleCopy({
    required this.style,
    required this.title,
    required this.blurb,
    this.badge,
  });

  final MessageNavigatorStyle style;
  final String title;
  final String blurb;
  final String? badge;
}

const List<_StyleCopy> _styles = [
  _StyleCopy(
    style: MessageNavigatorStyle.off,
    title: 'Off',
    blurb: 'No navigator. Scroll the transcript by hand.',
  ),
  _StyleCopy(
    style: MessageNavigatorStyle.rail,
    title: 'Ripple rail',
    badge: 'pointer',
    blurb:
        'A cosy cluster of ticks in the top-right corner — one per message you '
        'sent. Hover to ripple and reveal, click to jump.',
  ),
  _StyleCopy(
    style: MessageNavigatorStyle.scrubber,
    title: 'Prompt scrubber',
    badge: 'touch',
    blurb: 'Drag the right edge; a preview card snaps prompt to prompt.',
  ),
  _StyleCopy(
    style: MessageNavigatorStyle.palette,
    title: 'Prompt palette',
    blurb:
        'Opens a searchable list of your messages — the only style that can '
        'search what you wrote.',
  ),
  _StyleCopy(
    style: MessageNavigatorStyle.breadcrumb,
    title: 'Sticky breadcrumb',
    blurb:
        'A chip always shows which of your prompts produced what you are '
        'reading, with prev/next hops.',
  ),
  _StyleCopy(
    style: MessageNavigatorStyle.outline,
    title: 'Outline mode',
    blurb:
        'A toggle hides assistant output, leaving your prompts as a table of '
        'contents.',
  ),
];

/// The subsection: header, blurb, and the picker group.
class MessageNavigatorPrefs extends ConsumerWidget {
  /// Creates the `Message navigator` settings leaf.
  const MessageNavigatorPrefs({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final selected = ref.preference(messageNavigatorStylePreference);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const SettingsSectionHeader(title: 'Message navigator'),
        const Padding(
          padding: EdgeInsets.fromLTRB(16, 0, 16, 8),
          child: Text(
            'How you jump back to your own messages in a long transcript.',
          ),
        ),
        SettingsGroup(
          children: [
            for (final copy in _styles)
              _StyleRow(copy: copy, selected: copy.style == selected),
          ],
        ),
      ],
    );
  }
}

/// One style row; when selected it is followed by that style's options.
class _StyleRow extends ConsumerWidget {
  const _StyleRow({required this.copy, required this.selected});

  final _StyleCopy copy;
  final bool selected;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scheme = Theme.of(context).colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        ListTile(
          leading: Icon(
            selected
                ? Icons.radio_button_checked
                : Icons.radio_button_unchecked,
            size: 18,
            color: selected ? scheme.primary : scheme.outline,
          ),
          title: Row(
            children: [
              Flexible(child: Text(copy.title)),
              if (copy.badge != null) ...[
                const SizedBox(width: kSpace6),
                _Badge(label: copy.badge!),
              ],
            ],
          ),
          subtitle: Text(copy.blurb),
          onTap: () => ref
              .read(preferencesControllerProvider.notifier)
              .set(messageNavigatorStylePreference, copy.style),
        ),
        // Only the selected style's options are built — not built-and-hidden.
        if (selected) ..._optionsFor(copy.style),
      ],
    );
  }

  List<Widget> _optionsFor(MessageNavigatorStyle style) => switch (style) {
    MessageNavigatorStyle.rail => const [
      _SpacingRow(),
      _SwitchRow(
        entry: railRipplePreference,
        title: 'Ripple on hover',
        subtitle: 'Neighbouring ticks stretch and spread apart',
      ),
      _SwitchRow(
        entry: railEncodeLengthPreference,
        title: 'Tick length shows message length',
        subtitle: 'Makes the rail a fingerprint of the session',
      ),
    ],
    MessageNavigatorStyle.scrubber => const [
      _SwitchRow(
        entry: scrubLiveScrollPreference,
        title: 'Scroll while dragging',
        subtitle: 'Off shows a preview and jumps when you let go',
      ),
      _SwitchRow(
        entry: scrubTimestampsPreference,
        title: 'Show timestamps',
        subtitle: 'Relative time on the preview card',
      ),
    ],
    MessageNavigatorStyle.palette => const [
      _SwitchRow(
        entry: paletteSearchAllPreference,
        title: 'Search the agent\'s messages too',
        subtitle: 'Off searches only what you wrote',
      ),
    ],
    MessageNavigatorStyle.breadcrumb => const [
      _SwitchRow(
        entry: crumbAutoHidePreference,
        title: 'Fade at the newest message',
        subtitle: 'Where there is nothing to go back to',
      ),
      _SwitchRow(
        entry: crumbCounterPreference,
        title: 'Show position counter',
        subtitle: 'For example "4/7"',
      ),
    ],
    MessageNavigatorStyle.outline => const [
      _SwitchRow(
        entry: outlineHideToolsPreference,
        title: 'Hide tool calls too',
        subtitle: 'Off keeps tool calls as context between your prompts',
      ),
      _SwitchRow(
        entry: outlineShowCountsPreference,
        title: 'Show hidden-row counts',
        subtitle: 'For example "8 hidden" on the toggle',
      ),
    ],
    MessageNavigatorStyle.off => const [],
  };
}

class _Badge extends StatelessWidget {
  const _Badge({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: kSpace6),
      decoration: BoxDecoration(
        border: Border.all(color: scheme.outlineVariant),
        borderRadius: BorderRadius.circular(kRadius6),
      ),
      child: Text(
        label,
        style: Theme.of(
          context,
        ).textTheme.labelSmall?.copyWith(color: scheme.onSurfaceVariant),
      ),
    );
  }
}

/// Tick spacing: the one number a user notices immediately.
class _SpacingRow extends ConsumerWidget {
  const _SpacingRow();

  static const Map<int, String> _labels = {
    6: 'cosy',
    10: 'normal',
    14: 'roomy',
  };

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final value = ref.preference(railTickSpacingPreference);
    return Padding(
      padding: const EdgeInsets.fromLTRB(56, 0, 16, kSpace12),
      child: Row(
        children: [
          const Expanded(child: Text('Tick spacing')),
          SegmentedButton<int>(
            showSelectedIcon: false,
            segments: [
              for (final entry in _labels.entries)
                ButtonSegment(value: entry.key, label: Text(entry.value)),
            ],
            selected: {_labels.containsKey(value) ? value : 6},
            onSelectionChanged: (selection) => ref
                .read(preferencesControllerProvider.notifier)
                .set(railTickSpacingPreference, selection.first),
          ),
        ],
      ),
    );
  }
}

/// A boolean option row bound to [entry].
class _SwitchRow extends ConsumerWidget {
  const _SwitchRow({
    required this.entry,
    required this.title,
    required this.subtitle,
  });

  final PreferenceEntry<bool> entry;
  final String title;
  final String subtitle;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final value = ref.preference(entry);
    return Padding(
      padding: const EdgeInsets.only(left: 40),
      child: SwitchListTile(
        value: value,
        title: Text(title),
        subtitle: Text(subtitle),
        onChanged: (next) =>
            ref.read(preferencesControllerProvider.notifier).set(entry, next),
      ),
    );
  }
}
