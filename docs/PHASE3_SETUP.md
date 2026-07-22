# Phase 3 — Secrets Management & Image Security

Phase 2 proved two tenants can be isolated from each other. Phase 3 proves
the platform can handle something every real client will eventually need:
a secret (DB password, API key) that must never sit in Git as plaintext,
and a supply-chain gate that blocks a vulnerable image before it ever runs.

Three independent pieces, each with its own honest limitations noted below.

## 1. Vault (secrets management)

**What this is:** HashiCorp Vault in **dev mode** (in-memory, auto-unsealed,
fixed root token `"root"`) plus the Vault Agent Injector. This proves the
*pattern* — no plaintext secret in Git, secret lands in the pod as an
injected file, RBAC-equivalent scoping per tenant — not a production-grade
Vault install. See the warning at the top of `k8s/vault/vault-values.yaml`
for exactly what would need to change for real production use (real storage
backend, cloud KMS auto-unseal, TLS, root token rotation).

### Install
```bash
kubectl apply -f k8s/vault/namespace.yaml
helm repo add hashicorp https://helm.releases.hashicorp.com
helm repo update
helm install vault hashicorp/vault -n vault -f k8s/vault/vault-values.yaml
kubectl get pods -n vault -w   # wait for vault-0 to be Running (dev mode, no manual unseal needed)
```

### One-time configuration (run once, from your terminal — never from CI)
```bash
bash k8s/vault/vault-setup.sh
```
This enables Kubernetes auth, writes the synthetic `db_password` secret,
and binds `tenant-a-sa` to a policy that can read **only**
`secret/data/deployaz-demo/db`. `tenant-b-sa` is deliberately left unbound —
that absence is itself part of the isolation proof.

### Deploy the app changes
Merge `phase3-vault-security.patch` (already applied and build-verified),
push to `main`. ArgoCD syncs `k8s/base/deployment.yaml` — tenant-a's pod
gets the Vault Agent Injector's init container + sidecar, mounts the secret
at `/vault/secrets/db-password`, and `SecretStartupCheck` fails the app's
startup if it's missing (fail-fast, not a runtime check bolted on after).

### Verify (don't just trust that it "looks right")

**a. The secret is genuinely not in Git:**
```bash
git grep -i "dev-only-synthetic-value" -- ':!docs' ':!k8s/vault/vault-setup.sh'
```
Expect: no output (the only place that value appears is the one-time script
you ran locally, which is fine — that script itself isn't a secret, it just
*writes* one at runtime).

**b. The secret genuinely landed in the pod:**
```bash
kubectl exec -n deployaz-demo deploy/deployaz-demo -c deployaz-demo -- \
  cat /vault/secrets/db-password
```
Expect: the synthetic value. This is the manual, infra-side proof —
no app code involved.

**c. tenant-a's pod is actually Ready** (proves `SecretStartupCheck` passed;
if the secret were missing, the pod would never reach `Running`/`Ready`):
```bash
kubectl get pods -n deployaz-demo
```

**d. tenant-b has no access to tenant-a's secret** (isolation, not just
absence):
```bash
kubectl exec -n vault vault-0 -- sh -c \
  "VAULT_TOKEN=root vault read auth/kubernetes/role/tenant-a-role"
```
Confirm `bound_service_account_names` lists only `tenant-a-sa` — `tenant-b-sa`
should never appear here.

**e. The health indicator is visible only internally, on the management
port, not externally:**
```bash
kubectl exec -n deployaz-demo deploy/deployaz-demo -c deployaz-demo -- \
  curl -s http://localhost:8081/actuator/health
```
Should show `"dbPassword"`-related detail with `"configured": true,
"required": true` — but note this only works via `kubectl exec` *inside*
the pod's network namespace. Confirm it's actually blocked from outside:
```bash
curl -m 3 http://demo.deployaz.local:8081/actuator/health
```
Expect: connection refused / timeout (ingress doesn't route to 8081, and the
NetworkPolicy only allows the `monitoring` namespace and nginx in on that
port).

## 2. CI supply-chain gates (gitleaks + Trivy)

- **`secret-scan` job** (gitleaks) — runs first, on every push and PR,
  against full git history. Fails the pipeline if a secret is ever
  committed, before any build step runs.
- **`build-scan-push` job** — builds the image **locally only** first
  (`load: true`, not pushed), scans it with Trivy for CRITICAL/HIGH CVEs,
  and only pushes to GHCR + bumps the GitOps manifests if the scan passes.
  A failed scan means the image never reaches the registry and the
  manifests are never touched — tenant pods keep running the last known
  good image.
- On success, CI now stamps `security.deployaz.io/trivy-scan-passed: "true"`
  and `security.deployaz.io/scanned-sha` onto both deployment manifests —
  this is what Gatekeeper checks below.

### Verify
Push a small change, watch the Actions tab: `secret-scan` → `test` →
`build-scan-push` (with the Trivy step visible in the logs, listing 0
CRITICAL/HIGH or failing the job if it finds any).

To prove the *failure* path works (don't skip this — a gate that's never
seen a real failure hasn't been proven): temporarily point the Dockerfile's
base image at an old, known-vulnerable tag (e.g.
`eclipse-temurin:11-jre-alpine` pinned to an old digest), push, confirm the
job fails at the Trivy step and nothing gets pushed to GHCR. Then revert.

## 3. Gatekeeper (admission-time policy)

**What this is, honestly:** `K8sRequireTrivyScan` blocks any Deployment in
`deployaz-demo` or `deployaz-tenant-b` that lacks a matching
`trivy-scan-passed`/`scanned-sha` annotation pair. This is a **policy
signal CI asserts, not a cryptographic attestation** — see the limitation
note at the top of `constrainttemplate-trivy-scan.yaml`. It's real
defense-in-depth (stops a hand-edited or manually-pushed Deployment from
ever running), but the honest upgrade path beyond this phase is image
signing (cosign) verified directly against the registry, not trusting an
annotation.

### Install
```bash
helm repo add gatekeeper https://open-policy-agent.github.io/gatekeeper/charts
helm repo update
helm install gatekeeper gatekeeper/gatekeeper -n gatekeeper-system --create-namespace
kubectl apply -f k8s/gatekeeper/constrainttemplate-trivy-scan.yaml
kubectl apply -f k8s/gatekeeper/constraint-trivy-scan.yaml
```

### Verify — prove it actually blocks, not just reports
```bash
kubectl get deployment deployaz-demo -n deployaz-demo -o yaml > /tmp/test-deploy.yaml
# Edit /tmp/test-deploy.yaml: change spec.template.metadata.annotations
# "security.deployaz.io/trivy-scan-passed" to "false"
kubectl apply -f /tmp/test-deploy.yaml
```
Expect: the `apiserver` rejects the change outright with an admission
webhook denial message quoting the Rego policy's `msg` string — not a
successful apply that Kubernetes later reconciles away. If it applies
successfully, the constraint isn't being enforced (check
`kubectl get constrainttemplates` and `kubectl get k8srequiretrivyscan` for
errors first).

## Known Phase 3 gap, found in Phase 4 (fixed)

The `default-deny-all` NetworkPolicy in deployaz-demo denies **Egress**,
and the only egress allow rule was DNS (port 53). Phase 3 wired the Vault
Agent into tenant-a's pods but never opened a network path to Vault on
port 8200 -- so this phase's own headline feature had no legal route to its
backend. Init-container secret fetches only ever succeeded through a CNI
policy-enforcement race at pod startup, and the sidecar's token renewals
were silently timing out for the entire life of the deployment. Nothing in
this phase's verification steps caught it, because they all test the
*startup* path, not the *renewal* path. It was found within hours of
centralized logging being installed in Phase 4 (the sidecar's errors were
finally visible) and fixed by `k8s/base/networkpolicy-vault-egress.yaml`.
Lesson kept for the record: when a workload gains a new network dependency,
the NetworkPolicy change is part of the feature, and verification must
cover steady-state behavior, not just first boot. Full incident write-up:
`docs/OPERATIONS.md`.

## What Phase 3 deliberately does not include

- Self-service onboarding (Phase 4).
- Cosign image signing (documented above as the real next hardening step
  past annotation-based policy).
- Production Vault (real storage backend, auto-unseal, TLS) — dev mode only,
  as stated repeatedly above so it doesn't get missed.
