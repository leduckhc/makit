/// Flush the on-device log when the app leaves the foreground.
///
/// [RollingFileLogSink] buffers routine `debug`/`info` lines to keep logging off
/// the hot path, which leaves a small window where a **force-quit** (as opposed
/// to a crash — errors flush synchronously) could drop the last second of
/// breadcrumbs. The OS hands us `paused`/`detached` before it kills the process,
/// so flushing there closes that window at zero steady-state cost.
library;

import 'package:flutter/widgets.dart';

/// Call [flush] whenever the app is backgrounded (`paused`) or being torn down
/// (`detached`). Returns a disposer that stops listening.
///
/// Takes a plain callback rather than the sink itself so the lifecycle wiring
/// stays independent of the file implementation (and trivially testable).
void Function() installLifecycleFlush(void Function() flush) {
  final listener = AppLifecycleListener(onPause: flush, onDetach: flush);
  return listener.dispose;
}
