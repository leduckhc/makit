import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/legacy.dart';

/// The session currently shown in the desktop chat pane, or `null` when none
/// is selected (empty state). Desktop is a two-pane master/detail layout, so —
/// unlike the mobile push-navigation flow — the "current session" is app state,
/// not a route.
final selectedSessionProvider = StateProvider<String?>((ref) => null);

/// Convenience for widgets/tests that only need to change the selection.
@visibleForTesting
void selectSession(WidgetRef ref, String? sessionId) =>
    ref.read(selectedSessionProvider.notifier).state = sessionId;
