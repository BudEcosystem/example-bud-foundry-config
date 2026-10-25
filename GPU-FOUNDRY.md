# Adding GPU Foundry to an existing installation

How to add the GPU Foundry add-on to a configuration repository that `budctl` has already
generated and Argo CD is already syncing. A new installation gets the same result from `budctl`
with the add-on switched on, and skips step 7.

Proven on 2026-10-25 against the `tcs-vmware` estate: chart `gpu-foundry` `0.5.4-rc.2`, Keycloak
chart `0.2.1` (operator 26.6.1), Kyverno chart `0.0.2`. Below, `<env>` is your environment's
name (the one in `appsets/<env>.yaml`) and `<domain>` its base domain.

## What it installs

| Argo Application | What |
|---|---|
| `<env>-gpu-foundry` | GPU Foundry's platform chart, in namespace **`gpu-foundry`** (the chart refuses any other). It carries its own CRDs, RBAC, Kyverno policies and release image digests |
| `<env>-gpu-foundry-kueue` | Kueue `0.14.4`, in `kueue-system`, its job webhooks limited to GPU Foundry's project namespaces |
| `<env>-postgres`, `<env>-clickhouse`, `<env>-keycloak` | each gains a `values.gpu-foundry.yaml`: five database roles, seven ClickHouse users, one Keycloak client |

Before you start:

- **Kyverno must be installed**, because the chart ships Kyverno policies. Self-signed and
  internal-CA installations already have it. ACME and externally terminated TLS installations
  must add the `kyverno` element from `templates/appset.yaml.tmpl`, without `values.inject-ca.yaml`.
- **Your registry account needs pull access** to the `gpu-foundry` project on `registry.bud.studio`,
  as well as `runtime` and `charts`. Without it every platform image fails with `401`.
- If your Argo CD requires OCI Helm repositories to be registered, register
  `registry.k8s.io/kueue/charts`.

## 1. Copy the shared files

Copy these unchanged from this repository:

```text
values/postgres/values.gpu-foundry.yaml
values/clickhouse/values.gpu-foundry.yaml
values/keycloak/values.gpu-foundry.yaml
values/gpu-foundry/values.budruntime.yaml
values/gpu-foundry/values.minimal.yaml
values/gpu-foundry/values.inject-ca.yaml     # self-signed and internal-CA installations only
values/kueue/values.yaml
scripts/gpu-foundry-keycloak-client.sh
```

## 2. Edit `appsets/<env>.yaml`

Add each `values.gpu-foundry.yaml` **before** the component's `secrets.<env>.yaml`, so your real
passwords override the placeholders. Then add the two Applications at the end of the list.

```diff
           - name: clickhouse
             valueFiles:
               - "example.minimal.yaml"
               - "$values/values/clickhouse/values.budruntime.yaml"
+              - "$values/values/clickhouse/values.gpu-foundry.yaml"
               - "$values/values/clickhouse/secrets.<env>.yaml"
           - name: postgres
             valueFiles:
               ...
               - "$values/values/postgres/values.minimal.budruntime.yaml"
+              - "$values/values/postgres/values.gpu-foundry.yaml"
               - "$values/values/postgres/secrets.<env>.yaml"
           - name: keycloak
             valueFiles:
               - "$values/values/keycloak/values.budruntime.yaml"
+              - "$values/values/keycloak/values.gpu-foundry.yaml"
               - "$values/values/keycloak/values.<env>.yaml"
               - "$values/values/keycloak/secrets.<env>.yaml"
           ...
+          - name: gpu-foundry
+            namespace: gpu-foundry
+            repoURL: registry.bud.studio/charts
+            chart: gpu-foundry
+            targetRevision: "0.5.4-rc.2"
+            valueFiles:
+              - "$values/values/gpu-foundry/values.budruntime.yaml"
+              - "$values/values/gpu-foundry/values.minimal.yaml"
+              - "$values/values/gpu-foundry/values.inject-ca.yaml"   # self-signed / internal CA only
+              - "$values/values/gpu-foundry/values.<env>.yaml"
+              - "$values/values/gpu-foundry/secrets.<env>.yaml"
+          - name: gpu-foundry-kueue
+            namespace: kueue-system
+            repoURL: registry.k8s.io/kueue/charts
+            chart: kueue
+            targetRevision: "0.14.4"
+            valueFiles:
+              - "$values/values/kueue/values.yaml"
```

## 3. Write `values/gpu-foundry/values.<env>.yaml`

Start from `values/gpu-foundry/values.example.yaml`, and set:

| Value | Set to |
|---|---|
| `api.publicOrigin`, `api.terminalOrigin`, `api.ingress.host` | `https://gpu-foundry.<domain>` (and `/terminal`); the host must resolve to your ingress |
| `api.ingress.className` | your ingress class |
| `api.oidc.issuer` | `https://auth.<domain>/realms/bud-keycloak` |
| `api.tenancyProfile` | `internal-a` (tenants trust each other) or `csp-b` (they don't). Fixed for each organisation when it's created |
| `api.cells`, `controller.cells` | this cluster as one cell, the same `id` and `region` in both |
| `controller.network.serviceCIDR`, `platformCIDRs` | the service range; the pod range plus **every node's address** (`kubectl get nodes -o wide`) |

## 4. Add the client's hostnames to `values/keycloak/values.<env>.yaml`

```yaml
realms:
  keycloak-bud-keycloak-realm:
    clients:
      gpu-foundry-console:
        attributes:
          post.logout.redirect.uris: https://gpu-foundry.<domain>/*
        redirectUris:
          - https://gpu-foundry.<domain>/bff/callback
        webOrigins:
          - https://gpu-foundry.<domain>
```

## 5. Add the secrets (SOPS)

Edit the existing files with `sops`, and create the GPU Foundry one with the rule in `.sops.yaml`.

| File | Add |
|---|---|
| `values/postgres/secrets.<env>.yaml` | `users.foundry-{identity,platform,revenue,openmeter,lago}.password` |
| `values/clickhouse/secrets.<env>.yaml` | `users.foundry_logs_{schema,collector,reader,recorder}.password`, `users.foundry_revenue_{schema,writer,reader}.password` |
| `values/keycloak/secrets.<env>.yaml` | `realms.keycloak-bud-keycloak-realm.clients.gpu-foundry-console.secret` |
| `values/gpu-foundry/secrets.<env>.yaml` (new) | every key listed at the top of `values/gpu-foundry/values.example.yaml`, with the passwords above repeated under `secrets.postgres`, `secrets.clickhouse` and `secrets.oidcClientSecret` |

**`ssh.caKey` and `ssh.caPub` are required,** as well as `ssh.hostKey`. Without the CA pair the
access gateway serves no SSH, and its sshpiperd sidecar crash-loops until the pair is added and
the gateway restarted.

## 6. Commit, then sync in this order

Sync from the Argo CD UI or `argocd app sync`. Both apply the Application's own sync options,
`CreateNamespace=true` and `ServerSideApply=true`, which Kueue needs: its CRDs are too large for
a client-side apply, and its namespace doesn't exist yet. A hand-written sync operation must
name them itself.

1. The bootstrap Application, so the ApplicationSet creates the two new Applications.
2. `<env>-postgres`, `<env>-clickhouse`, `<env>-keycloak`.
3. `<env>-gpu-foundry-kueue`. Wait until it's Healthy, and
   `kubectl get apiservice v1beta1.visibility.kueue.x-k8s.io` reports Available.
4. `<env>-gpu-foundry`. **If the first sync fails with `CRD is not established`, sync again.**
   Argo checked the new CRDs before the API server had established them, and the later waves
   didn't run. The second sync completes them.

## 7. Create the Keycloak client

```bash
scripts/gpu-foundry-keycloak-client.sh
```

**Required on every existing installation.** The Keycloak operator imports realms with
`--override=false`, so a realm that already exists is skipped whole. The client from step 4 is
never created, and sign-in fails at Keycloak with `Client not found`.

The script reads everything it needs from the cluster (the console's origin, the realm, the
client secret, and Keycloak's admin credentials), then creates or updates the client. It's safe
to run again. It needs `kubectl` and `jq`.

## 8. Verify

```bash
kubectl -n argocd get applications | grep gpu-foundry            # Synced, Healthy
kubectl -n gpu-foundry get pods                                  # all Running; access-gateway 2/2
kubectl -n gpu-foundry-revenue get jobs                          # lago-migrate, revenue-schema: Complete
kubectl -n gpu-foundry-tenant-logs get jobs                      # tenant-logs-schema: Complete
```

`revenue-schema` and `tenant-logs-schema` log in as each ClickHouse user and check its grants,
so their completing proves step 5's ClickHouse passwords and this repository's grants.

Then open `https://gpu-foundry.<domain>` and sign in as a user with the realm role `super_admin`
(`root` by default). That user is GPU Foundry's platform administrator.
