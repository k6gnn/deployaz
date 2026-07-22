# DeployAZ Platform

A multi-tenant deployment platform, built in public. Real production shape at
every stage - CI, containerization, GitOps, monitoring, isolation, secrets
management, supply-chain security, and self-service onboarding - proven
end-to-end with real verification at each step, not assumed.

## Structure
```
app/            Spring Boot demo service (the original "tenant" workload)
charts/tenant/  Generic tenant Helm chart -- one chart, N tenants; every
                tenant gets the full isolation layer automatically
tenants/        Tenant registry -- one config.json per onboarded tenant,
                written ONLY by the onboarding workflow after a clean scan
k8s/base/       Tenant-a manifests -- what ArgoCD watches
k8s/tenants/    Hand-written tenant-b (kept as the pre-Phase-4 shape)
k8s/vault/      Vault install values + one-time setup script
k8s/gatekeeper/ Admission-time policy: blocks unscanned images (label-based)
k8s/logging/    Loki + Promtail values (centralized logs, all pods)
gitops/         ArgoCD Application + ApplicationSet definitions
docs/           Setup + verification instructions per phase, and the
                operations runbook (OPERATIONS.md) with every real
                incident and its root cause
```

## Status
**Phases 1-4 complete and verified.** Phase 4's full battery -- onboarding
(including a real Trivy rejection of a vulnerable first image), Gatekeeper
admission, RBAC/network/quota isolation on the auto-created tenant,
centralized logs, Git-driven teardown, re-onboarding -- was executed
against the live cluster. Record: `docs/PHASE4_SETUP.md`. Operational
incidents and their root causes: `docs/OPERATIONS.md`.
Next phase: cloud migration (real cluster, domain, TLS) -- the operational
failures documented in OPERATIONS.md are its justification.

## Setup docs
- `docs/PHASE1_SETUP.md` -- cluster, ArgoCD, monitoring, full CI/CD loop
- `docs/PHASE2_SETUP.md` -- multi-tenancy + the four isolation proofs
- `docs/PHASE3_SETUP.md` -- Vault, CI security gates, Gatekeeper policy
- `docs/PHASE4_SETUP.md` -- self-service onboarding, Loki, and the
  verification steps that separate "automation exists" from "automation
  is safe"

## What's actually proven, not just claimed
- Single-tenant app, GitOps-managed, monitored (Phase 1)
- Two isolated tenants on one cluster -- RBAC, NetworkPolicy, ResourceQuota,
  confirmed with real kubectl evidence (Phase 2)
- Vault-backed secrets: not in Git, injected at runtime, fail-fast if
  missing, isolated per tenant (Phase 3)
- CI security gates: gitleaks + Trivy -- Trivy has caught and blocked a real
  batch of CVEs, not just a synthetic test (Phase 3)
- Gatekeeper admission policy: confirmed to reject a manifest missing a
  valid scan annotation (Phase 3)
- Phase 4, verified end-to-end: repo URL -> built, scanned, deployed,
  isolated, log-shipping app with zero manual Kubernetes steps -- and the
  scan gate refused a genuinely vulnerable image on its first live run
- Full teardown via Git delete, and clean re-onboarding, both verified

## Known, honest limitations (not hidden)
- Runs on a local kind cluster: the free tier is NOT publicly reachable yet.
  Cloud migration (real cluster, domain, cert-manager TLS) is its own
  future phase with real monthly cost.
- Onboarding is operator-triggered (workflow_dispatch), deliberately, while
  the cluster is a laptop. The pipeline after the trigger is zero-touch.
- Vault runs in dev mode -- proves the pattern, not production-grade.
- Gatekeeper trusts a CI-written annotation, not a cryptographic signature;
  cosign image signing is the documented hardening step.
- No automatic rebuild when a tenant's repo changes (webhook trigger is
  future work). Public repos with a Dockerfile only.
- Spring Boot pinned to 3.5.16 (EOL branch, final patch) -- a deliberate
  4.x migration is separate future work.
