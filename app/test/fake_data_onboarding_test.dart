import 'package:makit/store/secure_store.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:makit/app/router.dart';
import 'package:makit/pairing/onboarding_controller.dart';
import 'package:makit/store/connection.dart';
import 'package:makit/store/store.dart';
import 'package:makit/ui/home/home_screen.dart';
import 'package:makit/pairing/readiness.dart';

/// Minimal in-memory secure storage: the connection controller boots with no
/// paired server, so the app starts unpaired (on the pairing screen).
class _EmptyStorage implements SecureStore {
  const _EmptyStorage();

  @override
  Future<String?> read({required String key}) async => null;

  @override
  Future<void> write({required String key, required String? value}) async {}

  @override
  Future<void> delete({required String key}) async {}
}

ProviderContainer _container() {
  final container = ProviderContainer(
    overrides: [
      onboardingControllerProvider.overrideWith(
        (_) => OnboardingController.withSeams(
          query: () async => NotificationPermission.notDetermined,
          request: () async => NotificationPermission.granted,
        ),
      ),
      connectionControllerProvider.overrideWith(
        (ref) => ConnectionController(const _EmptyStorage()),
      ),
    ],
  );
  addTearDown(container.dispose);
  return container;
}

void main() {
  testWidgets('"Open with fake data" navigates to Home and stays there', (
    tester,
  ) async {
    final container = _container();
    container.read(storeControllerProvider);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp.router(routerConfig: container.read(routerProvider)),
      ),
    );
    await tester.pump();

    final button = find.text('Open with fake data');
    expect(button, findsOneWidget);
    await tester.ensureVisible(button);
    await tester.tap(button);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));

    expect(container.read(onboardingStepProvider), OnboardingStep.ready);
    expect(container.read(routerProvider).state.matchedLocation, '/');
    expect(find.byType(HomeScreen), findsOneWidget);
    expect(button, findsNothing);

    // A later frame must not bounce Home back to onboarding.
    await tester.pump(const Duration(seconds: 1));
    expect(find.byType(HomeScreen), findsOneWidget);
  });
}
