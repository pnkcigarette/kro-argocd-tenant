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
  kubectl delete argocdprojects fraud-p claim-p ghost-p squat-p brown-p src-p ren-p del-p dup-p -n argocd --ignore-not-found --wait=false >/dev/null 2>&1
  kubectl delete argocdclusters dup-a dup-b legacy-badsrv -n argocd --ignore-not-found --wait=false >/dev/null 2>&1
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
spec: {tenant: teamx, name: appa, destinations: ["in-cluster/teamx-other"]}
EOF

echo "=== 2. destination namespace already claimed by another project ==="
t DENY claim-conflict "already claimed by another project" <<'EOF'
apiVersion: kro.run/v1alpha1
kind: ArgoCDProject
metadata: {name: claim-p, namespace: argocd}
spec: {tenant: fraud, name: svc, destinations: ["prod-east/teamx-appa-prod"]}
EOF

echo "=== 3. shared cluster, different namespaces: sibling project ALLOWED ==="
# teamx/appb already shares prod-east with appa on a different ns — its
# presence in the example proves this; assert a fresh claim on the shared
# cluster with a new prefixed ns is allowed.
t ALLOW shared-cluster-diff-ns "" <<'EOF'
apiVersion: kro.run/v1alpha1
kind: ArgoCDProject
metadata: {name: claim-p, namespace: argocd}
spec: {tenant: fraud, name: svc, destinations: ["prod-east/fraud-svc-prod"]}
EOF
kubectl delete argocdprojects claim-p -n argocd --wait=false >/dev/null 2>&1

echo "=== 4. destination references an unregistered cluster ==="
t DENY unregistered-cluster "unregistered cluster" <<'EOF'
apiVersion: kro.run/v1alpha1
kind: ArgoCDProject
metadata: {name: ghost-p, namespace: argocd}
spec: {tenant: ghostt, name: svc, destinations: ["ghost-cluster/ghostt-svc-x"]}
EOF

echo "=== 5. squatting: unprefixed generic destination namespace ==="
t DENY unprefixed-destination 'prefixed "<tenant>-"' <<'EOF'
apiVersion: kro.run/v1alpha1
kind: ArgoCDProject
metadata: {name: squat-p, namespace: argocd}
spec: {tenant: squat, name: svc, destinations: ["in-cluster/dev"]}
EOF

echo "=== 6. brownfield: pre-existing labeled namespace claimable unprefixed ==="
kubectl create ns "$SCRATCH_NS" >/dev/null 2>&1
kubectl label ns "$SCRATCH_NS" example.com/tenant-deployable=true --overwrite >/dev/null 2>&1
sleep 2
t ALLOW brownfield-claim "" <<EOF
apiVersion: kro.run/v1alpha1
kind: ArgoCDProject
metadata: {name: brown-p, namespace: argocd}
spec: {tenant: brown, name: svc, destinations: ["in-cluster/$SCRATCH_NS"]}
EOF
kubectl delete argocdprojects brown-p -n argocd --wait=false >/dev/null 2>&1

echo "=== 7. source namespace theft (extra = another project's source ns) ==="
t DENY source-ns-theft "source namespaces (derived or extra) are already claimed" <<'EOF'
apiVersion: kro.run/v1alpha1
kind: ArgoCDProject
metadata: {name: src-p, namespace: argocd}
spec:
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
spec: {tenant: rent, name: unit, destinations: ["in-cluster/rent-unit-dev"]}
EOF
sleep 3
t DENY project-rename "spec.tenant/spec.name are immutable" <<'EOF'
apiVersion: kro.run/v1alpha1
kind: ArgoCDProject
metadata: {name: ren-p, namespace: argocd}
spec: {tenant: rent, name: unit2, destinations: ["in-cluster/rent-unit-dev"]}
EOF
kubectl delete argocdprojects ren-p -n argocd --wait=false >/dev/null 2>&1

echo "=== 20. cluster server immutable ==="
t DENY cluster-server-immutable "spec.name/spec.server are immutable" <<'EOF'
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
spec: {tenant: fraud, name: svc, destinations: []}
EOF

echo "=== 22. offboard ordering: project delete blocked while repo child exists ==="
kubectl apply -f - >/dev/null 2>&1 <<'EOF'
apiVersion: kro.run/v1alpha1
kind: ArgoCDProject
metadata: {name: del-p, namespace: argocd}
spec: {tenant: delt, name: unit, destinations: ["in-cluster/delt-unit-dev"]}
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
spec: {tenant: reft, name: unit, destinations: ["onprem-dc1/reft-unit-prod"]}
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

echo
echo "RESULT: $PASS passed, $FAIL failed"
[ $FAIL -eq 0 ]
