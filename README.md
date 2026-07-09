# DeployAZ Platform — Phase 1

A multi-tenant deployment platform, built in public. This is Phase 1:
single-tenant, but with the full production shape — CI, containerization,
GitOps, monitoring — proven end-to-end before any multi-tenancy work
starts.

## Structure
```
app/         Spring Boot demo service (the "tenant" workload)
k8s/base/    Kubernetes manifests — this is what ArgoCD watches
gitops/      ArgoCD Application definition
monitoring/  Prometheus ServiceMonitor for the app
docs/        Setup instructions
```

## Status
Phase 1 — single-tenant, GitOps-managed, monitored. Not yet multi-tenant,
not yet secured for untrusted third-party code, not yet self-service.

## Setup
See `docs/PHASE1_SETUP.md` for the full walkthrough — cluster creation,
ArgoCD install, monitoring stack, and how to verify the whole loop actually
works rather than just assuming it does.

## Roadmap
1. **Phase 1 (this)** — single app, full pipeline, GitOps, monitored
2. Second synthetic tenant + isolation (namespaces, RBAC, NetworkPolicies, quotas)
3. Secrets management (Vault/sealed-secrets) + image scanning (Trivy) + policy (Kyverno)
4. Self-service: repo URL in, deployed+monitored app out, zero manual steps
