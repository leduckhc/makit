import 'package:phosphoricons_flutter/phosphoricons_flutter.dart';

import 'icon_glyph.dart';

/// The Forgejo mark. Phosphor ships no forge logos, so this is an in-house SVG
/// drawn on Phosphor's 256 grid with the weight carried by stroke width — the
/// same construction as [kClosedPrAsset]. Light, because every glyph the app
/// renders is `PhosphorIconsLight`; a heavier sibling would read bolder than its
/// neighbours.
///
/// Source of truth is the `phosphor_extras` repo; `scripts/sync-icons.sh` vendors
/// the built SVG here and `--check` fails if the copy drifts.
const kForgejoAsset = 'assets/icons/forgejo-light.svg';

/// The Gitea mark. Same construction and provenance as [kForgejoAsset].
const kGiteaAsset = 'assets/icons/gitea-light.svg';

/// Which forge hosts a pull request.
enum ForgeKind { github, forgejo, gitea }

/// Classify the forge for a pull-request URL, or null when nothing proves one.
///
/// [detected] is the server's own answer (`RepoDTO.settings.forge.software`), and it
/// WINS when supplied: the daemon asks the instance what software it runs, which is
/// the only way to know. Pass it wherever the repo is in scope.
///
/// Without it, only a host that is decisive on its own is claimed — `github.com`,
/// `gitea.com` and `codeberg.org` (Forgejo's own flagship instance). A self-hosted
/// host is left unnamed rather than guessed.
///
/// This used to report every other host as Forgejo. That agreed with the router while
/// the router also guessed by hostname, but the router now probes the instance, so the
/// guess could contradict the provider that actually served the data — labelling a
/// self-hosted Gitea, or a GitLab remote, with Forgejo's name and mark. Null is the
/// same null-versus-zero rule the PR lookup follows on the server, and it is what this
/// widget's own contract already asked for: naming the wrong forge is worse than
/// naming none.
ForgeKind? forgeKindForUrl(String? url, {String? detected}) {
  final fromServer = _kindFromSoftware(detected);
  if (fromServer != null) return fromServer;
  if (url == null || url.isEmpty) return null;
  final uri = Uri.tryParse(url);
  final host = uri?.host.toLowerCase();
  if (host == null || host.isEmpty) return null;
  if (host == 'github.com' || host.endsWith('.github.com')) {
    return ForgeKind.github;
  }
  if (host == 'gitea.com' || host.endsWith('.gitea.com')) {
    return ForgeKind.gitea;
  }
  // Hosts that PROVE a forge on their own, the same way `github.com` does. Codeberg
  // runs Forgejo (it is the project's own flagship instance), so naming it is a fact
  // rather than the hostname guess this function used to make for every host.
  if (host == 'codeberg.org' || host.endsWith('.codeberg.org')) {
    return ForgeKind.forgejo;
  }
  return null;
}

/// The server's `forge.software` string as a [ForgeKind]; null for anything the app
/// has no mark for (`gitlab`, `unknown`, or an absent value).
ForgeKind? _kindFromSoftware(String? software) => switch (software) {
  'github' => ForgeKind.github,
  'forgejo' => ForgeKind.forgejo,
  'gitea' => ForgeKind.gitea,
  _ => null,
};

/// The glyph for [kind]. GitHub's mark ships in Phosphor; the other two do not.
IconGlyph forgeGlyphFor(ForgeKind kind) => switch (kind) {
  ForgeKind.github => const IconGlyph.font(PhosphorIconsLight.githubLogo),
  ForgeKind.forgejo => const IconGlyph.svg(kForgejoAsset),
  ForgeKind.gitea => const IconGlyph.svg(kGiteaAsset),
};

/// How each project spells its own name, for user-facing copy.
String forgeNameFor(ForgeKind kind) => switch (kind) {
  ForgeKind.github => 'GitHub',
  ForgeKind.forgejo => 'Forgejo',
  ForgeKind.gitea => 'Gitea',
};

/// The glyph for the forge hosting [url], or null when it cannot be identified.
IconGlyph? forgeGlyphForUrl(String? url) {
  final kind = forgeKindForUrl(url);
  return kind == null ? null : forgeGlyphFor(kind);
}
