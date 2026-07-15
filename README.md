# KRO Argo CD Tenancy

Self-service Argo CD multi-tenancy built from KRO ResourceGraphDefinitions
and Kyverno ValidatingPolicies.

**Vocabulary:** a **tenant** is the org/team rollup (e.g. `teamx`) — a
label + field convention, not a CR. A **project** is the onboarding unit
(e.g. `appa`): one instance = one Argo CD AppProject (`teamx-appa`) + one
source namespace (`tenant-teamx-appa`) + one claim set. A team with three
apps onboards three projects sharing the same `tenant`.

| File | Instance kind | Creates |
|---|---|---|
| `rgd-argocd-project.yaml` | `ArgoCDProject` (one per unit) | source Namespace, AppProject, admin Role/RoleBinding, optional bootstrap Application |
| `rgd-argocd-project-repository.yaml` | `ArgoCDProjectRepository` (one per repo / cred template) | VaultStaticSecret → project-scoped Argo CD repository secret |
| `rgd-argocd-cluster.yaml` | `ArgoCDCluster` (one per physical cluster, **platform-registered, global**) | plain Secret (eks/aks), VaultStaticSecret (generic), or registry-only (agent) |
| `examples/argocd-rbac-cm.yaml` | — | static Argo CD RBAC (Option A): global settings-read; see RBAC model |
| `platform-policies-rbac-generator.yaml` | — | OPTIONAL Option B: per-project RBAC CSV generator (deploy later if needed) |

Plus `platform-policies.yaml`, applied once — eight Kyverno
`ValidatingPolicy` resources (`policies.kyverno.io/v1`, verified on
Kyverno v1.18, pure CEL) and the aggregated RBAC they need. Multiple RGDs
because KRO cannot fan a resource template out over a list — N repos is N
instances; plain list *values* pass straight through.

## Flow

1. Platform applies the RGDs and policies (see Apply below) and registers
   shared clusters (`ArgoCDCluster`) once each.
2. A team is onboarded with one `ArgoCDProject` per unit. Each creates the
   AppProject first, then the source namespace (ordered via reference),
   then RBAC — and, when `bootstrap.repoUrl` is set, a **bootstrap
   Application** (app-of-apps) that syncs the team's
   Application/ApplicationSet manifests from `repoUrl:path` (default path
   `argo-apps`) into the source namespace. Argo CD auto-detects plain
   manifests / kustomize / helm at that path, so the platform never
   dictates app tooling. Two opt-in tool knobs (mutually exclusive):
   `bootstrap.helmValueFiles` for **monorepo app-of-apps Helm charts with
   per-ENV overrides** — one chart serves every env project, each
   project's bootstrap selects its env values (e.g. `["values.yaml",
   "envs/dev.yaml"]`, relative paths within the repo) — and
   `bootstrap.recurse: true` for plain-manifest paths organized in
   subdirectories. Omit both for kustomize or single-dir manifests
   (auto-detect). From then on, adding an app = a PR to the team's
   repo; the namespace Role is break-glass.
3. The team writes repo creds into **their** Vault namespace at
   `<mount>/<pathPrefix>/<tenant>/<project>/repos/<name>`
   (`username`/`password` or `sshPrivateKey`); `ArgoCDProjectRepository`
   instances sync them into project-scoped repository secrets.
4. Generic (non-cloud-identity) cluster creds live in the **platform**
   Vault namespace at `<mount>/<pathPrefix>/clusters/<name>`
   (key `config`).

There is no chicken/egg: the only namespace a project can put apps in is
created by the same graph that creates its AppProject, Argo CD only
reconciles an Application in namespace X under AppProject P if
`P.sourceNamespaces` contains X, and the bootstrap app is machine-created
by the RGD.

## Shared clusters (the claim model)

Clusters are **global**: registered exactly once per physical cluster
(one-per-server enforced, name/server immutable) and shared by any
project. Argo CD's AppProject `destinations` — (cluster, namespace)
tuples built *only* from validated claims — are the per-project gate.

- **Claims**: `ArgoCDProject.spec.destinations` entries
  (`"<clusterName>/<namespace>"`) are explicit, exclusive,
  first-come-first-claim namespace ownership records. No globs (Argo CD
  treats destination namespaces as glob patterns, so `[?*` are rejected).
  projectA and projectB share a cluster and differ by namespace.
- **Anti-squatting prefix**: new destination namespaces must be prefixed
  `"<tenant>-"` (`teamx-appa-dev`, not `dev`) — generic-name landgrabs
  are impossible by construction. Pre-existing namespaces (brownfield)
  are claimable once the platform labels them
  `example.com/tenant-deployable: "true"`.
- **Existence**: destinations must reference a registered `ArgoCDCluster`
  (or `in-cluster`) — clusters pre-exist projects.
- **Blast radius**: the shared cluster credential is broad, so projects
  set `syncServiceAccount` — rendered as AppProject
  `destinationServiceAccounts`, Argo CD impersonates that remote SA when
  syncing, restoring per-project limits on the destination cluster.
- **`labels`** on `ArgoCDCluster` merge into the cluster secret's
  metadata (for ApplicationSet cluster generators). Platform keys win on
  merge; reserved prefixes (`argocd.argoproj.io/`, `example.com/`) are
  rejected at admission.
- **Race detector**: admission reads Kyverno's informer cache, so
  near-simultaneous writes can race; claim policies also run in
  background mode and surface conflicts in PolicyReports.
- **argocd-agent clusters (`provider: agent`)**: workload clusters
  connected via [argocd-agent](https://argocd-agent.readthedocs.io/)
  with **destination-based mapping** register here too — registry-only
  (no secret is rendered; `argocd-agentctl agent create` owns the
  principal-side cluster secret, certs, and any generator labels).
  `spec.name` MUST equal the agent name: the principal routes an
  AppProject to agents matching `.spec.destinations[].name`, and our
  claim-built, name-form destinations are exactly that — a project
  claiming `agent-east/teamx-appb-edge` gets its AppProject shipped to
  agent-east, where the preserved `sourceNamespaces` then bound app
  placement. `server` is the mandatory synthetic
  `https://<name>.agent.internal` (agents dial out; never dialed) so the
  one-per-server and immutability invariants hold unchanged, and claims,
  existence checks, and the referential delete-guard all apply to agent
  clusters exactly as to credentialed ones.

### Cluster provider spec matrix

| provider | required spec | forbidden spec | renders |
|---|---|---|---|
| `eks` | `name`, `server` (real API URL), `caData`, `eks.clusterName`, `eks.roleARN` | `aks`, `vault`, `agent` | plain Secret (IAM auth) |
| `aks` | `name`, `server` (real API URL), `caData`, `aks.environment` | `eks`, `vault`, `agent` | plain Secret (workload identity) |
| `generic` | `name`, `server` (real API URL), `vault.namespace` | `caData`, `eks`, `aks`, `agent` | VaultStaticSecret |
| `agent` | `name` (= agent name), `server` = `https://<name>.agent.internal`, `agent.mode` | `caData`, `eks`, `aks`, `vault`, `labels` | **nothing** (registry-only) |

**Default → agent migration is a one-line, in-place, tenant-invisible
change.** Clusters onboard credentialed by default; to move one behind
argocd-agent later, update the same instance: `provider: agent`, `server`
to the synthetic URL, drop the credential block, add `agent.mode`. This
is the ONE sanctioned `server` mutation (policy-enforced); KRO prunes the
old credential secret automatically. `spec.name` — and therefore every
project's claims and destinations — is unchanged, so tenants notice
nothing. The reverse (agent → credentialed) is not sanctioned in place:
delete and re-register.

## Project restriction (the tenancy boundary)

- **AppProject**: `sourceRepos`, derived `sourceNamespaces`, and
  claim-built `destinations` bound what each project may do. `in-cluster`
  destinations get a server-form entry too; the project's own source
  namespace is always appended so the bootstrap app-of-apps works.
- **Repository entries are project-scoped; repo-creds are tenant-scoped.**
  `secretType: repository` (the default) renders a secret carrying
  `project: <tenant>-<name>` (usable only by that AppProject) and
  **requires** `spec.project`. `secretType: repo-creds` is a credential
  *template* matched by URL prefix — it is NOT project-scoped in Argo CD
  and serves every project of the tenant whose `sourceRepos` match the
  prefix, so it **forbids** `spec.project`, renders as a tenant asset
  (`repo-creds-<tenant>-<name>`, Vault path
  `<mount>/<pathPrefix>/<tenant>/repo-creds/<name>`, tenant label only),
  and is **not** coupled to any project's lifecycle (offboarding a
  project won't ask you to delete it; it's torn down with the tenant).
  Use tenant-unique prefixes only.
- **Attaching one URL to a second project** (Argo CD repo entries are 1:1
  with an AppProject) is a second lightweight instance — use
  **`credType: none`**: a metadata-only project-scoped entry (no
  credentials, no Vault) whose creds resolve from the tenant's repo-creds
  template. One credential in Vault, N project attachments.
- **`argocd-project-binding`**: any Application/ApplicationSet in a
  namespace labeled `example.com/tenant` + `example.com/project` must set
  `spec.project` to `<tenant>-<project>` — readable failure at admission;
  Argo CD `sourceNamespaces` is the hard backstop.
- **`tenant-*` is a reserved namespace prefix**: every such namespace
  must be named `tenant-<tenant>-<project>` with matching labels, so an
  unlabeled/mislabeled namespace can't evade the label-matched binding.
- **AppProject guard**: no glob sourceNamespaces anywhere; labeled
  AppProjects may only list namespaces belonging to their own label pair.

## RBAC model (LDAP groups)

Two layers:

- **Global (`examples/argocd-rbac-cm.yaml`, static — Option A)**: every
  authenticated user gets metadata-level read on Settings objects
  (projects/clusters/repos specs and status; never credentials). No
  applications/logs globally.
- **Per-project (AppProject roles, rendered by the RGD)**: `viewer`
  (applications/applicationsets/logs get) and `admin` ("limited write":
  get, sync, action/*, update, override + logs — deliberately NO
  create/delete, app lifecycle flows through the bootstrap repo, and NO
  exec), both scoped `<tenant>-<name>/*`.

Groups are **derived** from `assigneeGroup` (SNOW ITSM, recorded
verbatim as the `assignee_group` annotation on the source namespace) and
`environment`. Normalization: lowercase, strip `_` and spaces —
`"APP_Team X"` → `appteamx`:

| environment | viewer | admin |
|---|---|---|
| dev / it / qa | `paas_appteamx` | `paas_appteamx` |
| uat | `paas_appteamx` | `paas_emerid_appteamx_nonprod` |
| prod | `paas_appteamx` | `paas_emerid_appteamx_prod` |

`viewerGroup`/`adminGroup` are one-off OVERRIDES: empty (default) means
derived; set means used verbatim (charset excludes commas/whitespace —
values flow into policy strings). The derived values are also published
as `example.com/viewer-group` / `example.com/admin-group` annotations on
the AppProject for machine consumers. Environments never share clusters
outside the DEV/IT/QA, UAT, PROD breakouts, so a project's single
`environment` is always accurate.

**Option B (deploy later if settings metadata becomes sensitive):**
`platform-policies-rbac-generator.yaml` — a Kyverno mutate-existing
ClusterPolicy that maintains `policy.projects.csv` in `argocd-rbac-cm`
as a pure function of the labeled AppProjects (per-project
`projects get` + `repositories get` viewer roles bound to the annotated
groups). Level-triggered: create/update/delete of a project regenerates
the key; no add/remove bookkeeping. Swap `policy.default` out of the
static CM when deploying it. Verified live incl. removal-on-delete.

## Labels (ownership rollup)

Everything rendered carries `example.com/tenant` + `example.com/project`.
Rollup queries: `kubectl get appprojects,ns,vaultstaticsecrets -A -l
example.com/tenant=teamx`. Clusters are shared infra and carry
`example.com/cluster` instead; "who uses cluster X" is answered by the
claim registry (`ArgoCDProject` destinations).

## Day-2 operations

- **Renames are blocked, not silent data-loss.** `spec.tenant`/`spec.name`
  on projects (and repo/cluster identity fields) are immutable — KRO's
  applyset would prune-and-recreate the namespace/AppProject/secrets.
  Delete and recreate to rename.
- **Offboarding order — children first.** The referential guard denies
  deleting a project while its `ArgoCDProjectRepository` instances exist:

  ```sh
  kubectl delete argocdprojectrepositories -n argocd \
    -l example.com/tenant=<tenant>,example.com/project=<name>
  kubectl delete argocdproject <tenant>-<name> -n argocd
  ```

- **Cluster deletion is guarded**: an `ArgoCDCluster` cannot be deleted
  while any project lists it in destinations — remove those destinations
  first. (No deadlock: clusters are not children of projects.)
- **Policy updates on a live cluster are safe**: `create-or-spec-changed`
  matchConditions mean KRO's reconcile (metadata-only applies) won't
  re-deny grandfathered instances; background eval reports pre-existing
  violations instead of blocking.
- **Removing a claim** releases the namespace record but does not delete
  the namespace on the target cluster; clean up out of band.
- **Shared assets are decoupled from single-project lifecycles.** A
  tenant `repo-creds` template serves multiple projects, so it does not
  block any one project's deletion — but that also means deleting or
  rotating it affects every project of the tenant using the prefix
  (including `credType: none` attachments). Coordinate rotation; there is
  no admission guard because rotation is legitimate. Likewise a shared
  `ArgoCDCluster` can't be deleted while *any* project references it in
  `destinations` — decommissioning it means removing that destination
  from every referencing project first (the referential guard lists who).
- **Changing `environment` (or `assigneeGroup` / the group overrides)
  rotates derived RBAC in place.** These are mutable; editing them
  re-derives the AppProject viewer/admin groups on the next reconcile
  (correct — supports a project reassignment) but silently changes *who
  has access*. Treat as a controlled operation: review the derived
  groups after the change. If you instead want an environment to be
  fixed for a project's life, model it as a separate project
  (`teamx-appa-prod` vs `teamx-appa-dev`) rather than mutating one.

## Enforcement surfaces (what's guarded where)

The tenancy boundary is enforced on **both** the KRO CRs and the objects
Argo CD actually reads:

- **CR path** (`ArgoCDProject` etc.): claims uniqueness, cluster
  existence, prefix/immutability — `argocd-project-claims` +
  `argocd-project-destination-guard`.
- **Effective-object path** (the rendered AppProject): `sourceNamespaces`
  AND `destinations` are re-validated against the owning project's claims
  by `argocd-appproject-guard` — so a direct AppProject edit that widens
  destinations to another tenant is denied at admission, not merely
  reverted by KRO drift-reconciliation.

**Platform hardening prereqs (outside these RGDs):** `argocd-project-binding`
matches only namespaces labeled `example.com/tenant`+`example.com/project`,
so Applications created **in the `argocd` namespace itself** are not
covered by it — they are backstopped only by Argo CD's `sourceNamespaces`
and by the stock `default` AppProject. Tenants have no RBAC in `argocd`,
so this isn't tenant-reachable, but as standard Argo CD hardening you
should (a) lock down the `default` project (narrow its `destinations` /
`sourceNamespaces`, or delete it) and (b) restrict who can create
Applications in the `argocd` namespace. Rendered repo/cluster **Secrets**'
`project` field is likewise enforced on the CR + kept correct by KRO
drift-reconciliation, not admission-guarded on the Secret itself (same
direct-edit class as AppProject destinations; not tenant-reachable).

## Prerequisites / caveats

- Argo CD apps-in-any-namespace: `application.namespaces` and
  `applicationsetcontroller.namespaces` = `tenant-*` in
  argocd-cmd-params-cm (managed centrally; the derived namespaces always
  match). Local cluster reachable as `in-cluster`; project sync
  impersonation (`destinationServiceAccounts`) needs Argo CD ≥ 2.13.
- Vault Secrets Operator (v0.4+) with a shared `VaultAuth`
  (default `vault-auth`) in `argocd`.
- KRO v0.9.2 verified (KIND): field markers only (no CEL `validation`
  block); `status` may only reference resources; template CEL
  (`map`/`filter`/concat/ternary/`has()`/`maps.merge`) works; applyset GC
  cleans cluster-scoped children; **deleting an RGD does NOT delete its
  CRD or instances** (migrations must delete CRDs explicitly and strip
  orphaned `kro.run/finalizer`s).
- Kyverno `ValidatingPolicy` at `policies.kyverno.io/v1` (verified
  v1.18). Quirks handled: `dyn()` casts on variables,
  `not-being-deleted` + `create-or-spec-changed` matchConditions, KRO
  plurals (`argocdprojectrepositories`).

## Apply

```sh
# RGDs FIRST: the claim policies resource.List the kro.run kinds — with
# failurePolicy Fail, a missing CRD locks out all project writes.
kubectl apply -f rgd-argocd-project.yaml \
              -f rgd-argocd-project-repository.yaml \
              -f rgd-argocd-cluster.yaml
kubectl wait --for condition=established \
  crd/argocdprojects.kro.run crd/argocdclusters.kro.run \
  crd/argocdprojectrepositories.kro.run
kubectl apply -f platform-policies.yaml
bash tests/preflight.sh            # HARD GATE — see below
kubectl apply -f examples/tenant-teamx.yaml   # sample tenant
```

**Preflight is a hard gate.** All policies except `argocd-project-binding`
and `argocd-referential-guard` are `failurePolicy: Fail`, and the claim
policies `resource.List` the kro.run kinds + namespaces via an aggregated
ClusterRole. If aggregation didn't take (chart labels differ from
`app.kubernetes.io/instance=kyverno`), project writes fail closed with an
opaque error. `tests/preflight.sh` fails unless both Kyverno controllers
can list everything and all eight policies are READY. SA names are
overridable: `KYVERNO_NS=... ADM_SA=... RPT_SA=... bash tests/preflight.sh`.

### Availability note (prod)

`argocd-project-binding` is `failurePolicy: Ignore` (it matches every app
write in project namespaces; Argo CD `sourceNamespaces` is the hard
enforcer). `argocd-referential-guard` is `Ignore` (teardown must survive a
Kyverno outage). Everything else fails closed because it IS the boundary —
run Kyverno's admission controller HA (≥2 replicas).

## Tests

`tests/policy-tests.sh` — deny/allow matrix (51 checks) covering claims,
sharing, squatting, brownfield, identity immutability, offboarding order,
bootstrap rendering (auto/helm/recurse), label merging, LDAP group
derivation/override, CSV-injection denial, agent clusters, credType=none
attachment, the credentialed→agent migration, and direct-AppProject-edit
enforcement. Asserts deny *reasons*, cleans up
after itself, safe to re-run back-to-back.
