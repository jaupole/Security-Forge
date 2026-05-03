#!/usr/bin/env bash
# Unseal openbao-seal after a Docker Desktop restart.
#
# Usage:
#   bash infrastructure/openbao/unseal-seal.sh
#
# Reads 3 unseal keys from stdin (one per line, blank line to finish).
# Each key is wiped from the script's memory immediately after use.
#
# This is the routine, post-restart operation. Init is in init-seal.sh
# and runs only once.

set -euo pipefail
NS=openbao
POD=openbao-seal-0

green()  { printf '\033[32m%s\033[0m\n' "$*"; }
yellow() { printf '\033[33m%s\033[0m\n' "$*"; }
red()    { printf '\033[31m%s\033[0m\n' "$*" >&2; }

# 0. Sanity — pod exists, sealed.
if ! kubectl get pod -n "$NS" "$POD" >/dev/null 2>&1; then
    red "$POD not found in $NS namespace. Is the seal-OpenBao deployed?"
    exit 1
fi

status=$(kubectl exec -n "$NS" "$POD" -c openbao -- \
    env BAO_SKIP_VERIFY=1 bao status -format=json 2>&1 || true)
if echo "$status" | grep -q '"sealed": false'; then
    green "openbao-seal is already unsealed. Nothing to do."
    exit 0
fi
if ! echo "$status" | grep -q '"initialized": true'; then
    red "openbao-seal is not initialized. Run init-seal.sh first."
    exit 1
fi

# 1. Read 3 keys from stdin.
yellow ""
yellow "Paste 3 unseal keys, one per line. Press Enter on a blank line to finish."
yellow "(Keys are NOT echoed back. They go straight to bao via stdin.)"
yellow ""

count=0
while [ "$count" -lt 3 ]; do
    if ! IFS= read -r -s key; then
        red "stdin closed before 3 keys read."
        exit 1
    fi
    if [ -z "$key" ]; then
        red "Got blank line at key $((count+1))/3. Aborting."
        exit 1
    fi
    kubectl exec -n "$NS" "$POD" -c openbao -- \
        env BAO_SKIP_VERIFY=1 bao operator unseal "$key" >/dev/null
    unset key
    count=$((count+1))
    green "  ✓ key $count of 3 accepted"
done

# 2. Verify.
status=$(kubectl exec -n "$NS" "$POD" -c openbao -- \
    env BAO_SKIP_VERIFY=1 bao status -format=json 2>&1)
if echo "$status" | grep -q '"sealed": false'; then
    green ""
    green "openbao-seal is unsealed. Main OpenBao should auto-unseal within ~10s."
else
    red "Unseal didn't take. status:"
    red "$status"
    exit 1
fi

# 3. Post-unseal cleanup — main OpenBao pods stuck in kubelet backoff.
#
# During the operator's manual-unseal window, main pods (openbao-0/1/2) try
# to reach the seal-pod's Transit endpoint, get back 503 "Vault is sealed",
# exit with code 1. Kubelet restarts them with exponential backoff. By the
# time the operator finishes the 3-key entry, the main pods can be sitting
# on backoff timers of 30s+ — they don't recover quickly even though the
# seal-pod is now healthy. Force-delete them so kubelet recreates immediately.
#
# Until the proper structural fix lands (initContainer on the main OpenBao
# StatefulSet that blocks startup until openbao-seal-0 reports Sealed: false
# — see PLAN.md operator-backlog or post-investigation issue), this is the
# friction-relief workaround.

green ""
green "Waiting 15s for main OpenBao to attempt auto-unseal..."
sleep 15

crashlooping_main=$(kubectl get pods -n "$NS" --no-headers 2>/dev/null \
    | awk '($3 == "CrashLoopBackOff" || $3 == "Error") && $1 ~ /^openbao-[0-9]+$/ { print $1 }' || true)

if [ -n "$crashlooping_main" ]; then
    yellow ""
    yellow "Main OpenBao pods stuck in kubelet backoff (seal-pod was unavailable on their last start):"
    while IFS= read -r pod; do
        yellow "  - $pod"
    done <<< "$crashlooping_main"
    yellow ""
    while IFS= read -r pod; do
        kubectl delete pod -n "$NS" "$pod" >/dev/null
        green "  ✓ deleted $pod (will restart against now-unsealed seal-pod)"
    done <<< "$crashlooping_main"

    yellow ""
    yellow "Waiting up to 90s for main OpenBao pods to reach Ready..."
    sleep 5  # let kubelet recreate the pods so the wait selector matches
    if kubectl wait --for=condition=Ready pod -n "$NS" \
            -l app.kubernetes.io/instance=openbao \
            --timeout=90s >/dev/null 2>&1; then
        green "  ✓ all main OpenBao pods Ready"
    else
        red ""
        red "Main OpenBao pods didn't reach Ready in 90s. Inspect: kubectl get pods -n $NS"
        red "May indicate a deeper issue (Raft state, NetworkPolicy, etc.). Stopping here so"
        red "the app-namespace cleanup below doesn't restart apps against a broken OpenBao."
        exit 1
    fi
fi

# 4. Replay any *-refresher CronJob whose most recent firing didn't succeed.
#
# Refresher cronjobs (e.g. spicedb-datastore-refresher, every 12h) renew
# dynamic OpenBao-issued credentials whose own lease is much shorter — the
# spicedb Postgres role's lease is 1h. If a firing lands inside a seal window
# it fails (OpenBao unreachable), the credential expires, and the consuming
# workload crashloops on the next auth attempt. The 12h schedule's safety
# margin is fully consumed by a single missed firing.
#
# Detect via the CronJob's own .status.lastScheduleTime vs lastSuccessfulTime
# (rather than scanning Failed Jobs, which stick around per failedJobsHistoryLimit
# and would cause re-runs of this script to replay the same job repeatedly).
# Manual `kubectl create job --from=cronjob/...` replays update the cronjob's
# lastSuccessfulTime, so this check is idempotent across script re-runs.
#
# Track which namespaces we touched so step 5 can bounce their crashlooping
# consumers immediately rather than waiting out CrashLoopBackOff backoff
# (capped at 5min).

yellow ""
yellow "Checking for *-refresher CronJob firings missed during the seal window..."

stale_crons=$(kubectl get cronjob -A -o jsonpath='{range .items[*]}{.metadata.namespace}{" "}{.metadata.name}{" "}{.status.lastScheduleTime}{" "}{.status.lastSuccessfulTime}{"\n"}{end}' 2>/dev/null \
    | awk '$2 ~ /refresher/ { sched=$3; ok=$4; if (sched != "" && (ok == "" || sched > ok)) print $1 " " $2 }' || true)

replayed_namespaces=""

if [ -z "$stale_crons" ]; then
    green "  ✓ No stale refresher cronjobs."
else
    while IFS= read -r line; do
        ns=$(echo "$line" | awk '{print $1}')
        cron=$(echo "$line" | awk '{print $2}')
        retry_name="${cron}-retry-$(date +%s)"
        yellow "  - replaying $ns/$cron as $retry_name"
        if ! kubectl create job -n "$ns" "$retry_name" --from="cronjob/$cron" >/dev/null 2>&1; then
            red "    ✗ could not create retry job"
            continue
        fi
        if kubectl wait --for=condition=Complete -n "$ns" "job/$retry_name" --timeout=120s >/dev/null 2>&1; then
            green "    ✓ $ns/$cron retry succeeded"
            case " $replayed_namespaces " in
                *" $ns "*) ;;
                *) replayed_namespaces="$replayed_namespaces $ns" ;;
            esac
        else
            red "    ✗ $ns/$cron retry did not complete in 120s — inspect: kubectl logs -n $ns job/$retry_name"
        fi
        sleep 1  # ensure unique $(date +%s) suffixes if multiple retries fall in the same second
    done <<< "$stale_crons"
fi

# 5. Post-unseal cleanup — pods that crashlooped during the seal window.
#
# Two distinct failure modes converge here:
#   a) Apps that auth to OpenBao via SPIFFE-JWT-SVID (helloworld-bff,
#      authzen-facade, …) start bootstrapping before the operator has
#      unsealed. They accumulate failed login attempts with SVIDs that
#      expire (5min default TTL) before unseal completes, ending up stuck
#      in CrashLoopBackOff with stale SVIDs even after OpenBao is healthy.
#      Affects the 'app' namespace.
#   b) Consumers of refresher-managed dynamic credentials (e.g. SpiceDB on
#      its expired Postgres role) crashloop until the refresher reruns AND
#      they retry. Step 4 reran the refreshers; here we shorten the wait
#      by bouncing the consumers in those same namespaces.
#
# Scope: 'app' (always, for case a) + any namespace where step 4 replayed
# a refresher (for case b). Both are tightly bounded to namespaces that
# definitely had OpenBao-related disruption.

cleanup_namespaces="app"
for ns in $replayed_namespaces; do
    case " $cleanup_namespaces " in
        *" $ns "*) ;;
        *) cleanup_namespaces="$cleanup_namespaces $ns" ;;
    esac
done

for ns in $cleanup_namespaces; do
    crashlooping=$(kubectl get pods -n "$ns" --no-headers 2>/dev/null \
        | awk '$3 == "CrashLoopBackOff" { print $1 }' || true)

    if [ -z "$crashlooping" ]; then
        continue
    fi

    yellow ""
    yellow "Found CrashLooping pods in '$ns' namespace:"
    while IFS= read -r pod; do
        yellow "  - $pod"
    done <<< "$crashlooping"
    yellow ""
    while IFS= read -r pod; do
        kubectl delete pod -n "$ns" "$pod" >/dev/null
        green "  ✓ deleted $pod (will restart with fresh SVID/secret)"
    done <<< "$crashlooping"
done

green ""
green "Cluster should be fully healthy in ~30s."
green "Verify: kubectl get pods --all-namespaces | grep -v 'Running\\|Completed'"
