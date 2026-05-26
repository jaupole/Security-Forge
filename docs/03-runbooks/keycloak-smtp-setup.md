# Keycloak Realm SMTP Setup

> **Purpose.** Configure realm-level SMTP so Keycloak can send password-reset,
> email-verify, magic-link, and admin-action emails. Required for the tenant
> signup wizard (verification email) and any future "forgot password" or
> "execute actions" flow.
>
> **Realms covered.** Both `platform` (staff/operator) and `secforge-tenants`
> (SaaS tenants) get the same SMTP server. The realms send different
> templates and from-addresses are realm-attributable; the underlying
> transport is shared.
>
> **Why not realm-import YAML.** SMTP config includes a password; we don't
> want it in git. The realm-import YAML's `smtpServer` block is therefore
> left empty on greenfield install and this runbook is the source-of-truth
> for the values. On a fresh cluster rebuild, run the steps below after
> realm-import completes.

---

## Storage shape (what + where)

Keycloak v26 stores SMTP config in its own table — **not** `realm_attribute`:

```
TABLE: realm_smtp_config
  realm_id (varchar, fk to realm.id)
  name     (varchar)   -- e.g. 'host', 'port', 'from', 'user', 'password'
  value    (varchar)
  PRIMARY KEY (realm_id, name)
```

Common gotcha: setting `realm_attribute` rows with `smtp.X` keys (the
shape used by an older Keycloak version) is silently ignored and you get
`Invalid sender address 'null'` on send. Use `realm_smtp_config` only.

## Required keys

| Key | Value | Notes |
|---|---|---|
| `host` | `smtp.gmail.com` | SMTP server hostname |
| `port` | `587` | SMTP submission port (STARTTLS) |
| `auth` | `true` | Required for Gmail |
| `ssl` | `false` | We use STARTTLS, not implicit SSL |
| `starttls` | `true` | Upgrade to TLS post-greeting |
| `from` | `sender@gmail.com` | Envelope `From` |
| `fromDisplayName` | `SecForge Account` | What users see in the inbox |
| `replyTo` | `no-reply@secforge.dev` | Where Reply goes; can be the same as From |
| `user` | `sender@gmail.com` | SMTP AUTH user (same as From for Gmail) |
| `password` | `<16-char Gmail App Password>` | NOT the Gmail account password |

For Gmail specifically, the `password` value must be an **App Password**
(not the account password). Generate at https://myaccount.google.com/apppasswords
(requires 2-Step Verification enabled on the Google account). Revocable
from the same URL.

## Egress NetworkPolicy

Required: outbound TCP/587 (and TCP/465 for SSL alternate) from
`app=keycloak` pods to the public internet. Covered by
`platform/manifests/keycloak/11-egress-smtp.yaml`. Without it the realm
config is fine but the TCP connection fails with `Connection refused`.

If using a different SMTP provider that uses different ports (e.g.
Postmark uses 587 too; Mailgun uses 465 / 587; SendGrid uses 587 / 2525),
add a matching `ports:` entry to that NetworkPolicy.

## Procedure (live cluster)

Run from a host with `kubectl` access to the cluster:

```bash
# 1. Confirm egress NetPol is present (file checked into repo; apply if absent).
sudo -n kubectl get netpol -n keycloak allow-egress-smtp \
  || bash ~/secforge/platform/lib/apply-manifest.sh \
       ~/secforge/platform/manifests/keycloak/11-egress-smtp.yaml

# 2. Write SMTP config to realm_smtp_config for both realms.
#    Replace <PASSWORD> with the App Password (16 chars, no spaces).
cat > /tmp/smtp.sql <<'EOF'
WITH realms_to_config AS (
  SELECT id, name FROM realm WHERE name IN ('platform', 'secforge-tenants')
),
smtp_attrs(name, value) AS (
  VALUES
    ('host',              'smtp.gmail.com'),
    ('port',              '587'),
    ('auth',              'true'),
    ('ssl',               'false'),
    ('starttls',          'true'),
    ('from',              'sender@gmail.com'),
    ('fromDisplayName',   'SecForge Account'),
    ('replyTo',           'no-reply@secforge.dev'),
    ('user',              'sender@gmail.com'),
    ('password',          '<PASSWORD>')
)
INSERT INTO realm_smtp_config (realm_id, name, value)
SELECT r.id, a.name, a.value
FROM realms_to_config r CROSS JOIN smtp_attrs a
ON CONFLICT (realm_id, name) DO UPDATE SET value = EXCLUDED.value;
EOF

PG_PWD=$(sudo -n kubectl get secret -n keycloak secforge-keycloak-db-app \
  -o jsonpath="{.data.password}" | base64 -d)
sudo -n kubectl exec -n keycloak -i secforge-keycloak-db-1 -c postgres -- \
  env PGPASSWORD="$PG_PWD" \
  psql -h 127.0.0.1 -U keycloak -d keycloak < /tmp/smtp.sql

# 3. Bounce keycloak-0. Direct DB writes do NOT invalidate Infinispan
#    cache — Keycloak keeps the old (empty) SMTP config in memory until
#    the pod restarts.
sudo -n kubectl delete pod -n keycloak keycloak-0
sudo -n kubectl wait -n keycloak --for=condition=Ready pod/keycloak-0 --timeout=120s

# 4. Verify.
sudo -n kubectl exec -n keycloak keycloak-0 -- timeout 5 bash -c \
  'echo > /dev/tcp/smtp.gmail.com/587 && echo OK'
# Expected: OK
```

Smoke test by triggering a signup against the wizard:

```bash
EMAIL="someone+verify-$(date +%s)@gmail.com"
curl -ksw "\nHTTP %{http_code}\n" \
  -H "Host: portal.secforge.dev" \
  -H "content-type: application/json" \
  -X POST -d "{\"organizationName\":\"SMTP Smoke\",\"firstName\":\"X\",\"lastName\":\"Y\",\"email\":\"$EMAIL\"}" \
  https://127.0.0.1/api/v1/signup
# Expected: 201 + emailVerificationSent: true
```

Check the destination inbox — the verification email lands within ~10s.

## Rotation

To rotate the App Password (e.g. you suspect it's leaked):

1. Generate a fresh App Password at https://myaccount.google.com/apppasswords
2. Delete the old one from the same page (revokes immediately)
3. Re-run step 2 of the procedure above with the new value
4. Re-run step 3 (bounce keycloak-0)

The user-perceived disruption is ≤2 minutes (one keycloak pod restart).

## Provider switching

To move off Gmail (e.g. to Postmark / Mailgun / SES once a domain is
verified there):

1. Set `host`, `port`, `user`, `password` to the new provider's values.
2. If the new provider uses `465` SSL instead of `587` STARTTLS, set
   `ssl='true'` and `starttls='false'`.
3. Update `from` and `replyTo` (some providers require From-address
   verification before they'll accept the send).
4. Same procedure: SQL UPSERT → keycloak-0 bounce → smoke test.

## Gotchas (learned in the field)

- **Wrong storage table.** SMTP config goes in `realm_smtp_config`, NOT
  `realm_attribute`. `smtp.host` rows in `realm_attribute` are silently
  ignored. Symptom: `Invalid sender address 'null'` on send.
- **Cache.** Direct DB writes don't invalidate Infinispan cache. You
  MUST bounce keycloak-0 after the SQL UPSERT.
- **Egress policy.** Keycloak ns is default-deny-egress (Layer A
  baseline). Without `allow-egress-smtp` the TCP connect to the SMTP
  server fails with `Connection refused`.
- **Gmail App Password format.** Google displays the 16 characters as
  four 4-char groups separated by spaces (`abcd efgh ijkl mnop`).
  Strip the spaces when you store it. With spaces, Gmail SMTP AUTH
  returns "535 Username and Password not accepted".
- **2-Step Verification required.** Gmail won't generate App Passwords
  until 2-Step is enabled on the Google account.
- **Daily send limit.** Gmail's free tier caps at ~500 sends/day per
  account. Plenty for tenant signups; not enough for bulk
  notification email. Migrate to Postmark / SES before that becomes a
  problem.

## Related

- `project_keycloak_admin_db_only` — why kcadm isn't an option here
- `project_keycloak_client_secret_rotation_pattern` — same Infinispan-
  cache gotcha shows up for client secret + redirect URI changes
- `project_signup_wizard_v1_landed` — the wizard that depends on this
- `platform/manifests/keycloak/11-egress-smtp.yaml` — the NetworkPolicy
