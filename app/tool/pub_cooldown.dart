// Pub "cooldown" gate — see SECURITY.md §8.
//
// pub has no equivalent of pnpm's `minimumReleaseAge` (server/SECURITY.md §3),
// so we enforce a minimum version age here too: a change may not introduce a
// pubspec.lock version that was published to pub.dev less than 3 days ago.
// This catches the large class of supply-chain attacks where a malicious
// version is published, then detected and unpublished within days.
//
// Keep this window in sync with `minimumReleaseAge` in
// `server/pnpm-workspace.yaml` — see SECURITY.md §8.
//
// Only versions that differ from the baseline lockfile (`COOLDOWN_BASE_REF`,
// default `HEAD`) are checked — like pnpm, the window gates what you newly
// install, not what is already locked.
//
// This gate fails CLOSED: anything it cannot verify (unparseable lockfile,
// unusable baseline ref, or a changed package whose publish date pub.dev will
// not confirm) is reported as "could not verify" rather than passing.
//
// Usage (from app/):
//   dart run tool/pub_cooldown.dart
//
// Exit codes: 0 = clean, 1 = violation, 2 = could not verify.
import 'dart:convert';
import 'dart:io';

import 'package:yaml/yaml.dart';

/// Cooldown window. Mirrors `minimumReleaseAge: 4320` (3d) in
/// `server/pnpm-workspace.yaml` — see SECURITY.md §8.
const cooldownWindow = Duration(days: 3);

/// Packages allowed to skip the cooldown, each with a justification.
/// Mirrors `minimumReleaseAgeExclude` in `server/pnpm-workspace.yaml`.
/// Adding an entry is a security review — keep the reason specific.
const cooldownExempt = <String, String>{
  // (empty — add as needed, e.g. a transitive the pinned Flutter SDK forces)
};

/// The all-zero sha git reports as the "before" commit when a branch is first
/// pushed. It resolves to nothing, so it cannot serve as a baseline.
const _zeroSha = '0000000000000000000000000000000000000000';

/// A resolved package version that is younger than the cooldown window.
class CooldownViolation {
  CooldownViolation({
    required this.name,
    required this.version,
    required this.published,
    required this.age,
  });

  final String name;
  final String version;
  final DateTime published;
  final Duration age;

  @override
  String toString() =>
      '$name $version published ${age.inDays}d ago ($published)';
}

/// Extracts `name -> version` for every `source: hosted` entry in a
/// `pubspec.lock`. SDK- and path-sourced entries are skipped (they have no
/// pub.dev publish date; non-hosted sources are barred by SECURITY.md §1–2).
///
/// Throws [FormatException] if the lockfile is not the shape pub generates —
/// a silent empty result would disable the gate.
Map<String, String> parseHostedPackages(String lockfile) {
  final Object? doc;
  try {
    doc = loadYaml(lockfile);
  } on YamlException catch (e) {
    throw FormatException('pubspec.lock is not valid YAML: $e');
  }
  if (doc is! Map) {
    throw const FormatException('pubspec.lock is not a YAML map');
  }
  final packages = doc['packages'];
  if (packages == null) return {};
  if (packages is! Map) {
    throw const FormatException('pubspec.lock `packages:` is not a map');
  }

  final result = <String, String>{};
  for (final entry in packages.entries) {
    final name = entry.key;
    final body = entry.value;
    if (name is! String || body is! Map) {
      throw FormatException('malformed package entry for "${entry.key}"');
    }
    if (body['source'] != 'hosted') continue;
    final version = body['version'];
    if (version == null) {
      throw FormatException('hosted package "$name" has no version');
    }
    result[name] = version.toString();
  }
  return result;
}

/// Returns the entries of [current] that are new or version-bumped relative to
/// [baseline] — i.e. the versions a change actually introduces. Mirrors pnpm,
/// where `minimumReleaseAge` gates resolution of new versions and leaves
/// already-locked ones alone.
Map<String, String> changedVersions({
  required Map<String, String> current,
  required Map<String, String> baseline,
}) {
  final changed = <String, String>{};
  for (final entry in current.entries) {
    if (baseline[entry.key] != entry.value) changed[entry.key] = entry.value;
  }
  return changed;
}

/// Normalises `COOLDOWN_BASE_REF`. Returns `HEAD` when unset/blank, or null
/// when the value cannot be a baseline.
///
/// A blank value must not be passed to git: `git show ':./pubspec.lock'`
/// succeeds and returns the *index* copy of the file, which would make the
/// baseline identical to the working tree and silently pass the gate.
String? resolveBaseRef(String? raw) {
  final ref = raw?.trim() ?? '';
  if (ref.isEmpty) return 'HEAD';
  if (ref == _zeroSha) return null;
  return ref;
}

/// Changed, non-exempt packages that pub.dev would not confirm a publish date
/// for. These cannot be judged, so callers must fail rather than skip them.
List<String> unverifiedPackages({
  required Map<String, String> resolved,
  required Map<String, DateTime> publishedAt,
  Map<String, String> exempt = const {},
}) {
  final missing =
      resolved.keys
          .where((name) => !exempt.containsKey(name))
          .where((name) => !publishedAt.containsKey(name))
          .toList()
        ..sort();
  return missing;
}

/// Returns the resolved packages whose publish date is inside [cooldown],
/// youngest first. Packages absent from [publishedAt] are skipped here — use
/// [unverifiedPackages] to fail on those.
List<CooldownViolation> findViolations({
  required Map<String, String> resolved,
  required Map<String, DateTime> publishedAt,
  required DateTime now,
  required Duration cooldown,
  Map<String, String> exempt = const {},
}) {
  final violations = <CooldownViolation>[];
  for (final entry in resolved.entries) {
    if (exempt.containsKey(entry.key)) continue;
    final published = publishedAt[entry.key];
    if (published == null) continue;
    final age = now.difference(published);
    if (age < cooldown) {
      violations.add(
        CooldownViolation(
          name: entry.key,
          version: entry.value,
          published: published,
          age: age,
        ),
      );
    }
  }
  violations.sort((a, b) => a.age.compareTo(b.age));
  return violations;
}

/// Fetches the publish date of [version] of [name] from the pub.dev API.
/// Returns null when pub.dev does not confirm the version (any non-200, or a
/// response without a `published` field) — the caller treats that as
/// unverifiable, not as a pass.
Future<DateTime?> _fetchPublished(
  HttpClient client,
  String name,
  String version,
) async {
  final request = await client.getUrl(
    Uri.parse('https://pub.dev/api/packages/$name/versions/$version'),
  );
  request.headers.set(HttpHeaders.acceptHeader, 'application/json');
  final response = await request.close();
  if (response.statusCode != 200) {
    await response.drain<void>();
    return null;
  }
  final body = jsonDecode(await response.transform(utf8.decoder).join());
  if (body is! Map) return null;
  final published = body['published'];
  if (published is! String) return null;
  return DateTime.parse(published).toUtc();
}

/// Reads `pubspec.lock` at [ref]. Returns null when git can't supply it
/// (unreachable ref, shallow clone, file not committed there).
String? _baselineLockfile(String ref) {
  try {
    final result = Process.runSync('git', ['show', '$ref:./pubspec.lock']);
    if (result.exitCode != 0) return null;
    final out = result.stdout;
    return out is String && out.isNotEmpty ? out : null;
  } on ProcessException {
    return null;
  }
}

Future<int> main() async {
  final lockfile = File('pubspec.lock');
  if (!lockfile.existsSync()) {
    stderr.writeln('pubspec.lock not found — run from app/');
    return exitCode = 2;
  }

  final rawRef = Platform.environment['COOLDOWN_BASE_REF'];
  final baseRef = resolveBaseRef(rawRef);
  if (baseRef == null) {
    stderr.writeln(
      'COOLDOWN_BASE_REF="$rawRef" cannot be a baseline (no parent commit?) '
      '— cooldown not verified',
    );
    return exitCode = 2;
  }

  final baseline = _baselineLockfile(baseRef);
  if (baseline == null) {
    stderr.writeln(
      'could not read pubspec.lock at $baseRef — cooldown not verified',
    );
    return exitCode = 2;
  }

  final Map<String, String> resolved;
  try {
    resolved = changedVersions(
      current: parseHostedPackages(lockfile.readAsStringSync()),
      baseline: parseHostedPackages(baseline),
    );
  } on FormatException catch (e) {
    stderr.writeln('could not parse a lockfile: ${e.message}');
    return exitCode = 2;
  }
  if (resolved.isEmpty) {
    stdout.writeln('no lockfile version changes vs $baseRef');
    return exitCode = 0;
  }

  final client = HttpClient();
  final publishedAt = <String, DateTime>{};
  try {
    await Future.wait(
      resolved.entries.where((e) => !cooldownExempt.containsKey(e.key)).map((
        e,
      ) async {
        final published = await _fetchPublished(client, e.key, e.value);
        if (published != null) publishedAt[e.key] = published;
      }),
    );
  } on Exception catch (e) {
    stderr.writeln('could not reach pub.dev: $e');
    return exitCode = 2;
  } finally {
    client.close();
  }

  final unverified = unverifiedPackages(
    resolved: resolved,
    publishedAt: publishedAt,
    exempt: cooldownExempt,
  );
  if (unverified.isNotEmpty) {
    stderr.writeln(
      'pub.dev did not confirm a publish date for: ${unverified.join(', ')} '
      '— cooldown not verified',
    );
    return exitCode = 2;
  }

  final violations = findViolations(
    resolved: resolved,
    publishedAt: publishedAt,
    now: DateTime.now().toUtc(),
    cooldown: cooldownWindow,
    exempt: cooldownExempt,
  );

  if (violations.isEmpty) {
    stdout.writeln(
      '${resolved.length} changed package(s), all published more '
      'than ${cooldownWindow.inDays}d ago',
    );
    return exitCode = 0;
  }
  stderr.writeln(
    'this change introduces versions younger than the '
    '${cooldownWindow.inDays}d cooldown (SECURITY.md §8):',
  );
  for (final v in violations) {
    stderr.writeln('  $v');
  }
  return exitCode = 1;
}
