/// About section body (SPEC-13 migration map).
///
/// App identity (name, protocol version) and a docs link — mirroring the mobile
/// About idiom (`app/lib/ui/settings/settings_screen.dart`). The destructive
/// **Unpair this device** action lives in the Server & Devices section.
library;

import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../../transport/protocol.dart' show protocolVersion;
import 'section_header.dart';
import 'settings_group.dart';

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
        SettingsGroup(children: [_AppInfoRow(), _ProtocolRow(), _DocsRow()]),
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
    // launchUrl can throw (e.g. PlatformException) as well as return false;
    // treat both as failure so the fallback message always shows.
    var ok = false;
    try {
      ok = await launchUrl(_kDocsUri, mode: LaunchMode.externalApplication);
    } catch (_) {
      ok = false;
    }
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
