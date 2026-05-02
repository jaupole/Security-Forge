#!/usr/bin/env bash
# Run every verify-*.sh in order. Prints one line per script with PASS/
# FAIL/SKIP status; exits 0 only if every script returned 0.
#
# Phase 7 schedules this as a weekly CronJob; failures emit
# severity=critical events. Operator-runnable today.
#
# Usage:
#   bash infrastructure/secrets-guardrails/verify/run-all.sh
#   LIVE=1 bash infrastructure/secrets-guardrails/verify/run-all.sh   # live cluster cases too
#
# Exit codes:
#   0  — all scripts passed (or skipped cleanly)
#   1  — at least one script failed
#   2  — at least one script returned 2 (operator setup issue) and none failed

set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"

green()  { printf '\033[32m%s\033[0m\n' "$*"; }
yellow() { printf '\033[33m%s\033[0m\n' "$*"; }
red()    { printf '\033[31m%s\033[0m\n' "$*" >&2; }
bold()   { printf '\033[1m%s\033[0m\n' "$*"; }

bold "──────────────────────────────────────────────────"
bold "SecForge guardrail verification suite (ADR-0013)"
bold "──────────────────────────────────────────────────"

FAIL=0
SETUP=0
PASS=0
TOTAL=0

for script in "$HERE"/[0-9][0-9]-*.sh; do
    name=$(basename "$script")
    TOTAL=$((TOTAL+1))
    bold ""
    bold "▶ $name"
    bash "$script"
    rc=$?
    case $rc in
        0)
            PASS=$((PASS+1))
            green "  ✓ $name"
            ;;
        2)
            SETUP=$((SETUP+1))
            yellow "  ⚠ $name (operator setup issue, exit=2)"
            ;;
        *)
            FAIL=$((FAIL+1))
            red   "  ✗ $name (exit=$rc)"
            ;;
    esac
done

bold ""
bold "──────────────────────────────────────────────────"
bold "Summary: $PASS/$TOTAL passed, $FAIL failed, $SETUP setup-issue"
bold "──────────────────────────────────────────────────"

if [ $FAIL -gt 0 ]; then
    red "FAIL — $FAIL guardrail layer(s) regressed. Re-run the failing"
    red "scripts individually for full output:"
    red "  ls $HERE/[0-9][0-9]-*.sh"
    exit 1
fi

if [ $SETUP -gt 0 ]; then
    yellow "ATTENTION — $SETUP script(s) skipped due to setup issues."
    yellow "Install missing tools (docker / pre-commit / kubectl) and re-run."
    exit 2
fi

green "ALL GUARDRAIL LAYERS HEALTHY ✅"
exit 0
