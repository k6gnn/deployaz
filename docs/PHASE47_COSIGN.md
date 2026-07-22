# Phase 4.5 part 3 -- cosign: signed images, verified at admission

Since Phase 3 the README has carried the same disclaimer: Gatekeeper
trusts a CI-written annotation, and anyone with repo write access can
forge it by hand-editing a registry entry. This phase closes that gap.
After it, admission requires a keyless cosign signature produced by THIS
repo's workflows on main -- an identity only the real pipeline can hold,
and the pipeline only signs after the Trivy gate passes.

Design decision (recorded): sigstore policy-controller over Kyverno
(second full policy engine = overlap and doubled webhook risk) and over
Gatekeeper external-data/ratify (extra service in the admission hot path,
youngest ecosystem). Policy-controller is single-purpose and coexists
with the existing Gatekeeper constraint, which stays as defense in depth.

## New standing risks (also in k8s/policy-controller/README.md)
- Fail-close webhook: policy-controller down => no pod creation in tenant
  namespaces. Added to the restart health sweep.
- Online verification: admission requires reaching Fulcio/Rekor. No
  internet, no tenant admission.

## Cutover -- ORDER IS THE WHOLE GAME

Every currently-running image is UNSIGNED. Enforcement before signing
bricks every tenant on its next pod restart. Therefore:

```bash
# 1. Commit the workflow + chart + policy files (this repo change).
#    The ci-cd.yml change triggers CI, which builds, scans, pushes AND
#    SIGNS a fresh platform image, then bumps demo + tenant-b entries.
git add -A && git commit -m "phase4.5 part 3: keyless cosign signing + admission verification" && git push

# 2. Wait for CI green, then for ArgoCD to roll demo and tenant-b onto the
#    signed image:
kubectl get pods -n deployaz-demo -w      # new pods on the new SHA
# (namespace label change also syncs via ArgoCD in this window)

# 3. Re-onboard sample so it too runs a SIGNED image (its current image
#    predates signing): run the Onboard Tenant workflow again with the
#    same inputs. Wait for the rollout.

# 4. ONLY NOW install enforcement:
helm repo add sigstore https://sigstore.github.io/helm-charts && helm repo update
helm install policy-controller sigstore/policy-controller -n cosign-system --create-namespace
kubectl get pods -n cosign-system         # wait Running
kubectl apply -f k8s/policy-controller/cluster-image-policy.yaml
```

## Verification battery -- part 3 is NOT done until all pass, WITH PASTED OUTPUT

1. **Signature exists and verifies out-of-cluster:**
   `cosign verify ghcr.io/k6gnn/deployaz-demo:<new-sha> --certificate-identity-regexp='^https://github.com/k6gnn/deployaz/' --certificate-oidc-issuer=https://token.actions.githubusercontent.com`
   returns the verified claims JSON. (Run in Git Bash with cosign
   installed locally, or inside any pod with cosign -- either is fine.)
2. **Unsigned image is REJECTED at admission:**
   `kubectl run unsigned-test --image=nginx:alpine -n deployaz-demo`
   -> error from the policy-controller webhook (no matching signature /
   no matching policy). This is the test that proves the phase.
3. **Signed platform image is ADMITTED:** the rollouts in steps 2-3 above
   completed, and a fresh
   `kubectl rollout restart deploy/demo -n deployaz-demo` completes.
4. **Forged annotation no longer sufficient (the Phase 3 gap, re-tested):**
   hand-edit is not needed -- reason it through and test the enforceable
   half: a manual `kubectl create deployment` in a tenant namespace using
   an UNSIGNED ghcr.io/k6gnn image tag (e.g. an old pre-signing SHA from
   the registry) gets its pods rejected even though Gatekeeper's
   annotation check isn't in the way. Old SHAs exist in GHCR -- use one.
5. **Fail-close is real (rehearsed, not assumed):**
   `kubectl scale deploy policy-controller-webhook -n cosign-system --replicas=0`
   -> `kubectl rollout restart deploy/demo -n deployaz-demo` -> pods fail
   admission (webhook unavailable) -> scale back to 1 -> rollout
   completes. Add the lesson to OPERATIONS.md restart sweep.
6. **Platform namespaces unaffected:** `kubectl delete pod vault-0 -n
   vault` still comes back (sealed, unseal it) -- proving enforcement
   didn't leak outside labeled namespaces.
7. **Sample tenant end-to-end:** post-re-onboard, sample pod Running on a
   signed image; `kubectl run` of nginx in deployaz-sample rejected.

## Honest limitations after part 3
- The trust anchor is "our GitHub org's CI on main" -- a compromised
  workflow or maintainer account can still sign. Branch protection on
  main is the real perimeter now; that's an org setting, not YAML.
- Rekor/Fulcio public-good instances are a availability dependency at
  admission time.
- Gatekeeper's annotation constraint is now redundant-by-design; kept
  until one full phase of cosign enforcement passes without incident,
  then it can be retired.
