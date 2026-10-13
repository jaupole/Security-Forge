#!/usr/bin/env python3
"""
diagnose.py — categorize gate findings.

Reads combined gate output JSON on stdin (the shape produced by run-gates.sh)
and emits a categorized JSON document on stdout.

The category catalog is in .claude/skills/diagnose-categories/SKILL.md. This
script encodes the matcher rules; when adding a new category to the catalog,
add a matcher entry here too.

Routing decisions:
  - auto-patch   : known recipe, safe to attempt
  - human-review : known category but consequential
  - unclassified : no category match (surfaced to user)
  - accepted     : fingerprint listed in the reviewed-findings file
                   (.claude/findings-accepted.json, or $DIAGNOSE_ACCEPTED_FILE)
                   with an owner, a reason and an unexpired expiry. Accepted
                   findings never count as outstanding; expired acceptances
                   are reported under summary.accepted_expired and DO count.

Versioning (v2 §1.1): the module's version is recorded in every output and
embedded in stamp predicates. Bump MODULE_VERSION whenever you change the
catalog or matcher semantics. Golden fixtures under tests/fixtures/ pin the
expected categorization; CI runs tests/test_diagnose.py to catch regressions.

The unclassified_rate metric is the canary for catalog drift. If it creeps
above 0.05 (5% of findings have no matching category), add categories.
"""

from __future__ import annotations

import json
import re
import sys
from dataclasses import dataclass, asdict, field
from typing import Callable, Optional

# Bump on every catalog change. Stamp predicates pin this so an approval
# always says exactly which version of the rules judged it.
MODULE_VERSION = "2.2.0"

# ---------- matcher framework ----------


@dataclass
class Matcher:
    category: str
    routing: str  # auto-patch | human-review
    test: Callable[[dict], bool]
    confidence: str = "high"  # high | medium | low

    def matches(self, finding: dict) -> bool:
        try:
            return self.test(finding)
        except Exception:
            return False


def _or(*tests: Callable[[dict], bool]) -> Callable[[dict], bool]:
    def _t(f: dict) -> bool:
        return any(t(f) for t in tests)
    return _t


def _id_contains(*needles: str) -> Callable[[dict], bool]:
    def _t(f: dict) -> bool:
        i = (f.get("id") or "").lower()
        return any(n in i for n in needles)

    return _t


def _id_regex(pattern: str) -> Callable[[dict], bool]:
    p = re.compile(pattern)

    def _t(f: dict) -> bool:
        return bool(p.search(f.get("id") or ""))

    return _t


def _scanner_is(s: str) -> Callable[[dict], bool]:
    def _t(f: dict) -> bool:
        return (f.get("_scanner") or "") == s

    return _t


def _and(*tests: Callable[[dict], bool]) -> Callable[[dict], bool]:
    def _t(f: dict) -> bool:
        return all(t(f) for t in tests)

    return _t


# ---------- catalog ----------
# Order matters: first match wins. More specific matchers go first.

CATALOG: list[Matcher] = [
    # ---- secrets (always human-review) ----
    Matcher("secret-leak", "human-review", _scanner_is("gitleaks")),
    Matcher(
        "secret-leak",
        "human-review",
        _and(_scanner_is("semgrep"), _id_contains("hardcoded-credential", "hardcoded-secret", "hardcoded-token")),
    ),
    # ---- SAST: source code ----
    Matcher("sql-injection", "auto-patch", _and(_scanner_is("semgrep"), _id_contains("sql-injection", "tainted-sql"))),
    Matcher("xss-output-encoding", "auto-patch", _and(_scanner_is("semgrep"), _id_contains("tainted-html", "xss"))),
    Matcher(
        "command-injection",
        "human-review",
        _and(_scanner_is("semgrep"), _id_contains("command-injection", "shell-injection", "dangerous-system-call")),
    ),
    Matcher("weak-crypto", "human-review", _and(_scanner_is("semgrep"), _id_contains("md5", "sha1", "weak-hash", "weak-crypto"))),
    Matcher("path-traversal", "auto-patch", _and(_scanner_is("semgrep"), _id_contains("path-traversal", "path-injection"))),
    Matcher("open-redirect", "auto-patch", _and(_scanner_is("semgrep"), _id_contains("open-redirect"))),
    Matcher("unused-import", "auto-patch", _and(_scanner_is("semgrep"), _id_contains("unused-import"))),
    Matcher("localstorage-token", "human-review", _and(_scanner_is("semgrep"), _id_contains("localstorage-token", "session-token-localstorage"))),
    # ---- IaC: Checkov IDs are well-structured ----
    Matcher("iac-public-storage", "auto-patch", _id_regex(r"CKV_AWS_(20|53|54|55|56)\b")),
    Matcher("iac-unencrypted-storage", "auto-patch", _id_regex(r"CKV_AWS_(19|17|18|21)\b")),
    Matcher("iac-iam-wildcard", "human-review", _id_regex(r"CKV_AWS_(40|41|44|62|63)\b")),
    Matcher("iac-open-security-group", "human-review", _id_regex(r"CKV_AWS_(24|25|260)\b")),
    Matcher("iac-container-root", "auto-patch", _id_regex(r"CKV_(K8S|DOCKER)_.*ROOT")),
    Matcher("iac-missing-tags", "auto-patch", _id_regex(r"CKV_AWS_\d+_TAG")),
    Matcher("iac-missing-audit-log", "human-review", _id_regex(r"CKV_AWS_(67|158|36|33)\b")),
    # ---- §12 JWT hardening ----
    Matcher("jwt-alg-not-pinned", "human-review",
            _and(_scanner_is("semgrep"), _id_contains("jwt-alg-none", "jwt-no-algorithms", "jwt-weak-algorithm"))),
    Matcher("jwt-claims-not-validated", "human-review",
            _and(_scanner_is("semgrep"), _id_contains("jwt-missing-iss", "jwt-missing-aud", "jwt-no-claim-validation"))),
    Matcher("jwt-weak-secret", "human-review",
            _and(_scanner_is("semgrep"), _id_contains("jwt-hardcoded-secret", "weak-jwt-secret"))),
    # ---- §13 SSRF ----
    Matcher("ssrf-no-allowlist", "human-review",
            _and(_scanner_is("semgrep"), _id_contains("ssrf", "server-side-request-forgery"))),
    Matcher("ssrf-metadata-ip", "human-review",
            _and(_scanner_is("semgrep"), _id_contains("aws-metadata", "imds", "169-254-169-254"))),
    Matcher("outbound-timeout-missing", "auto-patch",
            _and(_scanner_is("semgrep"), _id_contains("no-fetch-timeout", "missing-timeout", "axios-no-timeout"))),
    # ---- §15 agent permissions (lints settings.json shape) ----
    Matcher("agent-bypass-permissions", "human-review",
            _id_contains("bypass-permissions", "dangerously-skip-permissions")),
    Matcher("agent-wildcard-bash", "human-review",
            _id_contains("bash-wildcard", "settings-bash-star")),
    # ---- §16 prompt injection (rare for now; mostly manual review) ----
    Matcher("prompt-injection-untrusted-context", "human-review",
            _and(_scanner_is("semgrep"), _id_contains("prompt-template-injection", "untrusted-llm-input"))),
    # ---- §17 universal ----
    Matcher("prototype-pollution", "human-review",
            _and(_scanner_is("semgrep"), _id_contains("prototype-pollution", "lodash-merge-untrusted"))),
    Matcher("nosql-operator-injection", "human-review",
            _and(_scanner_is("semgrep"), _id_contains("nosql-injection", "mongo-operator-injection"))),
    Matcher("eval-untrusted-input", "human-review",
            _and(_scanner_is("semgrep"), _id_contains("eval", "function-constructor", "vm-runinnewcontext"))),
    Matcher("yaml-unsafe-load", "auto-patch",
            _and(_scanner_is("semgrep"), _id_contains("yaml-unsafe-load", "yaml-load", "yaml-loadall"))),
    Matcher("breach-compression-on-auth", "human-review",
            _and(_scanner_is("semgrep"), _id_contains("breach", "compression-secret"))),
    Matcher("error-stack-trace-leak", "auto-patch",
            _and(_scanner_is("semgrep"), _id_contains("stack-trace-disclosure", "error-leak", "express-error-stack"))),
    Matcher("fail-open-error-handler", "human-review",
            _and(_scanner_is("semgrep"), _id_contains("fail-open", "permissive-default-error"))),
    # ---- React overlay (R-1..R-4) ----
    Matcher("react-dangerous-html-unsanitized", "human-review",
            _and(_scanner_is("semgrep"), _id_contains("dangerously-set-inner-html", "react-dangerous-html", "react.dangerouslysetinnerhtml"))),
    Matcher("react-javascript-url", "auto-patch",
            _and(_scanner_is("semgrep"), _id_contains("javascript-url", "react-href-javascript"))),
    Matcher("react-ref-direct-dom", "auto-patch",
            _and(_scanner_is("semgrep"), _id_contains("ref-innerhtml", "ref-outerhtml", "insertadjacenthtml"))),
    # ---- Node overlay (N-1..N-8) ----
    Matcher("node-helmet-missing", "auto-patch",
            _and(_scanner_is("semgrep"), _id_contains("express-no-helmet", "missing-helmet"))),
    Matcher("node-body-limit-missing", "auto-patch",
            _and(_scanner_is("semgrep"), _id_contains("express-json-no-limit", "no-body-limit"))),
    Matcher("node-clone-via-json", "auto-patch",
            _and(_scanner_is("semgrep"), _id_contains("json-parse-stringify-clone", "deep-clone-json"))),
    # ---- Prisma overlay (P-1..P-3) ----
    Matcher("prisma-raw-unsafe", "human-review",
            _and(_scanner_is("semgrep"), _id_contains("prisma-raw-unsafe", "queryrawunsafe", "executerawunsafe"))),
    Matcher("prisma-raw-user-input", "human-review",
            _and(_scanner_is("semgrep"), _id_contains("prisma-raw-user-input", "prisma-tainted-raw"))),
    Matcher("prisma-dynamic-column", "human-review",
            _and(_scanner_is("semgrep"), _id_contains("prisma-dynamic-column", "dynamic-table-name"))),
    # ---- IaC: Kubernetes manifest hardening (checkov CKV_K8S_*) ----
    Matcher("iac-missing-resources", "auto-patch", _id_regex(r"CKV_K8S_(10|11|12|13)\b")),
    Matcher("iac-missing-seccomp", "auto-patch", _id_regex(r"CKV_K8S_31\b")),
    Matcher("iac-pod-hardening", "human-review",
            _or(_id_regex(r"CKV_K8S_(8|9|14|20|22|23|25|26|28|29|37|38|43)\b"),
                _and(_scanner_is("semgrep"), _id_contains("allow-privilege-escalation", "kubernetes.security")))),
    Matcher("iac-rbac-wide", "human-review", _id_regex(r"(CKV_K8S_(49|155|156|157|158)|CKV2_K8S_5)\b")),
    Matcher("iac-container-root", "auto-patch", _id_regex(r"CKV_DOCKER_3\b")),
    Matcher("gha-workflow-hygiene", "human-review", _id_regex(r"CKV_GHA_\d+\b")),
    Matcher("postmessage-wildcard-origin", "human-review",
            _and(_scanner_is("semgrep"), _id_contains("wildcard-postmessage"))),
    # ---- deps ----
    Matcher("dep-cve", "auto-patch", _scanner_is("trivy")),  # routing refined later by version-bump kind
    # ---- supply chain ----
    Matcher("supply-unsigned", "human-review", _id_contains("supply-unsigned")),
    Matcher("supply-new-maintainer", "human-review", _id_contains("supply-new-maintainer")),
    Matcher("supply-low-scorecard", "human-review", _id_contains("supply-low-scorecard")),
    # ---- tests ----
    Matcher("test-failure", "human-review", _scanner_is("test-runner")),
]


# Categories that always route human-review regardless of matcher's claim.
ALWAYS_HUMAN_REVIEW = {
    "secret-leak",
    "iac-iam-wildcard",
    "database-schema-change",
    "dep-major-upgrade",
    "auth-flow-change",
    "crypto-algorithm-change",
    "command-injection",
    "weak-crypto",
    "localstorage-token",
    # §12 JWT — every change to JWT verification is a high-blast-radius edit
    "jwt-alg-not-pinned",
    "jwt-claims-not-validated",
    "jwt-weak-secret",
    # §13 SSRF — egress allowlist changes can break or expose
    "ssrf-no-allowlist",
    "ssrf-metadata-ip",
    # §15 agent-permissions — auto-fixing a permission widening defeats the gate
    "agent-bypass-permissions",
    "agent-wildcard-bash",
    # §16 prompt injection — architectural, not pattern
    "prompt-injection-untrusted-context",
    # §17 universal — pollution and breach are subtle
    "prototype-pollution",
    "nosql-operator-injection",
    "eval-untrusted-input",
    "breach-compression-on-auth",
    "fail-open-error-handler",
    # React XSS — DOMPurify call sites are sensitive
    "react-dangerous-html-unsanitized",
    # Prisma raw — string-interp into SQL is the SQL-injection class
    "prisma-raw-unsafe",
    "prisma-raw-user-input",
    "prisma-dynamic-column",
}



# ---------- reviewed / accepted findings ----------
#
# A finding that was looked at by a human and deliberately left in place is
# recorded in .claude/findings-accepted.json:
#   {"version": 1, "accepted": [
#     {"fingerprint": "<rule>:<file>:<line>", "reason": "...", "owner": "...",
#      "accepted_on": "YYYY-MM-DD", "expires_on": "YYYY-MM-DD", "ticket": "optional"}]}
# Every acceptance expires (max 12 months); the stamp predicate records the
# file hash and the accepted fingerprints, so an approval always says exactly
# what was waived and by whom.
ACCEPTED_FILE_DEFAULT = ".claude/findings-accepted.json"
ACCEPTANCE_MAX_DAYS = 366
_REQUIRED_KEYS = ("fingerprint", "reason", "owner", "accepted_on", "expires_on")


def load_accepted(path: Optional[str] = None) -> tuple[dict[str, dict], list[dict], list[str]]:
    """Return (active_by_fingerprint, expired_entries, problems)."""
    import datetime as _dt
    import os
    path = path or os.environ.get("DIAGNOSE_ACCEPTED_FILE") or ACCEPTED_FILE_DEFAULT
    if not os.path.isfile(path):
        return {}, [], []
    try:
        with open(path, encoding="utf-8") as fh:
            doc = json.load(fh)
    except (OSError, json.JSONDecodeError) as e:
        return {}, [], [f"{path}: unreadable ({e})"]
    today = _dt.date.today()
    active: dict[str, dict] = {}
    expired: list[dict] = []
    problems: list[str] = []
    for i, e in enumerate(doc.get("accepted", []) or []):
        missing = [k for k in _REQUIRED_KEYS if not e.get(k)]
        if missing:
            problems.append(f"entry {i}: missing {missing}")
            continue
        try:
            start = _dt.date.fromisoformat(e["accepted_on"])
            end = _dt.date.fromisoformat(e["expires_on"])
        except ValueError:
            problems.append(f"entry {i} ({e['fingerprint']}): dates must be YYYY-MM-DD")
            continue
        if (end - start).days > ACCEPTANCE_MAX_DAYS or end <= start:
            problems.append(f"entry {i} ({e['fingerprint']}): expiry must be within {ACCEPTANCE_MAX_DAYS} days of accepted_on")
            continue
        if end < today:
            expired.append(e)
            continue
        active[e["fingerprint"]] = e
    return active, expired, problems


# ---------- main pipeline ----------


def normalize(gate_results: list[dict]) -> list[dict]:
    """Flatten gate findings, tagging each with its source scanner."""
    out: list[dict] = []
    for g in gate_results:
        scanner = g.get("scanner") or g.get("gate", "").replace("gate-", "")
        if g.get("error"):
            continue
        for f in g.get("findings", []):
            f = dict(f)
            f["_scanner"] = scanner
            f["_gate"] = g.get("gate")
            out.append(f)
    return out


def classify(finding: dict) -> tuple[Optional[str], Optional[str], str]:
    """Return (category, routing, confidence). Returns Nones for unclassified."""
    for m in CATALOG:
        if m.matches(finding):
            routing = m.routing
            if m.category in ALWAYS_HUMAN_REVIEW:
                routing = "human-review"
            return m.category, routing, m.confidence
    return None, None, "low"


def refine_dep_cve(finding: dict) -> str:
    """A dep-cve is auto-patch only if the fix is a patch-version bump."""
    installed = finding.get("installed_version") or ""
    fixed = finding.get("fixed_version") or ""
    if not installed or not fixed:
        return "human-review"

    def _major(v: str) -> Optional[int]:
        m = re.match(r"^v?(\d+)", v)
        return int(m.group(1)) if m else None

    if _major(installed) != _major(fixed):
        return "human-review"  # major bump
    return "auto-patch"


def main() -> int:
    raw = sys.stdin.read()
    if not raw.strip():
        print(json.dumps({"error": "no input on stdin"}))
        return 2

    try:
        doc = json.loads(raw)
    except json.JSONDecodeError as e:
        print(json.dumps({"error": "invalid JSON on stdin", "detail": str(e)}))
        return 2

    findings = normalize(doc.get("gate_results", []))
    accepted_active, accepted_expired, acceptance_problems = load_accepted()
    categorized: list[dict] = []
    summary_by_cat: dict[str, int] = {}
    summary_by_route: dict[str, int] = {"auto-patch": 0, "human-review": 0, "unclassified": 0, "accepted": 0}
    unclassified_samples: list[dict] = []
    accepted_used: list[str] = []

    for f in findings:
        cat, route, conf = classify(f)
        acc = accepted_active.get(f.get("fingerprint") or "")
        if acc is not None:
            entry = {
                "fingerprint": f.get("fingerprint"),
                "original": {k: v for k, v in f.items() if not k.startswith("_")},
                "category": cat or "unclassified",
                "routing": "accepted",
                "confidence": conf if cat else "n/a",
                "acceptance": {k: acc.get(k) for k in ("reason", "owner", "accepted_on", "expires_on", "ticket")},
            }
            summary_by_route["accepted"] += 1
            accepted_used.append(entry["fingerprint"])
            categorized.append(entry)
            continue
        if cat is None:
            entry = {
                "fingerprint": f.get("fingerprint"),
                "original": {k: v for k, v in f.items() if not k.startswith("_")},
                "category": "unclassified",
                "routing": "unclassified",
                "confidence": "n/a",
            }
            summary_by_route["unclassified"] += 1
            if len(unclassified_samples) < 3:
                unclassified_samples.append(entry["original"])
        else:
            # special-case refinement
            if cat == "dep-cve":
                route = refine_dep_cve(f)

            entry = {
                "fingerprint": f.get("fingerprint"),
                "original": {k: v for k, v in f.items() if not k.startswith("_")},
                "category": cat,
                "routing": route,
                "confidence": conf,
                "recipe_ref": f".claude/skills/diagnose-categories/SKILL.md#{cat}",
            }
            summary_by_cat[cat] = summary_by_cat.get(cat, 0) + 1
            summary_by_route[route] = summary_by_route.get(route, 0) + 1

        categorized.append(entry)

    total = len(categorized)
    unclassified_count = summary_by_route.get("unclassified", 0)
    unclassified_rate = (unclassified_count / total) if total > 0 else 0.0
    # Acceptances whose fingerprint no longer appears are stale: the finding was
    # fixed or the file moved. Surface them so the file does not rot.
    accepted_stale = sorted(set(accepted_active) - set(accepted_used))

    output = {
        "diagnose_module_version": MODULE_VERSION,
        "catalog_size": len(CATALOG),
        "categorized": categorized,
        "summary": {
            "total": total,
            "by_category": summary_by_cat,
            "by_routing": summary_by_route,
            "unclassified_rate": round(unclassified_rate, 4),
            "unclassified_threshold": 0.05,
            "unclassified_examples": unclassified_samples,
            "accepted": len(accepted_used),
            "accepted_expired": [e.get("fingerprint") for e in accepted_expired],
            "accepted_stale": accepted_stale,
            "acceptance_problems": acceptance_problems,
            "drift_warning": (
                "unclassified_rate exceeds 0.05 — catalog drift; add categories or fix matchers"
                if unclassified_rate > 0.05
                else None
            ),
        },
    }
    print(json.dumps(output, indent=2))
    return 0


if __name__ == "__main__":
    sys.exit(main())
