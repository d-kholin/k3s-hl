# k3s-hl — GitOps for k3s + Argo CD

Homelab GitOps repository for a k3s cluster managed by Argo CD.
Secrets are encrypted with [SOPS](https://github.com/getsops/sops) + [age](https://github.com/FiloSottile/age) and decrypted in-cluster by [KSOPS](https://github.com/viaduct-ai/kustomize-sops).

External access is intended via **Pangolin + Newt** (ClusterIP services), not LoadBalancer / MetalLB.

## Layout

```
.
├── .sops.yaml
├── .github/workflows/         # CI: kustomize build + kubeconform + sops guard
├── bootstrap/
│   └── root-app.yaml          # App-of-Apps root (infrastructure/ + apps/)
├── docs/                      # Runbooks (disaster recovery, encrypted-volume migration)
├── infrastructure/
│   ├── argocd/                # Argo CD manages itself (install.yaml + KSOPS patch)
│   ├── longhorn/              # Longhorn Helm
│   ├── longhorn-config/       # Encrypted StorageClass, S3 backup target, RecurringJobs
│   ├── monitoring/            # kube-prometheus-stack Helm
│   └── monitoring-config/     # Alertmanager email (SOPS), Longhorn alerts
└── apps/
    ├── actual-budget/         # Actual Budget (personal finance)
    ├── newt/                  # Pangolin tunnel client (two redundant sites)
    └── vaultwarden/           # Vaultwarden (password manager; SOPS secret)
```

## Infrastructure

| Component | Purpose | Notes |
|-----------|---------|--------|
| **argocd** | Argo CD manages itself | Stock `install.yaml` v3.5.0 + KSOPS repo-server patch; bootstrap via `kubectl apply -k` |
| **Longhorn** | Distributed block storage | **3 replicas**, data path `/var/lib/longhorn` |
| **longhorn-config** | Storage encryption + backups | `longhorn-encrypted` default StorageClass (dm-crypt), snapshot + tiered S3 backups |
| **monitoring** | kube-prometheus-stack | Prometheus (14d), Alertmanager → email, Grafana (ClusterIP) |
| **monitoring-config** | Alerting config | Alertmanager SMTP/email (SOPS), Longhorn scrape + alert rules |
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
- **Schedule** (all volumes, group `default`): local snapshots every 6h
  (retain 8) for fast rollback, plus tiered S3 backups — daily 03:00
  (retain 7), Saturday 04:30 (retain 5), monthly (retain 6) → recovery
  points span ~6 months.
- **Disaster recovery**: full cluster-rebuild runbook in
  [docs/disaster-recovery.md](docs/disaster-recovery.md). Restoring backups
  needs the crypto passphrase → which needs an age private key from
  `.sops.yaml`. Keep an **offline copy of your personal age key**.
- Migrating pre-existing unencrypted PVCs: see
  [docs/encrypted-volume-migration.md](docs/encrypted-volume-migration.md).
- App PVCs carry `argocd.argoproj.io/sync-options: Prune=false,Delete=false` so
  Argo never deletes data volumes on prune/app-deletion.

## Apps

| App | Purpose | Access |
|-----|---------|--------|
| **actual-budget** | [Actual Budget](https://actualbudget.org) sync server + web UI | ClusterIP `:5006` — expose with Pangolin/Newt |
| **vaultwarden** | [Vaultwarden](https://github.com/dani-garcia/vaultwarden) (Bitwarden-compatible) | ClusterIP `:80` (container listens on 8080) — expose with Pangolin/Newt; admin at `/admin` |
| **newt** | [Newt](https://github.com/fosrl/newt) Pangolin tunnel client | Two sites (redundant), spread across nodes |

Workload security: app namespaces enforce the **restricted** Pod Security
Standard (pods run non-root, all capabilities dropped, read-only rootfs,
seccomp); `newt` is **privileged** (needs root + NET_ADMIN + /dev/net/tun).
Default-deny ingress NetworkPolicies mean **only Newt pods** can reach the
apps — in-cluster smoke tests from other namespaces will (correctly) time
out; use `kubectl port-forward` instead.

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

### Bootstrap (fresh cluster)

```bash
# 1. Argo CD + KSOPS (same kustomization Argo later manages itself with)
kubectl apply -k infrastructure/argocd/manifests

# 2. The one manual secret — age private key from your offline copy
kubectl -n argocd create secret generic sops-age \
  --from-file=keys.txt=/path/to/offline/age-key.txt

# 3. Everything else
kubectl apply -f bootstrap/root-app.yaml
```

Root Application sources: `https://github.com/d-kholin/k3s-hl.git` → paths `infrastructure` and `apps`.
Rebuilding with data restore: follow [docs/disaster-recovery.md](docs/disaster-recovery.md) instead.

### Monitoring & email alerts

kube-prometheus-stack with Longhorn rules: volume degraded/faulted, backup
older than 26h, volume never backed up, Longhorn node unready, disk >85%.
Alertmanager emails them; SMTP host/credentials and the destination address
live encrypted in git — fill them in with:

```bash
sops infrastructure/monitoring-config/manifests/alertmanager-config.sops.yaml

# UIs (ClusterIP only):
kubectl -n monitoring port-forward svc/monitoring-grafana 3000:80        # admin / prom-operator — change it
kubectl -n monitoring port-forward svc/monitoring-kube-prometheus-alertmanager 9093:9093
```

### Verify

```bash
# Longhorn
kubectl -n longhorn-system get pods
kubectl get storageclass
# expect longhorn-encrypted (default)

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

- [ ] **Alertmanager SMTP**: fill real credentials + destination address:
  `sops infrastructure/monitoring-config/manifests/alertmanager-config.sops.yaml`
  (placeholders until then — no emails will send).
- [ ] **Grafana**: change the default admin password (`prom-operator`) on first login.
- [ ] **Test-restore a backup quarterly** — see docs/disaster-recovery.md "Ongoing hygiene".
- [ ] **Pangolin / Newt**: wire Newt to in-cluster services (e.g. Actual Budget, Vaultwarden).
- [ ] Chart pins today: Longhorn `1.12.0`, kube-prometheus-stack `88.2.0`, Argo CD `v3.5.0` (ref in `infrastructure/argocd/manifests/kustomization.yaml`) — bump deliberately, one minor at a time for Longhorn, reading release notes first.
- [ ] **Offline copy of personal age key** — it is the recovery root for encrypted backups AND all SOPS secrets. Verify you can locate it.
- [ ] The `hostAliases` IP `172.20.0.7` (Pangolin LAN address) is hardcoded in both Newt deployments — update there if the Pangolin server moves.
- [x] **Argo CD ↔ git access**: public HTTPS, no credentials required.
- [x] **No MetalLB**: external access via Pangolin + Newt to ClusterIP services.
- [x] **SOPS in Argo**: KSOPS plugin + `sops-age` secret — now GitOps-managed (`infrastructure/argocd`); `sops-age` itself stays manual by design.
- [x] **Backup target**: Garage bucket + credentials configured; daily/weekly/monthly backups + 6h snapshots scheduled.
- [x] **Volumes on `longhorn-encrypted`** — apps use encrypted PVCs.

