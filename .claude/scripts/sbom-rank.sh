#!/usr/bin/env bash
#
# sbom-rank.sh — generate an SBOM with syft, then rank vulnerabilities.
#
# Usage:
#   ./.claude/scripts/sbom-rank.sh [TARGET] [--top N] [--refresh]
#
# TARGET defaults to `dir:.`. Other useful targets:
#   ghcr.io/example/image:tag      — scan a container image
#   /path/to/binary                — scan a single binary
#
# Output:
#   .claude/state/sbom-ranked.json — full ranked list
#   .claude/state/sbom-latest.spdx.json — the SBOM that was scored
#
# Exits non-zero only on infra error. Findings (even P0) don't change the
# exit code — this is a daily reporting script, not a gate. Pair with
# `/sbom` slash command for a polished console summary.

set -euo pipefail

# --- Windows/Git-Bash → WSL re-exec guard ---
if [ -z "${ADVISOR_IN_WSL:-}" ] && [ "$(uname -o 2>/dev/null)" = "Msys" ]; then
  WIN_CWD="$(pwd -W 2>/dev/null || pwd)"
  exec env MSYS_NO_PATHCONV=1 MSYS2_ARG_CONV_EXCL='*' \
    wsl.exe -d Ubuntu-24.04 --cd "$WIN_CWD" -- \
    bash /home/jaupo/.claude/scripts/.wsl-exec.sh \
    "/home/jaupo/.claude/scripts/$(basename "$0")" "$@"
fi
# --- end guard ---

TARGET="dir:."
TOP=20
REFRESH=""

if [[ $# -gt 0 && "$1" != --* ]]; then
  TARGET="$1"
  shift
fi
while [[ $# -gt 0 ]]; do
  case "$1" in
    --top)     TOP="$2"; shift 2 ;;
    --refresh) REFRESH="--refresh"; shift ;;
    -h|--help)
      sed -n '3,18p' "$0"
      exit 0 ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
done

if ! command -v syft >/dev/null 2>&1; then
  echo "syft not installed. Install: curl -sSfL https://raw.githubusercontent.com/anchore/syft/main/install.sh | sh -s -- -b /usr/local/bin" >&2
  exit 1
fi
if ! command -v python3 >/dev/null 2>&1; then
  echo "python3 not found" >&2
  exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
STATE_DIR=""
# Walk up to find the nearest .claude/state/
cur="$(pwd)"
while [[ "$cur" != "/" ]]; do
  if [[ -d "$cur/.claude" ]]; then
    STATE_DIR="$cur/.claude/state"
    break
  fi
  cur="$(dirname "$cur")"
done
STATE_DIR="${STATE_DIR:-$HOME/Projects/.claude/state}"
mkdir -p "$STATE_DIR"

SBOM_PATH="$STATE_DIR/sbom-latest.spdx.json"
RANKED_PATH="$STATE_DIR/sbom-ranked.json"

echo ">>> generating SBOM for $TARGET" >&2
syft "$TARGET" -o spdx-json --quiet > "$SBOM_PATH"

echo ">>> ranking vulnerabilities" >&2
python3 "$SCRIPT_DIR/sbom-rank.py" --top "$TOP" --out "$RANKED_PATH" $REFRESH < "$SBOM_PATH" > /dev/null

echo "" >&2
echo ">>> wrote $RANKED_PATH" >&2
echo ">>> SBOM at $SBOM_PATH" >&2

# Print a one-line P0/P1 callout for shell consumption
P0=$(python3 -c "import json; d=json.load(open('$RANKED_PATH')); print(d['summary']['by_priority'].get('P0',0))")
P1=$(python3 -c "import json; d=json.load(open('$RANKED_PATH')); print(d['summary']['by_priority'].get('P1',0))")
echo "P0=$P0 P1=$P1"
