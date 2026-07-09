# Phase 2 — Multi-tenancy & Isolation

Phase 1 proved one app can be built, GitOps-deployed, and monitored end to
end. Phase 2 proves the platform can host **two mutually-isolated tenants**
on the same cluster — the actual hard technical claim of "multi-tenant
platform." Everything here is applied via GitOps (ArgoCD), same as Phase 1.
No `kubectl apply` on tenant resources directly.

## What changed

- `deployaz-demo` (your existing, live namespace) is now **tenant-a** in
  place. It was not renamed or recreated — same namespace, same running
  pods. I added isolation manifests (`resourcequota.yaml`, `limitrange.yaml`,
  `networkpolicy.yaml`, `rbac.yaml`) to `k8s/base/`, which ArgoCD already
  watches. Next sync applies them with no downtime.
- `k8s/tenants/tenant-b/` is a **new, second, synthetic tenant** — same
  container image as tenant-a (this is deliberate: the point is proving the
  *platform's* isolation, not writing a second app), deployed into its own
  namespace `deployaz-tenant-b` with its own quota, limits, network policy,
  and RBAC.
- `gitops/tenant-b-application.yaml` — new ArgoCD `Application` pointing at
  `k8s/tenants/tenant-b`, same `selfHeal`/`prune` pattern as tenant-a.
- `.github/workflows/ci-cd.yml` was **changed**: the image-tag bump now
  patches both `k8s/base/deployment.yaml` and
  `k8s/tenants/tenant-b/deployment.yaml`. If this hadn't been changed,
  tenant-b would have silently stopped receiving image updates after this
  point — an easy way to end up demoing a stale tenant without noticing.

## Apply steps

1. Merge these files into your repo (see integration commands in the chat).
2. Push to `main`.
3. ArgoCD picks up the new `Application` for tenant-b automatically if
   app-of-apps / auto-discovery is on; otherwise:
   ```
   kubectl apply -f gitops/tenant-b-application.yaml
   ```
4. Watch both apps sync:
   ```
   kubectl get applications -n argocd
   kubectl get pods -n deployaz-demo
   kubectl get pods -n deployaz-tenant-b
   ```
5. Install kube-prometheus-stack ServiceMonitor for tenant-b (already
   applied via GitOps if `monitoring/` is in ArgoCD's watched path — check
   your Application `path` covers it, or add it explicitly).

## Proving isolation (don't skip this — a manifest that "looks right" is not the same as isolation that works)

### 1. RBAC boundary
Tenant A's service account should have zero visibility into tenant B's namespace:
```
kubectl auth can-i list pods -n deployaz-tenant-b --as=system:serviceaccount:deployaz-demo:tenant-a-sa
```
Expected: `no`. If this returns `yes`, the Role/RoleBinding scoping is broken.

### 2. Network boundary
Exec into a tenant-a pod and try to reach tenant-b's service:
```
kubectl exec -n deployaz-demo deploy/deployaz-demo -it -- curl -m 3 http://deployaz-tenant-b.deployaz-tenant-b.svc.cluster.local
```
Expected: timeout / connection refused (blocked by `default-deny-all` +
the fact that tenant-b's allow-ingress rule only permits traffic from the
ingress-nginx namespace, not from tenant-a). If this succeeds, the
NetworkPolicy isn't being enforced — check that your CNI actually supports
NetworkPolicy (kind's default CNI does not; you need Calico or a
NetworkPolicy-capable CNI installed, or this test will falsely "pass" by
allowing everything).

### 3. Resource quota enforcement
Try to scale tenant-b past its quota:
```
kubectl scale deployment/deployaz-tenant-b -n deployaz-tenant-b --replicas=20
kubectl get events -n deployaz-tenant-b --field-selector reason=FailedCreate
```
Expected: new pods beyond the quota's `pods: "10"` (or CPU/memory ceiling,
whichever hits first) are rejected with a quota-exceeded event, not
silently pending forever.

### 4. Ingress still works per-tenant
```
curl http://demo.deployaz.local/api/hello
curl http://tenant-b.deployaz.local/api/hello
```
Both should respond independently. If one breaks when the other is
deployed, your ingress or service selectors are colliding.

## What Phase 2 deliberately does NOT include yet
- TLS/cert-manager — genuinely needs a public domain and internet-reachable
  cluster; doing this against a local kind/minikube cluster with no public
  IP wouldn't test anything real, it would just be theater. Revisit when
  you move to a cloud cluster.
- Secrets management (Vault/sealed-secrets) — Phase 3.
- Image scanning / policy enforcement (Trivy/Kyverno) — Phase 3.
- Self-service onboarding — Phase 4.

## Honest caveat
I don't have a live Kubernetes cluster or ArgoCD instance in my sandbox —
I validated the YAML structurally (see below) but could not run the four
isolation tests above against a real cluster. You are the first real
`kubectl apply`. If NetworkPolicy enforcement "passes" trivially (traffic
gets through when it shouldn't), the most common cause is the CNI not
supporting NetworkPolicy at all — check that before assuming the policy
YAML is wrong.
