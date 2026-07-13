import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:makit/notifications/notification_observer.dart';
import 'package:makit/notifications/notification_service.dart';
import 'package:makit/pairing/onboarding_controller.dart';
import 'package:makit/pairing/readiness.dart';
import 'package:makit/store/connection.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// A [NotificationService] whose permission query is fixed, so the onboarding
/// controller resolves without touching the plugin. Mirrors a fresh install
/// where the OS prompt hasn't been answered yet.
class _FixedPermissionService extends NotificationService {
  _FixedPermissionService(this._perm);
  final NotificationPermission _perm;

  @override
  Future<NotificationPermission> permissionStatus() async => _perm;
}

/// Minimal in-memory secure storage: the connection controller boots with no
/// paired server, so the app starts unpaired (on the pairing screen).
class _EmptyStorage extends FlutterSecureStorage {
  const _EmptyStorage() : super();

  @override
  Future<String?> read({
    required String key,
    AppleOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    AppleOptions? mOptions,
    WindowsOptions? wOptions,
  }) async => null;

  @override
  Future<void> write({
    required String key,
    required String? value,
    AppleOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    AppleOptions? mOptions,
    WindowsOptions? wOptions,
  }) async {}

  @override
  Future<void> delete({
    required String key,
    AppleOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    AppleOptions? mOptions,
    WindowsOptions? wOptions,
  }) async {}
}

ProviderContainer _container() {
  final container = ProviderContainer(
    overrides: [
      // Fresh install: OS prompt not yet answered → notDetermined.
      notificationServiceProvider.overrideWithValue(
        _FixedPermissionService(NotificationPermission.notDetermined),
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
  group('Open with fake data → onboarding readiness', () {
    test('unpaired app starts on the pair step', () async {
      final container = _container();
      // Let the onboarding controller resolve its (fixed) permission query.
      await Future<void>.delayed(Duration.zero);
      expect(container.read(onboardingStepProvider), OnboardingStep.pair);
    });

    test('attaching fake data WITHOUT skipping notifications is stuck at the '
        'notifications gate (never reaches Home) — the reported bug', () async {
      final container = _container();
      await Future<void>.delayed(Duration.zero);

      container.read(connectionControllerProvider.notifier).useFakeServer();

      // paired is now true, but the notifications gate is unsatisfied, so the
      // router redirect bounces off Home back to onboarding.
      expect(
        container.read(onboardingStepProvider),
        OnboardingStep.notifications,
      );
    });

    test(
      'the fake-data action (attach fake + skip notifications) reaches ready '
      'so the router lands on Home',
      () async {
        final container = _container();
        await Future<void>.delayed(Duration.zero);

        // Exactly what the "Open with fake data" button does.
        container.read(connectionControllerProvider.notifier).useFakeServer();
        container
            .read(onboardingControllerProvider.notifier)
            .skipNotifications();

        expect(container.read(onboardingStepProvider), OnboardingStep.ready);
      },
    );
  });
}
