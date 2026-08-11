// SPEC-52 — session identity: the underlying agent session id, its transcript
// path, and the one-button copy that gets them somewhere useful.
//
// The problem this exists for: pi's own `/session` is an AGENT command, so in
// makit's composer it falls through to `store.sendMessage` and — mid-turn —
// lands in the server's pending queue, executing only after the turn it was
// meant to help you hand off. Everything here is reachable without touching the
// wire, so it answers at 100% of a turn.
//
// Layering, deliberately:
//   * `SessionIdentity`      — an app-level value type. The widgets never see
//                              `SessionDTO`'s field names, which is what let
//                              this whole file (and its pixel sign-off) land
//                              before the wire contract was frozen.
//   * `sessionIdentityText`  — pure. THE copy contract, in one place, shared
//                              verbatim by the panel, `/session` and the menus.
//                              Same seam as `context_usage.dart`'s formatters.
//   * `SessionIdentityDetails` / `showSessionIdentity` — host-agnostic body plus
//                              a sheet/popover split, mirroring
//                              `ContextUsageButton` + `ContextUsageDetails`.
//
// Design reference: `mockups/session-identity.html`.
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:phosphoricons_flutter/phosphoricons_flutter.dart';

import '../../app/theme.dart';
import '../../status/status_event.dart';
import '../../status/status_providers.dart';
import '../../store/store.dart';

// ─── per-agent vocabulary (D10) ──────────────────────────────────────────────

/// What one agent calls its session, and how its CLI resumes one.
///
/// A record in a lookup table rather than a `switch`, because
/// `docs/ENGINEERING.md`'s open/closed rule is explicit that adding an adapter
/// must not mean editing a growing `switch`.
@immutable
class AgentSessionVocabulary {
  const AgentSessionVocabulary({required this.label, required this.resume});

  /// Row label, in the agent's own noun — codex calls it a thread, so we do.
  final String label;

  /// Builds the resume command for [id], or null when this agent has none.
  final String Function(String id)? resume;
}

/// The agents whose CLI we have actually verified. Anything absent falls to
/// [_unknownAgentVocabulary] — the escape hatch that keeps this open/closed.
///
/// Both forms were checked against the real binaries: `pi --help` documents
/// `--session <path|id>`, and `codex resume --help` documents
/// `codex resume [SESSION_ID]`.
final Map<String, AgentSessionVocabulary> kAgentSessionVocabulary = {
  'pi': AgentSessionVocabulary(
    label: 'pi session',
    resume: (id) => 'pi --session $id',
  ),
  'codex': AgentSessionVocabulary(
    label: 'Thread',
    resume: (id) => 'codex resume $id',
  ),
  // codex's own legacy alias, per `transportFor` on the server.
  'codex-native': AgentSessionVocabulary(
    label: 'Thread',
    resume: (id) => 'codex resume $id',
  ),
};

/// No resume line for an agent we have never seen: inventing a CLI invocation
/// is the same failure as inventing a path (D9), just harder to notice, because
/// it looks copy-pasteable.
const _unknownAgentVocabulary = AgentSessionVocabulary(
  label: 'Agent session',
  resume: null,
);

// ─── the store seam (C2a) ────────────────────────────────────────────────────

/// Maps the store's [Session] to the [SessionIdentity] the panel watches (D19).
///
/// It returns a `SessionIdentity` with null FIELDS — never null itself — and
/// never throws. Rationale: the panel always has something to show (the makit
/// session id at minimum), so a null provider would force every call site to
/// branch on it.
///
/// An UNKNOWN session id echoes the requested id back as [makitSessionId] with
/// an unknown agent, rather than throwing or returning null: that is truthful
/// (this client holds no record of it) and, like the empty case, keeps the
/// panel openable without a null check. A draft (no `agent` yet) falls back to
/// its `pendingAgent` for the label, matching `StoreController._cacheCommands`.
final sessionIdentityProvider = Provider.family<SessionIdentity, String>((
  ref,
  sessionId,
) {
  final session = ref.watch(sessionsProvider).byId(sessionId);
  final agent = session == null
      ? ''
      : (session.agent.isNotEmpty
            ? session.agent
            : (session.pendingAgent ?? ''));
  return SessionIdentity.from(
    agent: agent,
    makitSessionId: sessionId,
    agentSessionId: session?.agentSessionId,
    transcriptPath: session?.transcriptPath,
  );
});

// ─── the value type ──────────────────────────────────────────────────────────

/// Everything the identity panel can say about one session.
///
/// Fields are nullable and each is independently absent-able: a draft has no
/// agent id, codex has no transcript path in P1, and a stub adapter has neither.
/// Absent means *omitted*, never blank and never a placeholder (D9) — a
/// fabricated path is worse than no path, because it will be pasted into a
/// prompt and the next agent will report it missing.
@immutable
class SessionIdentity {
  const SessionIdentity({
    required this.makitSessionId,
    required this.agentLabel,
    this.agentSessionId,
    this.transcriptPath,
    this.resumeCommand,
  });

  /// Derives the per-agent vocabulary (D10) and the resume command (D15).
  factory SessionIdentity.from({
    required String agent,
    required String makitSessionId,
    String? agentSessionId,
    String? transcriptPath,
  }) {
    final vocab = kAgentSessionVocabulary[agent] ?? _unknownAgentVocabulary;
    final id = _blankToNull(agentSessionId);
    return SessionIdentity(
      makitSessionId: makitSessionId,
      agentLabel: vocab.label,
      agentSessionId: id,
      transcriptPath: _blankToNull(transcriptPath),
      // The FULL id, never a prefix (D15). pi documents `--session` as taking a
      // "partial UUID" and it is tempting to shorten for display, but pi ids are
      // UUIDv7: the first 48 bits are a millisecond timestamp, so an 8-char
      // prefix pins only the top 32 bits and leaves ~65 s of collisions. Two
      // real sessions on the author's machine share `019fa9f4`, and pi does not
      // error on the ambiguity — it silently picks one and offers to fork it.
      resumeCommand: (id == null || vocab.resume == null)
          ? null
          : vocab.resume!(id),
    );
  }

  /// makit's own session uuid. Always present, and last in the panel: it is only
  /// ever needed for a bug report.
  final String makitSessionId;

  /// Row label for [agentSessionId], in the agent's own noun (D10).
  final String agentLabel;

  /// The native ACP `sessionId` / codex `threadId`. For pi this is pi's OWN
  /// session uuid — `pi-acp` reuses it as the ACP session id — so it is exactly
  /// what pi's `/session` prints and what `pi --session` accepts.
  final String? agentSessionId;

  /// Absolute path to the transcript on the SERVER's host (D4/D21). Absolute
  /// because the receiver is another agent's shell or prompt, where `~` only
  /// expands if a shell gets there first — and because the app cannot know the
  /// server host's home directory to abbreviate it honestly.
  final String? transcriptPath;

  /// A ready-to-paste resume invocation, or null when this agent has no known
  /// CLI or this session has no id.
  final String? resumeCommand;

  /// True when the agent has not produced an id yet — a draft, or a session
  /// whose back end has no native session concept.
  bool get hasAgentSession => agentSessionId != null;

  static String? _blankToNull(String? v) => (v == null || v.isEmpty) ? null : v;
}

// ─── the copy contract (D14) ─────────────────────────────────────────────────

/// The clipboard payload: one `label: value` per line, labels padded into a
/// shared column, absent rows omitted.
///
/// Pure, and the single source of this format, because it has four callers (the
/// panel, `/session`, and two menus) and a format that differs between them is
/// a bug nobody would notice.
///
/// Plain lines rather than markdown or JSON: this gets pasted into prompts,
/// commit messages, issues and terminal comments, none of which want fences or
/// escaping.
String sessionIdentityText(SessionIdentity identity) {
  final rows = <(String, String)>[
    if (identity.agentSessionId case final id?)
      (_clipboardLabel(identity.agentLabel), id),
    if (identity.transcriptPath case final path?) ('transcript', path),
    if (identity.resumeCommand case final cmd?) ('resume', cmd),
    ('makit session', identity.makitSessionId),
  ];
  final width = rows.map((r) => r.$1.length).fold(0, (a, b) => math.max(a, b));
  return rows.map((r) => '${r.$1.padRight(width)}: ${r.$2}').join('\n');
}

/// Lower-cases the display label for the clipboard, so the payload reads as
/// data (`pi session: …`) rather than as UI chrome.
String _clipboardLabel(String displayLabel) => displayLabel.toLowerCase();

// ─── the panel ───────────────────────────────────────────────────────────────

/// The one copy affordance (D5). Named so the widget test can assert there is
/// exactly one of it — four per-row buttons were designed, measured and
/// superseded, and that assertion is what stops them coming back.
const IconData kSessionIdentityCopyIcon = PhosphorIconsLight.copy;

/// Shown instead of an id row when the agent has not produced one yet. One line
/// that says so, rather than a row with an empty value (D9).
const String kSessionIdentityNoAgentLine = 'Agent not started yet';

/// Panel width on desktop, matching `kUsagePanelWidth`'s role in SPEC-37.
const double kIdentityPanelWidth = 340;

/// Margin kept clear of the window edge when clamping the desktop popover.
const double _kIdentityPanelMargin = 12;

/// Host-agnostic body of the identity panel: the rows, then one `Copy all`.
///
/// Takes a [SessionIdentity] rather than a session id so it can be rendered by
/// the QA harness, by a widget test, and by both hosts without a store. The
/// caller is responsible for watching (D19) — `showSessionIdentity` does.
class SessionIdentityDetails extends ConsumerWidget {
  const SessionIdentityDetails({super.key, required this.identity});

  final SessionIdentity identity;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final rows = <Widget>[
      if (identity.agentSessionId case final id?)
        _IdentityRow(label: identity.agentLabel, value: id)
      else
        _AbsentAgentLine(),
      if (identity.transcriptPath case final path?)
        _IdentityRow(label: 'Transcript', value: path),
      if (identity.resumeCommand case final cmd?)
        _IdentityRow(label: 'Resume with', value: cmd),
      _IdentityRow(label: 'makit session', value: identity.makitSessionId),
    ];

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(kSpace12, kSpace12, kSpace12, 0),
          child: Text(
            'Session',
            style: theme.textTheme.labelSmall?.copyWith(
              color: cs.onSurfaceVariant,
              letterSpacing: 0.8,
            ),
          ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(
            horizontal: kSpace12,
            vertical: kSpace10,
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: rows,
          ),
        ),
        _CopyAllRow(identity: identity),
      ],
    );
  }
}

/// One stacked label-over-value row.
///
/// Stacked rather than side-by-side because dropping the per-row copy column AND
/// the fixed label column returns ~116px to the value, which is what lets a
/// 36-char uuid sit on one line — and a uuid wrapped mid-string is the worst
/// thing this panel could do, since it invites a partial selection.
class _IdentityRow extends StatelessWidget {
  const _IdentityRow({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: kSpace4),
      // One semantics node for the pair (D18): a screen reader should say
      // "pi session, 019f…" rather than announcing a bare uuid with no context.
      child: Semantics(
        label: '$label, $value',
        excludeSemantics: true,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              label,
              style: theme.textTheme.labelSmall?.copyWith(
                color: cs.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: kSpace2),
            Text(value, style: theme.textTheme.bodySmall?.mono),
          ],
        ),
      ),
    );
  }
}

/// The "no id yet" line for a draft (D9).
class _AbsentAgentLine extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: kSpace4),
      child: Text(
        kSessionIdentityNoAgentLine,
        style: theme.textTheme.bodySmall?.copyWith(
          color: theme.colorScheme.onSurfaceVariant,
          fontStyle: FontStyle.italic,
        ),
      ),
    );
  }
}

/// `N lines`, or `1 line`. Trivial, and it shipped wrong: the first build read
/// "1 lines" on a stub/detached session whose only measured value is the makit
/// id. Caught by the pixel gate on the real macOS app, not by a test — the tests
/// only exercised the 4- and 3-line cases — so the 1-line case is now asserted.
String sessionIdentityLineCountLabel(int lines) =>
    lines == 1 ? '1 line' : '$lines lines';

/// `Copy all` — the panel's single copy affordance (D5).
class _CopyAllRow extends ConsumerWidget {
  const _CopyAllRow({required this.identity});

  final SessionIdentity identity;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final payload = sessionIdentityText(identity);
    final lines = payload.split('\n').length;
    return Semantics(
      button: true,
      // Says WHAT and HOW MUCH before the tap (D18): a screen-reader user cannot
      // see the toast that confirms it afterwards.
      label: 'Copy session details, ${sessionIdentityLineCountLabel(lines)}',
      excludeSemantics: true,
      child: InkWell(
        onTap: () => _copy(ref, payload, lines),
        child: Container(
          height: 38,
          padding: const EdgeInsets.symmetric(horizontal: kSpace12),
          decoration: BoxDecoration(
            border: Border(top: BorderSide(color: cs.outlineVariant)),
          ),
          child: Row(
            children: [
              Icon(kSessionIdentityCopyIcon, size: 16, color: cs.primary),
              const SizedBox(width: kSpace10),
              Text(
                'Copy all',
                style: theme.textTheme.bodyMedium?.copyWith(color: cs.primary),
              ),
              const Spacer(),
              Text(
                sessionIdentityLineCountLabel(lines),
                style: theme.textTheme.labelSmall?.copyWith(
                  color: cs.onSurfaceVariant,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _copy(WidgetRef ref, String payload, int lines) async {
    // `ref.status` is resolved BEFORE the await (SPEC-48 D3, enforced by
    // `test/status/status_lifetime_test.dart`): a `StatusCenter` never expires,
    // but `ref` dies with its widget — and this panel is a sheet that can be
    // dismissed mid-flight, which is exactly when there is bad news to deliver.
    final status = ref.status;
    // The toast is posted only AFTER the write resolves. Reporting "copied"
    // before knowing it landed would be a success claim on a waited path.
    try {
      await Clipboard.setData(ClipboardData(text: payload));
    } catch (e) {
      // `failure`, not `warning`: an action the user asked for did not happen.
      // All three copy paths in this feature (panel `Copy all`, `/session id`,
      // the tab menu) report the same way, so severity is a property of the
      // event rather than of which door was used.
      status.failure(
        'Could not copy session details',
        error: e,
        source: StatusSources.session,
      );
      return;
    }
    status.info(
      'Session details copied',
      source: StatusSources.session,
      detail: sessionIdentityLineCountLabel(lines),
    );
  }
}

/// Opens the identity panel: a modal bottom sheet on mobile, an anchored
/// popover on desktop. Same split as `ContextUsageButton` (SPEC-37).
///
/// Pass EXACTLY ONE of [sessionId] or [identity]:
///
///  * [sessionId] — the production path. The panel WATCHES
///    [sessionIdentityProvider] and rebuilds live (D19): a draft's panel can be
///    opened before the adapter assigns `agentSessionId`, and that assignment
///    fans out a fresh snapshot, so a watching panel fills in its rows while
///    open rather than lying until reopened.
///  * [identity] — the store-free path, for the QA harness and widget tests.
///
/// Exactly one, asserted, rather than "both, and one silently wins": the first
/// wiring took a required [identity] *and* an optional [sessionId], so all three
/// doors did a redundant `ref.read` whose result was then discarded. An argument
/// that is ignored depending on another argument is a trap, not an API.
Future<void> showSessionIdentity({
  required BuildContext context,
  required bool desktop,
  String? sessionId,
  SessionIdentity? identity,
}) {
  assert(
    (sessionId == null) != (identity == null),
    'pass exactly one of sessionId (watches the store) or identity (static)',
  );
  Widget body() => sessionId == null
      ? SessionIdentityDetails(identity: identity!)
      : _WatchedIdentity(sessionId: sessionId);
  if (!desktop) {
    return showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      // Scrollable because the sheet's height is capped by the window while the
      // panel's height depends on how far the transcript path wraps — which on a
      // 320pt phone is four lines.
      builder: (_) => SafeArea(child: SingleChildScrollView(child: body())),
    );
  }
  return showDialog<void>(
    context: context,
    barrierColor: Colors.transparent,
    builder: (dialogContext) {
      final window = MediaQuery.sizeOf(dialogContext);
      final cs = Theme.of(dialogContext).colorScheme;
      return Align(
        alignment: Alignment.center,
        child: Material(
          color: cs.surface,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(kRadius12),
            side: BorderSide(color: cs.outlineVariant),
          ),
          clipBehavior: Clip.antiAlias,
          // Sized to the WINDOW, not to a constant: SPEC-37 learned that a fixed
          // panel opened from a narrow split pane hangs off-screen.
          child: ConstrainedBox(
            constraints: BoxConstraints(
              maxWidth: math.min(
                kIdentityPanelWidth,
                window.width - 2 * _kIdentityPanelMargin,
              ),
              maxHeight: window.height - 2 * _kIdentityPanelMargin,
            ),
            child: SingleChildScrollView(child: body()),
          ),
        ),
      );
    },
  );
}

/// Renders [SessionIdentityDetails] against a WATCHED identity, so the open
/// panel fills in live when the agent id is assigned underneath it (D19).
class _WatchedIdentity extends ConsumerWidget {
  const _WatchedIdentity({required this.sessionId});

  final String sessionId;

  @override
  Widget build(BuildContext context, WidgetRef ref) => SessionIdentityDetails(
    identity: ref.watch(sessionIdentityProvider(sessionId)),
  );
}
