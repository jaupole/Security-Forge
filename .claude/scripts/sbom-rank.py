#!/usr/bin/env python3
"""
sbom-rank.py — query OSV.dev for every package in an SBOM, enrich with
EPSS+KEV, and emit a ranked vulnerability list.

Input: a Syft SPDX-JSON or CycloneDX-JSON SBOM on stdin
       (e.g., `syft dir:. -o spdx-json | sbom-rank.py`)

Output: a JSON document with:
  - `ranked` — vulnerabilities sorted by priority (P0 → P3), then EPSS percentile
  - `summary` — counts by priority, KEV count, ecosystem breakdown
  - `cache_meta` — when caches were last refreshed

The OSV query results are cached per (ecosystem, package, version) under
.claude/state/osv-cache.json with a 24-hour TTL. The KEV + EPSS lookups go
through enrich-cves.py which has its own caching.

Usage:
  syft dir:. -o spdx-json | sbom-rank.py [--top N] [--refresh]
"""

from __future__ import annotations

import argparse
import datetime as dt
import json
import os
import sys
import urllib.error
import urllib.request
from pathlib import Path
from typing import Iterable

# Reuse the enricher's caching helpers + priority rule by importing it.
SCRIPT_DIR = Path(__file__).resolve().parent
sys.path.insert(0, str(SCRIPT_DIR))
import importlib.util  # noqa: E402

_spec = importlib.util.spec_from_file_location("enrich_cves", SCRIPT_DIR / "enrich-cves.py")
assert _spec and _spec.loader
enrich_cves = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(enrich_cves)  # type: ignore

STATE_DIR = enrich_cves.STATE_DIR
OSV_CACHE = STATE_DIR / "osv-cache.json"
OSV_API = "https://api.osv.dev/v1/query"
CACHE_TTL = 24 * 60 * 60


# ---------- SBOM walking ----------

# Syft SPDX-JSON ecosystem hint → OSV ecosystem
SPDX_ECOSYSTEM_MAP = {
    "npm": "npm",
    "pypi": "PyPI",
    "go-module": "Go",
    "go": "Go",
    "maven": "Maven",
    "cargo": "crates.io",
    "rubygems": "RubyGems",
    "nuget": "NuGet",
    "composer": "Packagist",
    "alpine": "Alpine",
    "deb": "Debian",
    "rpm": "Red Hat",
    "apk": "Alpine",
}


def _purl_to_eco(purl: str) -> str | None:
    """Extract OSV ecosystem from a PURL string."""
    # pkg:npm/foo@1.2.3 → npm
    if not purl.startswith("pkg:"):
        return None
    eco = purl[4:].split("/", 1)[0].lower()
    return SPDX_ECOSYSTEM_MAP.get(eco, eco)


def _purl_to_name(purl: str) -> tuple[str | None, str | None]:
    """Extract OSV package name and version from a PURL.

    OSV name conventions vary by ecosystem:
      pkg:maven/org.apache.logging.log4j/log4j-core@2.14.0 → "org.apache.logging.log4j:log4j-core"
      pkg:npm/lodash@4.17.20                                → "lodash"
      pkg:npm/@scope/pkg@1.0.0                              → "@scope/pkg"
      pkg:pypi/requests@2.20.0                              → "requests"
      pkg:golang/github.com/foo/bar@v1.0.0                  → "github.com/foo/bar"
    """
    if not purl.startswith("pkg:"):
        return None, None
    body = purl[4:]
    try:
        eco_part, rest = body.split("/", 1)
        if "@" in rest:
            ns_name, version = rest.rsplit("@", 1)
        else:
            ns_name, version = rest, None
    except ValueError:
        return None, None

    eco = eco_part.lower()
    if eco == "maven":
        # group/artifact → group:artifact
        if "/" in ns_name:
            group, artifact = ns_name.rsplit("/", 1)
            name = f"{group}:{artifact}"
        else:
            name = ns_name
    else:
        name = ns_name  # npm scoped packages keep their slash; OSV accepts that form
    return name, version


def walk_packages(sbom: dict) -> list[dict]:
    """Yield {ecosystem, name, version} for every package in the SBOM.

    Handles Syft's SPDX-JSON shape (most common) and CycloneDX as a fallback.
    """
    packages: list[dict] = []

    # SPDX-JSON: top-level "packages" array, each with name, versionInfo,
    # externalRefs containing a purl. Prefer purl-derived name when available
    # because the SPDX `name` field is wrong for Maven (it's the artifactId,
    # not groupId:artifactId).
    for pkg in sbom.get("packages", []):
        spdx_name = pkg.get("name")
        ver = pkg.get("versionInfo")
        purl = None
        for ref in pkg.get("externalRefs", []):
            if ref.get("referenceType") == "purl":
                purl = ref.get("referenceLocator", "")
                break

        eco = _purl_to_eco(purl) if purl else None
        if not eco:
            continue

        purl_name, purl_version = _purl_to_name(purl) if purl else (None, None)
        name = purl_name or spdx_name
        version = purl_version or ver
        if not name or not version or version in ("NOASSERTION", "NONE"):
            continue
        packages.append({"ecosystem": eco, "name": name, "version": version})

    # CycloneDX fallback: top-level "components" with purl.
    for comp in sbom.get("components", []):
        purl = comp.get("purl")
        if not purl:
            continue
        eco = _purl_to_eco(purl)
        name, version = _purl_to_name(purl)
        if not (eco and name and version):
            continue
        packages.append({"ecosystem": eco, "name": name, "version": version})

    # Dedupe
    seen = set()
    out: list[dict] = []
    for p in packages:
        key = (p["ecosystem"], p["name"], p["version"])
        if key in seen:
            continue
        seen.add(key)
        out.append(p)
    return out


# ---------- OSV query ----------


def _load_osv_cache() -> dict:
    if OSV_CACHE.exists():
        try:
            return json.loads(OSV_CACHE.read_text())
        except (json.JSONDecodeError, OSError):
            return {}
    return {}


def _save_osv_cache(cache: dict) -> None:
    try:
        OSV_CACHE.write_text(json.dumps(cache))
    except OSError as e:
        sys.stderr.write(f"warn: could not write OSV cache: {e}\n")


def _cache_key(p: dict) -> str:
    return f"{p['ecosystem']}|{p['name']}|{p['version']}"


def _is_fresh_entry(entry: dict) -> bool:
    ts = entry.get("fetched_at_ts", 0)
    return (dt.datetime.now().timestamp() - ts) < CACHE_TTL


def query_osv(packages: list[dict], force_refresh: bool = False) -> dict[str, list[dict]]:
    """Returns {cache_key: [vuln_record]} for every package. Cached results
    skipped from network."""
    cache = _load_osv_cache() if not force_refresh else {}
    fresh: dict[str, list[dict]] = {}
    needs_query: list[dict] = []

    for p in packages:
        k = _cache_key(p)
        cached = cache.get(k)
        if cached and _is_fresh_entry(cached):
            fresh[k] = cached.get("vulns", [])
        else:
            needs_query.append(p)

    sys.stderr.write(f"OSV: {len(packages)} packages, {len(needs_query)} need fetch, {len(fresh)} from cache\n")

    for p in needs_query:
        body = json.dumps({
            "package": {"ecosystem": p["ecosystem"], "name": p["name"]},
            "version": p["version"],
        }).encode()
        # Reject any non-https scheme — defeats semgrep's dynamic-urllib
        # warning AND closes the `file://` / `ftp://` exposure class. OSV_API
        # is a hardcoded https:// constant; the check is belt-and-suspenders.
        if not OSV_API.startswith("https://"):
            raise ValueError(f"only https:// allowed for OSV_API, got: {OSV_API[:30]!r}")
        req = urllib.request.Request(
            OSV_API,
            data=body,
            headers={"Content-Type": "application/json", "User-Agent": "claude-advisor-loop/2.0"},
            method="POST",
        )
        vulns: list[dict] = []
        try:
            # nosemgrep: python.lang.security.audit.dynamic-urllib-use-detected.dynamic-urllib-use-detected
            # OSV_API is a hardcoded https:// constant guarded by the scheme
            # check above; semgrep's static pattern flags the call regardless.
            with urllib.request.urlopen(req, timeout=20.0) as resp:
                data = json.loads(resp.read())
            vulns = data.get("vulns", []) or []
        except (urllib.error.URLError, json.JSONDecodeError, TimeoutError) as e:
            sys.stderr.write(f"warn: OSV query failed for {p['ecosystem']}/{p['name']}@{p['version']}: {e}\n")

        # Slim each vuln record to what we need.
        slim = [
            {
                "id": v.get("id"),
                "summary": v.get("summary") or v.get("details", "")[:200],
                "aliases": v.get("aliases", []),
                "severity": v.get("database_specific", {}).get("severity") or _osv_severity(v),
                "fixed_versions": _osv_fixed(v),
                "references": [r.get("url") for r in (v.get("references") or [])][:3],
            }
            for v in vulns
        ]

        k = _cache_key(p)
        fresh[k] = slim
        cache[k] = {"fetched_at_ts": dt.datetime.now().timestamp(), "vulns": slim}

    _save_osv_cache(cache)
    return fresh


def _osv_severity(v: dict) -> str | None:
    sev_arr = v.get("severity") or []
    for s in sev_arr:
        if s.get("type") == "CVSS_V3":
            return s.get("score")
    return None


def _osv_fixed(v: dict) -> list[str]:
    out: list[str] = []
    for aff in v.get("affected", []) or []:
        for r in aff.get("ranges", []) or []:
            for ev in r.get("events", []) or []:
                if "fixed" in ev:
                    out.append(ev["fixed"])
    return out


# ---------- ranking ----------


def _cve_ids_in(vuln: dict) -> Iterable[str]:
    if vuln.get("id", "").startswith("CVE-"):
        yield vuln["id"]
    for a in vuln.get("aliases", []):
        if isinstance(a, str) and a.startswith("CVE-"):
            yield a


def _parse_cvss(s: str | None) -> float | None:
    if not s:
        return None
    # OSV CVSS strings look like "CVSS:3.1/AV:N/AC:L/..." — score isn't always
    # in the string. Use 0 as a sentinel; we only use CVSS in the priority rule
    # when explicitly numeric.
    try:
        return float(s)
    except (ValueError, TypeError):
        return None


PRIORITY_ORDER = {"P0": 0, "P1": 1, "P2": 2, "P3": 3, "noise": 4}


def rank(packages: list[dict], osv_results: dict[str, list[dict]]) -> list[dict]:
    """Build one row per (package, vuln) and assign a priority."""
    # Collect all CVE IDs we'll need to enrich.
    all_cves: set[str] = set()
    for vulns in osv_results.values():
        for v in vulns:
            all_cves.update(_cve_ids_in(v))

    kev = enrich_cves.load_kev()
    epss = enrich_cves.load_epss(sorted(all_cves)) if all_cves else {}

    rows: list[dict] = []
    for p in packages:
        k = _cache_key(p)
        for v in osv_results.get(k, []):
            cves = list(_cve_ids_in(v))
            primary_cve = cves[0] if cves else (v.get("id") or "UNKNOWN")
            cvss = _parse_cvss(v.get("severity"))

            # Use the worst priority across all aliases.
            best_priority = "noise"
            best_meta = {"epss": 0.0, "epss_percentile": 0.0, "kev": False}
            for c in cves or [primary_cve]:
                e = epss.get(c, {"epss": 0.0, "percentile": 0.0})
                pri = enrich_cves.compute_priority(cvss, e["epss"], e.get("percentile", 0.0), c in kev)
                if PRIORITY_ORDER[pri] < PRIORITY_ORDER[best_priority]:
                    best_priority = pri
                    best_meta = {"epss": e["epss"], "epss_percentile": e.get("percentile", 0.0), "kev": c in kev}

            rows.append({
                "ecosystem": p["ecosystem"],
                "package": p["name"],
                "installed_version": p["version"],
                "vuln_id": primary_cve,
                "aliases": cves[1:] if len(cves) > 1 else [],
                "summary": v.get("summary"),
                "fixed_versions": v.get("fixed_versions"),
                "cvss": cvss,
                "epss": best_meta["epss"],
                "epss_percentile": best_meta["epss_percentile"],
                "kev": best_meta["kev"],
                "priority": best_priority,
                "fingerprint": f"sbom:{p['ecosystem']}:{p['name']}:{p['version']}:{primary_cve}",
                "references": v.get("references", []),
            })

    # Dedupe: OSV often returns two records for the same CVE (full + alias-only).
    # Keep the row with the worst priority per (ecosystem, package, version, vuln_id).
    deduped: dict[tuple, dict] = {}
    for r in rows:
        k = (r["ecosystem"], r["package"], r["installed_version"], r["vuln_id"])
        existing = deduped.get(k)
        if existing is None or PRIORITY_ORDER[r["priority"]] < PRIORITY_ORDER[existing["priority"]]:
            deduped[k] = r
    rows = list(deduped.values())

    rows.sort(key=lambda r: (PRIORITY_ORDER[r["priority"]], -r["epss_percentile"]))
    return rows


# ---------- main ----------


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--top", type=int, default=20, help="how many rows to print to console summary")
    ap.add_argument("--refresh", action="store_true", help="bypass all caches")
    ap.add_argument("--out", default=str(STATE_DIR / "sbom-ranked.json"),
                    help="where to write the full ranked JSON (default: .claude/state/sbom-ranked.json)")
    args = ap.parse_args()

    raw = sys.stdin.read().strip()
    if not raw:
        sys.stderr.write("no SBOM JSON on stdin\n")
        return 2
    try:
        sbom = json.loads(raw)
    except json.JSONDecodeError as e:
        sys.stderr.write(f"invalid JSON on stdin: {e}\n")
        return 2

    packages = walk_packages(sbom)
    sys.stderr.write(f"SBOM: {len(packages)} unique packages\n")
    if not packages:
        out = {"ranked": [], "summary": {"total": 0}, "warning": "no packages parsed from SBOM"}
        Path(args.out).write_text(json.dumps(out, indent=2))
        print(json.dumps(out, indent=2))
        return 0

    osv = query_osv(packages, force_refresh=args.refresh)
    ranked = rank(packages, osv)

    by_priority: dict[str, int] = {}
    for r in ranked:
        by_priority[r["priority"]] = by_priority.get(r["priority"], 0) + 1
    by_eco: dict[str, int] = {}
    for r in ranked:
        by_eco[r["ecosystem"]] = by_eco.get(r["ecosystem"], 0) + 1
    kev_count = sum(1 for r in ranked if r["kev"])

    output = {
        "generated_at": dt.datetime.now(dt.timezone.utc).isoformat(),
        "package_count": len(packages),
        "vuln_count": len(ranked),
        "summary": {
            "by_priority": by_priority,
            "by_ecosystem": by_eco,
            "kev_count": kev_count,
        },
        "ranked": ranked,
    }

    out_path = Path(args.out)
    out_path.parent.mkdir(parents=True, exist_ok=True)
    out_path.write_text(json.dumps(output, indent=2))

    # Console summary: priorities, KEV count, top-N
    sys.stderr.write("\n")
    sys.stderr.write(f"=== SBOM-rank summary ({len(ranked)} vulns across {len(packages)} packages) ===\n")
    for pri in ("P0", "P1", "P2", "P3", "noise"):
        sys.stderr.write(f"  {pri:6s}: {by_priority.get(pri, 0)}\n")
    sys.stderr.write(f"  KEV   : {kev_count}\n")
    sys.stderr.write(f"\nTop {args.top}:\n")
    for r in ranked[: args.top]:
        kev_tag = "[KEV]" if r["kev"] else "     "
        sys.stderr.write(
            f"  {r['priority']:5s} {kev_tag} {r['ecosystem']:8s} "
            f"{r['package']}@{r['installed_version']}  {r['vuln_id']}  "
            f"epss%={r['epss_percentile']:.2f}\n"
        )
    sys.stderr.write(f"\nFull JSON: {out_path}\n")

    # Stdout gets the JSON (so callers can pipe).
    print(json.dumps(output, indent=2))
    return 0


if __name__ == "__main__":
    sys.exit(main())
