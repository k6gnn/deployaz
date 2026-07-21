# Phase 2 — Multi-tenancy & Isolation

Phase 1 proved one app can be built, GitOps-deployed, and monitored end to
end. Phase 2 proves the platform can host **two mutually-isolated tenants**
on the same cluster — the actual hard technical claim of "multi-tenant
platform." Everything here is applied via GitOps (ArgoCD), same as Phase 1.
No `kubectl apply` on tenant resources directly.

## What changed

- `deployaz-demo` (the existing, live namespace) is now **tenant-a** in
  place. It was not renamed or recreated — same namespace, same running
  pods. Isolation manifests (`resourcequota.yaml`, `limitrange.yaml`,
  `networkpolicy.yaml`, `rbac.yaml`) were added to `k8s/base/`, which
  ArgoCD already watches. Next sync applies them with no downtime.
- `k8s/tenants/tenant-b/` is a **new, second, synthetic tenant** — same
  container image as tenant-a (deliberate: the point is proving the
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

1. Merge these files into the repo and push to `main`.
2. ArgoCD picks up the new `Application` for tenant-b automatically if
   app-of-apps / auto-discovery is on; otherwise:
   ```
   kubectl apply -f gitops/tenant-b-application.yaml
   ```
3. Watch both apps sync:
   ```
   kubectl get applications -n argocd
   kubectl get pods -n deployaz-demo
   kubectl get pods -n deployaz-tenant-b
   ```

## Proving isolation (don't skip this — a manifest that "looks right" is not the same as isolation that works)

### 1. RBAC boundary
Tenant A's service account should have zero visibility into tenant B's
namespace:
```
kubectl auth can-i list pods -n deployaz-tenant-b \
  --as=system:serviceaccount:deployaz-demo:tenant-a-sa
```
Expected: `no`. If this returns `yes`, the Role/RoleBinding scoping is
broken.

### 2. Network boundary
Reach tenant-b's service from inside a tenant-a pod. The app image has no
curl, so use an ephemeral debug container:
```
POD=$(kubectl get pods -n deployaz-demo -l app=deployaz-demo -o jsonpath='{.items[0].metadata.name}')
kubectl debug -n deployaz-demo -it "$POD" --image=nicolaka/netshoot \
  --target=deployaz-demo -- \
  curl -m 3 http://deployaz-tenant-b.deployaz-tenant-b.svc.cluster.local
```
Expected: timeout (blocked by `default-deny-all` + tenant-b's allow rule
permitting only the ingress-nginx and monitoring namespaces). If this
succeeds, the NetworkPolicy isn't being enforced — check that the CNI
actually supports NetworkPolicy (kind's default CNI does not; a
policy-capable CNI is required, or this test falsely "passes" by allowing
everything). Before trusting a timeout, confirm tenant-b's pod is
`1/1 Running` and its Service has a populated endpoint — otherwise the
timeout could just mean tenant-b is down, not that isolation works.

### 3. Resource quota enforcement
Try to scale tenant-b past its quota:
```
kubectl scale deployment/deployaz-tenant-b -n deployaz-tenant-b --replicas=20
kubectl get events -n deployaz-tenant-b --field-selector reason=FailedCreate
```
Expected: pods beyond the quota ceiling are rejected with a
quota-exceeded event, not silently pending forever. Scale back afterwards.

### 4. Ingress still works per-tenant
```
curl http://demo.deployaz.local/api/hello
curl http://tenant-b.deployaz.local/api/hello
```
Both should respond independently. If one breaks when the other is
deployed, ingress or service selectors are colliding.

## Verification record (honest)

All four tests above were run against the real cluster during Phase 2:
- Network isolation: confirmed with real evidence — timeout against a
  live, reachable tenant-b pod (ruling out the false-negative case).
- RBAC, quota, ingress: confirmed by the operator at the time; the RBAC
  `auth can-i` output specifically was never pasted back, so if a client
  account is ever able to touch another tenant's resources, re-check that
  one first.
- Known Phase 2 gap found later (fixed in Phase 3): neither Deployment
  originally set `serviceAccountName`, so pods ran as the default SA even
  though the tenant SAs' RBAC was correctly scoped. Fixed when Vault auth
  required real SA attachment.
