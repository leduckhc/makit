// Interactive demo of the SPEC-38 PR bar and everything it opens, with seeded
// data and no server. Run on the desktop you are reading this from:
//
//   cd app && flutter run -d macos -t tool/pr_bar_demo.dart
//
// Pick a state on the left; the composer at the bottom is the real one with the
// real `PrComposerBar` in its `header` slot. Every button, menu item, dialog,
// sheet and confirm is the shipped widget — only the server call at the end is
// stubbed (it reports what it *would* have run).
//
// Not part of the app or the test suite: this is a harness, kept out of `lib/` so
// it cannot be imported by either.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:makit/app/theme.dart';
import 'package:makit/desktop/chat/pr_bar.dart';
import 'package:makit/store/models.dart';
import 'package:makit/ui/composer/composer.dart';
import 'package:makit/ui/home/repo_chips.dart';
import 'package:makit/ui/widgets/pr_detail.dart';
import 'package:makit/ui/widgets/pr_signals.dart';
import 'package:makit/ui/widgets/wrap_up.dart';

// ── seeded data ──────────────────────────────────────────────────────────────

PrCheck _c(String name, String bucket, [String? workflow]) =>
    PrCheck(name: name, bucket: bucket, workflowName: workflow);

PullRequest _pr({
  String state = 'OPEN',
  String rollup = 'pass',
  bool isDraft = false,
  List<PrCheck> checks = const [],
  int unresolved = 0,
  bool stale = false,
  String? mergeable,
  String? mergeState,
}) => PullRequest(
  number: 142,
  url: 'https://github.com/makit/makit/pull/142',
  state: state,
  title: 'Landing strip: composer bar & pills, unified',
  isDraft: isDraft,
  mergeable: mergeable,
  mergeStateStatus: mergeState,
  baseRefName: 'main',
  checkRollup: rollup,
  checks: checks,
  unresolvedComments: unresolved,
  stale: stale,
);

final _twelve = [
  _c('analyze', 'fail'),
  _c('test (ios)', 'fail', 'CI'),
  for (var i = 1; i <= 9; i++) _c('build $i', 'pass', 'CI'),
  _c('ios build', 'skipped'),
];

final _green = [for (var i = 1; i <= 12; i++) _c('build $i', 'pass', 'CI')];

/// One row of the picker: what to call it, and the inputs `prStatus()` gets.
class _Scene {
  const _Scene(
    this.name, {
    this.pr,
    this.branch = 'feat/pr-actions',
    this.uncommitted = 0,
    this.ahead = 0,
    this.behind = 0,
    this.isPrimary = false,
    this.residue = const PrResidue(),
  });

  final String name;
  final PullRequest? pr;
  final String branch;
  final int uncommitted;
  final int ahead;
  final int behind;
  final bool isPrimary;

  /// What an ended worktree left lying around. Seeded per scene so the wrap-up
  /// brief's `left behind` group has something to show.
  final PrResidue residue;

  PrStatus get status => prStatus(
    pr: pr,
    branch: branch,
    uncommittedFiles: uncommitted,
    commitsAhead: ahead,
    commitsBehind: behind,
    isPrimary: isPrimary,
    residue: residue,
  );
}

/// Mockup §3's full ladder, in its order.
final _scenes = <_Scene>[
  const _Scene('clean primary', branch: 'main', isPrimary: true),
  const _Scene('no PR, clean'),
  const _Scene('no PR, 3 uncommitted', branch: 'spike/gauge', uncommitted: 3),
  _Scene('green', pr: _pr(checks: _green)),
  _Scene(
    'hot — unpushed + CI red + 3 threads',
    pr: _pr(rollup: 'fail', checks: _twelve, unresolved: 3),
    ahead: 1,
  ),
  _Scene('one problem — unpushed', pr: _pr(checks: _green), ahead: 1),
  _Scene(
    'ready to merge',
    pr: _pr(checks: _green, mergeable: 'MERGEABLE', mergeState: 'CLEAN'),
  ),
  _Scene(
    'blocked (review missing)',
    pr: _pr(checks: _green, mergeable: 'MERGEABLE', mergeState: 'BLOCKED'),
  ),
  _Scene(
    'checks running',
    pr: _pr(
      rollup: 'pending',
      checks: [
        for (var i = 1; i <= 8; i++) _c('build $i', 'pass', 'CI'),
        for (var i = 1; i <= 4; i++) _c('slow $i', 'pending', 'CI'),
      ],
    ),
  ),
  // Two red-CI states, side by side, because they look different for a reason:
  // one has the per-check list, the other only the rollup (SPEC-32 sheds the
  // lookup when GitHub's quota is tight).
  _Scene(
    'CI red — 12 checks listed',
    pr: _pr(rollup: 'fail', checks: _twelve),
  ),
  _Scene('CI red — rollup only, checks: [] (shed)', pr: _pr(rollup: 'fail')),
  _Scene('draft', pr: _pr(isDraft: true, checks: _green)),
  _Scene(
    'draft + red build',
    pr: _pr(isDraft: true, rollup: 'fail', checks: _twelve),
  ),
  _Scene('conflicts with base', pr: _pr(mergeable: 'CONFLICTING')),
  _Scene(
    'base moved on',
    pr: _pr(checks: _green, mergeState: 'BEHIND'),
  ),
  _Scene('2 behind the remote', pr: _pr(checks: _green), behind: 2),
  _Scene('3 threads open', pr: _pr(checks: _green, unresolved: 3)),
  _Scene(
    'merged',
    pr: _pr(state: 'MERGED', checks: _green),
    branch: 'fix/composer',
    uncommitted: 2,
    residue: const PrResidue(
      sessions: 1,
      targetBranch: 'main',
      targetBehind: 6,
    ),
  ),
  _Scene(
    'closed without merging',
    pr: _pr(state: 'CLOSED', checks: _green),
    branch: 'spike/gauge',
    uncommitted: 1,
    residue: const PrResidue(
      sessions: 2,
      targetBranch: 'main',
      targetBehind: 3,
    ),
  ),
  _Scene(
    'stale (GitHub quota)',
    pr: _pr(rollup: 'fail', checks: _twelve, stale: true),
  ),
];

const _repo = RepoInfo(
  id: 'p1',
  name: 'makit',
  path: '/repo/makit',
  pinned: false,
  lastActivityAt: 0,
  isGitRepo: true,
  defaultBranch: 'main',
  currentBranch: 'main',
  worktrees: [],
);

Worktree _worktree(_Scene s) => Worktree(
  id: s.branch,
  path: '/Users/you/.worktrees/makit/${s.branch.replaceAll('/', '-')}',
  branch: s.branch,
  isPrimary: s.isPrimary,
  insertions: 0,
  deletions: 0,
  filesChanged: 0,
  sessionIds: const ['s1'],
  uncommittedFiles: s.uncommitted,
  aheadCount: s.ahead,
  behindCount: s.behind,
  pr: s.pr,
);

void main() {
  runApp(
    ProviderScope(
      overrides: [
        // The only stub: the direct ops report what they would have run on the
        // server instead of needing a paired one. Everything before this — the
        // confirm, its copy, the branch guard — is the real path.
        prOpRunnerProvider.overrideWithValue((op, target) async {
          await Future<void>.delayed(const Duration(milliseconds: 400));
          return PrOpOutcome(
            'DEMO: would run ${op.name}',
            detail:
                'project=${target.projectId}\nworktree=${target.worktreePath}\n'
                'target=${target.targetBranch}\nexpectBranch=${target.expectBranch}',
          );
        }),
      ],
      child: const _DemoApp(),
    ),
  );
}

class _DemoApp extends StatefulWidget {
  const _DemoApp();

  @override
  State<_DemoApp> createState() => _DemoAppState();
}

class _DemoAppState extends State<_DemoApp> {
  bool _dark = true;
  int _i = 4; // the busy one, so there is something to look at on launch
  final _composer = TextEditingController();

  _Scene get _scene => _scenes[_i];

  @override
  void dispose() {
    _composer.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'SPEC-38 PR bar — demo',
      theme: _dark ? makitDarkTheme : makitLightTheme,
      home: Consumer(
        builder: (context, ref, _) {
          final cs = Theme.of(context).colorScheme;
          final scene = _scene;
          final status = scene.status;
          final worktree = _worktree(scene);

          Future<void> run(PrRemedy remedy) => runPrRemedy(
            context,
            ref,
            remedy: remedy,
            status: status,
            pr: scene.pr,
            projectId: _repo.id,
            worktreePath: worktree.path,
            branch: scene.branch,
            uncommittedFiles: scene.uncommitted,
            onInsertPrompt: (prompt) {
              _composer.text = prompt;
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(
                  content: Text('Prompt inserted in the composer — not sent'),
                ),
              );
            },
          );

          return Scaffold(
            backgroundColor: cs.surface,
            body: Row(
              children: [
                // ── the picker ──────────────────────────────────────────────
                // Material, not a plain Container: `selectedTileColor` paints
                // into the enclosing Material, and without one every ListTile
                // asserts that its ink will be invisible.
                Material(
                  color: cs.surfaceContainerLow,
                  child: SizedBox(
                    width: 260,
                    child: SafeArea(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          Padding(
                            padding: const EdgeInsets.all(12),
                            child: Row(
                              children: [
                                Expanded(
                                  child: Text(
                                    'SPEC-38 states',
                                    style: Theme.of(
                                      context,
                                    ).textTheme.titleSmall,
                                  ),
                                ),
                                IconButton(
                                  tooltip: 'light / dark',
                                  icon: Icon(
                                    _dark ? Icons.light_mode : Icons.dark_mode,
                                    size: 18,
                                  ),
                                  onPressed: () =>
                                      setState(() => _dark = !_dark),
                                ),
                              ],
                            ),
                          ),
                          const Divider(height: 1),
                          Expanded(
                            child: ListView.builder(
                              itemCount: _scenes.length,
                              itemBuilder: (context, i) => ListTile(
                                dense: true,
                                selected: i == _i,
                                selectedTileColor: cs.surfaceContainerHigh,
                                title: Text(
                                  _scenes[i].name,
                                  style: Theme.of(context).textTheme.bodySmall,
                                ),
                                onTap: () => setState(() => _i = i),
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
                const VerticalDivider(width: 1),
                // ── the pane ────────────────────────────────────────────────
                Expanded(
                  child: SafeArea(
                    child: Column(
                      children: [
                        Expanded(
                          child: Center(
                            child: ConstrainedBox(
                              constraints: const BoxConstraints(maxWidth: 720),
                              child: Column(
                                mainAxisSize: MainAxisSize.min,
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    'What the derivation says',
                                    style: Theme.of(context)
                                        .textTheme
                                        .labelSmall
                                        ?.copyWith(color: cs.outline),
                                  ),
                                  const SizedBox(height: 6),
                                  SelectableText(
                                    'identity=${status.identity}   '
                                    'dot=${status.dot.name}   '
                                    'tone=${status.tone.name}   '
                                    'cta="${status.cta.label}" '
                                    '(${status.cta.tone.name})   '
                                    'quiet=${status.isQuiet}\n'
                                    '${status.signals.map((s) => '• ${s.label}'
                                        '${s.detail == null ? '' : ' — ${s.detail}'}').join('\n')}',
                                    style: Theme.of(context).textTheme.bodySmall
                                        ?.copyWith(color: cs.onSurfaceVariant),
                                  ),
                                  const SizedBox(height: 20),
                                  Text(
                                    'The other two surfaces',
                                    style: Theme.of(context)
                                        .textTheme
                                        .labelSmall
                                        ?.copyWith(color: cs.outline),
                                  ),
                                  const SizedBox(height: 6),
                                  // The home row's chip (tap = the sheet).
                                  if (!status.isQuiet)
                                    Row(
                                      children: [
                                        Container(
                                          width: 3,
                                          height: 22,
                                          color: cs.primary,
                                        ),
                                        const SizedBox(width: 9),
                                        Text(
                                          scene.branch,
                                          style: Theme.of(context)
                                              .textTheme
                                              .bodyMedium
                                              ?.copyWith(
                                                fontWeight: FontWeight.w500,
                                              ),
                                        ),
                                        const SizedBox(width: 9),
                                        PrStatusChip(
                                          status: status,
                                          repo: _repo,
                                          worktree: worktree,
                                          onInsertPrompt: (p) =>
                                              _composer.text = p,
                                        ),
                                      ],
                                    )
                                  else
                                    Text(
                                      'no chip — PrStatus.isQuiet',
                                      style: Theme.of(context)
                                          .textTheme
                                          .bodySmall
                                          ?.copyWith(color: cs.outline),
                                    ),
                                  const SizedBox(height: 14),
                                  Wrap(
                                    spacing: 8,
                                    runSpacing: 8,
                                    children: [
                                      OutlinedButton(
                                        onPressed: () => showPrDetail(
                                          context,
                                          status: status,
                                          pr: scene.pr,
                                          onRun: run,
                                        ),
                                        child: const Text('Detail — dialog'),
                                      ),
                                      OutlinedButton(
                                        onPressed: () => showPrDetail(
                                          context,
                                          status: status,
                                          pr: scene.pr,
                                          sheet: true,
                                          onRun: run,
                                        ),
                                        child: const Text('Detail — sheet'),
                                      ),
                                      for (final op in PrDirectOp.values)
                                        OutlinedButton(
                                          onPressed: () =>
                                              run(DirectRemedy(op)),
                                          child: Text('run ${op.name}'),
                                        ),
                                    ],
                                  ),
                                ],
                              ),
                            ),
                          ),
                        ),
                        // ── the real composer, with the real bar inside ─────
                        Center(
                          child: ConstrainedBox(
                            constraints: const BoxConstraints(maxWidth: 720),
                            child: Padding(
                              padding: const EdgeInsets.fromLTRB(12, 4, 12, 12),
                              child: Composer(
                                controller: _composer,
                                alwaysExpanded: true,
                                onSend: (text) =>
                                    ScaffoldMessenger.of(context).showSnackBar(
                                      SnackBar(content: Text('sent: $text')),
                                    ),
                                header: PrComposerBar(
                                  status: status,
                                  pr: scene.pr,
                                  projectId: _repo.id,
                                  worktreePath: worktree.path,
                                  branch: scene.branch,
                                  uncommittedFiles: scene.uncommitted,
                                  onInsertPrompt: (p) => _composer.text = p,
                                ),
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          );
        },
      ),
    );
  }
}
