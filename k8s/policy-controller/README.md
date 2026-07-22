# Sigstore policy-controller

Install (pin the chart version you actually installed in the commit
message; latest at install time):

```bash
helm repo add sigstore https://sigstore.github.io/helm-charts
helm repo update
helm install policy-controller sigstore/policy-controller \
  -n cosign-system --create-namespace
kubectl get pods -n cosign-system   # webhook + policy-webhook Running
kubectl apply -f k8s/policy-controller/cluster-image-policy.yaml
```

Operational facts, learned before they hurt:
- FAIL-CLOSE: if the policy-controller webhook is down, NO pod can be
  created in labeled namespaces. Same class of risk as the Vault injector
  but blocking. It is now part of the restart health sweep.
- ONLINE verification: admission needs to reach fulcio.sigstore.dev /
  rekor.sigstore.dev. No internet = no tenant pod admission. Acceptable on
  a laptop; a cloud deployment should consider private Rekor mirroring or
  air-gap bundles (out of scope until then).
- Verification happens at POD creation (ReplicaSet -> Pod), so an existing
  running pod is never evicted by policy -- but any restart of an
  unsigned-image pod will be rejected. Hence the sign-first cutover order
  in docs/PHASE47_COSIGN.md.
