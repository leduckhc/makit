/// Global error capture — routes Flutter's framework errors and uncaught async
/// errors into [MakitLog] so they survive on a device with no reachable
/// console. This is the piece that turns an invisible iOS crash (e.g. an
/// `_dependents.isEmpty` framework assertion, or an `Unable to load asset`
/// exception) into a line you can read, share, and ship to the Mac.
library;

import 'package:flutter/foundation.dart';

import 'log.dart';

/// Flatten a [FlutterErrorDetails] into a single log message: the exception,
/// the framework context it happened in (e.g. "during layout"), and the stack.
String describeFlutterError(FlutterErrorDetails details) {
  final buf = StringBuffer(details.exceptionAsString());
  final context = details.context?.toDescription();
  if (context != null && context.isNotEmpty) {
    buf.write(' (thrown ${context.trim()})');
  }
  final lib = details.library;
  if (lib != null && lib.isNotEmpty) buf.write(' [$lib]');
  final stack = details.stack;
  if (stack != null) buf.write('\n$stack');
  return buf.toString();
}

/// Install [log] as the sink for framework and uncaught async errors.
///
/// Framework errors still go through [FlutterError.presentError] (the red
/// error widget / console dump in debug is unchanged) — we only *also* record
/// them. Uncaught async/platform errors are logged and reported as handled so
/// a single stray future can't tear the app down before the log is written.
///
/// Returns a disposer that restores the previous handlers (for tests).
void Function() installErrorCapture(MakitLog log) {
  final priorFlutterOnError = FlutterError.onError;
  final priorPlatformOnError = PlatformDispatcher.instance.onError;

  FlutterError.onError = (FlutterErrorDetails details) {
    log.error('flutter', describeFlutterError(details));
    FlutterError.presentError(details);
  };

  PlatformDispatcher.instance.onError = (Object error, StackTrace stack) {
    log.error('zone', '$error\n$stack');
    return true;
  };

  return () {
    FlutterError.onError = priorFlutterOnError;
    PlatformDispatcher.instance.onError = priorPlatformOnError;
  };
}
