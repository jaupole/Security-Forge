# Applying default-deny NetworkPolicies to the system namespaces (H-4.14)

> Manifests: [platform/manifests/system-netpol/](../../platform/manifests/system-netpol/)
> Audit: **H-4.14** — every app namespace is default-deny, but `kube-system`,
> `istio-system`, and `topolvm-system` had **zero** NetworkPolicy. This closes them.

## Design (read before applying)

- **Ingress-only.** Each namespace gets a `default-deny-ingress` plus explicit
  allow policies for the flows proven necessary from the live cluster. **Egress is
  left open** — system components (CoreDNS upstream, controllers → apiserver) have
  wide, not-fully-enumerated egress needs; locking egress here risks a cluster-wide
  outage and is out of scope for this conservative pass.
- **Host-callback convention.** On this k3s node the kube-apiserver and kubelet run
  in the host net namespace and reach pods **via `cni0` with source `10.42.0.1`** —
  *not* the node's public IP. So every host-sourced allow (kubelet probes, apiserver
  aggregation/webhooks) uses `ipBlock: {cidr: 0.0.0.0/0, except: [169.254.0.0/16]}`
  scoped tight by port + podSelector — byte-for-byte the proven live convention
  (`observability/allow-kubelet-probes`, `cert-manager/allow-api-to-webhook`).
  A node-public-IP `/32` would **silently drop** that traffic. Defense-in-depth is
  the per-listener TLS/mTLS on each port.
- Every allow rule was traced to a live pod label + real containerPort/probe port
  by an adversarial verifier. `local-path-provisioner` and `snapshot-controller`
  (kube-system) have no ports/probes and are covered by default-deny with no allow.

## Apply order (safest → riskiest)

Apply **one namespace at a time**, verify, then proceed. Order matters:

1. **`topolvm-system`** — lowest risk (ingress-only, sole ingress is kubelet probes, no cross-ns consumers).
2. **`istio-system`** — low risk (control plane is dormant; zero meshed namespaces today).
3. **`kube-system`** — **LAST and most careful** (its CoreDNS `:53` allow keeps *every other namespace's* DNS alive). Two-step: allows first, confirm, then default-deny.

> Each namespace currently has zero netpols, so **rollback for any of them is just
> deleting the policies** (reverts to fully-open ingress). NetworkPolicy delete is
> instant and stateless.

---

## 1. topolvm-system

```bash
scp platform/manifests/system-netpol/topolvm-system.yaml secforge:/tmp/   # or apply from a checkout on the host
ssh secforge 'sudo k3s kubectl apply -f /tmp/topolvm-system.yaml'
```
Verify (wait ~70s — controller liveness period is 60s):
```bash
ssh secforge 'sudo k3s kubectl get pods -n topolvm-system -o wide'        # all stay Ready, NO new restarts
ssh secforge 'sudo k3s kubectl get netpol -n topolvm-system'              # 2 policies
```
Rollback: `ssh secforge 'sudo k3s kubectl delete netpol -n topolvm-system default-deny-ingress allow-kubelet-probes'`

## 2. istio-system

```bash
ssh secforge 'sudo k3s kubectl apply -f /tmp/istio-system.yaml'           # single apply = one batch (allows + deny together)
```
Verify (istiod readiness period is 3s — watch ~30s):
```bash
ssh secforge 'sudo k3s kubectl get pods -n istio-system -o wide'          # all 3 stay 1/1 Running
ssh secforge 'sudo k3s kubectl get endpoints istiod -n istio-system'      # still lists the istiod pod with 15017/15012/15010
ssh secforge 'sudo k3s kubectl logs -n istio-system ds/ztunnel --tail=20' # no repeated CA/XDS connection-refused
```
Rollback: `ssh secforge 'sudo k3s kubectl delete netpol -n istio-system -l secforge.platform/component=istio'`

## 3. kube-system — DNS-critical, two-step

**Step 3a — apply the ALLOWS first and confirm they exist:**
```bash
ssh secforge 'sudo k3s kubectl apply -f /tmp/kube-system-allows.yaml'
ssh secforge 'sudo k3s kubectl get netpol -n kube-system'   # MUST list all 4 allow policies before continuing
```

**Step 3b — only then apply default-deny:**
```bash
ssh secforge 'sudo k3s kubectl apply -f /tmp/kube-system-default-deny.yaml'
```

**Step 3c — verify IMMEDIATELY (the landmine check):**
```bash
# DNS resolves cluster-wide:
ssh secforge 'sudo k3s kubectl run dnscheck --image=busybox:1.36 --restart=Never --rm -i --command -- nslookup kubernetes.default.svc.cluster.local'
# CoreDNS + metrics-server healthy, no new restarts:
ssh secforge 'sudo k3s kubectl get pods -n kube-system -o wide'
# metrics-server aggregation still works (proves apiserver -> pod:10250 via cni0):
ssh secforge 'sudo k3s kubectl top nodes'
ssh secforge 'sudo k3s kubectl get apiservice v1beta1.metrics.k8s.io -o jsonpath="{.status.conditions[?(@.type==\"Available\")].status}{\"\n\"}"'  # True
```
Confirm in Grafana/Prometheus that the `kps-coredns` scrape target is **UP** (the `:9153` metrics path).

**Instant rollback (if DNS regresses — do this FIRST, investigate after):**
```bash
ssh secforge 'sudo k3s kubectl delete netpol -n kube-system default-deny-ingress'
# full revert:
ssh secforge 'sudo k3s kubectl delete netpol -n kube-system allow-dns-from-all-pods allow-prometheus-to-coredns-metrics allow-kubelet-probes-coredns allow-host-to-metrics-server'
```

---

## Wiring into the platform (steady state)

These are applied via this runbook (operator-gated) for the first, validated rollout.
**Auto-wiring into the bootstrap is intentionally deferred** — an unattended re-run that
applied `kube-system` default-deny without the ordering/verification above could
black-hole cluster DNS. Once the manual apply is validated, wire each file into the
owning component's apply step (kube-system into early k3s hardening, istio into the
istio component, topolvm into the topolvm component), keeping the kube-system
allows-before-deny ordering.

## Last applied

Not yet applied. Record date + the post-apply DNS/probe/scrape evidence per namespace
here on first rollout. Re-walk quarterly per the runbooks README.
