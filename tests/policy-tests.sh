#!/bin/bash
# Policy regression matrix for kro-argocd-tenant.
#
# Prereqs (see AGENTS.md): RGDs Active, platform-policies applied and
# READY, the examples/tenant-payments.yaml tenant reconciled ACTIVE.
#
# DENY assertions check BOTH the verdict and the deny reason — a denial
# from the wrong policy (or a webhook internal error) is a FAIL, so a
# regressed rule can't hide behind a neighboring one.
#
# All artifacts are cleaned up on exit; the scratch namespace is unique
# per run so back-to-back runs never collide with terminating objects.

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
  # Children (repos/clusters) BEFORE tenants — the referential guard
  # denies deleting a tenant while its repo/cluster instances still exist.
  kubectl delete argocdtenantclusters fraud-east fr-eu-prod ca-shared cb-shared d2-cluster -n argocd --ignore-not-found --wait=false >/dev/null 2>&1
  kubectl delete argocdtenantrepoes d2-repo -n argocd --ignore-not-found --wait=false >/dev/null 2>&1
  sleep 2
  kubectl delete argocdtenant fraud fraud2 fr ca cb d2ren d2del -n argocd --ignore-not-found --wait=false >/dev/null 2>&1
  kubectl delete application legit -n tenant-payments --ignore-not-found >/dev/null 2>&1
  kubectl annotate appproject payments -n argocd policy-test- >/dev/null 2>&1
  # Restore the baseline cluster server in case an immutability test left
  # it patched (kubectl patch would have been rejected, but be safe).
  kubectl patch argocdtenantclusters payments-onprem-dc1 -n argocd --type merge \
    -p '{"spec":{"server":"https://dc1.k8s.indstri.com:6443"}}' >/dev/null 2>&1
  kubectl delete argocdtenantclusters legacy-badserver -n argocd --ignore-not-found --wait=false >/dev/null 2>&1
  kubectl delete ns "$SCRATCH_NS" tenant-labeltest --ignore-not-found --wait=false >/dev/null 2>&1
  # Safety: test 22c briefly removes the cluster field-guard; re-apply the
  # policies so an aborted run never leaves the guard off.
  kubectl apply -f "$POLICIES" >/dev/null 2>&1
}
trap cleanup EXIT
cleanup   # also clear leftovers from any previous aborted run

echo "=== 1. duplicate spec.tenant ==="
t DENY dup-tenant "already defines this tenant" <<'EOF'
apiVersion: kro.run/v1alpha1
kind: ArgoCDTenant
metadata: {name: payments-2, namespace: argocd}
spec: {tenant: payments, destinations: ["in-cluster/other-ns"]}
EOF

echo "=== 2. destination already claimed by payments ==="
t DENY claim-conflict "already claimed by another tenant" <<'EOF'
apiVersion: kro.run/v1alpha1
kind: ArgoCDTenant
metadata: {name: fraud, namespace: argocd}
spec: {tenant: fraud, destinations: ["in-cluster/payments-dev"]}
EOF

echo "=== 3. server-alias: fraud registers payments' EKS server under own name, then claims same ns ==="
t ALLOW alias-cluster-register "" <<'EOF'
apiVersion: kro.run/v1alpha1
kind: ArgoCDTenantCluster
metadata: {name: fraud-east, namespace: argocd}
spec:
  tenant: fraud
  name: east
  provider: eks
  server: https://ABC123.gr7.us-east-1.eks.amazonaws.com
  caData: LS0tRVhBTVBMRQ==
  eks: {clusterName: shared-east, roleARN: "arn:aws:iam::123456789012:role/argocd-fraud"}
EOF
t DENY alias-claim "already claimed by another tenant" <<'EOF'
apiVersion: kro.run/v1alpha1
kind: ArgoCDTenant
metadata: {name: fraud, namespace: argocd}
spec: {tenant: fraud, destinations: ["fraud-east/payments-prod"]}
EOF

echo "=== 4. hyphen-prefix cluster hijack: fr tenant references fr-eu's cluster ==="
# fr-eu registers a cluster; a separate throwaway tenant 'fr' (a
# hyphen-prefix of 'fr-eu') must not be able to reference fr-eu-prod.
# Deliberately NOT the live 'payments' baseline — this apply must never
# mutate an object other tests depend on.
kubectl apply -f - >/dev/null 2>&1 <<'EOF'
apiVersion: kro.run/v1alpha1
kind: ArgoCDTenantCluster
metadata: {name: fr-eu-prod, namespace: argocd}
spec:
  tenant: fr-eu
  name: prod
  provider: generic
  server: https://eu.k8s.example.com:6443
  vault: {namespace: fr-eu}
EOF
t DENY hyphen-prefix-hijack "reference a cluster registered by another tenant" <<'EOF'
apiVersion: kro.run/v1alpha1
kind: ArgoCDTenant
metadata: {name: fr, namespace: argocd}
spec:
  tenant: fr
  destinations: ["in-cluster/fr-app", "fr-eu-prod/x"]
EOF

echo "=== 5. existing unlabeled hub namespace ==="
kubectl create ns "$SCRATCH_NS" >/dev/null
sleep 2
t DENY existing-unlabeled-ns "must belong to this tenant or be labeled" <<EOF
apiVersion: kro.run/v1alpha1
kind: ArgoCDTenant
metadata: {name: fraud, namespace: argocd}
spec: {tenant: fraud, destinations: ["in-cluster/$SCRATCH_NS"]}
EOF
kubectl label ns "$SCRATCH_NS" indstri.com/tenant-deployable=true --overwrite >/dev/null
sleep 2
t ALLOW labeled-ns-claim "" <<EOF
apiVersion: kro.run/v1alpha1
kind: ArgoCDTenant
metadata: {name: fraud, namespace: argocd}
spec: {tenant: fraud, destinations: ["in-cluster/$SCRATCH_NS"]}
EOF
kubectl delete argocdtenant fraud -n argocd --wait=false >/dev/null 2>&1

echo "=== 6. source namespace theft ==="
t DENY source-ns-theft "source namespaces (derived or extra) are already claimed" <<'EOF'
apiVersion: kro.run/v1alpha1
kind: ArgoCDTenant
metadata: {name: fraud2, namespace: argocd}
spec:
  tenant: fraud2
  destinations: ["in-cluster/fraud2-app"]
  extraSourceNamespaces: ["tenant-payments"]
EOF

echo "=== 7. repo cred/url mismatch ==="
t DENY ssh-cred-https-url "credType=ssh requires" <<'EOF'
apiVersion: kro.run/v1alpha1
kind: ArgoCDTenantRepo
metadata: {name: bad-repo, namespace: argocd}
spec:
  tenant: payments
  name: bad
  url: https://github.com/indstri/x.git
  credType: ssh
  vault: {namespace: payments}
EOF

echo "=== 8. eks without caData ==="
t DENY eks-no-cadata "requires caData" <<'EOF'
apiVersion: kro.run/v1alpha1
kind: ArgoCDTenantCluster
metadata: {name: bad-eks, namespace: argocd}
spec:
  tenant: payments
  name: bad
  provider: eks
  server: https://x.example.com
  eks: {clusterName: x, roleARN: "arn:aws:iam::123456789012:role/x"}
EOF

echo "=== 9. project binding in tenant namespace ==="
t DENY app-wrong-project "must set spec.project=payments" <<'EOF'
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata: {name: sneaky, namespace: tenant-payments}
spec:
  project: default
  source: {repoURL: "https://github.com/indstri/payments-core.git", path: ., targetRevision: HEAD}
  destination: {name: in-cluster, namespace: payments-dev}
EOF
t ALLOW app-correct-project "" <<'EOF'
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata: {name: legit, namespace: tenant-payments}
spec:
  project: payments
  source: {repoURL: "https://github.com/indstri/payments-core.git", path: ., targetRevision: HEAD}
  destination: {name: in-cluster, namespace: payments-dev}
EOF

echo "=== 10. AppProject glob bypass ==="
t DENY appproject-glob "explicit namespace names" <<'EOF'
apiVersion: argoproj.io/v1alpha1
kind: AppProject
metadata: {name: sneaky-platform, namespace: argocd}
spec:
  sourceRepos: ["*"]
  sourceNamespaces: ["t*"]
EOF

echo "=== 11. repo without vault block ==="
t DENY repo-no-vault "vault.namespace" <<'EOF'
apiVersion: kro.run/v1alpha1
kind: ArgoCDTenantRepo
metadata: {name: bad-novault, namespace: argocd}
spec:
  tenant: payments
  name: novault
  url: https://github.com/indstri/x.git
EOF

echo "=== 12. labeled AppProject listing another tenant's namespace ==="
t DENY cross-tenant-appproject "belonging to the tenant in its indstri.com/tenant label" <<'EOF'
apiVersion: argoproj.io/v1alpha1
kind: AppProject
metadata:
  name: probe-crossproject
  namespace: argocd
  labels: {indstri.com/tenant: sometenant}
spec:
  sourceRepos: ["https://github.com/x/y.git"]
  sourceNamespaces: ["tenant-payments"]
EOF
# ...and KRO's own tenant AppProject must still update cleanly.
if kubectl annotate appproject payments -n argocd policy-test=1 --overwrite >/dev/null 2>&1; then
  echo "PASS (allowed) own-appproject-update"; PASS=$((PASS+1))
else
  echo "FAIL own-appproject-update: KRO's own AppProject can no longer be updated"; FAIL=$((FAIL+1))
fi

echo "=== 13. unused provider block / caData on generic ==="
t DENY eks-block-on-generic "eks.* may only be set" <<'EOF'
apiVersion: kro.run/v1alpha1
kind: ArgoCDTenantCluster
metadata: {name: bad-mixed, namespace: argocd}
spec:
  tenant: payments
  name: mixed
  provider: generic
  server: https://x.example.com
  vault: {namespace: payments}
  eks: {clusterName: x, roleARN: "arn:aws:iam::123456789012:role/x"}
EOF
t DENY cadata-on-generic "caData may only be set" <<'EOF'
apiVersion: kro.run/v1alpha1
kind: ArgoCDTenantCluster
metadata: {name: bad-cadata, namespace: argocd}
spec:
  tenant: payments
  name: badca
  provider: generic
  server: https://x.example.com
  caData: LS0tRVhBTVBMRQ==
  vault: {namespace: payments}
EOF

echo "=== 14. duplicate (tenant, name) repo ==="
t DENY dup-repo-name "already defines this tenant/name" <<'EOF'
apiVersion: kro.run/v1alpha1
kind: ArgoCDTenantRepo
metadata: {name: payments-core-dup, namespace: argocd}
spec:
  tenant: payments
  name: core
  url: https://github.com/indstri/payments-core-fork.git
  credType: https
  vault: {namespace: payments}
EOF

echo "=== 15. empty destinations (KRO minItems marker) ==="
t DENY empty-destinations "at least 1 items" <<'EOF'
apiVersion: kro.run/v1alpha1
kind: ArgoCDTenant
metadata: {name: probe-empty, namespace: argocd}
spec: {tenant: probeempty, destinations: []}
EOF

echo "=== 16. bracket-glob destination namespace ==="
t DENY bracket-destination "no glob metacharacters" <<'EOF'
apiVersion: kro.run/v1alpha1
kind: ArgoCDTenant
metadata: {name: probe-bracket, namespace: argocd}
spec: {tenant: probebracket, destinations: ["in-cluster/pay-[ab]"]}
EOF

echo "=== 17. cluster server is immutable (post-claim redirect) ==="
# The baseline payments-onprem-dc1 exists (generic, server dc1). An
# attempt to repoint its server must be rejected by KRO's immutable
# marker — otherwise an approved destination could be redirected past
# every claim check.
if kubectl patch argocdtenantclusters payments-onprem-dc1 -n argocd --type merge \
     -p '{"spec":{"server":"https://hijacked.example.com:6443"}}' >/dev/null 2>&1; then
  echo "FAIL cluster-server-immutable: server was mutated"; FAIL=$((FAIL+1))
  kubectl patch argocdtenantclusters payments-onprem-dc1 -n argocd --type merge \
    -p '{"spec":{"server":"https://dc1.k8s.indstri.com:6443"}}' >/dev/null 2>&1
else
  echo "PASS (denied) cluster-server-immutable"; PASS=$((PASS+1))
fi

echo "=== 18. cluster server with trailing slash rejected (aliasing guard) ==="
t DENY server-trailing-slash "must be host:port only" <<'EOF'
apiVersion: kro.run/v1alpha1
kind: ArgoCDTenantCluster
metadata: {name: bad-slash, namespace: argocd}
spec:
  tenant: payments
  name: slash
  provider: generic
  server: https://x.example.com:6443/
  vault: {namespace: payments}
EOF

echo "=== 19. URL-case aliasing: same host different case, second tenant claim denied ==="
# ca registers Shared (uppercase host); cb registers shared (lowercase) —
# same physical cluster. cb's claim on the same ns must be denied because
# the claim registry lowercases the server before comparing.
kubectl apply -f - >/dev/null 2>&1 <<'EOF'
apiVersion: kro.run/v1alpha1
kind: ArgoCDTenantCluster
metadata: {name: ca-shared, namespace: argocd}
spec: {tenant: ca, name: shared, provider: generic, server: "https://Shared.k8s.example.com:6443", vault: {namespace: ca}}
EOF
kubectl apply -f - >/dev/null 2>&1 <<'EOF'
apiVersion: kro.run/v1alpha1
kind: ArgoCDTenantCluster
metadata: {name: cb-shared, namespace: argocd}
spec: {tenant: cb, name: shared, provider: generic, server: "https://shared.k8s.example.com:6443", vault: {namespace: cb}}
EOF
sleep 2
kubectl apply -f - >/dev/null 2>&1 <<'EOF'
apiVersion: kro.run/v1alpha1
kind: ArgoCDTenant
metadata: {name: ca, namespace: argocd}
spec: {tenant: ca, destinations: ["ca-shared/collide-ns"]}
EOF
t DENY url-case-aliasing "already claimed by another tenant" <<'EOF'
apiVersion: kro.run/v1alpha1
kind: ArgoCDTenant
metadata: {name: cb, namespace: argocd}
spec: {tenant: cb, destinations: ["cb-shared/collide-ns"]}
EOF

echo "=== 20. unlabeled tenant-* namespace rejected ==="
t DENY unlabeled-tenant-ns "must carry indstri.com/tenant" <<'EOF'
apiVersion: v1
kind: Namespace
metadata: {name: tenant-evil}
EOF

echo "=== 21. mislabeled tenant-* namespace (label != name suffix) rejected ==="
t DENY mislabeled-tenant-ns "must carry indstri.com/tenant" <<'EOF'
apiVersion: v1
kind: Namespace
metadata:
  name: tenant-foo
  labels: {indstri.com/tenant: bar}
EOF

echo "=== 22b. positive control: benign update to a clean cluster is ALLOWED ==="
# Guards against a rule that over-blocks cluster UPDATEs (e.g. the
# host:port/immutability pair firing on an unrelated field change).
if kubectl patch argocdtenantclusters payments-onprem-dc1 -n argocd --type merge \
     -p '{"spec":{"clusterResources":true}}' >/dev/null 2>&1; then
  echo "PASS (allowed) clean-cluster-benign-update"; PASS=$((PASS+1))
  kubectl patch argocdtenantclusters payments-onprem-dc1 -n argocd --type merge \
    -p '{"spec":{"clusterResources":false}}' >/dev/null 2>&1
else
  echo "FAIL clean-cluster-benign-update: an unrelated update was denied"; FAIL=$((FAIL+1))
fi

echo "=== 22c. grandfathered bad-server cluster: unrelated update NOT wedged ==="
# DESTRUCTIVE: briefly removes the cluster field-guard cluster-wide to
# simulate a pre-policy bad-server cluster. Only safe on an isolated
# cluster. Runs only when the context looks like kind, or DESTRUCTIVE=1.
CTX="$(kubectl config current-context 2>/dev/null)"
if [ "${DESTRUCTIVE:-}" != 1 ] && ! printf '%s' "$CTX" | grep -qi kind; then
  echo "SKIP grandfathered-unrelated-update (set DESTRUCTIVE=1; context '$CTX' is not kind)"
else
# A cluster whose server predates the host:port rule (registered while the
# guard was absent) must still accept unrelated updates — server is
# immutable, so without CREATE-or-server-changed scoping it could only be
# deleted+recreated. Simulate by dropping the guard, creating a bad-server
# cluster, restoring the guard, then patching an unrelated field.
kubectl delete validatingpolicy argocd-tenant-cluster-field-guard >/dev/null 2>&1
sleep 3
kubectl apply -f - >/dev/null 2>&1 <<'EOF'
apiVersion: kro.run/v1alpha1
kind: ArgoCDTenantCluster
metadata: {name: legacy-badserver, namespace: argocd}
spec: {tenant: payments, name: legacy, provider: generic, server: "https://legacy.example.com:6443/", vault: {namespace: payments}}
EOF
kubectl apply -f "$POLICIES" >/dev/null 2>&1
sleep 6
if kubectl patch argocdtenantclusters legacy-badserver -n argocd --type merge \
     -p '{"spec":{"clusterResources":true}}' >/dev/null 2>&1; then
  echo "PASS (allowed) grandfathered-unrelated-update"; PASS=$((PASS+1))
else
  echo "FAIL grandfathered-unrelated-update: unrelated update to a bad-server cluster was wedged"; FAIL=$((FAIL+1))
fi
# ...but changing the server (even to a valid value) is still rejected by
# the immutability rule — no escape-by-repoint.
t DENY grandfathered-server-change "is immutable" <<'EOF'
apiVersion: kro.run/v1alpha1
kind: ArgoCDTenantCluster
metadata: {name: legacy-badserver, namespace: argocd}
spec: {tenant: payments, name: legacy, provider: generic, server: "https://other.example.com:6443", vault: {namespace: payments}}
EOF
kubectl delete argocdtenantclusters legacy-badserver -n argocd --wait=false >/dev/null 2>&1
fi

echo "=== 22. tenant-* namespace label removal rejected ==="
# Must be created WITH the correct label (an unlabeled create is itself
# denied by the guard — that's test 20).
kubectl apply -f - >/dev/null 2>&1 <<'EOF'
apiVersion: v1
kind: Namespace
metadata:
  name: tenant-labeltest
  labels: {indstri.com/tenant: labeltest}
EOF
if kubectl label ns tenant-labeltest indstri.com/tenant- --overwrite >/dev/null 2>&1; then
  echo "FAIL label-removal: the indstri.com/tenant label was removed"; FAIL=$((FAIL+1))
else
  echo "PASS (denied) label-removal"; PASS=$((PASS+1))
fi

echo "=== 23. spec.tenant rename rejected (would destroy namespace+project) ==="
kubectl apply -f - >/dev/null 2>&1 <<'EOF'
apiVersion: kro.run/v1alpha1
kind: ArgoCDTenant
metadata: {name: d2ren, namespace: argocd}
spec: {tenant: d2ren, destinations: ["in-cluster/d2ren-app"]}
EOF
sleep 3
t DENY tenant-rename "spec.tenant is immutable" <<'EOF'
apiVersion: kro.run/v1alpha1
kind: ArgoCDTenant
metadata: {name: d2ren, namespace: argocd}
spec: {tenant: d2ren-renamed, destinations: ["in-cluster/d2ren-app"]}
EOF

echo "=== 24. repo/cluster identity (tenant+name) rename rejected ==="
kubectl apply -f - >/dev/null 2>&1 <<'EOF'
apiVersion: kro.run/v1alpha1
kind: ArgoCDTenantCluster
metadata: {name: d2-cluster, namespace: argocd}
spec: {tenant: payments, name: idtest, provider: generic, server: "https://idtest.example.com:6443", vault: {namespace: payments}}
EOF
sleep 3
t DENY cluster-name-rename "spec.tenant/spec.name are immutable" <<'EOF'
apiVersion: kro.run/v1alpha1
kind: ArgoCDTenantCluster
metadata: {name: d2-cluster, namespace: argocd}
spec: {tenant: payments, name: idtest2, provider: generic, server: "https://idtest.example.com:6443", vault: {namespace: payments}}
EOF

echo "=== 25. offboard ordering: tenant delete blocked while children exist ==="
kubectl apply -f - >/dev/null 2>&1 <<'EOF'
apiVersion: kro.run/v1alpha1
kind: ArgoCDTenant
metadata: {name: d2del, namespace: argocd}
spec: {tenant: d2del, destinations: ["in-cluster/d2del-app"]}
---
apiVersion: kro.run/v1alpha1
kind: ArgoCDTenantRepo
metadata: {name: d2-repo, namespace: argocd}
spec: {tenant: d2del, name: core, url: "https://github.com/x/y.git", credType: https, vault: {namespace: d2del}}
EOF
sleep 4
# Deleting the tenant while its repo child exists must be denied...
if kubectl delete argocdtenant d2del -n argocd >/dev/null 2>&1; then
  echo "FAIL offboard-order: tenant deleted while child repo still existed"; FAIL=$((FAIL+1))
else
  echo "PASS (denied) offboard-order-tenant-first"; PASS=$((PASS+1))
fi
# ...but children-first, then the tenant, succeeds.
kubectl delete argocdtenantrepoes d2-repo -n argocd >/dev/null 2>&1
sleep 2
if kubectl delete argocdtenant d2del -n argocd >/dev/null 2>&1; then
  echo "PASS (allowed) offboard-order-children-first"; PASS=$((PASS+1))
else
  echo "FAIL offboard-order: childless tenant delete was still blocked"; FAIL=$((FAIL+1))
fi

echo
echo "RESULT: $PASS passed, $FAIL failed"
[ $FAIL -eq 0 ]
