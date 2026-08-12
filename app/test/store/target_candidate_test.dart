import 'package:flutter_test/flutter_test.dart';
import 'package:makit/store/models.dart';

void main() {
  test('parses a full candidate', () {
    final c = TargetCandidate.fromJson({
      'branch': 'feat/parent',
      'group': 'forkedFrom',
      'onRemote': true,
      'isSelf': false,
      'insertions': 96,
      'deletions': 12,
    })!;
    expect(c.branch, 'feat/parent');
    expect(c.group, TargetCandidateGroup.forkedFrom);
    expect(c.onRemote, isTrue);
    expect(c.isSelf, isFalse);
    expect(c.insertions, 96);
    expect(c.deletions, 12);
    expect(c.hasPreview, isTrue);
  });

  test('a candidate with no preview reports hasPreview false', () {
    final c = TargetCandidate.fromJson({
      'branch': 'zz-other',
      'group': 'other',
      'onRemote': true,
      'isSelf': false,
    })!;
    expect(c.hasPreview, isFalse);
    expect(c.insertions, isNull);
    expect(c.deletions, isNull);
  });

  test('a half-filled preview is not a preview', () {
    // The picker force-unwraps BOTH `insertions!` and `deletions!` behind
    // `hasPreview`, so one count alone must NOT report a preview or the picker
    // would throw on the missing half.
    final onlyIns = TargetCandidate.fromJson({
      'branch': 'zz-other',
      'group': 'other',
      'onRemote': true,
      'isSelf': false,
      'insertions': 5,
    })!;
    expect(onlyIns.hasPreview, isFalse);
    final onlyDel = TargetCandidate.fromJson({
      'branch': 'zz-other',
      'group': 'other',
      'onRemote': true,
      'isSelf': false,
      'deletions': 5,
    })!;
    expect(onlyDel.hasPreview, isFalse);
  });

  test('an unknown group falls back to other rather than throwing', () {
    // Forward compatibility: a newer server may add a group this build predates.
    final c = TargetCandidate.fromJson({
      'branch': 'x',
      'group': 'somethingNew',
      'onRemote': true,
      'isSelf': false,
    })!;
    expect(c.group, TargetCandidateGroup.other);
  });

  test('a candidate without a branch is rejected', () {
    expect(TargetCandidate.fromJson({'group': 'other'}), isNull);
  });

  test('selectable is false for self and for local-only branches', () {
    TargetCandidate c({bool self = false, bool remote = true}) =>
        TargetCandidate.fromJson({
          'branch': 'b',
          'group': 'other',
          'onRemote': remote,
          'isSelf': self,
        })!;
    expect(c().selectable, isTrue);
    expect(c(self: true).selectable, isFalse);
    // A PR base must exist on the remote, so an unpushed branch is refused —
    // listed with a reason rather than accepted and rejected later by `gh`.
    expect(c(remote: false).selectable, isFalse);
  });

  test('blockedReason explains each refusal in the user\'s terms', () {
    TargetCandidate c({bool self = false, bool remote = true}) =>
        TargetCandidate.fromJson({
          'branch': 'b',
          'group': 'other',
          'onRemote': remote,
          'isSelf': self,
        })!;
    expect(c().blockedReason, isNull);
    expect(c(self: true).blockedReason, 'this worktree');
    expect(c(remote: false).blockedReason, 'not pushed yet');
  });

  test('groupLabel names each section the way the picker shows it', () {
    expect(TargetCandidateGroup.forkedFrom.label, 'Forked from');
    expect(TargetCandidateGroup.defaultBranch.label, 'Repo default');
    expect(TargetCandidateGroup.worktree.label, 'Other worktrees');
    expect(TargetCandidateGroup.other.label, 'All branches');
  });
}
