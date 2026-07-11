import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/legacy.dart';

import '../notifications/notification_observer.dart';
import '../store/connection.dart';
import 'readiness.dart';

/// SPEC-09 Slice 1 — onboarding UI state that isn't part of the connection:
/// the queried notification permission and whether the user skipped that gate.
@immutable
class OnboardingState {
  const OnboardingState({
    this.notifications = NotificationPermission.notDetermined,
    this.notificationsSkipped = false,
  });

  final NotificationPermission notifications;
  final bool notificationsSkipped;

  OnboardingState copyWith({
    NotificationPermission? notifications,
    bool? notificationsSkipped,
  }) => OnboardingState(
    notifications: notifications ?? this.notifications,
    notificationsSkipped: notificationsSkipped ?? this.notificationsSkipped,
  );
}

/// Drives the notifications gate: queries permission on start, and exposes
/// enable/skip actions for the wizard's notifications step.
class OnboardingController extends StateNotifier<OnboardingState> {
  OnboardingController(this._read) : super(const OnboardingState()) {
    refreshPermission();
  }

  /// Injected query/request seams (default to the real NotificationService).
  /// Kept as function refs so widget tests can drive the step without plugins.
  OnboardingController.withSeams({
    required Future<NotificationPermission> Function() query,
    required Future<NotificationPermission> Function() request,
    OnboardingState initial = const OnboardingState(),
  }) : _query = query,
       _request = request,
       _read = null,
       super(initial) {
    refreshPermission();
  }

  final Ref? _read;
  Future<NotificationPermission> Function()? _query;
  Future<NotificationPermission> Function()? _request;

  Future<NotificationPermission> Function() get _queryFn =>
      _query ??= () =>
          _read!.read(notificationServiceProvider).permissionStatus();
  Future<NotificationPermission> Function() get _requestFn =>
      _request ??= () =>
          _read!.read(notificationServiceProvider).requestPermission();

  Future<void> refreshPermission() async {
    final perm = await _queryFn();
    if (mounted) state = state.copyWith(notifications: perm);
  }

  /// Show the OS prompt and record the result.
  Future<void> enableNotifications() async {
    final perm = await _requestFn();
    if (mounted) state = state.copyWith(notifications: perm);
  }

  /// Dismiss the notifications gate without enabling.
  void skipNotifications() =>
      state = state.copyWith(notificationsSkipped: true);
}

final onboardingControllerProvider =
    StateNotifierProvider<OnboardingController, OnboardingState>(
      (ref) => OnboardingController(ref),
    );

/// The current onboarding step, combining pairing (connection) + notification
/// state. Widgets watch this to render the right step; the router reads it.
final onboardingStepProvider = Provider<OnboardingStep>((ref) {
  final paired = ref.watch(connectionProvider).paired;
  final ob = ref.watch(onboardingControllerProvider);
  return onboardingStep(
    paired: paired,
    notifications: ob.notifications,
    notificationsSkipped: ob.notificationsSkipped,
  );
});

/// Listenable that fires when the onboarding step changes, so GoRouter
/// re-runs its redirect on pair/enable/skip transitions (not on every
/// connection tick).
final onboardingListenableProvider = Provider<Listenable>((ref) {
  final notifier = ValueNotifier<OnboardingStep>(
    ref.read(onboardingStepProvider),
  );
  ref.listen<OnboardingStep>(
    onboardingStepProvider,
    (_, next) => notifier.value = next,
  );
  return notifier;
});
