/// The docs vocabulary (SPEC-doc-preview): pure helpers + the kind accents, so the row,
/// the glyph, the popover and the preview toolbar cannot drift apart. No
/// widgets — the colours live here, the pixels live in the widgets.
library;

import 'package:flutter/material.dart';

import '../../app/theme.dart';
import '../../store/docs.dart';

/// HTML kind accent — warm (mockup `--html`). Not in the theme ramp: it is a
/// per-kind signal, paired with [kDocMdColor] so the two read as a set.
const Color kDocHtmlColor = Color(0xFFE8A33D);

/// Markdown kind accent — cool (mockup `--md`).
const Color kDocMdColor = Color(0xFF7DB8E8);

/// The accent for a doc kind (D4 glyph tint). One source for glyph + chip.
Color docKindColor(DocKind kind) => switch (kind) {
  DocKind.html => kDocHtmlColor,
  DocKind.md => kDocMdColor,
};

/// The short uppercase kind label the chip shows.
String docKindLabel(DocKind kind) => switch (kind) {
  DocKind.html => 'HTML',
  DocKind.md => 'MD',
};

/// A human file size: bytes under 1 KB, KB under 1 MB, then MB with one
/// decimal. `41 KB`, `5.0 MB` — never a raw byte count on a 375 pt row.
String docSizeLabel(int bytes) {
  if (bytes < 1024) return '$bytes B';
  if (bytes < 1024 * 1024) return '${(bytes / 1024).round()} KB';
  return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
}

/// "2 min ago" / "3 h ago" / "yesterday" / "3 days ago"; "just now" under a
/// minute. Injected clock so the row is deterministic in tests. Never a
/// fabricated future ("in 3 min") — a negative delta reads as "just now".
String docRelativeTime(int modifiedAt, {required int nowMs}) {
  final ms = nowMs - modifiedAt;
  if (ms < 60 * 1000) return 'just now';
  final mins = ms ~/ (60 * 1000);
  if (mins < 60) return '$mins min ago';
  final hours = mins ~/ 60;
  if (hours < 24) return '$hours h ago';
  final days = hours ~/ 24;
  if (days < 2) return 'yesterday';
  return '$days days ago';
}

/// The tint tokens for a docStatus badge (D14). `draft` warns amber,
/// `implemented` is the add-green, anything else stays a neutral outline —
/// the repo writes other statuses, and mislabelling them would be a guess.
/// Matched on the first word, case-insensitive.
({Color fill, Color text}) docStatusTone(ColorScheme cs, String status) {
  final first = status.trim().toLowerCase().split(RegExp(r'\s+')).first;
  return switch (first) {
    'draft' => (
      fill: kStatusWarning.withValues(alpha: 0.15),
      text: cs.statusWarningText,
    ),
    'implemented' => (
      fill: kDiffAdd.withValues(alpha: 0.14),
      text: cs.diffAddText,
    ),
    _ => (fill: cs.surfaceContainerHigh, text: cs.onSurfaceVariant),
  };
}

/// The badge's short label: the status' first clause, lower-cased (mockup
/// `draft` / `implemented`).
String docStatusLabel(String status) =>
    status.trim().toLowerCase().split(RegExp(r'\s+')).first;
