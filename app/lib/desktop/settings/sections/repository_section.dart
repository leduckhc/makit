import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:phosphoricons_flutter/phosphoricons_flutter.dart';

import '../../../app/theme.dart';
import '../../../ui/home/repo_chips.dart';
import '../../../ui/home/repo_monogram.dart';
import '../../../ui/widgets/forge_glyph.dart';
import 'section_header.dart';
import 'settings_group.dart';
import 'settings_reset_button.dart';

/// Everything one repository's Settings section renders — nothing more.
///
/// A view model rather than a `RepoInfo`, for two reasons. The section shows facts
/// the repo DTO does not carry yet (the detected forge, the *effective* worktree
/// root and whether it was overridden), and keeping those as inputs means the
/// widget is complete and testable before the server plumbing that will supply
/// them exists. It also keeps the section pure presentation: it is *told* facts
/// and never derives them, which is the rule that stopped the app re-deriving the
/// forge from a PR URL.
@immutable
class RepoSettingsView {
  const RepoSettingsView({
    required this.name,
    required this.path,
    required this.worktreeRoot,
    this.defaultBranch,
    this.forge,
    this.forgeHost,
    this.forgeAuthed = false,
    this.worktreeRootOverridden = false,
    this.editable = true,
  });

  final String name;
  final String path;

  /// The **effective** worktree root — never blank. An empty field that silently
  /// means `~/.worktrees` is how worktrees end up somewhere unexpected.
  final String worktreeRoot;

  /// From `origin/HEAD`; null when it could not be read.
  final String? defaultBranch;

  /// What detection reported. **Null means "not measured yet"**, and the provider
  /// row is then omitted entirely rather than rendering a guess: routing only
  /// happens when a PR operation runs, so a quiet repo may genuinely not know.
  final ForgeKind? forge;

  /// The instance host, shown as the provider row's subtitle.
  final String? forgeHost;

  /// Whether a credential is configured **for that host**. Never the token.
  final bool forgeAuthed;

  /// True when a repo-level value replaces the inherited one — the only state
  /// that earns a reset button.
  final bool worktreeRootOverridden;

  /// False on a client that may read but not write: per-repo writes are accepted
  /// only from a loopback connection (SPEC-48 D16), so a paired phone shows the
  /// same values read-only rather than offering a control that would be refused.
  final bool editable;
}

/// One repository's Settings section.
///
/// Built from the shipped settings atoms — [SettingsSectionHeader],
/// [SettingsGroup], [SettingsResetButton] — so it inherits the window's spacing,
/// the green uppercase headers and, crucially, the reset button's fixed-width
/// collapse, which keeps rows with and without an override on the same grid.
class RepositorySettingsSection extends StatelessWidget {
  const RepositorySettingsSection({
    required this.view,
    this.onEditWorktreeRoot,
    this.onResetWorktreeRoot,
    super.key,
  });

  final RepoSettingsView view;
  final VoidCallback? onEditWorktreeRoot;
  final VoidCallback? onResetWorktreeRoot;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final forge = view.forge;

    return ListView(
      children: [
        // The repo name is the page title, exactly as `Server & Devices` heads its
        // own section before its subsections.
        SettingsSectionHeader(title: view.name),

        const SettingsSectionHeader(title: 'Identity'),
        SettingsGroup(
          children: [
            ListTile(
              leading: RepoMonogram(name: view.name),
              title: const Text('Logo'),
              trailing: _Trailing(badge: _Badge(label: 'from name', color: cs.outline)),
            ),
            ListTile(
              leading: Icon(PhosphorIconsLight.folder, size: 20, color: cs.outline),
              title: const Text('Root path'),
              // The path as the subtitle, matching how the CLI row carries its
              // path — it is the value, not a description of one.
              subtitle: Text(view.path),
              trailing: IconButton(
                tooltip: 'Copy path',
                icon: Icon(PhosphorIconsLight.copy, size: 18, color: cs.outline),
                onPressed: () => Clipboard.setData(ClipboardData(text: view.path)),
              ),
            ),
            if (forge != null)
              ListTile(
                leading: SizedBox(
                  width: 20,
                  height: 20,
                  child: forgeGlyphFor(forge).build(size: 20, color: cs.primary),
                ),
                title: const Text('Git provider'),
                subtitle: Text(_forgeSubtitle(view)),
                trailing: _Trailing(badge: _Badge(label: 'detected', color: cs.primary)),
              ),
            if (view.defaultBranch != null)
              ListTile(
                leading: Icon(PhosphorIconsLight.gitBranch, size: 20, color: cs.outline),
                title: const Text('Default branch'),
                subtitle: Text(view.defaultBranch!),
                trailing: _Trailing(badge: _Badge(label: 'from remote', color: cs.outline)),
              ),
          ],
        ),

        const SettingsSectionHeader(title: 'Worktrees'),
        SettingsGroup(
          children: [
            ListTile(
              enabled: view.editable,
              onTap: view.editable ? onEditWorktreeRoot : null,
              title: const Text('Worktree root'),
              subtitle: Text(view.worktreeRoot),
              trailing: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  _Badge(
                    label: view.worktreeRootOverridden ? 'overridden' : 'inherited',
                    color: view.worktreeRootOverridden ? cs.primary : cs.outline,
                  ),
                  SettingsResetButton(
                    // Only an override can be reset, and "reset" means inherit
                    // again — not "copy today's inherited value", so a later
                    // change to the inherited source still propagates.
                    visible: view.worktreeRootOverridden && view.editable,
                    onPressed: onResetWorktreeRoot ?? () {},
                  ),
                ],
              ),
            ),
          ],
        ),

        if (!view.editable)
          Padding(
            padding: const EdgeInsets.fromLTRB(kSpace24, 0, kSpace24, kSpace24),
            child: Text(
              'These settings are editable on the machine running makit.',
              style: Theme.of(context).textTheme.bodySmall?.copyWith(color: cs.outline),
            ),
          ),
      ],
    );
  }

  /// `Forgejo · git.example.com · token set`.
  ///
  /// The forge NAME leads, because it is the fact this row exists to report and a
  /// glyph alone does not carry it — measured on the real app, where the row named
  /// only the host and the `detected` badge, leaving "detected as *what*?"
  /// answerable only by recognising a 20pt mark. The value lives in the subtitle
  /// for the same reason `Root path` and `Default branch` do: in this window the
  /// subtitle IS the value (see the shipped `CLI` row), and the trailing slot
  /// carries provenance.
  static String _forgeSubtitle(RepoSettingsView v) {
    final parts = <String>[
      if (v.forge != null) forgeNameFor(v.forge!),
      if (v.forgeHost != null) v.forgeHost!,
      v.forgeAuthed ? 'token set' : 'no token',
    ];
    return parts.join(' · ');
  }
}

/// A badge plus the reset slot every row reserves.
///
/// The slot is why the section has ONE right edge: `SettingsResetButton` collapses
/// to a fixed 40pt box when hidden, so a row that can never be reset still lines
/// up with one that can. Measured on the real macOS app — without this, the
/// badge-only rows sat 40pt right of `Worktree root` and the column visibly
/// stepped between the two groups.
class _Trailing extends StatelessWidget {
  const _Trailing({required this.badge});
  final Widget badge;
  @override
  Widget build(BuildContext context) => Row(
    mainAxisSize: MainAxisSize.min,
    children: [badge, SettingsResetButton(visible: false, onPressed: () {})],
  );
}

/// A provenance/resolution badge. Reuses [TagChip] so it cannot drift from the
/// chips the repo list already shows.
class _Badge extends StatelessWidget {
  const _Badge({required this.label, required this.color});
  final String label;
  final Color color;
  @override
  Widget build(BuildContext context) => TagChip(label: label, color: color);
}
