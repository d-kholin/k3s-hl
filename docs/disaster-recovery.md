# Disaster recovery — full cluster rebuild

Everything needed to rebuild lives in exactly two places:

1. **This git repository** — cluster config, apps, and (SOPS-encrypted) every
   secret including the volume-encryption passphrase and S3 credentials.
2. **Your personal age private key, kept offline** — the decryption root.
   Without it the encrypted secrets in git and the encrypted backups in
   Garage are unrecoverable. Verify you can find it before you need it.

Volume *data* is in the Garage S3 backup target (`garage.nakunga.com`,
Tailscale-only). Backups of `longhorn-encrypted` volumes are ciphertext;
restoring them needs the crypto secret, which comes from git + the age key.

## Rebuild procedure

### 1. Nodes

- Ubuntu + k3s, 3 nodes with embedded etcd (`--cluster-init` on the first).
- Per-node prerequisites (see README): `open-iscsi` (enabled), `nfs-common`,
  `cryptsetup`, `dm_crypt` module.
- Join each node to the tailnet: `tailscale up --accept-dns=false`
  (this is the network path to the backup target).

### 2. Argo CD + KSOPS

From a checkout of this repo:

```bash
kubectl apply -k infrastructure/argocd/manifests
kubectl -n argocd rollout status deploy/argocd-repo-server
```

This is the same kustomization Argo CD later manages itself with, so the
bootstrap install and the GitOps-managed install are identical.

### 3. The one manual secret: sops-age

The age private key is deliberately NOT in git. Restore it from the offline
copy:

```bash
kubectl -n argocd create secret generic sops-age \
  --from-file=keys.txt=/path/to/offline/age-key.txt
```

### 4. Infrastructure first — do NOT let apps create empty PVCs yet

Edit `bootstrap/root-app.yaml` **locally** and delete the `apps` entry from
`spec.sources` (leave `infrastructure`), then:

```bash
kubectl apply -f bootstrap/root-app.yaml
```

Longhorn first-install note: the chart's pre-upgrade Job is a PreSync hook
that needs a Sync-phase ServiceAccount — on a brand-new cluster sync the
longhorn app once with skip-hooks/apply-only (see
`infrastructure/longhorn/application.yaml`). Wait until `longhorn`,
`longhorn-config`, `monitoring` and `coredns-custom` are Synced/Healthy.

### 5. Restore volumes from backup

```bash
kubectl -n longhorn-system port-forward svc/longhorn-frontend 8000:80
```

In the Longhorn UI (http://127.0.0.1:8000) → **Backup**:

1. For each volume, restore the latest backup (the crypto secret from
   longhorn-config decrypts it transparently).
2. Create the target namespaces: `kubectl create ns vaultwarden actual-budget`
   (the apps will adopt + label them when they sync).
3. On each restored volume: **Create PV/PVC**, keeping the **original PVC
   name and namespace** (e.g. `vaultwarden-data-encrypted` in `vaultwarden`).

### 6. Apps

Re-apply the unmodified root app (both sources):

```bash
git checkout bootstrap/root-app.yaml
kubectl apply -f bootstrap/root-app.yaml
```

Apps sync, find their PVCs already bound to the restored data, and start.

### 7. Verify

```bash
kubectl -n argocd get applications          # all Synced/Healthy
kubectl -n vaultwarden get pods             # data present when you log in
kubectl -n longhorn-system get backuptargets.longhorn.io  # target reachable
```

Within 26 hours the `LonghornVolumeBackupTooOld` alert confirms (by staying
quiet) that backups are flowing again.

## Ongoing hygiene

- **Test-restore one volume a quarter**: restore the latest vaultwarden
  backup to a scratch name in the Longhorn UI, attach + mount it on a node
  (or spin up a throwaway pod with a PVC created from it) and check the
  files. An unverified backup is a hope, not a backup.
- After rotating age keys, re-encrypt every `*.sops.yaml` (`sops updatekeys`)
  and refresh both the `sops-age` secret and the offline copy.
- The Argo CD admin password is regenerated on reinstall:
  `kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d`
