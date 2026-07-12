/// Server endpoint settings for the desktop app (host + port).
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../desktop_app.dart' show desktopControllerProvider;
import 'server_config.dart';

/// Lets the user set the host + port makit's daemon listens on. Changes are
/// persisted immediately; a restart applies them to a running daemon.
class ServerSettingsScreen extends ConsumerStatefulWidget {
  /// Creates the settings screen.
  const ServerSettingsScreen({super.key});

  @override
  ConsumerState<ServerSettingsScreen> createState() =>
      _ServerSettingsScreenState();
}

class _ServerSettingsScreenState extends ConsumerState<ServerSettingsScreen> {
  late final TextEditingController _host;
  late final TextEditingController _port;
  String? _error;
  bool _saved = false;

  @override
  void initState() {
    super.initState();
    final cfg = ref.read(serverConfigProvider);
    _host = TextEditingController(text: cfg.host);
    _port = TextEditingController(text: '${cfg.port}');
  }

  Future<void> _save() async {
    final port = int.tryParse(_port.text.trim());
    if (port == null || port <= 0 || port > 65535) {
      setState(() {
        _error = 'Port must be a number between 1 and 65535.';
        _saved = false;
      });
      return;
    }
    final notifier = ref.read(serverConfigProvider.notifier);
    await notifier.setHost(_host.text);
    await notifier.setPort(port);
    if (!mounted) return;
    setState(() {
      _error = null;
      _saved = true;
    });
  }

  Future<void> _restart() async {
    await _save();
    if (_error != null) return;
    await ref.read(desktopControllerProvider).restart();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Server')),
      body: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          Text(
            'Where the makit server listens. The desktop app connects here and '
            'starts the server with these values. Default: '
            '$kDefaultServerHost:$kDefaultServerPort.',
            style: Theme.of(context).textTheme.bodyMedium,
          ),
          const SizedBox(height: 20),
          TextField(
            controller: _host,
            decoration: const InputDecoration(
              labelText: 'Host',
              hintText: kDefaultServerHost,
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 16),
          TextField(
            controller: _port,
            keyboardType: TextInputType.number,
            inputFormatters: [FilteringTextInputFormatter.digitsOnly],
            decoration: const InputDecoration(
              labelText: 'Port',
              hintText: '$kDefaultServerPort',
              border: OutlineInputBorder(),
            ),
          ),
          if (_error != null) ...[
            const SizedBox(height: 12),
            Text(
              _error!,
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
          ],
          const SizedBox(height: 20),
          Row(
            children: [
              FilledButton(onPressed: _save, child: const Text('Save')),
              const SizedBox(width: 12),
              OutlinedButton.icon(
                onPressed: _restart,
                icon: const Icon(Icons.restart_alt),
                label: const Text('Save & restart server'),
              ),
              const SizedBox(width: 12),
              if (_saved)
                Text(
                  'Saved',
                  style: TextStyle(color: Theme.of(context).colorScheme.primary),
                ),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            'A running server keeps its current port until restarted.',
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: Theme.of(context).colorScheme.outline,
                ),
          ),
        ],
      ),
    );
  }

  @override
  void dispose() {
    _host.dispose();
    _port.dispose();
    super.dispose();
  }
}
