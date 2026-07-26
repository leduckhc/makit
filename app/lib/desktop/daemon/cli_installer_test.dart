// Unit tests for [CliInstaller]. Lives beside the code under test
// (repo convention, see daemon_lifecycle_test.dart), so it imports the
// flutter_test dev-dependency from a lib/ path.
// ignore_for_file: depend_on_referenced_packages
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:makit/desktop/daemon/cli_installer.dart';

void main() {
  late Directory tmp;

  setUp(() => tmp = Directory.systemTemp.createTempSync('cli_installer'));
  tearDown(() => tmp.deleteSync(recursive: true));

  /// Creates a fake bundled CLI file and returns its path.
  String makeBundled() {
    final f = File('${tmp.path}/Resources/makit/makit')
      ..createSync(recursive: true)
      ..writeAsStringSync('#!/bin/sh\necho bundled\n');
    Process.runSync('chmod', ['+x', f.path]);
    return f.path;
  }

  group('CliInstaller', () {
    test('bundledCliPath reports null when no bundled CLI exists', () {
      final installer = CliInstaller(
        bundledCliPath: () => '${tmp.path}/nope/makit',
        homeDir: () => tmp.path,
      );
      expect(installer.bundledCli, isNull);
    });

    test('bundledCliPath reports the path when the bundled CLI exists', () {
      final bundled = makeBundled();
      final installer = CliInstaller(
        bundledCliPath: () => bundled,
        homeDir: () => tmp.path,
      );
      expect(installer.bundledCli, bundled);
    });

    test('install writes an executable wrapper into ~/.local/bin', () async {
      final bundled = makeBundled();
      final installer = CliInstaller(
        bundledCliPath: () => bundled,
        homeDir: () => tmp.path,
      );

      final result = await installer.install();

      expect(result.ok, isTrue);
      expect(result.installedPath, '${tmp.path}/.local/bin/makit');
      final wrapper = File(result.installedPath!);
      expect(wrapper.existsSync(), isTrue);
      final content = wrapper.readAsStringSync();
      expect(content, startsWith('#!/bin/sh'));
      expect(content, contains('exec "$bundled"'));
      // Owner execute bit set.
      expect(wrapper.statSync().mode & 0x40, isNot(0));
      // The wrapper actually runs the bundled CLI.
      final run = Process.runSync(result.installedPath!, []);
      expect((run.stdout as String).trim(), 'bundled');
    });

    test('install overwrites an existing wrapper', () async {
      final bundled = makeBundled();
      final target = File('${tmp.path}/.local/bin/makit')
        ..createSync(recursive: true)
        ..writeAsStringSync('old');
      final installer = CliInstaller(
        bundledCliPath: () => bundled,
        homeDir: () => tmp.path,
      );

      final result = await installer.install();

      expect(result.ok, isTrue);
      expect(target.readAsStringSync(), contains(bundled));
    });

    test('install fails cleanly when no bundled CLI exists', () async {
      final installer = CliInstaller(
        bundledCliPath: () => '${tmp.path}/nope/makit',
        homeDir: () => tmp.path,
      );

      final result = await installer.install();

      expect(result.ok, isFalse);
      expect(result.error, contains('bundled'));
      expect(File('${tmp.path}/.local/bin/makit').existsSync(), isFalse);
    });

    test('install surfaces filesystem errors instead of throwing', () async {
      final bundled = makeBundled();
      // Make the target path unwritable: ~/.local/bin exists as a *file*.
      File('${tmp.path}/.local').createSync();
      final installer = CliInstaller(
        bundledCliPath: () => bundled,
        homeDir: () => tmp.path,
      );

      final result = await installer.install();

      expect(result.ok, isFalse);
      expect(result.error, isNotEmpty);
    });
  });
}
