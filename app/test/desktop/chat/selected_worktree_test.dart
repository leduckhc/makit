import 'package:flutter_test/flutter_test.dart';
import 'package:makit/desktop/chat/selected_worktree.dart';

void main() {
  group('draftWorktreeFor', () {
    test('keys the virtual worktree path by the draft prefix + session id', () {
      final wt = draftWorktreeFor('p1', 's1');
      expect(wt.path, '${kDraftWorktreePrefix}s1');
      expect(wt.path, 'draft:s1');
    });

    test('carries the given projectId and always has a null branch', () {
      final wt = draftWorktreeFor('proj-42', 'session-7');
      expect(wt.projectId, 'proj-42');
      expect(wt.branch, isNull);
    });

    test('two different session ids never collide on the same key', () {
      final a = draftWorktreeFor('p1', 's1');
      final b = draftWorktreeFor('p1', 's2');
      expect(a.path, isNot(b.path));
    });

    test('the draft key is distinct from any plausible real worktree path', () {
      final wt = draftWorktreeFor('p1', 's1');
      expect(wt.path.startsWith(kDraftWorktreePrefix), isTrue);
      expect(wt.path.startsWith('/'), isFalse);
    });
  });
}
