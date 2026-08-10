import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// SPEC-48 D3 — `ref.status` must be resolved **before** the first `await`.
///
/// A `StatusCenter` is never null and never expires, which is why the old
/// capture-the-`ScaffoldMessenger`-first dance is gone. But `ref` itself still
/// dies with its widget: Riverpod throws
/// `Bad state: Using "ref" when a widget is about to or has been unmounted is
/// unsafe.` — and the call sites that report outcomes are exactly the ones whose
/// widget can vanish mid-flight (a sheet whose row dropped out of a snapshot, a
/// pane closed by the very action being reported). Reaching for `ref` *after* the
/// await would therefore crash precisely when there is bad news to deliver.
///
/// So: `final status = ref.status;` at the top, then post from `status`. One line,
/// no null checks, no `mounted` guards. This test keeps it that way, because the
/// mistake is invisible until a user hits the unlucky timing.
void main() {
  test('no lib/ file reaches for ref.status after an await', () {
    final offenders = <String>[];
    for (final entity in Directory('lib').listSync(recursive: true)) {
      if (entity is! File || !entity.path.endsWith('.dart')) continue;
      final src = entity.readAsStringSync();
      for (final body in _asyncBodies(src)) {
        final firstAwait = body.text.indexOf('await ');
        if (firstAwait < 0) continue;
        final use = _refStatus.allMatches(body.text).where(
          (m) => m.start > firstAwait,
        );
        for (final m in use) {
          final line =
              src.substring(0, body.start + m.start).split('\n').length;
          offenders.add('${entity.path}:$line');
        }
      }
    }
    expect(
      offenders,
      isEmpty,
      reason:
          'Hoist it: `final status = ref.status;` before the first await, then '
          'post from `status`. Offenders:\n${offenders.join('\n')}',
    );
  });
}

final RegExp _refStatus = RegExp(r'\bref\.status\b');
final RegExp _asyncOpen = RegExp(r'async\s*\*?\s*\{');

/// Every `async { … }` body in [src], as (offset, text). Brace-matched, so a
/// nested body is reported inside its parent too — deliberately conservative:
/// a false positive costs one hoist, a false negative costs a crash.
Iterable<({int start, String text})> _asyncBodies(String src) {
  final out = <({int start, String text})>[];
  for (final m in _asyncOpen.allMatches(src)) {
    final open = src.indexOf('{', m.start);
    var depth = 0;
    for (var i = open; i < src.length; i++) {
      if (src[i] == '{') depth++;
      if (src[i] == '}') {
        depth--;
        if (depth == 0) {
          out.add((start: open + 1, text: src.substring(open + 1, i)));
          break;
        }
      }
    }
  }
  return out;
}
