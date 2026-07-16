import 'package:makit/store/secure_store.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:makit/app/router.dart';
import 'package:makit/pairing/onboarding_controller.dart';
import 'package:makit/pairing/pairing_screen.dart';
import 'package:makit/pairing/readiness.dart';
import 'package:makit/store/connection.dart';
import 'package:makit/store/store.dart';
import 'package:makit/ui/home/home_screen.dart';

/// Minimal in-memory secure storage: starts unpaired.
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
  testWidgets('Home shows Exit demo while in fake data mode', (tester) async {
    final container = _container();
    container.read(storeControllerProvider);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp.router(routerConfig: container.read(routerProvider)),
      ),
    );
    await tester.pump();

    await tester.ensureVisible(find.text('Open with fake data'));
    await tester.tap(find.text('Open with fake data'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));

    expect(find.byType(HomeScreen), findsOneWidget);
    expect(find.byTooltip('Exit demo'), findsOneWidget);
  });

  testWidgets('Exit demo returns to pairing and clears fake mode', (
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

    await tester.ensureVisible(find.text('Open with fake data'));
    await tester.tap(find.text('Open with fake data'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));

    expect(container.read(connectionProvider).useFake, isTrue);
    expect(find.byType(HomeScreen), findsOneWidget);

    await tester.tap(find.byTooltip('Exit demo'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));

    expect(container.read(connectionProvider).useFake, isFalse);
    expect(container.read(connectionProvider).paired, isFalse);
    expect(container.read(onboardingStepProvider), OnboardingStep.pair);
    expect(container.read(routerProvider).state.matchedLocation, '/pair');
    expect(find.byType(PairingScreen), findsOneWidget);
    expect(find.byType(HomeScreen), findsNothing);
    expect(find.text('Open with fake data'), findsOneWidget);
  });

  test('unpair after fake data leaves the device unpaired', () async {
    final controller = ConnectionController(const _EmptyStorage());
    addTearDown(controller.dispose);

    controller.useFakeServer();
    expect(controller.state.useFake, isTrue);
    expect(controller.state.paired, isTrue);

    await controller.unpair();

    expect(controller.state.useFake, isFalse);
    expect(controller.state.paired, isFalse);
    expect(controller.state.server, isNull);
  });
}
