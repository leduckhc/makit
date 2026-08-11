# Bundled icon assets — attribution

Brand logos in [`assets/ide/`](assets/ide/) are used to identify the external
apps the "Open in…" title-bar button can launch. They are the property of their
respective owners and are included here under the licenses below.

| File(s) | App | Source | License |
|---------|-----|--------|---------|
| `visual-studio-code.svg`, `visual-studio-code-light.svg` | Visual Studio Code | [selfhst/icons](https://github.com/selfhst/icons) | CC BY 4.0 |
| `zed.svg`, `zed-light.svg` | Zed | [selfhst/icons](https://github.com/selfhst/icons) | CC BY 4.0 |
| `ghostty.svg`, `ghostty-light.svg` | Ghostty | [selfhst/icons](https://github.com/selfhst/icons) | CC BY 4.0 |
| `cursor.svg` | Cursor | [Simple Icons](https://simpleicons.org) | CC0 1.0 |
| `iterm2.svg` | iTerm2 | [Simple Icons](https://simpleicons.org) | CC0 1.0 |

Apple's Terminal and Finder have no official distributable logo, so the button
uses a neutral Phosphor glyph for those rather than a fabricated mark.

## Glyphs in [`assets/icons/`](assets/icons/)

| File(s) | Role | Source | License |
|---------|------|--------|---------|
| `repo-push.png`, `repo-pull.png` | Composer PR actions | [VS Code codicons](https://github.com/microsoft/vscode-codicons) | CC BY 4.0 |
| `git-pull-request-closed-{thin,light,regular,bold,fill}.svg` | Closed-PR state marker | Original — [`phosphor_extras`](../../phosphor_extras) | MIT |
| `forgejo-light.svg` | Forgejo forge marker | Original reduction of Forgejo's mark to [Phosphor](https://phosphoricons.com) metrics — [`phosphor_extras`](../../phosphor_extras) | MIT (drawing); Forgejo's mark belongs to the Forgejo project |
| `gitea-light.svg` | Gitea forge marker | Original reduction of Gitea's mark to Phosphor metrics — [`phosphor_extras`](../../phosphor_extras) | MIT (drawing); Gitea's mark belongs to the Gitea project |

Glyphs marked *Original* are authored in the **`phosphor_extras`** repo, which is
the source of truth for their geometry and holds the generator and the invariant
checks. `scripts/sync-icons.sh` vendors the built SVGs here (rather than adding a
dependency) so a fresh clone builds without network access to another repo;
`scripts/sync-icons.sh --check` fails if a vendored copy has drifted.

The Forgejo and Gitea glyphs identify those projects' software in the UI —
nominative use. The MIT grant covers our drawings, not the underlying marks.

## Agent logos in [`assets/agents/`](assets/agents/)

Used to identify which coding agent backs a session. Each is the property of its
project and is included for identification only.

| File | Agent | Owner |
|------|-------|-------|
| `claude.svg` | Claude Code | Anthropic |
| `codex.svg` | Codex | OpenAI |
| `pi.svg` | pi | Earendil Works |
