import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:phosphoricons_flutter/phosphoricons_flutter.dart';

import '../app/theme.dart';
import '../store/connection.dart';
import '../ui/widgets/makit_mark.dart';
import 'add_server_sheet.dart';
import 'onboarding_controller.dart';
import 'server_row.dart';
import '../app/routes.dart';

/// The one server surface: first run *and* management.
///
/// Nothing paired → a hero plus "Add server". Once servers exist the hero steps
/// aside and the same screen becomes the picker: tap a row to move the live
/// connection there, use its menu to rename or forget. Keeping both jobs on one
/// screen means there is a single place the user learns, and no second manager
/// screen to find.
///
/// Reached as `/pair` while onboarding (the router forces it) and as `/servers`
/// from Settings once paired.
class PairingScreen extends ConsumerStatefulWidget {
  const PairingScreen({super.key});

  @override
  ConsumerState<PairingScreen> createState() => _PairingScreenState();
}

class _PairingScreenState extends ConsumerState<PairingScreen> {
  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    final conn = ref.watch(connectionProvider);
    final controller = ref.read(connectionControllerProvider.notifier);
    final servers = conn.servers;
    final activeId = conn.activeServer?.id;
    final firstRun = servers.isEmpty;

    return Scaffold(
      // No back arrow on first run: there is nowhere behind it. Once paired the
      // screen is pushed from Settings and gets the standard one.
      appBar: firstRun ? null : AppBar(title: const Text('Servers')),
      body: SafeArea(
        child: ListView(
          padding: EdgeInsets.fromLTRB(
            kSpace20,
            firstRun ? kSpace32 : kSpace12,
            kSpace20,
            kSpace24,
          ),
          children: [
            if (firstRun) ...[
              Center(child: MakitMark(size: 56, color: cs.primary)),
              const SizedBox(height: kSpace20),
              Text(
                'Connect to your Mac',
                textAlign: TextAlign.center,
                style: text.headlineSmall?.copyWith(
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: kSpace8),
              Text(
                'Run makit serve in a terminal, then add it below.',
                textAlign: TextAlign.center,
                style: text.bodyMedium?.copyWith(color: cs.outline),
              ),
              const SizedBox(height: kSpace32),
            ] else
              for (final s in servers)
                ServerRow(
                  key: ValueKey(s.id),
                  server: s,
                  isActive: s.id == activeId,
                  wsState: conn.wsState,
                  onSelect: () => controller.switchTo(s.id),
                  onRename: () => renameServerDialog(context, controller, s),
                  onForget: () => forgetServerDialog(context, controller, s),
                ),

            const SizedBox(height: kSpace8),
            FilledButton.icon(
              icon: const Icon(PhosphorIconsLight.plus),
              label: const Text('Add server'),
              style: FilledButton.styleFrom(
                minimumSize: const Size.fromHeight(52),
                textStyle: text.titleSmall?.copyWith(
                  fontWeight: FontWeight.w600,
                ),
              ),
              onPressed: () => showAddServerSheet(context),
            ),

            const SizedBox(height: kSpace32),
            _DevModeCard(
              onOpen: () {
                ref.read(connectionControllerProvider.notifier).useFakeServer();
                // Fake data bypasses pairing, which satisfies `paired` but not
                // the notifications gate — clear that too or the redirect
                // bounces straight back here.
                ref
                    .read(onboardingControllerProvider.notifier)
                    .skipNotifications();
                context.go(kRouteRepos);
              },
            ),
          ],
        ),
      ),
    );
  }
}

class _DevModeCard extends StatelessWidget {
  const _DevModeCard({required this.onOpen});

  final VoidCallback onOpen;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.all(kSpace16),
      decoration: BoxDecoration(
        color: cs.surfaceContainerHighest.withValues(alpha: 0.5),
        borderRadius: BorderRadius.circular(kRadius12),
        border: Border.all(color: cs.outlineVariant),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(PhosphorIconsLight.flask, size: 16, color: cs.tertiary),
              const SizedBox(width: kSpace6),
              Text(
                'No Mac handy?',
                style: Theme.of(context).textTheme.titleSmall,
              ),
            ],
          ),
          const SizedBox(height: kSpace6),
          Text(
            'Explore the app with seeded demo data. Nothing is sent anywhere.',
            style: Theme.of(
              context,
            ).textTheme.bodySmall?.copyWith(color: cs.outline),
          ),
          const SizedBox(height: kSpace12),
          FilledButton.tonal(
            onPressed: onOpen,
            child: const Text('Open with fake data'),
          ),
        ],
      ),
    );
  }
}
