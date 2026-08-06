import 'package:flutter_test/flutter_test.dart';
import 'package:makit/store/models.dart';

void main() {
  _wrapUpAndBaseRefTests();
  test('PullRequest.fromJson parses CI checks + mergeability', () {
    final pr = PullRequest.fromJson({
      'number': 42,
      'url': 'https://github.com/o/r/pull/42',
      'state': 'OPEN',
      'title': 'feat: thing',
      'isDraft': false,
      'mergeable': 'MERGEABLE',
      'mergeStateStatus': 'CLEAN',
      'checkRollup': 'pending',
      'checks': [
        {
          'name': 'test',
          'bucket': 'pass',
          'workflowName': 'CI',
          'detailsUrl': 'https://x/1',
        },
        {'name': 'e2e', 'bucket': 'pending'},
      ],
    });

    expect(pr, isNotNull);
    expect(pr!.number, 42);
    expect(pr.mergeable, 'MERGEABLE');
    expect(pr.mergeStateStatus, 'CLEAN');
    expect(pr.checkRollup, 'pending');
    expect(pr.checks, hasLength(2));
    expect(pr.checks.first.name, 'test');
    expect(pr.checks.first.bucket, 'pass');
    expect(pr.checks.first.workflowName, 'CI');
    expect(pr.checks[1].workflowName, isNull);
    expect(pr.checks[1].detailsUrl, isNull);
  });

  test(
    'PullRequest.fromJson defaults new fields when absent (legacy wire)',
    () {
      final pr = PullRequest.fromJson({
        'number': 7,
        'url': 'u',
        'state': 'OPEN',
        'title': 't',
        'isDraft': true,
      });

      expect(pr, isNotNull);
      expect(pr!.mergeable, isNull);
      expect(pr.mergeStateStatus, isNull);
      expect(pr.checks, isEmpty);
      expect(pr.checkRollup, 'none');
    },
  );

  test('PullRequest.fromJson returns null without a number', () {
    expect(PullRequest.fromJson({'url': 'u'}), isNull);
  });

  test(
    'PullRequest.fromJson defaults stale/unresolvedUnknown false when absent',
    () {
      // Every server that predates SPEC-32 omits these fields; the pill must
      // still decode and render as a fresh, fully-known PR.
      final pr = PullRequest.fromJson({
        'number': 7,
        'url': 'u',
        'state': 'OPEN',
        'title': 't',
        'isDraft': false,
      });
      expect(pr, isNotNull);
      expect(pr!.stale, isFalse);
      expect(pr.unresolvedUnknown, isFalse);
    },
  );

  test('PullRequest.fromJson carries stale/unresolvedUnknown when present', () {
    final pr = PullRequest.fromJson({
      'number': 7,
      'url': 'u',
      'state': 'OPEN',
      'title': 't',
      'isDraft': false,
      'stale': true,
      'unresolvedUnknown': true,
    });
    expect(pr!.stale, isTrue);
    expect(pr.unresolvedUnknown, isTrue);
  });
}

// ── baseRefName + WrapUpReport (PR actions) ─────────────────────────────────

void _wrapUpAndBaseRefTests() {
  group('baseRefName', () {
    test('decodes the branch the PR merges into', () {
      final pr = PullRequest.fromJson({
        'number': 7,
        'baseRefName': 'release/2.0',
      });
      expect(pr!.baseRefName, 'release/2.0');
    });

    test('is null on a server that predates the field', () {
      // Wrap up then falls back to the repo's default branch server-side, so a
      // missing value must decode as null rather than throwing or defaulting to
      // a guessed "main".
      expect(PullRequest.fromJson({'number': 7})!.baseRefName, isNull);
    });

    test('ignores a non-string value instead of dropping the whole PR', () {
      final pr = PullRequest.fromJson({'number': 7, 'baseRefName': 42});
      expect(pr, isNotNull);
      expect(pr!.baseRefName, isNull);
    });
  });

  group('WrapUpReport', () {
    test('decodes a full report', () {
      final r = WrapUpReport.fromJson({
        'branchDeleted': 'feat/x',
        'baseBranch': 'main',
        'baseUpdated': true,
      });
      expect(r.branchDeleted, 'feat/x');
      expect(r.baseBranch, 'main');
      expect(r.baseUpdated, isTrue);
      expect(r.baseReason, isNull);
      expect(r.summary, 'Removed feat/x · main updated');
    });

    test('says the base was left alone when it was not fast-forwardable', () {
      final r = WrapUpReport.fromJson({
        'branchDeleted': 'feat/x',
        'baseBranch': 'main',
        'baseUpdated': false,
        'baseReason': 'main has local commits that are not on origin/main',
      });
      expect(r.summary, 'Removed feat/x · main unchanged');
      expect(r.baseReason, contains('local commits'));
    });

    test('a detached worktree reports the removal without a branch', () {
      final r = WrapUpReport.fromJson({'baseBranch': 'main'});
      expect(r.summary, 'Worktree removed · main unchanged');
    });

    test('an empty ack degrades instead of throwing', () {
      // The worktree is already gone by the time this arrives, so the UI must
      // still be able to say something.
      final r = WrapUpReport.fromJson(const {});
      expect(r.summary, 'Worktree removed');
      expect(r.baseUpdated, isFalse);
    });
  });
}
