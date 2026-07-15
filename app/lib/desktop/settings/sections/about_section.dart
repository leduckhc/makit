/// About section body (SPEC-13 migration map).
///
/// App identity (name, protocol version), a docs link, and the destructive
/// **Unpair this device** action — mirroring the mobile About idiom
/// (`app/lib/ui/settings/settings_screen.dart`).
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../../store/connection.dart' show connectionControllerProvider;
import '../../../transport/protocol.dart' show protocolVersion;
import 'section_header.dart';

/// The project docs / source link surfaced in About.
final Uri _kDocsUri = Uri.parse('https://github.com/leduckhc/makit');

/// About section body.
class AboutSection extends StatelessWidget {
  /// Creates the About section body.
  const AboutSection({super.key});

  @override
  Widget build(BuildContext context) {
    return ListView(
      children: const [
        SettingsSectionHeader(title: 'About'),
        _AppInfoRow(),
        _ProtocolRow(),
        _DocsRow(),
        SettingsSectionHeader(title: 'Danger zone'),
        _UnpairRow(),
      ],
    );
  }
}

/// App identity — name and role. Protocol version lives in its own row below.
class _AppInfoRow extends StatelessWidget {
  const _AppInfoRow();

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return ListTile(
      leading: Icon(Symbols.info, weight: 200, color: cs.primary),
      title: const Text('makit'),
      subtitle: const Text('Desktop control app for the makit daemon.'),
    );
  }
}

/// Protocol version — the compile-time wire-protocol constant (read-only).
class _ProtocolRow extends StatelessWidget {
  const _ProtocolRow();

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return ListTile(
      leading: Icon(Symbols.lan, weight: 200, color: cs.outline),
      title: const Text('Protocol version'),
      subtitle: const Text('v$protocolVersion'),
    );
  }
}

/// Docs / source link — opens the project page in the default browser.
class _DocsRow extends StatelessWidget {
  const _DocsRow();

  Future<void> _open(BuildContext context) async {
    final messenger = ScaffoldMessenger.of(context);
    final ok = await launchUrl(_kDocsUri, mode: LaunchMode.externalApplication);
    if (!ok) {
      messenger.showSnackBar(
        SnackBar(content: Text('Could not open $_kDocsUri')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return ListTile(
      leading: Icon(Symbols.link, weight: 200, color: cs.outline),
      title: const Text('Documentation & source'),
      subtitle: Text('$_kDocsUri'),
      trailing: const Icon(Symbols.open_in_new, weight: 200, size: 18),
      onTap: () => _open(context),
    );
  }
}

/// Unpair this device (danger): clears this app's stored server pairing via the
/// existing [connectionControllerProvider] flow, behind a confirm dialog. On
/// desktop the app re-pairs over loopback on the next launch; this still
/// clears the current pairing and disconnects, so it is a real action.
class _UnpairRow extends ConsumerWidget {
  const _UnpairRow();

  Future<void> _confirmAndUnpair(BuildContext context, WidgetRef ref) async {
    final messenger = ScaffoldMessenger.of(context);
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Unpair this device?'),
        content: const Text(
          'This clears the stored pairing and disconnects from the server.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(context).colorScheme.error,
            ),
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Unpair'),
          ),
        ],
      ),
    );
    if (confirmed ?? false) {
      await ref.read(connectionControllerProvider.notifier).unpair();
      messenger.showSnackBar(const SnackBar(content: Text('Device unpaired')));
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final cs = Theme.of(context).colorScheme;
    return ListTile(
      leading: Icon(Symbols.link_off, weight: 200, color: cs.error),
      title: Text('Unpair this device', style: TextStyle(color: cs.error)),
      subtitle: const Text('Remove this device\'s pairing and disconnect.'),
      trailing: OutlinedButton(
        style: OutlinedButton.styleFrom(foregroundColor: cs.error),
        onPressed: () => unawaited(_confirmAndUnpair(context, ref)),
        child: const Text('Unpair'),
      ),
    );
  }
}
