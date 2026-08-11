import 'package:flutter_test/flutter_test.dart';
import 'package:makit/store/models.dart';

/// The target branch and its resolution flag, mirrored from `WorktreeDTO`.
///
/// `showsDiff` is the consumer-facing rule the server's `targetResolved` exists
/// for: when the target cannot be resolved the numbers are a working-tree-only
/// figure, so rendering them would claim a committed delta we never measured.
/// The failure mode is not a zero but a *plausible small* count, which is why
/// suppression has to be explicit rather than left to `hasChanges`.
Map<String, dynamic> wtJson(Map<String, dynamic> extra) => {
  'id': '/wt/child',
  'path': '/wt/child',
  'branch': 'feat/child',
  'isPrimary': false,
  'insertions': 3,
  'deletions': 1,
  'filesChanged': 2,
  'sessionIds': <String>[],
  ...extra,
};

void main() {
  test('parses targetBranch and targetResolved', () {
    final w = Worktree.fromJson(
      wtJson({'targetBranch': 'feat/parent', 'targetResolved': true}),
    )!;
    expect(w.targetBranch, 'feat/parent');
    expect(w.targetResolved, isTrue);
  });

  test('a null targetBranch is preserved (primary / detached)', () {
    final w = Worktree.fromJson(
      wtJson({'targetBranch': null, 'targetResolved': true, 'isPrimary': true}),
    )!;
    expect(w.targetBranch, isNull);
  });

  test('targetResolved defaults to true when the server omits it', () {
    // Forward compatibility: an older server sends neither field. Defaulting to
    // "resolved" keeps today's rendering rather than blanking every pill.
    final w = Worktree.fromJson(wtJson({}))!;
    expect(w.targetBranch, isNull);
    expect(w.targetResolved, isTrue);
    expect(w.showsDiff, isTrue);
  });

  test('showsDiff is false when a target exists but did not resolve', () {
    final w = Worktree.fromJson(
      wtJson({'targetBranch': 'feat/gone', 'targetResolved': false}),
    )!;
    expect(w.hasChanges, isTrue, reason: 'the raw numbers are still non-zero');
    expect(
      w.showsDiff,
      isFalse,
      reason:
          'a partial count must not be rendered as if it were the full diff',
    );
  });

  test('showsDiff is true when there is no target to resolve', () {
    // The primary checkout legitimately reports working-tree-only numbers.
    final w = Worktree.fromJson(
      wtJson({'targetBranch': null, 'targetResolved': true}),
    )!;
    expect(w.showsDiff, isTrue);
  });

  test('showsDiff is false when there is nothing to show', () {
    final w = Worktree.fromJson(
      wtJson({
        'insertions': 0,
        'deletions': 0,
        'filesChanged': 0,
        'targetBranch': 'main',
        'targetResolved': true,
      }),
    )!;
    expect(w.showsDiff, isFalse);
  });

  test('targetUnresolved names the state the UI must explain', () {
    final broken = Worktree.fromJson(
      wtJson({'targetBranch': 'feat/gone', 'targetResolved': false}),
    )!;
    final fine = Worktree.fromJson(
      wtJson({'targetBranch': 'main', 'targetResolved': true}),
    )!;
    expect(broken.targetUnresolved, isTrue);
    expect(fine.targetUnresolved, isFalse);
  });
}
