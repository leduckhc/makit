import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter/widgets.dart';
import 'package:go_router/go_router.dart';

import '../pairing/onboarding_controller.dart';
import '../pairing/onboarding_screen.dart';
import '../pairing/readiness.dart';
import '../ui/home/home_screen.dart';
import '../ui/session/session_screen.dart';
import '../ui/session/tool_call_detail_screen.dart';
import '../ui/settings/settings_screen.dart';

/// Exposed so widgets sitting in `MaterialApp.builder` (above the Navigator)
/// can still push dialogs via the router's Navigator.
final makitNavigatorKey = GlobalKey<NavigatorState>();

final routerProvider = Provider<GoRouter>((ref) {
  // Build the GoRouter ONCE. Do NOT `ref.watch(connectionProvider)` here — that
  // recreates the entire router on every connection-state tick (connecting →
  // connected, errors, …), which synchronously remounts the active screen and
  // can collide with a first-time provider mount ("setState() called during
  // build"). Instead the redirect reads the current state on demand, and
  // `refreshListenable` re-runs redirects when `paired` actually changes.
  return GoRouter(
    navigatorKey: makitNavigatorKey,
    initialLocation: '/',
    redirect: (context, state) {
      // Onboarding is complete only at the `ready` step (paired + notification
      // gate resolved). Until then, keep the user on `/pair` (the wizard).
      final ready = ref.read(onboardingStepProvider) == OnboardingStep.ready;
      final goingToPair = state.matchedLocation == '/pair';
      if (!ready && !goingToPair) return '/pair';
      if (ready && goingToPair) return '/';
      return null;
    },
    refreshListenable: ref.watch(onboardingListenableProvider),
    routes: [
      GoRoute(path: '/pair', builder: (_, _) => const OnboardingScreen()),
      GoRoute(
        path: '/',
        builder: (_, _) => const HomeScreen(),
        routes: [
          GoRoute(path: 'settings', builder: (_, _) => const SettingsScreen()),
          GoRoute(
            path: 'session/:id',
            builder: (_, s) =>
                SessionScreen(sessionId: s.pathParameters['id']!),
            routes: [
              GoRoute(
                path: 'tool/:callId',
                builder: (_, s) => ToolCallDetailScreen(
                  sessionId: s.pathParameters['id']!,
                  callId: s.pathParameters['callId']!,
                ),
              ),
            ],
          ),
        ],
      ),
    ],
  );
});
