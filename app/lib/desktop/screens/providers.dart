/// Riverpod wiring for the desktop control screens.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../control/control_contract.dart';
import '../daemon/cli_installer.dart';

/// Provides the [ControlClient] the desktop screens read from.
///
/// This is a placeholder: the real binding is installed at the app root in
/// Phase 4 (see `desktop_app.dart`) and tests override it with a
/// `FakeControlClient` via `ProviderScope`.
final controlClientProvider = Provider<ControlClient>(
  (ref) => throw UnimplementedError('Set by parent'),
);

/// Provides the [CliInstaller] used by the Settings → Server CLI row's
/// one-click "Install CLI" action. The default targets the running .app's
/// bundled CLI; tests override it with temp-dir paths.
final cliInstallerProvider = Provider<CliInstaller>((ref) => CliInstaller());
