import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'app/router.dart';
import 'app/theme.dart';
import 'ui/widgets/srv_request_handler.dart';

void main() {
  runApp(const ProviderScope(child: PinoApp()));
}

class PinoApp extends ConsumerWidget {
  const PinoApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final router = ref.watch(routerProvider);
    return MaterialApp.router(
      title: 'pino',
      theme: pinoLightTheme,
      darkTheme: pinoDarkTheme,
      themeMode: ThemeMode.system,
      routerConfig: router,
      builder: (context, child) => SrvRequestHandler(child: child ?? const SizedBox()),
      debugShowCheckedModeBanner: false,
    );
  }
}
