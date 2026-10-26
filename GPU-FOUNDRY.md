# Adding GPU Foundry to an existing installation

How to add the GPU Foundry add-on to a configuration repository that `budctl` has already
generated and Argo CD is already syncing. A new installation gets the same result from `budctl`
with the add-on switched on, and skips step 7.

Below, `<env>` is your environment's name (the one in `appsets/<env>.yaml`) and `<domain>` its
base domain.

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

### On OpenShift

The chart detects OpenShift and adapts by itself (GPU Foundry M5 D86): its pods take their user
from the namespace's `restricted-v2` SCC, and the tenant-log collector runs under an SCC the
chart creates for it. The estate also needs:

- **Kyverno chart `0.0.5` or later.** Earlier versions set user IDs that `restricted-v2`
  refuses. Use it for the `kyverno` element in `appsets/<env>.yaml`, and leave out
  `values.inject-ca.yaml` unless the estate uses a private CA.
- **`api.ingress.className: openshift-default`** and the annotation
  `route.openshift.io/termination: edge`. `values.example.yaml` says `traefik`; left as is, the
  sync fails with `could not find traefik.io/Middleware`.
- **The console's TLS Secret must exist.** This is `api.ingress.tlsSecretName` in namespace
  `gpu-foundry` (`foundry-console-tls` by default). OpenShift makes no Route for an Ingress whose
  TLS Secret is missing, and records no event saying why. Where the Secret comes from depends on
  the TLS mode:
  - **self-signed, internal CA:** nothing to do. cert-manager's CA issuer signs it from the
    `kubernetes.io/tls-acme` annotation.
  - **ACME:** use a DNS-01 issuer. The default `letsencrypt-http01` answers through a `traefik`
    Ingress, which OpenShift doesn't serve, so the certificate is never issued.
  - **externally terminated:** there is no cert-manager, so create the Secret yourself.
- **OVN's ranges in `controller.network`:** `serviceCIDR: 172.30.0.0/16`, and in
  `platformCIDRs` the pod range (`10.128.0.0/14` by default) plus every node's address.
- **`monitoring.enabled: false`** (the default here), unless user-workload monitoring is on.

Under OpenShift's router the terminal page sends no `Referrer-Policy` header; only Traefik adds it.

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
+            targetRevision: "0.5.4-rc.3"
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
| `api.ingress.className` | your ingress class: `openshift-default` on OpenShift, with the annotation `route.openshift.io/termination: edge` |
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

If they fail with `Authentication failed`, check that the users exist:

```bash
kubectl -n clickhouse exec chi-clickhouse-cluster-0-0-0 -- clickhouse-client -q "select name from system.users" | grep foundry_
```

This only happens on a single-replica ClickHouse where Bud hasn't yet created its `metrics`
database, which in practice means a new installation. There, the `clickhouse` chart's user Job
stops at that database (`Macro 'uuid' in engine arguments is only supported ... within an ON
CLUSTER query`). It still logs `Success`, but creates none of the users after `bud`, which
includes all of GPU Foundry's. Once `metrics` exists the statement is a no-op, so an existing
installation is unaffected. Re-sync `<env>-clickhouse` with a changed value to re-run the Job,
then re-run `revenue-schema`. If OpenMeter created
`revenue_metering.om_events` first, the Job prints the one `ALTER TABLE ... MODIFY TTL` statement
to run before it will pass.

Then open `https://gpu-foundry.<domain>` and sign in as a user with the realm role `super_admin`
(`root` by default). That user is GPU Foundry's platform administrator.
