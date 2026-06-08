# Example Bud Foundry config

A starting-point config repository for installing **Bud Foundry** on Kubernetes
with [ArgoCD](https://argo-cd.readthedocs.io/). It holds the ArgoCD
ApplicationSets and the Helm values they reference. The platform's charts are
pulled from the OCI registry (`registry.bud.studio/charts`) — you do **not**
need access to the Bud source code.

> **This is an example to fork**, not to apply as-is. Applied unchanged it would
> install with placeholder credentials. Fork it, fill in your values and
> secrets, and repoint the ApplicationSets at your fork (see below).

## Layout

```
argocd/                     # ArgoCD method (other install methods can be added as sibling folders later)
├── cluster-addons.yaml     # ApplicationSet: in-cluster deps (postgres, kafka, …)
├── prod-apps.yaml          # ApplicationSet: keycloak + the bud platform
├── bud/
│   ├── values.yaml         # non-secret config: ingress host, storage class
│   └── secrets.example.yaml# secrets TEMPLATE (placeholders) — copy to secrets.yaml
└── keycloak/
    └── values.yaml
```

The `argocd/` folder isolates the ArgoCD-based install. Future install methods
(e.g. a plain Helm flow, or environment overlays) can live in sibling folders
without disturbing this one.

## How it works

Each ArgoCD Application uses **two sources**:

1. the Helm chart from `registry.bud.studio/charts`, and
2. **this repo**, referenced as `$values`, supplying the per-app `values.yaml`
   (and `secrets.yaml` for the `bud` app).

`$values` resolves to the **root of this repo**, which is why the value paths in
the ApplicationSets are `$values/argocd/<app>/values.yaml` — they include the
`argocd/` folder. If you move these files, update those paths to match, or the
sync will silently fall back to chart defaults
(`ignoreMissingValueFiles: true`).

## Use it

1. **Fork** this repo (keep your fork **private** if it will hold real secrets).
2. In both `argocd/cluster-addons.yaml` and `argocd/prod-apps.yaml`, set the
   `ref: values` source's `repoURL` to **your fork's URL**.
3. Edit `argocd/bud/values.yaml` — at minimum `global.ingress.hosts.root` and
   the `storage.*.className` values.
4. Generate your secrets (recommended) — one command produces a **coordinated**
   set across the bud chart and the stateful addons:
   ```bash
   scripts/gen-secrets.sh \
     --registry-user 'robot$yourname' \
     --registry-token '<token-from-bud>' \
     --admin-email you@yourco.com
   ```
   This writes `argocd/bud/secrets.yaml` plus `argocd/<addon>/secrets.yaml` for
   postgres/clickhouse/kafka/mongodb/valkey/seaweedfs, with matching passwords
   (the addons *create* the DB users; the bud chart *connects* with the same
   passwords — a mismatch breaks the install). The script then **renders the bud
   chart to verify the generated secrets are complete**. Re-run with `--force` to
   regenerate everything together; never hand-edit one file in isolation.
   Registry credentials are issued by Bud, so you pass them in rather than
   generate them.

   **Then commit them to your fork — this step is required.** ArgoCD delivers
   config over **git**, but `secrets.yaml` is gitignored (so it never lands in
   the public example). In your fork you must force-add them, or the bud
   Application renders with `values.yaml` only and fails with a nil-pointer:
   ```bash
   git add -f argocd/*/secrets.yaml
   git commit -m "add generated secrets" && git push
   ```
   After pushing, **hard-refresh** the ArgoCD apps (manifest errors are cached).
   Keep your fork **private**. For stronger protection, SOPS-encrypt instead and
   enable the helm-secrets plugin in your ArgoCD.

   <details><summary>Or fill the template by hand</summary>

   ```bash
   cp argocd/bud/secrets.example.yaml argocd/bud/secrets.yaml
   # replace every GENERATED_* placeholder, and create matching argocd/<addon>/secrets.yaml
   ```
   </details>
5. Register the OCI registry credential and apply the ApplicationSets — see the
   full walkthrough in the
   [Installation Guide](https://docs.budecosystem.com/developer-docs/installation).

```bash
kubectl apply -f argocd/cluster-addons.yaml
kubectl apply -f argocd/prod-apps.yaml
```

## Notes

- **In-cluster databases.** This config deploys Postgres/ClickHouse/Kafka/Mongo/
  Valkey in-cluster. The chart defaults already point the platform at them — do
  **not** set `externalServices.*.host`. (For managed/external databases, see the
  [Deployment Guide](https://docs.budecosystem.com/developer-docs/deployment).)
- **Database password consistency.** Each DB password in `secrets.yaml` must
  match the password its addon provisions — set each once, reuse the same value.
- **Registry credentials** are required even if you mirror images locally; the
  chart still creates the imagePullSecret every Deployment references.
