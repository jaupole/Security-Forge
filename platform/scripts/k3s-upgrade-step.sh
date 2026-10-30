#!/usr/bin/env bash
# One k3s minor-version step on the single secforge-prod node (manual binary
# upgrade, docs.k3s.io/upgrades/manual). NEVER skip minors; NEVER run two steps
# in one day — the 2026-10-30 1.31→1.32→1.33 run (restarts 6 min apart) set off
# the spiffe CSI mount storm (see csi-mount-unwind.sh) and compute-starved the
# node for an hour. Pre-gates refuse to start unless the node is quiet.
#
# Usage: sudo VER=v1.34.12+k3s1 platform/scripts/k3s-upgrade-step.sh
#   - backs up the SQLite datastore (MinIO via k3s-datastore-backup.sh + local
#     copy under /var/backups/k3s-upgrade/ with the token and old binary)
#   - downloads + sha256-verifies the release binary, swaps it atomically,
#     restarts k3s (unit file untouched — the installer is NOT used)
#   - waits for Ready, settles, prints gates. Rollback = copy the saved binary
#     back and restart (same minor only; never downgrade across a minor).
set -euo pipefail
: "${VER:?set VER=v1.xx.y+k3s1}"
export PATH=/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
K=/usr/local/bin/kubectl
echo "=== STEP to $VER  (from $(k3s --version | head -1 | awk '{print $3}'))"
echo "--- pre-gates (node must be quiet)"
m=$(wc -l < /proc/mounts); (( m < 5000 )) || { echo "ABORT: $m mounts — run csi-mount-unwind.sh and wait"; exit 1; }
l=$(cut -d. -f1 /proc/loadavg); (( l < 8 )) || { echo "ABORT: load $l"; exit 1; }
csi=$($K -n spire get pod -l app.kubernetes.io/name=spiffe-csi-driver -o jsonpath='{.items[0].status.containerStatuses[?(@.name=="spiffe-csi-driver")].lastState.terminated.finishedAt}')
if [[ -n "$csi" ]]; then age=$(( $(date +%s) - $(date -d "$csi" +%s) )); (( age > 21600 )) || { echo "ABORT: spiffe-csi-driver restarted ${age}s ago (<6h)"; exit 1; }; fi
bad=$($K get pods -A --no-headers | grep -vcE "Running|Completed"); (( bad <= 3 )) || { echo "ABORT: $bad non-running pods"; exit 1; }
echo "pre-gates ok: mounts=$m load=$l non-running=$bad"
echo "--- pre: datastore backups"
bash /home/ops/secforge/platform/scripts/k3s-datastore-backup.sh 2>&1 | tail -1
mkdir -p /var/backups/k3s-upgrade && sqlite3 /var/lib/rancher/k3s/server/db/state.db ".backup /var/backups/k3s-upgrade/state-pre-${VER}.db" && cp -p /var/lib/rancher/k3s/server/token /var/backups/k3s-upgrade/token-pre-${VER} && cp -p /usr/local/bin/k3s /var/backups/k3s-upgrade/k3s-bin-pre-${VER} && ls -la /var/backups/k3s-upgrade/ | awk '{print $5, $9}' | tail -3
echo "--- fetch + verify binary"
ENC=$(printf '%s' "$VER" | sed 's/+/%2B/')
cd /usr/local/bin && rm -f k3s.new /var/backups/k3s-upgrade/sha256sum-amd64.txt
curl -sSfL -o k3s.new "https://github.com/k3s-io/k3s/releases/download/${ENC}/k3s"
curl -sSfL -o /var/backups/k3s-upgrade/sha256sum-amd64.txt "https://github.com/k3s-io/k3s/releases/download/${ENC}/sha256sum-amd64.txt"
EXP=$(awk '$2=="k3s"{print $1}' /var/backups/k3s-upgrade/sha256sum-amd64.txt); GOT=$(sha256sum k3s.new | awk '{print $1}')
[ -n "$EXP" ] && [ "$EXP" = "$GOT" ] || { echo "CHECKSUM MISMATCH exp=$EXP got=$GOT"; exit 1; }
echo "sha256 ok $GOT"
chmod 0755 k3s.new && chown root:root k3s.new && ./k3s.new --version | head -1
echo "--- swap + restart $(date -u +%H:%M:%S)"
mv -f /usr/local/bin/k3s.new /usr/local/bin/k3s
systemctl restart k3s
for i in $(seq 1 60); do sleep 3; v=$($K get node secforge-prod --no-headers 2>/dev/null | awk '{print $2" "$5}') && case "$v" in "Ready $VER") echo "node Ready on $VER after $((i*3))s"; break;; esac; [ $i -eq 60 ] && { echo "TIMEOUT node not Ready: '$v'"; exit 1; }; done
echo "--- settle"
sleep 45
for i in $(seq 1 16); do
  bad=$($K get pods -A --no-headers 2>/dev/null | grep -vE "Running|Completed" | wc -l)
  notready=$($K get pods -A --no-headers 2>/dev/null | awk '$4=="Running"{split($3,a,"/"); if(a[1]!=a[2]) print}' | wc -l)
  [ "$bad" -le 2 ] && [ "$notready" -eq 0 ] && break
  sleep 15
done
echo "mounts=$(wc -l < /proc/mounts) load=$(cut -d' ' -f1-3 /proc/loadavg)"
echo "pods: $($K get pods -A --no-headers | awk '{print $4}' | sort | uniq -c | tr '\n' ';')  containers_not_ready=$notready"
$K get pods -A --no-headers | grep -vE "Running|Completed" | awk '{print "  non-running:", $1"/"$2, $4}' | head -5
echo "--- gates"
echo "kube-system: $($K -n kube-system get deploy -o jsonpath='{range .items[*]}{.metadata.name}={.status.readyReplicas}/{.spec.replicas} {end}')"
echo "istio: $($K -n istio-system get deploy,ds -o jsonpath='{range .items[*]}{.metadata.name}={.status.readyReplicas}{.status.numberReady}/{.spec.replicas}{.status.desiredNumberScheduled} {end}')"
echo "kyverno: $($K -n kyverno get deploy -o jsonpath='{range .items[*]}{.metadata.name}={.status.readyReplicas}/{.spec.replicas} {end}')"
echo "cnpg: $($K get clusters.postgresql.cnpg.io -A -o jsonpath='{range .items[*]}{.metadata.name}={.status.phase}; {end}')"
echo -n "kyverno-webhook-dryrun: "; $K -n default run upgrade-probe --image=docker.io/library/busybox:latest --dry-run=server -o name 2>&1 | head -1 | cut -c1-100 || true
echo "https: portal=$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 https://portal.secforge.dev/) auth=$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 https://auth.secforge.dev/) members=$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 https://members.secforge.dev/)"
echo "api-deprecations: $($K get --raw /metrics 2>/dev/null | grep -c '^apiserver_requested_deprecated_apis' )"
echo "=== DONE $VER $(date -u +%H:%M:%S)"
