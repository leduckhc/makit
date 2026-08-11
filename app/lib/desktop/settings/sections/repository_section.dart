import 'dart:io' show Platform;

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
            _SettingsValueRow(
              leading: RepoMonogram(name: view.name),
              title: 'Logo',
              badge: _Badge(label: 'from name', color: cs.outline),
            ),
            _SettingsValueRow(
              leading: Icon(PhosphorIconsLight.folder, size: 20, color: cs.outline),
              title: 'Root path',
              value: _tilde(view.path),
              mono: true,
              action: IconButton(
                tooltip: 'Copy path',
                icon: Icon(PhosphorIconsLight.copy, size: 18, color: cs.outline),
                onPressed: () => Clipboard.setData(ClipboardData(text: view.path)),
              ),
            ),
            if (forge != null)
              _SettingsValueRow(
                leading: SizedBox(
                  width: 20,
                  height: 20,
                  child: forgeGlyphFor(forge).build(size: 20, color: cs.primary),
                ),
                title: 'Git provider',
                // The host is a second FACT, not a description of the row.
                subtitle: _forgeSubtitle(view),
                value: forgeNameFor(forge),
                badge: _Badge(label: 'detected', color: cs.primary),
              ),
            if (view.defaultBranch != null)
              _SettingsValueRow(
                leading: Icon(PhosphorIconsLight.gitBranch, size: 20, color: cs.outline),
                title: 'Default branch',
                value: view.defaultBranch,
                mono: true,
                badge: _Badge(label: 'from remote', color: cs.outline),
              ),
          ],
        ),

        const SettingsSectionHeader(title: 'Worktrees'),
        SettingsGroup(
          children: [
            _SettingsValueRow(
              enabled: view.editable,
              onTap: onEditWorktreeRoot,
              title: 'Worktree root',
              value: _tilde(view.worktreeRoot),
              mono: true,
              badge: _Badge(
                label: view.worktreeRootOverridden ? 'overridden' : 'inherited',
                color: view.worktreeRootOverridden ? cs.primary : cs.outline,
              ),
              // Only an override can be reset, and reset means inherit again — not
              // "copy today's inherited value" — so a later change still propagates.
              resetVisible: view.worktreeRootOverridden && view.editable,
              onReset: onResetWorktreeRoot,
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

  /// `/Users/le/x` -> `~/x`. A settings row is not the place to spend 40pt of the
  /// value column on a home directory the reader already knows.
  static String _tilde(String path) {
    final home = Platform.environment['HOME'];
    if (home == null || home.isEmpty || !path.startsWith(home)) return path;
    return '~${path.substring(home.length)}';
  }

  static String _forgeSubtitle(RepoSettingsView v) {
    final parts = <String>[
      if (v.forgeHost != null) v.forgeHost!,
      v.forgeAuthed ? 'token set' : 'no token',
    ];
    return parts.join(' · ');
  }
}

/// One settings row: title on the left, its **value right-aligned** in a column
/// down the section, then the provenance badge and the reset slot.
///
/// The value column is the mockup's idea and it earns its place — a column of
/// right-aligned values scans in one vertical sweep, where values buried in
/// subtitles have to be read line by line. It does mean this row style differs
/// from `CLI`/`Fingerprint` in Server & Devices, which put their value in the
/// subtitle; that is a deliberate, recorded divergence rather than an oversight.
///
/// [subtitle] is for a SECOND fact worth showing (the forge's host), never for a
/// description of the row — "Monogram from the name" under a row labelled "Logo"
/// is words about words.
class _SettingsValueRow extends StatelessWidget {
  const _SettingsValueRow({
    required this.title,
    this.leading,
    this.subtitle,
    this.value,
    this.mono = false,
    this.badge,
    this.action,
    this.resetVisible = false,
    this.onReset,
    this.enabled = true,
    this.onTap,
  });

  final String title;
  final Widget? leading;
  final String? subtitle;
  final String? value;
  /// Render [value] monospaced — paths and refs, where character shape matters.
  final bool mono;
  final Widget? badge;
  /// A trailing control that occupies the reset slot instead (the copy button).
  final Widget? action;
  final bool resetVisible;
  final VoidCallback? onReset;
  final bool enabled;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final cs = t.colorScheme;
    final valueStyle = t.textTheme.bodySmall?.copyWith(color: cs.onSurfaceVariant);
    return ListTile(
      enabled: enabled,
      onTap: enabled ? onTap : null,
      leading: leading,
      title: Text(title),
      subtitle: subtitle == null ? null : Text(subtitle!),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (value != null)
            ConstrainedBox(
              // Bounded so a long path elides instead of shoving the badge off the
              // row — the failure the mockup hit until its subtitle was shortened.
              constraints: const BoxConstraints(maxWidth: 260),
              child: Text(
                value!,
                textAlign: TextAlign.right,
                overflow: TextOverflow.ellipsis,
                style: mono ? valueStyle?.mono : valueStyle,
              ),
            ),
          if (badge != null) ...[const SizedBox(width: kSpace8), badge!],
          // Exactly one thing occupies the trailing slot, so every row shares one
          // right edge whether or not it can be reset.
          if (action != null)
            action!
          else
            SettingsResetButton(visible: resetVisible, onPressed: onReset ?? () {}),
        ],
      ),
    );
  }
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
