import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:makit/pairing/onboarding_controller.dart';
import 'package:makit/pairing/onboarding_screen.dart';
import 'package:makit/pairing/readiness.dart';

/// Builds the wizard forced to the notifications step, with a controller whose
/// enable/skip seams are recorded (no plugins).
Widget _host(OnboardingController controller) {
  return ProviderScope(
    overrides: [
      onboardingStepProvider.overrideWithValue(OnboardingStep.notifications),
      onboardingControllerProvider.overrideWith((_) => controller),
    ],
    child: const MaterialApp(home: OnboardingScreen()),
  );
}

void main() {
  testWidgets('notifications step shows enable + skip affordances', (
    tester,
  ) async {
    final c = OnboardingController.withSeams(
      query: () async => NotificationPermission.notDetermined,
      request: () async => NotificationPermission.granted,
    );
    await tester.pumpWidget(_host(c));
    await tester.pump();

    expect(find.text('Enable notifications'), findsOneWidget);
    expect(find.text('Not now'), findsOneWidget);
    expect(
      find.text('You can enable this later in your device Settings.'),
      findsOneWidget,
    );
  });

  testWidgets('"Not now" skips the gate', (tester) async {
    final c = OnboardingController.withSeams(
      query: () async => NotificationPermission.notDetermined,
      request: () async => NotificationPermission.granted,
    );
    await tester.pumpWidget(_host(c));
    await tester.pump();

    await tester.tap(find.text('Not now'));
    await tester.pump();

    expect(c.state.notificationsSkipped, isTrue);
  });

  testWidgets('"Enable notifications" requests permission', (tester) async {
    var requested = false;
    final c = OnboardingController.withSeams(
      query: () async => NotificationPermission.notDetermined,
      request: () async {
        requested = true;
        return NotificationPermission.granted;
      },
    );
    await tester.pumpWidget(_host(c));
    await tester.pump();

    await tester.tap(find.text('Enable notifications'));
    await tester.pump();

    expect(requested, isTrue);
    expect(c.state.notifications, NotificationPermission.granted);
  });
}
