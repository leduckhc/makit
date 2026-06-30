import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../pairing/pairing_screen.dart';
import '../store/connection.dart';
import '../ui/home/home_screen.dart';
import '../ui/session/session_screen.dart';
import '../ui/session/tool_call_detail_screen.dart';
import '../ui/settings/settings_screen.dart';

final routerProvider = Provider<GoRouter>((ref) {
  final connection = ref.watch(connectionProvider);

  return GoRouter(
    initialLocation: '/',
    redirect: (context, state) {
      final paired = connection.paired;
      final goingToPair = state.matchedLocation == '/pair';
      if (!paired && !goingToPair) return '/pair';
      if (paired && goingToPair) return '/';
      return null;
    },
    refreshListenable: ref.watch(connectionListenableProvider),
    routes: [
      GoRoute(path: '/pair', builder: (_, __) => const PairingScreen()),
      GoRoute(
        path: '/',
        builder: (_, __) => const HomeScreen(),
        routes: [
          GoRoute(path: 'settings', builder: (_, __) => const SettingsScreen()),
          GoRoute(
            path: 'session/:id',
            builder: (_, s) => SessionScreen(sessionId: s.pathParameters['id']!),
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
