/// Riverpod wiring for the status/Activity layer.
///
/// Deliberately imports `app_log.dart` (the global) rather than
/// `diagnostics_providers.dart`: that file reaches into the connection/store
/// providers for the log uploader, and the store posts status events (SPEC-48
/// D7), so going through it would close an import cycle.
library;

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../diagnostics/app_log.dart';
import 'status_center.dart';
import 'status_event.dart';

/// The app-wide activity record. Overridden in tests with a fresh instance (and,
/// where the mirroring matters, a test [MakitLog]).
final statusCenterProvider = Provider<StatusCenter>((ref) {
  final center = StatusCenter(log: appLog);
  ref.onDispose(center.dispose);
  return center;
});

/// Unread badge state: how many, and how loud the loudest is. One provider so a
/// badge does a single `watch` instead of hand-rolling a stream subscription.
///
/// Seeds with the current value before following the change stream — a badge
/// mounted *after* events have landed (navigating back to the home screen) must
/// not read zero until the next post.
final statusBadgeProvider = StreamProvider<StatusBadge>((ref) {
  final center = ref.watch(statusCenterProvider);
  return _badgeStates(center);
});

typedef StatusBadge = ({int unread, StatusSeverity? worst});

Stream<StatusBadge> _badgeStates(StatusCenter center) async* {
  StatusBadge read() => (unread: center.unreadCount, worst: center.worstUnread);
  yield read();
  yield* center.changes.map((_) => read());
}

/// `ref.status.failure('Could not create worktree', error: e, source: 'worktree')`
///
/// A plain object, so — unlike `ScaffoldMessenger.of(context)` — it is never null
/// and never expires. That deletes the `maybeOf`-plus-`?.` and
/// `if (context.mounted)` dances at 24 of the call sites this layer replaces
/// (SPEC-48 D3).
///
/// **But hoist it before the first `await`.** `ref` still dies with its widget
/// (Riverpod throws `Using "ref" when a widget … has been unmounted is unsafe`),
/// and the flows that report outcomes are exactly the ones whose widget can
/// vanish mid-flight — so reaching for `ref` after the await crashes precisely
/// when there is bad news to deliver:
///
/// ```dart
/// final status = ref.status;         // ← before the await
/// try {
///   await store.removeWorktree(...);
/// } catch (e) {
///   status.failure('Could not delete worktree',
///       error: e, source: StatusSources.worktree);
/// }
/// ```
///
/// Pinned by `test/status/status_lifetime_test.dart`.
extension StatusFromWidgetRef on WidgetRef {
  StatusCenter get status => read(statusCenterProvider);
}

extension StatusFromRef on Ref {
  StatusCenter get status => read(statusCenterProvider);
}

/// For the few helpers that hold a [BuildContext] but no `ref`.
StatusCenter statusOf(BuildContext context) =>
    ProviderScope.containerOf(context).read(statusCenterProvider);
