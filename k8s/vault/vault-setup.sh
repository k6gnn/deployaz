#!/usr/bin/env bash
# Vault configuration for the deployaz platform (raft-mode version).
# Run AFTER vault-0 is Running, INITIALIZED and UNSEALED
# (see docs/PHASE46_VAULT_RAFT.md for init/unseal).
#
# The root token is NOT hardcoded anymore (dev mode's fixed "root" token is
# gone). Export it first -- from the init output you stored OUTSIDE this
# repo:
#   export VAULT_ROOT_TOKEN=hvs....
#   bash k8s/vault/vault-setup.sh
#
# This script is intentionally NOT part of CI/GitOps -- secret material and
# root-token usage belong in an operator's terminal, never in a pipeline
# log or a committed file.
set -euo pipefail

: "${VAULT_ROOT_TOKEN:?Set VAULT_ROOT_TOKEN to the root token from 'vault operator init' (stored outside this repo)}"

NAMESPACE="vault"
POD="vault-0"

exec_vault() {
  kubectl exec -n "$NAMESPACE" "$POD" -- sh -c "VAULT_TOKEN='$VAULT_ROOT_TOKEN' $1"
}

echo "==> Refusing to run against a sealed or uninitialized Vault"
kubectl exec -n "$NAMESPACE" "$POD" -- vault status | grep -q "Sealed *false" || {
  echo "ERROR: vault-0 is sealed or not initialized. Follow docs/PHASE46_VAULT_RAFT.md first."; exit 1; }

echo "==> Enabling the Kubernetes auth method"
exec_vault "vault auth enable kubernetes || echo 'already enabled'"

echo "==> Configuring Kubernetes auth to talk to this cluster's API server"
exec_vault "vault write auth/kubernetes/config \
  kubernetes_host=https://\$KUBERNETES_SERVICE_HOST:\$KUBERNETES_SERVICE_PORT"

echo "==> Enabling the KV v2 secrets engine at path 'secret/'"
exec_vault "vault secrets enable -path=secret kv-v2 || echo 'already enabled'"

echo "==> Writing the synthetic DB_PASSWORD secret (dev/demo value, not a real credential)"
exec_vault "vault kv put secret/deployaz-demo/db db_password='dev-only-synthetic-value-42'"

echo "==> Writing a Vault policy that can ONLY read the demo tenant's own secret path"
exec_vault "vault policy write tenant-demo-policy -<<'POLICY'
path \"secret/data/deployaz-demo/db\" {
  capabilities = [\"read\"]
}
POLICY"

echo "==> Binding tenant-demo-sa (deployaz-demo namespace, chart-generated name) to that policy"
exec_vault "vault write auth/kubernetes/role/tenant-demo-role \
  bound_service_account_names=tenant-demo-sa \
  bound_service_account_namespaces=deployaz-demo \
  policies=tenant-demo-policy \
  ttl=1h"

echo "==> Done. Verify tenant-tenant-b-sa is NOT bound to tenant-demo-policy --"
echo "    that's the isolation boundary this platform is supposed to prove."
