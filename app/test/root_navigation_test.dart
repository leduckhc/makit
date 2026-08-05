// The connect/servers page is the app's root, with the repo list pushed on top.
// That is what makes it reachable by backing out of the repos — the point of the
// change — so the stack shape is pinned here rather than left to the route table
// looking plausible.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:makit/app/router.dart';
import 'package:makit/pairing/onboarding_controller.dart';
import 'package:makit/pairing/pairing_screen.dart';
import 'package:makit/pairing/readiness.dart';
import 'package:makit/store/connection.dart';
import 'package:makit/store/secure_store.dart';
import 'package:makit/store/store.dart';
import 'package:makit/ui/home/home_screen.dart';

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

/// Boot the app and take the demo door, which is the only way to reach a ready
/// state without a server.
Future<ProviderContainer> _openDemo(WidgetTester tester) async {
  final container = _container();
  container.read(storeControllerProvider);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp.router(routerConfig: container.read(routerProvider)),
    ),
  );
  await tester.pump();
  final door = find.text('Open with fake data');
  await tester.ensureVisible(door);
  await tester.tap(door);
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 500));
  return container;
}

void main() {
  testWidgets('launch lands on the repo list, not the server picker', (
    tester,
  ) async {
    final container = await _openDemo(tester);

    // Straight to work: the picker must not cost a tap on every launch.
    expect(container.read(routerProvider).state.matchedLocation, '/repos');
    expect(find.byType(HomeScreen), findsOneWidget);
  });

  testWidgets('backing out of the repo list reaches the servers page', (
    tester,
  ) async {
    final container = await _openDemo(tester);
    expect(find.byType(HomeScreen), findsOneWidget);

    // A back gesture from the repo list — the thing that previously had nowhere
    // to go, because the connect screen was a leaf rather than the root.
    final popped = await container
        .read(routerProvider)
        .routerDelegate
        .popRoute();
    expect(popped, isTrue, reason: 'the repo list must be poppable');
    await tester.pumpAndSettle();

    expect(container.read(routerProvider).state.matchedLocation, '/');
    expect(find.byType(PairingScreen), findsOneWidget);
    expect(find.byType(HomeScreen), findsNothing);
  });

  testWidgets('the redirect does not bounce back off the servers page', (
    tester,
  ) async {
    final container = await _openDemo(tester);
    await container.read(routerProvider).routerDelegate.popRoute();
    await tester.pumpAndSettle();

    // Onboarding is complete, so a forwarding redirect would fire here and shove
    // the user straight back to /repos, making the back arrow useless.
    expect(container.read(onboardingStepProvider), OnboardingStep.ready);
    await tester.pump(const Duration(milliseconds: 500));
    expect(container.read(routerProvider).state.matchedLocation, '/');
  });
}
