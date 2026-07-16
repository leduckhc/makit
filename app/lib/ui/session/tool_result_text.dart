/// Pure tool-result text helpers — no Flutter dependency so they can be unit
/// tested directly. Extracted from `tool_renderers.dart` (SPEC-19).
library;

import 'dart:convert';

/// Tool results arrive as one or more concatenated MCP-style envelopes, e.g.
/// `{"content":[{"type":"text","text":"..."}],"details":{}}`. Extract and
/// concatenate the human-readable text. Falls back to the raw string when it
/// isn't in that shape (plain stdout, file contents, etc.).
String extractToolResultText(String raw) {
  final trimmed = raw.trim();
  if (!trimmed.startsWith('{') && !trimmed.startsWith('[')) return raw;
  final buf = StringBuffer();
  var matched = false;
  for (final chunk in _splitJsonValues(trimmed)) {
    dynamic decoded;
    try {
      decoded = jsonDecode(chunk);
    } catch (_) {
      return raw; // Not the envelope shape — show it verbatim.
    }
    if (decoded is Map && decoded['content'] is List) {
      matched = true;
      for (final part in decoded['content'] as List) {
        if (part is Map && part['type'] == 'text' && part['text'] is String) {
          buf.write(part['text'] as String);
        }
      }
    }
  }
  return matched ? buf.toString() : raw;
}

/// Split a string of back-to-back top-level JSON values (e.g. `{...}{...}`)
/// into their individual source substrings, honouring braces/brackets inside
/// strings and escapes.
List<String> _splitJsonValues(String s) {
  final out = <String>[];
  var depth = 0;
  var start = -1;
  var inString = false;
  var escaped = false;
  for (var i = 0; i < s.length; i++) {
    final ch = s[i];
    if (inString) {
      if (escaped) {
        escaped = false;
      } else if (ch == r'\') {
        escaped = true;
      } else if (ch == '"') {
        inString = false;
      }
      continue;
    }
    switch (ch) {
      case '"':
        inString = true;
      case '{':
      case '[':
        if (depth == 0) start = i;
        depth++;
      case '}':
      case ']':
        depth--;
        if (depth == 0 && start >= 0) {
          out.add(s.substring(start, i + 1));
          start = -1;
        }
    }
  }
  return out;
}

/// Render a single arg value for display. Scalars show as-is; nested
/// structures fall back to compact JSON so the row stays readable.
String valueString(dynamic value) {
  if (value == null) return '';
  if (value is String || value is num || value is bool) return value.toString();
  try {
    return jsonEncode(value);
  } catch (_) {
    return value.toString();
  }
}
