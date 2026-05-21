#!/usr/bin/env bash
#
# stamp.sh — produce a signed in-toto attestation (v2 §1.3) for the current state.
#
# Usage:
#   ./.claude/scripts/stamp.sh <subject> [--from-gate-run gate-run.json]
#                              [--patches patches.json]
#                              [--predicate predicate.json]
#                              [--mode keyless|local|auto]
#                              [--key cosign.key]
#
# Subjects:
#   - file path  → sign the file (writes .sig, .pem, .attestation.json)
#   - directory  → tar it, sign the tar
#   - container reference (something with a colon, not a path) → cosign attest
#
# Modes:
#   keyless  — cosign keyless via OIDC (GitHub Actions, GitLab OIDC, interactive flow)
#   local    — cosign sign-blob with a local key (for dev / no-OIDC environments)
#   auto     — keyless if OIDC env vars are present, else local (default)
#
# The auto-built predicate captures everything v2 §1.3 requires: gate
# scanner+config hashes, diagnose module version, rules+policy bundle hashes,
# patch transparency log.

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

# ---------- arg parsing ----------

SUBJECT=""
GATE_RUN_FILE=""
PATCHES_FILE=""
PREDICATE_FILE=""
MODE="auto"
KEY_FILE=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --from-gate-run) GATE_RUN_FILE="$2"; shift 2 ;;
    --patches)       PATCHES_FILE="$2"; shift 2 ;;
    --predicate)     PREDICATE_FILE="$2"; shift 2 ;;
    --mode)          MODE="$2"; shift 2 ;;
    --key)           KEY_FILE="$2"; shift 2 ;;
    -h|--help)
      sed -n '3,22p' "$0"
      exit 0 ;;
    -*)
      echo "unknown arg: $1" >&2; exit 2 ;;
    *)
      if [[ -z "$SUBJECT" ]]; then SUBJECT="$1"; else echo "extra arg: $1" >&2; exit 2; fi
      shift ;;
  esac
done

if [[ -z "$SUBJECT" ]]; then
  echo "usage: $0 <subject> [options]" >&2
  exit 2
fi

# ---------- prerequisites ----------

require() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "error: $1 not installed${2:+ — $2}" >&2
    exit 1
  }
}

require cosign "install: https://docs.sigstore.dev/system_config/installation/"
require jq
require sha256sum
require python3

# ---------- mode resolution ----------

resolve_mode() {
  if [[ "$MODE" == "auto" ]]; then
    if [[ -n "${ACTIONS_ID_TOKEN_REQUEST_TOKEN:-}${GITLAB_OIDC_TOKEN:-}${SIGSTORE_ID_TOKEN:-}" ]]; then
      MODE="keyless"
    else
      MODE="local"
    fi
  fi
  case "$MODE" in
    keyless|local) : ;;
    *) echo "invalid --mode: $MODE" >&2; exit 2 ;;
  esac
}
resolve_mode
echo ">>> signing mode: $MODE" >&2

# ---------- predicate construction ----------

# Find the nearest .claude/
find_claude_root() {
  local cur
  cur="$(pwd)"
  while [[ "$cur" != "/" ]]; do
    if [[ -d "$cur/.claude" ]]; then
      echo "$cur/.claude"
      return
    fi
    cur="$(dirname "$cur")"
  done
  echo ""
}

CLAUDE_DIR=$(find_claude_root)
if [[ -z "$CLAUDE_DIR" ]]; then
  echo "warn: no .claude/ found; predicate will be sparse" >&2
fi

# Hash a single file (relative to CLAUDE_DIR root) safely
hash_file() {
  local f="$1"
  if [[ -f "$f" ]]; then
    sha256sum "$f" | awk '{print "sha256:" $1}'
  else
    echo "sha256:absent"
  fi
}

# Deterministic hash of the entire .claude/ tree (excluding state/ and tests/fixtures/)
hash_policy_bundle() {
  if [[ -z "$CLAUDE_DIR" ]]; then echo "sha256:absent"; return; fi
  ( cd "$CLAUDE_DIR" \
      && find . -type f \
           -not -path './state/*' \
           -not -path './scripts/tests/fixtures/*' \
           -print0 \
      | sort -z \
      | xargs -0 sha256sum ) 2>/dev/null \
    | sha256sum \
    | awk '{print "sha256:" $1}'
}

# Convert run-gates.sh output into the gates_passed[] array
build_gates_passed() {
  local gate_run="$1"
  if [[ ! -f "$gate_run" ]]; then echo "[]"; return; fi
  jq '
    (.gate_results // [])
    | map(select(.error == null))
    | map({
        name: .gate,
        scanner: (.scanner // .framework // "n/a"),
        scanner_version: (.scanner_version // "n/a"),
        runtime_seconds: (.runtime_seconds // 0),
        findings_count: ((.findings // []) | length)
      })
  ' "$gate_run"
}

# patches_applied[] — accept user-provided JSON or default to []
build_patches_applied() {
  if [[ -n "$PATCHES_FILE" && -f "$PATCHES_FILE" ]]; then
    jq '.' "$PATCHES_FILE"
  else
    echo "[]"
  fi
}

if [[ -z "$PREDICATE_FILE" ]]; then
  PREDICATE_FILE=$(mktemp --suffix=.predicate.json)
  GATES_JSON=$(build_gates_passed "$GATE_RUN_FILE")
  PATCHES_JSON=$(build_patches_applied)

  # Extract tier from the gate-run JSON if available
  TIER="manual"
  if [[ -n "$GATE_RUN_FILE" && -f "$GATE_RUN_FILE" ]]; then
    TIER=$(jq -r '.tier // "manual"' "$GATE_RUN_FILE")
  fi
  ADVISOR_RUN_ID=""
  if [[ -n "$GATE_RUN_FILE" && -f "$GATE_RUN_FILE" ]]; then
    ADVISOR_RUN_ID=$(jq -r '.advisor_run_id // ""' "$GATE_RUN_FILE")
  fi

  RULES_HASH=$(hash_file "$CLAUDE_DIR/security-rules.md")
  BUNDLE_HASH=$(hash_policy_bundle)

  # Diagnose module version — read from diagnose.py constant if present
  DIAG_VERSION="unknown"
  if [[ -n "$CLAUDE_DIR" && -f "$CLAUDE_DIR/scripts/diagnose.py" ]]; then
    DIAG_VERSION=$(grep -E '^MODULE_VERSION\s*=' "$CLAUDE_DIR/scripts/diagnose.py" \
      | head -1 | sed -E 's/.*"(.+)".*/\1/' || echo "unknown")
  fi

  jq -n \
    --arg approved_at "$(date -u +"%Y-%m-%dT%H:%M:%SZ")" \
    --arg git_sha "$(git rev-parse HEAD 2>/dev/null || echo 'no-git')" \
    --arg git_branch "$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo 'no-git')" \
    --arg tier "$TIER" \
    --arg advisor_run_id "$ADVISOR_RUN_ID" \
    --argjson gates_passed "$GATES_JSON" \
    --argjson patches_applied "$PATCHES_JSON" \
    --arg diag_version "$DIAG_VERSION" \
    --arg rules_hash "$RULES_HASH" \
    --arg bundle_hash "$BUNDLE_HASH" \
    --arg signing_mode "$MODE" \
    '{
      approved_at:$approved_at,
      git_sha:$git_sha,
      git_branch:$git_branch,
      tier:$tier,
      advisor_run_id:$advisor_run_id,
      gates_passed:$gates_passed,
      diagnose_module_version:$diag_version,
      rules_version_sha256:$rules_hash,
      policy_bundle_hash:$bundle_hash,
      patch_governance_version:"2.0.0",
      patches_applied:$patches_applied,
      signer:{ mode:$signing_mode, host: (env.HOSTNAME // "unknown") }
    }' >"$PREDICATE_FILE"

  echo ">>> built predicate at $PREDICATE_FILE" >&2
fi

# ---------- subject classification ----------

SUBJECT_KIND="container"
if [[ -f "$SUBJECT" ]]; then SUBJECT_KIND="file"
elif [[ -d "$SUBJECT" ]]; then SUBJECT_KIND="dir"
fi

# ---------- sign ----------

case "$SUBJECT_KIND" in
  container)
    if [[ "$MODE" == "keyless" ]]; then
      cosign attest \
        --predicate "$PREDICATE_FILE" \
        --type "https://forge.praxis/attestations/v1" \
        --yes \
        "$SUBJECT"
    else
      if [[ -z "$KEY_FILE" ]]; then
        echo "local mode requires --key cosign.key" >&2; exit 2
      fi
      cosign attest \
        --key "$KEY_FILE" \
        --predicate "$PREDICATE_FILE" \
        --type "https://forge.praxis/attestations/v1" \
        --yes \
        "$SUBJECT"
    fi
    echo "stamped container: $SUBJECT" >&2
    ;;

  file)
    digest=$(sha256sum "$SUBJECT" | awk '{print $1}')
    name=$(basename "$SUBJECT")
    sig_path="${SUBJECT}.sig"
    cert_path="${SUBJECT}.pem"
    att_path="${SUBJECT}.attestation.json"

    if [[ "$MODE" == "keyless" ]]; then
      cosign sign-blob \
        --output-signature "$sig_path" \
        --output-certificate "$cert_path" \
        --yes \
        "$SUBJECT"
    else
      if [[ -z "$KEY_FILE" ]]; then
        echo "local mode requires --key cosign.key" >&2; exit 2
      fi
      cosign sign-blob \
        --key "$KEY_FILE" \
        --output-signature "$sig_path" \
        --yes \
        "$SUBJECT"
    fi

    # Wrap predicate as in-toto Statement and write sidecar
    jq -n \
      --arg name "$name" \
      --arg digest "$digest" \
      --slurpfile pred "$PREDICATE_FILE" \
      '{
        _type:"https://in-toto.io/Statement/v0.1",
        subject:[{ name:$name, digest:{ sha256:$digest } }],
        predicateType:"https://forge.praxis/attestations/v1",
        predicate: $pred[0]
      }' >"$att_path"

    echo "stamped file: $SUBJECT" >&2
    echo "  signature:   $sig_path" >&2
    [[ -f "$cert_path" ]] && echo "  certificate: $cert_path" >&2
    echo "  attestation: $att_path" >&2
    echo ""
    echo "$att_path"
    ;;

  dir)
    bundle=$(mktemp --suffix=.tar)
    tar -cf "$bundle" -C "$SUBJECT" . 2>/dev/null
    echo ">>> tar of $SUBJECT → $bundle" >&2
    extra_args=()
    [[ "$MODE" == "local" && -n "$KEY_FILE" ]] && extra_args=(--mode local --key "$KEY_FILE")
    "$0" "$bundle" --predicate "$PREDICATE_FILE" "${extra_args[@]}"
    ;;
esac
