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
        final use = _refStatus
            .allMatches(body.text)
            .where((m) => m.start > firstAwait);
        for (final m in use) {
          final line = src
              .substring(0, body.start + m.start)
              .split('\n')
              .length;
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

  test('a brace in a string or a comment does not end a body early', () {
    // The scanner used to count raw braces, so either line below closed the
    // body and hid the `ref.status` after the await — a silent false negative
    // in the guard that is supposed to prevent a crash.
    const src = '''
void f() async {
  await g();
  final brace = '}';
  // }
  ref.status.info('late');
}
''';
    final bodies = _asyncBodies(src).toList();
    expect(bodies, hasLength(1));
    expect(bodies.single.text, contains('ref.status'));
  });
}

final RegExp _refStatus = RegExp(r'\bref\.status\b');
final RegExp _asyncOpen = RegExp(r'async\s*\*?\s*\{');

/// Every `async { … }` body in [src], as (offset, text).
///
/// Brace-matched over a copy with comment and string-literal *contents* blanked,
/// so a lone `}` in a string or a comment cannot close a body early. It could
/// before, and the effect was the opposite of what this guard is for: the body
/// ended at the stray brace and every later `ref.status` in that function went
/// unseen. Offsets are preserved by the blanking, so matches still map onto the
/// original source.
///
/// A nested body is reported inside its parent too — deliberately conservative:
/// a false positive costs one hoist, a false negative costs a crash.
Iterable<({int start, String text})> _asyncBodies(String src) {
  final scan = _blankStringsAndComments(src);
  final out = <({int start, String text})>[];
  for (final m in _asyncOpen.allMatches(scan)) {
    final open = scan.indexOf('{', m.start);
    var depth = 0;
    for (var i = open; i < scan.length; i++) {
      if (scan[i] == '{') depth++;
      if (scan[i] == '}') {
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

/// [src] with the contents of `//` comments, `/* */` comments and string
/// literals (single, double, triple-quoted, escapes included) replaced by
/// spaces. Same length, same newlines, same offsets — only the braces that were
/// never code are gone.
String _blankStringsAndComments(String src) {
  final out = src.split('');
  var i = 0;
  void blank(int at) {
    if (src[at] != '\n') out[at] = ' ';
  }

  while (i < src.length) {
    final c = src[i];
    if (c == '/' && i + 1 < src.length && src[i + 1] == '/') {
      while (i < src.length && src[i] != '\n') {
        blank(i);
        i++;
      }
      continue;
    }
    if (c == '/' && i + 1 < src.length && src[i + 1] == '*') {
      blank(i);
      blank(i + 1);
      i += 2;
      while (i < src.length &&
          !(src[i] == '*' && i + 1 < src.length && src[i + 1] == '/')) {
        blank(i);
        i++;
      }
      if (i < src.length) {
        blank(i);
        if (i + 1 < src.length) blank(i + 1);
        i += 2;
      }
      continue;
    }
    if (c == "'" || c == '"') {
      final triple = src.startsWith(c * 3, i);
      final quote = triple ? c * 3 : c;
      i += quote.length;
      while (i < src.length) {
        if (src[i] == r'\') {
          blank(i);
          if (i + 1 < src.length) blank(i + 1);
          i += 2;
          continue;
        }
        if (src.startsWith(quote, i)) {
          i += quote.length;
          break;
        }
        blank(i);
        i++;
      }
      continue;
    }
    i++;
  }
  return out.join();
}
