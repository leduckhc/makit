# Mobile redesign mocks

Static HTML mocks used to pick a direction before writing Dart. Open in a browser.

- `repo-card.html` — Baseline vs three directions (A/B/C)
- `servers.html` — first-run pairing, server manager, home switcher sheet

Colours, type and spacing are the **real tokens**, dumped from
`app/lib/app/theme.dart` — including `primary #98d4a3` — so the mocks show what
actually renders rather than an idealised palette. Icons are Phosphor (CDN), the
same family the app uses.

## Outcome

**Repo card → direction C (status-forward)** was chosen and built.

**Servers**: the manager was folded into the first-run connect screen, which is
now the single server surface (list + Add server + demo data). The separate
`/servers` manager screen and the home-title switcher were both dropped.

So `servers.html` no longer matches what ships — it is kept only as a record of
what was compared. `repo-card.html` column C is the built design.
