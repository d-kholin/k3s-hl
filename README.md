# k3s-hl — GitOps for k3s + Argo CD

Homelab GitOps repository for a k3s cluster managed by Argo CD.
Secrets are encrypted with [SOPS](https://github.com/getsops/sops) + [age](https://github.com/FiloSottile/age) and decrypted in-cluster by [KSOPS](https://github.com/viaduct-ai/kustomize-sops).

External access is intended via **Pangolin + Newt** (ClusterIP services), not LoadBalancer / MetalLB.

## Layout

```
.
├── .sops.yaml
├── bootstrap/
│   └── root-app.yaml          # App-of-Apps root (infrastructure/ + apps/)
├── infrastructure/
│   └── longhorn/              # Longhorn Helm (default StorageClass)
└── apps/
    └── actual-budget/         # Actual Budget (personal finance)
```

## Infrastructure

| Component | Purpose | Notes |
|-----------|---------|--------|
| **Longhorn** | Distributed block storage | Default StorageClass, **3 replicas**, data path `/var/lib/longhorn` |

## Apps

| App | Purpose | Access |
|-----|---------|--------|
| **actual-budget** | [Actual Budget](https://actualbudget.org) sync server + web UI | ClusterIP `:5006` — expose with Pangolin/Newt |

### Actual Budget

- Image: `actualbudget/actual-server:26.8.1-alpine`
- Data: Longhorn PVC `actual-budget-data` (**5Gi**, RWO) mounted at `/data`
- In-cluster URL: `http://actual-budget.actual-budget.svc.cluster.local:5006`
- First visit (via Pangolin or port-forward): set the **server password** in the UI (stored in the volume; not in git)

```bash
kubectl -n actual-budget get pods,svc,pvc

# Local smoke test without Pangolin:
kubectl -n actual-budget port-forward svc/actual-budget 5006:5006
# open http://127.0.0.1:5006
```

### Prerequisites (host / k3s)

**Longhorn — on every node** that should run replicas:

```bash
# Debian/Ubuntu example
sudo apt-get install -y open-iscsi nfs-common
sudo systemctl enable --now iscsid
```

Ensure enough disk under `/var/lib/longhorn` (or change `defaultDataPath` in `infrastructure/longhorn/values.yaml`).

### Bootstrap Argo CD apps

```bash
kubectl apply -f bootstrap/root-app.yaml
```

Root Application sources: `https://github.com/d-kholin/k3s-hl.git` → paths `infrastructure` and `apps`.

### Verify

```bash
# Longhorn
kubectl -n longhorn-system get pods
kubectl get storageclass
# expect longhorn (default)

# Apps
kubectl -n argocd get applications
kubectl -n actual-budget get pods,svc
```

## How secrets work (SOPS + age + KSOPS)

1. **SOPS** encrypts selected fields (`data` / `stringData`) in `*.sops.yaml` files using age public keys.
2. **age** keys: Argo CD holds a private key (Secret `sops-age` in `argocd`) for local decrypt automation; you hold a personal private key for edit/encrypt.
3. **KSOPS** is a Kustomize generator plugin. Argo CD runs it so encrypted Secret manifests are decrypted at apply time — plaintext never lives in git.

### Encrypt a new secret

```bash
sops --encrypt --in-place path/to/foo.sops.yaml
git add path/to/foo.sops.yaml
```

### Edit an existing encrypted secret

```bash
sops path/to/file.sops.yaml
```

## Open items / reminders

- [x] **Argo CD ↔ git access**: apps use public HTTPS `https://github.com/d-kholin/k3s-hl.git` (no credentials required).
- [x] **No MetalLB**: external access via Pangolin + Newt to ClusterIP services.
- [ ] **Pangolin / Newt**: wire Newt to in-cluster services (e.g. Actual Budget).
- [ ] **Longhorn node readiness**: open-iscsi on all storage nodes before expecting volumes to schedule.
- [ ] **SOPS in Argo**: KSOPS plugin + `sops-age` secret in `argocd` when you start using encrypted secrets for real apps.
- [ ] Chart pins today: Longhorn `1.8.1` — bump `targetRevision` in the Application manifest when you want upgrades.

