/// Route paths, in one place.
///
/// The connect/servers surface is the app's **root**: the repo list is pushed on
/// top of it, so backing out of the repos lands on the server picker instead of
/// nowhere. That nesting means every screen below the repo list carries the
/// `/repos` prefix, and a hand-written literal is easy to get subtly wrong — so
/// the paths live here rather than being spelled out at ~16 call sites.
///
/// Deliberately imports nothing: `router.dart` imports every screen, and the
/// screens need these paths, so putting them there would create an import cycle.
library;

/// The connect / servers page. Root of the stack, and where onboarding lives
/// until it completes.
const kRouteRoot = '/';

/// The repo list — the working surface, and what a launch lands on once paired.
const kRouteRepos = '/repos';

const kRouteSettings = '$kRouteRepos/settings';
const kRouteArchived = '$kRouteRepos/archived';
const kRouteDiagnostics = '$kRouteRepos/diagnostics';

/// The Activity feed (SPEC-48) — every outcome the app has reported, with the
/// error text still attached.
const kRouteActivity = '$kRouteRepos/activity';

/// The global Ports screen (SPEC-42 P2a) — "everything, all repos". Accepts an
/// optional `?repo=<id>` that pre-selects the *This repo* filter.
const kRoutePorts = '$kRouteRepos/ports';

/// The global Docs screen (SPEC-46 P1) — the repo's mockups and specs, grouped
/// repo → worktree.
const kRouteDocs = '$kRouteRepos/docs';

/// A single session's screen.
String routeForSession(String sessionId) => '$kRouteRepos/session/$sessionId';
