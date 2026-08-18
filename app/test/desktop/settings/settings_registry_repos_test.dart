// The settings taxonomy becomes a function of the repo list (SPEC-per-repo-settings D1/D21).
// Before this it was a static `final List`, so a per-repo section was impossible.
import 'package:flutter_test/flutter_test.dart';
import 'package:makit/desktop/settings/registry/settings_registry.dart';
import 'package:makit/store/models.dart';
import 'package:makit/ui/home/repo_monogram.dart';

RepoInfo _repo(String id, String name, {bool pinned = true, int? logoHue}) =>
    RepoInfo.fromJson({
      'id': id,
      'name': name,
      'path': '/p/$name',
      'pinned': pinned,
      'isGitRepo': true,
      'worktrees': const <Map<String, dynamic>>[],
      if (logoHue != null)
        'settings': {
          'worktreeRoot': {'value': '/w', 'source': 'default'},
          'provider': {'value': 'auto', 'source': 'default'},
          'hasRemote': true,
          'logoHue': logoHue,
        },
    })!;

void main() {
  test('the fixed sections are unchanged and come first', () {
    final s = sectionsFor([_repo('a', 'Diana')]);
    expect(
      s.take(kSettingsSections.length).map((x) => x.id),
      kSettingsSections.map((x) => x.id),
    );
  });

  test('one section per PINNED repo; unpinned ones stay out of the sidebar', () {
    // This is what bounds the sidebar. Without the filter it grows into a file
    // browser as makit notices repos.
    final s = sectionsFor([
      _repo('a', 'Diana'),
      _repo('b', 'noticed', pinned: false),
      _repo('c', 'makit'),
    ]);
    final ids = s.map((x) => x.id).where(isRepoSection).toList();
    expect(ids, ['repo:a', 'repo:c']);
  });

  test('no repos means no repo sections, and no empty group', () {
    final s = sectionsFor(const []);
    expect(s.where((x) => isRepoSection(x.id)), isEmpty);
    expect(s.length, kSettingsSections.length);
  });

  test('the section id is keyed off the persisted id, not the name or path', () {
    // So a repo that is renamed or moved keeps its section and its deep links.
    final s = sectionsFor([_repo('abc-123', 'Diana')]);
    expect(s.last.id, 'repo:abc-123');
    expect(s.last.title, 'Diana');
  });

  test('repo rows are searchable, and their titles are not raw ids', () {
    final sections = sectionsFor([_repo('a', 'Diana')]);
    final hits = searchSettings('worktree root', sections: sections);
    expect(hits.any((h) => h.sectionId == 'repo:a'), isTrue);
    // The title the nav pane shows for the owning section.
    final titles = {for (final s in sections) s.id: s.title};
    expect(titles['repo:a'], 'Diana');
  });

  test('searching something only a repo section knows finds it', () {
    final sections = sectionsFor([_repo('a', 'Diana')]);
    expect(searchSettings('forge', sections: sections), isNotEmpty);
    // …and the static list alone does not, which is why threading matters.
    expect(
      searchSettings('worktree root', sections: kSettingsSections),
      isEmpty,
    );
  });

  group('the sidebar tells the repos apart (SPEC-per-repo-settings D15)', () {
    test(
      'a repo section leads with its own mark, not a folder every repo shares',
      () {
        // A folder glyph on every row makes the sections indistinguishable in exactly
        // the place the monogram exists to disambiguate \u2014 and it is where the user
        // looks after choosing a colour, so the choice appears to have done nothing.
        final section = sectionsFor([
          _repo('a', 'Diana'),
        ]).firstWhere((x) => x.id == 'repo:a');
        expect(section.leading, isA<RepoMonogram>());
        expect((section.leading! as RepoMonogram).name, 'Diana');
      },
    );

    test(
      'the mark carries the chosen hue, so the sidebar shows the choice',
      () {
        final section = sectionsFor([
          _repo('a', 'Diana', logoHue: 2),
        ]).firstWhere((x) => x.id == 'repo:a');
        expect((section.leading! as RepoMonogram).hue, 2);
      },
    );

    test('an app section has no mark, so the icon still renders', () {
      expect(sectionsFor(const []).first.leading, isNull);
    });
  });

  test('isRepoSection distinguishes repo ids from app ones', () {
    expect(isRepoSection('repo:a'), isTrue);
    expect(isRepoSection('general'), isFalse);
    expect(repoSectionId('x'), 'repo:x');
  });
}
