# DeployAZ Platform

A multi-tenant deployment platform, built in public. Real production shape at
every stage — CI, containerization, GitOps, monitoring, isolation, secrets
management, and supply-chain security — proven end-to-end with real
verification at each step, not assumed.

## Structure
```
app/            Spring Boot demo service (the "tenant" workload)
k8s/base/       Tenant-a manifests -- this is what ArgoCD watches
k8s/tenants/    Additional tenant(s) -- tenant-b is synthetic, proving
                platform isolation rather than app diversity
k8s/vault/      Vault install values + one-time setup script
k8s/gatekeeper/ Admission-time policy: blocks unscanned images
gitops/         ArgoCD Application definitions
docs/           Setup + verification instructions per phase
```

## Status
**Phases 1-3 complete.** Single-tenant pipeline, two isolated tenants,
secrets management, CVE scanning, and admission-time policy enforcement --
all built and verified against a real cluster, not just written. Not yet
self-service (Phase 4).

## Setup
- `docs/PHASE1_SETUP.md` -- cluster creation, ArgoCD install, monitoring
  stack, and how to verify the full CI/CD loop actually works.
- `docs/PHASE3_SETUP.md` -- Vault install + verification, CI security gates
  (gitleaks + Trivy), and Gatekeeper admission policy + verification.
- **Note:** a `PHASE2_SETUP.md` was discussed but never actually committed
  to this repo -- that's a real gap, not an oversight to gloss over. The
  Phase 2 work itself (tenant-b isolation: namespaces, RBAC, NetworkPolicies,
  ResourceQuotas) is live and proven in the cluster and reflected in
  `k8s/tenants/tenant-b/`, but its own setup doc should still get written.

## What's actually proven, not just claimed
- Single-tenant app, GitOps-managed, monitored (Phase 1)
- Two isolated tenants on one cluster -- RBAC, NetworkPolicy, ResourceQuota,
  all confirmed with real `kubectl` evidence, not just "looks right" (Phase 2)
- Vault-backed secrets: not in Git, injected at runtime, fail-fast if
  missing, isolated per tenant, internal-only visibility (Phase 3)
- CI security gates: gitleaks (secret scanning) and Trivy (CVE scanning) --
  Trivy has already caught and blocked a real batch of CVEs in outdated
  dependencies, not just a synthetic test (Phase 3)
- Gatekeeper admission policy: confirmed to actually reject a manifest
  missing a valid scan annotation, with a real denial message from the
  apiserver (Phase 3)

## Known, honest limitations (not hidden)
- Vault runs in **dev mode** (in-memory, auto-unsealed, fixed root token) --
  proves the pattern, not production-grade. Real production needs a proper
  storage backend, cloud KMS auto-unseal, and TLS.
- Gatekeeper's policy trusts a CI-written annotation, not a cryptographic
  signature. The real hardening step is image signing (cosign) verified
  directly against the registry.
- Spring Boot is pinned to `3.5.16`, the final patch of an now-EOL branch --
  this bought time by fixing real CVEs, it didn't permanently solve the
  problem. A deliberate Spring Boot 4.x migration is separate future work,
  not something to fold into a security-hardening phase.

## Roadmap
1. Single app, full pipeline, GitOps, monitored -- **done**
2. Second synthetic tenant + isolation (namespaces, RBAC, NetworkPolicies,
   quotas) -- **done**
3. Secrets management (Vault) + image scanning (Trivy) + policy enforcement
   (OPA/Gatekeeper) -- **done**
4. Self-service: client submits a repo URL, gets a deployed and monitored
   app back, zero manual steps -- **next**
