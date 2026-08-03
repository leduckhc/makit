/// Domain model used by the UI. Decoupled from wire types so we can evolve
/// either side independently.
library;

// Re-export the chat item tree + event folding so existing importers of
// `models.dart` keep resolving them after the SPEC-19 split.
export 'chat_items.dart';

/// An agent the host can spawn, surfaced by `agents.list` for the picker.
class AgentDescriptor {
  const AgentDescriptor({
    required this.id,
    required this.label,
    required this.transport,
    required this.available,
    this.fingerprint = '',
    this.configOptions = const [],
  });

  final String id;
  final String label;

  /// `native` | `acp`.
  final String transport;
  final bool available;

  /// Hash of the harness's resolved binary + catalog-affecting config inputs
  /// (SPEC-27). Empty when the server didn't advertise one. Used to detect a
  /// stale cached capability catalog.
  final String fingerprint;

  /// The harness's cached capability catalog — the `configOptions` snapshot
  /// from the server's throwaway probe (SPEC-27), rendered pre-session by the
  /// SPEC-26 generic renderer. Empty when the harness advertises no options
  /// (default-only) or the field is absent.
  final List<SessionConfigOption> configOptions;

  static AgentDescriptor? fromJson(Map<String, dynamic> j) {
    final id = j['id'] as String?;
    if (id == null) return null;
    return AgentDescriptor(
      id: id,
      label: (j['label'] as String?) ?? id,
      transport: (j['transport'] as String?) ?? 'native',
      available: (j['available'] as bool?) ?? true,
      fingerprint: (j['fingerprint'] is String)
          ? j['fingerprint'] as String
          : '',
      configOptions:
          ((j['configOptions'] is List)
                  ? j['configOptions'] as List<dynamic>
                  : const <dynamic>[])
              .whereType<Map<dynamic, dynamic>>()
              .map(
                (m) =>
                    SessionConfigOption.fromJson(Map<String, dynamic>.from(m)),
              )
              .whereType<SessionConfigOption>()
              .toList(),
    );
  }
}

/// A single pre-spawn config pick carried on `session.spawn` (SPEC-27): the
/// [id] of a harness [SessionConfigOption] and the chosen [value] (a [String]
/// for a select option, a [bool] for a boolean). The server maps [id] to the
/// transport-specific apply-at-launch param (ACP `session/set_config_option`
/// `configId`, or codex thread/turn params).
class ConfigOptionPick {
  const ConfigOptionPick({required this.id, required this.value});

  final String id;

  /// A [String] for a select option, a [bool] for a boolean.
  final Object value;

  Map<String, dynamic> toJson() => {'id': id, 'value': value};
}

/// One command exposed by the agent — extension, prompt template, or skill.
class SlashCmd {
  const SlashCmd({
    required this.name,
    required this.description,
    required this.source,
    this.location,
  });

  /// Without the leading `/`. e.g. `skill:foo`, `fix-tests`, `session-name`.
  final String name;
  final String description;

  /// `extension` | `prompt` | `skill`
  final String source;

  /// `user` | `project` | `path` — optional.
  final String? location;

  String get invocation => '/$name';

  static SlashCmd? fromJson(Map<String, dynamic> j) {
    final name = j['name'] as String?;
    if (name == null) return null;
    return SlashCmd(
      name: name,
      description: (j['description'] as String?) ?? '',
      source: (j['source'] as String?) ?? 'extension',
      location: j['location'] as String?,
    );
  }
}

/// A model the agent can run, as pushed via `session.meta`. Also used for the
/// currently-active model.
class ModelInfo {
  const ModelInfo({
    required this.provider,
    required this.id,
    required this.name,
  });

  final String provider;
  final String id;
  final String name;

  static ModelInfo? fromJson(Map<String, dynamic> j) {
    final provider = j['provider'] as String?;
    final id = j['id'] as String?;
    if (provider == null || id == null) return null;
    return ModelInfo(
      provider: provider,
      id: id,
      name: (j['name'] as String?) ?? id,
    );
  }
}

/// Error reported by the pi extension when a built-in control action fails
/// (e.g. `/compact` before the session is ready, `/model` switch rejected).
/// Pushed via `session.action_error`; surfaces as a transient snackbar.
class ActionError {
  const ActionError({
    required this.seq,
    required this.action,
    required this.reason,
  });

  final int seq;
  final String action;
  final String reason;
}

/// Per-session model + thinking-level snapshot. Drives the subtle header
/// indicator and the `/model` picker. Pushed via the `session.meta` event.
class SessionMeta {
  const SessionMeta({
    this.model,
    required this.thinking,
    required this.models,
    this.modes,
    this.configOptions = const [],
  });

  final ModelInfo? model;
  final String thinking;
  final List<ModelInfo> models;

  /// ACP session modes (e.g. ask/code/architect), when the agent is an ACP
  /// agent that advertises them. Native pi has no modes (null); ACP has no
  /// model/thinking. Drives the composer's mode selector.
  final SessionModes? modes;

  /// Generic, category-tagged config selectors (ACP `configOptions`), ordered
  /// by agent priority. Empty when the agent emits only the legacy
  /// `model`/`thinking`/`modes` fields (back-compat). See SPEC-26.
  final List<SessionConfigOption> configOptions;

  static SessionMeta fromJson(Map<String, dynamic> j) {
    final rawModel = j['model'];
    final rawModes = j['modes'];
    return SessionMeta(
      model: rawModel is Map
          ? ModelInfo.fromJson(Map<String, dynamic>.from(rawModel))
          : null,
      thinking: (j['thinking'] as String?) ?? '',
      models: ((j['models'] as List?) ?? const [])
          .whereType<Map<dynamic, dynamic>>()
          .map((m) => ModelInfo.fromJson(Map<String, dynamic>.from(m)))
          .whereType<ModelInfo>()
          .toList(),
      modes: rawModes is Map
          ? SessionModes.fromJson(Map<String, dynamic>.from(rawModes))
          : null,
      configOptions:
          ((j['configOptions'] is List)
                  ? j['configOptions'] as List
                  : const <dynamic>[])
              .whereType<Map<dynamic, dynamic>>()
              .map(
                (m) =>
                    SessionConfigOption.fromJson(Map<String, dynamic>.from(m)),
              )
              .whereType<SessionConfigOption>()
              .toList(),
    );
  }
}

/// Whether a [SessionConfigOption] is a value picker or an on/off toggle.
/// ACP defaults an option to `select` when `type` is absent.
enum ConfigOptionType { select, boolean }

/// One choice within a select [SessionConfigOption] — either directly under
/// `options` (flat) or inside a [ConfigOptionGroup].
class ConfigOptionValue {
  const ConfigOptionValue({
    required this.value,
    required this.name,
    this.description,
  });

  final String value;
  final String name;
  final String? description;

  static ConfigOptionValue? fromJson(Map<String, dynamic> j) {
    final value = j['value'] as String?;
    if (value == null) return null;
    return ConfigOptionValue(
      value: value,
      name: (j['name'] as String?) ?? value,
      description: j['description'] as String?,
    );
  }
}

/// A named group of [ConfigOptionValue]s for a grouped select option. The
/// composer renders these as labeled sections.
class ConfigOptionGroup {
  const ConfigOptionGroup({required this.name, required this.options});

  final String name;
  final List<ConfigOptionValue> options;

  static ConfigOptionGroup? fromJson(Map<String, dynamic> j) {
    final name = j['name'] as String?;
    if (name == null) return null;
    return ConfigOptionGroup(
      name: name,
      options: _parseOptionValues(j['options']),
    );
  }
}

List<ConfigOptionValue> _parseOptionValues(Object? raw) =>
    ((raw as List?) ?? const [])
        .whereType<Map<dynamic, dynamic>>()
        .map((m) => ConfigOptionValue.fromJson(Map<String, dynamic>.from(m)))
        .whereType<ConfigOptionValue>()
        .toList();

/// A generic, category-tagged session config selector advertised by the agent
/// (ACP `configOptions`). Supersedes the legacy `model`/`thinking`/`modes`
/// fields on [SessionMeta]. Ordered by agent priority; the composer renders
/// each option by [category]. See SPEC-26.
class SessionConfigOption {
  const SessionConfigOption({
    required this.id,
    required this.name,
    this.description,
    this.category,
    required this.type,
    required this.currentValue,
    this.options = const [],
    this.groups = const [],
  });

  final String id;
  final String name;
  final String? description;

  /// Semantic, UX-only hint: known values are `mode`, `model`, `model_config`,
  /// `thought_level`. Open string — unknown/`_`-prefixed values are preserved
  /// and rendered with the generic select.
  final String? category;

  final ConfigOptionType type;

  /// The active value: a [String] for `select`, a [bool] for `boolean`.
  final Object currentValue;

  /// Flat choices for a select option; empty when grouped or boolean.
  final List<ConfigOptionValue> options;

  /// Named groups for a grouped select option; empty when flat or boolean.
  final List<ConfigOptionGroup> groups;

  static SessionConfigOption? fromJson(Map<String, dynamic> j) {
    final id = j['id'] as String?;
    final name = j['name'] as String?;
    if (id == null || name == null) return null;
    final type = j['type'] == 'boolean'
        ? ConfigOptionType.boolean
        : ConfigOptionType.select;
    final rawValue = j['currentValue'];
    final currentValue = rawValue is bool || rawValue is String
        ? rawValue as Object
        : (type == ConfigOptionType.boolean ? false : '');
    return SessionConfigOption(
      id: id,
      name: name,
      description: j['description'] as String?,
      category: j['category'] as String?,
      type: type,
      currentValue: currentValue,
      options: _parseOptionValues(j['options']),
      groups: ((j['groups'] as List?) ?? const [])
          .whereType<Map<dynamic, dynamic>>()
          .map((m) => ConfigOptionGroup.fromJson(Map<String, dynamic>.from(m)))
          .whereType<ConfigOptionGroup>()
          .toList(),
    );
  }
}

/// One selectable agent mode (ACP session mode).
class SessionMode {
  const SessionMode({required this.id, required this.name});

  final String id;
  final String name;

  static SessionMode? fromJson(Map<String, dynamic> j) {
    final id = j['id'] as String?;
    if (id == null) return null;
    return SessionMode(id: id, name: (j['name'] as String?) ?? id);
  }
}

/// The set of agent modes and the one currently active (ACP `SessionModeState`).
class SessionModes {
  const SessionModes({required this.current, required this.available});

  final String current;
  final List<SessionMode> available;

  static SessionModes fromJson(Map<String, dynamic> j) => SessionModes(
    current: (j['current'] as String?) ?? '',
    available: ((j['available'] as List?) ?? const [])
        .whereType<Map<dynamic, dynamic>>()
        .map((m) => SessionMode.fromJson(Map<String, dynamic>.from(m)))
        .whereType<SessionMode>()
        .toList(),
  );
}

class Project {
  Project({
    required this.id,
    required this.name,
    required this.path,
    this.pinned = false,
    this.lastActivityAt = 0,
  });

  final String id;
  final String name;
  final String path;
  final bool pinned;
  final int lastActivityAt;
}

/// A single CI check on a PR head, normalized server-side from `gh`'s
/// `statusCheckRollup` (see server `PrCheckDTO`). Rendered in the PR pill's
/// hover popover.
class PrCheck {
  const PrCheck({
    required this.name,
    required this.bucket,
    this.workflowName,
    this.detailsUrl,
  });

  /// The check/context name, e.g. `test` or `CodeRabbit`.
  final String name;

  /// `pass` | `fail` | `pending` | `skipping` | `cancel`.
  final String bucket;

  /// Owning workflow (Actions checks), or null for a legacy status context.
  final String? workflowName;

  /// Deep link to the check's details, or null when the provider gave none.
  final String? detailsUrl;

  static PrCheck? fromJson(Map<String, dynamic> j) {
    final name = j['name'];
    if (name is! String) return null;
    return PrCheck(
      name: name,
      bucket: j['bucket'] is String ? j['bucket'] as String : 'pending',
      workflowName: j['workflowName'] is String
          ? j['workflowName'] as String
          : null,
      detailsUrl: j['detailsUrl'] is String ? j['detailsUrl'] as String : null,
    );
  }
}

/// An open pull request tied to a worktree's branch (surfaced via `gh`).
class PullRequest {
  const PullRequest({
    required this.number,
    required this.url,
    required this.state,
    required this.title,
    required this.isDraft,
    this.mergeable,
    this.mergeStateStatus,
    this.checks = const [],
    this.checkRollup = 'none',
    this.unresolvedComments = 0,
    this.stale = false,
    this.unresolvedUnknown = false,
  });

  final int number;
  final String url;
  final String state;
  final String title;
  final bool isDraft;

  /// MERGEABLE | CONFLICTING | UNKNOWN, or null when `gh` didn't report it.
  final String? mergeable;

  /// CLEAN | BLOCKED | BEHIND | DIRTY | …, or null when unreported.
  final String? mergeStateStatus;

  /// Per-check status for the hover popover. Empty when there are no checks.
  final List<PrCheck> checks;

  /// Aggregate CI verdict: `pass` | `fail` | `pending` | `none`.
  final String checkRollup;

  /// Count of unresolved review threads on the PR.
  final int unresolvedComments;

  /// True when this PR was not re-fetched successfully (a throttled/failed
  /// lookup); the last-known state is retained and the pill is shown dimmed
  /// (SPEC-32 G2). Defaults false on any server that predates the field.
  final bool stale;

  /// True when `unresolvedComments` was shed to save quota, so its value is not
  /// reliable and the count should be hidden rather than shown as a lie.
  /// Defaults false on any server that predates the field.
  final bool unresolvedUnknown;

  static PullRequest? fromJson(Map<String, dynamic> j) {
    final number = j['number'];
    if (number is! num) return null;
    return PullRequest(
      number: number.toInt(),
      url: j['url'] is String ? j['url'] as String : '',
      state: j['state'] is String ? j['state'] as String : 'OPEN',
      title: j['title'] is String ? j['title'] as String : '',
      isDraft: j['isDraft'] == true,
      mergeable: j['mergeable'] is String ? j['mergeable'] as String : null,
      mergeStateStatus: j['mergeStateStatus'] is String
          ? j['mergeStateStatus'] as String
          : null,
      checks: ((j['checks'] as List?) ?? const [])
          .whereType<Map<dynamic, dynamic>>()
          .map((c) => PrCheck.fromJson(Map<String, dynamic>.from(c)))
          .whereType<PrCheck>()
          .toList(),
      checkRollup: j['checkRollup'] is String
          ? j['checkRollup'] as String
          : 'none',
      unresolvedComments: (j['unresolvedComments'] as num?)?.toInt() ?? 0,
      stale: j['stale'] == true,
      unresolvedUnknown: j['unresolvedUnknown'] == true,
    );
  }
}

/// An open pull request as returned by the `pr.list` command, used to populate
/// the "New worktree from PR" picker.
class OpenPr {
  const OpenPr({
    required this.number,
    required this.title,
    required this.headRefName,
    required this.isDraft,
    required this.url,
  });

  final int number;
  final String title;
  final String headRefName;
  final bool isDraft;
  final String url;

  static OpenPr fromJson(Map<String, dynamic> j) => OpenPr(
    number: (j['number'] as num?)?.toInt() ?? 0,
    title: j['title'] is String ? j['title'] as String : '',
    headRefName: j['headRefName'] is String ? j['headRefName'] as String : '',
    isDraft: j['isDraft'] == true,
    url: j['url'] is String ? j['url'] as String : '',
  );
}

/// Health of the GitHub API budget, driven server-side by time-to-empty rather
/// than percentage remaining (SPEC-32 §6.1). `unknown` means never measured
/// (distinct from a real, measured value) and drives a dimmed icon.
enum BudgetLevel { healthy, warm, critical, paused, unknown }

BudgetLevel parseBudgetLevel(String s) => switch (s) {
  'healthy' => BudgetLevel.healthy,
  'warm' => BudgetLevel.warm,
  'critical' => BudgetLevel.critical,
  'paused' => BudgetLevel.paused,
  _ => BudgetLevel.unknown,
};

/// One GitHub rate-limit bucket (`core`, `graphql`, or `search`). A bucket is
/// `null` on the owning [GithubBudget] when it has not been measured yet —
/// **unmeasured is not the same as empty**, and the two render differently, so
/// callers must never coerce a missing bucket into a zeroed one.
class BudgetBucket {
  const BudgetBucket({
    required this.limit,
    required this.remaining,
    required this.resetAt,
    required this.mine,
    required this.others,
  });

  final int limit;
  final int remaining;

  /// Epoch **milliseconds** when the window resets (the server already
  /// converted from GitHub's seconds). The `search` bucket resets per minute;
  /// the two hourly buckets on a fixed absolute reset.
  final int resetAt;

  /// Requests attributed to makit in this window.
  final int mine;

  /// Derived spend by other tools on the same token (`limit-remaining-mine`).
  final int others;

  /// Returns null when [limit]/[remaining] are missing or non-numeric — the
  /// caller treats that as an unmeasured bucket, not a zeroed one.
  static BudgetBucket? fromJson(Map<String, dynamic> j) {
    final limit = j['limit'];
    final remaining = j['remaining'];
    if (limit is! num || remaining is! num) return null;
    return BudgetBucket(
      limit: limit.toInt(),
      remaining: remaining.toInt(),
      resetAt: j['resetAt'] is num ? (j['resetAt'] as num).toInt() : 0,
      mine: j['mine'] is num ? (j['mine'] as num).toInt() : 0,
      others: j['others'] is num ? (j['others'] as num).toInt() : 0,
    );
  }
}

/// One per-minute slot of the trailing 60-minute burn history, used by the
/// popover's sparkline. Oldest first.
class BudgetHistorySlot {
  const BudgetHistorySlot({required this.mine, required this.others});

  final int mine;
  final int others;

  static BudgetHistorySlot? fromJson(Map<String, dynamic> j) {
    final mine = j['mine'];
    final others = j['others'];
    if (mine is! num && others is! num) return null;
    return BudgetHistorySlot(
      mine: mine is num ? mine.toInt() : 0,
      others: others is num ? others.toInt() : 0,
    );
  }
}

/// Gateway spend counters (SPEC-32 §6.4). Present only once the gateway has
/// run at least one measurement; a `null` [GithubBudget.stats] means unmeasured.
class BudgetStats {
  const BudgetStats({required this.execs, required this.cacheHits});

  final int execs;
  final int cacheHits;

  static BudgetStats fromJson(Map<String, dynamic> j) => BudgetStats(
    execs: j['execs'] is num ? (j['execs'] as num).toInt() : 0,
    cacheHits: j['cacheHits'] is num ? (j['cacheHits'] as num).toInt() : 0,
  );
}

/// The GitHub API budget snapshot pushed via the `github.budget` frame
/// (SPEC-32 §6.6), surfaced by the desktop sidebar footer icon + popover.
///
/// Tolerant by construction: any of the three buckets may be `null`
/// (unmeasured), [msUntilEmpty]/[retryAfterMs] are meaningfully nullable
/// ("never empties" / "no burst limit"), [history] defaults to empty, and
/// [stats] is `null` until the gateway has measured.
class GithubBudget {
  const GithubBudget({
    required this.core,
    required this.graphql,
    required this.search,
    required this.burnPerHour,
    required this.msUntilEmpty,
    required this.level,
    required this.throttles,
    required this.retryAfterMs,
    required this.measuredAt,
    required this.history,
    required this.stats,
  });

  /// REST bucket (5,000/hour), or null when unmeasured.
  final BudgetBucket? core;

  /// GraphQL points bucket (5,000/hour) — makit's hot path — or null.
  final BudgetBucket? graphql;

  /// Search bucket (30/**minute**), or null. makit never searches, so a
  /// non-idle search bucket is itself information (something else on the token).
  final BudgetBucket? search;

  /// Observed requests/hour over the trailing window.
  final int burnPerHour;

  /// Ms until the governing bucket empties at [burnPerHour], or null when it
  /// will never empty (burn 0). Null is meaningful — do not coerce to 0.
  final int? msUntilEmpty;

  final BudgetLevel level;

  /// Active throttles in ladder order; drives the popover banner + badge.
  final List<String> throttles;

  /// Set while a secondary (burst) limit is in force; null otherwise. Null is
  /// meaningful ("no burst limit") — do not coerce to 0.
  final int? retryAfterMs;

  final int measuredAt;

  /// Trailing 60 per-minute burn slots, oldest first. Empty when unreported.
  final List<BudgetHistorySlot> history;

  /// Gateway spend counters, or null when unmeasured.
  final BudgetStats? stats;

  /// Tolerant decode: never throws, never drops the whole snapshot for one bad
  /// field. A missing/garbage/null bucket becomes a `null` field (unmeasured),
  /// not a zeroed bucket.
  static GithubBudget fromJson(Map<String, dynamic> j) {
    final rawBuckets = j['buckets'];
    final buckets = rawBuckets is Map
        ? Map<String, dynamic>.from(rawBuckets)
        : const <String, dynamic>{};
    BudgetBucket? bucket(String name) {
      final v = buckets[name];
      return v is Map
          ? BudgetBucket.fromJson(Map<String, dynamic>.from(v))
          : null;
    }

    return GithubBudget(
      core: bucket('core'),
      graphql: bucket('graphql'),
      search: bucket('search'),
      burnPerHour: j['burnPerHour'] is num
          ? (j['burnPerHour'] as num).toInt()
          : 0,
      msUntilEmpty: j['msUntilEmpty'] is num
          ? (j['msUntilEmpty'] as num).toInt()
          : null,
      level: parseBudgetLevel(j['level'] is String ? j['level'] as String : ''),
      // `as List?` would THROW on a present non-null non-list (e.g. a bare
      // string), taking down the whole frame -- and decode failures are
      // swallowed, so the footer would silently go stale. Degrade to empty.
      throttles:
          (j['throttles'] is List ? j['throttles'] as List : const <Object?>[])
              .whereType<String>()
              .toList(),
      retryAfterMs: j['retryAfterMs'] is num
          ? (j['retryAfterMs'] as num).toInt()
          : null,
      measuredAt: j['measuredAt'] is num ? (j['measuredAt'] as num).toInt() : 0,
      history: (j['history'] is List ? j['history'] as List : const <Object?>[])
          .whereType<Map<dynamic, dynamic>>()
          .map((m) => BudgetHistorySlot.fromJson(Map<String, dynamic>.from(m)))
          .whereType<BudgetHistorySlot>()
          .toList(),
      stats: j['stats'] is Map
          ? BudgetStats.fromJson(Map<String, dynamic>.from(j['stats'] as Map))
          : null,
    );
  }
}

/// One git worktree of a repo. `isPrimary` marks the repo's main checkout;
/// other worktrees are feature branches created for sessions. Diff stats are
/// measured against the repo's default branch.
class Worktree {
  const Worktree({
    required this.id,
    required this.path,
    required this.branch,
    required this.isPrimary,
    required this.insertions,
    required this.deletions,
    required this.filesChanged,
    required this.sessionIds,
    this.uncommittedFiles = 0,
    this.aheadCount = 0,
    this.behindCount = 0,
    this.committedAt,
    this.pr,
  });

  final String id;
  final String path;
  final String? branch;
  final bool isPrimary;
  final int insertions;
  final int deletions;
  final int filesChanged;
  final List<String> sessionIds;

  /// Files with uncommitted changes (staged + unstaged + untracked).
  final int uncommittedFiles;

  /// Commits not yet pushed to the remote (what a push would send).
  final int aheadCount;

  /// Commits on the upstream not yet local (what a pull would fetch).
  final int behindCount;

  /// HEAD commit time, or null when unavailable.
  final DateTime? committedAt;
  final PullRequest? pr;

  bool get hasChanges => insertions > 0 || deletions > 0 || filesChanged > 0;

  static Worktree? fromJson(Map<String, dynamic> j) {
    final path = j['path'];
    if (path is! String) return null;
    final rawPr = j['pr'];
    return Worktree(
      id: j['id'] is String ? j['id'] as String : path,
      path: path,
      branch: j['branch'] is String ? j['branch'] as String : null,
      isPrimary: j['isPrimary'] == true,
      insertions: (j['insertions'] as num?)?.toInt() ?? 0,
      deletions: (j['deletions'] as num?)?.toInt() ?? 0,
      filesChanged: (j['filesChanged'] as num?)?.toInt() ?? 0,
      uncommittedFiles: (j['uncommittedFiles'] as num?)?.toInt() ?? 0,
      aheadCount: (j['aheadCount'] as num?)?.toInt() ?? 0,
      behindCount: (j['behindCount'] as num?)?.toInt() ?? 0,
      sessionIds: ((j['sessionIds'] as List?) ?? const [])
          .whereType<String>()
          .toList(),
      committedAt: (j['committedAt'] as num?) != null
          ? DateTime.fromMillisecondsSinceEpoch(
              (j['committedAt'] as num).toInt(),
            )
          : null,
      pr: rawPr is Map
          ? PullRequest.fromJson(Map<String, dynamic>.from(rawPr))
          : null,
    );
  }
}

/// A repo on the home screen: a [Project] enriched with git intelligence —
/// its default/current branch and live worktrees.
class RepoInfo {
  const RepoInfo({
    required this.id,
    required this.name,
    required this.path,
    required this.pinned,
    required this.lastActivityAt,
    required this.isGitRepo,
    required this.defaultBranch,
    required this.currentBranch,
    required this.worktrees,
  });

  final String id;
  final String name;
  final String path;
  final bool pinned;
  final int lastActivityAt;
  final bool isGitRepo;
  final String? defaultBranch;
  final String? currentBranch;
  final List<Worktree> worktrees;

  /// Total added/removed lines across every worktree.
  int get totalInsertions => worktrees.fold(0, (a, w) => a + w.insertions);
  int get totalDeletions => worktrees.fold(0, (a, w) => a + w.deletions);

  /// Worktrees that have any uncommitted/committed diff vs the default branch.
  int get activeWorktreeCount => worktrees.where((w) => w.hasChanges).length;

  /// Worktrees with an **open** pull request. Merged/closed PRs are history, so
  /// they don't count towards the repo card's "N PRs" meta.
  int get openPrCount =>
      worktrees.where((w) => w.pr?.state.toUpperCase() == 'OPEN').length;

  static RepoInfo? fromJson(Map<String, dynamic> j) {
    final id = j['id'];
    final name = j['name'];
    final path = j['path'];
    if (id is! String || name is! String || path is! String) return null;
    return RepoInfo(
      id: id,
      name: name,
      path: path,
      pinned: j['pinned'] == true,
      lastActivityAt: (j['lastActivityAt'] as num?)?.toInt() ?? 0,
      isGitRepo: j['isGitRepo'] == true,
      defaultBranch: j['defaultBranch'] is String
          ? j['defaultBranch'] as String
          : null,
      currentBranch: j['currentBranch'] is String
          ? j['currentBranch'] as String
          : null,
      worktrees: ((j['worktrees'] as List?) ?? const [])
          .whereType<Map<dynamic, dynamic>>()
          .map((m) => Worktree.fromJson(Map<String, dynamic>.from(m)))
          .whereType<Worktree>()
          .toList(),
    );
  }
}

/// Metadata about a prior on-disk pi session, for the "attach" list.
class PiSessionMeta {
  const PiSessionMeta({
    required this.piSessionId,
    required this.name,
    required this.lastActivityAt,
    required this.preview,
    required this.messageCount,
    this.attached = false,
  });

  final String piSessionId;
  final String name;
  final int lastActivityAt;
  final String preview;
  final int messageCount;
  final bool attached;

  static PiSessionMeta? fromJson(Map<String, dynamic> j) {
    final id = j['piSessionId'] as String?;
    if (id == null) return null;
    return PiSessionMeta(
      piSessionId: id,
      name: (j['name'] as String?) ?? '',
      lastActivityAt: (j['lastActivityAt'] as num?)?.toInt() ?? 0,
      preview: (j['preview'] as String?) ?? '',
      messageCount: (j['messageCount'] as num?)?.toInt() ?? 0,
      attached: j['attached'] == true,
    );
  }
}

/// A directory entry returned by `project.browse`. Directories only; [isRepo]
/// marks git repositories so the picker can highlight them.
class FolderEntry {
  const FolderEntry({
    required this.name,
    required this.path,
    required this.isRepo,
  });

  final String name;
  final String path;
  final bool isRepo;

  /// Defensive: returns null when [name] or [path] is missing/wrong-typed so
  /// the caller can skip the bad entry instead of throwing.
  static FolderEntry? fromJson(Map<String, dynamic> j) {
    final name = j['name'];
    final path = j['path'];
    if (name is! String || path is! String) return null;
    return FolderEntry(name: name, path: path, isRepo: j['isRepo'] == true);
  }
}

/// Result of a `project.browse` request: the resolved absolute [path], its
/// [parent] (null at the filesystem root), and the child directory [entries].
class BrowseResult {
  const BrowseResult({
    required this.path,
    required this.parent,
    required this.entries,
  });

  final String path;
  final String? parent;
  final List<FolderEntry> entries;

  /// Defensive parse: bad [entries] are skipped, a bad [parent] becomes null,
  /// and a missing [path] falls back to empty — never throws.
  static BrowseResult fromJson(Map<String, dynamic> j) {
    final raw = j['entries'];
    final entries = raw is List
        ? raw
              .whereType<Map<dynamic, dynamic>>()
              .map((m) => FolderEntry.fromJson(Map<String, dynamic>.from(m)))
              .whereType<FolderEntry>()
              .toList()
        : <FolderEntry>[];
    return BrowseResult(
      path: j['path'] is String ? j['path'] as String : '',
      parent: j['parent'] is String ? j['parent'] as String : null,
      entries: entries,
    );
  }
}

enum SessionStatus {
  idle,
  running,
  awaitingInput,
  awaitingApproval,
  error,
  exited,
}

SessionStatus parseStatus(String s) => switch (s) {
  'idle' => SessionStatus.idle,
  'running' => SessionStatus.running,
  'awaiting-input' => SessionStatus.awaitingInput,
  'awaiting-approval' => SessionStatus.awaitingApproval,
  'error' => SessionStatus.error,
  'exited' => SessionStatus.exited,
  _ => SessionStatus.idle,
};

enum ApprovalPolicy { yolo, askOnRisky, askAlways }

ApprovalPolicy parsePolicy(String s) => switch (s) {
  'yolo' => ApprovalPolicy.yolo,
  'ask-on-risky' => ApprovalPolicy.askOnRisky,
  'ask-always' => ApprovalPolicy.askAlways,
  _ => ApprovalPolicy.askOnRisky,
};

/// Multiplexer pane locator for a session running in a pane (SPEC-05).
class PaneInfo {
  const PaneInfo({required this.mux, required this.paneId});
  final String mux;
  final String paneId;

  static PaneInfo? fromJson(Map<String, dynamic> j) {
    final mux = j['mux'];
    final paneId = j['paneId'];
    if (mux is! String || paneId is! String) return null;
    return PaneInfo(mux: mux, paneId: paneId);
  }

  @override
  bool operator ==(Object other) =>
      other is PaneInfo && other.mux == mux && other.paneId == paneId;

  @override
  int get hashCode => Object.hash(mux, paneId);
}

class Session {
  Session({
    required this.id,
    required this.projectId,
    required this.agent,
    required this.title,
    required this.status,
    required this.policy,
    this.lastActivityAt = 0,
    this.lastPreview = '',
    this.pane,
    this.pending = false,
    this.pendingAgent,
    this.branch,
    this.worktreePath,
    this.resumable = false,
    this.archived = false,
    this.orphaned = false,
  });

  final String id;
  final String projectId;
  final String agent;
  final String title;
  final SessionStatus status;
  final ApprovalPolicy policy;
  final int lastActivityAt;
  final String lastPreview;

  /// Set when this session runs in a multiplexer pane (SPEC-05).
  final PaneInfo? pane;

  /// Draft session: worktree + agent are deferred until the first real message.
  final bool pending;

  /// Chosen harness for a still-pending draft (before its worktree exists).
  final String? pendingAgent;

  /// Branch this session runs on, once its worktree exists.
  final String? branch;

  /// Absolute worktree path, once created.
  final String? worktreePath;

  /// True when a (possibly cold) session can be brought back to a live agent
  /// after a server restart (SPEC-29). Drives auto-attach on subscribe.
  final bool resumable;

  /// Archived (SPEC-29): hidden from the active list. Present for surfaces that
  /// explicitly list archived sessions; the active snapshot omits these.
  final bool archived;

  /// Orphaned (SPEC-29): an archived session whose worktree was removed. Only
  /// set on the `session.listArchived` result; drives the "worktree removed"
  /// chip in the archive view. Restoring an orphaned session runs it at the
  /// repo root (no recreate-worktree path).
  final bool orphaned;

  Session copyWith({
    SessionStatus? status,
    ApprovalPolicy? policy,
    String? title,
    int? lastActivityAt,
    String? lastPreview,
    PaneInfo? pane,
    bool clearPane = false,
    bool? pending,
    String? pendingAgent,
    String? branch,
    String? worktreePath,
    bool? resumable,
    bool? archived,
    bool? orphaned,
  }) => Session(
    id: id,
    projectId: projectId,
    agent: agent,
    title: title ?? this.title,
    status: status ?? this.status,
    policy: policy ?? this.policy,
    lastActivityAt: lastActivityAt ?? this.lastActivityAt,
    lastPreview: lastPreview ?? this.lastPreview,
    pane: clearPane ? null : (pane ?? this.pane),
    pending: pending ?? this.pending,
    pendingAgent: pendingAgent ?? this.pendingAgent,
    branch: branch ?? this.branch,
    worktreePath: worktreePath ?? this.worktreePath,
    resumable: resumable ?? this.resumable,
    archived: archived ?? this.archived,
    orphaned: orphaned ?? this.orphaned,
  );
}
