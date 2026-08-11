// The settings taxonomy becomes a function of the repo list (SPEC-48 D1/D21).
// Before this it was a static `final List`, so a per-repo section was impossible.
import 'package:flutter_test/flutter_test.dart';
import 'package:makit/desktop/settings/registry/settings_registry.dart';
import 'package:makit/store/models.dart';

RepoInfo _repo(String id, String name, {bool pinned = true}) => RepoInfo.fromJson({
  'id': id,
  'name': name,
  'path': '/p/$name',
  'pinned': pinned,
  'isGitRepo': true,
  'worktrees': const <Map<String, dynamic>>[],
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

  test('isRepoSection distinguishes repo ids from app ones', () {
    expect(isRepoSection('repo:a'), isTrue);
    expect(isRepoSection('general'), isFalse);
    expect(repoSectionId('x'), 'repo:x');
  });
}
