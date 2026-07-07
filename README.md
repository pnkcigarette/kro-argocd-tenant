# KRO Argo CD Tenant

Three ResourceGraphDefinitions that onboard an Argo CD tenant end to end:

| RGD | Instance kind | Creates |
|---|---|---|
| `rgd-argocd-tenant.yaml` | `ArgoCDTenant` (one per tenant) | tenant Namespace, AppProject, admin Role/RoleBinding |
| `rgd-argocd-tenant-repo.yaml` | `ArgoCDTenantRepo` (one per repo / cred template) | VaultStaticSecret → project-scoped Argo CD repository secret |
| `rgd-argocd-tenant-cluster.yaml` | `ArgoCDTenantCluster` (one per external cluster) | plain Secret (eks/aks) or VaultStaticSecret (generic) → project-scoped Argo CD cluster secret |

Plus `platform-policies.yaml`, applied once — four Kyverno
`ValidatingPolicy` resources (`policies.kyverno.io/v1alpha1`, Kyverno
1.14+, pure CEL): project-binding enforcement for apps/appsets in tenant
namespaces, the AppProject sourceNamespaces invariant, the
system-namespace destination guard, and the cross-tenant namespace-claim
registry (via `resource.List`).

Multiple RGDs because KRO cannot fan a resource template out over a list —
a tenant with N repos/clusters is N instances, not one instance with a
list. Plain list *values* (`sourceRepos`, `destinations`) pass straight
through to the AppProject.

## Flow

1. Platform applies the RGDs and `platform-policies.yaml`; KRO serves the
   tenant APIs.
2. Tenant is onboarded with an `ArgoCDTenant` instance. That creates the
   AppProject first, then their app namespace (the Namespace carries a
   reference to the AppProject so KRO orders it after the fence exists),
   then the Role/RoleBinding granting their IdP group management of
   Applications/ApplicationSets in that namespace. The namespace's
   `indstri.com/tenant` label is what puts it under the platform
   project-binding policy — no per-tenant policy is generated.

   There is no chicken/egg window: the only namespace a tenant can write
   apps into is created by the same graph that creates their project, and
   Argo CD itself only reconciles an Application in namespace X under
   project P if `P.sourceNamespaces` contains X — since each tenant
   namespace is listed by exactly one AppProject (see the platform
   guard), claiming another project is rejected by the application
   controller regardless of Kyverno.
3. Tenant writes creds into **their** Vault namespace:
   - repos: `<mount>/<pathPrefix>/<tenant>/repos/<name>` —
     `username`/`password` or `sshPrivateKey`
   - clusters: `<mount>/<pathPrefix>/<tenant>/clusters/<name>` —
     `config` = `{"bearerToken": ..., "tlsClientConfig": {...}}`
4. `ArgoCDTenantRepo` / `ArgoCDTenantCluster` instances deploy
   VaultStaticSecrets that render those into Argo CD repository / cluster
   secrets in the Argo CD namespace.

## Namespace convention (the `tenant-*` glob)

argocd-cmd-params-cm has `application.namespaces` /
`applicationsetcontroller.namespaces` set to `tenant-*`. The RGD leans on
that instead of fighting it:

- The tenant's app namespace is **derived**, not chosen:
  `tenant-<tenant>`, and the RGD creates it. It therefore always falls
  inside the glob — no per-tenant ConfigMap edits, ever. The prefix is a
  platform invariant (the ConfigMap glob and the guards in
  `platform-policies.yaml` all assume it), so it is deliberately not a
  schema knob.
- `extraSourceNamespaces` allows additional namespaces, but a schema
  `validation` CEL rule rejects any that don't start with `tenant-`, so
  an instance can't silently reference a namespace Argo CD will ignore.

What the RGD *can't* do is edit the glob itself — KRO composes new
resources; it doesn't patch shared ConfigMaps. With the derived-namespace
convention there's nothing left to patch.

## Cluster scoping

Argo CD cluster secrets support the same `project` data field as repo
secrets. `ArgoCDTenantCluster` registers the cluster as
`<tenant>-<name>` with `project: <tenant>`, which makes it a
**project-scoped cluster**: it only resolves for that tenant's AppProject
and is invisible to all other projects — another tenant declaring the same
server URL in their destinations still has no credential to reach it.

One API covers all providers via `spec.provider`; `includeWhen` picks
exactly one cluster-secret resource per instance:

| provider | auth | secret material |
|---|---|---|
| `eks` | `awsAuthConfig` — controllers assume `eks.roleARN` via Pod Identity/IRSA | none, plain Secret |
| `aks` | `execProviderConfig` — `argocd-k8s-auth azure` with AAD workload identity | none, plain Secret |
| `generic` | bearer token / TLS from the tenant's Vault namespace | VaultStaticSecret |

eks/aks API servers present certs signed by the cluster's own CA, so
those providers require `caData` (base64 CA bundle — for EKS,
`aws eks describe-cluster --query cluster.certificateAuthority.data`);
`generic` carries its CA inside the Vault-held config JSON.

Schema-level CEL `validation` enforces the provider contract at admission:
provider enum, `https://` server, EKS role-ARN format, Azure environment
enum, `caData` required for eks/aks, `vault.namespace` required for
`generic` — and, to catch silent misconfiguration, unused provider blocks
(`eks.*`, `vault.*`, `caData` for generic) must be empty.

`ArgoCDTenant.spec.destinations` takes `"<clusterName>/<namespace>"`
entries — `in-cluster` for the local cluster, or the `<tenant>-<name>`
of an `ArgoCDTenantCluster`. `in-cluster` is rendered as a **server**
destination (`https://kubernetes.default.svc`), so apps may target it by
name or URL; external clusters are rendered **name-only**, so apps
targeting them must use `destination.name`, not `destination.server`
(a name-only project destination doesn't match a server-only app
destination). Ownership of external cluster names is checked exactly at
admission against `ArgoCDTenantCluster` instances (the RGD's own
prefix check is only a fast self-consistency hint — prefix matching
alone would let tenant `payments` reference `payments-eu-prod` belonging
to tenant `payments-eu`). Cluster-scoped resource access stays off
unless both `ArgoCDTenantCluster.spec.clusterResources` and the
AppProject `clusterResourceWhitelist` allow it.

## Namespace claims (new namespaces, shared clusters)

Destination namespaces are **explicit ownership claims, not patterns** —
tenants name namespaces freely, so allow-globs can't express ownership,
and on shared clusters two tenants could want the same name. Wildcards in
`destinations` are rejected by the RGD's own CEL validation; correctness
comes from `platform-policies.yaml` at admission:

- **System-namespace guard**: destinations may never target platform
  namespaces (`kube-*`, `argocd`, `kyverno`, `vault-secrets-operator`, …)
  or another tenant's `tenant-*` app namespace.
- **Claim registry** (`argocd-tenant-claims`): a CEL `resource.List`
  over the other `ArgoCDTenant` / `ArgoCDTenantCluster` instances denies
  a create/update that (a) reuses an existing `spec.tenant` from a
  different instance, (b) claims a destination namespace already owned by
  another tenant — **compared by server URL**, with cluster names
  resolved through the `ArgoCDTenantCluster` instances, so registering
  the same physical cluster under a different name doesn't evade the
  claim, (c) references a cluster registered by another tenant, or
  (d) claims a source namespace (derived *or* extra) owned by another
  tenant. First-come-first-claim; disputes are settled in PR review.
- **Positive claim for existing hub namespaces**: an `in-cluster`
  destination namespace that already exists must be the tenant's own or
  carry `indstri.com/tenant-deployable: "true"` — so platform namespaces
  (monitoring, ingress, cert-manager, …) are protected by default
  instead of relying on a denylist keeping up. Namespaces that don't
  exist yet are claimable; the denylist remains as the belt for external
  clusters, which the hub can't inspect.
- **Race detector**: admission checks read Kyverno's informer cache, so
  two near-simultaneous writes can both pass. The claims policy also runs
  in background mode — a conflict that slips through a race shows up in
  PolicyReports on the next scan rather than staying invisible.

Adding a namespace is therefore a PR appending one `destinations` entry.
Once admitted, the claim is exclusive, so letting the tenant's apps use
`CreateNamespace=true` is safe — Argo CD only syncs to namespaces the
AppProject lists.

## Project restriction (the tenancy boundary)

- **AppProject**: `sourceRepos`, derived `sourceNamespaces`, and
  name-based `destinations` bound what the project may do.
- **`project` field on repo *and* cluster secrets**: credentials are
  usable only by the tenant's project, even if another project's globs
  match the URL/server.
- **Platform `ValidatingPolicy` (`argocd-tenant-project-binding`)**: any
  `Application`/`ApplicationSet` in a namespace labeled
  `indstri.com/tenant=<t>` is rejected unless `spec.project` (or
  `spec.template.spec.project` for appsets) equals `<t>` — one policy for
  all tenants, keyed on the namespace label via `namespaceObject`,
  closing the apps-in-any-namespace gap of referencing someone else's
  project.

## Prerequisites / caveats

- argocd-cmd-params-cm: `application.namespaces` and
  `applicationsetcontroller.namespaces` = `tenant-*` (already in place).
- Vault Secrets Operator (v0.4+ for `transformation`) with a shared
  `VaultAuth` (default name `vault-auth`) in the Argo CD namespace whose
  Vault role can read across tenant Vault namespaces, or override
  `vault.authRef` per tenant.
- `ArgoCDTenant.spec.sourceRepos` and the `ArgoCDTenantRepo` URLs must
  stay in sync — a URL glob per tenant (e.g.
  `https://github.com/indstri/payments-*`) keeps that maintenance-free.
- `secretType: repo-creds` turns a repo instance into a credential
  template for every repo under the URL prefix. **repo-creds are not
  project-scoped in Argo CD** — any project whose `sourceRepos` matches a
  URL under the prefix gets the credentials — so only use prefixes
  unique to the tenant (org/team path, not a shared host).
- Helm OCI registries are `repoType: helm` + `enableOCI: true` with an
  `oci://` url (Argo CD has no distinct oci repo type); validation
  enforces the combination.
- `provider: aks` requires the `aks:` block to be present (`aks: {}` for
  defaults).
- The tenant Namespace is cluster-scoped while the `ArgoCDTenant`
  instance is namespaced; Kubernetes GC doesn't honor cross-scope
  ownership, so verify on your KRO version whether the Namespace is
  cleaned up on instance deletion — if not, offboarding must delete
  `tenant-<tenant>` explicitly.
- Kyverno 1.14+ for `ValidatingPolicy` (`policies.kyverno.io/v1alpha1`);
  the claims policy uses the Kyverno CEL `resource.List` library, so it
  runs in the Kyverno engine rather than compiling to a native
  ValidatingAdmissionPolicy.
- The RGD labels the derived tenant namespace `indstri.com/tenant`;
  `extraSourceNamespaces` must be given the same label at approval time
  or the project-binding policy won't cover them (Argo CD's own
  sourceNamespaces check still applies either way).
- Verify against your versions: KRO simple-schema `validation` block
  (CEL over `self`) and `status` projections; destinations-by-name
  requires the local cluster to be reachable as `in-cluster` (default in
  current Argo CD).

## Apply

```sh
# RGDs FIRST: the claims policy resource.List's argocdtenants,
# argocdtenantclusters, and namespaces — with failurePolicy Fail, a
# missing CRD locks out all tenant writes until it exists.
kubectl apply -f rgd-argocd-tenant.yaml \
              -f rgd-argocd-tenant-repo.yaml \
              -f rgd-argocd-tenant-cluster.yaml
kubectl wait --for condition=established \
  crd/argocdtenants.kro.run crd/argocdtenantclusters.kro.run
kubectl apply -f platform-policies.yaml
kubectl apply -f examples/tenant-payments.yaml   # sample tenant
```

Note the claims policy fails closed: if Kyverno can't list
`argocdtenants`, tenant creates/updates are denied, not silently
allowed. The ClusterRole in `platform-policies.yaml` aggregates into
`kyverno:admission-controller` via
`rbac.kyverno.io/aggregate-to-admission-controller: "true"` (Kyverno
1.11+; the `app.kubernetes.io/*` labels cover older charts). Verify with:

```sh
kubectl auth can-i list argocdtenants.kro.run \
  --as system:serviceaccount:kyverno:kyverno-admission-controller
```
