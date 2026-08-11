import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter/widgets.dart';
import 'package:go_router/go_router.dart';

import '../diagnostics/diagnostics_screen.dart';
import '../status/activity_screen.dart';
import '../pairing/onboarding_controller.dart';
import '../pairing/onboarding_screen.dart';
import '../pairing/readiness.dart';
import '../ui/docs/docs_screen.dart';
import '../ui/home/archived_screen.dart';
import '../ui/home/home_screen.dart';
import '../ui/ports/ports_screen.dart';
import '../ui/session/session_screen.dart';
import '../ui/settings/settings_screen.dart';
import 'routes.dart';

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
    // Launch goes straight to the working surface. Because `repos` is a child of
    // `/`, go_router still builds the connect page beneath it, so the back arrow
    // reaches the server picker without costing a tap on every launch.
    initialLocation: kRouteRepos,
    redirect: (context, state) {
      // Until onboarding completes, the root is the only place to be: it shows
      // the connect screen (or the notifications gate) and nothing else is
      // reachable without credentials.
      final ready = ref.read(onboardingStepProvider) == OnboardingStep.ready;
      final atRoot = state.matchedLocation == kRouteRoot;
      if (!ready && !atRoot) return kRouteRoot;
      // Ready: deliberately do NOT forward `/` → `/repos`. Forwarding would make
      // the back arrow bounce straight forward again, which is the whole point
      // of putting the connect page underneath.
      return null;
    },
    refreshListenable: ref.watch(onboardingListenableProvider),
    routes: [
      GoRoute(
        path: kRouteRoot,
        builder: (_, _) => const OnboardingScreen(),
        routes: [
          GoRoute(
            path: 'repos',
            builder: (_, _) => const HomeScreen(),
            routes: [
              GoRoute(
                path: 'settings',
                builder: (_, _) => const SettingsScreen(),
              ),
              GoRoute(
                path: 'archived',
                builder: (_, _) => const ArchivedScreen(),
              ),
              GoRoute(
                path: 'ports',
                builder: (_, s) =>
                    PortsScreen(repoId: s.uri.queryParameters['repo']),
              ),
              GoRoute(path: 'docs', builder: (_, _) => const DocsScreen()),
              GoRoute(
                path: 'diagnostics',
                builder: (_, _) => const DiagnosticsScreen(),
              ),
              GoRoute(
                path: 'activity',
                builder: (_, _) => const ActivityScreen(),
              ),
              GoRoute(
                path: 'session/:id',
                builder: (_, s) =>
                    SessionScreen(sessionId: s.pathParameters['id']!),
              ),
            ],
          ),
        ],
      ),
    ],
  );
});
