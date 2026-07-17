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
  });

  final String id;
  final String label;

  /// `native` | `acp`.
  final String transport;
  final bool available;

  static AgentDescriptor? fromJson(Map<String, dynamic> j) {
    final id = j['id'] as String?;
    if (id == null) return null;
    return AgentDescriptor(
      id: id,
      label: (j['label'] as String?) ?? id,
      transport: (j['transport'] as String?) ?? 'native',
      available: (j['available'] as bool?) ?? true,
    );
  }
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
  });

  final ModelInfo? model;
  final String thinking;
  final List<ModelInfo> models;

  /// ACP session modes (e.g. ask/code/architect), when the agent is an ACP
  /// agent that advertises them. Native pi has no modes (null); ACP has no
  /// model/thinking. Drives the composer's mode selector.
  final SessionModes? modes;

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

/// An open pull request tied to a worktree's branch (surfaced via `gh`).
class PullRequest {
  const PullRequest({
    required this.number,
    required this.url,
    required this.state,
    required this.title,
    required this.isDraft,
  });

  final int number;
  final String url;
  final String state;
  final String title;
  final bool isDraft;

  static PullRequest? fromJson(Map<String, dynamic> j) {
    final number = j['number'];
    if (number is! num) return null;
    return PullRequest(
      number: number.toInt(),
      url: j['url'] is String ? j['url'] as String : '',
      state: j['state'] is String ? j['state'] as String : 'OPEN',
      title: j['title'] is String ? j['title'] as String : '',
      isDraft: j['isDraft'] == true,
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

  int get openPrCount => worktrees.where((w) => w.pr != null).length;

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
  );
}
