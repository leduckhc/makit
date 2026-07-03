import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'app/router.dart';
import 'app/theme.dart';
import 'app/test_bootstrap.dart';
import 'store/store.dart';
import 'ui/widgets/pino_mark.dart';
import 'ui/widgets/srv_request_handler.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await seedTestPairingIfRequested();
  // The store listens to a broadcast stream that drops events without
  // listeners. Eagerly create the controller so it's subscribed before the
  // WS connects and starts pushing projects/sessions snapshots.
  final container = ProviderContainer();
  container.read(storeControllerProvider);
  runApp(UncontrolledProviderScope(container: container, child: const PinoApp()));
}

class PinoApp extends ConsumerStatefulWidget {
  const PinoApp({super.key});

  @override
  ConsumerState<PinoApp> createState() => _PinoAppState();
}

class _PinoAppState extends ConsumerState<PinoApp> {
  bool _showSplash = true;

  @override
  Widget build(BuildContext context) {
    if (_showSplash) {
      return MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: pinoDarkTheme,
        home: PinoSplash(
          onCompleted: () {
            if (mounted) setState(() => _showSplash = false);
          },
        ),
      );
    }
    final router = ref.watch(routerProvider);
    return MaterialApp.router(
      title: 'pino',
      theme: pinoLightTheme,
      darkTheme: pinoDarkTheme,
      themeMode: ThemeMode.system,
      routerConfig: router,
      builder: (context, child) =>
          SrvRequestHandler(child: child ?? const SizedBox()),
      debugShowCheckedModeBanner: false,
    );
  }
}
