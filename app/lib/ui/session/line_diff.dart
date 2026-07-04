/// Pure-Dart line-level diff for the edit-tool viewer.
///
/// No third-party dependency: a classic LCS dynamic-programming table drives a
/// removed / context / added line stream. Inputs larger than [_maxDiffLines]
/// on either side skip the O(n*m) table and fall back to the old whole-block
/// behaviour (all removed, then all added) so a giant edit can't blow up.
library;

/// Classification of a single line in a computed diff.
enum DiffKind { context, added, removed }

/// One line of a diff: its [kind] and the (newline-free) [text].
class DiffLine {
  const DiffLine(this.kind, this.text);

  final DiffKind kind;
  final String text;

  @override
  bool operator ==(Object other) =>
      other is DiffLine && other.kind == kind && other.text == text;

  @override
  int get hashCode => Object.hash(kind, text);

  @override
  String toString() => 'DiffLine($kind, ${text.length} chars)';
}

/// Above this many lines on either side we skip the LCS table.
const int _maxDiffLines = 2000;

/// Split [text] into lines. An empty string is zero lines (not one blank
/// line) so an empty side reads as a pure add/remove.
List<String> _splitLines(String text) => text.isEmpty ? const [] : text.split('\n');

/// Compute a line-level diff between [oldText] and [newText].
///
/// Identical inputs produce all-context lines; an empty old side is all added
/// and an empty new side is all removed. When either side exceeds
/// [_maxDiffLines], returns all removed lines followed by all added lines.
List<DiffLine> computeLineDiff(String oldText, String newText) {
  final oldLines = _splitLines(oldText);
  final newLines = _splitLines(newText);

  if (oldLines.length > _maxDiffLines || newLines.length > _maxDiffLines) {
    return [
      for (final line in oldLines) DiffLine(DiffKind.removed, line),
      for (final line in newLines) DiffLine(DiffKind.added, line),
    ];
  }

  final n = oldLines.length;
  final m = newLines.length;

  // lcs[i][j] = length of the longest common subsequence of oldLines[i..]
  // and newLines[j..]. Row/column n/m stay zero as the base case.
  final lcs = List.generate(n + 1, (_) => List<int>.filled(m + 1, 0));
  for (var i = n - 1; i >= 0; i--) {
    for (var j = m - 1; j >= 0; j--) {
      lcs[i][j] = oldLines[i] == newLines[j]
          ? lcs[i + 1][j + 1] + 1
          : (lcs[i + 1][j] >= lcs[i][j + 1] ? lcs[i + 1][j] : lcs[i][j + 1]);
    }
  }

  final result = <DiffLine>[];
  var i = 0;
  var j = 0;
  while (i < n && j < m) {
    if (oldLines[i] == newLines[j]) {
      result.add(DiffLine(DiffKind.context, oldLines[i]));
      i++;
      j++;
    } else if (lcs[i + 1][j] >= lcs[i][j + 1]) {
      result.add(DiffLine(DiffKind.removed, oldLines[i]));
      i++;
    } else {
      result.add(DiffLine(DiffKind.added, newLines[j]));
      j++;
    }
  }
  for (; i < n; i++) {
    result.add(DiffLine(DiffKind.removed, oldLines[i]));
  }
  for (; j < m; j++) {
    result.add(DiffLine(DiffKind.added, newLines[j]));
  }
  return result;
}
