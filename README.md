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
| `rgd-argocd-cluster.yaml` | `ArgoCDCluster` (one per physical cluster, **platform-registered, global**) | plain Secret (eks/aks) or VaultStaticSecret (generic) → shared Argo CD cluster secret |

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
   dictates app tooling. From then on, adding an app = a PR to the team's
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

## Project restriction (the tenancy boundary)

- **AppProject**: `sourceRepos`, derived `sourceNamespaces`, and
  claim-built `destinations` bound what each project may do. `in-cluster`
  destinations get a server-form entry too; the project's own source
  namespace is always appended so the bootstrap app-of-apps works.
- **Repository secrets** carry `project: <tenant>-<name>` — usable only
  by that AppProject. (`repo-creds` templates are NOT project-scoped in
  Argo CD; only use tenant-unique URL prefixes.)
- **`argocd-project-binding`**: any Application/ApplicationSet in a
  namespace labeled `example.com/tenant` + `example.com/project` must set
  `spec.project` to `<tenant>-<project>` — readable failure at admission;
  Argo CD `sourceNamespaces` is the hard backstop.
- **`tenant-*` is a reserved namespace prefix**: every such namespace
  must be named `tenant-<tenant>-<project>` with matching labels, so an
  unlabeled/mislabeled namespace can't evade the label-matched binding.
- **AppProject guard**: no glob sourceNamespaces anywhere; labeled
  AppProjects may only list namespaces belonging to their own label pair.

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

`tests/policy-tests.sh` — deny/allow matrix (26 checks) covering claims,
sharing, squatting, brownfield, identity immutability, offboarding order,
bootstrap rendering, and label merging. Asserts deny *reasons*, cleans up
after itself, safe to re-run back-to-back.
