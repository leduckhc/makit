import 'package:flutter/material.dart';

/// QR scanner is disabled in this build. Use the "Paste pairing URL"
/// button on the pairing screen instead.
///
/// We'll bring back camera scanning once we swap to an iOS Vision-based
/// scanner that doesn't pull in Google MLKit (which has no arm64 simulator
/// slice on iOS 26+).
class QrScannerScreen extends StatelessWidget {
  const QrScannerScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Scan pairing QR'),
        leading: IconButton(
          icon: const Icon(Icons.close),
          onPressed: () => Navigator.of(context).pop(),
        ),
      ),
      body: const Padding(
        padding: EdgeInsets.all(24),
        child: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.qr_code_scanner, size: 64),
              SizedBox(height: 16),
              Text(
                'Camera-based QR scanning is temporarily disabled in this build.\n\n'
                'Use "Paste pairing URL" instead — copy the pino://pair?... line '
                'from your server terminal.',
                textAlign: TextAlign.center,
              ),
            ],
          ),
        ),
      ),
    );
  }
}
