#!/usr/bin/env bash
#
# install-verify.sh — install pinned scanner versions from tool-versions.json,
# verifying integrity with cosign keyless (where the tool publishes attestations)
# or SHA256 (where it doesn't).
#
# Usage:
#   ./.claude/scripts/install-verify.sh [TOOL...]   # default: all enabled tools
#   ./.claude/scripts/install-verify.sh --check     # check what's installed vs pinned
#   ./.claude/scripts/install-verify.sh --capture-hashes TOOL
#       Download the asset for TOOL and print its SHA256 (for filling in PINME).
#
# The goal (v2 §3.6): the gate chain trusting `trivy:latest` is the gate chain.
# Every scanner version is pinned by digest; an install that doesn't match a
# known good pin halts. Re-pin quarterly, not on every patch release.

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

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
VERSIONS_FILE="$SCRIPT_DIR/tool-versions.json"
INSTALL_DIR="${INSTALL_DIR:-$HOME/.local/bin}"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

if [[ ! -f "$VERSIONS_FILE" ]]; then
  echo "error: $VERSIONS_FILE not found" >&2
  exit 1
fi
command -v jq >/dev/null 2>&1 || { echo "jq required" >&2; exit 1; }
command -v curl >/dev/null 2>&1 || { echo "curl required" >&2; exit 1; }

mkdir -p "$INSTALL_DIR"
case ":$PATH:" in
  *":$INSTALL_DIR:"*) : ;;
  *) echo "warn: $INSTALL_DIR is not on PATH" >&2 ;;
esac

# ---------- platform detection ----------

PLAT_OS="linux"; case "$(uname -s)" in Darwin) PLAT_OS="darwin" ;; esac
PLAT_ARCH="amd64"
case "$(uname -m)" in
  arm64|aarch64) PLAT_ARCH="arm64" ;;
  x86_64) PLAT_ARCH="amd64" ;;
esac

# ---------- subcommands ----------

ACTION="install"
TOOLS_ARG=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --check)            ACTION="check"; shift ;;
    --capture-hashes)   ACTION="capture-hashes"; shift ;;
    -h|--help)
      sed -n '3,16p' "$0"
      exit 0 ;;
    -*) echo "unknown arg: $1" >&2; exit 2 ;;
    *)  TOOLS_ARG+=("$1"); shift ;;
  esac
done

read_pinned_tools() {
  jq -r '.tools | to_entries | .[] | .key' "$VERSIONS_FILE"
}

# ---------- check action ----------

if [[ "$ACTION" == "check" ]]; then
  echo "Tool versions check vs $VERSIONS_FILE"
  echo
  printf "%-12s %-12s %s\n" "TOOL" "INSTALLED" "PINNED"
  for tool in $(read_pinned_tools); do
    pinned=$(jq -r --arg t "$tool" '.tools[$t].version' "$VERSIONS_FILE")
    if command -v "$tool" >/dev/null 2>&1; then
      case "$tool" in
        trivy)    installed=$($tool --version 2>/dev/null | head -1 | awk '{print $2}') ;;
        grype)    installed=$($tool version 2>/dev/null | grep -i '^application:' | awk '{print $2}') ;;
        syft)     installed=$($tool version 2>/dev/null | grep -i '^application:' | awk '{print $2}') ;;
        cosign)   installed=$($tool version 2>/dev/null | grep -i 'gitversion' | awk '{print $2}') ;;
        semgrep)  installed=$($tool --version 2>/dev/null | head -1) ;;
        checkov)  installed=$($tool --version 2>/dev/null | head -1) ;;
        gitleaks) installed=$($tool version 2>/dev/null | awk '{print $NF}') ;;
        tfsec)    installed=$($tool --version 2>/dev/null | awk '{print $NF}') ;;
        pip-audit)installed=$($tool --version 2>/dev/null | awk '{print $NF}') ;;
        scorecard)installed=$($tool version 2>/dev/null | head -1) ;;
        *)        installed="(unknown probe)" ;;
      esac
      mark="✓"
      case "$installed" in *"$pinned"*) : ;; *) mark="✗ drift" ;; esac
      printf "%-12s %-12s %s  %s\n" "$tool" "${installed:-unknown}" "$pinned" "$mark"
    else
      printf "%-12s %-12s %s  (not installed)\n" "$tool" "—" "$pinned"
    fi
  done
  exit 0
fi

# ---------- capture-hashes action ----------

if [[ "$ACTION" == "capture-hashes" ]]; then
  if [[ ${#TOOLS_ARG[@]} -eq 0 ]]; then
    echo "usage: $0 --capture-hashes TOOL" >&2; exit 2
  fi
  for tool in "${TOOLS_ARG[@]}"; do
    repo=$(jq -r --arg t "$tool" '.tools[$t].repo // empty' "$VERSIONS_FILE")
    version=$(jq -r --arg t "$tool" '.tools[$t].version // empty' "$VERSIONS_FILE")
    template=$(jq -r --arg t "$tool" '.tools[$t].asset_template // empty' "$VERSIONS_FILE")
    if [[ -z "$repo" || -z "$version" || -z "$template" ]]; then
      echo "skip $tool: no GitHub release asset configured" >&2; continue
    fi
    asset="${template//\{version\}/$version}"
    asset="${asset//\{os\}/$PLAT_OS}"
    asset="${asset//\{arch\}/$PLAT_ARCH}"
    url="https://github.com/$repo/releases/download/v$version/$asset"
    echo "downloading $url" >&2
    curl -fsSL --retry 3 "$url" -o "$TMP_DIR/$asset"
    sha=$(sha256sum "$TMP_DIR/$asset" | awk '{print $1}')
    echo "$tool ${PLAT_OS}-${PLAT_ARCH} sha256:$sha"
  done
  exit 0
fi

# ---------- install action ----------

install_one() {
  local tool="$1"
  local version repo template install_via verify_with cosign_identity cosign_issuer
  version=$(jq -r --arg t "$tool" '.tools[$t].version // empty' "$VERSIONS_FILE")
  install_via=$(jq -r --arg t "$tool" '.tools[$t].install_via // empty' "$VERSIONS_FILE")
  repo=$(jq -r --arg t "$tool" '.tools[$t].repo // empty' "$VERSIONS_FILE")
  template=$(jq -r --arg t "$tool" '.tools[$t].asset_template // empty' "$VERSIONS_FILE")
  verify_with=$(jq -r --arg t "$tool" '.tools[$t].verify_with // empty' "$VERSIONS_FILE")
  cosign_identity=$(jq -r --arg t "$tool" '.tools[$t].cosign_identity // empty' "$VERSIONS_FILE")
  cosign_issuer=$(jq -r --arg t "$tool" '.tools[$t].cosign_issuer // empty' "$VERSIONS_FILE")
  cosign_identity="${cosign_identity//\{version\}/$version}"

  echo "==> $tool $version (verify_with=$verify_with)"

  if [[ "$install_via" == "pipx" ]]; then
    if ! command -v pipx >/dev/null 2>&1; then
      echo "pipx not installed; cannot install $tool" >&2
      return 1
    fi
    pipx install --force "${tool}==${version}" >/dev/null 2>&1 \
      || { echo "pipx install $tool==$version failed" >&2; return 1; }
    echo "    installed via pipx"
    return 0
  fi

  # GitHub release-asset path
  if [[ -z "$repo" || -z "$template" ]]; then
    echo "    skip: no repo/asset configured" >&2
    return 0
  fi

  local asset url tarball
  asset="${template//\{version\}/$version}"
  asset="${asset//\{os\}/$PLAT_OS}"
  asset="${asset//\{arch\}/$PLAT_ARCH}"
  url="https://github.com/$repo/releases/download/v$version/$asset"

  tarball="$TMP_DIR/$asset"
  echo "    downloading $url"
  if ! curl -fsSL --retry 3 "$url" -o "$tarball"; then
    echo "    download failed" >&2; return 1
  fi

  # Verification path
  case "$verify_with" in
    cosign-keyless)
      if ! command -v cosign >/dev/null 2>&1; then
        echo "    warn: cosign not installed, cannot verify keyless signature; skipping verify" >&2
      else
        local sig_url cert_url
        sig_url="${url}.sig"
        cert_url="${url}.pem"
        curl -fsSL --retry 3 "$sig_url"  -o "${tarball}.sig"  || sig_url=""
        curl -fsSL --retry 3 "$cert_url" -o "${tarball}.pem" || cert_url=""
        if [[ -f "${tarball}.sig" && -f "${tarball}.pem" && -n "$cosign_identity" ]]; then
          if cosign verify-blob \
                --signature "${tarball}.sig" \
                --certificate "${tarball}.pem" \
                --certificate-identity "$cosign_identity" \
                --certificate-oidc-issuer "${cosign_issuer:-https://token.actions.githubusercontent.com}" \
                "$tarball" >/dev/null 2>&1; then
            echo "    cosign keyless verify: OK"
          else
            echo "    cosign keyless verify FAILED — refusing install" >&2
            return 1
          fi
        else
          echo "    warn: signature sidecar missing; cannot verify" >&2
        fi
      fi
      ;;
    sha256)
      local pinned
      pinned=$(jq -r --arg t "$tool" --arg key "${PLAT_OS}-${PLAT_ARCH}_sha256" '.tools[$t][$key] // .tools[$t].sha256 // empty' "$VERSIONS_FILE")
      if [[ -z "$pinned" || "$pinned" == "PINME" ]]; then
        echo "    warn: no pinned SHA256 for $tool/${PLAT_OS}-${PLAT_ARCH} — run --capture-hashes" >&2
      else
        local got
        got=$(sha256sum "$tarball" | awk '{print $1}')
        if [[ "$got" != "${pinned#sha256:}" ]]; then
          echo "    SHA256 MISMATCH — refusing install: got=$got pinned=${pinned#sha256:}" >&2
          return 1
        fi
        echo "    sha256 verify: OK"
      fi
      ;;
    self-bootstrap)
      echo "    self-bootstrap: skipping verify on first install (use cosign-keyless after)" ;;
    *)
      echo "    no verifier configured" ;;
  esac

  # Extract and install
  case "$asset" in
    *.tar.gz)
      tar -C "$TMP_DIR" -xzf "$tarball"
      # The expected binary name is the tool itself
      local bin="$TMP_DIR/$tool"
      [[ -f "$bin" ]] || bin=$(find "$TMP_DIR" -maxdepth 2 -type f -name "$tool" | head -1)
      [[ -n "$bin" && -f "$bin" ]] || { echo "    extracted but no $tool binary found" >&2; return 1; }
      install -m 0755 "$bin" "$INSTALL_DIR/$tool"
      ;;
    *)
      install -m 0755 "$tarball" "$INSTALL_DIR/$tool"
      ;;
  esac
  echo "    installed → $INSTALL_DIR/$tool"
}

if [[ ${#TOOLS_ARG[@]} -eq 0 ]]; then
  mapfile -t TOOLS_ARG < <(read_pinned_tools)
fi

ANY_FAILED=0
for t in "${TOOLS_ARG[@]}"; do
  if ! install_one "$t"; then
    ANY_FAILED=1
  fi
done

if [[ "$ANY_FAILED" -ne 0 ]]; then
  echo
  echo "one or more installs failed — see above" >&2
  exit 1
fi
echo
echo "done. Run \`$0 --check\` to verify pinned vs installed."
