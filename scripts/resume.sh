#!/usr/bin/env bash
# DeployAZ post-reboot resume ritual, automated.
# Usage:  bash scripts/resume.sh
# Reads the unseal key from ~/vault-deployaz-keys.txt (first line matching
# "Unseal Key" or a bare base64 line). SECURITY TRADEOFF, stated: reading
# the key from disk means the seal only protects the raft PVC against
# offline theft, not against compromise of this user account. Acceptable
# for a dev laptop; the cloud phase replaces this with KMS auto-unseal.
set -euo pipefail
KEYFILE="${VAULT_KEYFILE:-$HOME/vault-deployaz-keys.txt}"

step() { printf '\n==> %s\n' "$1"; }

step "Cluster reachable?"
kubectl get nodes --no-headers || { echo "FATAL: cluster not up (is Docker Desktop running?)"; exit 1; }

step "Waiting for vault-0 to exist and be Running (sealed = 0/1 is fine)"
for i in $(seq 1 30); do
  PHASE=$(kubectl get pod vault-0 -n vault -o jsonpath='{.status.phase}' 2>/dev/null || echo "")
  [ "$PHASE" = "Running" ] && break
  sleep 5
done
[ "$PHASE" = "Running" ] || { echo "FATAL: vault-0 not Running after 150s"; kubectl get pods -n vault; exit 1; }

step "Vault seal status"
if kubectl exec -n vault vault-0 -- vault status 2>/dev/null | grep -q "Sealed *true"; then
  [ -f "$KEYFILE" ] || { echo "FATAL: sealed, and no key file at $KEYFILE"; exit 1; }
  KEY=$(grep -oE '[A-Za-z0-9+/]{40,}={0,2}' "$KEYFILE" | head -1)
  [ -n "$KEY" ] || { echo "FATAL: no key-looking string found in $KEYFILE"; exit 1; }
  echo "Sealed -- unsealing from $KEYFILE"
  kubectl exec -n vault vault-0 -- vault operator unseal "$KEY" | grep -E "Sealed|HA Mode"
else
  echo "Already unsealed"
fi

step "Health sweep: anything not Running/Completed"
kubectl get pods -A --no-headers | grep -vE "Running|Completed" || echo "  (nothing -- clean)"
echo "NOTE: 'Unknown' corpses from the reboot usually self-clean within minutes."
echo "      Tenant pods stuck in Init self-recover ~1 min after the unseal above."

step "Waiting up to 3 min for ArgoCD applications to settle"
for i in $(seq 1 18); do
  BAD=$(kubectl get application -n argocd --no-headers 2>/dev/null | grep -vcE "Synced +Healthy" || true)
  [ "$BAD" = "0" ] && break
  sleep 10
done
kubectl get application -n argocd

step "Policy-controller (fail-close dependency -- if this is down, no tenant rollouts)"
kubectl get pods -n cosign-system --no-headers

step "Smoke: demo secret path end-to-end"
kubectl exec -n deployaz-demo deploy/demo -c app -- cat /vault/secrets/db-password >/dev/null 2>&1 \
  && echo "  vault->tenant secret path: OK" \
  || echo "  WARN: demo secret read failed -- if pods are mid-restart give it a minute, else investigate"

printf '\n==> Resume complete.\n'
