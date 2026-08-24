# Monitoring and notifications

The cluster uses Argo CD's built-in notifications controller for lightweight
application-level alerting. It does not deploy Prometheus, Grafana, or a
cluster-wide metrics database.

## Email policy

The global policy applies to every Argo CD `Application`:

- a failed sync sends one email immediately for that operation;
- an `Unknown` sync status sends one email per revision;
- a `Degraded` application sends one email after 5 minutes; and
- an application that remains `Degraded` sends one escalation after 1 hour.

The 5-minute and 1-hour notifications are deduplicated using the health
transition timestamp, so reconciliation does not produce repeated mail for the
same incident. Delivery happens on an Argo CD reconciliation after the
threshold, not at an exact wall-clock second. An application that is already
degraded for more than an hour when email is first enabled can produce the
one-hour escalation once.

Argo CD derives application health from the Kubernetes resources it manages,
which covers common workload failures such as unavailable Deployments. It does
not reliably detect a Kubernetes node disappearing because Nodes are not Argo
CD-managed application resources. That check should run from the separate
outside machine so it can still alert when the cluster itself is unreachable.

## Configure SMTP

Open the encrypted Secret with SOPS:

```bash
sops infrastructure/argocd/managed/argocd-notifications-secret.sops.yaml
```

Replace all four placeholder values:

- `email-host`
- `email-from`
- `email-username`
- `email-password`

Open the encrypted subscription ConfigMap and replace
`CHANGE_ME@example.com` with the destination address:

```bash
sops infrastructure/argocd/managed/argocd-notifications-subscriptions.sops.yaml
```

The starting SMTP port in
`infrastructure/argocd/manifests/argocd-notifications-cm-patch.yaml` is 587.
Change `port` to 465 if the provider requires implicit TLS. Certificate
verification remains enabled. The destination is decrypted into the live Argo
CD ConfigMap because Argo requires a literal subscription recipient, but it
remains encrypted in Git.

Commit both files together and let the `argocd` Application reconcile them.
Inspect controller startup and delivery errors with:

```bash
kubectl -n argocd rollout status deploy/argocd-notifications-controller
kubectl -n argocd logs deploy/argocd-notifications-controller --since=10m
```

After reconciliation, send a test using any existing Argo CD application:

```bash
argocd admin notifications template notify app-health-degraded <application> \
  --recipient email:<destination-address>
```

The templates, subscriptions, and timing expressions live in
`infrastructure/argocd/manifests/argocd-notifications-cm-patch.yaml`.
