# Control audit anchor — runbook

Off-site, signed anchors for the two audit logs Control holds: the **fleet audit log**
(`app_audit_events`, the rows Proposal Forge, Business Manager and Project Manager forward)
and **Control's own `audit_log`**.

Same mechanism as the platform's other anchors (`platform-audit-anchor-activation.md`,
`platform-loki-audit-anchor.md`, Member Hub's `audit-anchor`): OpenBao Transit signs with the
`audit-signing` Ed25519 key and the result is committed to `jaupole/secforge-audit-anchors`.

## What it does

| Job | Schedule (UTC) | Does |
|---|---|---|
| `control-audit-anchor` | 00:53 daily | Reduces the chain heads to one value, signs it, commits `control/<date>.json`. Commits nothing when nothing is new. |
| `control-audit-verifier` | 05:11 daily | Re-checks the last 30 days of anchors: signature against the **pinned** public key, then that the database still produces the anchored values. |

A mismatch means audit history was rewritten after the anchor was made, or an anchor was forged.
The verifier logs `AUDIT_CHAIN_BROKEN` (the `AuditChainBroken` Loki alert, `alerts.md#auditchainbroken`)
and the Job fails. The Job also fails, without that marker, when no anchor has been published for
14 days.

**What is published.** The anchors repository is public, so an anchor is opaque: for the fleet log a
row id and ONE hash over the head of every `(org, app)` chain at that id; for Control's log a
timestamp and the hash of the newest row. No org ids, no per-org counts.

**Why it does not cry wolf.** Rows younger than 15 minutes wait for the next anchor. Retention
(three years) deletes old rows, sometimes a quiet chain's head, so the hash covers only heads with
at least 60 days left before retention could delete them — twice the 30-day verification window.

## Known limits

- An anchor proves history was not rewritten **after** it was made. It says nothing about a row
  that was wrong when written.
- A chain with no activity for about two years and ten months drops out of new anchors (its head
  is about to be purged). It was covered by every anchor made while it was younger.
- The verifier checks 30 days of anchors. Older anchors stand on record in the repository and can
  be checked by hand while their rows are still inside retention.

## Activation

Prerequisites already in place: the `audit-signing` Transit key, the `audit-signer` and
`platform-audit` policies, and the push token at `secret/platform/audit-anchors-push-token`.
New: one OpenBao role, the VSO bindings, and the two CronJobs (which ship suspended).

```bash
# 0. Control must be running an image that has the two CLI commands and
#    migration 110 applied (ecosystem-control PR "off-site signed anchors").
#    deploy-app applies manifests/control/22-audit-anchor-cronjob.yaml with it
#    (service account + both CronJobs, suspended).
cd ~/secforge && git pull --ff-only

# 1. Create the control-audit-signer OpenBao role via break-glass (no root
#    token; the admin token lives only in this shell and expires in an hour).
SA=$(sudo -n kubectl -n openbao exec openbao-0 -c openbao -- cat /var/run/secrets/kubernetes.io/serviceaccount/token)
T=$(sudo -n kubectl -n openbao exec openbao-0 -c openbao -- env BAO_SKIP_VERIFY=1 \
      bao write -field=token auth/kubernetes/login role=admin-break-glass jwt="$SA")
sudo -n kubectl -n openbao exec openbao-0 -c openbao -- env BAO_SKIP_VERIFY=1 BAO_TOKEN="$T" \
  bao write auth/kubernetes/role/control-audit-signer \
    bound_service_account_names=control-audit-signer \
    bound_service_account_namespaces=control \
    audience=https://kubernetes.default.svc.cluster.local \
    token_policies=audit-signer,platform-audit token_ttl=900 token_max_ttl=1800 \
    alias_name_source=serviceaccount_uid
unset T SA
#    (A full 05j-app-vso-roles.sh run also creates it — the row is codified —
#    but 05j re-applies the openbao 12/13 manifests; see
#    platform-loki-audit-anchor.md for that caveat. Never `bao token revoke -self`.)

# 2. Apply the VSO bindings (NOT applied by deploy-app) and confirm the push
#    token rendered into the control ns.
cd ~/secforge/platform && KUBECONFIG=$HOME/.kube/config bash lib/apply-manifest.sh \
  manifests/control/22a-audit-anchor-vso.yaml
sudo -n kubectl -n control get secret audit-anchors-push-token

# 3. One manual anchor run, then one verifier run.
sudo -n kubectl -n control create job --from=cronjob/control-audit-anchor control-audit-anchor-first
sudo -n kubectl -n control logs -f job/control-audit-anchor-first
#    expect: [audit:anchor] committed control/<date>.json …
#    and the file at https://github.com/jaupole/secforge-audit-anchors/tree/main/control
sudo -n kubectl -n control create job --from=cronjob/control-audit-verifier control-audit-verifier-first
sudo -n kubectl -n control logs -f job/control-audit-verifier-first
#    expect: [audit:verify-anchors] 1 anchor(s) verified; newest is 0 day(s) old
```

4. Unsuspend **in git**: set `suspend: false` on both CronJobs in
   `manifests/control/22-audit-anchor-cronjob.yaml`, commit, and apply it. A `kubectl patch`
   would be undone by the next Control deploy, which re-applies the file.

## When the verifier fails

```bash
sudo -n kubectl -n control logs job/<the failed job>
```

| Log line | Meaning | Do |
|---|---|---|
| `AUDIT_CHAIN_BROKEN: off-site audit anchor does not match the database [...]` with `fleet log no longer matches` or `Control log no longer matches` | The database no longer produces what was anchored on that date. | Treat as a tampering incident until explained: `alerts.md#auditchainbroken`. Do not "fix" anything first. |
| `... signature does not verify against a pinned key` | The anchor file was not signed by a pinned key: forged, or the key was rotated. | Check the repository's commit history for that file. If the Transit key was rotated, see below. |
| `no anchor published in the last 14 days` | The anchor job is suspended or failing. | `kubectl -n control get cronjob control-audit-anchor`; read its last Job's logs. |
| `AUDIT_ANCHOR_PUBKEY_B64 is not set` | The verifier's pinned key is missing from the manifest. | Restore it in `22-audit-anchor-cronjob.yaml`. |

## Key rotation

The verifier pins the **public** half of `transit/keys/audit-signing` in
`AUDIT_ANCHOR_PUBKEY_B64` (`22-audit-anchor-cronjob.yaml`). The value may hold several keys,
comma-separated. After rotating the Transit key, anchors are signed with the new version: ADD the
new public key (`bao read transit/keys/audit-signing`, field `keys.<version>.public_key`) beside the
old one and commit, so anchors from before the rotation keep verifying. Drop the old key once 30
days have passed.
