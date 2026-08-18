// Guards the spec naming convention, and every reference that points at one.
//
// Spec ids used to be sequential, so a number had to be *claimed*, and two
// branches in two worktrees could not see each other claim it. They clashed six
// times. The target-branch spec recorded one such collision in its own header:
// three numbers were taken while its branch was in flight, and the number it
// settled on was then double-booked anyway.
//
// The convention now needs no allocation:
//   docs/specs/<YYYYMMDD>-<HHMMSS>-SPEC-<slug>.md
// The timestamp comes from the clock when the spec is created, so two worktrees
// cannot collide. The slug is the id a human reads and code refers to.
//
// This test enforces four things, because prose could not:
//   1. every spec filename matches the convention,
//   2. slugs are unique  — the readable id stays unambiguous,
//   3. timestamps are unique — the sort key stays a key,
//   4. every `SPEC-<slug>` reference in the repo resolves to a real spec, and no
//      numeric `SPEC-<NN>` reference survives anywhere.
//
// Rule 4 is the one that pays. A renamed or deleted spec now fails a test
// instead of leaving a comment that points nowhere.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Tests run with the working directory at `app/`.
final _repoRoot = Directory.current.parent;

final _specsDir = Directory('${_repoRoot.path}/docs/specs');

/// `20260807-004600-SPEC-cli-as-client.md`, plus the sibling-document suffixes.
final _specName = RegExp(
  r'^(\d{8})-(\d{6})-SPEC-([a-z0-9]+(?:-[a-z0-9]+)*)'
  r'(-PLAN|-REVIEW|-ARCHITECTURE-AND-PLAN)?\.md$',
);

/// Files in `docs/specs/` that are not specs, and are exempt by name.
const _notSpecs = {'README.md', '20260809-000000-PORTS-P2c-P4-STATUS.md'};

/// The migration's own record. It keeps the retired numeric ids on purpose,
/// because it maps them to the names that replaced them.
const _migrationRecord = 'scripts/spec-migration';

/// Directories that hold no authored source, so scanning them is waste.
const _skipDirs = {
  '.git',
  'node_modules',
  'build',
  'dist',
  '.dart_tool',
  'Pods',
  '.pub-cache',
};

/// Trees that are checkouts of *other* repositories. makit's convention does not
/// govern them, and rewriting them would fight the tool that manages the clone.
///
/// `.agents/skills` is NOT in this list, and must not be. It holds makit's own
/// skills beside the vendored ones, so exempting the whole tree left a hole:
/// #168 added twelve first-party skills through it, and they reintroduced ten
/// retired numeric ids and one link to a spec file that no longer exists.
/// Exempt only the vendor subtree.
const _vendored = {'.pi/git', '.agents/skills/vendor', 'signatures'};

/// Extensions that can carry a spec reference in prose or in a comment.
const _textExt = {
  '.dart',
  '.ts',
  '.js',
  '.md',
  '.html',
  '.sh',
  '.yaml',
  '.yml',
  '.json',
  '.swift',
  '.entitlements',
};

List<File> _specFiles() {
  final files = _specsDir
      .listSync()
      .whereType<File>()
      .where((f) => !_notSpecs.contains(f.uri.pathSegments.last))
      .toList();
  expect(files, isNotEmpty, reason: 'no spec files found in docs/specs');
  return files;
}

/// Every text file in the repo that a reference could hide in.
Iterable<File> _sourceFiles() sync* {
  final queue = <Directory>[_repoRoot];
  while (queue.isNotEmpty) {
    final dir = queue.removeLast();
    for (final entry in dir.listSync(followLinks: false)) {
      final name = entry.uri.pathSegments.where((s) => s.isNotEmpty).last;
      final rel = entry.path.substring(_repoRoot.path.length + 1);
      if (entry is Directory) {
        if (_skipDirs.contains(name)) continue;
        if (_vendored.any((v) => rel == v || rel.startsWith('$v/'))) continue;
        if (rel == _migrationRecord) continue;
        queue.add(entry);
      } else if (entry is File) {
        final dot = name.lastIndexOf('.');
        if (dot > 0 && _textExt.contains(name.substring(dot))) yield entry;
      }
    }
  }
}

void main() {
  test('every spec filename matches the convention', () {
    final bad = <String>[];
    for (final f in _specFiles()) {
      final name = f.uri.pathSegments.last;
      if (!_specName.hasMatch(name)) bad.add(name);
    }
    expect(
      bad,
      isEmpty,
      reason:
          'expected <YYYYMMDD>-<HHMMSS>-SPEC-<slug>.md, got:\n${bad.join('\n')}',
    );
  });

  test('slugs are unique, so the readable id is unambiguous', () {
    final owners = <String, List<String>>{};
    for (final f in _specFiles()) {
      final name = f.uri.pathSegments.last;
      final m = _specName.firstMatch(name);
      if (m == null) continue;
      // A sibling (-PLAN, -REVIEW) shares its parent's slug by design.
      if (m.group(4) != null) continue;
      owners.putIfAbsent(m.group(3)!, () => []).add(name);
    }
    final clashes = owners.entries.where((e) => e.value.length > 1).toList();
    expect(
      clashes.map((e) => '${e.key}: ${e.value.join(", ")}'),
      isEmpty,
      reason: 'two specs claim one slug',
    );
  });

  test('timestamps are unique, so the sort key stays a key', () {
    final owners = <String, List<String>>{};
    for (final f in _specFiles()) {
      final name = f.uri.pathSegments.last;
      final m = _specName.firstMatch(name);
      if (m == null || m.group(4) != null) continue;
      owners.putIfAbsent('${m.group(1)}-${m.group(2)}', () => []).add(name);
    }
    final clashes = owners.entries.where((e) => e.value.length > 1).toList();
    expect(
      clashes.map((e) => '${e.key}: ${e.value.join(", ")}'),
      isEmpty,
      reason: 'two specs claim one timestamp; create the second one second',
    );
  });

  test('no numeric SPEC-<NN> reference survives anywhere', () {
    final numeric = RegExp(r'\bSPEC-\d');
    final offenders = <String>[];
    for (final f in _sourceFiles()) {
      final text = f.readAsStringSync();
      if (!numeric.hasMatch(text)) continue;
      final lines = text.split('\n');
      for (var i = 0; i < lines.length; i++) {
        if (numeric.hasMatch(lines[i])) {
          final rel = f.path.substring(_repoRoot.path.length + 1);
          offenders.add('$rel:${i + 1}: ${lines[i].trim()}');
        }
      }
    }
    expect(
      offenders.length,
      0,
      reason:
          'spec ids are slugs now, not numbers:\n${offenders.take(20).join('\n')}',
    );
  });

  test('every SPEC-<slug> reference resolves to a real spec', () {
    final known = <String>{};
    for (final f in _specFiles()) {
      final m = _specName.firstMatch(f.uri.pathSegments.last);
      if (m != null) known.add(m.group(3)!);
    }
    // A reference is `SPEC-` plus a lowercase slug. Stop at the first character
    // that cannot be part of one, so trailing prose and punctuation drop off.
    final ref = RegExp(r'\bSPEC-([a-z0-9]+(?:-[a-z0-9]+)*)');
    final dangling = <String>[];
    for (final f in _sourceFiles()) {
      final text = f.readAsStringSync();
      for (final m in ref.allMatches(text)) {
        final slug = m.group(1)!;
        // `-PLAN`/`-REVIEW` are lowercase-insensitive here: a reference to a
        // sibling still names the parent slug, so nothing extra to strip.
        if (known.contains(slug)) continue;
        // Tolerate a reference that trails into prose, e.g. "SPEC-profiles-era".
        final owner = known.firstWhere(
          (k) => slug.startsWith('$k-'),
          orElse: () => '',
        );
        if (owner.isNotEmpty) continue;
        final rel = f.path.substring(_repoRoot.path.length + 1);
        dangling.add('$rel: SPEC-$slug');
      }
    }
    expect(
      dangling.toSet().length,
      0,
      reason:
          'these reference a spec that does not exist:\n'
          '${dangling.toSet().take(20).join('\n')}',
    );
  });
}
