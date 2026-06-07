# WSL2 Setup and Verification

You should have already installed WSL2 in [01-prerequisites.md](./01-prerequisites.md). This document covers configuration tweaks that make WSL2 nicer to work in.

---

## 1. Verify WSL is set to version 2

In **PowerShell (not WSL)**:

```powershell
wsl --list --verbose
```

You should see:
```
NAME            STATE           VERSION
* Ubuntu-24.04    Running         2
```

If `VERSION` shows `1`, upgrade:
```powershell
wsl --set-version Ubuntu-24.04 2
```

---

## 2. Configure WSL resource limits (recommended)

By default, WSL2 can consume up to 50% of your RAM and 25% of your swap. For a development machine this is fine, but if you find your Windows host getting sluggish, cap WSL.

Create or edit `C:\Users\<your-windows-user>\.wslconfig`:

```ini
[wsl2]
memory=8GB
processors=4
swap=4GB
localhostForwarding=true
```

Adjust based on your machine. Restart WSL after changing this:

```powershell
wsl --shutdown
```

Then reopen the Ubuntu terminal.

---

## 3. Set up SSH keys (for GitHub later)

In WSL2 Ubuntu:

```bash
# Generate a new SSH keypair
ssh-keygen -t ed25519 -C "yourname@yourdomain.com" -f ~/.ssh/id_ed25519

# Start the SSH agent
eval "$(ssh-agent -s)"

# Add your key
ssh-add ~/.ssh/id_ed25519

# Print the public key (you'll add this to GitHub)
cat ~/.ssh/id_ed25519.pub
```

Save the public key for when you set up your repository.

---

## 4. Configure Git

In WSL2 Ubuntu:

```bash
git config --global user.name "Your Name"
git config --global user.email "yourname@yourdomain.com"
git config --global init.defaultBranch main
git config --global pull.rebase false

# Optional but recommended: sign commits with Sigstore-style identity (we'll set this up later in Phase 1)
```

---

## 5. Install signed-commits prerequisites (we'll fully set up later)

Place this in your bash setup for later:

```bash
# Install gitsign (will sign commits with Sigstore)
GITSIGN_VERSION=$(curl -s https://api.github.com/repos/sigstore/gitsign/releases/latest | grep tag_name | cut -d : -f2 | tr -d "\"v\, ")
wget "https://github.com/sigstore/gitsign/releases/download/v${GITSIGN_VERSION}/gitsign_${GITSIGN_VERSION}_linux_amd64.deb"
sudo dpkg -i gitsign_${GITSIGN_VERSION}_linux_amd64.deb
rm gitsign_${GITSIGN_VERSION}_linux_amd64.deb
```

We won't enable signed commits until Phase 1 because it requires repo configuration.

---

## 6. Open this project in VS Code

You should already have your project folder. If not, it'll be created in Phase 0.

```bash
# In WSL2 Ubuntu, navigate to where you want the project
cd ~
mkdir -p code
cd code

# Once you have the project folder
cd secforge-platform
code .
```

VS Code will open with the WSL connection active. The bottom-left of VS Code should say `WSL: Ubuntu-24.04`. If it doesn't, click that area and choose "Connect to WSL".

---

## 7. Test Claude Code from inside the project

```bash
cd ~/code/secforge-platform
claude
```

Claude Code starts and reads CLAUDE.md from the current directory automatically. Try:

```
> Read PLAN.md and tell me what phase we're currently in.
```

If Claude Code responds correctly, you're set up.

---

## You're done with WSL2 setup when:

- [ ] WSL is on version 2
- [ ] Resource limits are configured (if needed)
- [ ] SSH keys are generated
- [ ] Git is configured
- [ ] VS Code opens in WSL mode for the project
- [ ] Claude Code starts and reads CLAUDE.md correctly

Next: **[05-first-claude-code-session.md](./05-first-claude-code-session.md)** to learn how to work with Claude Code through the phases.
