/// Shared formatting helpers for the Profiles section.
library;

/// Formats a byte count the way the mockup does: `4.4 MB`, `412 KB`, `938 B`.
///
/// `null` (unmeasured) renders as an em dash rather than `0 B`, so the UI never
/// claims a profile is empty while its size is still being measured.
String formatProfileBytes(int? bytes) {
  if (bytes == null) return '—';
  if (bytes < 1024) return '$bytes B';
  const units = ['KB', 'MB', 'GB', 'TB'];
  var value = bytes / 1024;
  var unit = 0;
  while (value >= 1024 && unit < units.length - 1) {
    value /= 1024;
    unit++;
  }
  final rounded = value >= 100
      ? value.toStringAsFixed(0)
      : value.toStringAsFixed(1);
  return '$rounded ${units[unit]}';
}
