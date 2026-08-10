/// Collapsed one-liner compaction (pure string helpers, no Flutter deps).
///
/// A tool row in the transcript shows a single ellipsised line, so the first
/// ~40 characters decide whether it is readable. Absolute paths and the
/// `cd <worktree> && export …` prologue of agent-issued shell commands waste
/// all of them, which makes consecutive rows look identical. These helpers
/// strip that noise before the row is rendered; the expanded body still shows
/// the verbatim path/command.
library;

/// Collapse a (possibly multi-line) string into one whitespace-normalised line.
String oneLine(String s) => s.trim().replaceAll(RegExp(r'\s+'), ' ');

/// Max path segments kept before the head is replaced by an ellipsis.
const int _maxPathSegments = 4;

/// Shorten [path] for a collapsed one-liner: relative to [root] when it lives
/// inside it, then head-truncated to the last few segments so the filename —
/// the informative part — survives the row's trailing ellipsis.
String compactPath(String path, {String? root}) {
  var p = path;
  if (root != null && root.isNotEmpty) {
    if (p == root) return '.';
    final prefix = root.endsWith('/') ? root : '$root/';
    if (p.startsWith(prefix)) p = p.substring(prefix.length);
  }
  final segments = p.split('/').where((s) => s.isNotEmpty).toList();
  if (segments.length <= _maxPathSegments) return p;
  final tail = segments.sublist(segments.length - _maxPathSegments);
  return '…/${tail.join('/')}';
}

/// Absolute POSIX paths: a `/` at a word boundary followed by at least two
/// segments, so `a/b` or a bare `/` is not mistaken for one. The leading
/// `(?<![\w:/])` guard keeps this off the tail of a relative path
/// (`a/b/c/d/e` must not match `/b/c/d/e`) and off URLs (`https://host/a/b`),
/// whose scheme and host would otherwise be eaten by the head-truncation.
/// Deliberately conservative about the characters allowed in a segment — a
/// path inside a quoted commit message may be compacted too, which is fine,
/// but shell operators must never be swallowed.
final RegExp _absolutePath = RegExp(r'(?<![\w:/])/[\w.\-@+]+(?:/[\w.\-@+]+)+');

/// Apply [compactPath] to every absolute path embedded in [line].
String compactPathsIn(String line, {String? root}) =>
    line.replaceAllMapped(_absolutePath, (m) => compactPath(m[0]!, root: root));

/// Shell prologue segments that carry no information about what the agent
/// actually did: entering the worktree, exporting a toolchain onto `PATH`,
/// sourcing an env file, `set -euo pipefail`.
final RegExp _prologue = RegExp(r'^(cd\s|export\s|source\s|\.\s|set\s+[-+])');

/// A segment that is *only* an assignment (`FOO=bar`). Anchored at both ends so
/// an assignment that prefixes a real command (`NODE_ENV=production npm run
/// build`) is kept — there the assignment is not prologue, it is part of what
/// the agent ran.
final RegExp _bareAssignment = RegExp(r'^[A-Za-z_][A-Za-z0-9_]*=\S*$');

/// True when [segment] is prologue at all (env mutation or a `cd`).
bool _isPrologue(String segment) =>
    _prologue.hasMatch(segment) || _bareAssignment.hasMatch(segment);

/// True when [segment] is a prologue segment that mutates the environment
/// (as opposed to `cd`, which is silently dropped).
bool _isEnv(String segment) =>
    !segment.startsWith('cd ') && !segment.startsWith('cd\t');

/// Shorten a shell command for a collapsed one-liner: drop the prologue, mark
/// stripped env mutations with `+env`, replace a heredoc body with its line
/// count, and join the remaining segments with `›`. Falls back to the plain
/// one-lined command when nothing informative is left.
String compactCommand(String command) {
  final full = oneLine(command);
  if (full.isEmpty) return '';

  final segments = _splitTopLevel(_stripHeredocs(command));
  final kept = <String>[];
  var env = false;
  for (final s in segments) {
    if (_isPrologue(s)) {
      env |= _isEnv(s);
      continue;
    }
    kept.add(s);
  }
  if (kept.isEmpty) return full;
  return '${kept.join(' › ')}${env ? ' +env' : ''}';
}

final RegExp _heredocOpen = RegExp(r'<<-?\s*[\x27"]?(\w+)[\x27"]?');

/// Replace every heredoc (`… <<'EOF' … EOF`) body with a `«heredoc, N lines»`
/// marker. A body is often a whole script — useless in one line and full of
/// operators that would confuse [_splitTopLevel]. Text between and after the
/// terminators is kept verbatim, so `python3 <<EOF … EOF && echo done` still
/// shows the `echo done`. An unterminated heredoc runs to the end of the
/// command.
String _stripHeredocs(String command) {
  final out = StringBuffer();
  var rest = command;
  while (true) {
    final open = _heredocOpen.firstMatch(rest);
    if (open == null) {
      out.write(rest);
      return out.toString();
    }
    final tag = open[1]!;
    final lines = rest.substring(open.end).split('\n').skip(1).toList();
    final end = lines.indexWhere((l) => l.trim() == tag);
    final bodyLines = end < 0 ? lines.length : end;
    out.write(rest.substring(0, open.start));
    out.write('«heredoc, $bodyLines line${bodyLines == 1 ? '' : 's'}»');
    if (end < 0) return out.toString();
    out.write('\n');
    rest = lines.sublist(end + 1).join('\n');
  }
}

/// Split a command on top-level `&&`, `||`, `;` and newlines, ignoring
/// operators inside single/double quotes (and backslash-escaped quotes, so
/// `-m "a \" && b"` stays one segment). Pipes stay inside their segment:
/// `grep x | head` is one thing the agent did, not two.
List<String> _splitTopLevel(String command) {
  final segments = <String>[];
  final buf = StringBuffer();
  String? quote;
  for (var i = 0; i < command.length; i++) {
    final c = command[i];
    // An escape keeps the next character literal, so it can neither open nor
    // close a quoted run (`\"` inside "…" is a quote character, not the end).
    // Inside single quotes a backslash is literal in POSIX sh, so skip it.
    if (c == r'\' && quote != "'" && i + 1 < command.length) {
      buf.write(c);
      buf.write(command[i + 1]);
      i++;
      continue;
    }
    if (quote != null) {
      buf.write(c);
      if (c == quote) quote = null;
      continue;
    }
    if (c == "'" || c == '"') {
      quote = c;
      buf.write(c);
      continue;
    }
    final two = i + 1 < command.length ? command.substring(i, i + 2) : '';
    if (two == '&&' || two == '||') {
      segments.add(buf.toString());
      buf.clear();
      i++;
      continue;
    }
    if (c == ';' || c == '\n') {
      segments.add(buf.toString());
      buf.clear();
      continue;
    }
    buf.write(c);
  }
  segments.add(buf.toString());
  return segments.map(oneLine).where((s) => s.isNotEmpty).toList();
}

// ─────────────────────────────────────────────────────────────────────────────
// Command-name summary
//
// A collapsed shell row lists the *commands* the agent ran, not their
// arguments: `Run grep, gh pr, sed, makit serve, python, head, lsof`. The
// arguments are still one hover (tooltip) or one tap (expanded body) away, and
// they were never readable inside 40 ellipsised characters anyway.
//
// The rule ladder below is documented — with its full test corpus — in
// `mockups/tool-one-liner.html` §2. Keep the two in step.
// ─────────────────────────────────────────────────────────────────────────────

/// Binaries that run *another* command; the interesting name is the wrapped
/// one, so these are skipped over rather than reported.
const Set<String> _wrappers = {
  'sudo',
  'doas',
  'env',
  'time',
  'nice',
  'nohup',
  'exec',
  'command',
  'builtin',
  'stdbuf',
  'xargs',
  'timeout',
  'caffeinate',
  'script',
  'strace',
  'ltrace',
  'dtruss',
  'watch',
};

/// Shell syntax that can appear where a command name would be.
const Set<String> _shellKeywords = {
  'then',
  'else',
  'elif',
  'fi',
  'do',
  'done',
  'esac',
  'in',
  'function',
  '{',
  '}',
  '[[',
  ']]',
  '!',
  '(',
  ')',
  'coproc',
};

/// Openers of a compound statement. The whole segment is plumbing (`for f in
/// *.dart`), while the body arrives as a later segment (`do wc -l "$f"`), so
/// the segment is dropped rather than scanned.
const Set<String> _compoundHeads = {
  'for',
  'while',
  'until',
  'case',
  'if',
  'elif',
  'select',
};

/// Heads of a prologue segment: entering the tree, mutating the environment,
/// setting shell options. Never worth a name of its own.
const Set<String> _prologueHeads = {
  'cd',
  'export',
  'source',
  '.',
  'set',
  'shopt',
  'umask',
  'ulimit',
  'unset',
  'alias',
  'eval',
};

/// Subcommands that are pure plumbing: the *next* word is the information
/// (`pnpm run build` → `pnpm build`).
const Set<String> _fillerSubcommands = {'run', 'exec', 'dlx', '--'};

/// Multiplexers — binaries whose bare name leaves you asking "doing what?", so
/// the first bare-word argument is kept (`git commit`, `gh pr`, `makit serve`).
/// Everything absent from this set renders as its bare name, which is never
/// wrong: `sed`, `lsof`, `curl`, `jq` and friends say what they did already.
const Set<String> _multiplexers = {
  // VCS / forges
  'git', 'jj', 'hg', 'svn', 'gh', 'glab',
  // containers / infra
  'docker', 'podman', 'kubectl', 'helm', 'terraform', 'ansible', 'vagrant',
  // language toolchains
  'npm', 'pnpm', 'yarn', 'bun', 'npx', 'deno', 'pip', 'uv', 'poetry', 'pipx',
  'cargo', 'go', 'rustup', 'dotnet', 'composer',
  // dart / apple
  'dart', 'flutter', 'xcrun', 'swift', 'pod', 'fastlane', 'gradle',
  // package managers / version managers
  'brew', 'apt', 'apt-get', 'dnf', 'pacman', 'nix', 'mise', 'asdf', 'pyenv',
  // system
  'systemctl', 'launchctl', 'journalctl', 'defaults', 'security', 'scutil',
  'networksetup', 'pmset', 'tailscale',
  // clouds
  'aws', 'gcloud', 'az', 'fly', 'vercel', 'wrangler', 'supabase', 'heroku',
  // task runners / agents
  'make', 'just', 'task', 'rake', 'mvn', 'tmux', 'screen', 'pi', 'codex',
  'claude', 'makit', 'openssl',
};

/// Interpreters whose trailing version is noise (`python3.12` → `python`).
const Set<String> _versionedTools = {
  'python',
  'pip',
  'php',
  'ruby',
  'perl',
  'node',
  'clang',
  'gcc',
};

/// Names shown before the list is truncated to `… +N`. A safety valve for a
/// 30-segment script, not a width control — the row already ellipsises.
const int _maxCommandNames = 8;

/// A token that can be a subcommand: a bare lowercase word. Excludes flags,
/// paths, values and anything with a dot, so `git -C /repo status` still finds
/// `status` and `sed -i '' 's/a/b/'` finds nothing.
final RegExp _subcommandWord = RegExp(r'^[a-z][a-z0-9:_+-]*$');

/// `FOO=bar` — an assignment, not a command.
final RegExp _assignment = RegExp(r'^[A-Za-z_][A-Za-z0-9_]*=');

/// A redirection: `>`, `>>`, `<`, `2>`, `&>`, `>&2`, or any of those with the
/// target attached (`>out.txt`, `2>/dev/null`).
///
/// Neither the operator nor its target is a command. Before this existed,
/// `pnpm typecheck > /tmp/tc.log 2>&1` summarised as `pnpm typecheck, 1` — the
/// `&` split off a segment holding the bare file descriptor.
final RegExp _redirection = RegExp(r'^(?:[0-9]*(?:>>?|<)|&>>?)');

/// A redirection operator with nothing attached, so its target is the *next*
/// token and has to be skipped too (`> out.txt` vs `>out.txt`).
final RegExp _bareRedirection = RegExp(r'^(?:[0-9]*(?:>>?|<)&?[0-9]*|&>>?)$');

/// A trailing version on an interpreter name: `python3`, `python3.12`, `pip3`.
final RegExp _trailingVersion = RegExp(r'^([A-Za-z_+-]+?)[0-9]+(?:\.[0-9]+)*$');

/// The distinct commands [command] runs, in first-seen order, joined with
/// `, ` — the payload of a collapsed shell row. Empty when the command is
/// empty or is nothing but prologue.
String commandNames(String command) {
  final segments = _splitForNames(_stripHeredocs(command));
  final order = <String>[];
  for (final segment in segments) {
    final name = _segmentName(segment);
    if (name == null || order.contains(name)) continue;
    order.add(name);
  }
  if (order.isEmpty) return '';
  if (order.length <= _maxCommandNames) return order.join(', ');
  final shown = order.take(_maxCommandNames);
  return '${shown.join(', ')} +${order.length - _maxCommandNames}';
}

/// Split for [commandNames]: like [_splitTopLevel] but pipes and `&` are
/// separators too (each pipeline member is its own command), and the body of
/// every `$( … )` / backtick substitution is appended as further segments —
/// that is where `lsof` hides in `kill $(lsof -t -i:9787)`.
List<String> _splitForNames(String command) {
  final segments = <String>[];
  final nested = <String>[];
  final buf = StringBuffer();
  String? quote;
  void flush() {
    final s = oneLine(buf.toString());
    if (s.isNotEmpty) segments.add(s);
    buf.clear();
  }

  for (var i = 0; i < command.length; i++) {
    final c = command[i];
    if (c == r'\' && quote != "'" && i + 1 < command.length) {
      buf.write(c);
      buf.write(command[i + 1]);
      i++;
      continue;
    }
    if (quote != null) {
      buf.write(c);
      if (c == quote) quote = null;
      continue;
    }
    if (c == "'" || c == '"') {
      quote = c;
      buf.write(c);
      continue;
    }
    // Command substitution: capture the body, drop it from this segment.
    final substitution =
        (c == r'$' && i + 1 < command.length && command[i + 1] == '(')
        ? 2
        : (c == '`' ? 1 : 0);
    if (substitution > 0) {
      final close = c == '`' ? '`' : ')';
      var depth = 1;
      var j = i + substitution;
      final body = StringBuffer();
      while (j < command.length) {
        final d = command[j];
        if (d == '(' && close == ')') {
          depth++;
        } else if (d == close) {
          depth--;
          if (depth == 0) break;
        }
        body.write(d);
        j++;
      }
      nested.add(body.toString());
      buf.write(' ');
      i = j;
      continue;
    }
    final two = i + 1 < command.length ? command.substring(i, i + 2) : '';
    if (two == '&&' || two == '||') {
      flush();
      i++;
      continue;
    }
    // `&` separates a background job, but the `&` in `2>&1`, `>&2` and `&>` is
    // part of the redirection and must stay in the token.
    final prev = buf.isEmpty ? '' : buf.toString().substring(buf.length - 1);
    final next = i + 1 < command.length ? command[i + 1] : '';
    final redirecting = c == '&' && (prev == '>' || prev == '<' || next == '>');
    if (!redirecting && (c == ';' || c == '\n' || c == '|' || c == '&')) {
      flush();
      continue;
    }
    buf.write(c);
  }
  flush();
  for (final body in nested) {
    segments.addAll(_splitForNames(body));
  }
  return segments;
}

/// Split [segment] into shell words, dropping quotes and escapes.
List<String> _words(String segment) {
  final words = <String>[];
  final buf = StringBuffer();
  String? quote;
  for (var i = 0; i < segment.length; i++) {
    final c = segment[i];
    if (c == r'\' && quote != "'" && i + 1 < segment.length) {
      buf.write(segment[i + 1]);
      i++;
      continue;
    }
    if (quote != null) {
      if (c == quote) {
        quote = null;
      } else {
        buf.write(c);
      }
      continue;
    }
    if (c == "'" || c == '"') {
      quote = c;
      continue;
    }
    if (c.trim().isEmpty) {
      if (buf.isNotEmpty) {
        words.add(buf.toString());
        buf.clear();
      }
      continue;
    }
    buf.write(c);
  }
  if (buf.isNotEmpty) words.add(buf.toString());
  return words;
}

/// `~/flutter/bin/flutter` → `flutter`; `./scripts/deploy.sh` → `deploy.sh`.
String _basename(String token) {
  final trimmed = token.replaceAll(RegExp(r'/+$'), '');
  final slash = trimmed.lastIndexOf('/');
  final name = slash < 0 ? trimmed : trimmed.substring(slash + 1);
  return name.isEmpty ? token : name;
}

/// `python3.12` → `python`, but only for known interpreters (so `s3cmd` and
/// `7z` keep their digits).
String _unversioned(String name) {
  final m = _trailingVersion.firstMatch(name);
  if (m == null) return name;
  return _versionedTools.contains(m[1]) ? m[1]! : name;
}

/// The one name [segment] contributes, or null when it contributes none
/// (prologue, a compound-statement head, or nothing but flags).
String? _segmentName(String segment) {
  final words = _words(segment);
  if (words.isEmpty) return null;
  if (_compoundHeads.contains(words.first)) return null;

  var i = 0;
  while (i < words.length) {
    final word = words[i];
    final base = _unversioned(_basename(word));
    // A redirection and its target are plumbing. `> out.txt grep foo` must find
    // `grep`, so a bare operator swallows the token that follows it.
    if (_redirection.hasMatch(word)) {
      i += _bareRedirection.hasMatch(word) ? 2 : 1;
      continue;
    }
    if (_assignment.hasMatch(word) ||
        _shellKeywords.contains(word) ||
        _wrappers.contains(base) ||
        word.startsWith('-') ||
        word.startsWith('«')) {
      i++;
      continue;
    }
    if (_prologueHeads.contains(base)) return null;
    break;
  }
  if (i >= words.length) return null;

  final name = _unversioned(_basename(words[i]));
  if (!_multiplexers.contains(name)) return name;

  // Keep the first bare-word argument as the subcommand, skipping filler.
  for (var j = i + 1; j < words.length; j++) {
    final word = words[j];
    if (!_subcommandWord.hasMatch(word)) continue;
    if (_fillerSubcommands.contains(word)) continue;
    return '$name $word';
  }
  return name;
}

/// A collapsed one-liner split into its leading verb and the rest, so the row
/// can render the verb at a heavier weight (the payload is the same colour and
/// size — see `mockups/tool-one-liner.html` §5).
typedef VerbLine = ({String verb, String rest});

/// Split [line] at [verb] when it opens the line; otherwise the whole line is
/// payload (an unregistered tool's summary is its raw name, which is not a
/// verb and must not be emphasised).
VerbLine splitVerb(String line, String verb) {
  if (verb.isNotEmpty && line == verb) return (verb: verb, rest: '');
  if (verb.isNotEmpty && line.startsWith('$verb ')) {
    return (verb: verb, rest: line.substring(verb.length + 1));
  }
  return (verb: '', rest: line);
}
