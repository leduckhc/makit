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
