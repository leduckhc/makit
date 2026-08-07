// SPEC-42 P2a T1 — the global Ports screen is a real route beside Archived.
// `kRoutePorts` builds a `PortsScreen`; `?repo=<id>` is readable by the screen.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:makit/app/router.dart';
import 'package:makit/app/routes.dart';
import 'package:makit/pairing/onboarding_controller.dart';
import 'package:makit/pairing/readiness.dart';
import 'package:makit/store/connection.dart';
import 'package:makit/store/ports.dart';
import 'package:makit/store/secure_store.dart';
import 'package:makit/ui/ports/ports_screen.dart';

class _EmptyStorage implements SecureStore {
  const _EmptyStorage();
  @override
  Future<String?> read({required String key}) async => null;
  @override
  Future<void> write({required String key, required String? value}) async {}
  @override
  Future<void> delete({required String key}) async {}
}

ProviderContainer _container() => ProviderContainer(
  overrides: [
    // Ready so the router lets a child route render (redirect passes).
    onboardingStepProvider.overrideWithValue(OnboardingStep.ready),
    connectionControllerProvider.overrideWith(
      (ref) => ConnectionController(const _EmptyStorage()),
    ),
    // Fire-and-forget spy: the screen arms the watch on mount; keep it off the
    // socket so the route test doesn't touch a live connection.
    portsWatchProvider.overrideWithValue(PortsWatch((_) {})),
    portsProvider.overrideWithValue(
      const PortsSnapshot(ports: [], scannedAt: 0, scanOk: true),
    ),
  ],
);

Future<GoRouterHarness> _pump(WidgetTester tester) async {
  final container = _container();
  addTearDown(container.dispose);
  final router = container.read(routerProvider);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp.router(routerConfig: router),
    ),
  );
  await tester.pumpAndSettle();
  return GoRouterHarness(router);
}

class GoRouterHarness {
  GoRouterHarness(this.router);
  final GoRouter router;
}

void main() {
  testWidgets('kRoutePorts builds a PortsScreen titled "Ports"', (
    tester,
  ) async {
    final harness = await _pump(tester);
    harness.router.go(kRoutePorts);
    await tester.pumpAndSettle();

    expect(find.byType(PortsScreen), findsOneWidget);
    expect(find.widgetWithText(AppBar, 'Ports'), findsOneWidget);
  });

  testWidgets('?repo=<id> is readable by the screen', (tester) async {
    final harness = await _pump(tester);
    harness.router.go('$kRoutePorts?repo=p1');
    await tester.pumpAndSettle();

    final screen = tester.widget<PortsScreen>(find.byType(PortsScreen));
    expect(screen.repoId, 'p1');
  });
}
