#!/usr/bin/env bash
# 02 BOOTSTRAP — Generate the SPIRE upstream CA and load it as a K8s Secret.
#
# *** RUN THIS ONCE, BEFORE 02-spire.sh. IT IS IRREVERSIBLE. ***
#
# What this does:
#   1. Generates an ECDSA P-256 self-signed CA (10 year validity)
#      Subject: CN="SecForge Production SPIRE Upstream Root CA", O=SecForge, C=US
#      The CA's CN is decorative; what matters is that it signs the SPIRE-server
#      intermediate.
#   2. Prints the cert + key to the terminal ONCE so the operator can capture
#      them for offline backup (1Password, encrypted USB, paper, etc.).
#   3. Waits for explicit confirmation that the operator has captured them.
#   4. Loads the cert+key into the `spire-upstream-ca` Secret in the `spire`
#      namespace. SPIRE's disk upstream-authority plugin reads from there.
#   5. Shreds the on-disk copies.
#
# *** If you lose this private key, every SVID issued by SPIRE becomes ***
# *** unverifiable. There is no recovery. Back it up before continuing. ***

set -euo pipefail

if kubectl get secret spire-upstream-ca -n spire >/dev/null 2>&1; then
  echo "✓ spire-upstream-ca Secret already exists in 'spire' namespace."
  echo "  Skipping CA generation. If you need to rotate the CA, delete the"
  echo "  Secret first AND plan for fleet-wide SVID re-issuance."
  exit 0
fi

echo "==========================================================="
echo " SPIRE upstream CA bootstrap — IRREVERSIBLE"
echo "==========================================================="
echo
echo "About to generate a new ECDSA P-256 self-signed CA"
echo "(10 year validity) for this SPIRE installation."
echo
echo "If you lose the private key after this step, EVERY SVID"
echo "issued by SPIRE will become unverifiable. There is NO"
echo "recovery. Back it up offline IMMEDIATELY."
echo
read -rp "Type 'I UNDERSTAND' to proceed: " ack
if [[ "$ack" != "I UNDERSTAND" ]]; then
  echo "Aborted."
  exit 1
fi

# Ensure spire namespace exists
kubectl create namespace spire 2>/dev/null || true

# Generate CA into a tmpfs-backed dir to minimize disk forensics surface
TMPDIR="$(mktemp -d -p /dev/shm 2>/dev/null || mktemp -d)"
trap 'shred -u "$TMPDIR"/* 2>/dev/null || rm -f "$TMPDIR"/*; rmdir "$TMPDIR" 2>/dev/null || true' EXIT

CA_KEY="$TMPDIR/spire-ca.key"
CA_CRT="$TMPDIR/spire-ca.crt"

openssl ecparam -name prime256v1 -genkey -noout -out "$CA_KEY"
openssl req -new -x509 -days 3650 \
  -key "$CA_KEY" \
  -out "$CA_CRT" \
  -subj "/C=US/O=SecForge/CN=SecForge Production SPIRE Upstream Root CA"

# Display the material once for offline backup
cat <<'BANNER'

==========================================================
 OFFLINE BACKUP — copy both blocks below into 1Password
 (or your secure store) BEFORE pressing Enter to continue.
 The K8s Secret will be the ONLY copy after this step.
==========================================================

>>> spire-upstream-ca.crt (public — also fine to commit) >>>
BANNER

cat "$CA_CRT"

cat <<'BANNER'

>>> spire-upstream-ca.key (PRIVATE — guard this with your life) >>>
BANNER

cat "$CA_KEY"

cat <<'BANNER'

==========================================================
BANNER

read -rp "Have you stored BOTH blocks in offline storage? Type 'YES' to continue: " backed_up
if [[ "$backed_up" != "YES" ]]; then
  echo "Aborted before loading Secret. The temp files have been shredded."
  exit 1
fi

# Load into K8s Secret
kubectl create secret generic spire-upstream-ca \
  --namespace spire \
  --from-file=tls.crt="$CA_CRT" \
  --from-file=tls.key="$CA_KEY"

# tmpfile cleanup happens via trap
echo
echo "✓ spire-upstream-ca Secret loaded in 'spire' namespace."
echo "✓ On-disk copies shredded."
echo
echo "Next: bash ~/secforge/platform/components/02-spire.sh"
