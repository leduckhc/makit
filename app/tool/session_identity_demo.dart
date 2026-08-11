// Interactive QA harness for the SPEC-51 session-identity panel. Seeded data,
// no server, no agent binary.
//
//   cd app && flutter run -d macos       --debug -t tool/session_identity_demo.dart
//   cd app && flutter run -d "iPhone 17" --debug -t tool/session_identity_demo.dart
//
// Every panel is the shipped `SessionIdentityDetails` on the real theme, so row
// pitch, wrap behaviour and mono metrics are the product's — not an
// approximation. The design reference is `mockups/session-identity.html`.
//
// Why a harness at all, when there are 16 widget tests: D5's justification is a
// MEASURED claim — dropping the per-row copy column returned ~116px to each
// value, which is what lets a 36-char uuid sit on one line instead of wrapping
// mid-string. A widget test cannot verify that on the real platform at the real
// text scale; `cua-driver` reading the accessibility tree can.
//
// No controls: every state renders in one pass (see the note in build). The stamp
// reports the live state so a STALE macOS bundle is detectable — the trap that
// once made a whole QA pass grade the wrong theme.
//
// Not part of the app or the test suite: kept out of `lib/` so neither can
// import it.
import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:makit/app/theme.dart';
import 'package:makit/ui/session/session_identity.dart';

// ── seeded identities ────────────────────────────────────────────────────────
//
// Real captures, so the wrap behaviour on this page is the wrap behaviour in
// production. `kPiId` and `kCollidingId` share their first 8 characters and both
// exist in one real sessions directory — the evidence behind D15.

const kPiId = '019ff121-1cc1-7c60-bc40-65890c87e6ff';
const kPiPath =
    '/Users/le/.pi/agent/sessions/'
    '--Users-le-.worktrees-makit-feat-get-session-id--/'
    '2026-08-11T14-01-46-945Z_019ff121-1cc1-7c60-bc40-65890c87e6ff.jsonl';
const kCodexId = '019efe19-101b-7183-8345-47f61b78dd61';
const kMakitId = '7c9e6d5a-1f42-4b8e-9a01-2d3f4e5a6b7c';

class _Case {
  const _Case(this.title, this.identity);
  final String title;
  final SessionIdentity identity;
}

final List<_Case> _cases = [
  _Case(
    'pi · live, transcript resolved',
    SessionIdentity.from(
      agent: 'pi',
      makitSessionId: kMakitId,
      agentSessionId: kPiId,
      transcriptPath: kPiPath,
    ),
  ),
  _Case(
    'pi · transcript unresolved (D9 — row omitted)',
    SessionIdentity.from(
      agent: 'pi',
      makitSessionId: kMakitId,
      agentSessionId: kPiId,
    ),
  ),
  _Case(
    'codex · thread, no path in P1 (D16)',
    SessionIdentity.from(
      agent: 'codex',
      makitSessionId: kMakitId,
      agentSessionId: kCodexId,
    ),
  ),
  _Case(
    'unknown agent · no resume row (D10 default)',
    SessionIdentity.from(
      agent: 'stub',
      makitSessionId: kMakitId,
      agentSessionId: kPiId,
    ),
  ),
  _Case(
    'draft · agent not started (D9)',
    SessionIdentity.from(agent: 'pi', makitSessionId: kMakitId),
  ),
];

void main() {
  // Force the semantics tree on, permanently, for two reasons:
  //
  //  1. Flutter only publishes accessibility nodes when it detects an assistive
  //     client. `cua-driver` reads the AX tree without announcing itself as one,
  //     so without this the window exposes nothing but the menu bar and the
  //     pixel gate has nothing to measure. (Learned the hard way here.)
  //  2. D18 is a locked decision, so the semantics labels are part of what this
  //     harness exists to verify — not an afterthought.
  WidgetsFlutterBinding.ensureInitialized();
  SemanticsBinding.instance.ensureSemantics();
  runApp(const ProviderScope(child: _Demo()));
}

class _Demo extends StatelessWidget {
  const _Demo();

  /// The tightest width is where every risk lives (a 36-char uuid against a
  /// 320 pt phone), so it is the width rendered for BOTH themes. The wider
  /// columns only ever have more room.
  static const double _phone = 320;

  @override
  Widget build(BuildContext context) {
    // Deliberately input-free: both themes and all five cases render in ONE
    // pass. Driving a Flutter macOS window by synthesized CGEvent did not
    // register (verified: the staleness stamp never changed), and a QA gate that
    // depends on a click landing is a QA gate that silently measures the wrong
    // state. Rendering every combination removes the dependency entirely.
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: makitDarkTheme,
      home: Scaffold(
        backgroundColor: const Color(0xFF0E0E0E),
        body: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _stamp(),
              _band(makitDarkTheme, 'DARK', _phone),
              _band(makitLightTheme, 'LIGHT', _phone),
              _band(makitDarkTheme, 'DARK · 375pt', 375),
            ],
          ),
        ),
      ),
    );
  }

  /// Proof the bundle is not stale: it names every state on the page, so a
  /// screenshot that disagrees with the source is obvious at a glance.
  Widget _stamp() => Builder(
    builder: (context) => Container(
      padding: const EdgeInsets.symmetric(
        horizontal: kSpace12,
        vertical: kSpace8,
      ),
      color: makitDarkTheme.colorScheme.surfaceContainerLow,
      child: Text(
        'session identity · dark+light · ${_phone.round()}pt & 375pt · '
        '${_cases.length} cases · no input required',
        style: makitDarkTheme.textTheme.labelMedium,
      ),
    ),
  );

  Widget _band(ThemeData theme, String title, double width) => Container(
    color: theme.colorScheme.surfaceContainerLowest,
    padding: const EdgeInsets.fromLTRB(kSpace16, kSpace12, kSpace16, kSpace20),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(bottom: kSpace10),
          child: Text(
            title,
            style: theme.textTheme.labelMedium?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
              letterSpacing: 1.2,
            ),
          ),
        ),
        Theme(
          data: theme,
          child: Wrap(
            spacing: kSpace16,
            runSpacing: kSpace16,
            crossAxisAlignment: WrapCrossAlignment.start,
            children: [for (final c in _cases) _panel(theme, c, width)],
          ),
        ),
      ],
    ),
  );

  Widget _panel(ThemeData theme, _Case c, double width) => SizedBox(
    width: width,
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.only(bottom: kSpace6),
          child: Text(
            c.title.toUpperCase(),
            style: theme.textTheme.labelSmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
              letterSpacing: 0.7,
            ),
          ),
        ),
        DecoratedBox(
          decoration: BoxDecoration(
            color: theme.colorScheme.surface,
            border: Border.all(color: theme.colorScheme.outlineVariant),
            borderRadius: BorderRadius.circular(kRadius12),
          ),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(kRadius12),
            child: SessionIdentityDetails(identity: c.identity),
          ),
        ),
      ],
    ),
  );
}
