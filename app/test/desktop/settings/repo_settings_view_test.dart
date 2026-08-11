// Mapping wire facts to rendered facts. Kept apart from the widget tests because
// this is where "the app is told, never derives" is actually enforced.
import 'package:flutter_test/flutter_test.dart';
import 'package:makit/desktop/settings/sections/repository_section.dart';
import 'package:makit/store/models.dart';
import 'package:makit/ui/widgets/forge_glyph.dart';

RepoInfo _repo(Map<String, dynamic> settings, {List<Map<String, dynamic>> worktrees = const []}) =>
    RepoInfo.fromJson({
      'id': 'p1',
      'name': 'Diana',
      'path': '/Users/le/Work/XDent/Diana',
      'pinned': true,
      'isGitRepo': true,
      'defaultBranch': 'main',
      'currentBranch': 'main',
      'worktrees': worktrees,
      'settings': settings,
    })!;

const _root = {'value': '/Users/le/.worktrees', 'source': 'default'};

void main() {
  test('a server that sends no settings yields no view, not fabricated defaults', () {
    final repo = RepoInfo.fromJson({
      'id': 'p1',
      'name': 'Diana',
      'path': '/p',
      'pinned': true,
      'isGitRepo': true,
      'worktrees': const <Map<String, dynamic>>[],
    })!;
    expect(repoSettingsViewFor(repo), isNull);
  });

  test('the effective worktree root and its source come across', () {
    final v = repoSettingsViewFor(_repo({
      'worktreeRoot': {'value': '/Users/le/trees', 'source': 'override'},
      'provider': {'value': 'auto', 'source': 'default'},
      'hasRemote': true,
    }))!;
    expect(v.worktreeRoot, '/Users/le/trees');
    expect(v.worktreeRootOverridden, isTrue);
  });

  test('environment-sourced values are NOT shown as overrides', () {
    // MAKIT_WORKTREE_DIR is inherited, so it must not offer a reset the app cannot
    // honour — it cannot change the daemon's environment.
    final v = repoSettingsViewFor(_repo({
      'worktreeRoot': {'value': '/env/trees', 'source': 'environment'},
      'provider': {'value': 'auto', 'source': 'default'},
      'hasRemote': true,
    }))!;
    expect(v.worktreeRoot, '/env/trees');
    expect(v.worktreeRootOverridden, isFalse);
  });

  test('a forge we cannot talk to maps to no glyph, not to a wrong one', () {
    for (final software in ['gitlab', 'unknown', 'bitbucket']) {
      final v = repoSettingsViewFor(_repo({
        'worktreeRoot': _root,
        'provider': {'value': 'auto', 'source': 'default'},
        'hasRemote': true,
        'forge': {'software': software, 'host': 'h'},
      }))!;
      expect(v.forge, isNull, reason: software);
      expect(v.forgeHost, 'h', reason: 'the host still shows, so the row can name it');
    }
  });

  test('each known forge maps to its glyph', () {
    for (final pair in const [
      ['github', ForgeKind.github],
      ['forgejo', ForgeKind.forgejo],
      ['gitea', ForgeKind.gitea],
    ]) {
      final v = repoSettingsViewFor(_repo({
        'worktreeRoot': _root,
        'provider': {'value': 'auto', 'source': 'default'},
        'hasRemote': true,
        'forge': {'software': pair[0], 'host': 'h', 'authed': true},
      }))!;
      expect(v.forge, pair[1]);
      expect(v.forgeAuthed, isTrue);
    }
  });

  test('no remote and no detection are DIFFERENT states', () {
    final noRemote = repoSettingsViewFor(_repo({
      'worktreeRoot': _root,
      'provider': {'value': 'auto', 'source': 'default'},
      'hasRemote': false,
    }))!;
    final pending = repoSettingsViewFor(_repo({
      'worktreeRoot': _root,
      'provider': {'value': 'auto', 'source': 'default'},
      'hasRemote': true,
    }))!;
    expect(noRemote.hasRemote, isFalse);
    expect(pending.hasRemote, isTrue);
    expect(noRemote.forge, isNull);
    expect(pending.forge, isNull);
  });

  test('the provider choice round-trips, unknown wire values falling back to auto', () {
    ForgeChoice choiceFor(String wire) => repoSettingsViewFor(_repo({
      'worktreeRoot': _root,
      'provider': {'value': wire, 'source': 'override'},
      'hasRemote': true,
    }))!.providerChoice;
    expect(choiceFor('none'), ForgeChoice.none);
    expect(choiceFor('forgejo'), ForgeChoice.forgejo);
    expect(choiceFor('gitea'), ForgeChoice.gitea);
    expect(choiceFor('github'), ForgeChoice.github);
    // A newer server sending a provider this build has never heard of must not
    // crash the settings page.
    expect(choiceFor('mercurial-hub'), ForgeChoice.auto);
  });

  test('an override wins over git for the default branch', () {
    final v = repoSettingsViewFor(_repo({
      'worktreeRoot': _root,
      'provider': {'value': 'auto', 'source': 'default'},
      'hasRemote': true,
      'defaultBranch': {'value': 'develop', 'source': 'override'},
    }))!;
    expect(v.defaultBranch, 'develop');
  });

  test('with no override the branch comes from git, not from settings', () {
    final v = repoSettingsViewFor(_repo({
      'worktreeRoot': _root,
      'provider': {'value': 'auto', 'source': 'default'},
      'hasRemote': true,
    }))!;
    expect(v.defaultBranch, 'main');
  });

  test('branches are offered from the repo itself, deduped and sorted', () {
    final v = repoSettingsViewFor(_repo(
      {
        'worktreeRoot': _root,
        'provider': {'value': 'auto', 'source': 'default'},
        'hasRemote': true,
      },
      worktrees: [
        {'id': 'w1', 'path': '/a', 'branch': 'feat/z'},
        {'id': 'w2', 'path': '/b', 'branch': 'main'},
        {'id': 'w3', 'path': '/c', 'branch': 'feat/z'},
        {'id': 'w4', 'path': '/d'},
      ],
    ))!;
    expect(v.branches, ['feat/z', 'main']);
  });

  test('a malformed settings object yields no view rather than throwing', () {
    for (final bad in [<String, dynamic>{}, {'worktreeRoot': 7}, {'worktreeRoot': {'value': 1}}]) {
      expect(repoSettingsViewFor(_repo(bad)), isNull, reason: bad.toString());
    }
  });
}
