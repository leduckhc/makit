// The nav pane must search the sections it was GIVEN, not the static list.
// Without this the generated repo items exist but are unreachable, which looks
// identical to not generating them at all.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:makit/app/theme.dart';
import 'package:makit/desktop/settings/registry/settings_registry.dart';
import 'package:makit/desktop/settings/settings_nav_pane.dart';
import 'package:makit/store/models.dart';

void main() {
  testWidgets(
    'searching a repo-only term shows the result under the repo name',
    (t) async {
      final repo = RepoInfo.fromJson({
        'id': 'a',
        'name': 'Diana',
        'path': '/p/Diana',
        'pinned': true,
        'isGitRepo': true,
        'worktrees': const <Map<String, dynamic>>[],
      })!;
      final sections = sectionsFor([repo]);
      // Owned by the test, so the test disposes it: an undisposed ChangeNotifier is
      // what Flutter's leak tracking reports.
      final controller = TextEditingController(text: 'worktree root');
      addTearDown(controller.dispose);

      await t.pumpWidget(
        MaterialApp(
          theme: makitDarkTheme,
          home: Scaffold(
            body: SizedBox(
              width: 300,
              height: 700,
              child: SettingsNavPane(
                sections: sections,
                selectedId: sections.first.id,
                // A term only a repo section knows: nothing in the static list
                // mentions a worktree root.
                query: 'worktree root',
                controller: controller,
                onQueryChanged: (_) {},
                onSelect: (_, {String? targetItemId}) {},
                onSelectResult: (_, _) {},
                onClose: () {},
              ),
            ),
          ),
        ),
      );
      await t.pumpAndSettle();

      expect(
        find.text('No matches'),
        findsNothing,
        reason: 'the repo item must be found',
      );
      // Rendered under the repo's NAME, not its raw `repo:<id>` section id.
      expect(find.text('Diana'), findsWidgets);
      expect(find.textContaining('repo:a'), findsNothing);
    },
  );
}
