# Bud Foundry configuration template

This repository is the customer-neutral base used by `budctl install` when it
initializes an empty GitOps repository. It follows the current layout and
shared deployment values from
[`BudEcosystem/infra`](https://github.com/BudEcosystem/infra), without copying
customer names, deployed environment overlays, or credentials.

Do not apply this repository directly. The shared values contain development
placeholders where the charts require a value, and they are deliberately
incomplete without an environment overlay. `budctl` generates that overlay,
creates coordinated credentials, encrypts every secret file with SOPS, and
commits the result to the operator's target repository.

## Layout

```text
apps/
└── example.yaml       # illustrative bootstrap Application
appsets/
└── example.yaml       # illustrative rendered ApplicationSet
values/
├── argocd/          # common ArgoCD scheduling values
├── bud/             # illustrative generated public Bud overlay
├── cert-manager/    # common, self-signed, ACME, and internal-CA profiles
├── clickhouse/      # Bud databases and operator scheduling
├── dapr/            # Dapr control-plane profile
├── kafka/           # Bud user and operator scheduling
├── keycloak/        # realm/client baseline and Bud theme
├── kyverno/         # private-CA injection and controller scheduling
├── mongodb/         # Bud/Novu database baseline
├── postgres/        # Bud service databases and poolers
├── seaweedfs/       # Bud buckets and S3 policy
└── valkey/           # replication, persistence and keyspace notifications
templates/
└── appset.yaml.tmpl  # canonical component inventory and ApplicationSet
```

The `example` files are documentation, not installation input. They use a
non-functional repository URL and deliberately omit secret files. During an
installation, budctl generates:

- `apps/<environment>.yaml` and `appsets/<environment>.yaml`;
- `values/<component>/values.<environment>.yaml`;
- SOPS-encrypted `values/<component>/secrets.<environment>.yaml`;
- an environment-specific rule in `.sops.yaml`.

OpenSandbox is included by default. Self-signed and imported internal-CA
installations automatically include Kyverno for CA trust injection. Public
ACME modes use cert-manager without Kyverno; externally terminated TLS omits
both. Bud Studio is the only optional add-on.

The generated ArgoCD secret values configure authenticated access to the Bud
OCI chart repository. Private Git access and internal issuing-CA key material
are also generated only as SOPS-encrypted values; this template contains no
credentials.

## Use through budctl

Run the guided installer:

```bash
budctl install
```

For a non-interactive preview:

```bash
budctl install --plan --no-prompt \
  --repo https://github.com/acme/bud-config.git \
  --environment production \
  --domain bud.example.com \
  --ingress-class nginx \
  --storage-class standard \
  --tls self-signed \
  --registry-user robot \
  --registry-password "$BUD_REGISTRY_PASSWORD" \
  --admin-email admin@example.com
```

The installer copies only its explicit allow-list of shared files and renders
`templates/appset.yaml.tmpl` into the target repository. Adding a customer
overlay—or the illustrative `example` files—does not make budctl distribute it.

## Maintaining the template

When the shared runtime values change in `BudEcosystem/infra`, copy only the
customer-neutral `values.*budruntime.yaml`, minimal profiles, and common
component values. Never copy:

- `apps/` or `appsets/` from a deployed environment;
- `values.<customer>.yaml` or `secrets.<customer>.yaml`;
- `.sops.yaml` recipients or private age identities;
- customer domains, repository URLs, credentials, capacity overrides, or
  hardware-specific service-disable flags.

After updating this repository, budctl should pin the resulting commit rather
than following a moving branch.
