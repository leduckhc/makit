// Which forge hosts a pull request, derived from its URL. Pure Dart — no
// widgets — so the classification rules are pinned here and the widget layer
// only has to prove the glyph is rendered.
import 'package:flutter_test/flutter_test.dart';
import 'package:makit/ui/widgets/forge_glyph.dart';

void main() {
  group('forgeKindForUrl', () {
    test('recognises github.com and its subdomains', () {
      expect(
        forgeKindForUrl('https://github.com/acme/app/pull/42'),
        ForgeKind.github,
      );
      expect(
        forgeKindForUrl('https://www.github.com/acme/app/pull/42'),
        ForgeKind.github,
      );
    });

    test('is not fooled by a lookalike host', () {
      // Mirrors the server router's isGitHubHost: a suffix test alone would
      // classify an attacker-controlled host as GitHub. It is now unnamed rather
      // than named as some other forge.
      expect(
        forgeKindForUrl('https://github.com.evil.test/a/b/pull/1'),
        isNull,
      );
      expect(forgeKindForUrl('https://notgithub.com/a/b/pull/1'), isNull);
    });

    test('recognises gitea.com explicitly', () {
      expect(
        forgeKindForUrl('https://gitea.com/gitea/tea/pulls/1'),
        ForgeKind.gitea,
      );
    });

    test('an unidentifiable host is left UNNAMED, not guessed', () {
      // It used to report every non-GitHub host as Forgejo, which agreed with the
      // router while the router also guessed by hostname. The router now probes the
      // instance, so the guess could contradict the provider that served the data --
      // putting Forgejo's name and mark on a self-hosted Gitea or a GitLab remote.
      expect(
        forgeKindForUrl('https://codeberg.org/forgejo/forgejo/pulls/1'),
        isNull,
      );
      expect(
        forgeKindForUrl('https://git.example.com:3000/a/b/pulls/1'),
        isNull,
      );
    });

    test("the server's detected software wins over the URL", () {
      // The daemon asks the instance what it runs, which is the only way to know.
      expect(
        forgeKindForUrl(
          'https://git.example.com/a/b/pulls/1',
          detected: 'forgejo',
        ),
        ForgeKind.forgejo,
      );
      expect(
        forgeKindForUrl(
          'https://git.example.com/a/b/pulls/1',
          detected: 'gitea',
        ),
        ForgeKind.gitea,
      );
    });

    test('a forge the app has no mark for stays unnamed', () {
      expect(
        forgeKindForUrl('https://gl.example.com/a/b/-/1', detected: 'gitlab'),
        isNull,
      );
      expect(
        forgeKindForUrl('https://x.example.com/a/b/1', detected: 'unknown'),
        isNull,
      );
    });

    test('returns null when there is no URL to classify', () {
      // Null, not a default glyph: claiming a forge we did not measure would put
      // a wrong logo beside a PR.
      expect(forgeKindForUrl(null), isNull);
      expect(forgeKindForUrl(''), isNull);
      expect(forgeKindForUrl('not a url'), isNull);
      expect(forgeKindForUrl('/relative/path'), isNull);
    });
  });

  group('forgeGlyphFor', () {
    test('every kind has a glyph', () {
      for (final kind in ForgeKind.values) {
        expect(forgeGlyphFor(kind), isNotNull, reason: '$kind has no glyph');
      }
    });

    test('GitHub uses the Phosphor font glyph, the others use our SVGs', () {
      // GitHub's mark ships in Phosphor; Forgejo's and Gitea's do not, hence the
      // in-house SVGs on the same 256 grid.
      expect(
        forgeGlyphFor(ForgeKind.forgejo),
        forgeGlyphFor(ForgeKind.forgejo),
      );
      expect(
        forgeGlyphFor(ForgeKind.forgejo) == forgeGlyphFor(ForgeKind.gitea),
        isFalse,
      );
      expect(
        forgeGlyphFor(ForgeKind.github) == forgeGlyphFor(ForgeKind.forgejo),
        isFalse,
      );
    });
  });

  group('forgeNameFor', () {
    test('names each forge as that project spells it', () {
      expect(forgeNameFor(ForgeKind.github), 'GitHub');
      expect(forgeNameFor(ForgeKind.forgejo), 'Forgejo');
      expect(forgeNameFor(ForgeKind.gitea), 'Gitea');
    });
  });

  group('forgeGlyphForUrl', () {
    test('composes classification and glyph lookup', () {
      expect(
        forgeGlyphForUrl('https://gitea.com/a/b/pulls/1'),
        forgeGlyphFor(ForgeKind.gitea),
      );
      expect(forgeGlyphForUrl(null), isNull);
      // An unidentifiable host composes to no glyph, rather than to Forgejo's.
      expect(forgeGlyphForUrl('https://git.example.com/a/b/pulls/1'), isNull);
    });
  });

  group('asset paths', () {
    test('point at glyphs that are actually declared in pubspec assets', () {
      // assets/icons/ is bundled wholesale, so a typo here fails only at runtime
      // as an invisible icon. Pin the exact names the sync script vendors.
      expect(kForgejoAsset, 'assets/icons/forgejo-light.svg');
      expect(kGiteaAsset, 'assets/icons/gitea-light.svg');
    });
  });
}
