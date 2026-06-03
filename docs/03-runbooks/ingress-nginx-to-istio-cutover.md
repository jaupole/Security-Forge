# Cutover: ingress-nginx → Istio gateway (the `:80/:443` hand-off)

> One-time migration of a **live** cluster from ingress-nginx to the Istio
> gateway (06a). On a single node both want hostPort `:80/:443`, so the cutover
> is a deliberate, reversible hand-off. See ADR-0032. Learned the hard way —
> follow the order exactly.

## Pre-requisites
- Gateway already running **alongside** nginx on alt ports: deploy 06a with
  `GATEWAY_HOSTPORT_HTTP=8080 GATEWAY_HOSTPORT_HTTPS=8443`.
- Every host validated on `:8443` (routing, backend-TLS, rewrites). Note: the
  per-host `AuthorizationPolicy` is **inert on `:8443`** because it matches the
  `:authority` (which includes the port); it enforces on `:443` — confirm by
  temporarily adding the `:8443` host variant and watching the deny fire.

## ⚠ Three traps (all cost real outage time)
1. **Test externally, never node-local.** This node cannot hairpin to its own
   public IP on a hostPort — `curl <node-public-ip>:443` from the node returns
   `000` even when the edge is fine. Validate from a separate host.
2. **Don't `--grace-period=0 --force` the nginx pod.** Force-delete skips the
   CNI teardown and **orphans the portmap DNAT** (`CNI-DN-<hash>` → dead pod IP);
   iptables first-match then black-holes `:443`. Instead, shorten the grace
   period so graceful termination is fast AND the CNI cleans up.
3. **nginx `terminationGracePeriodSeconds=300`** (+ `/wait-shutdown` preStop)
   holds `:80/:443` for 5 min → the gateway gets `FailedScheduling: didn't have
   free ports`. Shorten it first.

## Cutover
```bash
NS_GW=istio-ingress; NS_NX=ingress-nginx; PUB=<node-public-ip>
# 1. make nginx terminate fast (so the port frees AND the CNI cleans up)
kubectl -n $NS_NX patch deploy ingress-nginx-controller --type=strategic \
  -p '{"spec":{"template":{"spec":{"terminationGracePeriodSeconds":10}}}}'
kubectl -n $NS_NX rollout status deploy/ingress-nginx-controller --timeout=120s

# 2. free :80/:443 (graceful — NOT force)
kubectl -n $NS_NX scale deploy ingress-nginx-controller --replicas=0
kubectl -n $NS_NX wait --for=delete pod -l app.kubernetes.io/name=ingress-nginx --timeout=60s

# 3. flip the gateway onto :80/:443 (single patch)
kubectl -n $NS_GW patch deploy istio-ingress --type=strategic -p \
 '{"spec":{"template":{"spec":{"containers":[{"name":"istio-proxy","ports":[{"name":"http","containerPort":80,"hostPort":80,"protocol":"TCP"},{"name":"https","containerPort":443,"hostPort":443,"protocol":"TCP"}]}]}}}}'
kubectl -n $NS_GW rollout status deploy/istio-ingress --timeout=150s

# 4. VERIFY exactly one :443 DNAT (to the live gateway pod). If a stale
#    CNI-DN chain to a dead pod remains, flush it:
GWIP=$(kubectl -n $NS_GW get pod --field-selector=status.phase=Running \
  -o jsonpath='{.items[0].status.podIP}')
sudo iptables-save -t nat | grep 'dport 443 -j DNAT'        # expect only ->$GWIP
#   to clean a stale chain CNI-DN-XXXX pointing at a dead IP:
#   sudo iptables -t nat -F CNI-DN-XXXX     # flush its rules (DNAT to dead pod)

# 5. validate EXTERNALLY (real allow/deny matrix)
hit(){ curl -sk --resolve $1:443:$PUB https://$1$2 -o /dev/null -w '%{http_code}\n'; }
hit members.secforge.dev /        # 200  (public)
hit grafana.secforge.dev /        # 403  (tailnet, from off-tailnet client)
hit auth.secforge.dev /admin/     # 403  (admin path tailnet-only)
hit portal.secforge.dev /api/v1/admin/x   # 403 (deny-list)
```

## Rollback (fast, reversible)
```bash
kubectl -n $NS_GW patch deploy istio-ingress --type=strategic -p \
 '{"spec":{"template":{"spec":{"containers":[{"name":"istio-proxy","ports":[{"name":"http","containerPort":80,"hostPort":8080},{"name":"https","containerPort":443,"hostPort":8443}]}]}}}}'
kubectl -n $NS_NX scale deploy ingress-nginx-controller --replicas=1
# then re-check `sudo iptables-save -t nat | grep 'dport 443 -j DNAT'` is the nginx pod only.
```

## After cutover
- nginx stays scaled to 0 through the stability window (rollback safety).
- Decommission (helm-uninstall nginx, remove the Ingresses/certs/etc.) only
  after several days stable — see ADR-0032's decommission inventory.
