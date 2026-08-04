import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:phosphoricons_flutter/phosphoricons_flutter.dart';

import '../app/theme.dart';
import '../store/connection.dart';
import '../ui/widgets/makit_mark.dart';
import 'add_server_sheet.dart';
import 'mdns_browser.dart';
import 'onboarding_controller.dart';
import 'pair_info.dart';
import 'qr_scanner_screen.dart';

/// First-run pairing. The one job here is getting a first server connected, so
/// the screen leads with a single primary action (scan) and demotes everything
/// else — pasting a URL, picking a discovered host, demo data — below it.
///
/// Once a server is paired the user never comes back here: adding a second
/// machine happens in the server manager (`/servers`), which shares this
/// screen's [AddServerSheet] plumbing.
class PairingScreen extends ConsumerStatefulWidget {
  const PairingScreen({super.key});

  @override
  ConsumerState<PairingScreen> createState() => _PairingScreenState();
}

class _PairingScreenState extends ConsumerState<PairingScreen> {
  Future<List<DiscoveredServer>>? _browse;

  @override
  void initState() {
    super.initState();
    _browse = browseLan();
  }

  void _refresh() => setState(() => _browse = browseLan());

  Future<void> _pair(PairInfo info) async {
    final ok = await pairAndReport(context, ref, info);
    if (ok && mounted) context.go('/');
  }

  Future<void> _scanQr() async {
    final info = await Navigator.of(context).push<PairInfo>(
      MaterialPageRoute(builder: (_) => const QrScannerScreen()),
    );
    if (info == null || !mounted) return;
    await _pair(info);
  }

  Future<void> _pasteUrl() async {
    final ctrl = TextEditingController();
    final url = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Paste pairing URL'),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          decoration: const InputDecoration(hintText: 'makit://pair?host=…'),
          maxLines: 3,
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, ctrl.text.trim()),
            child: const Text('Pair'),
          ),
        ],
      ),
    );
    if (url == null || url.isEmpty || !mounted) return;
    final info = PairInfo.tryParse(url);
    if (info == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Not a makit pairing URL.')),
      );
      return;
    }
    await _pair(info);
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;

    return Scaffold(
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.fromLTRB(
            kSpace24,
            kSpace32,
            kSpace24,
            kSpace24,
          ),
          children: [
            Center(child: MakitMark(size: 56, color: cs.primary)),
            const SizedBox(height: kSpace20),
            Text(
              'Connect to your Mac',
              textAlign: TextAlign.center,
              style: text.headlineSmall?.copyWith(fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: kSpace8),
            Text(
              'Run makit serve in a terminal, then scan the QR code it prints.',
              textAlign: TextAlign.center,
              style: text.bodyMedium?.copyWith(color: cs.outline),
            ),
            const SizedBox(height: kSpace32),
            FilledButton.icon(
              icon: const Icon(PhosphorIconsLight.qrCode),
              label: const Text('Scan QR code'),
              style: FilledButton.styleFrom(
                minimumSize: const Size.fromHeight(52),
                textStyle: text.titleSmall?.copyWith(
                  fontWeight: FontWeight.w600,
                ),
              ),
              onPressed: _scanQr,
            ),
            const SizedBox(height: kSpace8),
            TextButton.icon(
              icon: const Icon(PhosphorIconsLight.clipboard, size: 16),
              label: const Text('Paste pairing URL instead'),
              onPressed: _pasteUrl,
            ),
            const SizedBox(height: kSpace24),
            _SectionHeader(
              title: 'On this network',
              trailing: IconButton(
                onPressed: _refresh,
                visualDensity: VisualDensity.compact,
                tooltip: 'Search again',
                icon: const Icon(PhosphorIconsLight.arrowClockwise, size: 18),
              ),
            ),
            // Discovery can't produce a pairing token, so a hit here is a
            // shortcut into the scanner rather than a one-tap pair. Saying so
            // up front beats the old flow's after-the-fact snackbar.
            DiscoveredServersList(
              browse: _browse ?? Future.value(const []),
              onTap: (_) => _scanQr(),
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
                context.go('/');
              },
            ),
          ],
        ),
      ),
    );
  }
}

class _SectionHeader extends StatelessWidget {
  const _SectionHeader({required this.title, this.trailing});

  final String title;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Expanded(
          child: Text(
            title.toUpperCase(),
            style: Theme.of(context).textTheme.labelSmall?.copyWith(
              color: Theme.of(context).colorScheme.outline,
              letterSpacing: 1,
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
        trailing ?? const SizedBox.shrink(),
      ],
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
