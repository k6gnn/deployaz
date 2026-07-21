# Phase 4 — Self-Service Onboarding + Centralized Logs

Phases 1-3 proved the platform can run, isolate, and secure tenants that
were hand-written into the repo. Phase 4 removes the hands: a repo URL goes
in, a deployed, isolated, log-shipping app comes out, with zero manual
Kubernetes steps.

## Honest scope statement, before anything else

- This proves the **automation** end-to-end on the local kind cluster. It
  does NOT make the free tier publicly available to strangers -- that
  requires a cloud cluster, a real domain, and cert-manager TLS, which is
  its own future phase with real monthly cost. Do not claim "public free
  tier live" anywhere until that is true.
- Onboarding is triggered by the operator running a workflow (with the
  tenant's repo URL), not yet by tenants themselves through a public form.
  The entire pipeline after the trigger is zero-touch; the trigger itself
  is operator-gated on purpose while the cluster is a laptop.
- Tenant apps get automatic **logs** (Promtail scrapes every pod -- no
  tenant integration needed) but not automatic **metrics** (that requires
  the app to expose a Prometheus endpoint; it becomes a tenant config
  option later). Uptime is still visible via kube-state pod metrics.
- Vault integration is NOT part of generic tenant onboarding yet. Tenants
  that need secrets are a manual Vault policy + role step -- documented
  future work, not silently missing.

## Architecture

```
operator runs "Onboard tenant" workflow (tenant_name, repo_url, port)
        |
        v
GitHub-hosted runner (ephemeral VM -- untrusted code never touches cluster)
  1. validate inputs, refuse duplicates/reserved names
  2. clone tenant repo, no credentials, shallow
  3. docker build (no registry token present during build)
  4. Trivy scan, CRITICAL/HIGH -> hard stop, nothing pushed
  5. GHCR login + push  ghcr.io/k6gnn/deployaz-tenant-<name>:<sha>
  6. commit tenants/<name>/config.json  <-- this commit IS the deploy
        |
        v
ArgoCD ApplicationSet (git file generator on tenants/*/config.json)
  -> instantiates charts/tenant with that tenant's values
  -> Namespace + RBAC + ResourceQuota + LimitRange + NetworkPolicies
     + Deployment + Service + Ingress, all stamped automatically
        |
        v
Gatekeeper re-checks scan annotations at admission (second, independent gate)
Promtail ships the pods' logs to Loki -> visible in Grafana
```

## One-time setup

### 1. Apply the updated Gatekeeper constraint (label-based now)
```bash
kubectl apply -f k8s/gatekeeper/constraint-trivy-scan.yaml
```
Why this changed: the old constraint listed namespaces by name, so every
auto-created tenant namespace would have bypassed the unscanned-image gate.
It now selects any namespace labeled `deployaz.io/tenant-workloads: "true"`.
ArgoCD will sync the same label onto the two existing namespaces.

Verify the gate still bites (this is Phase 3's test, repeated because the
match mechanism changed -- a policy that changed how it matches is an
unverified policy until re-proven):
```bash
kubectl -n deployaz-demo patch deployment deployaz-demo --type=json \
  -p='[{"op":"replace","path":"/spec/template/metadata/annotations/security.deployaz.io~1trivy-scan-passed","value":"false"}]'
```
Expected: denied by Gatekeeper with the violation message. If it goes
through, the label isn't on the namespace yet -- stop and fix before
onboarding anyone.

### 2. Apply the ApplicationSet
```bash
kubectl apply -f gitops/tenant-applicationset.yaml
kubectl get applicationsets -n argocd
```

### 3. Install Loki + Promtail
```bash
helm repo add grafana https://grafana.github.io/helm-charts
helm repo update
helm install loki grafana/loki-stack -n logging --create-namespace \
  -f k8s/logging/loki-values.yaml
kubectl get pods -n logging   # loki-0 Running + one promtail per node
```
Add Loki as a Grafana datasource (Grafana from Phase 1):
Connections -> Data sources -> Add -> Loki ->
URL `http://loki.logging.svc.cluster.local:3100` -> Save & test.

## Onboarding a tenant (the actual Phase 4 proof)

Use a real public repo with a Dockerfile -- ideally NOT this repo's own app,
because the point is a *stranger's* code shape. A minimal test tenant repo
(any small HTTP app + Dockerfile) is fine.

1. GitHub -> Actions -> "Onboard tenant" -> Run workflow:
   - tenant_name: e.g. `acme`
   - repo_url: the tenant's public repo
   - app_port: whatever the app listens on
2. Watch the run. Failure modes that are FEATURES, not bugs:
   - no Dockerfile -> refused
   - CRITICAL/HIGH CVEs -> refused, nothing pushed
   - duplicate/reserved name -> refused
3. On success, the workflow committed `tenants/acme/config.json`. Now watch
   provisioning happen with no human action:
```bash
kubectl get applications -n argocd          # tenant-acme appears
kubectl get ns deployaz-acme --show-labels  # has deployaz.io/tenant-workloads=true
kubectl get all,resourcequota,networkpolicy,sa -n deployaz-acme
```
4. Add `127.0.0.1 acme.deployaz.local` to hosts, then:
```bash
curl http://acme.deployaz.local/
```

## Verifying the claims (do not skip)

### Isolation applies to auto-created tenants too
Every Phase 2 test, against the NEW namespace -- automation that skips
isolation is worse than no automation:
```bash
kubectl auth can-i list pods -n deployaz-tenant-b \
  --as=system:serviceaccount:deployaz-acme:tenant-acme-sa     # expect: no
POD=$(kubectl get pods -n deployaz-demo -l app=deployaz-demo -o jsonpath='{.items[0].metadata.name}')
kubectl debug -n deployaz-demo -it "$POD" --image=nicolaka/netshoot \
  --target=deployaz-demo -- curl -m 3 http://acme.deployaz-acme.svc.cluster.local  # expect: timeout
kubectl scale deployment/acme -n deployaz-acme --replicas=20
kubectl get events -n deployaz-acme --field-selector reason=FailedCreate  # expect: quota rejection
```

### The scan gate cannot be bypassed by onboarding
Onboard (or attempt to) a repo whose image has known CRITICAL CVEs (e.g. a
Dockerfile `FROM` an old, unpatched base). Expected: Trivy step fails, no
image pushed, no config.json committed, no namespace created. If any of
those three happened anyway, the gate is broken -- stop.

### Logs flow with zero tenant integration
Grafana -> Explore -> Loki datasource:
```
{namespace="deployaz-acme"}
```
Expected: the tenant app's stdout, live, without the tenant having done
anything logging-related.

### Teardown is also self-service
Delete `tenants/acme/` from the repo, push. Expected: ArgoCD prunes the
Application and the entire namespace disappears. If resources linger,
prune/ownership is misconfigured -- fix before claiming "self-service."

## Known limitations (stated, not hidden)
- No automatic rebuild on tenant repo changes: updating a tenant currently
  means delete + re-onboard. A webhook/GitHub-App trigger is the future fix.
- Public repos only, Dockerfile required. Buildpacks (no-Dockerfile UX) and
  private-repo support are future work.
- Scan-annotation trust model unchanged from Phase 3 (cosign signing is
  still the documented hardening step).
- TCP-only health probes for tenant apps (no universal HTTP path exists).
- Operator-triggered onboarding; public self-serve UI needs the cloud
  migration first.
