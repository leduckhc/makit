/// General section body (SPEC-13 migration map).
///
/// Home for one-time, user-level actions. SPEC-50 D6 moves `Install CLI` here
/// from the Server section: installing the bundled `makit` binary is a one-time
/// action, and one-time actions belong with one-time actions.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:phosphoricons_flutter/phosphoricons_flutter.dart';

import '../../../status/status_event.dart';
import '../../../status/status_providers.dart';
import '../../screens/providers.dart'
    show bundledCliPathProvider, cliInstallerProvider;
import 'section_header.dart';
import 'settings_group.dart';

/// General section body.
class GeneralSection extends StatelessWidget {
  /// Creates the General section body.
  const GeneralSection({super.key});

  @override
  Widget build(BuildContext context) {
    return ListView(
      children: const [
        SettingsSectionHeader(title: 'General'),
        SettingsSectionHeader(title: 'Command-line tool'),
        SettingsGroup(children: [_InstallCliRow()]),
      ],
    );
  }
}

/// One-time install of the app-bundled `makit` CLI into `~/.local/bin/makit`.
///
/// Shown only when the running app actually bundles a CLI (dev builds run from
/// source do not). Moved here from the Server section (SPEC-50 D6).
class _InstallCliRow extends ConsumerWidget {
  const _InstallCliRow();

  Future<void> _install(WidgetRef ref) async {
    // Resolved before the first await: `ref` throws once its widget is
    // unmounted, and the record must survive the thing that reported to it.
    final status = ref.status;
    final result = await ref.read(cliInstallerProvider).install();
    if (result.ok) {
      status.success(
        'Installed makit CLI to ${result.installedPath}',
        source: StatusSources.settings,
        detail:
            'If your terminal can’t find `makit`, add ~/.local/bin to your PATH.',
      );
    } else {
      status.failure(
        'Could not install the makit CLI',
        source: StatusSources.settings,
        detail: result.error,
      );
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final cs = Theme.of(context).colorScheme;
    final bundled = ref.watch(bundledCliPathProvider) != null;
    return ListTile(
      leading: Icon(PhosphorIconsLight.terminalWindow, color: cs.outline),
      title: const Text('Install CLI'),
      subtitle: Text(
        bundled
            ? 'Install the bundled makit command to ~/.local/bin so you can '
                  'drive the server from a terminal.'
            : 'This build has no bundled CLI to install.',
      ),
      trailing: bundled
          ? OutlinedButton.icon(
              onPressed: () => unawaited(_install(ref)),
              icon: const Icon(PhosphorIconsLight.downloadSimple, size: 18),
              label: const Text('Install CLI'),
            )
          : null,
    );
  }
}
