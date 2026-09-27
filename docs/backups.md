# Backups — two tiers

| Tier | Tool | Cadence | What it's for |
|------|------|---------|---------------|
| File / dump level | **K8up + restic** → Backblaze B2 bucket `k8up-k3s` | nightly (`@daily-random`) | The usable tier: browse and restore single files or plain-SQL database dumps, from any machine with the credentials, even with the cluster down |
| Block level | **Longhorn** → `naku-longhorn` Garage bucket | daily 03:00 + weekly Sat 04:30 + monthly (no local-only snapshot job) | Whole-volume disaster recovery (see [disaster-recovery.md](disaster-recovery.md)) |

Both tiers store only ciphertext off-cluster: Longhorn backups are dm-crypt
volumes, and restic encrypts everything client-side with the repository
password before upload (object-store encryption is irrelevant).

## How the K8up tier is wired

- **Operator**: `infrastructure/k8up/` (Helm, wave 1). All backend settings
  are operator-level globals from the `k8up-global` secret
  (`infrastructure/k8up-config/manifests/global-secret.sops.yaml`):
  B2 S3 endpoint, the application key for bucket `k8up-k3s`, and the
  **shared restic repository password**. Losing that password means losing
  every restic backup — keep a copy wherever the offline age key lives.
- **Per app**: one `k8up-schedule.yaml` (Schedule + PodConfig) in the app's
  manifests. The Schedule only sets its bucket folder — each namespace is its
  own standard restic repo at `k8up-k3s/<namespace>`:
  nightly backup, weekly `restic check`, weekly prune with retention
  `keepLast 3 / daily 14 / weekly 5 / monthly 6`.
- **What gets backed up per namespace**: every PVC not annotated
  `k8up.io/backup: "false"`, plus the stdout of any `k8up.io/backupcommand`
  pod annotation. Postgres apps (mealie, linkwarden, dawarich, teslamate)
  dump via `pg_dump --clean` into `/<namespace>-postgres.sql`; their raw
  pgdata PVCs are annotated skip (a live file copy would be torn).
- **Consistency caveat**: vaultwarden, actual-budget, lubelogger, and
  teslamate's Grafana keep SQLite/LiteDB files that are backed up live
  (their images ship no dump CLI). WAL journaling makes a torn copy unlikely
  but not impossible — Longhorn S3 block backups (daily+) are the
  point-in-time net for those.

### Adding a new app to backups

1. Copy any `k8up-schedule.yaml` (e.g. from `apps/lubelogger/manifests/`),
   change namespace + bucket folder + the PodConfig uid to the app's
   `runAsUser`, and register it in the app's `kustomization.yaml`.
2. Give the app's `application.yaml` the `SkipDryRunOnMissingResource=true`
   + retry syncOptions (same block as the other apps).
3. Databases: add a `k8up.io/backupcommand` annotation to the pod template
   and `k8up.io/backup: "false"` to the raw DB PVC.

No B2-side work and no new credentials — the bucket and key are shared.

## Restoring

### Single files, from anywhere (works with the cluster down)

Any machine with `restic`, the repo password, and the B2 application key
(all recoverable from git + the offline age key — see
`sops -d infrastructure/k8up-config/manifests/global-secret.sops.yaml`):

```bash
export RESTIC_REPOSITORY='s3:https://s3.us-east-005.backblazeb2.com/k8up-k3s/<namespace>'
export RESTIC_PASSWORD='<BACKUP_GLOBALREPOPASSWORD>'
export AWS_ACCESS_KEY_ID='<BACKUP_GLOBALACCESSKEYID>'
export AWS_SECRET_ACCESS_KEY='<BACKUP_GLOBALSECRETACCESSKEY>'

restic snapshots                        # list; PVC snapshots have path /data/<pvc>
restic ls latest                        # browse
restic restore latest --target ./out --include '/data/<pvc>/<some/file>'
restic mount /mnt/restic                # or browse it as a filesystem
```

### Database dumps — NOT restorable via the Restore CRD

Backups made from stdin (`k8up.io/backupcommand`) can only be restored
manually — `restic dump` the SQL and pipe it into psql:

```bash
restic dump latest /<namespace>-postgres.sql | \
  kubectl -n <namespace> exec -i deploy/postgres -- \
    psql -U <POSTGRES_USER> -d <database>
```

(`pg_dump --clean` emits DROP+CREATE statements, so restoring into the live
database overwrites its objects. For a drill, restore into a scratch
database instead.)

### Whole PVC, in-cluster (Restore CRD)

For file-based snapshots only. Scale the app down, then:

```yaml
apiVersion: k8up.io/v1
kind: Restore
metadata:
  name: restore-<pvc>
  namespace: <namespace>
spec:
  podConfigRef:
    name: backup-pod
  snapshot: <snapshot-id>            # from `restic snapshots` or `kubectl get snapshots`
  restoreMethod:
    folder:
      claimName: <pvc-name>
```

Whole-volume loss (or all of Longhorn gone) can also go through the Longhorn
block-backup path in [disaster-recovery.md](disaster-recovery.md).

## Backrest — web UI (out of cluster)

[Backrest](https://github.com/garethgeorge/backrest) gives browse +
click-restore over the same repos and keeps working when the cluster is
down. Per repo add an entry with:

- Repo URI `s3:https://s3.us-east-005.backblazeb2.com/k8up-k3s/<namespace>`
- The shared repo password and the B2 application key credentials
  (hand them over out-of-band from the SOPS secret; nothing plaintext in git)

**Read-only rule: configure no prune/forget/schedule plans in Backrest.**
The cluster owns retention; two concurrent pruners fight over restic locks
(K8up's schedules assume they're the only writer). Browse, index, and
restore only.

## Backblaze B2 setup (one-time, manual)

Done in the B2 console, outside this repo:

1. Create private bucket `k8up-k3s`.
2. Create an **application key** scoped to that bucket (read+write, allow
   listing buckets). The account **master** key does **not** work with the
   S3-compatible API.
3. Note the bucket's S3 endpoint (e.g. `s3.us-east-005.backblazeb2.com`).
4. Put endpoint + key id + application key into `global-secret.sops.yaml`.

Repos are auto-initialized on first backup under `k8up-k3s/<namespace>`.

**Cutover note:** changing endpoint/bucket does not migrate existing restic
history. Prior Garage repos (`naku-k8up/<ns>`) remain readable only with the
old Garage credentials if that store is still up; new backups start fresh on
B2 unless you `restic copy` between repositories.
