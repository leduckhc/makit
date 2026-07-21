import 'package:flutter_test/flutter_test.dart';
import 'package:makit/store/models.dart';

void main() {
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
}
