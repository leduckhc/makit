/// One thing the app told you: what happened, how loud it was, and — kept apart
/// from the human sentence — the machine detail worth pasting into an issue.
///
/// Pure Dart (no Flutter import) so the model and its clipboard format stay
/// unit-testable next to [StatusCenter], mirroring `diagnostics/log.dart`.
library;

/// How much an event deserves your attention, ascending.
///
/// The declaration order is load-bearing: the Activity filter is a *threshold*
/// ("warnings and worse"), the same shape as the Diagnostics level filter, and
/// [atLeast] compares by [Enum.index].
///
/// The ranking is about value *after the fact*, which is why `info` sits below
/// `success`: a progress notice is worthless once superseded, neutral chatter
/// ("URL copied") is next, a completed action is worth remembering, and warnings
/// and failures escalate from there.
enum StatusSeverity {
  progress,
  info,
  success,
  warning,
  failure;

  /// Whether this severity is at least as loud as [floor].
  bool atLeast(StatusSeverity floor) => index >= floor.index;

  /// Fixed-width token for the clipboard/log column (`FAILURE `, `INFO    `).
  String get column => name.toUpperCase().padRight(8);
}

/// The [StatusEvent.source] vocabulary.
///
/// Constants rather than free strings so a typo fails to compile and the tag set
/// stays a closed list one file can show you — the Activity filter groups by it,
/// and `worktree` vs `worktrees` vs `wt` would fragment the feed silently. Not an
/// enum: it is a display tag, not a decision the code branches on.
abstract final class StatusSources {
  static const String worktree = 'worktree';
  static const String repo = 'repo';
  static const String session = 'session';
  static const String agent = 'agent';
  static const String pairing = 'pairing';
  static const String devices = 'devices';
  static const String ports = 'ports';
  static const String pr = 'pr';
  static const String attachment = 'attachment';
  static const String settings = 'settings';
  static const String ide = 'ide';
  static const String metrics = 'metrics';
  static const String diagnostics = 'diagnostics';
}

class StatusEvent {
  const StatusEvent({
    required this.id,
    required this.ts,
    required this.severity,
    required this.title,
    required this.source,
    this.detail,
    this.sessionId,
    this.count = 1,
    this.read = false,
  });

  /// Unique and monotonic within a [StatusCenter]; used as a list key and to
  /// tell an updated (coalesced) event from a new one.
  final String id;

  /// When it happened — refreshed when a repeat coalesces, so relative time
  /// keeps describing the most recent occurrence.
  final DateTime ts;

  final StatusSeverity severity;

  /// The short human line. This is what a toast shows, and it never carries an
  /// exception: `Could not create worktree`, not `Could not create worktree: $e`.
  final String title;

  /// The machine payload, verbatim and multi-line: the exception, stderr, a URL,
  /// a command. The reason this feature exists — a `SnackBar` had nowhere to put
  /// it and no way to copy it.
  final String? detail;

  /// Coarse origin used for the Activity tag and grouping: `worktree`,
  /// `pairing`, `ports`, `agent`, `session`, `diagnostics`.
  final String source;

  /// Set when the event belongs to a session, which makes the toast and the
  /// Activity row a deep link.
  final String? sessionId;

  /// How many identical occurrences this row stands for (see
  /// `StatusCenter.coalesceWindow`).
  final int count;

  final bool read;

  bool get hasDetail => detail != null && detail!.trim().isNotEmpty;

  /// Title with the repeat count appended, which is what every surface renders.
  String get displayTitle => count > 1 ? '$title ×$count' : title;

  /// Whether [other] is "the same thing happening again": same severity, same
  /// wording, same origin, same session.
  ///
  /// [detail] is deliberately excluded — three failed deletes each carry a
  /// different path in `$e`, and the user wants one row saying it happened three
  /// times, with the newest detail kept.
  bool coalescesWith(StatusEvent other) =>
      severity == other.severity &&
      title == other.title &&
      source == other.source &&
      sessionId == other.sessionId;

  /// One clipboard/report block, a deliberate sibling of `LogRecord.toLine()`:
  ///
  /// ```
  /// 12:34:56.789 FAILURE  [worktree] Could not create worktree
  ///     FileSystemException: Creation failed, errno = 17
  /// ```
  String toClipboardText() {
    final t = ts.toIso8601String().split('T').last;
    final head = '$t ${severity.column} [$source] $displayTitle';
    if (!hasDetail) return head;
    final body = detail!
        .trimRight()
        .split('\n')
        .map((l) => '    $l')
        .join('\n');
    return '$head\n$body';
  }

  StatusEvent copyWith({
    DateTime? ts,
    String? detail,
    int? count,
    bool? read,
  }) => StatusEvent(
    id: id,
    ts: ts ?? this.ts,
    severity: severity,
    title: title,
    source: source,
    detail: detail ?? this.detail,
    sessionId: sessionId,
    count: count ?? this.count,
    read: read ?? this.read,
  );
}
