import 'package:flutter_test/flutter_test.dart';
import 'package:makit/pairing/readiness.dart';

void main() {
  group('onboardingStep', () {
    // Gate 1: pairing. Until we have creds, always the pair step regardless of
    // notification state. (Reachability is informational within the pair step
    // per SPEC-onboarding-and-tray-polish resolved decision 1, not a separate gate.)
    group('not paired → pair', () {
      for (final perm in NotificationPermission.values) {
        for (final skipped in [true, false]) {
          test('perm=$perm skipped=$skipped', () {
            expect(
              onboardingStep(
                paired: false,
                notifications: perm,
                notificationsSkipped: skipped,
              ),
              OnboardingStep.pair,
            );
          });
        }
      }
    });

    // Gate 2: notifications. Only `notDetermined` (we can still prompt) blocks,
    // and only when not skipped — "never get stuck".
    test('paired + notDetermined + not skipped → notifications', () {
      expect(
        onboardingStep(
          paired: true,
          notifications: NotificationPermission.notDetermined,
          notificationsSkipped: false,
        ),
        OnboardingStep.notifications,
      );
    });

    test('paired + notDetermined + skipped → ready', () {
      expect(
        onboardingStep(
          paired: true,
          notifications: NotificationPermission.notDetermined,
          notificationsSkipped: true,
        ),
        OnboardingStep.ready,
      );
    });

    // A user who already answered (granted/denied) or a platform without
    // notifications must not be trapped — they go straight to ready.
    test('paired + granted → ready', () {
      expect(
        onboardingStep(
          paired: true,
          notifications: NotificationPermission.granted,
          notificationsSkipped: false,
        ),
        OnboardingStep.ready,
      );
    });

    test(
      'paired + denied → ready (already asked; Settings has the toggle)',
      () {
        expect(
          onboardingStep(
            paired: true,
            notifications: NotificationPermission.denied,
            notificationsSkipped: false,
          ),
          OnboardingStep.ready,
        );
      },
    );

    test('paired + unsupported → ready', () {
      expect(
        onboardingStep(
          paired: true,
          notifications: NotificationPermission.unsupported,
          notificationsSkipped: false,
        ),
        OnboardingStep.ready,
      );
    });

    // Convenience: `isReady` mirrors the step for the router redirect.
    test('isReady true only at the ready step', () {
      expect(
        isReady(
          paired: true,
          notifications: NotificationPermission.granted,
          notificationsSkipped: false,
        ),
        isTrue,
      );
      expect(
        isReady(
          paired: false,
          notifications: NotificationPermission.granted,
          notificationsSkipped: false,
        ),
        isFalse,
      );
    });
  });
}
