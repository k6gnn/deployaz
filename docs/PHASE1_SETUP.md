# Phase 1 Setup — Local Kind Cluster

Honest scope check: this gets you a single app, containerized, deployed via
GitOps, monitored — running on your machine. It does not give you a public
URL. That's the tradeoff of starting local. Move to EKS later for that.

## Prerequisites
- Docker
- `kind` (https://kind.sigs.k8s.io/)
- `kubectl`
- `helm`
- A GitHub account + this repo pushed there (GitHub Actions and ArgoCD both
  need to pull from a real remote — they can't run against your local-only
  git history)

## 1. Push this repo to GitHub
```bash
cd deployaz-platform
git init
git add .
git commit -m "chore: phase 1 scaffold"
gh repo create deployaz-platform --public --source=. --push
# or manually: create the repo on github.com, then
# git remote add origin https://github.com/<you>/deployaz-platform.git
# git push -u origin main
```

Then replace every `OWNER` placeholder with your actual GitHub username in:
- `.github/workflows/ci-cd.yml`
- `k8s/base/deployment.yaml`
- `gitops/argocd-application.yaml`

Commit and push that change. This push triggers the CI pipeline, which will
build the image, push it to GHCR, and commit the new tag back into
`k8s/base/deployment.yaml`. Check the Actions tab — confirm it went green
before continuing.

By default GHCR images are private. Either make the package public
(package settings on GitHub → Change visibility) or create an
`imagePullSecret` in the `deployaz-demo` namespace — public is simpler for
now.

## 2. Create the local cluster
```bash
kind create cluster --name deployaz --config k8s/kind-config.yaml
kubectl cluster-info --context kind-deployaz
```

## 3. Install the ingress controller
```bash
kubectl apply -f https://raw.githubusercontent.com/kubernetes/ingress-nginx/main/deploy/static/provider/kind/deploy.yaml
kubectl wait --namespace ingress-nginx \
  --for=condition=ready pod \
  --selector=app.kubernetes.io/component=controller \
  --timeout=120s
```

## 4. Install ArgoCD
```bash
kubectl create namespace argocd
kubectl apply -n argocd -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml
kubectl wait --namespace argocd \
  --for=condition=available deployment/argocd-server --timeout=180s
```

Get the initial admin password and log in:
```bash
kubectl -n argocd get secret argocd-initial-admin-secret \
  -o jsonpath="{.data.password}" | base64 -d; echo
kubectl -n argocd port-forward svc/argocd-server 8080:443
# open https://localhost:8080  (user: admin)
```

## 5. Point ArgoCD at the repo (the actual GitOps step)
```bash
kubectl apply -f gitops/argocd-application.yaml
```
ArgoCD now watches `k8s/base` in your repo and reconciles the cluster to
match it continuously. From here on, **you don't run `kubectl apply` on the
app manifests manually** — you edit them in Git and ArgoCD syncs. That's the
whole point of GitOps; if you catch yourself running kubectl apply by hand
on deployment.yaml, you've broken the model.

Verify:
```bash
kubectl get application -n argocd
kubectl get pods -n deployaz-demo
```

## 6. Route to the app
Add to `/etc/hosts` (or Windows equivalent):
```
127.0.0.1 demo.deployaz.local
```
Then:
```bash
curl http://demo.deployaz.local/api/hello
curl http://demo.deployaz.local/actuator/health
```

## 7. Install monitoring
```bash
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
helm repo update
helm install kube-prometheus-stack prometheus-community/kube-prometheus-stack \
  --namespace monitoring --create-namespace
kubectl apply -f monitoring/servicemonitor.yaml
```

Access Grafana:
```bash
kubectl -n monitoring port-forward svc/kube-prometheus-stack-grafana 3000:80
# open http://localhost:3000  (user: admin / pass: prom-operator, default)
```
Add a panel for `http_server_requests_seconds_count{application="deployaz-demo"}`
to confirm real metrics are flowing from the app, not just the exporter.

## 8. Prove the full loop end-to-end
Change something visible in `HelloController.java` (e.g. the message text),
push to `main`, and watch:
1. GitHub Actions builds + pushes a new image + commits the new tag
2. ArgoCD detects the Git change and syncs
3. `kubectl get pods -n deployaz-demo` shows a rollout
4. `curl http://demo.deployaz.local/api/hello` reflects the change

If all four happen without you touching `kubectl apply` on the app itself,
Phase 1 is done. If you had to intervene manually anywhere in that chain,
something's still broken — don't call it done.

## What Phase 1 deliberately does NOT include yet
- TLS/cert-manager (needs a real public domain — Phase 2+ when you move to
  a cloud cluster)
- Multi-tenancy, RBAC, quotas, NetworkPolicies (Phase 2)
- Secrets management / Vault (Phase 3)
- Image scanning / policy enforcement (Phase 3)
- Self-service onboarding (Phase 4)

Don't add these now. Scope creep here is exactly what turns "single-tenant
proof of concept" into a stalled project.
