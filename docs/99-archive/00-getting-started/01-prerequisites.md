> 🗄️ **ARCHIVED 2026-06-07 — local-first / build-era document.**
> This describes the original Docker Desktop / WSL2 / `secforge.local` build, **not** the current
> bare-metal `secforge-prod` deployment. Kept for history only. For current state see `PLAN.md`,
> `docs/01-architecture/`, and `docs/06-reference/operator-backlog.md` (archive index: `docs/99-archive/README.md`).

# Prerequisites — What to Install Before You Start

This is a one-time setup. Allow about half a day for the whole getting-started sequence (this doc plus Docker Desktop and DNS/TLS).

If a step doesn't work, paste the error into Claude Code and ask. That's the whole point — Claude Code will help you debug.

---

## 1. Verify Windows 11 + WSL2

You should have WSL2 with Ubuntu 24.04. Quick check:

In **PowerShell (Admin)**:
```powershell
wsl --list --verbose
```

You should see:
```
NAME            STATE           VERSION
* Ubuntu-24.04  Running         2
```

If not, install:
```powershell
wsl --install -d Ubuntu-24.04
```

Reboot if prompted, finish the Ubuntu setup (pick a Linux username and password, write the password down).

### Configure WSL2 resource limits

Create or edit `C:\Users\<your-windows-user>\.wslconfig`:
```ini
[wsl2]
memory=20GB
processors=6
swap=4GB
localhostForwarding=true
```

This reserves enough memory for WSL (and Docker Desktop, which uses WSL's VM) to run the platform plus your dev work. With 32 GB total, leaving 12 GB for Windows + browser + other apps is reasonable.

After editing:
```powershell
wsl --shutdown
```

Then reopen Ubuntu.

---

## 2. Install Docker Desktop

Download from https://www.docker.com/products/docker-desktop/ and install.

**Critical settings to verify after install:**

1. Open Docker Desktop → Settings → Resources → Advanced.
2. Memory: 12 GB minimum (16 GB recommended for the full stack with apps).
3. CPUs: at least 4.
4. Swap: 2 GB.
5. Disk image size: 100 GB+ (the platform images add up).

6. Settings → Kubernetes → ✅ Enable Kubernetes.
7. Click "Apply & Restart". Wait for the green "Kubernetes is running" indicator (can take 5+ minutes the first time).

8. Settings → Resources → WSL Integration → enable for `Ubuntu-24.04`.

### Verify Docker + Kubernetes from WSL2

In WSL2 Ubuntu:
```bash
docker version           # Should show client + server versions
docker run --rm hello-world

kubectl config current-context  # Should be "docker-desktop"
kubectl get nodes               # Should show 1 node, Ready
```

If `kubectl config current-context` returns something else, switch:
```bash
kubectl config use-context docker-desktop
```

---

## 3. Install Visual Studio Code

Download from https://code.visualstudio.com/.

Install these extensions:
- **WSL** (lets VS Code edit files inside WSL)
- **Remote Development** pack
- **Kubernetes** (the official Microsoft one)
- **YAML**
- **HashiCorp HCL** (for any Terraform we add later when migrating)
- **Go** (for the BFF code)

---

## 4. Install Claude Code

In WSL2 Ubuntu:
```bash
curl -fsSL https://claude.ai/install.sh | sh
```

(Read the script first if you want — it's a normal install script.)

Sign in:
```bash
claude
```

Follow the prompts.

Verify:
```bash
claude --version
```

---

## 5. Install command-line tools (in WSL2)

```bash
# Update package index
sudo apt update

# Essentials
sudo apt install -y curl wget git unzip jq make build-essential libnss3-tools

# kubectl (Kubernetes CLI)
curl -LO "https://dl.k8s.io/release/$(curl -L -s https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl"
sudo install -o root -g root -m 0755 kubectl /usr/local/bin/kubectl
rm kubectl

# Helm
curl https://baltocdn.com/helm/signing.asc | gpg --dearmor | sudo tee /usr/share/keyrings/helm.gpg > /dev/null
sudo apt-get install apt-transport-https --yes
echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/helm.gpg] https://baltocdn.com/helm/stable/debian/ all main" | sudo tee /etc/apt/sources.list.d/helm-stable-debian.list
sudo apt-get update
sudo apt-get install helm

# k9s (TUI for Kubernetes — much easier than memorizing kubectl)
curl -sS https://webinstall.dev/k9s | bash

# yq (YAML processor)
sudo wget https://github.com/mikefarah/yq/releases/latest/download/yq_linux_amd64 -O /usr/local/bin/yq
sudo chmod +x /usr/local/bin/yq

# Cosign (image signing)
curl -O -L "https://github.com/sigstore/cosign/releases/latest/download/cosign-linux-amd64"
sudo mv cosign-linux-amd64 /usr/local/bin/cosign
sudo chmod +x /usr/local/bin/cosign

# mkcert (local CA for trusted TLS)
curl -JLO "https://dl.filippo.io/mkcert/latest?for=linux/amd64"
chmod +x mkcert-v*-linux-amd64
sudo cp mkcert-v*-linux-amd64 /usr/local/bin/mkcert
rm mkcert-v*-linux-amd64

# stern (multi-pod log tailing — very useful for local debugging)
LATEST=$(curl -s https://api.github.com/repos/stern/stern/releases/latest | grep tag_name | cut -d : -f2 | tr -d "\"v\, ")
wget "https://github.com/stern/stern/releases/download/v${LATEST}/stern_${LATEST}_linux_amd64.tar.gz"
tar xzf stern_${LATEST}_linux_amd64.tar.gz
sudo mv stern /usr/local/bin/
rm stern_${LATEST}_linux_amd64.tar.gz

# grpcurl (for testing gRPC services like SpiceDB)
GRPCURL_VERSION=$(curl -s https://api.github.com/repos/fullstorydev/grpcurl/releases/latest | grep tag_name | cut -d : -f2 | tr -d "\"v\, ")
wget "https://github.com/fullstorydev/grpcurl/releases/download/v${GRPCURL_VERSION}/grpcurl_${GRPCURL_VERSION}_linux_x86_64.tar.gz"
tar xzf grpcurl_${GRPCURL_VERSION}_linux_x86_64.tar.gz
sudo mv grpcurl /usr/local/bin/
rm grpcurl_${GRPCURL_VERSION}_linux_x86_64.tar.gz LICENSE
```

### Verify all tools

```bash
docker --version           # Docker version 27+
kubectl version --client   # Client v1.31+
helm version               # v3.16+
k9s version                # 0.32+
yq --version               # v4+
cosign version             # v2.4+
mkcert -version            # v1.4+
stern --version            # 1.30+
grpcurl --version          # v1.9+
```

If anything fails, fix before continuing.

---

## 6. Hardware FIDO2 keys — deferred for local edition

For the **local edition only**, hardware FIDO2 keys are not required up front. Windows Hello (your PC's TPM) is a FIDO2 platform authenticator and satisfies WebAuthn's origin-binding and phishing-resistance properties for single-developer local use. See [ADR-0002](../02-decisions/0002-local-passkey-via-windows-hello.md) for the rationale and the migration trigger.

What you'll do in Phase 3 (Keycloak): configure the WebAuthn policy to accept both platform and cross-platform authenticators, register Windows Hello as your admin passkey, and create a separate break-glass account with a long random password + TOTP stored offline.

### When you do need to order hardware keys

Before any deployment beyond your single local machine — i.e., before following [migration-to-vps.md](../06-reference/migration-to-vps.md) or [migration-to-aws.md](../06-reference/migration-to-aws.md) — order at minimum **two** hardware FIDO2 keys. Register both; one stays on your keyring, one in a safe (backup against loss).

Recommendations in priority order:
1. **Token2 PIN+** — ~$25 each. Cheapest FIDO2 L1 option.
2. **YubiKey 5 NFC** (or 5C NFC) — ~$55 each. Most widely supported.
3. **SoloKey v2** — ~$30 each. Fully open-source firmware.

**Local-edition note:** Passkeys (whether Windows Hello or a hardware key) work over local HTTPS using `*.secforge.local` because the mkcert root CA is browser-trusted after the next setup step. WebAuthn cares about the origin's TLS validity from the *browser's* perspective, not whether the domain is public.

---

## 7. Configure Git

```bash
git config --global user.name "Your Name"
git config --global user.email "yourname@yourdomain.com"
git config --global init.defaultBranch main
git config --global pull.rebase false
```

Generate an SSH key if you don't have one (for any future GitHub repos):
```bash
ssh-keygen -t ed25519 -C "yourname@yourdomain.com" -f ~/.ssh/id_ed25519
cat ~/.ssh/id_ed25519.pub  # add this to GitHub if you create a repo
```

---

## You're done with prerequisites when:

- [ ] WSL2 Ubuntu 24.04 installed and resource-limited
- [ ] Docker Desktop installed with Kubernetes enabled and 12+ GB allocated
- [ ] `kubectl get nodes` works in WSL2 and shows the docker-desktop node
- [ ] VS Code with WSL extension installed
- [ ] Claude Code authenticated and working
- [ ] All command-line tools above are installed and verified
- [ ] Git configured
- [ ] Windows Hello set up on your PC (PIN or biometric) — used as the local-edition passkey factor; hardware FIDO2 keys deferred per [ADR-0002](../02-decisions/0002-local-passkey-via-windows-hello.md)

When all eight are done, proceed to **[02-docker-desktop-setup.md](./02-docker-desktop-setup.md)** for cluster-specific configuration.
