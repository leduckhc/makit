/// Which status events are on screen right now, and for how long.
///
/// Pure Dart so the crowding rules (cap, promotion, in-place updates) are tested
/// without pumping a widget; `status_toast.dart` owns the timers and the pixels.
library;

import 'status_event.dart';

/// How long a toast lingers before it fades. Nothing is sticky — the record in
/// the [StatusCenter] is the durable copy, so an unclosable toast would be pure
/// obstruction (SPEC-status-and-activity D5).
Duration toastDwell(StatusSeverity severity) => switch (severity) {
  StatusSeverity.info => const Duration(seconds: 3),
  StatusSeverity.success => const Duration(seconds: 3),
  StatusSeverity.progress => const Duration(seconds: 4),
  StatusSeverity.warning => const Duration(seconds: 6),
  StatusSeverity.failure => const Duration(seconds: 8),
};

class ToastQueue {
  ToastQueue({this.maxVisible = 3});

  /// Beyond this, toasts wait behind a `+N` chip rather than papering the screen.
  final int maxVisible;

  /// Live toasts, oldest first — [visible] reverses so the newest reads on top.
  final List<StatusEvent> _live = <StatusEvent>[];

  /// On screen, newest first.
  List<StatusEvent> get visible =>
      List<StatusEvent>.unmodifiable(_live.reversed.take(maxVisible));

  /// How many live toasts are hidden behind the cap.
  int get overflow => (_live.length - maxVisible).clamp(0, _live.length);

  /// Show [event]. Returns whether it is new: a coalesced repeat whose toast is
  /// still live updates **in place** (keeping its slot, so a bumping count does
  /// not shuffle the stack) and returns false.
  bool push(StatusEvent event) {
    final at = _live.indexWhere((e) => e.id == event.id);
    if (at >= 0) {
      _live[at] = event;
      return false;
    }
    _live.add(event);
    return true;
  }

  void dismiss(String id) => _live.removeWhere((e) => e.id == id);

  void clear() => _live.clear();
}
