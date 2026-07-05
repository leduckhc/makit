import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../store/connection.dart';
import 'device_name.dart';
import 'mdns_browser.dart';
import 'pair_info.dart';
import 'qr_scanner_screen.dart';

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

  void _refresh() {
    setState(() {
      _browse = browseLan();
    });
  }

  Future<void> _pair(PairInfo info) async {
    final messenger = ScaffoldMessenger.of(context);
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
      if (!mounted) return;
      Navigator.of(context).pop(); // close spinner
      messenger.showSnackBar(const SnackBar(content: Text('Paired!')));
      context.go('/');
    } catch (e) {
      if (!mounted) return;
      Navigator.of(context).pop();
      messenger.showSnackBar(SnackBar(content: Text('Pair failed: $e')));
    }
  }

  Future<void> _scanQr() async {
    final info = await Navigator.of(context).push<PairInfo>(
      MaterialPageRoute(builder: (_) => const QrScannerScreen()),
    );
    if (info == null) return;
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
          decoration: const InputDecoration(hintText: 'pino://pair?host=…'),
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
    if (url == null || url.isEmpty) return;
    final info = PairInfo.tryParse(url);
    if (info == null) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('Not a pino pairing URL.')));
      return;
    }
    await _pair(info);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Pair with desktop'),
        actions: [
          IconButton(onPressed: _refresh, icon: const Icon(Icons.refresh)),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          const SizedBox(height: 8),
          Center(
            child: Text(
              'Run `pino serve` on your Mac.\nScan the QR it prints, or pick the server below.',
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.bodyMedium,
            ),
          ),
          const SizedBox(height: 24),
          FilledButton.icon(
            icon: const Icon(Icons.qr_code_scanner),
            label: const Text('Scan QR'),
            onPressed: _scanQr,
          ),
          const SizedBox(height: 8),
          OutlinedButton.icon(
            icon: const Icon(Icons.content_paste),
            label: const Text('Paste pairing URL'),
            onPressed: _pasteUrl,
          ),
          const SizedBox(height: 24),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 4),
            child: Text(
              'On this network',
              style: Theme.of(context).textTheme.titleSmall,
            ),
          ),
          const SizedBox(height: 8),
          FutureBuilder<List<DiscoveredServer>>(
            future: _browse,
            builder: (context, snapshot) {
              if (snapshot.connectionState == ConnectionState.waiting) {
                return const Padding(
                  padding: EdgeInsets.all(16),
                  child: Center(child: CircularProgressIndicator()),
                );
              }
              final servers = snapshot.data ?? const [];
              if (servers.isEmpty) {
                return const Padding(
                  padding: EdgeInsets.all(16),
                  child: Text(
                    'No servers found. Make sure `pino serve` is running on the same Wi-Fi.',
                  ),
                );
              }
              return Column(
                children: servers
                    .map(
                      (s) => Card(
                        child: ListTile(
                          leading: const Icon(Icons.dns_outlined),
                          title: Text(s.name),
                          subtitle: Text(
                            '${s.host}:${s.port}\nfp ${_short(s.fingerprint)}',
                          ),
                          isThreeLine: true,
                          trailing: const Icon(Icons.qr_code_scanner),
                          onTap: () {
                            ScaffoldMessenger.of(context).showSnackBar(
                              const SnackBar(
                                content: Text(
                                  'Found via mDNS. Still need to scan the QR to get a pairing token.',
                                ),
                              ),
                            );
                            _scanQr();
                          },
                        ),
                      ),
                    )
                    .toList(),
              );
            },
          ),
          const SizedBox(height: 24),
          Card(
            color: Theme.of(context).colorScheme.surfaceContainerHighest,
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Dev mode',
                    style: Theme.of(context).textTheme.titleSmall,
                  ),
                  const SizedBox(height: 4),
                  const Text(
                    'Skip pairing and open the app with seeded fake data. Useful for UI iteration when no server is around.',
                  ),
                  const SizedBox(height: 8),
                  FilledButton.tonal(
                    onPressed: () {
                      ref
                          .read(connectionControllerProvider.notifier)
                          .useFakeServer();
                      context.go('/');
                    },
                    child: const Text('Open with fake data'),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  String _short(String fp) => fp.length > 16
      ? '${fp.substring(0, 8)}…${fp.substring(fp.length - 8)}'
      : fp;
}
