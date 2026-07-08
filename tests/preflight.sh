#!/bin/bash
# Preflight gate — run AFTER applying platform-policies.yaml and BEFORE
# onboarding any tenant. Fails (non-zero) unless Kyverno actually has the
# RBAC and all policies are ready. A silent RBAC-aggregation miss makes
# the fail-closed policies deny every tenant write with an opaque error;
# this turns that into a loud, early failure.
#
# Usage: bash tests/preflight.sh   (exit 0 = safe to onboard)

set -u
FAIL=0
# Kyverno controller service accounts. Override if your chart names them
# differently (release-name prefix, older/newer chart):
#   KYVERNO_NS=kyverno ADM_SA=... RPT_SA=... bash tests/preflight.sh
KYVERNO_NS="${KYVERNO_NS:-kyverno}"
ADM="system:serviceaccount:${KYVERNO_NS}:${ADM_SA:-kyverno-admission-controller}"
RPT="system:serviceaccount:${KYVERNO_NS}:${RPT_SA:-kyverno-reports-controller}"

check_rbac() { # <serviceaccount> <verb> <resource>
  local sa=$1 verb=$2 res=$3
  if [ "$(kubectl auth can-i "$verb" "$res" --as "$sa" 2>/dev/null)" = yes ]; then
    echo "  ok   $verb $res  (as ${sa##*:})"
  else
    echo "  FAIL $verb $res  (as ${sa##*:})"; FAIL=1
  fi
}

echo "== RBAC: admission controller must list the claim inputs =="
for res in argocdtenants.kro.run argocdtenantclusters.kro.run \
           argocdtenantrepoes.kro.run namespaces; do
  check_rbac "$ADM" list "$res"
done

echo "== RBAC: reports controller (background conflict scans) =="
# repoes included: the repo field-guard has background eval and lists it.
for res in argocdtenants.kro.run argocdtenantclusters.kro.run \
           argocdtenantrepoes.kro.run namespaces; do
  check_rbac "$RPT" list "$res"
done

echo "== ValidatingPolicies must all be READY =="
for p in argocd-tenant-project-binding argocd-appproject-guard \
         argocd-tenant-namespace-guard argocd-tenant-destination-guard \
         argocd-tenant-claims argocd-tenant-repo-field-guard \
         argocd-tenant-cluster-field-guard argocd-tenant-referential-guard; do
  ready=$(kubectl get validatingpolicy "$p" -o jsonpath='{.status.conditionStatus.ready}' 2>/dev/null)
  if [ "$ready" = true ]; then
    echo "  ok   $p"
  else
    echo "  FAIL $p (ready=$ready)"; FAIL=1
  fi
done

echo
if [ $FAIL -eq 0 ]; then
  echo "PREFLIGHT OK — safe to onboard tenants"
else
  echo "PREFLIGHT FAILED — do NOT onboard; fix RBAC aggregation / policy readiness first"
fi
exit $FAIL
