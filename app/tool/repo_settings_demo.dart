// Visual harness for SPEC-48's per-repo Settings section, with seeded data and no
// server. Run on the desktop you are reading this from:
//
//   cd app && rm -rf .dart_tool/flutter_build build/macos/Build/Products/Profile
//   flutter run -d macos --profile -t tool/repo_settings_demo.dart
//
// The cache clear is not optional: `flutter run -t <alt>.dart` silently reuses a
// cached bundle and will render lib/main.dart instead, omitting every edit here.
//
// The section is the shipped `RepositorySettingsSection` inside the real settings
// chrome (a sidebar + the real `SettingsSectionHeader` / `SettingsGroup` /
// `SettingsResetButton`), so what you see is what the Settings window will draw.
// Pick a repo on the left to switch states.
//
// Not part of the app or the test suite: a harness, kept out of `lib/` so neither
// can import it.
import 'package:flutter/material.dart';
import 'package:phosphoricons_flutter/phosphoricons_flutter.dart';
import 'package:makit/app/theme.dart';
import 'package:makit/desktop/settings/sections/repository_section.dart';
import 'package:makit/ui/home/repo_monogram.dart';
import 'package:makit/ui/widgets/forge_glyph.dart';

/// The states worth looking at, including the ones that must render *nothing*.
final _scenes = <String, RepoSettingsView>{
  'Diana — Forgejo, authed': const RepoSettingsView(
    name: 'Diana',
    path: '/Users/le/Work/XDent/Diana',
    defaultBranch: 'main',
    forge: ForgeKind.forgejo,
    forgeHost: 'forgejo.internal.xdent.ai',
    forgeAuthed: true,
    worktreeRoot: '/Users/le/.worktrees',
  ),
  'makit — GitHub, overridden root': const RepoSettingsView(
    name: 'makit',
    path: '/Users/le/Work/Vibe/makit',
    defaultBranch: 'main',
    forge: ForgeKind.github,
    forgeHost: 'github.com',
    forgeAuthed: true,
    worktreeRoot: '/Users/le/.worktrees/makit',
    worktreeRootOverridden: true,
  ),
  'piano — Gitea, no token': const RepoSettingsView(
    name: 'piano',
    path: '/Users/le/Work/Vibe/piano',
    defaultBranch: 'master',
    forge: ForgeKind.gitea,
    forgeHost: 'gitea.example.org',
    worktreeRoot: '/Users/le/.worktrees',
  ),
  'unprobed — forge not measured': const RepoSettingsView(
    name: 'quiet-repo',
    path: '/Users/le/Work/Vibe/quiet-repo',
    defaultBranch: 'main',
    worktreeRoot: '/Users/le/.worktrees',
  ),
  'read-only (paired phone)': const RepoSettingsView(
    name: 'Diana',
    path: '/Users/le/Work/XDent/Diana',
    defaultBranch: 'main',
    forge: ForgeKind.forgejo,
    forgeHost: 'forgejo.internal.xdent.ai',
    forgeAuthed: true,
    worktreeRoot: '/Users/le/.worktrees',
    editable: false,
  ),
};

void main() => runApp(const _DemoApp());

class _DemoApp extends StatelessWidget {
  const _DemoApp();
  @override
  Widget build(BuildContext context) => MaterialApp(
    debugShowCheckedModeBanner: false,
    theme: makitDarkTheme,
    home: const _Shell(),
  );
}

class _Shell extends StatefulWidget {
  const _Shell();
  @override
  State<_Shell> createState() => _ShellState();
}

class _ShellState extends State<_Shell> {
  // Default to the OVERRIDDEN scene: the reset button is the affordance the whole
  // inheritance model depends on, so it must be the one you see first.
  String _key = _scenes.keys.elementAt(1);

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Scaffold(
      body: Row(
        children: [
          // Stand-in for the Settings sidebar: enough chrome to judge the section
          // in context, deliberately not a copy of the real nav pane.
          Container(
            width: 220,
            color: cs.surface,
            child: ListView(
              padding: const EdgeInsets.symmetric(vertical: kSpace12),
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(kSpace16, kSpace4, kSpace16, kSpace12),
                  child: Row(
                    children: [
                      Icon(PhosphorIconsLight.x, size: 16, color: cs.outline),
                      const SizedBox(width: kSpace8),
                      Text('Settings', style: Theme.of(context).textTheme.titleSmall),
                    ],
                  ),
                ),
                for (final label in const [
                  'General',
                  'Appearance',
                  'Agents & Chat',
                  'Server & Devices',
                  'Notifications',
                  'Shortcuts',
                  'Advanced',
                  'About',
                ])
                  ListTile(
                    dense: true,
                    leading: Icon(PhosphorIconsLight.circle, size: 15, color: cs.outline),
                    title: Text(label, style: Theme.of(context).textTheme.bodySmall),
                  ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(kSpace16, kSpace16, kSpace16, kSpace4),
                  child: Text(
                    'REPOSITORIES',
                    style: Theme.of(context).textTheme.labelSmall?.copyWith(
                      color: cs.primary,
                      fontWeight: FontWeight.w700,
                      letterSpacing: 0.9,
                    ),
                  ),
                ),
                for (final entry in _scenes.entries)
                  ListTile(
                    dense: true,
                    selected: entry.key == _key,
                    selectedTileColor: cs.surfaceContainerHigh,
                    leading: RepoMonogram(name: entry.value.name, size: 16),
                    title: Text(
                      entry.key,
                      style: Theme.of(context).textTheme.bodySmall,
                      overflow: TextOverflow.ellipsis,
                    ),
                    onTap: () => setState(() => _key = entry.key),
                  ),
              ],
            ),
          ),
          const VerticalDivider(width: 1),
          Expanded(
            child: RepositorySettingsSection(
              key: ValueKey(_key),
              view: _scenes[_key]!,
              onEditWorktreeRoot: () {},
              onResetWorktreeRoot: () {},
            ),
          ),
        ],
      ),
    );
  }
}
