# SecForge Wazuh rule conventions

Conventions for custom rules added to the Wazuh manager so the dashboard
stays organized and operators can find what they need.

## Rule ID range

| Range | Purpose |
|---|---|
| 100001–100099 | Wazuh chart `local_rules.xml` — application-error catch-alls (chart-shipped) |
| 100100–100199 | Reserved for upstream Wazuh examples |
| 100200–100299 | Trivy / image-scanning integration (`14-trivy-wazuh.sh`) |
| 100300–100399 | OpenBao + Keycloak audit-log rules (`07o-wazuh-audit-rules.sh`) |
| 100400–100499 | upstream-image-check (`07l-wazuh-upstream-image-rules.sh`) |
| 100500–100599 | OpenBao seal-state maintenance rules (`07m-wazuh-maintenance-rules.sh`) |
| 100600–100699 | cert-manager renewal maintenance rules (`07m-wazuh-maintenance-rules.sh`) |
| 100700–100799 | CloudNativePG cluster-health maintenance rules (`07m-wazuh-maintenance-rules.sh`) |
| 100800–100899 | Velero backup-status maintenance rules (`07m-wazuh-maintenance-rules.sh`) |
| 100900–100999 | Wazuh agent connectivity maintenance rules (`07m-wazuh-maintenance-rules.sh`) |
| 101000+ | Available (next: per-app audit rules — Project Tracker, Proposal Forge) |

> The OpenBao + Keycloak audit rules originated in the retired local edition
> at 100200–100299; they were renumbered into 100300–100399 during the
> platform migration because Trivy already occupies the 100200 range.

## Meta-groups (cross-cutting tags)

These groups span rule families and let the dashboard build category-wide
views. Apply them in addition to whatever specific rule.groups a rule
already has.

| Meta-group | Use when |
|---|---|
| **`system_admin_attention`** | A human operator must take action. The default landing-page filter for the "Maintenance Required" dashboard. Applied to: upstream image bumps, expired certs, capacity warnings, manual-intervention crash loops, sealed OpenBao, etc. |
| **`security_update`** | Security-relevant patch is available. Subset of `system_admin_attention` for vulnerability-driven updates. |
| **`compliance_drift`** | A configuration that was set deliberately has reverted (e.g., chart re-render wiped our OIDC config — see Gap #23). |
| **`operational`** | Information that may need attention but isn't a security issue (e.g., job failures, retry storms). |
| **`info`** | Informational only. Should never page anyone. Used for run-completion summaries. |

## Severity ladder

Stay aligned with Wazuh's standard scale (1–15) but pick consistent
levels for similar types of events:

| Level | When |
|---|---|
| 2 | Info: normal completions, status messages |
| 3 | Generic catch-all for a custom decoder, used for if_sid chaining |
| 6 | Operational warning: registry lookup failed, retry succeeded |
| 8 | Operational error: 3+ failures in a window, persistent retry loop |
| **10** | **Action required**: a human needs to do something. Routes to the Maintenance Required dashboard. |
| 12 | Security event: anomalous auth, unauthorized config change |
| 15 | Critical security incident: confirmed compromise |

Anything `level >= 10` in `system_admin_attention` is the working set for
the "what does ops need to do this week" dashboard.

## Dashboard pattern

The "Maintenance Required" saved Dashboard filters on:

```
rule.groups : "system_admin_attention" AND rule.level >= 8
```

Time range: last 30 days (matches how often you might miss a Monday
weekly check). Grouped by:
- `rule.id` (which alert, top 10)
- `data.image` (when applicable)
- `agent.name`

To add a new alert class to this dashboard, just include
`system_admin_attention` in the rule's `<group>` element and pick the
right severity from the ladder above. No dashboard changes needed — the
filter picks it up automatically.

## File layout

- `platform/manifests/wazuh/local-decoders/<name>.xml` — custom decoder
- `platform/manifests/wazuh/local-rules/<name>.xml` — custom rule
- `platform/components/07X-wazuh-<name>-rules.sh` — idempotent installer
  (push to `/var/ossec/etc/decoders/local_decoder_<name>.xml` and
  `/var/ossec/etc/rules/local_rules_<name>.xml`, validate, reload)

Pattern established by 07l-wazuh-upstream-image-rules.sh; copy that
template when adding new rule families.
