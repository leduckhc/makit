import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:phosphoricons_flutter/phosphoricons_flutter.dart';

import '../../ui/widgets/codicons.dart';
import '../../ui/widgets/icon_glyph.dart';
import '../settings/prefs/preference.dart';
import '../settings/prefs/preference_entries.dart';
import '../settings/prefs/preferences_providers.dart';

/// PNG glyphs exported from the codicon `repo-push`/`repo-pull` SVGs
/// (assets/icons/, tinted at render time via [IconGlyph]/[ImageIcon]).
const String _repoPushAsset = 'assets/icons/repo-push.png';
const String _repoPullAsset = 'assets/icons/repo-pull.png';

/// The canned-prompt actions offered by the composer's "PR actions" split
/// button (SPEC-23). Each is an **app-owned, agent-agnostic prompt** — selecting
/// one inserts its text into the composer (it does not auto-send), so the user
/// reviews and hits Send. The prompt text is overridable per action in Settings
/// → Agents & Chat; an empty override means "use [defaultPrompt]".
enum PrPromptAction {
  createPr(
    'Create PR',
    IconGlyph.font(PhosphorIconsLight.gitPullRequest),
    prCreatePromptPreference,
    'Create a GitHub pull request for the current branch. Push the branch '
        'first if it has no upstream, then run `gh pr create` with a clear '
        'title and a description that summarizes what changed, why, and how it '
        'was tested. Reply with the PR URL when done.',
  ),
  fixPr(
    'Fix PR',
    IconGlyph.font(PhosphorIconsLight.wrench),
    prFixPromptPreference,
    'The CI checks on this pull request are failing. Use `gh pr checks` and '
        'the failing run logs to find the root cause, fix it on this branch, '
        'and push. Repeat until every required check is green.',
  ),
  resolveComments(
    'Resolve comments',
    IconGlyph.font(Codicons.commentDiscussion),
    prResolveCommentsPromptPreference,
    'Fetch the open review comments on this pull request (e.g. '
        '`gh pr view --comments`). Address each one with a concrete code change, '
        'or reply briefly explaining why no change is needed, then push and '
        'resolve the threads.',
  ),
  commitAndPush(
    'Commit and push',
    IconGlyph.font(PhosphorIconsLight.arrowLineUp),
    prCommitPushPromptPreference,
    'Commit the current uncommitted changes on this branch with a clear, '
        'conventional commit message summarizing what changed and why, then '
        'push to the remote (setting the upstream if the branch has none). '
        'Reply with the commit summary when done.',
  ),
  push(
    'Push',
    IconGlyph.asset(_repoPushAsset),
    prPushPromptPreference,
    'Push the current branch to its remote (use `git push -u` to set the '
        'upstream if it has none). Reply when the push succeeds.',
  ),
  pull(
    'Pull',
    IconGlyph.asset(_repoPullAsset),
    prPullPromptPreference,
    'Integrate the latest changes from the remote into this branch (e.g. '
        '`git pull --rebase`), resolving any conflicts. Reply when the branch '
        'is up to date.',
  );

  const PrPromptAction(
    this.label,
    this.icon,
    this.promptPreference,
    this.defaultPrompt,
  );

  /// Menu label, e.g. "Create PR".
  final String label;

  /// Leading glyph shown in the split-button menu (font icon or PNG asset).
  final IconGlyph icon;

  /// The preference holding the user's override ('' = use [defaultPrompt]).
  final PreferenceEntry<String> promptPreference;

  /// Built-in prompt used when the override is blank.
  final String defaultPrompt;
}

/// Resolve [action] to the name of the matching enum value, falling back to
/// the first action for an unknown/legacy stored value.
PrPromptAction prActionFromName(String name) => PrPromptAction.values
    .firstWhere((a) => a.name == name, orElse: () => PrPromptAction.createPr);

/// The effective prompt for [action]: the user's Settings override when it is
/// non-blank, else the built-in [PrPromptAction.defaultPrompt].
extension PrPromptResolution on WidgetRef {
  String effectivePrPrompt(PrPromptAction action) {
    final override = preference(action.promptPreference).trim();
    return override.isEmpty ? action.defaultPrompt : override;
  }
}
