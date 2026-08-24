# k3s-hl

`k3s-hl` is the GitOps source of truth for a private k3s homelab cluster. Argo CD continuously reconciles the cluster from this repository, including shared infrastructure and namespaced workloads.

The cluster is designed around private-by-default networking, encrypted persistent storage, layered backups, and encrypted configuration in Git. Workload services remain inside the cluster and are published through Pangolin and redundant Newt tunnels; the cluster does not use public `LoadBalancer` services or MetalLB.

## Architecture

```text
Git repository
└── Argo CD root Application
    ├── infrastructure/  → cluster-wide services and configuration
    └── apps/            → one child Application per workload
```

- **GitOps:** Argo CD tracks the repository's default branch through `HEAD`, creates child Applications, and automatically prunes drift and self-heals managed resources.
- **Networking:** Workloads normally expose `ClusterIP` Services. NetworkPolicies restrict traffic, while Pangolin and Newt provide external access.
- **Storage:** Longhorn supplies replicated persistent volumes. The default StorageClass encrypts volumes with dm-crypt and retains them when claims are removed.
- **Secrets:** SOPS encrypts secrets with age before they enter Git. Argo CD uses KSOPS to decrypt them only while rendering manifests.
- **Backups:** Longhorn provides block-level disaster-recovery backups, while K8up provides file- and database-level restic backups.
- **Observability:** Argo CD Notifications provides lightweight email alerting for application health and sync failures. Node availability still requires an out-of-cluster check.

## Repository structure

```text
.
├── .github/workflows/          # Pull-request validation
├── bootstrap/
│   └── root-app.yaml           # Argo CD root Application
├── infrastructure/
│   ├── kustomization.yaml      # Active infrastructure Applications
│   └── <component>/
│       ├── application.yaml    # Argo CD child Application
│       ├── values.yaml         # Helm values, when applicable
│       └── manifests/          # Additional Kubernetes resources
├── apps/
│   ├── kustomization.yaml      # Workload Applications
│   └── <workload>/
│       ├── application.yaml    # Argo CD child Application
│       └── manifests/          # Workload resources
├── docs/                       # Operational and recovery runbooks
├── scripts/                    # Node setup and CI validation helpers
├── .sops.yaml                  # SOPS creation and age recipient rules
└── renovate.json               # Automated dependency update policy
```

The two top-level Kustomizations are an app-of-apps index: they contain Argo CD `Application` resources rather than the workloads themselves. Each child Application points back to its own directory in this repository and is reconciled independently.

## Application structure

Each workload lives in `apps/<workload>/` and owns its full Kubernetes definition. A typical directory looks like this:

```text
apps/<workload>/
├── application.yaml
└── manifests/
    ├── kustomization.yaml
    ├── namespace.yaml
    ├── deployment.yaml
    ├── service.yaml
    ├── networkpolicy.yaml
    ├── pvc.yaml                 # Stateful workloads only
    ├── k8up-schedule.yaml       # Backup-enabled workloads only
    ├── secret.sops.yaml         # Encrypted configuration only
    └── ksops-generator.yaml     # Includes encrypted resources
```

Only `application.yaml` and `manifests/kustomization.yaml` are universal. The remaining files are included when the workload needs them; more complex workloads may have several Deployments, Services, PVCs, or internal data stores.

### Workload conventions

- Every workload has an explicit namespace managed in Git.
- Namespaces use the restricted Pod Security Standard by default. Any baseline or privileged exception is declared explicitly for software that cannot run under the restricted profile.
- Containers use explicit, readable image tags. Renovate proposes version updates through pull requests.
- Deployments are expected to define resource requests and limits, health probes, and hardened security contexts where supported by the image.
- User-facing services are normally `ClusterIP` and protected by default-deny NetworkPolicies. External routing is handled by the tunnel layer.
- Stateful workloads use `longhorn-encrypted` PVCs. Namespace and PVC resources carry `Prune=false,Delete=false` where deletion would risk persistent data.
- Backup-enabled workloads define their K8up schedule beside the application manifests so backup behavior changes with the workload.
- Argo CD child Applications use automated pruning, self-healing, and retry policies.

To add a workload, create its Application and manifests, then add `apps/<workload>/application.yaml` to `apps/kustomization.yaml`. A pull request must render and validate successfully before it can be merged.

## Cluster infrastructure

The active infrastructure layer provides:

- Argo CD, including KSOPS secret rendering and email notifications for unhealthy Applications.
- Longhorn, an encrypted default StorageClass, snapshot support, and recurring block backups.
- K8up and shared backup-target configuration for restic-based workload backups.
- Custom CoreDNS configuration needed for private cluster dependencies.

## Storage, backups, and recovery

`longhorn-encrypted` is the default StorageClass. It uses three Longhorn replicas, dm-crypt encryption, volume expansion, and a `Retain` reclaim policy. Each k3s node that hosts Longhorn replicas needs iSCSI, NFS, cryptsetup, and the required kernel modules; [`scripts/node-setup.sh`](scripts/node-setup.sh) installs and verifies those prerequisites on Debian or Ubuntu nodes.

The backup design has two complementary layers:

- **K8up/restic** captures recoverable files and database dumps into per-workload repositories.
- **Longhorn** sends recurring encrypted block backups to S3-compatible object storage for full-volume recovery.

The age private key is part of the recovery chain because it unlocks the encrypted storage and backup credentials. Keep a tested offline copy outside the cluster.

See the runbooks for operational detail:

- [Backup architecture and restore procedures](docs/backups.md)
- [Full-cluster disaster recovery](docs/disaster-recovery.md)
- [Encrypted-volume migration](docs/encrypted-volume-migration.md)
- [Monitoring and Argo CD email notifications](docs/monitoring.md)

## Secrets

Files named `*.sops.yaml` contain SOPS-encrypted Kubernetes Secrets. `.sops.yaml` defines which fields are encrypted and which age recipients can decrypt them. KSOPS generators include those files in Kustomize without committing plaintext to the repository.

The age private key used by Argo CD is the one intentionally manual cluster secret:

```bash
kubectl -n argocd create secret generic sops-age \
  --from-file=keys.txt=/path/to/offline/age-key.txt
```

Create or edit encrypted secrets locally with SOPS:

```bash
sops --encrypt --in-place path/to/secret.sops.yaml
sops path/to/secret.sops.yaml
```

Never commit a decrypted secret. CI checks SOPS files and the Secret references produced by the rendered manifests.

## Bootstrap

On a fresh k3s cluster:

```bash
# Install Argo CD with the KSOPS-enabled repository server.
kubectl apply -k infrastructure/argocd/manifests

# Create the sops-age Secret using the offline private key.
kubectl -n argocd create secret generic sops-age \
  --from-file=keys.txt=/path/to/offline/age-key.txt

# Start reconciliation of infrastructure and workloads.
kubectl apply -f bootstrap/root-app.yaml
```

For a rebuild that restores existing data, follow the [disaster-recovery runbook](docs/disaster-recovery.md) instead of the basic bootstrap sequence.

## Validation and change workflow

Changes to `master` go through pull requests. Branch protection requires the **Render and validate manifests** status check, requires the branch to be current before merge, and blocks direct and force pushes.

The validation workflow:

- renders every Kustomization with the same Kustomize version used by the cluster's KSOPS integration;
- validates rendered Kubernetes resources with kubeconform;
- verifies encrypted Secret references and rejects unencrypted SOPS files; and
- checks critical rendered invariants that must remain consistent across related manifests.

The workflow is defined in [`.github/workflows/validate.yaml`](.github/workflows/validate.yaml), with repository-specific checks under [`scripts/`](scripts/).
