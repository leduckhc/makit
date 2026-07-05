/// Pairing QR-code display for the desktop control app.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../../control/control_contract.dart';
import 'providers.dart';
import 'time_format.dart';

/// Side of the rendered QR image in logical pixels.
const double _kQrSize = 280;

/// Displays a pairing QR code and its live expiry countdown.
///
/// On mount it reuses the current token via `pairCurrent()`, minting a fresh
/// one only when none is live. The refresh action always mints anew.
class QrScreen extends ConsumerStatefulWidget {
  /// Creates the pairing QR screen.
  const QrScreen({super.key});

  @override
  ConsumerState<QrScreen> createState() => _QrScreenState();
}

/// A normalized view of pairing data, whether current or freshly minted.
class _Pairing {
  const _Pairing({
    required this.url,
    required this.expiresAt,
    this.fingerprint,
  });

  final String url;
  final int expiresAt;
  final String? fingerprint;
}

class _QrScreenState extends ConsumerState<QrScreen> {
  Future<_Pairing>? _future;
  Timer? _ticker;
  Duration _remaining = Duration.zero;

  @override
  void initState() {
    super.initState();
    _future = _loadOrMint();
  }

  @override
  void dispose() {
    _ticker?.cancel();
    super.dispose();
  }

  Future<_Pairing> _loadOrMint() async {
    final client = ref.read(controlClientProvider);
    final current = await client.pairCurrent();
    final pairing = current != null
        ? _Pairing(url: current.url, expiresAt: current.expiresAt)
        : _fromMint(await client.pairMint());
    if (!mounted) return pairing;
    _startTicker(pairing);
    return pairing;
  }

  Future<_Pairing> _mint() async {
    final pairing = _fromMint(await ref.read(controlClientProvider).pairMint());
    if (!mounted) return pairing;
    _startTicker(pairing);
    return pairing;
  }

  _Pairing _fromMint(PairMintData data) => _Pairing(
    url: data.url,
    expiresAt: data.expiresAt,
    fingerprint: data.fingerprint,
  );

  void _startTicker(_Pairing pairing) {
    _ticker?.cancel();
    void tick() {
      final remaining = DateTime.fromMillisecondsSinceEpoch(
        pairing.expiresAt,
      ).difference(DateTime.now());
      if (mounted) {
        setState(
          () => _remaining = remaining.isNegative ? Duration.zero : remaining,
        );
      }
    }

    tick();
    _ticker = Timer.periodic(const Duration(seconds: 1), (_) => tick());
  }

  void _refresh() {
    setState(() {
      _future = _mint();
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Pair'),
        actions: [
          IconButton(
            tooltip: 'Refresh',
            icon: const Icon(Icons.refresh),
            onPressed: _refresh,
          ),
        ],
      ),
      body: FutureBuilder<_Pairing>(
        future: _future,
        builder: (context, snapshot) {
          if (snapshot.connectionState == ConnectionState.waiting) {
            return const Center(child: CircularProgressIndicator());
          }
          if (snapshot.hasError) {
            return _QrError(onRetry: _refresh, error: snapshot.error);
          }
          return _QrBody(pairing: snapshot.requireData, remaining: _remaining);
        },
      ),
    );
  }
}

class _QrBody extends StatelessWidget {
  const _QrBody({required this.pairing, required this.remaining});

  final _Pairing pairing;
  final Duration remaining;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            QrImageView(data: pairing.url, size: _kQrSize),
            const SizedBox(height: 24),
            SelectableText(
              pairing.url,
              textAlign: TextAlign.center,
              style: theme.textTheme.bodyMedium,
            ),
            if (pairing.fingerprint != null) ...[
              const SizedBox(height: 12),
              SelectableText(
                pairing.fingerprint!,
                textAlign: TextAlign.center,
                style: theme.textTheme.bodySmall?.copyWith(
                  fontFamily: 'monospace',
                ),
              ),
            ],
            const SizedBox(height: 12),
            Text(
              'Expires in ${formatCountdown(remaining)}',
              style: theme.textTheme.labelLarge,
            ),
          ],
        ),
      ),
    );
  }
}

class _QrError extends StatelessWidget {
  const _QrError({required this.onRetry, required this.error});

  final VoidCallback onRetry;
  final Object? error;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.error_outline, color: cs.error, size: 40),
          const SizedBox(height: 12),
          Text(
            'Could not load pairing',
            style: Theme.of(context).textTheme.titleMedium,
          ),
          const SizedBox(height: 4),
          Text('$error', style: Theme.of(context).textTheme.bodySmall),
          const SizedBox(height: 16),
          FilledButton.tonal(onPressed: onRetry, child: const Text('Retry')),
        ],
      ),
    );
  }
}
