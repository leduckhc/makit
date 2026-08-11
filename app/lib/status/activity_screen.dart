/// The phone's Activity surface: [ActivityView] as a pushed screen.
///
/// Mirrors `DiagnosticsScreen`'s chrome (back arrow, plain AppBar) because it is
/// the same kind of place — a log you came here to read — one shelf up: this one
/// is curated for the person using the app, not for whoever debugs it.
library;

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:phosphoricons_flutter/phosphoricons_flutter.dart';

import '../app/routes.dart';
import 'activity_view.dart';

class ActivityScreen extends StatelessWidget {
  const ActivityScreen({super.key});

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      leading: IconButton(
        tooltip: 'Back',
        icon: const Icon(PhosphorIconsLight.arrowLeft),
        onPressed: () => Navigator.of(context).maybePop(),
      ),
      title: const Text('Activity'),
    ),
    body: ActivityView(onOpenSession: (id) => context.go(routeForSession(id))),
  );
}
