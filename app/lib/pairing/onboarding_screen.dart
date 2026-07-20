import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:phosphoricons_flutter/phosphoricons_flutter.dart';

import 'onboarding_controller.dart';
import 'pairing_screen.dart';
import 'readiness.dart';

/// SPEC-09 Slice 1 — the first-run wizard. Renders the first unsatisfied gate:
/// [OnboardingStep.pair] (scan/paste) or [OnboardingStep.notifications]
/// (skippable enable prompt). The [OnboardingStep.ready] case never renders —
/// the router redirects to Home before it can.
class OnboardingScreen extends ConsumerWidget {
  const OnboardingScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final step = ref.watch(onboardingStepProvider);
    return switch (step) {
      OnboardingStep.pair => const PairingScreen(),
      OnboardingStep.notifications => const _NotificationsStep(),
      // Router redirects away before this renders; a spinner is a safe stand-in.
      OnboardingStep.ready => const Scaffold(
        body: Center(child: CircularProgressIndicator()),
      ),
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
