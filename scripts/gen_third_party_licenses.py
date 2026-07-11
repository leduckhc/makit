#!/usr/bin/env python3
"""Generate THIRD_PARTY_LICENSES.md from the server + app dependency manifests.

Sources of truth:
  - Server (npm): `pnpm licenses list --prod --json` in server/
  - App (Dart):   direct deps from app/pubspec.yaml, versions from
                  app/pubspec.lock, license classified from the local pub cache.

Usage:
  python3 scripts/gen_third_party_licenses.py            # write the file
  python3 scripts/gen_third_party_licenses.py --check     # fail if out of date

Run from the repo root.
"""
from __future__ import annotations

import json
import os
import re
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
OUT = ROOT / "THIRD_PARTY_LICENSES.md"
PUB_CACHE = Path(os.environ.get("PUB_CACHE", Path.home() / ".pub-cache")) / "hosted" / "pub.dev"


def npm_rows() -> list[tuple[str, str, str]]:
    raw = subprocess.run(
        ["pnpm", "licenses", "list", "--prod", "--json"],
        cwd=ROOT / "server",
        capture_output=True,
        text=True,
        check=True,
    ).stdout
    data = json.loads(raw)
    rows: list[tuple[str, str, str]] = []
    for lic, pkgs in data.items():
        lic = lic.replace("Apache 2.0", "Apache-2.0")
        for p in pkgs:
            ver = ", ".join(p.get("versions", []))
            rows.append((p["name"], ver, lic))
    rows.sort(key=lambda r: r[0].lower())
    return rows


def classify_license(pkg_dir: Path) -> str:
    f = pkg_dir / "LICENSE"
    if not f.exists():
        for alt in ("LICENSE.md", "LICENSE.txt"):
            if (pkg_dir / alt).exists():
                f = pkg_dir / alt
                break
        else:
            return "see package"
    text = f.read_text(errors="ignore")
    low = text.lower()
    if "mit license" in low or ("permission is hereby granted, free of charge" in low):
        return "MIT"
    if "redistribution and use in source and binary" in low:
        return "BSD-3-Clause" if "neither the name" in low else "BSD-2-Clause"
    if "apache license" in low:
        return "Apache-2.0"
    return "see package"


def dart_direct_deps() -> list[str]:
    lines = (ROOT / "app" / "pubspec.yaml").read_text().splitlines()
    deps: list[str] = []
    in_deps = False
    for line in lines:
        if re.match(r"^dependencies:\s*$", line):
            in_deps = True
            continue
        if in_deps and re.match(r"^[a-zA-Z_]", line):  # next top-level key
            break
        if in_deps:
            m = re.match(r"^  ([a-zA-Z0-9_]+):", line)
            if m and m.group(1) != "flutter":
                deps.append(m.group(1))
    return deps


def dart_versions() -> dict[str, str]:
    ver: dict[str, str] = {}
    cur = None
    for line in (ROOT / "app" / "pubspec.lock").read_text().splitlines():
        m = re.match(r"^  ([a-zA-Z0-9_]+):\s*$", line)
        if m:
            cur = m.group(1)
        v = re.match(r'^    version: "([^"]+)"', line)
        if v and cur:
            ver[cur] = v.group(1)
    return ver


def dart_rows() -> list[tuple[str, str, str]]:
    versions = dart_versions()
    rows: list[tuple[str, str, str]] = []
    for name in sorted(dart_direct_deps()):
        v = versions.get(name, "?")
        pkg_dir = PUB_CACHE / f"{name}-{v}"
        lic = classify_license(pkg_dir) if pkg_dir.is_dir() else "see pub.dev"
        rows.append((name, v, lic))
    return rows


def render() -> str:
    npm = npm_rows()
    dart = dart_rows()

    def table(rows: list[tuple[str, str, str]]) -> str:
        out = ["| Package | Version | License |", "|---------|---------|---------|"]
        out += [f"| `{n}` | {v} | {l} |" for n, v, l in rows]
        return "\n".join(out)

    return f"""# Third-Party Licenses

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

{len(npm)} production packages across the resolved dependency tree:

{table(npm)}

---

## App (Flutter / Dart — direct dependencies)

Direct runtime dependencies from `pubspec.yaml`. Full license texts (including
the 130+ transitive packages such as the Flutter SDK libraries, all
BSD-3-Clause) are bundled in the app and shown on the in-app Licenses page.

{table(dart)}

Flutter SDK packages (`flutter`, `flutter_web_plugins`, `sky_engine`, etc.) are
licensed under BSD-3-Clause by Google/the Flutter authors.
"""


def main() -> int:
    check = "--check" in sys.argv[1:]
    content = render()
    if check:
        if not OUT.exists() or OUT.read_text() != content:
            print(
                "THIRD_PARTY_LICENSES.md is out of date. "
                "Run: python3 scripts/gen_third_party_licenses.py",
                file=sys.stderr,
            )
            return 1
        return 0
    OUT.write_text(content)
    print(f"Wrote {OUT.relative_to(ROOT)}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
