# Phase 4.5 part 2 -- Vault: dev mode -> Integrated Raft

Dev-mode Vault wiped every secret, policy and role on each restart --
acceptable while proving the injection pattern, disqualifying for anything
public, and this cluster restarts constantly. This phase moves Vault to
Integrated Raft storage on a PVC. Data now survives pod and node restarts.

The price, stated up front: **Vault now starts SEALED after every restart.**
Unsealing is a manual operator step until the cloud phase adds KMS
auto-unseal. Until unsealed: running vault-agent sidecars cannot renew
leases, and any new pod of a vault-enabled tenant hangs in its init
container. A sealed Vault after a laptop reboot is now the EXPECTED state,
not an incident.

## Laptop-scale compromises (deliberate, replaced in the cloud phase)
- 1 unseal key share, threshold 1 (`-key-shares=1 -key-threshold=1`).
  Production is 5/3 across people, or cloud-KMS auto-unseal.
- No TLS on the listener (in-cluster plaintext until cert-manager exists).
- Raft `replicas=1` -- the production storage SHAPE without the HA.
- No audit device, no automated raft snapshots yet.

## Where the key material lives
`vault operator init` prints ONE unseal key and ONE root token. Store both
in a file OUTSIDE this repo (e.g. `~/vault-deployaz-keys.txt`), never in
the repo, never in a pipeline. gitleaks in CI is the backstop, not the
policy. Anyone with that file owns every tenant secret -- treat it like a
password.

## Migration procedure

Dev mode was in-memory, so there is no data to migrate -- this is a
replace, not a migration. The old instance's state is recreated by
vault-setup.sh, same as after every restart until now.

```bash
# 0. Preflight (OPERATIONS.md), repo at latest main.

# 1. Upgrade the Helm release -- this replaces the dev server with raft:
helm upgrade vault hashicorp/vault -n vault -f k8s/vault/vault-values.yaml
kubectl get pods -n vault -w
# vault-0 will show Running but 0/1 READY -- readiness fails while sealed.
# That is correct behavior, not a crash.

# 2. Confirm the PVC exists and is Bound:
kubectl get pvc -n vault      # expect data-vault-0, Bound, 1Gi

# 3. Initialize (ONCE, EVER, for this cluster):
kubectl exec -n vault vault-0 -- vault operator init -key-shares=1 -key-threshold=1
# SAVE the "Unseal Key 1" and "Initial Root Token" lines to
# ~/vault-deployaz-keys.txt (outside the repo) NOW. They are shown once.

# 4. Unseal:
kubectl exec -n vault vault-0 -- vault operator unseal <UNSEAL_KEY>
kubectl get pods -n vault     # vault-0 now 1/1

# 5. Reconfigure (auth method, KV engine, secret, policy, role):
export VAULT_ROOT_TOKEN=<INITIAL_ROOT_TOKEN>
bash k8s/vault/vault-setup.sh

# 6. Roll the demo tenant so every pod authenticates against the new
#    instance (old sidecars hold tokens from the dead dev instance):
kubectl rollout restart deploy/demo -n deployaz-demo
kubectl rollout status deploy/demo -n deployaz-demo --timeout=300s
```

## Restart runbook (add to muscle memory -- this replaces "re-run
vault-setup after restart")

After ANY cluster/laptop restart:
```bash
kubectl exec -n vault vault-0 -- vault status
# Sealed: true  -> expected. Unseal:
kubectl exec -n vault vault-0 -- vault operator unseal <UNSEAL_KEY>
```
That's all -- configuration and secrets PERSIST now. vault-setup.sh is no
longer a restart step; it's only for changing configuration. Vault-enabled
tenant pods created while sealed will be stuck in init and recover on their
own within ~1 min of unsealing (agent retries).

## Verification battery -- part 2 is NOT done until all pass

1. **Mode:** `kubectl exec -n vault vault-0 -- vault status` shows
   `Initialized true`, `Sealed false`, `Storage Type raft`. The dev-mode
   warning is gone from `kubectl logs -n vault vault-0`.
2. **PVC:** `kubectl get pvc -n vault` -> Bound.
3. **The persistence proof (the whole point):**
   `kubectl delete pod vault-0 -n vault` -> pod returns **sealed** (0/1) ->
   unseal -> then WITHOUT re-running vault-setup.sh:
   `kubectl exec -n vault vault-0 -- sh -c "VAULT_TOKEN=$VAULT_ROOT_TOKEN vault kv get secret/deployaz-demo/db"`
   returns the secret. Dev mode failed this test by design; raft must pass.
4. **Tenant path end-to-end after the restart cycle:**
   `kubectl exec -n deployaz-demo deploy/demo -c app -- cat //vault/secrets/db-password`
   -> `dev-only-synthetic-value-42`, and
   `kubectl rollout restart deploy/demo -n deployaz-demo` completes with new
   2/2 pods (fresh injection against raft Vault).
5. **Sealed-state behavior is understood, not just documented:** with Vault
   deliberately sealed, `kubectl rollout restart deploy/demo` -> new pods
   hang in init (expected) -> unseal -> rollout completes without further
   action. This rehearses the exact post-reboot failure you WILL see.
6. **No key material in the repo:** `git status` clean of key files;
   `grep -r "hvs\." . --exclude-dir=.git` in the repo root returns nothing;
   the CI gitleaks job on the phase commit is green.
7. **Isolation unchanged:** re-run the Phase 4.5 RBAC + egress spot checks
   (can-i no/yes/no/no, wget egress fail) -- Vault changes must not have
   touched tenant isolation.

## Honest limitations after part 2
- Manual unseal is a single point of operator dependence -- fine for a
  laptop, replaced by KMS auto-unseal in the cloud phase.
- Single raft node: storage durability, not availability.
- No raft snapshot backups yet -- `vault operator raft snapshot save` gets
  automated in the cloud phase alongside Velero.
- Root token is being used for routine setup; a scoped admin token/policy
  is deferred until there's more than one operator.
