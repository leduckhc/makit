# Third-Party Licenses

Makit is distributed under GPL-3.0-or-later (see [`LICENSE`](./LICENSE)). It
bundles and depends on third-party open source software listed below. All
third-party licenses here are permissive (MIT, BSD, Apache-2.0, 0BSD) and are
compatible with GPL-3.0-or-later distribution.

> **Generated file** — do not edit by hand. Regenerate with
> `python3 scripts/gen_third_party_licenses.py`.

This file is generated from the project's dependency manifests:

- **Server:** `pnpm licenses list --prod` in [`server/`](./server/)
- **App:** direct dependencies from [`app/pubspec.yaml`](./app/pubspec.yaml),
  versions from `app/pubspec.lock`, licenses classified from the local pub cache.

> **Full license texts (app):** the Flutter app bundles the complete license
> text of every Dart/Flutter dependency (direct and transitive) at build time.
> They are viewable at runtime via the standard **Licenses** page
> (`showLicensePage` / `LicenseRegistry`). The table below lists direct
> dependencies for reference.

---

## Server (Node / npm — production dependencies)

32 production packages across the resolved dependency tree:

| Package | Version | License |
|---------|---------|---------|
| `@agentclientprotocol/sdk` | 0.26.0 | Apache-2.0 |
| `@leichtgewicht/ip-codec` | 2.0.5 | MIT |
| `@noble/hashes` | 1.4.0 | MIT |
| `@peculiar/asn1-cms` | 2.8.0 | MIT |
| `@peculiar/asn1-csr` | 2.8.0 | MIT |
| `@peculiar/asn1-ecc` | 2.8.0 | MIT |
| `@peculiar/asn1-pfx` | 2.8.0 | MIT |
| `@peculiar/asn1-pkcs8` | 2.8.0 | MIT |
| `@peculiar/asn1-pkcs9` | 2.8.0 | MIT |
| `@peculiar/asn1-rsa` | 2.8.0 | MIT |
| `@peculiar/asn1-schema` | 2.8.0 | MIT |
| `@peculiar/asn1-x509` | 2.8.0 | MIT |
| `@peculiar/asn1-x509-attr` | 2.8.0 | MIT |
| `@peculiar/utils` | 2.0.3 | MIT |
| `@peculiar/x509` | 1.14.3 | MIT |
| `asn1js` | 3.0.10 | BSD-3-Clause |
| `bonjour-service` | 1.4.2 | MIT |
| `bytestreamjs` | 2.0.1 | BSD-3-Clause |
| `dns-packet` | 5.6.1 | MIT |
| `fast-deep-equal` | 3.1.3 | MIT |
| `multicast-dns` | 7.2.5 | MIT |
| `pkijs` | 3.4.0 | BSD-3-Clause |
| `pvtsutils` | 1.3.6 | MIT |
| `pvutils` | 1.1.5 | MIT |
| `qrcode-terminal` | 0.12.0 | Apache-2.0 |
| `reflect-metadata` | 0.2.2 | Apache-2.0 |
| `selfsigned` | 5.5.0 | MIT |
| `thunky` | 1.1.0 | MIT |
| `tslib` | 1.14.1, 2.8.1 | 0BSD |
| `tsyringe` | 4.10.0 | MIT |
| `ws` | 8.21.0 | MIT |
| `zod` | 3.25.76 | MIT |

---

## App (Flutter / Dart — direct dependencies)

Direct runtime dependencies from `pubspec.yaml`. Full license texts (including
the 130+ transitive packages such as the Flutter SDK libraries, all
BSD-3-Clause) are bundled in the app and shown on the in-app Licenses page.

| Package | Version | License |
|---------|---------|---------|
| `collection` | 1.19.1 | BSD-3-Clause |
| `crypto` | 3.0.7 | BSD-3-Clause |
| `flutter_highlight` | 0.7.0 | MIT |
| `flutter_local_notifications` | 22.0.1 | BSD-3-Clause |
| `flutter_markdown_plus` | 1.0.7 | BSD-3-Clause |
| `flutter_riverpod` | 3.3.2 | MIT |
| `flutter_secure_storage` | 10.3.1 | BSD-3-Clause |
| `flutter_svg` | 2.3.0 | MIT |
| `go_router` | 17.3.0 | BSD-3-Clause |
| `liquid_glass_renderer` | 0.2.0-dev.4 | MIT |
| `markdown` | 7.3.1 | BSD-3-Clause |
| `multicast_dns` | 0.3.3+1 | BSD-3-Clause |
| `qr_flutter` | 4.1.0 | BSD-3-Clause |
| `shared_preferences` | 2.5.3 | BSD-3-Clause |
| `tray_manager` | 0.5.3 | MIT |
| `ulid` | 2.0.1 | BSD-3-Clause |
| `url_launcher` | 6.3.2 | BSD-3-Clause |
| `web_socket_channel` | 3.0.3 | BSD-3-Clause |
| `window_manager` | 0.5.2 | MIT |

Flutter SDK packages (`flutter`, `flutter_web_plugins`, `sky_engine`, etc.) are
licensed under BSD-3-Clause by Google/the Flutter authors.
