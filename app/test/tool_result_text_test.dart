import 'package:flutter_test/flutter_test.dart';
import 'package:makit/ui/session/tool_result_text.dart';

void main() {
  group('extractToolResultText', () {
    test('returns plain (non-JSON) text verbatim', () {
      expect(
        extractToolResultText('exit 0\nstdout here'),
        'exit 0\nstdout here',
      );
    });

    test('extracts text from a single MCP-style envelope', () {
      const raw = '{"content":[{"type":"text","text":"hello"}],"details":{}}';
      expect(extractToolResultText(raw), 'hello');
    });

    test('concatenates text across back-to-back envelopes', () {
      const raw =
          '{"content":[{"type":"text","text":"one\\n"}]}'
          '{"content":[{"type":"text","text":"two"}]}';
      expect(extractToolResultText(raw), 'one\ntwo');
    });

    test('ignores non-text content parts', () {
      const raw =
          '{"content":[{"type":"image","data":"x"},{"type":"text","text":"ok"}]}';
      expect(extractToolResultText(raw), 'ok');
    });

    test('returns the raw string verbatim when JSON decode fails', () {
      // Looks like an envelope (starts with `{`) but is malformed — the
      // silent `return raw` fallback must surface the original text, not "".
      const raw = '{"content":[{"type":"text","text":"unterminated';
      expect(extractToolResultText(raw), raw);
    });

    test(
      'returns raw when a well-formed JSON value is not the envelope shape',
      () {
        const raw = '{"foo":"bar"}';
        expect(extractToolResultText(raw), raw);
      },
    );

    test('handles braces inside string values without splitting mid-value', () {
      const raw = '{"content":[{"type":"text","text":"a } b { c"}]}';
      expect(extractToolResultText(raw), 'a } b { c');
    });
  });

  group('valueString', () {
    test('renders null as empty string', () {
      expect(valueString(null), '');
    });

    test('renders scalars as-is', () {
      expect(valueString('hi'), 'hi');
      expect(valueString(42), '42');
      expect(valueString(true), 'true');
    });

    test('renders nested structures as compact JSON', () {
      expect(valueString({'a': 1, 'b': 2}), '{"a":1,"b":2}');
      expect(valueString([1, 2, 3]), '[1,2,3]');
    });
  });

  // Rule 3 of the expanded body (mockups/tool-expanded-body.html §5): a result
  // that is one short line is a FACT — it belongs in the dim key/value strip,
  // not in a syntax-highlighted panel with a copy button. `307 lines` was being
  // rendered as source code, digits tinted teal.
  group('isFactResult', () {
    test('a short single line is a fact', () {
      expect(isFactResult('307 lines'), isTrue);
      expect(isFactResult('No matches found'), isTrue);
      expect(isFactResult('exit 0'), isTrue);
      expect(isFactResult('  ok  '), isTrue);
    });

    test('anything with a newline is a payload', () {
      expect(isFactResult('line one\nline two'), isFalse);
      expect(isFactResult('one line\n'), isTrue, reason: 'trailing \\n only');
    });

    test('a long single line is a payload', () {
      expect(isFactResult('x' * 80), isTrue);
      expect(isFactResult('x' * 81), isFalse);
    });

    test('empty is neither — callers drop it', () {
      expect(isFactResult(''), isFalse);
      expect(isFactResult('   '), isFalse);
    });
  });
}
