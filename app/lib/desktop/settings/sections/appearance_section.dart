import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_symbols_icons/symbols.dart';

import '../../chat/sidebar_layout.dart';
import '../prefs/preference_entries.dart';
import '../prefs/preferences_providers.dart';
import 'section_header.dart';

/// Lowest UI text scale offered by the slider.
const double _kMinTextScale = 0.9;

/// Highest UI text scale offered by the slider.
const double _kMaxTextScale = 1.3;

/// Appearance section body.
///
/// Wires the real leaves: **Theme** (segmented control), **Layout** (sidebar
/// width + start collapsed, backed by persisted prefs), and **Text** (UI text
/// scale). Accent color, the monospace code font, and chat rendering have no
/// clean desktop hook yet and stay reserved `[future]` placeholders.
class AppearanceSection extends StatelessWidget {
  /// Creates the Appearance section body.
  const AppearanceSection({super.key});

  @override
  Widget build(BuildContext context) {
    return ListView(
      children: const [
        SettingsSectionHeader(title: 'Appearance'),
        _ThemeRow(),
        _AccentColorRow(),
        SettingsSectionHeader(title: 'Layout'),
        _SidebarWidthRow(),
        _StartCollapsedRow(),
        SettingsSectionHeader(title: 'Text'),
        _TextScaleRow(),
        _MonospaceFontRow(),
        _ChatRenderingRow(),
      ],
    );
  }
}

/// The Theme row: a System / Light / Dark segmented control that reads and
/// writes [themeModePreference], plus a per-row reset (↺) when it differs from
/// the default (System) — mirroring the keymap row's reset idiom.
class _ThemeRow extends ConsumerWidget {
  const _ThemeRow();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final mode = ref.preference(themeModePreference);
    final modified = ref.preferenceModified(themeModePreference);
    final controller = ref.read(preferencesControllerProvider.notifier);

    return ListTile(
      title: const Text('Theme'),
      subtitle: const Text('Match the system appearance, or force light/dark.'),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          SegmentedButton<ThemeMode>(
            showSelectedIcon: false,
            segments: const [
              ButtonSegment(value: ThemeMode.system, label: Text('System')),
              ButtonSegment(value: ThemeMode.light, label: Text('Light')),
              ButtonSegment(value: ThemeMode.dark, label: Text('Dark')),
            ],
            selected: {mode},
            onSelectionChanged: (selection) =>
                controller.set(themeModePreference, selection.first),
          ),
          const SizedBox(width: 8),
          if (modified)
            IconButton(
              tooltip: 'Reset to default',
              icon: const Icon(Symbols.settings_backup_restore, size: 18),
              onPressed: () => controller.reset(themeModePreference),
            )
          else
            const SizedBox(width: 40),
        ],
      ),
    );
  }
}

/// Sidebar width: a slider (250–450) bound to [sidebarWidthProvider], which is
/// persisted via [sidebarWidthPreference]. Dragging resizes the live sidebar;
/// reset restores [kSidebarDefaultWidth].
class _SidebarWidthRow extends ConsumerWidget {
  const _SidebarWidthRow();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final width = ref.watch(sidebarWidthProvider);
    final modified = ref.preferenceModified(sidebarWidthPreference);
    final clamped = width.clamp(kSidebarMinWidth, kSidebarMaxWidth);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        ListTile(
          title: const Text('Default sidebar width'),
          subtitle: Text(
            '${clamped.round()} px. Also set by dragging the '
            'sidebar edge.',
          ),
          trailing: _ResetButton(
            visible: modified,
            onPressed: () => ref.read(sidebarWidthProvider.notifier).state =
                kSidebarDefaultWidth,
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(24, 0, 24, 8),
          child: Slider(
            min: kSidebarMinWidth,
            max: kSidebarMaxWidth,
            value: clamped,
            label: '${clamped.round()} px',
            onChanged: (value) =>
                ref.read(sidebarWidthProvider.notifier).state = value,
          ),
        ),
      ],
    );
  }
}

/// Start collapsed: a switch bound to [sidebarCollapsedProvider], persisted via
/// [sidebarStartCollapsedPreference]. Toggling folds/unfolds the live sidebar
/// and is restored on the next launch.
class _StartCollapsedRow extends ConsumerWidget {
  const _StartCollapsedRow();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final collapsed = ref.watch(sidebarCollapsedProvider);
    final modified = ref.preferenceModified(sidebarStartCollapsedPreference);

    return ListTile(
      title: const Text('Start with sidebar collapsed'),
      subtitle: const Text('Open the window with the sidebar folded away.'),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Switch(
            value: collapsed,
            onChanged: (value) =>
                ref.read(sidebarCollapsedProvider.notifier).state = value,
          ),
          const SizedBox(width: 8),
          _ResetButton(
            visible: modified,
            onPressed: () =>
                ref.read(sidebarCollapsedProvider.notifier).state = false,
          ),
        ],
      ),
    );
  }
}

/// UI text scale: a slider (0.9–1.3) bound to [textScalePreference], applied
/// app-wide via `MediaQuery.textScaler` in `desktop_app.dart`.
class _TextScaleRow extends ConsumerWidget {
  const _TextScaleRow();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scale = ref.preference(textScalePreference);
    final modified = ref.preferenceModified(textScalePreference);
    final controller = ref.read(preferencesControllerProvider.notifier);
    final clamped = scale.clamp(_kMinTextScale, _kMaxTextScale);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        ListTile(
          title: const Text('UI text scale'),
          subtitle: Text(
            '${(clamped * 100).round()}% of the default text '
            'size.',
          ),
          trailing: _ResetButton(
            visible: modified,
            onPressed: () => controller.reset(textScalePreference),
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(24, 0, 24, 8),
          child: Slider(
            min: _kMinTextScale,
            max: _kMaxTextScale,
            divisions: 8,
            value: clamped,
            label: '${(clamped * 100).round()}%',
            onChanged: (value) => controller.set(textScalePreference, value),
          ),
        ),
      ],
    );
  }
}

/// A per-row reset (↺) that occupies fixed width whether shown or hidden, so
/// rows stay vertically aligned — mirrors the Theme row's idiom.
class _ResetButton extends StatelessWidget {
  const _ResetButton({required this.visible, required this.onPressed});

  final bool visible;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    if (!visible) return const SizedBox(width: 40);
    return IconButton(
      tooltip: 'Reset to default',
      icon: const Icon(Symbols.settings_backup_restore, size: 18),
      onPressed: onPressed,
    );
  }
}

/// Accent color — reserved `[future]` placeholder (SPEC-13 §2). The app uses a
/// single fixed green accent today; a picker needs theme plumbing that does not
/// exist yet.
class _AccentColorRow extends StatelessWidget {
  const _AccentColorRow();

  @override
  Widget build(BuildContext context) => const _ComingSoonRow(
    icon: Symbols.palette,
    title: 'Accent color',
    subtitle: 'The single accent hue used for active and selected states.',
  );
}

/// Monospace code font — reserved `[future]` placeholder. There is no desktop
/// hook to override the code font family yet.
class _MonospaceFontRow extends StatelessWidget {
  const _MonospaceFontRow();

  @override
  Widget build(BuildContext context) => const _ComingSoonRow(
    icon: Symbols.code,
    title: 'Monospace code font',
    subtitle: 'The font used for code blocks and inline code.',
  );
}

/// Chat rendering — reserved `[future]` placeholder. Markdown/highlight/
/// timestamp toggles need renderer plumbing that does not exist yet.
class _ChatRenderingRow extends StatelessWidget {
  const _ChatRenderingRow();

  @override
  Widget build(BuildContext context) => const _ComingSoonRow(
    icon: Symbols.chat,
    title: 'Chat rendering',
    subtitle: 'Markdown, code highlight theme, and timestamps.',
  );
}

/// A disabled row with a "Coming soon" tag for reserved `[future]` leaves.
class _ComingSoonRow extends StatelessWidget {
  const _ComingSoonRow({
    required this.icon,
    required this.title,
    required this.subtitle,
  });

  final IconData icon;
  final String title;
  final String subtitle;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return ListTile(
      enabled: false,
      leading: Icon(icon, weight: 200, color: cs.outline),
      title: Text(title),
      subtitle: Text(subtitle),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Symbols.schedule, weight: 200, size: 16, color: cs.outline),
          const SizedBox(width: 6),
          Text(
            'Coming soon',
            style: TextStyle(color: cs.outline, fontSize: 12),
          ),
        ],
      ),
    );
  }
}
