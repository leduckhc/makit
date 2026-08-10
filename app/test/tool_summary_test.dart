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

    test('keeps an inline env assignment that prefixes a real command', () {
      expect(
        compactCommand('NODE_ENV=production npm run build && echo ok'),
        'NODE_ENV=production npm run build › echo ok',
      );
    });

    test('collapses every heredoc in the command', () {
      expect(
        compactCommand(
          "python3 <<'EOF'\na\nEOF\ncat <<'X'\nb\nc\nX\necho done",
        ),
        'python3 «heredoc, 1 line» › cat «heredoc, 2 lines» › echo done',
      );
    });

    test('collapses an unterminated heredoc to the end of the command', () {
      expect(
        compactCommand("python3 <<'EOF'\na\nb"),
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

  // ─────────────────────────────────────────────────────────────────────────
  // commandNames — the corpus is `mockups/tool-one-liner.html` §2, verbatim.
  // Each test names the rule (T1…T7) it pins.
  // ─────────────────────────────────────────────────────────────────────────
  group('commandNames', () {
    test('T1 splits a pipeline into its members', () {
      expect(commandNames('grep -rn x src | head -20'), 'grep, head');
    });

    test('T1 splits on &&, ||, ; and newlines', () {
      expect(commandNames('sed -i s/a/b/ x.ts && grep -n b x.ts'), 'sed, grep');
      expect(commandNames('rg foo || rg bar; wc -l x\nsort x'), 'rg, wc, sort');
    });

    test('T1 does not split on operators inside quotes', () {
      expect(commandNames('git commit -m "a && b; c | d"'), 'git commit');
    });

    test('T2 recurses into a command substitution', () {
      expect(commandNames(r'kill $(lsof -t -i:9787)'), 'kill, lsof');
      expect(commandNames('kill `lsof -t -i:9787`'), 'kill, lsof');
    });

    test('T3 drops the cd/export/source/set prologue', () {
      expect(
        commandNames(
          'set -euo pipefail; source .env; cd server && pnpm typecheck',
        ),
        'pnpm typecheck',
      );
    });

    test('T3 drops a loop header but keeps its body', () {
      expect(
        commandNames(
          r'for f in lib/*.dart; do wc -l "$f"; done | sort -n | tail -5',
        ),
        'wc, sort, tail',
      );
    });

    test('T4 unwraps wrappers and takes the basename', () {
      expect(
        commandNames('time ~/flutter/bin/flutter test --no-pub'),
        'flutter test',
      );
      expect(commandNames('sudo lsof -i:80'), 'lsof');
      expect(commandNames('xargs grep -l TODO'), 'grep');
      expect(commandNames('./scripts/deploy.sh --dry-run'), 'deploy.sh');
    });

    test('T4 normalises a versioned interpreter', () {
      expect(commandNames('python3 -c "print(1)"'), 'python');
      expect(commandNames('python3.12 tool/wait.py'), 'python');
      expect(commandNames('pip3 install -r requirements.txt'), 'pip install');
    });

    test('T4 keeps an inline env assignment out of the name', () {
      expect(commandNames('NODE_ENV=production pnpm run build'), 'pnpm build');
    });

    test('T5 keeps the subcommand only for a multiplexer', () {
      expect(commandNames('gh pr view 154 --json title'), 'gh pr');
      expect(commandNames('makit serve --port 7810'), 'makit serve');
      expect(commandNames('git -C /repo status --short'), 'git status');
      expect(
        commandNames('defaults write dev.getmakit.app x -int 1'),
        'defaults write',
      );
      expect(commandNames('make -j8 build'), 'make build');
      expect(commandNames('docker compose up -d'), 'docker compose');
    });

    test('T5 discards the second token for everything else', () {
      expect(commandNames("sed -i '' 's/a/b/' x.ts"), 'sed');
      expect(commandNames('lsof -nP -iTCP:7800-7899 -sTCP:LISTEN'), 'lsof');
      expect(commandNames('curl -sS https://example.com/a/b'), 'curl');
      expect(commandNames('ssh le@host uptime'), 'ssh');
    });

    test('T5 never scans a heredoc body for commands', () {
      expect(
        commandNames("python3 - <<'EOF'\nimport os\nprint(1)\nEOF"),
        'python',
      );
    });

    test('T6 skips a filler subcommand', () {
      expect(commandNames('pnpm run build'), 'pnpm build');
      expect(commandNames('pnpm exec tsx test/e2e-server.ts'), 'pnpm tsx');
      expect(commandNames('npm run test -- --watch'), 'npm test');
    });

    // A redirection is not a separator and not a command. `&` splits a
    // background job, but the `&` in `2>&1` / `&>` belongs to the redirect, and
    // a redirect's target is not the next command. Reported in review: this
    // rendered `Run pnpm typecheck, 1`.
    test('T2a a redirection contributes no name', () {
      expect(
        commandNames('pnpm typecheck > /tmp/tc.log 2>&1'),
        'pnpm typecheck',
      );
      expect(commandNames('grep x 2>&1 | tail'), 'grep, tail');
      expect(commandNames('cmd &> log'), 'cmd');
      expect(commandNames('cmd >>log 2>&1'), 'cmd');
      expect(
        commandNames('make build 2>/dev/null && echo ok'),
        'make build, echo',
      );
    });

    test('T2a a leading redirection does not become the command', () {
      expect(commandNames('> out.txt grep foo'), 'grep');
      expect(commandNames('2> err.log tail -f x'), 'tail');
    });

    test('T2a a background & still separates', () {
      expect(
        commandNames('makit serve --port 7810 & lsof -nP -i:7810'),
        'makit serve, lsof',
      );
    });

    test('T7 de-duplicates and keeps first-seen order', () {
      expect(
        commandNames('grep -rn a app && grep -rn b app && wc -l x && grep c'),
        'grep, wc',
      );
      expect(
        commandNames('git add -A && git commit -m wip && git push'),
        'git add, git commit, git push',
      );
    });

    test('T7 caps the list and counts the remainder', () {
      expect(
        commandNames('a1;b2;c3;d4;e5;f6;g7;h8;i9;j10'),
        'a1, b2, c3, d4, e5, f6, g7, h8 +2',
      );
    });

    test('an unknown binary renders as its bare name', () {
      expect(commandNames('dbvr datasource list'), 'dbvr');
    });

    test('returns an empty string when nothing informative is left', () {
      expect(commandNames('   '), '');
      expect(commandNames('cd /tmp'), '');
      expect(commandNames(r'export PATH=/x:$PATH'), '');
    });
  });

  group('splitVerb', () {
    test('splits a leading verb from its payload', () {
      final p = splitVerb('Run grep, head', 'Run');
      expect(p.verb, 'Run');
      expect(p.rest, 'grep, head');
    });

    test('keeps the payload of a one-word verb prefix', () {
      final p = splitVerb('Ask the user', 'Ask');
      expect(p.verb, 'Ask');
      expect(p.rest, 'the user');
    });

    test('treats the whole line as the verb when there is no payload', () {
      final p = splitVerb('Run', 'Run');
      expect(p.verb, 'Run');
      expect(p.rest, '');
    });

    test('does not weight a line that does not start with the verb', () {
      final p = splitVerb('some_mcp_tool foo', 'Run');
      expect(p.verb, '');
      expect(p.rest, 'some_mcp_tool foo');
    });
  });
}
