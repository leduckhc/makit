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
    this.baseRefName,
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

  /// The branch this PR merges into. "Wrap up" fast-forwards this one after the
  /// PR lands; null on a server that predates the field, and the server then
  /// falls back to the repo's default branch.
  final String? baseRefName;

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
      baseRefName: j['baseRefName'] is String
          ? j['baseRefName'] as String
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

/// Context-window + cost snapshot for one session (SPEC-37), pushed via the
/// `session.usage` event.
///
/// Every reading is nullable because the three sources report different subsets:
/// codex sends a full token breakdown and window but no cost, ACP sends only
/// used/size/cost, and pi (which reports nothing over ACP) sends what
/// `ctx.getContextUsage()` knows. **Null means unmeasured, never zero** — the
/// same rule [BudgetBucket] follows, because a zeroed bar and an unknown bar
/// mean opposite things.
class SessionUsage {
  const SessionUsage({
    this.contextTokens,
    this.contextWindow,
    this.totals,
    this.cost,
    required this.measuredAt,
  });

  /// Tokens currently occupying the context window — the numerator of
  /// [fraction]. This is the last request's total, not the session total.
  final int? contextTokens;

  /// Context window size in tokens, when the agent reports one.
  final int? contextWindow;

  /// Cumulative session token counts — **billing**, not context occupancy.
  /// Deliberately a separate field so it can never be drawn against
  /// [contextWindow].
  final SessionUsageTotals? totals;

  /// Cumulative session cost, when the agent prices its own calls.
  final UsageCost? cost;

  /// Epoch ms this snapshot was measured (0 when the server omitted it).
  final int measuredAt;

  /// Share of the context window in use, or null when either half is unmeasured.
  ///
  /// Clamped to 1.0: providers occasionally report a context slightly past the
  /// advertised window, which would otherwise overflow the bar.
  double? get fraction {
    final used = contextTokens;
    final window = contextWindow;
    if (used == null || window == null || window <= 0) return null;
    return (used / window).clamp(0.0, 1.0);
  }

  static int? _int(Object? v) => v is num ? v.toInt() : null;

  static SessionUsage fromJson(Map<String, dynamic> j) => SessionUsage(
    contextTokens: _int(j['contextTokens']),
    contextWindow: _int(j['contextWindow']),
    totals: j['totals'] is Map
        ? SessionUsageTotals.fromJson(
            Map<String, dynamic>.from(j['totals'] as Map),
          )
        : null,
    cost: j['cost'] is Map
        ? UsageCost.fromJson(Map<String, dynamic>.from(j['cost'] as Map))
        : null,
    measuredAt: _int(j['measuredAt']) ?? 0,
  );
}

/// Cumulative per-category token counts for a session (SPEC-37) — what the
/// session has *billed*, as opposed to what currently occupies the context.
/// Only codex reports these; every field is null for the other agents.
class SessionUsageTotals {
  const SessionUsageTotals({
    this.total,
    this.input,
    this.cachedInput,
    this.cacheWrite,
    this.output,
    this.reasoning,
  });

  final int? total;
  final int? input;

  /// Input tokens served from the provider's prompt cache.
  final int? cachedInput;

  /// Input tokens written *into* the cache.
  final int? cacheWrite;
  final int? output;

  /// Reasoning/thinking output tokens, when billed separately.
  final int? reasoning;

  static SessionUsageTotals fromJson(Map<String, dynamic> j) {
    int? at(String k) => j[k] is num ? (j[k] as num).toInt() : null;
    return SessionUsageTotals(
      total: at('total'),
      input: at('input'),
      cachedInput: at('cachedInput'),
      cacheWrite: at('cacheWrite'),
      output: at('output'),
      reasoning: at('reasoning'),
    );
  }
}

/// Cumulative session cost. Both halves are required: an amount with no currency
/// cannot be rendered honestly, so a partial cost is treated as no cost at all.
class UsageCost {
  const UsageCost({required this.amount, required this.currency});

  final double amount;
  final String currency;

  static UsageCost? fromJson(Map<String, dynamic> j) {
    final amount = j['amount'];
    final currency = j['currency'];
    if (amount is! num || currency is! String) return null;
    return UsageCost(amount: amount.toDouble(), currency: currency);
  }
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
    this.targetBranch,
    this.targetResolved = true,
    this.retargetedFrom,
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

  /// The branch this worktree's work lands in: what [insertions]/[deletions]
  /// measure against (`git diff target...HEAD` — what a PR into it would
  /// contain), what a PR will target, and what a wrap-up fast-forwards.
  ///
  /// Null for the primary checkout (it *is* where branches land) and for a
  /// detached worktree (no branch to land).
  final String? targetBranch;

  /// False when [targetBranch] could not be resolved (deleted, never fetched):
  /// the diff numbers are then working-tree-only and the committed delta is
  /// unknown. Prefer [showsDiff] over reading this directly.
  ///
  /// Defaults to true so an older server that sends neither field keeps today's
  /// rendering instead of blanking every pill.
  final bool targetResolved;

  /// The target this one replaced, when makit changed it automatically: the
  /// branch we were aiming at vanished without a wrap-up, so we fell back to the
  /// repo default (or to wherever the chain actually landed).
  ///
  /// Present so the change can be **announced**. A silent repoint moves this
  /// worktree's diff and its future pull request to a different destination, and
  /// doing that invisibly is how someone opens a PR against the wrong branch.
  /// Cleared once the user picks a target explicitly — by then they own the value
  /// and there is nothing left to tell them.
  final String? retargetedFrom;

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

  /// True when the target exists but could not be resolved — the one state that
  /// needs explaining rather than rendering.
  bool get targetUnresolved => targetBranch != null && !targetResolved;

  /// Whether the +/- diff may be shown.
  ///
  /// Not just [hasChanges]: when the target cannot be resolved the numbers are a
  /// working-tree-only figure, so painting them would assert a committed delta
  /// that was never measured. The failure mode is not a zero but a *plausible
  /// small* count — which reads as "barely diverged" on a worktree that may be
  /// far ahead — so suppression has to be explicit.
  bool get showsDiff => hasChanges && !targetUnresolved;

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
      targetBranch: j['targetBranch'] is String
          ? j['targetBranch'] as String
          : null,
      targetResolved: j['targetResolved'] is bool
          ? j['targetResolved'] as bool
          : true,
      retargetedFrom: j['retargetedFrom'] is String
          ? j['retargetedFrom'] as String
          : null,
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

/// Why a branch is offered as a target — the picker's section headers.
///
/// `defaultBranch` rather than `default`, which is a Dart keyword.
enum TargetCandidateGroup {
  /// The closest ancestor branch: the honest suggestion, and the one today's
  /// pill gets wrong for a stacked worktree.
  forkedFrom('Forked from'),

  /// The repo's default branch — what you want once a stack lands.
  defaultBranch('Repo default'),

  /// Checked out in another worktree: the stacked case.
  worktree('Other worktrees'),

  /// Everything else, behind a filter.
  other('All branches');

  const TargetCandidateGroup(this.label);

  /// Section header text.
  final String label;

  /// Wire value -> enum, defaulting to [other] so a newer server's group name
  /// degrades to "listed under All branches" instead of throwing.
  static TargetCandidateGroup fromWire(String? raw) => switch (raw) {
    'forkedFrom' => TargetCandidateGroup.forkedFrom,
    'default' => TargetCandidateGroup.defaultBranch,
    'worktree' => TargetCandidateGroup.worktree,
    _ => TargetCandidateGroup.other,
  };
}

/// One row in the "Lands in" picker.
class TargetCandidate {
  const TargetCandidate({
    required this.branch,
    required this.group,
    required this.onRemote,
    required this.isSelf,
    this.insertions,
    this.deletions,
  });

  final String branch;
  final TargetCandidateGroup group;

  /// Whether the branch exists on a remote. A pull-request base must, so a
  /// local-only branch is shown disabled with a reason rather than accepted and
  /// then refused by `gh`.
  final bool onRemote;

  /// True for the worktree's own branch: listed so the picker can explain why it
  /// is not selectable, rather than leaving an unexplained gap.
  final bool isSelf;

  /// What the diff would become. Null when the server did not preview this
  /// candidate (only the ranked few are previewed) or could not measure it.
  final int? insertions;
  final int? deletions;

  bool get hasPreview => insertions != null && deletions != null;

  /// Whether picking this row is allowed.
  bool get selectable => !isSelf && onRemote;

  /// Why it is not selectable, in the user's terms — null when it is.
  ///
  /// Follows the "explain the block, don't hide it" convention the worktree and
  /// PR action menus already use.
  String? get blockedReason {
    if (isSelf) return 'this worktree';
    if (!onRemote) return 'not pushed yet';
    return null;
  }

  static TargetCandidate? fromJson(Map<String, dynamic> j) {
    final branch = j['branch'];
    if (branch is! String || branch.isEmpty) return null;
    return TargetCandidate(
      branch: branch,
      group: TargetCandidateGroup.fromWire(j['group'] as String?),
      onRemote: j['onRemote'] != false,
      isSelf: j['isSelf'] == true,
      insertions: (j['insertions'] as num?)?.toInt(),
      deletions: (j['deletions'] as num?)?.toInt(),
    );
  }
}

/// A repo on the home screen: a [Project] enriched with git intelligence —
/// its default/current branch and live worktrees.
/// Where an effective per-repo value came from. Drives the badge; the app is told
/// this rather than deriving it, so one rule lives on the server.
enum SettingSource { override, environment, defaultValue }

SettingSource _sourceFrom(Object? raw) => switch (raw) {
  'override' => SettingSource.override,
  'environment' => SettingSource.environment,
  // Anything unrecognised reads as the default rather than throwing: a newer
  // server adding a source must not crash an older app.
  _ => SettingSource.defaultValue,
};

/// An effective value and its source.
class Resolved<T> {
  const Resolved(this.value, this.source);
  final T value;
  final SettingSource source;

  /// True when a repo-level value replaces the inherited one — the only state that
  /// earns a reset affordance.
  bool get isOverride => source == SettingSource.override;

  @override
  bool operator ==(Object other) =>
      other is Resolved<T> && other.value == value && other.source == source;
  @override
  int get hashCode => Object.hash(value, source);
}

/// What detection concluded about a repo's forge.
class RepoForge {
  const RepoForge({required this.software, required this.host, this.authed});
  final String software;
  final String host;

  /// Whether a credential is configured for that host. Absent for GitHub, where
  /// `gh`'s budget is not host-specific authentication.
  final bool? authed;

  static RepoForge? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final j = Map<String, dynamic>.from(raw);
    final software = j['software'];
    final host = j['host'];
    if (software is! String || host is! String) return null;
    return RepoForge(
      software: software,
      host: host,
      authed: j['authed'] is bool ? j['authed'] as bool : null,
    );
  }
}

/// Per-repo settings as the server resolved them.
class RepoSettings {
  const RepoSettings({
    required this.worktreeRoot,
    required this.provider,
    required this.hasRemote,
    this.defaultBranch,
    this.logoHue,
    this.forge,
  });

  final Resolved<String> worktreeRoot;
  final Resolved<String> provider;

  /// False = no `origin`, so no forge is possible. A different statement from
  /// "not identified yet", which is [forge] being null.
  final bool hasRemote;

  /// Present ONLY when overridden; otherwise read `RepoInfo.defaultBranch`.
  final Resolved<String>? defaultBranch;
  final int? logoHue;

  /// Null means detection has not run for this repo yet, never "no forge".
  final RepoForge? forge;

  static RepoSettings? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final j = Map<String, dynamic>.from(raw);
    final root = _resolvedString(j['worktreeRoot']);
    if (root == null) return null;
    return RepoSettings(
      worktreeRoot: root,
      provider:
          _resolvedString(j['provider']) ??
          const Resolved('auto', SettingSource.defaultValue),
      hasRemote: j['hasRemote'] == true,
      defaultBranch: _resolvedString(j['defaultBranch']),
      logoHue: j['logoHue'] is num ? (j['logoHue'] as num).toInt() : null,
      forge: RepoForge.fromJson(j['forge']),
    );
  }

  static Resolved<String>? _resolvedString(Object? raw) {
    if (raw is! Map) return null;
    final v = raw['value'];
    if (v is! String) return null;
    return Resolved(v, _sourceFrom(raw['source']));
  }
}

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
    this.settings,
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

  /// Per-repo settings, or null when the server did not send any — an older
  /// server, in which case the settings section renders nothing rather than
  /// fabricating defaults.
  final RepoSettings? settings;

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
      settings: RepoSettings.fromJson(j['settings']),
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
    this.createdAt,
    this.lastPreview = '',
    this.pane,
    this.pending = false,
    this.pendingAgent,
    this.branch,
    this.worktreePath,
    this.resumable = false,
    this.closed = false,
    this.orphaned = false,
    this.parentId,
    this.handoffReason,
    this.origin,
    this.queued = const [],
  });

  final String id;
  final String projectId;
  final String agent;
  final String title;
  final SessionStatus status;
  final ApprovalPolicy policy;
  final int lastActivityAt;

  /// When this session was created, in epoch ms (SPEC-47 D12), or null when the
  /// server did not report one (an older server, or a session that predates the
  /// field). **Nullable rather than `0`-as-unknown** like [lastActivityAt]: an
  /// absent age is not rendered rather than fabricated as "56 years".
  final int? createdAt;
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

  /// Closed (SPEC-29): hidden from the active list. Present for surfaces that
  /// explicitly list closed sessions; the active snapshot omits these.
  final bool closed;

  /// Orphaned (SPEC-29): a closed session whose worktree was removed. Only
  /// set on the `session.listClosed` result; drives the "worktree removed"
  /// chip in the closed view. Restoring an orphaned session runs it at the
  /// repo root (no recreate-worktree path).
  final bool orphaned;

  /// SPEC-46 lineage (D10): the session this one was handed off / spawned from,
  /// so the app can caption "handed off from …". Null for a session with no
  /// parent (every session created before SPEC-46, and every app-spawned one).
  final String? parentId;

  /// SPEC-46 (D10): why the handoff happened, as written by the outgoing agent.
  final String? handoffReason;

  /// SPEC-46 (D10): which client created this session ("app"/"cli"/"agent").
  /// Null on pre-SPEC-46 rows; a plain string so an unknown value never throws.
  final String? origin;

  /// Messages submitted while the agent was busy that could not be steered into
  /// the running turn (SPEC-35), oldest first. They are delivered one per idle
  /// transition and can be cancelled until then.
  final List<QueuedMessage> queued;

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
    bool? closed,
    bool? orphaned,
    String? parentId,
    String? handoffReason,
    String? origin,
    List<QueuedMessage>? queued,
  }) => Session(
    id: id,
    projectId: projectId,
    agent: agent,
    title: title ?? this.title,
    status: status ?? this.status,
    policy: policy ?? this.policy,
    lastActivityAt: lastActivityAt ?? this.lastActivityAt,
    createdAt: createdAt,
    lastPreview: lastPreview ?? this.lastPreview,
    pane: clearPane ? null : (pane ?? this.pane),
    pending: pending ?? this.pending,
    pendingAgent: pendingAgent ?? this.pendingAgent,
    branch: branch ?? this.branch,
    worktreePath: worktreePath ?? this.worktreePath,
    resumable: resumable ?? this.resumable,
    closed: closed ?? this.closed,
    orphaned: orphaned ?? this.orphaned,
    parentId: parentId ?? this.parentId,
    handoffReason: handoffReason ?? this.handoffReason,
    origin: origin ?? this.origin,
    queued: queued ?? this.queued,
  );
}

/// What the server's `worktree.wrapUp` actually did.
///
/// The base-branch leg is best-effort by design (the worktree is already gone by
/// then, so a failed fast-forward is a partial success, not an error), which is
/// why this reports rather than throws: the UI turns it into "worktree removed ·
/// main up to date" or "worktree removed · main left alone (it has local
/// commits)".
class WrapUpReport {
  const WrapUpReport({
    this.branchDeleted,
    this.branchReason,
    this.targetBranch,
    this.targetUpdated = false,
    this.targetReason,
  });

  /// The local branch that was deleted, or null for a detached worktree — or for
  /// one whose deletion failed, in which case [branchReason] says why.
  final String? branchDeleted;

  /// Why the branch survived when it should have gone. Like [targetReason] this is
  /// reported rather than thrown: the worktree is already removed by then, so the
  /// job partly succeeded and the client cannot retry it.
  final String? branchReason;

  /// The branch that was caught up, or null when none could be resolved.
  final String? targetBranch;

  /// True when [targetBranch] actually moved.
  final bool targetUpdated;

  /// Why [targetBranch] was not updated, when that is worth telling the user.
  /// Null for the benign "already up to date" case — that is not a problem.
  final String? targetReason;

  /// Tolerant decode: an empty/garbage ack degrades to "nothing reported"
  /// rather than throwing, because by the time this arrives the worktree has
  /// already been removed and the user needs to be told *something*.
  static WrapUpReport fromJson(Map<String, dynamic> j) => WrapUpReport(
    branchDeleted: j['branchDeleted'] is String
        ? j['branchDeleted'] as String
        : null,
    branchReason: j['branchReason'] is String
        ? j['branchReason'] as String
        : null,
    // `targetBranch` is the name; `baseBranch` is read for one release so a
    // server that predates the rename still produces a complete report.
    targetBranch: j['targetBranch'] is String
        ? j['targetBranch'] as String
        : (j['baseBranch'] is String ? j['baseBranch'] as String : null),
    // Same one-release aliases as `targetBranch` above.
    targetUpdated: j['targetUpdated'] == true || j['baseUpdated'] == true,
    targetReason: j['targetReason'] is String
        ? j['targetReason'] as String
        : (j['baseReason'] is String ? j['baseReason'] as String : null),
  );

  /// One line for a snackbar, e.g. `Removed feat/x · main updated`, or
  /// `Worktree removed · branch kept · main updated` when the branch survived.
  String get summary {
    final parts = <String>[
      if (branchDeleted != null)
        'Removed $branchDeleted'
      else
        'Worktree removed',
      // Never silently imply the branch went when it did not.
      if (branchDeleted == null && branchReason != null) 'branch kept',
      if (targetBranch != null)
        targetUpdated ? '$targetBranch updated' : '$targetBranch unchanged',
    ];
    return parts.join(' · ');
  }

  /// The full explanation behind [summary], for the snackbar's "Why?" action.
  /// Null when everything went as advertised — both legs are best-effort, and
  /// either can have something to say.
  String? get detail {
    final reasons = [?branchReason, ?targetReason];
    return reasons.isEmpty ? null : reasons.join('\n');
  }
}

/// One message waiting for the agent to go idle (SPEC-35). [attachmentCount] is
/// a count, not descriptors: the chip only needs to say "and an image", and the
/// bytes are already safe in the server's media store.
/// Where (and how) a pending mid-turn message is shown (SPEC-38).
///
/// Originally three; `inline` (in the transcript trailer) was removed because
/// it required touching SPEC-21's anchoring and added no value over pinned.
enum PendingQueuePlacement {
  /// Hollow ghost bubbles directly above the composer — always visible.
  pinned,

  /// A compact work list above the composer (mockup variant C): tighter than
  /// the bubbles, same actions.
  tray,
}

class QueuedMessage {
  const QueuedMessage({
    required this.id,
    required this.text,
    required this.queuedAt,
    this.attachmentCount,
  });

  /// Server-assigned; the handle `queue.cancel` takes.
  final String id;
  final String text;
  final int queuedAt;
  final int? attachmentCount;

  static QueuedMessage? fromJson(Map<String, dynamic> j) {
    final id = j['id'];
    if (id is! String || id.isEmpty) return null;
    return QueuedMessage(
      id: id,
      text: j['text'] is String ? j['text'] as String : '',
      queuedAt: j['queuedAt'] is num ? (j['queuedAt'] as num).toInt() : 0,
      attachmentCount: j['attachmentCount'] is num
          ? (j['attachmentCount'] as num).toInt()
          : null,
    );
  }
}
