/// Small pure formatting helpers shared by the desktop control screens.
library;

/// Formats an uptime [milliseconds] duration as a compact "2h 13m" string.
///
/// Falls back to minutes ("13m") under an hour, and seconds ("42s") under a
/// minute, so short-lived daemons still read sensibly.
String formatUptime(int milliseconds) {
  final duration = Duration(milliseconds: milliseconds);
  final hours = duration.inHours;
  final minutes = duration.inMinutes % 60;
  if (hours > 0) return '${hours}h ${minutes}m';
  if (duration.inMinutes > 0) return '${duration.inMinutes}m';
  return '${duration.inSeconds}s';
}

/// Formats a countdown [remaining] as "4m 32s" (or "32s" under a minute).
///
/// Clamps to "0s" once the deadline has passed.
String formatCountdown(Duration remaining) {
  if (remaining.isNegative || remaining == Duration.zero) return '0s';
  final minutes = remaining.inMinutes;
  final seconds = remaining.inSeconds % 60;
  if (minutes > 0) return '${minutes}m ${seconds}s';
  return '${seconds}s';
}

/// Formats an absolute [epochMs] timestamp as a coarse relative string such as
/// "just now", "5 minutes ago", or "3 days ago", relative to [now]
/// (defaults to [DateTime.now]).
String formatRelative(int epochMs, {DateTime? now}) {
  final reference = now ?? DateTime.now();
  final then = DateTime.fromMillisecondsSinceEpoch(epochMs);
  final delta = reference.difference(then);

  if (delta.isNegative) return 'just now';
  if (delta.inSeconds < 45) return 'just now';
  if (delta.inMinutes < 1) return 'a minute ago';
  if (delta.inMinutes < 60) return _plural(delta.inMinutes, 'minute');
  if (delta.inHours < 24) return _plural(delta.inHours, 'hour');
  if (delta.inDays < 30) return _plural(delta.inDays, 'day');
  if (delta.inDays < 365) return _plural(delta.inDays ~/ 30, 'month');
  return _plural(delta.inDays ~/ 365, 'year');
}

String _plural(int value, String unit) =>
    '$value $unit${value == 1 ? '' : 's'} ago';
