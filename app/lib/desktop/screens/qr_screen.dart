/// Pairing QR-code display for the desktop control app.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:phosphoricons_flutter/phosphoricons_flutter.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../../app/theme.dart';
import '../../control/control_contract.dart';
import 'providers.dart';
import 'time_format.dart';

/// Side of the rendered QR image in logical pixels. Kept compact since the
/// pairing view is now embedded inline in the settings section.
const double _kQrSize = 140;

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
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Align(
          alignment: Alignment.centerRight,
          child: IconButton(
            tooltip: 'Refresh',
            icon: const Icon(PhosphorIconsLight.arrowClockwise, size: 18),
            onPressed: _refresh,
          ),
        ),
        FutureBuilder<_Pairing>(
          future: _future,
          builder: (context, snapshot) {
            if (snapshot.connectionState == ConnectionState.waiting) {
              return const Padding(
                padding: EdgeInsets.all(kSpace24),
                child: Center(child: CircularProgressIndicator()),
              );
            }
            if (snapshot.hasError) {
              return _QrError(onRetry: _refresh, error: snapshot.error);
            }
            return _QrBody(
              pairing: snapshot.requireData,
              remaining: _remaining,
            );
          },
        ),
      ],
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
    return Padding(
      padding: const EdgeInsets.all(kSpace24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            padding: const EdgeInsets.all(kSpace16),
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(kRadius12),
            ),
            child: QrImageView(
              data: pairing.url,
              size: _kQrSize,
              backgroundColor: Colors.white,
            ),
          ),
          const SizedBox(height: kSpace24),
          SelectableText(
            pairing.url,
            textAlign: TextAlign.center,
            style: theme.textTheme.bodyMedium,
          ),
          if (pairing.fingerprint != null) ...[
            const SizedBox(height: kSpace12),
            SelectableText(
              pairing.fingerprint!,
              textAlign: TextAlign.center,
              style: theme.textTheme.bodySmall?.mono,
            ),
          ],
          const SizedBox(height: kSpace12),
          Text(
            'Expires in ${formatCountdown(remaining)}',
            style: theme.textTheme.labelLarge,
          ),
        ],
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
          Icon(PhosphorIconsLight.warningCircle, color: cs.error, size: 40),
          const SizedBox(height: kSpace12),
          Text(
            'Could not load pairing',
            style: Theme.of(context).textTheme.titleMedium,
          ),
          const SizedBox(height: kSpace4),
          Text('$error', style: Theme.of(context).textTheme.bodySmall),
          const SizedBox(height: kSpace16),
          FilledButton.tonal(onPressed: onRetry, child: const Text('Retry')),
        ],
      ),
    );
  }
}
