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
├── docs/                      # Runbooks (encrypted-volume migration)
├── infrastructure/
│   ├── longhorn/              # Longhorn Helm
│   └── longhorn-config/       # Encrypted StorageClass, S3 backup target, RecurringJob
└── apps/
    ├── actual-budget/         # Actual Budget (personal finance)
    └── vaultwarden/           # Vaultwarden (password manager; SOPS secret)
```

## Infrastructure

| Component | Purpose | Notes |
|-----------|---------|--------|
| **Longhorn** | Distributed block storage | **3 replicas**, data path `/var/lib/longhorn` |
| **longhorn-config** | Storage encryption + backups | `longhorn-encrypted` default StorageClass (dm-crypt), daily S3 backups |
| **coredns-custom** | Cluster DNS overrides | Pins `garage.nakunga.com` (S3 backup target, Tailscale-only) for pods |

### Volume encryption & backups

- **`longhorn-encrypted`** is the default StorageClass: volumes are dm-crypt
  encrypted with the passphrase in `longhorn-config/manifests/crypto-secret.sops.yaml`
  (SOPS/age, decrypted in-cluster by KSOPS). Backups of encrypted volumes stay
  encrypted — the S3 target never sees plaintext. `reclaimPolicy: Retain`.
- **Backup target**: self-hosted Garage S3 (`garage.nakunga.com`, Tailscale-only),
  configured in `infrastructure/longhorn/values.yaml` (`defaultBackupStore`) with
  credentials in `longhorn-config/manifests/backup-target-secret.sops.yaml`.
  Nodes are joined to the tailnet (`tailscale up --accept-dns=false`); pod DNS
  for the hostname comes from the `coredns-custom` app.
- **Schedule**: `RecurringJob` `backup-daily` — 03:00 daily, retain 7, applies
  to all volumes (group `default`).
- **Disaster recovery**: restoring backups needs the crypto passphrase → which
  needs an age private key from `.sops.yaml`. Keep an **offline copy of your
  personal age key**.
- Migrating pre-existing unencrypted PVCs: see
  [docs/encrypted-volume-migration.md](docs/encrypted-volume-migration.md).
- App PVCs carry `argocd.argoproj.io/sync-options: Prune=false,Delete=false` so
  Argo never deletes data volumes on prune/app-deletion.

## Apps

| App | Purpose | Access |
|-----|---------|--------|
| **actual-budget** | [Actual Budget](https://actualbudget.org) sync server + web UI | ClusterIP `:5006` — expose with Pangolin/Newt |
| **vaultwarden** | [Vaultwarden](https://github.com/dani-garcia/vaultwarden) (Bitwarden-compatible) | ClusterIP `:80` — expose with Pangolin/Newt; admin at `/admin` |

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

### Vaultwarden

- Image: `vaultwarden/server:1.37.1`
- Data: Longhorn PVC `vaultwarden-data` (**5Gi**, RWO) mounted at `/data`
- Secret: `ADMIN_TOKEN` in `apps/vaultwarden/manifests/secret.sops.yaml` (SOPS + age; decrypted by KSOPS)
- In-cluster URL: `http://vaultwarden.vaultwarden.svc.cluster.local`
- Admin UI: `/admin` (token from the secret). Signups disabled by default (`SIGNUPS_ALLOWED=false`); invite users from admin.

```bash
kubectl -n vaultwarden get pods,svc,pvc

# Local smoke test without Pangolin:
kubectl -n vaultwarden port-forward svc/vaultwarden 8080:80
# open http://127.0.0.1:8080  and  http://127.0.0.1:8080/admin
```

### Prerequisites (host / k3s)

**Longhorn — on every node** that should run replicas:

```bash
# Debian/Ubuntu example
sudo apt-get install -y open-iscsi nfs-common
sudo systemctl enable --now iscsid

# Volume encryption (longhorn-encrypted StorageClass) additionally needs
# cryptsetup + the dm_crypt kernel module on every node:
sudo apt-get install -y cryptsetup
sudo modprobe dm_crypt   # usually built-in/autoloaded; verify with: lsmod | grep dm_crypt
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
kubectl -n vaultwarden get pods,svc
```

## How secrets work (SOPS + age + KSOPS)

1. **SOPS** encrypts selected fields (`data` / `stringData`) in `*.sops.yaml` files using age public keys.
2. **age** keys: Argo CD holds a private key (Secret `sops-age` in `argocd`) for local decrypt automation; you hold a personal private key for edit/encrypt.
3. **KSOPS** is a Kustomize generator plugin. Argo CD runs it so encrypted Secret manifests are decrypted at apply time — plaintext never lives in git.

### Encrypt a new secret

Write the Secret YAML with plaintext `stringData` (file name must match `*.sops.yaml` so `.sops.yaml` creation rules apply), then:

```bash
# Example: vaultwarden admin token
# 1. Edit plaintext (before first encrypt):
#    stringData.ADMIN_TOKEN: "<your token>"
#    Generate a token:  openssl rand -base64 48
#    Or argon2 hash:    docker run --rm -it vaultwarden/server:1.37.1 /vaultwarden hash

sops --encrypt --in-place apps/vaultwarden/manifests/secret.sops.yaml
git add apps/vaultwarden/manifests/secret.sops.yaml
```

Requires `sops` and age private keys matching the public keys in `.sops.yaml` (personal key for encrypt/edit; Argo uses `sops-age` in-cluster).

### Edit an existing encrypted secret

```bash
sops apps/vaultwarden/manifests/secret.sops.yaml
```

## Open items / reminders

- [x] **Argo CD ↔ git access**: apps use public HTTPS `https://github.com/d-kholin/k3s-hl.git` (no credentials required).
- [x] **No MetalLB**: external access via Pangolin + Newt to ClusterIP services.
- [ ] **Pangolin / Newt**: wire Newt to in-cluster services (e.g. Actual Budget, Vaultwarden).
- [ ] **Longhorn node readiness**: open-iscsi on all storage nodes before expecting volumes to schedule.
- [ ] **SOPS in Argo**: KSOPS plugin + `sops-age` secret in `argocd` — required for Vaultwarden `secret.sops.yaml`.
- [x] **Vaultwarden secret**: `ADMIN_TOKEN` encrypted in `secret.sops.yaml` (still needs KSOPS + `sops-age` in Argo).
- [ ] Chart pins today: Longhorn `1.8.1` — bump `targetRevision` in the Application manifest when you want upgrades.
- [ ] **Backup target**: set real bucket in `infrastructure/longhorn/values.yaml` (`defaultBackupStore.backupTarget`) and fill credentials: `sops infrastructure/longhorn-config/manifests/backup-target-secret.sops.yaml`.
- [ ] **Migrate volumes to `longhorn-encrypted`** before the first 3 AM backup runs (plaintext backups otherwise) — see `docs/encrypted-volume-migration.md`.
- [ ] **Offline copy of personal age key** — it is the recovery root for encrypted backups.

