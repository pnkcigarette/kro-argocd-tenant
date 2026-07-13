# AGENTS.md — kro-argocd-tenant

KRO ResourceGraphDefinitions + Kyverno ValidatingPolicies implementing
Argo CD multi-tenancy. README.md has the design rationale; this file is
the operating rules for changing it safely.

## Vocabulary (locked)

**tenant** = org/team rollup (`teamx`) — a field + label convention, no
CR. **project** = onboarding unit (`appa`) — `ArgoCDProject`, rendering
AppProject `<tenant>-<name>` and source namespace
`tenant-<tenant>-<name>`. Clusters (`ArgoCDCluster`) are **global**,
platform-registered, shared by projects via namespace claims. Do not
reintroduce "tenant" for the unit — that ambiguity was deliberately
removed.

## Verified version envelope

Everything below was verified live on the `kind-kro-validate` KIND
cluster (2026-07): **KRO v0.9.2**, **Kyverno v1.18**, Argo CD stable
CRDs, VSO main CRDs. Re-verify before assuming on other versions.

## KRO rules (violations = "invalid spec" or broken reconcile)

- Simple schema supports **field markers only**: `required`, `default`,
  `enum`, `pattern`, `minItems`, `uniqueItems`, `minLength`. There is
  **no `validation:` CEL block** — cross-field rules go in
  `platform-policies.yaml`, never the RGD.
- **`immutable=true` is silently ignored** — enforce immutability in
  Kyverno via `oldObject`. Re-check any marker actually lands in
  `kubectl get crd ... -o json`.
- **KRO refuses to TIGHTEN a validation on an existing RGD** ("breaking
  changes detected" → RGD Inactive). Tighter constraints go in a Kyverno
  field-guard instead (that's why cluster `server` host:port lives in
  policy, not the RGD pattern).
- **Deleting an RGD does NOT delete its CRD or instances** — they orphan,
  and the instances keep a `kro.run/finalizer` no controller will ever
  remove. Migrations must delete the CRDs explicitly and strip stranded
  finalizers (`kubectl patch ... -p '{"metadata":{"finalizers":[]}}'`).
- **Schema `default=` markers materialize blocks into stored specs**
  (structural defaulting): a leaf default under `aks:` makes every EKS
  instance's stored spec grow an `aks:` block. Provider-scoped blocks
  therefore carry NO defaults; fallbacks are applied in template CEL
  (`has()` ternaries). Presence of a block is meaningful: required for
  its provider, forbidden otherwise (policy-enforced).
- RGD `status` fields may only reference **resources**, never `schema`.
- No fan-out: a resource template cannot iterate a list. N repos = N
  instances; variant selection is `includeWhen`; list-valued *fields*
  pass through fine.
- Template CEL verified working: `map()`, `filter()`, list concat `+`,
  scalar/list ternaries, `has()` (incl. in `includeWhen`),
  `string(bool)`, and **`maps.merge()`** (member method, RIGHT side wins
  — put platform keys second). Keep objects as static YAML with CEL in
  values; conditional list-of-objects uses the literal+`filter()` trick
  (see destinationServiceAccounts), not object-valued ternaries.
- Optional nested blocks/arrays are NOT materialized — every
  template/policy dereference needs a `has()` guard. YAML: any value
  containing `: ` or leading specials (inline CEL ternaries) must be
  quoted.
- **Pluralization trap**: CRD plurals come from KRO's pluralizer and can
  surprise (`...Repo` → `...repoes` — which is why the repo kind is named
  `ArgoCDProjectRepository`, pluralizing cleanly to
  `argocdprojectrepositories`). Anything matching CRD plurals (policy
  matchConstraints, RBAC, preflight) must use the real plural — check
  `kubectl get crd | grep kro.run`; a wrong plural fails SILENTLY.
- KRO tracks via applysets, not ownerReferences — cluster-scoped
  children (the source Namespace) ARE garbage-collected on instance
  delete, and **KRO's labeller server-side-applies METADATA to the main
  resource on reconcile** (see the matchCondition rule below).

## Kyverno ValidatingPolicy rules

- API is `policies.kyverno.io/v1` (v1alpha1 deprecated).
- `variables.*` are typed `any`: wrap in `dyn()` before comprehensions.
- Every UPDATE-matching policy keeps `not-being-deleted`, or
  finalizer-removal on invalid objects deadlocks deletion.
- Every spec-validating policy on a KRO kind keeps
  `create-or-spec-changed` (`request.operation == 'CREATE' ||
  object.spec != oldObject.spec`) or KRO's metadata applies re-deny
  grandfathered instances and wedge reconcile. A guard that reads
  `metadata.labels` (appproject-guard) must also re-run on label changes.
- A field that is BOTH immutable and structurally constrained (cluster
  `server`) needs its structural rule scoped to
  CREATE-or-that-field-changed — otherwise a grandfathered bad value
  blocks every unrelated update and can never be corrected.
- **failurePolicy split**: `argocd-project-binding` and
  `argocd-referential-guard` are `Ignore` (hot path / teardown path;
  Argo CD sourceNamespaces is the hard enforcer). Everything else is
  `Fail` — it IS the boundary. Don't flip either direction.
- DELETE-time policies read `oldObject` (`object` is null) and skip the
  not-being-deleted condition. Do NOT guard cluster-delete AND
  project-delete against each other's children — ownership cycles
  deadlock teardown (verified live in v1; safe now only because clusters
  are not project children).
- The aggregated ClusterRole needs list/watch on every matched kind for
  BOTH controllers (admission + reports); `tests/preflight.sh` gates
  this — a silent RBAC miss denies all project writes.
- **Kyverno discovery lags new CRDs**: right after a CRD is created,
  `resource.List` on it fails ("resource ... not found in group") and
  fail-closed policies deny matched writes. The cache did NOT self-heal
  within minutes on v1.18 — `kubectl rollout restart
  deploy/kyverno-admission-controller -n kyverno` is the reliable
  remedy. On bootstrap/migration: establish CRDs, apply policies, and if
  writes fail with "not found in group", bounce the admission
  controller.
- When policies list OTHER instances, `has()`-guard optional fields and
  shape-filter before indexing — one malformed legacy object must not
  error out everyone's admission.

## Tenancy invariants — do not weaken

- The `tenant-` namespace prefix, the `argocd` namespace, and the
  in-cluster server URL are **fixed literals**, not schema knobs (knobs
  on one side of a shared invariant were holes twice).
- **`tenant-*` is a RESERVED namespace prefix**: such namespaces must be
  named `tenant-<tenant>-<project>` with matching `example.com/tenant` +
  `example.com/project` labels (namespace-guard). Never name unrelated
  infra `tenant-...`.
- Destinations are exact `"<cluster>/<namespace>"` claims — reject
  `*?[` (Argo CD globs both the namespace AND name fields). New claim
  namespaces must be prefixed `<tenant>-`; brownfield goes through the
  `example.com/tenant-deployable` label. Claims are exclusive across ALL
  projects, siblings included.
- Clusters are registered exactly once per physical cluster: `name` AND
  normalized `server` are unique and immutable. That 1:1 mapping is what
  lets claims compare by name with no URL canonicalization. Destination
  clusters must exist at claim time.
- The global cluster credential is broad — projects should set
  `syncServiceAccount` (AppProject `destinationServiceAccounts`) for
  remote blast-radius. Cluster `labels` merge with platform keys winning;
  reserved prefixes rejected.
- Identity fields are immutable (project `tenant`+`name`; repo
  `tenant`+`project`+`name`; cluster `name`+`server`) — renaming makes
  KRO prune-and-recreate, destroying namespaces/workloads/secrets.
- Repository secrets carry `project: <tenant>-<name>`; `repo-creds`
  are NOT project-scoped in Argo CD — tenant-unique URL prefixes only.
- Every rendered resource carries the `example.com/tenant` +
  `example.com/project` label pair (rollup queries + teardown selectors);
  clusters carry `example.com/cluster` instead.

## Known limitations (accepted for MVP)

- Server normalization covers case + trailing-slash/path, NOT port form
  (`:443` vs implicit) — register consistently.
- The claims positive-check lists all hub namespaces per project write;
  bounded because project writes are onboarding-rare.
- Duplicate/invalid instances predating a rule are only *reported*
  (background eval), not auto-resolved.
- Bootstrap path contents are convention (Application manifests only),
  not enforced.

## Testing changes

Test on `kind-kro-validate` (KRO in `kro-system`, Kyverno in `kyverno`,
Argo CD + VSO CRDs applied). Apply order: RGDs → wait CRDs established →
platform-policies → `tests/preflight.sh` (hard gate) → example. After RGD
changes check `kubectl get rgd` reaches Active and read failed conditions.
After policy changes run `tests/policy-tests.sh` — every case must PASS;
it asserts deny REASONS, so a deny from the wrong policy is a FAIL. Give
each test case a UNIQUE instance identity (name and tenant/name pair) —
reusing one while a previous instance drains makes applies hit the
deleting object and false-pass. If instances stick in DELETING after a
policy change, you broke a matchCondition.
