# Runbook: Kyverno image-signature verification (fail-closed)

Covers the `verify-image-signature-secforge` ClusterPolicy after it goes
**fail-closed** (`webhookConfiguration.failurePolicy: Fail`) — backlog #97.

## What "fail-closed" means here

A Pod whose image matches `ghcr.io/{secforge,jaupole}/*` is **denied at
admission** unless Kyverno can cryptographically verify a valid cosign keyless
signature (GitHub-OIDC identity `^https://github.com/(secforge|jaupole)/`).
With `failurePolicy: Fail`, a Kyverno **error or timeout also denies** — so a
broken verifier blocks deploys instead of silently admitting unsigned images.

The critical design property (why this is safe where #95/#96 were not): the
trust material is **pinned offline** in the policy (Fulcio root, Rekor pubkey,
CT-log pubkey). Verification makes **no call to Sigstore infrastructure** — it
only pulls the signature artifact from ghcr (same fate as the image pull). The
TUF/Fulcio root-init race that denied signed pods on reboot cannot occur.

## BREAK-GLASS — flip back to fail-open (≈10 s)

If signed SecForge pods are being denied and you need deploys/recovery to
proceed **now**:

```bash
ssh secforge
sudo -n kubectl patch clusterpolicy verify-image-signature-secforge --type=merge \
  -p '{"spec":{"webhookConfiguration":{"failurePolicy":"Ignore"}}}'
# verify:
sudo -n kubectl get clusterpolicy verify-image-signature-secforge \
  -o jsonpath='{.spec.webhookConfiguration.failurePolicy}'; echo
```

`Ignore` = a verify error/timeout admits the pod (fail-open). Signed-image
enforcement on the happy path still applies; only the failure semantics change.
This is the pre-#97 posture — safe to sit in indefinitely while you diagnose.

**Re-arm** after the cause is fixed: same patch with `"Fail"`, then confirm a
signed deploy admits and the guardrail self-test still denies an unsigned pod.

> Do NOT "fix" a denial by disabling the policy, widening the identity regex,
> or dropping `required: true`. Those weaken the control fleet-wide. Break-glass
> is the failure-policy flip and nothing else.

## Triage: signed pods being denied

1. **Is it actually this policy?** The deny message names
   `verify-image-signature-secforge / verify-secforge`. If it names
   `require-image-digest`, `restrict-image-registries`, or a vendor policy,
   this runbook does not apply.
2. **ghcr reachable + creds valid?** Kyverno pulls the signature with
   `ghcr-pull-secret` (VSO-rendered, `03-vso-binding.yaml`). A 401/403 or ghcr
   outage looks like a verify failure. Check:
   ```bash
   sudo -n kubectl -n kyverno logs deploy/kyverno-admission-controller --tail=100 \
     | grep -iE 'verifyimages|signature|ghcr|fulcio|rekor'
   ```
   A `ghcr.io ... 403` → the pull secret is stale: re-check the
   `kyverno-vso` VaultStaticSecret is `SecretSynced=True`.
3. **New signing identity?** If a new image-build workflow signs from a repo the
   regex doesn't match (e.g. a new GitHub org), verification legitimately fails.
   Fix = widen `subjectRegExp` deliberately in the policy, not break-glass.
4. **Trust material expired/rotated?** The pinned Fulcio root is valid until
   **2031-10-05**. If Sigstore rotates the root early, offline verify fails for
   *everything*. Re-extract and re-pin:
   ```bash
   ssh secforge
   HOME=/tmp/sig cosign initialize          # refreshes ~/.sigstore TUF cache
   cat /tmp/sig/.sigstore/root/targets/fulcio_v1.crt.pem   # -> policy roots
   cat /tmp/sig/.sigstore/root/targets/rekor.pub           # -> rekor.pubkey
   cat /tmp/sig/.sigstore/root/targets/ctfe_2022.pub       # -> ctlog.pubkey
   ```
   Update `platform/manifests/kyverno/policies/05-image-signature-verification.yaml`
   via PR. (Quarterly check recommended — see the policy comment.)

## Alerting

`ImageSignatureVerificationFailing` (PrometheusRule) fires on repeated verify
failures. Under fail-open it was informational; under fail-closed a sustained
firing means deploys are being blocked — treat as page-worthy. One-off = a
transient ghcr blip; repeated = creds (step 2) or trust material (step 4).

## Scope note

`verify-image-signature-vendors` stays **Audit + Ignore** (report-only): ~44 of
65 vendor repos publish no signature, so fail-closed there would deny most of
the platform. Only the SecForge-own images (which CI always signs) are
fail-closed. Getting vendors enforceable is the separate digest-pin +
mirror-and-sign workstream in
`docs/04-security/image-supply-chain-verification.md`.
