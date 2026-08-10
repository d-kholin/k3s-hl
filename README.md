# k3s-hl — GitOps for k3s + Argo CD

Minimal GitOps repository for a k3s cluster managed by Argo CD.
Secrets are encrypted with [SOPS](https://github.com/getsops/sops) + [age](https://github.com/FiloSottile/age) and decrypted in-cluster by [KSOPS](https://github.com/viaduct-ai/kustomize-sops).

## Layout

```
.
├── .sops.yaml
├── .gitignore
├── README.md
├── bootstrap/
│   └── root-app.yaml          # App-of-Apps starter (optional)
├── apps/
│   └── example-app/
└── infrastructure/            # cluster add-ons later (Newt, storage, etc.)
```

## How secrets work (SOPS + age + KSOPS)

1. **SOPS** encrypts selected fields (`data` / `stringData`) in `*.sops.yaml` files using age public keys.
2. **age** keys: Argo CD holds a private key (Secret `sops-age` in `argocd`) for automated decrypt; you hold a personal private key for local edit/encrypt.
3. **KSOPS** is a Kustomize generator plugin. Argo CD runs it so encrypted Secret manifests are decrypted at apply time — plaintext never lives in git.

## Encrypt a new secret

```bash
# 1. Write a normal Kubernetes Secret as foo.sops.yaml (plaintext stringData/data)
# 2. Encrypt in place (uses .sops.yaml recipients)
sops --encrypt --in-place path/to/foo.sops.yaml

# 3. Commit the encrypted file
git add path/to/foo.sops.yaml
```

## Edit an existing encrypted secret

```bash
# Opens your $EDITOR with decrypted content; re-encrypts on save
sops path/to/file.sops.yaml
```

## Setup checklist

- [ ] Replace the two age public key placeholders in `.sops.yaml`:
  - `AGE_PUBLIC_KEY_ARGOCD`
  - `AGE_PUBLIC_KEY_PERSONAL`
- [ ] **Back up the age private keys** offline. Loss of both keys means secrets cannot be recovered.
- [ ] Ensure Argo CD has the KSOPS plugin and the `sops-age` secret configured for decrypt.

## Example app

`apps/example-app/` is a minimal nginx Deployment + Service with a KSOPS-backed Secret. It is scaffolding only — not a real application.
