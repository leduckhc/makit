/// SPEC-09 Slice 1 — first-run onboarding readiness.
///
/// Pure, dependency-free state machine. Given the current pairing +
/// notification-permission state, it returns the first unsatisfied onboarding
/// gate. The wizard UI renders that step's "one concrete fix"; the router
/// redirect uses [isReady] to decide when to leave onboarding.
///
/// Kept free of Flutter/plugin imports so every transition is unit-tested in
/// isolation (see `test/readiness_test.dart`).
library;

/// OS notification-permission status, queried (not requested) from
/// `NotificationService.permissionStatus()`.
enum NotificationPermission {
  /// The user has allowed notifications.
  granted,

  /// The user has explicitly denied. We won't re-prompt; the OS Settings app
  /// holds the toggle. Treated as "answered" so the user isn't trapped.
  denied,

  /// Not yet asked — we can still show the OS prompt.
  notDetermined,

  /// Platform without notification permissions (or plugin unavailable).
  unsupported,
}

/// The ordered onboarding gates. The wizard shows the first unsatisfied one.
///
/// Reachability ("is a server reachable?") is *informational* and folded into
/// the [pair] step per SPEC-09 resolved decision 1 — it is not a separate gate,
/// because the router only routes into onboarding when unpaired.
enum OnboardingStep {
  /// No stored creds yet → scan a QR / paste a pair URL.
  pair,

  /// Paired, but the notification prompt hasn't been answered → offer to enable
  /// (skippable).
  notifications,

  /// All gates satisfied → land on Home.
  ready,
}

/// Compute the first unsatisfied onboarding gate.
///
/// - Not paired → [OnboardingStep.pair] (regardless of notification state).
/// - Paired but notifications [NotificationPermission.notDetermined] and not
///   [notificationsSkipped] → [OnboardingStep.notifications] (we can prompt).
/// - Otherwise → [OnboardingStep.ready]. `granted`/`denied`/`unsupported` never
///   trap the user; `denied` already answered and Settings holds the toggle.
OnboardingStep onboardingStep({
  required bool paired,
  required NotificationPermission notifications,
  required bool notificationsSkipped,
}) {
  if (!paired) return OnboardingStep.pair;
  final canPrompt = notifications == NotificationPermission.notDetermined;
  if (canPrompt && !notificationsSkipped) return OnboardingStep.notifications;
  return OnboardingStep.ready;
}

/// True when onboarding is complete — the router uses this to redirect to Home.
bool isReady({
  required bool paired,
  required NotificationPermission notifications,
  required bool notificationsSkipped,
}) =>
    onboardingStep(
      paired: paired,
      notifications: notifications,
      notificationsSkipped: notificationsSkipped,
    ) ==
    OnboardingStep.ready;
