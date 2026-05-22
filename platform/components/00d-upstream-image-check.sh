#!/usr/bin/env bash
# 00d — Install the weekly upstream-image-check systemd timer.
#
# Watches container images (listed in watched-images.txt) for upstream
# digest changes. When a tracked image gets a newer digest, the script
# logs a warning via syslog ("NEW DIGEST AVAILABLE for <image>") that
# the host wazuh-agent picks up and forwards to the manager.
#
# This is the companion to docs/06-reference/trivy-baseline.md — when
# Trivy finds CRITICAL CVEs in our running images and we're already on
# the latest published tag, we add the image here. The weekly check
# tells us when upstream has published a new build, prompting a bump.

set -euo pipefail

if [ "$EUID" -ne 0 ]; then
  echo "ERROR: must run as root" >&2
  exit 1
fi

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &> /dev/null && pwd)"
PLATFORM_DIR="$(dirname "$SCRIPT_DIR")"
SRC="$PLATFORM_DIR/host/upstream-image-check"

green()  { printf '\033[32m%s\033[0m\n' "$*"; }
yellow() { printf '\033[33m%s\033[0m\n' "$*"; }

# 1. Install script
green "==> install /usr/local/sbin/upstream-image-check.sh"
install -m 0755 -o root -g root \
    "$SRC/upstream-image-check.sh" \
    /usr/local/sbin/upstream-image-check.sh

# 2. Install watched-images.txt config
green "==> install /etc/upstream-image-check/watched-images.txt"
mkdir -p /etc/upstream-image-check
install -m 0644 -o root -g root \
    "$SRC/watched-images.txt" \
    /etc/upstream-image-check/watched-images.txt

# 3. State directory
mkdir -p /var/lib/upstream-image-check
chown root:root /var/lib/upstream-image-check
chmod 0755 /var/lib/upstream-image-check

# 4. Install systemd unit + timer
green "==> install systemd units"
for unit in upstream-image-check.service upstream-image-check.timer; do
  install -m 0644 -o root -g root \
      "$SRC/$unit" \
      "/etc/systemd/system/$unit"
done

systemctl daemon-reload
systemctl enable --now upstream-image-check.timer

# 5. Run once now to seed the state file (no alerts on first run).
green "==> run initial check to seed state file"
systemctl start upstream-image-check.service
sleep 2
yellow "    initial state:"
cat /var/lib/upstream-image-check/state | sed 's/^/      /'

cat <<EOF

✓ Weekly upstream-image-check installed.

Schedule: Monday 04:00 (with 30min jitter).
Watched images: $(grep -v '^#' /etc/upstream-image-check/watched-images.txt | grep -v '^\s*$' | wc -l)
State file:    /var/lib/upstream-image-check/state

When upstream publishes a new digest for a watched image, syslog will get:
  upstream-image-check: NEW DIGEST AVAILABLE for <image> (was X, now Y)

Wazuh forwards this; review against docs/06-reference/trivy-baseline.md
and bump the cluster image if appropriate.

Verify:
  systemctl list-timers upstream-image-check.timer
  journalctl -u upstream-image-check.service --since today
EOF
