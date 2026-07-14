#!/bin/bash
# Policy regression matrix for kro-argocd-tenant (v2: tenant=rollup,
# project=unit, global clusters).
#
# Prereqs (see AGENTS.md): RGDs Active, platform-policies applied and
# READY, the examples/tenant-teamx.yaml projects reconciled ACTIVE.
#
# DENY assertions check BOTH the verdict and the deny reason. All
# artifacts are cleaned up on exit; the scratch namespace is unique per
# run so back-to-back runs never collide with terminating objects.

set -u
PASS=0; FAIL=0
SCRATCH_NS="ptest-ns-$$"
POLICIES="$(cd "$(dirname "$0")/.." && pwd)/platform-policies.yaml"

t() { # t <DENY|ALLOW> <name> <expected-deny-substring> ; manifest on stdin
  local expect=$1 name=$2 want=${3:-} out rc
  out=$(kubectl apply -f - 2>&1); rc=$?
  if [ "$expect" = DENY ]; then
    if [ $rc -ne 0 ] && echo "$out" | grep -qF "$want"; then
      echo "PASS (denied) $name"; PASS=$((PASS+1))
    elif [ $rc -ne 0 ]; then
      echo "FAIL $name: denied for the WRONG reason (wanted '$want') :: $out"; FAIL=$((FAIL+1))
    else
      echo "FAIL $name: was ALLOWED :: $out"; FAIL=$((FAIL+1))
    fi
  else
    if [ $rc -eq 0 ]; then
      echo "PASS (allowed) $name"; PASS=$((PASS+1))
    else
      echo "FAIL $name: was DENIED :: $out"; FAIL=$((FAIL+1))
    fi
  fi
}

cleanup() {
  # Children before projects (referential guard); projects before
  # clusters they reference.
  kubectl delete argocdprojectrepositories t-repo -n argocd --ignore-not-found --wait=false >/dev/null 2>&1
  sleep 1
  kubectl delete argocdprojects fraud-p claim-p ghost-p squat-p brown-p src-p ren-p del-p dup-p boot-p -n argocd --ignore-not-found --wait=false >/dev/null 2>&1
  kubectl delete argocdclusters dup-a dup-b legacy-badsrv agent-bad mig-c -n argocd --ignore-not-found --wait=false >/dev/null 2>&1
  kubectl delete application legit -n tenant-teamx-appa --ignore-not-found >/dev/null 2>&1
  kubectl delete ns "$SCRATCH_NS" tenant-labeltest --ignore-not-found --wait=false >/dev/null 2>&1
  kubectl apply -f "$POLICIES" >/dev/null 2>&1
}
trap cleanup EXIT
cleanup

echo "=== 1. duplicate project (same tenant/name) ==="
t DENY dup-project "already defines this tenant/name" <<'EOF'
apiVersion: kro.run/v1alpha1
kind: ArgoCDProject
metadata: {name: teamx-appa-2, namespace: argocd}
spec: {assigneeGroup: Test Team, environment: dev, tenant: teamx, name: appa, destinations: ["in-cluster/teamx-other"]}
EOF

echo "=== 2. destination namespace already claimed by another project ==="
t DENY claim-conflict "already claimed by another project" <<'EOF'
apiVersion: kro.run/v1alpha1
kind: ArgoCDProject
metadata: {name: claim-p, namespace: argocd}
spec: {assigneeGroup: Test Team, environment: dev, tenant: fraud, name: svc, destinations: ["prod-east/teamx-appa-prod"]}
EOF

echo "=== 3. shared cluster, different namespaces: sibling project ALLOWED ==="
# teamx/appb already shares prod-east with appa on a different ns — its
# presence in the example proves this; assert a fresh claim on the shared
# cluster with a new prefixed ns is allowed.
t ALLOW shared-cluster-diff-ns "" <<'EOF'
apiVersion: kro.run/v1alpha1
kind: ArgoCDProject
metadata: {name: claim-p, namespace: argocd}
spec: {assigneeGroup: Test Team, environment: dev, tenant: fraud, name: svc, destinations: ["prod-east/fraud-svc-prod"]}
EOF
kubectl delete argocdprojects claim-p -n argocd --wait=false >/dev/null 2>&1

echo "=== 4. destination references an unregistered cluster ==="
t DENY unregistered-cluster "unregistered cluster" <<'EOF'
apiVersion: kro.run/v1alpha1
kind: ArgoCDProject
metadata: {name: ghost-p, namespace: argocd}
spec: {assigneeGroup: Test Team, environment: dev, tenant: ghostt, name: svc, destinations: ["ghost-cluster/ghostt-svc-x"]}
EOF

echo "=== 5. squatting: unprefixed generic destination namespace ==="
t DENY unprefixed-destination 'prefixed "<tenant>-"' <<'EOF'
apiVersion: kro.run/v1alpha1
kind: ArgoCDProject
metadata: {name: squat-p, namespace: argocd}
spec: {assigneeGroup: Test Team, environment: dev, tenant: squat, name: svc, destinations: ["in-cluster/dev"]}
EOF

echo "=== 6. brownfield: pre-existing labeled namespace claimable unprefixed ==="
kubectl create ns "$SCRATCH_NS" >/dev/null 2>&1
kubectl label ns "$SCRATCH_NS" example.com/tenant-deployable=true --overwrite >/dev/null 2>&1
sleep 2
t ALLOW brownfield-claim "" <<EOF
apiVersion: kro.run/v1alpha1
kind: ArgoCDProject
metadata: {name: brown-p, namespace: argocd}
spec: {assigneeGroup: Test Team, environment: dev, tenant: brown, name: svc, destinations: ["in-cluster/$SCRATCH_NS"]}
EOF
kubectl delete argocdprojects brown-p -n argocd --wait=false >/dev/null 2>&1

echo "=== 7. source namespace theft (extra = another project's source ns) ==="
t DENY source-ns-theft "source namespaces (derived or extra) are already claimed" <<'EOF'
apiVersion: kro.run/v1alpha1
kind: ArgoCDProject
metadata: {name: src-p, namespace: argocd}
spec:
  assigneeGroup: Test Team
  environment: dev
  tenant: thief
  name: svc
  destinations: ["in-cluster/thief-svc-app"]
  extraSourceNamespaces: ["tenant-teamx-appa"]
EOF

echo "=== 8. repo cred/url mismatch ==="
t DENY ssh-cred-https-url "credType=ssh requires" <<'EOF'
apiVersion: kro.run/v1alpha1
kind: ArgoCDProjectRepository
metadata: {name: t-repo, namespace: argocd}
spec: {tenant: teamx, project: appa, name: bad, url: "https://github.com/x/y.git", credType: ssh, vault: {namespace: teamx}}
EOF

echo "=== 9. eks cluster without caData ==="
t DENY eks-no-cadata "requires caData" <<'EOF'
apiVersion: kro.run/v1alpha1
kind: ArgoCDCluster
metadata: {name: dup-a, namespace: argocd}
spec:
  name: eks-nocad
  server: https://eks-nocad.example.com
  provider: eks
  eks: {clusterName: x, roleARN: "arn:aws:iam::123456789012:role/x"}
EOF

echo "=== 10. project binding in project namespace ==="
t DENY app-wrong-project "must set spec.project=teamx-appa" <<'EOF'
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata: {name: sneaky, namespace: tenant-teamx-appa}
spec:
  project: default
  source: {repoURL: "https://github.com/example-org/teamx-appa.git", path: ., targetRevision: HEAD}
  destination: {name: in-cluster, namespace: teamx-appa-dev}
EOF
t ALLOW app-correct-project "" <<'EOF'
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata: {name: legit, namespace: tenant-teamx-appa}
spec:
  project: teamx-appa
  source: {repoURL: "https://github.com/example-org/teamx-appa.git", path: ., targetRevision: HEAD}
  destination: {name: in-cluster, namespace: teamx-appa-dev}
EOF

echo "=== 11. AppProject sourceNamespaces glob bypass ==="
t DENY appproject-glob "explicit namespace names" <<'EOF'
apiVersion: argoproj.io/v1alpha1
kind: AppProject
metadata: {name: sneaky-platform, namespace: argocd}
spec:
  sourceRepos: ["*"]
  sourceNamespaces: ["t*"]
EOF

echo "=== 12. labeled AppProject listing another project's namespace ==="
t DENY cross-project-appproject "belonging to the project in its" <<'EOF'
apiVersion: argoproj.io/v1alpha1
kind: AppProject
metadata:
  name: sneaky-labeled
  namespace: argocd
  labels: {example.com/tenant: someteam, example.com/project: someproj}
spec:
  sourceRepos: ["https://github.com/x/y.git"]
  sourceNamespaces: ["tenant-teamx-appa"]
EOF

echo "=== 12b. direct AppProject edit adding an unclaimed cross-tenant destination ==="
# The claims registry runs on the ArgoCDProject CR; this asserts the
# effective AppProject is guarded too. teamx-appa does NOT claim
# teamx-appb-prod (that's appb's) — adding it directly must be denied.
if kubectl patch appproject teamx-appa -n argocd --type=json \
     -p '[{"op":"add","path":"/spec/destinations/-","value":{"name":"prod-east","namespace":"teamx-appb-prod"}}]' 2>&1 | grep -q "must be the project's source namespace\|owning ArgoCDProject claims"; then
  echo "PASS (denied) appproject-direct-dest-edit"; PASS=$((PASS+1))
else
  # if it slipped through, revert the drift and fail
  kubectl apply -f examples/tenant-teamx.yaml >/dev/null 2>&1
  echo "FAIL appproject-direct-dest-edit: cross-tenant destination was admitted"; FAIL=$((FAIL+1))
fi
# ...but adding a destination the project DOES claim is allowed.
if kubectl patch appproject teamx-appa -n argocd --type=json \
     -p '[{"op":"add","path":"/spec/destinations/-","value":{"name":"in-cluster","namespace":"teamx-appa-dev"}}]' >/dev/null 2>&1; then
  echo "PASS (allowed) appproject-claimed-dest-edit"; PASS=$((PASS+1))
else
  echo "FAIL appproject-claimed-dest-edit: a legitimately-claimed destination was denied"; FAIL=$((FAIL+1))
fi

echo "=== 13. repo without vault block ==="
t DENY repo-no-vault "vault.namespace" <<'EOF'
apiVersion: kro.run/v1alpha1
kind: ArgoCDProjectRepository
metadata: {name: t-repo, namespace: argocd}
spec: {tenant: teamx, project: appa, name: novault, url: "https://github.com/x/y.git"}
EOF

echo "=== 14. unregistered/duplicate cluster: second registration of same server ==="
kubectl apply -f - >/dev/null 2>&1 <<'EOF'
apiVersion: kro.run/v1alpha1
kind: ArgoCDCluster
metadata: {name: dup-a, namespace: argocd}
spec: {name: dup-a, server: "https://dup.example.com:6443", provider: generic, vault: {namespace: platform}}
EOF
sleep 2
t DENY dup-cluster-server "registered exactly once" <<'EOF'
apiVersion: kro.run/v1alpha1
kind: ArgoCDCluster
metadata: {name: dup-b, namespace: argocd}
spec: {name: dup-b, server: "https://dup.example.com:6443", provider: generic, vault: {namespace: platform}}
EOF

echo "=== 15. cluster server trailing slash rejected ==="
t DENY server-trailing-slash "must be host:port only" <<'EOF'
apiVersion: kro.run/v1alpha1
kind: ArgoCDCluster
metadata: {name: dup-b, namespace: argocd}
spec: {name: badsrv, server: "https://badsrv.example.com:6443/", provider: generic, vault: {namespace: platform}}
EOF

echo "=== 16. reserved label prefix on cluster ==="
t DENY reserved-cluster-label "reserved prefixes" <<'EOF'
apiVersion: kro.run/v1alpha1
kind: ArgoCDCluster
metadata: {name: dup-b, namespace: argocd}
spec:
  name: lblcluster
  server: https://lbl.example.com:6443
  provider: generic
  vault: {namespace: platform}
  labels: {"example.com/tenant": spoofed}
EOF
t DENY reserved-cluster-label-kro "reserved prefixes" <<'EOF'
apiVersion: kro.run/v1alpha1
kind: ArgoCDCluster
metadata: {name: dup-b, namespace: argocd}
spec:
  name: lblcluster
  server: https://lbl.example.com:6443
  provider: generic
  vault: {namespace: platform}
  labels: {"kro.run/owned": "false"}
EOF

echo "=== 17. unlabeled tenant-* namespace rejected ==="
t DENY unlabeled-tenant-ns "must be named tenant-<tenant>-<project>" <<'EOF'
apiVersion: v1
kind: Namespace
metadata: {name: tenant-evil}
EOF

echo "=== 18. mislabeled tenant-* namespace (labels != name) rejected ==="
t DENY mislabeled-tenant-ns "must be named tenant-<tenant>-<project>" <<'EOF'
apiVersion: v1
kind: Namespace
metadata:
  name: tenant-foo-bar
  labels: {example.com/tenant: other, example.com/project: thing}
EOF

echo "=== 19. project rename rejected (identity immutable) ==="
kubectl apply -f - >/dev/null 2>&1 <<'EOF'
apiVersion: kro.run/v1alpha1
kind: ArgoCDProject
metadata: {name: ren-p, namespace: argocd}
spec: {assigneeGroup: Test Team, environment: dev, tenant: rent, name: unit, destinations: ["in-cluster/rent-unit-dev"]}
EOF
sleep 3
t DENY project-rename "spec.tenant/spec.name are immutable" <<'EOF'
apiVersion: kro.run/v1alpha1
kind: ArgoCDProject
metadata: {name: ren-p, namespace: argocd}
spec: {assigneeGroup: Test Team, environment: dev, tenant: rent, name: unit2, destinations: ["in-cluster/rent-unit-dev"]}
EOF
kubectl delete argocdprojects ren-p -n argocd --wait=false >/dev/null 2>&1

echo "=== 20. cluster server immutable ==="
t DENY cluster-server-immutable "spec.server is immutable" <<'EOF'
apiVersion: kro.run/v1alpha1
kind: ArgoCDCluster
metadata: {name: onprem-dc1, namespace: argocd}
spec: {name: onprem-dc1, server: "https://moved.example.com:6443", provider: generic, vault: {namespace: platform}}
EOF

echo "=== 21. empty destinations (KRO minItems marker) ==="
t DENY empty-destinations "at least 1 items" <<'EOF'
apiVersion: kro.run/v1alpha1
kind: ArgoCDProject
metadata: {name: claim-p, namespace: argocd}
spec: {assigneeGroup: Test Team, environment: dev, tenant: fraud, name: svc, destinations: []}
EOF

echo "=== 22. offboard ordering: project delete blocked while repo child exists ==="
kubectl apply -f - >/dev/null 2>&1 <<'EOF'
apiVersion: kro.run/v1alpha1
kind: ArgoCDProject
metadata: {name: del-p, namespace: argocd}
spec: {assigneeGroup: Test Team, environment: dev, tenant: delt, name: unit, destinations: ["in-cluster/delt-unit-dev"]}
---
apiVersion: kro.run/v1alpha1
kind: ArgoCDProjectRepository
metadata: {name: t-repo, namespace: argocd}
spec: {tenant: delt, project: unit, name: core, url: "https://github.com/x/y.git", credType: https, vault: {namespace: delt}}
EOF
sleep 4
if kubectl delete argocdprojects del-p -n argocd >/dev/null 2>&1; then
  echo "FAIL offboard-order: project deleted while child repo existed"; FAIL=$((FAIL+1))
else
  echo "PASS (denied) offboard-order-project-first"; PASS=$((PASS+1))
fi
kubectl delete argocdprojectrepositories t-repo -n argocd >/dev/null 2>&1
sleep 2
if kubectl delete argocdprojects del-p -n argocd >/dev/null 2>&1; then
  echo "PASS (allowed) offboard-order-children-first"; PASS=$((PASS+1))
else
  echo "FAIL offboard-order: childless project delete was still blocked"; FAIL=$((FAIL+1))
fi

echo "=== 23. cluster delete blocked while a project references it ==="
# onprem-dc1 is referenced by nothing in the example; give it a referrer.
kubectl apply -f - >/dev/null 2>&1 <<'EOF'
apiVersion: kro.run/v1alpha1
kind: ArgoCDProject
metadata: {name: del-p, namespace: argocd}
spec: {assigneeGroup: Test Team, environment: dev, tenant: reft, name: unit, destinations: ["onprem-dc1/reft-unit-prod"]}
EOF
sleep 4
if kubectl delete argocdclusters onprem-dc1 -n argocd >/dev/null 2>&1; then
  echo "FAIL cluster-ref-guard: cluster deleted while referenced"; FAIL=$((FAIL+1))
  kubectl apply -f "$(dirname "$0")/../examples/tenant-teamx.yaml" >/dev/null 2>&1
else
  echo "PASS (denied) cluster-delete-while-referenced"; PASS=$((PASS+1))
fi
kubectl delete argocdprojects del-p -n argocd --wait=false >/dev/null 2>&1

echo "=== 24. bootstrap app-of-apps rendered for a project with bootstrap.repoUrl ==="
if [ "$(kubectl get application bootstrap -n tenant-teamx-appa -o jsonpath='{.spec.project}' 2>/dev/null)" = teamx-appa ]; then
  echo "PASS (allowed) bootstrap-app-present"; PASS=$((PASS+1))
else
  echo "FAIL bootstrap-app-present: bootstrap Application not rendered/bound"; FAIL=$((FAIL+1))
fi

echo "=== 25. LDAP group derivation from assigneeGroup + environment ==="
# appa: assigneeGroup "APP_Team X", env dev -> viewer+admin paas_appteamx
V=$(kubectl get appproject teamx-appa -n argocd -o jsonpath='{.spec.roles[?(@.name=="viewer")].groups[0]}' 2>/dev/null)
A=$(kubectl get appproject teamx-appa -n argocd -o jsonpath='{.spec.roles[?(@.name=="admin")].groups[0]}' 2>/dev/null)
if [ "$V" = paas_appteamx ] && [ "$A" = paas_appteamx ]; then
  echo "PASS (allowed) group-derivation-dev"; PASS=$((PASS+1))
else
  echo "FAIL group-derivation-dev: viewer=$V admin=$A (wanted paas_appteamx both)"; FAIL=$((FAIL+1))
fi
# appb: env prod would derive paas_emerid_appteamx_prod, but adminGroup
# override is set -> override wins; viewer still derived.
V=$(kubectl get appproject teamx-appb -n argocd -o jsonpath='{.spec.roles[?(@.name=="viewer")].groups[0]}' 2>/dev/null)
A=$(kubectl get appproject teamx-appb -n argocd -o jsonpath='{.spec.roles[?(@.name=="admin")].groups[0]}' 2>/dev/null)
if [ "$V" = paas_appteamx ] && [ "$A" = paas_special_appteamb_ops ]; then
  echo "PASS (allowed) group-override-prod"; PASS=$((PASS+1))
else
  echo "FAIL group-override-prod: viewer=$V admin=$A"; FAIL=$((FAIL+1))
fi

echo "=== 26. assignee_group annotation recorded on the source namespace ==="
AG=$(kubectl get ns tenant-teamx-appa -o jsonpath='{.metadata.annotations.assignee_group}' 2>/dev/null)
if [ "$AG" = "APP_Team X" ]; then
  echo "PASS (allowed) assignee-group-annotation"; PASS=$((PASS+1))
else
  echo "FAIL assignee-group-annotation: got '$AG'"; FAIL=$((FAIL+1))
fi

echo "=== 27. group override injection rejected (schema pattern) ==="
t DENY group-injection "should match" <<'EOF'
apiVersion: kro.run/v1alpha1
kind: ArgoCDProject
metadata: {name: inj-p, namespace: argocd}
spec:
  assigneeGroup: Test Team
  environment: dev
  tenant: inj
  name: svc
  adminGroup: "x, role:admin"
  destinations: ["in-cluster/inj-svc-app"]
EOF

echo "=== 28. argocd-agent cluster rules (registry-only provider) ==="
t DENY agent-wrong-server "synthetic server" <<'EOF'
apiVersion: kro.run/v1alpha1
kind: ArgoCDCluster
metadata: {name: agent-bad, namespace: argocd}
spec:
  name: agent-bad
  server: https://real-looking.example.com:6443
  provider: agent
  agent: {mode: managed}
EOF
t DENY agent-with-cadata "caData may only be set" <<'EOF'
apiVersion: kro.run/v1alpha1
kind: ArgoCDCluster
metadata: {name: agent-bad, namespace: argocd}
spec:
  name: agent-bad
  server: https://agent-bad.agent.internal
  provider: agent
  caData: UkVQTEFDRQ==
  agent: {mode: managed}
EOF
t DENY agent-missing-mode "requires agent.mode" <<'EOF'
apiVersion: kro.run/v1alpha1
kind: ArgoCDCluster
metadata: {name: agent-bad, namespace: argocd}
spec:
  name: agent-bad
  server: https://agent-bad.agent.internal
  provider: agent
EOF
t DENY agent-with-labels "ignored for agent clusters" <<'EOF'
apiVersion: kro.run/v1alpha1
kind: ArgoCDCluster
metadata: {name: agent-bad, namespace: argocd}
spec:
  name: agent-bad
  server: https://agent-bad.agent.internal
  provider: agent
  agent: {mode: managed}
  labels: {env: prod}
EOF
# ...and the baseline agent registration + claim rendered correctly.
D=$(kubectl get appproject teamx-appb -n argocd -o jsonpath='{.spec.destinations[?(@.name=="agent-east")].namespace}' 2>/dev/null)
S=$(kubectl get argocdclusters agent-east -n argocd -o jsonpath='{.status.state}' 2>/dev/null)
if [ "$D" = teamx-appb-edge ] && [ "$S" = ACTIVE ]; then
  echo "PASS (allowed) agent-registration-and-claim"; PASS=$((PASS+1))
else
  echo "FAIL agent-registration-and-claim: state=$S dest-ns=$D"; FAIL=$((FAIL+1))
fi

echo "=== 24b. bootstrap helm variant: monorepo chart with ENV valueFiles ==="
VF=$(kubectl get application bootstrap -n tenant-teamx-appa -o jsonpath='{.spec.source.helm.valueFiles}' 2>/dev/null)
if echo "$VF" | grep -q "envs/dev.yaml"; then
  echo "PASS (allowed) bootstrap-helm-valuefiles"; PASS=$((PASS+1))
else
  echo "FAIL bootstrap-helm-valuefiles: got '$VF'"; FAIL=$((FAIL+1))
fi
t DENY bootstrap-tool-conflict "mutually" <<'EOF'
apiVersion: kro.run/v1alpha1
kind: ArgoCDProject
metadata: {name: boot-p, namespace: argocd}
spec:
  assigneeGroup: Test Team
  environment: dev
  tenant: boott
  name: svc
  destinations: ["in-cluster/boott-svc-app"]
  bootstrap:
    repoUrl: https://github.com/x/y.git
    helmValueFiles: ["values.yaml"]
    recurse: true
EOF
t DENY bootstrap-bad-valuefile "non-empty relative paths" <<'EOF'
apiVersion: kro.run/v1alpha1
kind: ArgoCDProject
metadata: {name: boot-p, namespace: argocd}
spec:
  assigneeGroup: Test Team
  environment: dev
  tenant: boott
  name: svc
  destinations: ["in-cluster/boott-svc-app"]
  bootstrap:
    repoUrl: https://github.com/x/y.git
    helmValueFiles: ["/etc/absolute.yaml"]
EOF

echo "=== 29. credType=none: metadata-only second-project attachment ==="
# Baseline teamx-appb-core attaches appa's URL to appb: rendered secret
# must carry url+project but NO credential keys and no Vault objects.
U=$(kubectl get secret repo-teamx-appb-core -n argocd -o jsonpath='{.data.url}' 2>/dev/null)
C=$(kubectl get secret repo-teamx-appb-core -n argocd -o jsonpath='{.data.username}{.data.password}{.data.sshPrivateKey}' 2>/dev/null)
VSS=$(kubectl get vaultstaticsecret repo-teamx-appb-core -n argocd --no-headers 2>/dev/null | wc -l | tr -d ' ')
if [ -n "$U" ] && [ -z "$C" ] && [ "$VSS" = 0 ]; then
  echo "PASS (allowed) none-attachment-render"; PASS=$((PASS+1))
else
  echo "FAIL none-attachment-render: url=$U credkeys='$C' vss=$VSS"; FAIL=$((FAIL+1))
fi
t DENY none-with-repo-creds "only usable with secretType=repository" <<'EOF'
apiVersion: kro.run/v1alpha1
kind: ArgoCDProjectRepository
metadata: {name: t-repo, namespace: argocd}
spec: {tenant: teamx, project: appa, name: badnone, url: "https://github.com/x/y.git", secretType: repo-creds, credType: none}
EOF
t DENY none-with-vault "may not be set when credType=none" <<'EOF'
apiVersion: kro.run/v1alpha1
kind: ArgoCDProjectRepository
metadata: {name: t-repo, namespace: argocd}
spec: {tenant: teamx, project: appa, name: badnone, url: "https://github.com/x/y.git", credType: none, vault: {namespace: teamx}}
EOF

echo "=== 30. one-way in-place migration: credentialed cluster -> agent ==="
kubectl apply -f - >/dev/null 2>&1 <<'EOF'
apiVersion: kro.run/v1alpha1
kind: ArgoCDCluster
metadata: {name: mig-c, namespace: argocd}
spec: {name: mig-c, server: "https://mig-c.example.com:6443", provider: generic, vault: {namespace: platform}}
EOF
sleep 4
t ALLOW migrate-to-agent "" <<'EOF'
apiVersion: kro.run/v1alpha1
kind: ArgoCDCluster
metadata: {name: mig-c, namespace: argocd}
spec:
  name: mig-c
  server: https://mig-c.agent.internal
  provider: agent
  agent: {mode: managed}
EOF
sleep 6
# the credentialed secret machinery must be pruned by the migration
if [ -z "$(kubectl get vaultstaticsecret cluster-mig-c -n argocd --no-headers 2>/dev/null)" ]; then
  echo "PASS (allowed) migration-prunes-secret"; PASS=$((PASS+1))
else
  echo "FAIL migration-prunes-secret: VSS still present"; FAIL=$((FAIL+1))
fi
# ...and the reverse (agent -> credentialed) is denied.
t DENY migrate-back-denied "is immutable" <<'EOF'
apiVersion: kro.run/v1alpha1
kind: ArgoCDCluster
metadata: {name: mig-c, namespace: argocd}
spec: {name: mig-c, server: "https://mig-c.example.com:6443", provider: generic, vault: {namespace: platform}}
EOF
kubectl delete argocdclusters mig-c -n argocd --wait=false >/dev/null 2>&1

echo
echo "RESULT: $PASS passed, $FAIL failed"
[ $FAIL -eq 0 ]
