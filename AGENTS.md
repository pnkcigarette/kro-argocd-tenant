# AGENTS.md — kro-argocd-tenant

KRO ResourceGraphDefinitions + Kyverno ValidatingPolicies implementing
Argo CD multi-tenancy. README.md has the design rationale; this file is
the operating rules for changing it safely.

## Verified version envelope

Everything below was verified live on the `kind-kro-validate` KIND
cluster (2026-07): **KRO v0.9.2**, **Kyverno v1.18**, Argo CD stable
CRDs, VSO main CRDs. Re-verify these notes before assuming they hold on
other versions.

## KRO rules (violations = "invalid spec" or broken reconcile)

- Simple schema supports **field markers only**: `required`, `default`,
  `enum`, `pattern`, `minItems`, `uniqueItems`, `minLength`. There is
  **no `validation:` CEL block** — cross-field rules go in
  `platform-policies.yaml`, never the RGD.
- **`immutable=true` is silently ignored on KRO v0.9.2** — it never
  reaches the generated CRD (verified: the field gets only its `pattern`,
  no `x-kubernetes-validations`). Enforce immutability in Kyverno with
  `request.operation != 'UPDATE' || object.spec.X == oldObject.spec.X`
  (see the server-immutable rule in the cluster field guard). Re-check
  any marker you rely on actually lands in `kubectl get crd ... -o json`.
- **KRO refuses to TIGHTEN a validation on an existing RGD** — narrowing
  a `pattern` (or similar) fails with "breaking changes detected" and the
  RGD goes Inactive. Loosening is fine. So any tighter field constraint
  must go in a Kyverno field-guard rule instead (that's why the
  cluster `server` host:port-only check lives in policy, not the RGD
  pattern). Changing it in the RGD would need deleting + recreating the
  CRD — which cascades all instances.
- RGD `status` fields may only reference **resources**, never `schema`.
  The repo/cluster RGDs deliberately have no custom status.
- No fan-out: a resource template cannot iterate a list. N repos/clusters
  = N instances. Variant selection is `includeWhen` (see the 4 repo
  secret variants); list-valued *fields* are fine.
- Template CEL that IS verified working: `map()`, `filter()`, list
  concat with `+`, scalar/list ternaries, `has()` guards,
  `string(bool)`. Keep objects as static YAML with CEL only in values
  (see appProject `roles`) rather than CEL object construction.
- Optional nested blocks/arrays are NOT materialized by defaulting —
  every template/policy dereference needs a `has()` ternary.
- **Pluralization trap**: KRO pluralizes `ArgoCDTenantRepo` →
  `argocdtenantrepoes`. Anything matching CRD plurals (policy
  matchConstraints, RBAC) must use the real plural — check
  `kubectl get crd | grep kro.run` before writing one. A wrong plural
  fails SILENTLY (webhook rule matches nothing).
- KRO tracks resources via applysets, not ownerReferences —
  cluster-scoped resources (the tenant Namespace) from namespaced
  instances ARE garbage-collected on instance delete.

## Kyverno ValidatingPolicy rules

- API is `policies.kyverno.io/v1` (v1alpha1 deprecated).
- `variables.*` are typed `any`: wrap in `dyn()` before any
  comprehension (`filter`/`map`/`exists`/`all`) or the policy fails to
  compile.
- Every UPDATE-matching policy MUST keep the `not-being-deleted`
  matchCondition. Without it, finalizer-removal on an already-invalid
  object is denied and deletion deadlocks (KRO instances stick in
  DELETING forever).
- `resource.List` fails closed (`failurePolicy: Fail`): the RGDs (and
  their CRDs) must exist before the policies are applied. README has
  the `kubectl wait --for condition=established` sequence.
- The aggregated ClusterRole needs list/watch on every matched kind for
  the reports controller, or policies sit READY=false on
  RBACPermissionsGranted. `tests/preflight.sh` gates this — run it after
  every policy apply; a silent RBAC miss denies all tenant writes.
- When policies list OTHER instances, guard optional fields
  (`has(t.spec.destinations)`) and shape-filter before indexing — one
  malformed legacy object must not error out everyone's admission.
- **failurePolicy split**: everything is `Fail` (fail-closed) EXCEPT
  `argocd-tenant-project-binding`, which is `Ignore` — it matches every
  Application write in a tenant namespace, and Argo CD `sourceNamespaces`
  is the hard enforcer, so it must not put Kyverno in the app-admission
  hot path. Don't flip the boundary policies to Ignore or the
  hot-path one to Fail.
- Immutability isn't a working KRO marker (see above) — enforce it in
  Kyverno with `request.operation != 'UPDATE' || object.spec.X ==
  oldObject.spec.X` (see the cluster server-immutable rule).
- Field-guards run `evaluation.background.enabled: true` so pre-existing
  duplicate/invalid instances (predating a rule) surface in
  PolicyReports, not just on new writes.
- **KRO writes the MAIN resource on reconcile** (managers
  `kro.run/labeller`, `applyset-parent` server-side-APPLY metadata) — not
  only `/status`. So a spec-validating webhook DOES fire on reconcile and
  would re-deny any grandfathered instance that predates a rule, wedging
  KRO's labeller. Every spec-validating policy therefore carries a
  `create-or-spec-changed` matchCondition
  (`request.operation == 'CREATE' || object.spec != oldObject.spec`) so
  metadata-only applies skip structural re-validation. Add it to any new
  spec-validating policy on a KRO kind.
- A field that is BOTH immutable and structurally constrained (cluster
  `server`) additionally needs its structural rule scoped to
  CREATE-or-that-field-changed — otherwise a grandfathered bad value
  can't be corrected (immutable) AND blocks every unrelated update. The
  spec-change matchCondition alone isn't enough there, because an
  unrelated field change IS a spec change.
- **Identity fields are immutable**: `ArgoCDTenant.spec.tenant` and
  repo/cluster `spec.tenant`+`spec.name` name the AppProject/namespace/
  secrets, so renaming them makes KRO's applyset prune-and-recreate
  (destroying the tenant's namespace + workloads). Enforced via Kyverno
  `oldObject` (KRO's `immutable` marker doesn't work). Delete+recreate to
  change identity.
- A guard whose validation reads `metadata.labels` (appproject-guard)
  must include `|| object.metadata.labels != oldObject.metadata.labels`
  in its spec-changed matchCondition, or a label-only edit bypasses it.
- **DELETE-time referential integrity is its own policy**
  (`argocd-tenant-referential-guard`, `operations: [DELETE]`, reads
  `oldObject`, no `not-being-deleted` condition, `failurePolicy: Ignore`
  so teardown survives a Kyverno outage). It blocks deleting a tenant
  while repo/cluster children exist (else orphaned credential secrets).
  Do NOT also guard cluster-delete-while-referenced — it deadlocks
  against the tenant rule (a tenant owning+referencing its cluster can't
  be deleted either way). See the README day-2 runbook for teardown
  order (children first).

## Tenancy invariants — do not weaken

- The `tenant-` namespace prefix, the `argocd` namespace, and the
  in-cluster server URL are **fixed literals**, not schema knobs. The
  ConfigMap glob, the policies, and the RGDs all assume them; a knob on
  one side is a hole (this bit us twice: namespacePrefix,
  argocdNamespace).
- Destinations are exact `"<cluster>/<namespace>"` claims — no globs
  anywhere (reject `*?[` in BOTH destination namespaces and
  `sourceNamespaces`; a bracket destination slipped through once).
- Claim uniqueness is compared by **normalized server URL**, not cluster
  name: cluster names are aliases AND URL format is an alias vector.
  `server` must be host:port only (RGD pattern `^https://[^/]+$`, no
  trailing slash/path) and the claims policy `.lowerAscii()`-es it before
  comparing (DNS case-insensitive). Residual: explicit vs implicit `:443`
  is not normalized — register a cluster's server consistently.
- `spec.server` on a cluster is effectively immutable (enforced in
  Kyverno): repointing it after a claim would redirect an approved
  destination past every check.
- Repo AND cluster secrets carry `project: <tenant>`; `repo-creds` are
  NOT project-scoped in Argo CD — tenant-unique URL prefixes only.
- Each tenant namespace appears in exactly one AppProject's
  `sourceNamespaces`; the appproject-guard enforces this, binds a labeled
  project's namespaces to the tenant in its OWN label, and rejects glob
  metacharacters.
- A `tenant-*` namespace MUST carry `indstri.com/tenant` == the name
  suffix (argocd-tenant-namespace-guard). Otherwise an unlabeled/stripped
  tenant-* namespace evades project-binding (which is label-matched),
  backstopped only by Argo CD. The label is bound to the name and can't
  be removed. **Consequence: `tenant-*` is a RESERVED namespace prefix** —
  the platform cannot have any `tenant-*` namespace that isn't a KRO
  tenant (the Argo CD apps-in-any-namespace glob claims that space
  anyway). Don't name unrelated infra `tenant-...`.
- eks/aks cluster secrets require `caData` (private cluster CAs);
  external-cluster apps must use `destination.name`, not `server`.

## Known limitations (accepted for MVP)

- Server URL normalization covers case + trailing-slash/path, NOT port
  form (`:443` vs implicit) — consistent registration is assumed.
- The claims positive-check `resource.List`s all namespaces per tenant
  admission; bounded because tenant writes are onboarding-rare, but O(all
  namespaces) per write.
- The (tenant,name) dup rules stop NEW collisions; pre-existing dups are
  only reported (background eval), not auto-resolved.

## YAML footguns

- CEL ternaries and messages containing `: ` or starting with special
  chars must be quoted (`groups: '${... ? [] : [...]}'`) — plain
  scalars break.
- The applicationset CRD is too big for `kubectl apply` (annotation
  limit); use `kubectl create`.

## Testing changes

Test on the `kind-kro-validate` KIND cluster (KRO in `kro-system`,
Kyverno in `kyverno`, Argo CD + VSO CRDs applied). Apply order: RGDs →
wait for CRDs established → platform-policies. After RGD changes, check
`kubectl get rgd` reaches Active and read the failed conditions if not.
After policy changes, run `tests/policy-tests.sh` — a deny/allow matrix
covering claims, aliasing, hijack, and field-guard cases; every case
should print PASS. If KRO instances stick in DELETING after a policy
change, you broke the not-being-deleted matchCondition.
