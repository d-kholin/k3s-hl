# Migrating existing PVCs to `longhorn-encrypted`

The two existing app volumes (`vaultwarden-data`, `actual-budget-data`) were
provisioned on the plain `longhorn` class. StorageClass is immutable on a PVC,
so each volume is migrated by copying data into a new PVC on the encrypted
class. Downtime is a few minutes per app.

> **Do this before the first 3 AM recurring backup fires** (or delete the
> resulting backups afterwards) — backups of *unencrypted* volumes land in S3
> as plaintext.

Steps below use vaultwarden; repeat with `actual-budget` / `actual-budget-data`.

## 1. Add the new PVC and stop the app (git)

- In `apps/vaultwarden/manifests/pvc.yaml`, add a second PVC named
  `vaultwarden-data-encrypted` — same spec as the original, plus explicit
  `storageClassName: longhorn-encrypted` and the same
  `argocd.argoproj.io/sync-options: Prune=false,Delete=false` annotation.
- In `deployment.yaml`, set `replicas: 0`.
- Commit, push, wait for Argo to sync: pod gone, new PVC `Bound`.

Don't `kubectl scale` instead — `selfHeal` reverts it.

## 2. Copy the data (kubectl)

```bash
kubectl -n vaultwarden apply -f - <<'EOF'
apiVersion: v1
kind: Pod
metadata:
  name: pvc-copy
spec:
  restartPolicy: Never
  containers:
    - name: copy
      image: alpine:3.21
      command: ["sh", "-c", "cp -a /old/. /new/ && echo DONE && ls -la /new"]
      volumeMounts:
        - { name: old, mountPath: /old }
        - { name: new, mountPath: /new }
  volumes:
    - name: old
      persistentVolumeClaim: { claimName: vaultwarden-data }
    - name: new
      persistentVolumeClaim: { claimName: vaultwarden-data-encrypted }
EOF

kubectl -n vaultwarden wait --for=jsonpath='{.status.phase}'=Succeeded pod/pvc-copy --timeout=5m
kubectl -n vaultwarden logs pvc-copy    # expect DONE + file listing
kubectl -n vaultwarden delete pod pvc-copy
```

## 3. Switch the app over (git)

- In `deployment.yaml`: `claimName: vaultwarden-data-encrypted`, `replicas: 1`.
- Remove the old PVC block from `pvc.yaml`.
  (`Prune=false` on it means Argo leaves the live object alone.)
- Commit, push, sync. Verify the app comes up with its data intact.

## 4. Clean up the old volume (manual, after verifying)

```bash
kubectl -n vaultwarden delete pvc vaultwarden-data
```

The plain `longhorn` class has `reclaimPolicy: Delete`, so this removes the
old PV and its replicas.

## 5. Verify encryption + backup

- Longhorn UI → Volume → the new volume shows `Encrypted: true`.
- Trigger a manual backup (or wait for the 3 AM job) and confirm it appears
  under Backup with the S3 target reachable.
