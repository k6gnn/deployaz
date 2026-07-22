# Operations — Known Issues & Recovery Runbook

Everything in this file was hit for real on this cluster. None of it is
hypothetical. The overall lesson is stated up front: a platform on Docker
Desktop + kind on a Windows laptop accumulates silent failures across
reboots. This is the operational case for the cloud migration phase.

## After ANY reboot or Docker Desktop restart — recovery checklist

Run through this in order before trusting the cluster:

1. **kubectl connectivity.** If `kubectl get nodes` refuses connection:
   - Check runtime port bindings, not just config:
     `docker port deployaz-control-plane` (must list 80, 443, 6443).
   - If bindings are missing: Windows winnat has very likely reserved the
     ports (ranges reshuffle each boot). Check with
     `netsh int ipv4 show excludedportrange protocol=tcp`.
   - Fix (admin PowerShell):
     `net stop winnat` → `docker restart deployaz-control-plane` → wait 90s
     → `net start winnat`.
   - The API server can be verified alive from inside regardless of host
     ports: `docker exec deployaz-control-plane curl -sk https://localhost:6443/healthz`.
2. **Zombie pods.** Pods showing `0/2 Unknown` after restarts are lost by
   the kubelet and never recover. `kubectl delete pod -n <ns> --all` and let
   the Deployment recreate them. Seen twice in one day on deployaz-demo.
3. **Vault (dev mode, in-memory).** Any Vault pod restart wipes ALL state.
   Additionally, apiserver restarts can invalidate the Kubernetes auth
   config even while Vault stays up (symptom: init containers get
   `403 permission denied` on /v1/auth/kubernetes/login). Either way the
   fix is the same: `bash k8s/vault/vault-setup.sh`, then delete the
   affected tenant pods.
4. **Port-forwards.** ArgoCD/Grafana UI access dies with the terminal
   session. Re-run:
   `kubectl port-forward svc/argocd-server -n argocd 8080:443`
   `kubectl port-forward svc/kube-prometheus-stack-grafana -n monitoring 3000:80`
5. **Health sweep before doing any work:**
   `kubectl get pods -A | grep -Ei "argocd|vault|gatekeeper|monitoring|ingress|logging|deployaz"`
   Treat abnormal RESTARTS counts as a finding, not noise — a controller
   that is Running is not necessarily working (see ApplicationSet CRD
   incident below).

## Known issues (with root causes)

### Windows winnat port exclusions break kind after reboots
Hyper-V/WSL reserves random TCP port ranges at each boot. If a range lands
on the kind API server's published port (or 80/443), Docker cannot rebind
it and kubectl gets "actively refused". Diagnosis and fix in the checklist
above. A permanent per-port exclusion
(`netsh int ipv4 add excludedportrange ...`) only works if run while the
port is unbound (stop winnat, add exclusion BEFORE the container rebinds,
then start winnat) — otherwise it fails with "file in use".

### ApplicationSet CRD was silently missing for 11 days
The ArgoCD install left out `applicationsets.argoproj.io`. Cause: the CRD
manifest exceeds the 256KB annotation limit of client-side
`kubectl apply`, so the apply fails — and nothing consumed the CRD, so the
only symptom was the applicationset-controller crash-looping every ~10
minutes (66 restarts) while everything user-facing stayed green.
Fix: `kubectl apply --server-side -f .../applicationset-crd.yaml`.
Rule adopted: install ArgoCD (and any large-CRD software) with
`--server-side`. Rule adopted: investigate outlier restart counts.

### Latent Phase 3 bug: no egress path from tenant-a to Vault
`default-deny-all` in deployaz-demo denies Egress, and the only egress
allow was DNS. The Vault agent therefore never had a legal route to Vault
:8200 — init fetches only ever succeeded through a CNI policy-enforcement
race at pod startup, and sidecar token renewals were silently timing out.
Found within hours of Loki being installed (the sidecar's error log was
visible in Grafana). Fixed by `k8s/base/networkpolicy-vault-egress.yaml`.
Lessons: (a) a green pod is not a healthy pod; (b) NetworkPolicy changes
require testing the *renewal* path, not just startup; (c) centralized
logging paid for itself on day one.

### Loki version clash (accepted limitation)
The deprecated `loki-stack` chart ships Loki 2.6.x. Modern Grafana's
datasource health check and log-volume histogram use LogQL syntax that old
Loki rejects ("parse error ... unexpected IDENTIFIER"). Actual log queries
work fine. Accepted for now; migrating to the current `grafana/loki` +
`grafana/promtail` charts is scheduled with the cloud migration, where
storage/retention get decided properly.

### Trivy gate rejected the first real tenant image (working as intended)
First onboarding attempt failed the scan: 1 CRITICAL + 4 HIGH CVEs — all
in npm's own bundled tooling inside `node:22-alpine`, not in the tenant's
code. Resolution: the tenant image removes npm/corepack/yarn from the
runtime layer (they are build-time tools). Kept here as the reference
answer for the most common onboarding failure.

### Dev-mode Vault
In-memory storage; all secrets, policies, and auth config are lost on any
restart, and k8s auth can break on apiserver restarts even without a Vault
restart. Production-grade Vault (persistent storage, auto-unseal, real
policies) is future work, documented since Phase 3.

---

## Phase 4.5 consolidation cutover -- incidents (2026-07-22)

Three real failures during the cutover, all diagnosed live. Recorded because
each one is a class of failure, not a one-off.

### Incident: kubectl rejected the ApplicationSet -- go-template braces are invalid YAML
`kubectl apply` failed with `invalid map key: {".port": nil}` on
`port: {{ .port }}`. kubectl parses the manifest as YAML BEFORE ArgoCD ever
sees the template, and an unquoted value starting with `{{` opens a YAML flow
mapping. Fix: quote every templated value in the ApplicationSet -- which
turns all values into strings post-render, so the chart now coerces types
itself (`| int` for numbers, `eq (toString x) "true"` for booleans). The
naive `{{- if .Values.x.enabled }}` is a trap: the STRING "false" is truthy
in Go templates. Lesson: in ApplicationSet templates, quoting and chart-side
type coercion are a package deal -- doing only the first silently inverts
every boolean gate.

### Incident: nginx admission webhook blocks same-host Ingress coexistence
The planned zero-downtime overlap (old + new Ingress on the same host,
nginx merges) does not survive the validating admission webhook: it rejects
any Ingress whose host+path already exists ("already defined in ingress
deployaz-demo/deployaz-demo"), so the new Application's sync failed
repeatedly until the old Ingress was deleted. Cost: a few seconds of
downtime per host at cutover. Lesson: "nginx merges duplicate hosts" is
dataplane behavior; the ADMISSION layer forbids creating the duplicate in
the first place. Any future migration that swaps Ingress objects for a live
host must sequence delete-old before sync-new and accept the gap, or use a
temporary secondary host.

### Incident: orphaned quota starved the new ReplicaSet, then backoff hid the recovery
The new demo pods (app + Vault sidecar, 320Mi/1CPU-limit each) could not be
created because the ORPHANED tenant-a-quota (1.5 CPU / 1Gi requests) was
still enforcing while the orphaned old pods consumed most of it --
FailedCreate, quota exceeded. After deleting the old quota, pods STILL did
not appear for several minutes: a ReplicaSet that failed creation enters
exponential backoff (up to ~5 min between retries), so the fix looked like
it hadn't worked. ArgoCD reported Degraded when the progress deadline
expired -- a symptom timestamp, not a cause. Lesson: two quotas can enforce
simultaneously in one namespace and the STRICTER one wins; and after fixing
any FailedCreate cause, either wait out backoff or `kubectl rollout restart`
to get a fresh ReplicaSet with a clean backoff slate. The RS events, not the
Deployment status, name the actual blocker.

### Observation: a stale ApplicationSet template renders plausible-looking wrong pods
Between the consolidation push and the hotfix apply, the OLD in-cluster
ApplicationSet (v1 template) picked up the new config files and rendered
demo with v1 fields only -- producing a Running, Ready, 1/1 pod with no
Vault sidecar and no metrics. Nothing was red; the pod was simply wrong.
Lesson: the in-cluster ApplicationSet spec and the repo's chart must move
together; when they diverge, the failure mode is silently degraded pods,
not errors. Checking container COUNT (1/1 vs 2/2) caught it.
