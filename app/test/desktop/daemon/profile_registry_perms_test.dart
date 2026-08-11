// Live, real-filesystem tests for [FileSystemAdapter] permissions (SPEC-50).
//
// The server guarantees MAKIT_HOME is 0700 and its files 0600
// (server/src/daemon/paths.ts) because that directory holds an APNs auth key and
// a TLS private key. Dart's defaults are 0755/0644, so an app that creates the
// directory first would silently downgrade the server's guarantee. Only a real
// filesystem can prove the modes, so these tests use one (in a temp dir).
// ignore_for_file: depend_on_referenced_packages
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:makit/desktop/daemon/profile_registry.dart';

void main() {
  late Directory root;
  setUp(() => root = Directory.systemTemp.createTempSync('spec50-perm-'));
  tearDown(() {
    if (root.existsSync()) root.deleteSync(recursive: true);
  });

  /// The octal permission bits (e.g. `700`) of [path]. Uses the Dart API so it
  /// is portable — `stat -f %Lp` is BSD-only and fails on the Linux CI VM.
  String modeOf(String path) =>
      (FileStat.statSync(path).mode & 0xFFF).toRadixString(8).padLeft(3, '0');

  test('the registry file is 0600 and its directory 0700', () {
    final home = '${root.path}/.makit';
    const FileSystemAdapter().writeAtomic('$home/profiles.json', '{}\n');

    expect(File('$home/profiles.json').existsSync(), isTrue);
    expect(
      modeOf('$home/profiles.json'),
      '600',
      reason: 'profiles.json is readable by other local users',
    );
    expect(
      modeOf(home),
      '700',
      reason: 'the directory holding the APNs and TLS keys is traversable',
    );
  });

  test('rewriting an existing file keeps it 0600', () {
    final path = '${root.path}/.makit/profiles.json';
    const fs = FileSystemAdapter();
    fs.writeAtomic(path, '{"a":1}\n');
    fs.writeAtomic(path, '{"a":2}\n');
    expect(File(path).readAsStringSync(), '{"a":2}\n');
    expect(modeOf(path), '600');
  });

  test('a pre-existing loose directory is tightened, not left open', () {
    // The realistic case: something else created ~/.makit first with 0755.
    final home = Directory('${root.path}/.makit')..createSync(recursive: true);
    Process.runSync('/bin/chmod', ['755', home.path]);
    expect(modeOf(home.path), '755');

    const FileSystemAdapter().writeAtomic('${home.path}/profiles.json', '{}\n');

    expect(modeOf(home.path), '700');
  });

  test('the temp file never lingers after a successful write', () {
    final home = '${root.path}/.makit';
    const FileSystemAdapter().writeAtomic('$home/profiles.json', '{}\n');
    final leftovers = Directory(home)
        .listSync()
        .map((e) => e.path.split('/').last)
        .where((n) => n.contains('.tmp'))
        .toList();
    expect(leftovers, isEmpty);
  });
}
