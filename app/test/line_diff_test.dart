/// Tests for the pure-Dart line-level diff used by the edit-tool viewer.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:makit/ui/session/line_diff.dart';

/// Convenience: collapse a diff into a compact string like `=a -b +c` so the
/// expectations below read like the rendered gutter.
String _sketch(List<DiffLine> lines) => lines
    .map(
      (l) => switch (l.kind) {
        DiffKind.context => '=${l.text}',
        DiffKind.removed => '-${l.text}',
        DiffKind.added => '+${l.text}',
      },
    )
    .join(' ');

void main() {
  group('DiffLine value equality', () {
    test('equal kind + text compare equal and share a hashCode', () {
      const a = DiffLine(DiffKind.added, 'x');
      const b = DiffLine(DiffKind.added, 'x');
      expect(a, equals(b));
      expect(a.hashCode, equals(b.hashCode));
    });

    test('different kind or text compare unequal', () {
      expect(
        const DiffLine(DiffKind.added, 'x'),
        isNot(equals(const DiffLine(DiffKind.removed, 'x'))),
      );
      expect(
        const DiffLine(DiffKind.added, 'x'),
        isNot(equals(const DiffLine(DiffKind.added, 'y'))),
      );
    });
  });

  group('computeLineDiff', () {
    test('identical text yields all context lines', () {
      final diff = computeLineDiff('a\nb\nc', 'a\nb\nc');
      expect(diff, const [
        DiffLine(DiffKind.context, 'a'),
        DiffLine(DiffKind.context, 'b'),
        DiffLine(DiffKind.context, 'c'),
      ]);
    });

    test('empty old yields all added lines', () {
      final diff = computeLineDiff('', 'a\nb');
      expect(diff, const [
        DiffLine(DiffKind.added, 'a'),
        DiffLine(DiffKind.added, 'b'),
      ]);
    });

    test('empty new yields all removed lines', () {
      final diff = computeLineDiff('a\nb', '');
      expect(diff, const [
        DiffLine(DiffKind.removed, 'a'),
        DiffLine(DiffKind.removed, 'b'),
      ]);
    });

    test('both empty yields nothing', () {
      expect(computeLineDiff('', ''), isEmpty);
    });

    test('pure insertion in the middle keeps surrounding context', () {
      final diff = computeLineDiff('a\nc', 'a\nb\nc');
      expect(_sketch(diff), '=a +b =c');
    });

    test('pure deletion keeps surrounding context', () {
      final diff = computeLineDiff('a\nb\nc', 'a\nc');
      expect(_sketch(diff), '=a -b =c');
    });

    test('mixed change reports removed then added', () {
      final diff = computeLineDiff('a\nb\nc', 'a\nB\nc');
      expect(_sketch(diff), '=a -b +B =c');
    });

    test('trailing newline is treated as a distinct blank line', () {
      // 'a\n' -> ['a', ''];  'a' -> ['a'].  The blank tail is a removed line.
      final diff = computeLineDiff('a\n', 'a');
      expect(_sketch(diff), '=a -');
    });

    test('caps huge inputs: falls back to all-removed then all-added', () {
      final oldText = List.generate(2001, (i) => 'old$i').join('\n');
      const newText = 'new0\nnew1';
      final diff = computeLineDiff(oldText, newText);

      expect(diff.length, 2003);
      expect(diff.first, const DiffLine(DiffKind.removed, 'old0'));
      expect(diff[2000], const DiffLine(DiffKind.removed, 'old2000'));
      expect(diff[2001], const DiffLine(DiffKind.added, 'new0'));
      expect(diff.last, const DiffLine(DiffKind.added, 'new1'));
      // No context lines are produced on the fallback path.
      expect(diff.any((l) => l.kind == DiffKind.context), isFalse);
    });
  });
}
