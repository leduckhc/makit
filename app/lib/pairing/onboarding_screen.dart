import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:phosphoricons_flutter/phosphoricons_flutter.dart';

import 'onboarding_controller.dart';
import 'pairing_screen.dart';
import 'readiness.dart';

/// The app's root screen (`/`), beneath the repo list.
///
/// Mostly this *is* the connect/servers surface — [PairingScreen] — which the
/// user can reach at any time by backing out of the repos. The one exception is
/// the notifications gate (SPEC-onboarding-and-tray-polish Slice 1), a skippable detour shown while that
/// gate is the first unsatisfied onboarding step.
///
/// Unlike before, [OnboardingStep.ready] renders too: the root is a real
/// destination now, not a wizard the router forwards away from.
class OnboardingScreen extends ConsumerWidget {
  const OnboardingScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final step = ref.watch(onboardingStepProvider);
    return switch (step) {
      OnboardingStep.notifications => const _NotificationsStep(),
      // Both `pair` and `ready` land on the server surface: it already adapts,
      // showing the hero when nothing is paired and the picker once servers
      // exist.
      OnboardingStep.pair || OnboardingStep.ready => const PairingScreen(),
    };
  }
}

class _NotificationsStep extends ConsumerWidget {
  const _NotificationsStep();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final controller = ref.read(onboardingControllerProvider.notifier);
    return Scaffold(
      appBar: AppBar(title: const Text('Stay in the loop')),
      body: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Icon(PhosphorIconsLight.bell, size: 64),
            const SizedBox(height: 24),
            Text(
              'Get notified when an agent needs you',
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.headlineSmall,
            ),
            const SizedBox(height: 12),
            Text(
              'Makit can alert you when an agent finishes a turn, asks a '
              'question, or needs you to approve a tool call — so you can step '
              'away and still stay in control.',
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.bodyMedium,
            ),
            const SizedBox(height: 32),
            FilledButton.icon(
              icon: const Icon(PhosphorIconsLight.bell),
              label: const Text('Enable notifications'),
              onPressed: controller.enableNotifications,
            ),
            const SizedBox(height: 8),
            TextButton(
              onPressed: controller.skipNotifications,
              child: const Text('Not now'),
            ),
            const SizedBox(height: 8),
            Text(
              'You can enable this later in your device Settings.',
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ],
        ),
      ),
    );
  }
}
