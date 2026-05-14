#!/usr/bin/env bash
# Set a GRUB superuser password on the bare-metal host.
#
# Why: without this, anyone with console access (Hetzner KVM, physical,
# Hetzner support engineer with the right role) can boot into single-user
# mode and reset root. GRUB password protects the menu editor + GRUB CLI +
# alternate boot entries WITHOUT prompting on normal boot.
#
# Mechanism:
#   - /etc/grub.d/01_secforge_password defines superuser "jaupole" with
#     a pbkdf2-sha512 hashed password
#   - /etc/grub.d/10_linux is patched to add --unrestricted to the menu
#     entry CLASS so the default Ubuntu boot still works without prompt
#   - update-grub regenerates /boot/grub/grub.cfg
#
# Idempotent — re-running will rotate the password.
#
# Applied 2026-05-14. Password stored in operator's 1Password vault under
# "secforge — Hetzner GRUB superuser (jaupole)".

set -euo pipefail

if [[ $EUID -ne 0 ]]; then
    echo "ERROR: must run as root" >&2
    exit 1
fi

green() { printf '\033[32m%s\033[0m\n' "$*"; }

if [[ -z "${SECFORGE_GRUB_PASSWORD:-}" ]]; then
    green "==> generating new GRUB password (24 base64 chars)"
    PW=$(openssl rand -base64 24)
    cat <<EOF >&2

╔════════════════════════════════════════════════════════════════════╗
║                                                                    ║
║   GRUB PASSWORD GENERATED — SAVE THIS NOW                          ║
║                                                                    ║
║   User:      jaupole                                               ║
║   Password:  $PW
║                                                                    ║
║   This will not be shown again. Store in 1Password under:          ║
║     "secforge — Hetzner GRUB superuser (jaupole)"                  ║
║                                                                    ║
╚════════════════════════════════════════════════════════════════════╝

EOF
    read -rp "Press ENTER after saving the password to 1Password..." _
else
    PW="$SECFORGE_GRUB_PASSWORD"
    green "==> using SECFORGE_GRUB_PASSWORD from environment"
fi

green "==> generating PBKDF2 hash"
HASH=$(printf '%s\n%s\n' "$PW" "$PW" | grub-mkpasswd-pbkdf2 2>/dev/null \
       | awk '/grub.pbkdf2/{print $NF}')
unset PW
[[ "$HASH" == grub.pbkdf2* ]] || { echo "ERROR: hash generation failed" >&2; exit 1; }

green "==> writing /etc/grub.d/01_secforge_password"
cat > /etc/grub.d/01_secforge_password <<EOF
#!/bin/sh
exec tail -n +3 \$0
# GRUB superuser auth. Superuser "jaupole" required for editing menu
# entries or accessing GRUB CLI. Boot entries themselves carry
# --unrestricted (see 10_linux patch) so normal boot is unaffected.
set superusers="jaupole"
password_pbkdf2 jaupole $HASH
EOF
chmod 0700 /etc/grub.d/01_secforge_password

green "==> patching /etc/grub.d/10_linux to add --unrestricted to menuentry CLASS"
if ! grep -qE '^CLASS=.*--unrestricted' /etc/grub.d/10_linux; then
    sed -i 's/^CLASS="--class gnu-linux --class gnu --class os"/CLASS="--class gnu-linux --class gnu --class os --unrestricted"/' /etc/grub.d/10_linux
fi
grep -E '^CLASS=' /etc/grub.d/10_linux | head -1

green "==> regenerating /boot/grub/grub.cfg"
update-grub 2>&1 | grep -vE "^Generating|^Found|^done$|^Sourcing"

green "==> verify"
grep -E "^set superusers|^password_pbkdf2|--unrestricted" /boot/grub/grub.cfg | head -3

cat <<EOF

✓ GRUB password installed.

  Normal boot: no prompt (Ubuntu menu entry has --unrestricted).
  Edit menu entry / GRUB CLI / single-user mode: prompts for "jaupole" + password.
EOF
