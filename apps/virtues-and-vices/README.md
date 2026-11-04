# Virtues & Vices

Image: `ghcr.io/d-kholin/virtues-and-vices:1.5` (Linux amd64).
Public URL: `https://habits.thegriffiths.ca`.

## Routing and sign-in

Create a Pangolin resource for `habits.thegriffiths.ca` targeting
`http://virtues-and-vices.virtues-and-vices.svc.cluster.local:5173` through
Newt. Preserve the original host and send `X-Forwarded-Proto: https`.
The app trusts one reverse proxy; only the Newt namespace can reach it.
Pocket ID handles authentication in the app. Configure the OIDC client callback
as `https://habits.thegriffiths.ca/auth/callback`. Both approved subject IDs,
the client credentials, and a generated session secret are in the SOPS Secret.
Demo mode is explicitly disabled. The hostname is registered in the encrypted
Cloudflare DDNS domain list; Pangolin routing is configured outside this repo.

## Storage and backups

A retained 1Gi encrypted Longhorn PVC stores `/app/data/app.sqlite` and WAL files.
A single replica with Recreate updates prevents concurrent writers.
Nightly K8up backups use Node's SQLite online backup API, writing a consistent
SQLite database to stdout. Raw live PVC file backups are disabled. The backup
script is mounted from a generated ConfigMap; changing it rolls the Deployment.
The restic repository is `naku-k8up/virtues-and-vices` with standard retention.
Longhorn also supplies the cluster's block backup tier.

To restore, find the `.sqlite` dump path with `restic ls latest`, export it with
`restic dump latest <dump-path> > app.sqlite`, stop the Deployment, and replace
`/app/data/app.sqlite` on the PVC. Remove old `app.sqlite-wal` and
`app.sqlite-shm` files while the app is stopped, restore ownership to UID/GID
1000, then start the Deployment. A dump contains habit data and sessions;
restore it only into this household's trusted environment.
