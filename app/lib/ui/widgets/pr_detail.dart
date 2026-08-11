/// The detail layer behind the next-step bar (direction B1).
///
/// B1's bar shows one fact and a `+n more` count. This is what that count opens:
/// the full ordered fact list, each row with its own remedy, then the raw CI
/// check list. Nothing here is new information — it is [PrStatus.signals]
/// rendered in full — but it is where the *secondary* facts become actionable,
/// which is the trade B1 makes for a quiet bar.
///
/// One implementation for both platforms. Desktop opens it as a dialog anchored
/// to nothing in particular (a hover popover cannot hold buttons); mobile opens
/// the same body as a bottom sheet.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:phosphoricons_flutter/phosphoricons_flutter.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../app/theme.dart';
import '../../status/status_event.dart';
import '../../status/status_providers.dart';
import '../../store/models.dart';
import '../../store/prefs/preference_entries.dart';
import '../../store/prefs/preferences_providers.dart';
import '../../store/store.dart';
import '../home/repo_chips.dart' show DiffChip;
import 'lands_in_picker.dart';
import 'pr_actions.dart';
import 'pr_signals.dart';
import 'pr_state_style.dart';
import 'pr_tone.dart';
import 'sheet_header.dart';

/// Why a pull request can report a build verdict with no checks to show: GitHub
/// answered with the rollup only. SPEC-32 sheds the per-check lookup when the
/// quota is tight, which is also why the bar's wording is the vague `CI failing`
/// rather than a count.
const kShedChecksNote =
    'Per-check results were not fetched (GitHub quota), so only the overall '
    'verdict is known.';

/// Show the fact list + checks for [status].
Future<void> showPrDetail(
  BuildContext context, {
  required PrStatus status,
  required PullRequest? pr,
  required void Function(PrRemedy remedy) onRun,
  bool sheet = false,
  bool canInsertPrompt = true,

  /// Identity so the sheet can re-derive its facts live rather than freeze them
  /// at open time (see [PrDetailBody.status]).
  String? projectId,
  String? worktreePath,
}) {
  // On mobile the sheet *is* the PR surface — there is no persistent bar
  // carrying the call to action — so it pins one, and opens on the decision
  // rather than on a list. Desktop already has the CTA in the bar above.
  final body = PrDetailBody(
    status: status,
    pr: pr,
    onRun: onRun,
    showCta: sheet,
    canInsertPrompt: canInsertPrompt,
    projectId: projectId,
    worktreePath: worktreePath,
  );
  if (sheet) {
    return showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (_) => SafeArea(child: body),
    );
  }
  return showDialog<void>(
    context: context,
    builder: (_) => Dialog(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 420),
        child: body,
      ),
    ),
  );
}

/// The shared body: header, the facts (with remedies), then the CI checks.
class PrDetailBody extends ConsumerWidget {
  const PrDetailBody({
    super.key,
    required this.status,
    required this.pr,
    required this.onRun,
    this.showCta = false,
    this.canInsertPrompt = true,
    this.projectId,
    this.worktreePath,
  });

  /// The facts as of open time.
  ///
  /// Used only as a FALLBACK. This sheet used to be a `StatelessWidget` handed a
  /// `PrStatus` computed by its caller, so it painted whatever was true when it
  /// opened and never looked again — which became a real defect the moment the
  /// header started hosting the "Lands in" picker: change where a worktree lands
  /// from inside this sheet and it would keep showing the old +/- numbers until
  /// you closed and reopened it. Now it re-derives from `reposProvider` whenever
  /// [worktreePath] identifies a worktree the snapshot still knows.
  final PrStatus status;
  final PullRequest? pr;
  final void Function(PrRemedy remedy) onRun;

  /// Identity, so the sheet can re-derive rather than re-use. Optional: some
  /// surfaces (a brand-new worktree the snapshot has not seen) have no identity
  /// to resolve, and those keep the passed-in [status].
  final String? projectId;
  final String? worktreePath;

  /// Pin the lifecycle CTA at the bottom (mobile, where nothing else carries it).
  final bool showCta;

  /// Whether this surface can receive a canned prompt. False on the home list,
  /// which has no composer: a prompt remedy there would save a preference,
  /// compose the text, close the sheet and drop it on the floor. Prompt-backed
  /// remedies are hidden rather than shown dead — the direct ops still work,
  /// because tidying up needs no composer.
  final bool canInsertPrompt;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // Re-derive from the single source of truth. `locateWorktree` returns null for
    // a path the snapshot does not carry (removed, or not yet seen), in which case
    // the open-time values are the best we have and the sheet stays put.
    final projectId = this.projectId;
    final at = worktreePath == null
        ? null
        : ref.watch(reposProvider).locateWorktree(worktreePath);
    final status = at == null ? this.status : prStatusFor(at);
    final pr = at == null ? this.pr : at.worktree.pr;
    final worktree = at?.worktree;
    final checks = sortPrChecks(pr?.checks ?? const []);
    // With a pinned CTA (mobile) the loud fact is already the headline *and* the
    // button, so listing it again below would say the same thing three times.
    // The list then carries exactly what the headline elided — the same split the
    // desktop bar makes between its sentence and its `+n more`.
    final rest = showCta ? status.signals.skip(1).toList() : status.signals;
    bool offerable(PrSignal s) =>
        s.remedy != null && (canInsertPrompt || s.remedy is! PromptRemedy);
    final actionable = rest.where(offerable).toList();
    final context_ = rest.where((s) => !offerable(s)).toList();
    // An ended pull request has no next step, so its facts read as a wrap-up
    // brief rather than a to-do list: what landed, and what it left lying around
    // (mockup §4's merged popover).
    //
    // Grouped off `status.signals`, **not** off `rest`: the sheet drops the loud
    // fact before grouping (its headline already said it), and taking the first of
    // what remained put `worktree still here` under `Landed` and took it out of
    // `Left behind`. The ending is `signals.first` by construction.
    final ended = status.isEnded;
    final landed = ended && !showCta
        ? status.signals.take(1).toList()
        : const <PrSignal>[];
    final leftBehind = ended ? status.signals.skip(1).toList() : context_;
    // A merged PR's build is history: a 12-row check list is 12 rows of nothing
    // to do, so it collapses to the one line the brief actually needs.
    final passed = checks.where((c) => c.bucket == 'pass').length;

    final detail = <Widget>[
      if (actionable.isNotEmpty) ...[
        const SizedBox(height: kSpace10),
        _GroupLabel(
          icon: PhosphorIconsLight.warning,
          // "Also" is only true where something already said the loud fact — the
          // sheet's headline. The dialog lists every fact, so there is nothing
          // for "also" to refer to.
          text: showCta ? 'Also needs you' : 'Needs you',
        ),
        for (final s in actionable)
          _FactRow(signal: s, onRun: onRun, offerRemedy: true),
      ],
      if (landed.isNotEmpty || (ended && !showCta && passed > 0)) ...[
        const SizedBox(height: kSpace8),
        const _GroupLabel(icon: PhosphorIconsLight.gitMerge, text: 'Landed'),
        for (final s in landed)
          _FactRow(signal: s, onRun: onRun, offerRemedy: false),
        if (passed > 0)
          _FactRow(
            signal: PrSignal(
              '$passed ${passed == 1 ? 'check' : 'checks'} passed',
              PrTone.quiet,
            ),
            onRun: onRun,
            offerRemedy: false,
            // The build's own verdict, so the check glyph in the check green —
            // a grey dot here reported nothing about the thing it names.
            glyphIcon: prCheckBucketIcon('pass'),
            glyphColor: prCheckBucketColor(
              Theme.of(context).colorScheme,
              'pass',
            ),
          ),
      ],
      if (leftBehind.isNotEmpty) ...[
        const SizedBox(height: kSpace8),
        if (ended)
          const _GroupLabel(
            icon: PhosphorIconsLight.broom,
            text: 'Left behind',
          ),
        // Reported, but with no button: either there is nothing to do about it,
        // or there is nowhere to put the prompt.
        for (final s in leftBehind)
          _FactRow(signal: s, onRun: onRun, offerRemedy: false),
      ],
      if (checks.isNotEmpty && !ended) ...[
        const SizedBox(height: kSpace10),
        const Divider(height: 1),
        const SizedBox(height: kSpace6),
        _GroupLabel(
          icon: PhosphorIconsLight.checkCircle,
          text:
              '${checks.length} '
              '${checks.length == 1 ? 'check' : 'checks'}',
        ),
        for (final c in checks) PrCheckRow(check: c),
      ]
      // A verdict with no rows behind it. Saying nothing here reads as "the app
      // lost them": the rollup is on screen claiming a build result while the list
      // that would explain it is simply absent. Name the reason instead — and it
      // is the same reason the fact itself says `CI failing` rather than a count.
      else if (!ended && (pr?.checkRollup ?? 'none') != 'none') ...[
        const SizedBox(height: kSpace10),
        const Divider(height: 1),
        const SizedBox(height: kSpace6),
        Padding(
          padding: const EdgeInsets.symmetric(vertical: kSpace4),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(
                PhosphorIconsLight.listDashes,
                size: 15,
                color: Theme.of(context).colorScheme.outline,
              ),
              const SizedBox(width: kSpace10),
              Expanded(
                child: Text(
                  kShedChecksNote,
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: Theme.of(context).colorScheme.outline,
                  ),
                ),
              ),
            ],
          ),
        ),
      ],
    ];

    return SingleChildScrollView(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SheetHeader(title: status.identity),
          // Home 2: `branch ≫ target`.
          //
          // This is the only place head and target appear together, and with a PR
          // it is the only place the BRANCH appears at all — `status.identity` is
          // `#<number>` once a PR exists (see `prStatusFor`), so without this line
          // a PR sheet never names the branch it is about.
          //
          // A header subtitle rather than a `Needs you` row on purpose: putting it
          // in the fact list would claim something is wrong, and this is merely
          // true. The picker opens from the target half.
          if (worktree != null &&
              !worktree.isPrimary &&
              worktree.branch != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, kSpace8),
              child: LandsInLine(
                sourceBranch: pr != null ? worktree.branch : null,
                targetBranch: worktree.targetBranch,
                targetResolved: worktree.targetResolved,
                onTap: projectId == null
                    ? null
                    : () => showLandsInPicker(
                        context,
                        ref,
                        projectId: projectId,
                        worktree: worktree,
                        sheet: showCta,
                      ),
                trailing: worktree.showsDiff
                    ? DiffChip(
                        insertions: worktree.insertions,
                        deletions: worktree.deletions,
                      )
                    : null,
              ),
            ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (showCta) _Hero(status: status),
                if (pr != null && pr.title.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(bottom: kSpace10),
                    child: Text(
                      pr.title,
                      style: Theme.of(context).textTheme.bodyMedium,
                    ),
                  ),
                // Decision first: the action sits directly under the headline,
                // above the supporting detail, so the sheet opens on the choice.
                if (showCta)
                  _PinnedCta(
                    status: status,
                    onRun: onRun,
                    canInsertPrompt: canInsertPrompt,
                  ),
                // On the sheet the detail goes behind a disclosure: with the
                // decision pinned at the top, a phone that opens on twelve check
                // rows opens on a list instead of on the choice (mockup §6).
                if (showCta && detail.isNotEmpty)
                  _DetailDisclosure(
                    summary: checks.isEmpty || ended
                        ? null
                        : '${checks.length} '
                              '${checks.length == 1 ? 'check' : 'checks'}',
                    // The closed row's one job is to say what is behind it, so the
                    // count is tinted by the build it stands for (mockup §6 draws
                    // it in `--fail`). Grey for a green or absent verdict — there
                    // is nothing to peek at.
                    summaryTone: switch (pr?.checkRollup) {
                      'fail' => PrTone.blocking,
                      'pending' => PrTone.attention,
                      _ => null,
                    },
                    children: detail,
                  )
                else
                  ...detail,
                if ((pr?.url ?? '').isNotEmpty) ...[
                  const SizedBox(height: kSpace8),
                  Align(
                    alignment: Alignment.centerLeft,
                    child: TextButton.icon(
                      onPressed: () => _open(context, pr!.url),
                      icon: const Icon(
                        PhosphorIconsLight.arrowSquareOut,
                        size: 16,
                      ),
                      label: Text('Open ${status.identity} on GitHub'),
                    ),
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }

  void _open(BuildContext context, String url) {
    Navigator.of(context).maybePop();
    openPrUrl(context, url);
  }
}

/// Open [url] externally, reporting failure rather than doing nothing. Lives
/// here because both the detail body and the desktop bar need it and neither
/// should depend on the other.
Future<void> openPrUrl(BuildContext context, String url) async {
  if (url.isEmpty) return;
  final status = statusOf(context);
  final uri = Uri.tryParse(url);
  try {
    if (uri == null) throw const FormatException('bad PR url');
    // `launchUrl` reports "nobody handled it" by *returning false*, not by
    // throwing — so the result has to be read, or a platform with no handler for
    // the scheme leaves the tap doing nothing at all.
    if (await launchUrl(uri, mode: LaunchMode.externalApplication)) return;
  } catch (_) {
    // Fall through to the same report: from the user's side "it threw" and "it
    // declined" are one outcome.
  }
  status.failure(
    'Could not open the PR',
    detail: url,
    source: StatusSources.pr,
  );
}

/// The sheet's headline (mobile): the loud fact, large and toned. Just the one —
/// the quieter facts are listed below with their own remedies, and trailing them
/// here as prose repeated the list verbatim.
class _Hero extends StatelessWidget {
  const _Hero({required this.status});

  final PrStatus status;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.only(bottom: kSpace8),
      child: Text(
        status.loud.label,
        style: Theme.of(context).textTheme.titleMedium?.copyWith(
          color: prToneTextColor(cs, status.tone),
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }
}

/// The pinned lifecycle CTA (mobile). Filled in the fact's tone for a direct op,
/// tonal for a prompt, and absent entirely when nothing is pressing — an idle
/// full-width button would be the loudest thing on a screen with nothing to do.
class _PinnedCta extends StatelessWidget {
  const _PinnedCta({
    required this.status,
    required this.onRun,
    this.canInsertPrompt = true,
  });

  final PrStatus status;
  final void Function(PrRemedy remedy) onRun;
  final bool canInsertPrompt;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final remedy = status.cta.remedy;
    if (remedy == null) return const SizedBox.shrink();
    // Nowhere to put the text — see [PrDetailBody.canInsertPrompt].
    if (!canInsertPrompt && remedy is! DirectRemedy) {
      return const SizedBox.shrink();
    }
    final tone = prToneTextColor(cs, status.cta.tone);
    final direct = remedy is DirectRemedy;
    // One value for the label *and* the icon. Computing the foreground twice is
    // how they came apart: the label moved to `onPrToneFill` while the icon kept
    // `cs.surface`, so on the amber fill — where `onPrToneFill` picks the dark
    // ink — the label went dark and the icon stayed near-white and vanished.
    //
    // The fill comes from the shared [prDirectCtaFill], so this button and the
    // desktop bar's cannot disagree about the same op — which they did: the muted
    // error pairing for `discard` reached the bar and not the sheet.
    final fill = prDirectCtaFill(
      cs,
      status.cta.tone,
      destructive: direct && remedy.op == PrDirectOp.discardWorktree,
    );
    final fg = direct ? fill.fg : tone;
    return Padding(
      padding: const EdgeInsets.only(top: kSpace12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          FilledButton.icon(
            onPressed: () {
              Navigator.of(context).maybePop();
              onRun(remedy);
            },
            style: FilledButton.styleFrom(
              minimumSize: const Size.fromHeight(46),
              backgroundColor: direct
                  ? fill.bg
                  : Color.alphaBlend(
                      fill.bg.withValues(alpha: 0.20),
                      cs.surfaceContainerHigh,
                    ),
              foregroundColor: fg,
            ),
            icon: prRemedyIcon(remedy).build(size: 16, color: fg),
            label: Text(status.cta.label),
          ),
          const SizedBox(height: kSpace6),
          Text(
            !direct
                ? 'Puts the prompt in the composer — it never sends for you.'
                : needsConfirm(remedy.op)
                ? 'Runs on the server. Asks first.'
                : 'Runs on the server, straight away.',
            textAlign: TextAlign.center,
            style: Theme.of(
              context,
            ).textTheme.labelSmall?.copyWith(color: cs.outline),
          ),
        ],
      ),
    );
  }
}

/// The sheet's collapsed detail (mockup §6): `≡ Detail · 12 checks ▾`.
///
/// Collapsed by default and only on the sheet — the point of the pinned CTA is
/// that the sheet opens on the decision, which a list of facts and twelve check
/// rows above the fold undoes. The dialog has no pinned CTA, so it keeps showing
/// everything.
class _DetailDisclosure extends StatefulWidget {
  const _DetailDisclosure({
    required this.children,
    this.summary,
    this.summaryTone,
  });

  final List<Widget> children;

  /// A count worth showing on the closed row, so the disclosure is not a blind
  /// door. Null when there is nothing to count.
  final String? summary;

  /// The build's verdict, so the count reads as a peek rather than chrome. Null
  /// leaves it in the neutral outline.
  final PrTone? summaryTone;

  @override
  State<_DetailDisclosure> createState() => _DetailDisclosureState();
}

class _DetailDisclosureState extends State<_DetailDisclosure> {
  /// Tracked because a custom `trailing` replaces the one `ExpansionTile` would
  /// have rotated for us — so without this the open row and the closed row look
  /// identical and the control reports nothing about its own state.
  bool _open = false;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final summary = widget.summary;
    final tone = widget.summaryTone;
    return Theme(
      // The tile's own dividers would draw a second hairline against the groups'
      // labels; the rows below supply their own separation.
      data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
      child: ExpansionTile(
        tilePadding: EdgeInsets.zero,
        childrenPadding: EdgeInsets.zero,
        expandedCrossAxisAlignment: CrossAxisAlignment.start,
        expandedAlignment: Alignment.centerLeft,
        onExpansionChanged: (open) => setState(() => _open = open),
        leading: Icon(
          PhosphorIconsLight.listDashes,
          size: 16,
          color: cs.outline,
        ),
        title: Text(
          'Detail',
          style: Theme.of(
            context,
          ).textTheme.bodyMedium?.copyWith(color: cs.onSurfaceVariant),
        ),
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (summary != null)
              Text(
                summary,
                style: Theme.of(context).textTheme.labelSmall?.copyWith(
                  color: tone == null ? cs.outline : prToneTextColor(cs, tone),
                  fontWeight: tone == null ? null : FontWeight.w600,
                ),
              ),
            // Same turn and duration as the bar's split-button caret, so the two
            // disclosures in this feature animate alike.
            AnimatedRotation(
              turns: _open ? 0.5 : 0,
              duration: const Duration(milliseconds: 150),
              child: Icon(
                PhosphorIconsLight.caretDown,
                size: 14,
                color: cs.outline,
              ),
            ),
          ],
        ),
        children: widget.children,
      ),
    );
  }
}

/// One fact: its glyph, the label (+ optional detail), and its remedy as a
/// button.
class _FactRow extends StatelessWidget {
  const _FactRow({
    required this.signal,
    required this.onRun,
    this.offerRemedy = true,
    this.glyphIcon,
    this.glyphColor,
  });

  final PrSignal signal;
  final void Function(PrRemedy remedy) onRun;

  /// Overrides the leading graphic. Used for the landed brief's `N checks passed`
  /// line, which reports the build and so wants the check glyph rather than the
  /// tone dot a remedy-less fact would otherwise get.
  final IconData? glyphIcon;
  final Color? glyphColor;

  /// Draw the remedy button. False for a fact that cannot be acted on here —
  /// see [PrDetailBody.canInsertPrompt].
  final bool offerRemedy;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    // Label/chip text, so the AA-safe variant; the dot below keeps the vivid hue.
    final tone = prToneTextColor(cs, signal.tone);
    final remedy = offerRemedy ? signal.remedy : null;
    // The label carries its fact's tone — a failing build is red *in words*, not
    // only in the glyph beside it and the chip after it. Quiet facts keep the
    // surface ink: they are context, and tinting them grey would make the list's
    // own reading order (loud first) harder to see, not easier.
    //
    // A departure from the mockup, which prints every row's label untoned.
    final labelColor = signal.tone == PrTone.quiet ? null : tone;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: kSpace4),
      child: Row(
        children: [
          // The fact's own glyph where it has one, so a list of four reads as four
          // different things (mockup §4). A fact with no remedy has no glyph of
          // its own and keeps the tone dot.
          if (glyphIcon != null)
            SizedBox(
              width: 15,
              child: Icon(glyphIcon, size: 15, color: glyphColor),
            )
          else if (signal.remedy != null)
            SizedBox(
              width: 15,
              child: prRemedyIcon(
                signal.remedy,
              ).build(size: 15, color: prToneColor(cs, signal.tone)),
            )
          else
            PrToneDot(tone: signal.tone),
          const SizedBox(width: kSpace10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  signal.label,
                  style: Theme.of(
                    context,
                  ).textTheme.bodyMedium?.copyWith(color: labelColor),
                ),
                if (signal.detail != null)
                  Text(
                    signal.detail!,
                    style: Theme.of(
                      context,
                    ).textTheme.bodySmall?.copyWith(color: cs.outline),
                  ),
              ],
            ),
          ),
          if (remedy != null) ...[
            const SizedBox(width: kSpace8),
            TextButton(
              onPressed: () {
                Navigator.of(context).maybePop();
                onRun(remedy);
              },
              style: TextButton.styleFrom(
                foregroundColor: tone,
                backgroundColor: prToneColor(
                  cs,
                  signal.tone,
                ).withValues(alpha: 0.14),
                padding: const EdgeInsets.symmetric(
                  horizontal: kSpace10,
                  vertical: kSpace4,
                ),
                minimumSize: Size.zero,
                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              ),
              child: Text(
                prRemedyLabel(remedy),
                style: Theme.of(context).textTheme.labelSmall?.copyWith(
                  color: tone,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

/// A small uppercase group heading inside the detail body.
class _GroupLabel extends StatelessWidget {
  const _GroupLabel({required this.icon, required this.text});

  final IconData icon;
  final String text;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.only(bottom: kSpace4),
      child: Row(
        children: [
          Icon(icon, size: 13, color: cs.outline),
          const SizedBox(width: kSpace6),
          Text(
            text.toUpperCase(),
            style: Theme.of(context).textTheme.labelXs?.copyWith(
              color: cs.outline,
              fontWeight: FontWeight.w700,
              letterSpacing: 0.8,
            ),
          ),
        ],
      ),
    );
  }
}

/// The CTA caret's menu, grouped by kind.
///
/// The old menu listed all six prompts on every PR, in enum order, regardless of
/// state — "Pull" with nothing to pull, "Fix PR" on a green build. This groups
/// them (**Do now** = a server command, **Ask the agent** = insert a prompt) and
/// keeps the ones that do not currently apply **visible but disabled with the
/// reason**, following the same "explain the block, don't hide it" convention
/// `worktree_actions.dart` already uses for a disabled Rename.
///
/// One exception, and it is not a block: "Create PR" is *removed* once a PR
/// exists. The convention covers actions that could apply later — listing one
/// that is permanently meaningless would explain nothing and invite the reader to
/// wonder what would re-enable it.
List<Widget> buildPrActionMenu(
  BuildContext context,
  WidgetRef ref, {
  required PrStatus status,
  required void Function(PrRemedy remedy) onRun,

  /// Identity for the "Lands in" entry. Omitted where the surface cannot name a
  /// worktree, in which case the group is simply absent.
  String? projectId,
  Worktree? worktree,
}) {
  final hasPr = status.hasPr;
  final ended = status.isEnded;
  final offered = {
    for (final s in status.signals)
      if (s.remedy case PromptRemedy(action: final a)) a,
  };
  final ctaRemedy = status.cta.remedy;
  if (ctaRemedy case PromptRemedy(action: final a)) offered.add(a);

  // Every direct op the current state allows, not just the one the CTA happens
  // to be showing: a draft with a red build has "Fix CI" on the button, and
  // "Mark ready" still belongs in the menu.
  final ops = <PrDirectOp>{
    for (final s in status.signals)
      if (s.remedy case DirectRemedy(op: final o)) o,
    if (status.cta.remedy case DirectRemedy(op: final o)) o,
  };
  final direct = [for (final o in ops) DirectRemedy(o)];
  // Offered whenever it is not just one remedy wearing a vaguer label. Sits with
  // the prompts, because that is what it is — one composed from all of them.
  final magic = status.cta.remedy is MagicRemedy;

  return [
    if (direct.isNotEmpty) ...[
      const _MenuGroup('Do now'),
      for (final d in direct)
        MenuItemButton(
          leadingIcon: prRemedyIcon(d).build(size: 16),
          onPressed: () => onRun(d),
          child: Text(
            prRemedyLabel(d),
            style: Theme.of(context).textTheme.bodyMedium,
          ),
        ),
      const Divider(height: 1),
    ],
    _MenuGroup(ended ? 'History' : 'Ask the agent'),
    if (magic)
      MenuItemButton(
        leadingIcon: prRemedyIcon(const MagicRemedy()).build(size: 16),
        onPressed: () => onRun(const MagicRemedy()),
        child: Text(
          'Fix everything',
          style: Theme.of(context).textTheme.bodyMedium,
        ),
      ),
    for (final action in PrPromptAction.values)
      // "Create PR" and "Ship it" are meaningless once one exists — both aim at
      // raising it. Removed rather than greyed, for the reason in the docstring.
      if (!(hasPr &&
          (action == PrPromptAction.createPr ||
              action == PrPromptAction.shipIt)))
        _PromptMenuItem(
          action: action,
          // Applies when the current facts asked for it. Everything else stays
          // listed, greyed, with why.
          enabled: offered.contains(action) && !ended,
          reason: _whyNot(action, status, ended: ended),
          onRun: onRun,
        ),
    // Home 1: per-worktree config, at the BOTTOM, below a divider.
    //
    // The two groups above are "what to do next"; where a branch lands is not a
    // next step, so it belongs in neither. Bottom-of-menu is the conventional
    // home for per-object settings and it is where the eye stops looking for
    // actions. It prints its current value inline, so opening this menu for any
    // other reason answers "where does this go?" for free — which is the whole
    // disclosure budget this feature needs.
    if (projectId != null &&
        worktree != null &&
        !worktree.isPrimary &&
        worktree.branch != null) ...[
      const Divider(height: 1),
      const _MenuGroup('This worktree'),
      MenuItemButton(
        leadingIcon: const Icon(kLandsInIcon, size: 16),
        onPressed: () => showLandsInPicker(
          context,
          ref,
          projectId: projectId,
          worktree: worktree,
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text('Lands in', style: Theme.of(context).textTheme.bodyMedium),
            const SizedBox(width: kSpace10),
            // Flexible + ellipsis: a long target branch must truncate, not blow
            // the menu row past the screen edge (matches `LandsInLine`).
            Flexible(
              child: Text(
                worktree.targetBranch ?? 'not set',
                overflow: TextOverflow.ellipsis,
                softWrap: false,
                style: Theme.of(context).textTheme.labelSmall?.mono.copyWith(
                  color: worktree.targetUnresolved
                      ? Theme.of(context).colorScheme.statusWarningText
                      : Theme.of(context).colorScheme.outline,
                ),
              ),
            ),
          ],
        ),
      ),
    ],
  ];
}

/// Why [action] is not on offer right now, in the user's terms. Always has an
/// answer: an action is listed disabled precisely because there is a reason.
String _whyNot(PrPromptAction action, PrStatus status, {required bool ended}) {
  if (ended) return 'the pull request has already ended';
  return switch (action) {
    // Two different blocks wear the same label. Giving the branch reason for the
    // primary checkout sent the user looking for commits to make, when the
    // derivation had refused for a reason no commit would change.
    PrPromptAction.createPr =>
      status.isPrimary
          ? 'the primary checkout is not a branch you open a pull request from'
          : 'this branch has no commits to open a PR with',
    // Blocked by two different states, and they need different sentences.
    // `canShipIt` is false when a PR exists (the menu drops the entry rather than
    // explaining it), on the primary checkout, *and* on a detached head — so
    // returning the primary reason unconditionally told a detached worktree
    // something plainly untrue. Worded differently from `createPr`'s otherwise
    // identical primary block on purpose: both are listed here, and two rows
    // repeating one sentence verbatim reads like a rendering bug.
    PrPromptAction.shipIt =>
      status.isPrimary
          ? 'the primary checkout is not a branch you ship from'
          : 'this worktree is not on a branch',
    // On a PR-less branch these are all true but beside the point: there is no
    // build and no thread because there is no pull request. Say that instead.
    PrPromptAction.fixPr =>
      status.hasPr
          ? 'the build is not failing'
          : 'there is no pull request yet',
    PrPromptAction.resolveComments =>
      status.hasPr
          ? 'there are no unresolved threads'
          : 'there is no pull request yet',
    PrPromptAction.commitAndPush => 'there is nothing uncommitted',
    PrPromptAction.push => 'there is nothing to push',
    PrPromptAction.pull => 'the branch is up to date with the remote',
  };
}

/// A prompt action in the menu — enabled and runnable, or greyed with its reason.
class _PromptMenuItem extends ConsumerWidget {
  const _PromptMenuItem({
    required this.action,
    required this.enabled,
    required this.reason,
    required this.onRun,
  });

  final PrPromptAction action;
  final bool enabled;
  final String reason;
  final void Function(PrRemedy remedy) onRun;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final cs = Theme.of(context).colorScheme;
    final last = prActionFromName(ref.preference(lastPrActionPreference));
    return MenuItemButton(
      leadingIcon: action.icon.build(
        size: 16,
        color: enabled ? null : cs.onSurface.withValues(alpha: 0.38),
      ),
      trailingIcon: action == last && enabled
          ? const Icon(PhosphorIconsLight.check, size: 16)
          : null,
      // A disabled item is still *listed* — the absence of an action must never
      // read as the feature missing.
      onPressed: enabled ? () => onRun(PromptRemedy(action)) : null,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(action.label, style: Theme.of(context).textTheme.bodyMedium),
          if (!enabled)
            Text(
              reason,
              style: Theme.of(
                context,
              ).textTheme.labelXs?.copyWith(color: cs.outline),
            ),
        ],
      ),
    );
  }
}

/// A group heading inside the CTA menu.
class _MenuGroup extends StatelessWidget {
  const _MenuGroup(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(kSpace12, kSpace8, kSpace12, kSpace4),
      child: Text(
        text.toUpperCase(),
        style: Theme.of(context).textTheme.labelXs?.copyWith(
          color: cs.outline,
          fontWeight: FontWeight.w700,
          letterSpacing: 0.8,
        ),
      ),
    );
  }
}

/// One CI check: a coloured status glyph, the workflow-qualified name, and the
/// human status word.
///
/// Used by both PR check lists — this sheet, and the desktop pill's popover,
/// which passes [dense]. They differ only in glyph size and row padding: a
/// hover popover is read with a mouse at desk distance, a sheet with a thumb.
class PrCheckRow extends StatelessWidget {
  const PrCheckRow({super.key, required this.check, this.dense = false});

  final PrCheck check;

  /// Tighter rows and a smaller glyph, for the desktop popover.
  final bool dense;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final base = Theme.of(context).textTheme.bodySmall ?? const TextStyle();
    final color = prCheckBucketColor(cs, check.bucket);
    final workflow = check.workflowName;
    final label = workflow == null || workflow.isEmpty
        ? check.name
        : '$workflow / ${check.name}';
    return Padding(
      padding: EdgeInsets.symmetric(vertical: dense ? 1.5 : 3),
      child: Row(
        children: [
          Icon(
            prCheckBucketIcon(check.bucket),
            size: dense ? 12 : 14,
            color: color,
          ),
          const SizedBox(width: kSpace6),
          Expanded(
            child: Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: base.copyWith(color: cs.onSurface),
            ),
          ),
          const SizedBox(width: kSpace12),
          Text(
            prCheckBucketLabel(check.bucket),
            style: base.copyWith(color: color, fontWeight: FontWeight.w600),
          ),
        ],
      ),
    );
  }
}
