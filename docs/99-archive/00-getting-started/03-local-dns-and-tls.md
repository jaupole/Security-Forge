# Local DNS and TLS

To run a multi-component platform locally, we need:
1. Hostnames that look like real production hostnames (`auth.secforge.local`, `app.secforge.local`, etc.)
2. TLS certificates the browser actually trusts (so passkeys, secure cookies, and HSTS all work the same as in production)

mkcert + a hosts file entry gets you both in about 15 minutes.

---

## 1. Set up the local CA with mkcert

mkcert creates a local Certificate Authority (CA), then issues certificates from it. The CA is added to your operating system's trust store so your browser trusts certs it issues — no warnings, no `--insecure` flags.

You should already have mkcert installed (from `01-prerequisites.md`).

### Install the CA into your trust stores

In WSL2 Ubuntu:

```bash
mkcert -install
```

This installs the CA into:
- The Linux trust store (so `curl` and other CLI tools trust it)
- Firefox's NSS trust store (if Firefox is installed)

**Critical: also install the CA on Windows** so Chrome/Edge trust it. From WSL2:

```bash
# Find the CA root
mkcert -CAROOT
# Output: /home/<your-user>/.local/share/mkcert
```

In **Windows Explorer**, navigate to that path (use the WSL path: `\\wsl$\Ubuntu-24.04\home\<your-user>\.local\share\mkcert`).

Double-click `rootCA.pem`. Windows opens the certificate dialog. Click "Install Certificate":
1. Store Location: **Local Machine** (requires admin)
2. Certificate Store: **Place all certificates in the following store** → Browse → **Trusted Root Certification Authorities**
3. Finish.

After this, Chrome, Edge, Firefox (Windows version), and Windows command-line tools all trust certificates issued by your local CA.

### Verify

In a Windows command prompt:
```
certutil -store -user Root | findstr "mkcert"
```

You should see your mkcert CA listed.

---

## 2. Issue a wildcard cert for `*.secforge.local`

```bash
mkdir -p ~/.local/secforge-certs
cd ~/.local/secforge-certs
mkcert -cert-file secforge.local.pem -key-file secforge.local-key.pem "secforge.local" "*.secforge.local"
```

This creates two files:
- `secforge.local.pem` — the certificate
- `secforge.local-key.pem` — the private key

We'll use these in cert-manager later (Phase 1), or as a Kubernetes Secret directly.

**Note:** This local CA private key is on your laptop only. Don't check it into a public repo. (We'll add a `.gitignore` rule for `*.local-key.pem`.)

---

## 3. Set up local DNS resolution

We need `*.secforge.local` to resolve to `127.0.0.1`. The simplest approach: hosts file entries.

### Windows hosts file

Open Notepad **as Administrator**. File → Open → navigate to:
```
C:\Windows\System32\drivers\etc\hosts
```
(In the file dialog, change "Text Documents (*.txt)" to "All Files" to see it.)

Add at the end:
```
127.0.0.1   secforge.local
127.0.0.1   auth.secforge.local
127.0.0.1   auth-admin.secforge.local
127.0.0.1   app.secforge.local
127.0.0.1   api.secforge.local
127.0.0.1   bao.secforge.local
127.0.0.1   wazuh.secforge.local
127.0.0.1   tp.secforge.local
127.0.0.1   grafana.secforge.local
127.0.0.1   tempo.secforge.local
127.0.0.1   minio.secforge.local
127.0.0.1   pf.secforge.local
127.0.0.1   pt.secforge.local
127.0.0.1   pm.secforge.local
```

(`pf` = Proposal Forge, `pt` = Project Tracker, `pm` = future PM app — these are placeholders.)

Save. Close.

### WSL2 hosts file

WSL2 inherits Windows DNS for many things but not for hosts file entries by default. The cleanest fix: also add the same entries to WSL's hosts file.

In WSL2 Ubuntu:
```bash
sudo nano /etc/hosts
```

Add the same lines as above. Save with Ctrl+O, Enter, Ctrl+X.

### Verify

From WSL2:
```bash
getent hosts auth.secforge.local
# Should print: 127.0.0.1   auth.secforge.local

ping -c 2 app.secforge.local
# Should ping 127.0.0.1
```

From Windows (Command Prompt or PowerShell):
```
ping app.secforge.local
```
Should resolve to `127.0.0.1`.

---

## 4. Verify TLS works

Once Phase 1 deploys ingress-nginx and a service, we'll verify in the browser:
- Visit `https://app.secforge.local`
- See a green padlock with no warnings
- Certificate details show issuer = "mkcert <username>@<machine>"

For now, you've done what you need to. The actual end-to-end TLS test happens in Phase 1.

---

## 5. Why not just use `localhost`?

Two reasons:
1. **Multi-host realism.** Production has many hostnames. We want our local development to exercise the same hostname routing logic (Keycloak's redirect URIs, BFF's CORS handling, OAuth's `iss` claims, etc.).
2. **Cookie scoping.** Real production has Cookies scoped to specific subdomains. Testing this on `localhost:3000` vs `localhost:3001` doesn't exercise it the same way.

`*.secforge.local` simulates a real domain at no cost.

---

## 6. Why `.local` vs other TLDs?

`.local` is technically reserved for Multicast DNS (mDNS / Bonjour), which can occasionally cause weird behavior on some networks. Alternative TLDs you could use:
- `.test` (RFC 2606 — explicitly reserved for testing; technically the most correct choice)
- `.localhost` (also reserved, but some software treats it specially)
- A subdomain of a domain you actually own that you don't use publicly (e.g., `secforge.dev.example.com` resolving to 127.0.0.1)

If you hit weird mDNS issues, switch to `.test` — replace `secforge.local` with `secforge.test` everywhere in the config files we'll create. Mention this preference to Claude Code in your first session and it'll use `.test` consistently.

---

## You're done with DNS and TLS setup when:

- [ ] mkcert CA installed in WSL trust store
- [ ] mkcert CA installed in Windows trust store
- [ ] Wildcard cert generated for `*.secforge.local`
- [ ] Hosts file entries added on both Windows and WSL
- [ ] `ping auth.secforge.local` resolves to 127.0.0.1 from both Windows and WSL

Next: **[04-wsl2-setup.md](./04-wsl2-setup.md)** if you want WSL convenience tweaks, or skip to **[05-first-claude-code-session.md](./05-first-claude-code-session.md)** to learn the Claude Code workflow.
