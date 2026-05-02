# security-events-collector

Webhook receiver for `secrets.guardrail.bypass` events. Phase 6b-2 commit
4 — ADR-0013 § Multi-layer prevention guardrails (Layers 4 admission +
6 error reporting + 8 webhook receiver auth).

## What this service does

Accepts POSTs to `/v1/secrets/guardrail/bypass`. For each event:

1. Validates the inbound JWT via `apps/lib/api-auth/` middleware. SPIFFE-SVID
   for in-cluster callers (Kyverno reporter, library-hygiene checks,
   image-build pipeline running in-cluster); short-lived Keycloak JWT for
   out-of-cluster CI runners.
2. **Overrides** the payload's `actor` field with the verified caller
   identity. Closes the "trust the payload" weakness — a compromised CI
   runner cannot launder identity by claiming to be a different actor.
3. Validates the event against the closed-enum schema (Phase 6b-2 prompt
   § Section 8).
4. Writes one JSON-line per accepted event to stdout. Phase 7b's Promtail
   tails the container logs and ships to Loki.

Unauthenticated requests get a 401 **and** synthesize their own
`secrets.guardrail.bypass` event with `actor=unauthenticated`,
`severity=high`, `outcome=blocked` so silent rejection cannot mask an
attacker probing the endpoint.

## Event schema (canonical)

```json
{
  "ts":             "2026-05-02T14:22:01Z",
  "event":          "secrets.guardrail.bypass",
  "layer":          "kyverno|gitleaks|trivy|precommit|ci|kubernetes-secret|library-redaction",
  "severity":       "warn|high|critical",
  "actor":          "<verified caller — overridden server-side>",
  "resource":       "<repo+path | pod name | image+layer | etc>",
  "rule":           "<rule id that fired or was bypassed>",
  "outcome":        "blocked|annotated-bypass|warn-only|leaked",
  "annotation_ref": "<ticket id if escape-hatch annotation used>",
  "request_id":     "<correlation id when available>"
}
```

The `event` field is a discriminator; payloads with any other value are
rejected at validation time. Unknown values for `layer`, `severity`,
`outcome` are rejected.

## Wire / deploy

```
deploy/
  01-serviceaccount.yaml          ServiceAccount + SPIFFE label
  02-deployment.yaml              single replica, distroless/static
  03-service.yaml                 ClusterIP :8080
  04-networkpolicies.yaml         default-deny + selective allow
  05-cronjob-legacy-env-warner.yaml   daily 14d-warning sweep
```

Build: `bash apps/security-events-collector/build.sh` (mirrors
helloworld-bff's pattern; Trivy invocation includes `--scanners
vuln,secret` per ADR-0013 § Layer 3).

Apply: operator-only at 6b-2; the LLM does not `kubectl apply` to a live
cluster. Once applied:

```bash
kubectl apply -f apps/security-events-collector/deploy/
```

## Configuration

All knobs sourced from env. Required:

| Variable | Example |
|---|---|
| `COLLECTOR_ISSUER` | `https://auth.secforge.local/realms/secforge-tenants` |
| `COLLECTOR_AUDIENCE` | `security-events-collector` |
| `COLLECTOR_JWKS_ENDPOINT` | `https://auth.secforge.local/realms/secforge-tenants/protocol/openid-connect/certs` |
| `COLLECTOR_WORKLOAD_ID` | `spiffe://secforge.local/ns/app/sa/security-events-collector` |

Optional:

| Variable | Default |
|---|---|
| `COLLECTOR_LISTEN_ADDR` | `:8080` |

## Operator prerequisites

Before commit 4's manifests can be applied:

1. Provision a `security-events-collector` Keycloak client (audience
   value the BFF + CI runners + future ingestors will request) — runbook
   to land in commit 6.
2. Provision a `security-events-ci` Keycloak client for out-of-cluster
   CI callers — runbook in commit 6.
3. Confirm the namespace-scoped ClusterSPIFFEID covering `app` issues an
   ID for `security-events-collector` SA. (Should already; the existing
   helloworld-bff SA gets one the same way.)

## What this service explicitly does NOT do

- **No outbound credential needs.** No OpenBao auth, no Valkey session
  store, no DPoP keypair. Inbound-only. If a future ingestor needs to
  reach back out to a third-party SaaS, mirror helloworld-bff's
  `apps/lib/secrets/`-driven bootstrap path.
- **No durable storage.** Events are JSON-line stdout; durability is
  Phase 7b's Promtail/Loki problem.
- **No retention or TTL handling.** Loki's retention config governs that.
- **No correlation across events.** Each event stands alone; downstream
  Grafana queries do the correlation.

## References

- [ADR-0013](../../docs/02-decisions/0013-outbound-secrets-no-env.md) §
  Multi-layer prevention guardrails (Layer 8 webhook receiver auth)
- [Phase 6b-2 prompt](../../docs/05-claude-code-prompts/phase-06b-2-outbound-secrets.md)
  § Section 8 (event schema + per-layer emission table)
- [apps/lib/api-auth/](../lib/api-auth/) — the validation middleware
  reused for both auth paths (Phase 6b-1)
- [apps/lib/errreport/](../lib/errreport/) — companion scrubber that
  prevents secret values from leaking *into* events at the source
  (Phase 6b-2 commit 2)
