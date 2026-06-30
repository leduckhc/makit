import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'pair_info.dart';

/// Vision-backed QR scanner (iOS).
///
/// We don't render a Flutter UI here — we just call the `pino/qr_scanner`
/// platform channel, which presents a native AVFoundation + Vision view
/// controller. On detection (or cancel) it dismisses and returns the
/// payload string (or null).
///
/// On other platforms / when the channel isn't available, falls back to a
/// "not supported on this platform" message; the pairing screen's
/// "Paste pairing URL" button is still usable.
class QrScannerScreen extends StatefulWidget {
  const QrScannerScreen({super.key});

  @override
  State<QrScannerScreen> createState() => _QrScannerScreenState();
}

class _QrScannerScreenState extends State<QrScannerScreen> {
  static const _channel = MethodChannel('pino/qr_scanner');
  bool _started = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _scan());
  }

  Future<void> _scan() async {
    if (_started) return;
    _started = true;
    try {
      final raw = await _channel.invokeMethod<String?>('scan');
      if (!mounted) return;
      if (raw == null) {
        Navigator.of(context).pop();
        return;
      }
      final info = PairInfo.tryParse(raw);
      Navigator.of(context).pop(info);
    } on PlatformException catch (e) {
      if (!mounted) return;
      setState(() => _error = e.message ?? 'Scanner failed');
    } on MissingPluginException {
      if (!mounted) return;
      setState(() => _error =
          'Camera scanner not available on this platform — use "Paste pairing URL" instead.');
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Scan pairing QR')),
      body: Center(
        child: _error != null
            ? Padding(
                padding: const EdgeInsets.all(24),
                child: Text(_error!, textAlign: TextAlign.center),
              )
            : const CircularProgressIndicator(),
      ),
    );
  }
}
