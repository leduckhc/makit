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

/// Classify the forge from a pull-request URL, or null when there is nothing to
/// classify.
///
/// Null rather than a default: putting a GitHub mark beside a PR we never
/// identified would be a claim we cannot support, the same null-versus-zero rule
/// the PR lookup follows on the server.
///
/// Anything that is not GitHub or gitea.com is reported as Forgejo. That is a
/// guess — a hostname cannot tell you which software a server runs — but it is
/// deliberately the SAME guess the server's forge router makes when it picks a
/// provider, so the glyph always agrees with whichever provider actually served
/// the data. If the router's rule changes, change this with it.
ForgeKind? forgeKindForUrl(String? url) {
  if (url == null || url.isEmpty) return null;
  final uri = Uri.tryParse(url);
  final host = uri?.host.toLowerCase();
  if (host == null || host.isEmpty) return null;
  if (host == 'github.com' || host.endsWith('.github.com')) {
    return ForgeKind.github;
  }
  if (host == 'gitea.com' || host.endsWith('.gitea.com')) return ForgeKind.gitea;
  return ForgeKind.forgejo;
}

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
