#!/usr/bin/env bash
#
# run-gates.sh — invoke configured security gates and emit combined JSON.
#
# Usage:
#   ./.claude/scripts/run-gates.sh [--tier pre-commit|pr|merge|pre-deploy] [--base-sha SHA]
#
# Tiers (v2 §1, fast vs slow split):
#   pre-commit  — fastest. format, lint, secrets-on-staged. <5s budget.
#   pr          — fast PR gates. <30s budget. SAST diff, IaC diff, tests, signatures.
#   merge       — slow gates on merge-to-main. Full SAST, full Trivy, license sweep, full SBOM.
#   pre-deploy  — release pipeline. Container scan, attestation verify, DAST.
#
# Output: a single JSON document on stdout with the gate_results array, the tier
# that ran, and the gates_in_tier list so a stamp signer can record exactly what
# was judged.
#
# Exit code: 0 if all gates ran (regardless of findings); non-zero only on infra error.
#
# The orchestrator subagent decides pass/fail based on the JSON contents — this
# script just runs the tools and aggregates their output.

set -euo pipefail

# --- Windows/Git-Bash → WSL re-exec guard ---
# When invoked from Claude Code on Windows, scanners live in WSL Ubuntu-24.04
# and not in Git Bash's PATH. Re-exec transparently so the caller never knows.
if [ -z "${ADVISOR_IN_WSL:-}" ] && [ "$(uname -o 2>/dev/null)" = "Msys" ]; then
  WIN_CWD="$(pwd -W 2>/dev/null || pwd)"
  exec env MSYS_NO_PATHCONV=1 MSYS2_ARG_CONV_EXCL='*' \
    wsl.exe -d Ubuntu-24.04 --cd "$WIN_CWD" -- \
    bash /home/jaupo/.claude/scripts/.wsl-exec.sh \
    "/home/jaupo/.claude/scripts/$(basename "$0")" "$@"
fi
# --- end guard ---

TIER="pr"
BASE_SHA=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --tier)      TIER="$2"; shift 2 ;;
    --scope)
      # Back-compat: --scope full → --tier merge, pr → pr, pre-commit → pre-commit
      case "$2" in
        full)        TIER="merge" ;;
        pr)          TIER="pr" ;;
        pre-commit)  TIER="pre-commit" ;;
        *)           echo "unknown --scope value: $2" >&2; exit 2 ;;
      esac
      shift 2 ;;
    --base-sha)  BASE_SHA="$2"; shift 2 ;;
    -h|--help)
      sed -n '3,20p' "$0"
      exit 0 ;;
    *)
      echo "unknown arg: $1" >&2
      exit 2 ;;
  esac
done

case "$TIER" in
  pre-commit|pr|merge|pre-deploy) : ;;
  *) echo "invalid --tier: $TIER (use pre-commit|pr|merge|pre-deploy)" >&2; exit 2 ;;
esac

# SCOPE is referenced inside individual gate functions (e.g. gate_tests skips at
# pre-commit). Map TIER → SCOPE for back-compat with those internal checks.
SCOPE="$TIER"

# ---------- helpers ----------

require_jq() {
  command -v jq >/dev/null 2>&1 || {
    echo '{"error":"jq required for run-gates.sh"}' >&2
    exit 1
  }
}

now_iso() { date -u +"%Y-%m-%dT%H:%M:%SZ"; }

git_sha() {
  git rev-parse HEAD 2>/dev/null || echo "no-git"
}

git_branch() {
  git rev-parse --abbrev-ref HEAD 2>/dev/null || echo "no-git"
}

# Emit a gate-error result and continue.
gate_error() {
  local name="$1" reason="$2" install_hint="${3:-}"
  jq -n \
    --arg gate "$name" \
    --arg err  "$reason" \
    --arg hint "$install_hint" \
    '{gate:$gate, error:$err, install_hint:$hint}'
}

# Time a command, capture stdout, return JSON {findings: [...], runtime_seconds}.
time_and_capture() {
  local start_ns end_ns runtime
  start_ns=$(date +%s%N)
  set +e
  local raw
  raw=$("$@" 2>/dev/null || true)
  set -e
  end_ns=$(date +%s%N)
  runtime=$(awk -v s="$start_ns" -v e="$end_ns" 'BEGIN { printf "%.2f", (e-s)/1e9 }')
  printf '%s\n%s\n' "$runtime" "$raw"
}

# ---------- gate: sast (semgrep) ----------

gate_sast() {
  if ! command -v semgrep >/dev/null 2>&1; then
    gate_error "gate-sast" "semgrep not installed" "brew install semgrep"
    return
  fi

  local version configs=(--config p/security-audit --config p/secrets --config p/owasp-top-ten)
  version=$(semgrep --version 2>/dev/null || echo "unknown")

  local args=(semgrep "${configs[@]}" --config auto --severity ERROR --severity WARNING --json --quiet)
  if [[ "$SCOPE" == "pr" && -n "$BASE_SHA" ]]; then
    args+=(--baseline-commit "$BASE_SHA")
  else
    args+=(.)
  fi

  local raw runtime
  runtime=$(date +%s)
  set +e
  raw=$("${args[@]}" 2>/dev/null)
  set -e
  runtime=$(( $(date +%s) - runtime ))

  if [[ -z "$raw" ]]; then
    gate_error "gate-sast" "semgrep produced no output"
    return
  fi

  # semgrep --json normally returns {results:[...], ...}. Some configs
  # (e.g. --config auto on newer semgrep, or certain error shapes) return
  # a bare array. Accept both.
  jq -n \
    --arg gate "gate-sast" \
    --arg scanner "semgrep" \
    --arg version "$version" \
    --argjson runtime "$runtime" \
    --argjson raw "$raw" \
    '{
      gate:$gate, scanner:$scanner, scanner_version:$version,
      runtime_seconds:$runtime,
      findings: ((if ($raw|type) == "array" then $raw else ($raw.results // []) end) | map({
        id: .check_id,
        severity: (.extra.severity // "WARNING"),
        message: .extra.message,
        file: .path,
        line_start: .start.line,
        line_end: .end.line,
        cwe: (.extra.metadata.cwe // null),
        owasp: (.extra.metadata.owasp // null),
        fingerprint: (.check_id + ":" + .path + ":" + (.start.line|tostring))
      }))
    }'
}

# ---------- gate: deps (trivy) ----------

gate_deps() {
  if ! command -v trivy >/dev/null 2>&1; then
    gate_error "gate-deps" "trivy not installed" "brew install trivy"
    return
  fi

  local version raw runtime
  version=$(trivy --version 2>/dev/null | head -1 | awk '{print $2}' || echo "unknown")
  runtime=$(date +%s)

  set +e
  raw=$(trivy fs \
    --severity HIGH,CRITICAL \
    --ignore-unfixed \
    --skip-dirs node_modules,vendor,.venv,__pycache__,dist,build \
    --format json --quiet . 2>/dev/null)
  set -e
  runtime=$(( $(date +%s) - runtime ))

  if [[ -z "$raw" ]]; then raw='{"Results":[]}'; fi

  # Build the raw findings shape first.
  local base
  base=$(jq -n \
    --arg gate "gate-deps" \
    --arg scanner "trivy" \
    --arg version "$version" \
    --argjson runtime "$runtime" \
    --argjson raw "$raw" \
    '{
      gate:$gate, scanner:$scanner, scanner_version:$version,
      runtime_seconds:$runtime,
      findings: [
        ((if ($raw|type) == "array" then $raw else ($raw.Results // []) end))[]
        | select(.Vulnerabilities)
        | . as $r
        | .Vulnerabilities[]
        | {
            id: .VulnerabilityID,
            package: .PkgName,
            installed_version: .InstalledVersion,
            fixed_version: (.FixedVersion // null),
            severity: .Severity,
            cvss: (.CVSS.nvd.V3Score // .CVSS.redhat.V3Score // null),
            manifest_path: $r.Target,
            fingerprint: (.VulnerabilityID + ":" + .PkgName + ":" + .InstalledVersion)
          }
      ]
    }')

  # Enrich each finding with EPSS + KEV + layered priority (v2 §3).
  # If the enricher is missing or fails, fall back to the un-enriched base.
  local enricher="$(dirname "$0")/enrich-cves.py"
  if [[ -x "$enricher" ]] && command -v python3 >/dev/null 2>&1; then
    local enriched
    set +e
    enriched=$(echo "$base" | python3 "$enricher" --mode findings 2>/dev/null)
    set -e
    if [[ -n "$enriched" ]]; then
      echo "$enriched"
      return
    fi
  fi
  echo "$base"
}

# ---------- gate: iac (checkov) ----------

gate_iac() {
  if ! command -v checkov >/dev/null 2>&1; then
    gate_error "gate-iac" "checkov not installed" "pip install checkov"
    return
  fi

  # Detect if there's anything IaC-shaped to scan
  if ! find . -maxdepth 4 \( -name "*.tf" -o -name "Dockerfile" -o -name "*.yaml" -o -name "*.yml" \) \
        -not -path '*/node_modules/*' -not -path '*/.venv/*' -print -quit 2>/dev/null | grep -q .; then
    jq -n '{gate:"gate-iac", warning:"no IaC files detected", findings:[]}'
    return
  fi

  local version raw runtime
  version=$(checkov --version 2>/dev/null || echo "unknown")
  runtime=$(date +%s)

  set +e
  raw=$(checkov --directory . --output json --compact \
    --skip-path 'node_modules,.venv,dist,build,.terraform' \
    --soft-fail-on LOW,MEDIUM --quiet 2>/dev/null)
  set -e
  runtime=$(( $(date +%s) - runtime ))

  if [[ -z "$raw" ]]; then raw='{"results":{"failed_checks":[]}}'; fi

  jq -n \
    --arg gate "gate-iac" \
    --arg scanner "checkov" \
    --arg version "$version" \
    --argjson runtime "$runtime" \
    --argjson raw "$raw" \
    '{
      gate:$gate, scanner:$scanner, scanner_version:$version,
      runtime_seconds:$runtime,
      findings: ((if ($raw|type) == "array" then [] else ($raw.results.failed_checks // []) end) | map({
        id: .check_id,
        severity: (.severity // "MEDIUM"),
        message: .check_name,
        file: .file_path,
        line_start: (.file_line_range[0] // 0),
        line_end:   (.file_line_range[1] // 0),
        resource: .resource,
        framework: .file_abs_path,
        guideline_url: (.guideline // null),
        fingerprint: (.check_id + ":" + .file_path + ":" + ((.file_line_range[0] // 0)|tostring))
      }))
    }'
}

# ---------- gate: secrets (gitleaks) ----------

gate_secrets() {
  if ! command -v gitleaks >/dev/null 2>&1; then
    gate_error "gate-secrets" "gitleaks not installed" "brew install gitleaks"
    return
  fi

  local version raw runtime tmpfile
  version=$(gitleaks version 2>/dev/null || echo "unknown")
  tmpfile=$(mktemp)
  runtime=$(date +%s)

  set +e
  gitleaks detect --source . --no-banner --report-format json \
    --report-path "$tmpfile" --no-git --redact 2>/dev/null
  set -e
  runtime=$(( $(date +%s) - runtime ))

  raw=$(cat "$tmpfile" 2>/dev/null || echo "[]")
  rm -f "$tmpfile"
  if [[ -z "$raw" ]]; then raw="[]"; fi

  jq -n \
    --arg gate "gate-secrets" \
    --arg scanner "gitleaks" \
    --arg version "$version" \
    --argjson runtime "$runtime" \
    --argjson raw "$raw" \
    '{
      gate:$gate, scanner:$scanner, scanner_version:$version,
      runtime_seconds:$runtime,
      findings: ($raw | map({
        id: .RuleID,
        severity: "CRITICAL",
        message: .Description,
        file: .File,
        line_start: .StartLine,
        line_end: .EndLine,
        commit: (.Commit // "unstaged"),
        redacted_secret_preview: (.Secret // ""),
        fingerprint: (.RuleID + ":" + .File + ":" + (.StartLine|tostring))
      }))
    }'
}

# ---------- gate: supply-chain (publish-time, v2 §2) ----------
#
# Publish-time signals catch what OSV/Trivy cannot — typosquats, install-script
# malware, unsigned packages, projects with poor hygiene. Each sub-scanner is
# optional; we explicitly track scanners_run vs scanners_skipped so the result
# can never silently lie about coverage.

gate_supply_chain() {
  local result='{"gate":"gate-supply-chain","scanners_run":[],"scanners_skipped":[],"findings":[]}'

  # Helper: record a skipped scanner with a reason
  skip() {
    local name="$1" reason="$2" hint="${3:-}"
    result=$(echo "$result" | jq \
      --arg n "$name" --arg r "$reason" --arg h "$hint" \
      '.scanners_skipped += [{scanner:$n, reason:$r, install_hint:$h}]')
  }

  # ---- npm: signature verification ----
  if [[ -f package-lock.json || -f yarn.lock || -f pnpm-lock.yaml ]]; then
    if command -v npm >/dev/null 2>&1; then
      local raw
      set +e
      raw=$(npm audit signatures --json 2>/dev/null || echo '{}')
      set -e
      result=$(echo "$result" | jq --argjson r "$raw" '
        .scanners_run += ["npm-audit-signatures"]
        | .findings += ($r.invalid // [] | map({
            id:"SUPPLY-UNSIGNED",
            severity:"CRITICAL",
            package:.name,
            ecosystem:"npm",
            signal:"no valid registry signature",
            scanner:"npm-audit-signatures",
            fingerprint:("supply-unsigned:npm:" + .name)
          }))')
    else
      skip "npm-audit-signatures" "npm not installed" "install Node.js"
    fi
  fi

  # ---- npm/yarn: Socket security scan (publish-time intel) ----
  if [[ -f package.json ]]; then
    if command -v socket >/dev/null 2>&1; then
      local socket_raw
      set +e
      socket_raw=$(socket security scan . --json 2>/dev/null || echo '{}')
      set -e
      result=$(echo "$result" | jq --argjson r "$socket_raw" '
        .scanners_run += ["socket"]
        | .findings += (($r.alerts // []) | map({
            id:("SUPPLY-SOCKET-" + (.type // "UNKNOWN" | ascii_upcase)),
            severity:(.severity // "MEDIUM" | ascii_upcase),
            package:(.package // .name // "unknown"),
            ecosystem:"npm",
            signal:(.title // .description // "socket alert"),
            scanner:"socket",
            fingerprint:("supply-socket:" + (.type // "x") + ":" + (.package // .name // "x"))
          }))')
    else
      skip "socket" "socket CLI not installed" "npm i -g @socketsecurity/cli"
    fi
  fi

  # ---- python: pip-audit ----
  if [[ -f requirements.txt || -f pyproject.toml || -f poetry.lock ]]; then
    if command -v pip-audit >/dev/null 2>&1; then
      local pip_raw
      set +e
      pip_raw=$(pip-audit --format json --progress-spinner off 2>/dev/null || echo '{"dependencies":[]}')
      set -e
      result=$(echo "$result" | jq --argjson r "$pip_raw" '
        .scanners_run += ["pip-audit"]
        | .findings += (
            ($r.dependencies // [])
            | map(. as $dep | (.vulns // []) | map({
                id: .id,
                severity:"HIGH",
                package:$dep.name,
                installed_version:$dep.version,
                fixed_versions:.fix_versions,
                ecosystem:"pypi",
                signal:.description,
                scanner:"pip-audit",
                fingerprint:("pip-audit:" + .id + ":" + $dep.name)
              }))
            | flatten
          )')
    else
      skip "pip-audit" "pip-audit not installed" "pipx install pip-audit"
    fi
  fi

  # ---- OpenSSF Scorecard: project hygiene of direct deps ----
  # Only run if we have a manifest and the binary is available. Cheap-ish but
  # network-dependent, so skip cleanly when offline.
  if command -v scorecard >/dev/null 2>&1; then
    if [[ -f package.json || -f pyproject.toml || -f go.mod ]]; then
      local sc_raw
      set +e
      # Score the current repo; for full transitive scoring use sbom-rank.sh.
      sc_raw=$(scorecard --local . --format json 2>/dev/null || echo '{}')
      set -e
      result=$(echo "$result" | jq --argjson r "$sc_raw" '
        .scanners_run += ["scorecard"]
        | .findings += (
            ($r.checks // [])
            | map(select((.score // 10) < 5))
            | map({
                id:("SCORECARD-" + .name),
                severity:(if (.score // 10) < 3 then "HIGH" else "MEDIUM" end),
                check:.name,
                score:.score,
                reason:.reason,
                ecosystem:"meta",
                scanner:"scorecard",
                fingerprint:("scorecard:" + .name)
              }))')
    fi
  else
    skip "scorecard" "OpenSSF scorecard not installed" \
         "go install github.com/ossf/scorecard/v4@latest  # or  brew install scorecard"
  fi

  # If nothing ran, warn cleanly.
  local ran_count
  ran_count=$(echo "$result" | jq '.scanners_run | length')
  if [[ "$ran_count" -eq 0 ]]; then
    result=$(echo "$result" | jq '. + {warning:"no supply-chain scanner ran — see scanners_skipped for reasons"}')
  fi

  echo "$result"
}

# ---------- gate: dast (OWASP ZAP baseline) ----------
#
# Pre-deploy tier only. Reads $ADVISOR_STAGING_URL (see
# .claude/skills/deployment-targets/SKILL.md). Skips cleanly when no URL is
# set — that's not an error, it's "this project doesn't deploy yet."

gate_dast() {
  local url="${ADVISOR_STAGING_URL:-}"
  if [[ -z "$url" ]]; then
    jq -n '{gate:"gate-dast", skipped:true, reason:"ADVISOR_STAGING_URL not set", findings:[]}'
    return
  fi

  # Reachability probe — clean skip if the URL is dead. Avoids long ZAP timeouts.
  if ! curl -fsSL --max-time 10 -o /dev/null -I "$url" 2>/dev/null; then
    jq -n --arg u "$url" '{gate:"gate-dast", skipped:true, reason:("URL unreachable: " + $u), findings:[]}'
    return
  fi

  # Choose runner: prefer local zap-baseline.py, fall back to docker.
  local mode=""
  if command -v zap-baseline.py >/dev/null 2>&1; then
    mode="local"
  elif command -v docker >/dev/null 2>&1; then
    mode="docker"
  else
    gate_error "gate-dast" "neither zap-baseline.py nor docker is installed" \
               "install OWASP ZAP or Docker; see .claude/skills/tool-provenance/SKILL.md for the pinned image"
    return
  fi

  local tmpdir report_path
  tmpdir=$(mktemp -d)
  report_path="$tmpdir/zap-report.json"

  # Build ZAP arguments. -I skips warnings as failures; the parser does
  # severity gating downstream.
  local zap_args=(-t "$url" -J "$(basename "$report_path")" -I)
  if [[ -n "${ADVISOR_STAGING_AUTH_HEADER:-}" ]]; then
    zap_args+=(-z "-config replacer.full_list(0).description=auth -config replacer.full_list(0).enabled=true -config replacer.full_list(0).matchtype=REQ_HEADER -config replacer.full_list(0).matchstr=Authorization -config replacer.full_list(0).regex=false -config replacer.full_list(0).replacement=${ADVISOR_STAGING_AUTH_HEADER}")
  fi

  local start_ts runtime
  start_ts=$(date +%s)

  set +e
  if [[ "$mode" == "local" ]]; then
    ( cd "$tmpdir" && timeout 600 zap-baseline.py "${zap_args[@]}" >/dev/null 2>&1 )
  else
    # Docker fallback. Image digest is pinned in tool-versions.json; the
    # install-verify.sh script enforces the pin separately.
    local zap_image
    zap_image=$(jq -r '.tools.zap.image // "zaproxy/zap-stable"' "$(dirname "$0")/tool-versions.json" 2>/dev/null)
    timeout 600 docker run --rm -t \
      -v "${tmpdir}:/zap/wrk/:rw" \
      "$zap_image" \
      zap-baseline.py "${zap_args[@]}" >/dev/null 2>&1
  fi
  local exit_code=$?
  set -e
  runtime=$(( $(date +%s) - start_ts ))

  if [[ ! -s "$report_path" ]]; then
    rm -rf "$tmpdir"
    if [[ "$exit_code" -eq 124 ]]; then
      jq -n --argjson runtime "$runtime" '{gate:"gate-dast", error:"ZAP scan exceeded 10-minute timeout", timeout:true, runtime_seconds:$runtime, findings:[]}'
    else
      gate_error "gate-dast" "ZAP produced no report (exit=$exit_code)" "check that staging URL is reachable from the runner"
    fi
    return
  fi

  # Pipe through the normalizer. The parser emits scanner/findings/summary;
  # we wrap with the standard gate envelope.
  local parsed
  parsed=$(python3 "$(dirname "$0")/dast-parse.py" < "$report_path" 2>/dev/null || echo '{}')
  rm -rf "$tmpdir"

  jq -n \
    --arg gate "gate-dast" \
    --arg url "$url" \
    --argjson runtime "$runtime" \
    --argjson p "$parsed" \
    '{
      gate: $gate,
      scanner: ($p.scanner // "zap-baseline"),
      scanner_version: ($p.scanner_version // "unknown"),
      target_url: $url,
      runtime_seconds: $runtime,
      findings: ($p.findings // []),
      summary: ($p.summary // {})
    }'
}

# ---------- gate: tests ----------
#
# Runs the project's test suite for the detected framework. At pre-commit scope
# we skip — tests run on PR/full only (jason §1 table). The runner emits a
# pass/fail result with counts; the gate-tests subagent does the deeper parse
# (per-failure file/line, coverage delta vs main) when invoked by the orchestrator.

gate_tests() {
  if [[ "$SCOPE" == "pre-commit" ]]; then
    jq -n '{gate:"gate-tests", skipped:true, reason:"pre-commit scope: tests deferred to PR", findings:[]}'
    return
  fi

  # Framework detection — order matters; first match wins
  local framework="" cmd=()
  if   [[ -f vitest.config.ts || -f vitest.config.js || -f vitest.config.mts ]]; then
    framework="vitest"; cmd=(npx --no-install vitest run --reporter=default)
  elif [[ -f jest.config.ts || -f jest.config.js || -f jest.config.mjs ]]; then
    framework="jest"; cmd=(npx --no-install jest --silent --passWithNoTests)
  elif [[ -f pytest.ini ]] || ( [[ -f pyproject.toml ]] && grep -q '\[tool\.pytest' pyproject.toml 2>/dev/null ) || [[ -d tests && -n "$(find tests -maxdepth 2 -name 'test_*.py' -o -name '*_test.py' 2>/dev/null | head -1)" ]]; then
    framework="pytest"; cmd=(pytest -q --tb=line --no-header)
  elif [[ -f go.mod ]]; then
    framework="go"; cmd=(go test ./...)
  elif [[ -f Cargo.toml ]]; then
    framework="cargo"; cmd=(cargo test --quiet)
  fi

  if [[ -z "$framework" ]]; then
    jq -n '{gate:"gate-tests", warning:"no test framework detected", findings:[]}'
    return
  fi

  if ! command -v "${cmd[0]}" >/dev/null 2>&1; then
    gate_error "gate-tests" "${framework} runner not installed (${cmd[0]})" \
               "install ${framework} for this project"
    return
  fi

  local raw exit_code start_ts runtime
  start_ts=$(date +%s)
  set +e
  raw=$("${cmd[@]}" 2>&1)
  exit_code=$?
  set -e
  runtime=$(( $(date +%s) - start_ts ))

  # Parse summary counts. Each framework prints something different; we
  # extract conservative numbers and let the agent do nuanced re-parse if needed.
  local passed=0 failed=0 skipped=0
  case "$framework" in
    pytest)
      passed=$(echo "$raw"  | grep -oE '[0-9]+ passed'  | tail -1 | awk '{print $1}'); passed=${passed:-0}
      failed=$(echo "$raw"  | grep -oE '[0-9]+ failed'  | tail -1 | awk '{print $1}'); failed=${failed:-0}
      skipped=$(echo "$raw" | grep -oE '[0-9]+ skipped' | tail -1 | awk '{print $1}'); skipped=${skipped:-0}
      ;;
    vitest|jest)
      passed=$(echo "$raw"  | grep -oE 'Tests:.*[0-9]+ passed'  | grep -oE '[0-9]+ passed'  | head -1 | awk '{print $1}'); passed=${passed:-0}
      failed=$(echo "$raw"  | grep -oE 'Tests:.*[0-9]+ failed'  | grep -oE '[0-9]+ failed'  | head -1 | awk '{print $1}'); failed=${failed:-0}
      skipped=$(echo "$raw" | grep -oE 'Tests:.*[0-9]+ skipped' | grep -oE '[0-9]+ skipped' | head -1 | awk '{print $1}'); skipped=${skipped:-0}
      ;;
    go)
      failed=$(echo "$raw" | grep -cE '^--- FAIL' || true); failed=${failed:-0}
      passed=$(echo "$raw" | grep -cE '^--- PASS' || true); passed=${passed:-0}
      ;;
    cargo)
      passed=$(echo "$raw"  | grep -oE '[0-9]+ passed'   | tail -1 | awk '{print $1}'); passed=${passed:-0}
      failed=$(echo "$raw"  | grep -oE '[0-9]+ failed'   | tail -1 | awk '{print $1}'); failed=${failed:-0}
      skipped=$(echo "$raw" | grep -oE '[0-9]+ ignored'  | tail -1 | awk '{print $1}'); skipped=${skipped:-0}
      ;;
  esac

  # Build findings: one entry per failed test bucket. Detail-level parsing
  # (per-test file/line) is the subagent's job; the runner just signals fail.
  local status="pass"
  if [[ "$exit_code" -ne 0 || "$failed" -gt 0 ]]; then status="fail"; fi

  local findings='[]'
  if [[ "$status" == "fail" ]]; then
    # Cap raw output at 4KB so the JSON stays manageable
    local snippet
    snippet=$(echo "$raw" | tail -c 4096)
    findings=$(jq -n \
      --arg fw "$framework" \
      --arg msg "$snippet" \
      --argjson n "$failed" \
      '[{
        id: ("TEST-FAIL-" + $fw),
        severity: "HIGH",
        message: ("test suite failed (" + ($n|tostring) + " failures)"),
        framework: $fw,
        output_tail: $msg,
        fingerprint: ("test-fail:" + $fw)
      }]')
  fi

  jq -n \
    --arg fw "$framework" \
    --arg status "$status" \
    --argjson exit "$exit_code" \
    --argjson runtime "$runtime" \
    --argjson passed "$passed" \
    --argjson failed "$failed" \
    --argjson skipped "$skipped" \
    --argjson findings "$findings" \
    '{
      gate:"gate-tests",
      framework:$fw,
      status:$status,
      exit_code:$exit,
      runtime_seconds:$runtime,
      passed:$passed,
      failed:$failed,
      skipped:$skipped,
      coverage_unavailable:true,
      note:"runner emits pass/fail + counts only; gate-tests subagent does coverage and per-failure parse",
      findings:$findings
    }'
}

# ---------- main ----------

require_jq

# Per-tier gate selection. Mirrors v2 §1 table.
# pre-commit: fastest, staged-only checks.
# pr        : fast PR set; diff-scoped where the gate supports it.
# merge     : full SAST/dep/IaC/supply/test + license sweep (license sweep TBD).
# pre-deploy: post-merge attestation and container scans (DAST handled by separate workflow).
PRE_COMMIT_GATES=("gate_secrets")
PR_GATES=("gate_sast" "gate_deps" "gate_iac" "gate_secrets" "gate_supply_chain" "gate_tests")
MERGE_GATES=("gate_sast" "gate_deps" "gate_iac" "gate_secrets" "gate_supply_chain" "gate_tests")
PRE_DEPLOY_GATES=("gate_deps" "gate_iac" "gate_supply_chain" "gate_dast")

case "$TIER" in
  pre-commit) GATES=("${PRE_COMMIT_GATES[@]}") ;;
  pr)         GATES=("${PR_GATES[@]}") ;;
  merge)      GATES=("${MERGE_GATES[@]}") ;;
  pre-deploy) GATES=("${PRE_DEPLOY_GATES[@]}") ;;
esac

results="[]"
for g in "${GATES[@]}"; do
  result=$("$g")
  results=$(echo "$results" | jq --argjson r "$result" '. += [$r]')
done

# Build gates_in_tier list (without the gate_ prefix, dashed) for stamp predicate.
gates_in_tier=$(printf '%s\n' "${GATES[@]}" | sed 's/^gate_/gate-/; s/_/-/g' | jq -R . | jq -s .)

jq -n \
  --arg run_id "$(uuidgen 2>/dev/null || cat /proc/sys/kernel/random/uuid 2>/dev/null || echo 'no-uuid')" \
  --arg started_at "$(now_iso)" \
  --arg tier "$TIER" \
  --arg git_sha "$(git_sha)" \
  --arg git_branch "$(git_branch)" \
  --argjson results "$results" \
  --argjson gates_in_tier "$gates_in_tier" \
  '{
    advisor_run_id:$run_id,
    started_at:$started_at,
    tier:$tier,
    scope:$tier,
    gates_in_tier:$gates_in_tier,
    git_sha:$git_sha,
    git_branch:$git_branch,
    gate_results:$results
  }'
