# k3s-hl — GitOps for k3s + Argo CD

Homelab GitOps repository for a k3s cluster managed by Argo CD.
Secrets are encrypted with [SOPS](https://github.com/getsops/sops) + [age](https://github.com/FiloSottile/age) and decrypted in-cluster by [KSOPS](https://github.com/viaduct-ai/kustomize-sops).

## Layout

```
.
├── .sops.yaml
├── bootstrap/
│   └── root-app.yaml          # App-of-Apps root (points at infrastructure/)
├── infrastructure/
│   ├── metallb/               # MetalLB Helm + L2 IP pool
│   └── longhorn/              # Longhorn Helm (default StorageClass)
└── apps/
    └── example-app/           # Scaffold only
```

## Infrastructure

| Component | Purpose | Notes |
|-----------|---------|--------|
| **MetalLB** | LoadBalancer Services on bare metal | L2 mode, pool `192.168.1.10–192.168.1.99` |
| **Longhorn** | Distributed block storage | Default StorageClass, **3 replicas**, data path `/var/lib/longhorn` |

### Prerequisites (host / k3s)

**MetalLB — disable k3s ServiceLB** (klipper-lb conflicts with MetalLB):

```bash
# On each server node, ensure k3s is started with ServiceLB disabled, e.g. in
# /etc/rancher/k3s/config.yaml:
#   disable:
#     - servicelb
# Then restart k3s and remove any leftover svclb-* DaemonSets if present.
```

**Longhorn — on every node** that should run replicas:

```bash
# Debian/Ubuntu example
sudo apt-get install -y open-iscsi nfs-common
sudo systemctl enable --now iscsid
```

Ensure enough disk under `/var/lib/longhorn` (or change `defaultDataPath` in `infrastructure/longhorn/values.yaml`).

### Bootstrap Argo CD apps

```bash
# After Argo CD can clone this repo (SSH deploy key or equivalent):
kubectl apply -f bootstrap/root-app.yaml
```

Root Application source: `https://github.com/d-kholin/k3s-hl.git` → path `infrastructure`.

### Verify

```bash
# MetalLB
kubectl -n metallb-system get pods
kubectl -n metallb-system get ipaddresspools,l2advertisements

# Longhorn
kubectl -n longhorn-system get pods
kubectl get storageclass
# expect longhorn (default)
```

Smoke-test LoadBalancer (after MetalLB is healthy):

```bash
kubectl create deploy lb-test --image=nginx --port=80
kubectl expose deploy lb-test --port=80 --type=LoadBalancer
kubectl get svc lb-test -w
# EXTERNAL-IP should be in 192.168.1.10–192.168.1.99
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
- [ ] **DHCP vs MetalLB pool**: pool is `192.168.1.10-192.168.1.99`. Exclude that range from your router DHCP (or shrink the pool) so addresses are not double-assigned.
- [ ] **Longhorn node readiness**: open-iscsi on all storage nodes before expecting volumes to schedule.
- [ ] **SOPS in Argo**: KSOPS plugin + `sops-age` secret in `argocd` when you start using encrypted secrets for real apps.
- [ ] Chart pins today: MetalLB `0.14.9`, Longhorn `1.8.1` — bump `targetRevision` in the Application manifests when you want upgrades.

## Example app

`apps/example-app/` is a minimal nginx Deployment + Service with a KSOPS-backed Secret. Scaffolding only — not wired into the root app yet.
