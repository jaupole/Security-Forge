#!/usr/bin/env python3
"""
enrich-cves.py — enrich CVE findings with EPSS score, EPSS percentile,
CISA KEV flag, and a layered priority label.

Two input modes:

  1) CVE-list mode (stdin: JSON array of CVE IDs)
       echo '["CVE-2024-12345","CVE-2023-99999"]' | enrich-cves.py
     → JSON array of enriched records

  2) Findings mode (stdin: JSON object {"findings":[...]} where each finding
     has an "id" field that is a CVE ID; non-CVE findings are passed through
     unchanged)
       cat trivy-findings.json | enrich-cves.py --mode findings

Priority rule (v2 §3, fixed from v1):

    P0  : CVE is in CISA KEV  OR  epss_percentile ≥ 0.99
    P1  : epss_percentile ≥ 0.95
    P2  : cvss ≥ 9.0
    P3  : epss_percentile ≥ 0.80  OR  cvss ≥ 7.0
    noise: everything else

(`cvss * epss` is wrong because most EPSS scores are <0.05 — the multiplication
collapses real signals. Percentile bands handle the heavy-tailed distribution.)

Caching: KEV mirror and EPSS lookups land under .claude/state/. The cache is
keyed by date for EPSS (daily refresh) and CVE-ID for KEV (refreshed daily).
"""

from __future__ import annotations

import argparse
import datetime as dt
import json
import os
import sys
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path
from typing import Iterable

# ---------- paths & constants ----------

REPO_ROOT = Path(os.environ.get("CLAUDE_PROJECTS_ROOT", ".")).resolve()
# Find the nearest .claude/ (walk up from CWD)
def _state_dir() -> Path:
    cur = Path.cwd().resolve()
    while cur != cur.parent:
        c = cur / ".claude"
        if c.is_dir():
            (c / "state").mkdir(exist_ok=True)
            return c / "state"
        cur = cur.parent
    # Fallback: ~/Projects/.claude/state
    p = REPO_ROOT / ".claude" / "state"
    p.mkdir(parents=True, exist_ok=True)
    return p


STATE_DIR = _state_dir()
KEV_URL = "https://www.cisa.gov/sites/default/files/feeds/known_exploited_vulnerabilities.json"
EPSS_URL = "https://api.first.org/data/v1/epss"
CACHE_TTL_SECONDS = 24 * 60 * 60  # 1 day


# ---------- HTTP with timeout + ETag-friendly caching ----------


def _http_get(url: str, timeout: float = 15.0) -> bytes:
    req = urllib.request.Request(url, headers={"User-Agent": "claude-advisor-loop/2.0"})
    with urllib.request.urlopen(req, timeout=timeout) as resp:
        return resp.read()


def _cache_path(name: str) -> Path:
    return STATE_DIR / name


def _is_fresh(p: Path, ttl: int = CACHE_TTL_SECONDS) -> bool:
    if not p.exists():
        return False
    age = dt.datetime.now().timestamp() - p.stat().st_mtime
    return age < ttl


# ---------- CISA KEV ----------


def load_kev(force_refresh: bool = False) -> set[str]:
    """Returns the set of CVE IDs known to be exploited in the wild."""
    cache = _cache_path("kev-cache.json")
    if not force_refresh and _is_fresh(cache):
        try:
            raw = json.loads(cache.read_text())
            return set(raw.get("cves", []))
        except (json.JSONDecodeError, OSError):
            pass

    try:
        data = json.loads(_http_get(KEV_URL))
    except (urllib.error.URLError, json.JSONDecodeError, TimeoutError) as e:
        # Fall back to whatever cache we have, even stale.
        if cache.exists():
            try:
                return set(json.loads(cache.read_text()).get("cves", []))
            except (json.JSONDecodeError, OSError):
                return set()
        sys.stderr.write(f"warn: KEV fetch failed and no cache: {e}\n")
        return set()

    cves = {v["cveID"] for v in data.get("vulnerabilities", [])}
    cache.write_text(json.dumps({"fetched_at": dt.datetime.now(dt.timezone.utc).isoformat(), "cves": sorted(cves)}))
    return cves


# ---------- EPSS ----------


def load_epss(cve_ids: Iterable[str], force_refresh: bool = False) -> dict[str, dict]:
    """Returns {cve_id: {"epss": float, "percentile": float}} for the given CVEs.

    EPSS supports batch query: /data/v1/epss?cve=CVE-X,CVE-Y,... up to ~100/req.
    Results are cached per CVE per day.
    """
    today = dt.date.today().isoformat()
    cache = _cache_path(f"epss-cache-{today}.json")
    cached: dict[str, dict] = {}
    if not force_refresh and cache.exists():
        try:
            cached = json.loads(cache.read_text())
        except (json.JSONDecodeError, OSError):
            cached = {}

    needed = [c for c in cve_ids if c not in cached and c.startswith("CVE-")]
    BATCH = 100
    for i in range(0, len(needed), BATCH):
        batch = needed[i : i + BATCH]
        q = urllib.parse.urlencode({"cve": ",".join(batch)})
        url = f"{EPSS_URL}?{q}"
        try:
            data = json.loads(_http_get(url))
        except (urllib.error.URLError, json.JSONDecodeError, TimeoutError) as e:
            sys.stderr.write(f"warn: EPSS batch fetch failed: {e}\n")
            continue
        for row in data.get("data", []):
            cve = row.get("cve")
            if not cve:
                continue
            cached[cve] = {
                "epss": float(row.get("epss", 0.0)),
                "percentile": float(row.get("percentile", 0.0)),
            }

    # Also record explicit-miss entries so we don't re-query unknown CVEs all day.
    for c in needed:
        cached.setdefault(c, {"epss": 0.0, "percentile": 0.0, "missing": True})

    try:
        cache.write_text(json.dumps(cached))
    except OSError as e:
        sys.stderr.write(f"warn: could not write EPSS cache: {e}\n")

    return {c: cached.get(c, {"epss": 0.0, "percentile": 0.0}) for c in cve_ids}


# ---------- priority rule (v2 §3) ----------


def compute_priority(cvss: float | None, epss: float, percentile: float, is_kev: bool) -> str:
    if is_kev:
        return "P0"
    if percentile >= 0.99:
        return "P0"
    if percentile >= 0.95:
        return "P1"
    if cvss is not None and cvss >= 9.0:
        return "P2"
    if percentile >= 0.80 or (cvss is not None and cvss >= 7.0):
        return "P3"
    return "noise"


def enrich_one(cve_id: str, cvss: float | None, kev: set[str], epss: dict[str, dict]) -> dict:
    e = epss.get(cve_id, {"epss": 0.0, "percentile": 0.0})
    is_kev = cve_id in kev
    return {
        "cve": cve_id,
        "cvss": cvss,
        "epss": e.get("epss", 0.0),
        "epss_percentile": e.get("percentile", 0.0),
        "kev": is_kev,
        "priority": compute_priority(cvss, e.get("epss", 0.0), e.get("percentile", 0.0), is_kev),
    }


# ---------- modes ----------


def _extract_cve(s: str | None) -> str | None:
    if not s:
        return None
    if s.startswith("CVE-") or s.startswith("GHSA-"):
        return s
    return None


def cve_list_mode(cve_ids: list[str]) -> list[dict]:
    kev = load_kev()
    epss = load_epss(cve_ids)
    return [enrich_one(c, None, kev, epss) for c in cve_ids]


def findings_mode(doc: dict) -> dict:
    """Enrich a {'findings': [...]} doc. Each finding with id starting CVE-* gets
    an `enrichment` field added; others pass through unchanged."""
    findings = doc.get("findings", [])
    cve_ids = sorted({_extract_cve(f.get("id")) for f in findings if _extract_cve(f.get("id"))})
    kev = load_kev()
    epss = load_epss(list(cve_ids))

    for f in findings:
        cve = _extract_cve(f.get("id"))
        if not cve:
            continue
        cvss = f.get("cvss")
        f["enrichment"] = enrich_one(cve, cvss, kev, epss)
        # also bubble priority up to the top of the finding for easy sorting
        f["priority"] = f["enrichment"]["priority"]

    # Top-line summary
    counts: dict[str, int] = {}
    for f in findings:
        p = f.get("priority", "noise")
        counts[p] = counts.get(p, 0) + 1
    doc["enrichment_summary"] = {
        "by_priority": counts,
        "kev_count": sum(1 for f in findings if f.get("enrichment", {}).get("kev")),
    }
    return doc


# ---------- main ----------


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--mode", choices=["cve-list", "findings"], default="cve-list")
    ap.add_argument("--refresh", action="store_true", help="bypass cache, force fresh fetches")
    args = ap.parse_args()

    raw = sys.stdin.read().strip()
    if not raw:
        sys.stderr.write("no JSON on stdin\n")
        return 2

    try:
        doc = json.loads(raw)
    except json.JSONDecodeError as e:
        sys.stderr.write(f"invalid JSON on stdin: {e}\n")
        return 2

    if args.refresh:
        # Clear the KEV cache; EPSS naturally rotates by date.
        kev_cache = _cache_path("kev-cache.json")
        if kev_cache.exists():
            kev_cache.unlink()

    if args.mode == "cve-list":
        if not isinstance(doc, list):
            sys.stderr.write("cve-list mode expects a JSON array on stdin\n")
            return 2
        out = cve_list_mode(doc)
    else:
        if not isinstance(doc, dict):
            sys.stderr.write("findings mode expects a JSON object on stdin\n")
            return 2
        out = findings_mode(doc)

    print(json.dumps(out, indent=2))
    return 0


if __name__ == "__main__":
    sys.exit(main())
