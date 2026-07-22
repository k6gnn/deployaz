# Phase 4.5 — Tenant Consolidation (pre-cloud hardening, part 1 of 3)

Phases 1-4 left the repo maintaining THREE implementations of "a tenant":
hand-written `k8s/base/` (the demo app), hand-written `k8s/tenants/tenant-b/`,
and the Phase 4 Helm chart. CI `sed`-patched two of them; the third went
through the ApplicationSet. Migrating three shapes to a cloud cluster means
debugging three shapes on new infrastructure. This phase collapses everything
onto one shape: every tenant -- including the platform's own demo app -- is a
`tenants/<name>/config.json` registry entry rendered through `charts/tenant`.

## Findings that made this phase non-optional

1. **Egress regression (security).** The hand-written tenants deny egress by
   default (DNS-only, Phase 2 posture). The Phase 4 chart only denied
   INGRESS -- every onboarded tenant had unrestricted egress. A free-tier
   stranger's container could reach anywhere. Fixed: the chart now enforces
   default-deny Ingress+Egress, DNS allowed, Vault egress only when
   `vault.enabled`, monitoring ingress only when `metrics.enabled` and only
   on the metrics port. **This changes runtime behavior for the `sample`
   tenant** -- its egress gets cut on sync. Verified below.
2. **Feature gap.** The chart had no HTTP probes, no metrics
   (ServiceMonitor/management port), no Vault support -- so the demo app
   physically could not move onto it. All three are now opt-in chart
   features (schema v2).
3. **Name collisions on cutover.** The old ArgoCD Applications manage the
   Namespace objects and NetworkPolicies with the same names the chart
   creates (`default-deny-all`, `allow-dns-egress`, and in demo's case
   `allow-egress-to-vault`). Two selfHeal-ing Applications contesting one
   object = tracking-annotation ping-pong. The cutover sequence below exists
   to avoid that: orphan first, adopt second, clean up third.

## Schema v2 -- the atomicity rule

The ApplicationSet renders with `missingkey=error` (deliberate: a malformed
registry entry fails loudly instead of deploying something half-configured).
Consequence: **every** `tenants/*/config.json` must contain **every** key the
template references. New keys: `healthPath`, `healthPort`, `metrics{enabled,
port,path}`, `vault{enabled,role,secretPath}`. Optional features are written
as `enabled: false`, never as an absent key.

**Therefore the entire consolidation -- chart changes, ApplicationSet
template, and all three config.json rewrites -- must land in ONE commit.**
Splitting it across commits leaves a window where every tenant Application
fails to render.

## What changed in the repo

- `charts/tenant/values.yaml` -- schema v2 (documented per-field)
- `charts/tenant/templates/deployment.yaml` -- optional HTTP probes, metrics
  annotations + management port, Vault agent-inject annotations,
  `DEPLOYAZ_SECRETS_REQUIRE` env for vault-enabled tenants
- `charts/tenant/templates/service.yaml` -- optional management port
- `charts/tenant/templates/servicemonitor.yaml` -- NEW, gated on metrics
- `charts/tenant/templates/networkpolicy.yaml` -- full Phase 2 posture
  (egress deny + DNS), port-restricted nginx/monitoring allowances, gated
  Vault egress
- `gitops/tenant-applicationset.yaml` -- passes schema v2; Applications now
  carry the `resources-finalizer` so future deletes cascade predictably
- `tenants/demo/config.json` -- NEW: the demo app as an ordinary tenant
  (replicas 2, HTTP probes on 8081, metrics, Vault)
- `tenants/tenant-b/config.json` -- NEW: tenant-b as an ordinary tenant
  (metrics, no Vault)
- `tenants/sample/config.json` -- migrated to schema v2, values unchanged
- `.github/workflows/ci-cd.yml` -- the `sed`-over-YAML step is gone; image
  bumps are now `jq` updates to the demo and tenant-b registry entries
- `.github/workflows/onboard-tenant.yml` -- writes schema v2
- `k8s/vault/vault-setup.sh` -- role/policy/SA renamed to the chart's
  generated names (`tenant-demo-sa`, `tenant-demo-role`,
  `tenant-demo-policy`); secret path unchanged

**Deleted** (in the same commit):
```
git rm -r k8s/base k8s/tenants
git rm gitops/argocd-application.yaml gitops/tenant-b-application.yaml
```

Naming consequences, stated: the Deployment/Service/Ingress in
`deployaz-demo` are now named `demo` (was `deployaz-demo`), the SA is
`tenant-demo-sa` (was `tenant-a-sa`); analogous for tenant-b. RBAC also
TIGHTENS: the old `tenant-*-namespace-admin` Role is replaced by the chart's
read-only Role -- deliberate, the admin role was broader than any tenant
needs.

## Cutover sequence (order matters -- collisions are why)

**Step 0 -- Preflight.** Run the full recovery checklist in
`docs/OPERATIONS.md`. Do not start on a cluster you haven't verified today.

**Step 1 -- Orphan the old Applications (non-cascading).** They have no
resources-finalizer, so a plain delete leaves all their resources running,
now unmanaged:
```bash
kubectl delete application deployaz-demo deployaz-tenant-b -n argocd
kubectl get application -n argocd    # only tenant-sample should remain
```
Old pods keep serving throughout. Nothing is down.

**Step 2 -- Push the consolidation commit.** One commit: all changed files
above, plus the `git rm` deletions. Note: this commit touches
`.github/workflows/ci-cd.yml`, which triggers CI -- it will build, scan,
push a fresh image and follow up with its own commit bumping the demo and
tenant-b registry entries to the new SHA. Expected, not a problem.

**Step 3 -- Apply the updated ApplicationSet:**
```bash
kubectl apply -f gitops/tenant-applicationset.yaml
kubectl logs -n argocd deploy/argocd-applicationset-controller --tail=20
```
Expect it to reconcile three Applications: `tenant-demo`,
`tenant-tenant-b`, `tenant-sample` (allow the ~3-minute git poll).

**Step 4 -- Rebind Vault BEFORE judging demo's pods.** The chart SA is
`tenant-demo-sa`; the existing Vault role binds the old `tenant-a-sa`, so
new demo pods will fail their Vault init until this runs:
```bash
bash k8s/vault/vault-setup.sh
kubectl delete pod -n deployaz-demo -l app=demo   # retry with the new role
```
The old role still exists, so the ORPHANED old pods keep renewing fine.

**Step 5 -- Watch adoption and rollout.**
```bash
kubectl get application -n argocd
kubectl get pods -n deployaz-demo        # old deployaz-demo-* AND new demo-* pods coexist
kubectl get pods -n deployaz-tenant-b
kubectl get pods -n deployaz-sample      # sample rolls too (new NetworkPolicies)
```
The same-named objects (Namespaces, default-deny-all, allow-dns-egress,
demo's allow-egress-to-vault) are ADOPTED by the new Applications via
ServerSideApply -- expected, not an error. Known transient: adoption
rewrites `allow-egress-to-vault`'s podSelector from `app: deployaz-demo` to
`app: demo`, so the OLD demo pods lose their Vault egress path until Step 6.
Their sidecar renewals have a 1h TTL -- harmless if you don't stall between
steps; this is exactly the silent-failure mode in OPERATIONS.md, so don't
stall.

**Step 6 -- Delete the orphans (one-time manual cleanup; the objects are
unmanaged, so kubectl is legitimate here).**
```bash
# deployaz-demo
kubectl delete -n deployaz-demo deploy/deployaz-demo svc/deployaz-demo \
  ingress/deployaz-demo servicemonitor/deployaz-demo \
  networkpolicy/allow-ingress-from-nginx networkpolicy/allow-ingress-from-monitoring \
  sa/tenant-a-sa role/tenant-a-namespace-admin \
  rolebinding/tenant-a-namespace-admin-binding \
  resourcequota/tenant-a-quota limitrange/tenant-a-limits
# deployaz-tenant-b
kubectl delete -n deployaz-tenant-b deploy/deployaz-tenant-b svc/deployaz-tenant-b \
  ingress/deployaz-tenant-b servicemonitor/deployaz-tenant-b \
  networkpolicy/allow-ingress-from-nginx networkpolicy/allow-ingress-from-monitoring \
  sa/tenant-b-sa role/tenant-b-namespace-admin \
  rolebinding/tenant-b-namespace-admin-binding \
  resourcequota/tenant-b-quota limitrange/tenant-b-limits
```
(Ingress overlap note: until this step, demo.deployaz.local is served by
both the old and new Ingress/Service pair -- nginx merges same-host rules,
both backends are healthy, users see no interruption.)

## Verification battery -- the phase is NOT done until all of these pass

1. **Serving:** `curl http://demo.deployaz.local/api/hello`,
   `curl http://tenant-b.deployaz.local/api/hello`, and the sample tenant's
   host all answer AFTER Step 6 (i.e. served purely by chart-managed
   resources).
2. **Vault, new pods:** `kubectl exec -n deployaz-demo deploy/demo -c app --
   cat /vault/secrets/db-password` returns the secret;
   `/actuator/health` reports the db-password indicator UP.
3. **RBAC isolation (Phase 2 standard, new SA names):**
   `kubectl auth can-i get pods -n deployaz-tenant-b
   --as=system:serviceaccount:deployaz-demo:tenant-demo-sa` -> **no**
   (and the reverse direction, and can-i within its own namespace -> yes).
4. **Egress deny actually bites (the regression fix):** from a sample pod,
   `wget -T 5 -qO- https://example.com` -> **fails**; DNS lookups still
   resolve; from a demo pod, Vault on 8200 is reachable but
   `wget -T 5 example.com` -> **fails**.
5. **Metrics:** Prometheus targets page shows the NEW ServiceMonitors
   (`demo`, `tenant-b`) UP; the old `deployaz-*` targets are gone.
6. **Logs:** Loki query `{namespace="deployaz-demo"}` shows the new pods'
   stdout.
7. **Gatekeeper still enforcing:** `kubectl -n deployaz-demo patch deploy
   demo --type=json -p '[{"op":"replace","path":"/spec/template/metadata/annotations/security.deployaz.io~1trivy-scan-passed","value":"false"}]'`
   -> **rejected by admission** (then no cleanup needed -- the patch never
   landed; if it somehow did, ArgoCD selfHeal reverts it).
8. **CI loop end-to-end on the new shape:** change the hello message, push,
   and watch: CI builds -> scans -> pushes -> jq-bumps BOTH registry
   entries -> ArgoCD rolls demo and tenant-b -> curl reflects the change.
   This is the Phase 1 loop test, re-proven against the consolidated shape.
9. **Onboarding still works:** re-run the offboard/onboard cycle for
   `sample` -- the workflow now writes schema v2; confirm the tenant comes
   up with TCP probes, no metrics, no Vault, and denied egress.

## Honest limitations after this phase
- Vault is still dev mode (part 2 of pre-cloud hardening).
- Gatekeeper still trusts CI-written annotations (part 3: cosign).
- Egress deny protects the network, not CPU -- crypto-mining inside quota
  limits is still possible; real abuse controls arrive with the cloud
  phase's AUP and monitoring alerts.
- Tenants needing egress to external APIs currently have no opt-in "open
  egress" path -- a deliberate omission until there's an AUP to attach it to.
