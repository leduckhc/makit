import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:phosphoricons_flutter/phosphoricons_flutter.dart';

import '../app/theme.dart';
import '../store/connection.dart';
import '../ui/widgets/sheet_header.dart';
import 'device_name.dart';
import 'mdns_browser.dart';
import 'pair_info.dart';
import 'qr_scanner_screen.dart';

/// Add another server: scan its QR, or paste the pairing URL it printed.
///
/// Shown as a sheet from the server manager, and inlined by the first-run
/// pairing screen. Both routes end in [ConnectionController.pairWith], which
/// appends the server and makes it active.
Future<void> showAddServerSheet(BuildContext context) => showModalBottomSheet(
  context: context,
  showDragHandle: true,
  isScrollControlled: true,
  builder: (_) => const AddServerSheet(),
);

class AddServerSheet extends ConsumerStatefulWidget {
  const AddServerSheet({super.key});

  @override
  ConsumerState<AddServerSheet> createState() => _AddServerSheetState();
}

class _AddServerSheetState extends ConsumerState<AddServerSheet> {
  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const SheetHeader(title: 'Add a server'),
            Padding(
              padding: const EdgeInsets.fromLTRB(
                kSpace20,
                0,
                kSpace20,
                kSpace12,
              ),
              child: Text(
                'Run `makit serve` on the Mac you want to reach, then scan the '
                'QR code it prints.',
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: Theme.of(context).colorScheme.outline,
                ),
              ),
            ),
            ListTile(
              leading: const Icon(PhosphorIconsLight.qrCode),
              title: const Text('Scan QR code'),
              subtitle: const Text('The usual way'),
              onTap: _scanQr,
            ),
            ListTile(
              leading: const Icon(PhosphorIconsLight.clipboard),
              title: const Text('Paste pairing URL'),
              subtitle: const Text('makit://pair?host=…'),
              onTap: _pasteUrl,
            ),
            const SizedBox(height: kSpace8),
          ],
        ),
      ),
    );
  }

  Future<void> _scanQr() async {
    final navigator = Navigator.of(context);
    final info = await navigator.push<PairInfo>(
      MaterialPageRoute(builder: (_) => const QrScannerScreen()),
    );
    if (info == null || !mounted) return;
    navigator.pop(); // dismiss the sheet before pairing feedback
    await pairAndReport(context, ref, info);
  }

  Future<void> _pasteUrl() async {
    final navigator = Navigator.of(context);
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
    navigator.pop();
    await pairAndReport(context, ref, info);
  }
}

/// Run the pair handshake with a blocking spinner and report the outcome.
///
/// Shared by the add-server sheet and the first-run pairing screen so both
/// report failure the same way — pairing is the one place a user has no other
/// signal that something went wrong.
Future<bool> pairAndReport(
  BuildContext context,
  WidgetRef ref,
  PairInfo info,
) async {
  final messenger = ScaffoldMessenger.of(context);
  final navigator = Navigator.of(context);
  showDialog<void>(
    context: context,
    barrierDismissible: false,
    builder: (_) => const Center(child: CircularProgressIndicator()),
  );
  try {
    final label = await deviceName();
    await ref
        .read(connectionControllerProvider.notifier)
        .pairWith(info, label: label);
    navigator.pop(); // close spinner
    messenger.showSnackBar(const SnackBar(content: Text('Paired!')));
    return true;
  } catch (e) {
    navigator.pop();
    messenger.showSnackBar(SnackBar(content: Text('Pair failed: $e')));
    return false;
  }
}

/// mDNS-discovered servers on this network, refreshable. Discovery alone can't
/// pair (there's no token in the advertisement), so a hit here is a shortcut
/// into the scanner — with the host already confirmed reachable.
class DiscoveredServersList extends StatelessWidget {
  const DiscoveredServersList({
    super.key,
    required this.browse,
    required this.onTap,
  });

  final Future<List<DiscoveredServer>> browse;
  final void Function(DiscoveredServer) onTap;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return FutureBuilder<List<DiscoveredServer>>(
      future: browse,
      builder: (context, snapshot) {
        if (snapshot.connectionState == ConnectionState.waiting) {
          return const Padding(
            padding: EdgeInsets.all(kSpace16),
            child: Center(
              child: SizedBox(
                width: 20,
                height: 20,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
            ),
          );
        }
        final servers = snapshot.data ?? const [];
        if (servers.isEmpty) {
          return Padding(
            padding: const EdgeInsets.symmetric(
              horizontal: kSpace4,
              vertical: kSpace8,
            ),
            child: Text(
              'Nothing found. Check that `makit serve` is running and this '
              'phone is on the same Wi-Fi.',
              style: Theme.of(
                context,
              ).textTheme.bodySmall?.copyWith(color: cs.outline),
            ),
          );
        }
        return Column(
          children: [
            for (final s in servers)
              ListTile(
                contentPadding: const EdgeInsets.symmetric(
                  horizontal: kSpace4,
                ),
                leading: Icon(PhosphorIconsLight.hardDrives, color: cs.outline),
                title: Text(s.name, maxLines: 1, overflow: TextOverflow.ellipsis),
                subtitle: Text('${s.host}:${s.port}'),
                trailing: const Icon(PhosphorIconsLight.qrCode, size: 18),
                onTap: () => onTap(s),
              ),
          ],
        );
      },
    );
  }
}
