# Mobile redesign mocks

Static HTML mocks for the mobile home screen. Open either file in a browser.

- `repo-card.html` — Baseline (what ships) vs three directions (A/B/C)
- `servers.html` — first-run pairing, `/servers` manager, home switcher sheet

Colours, type and spacing are the **real tokens**, dumped from
`app/lib/app/theme.dart` — including `primary #98d4a3`, so the mocks show what
actually renders rather than an idealised palette. Icons are Phosphor (CDN),
the same family the app uses. Agent avatars are the app's own SVGs.

These are throwaway review artefacts, not a design system. Delete once a
direction is chosen and built.
