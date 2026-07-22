#!/usr/bin/env bash
# One-time Vault configuration for Phase 3.
# Run this AFTER `helm install vault ...` has finished and the vault-0 pod
# is Running (dev mode auto-unseals, so no separate unseal step is needed).
#
# This script is intentionally NOT part of CI/GitOps -- writing a secret
# value belongs in an operator's terminal, never in a pipeline log or a
# committed file. That is the whole point of this phase.
set -euo pipefail

NAMESPACE="vault"
POD="vault-0"

exec_vault() {
  kubectl exec -n "$NAMESPACE" "$POD" -- sh -c "$1"
}

echo "==> Enabling the Kubernetes auth method"
exec_vault "VAULT_TOKEN=root vault auth enable kubernetes || echo 'already enabled'"

echo "==> Configuring Kubernetes auth to talk to this cluster's API server"
exec_vault "VAULT_TOKEN=root vault write auth/kubernetes/config \
  kubernetes_host=https://\$KUBERNETES_SERVICE_HOST:\$KUBERNETES_SERVICE_PORT"

echo "==> Enabling the KV v2 secrets engine at path 'secret/'"
exec_vault "VAULT_TOKEN=root vault secrets enable -path=secret kv-v2 || echo 'already enabled'"

echo "==> Writing the synthetic DB_PASSWORD secret (dev/demo value, not a real credential)"
exec_vault "VAULT_TOKEN=root vault kv put secret/deployaz-demo/db db_password='dev-only-synthetic-value-42'"

echo "==> Writing a Vault policy that can ONLY read tenant-a's own secret path"
exec_vault "VAULT_TOKEN=root vault policy write tenant-demo-policy -<<'EOF'
path \"secret/data/deployaz-demo/db\" {
  capabilities = [\"read\"]
}
EOF"

echo "==> Binding tenant-demo-sa (deployaz-demo namespace, chart-generated name) to that policy"
exec_vault "VAULT_TOKEN=root vault write auth/kubernetes/role/tenant-demo-role \
  bound_service_account_names=tenant-demo-sa \
  bound_service_account_namespaces=deployaz-demo \
  policies=tenant-demo-policy \
  ttl=1h"

echo "==> Done. Verify tenant-tenant-b-sa is NOT bound to tenant-demo-policy --"
echo "    that's the isolation boundary this phase is supposed to prove."
