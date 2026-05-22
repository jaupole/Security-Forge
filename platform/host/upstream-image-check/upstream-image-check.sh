#!/usr/bin/env bash
# Weekly upstream image digest check.
#
# For each image in /etc/upstream-image-check/watched-images.txt, query
# the registry for the current manifest digest and compare to the
# last-known digest stored in /var/lib/upstream-image-check/state.
#
# When a digest changes (= upstream published a new build), log a syslog
# line that the host wazuh-agent forwards to the manager. That's the
# signal to bump the image, re-run Trivy, and update the trivy-baseline.md.
#
# Runs as the `upstream-image-check.timer` systemd unit (weekly, Mon 04:00).

set -euo pipefail

WATCHED=/etc/upstream-image-check/watched-images.txt
STATE_DIR=/var/lib/upstream-image-check
STATE_FILE="$STATE_DIR/state"
LOG_TAG=upstream-image-check

mkdir -p "$STATE_DIR"
touch "$STATE_FILE"
chmod 0644 "$STATE_FILE"

if [ ! -r "$WATCHED" ]; then
  logger -t "$LOG_TAG" -p daemon.warning "watched-images config missing: $WATCHED"
  exit 0
fi

# Get a registry pull token. Anonymous works for the public images we track.
get_token() {
  local registry="$1" repo="$2"
  case "$registry" in
    ghcr.io)
      curl -sf "https://ghcr.io/token?scope=repository:${repo}:pull" \
        | python3 -c 'import json,sys; print(json.load(sys.stdin).get("token",""))'
      ;;
    registry.k8s.io)
      # registry.k8s.io is anonymous; no token needed but the API is the same shape
      echo ""
      ;;
    *)
      echo ""
      ;;
  esac
}

# Resolve the current manifest digest for an image:tag from the registry.
get_remote_digest() {
  local image_with_tag="$1"
  local image="${image_with_tag%:*}"
  local tag="${image_with_tag##*:}"
  local registry="${image%%/*}"
  local repo="${image#*/}"
  local token
  token=$(get_token "$registry" "$repo")

  local auth=()
  [ -n "$token" ] && auth=(-H "Authorization: Bearer $token")

  # -L follows redirects (registry.k8s.io 307s to europe-north1-docker.pkg.dev).
  # We grep the LAST docker-content-digest header (final hop's digest) since
  # `curl -I -L` emits headers from each hop.
  curl -sIL \
       -H 'Accept: application/vnd.oci.image.index.v1+json' \
       -H 'Accept: application/vnd.docker.distribution.manifest.list.v2+json' \
       -H 'Accept: application/vnd.docker.distribution.manifest.v2+json' \
       "${auth[@]}" \
       "https://${registry}/v2/${repo}/manifests/${tag}" 2>/dev/null \
    | tr -d '\r' \
    | grep -i '^docker-content-digest:' \
    | tail -1 \
    | sed -E 's/^[Dd]ocker-[Cc]ontent-[Dd]igest:[[:space:]]+//' \
    || true
}

new_digests_seen=0

# State file format: <image_with_tag> <digest> <iso8601_seen>
# We rewrite the file each run with current state.
TMP=$(mktemp)
trap 'rm -f "$TMP"' EXIT

while IFS= read -r line; do
  # strip comments and trim
  img="${line%%#*}"
  img="${img#"${img%%[![:space:]]*}"}"
  img="${img%"${img##*[![:space:]]}"}"
  [ -z "$img" ] && continue

  remote=$(get_remote_digest "$img")
  if [ -z "$remote" ]; then
    logger -t "$LOG_TAG" -p daemon.warning "could not resolve digest for $img"
    continue
  fi

  prior=$(awk -v i="$img" '$1==i {print $2; exit}' "$STATE_FILE")
  now=$(date -u +%Y-%m-%dT%H:%M:%SZ)

  if [ -z "$prior" ]; then
    # First time seeing this image — record without alerting.
    logger -t "$LOG_TAG" -p daemon.info "first observation: $img -> $remote"
  elif [ "$prior" != "$remote" ]; then
    # Digest changed — upstream published a new build.
    logger -t "$LOG_TAG" -p daemon.warning \
      "NEW DIGEST AVAILABLE for $img (was $prior, now $remote)"
    new_digests_seen=$((new_digests_seen + 1))
  fi

  printf '%s %s %s\n' "$img" "$remote" "$now" >> "$TMP"
done < "$WATCHED"

mv "$TMP" "$STATE_FILE"
chmod 0644 "$STATE_FILE"

logger -t "$LOG_TAG" -p daemon.info \
  "weekly check complete: $new_digests_seen images have new upstream digests"
