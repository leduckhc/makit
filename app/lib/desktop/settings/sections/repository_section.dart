import 'dart:io' show Platform;

import 'package:flutter/material.dart';
import 'package:phosphoricons_flutter/phosphoricons_flutter.dart';

import '../../../app/theme.dart';
import '../../../store/models.dart';
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
    this.providerChoice = ForgeChoice.auto,
    this.branches = const [],
    this.hasRemote = true,
    this.logoHue,
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

  /// What the user picked for the provider. [ForgeChoice.auto] means "believe
  /// detection", and is the default — an override exists for the case detection
  /// cannot solve (a private instance with no token, or a proxy hiding
  /// `/api/forgejo/v1/version`), not as a preference.
  final ForgeChoice providerChoice;

  /// Whether the repo has an `origin` remote at all. False means no forge is
  /// possible — which is a **different statement** from "not identified yet", and
  /// rendering them the same implies a probe is still pending when none can help.
  final bool hasRemote;

  /// Branches offered when picking a default. Empty = nothing to pick from, so the
  /// row stays read-only rather than opening an empty picker.
  final List<String> branches;

  /// False on a client that may read but not write: per-repo writes are accepted
  /// only from a loopback connection (SPEC-48 D16), so a paired phone shows the
  /// same values read-only rather than offering a control that would be refused.
  final bool editable;

  /// The palette index the user chose for this repo's mark, or null to derive it
  /// from the name.
  ///
  /// Null rather than a default index, because index 0 is a real palette entry: a
  /// numeric default would silently repaint every repo that never chose one.
  final int? logoHue;
}

/// Build the section's view from a real [RepoInfo].
///
/// One place, so the section stays pure presentation and the mapping from wire
/// facts to rendered facts is testable on its own. Returns null when the server
/// sent no settings — an older server, where rendering fabricated defaults would
/// be worse than rendering nothing.
RepoSettingsView? repoSettingsViewFor(RepoInfo repo, {bool editable = true}) {
  final st = repo.settings;
  if (st == null) return null;
  final forge = st.forge;
  return RepoSettingsView(
    name: repo.name,
    path: repo.path,
    worktreeRoot: st.worktreeRoot.value,
    worktreeRootOverridden: st.worktreeRoot.isOverride,
    // The override wins; otherwise git's own answer, which the DTO already carries
    // rather than duplicating into settings.
    defaultBranch: st.defaultBranch?.value ?? repo.defaultBranch,
    forge: forge == null ? null : _forgeKindFor(forge.software),
    forgeHost: forge?.host,
    forgeAuthed: forge?.authed ?? false,
    providerChoice: _choiceFor(st.provider.value),
    hasRemote: st.hasRemote,
    // Offered from what the repo actually has, so a pick cannot be a typo.
    branches: <String>{
      for (final w in repo.worktrees)
        if (w.branch != null && w.branch!.isNotEmpty) w.branch!,
      if (repo.defaultBranch != null) repo.defaultBranch!,
    }.toList()..sort(),
    editable: editable,
    logoHue: st.logoHue,
  );
}

/// `gitlab` and `unknown` map to null: the app has no glyph for a forge it cannot
/// talk to, and the row's subtitle carries the name instead.
ForgeKind? _forgeKindFor(String software) => switch (software) {
  'github' => ForgeKind.github,
  'forgejo' => ForgeKind.forgejo,
  'gitea' => ForgeKind.gitea,
  _ => null,
};

ForgeChoice _choiceFor(String wire) => switch (wire) {
  'none' => ForgeChoice.none,
  'forgejo' => ForgeChoice.forgejo,
  'gitea' => ForgeChoice.gitea,
  'github' => ForgeChoice.github,
  _ => ForgeChoice.auto,
};

/// The provider the user chose, or [auto] to believe detection.
enum ForgeChoice {
  auto,

  /// No forge for this repository: makit does not talk to one, and does not poll
  /// pull requests. Distinct from [auto] failing to identify something — this is
  /// an instruction, not an outcome. Two reasons it earns a place beside the three
  /// forges: a purely local repo has no remote and never will, and a repo whose
  /// forge you simply do not care about (a mirror, a vendored copy) should be able
  /// to stop generating PR chatter.
  none,

  forgejo,
  gitea,
  github;

  String get label => switch (this) {
    ForgeChoice.auto => 'Auto',
    ForgeChoice.none => 'None',
    ForgeChoice.forgejo => 'Forgejo',
    ForgeChoice.gitea => 'Gitea',
    ForgeChoice.github => 'GitHub',
  };
}

/// One repository's Settings section.
///
/// **A badge appears only where nothing else in the row says it.** The provenance
/// family (`from name`, `detected`, `from remote`) was cut: the monogram *is* the
/// logo, `main` *is* the branch, and the provider row's subtitle already reads
/// `Auto: GitHub · …` or `Set to Gitea · …`. Restating that in a chip beside it is
/// the same sentence twice, and once every row became editable the provenance
/// stopped being actionable. What survives is `inherited` / `overridden` on
/// Worktree root, which has no subtitle and where the distinction is the whole
/// point — paired with the reset button, which is an action rather than a label.
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
    this.onEditLogo,
    this.onChangeRootPath,
    this.onChooseProvider,
    this.onChooseDefaultBranch,
    super.key,
  });

  final RepoSettingsView view;
  final VoidCallback? onEditWorktreeRoot;
  final VoidCallback? onResetWorktreeRoot;
  final VoidCallback? onEditLogo;
  final VoidCallback? onChangeRootPath;
  final ValueChanged<ForgeChoice>? onChooseProvider;
  final VoidCallback? onChooseDefaultBranch;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;

    return ListView(
      children: [
        // The repo name is the page title, exactly as `Server & Devices` heads its
        // own section before its subsections.
        SettingsSectionHeader(title: view.name),

        const SettingsSectionHeader(title: 'Identity'),
        SettingsGroup(
          children: [
            _SettingsValueRow(
              leading: RepoMonogram(name: view.name, hue: view.logoHue),
              title: 'Logo',
              enabled: view.editable,
              onTap: onEditLogo,
              // A chevron, not a text field: the choice is a colour and a glyph
              // from a fixed set. Two repos that hash to the same hue are
              // indistinguishable in the sidebar, which is the one thing the
              // monogram exists to prevent — so it must be overridable.
              action: _Chevron(enabled: view.editable),
            ),
            _SettingsValueRow(
              leading: Icon(
                PhosphorIconsLight.folder,
                size: 20,
                color: cs.outline,
              ),
              title: 'Root path',
              enabled: view.editable,
              onTap: onChangeRootPath,
              value: _tilde(view.path),
              mono: true,
              // Editable, reversing an earlier "identity is immutable" position:
              // when a repo MOVES on disk, remove-and-re-add loses its persisted
              // id and everything keyed to it (settings, session history).
              // Re-pointing keeps the id, which is the whole reason the id exists.
              action: _Chevron(enabled: view.editable),
            ),
            // Row + segmented control below, exactly as `Endpoint` does it: the
            // subtitle says what `Auto` resolved to, so the default is legible
            // rather than mysterious. An override is here for the case detection
            // cannot solve — a private instance answering 401, or a proxy hiding
            // `/api/forgejo/v1/version` — where the repo is otherwise unusable
            // with no recourse.
            _ProviderRow(
              view: view,
              onChoose: view.editable ? onChooseProvider : null,
            ),
            if (view.defaultBranch != null)
              _SettingsValueRow(
                leading: Icon(
                  PhosphorIconsLight.gitBranch,
                  size: 20,
                  color: cs.outline,
                ),
                title: 'Default branch',
                // Pickable from the repo's own branches, never free text: a typo
                // here silently breaks diff-vs-default and the PR base. Needed
                // because `origin/HEAD` is genuinely absent after a
                // `--single-branch` clone or a default-branch rename.
                enabled: view.editable && view.branches.isNotEmpty,
                onTap: onChooseDefaultBranch,
                value: view.defaultBranch,
                mono: true,
                action: _Chevron(
                  enabled: view.editable && view.branches.isNotEmpty,
                ),
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
              style: Theme.of(
                context,
              ).textTheme.bodySmall?.copyWith(color: cs.outline),
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

  /// Visible for [_ProviderRow].
  static String forgeSubtitle(RepoSettingsView v) {
    if (v.providerChoice == ForgeChoice.none) {
      return 'No forge · pull requests are not checked for this repository';
    }
    if (v.providerChoice != ForgeChoice.auto) {
      return 'Set to ${v.providerChoice.label}'
          '${v.forgeHost == null ? '' : ' · ${v.forgeHost}'}';
    }
    // "No remote" is a conclusion; "not identified yet" is a pending probe. Saying
    // the second when the first is true sends the reader looking for a fix that
    // does not exist.
    if (!v.hasRemote) return 'Auto: no remote, so no forge';
    if (v.forge == null) return 'Auto: not identified yet';
    final parts = <String>[
      'Auto: ${forgeNameFor(v.forge!)}',
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
/// No subtitle slot: a description under a row labelled "Logo" is words about
/// words. The one row with a genuine second fact — the forge's host — builds its
/// own ListTile in [_ProviderRow].
class _SettingsValueRow extends StatelessWidget {
  const _SettingsValueRow({
    required this.title,
    this.leading,
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
    final valueStyle = t.textTheme.bodySmall?.copyWith(
      color: cs.onSurfaceVariant,
    );
    return ListTile(
      enabled: enabled,
      onTap: enabled ? onTap : null,
      leading: leading,
      title: Text(title),
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
            SettingsResetButton(
              visible: resetVisible,
              onPressed: onReset ?? () {},
            ),
        ],
      ),
    );
  }
}

/// The Git provider row and its selector.
///
/// Row then segmented control below, exactly as `Endpoint` does it, so the
/// subtitle can say what `Auto` resolved to and the default is legible rather than
/// mysterious.
class _ProviderRow extends StatelessWidget {
  const _ProviderRow({required this.view, this.onChoose});
  final RepoSettingsView view;
  final ValueChanged<ForgeChoice>? onChoose;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final detected = view.forge;
    final overridden = view.providerChoice != ForgeChoice.auto;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        ListTile(
          leading: view.providerChoice == ForgeChoice.none || !view.hasRemote
              // Not a question mark: nothing is being asked. This state is settled.
              ? Icon(PhosphorIconsLight.prohibit, size: 20, color: cs.outline)
              : detected == null
              ? Icon(PhosphorIconsLight.question, size: 20, color: cs.outline)
              : SizedBox(
                  width: 20,
                  height: 20,
                  child: forgeGlyphFor(
                    detected,
                  ).build(size: 20, color: cs.primary),
                ),
          title: const Text('Git provider'),
          subtitle: Text(RepositorySettingsSection.forgeSubtitle(view)),
          trailing: SettingsResetButton(
            visible: overridden && view.editable,
            onPressed: () => onChoose?.call(ForgeChoice.auto),
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(kSpace24, 0, kSpace24, kSpace8),
          child: SegmentedButton<ForgeChoice>(
            segments: [
              for (final c in ForgeChoice.values)
                ButtonSegment(value: c, label: Text(c.label)),
            ],
            selected: {view.providerChoice},
            showSelectedIcon: false,
            onSelectionChanged: onChoose == null
                ? null
                : (s) => onChoose!(s.first),
          ),
        ),
      ],
    );
  }
}

/// The "opens something" affordance, sized to the reset slot so every row keeps
/// one right edge whether it navigates, copies or resets.
class _Chevron extends StatelessWidget {
  const _Chevron({required this.enabled});
  final bool enabled;
  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return SizedBox(
      width: 40,
      child: Icon(
        PhosphorIconsLight.caretRight,
        size: 16,
        color: enabled ? cs.outline : cs.outline.withValues(alpha: 0.35),
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
