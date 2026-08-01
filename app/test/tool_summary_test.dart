/// Tests for the collapsed one-liner compaction helpers: absolute paths get
/// shortened (relative to the session worktree when known) and bash commands
/// lose their repetitive `cd`/`export` prologue so the informative part fits
/// before the ellipsis.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:makit/ui/session/tool_summary.dart';

const _root = '/Users/le/.worktrees/makit/feat-mobile-parity';

void main() {
  group('compactPath', () {
    test('drops the session worktree prefix', () {
      expect(
        compactPath('$_root/app/lib/store/fake_server.dart', root: _root),
        'app/lib/store/fake_server.dart',
      );
    });

    test('renders the worktree root itself as a dot', () {
      expect(compactPath(_root, root: _root), '.');
    });

    test('keeps the tail when the path is outside the worktree', () {
      expect(
        compactPath('/Users/le/other/app/lib/store/fake_server.dart'),
        '…/app/lib/store/fake_server.dart',
      );
    });

    test('leaves short paths alone', () {
      expect(compactPath('/tmp/makit-demo.txt'), '/tmp/makit-demo.txt');
      expect(compactPath('lib/foo.dart'), 'lib/foo.dart');
      expect(
        compactPath('app/lib/store/fake_server.dart'),
        'app/lib/store/fake_server.dart',
      );
    });

    test('shortens a deep path even after the root is stripped', () {
      expect(
        compactPath(
          '$_root/app/lib/ui/session/tool_renderers.dart',
          root: _root,
        ),
        '…/lib/ui/session/tool_renderers.dart',
      );
    });
  });

  group('compactPathsIn', () {
    test('compacts every absolute path embedded in a line', () {
      expect(
        compactPathsIn(
          'Read $_root/app/lib/store/fake_server.dart',
          root: _root,
        ),
        'Read app/lib/store/fake_server.dart',
      );
    });

    test('compacts several paths in the same line', () {
      expect(
        compactPathsIn(
          'Moved $_root/app/a.dart to $_root/app/b.dart',
          root: _root,
        ),
        'Moved app/a.dart to app/b.dart',
      );
    });

    test('leaves URLs alone', () {
      expect(
        compactPathsIn(
          'Fetched https://github.com/alibaba/open-code-review/blob/main/README.md',
        ),
        'Fetched https://github.com/alibaba/open-code-review/blob/main/README.md',
      );
    });

    test('leaves relative paths alone (no leading-segment mangling)', () {
      expect(
        compactPathsIn(
          'Grep TODO in app/lib/ui/session/deep/nested/thing.dart',
        ),
        'Grep TODO in app/lib/ui/session/deep/nested/thing.dart',
      );
    });

    test('leaves path-free text untouched', () {
      expect(
        compactPathsIn('Ran git commit -m "feat(app): archived list"'),
        'Ran git commit -m "feat(app): archived list"',
      );
    });
  });

  group('compactCommand', () {
    test('strips a leading cd into the worktree', () {
      expect(
        compactCommand('cd $_root/app && flutter analyze --no-pub'),
        'flutter analyze --no-pub',
      );
    });

    test('folds a stripped env prologue into an +env marker', () {
      expect(
        compactCommand(
          'cd $_root/app && export PATH=/Users/le/flutter/bin:\$PATH && flutter analyze',
        ),
        'flutter analyze +env',
      );
    });

    test('marks the other env-mutating prologue forms too', () {
      expect(compactCommand('FOO=bar && pnpm test'), 'pnpm test +env');
      expect(compactCommand('source env.sh && pnpm test'), 'pnpm test +env');
      expect(compactCommand('set -euo pipefail; pnpm test'), 'pnpm test +env');
    });

    test('joins the remaining segments with a chevron', () {
      expect(
        compactCommand('cd $_root && git add -A && git commit -m "wip"'),
        'git add -A › git commit -m "wip"',
      );
    });

    test('collapses whitespace and newlines', () {
      expect(compactCommand('cd /x &&\n  pnpm  server'), 'pnpm server');
    });

    // The bare path survives here; `compactPathsIn` shortens it afterwards.
    test('keeps the command when every segment is prologue', () {
      expect(compactCommand('cd $_root/app'), 'cd $_root/app');
    });

    test('replaces a heredoc body with a line count', () {
      expect(
        compactCommand(
          "cd $_root/app && python3 <<'EOF'\nprint(1)\nprint(2)\nEOF",
        ),
        'python3 «heredoc, 2 lines»',
      );
    });

    test('keeps commands chained after the heredoc terminator', () {
      expect(
        compactCommand("python3 <<'EOF'\nprint(1)\nEOF\necho done"),
        'python3 «heredoc, 1 line» › echo done',
      );
    });

    test('does not split on operators inside escaped quotes', () {
      expect(
        compactCommand(r'git commit -m "a \" && b"'),
        r'git commit -m "a \" && b"',
      );
    });

    test('does not split on operators inside quotes', () {
      expect(
        compactCommand('git commit -m "a && b; c"'),
        'git commit -m "a && b; c"',
      );
    });

    test('returns an empty string for an empty command', () {
      expect(compactCommand('   '), '');
    });
  });
}
