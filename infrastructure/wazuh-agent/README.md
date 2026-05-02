# Wazuh agent (Phase 7d Item 5 + Item 6)

A standalone hardened Wazuh agent DaemonSet that lives in its own
namespace (`wazuh-agent`, PSS=privileged) and reports to the
`wazuh-manager` in the `wazuh` namespace.

## Why standalone (not chart-managed)

The vendored Wazuh chart bundles the agent in the same Helm release
as manager + indexer + dashboard. The chart's agent template
hard-codes `privileged: true` + `hostPID: true`. PSS=baseline (the
`wazuh` ns label) blocks both `hostPath` volumes AND `hostPID`
entirely — the chart's agent can't run there regardless of how we
configure capabilities.

Splitting the agent into its own namespace gives:
- A contained privilege bubble (manager/indexer/dashboard stay
  PSS=baseline-locked).
- Standalone manifests = full operator control over the hardening
  surface, no vendor patch round-trips.

## Hardening (per-pod, vs chart default)

| Setting | Chart default | This DaemonSet |
|---|---|---|
| `securityContext.privileged` | `true` | `false` |
| `hostPID` | `true` | `false` |
| `capabilities` | (privileged → all) | drop ALL + add `[DAC_OVERRIDE, SETUID, SETGID]` |
| `image` | floating tag `4.14.4` | pinned by digest `sha256:085aac6…` |
| `seccompProfile` | unset | `RuntimeDefault` |
| `runAsUser` | (privileged → root) | `0` (allowed at PSS=privileged) |
| pod-level `fsGroup` | unset | `999` (the wazuh user's GID) |

## What this provides

| Feature | Working |
|---|---|
| Manager registration via authd (port 1515) | ✅ |
| Network connectivity to manager (port 1514) | ✅ |
| File integrity monitoring (FIM) on host /etc, /usr/bin, /usr/sbin | ✅ |
| Inventory (packages, hardware, network, OS) via syscollector | ✅ |
| Pod-log tailing for Keycloak + OpenBao (Phase 7d Item 6) | ✅ (configured in ossec.conf) |
| File-based rootcheck | ✅ (image default) |

## What this does NOT provide (PSS=baseline-imposed gaps)

The hardening trade-off costs us a few features that would require
additional capabilities not granted at PSS=privileged + minimal-caps:

| Feature | Reason |
|---|---|
| Host-level process inventory | `hostPID: false` — agent only sees its own PID namespace |
| Rootcheck process-based scans | Same as above |
| Auditd integration | Requires `AUDIT_READ` + DBus access |
| Active-response | Disabled (would need root + more caps; not used on local-edition) |

For local-edition (single-tenant dev VM) these gaps are an
acceptable trade-off vs. relaxing the wazuh ns to PSS=privileged.

## Known issue: enrollment key persistence

`/var/ossec/etc/` is mounted as an EmptyDir, so the agent's
`client.keys` (holding the manager-issued enrollment key) is wiped
on every pod restart. The agent's auto-enrollment then races
against the manager's existing-name registration:

1. Pod restart → empty client.keys → agentd auto-enrolls → manager
   creates a new agent ID with the same node name.
2. Agent doesn't reliably persist the key to client.keys (the
   write race / image init quirk results in 0-byte client.keys
   even after successful enrollment).
3. Subsequent enrollment attempts fail with `Duplicate agent name`
   (the manager's `<purge>yes</purge>` doesn't help because
   `<after_registration_time>1h</after_registration_time>` blocks
   re-replacement).

**Symptoms:** manager `agent_control -l` shows the agent as Active,
but the agent's `wazuh-logcollector` doesn't reach steady state
and pod-log events from Keycloak/OpenBao (Item 6) don't flow
reliably until the operator intervenes.

**Recovery (manual):** restart the manager pod (clears stuck
remoted state) or remove the duplicate agent ID from the
manager's keys file:

```bash
kubectl exec -n wazuh wazuh-manager-0 -i -- /var/ossec/bin/manage_agents <<< $'r\n<id>\ny\nq\n'
kubectl rollout restart -n wazuh-agent daemonset/wazuh-agent
```

**Permanent fix (deferred follow-up):** pre-register the agent on
the manager with a known name + extract the key, persist as a K8s
Secret in wazuh-agent ns, mount as `/var/ossec/etc/client.keys`
via subPath. Or use a hostPath mount for per-node key persistence.

This is tracked separately as a Phase 7d.5 follow-up — the
hardening surface (the substantive Item 5 work) IS shipped.

## Files

| File | Purpose |
|---|---|
| `01-namespace.yaml` | Namespace `wazuh-agent` with PSS=privileged labels. |
| `02-rbac.yaml` | ServiceAccount `wazuh-agent` (no K8s API access; SA exists for SPIRE-managed identity wiring). |
| `03-configmap.yaml` | `ossec-supplements.xml` — XML appended to the image's default ossec.conf during init (FIM directories on host paths, pod-log localfile blocks for Item 6, syscollector config). |
| `04-daemonset.yaml` | DaemonSet itself. Init container copies the image's `/var/ossec/etc/` to an EmptyDir, appends our supplements, chmods writable. Main container mounts the EmptyDir over `/var/ossec/etc/`. |
| `05-networkpolicies.yaml` | Default-deny ingress + egress allow for agent → manager:1514/1515 (cross-ns to wazuh ns) + DNS. |

Companion change in `infrastructure/wazuh/02-networkpolicies.yaml`
adds an `allow-wazuh-agent-to-manager` ingress rule on the manager
side (cross-ns ingress allow on 1514 + 1515).

Companion change in
`infrastructure/kyverno/policies/pod-security.yaml` adds
`wazuh-agent` to the namespace exclusion list (the rest of the
restricted-PSS Kyverno policy doesn't apply to the agent's
hostPath/hostPID/runAsUser=0 needs).

## Apply

```bash
kubectl apply -f infrastructure/wazuh/02-networkpolicies.yaml   # cross-ns ingress allow
kubectl apply -f infrastructure/kyverno/policies/pod-security.yaml   # ns exclusion
kubectl apply -f infrastructure/wazuh-agent/                    # all five files in this dir
```
