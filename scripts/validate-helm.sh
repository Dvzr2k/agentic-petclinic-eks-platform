#!/usr/bin/env bash
# PETPLAT-110: Validate Helm template rendering for all services/environments.
#
# Runs `helm lint`, then `helm template` + `kubectl apply --dry-run=client`
# for each of the 8 services against both dev and prod values, failing on
# the first error. Run this after any change to helm/petclinic-service/ or
# helm-values/.
#
# Usage:
#   ./scripts/validate-helm.sh
set -euo pipefail

CHART="helm/petclinic-service"
SERVICES=(config-server discovery-server customers-service visits-service vets-service genai-service api-gateway admin-server)
ENVIRONMENTS=(dev prod)

echo "==> helm lint ${CHART}"
helm lint "${CHART}"

fail=0
for svc in "${SERVICES[@]}"; do
  for env in "${ENVIRONMENTS[@]}"; do
    ns="petclinic-${env}"
    rendered=$(mktemp)
    echo "==> helm template ${svc} (${env})"
    if ! helm template "${svc}" "${CHART}/" -n "${ns}" \
        -f "helm-values/${svc}.yaml" -f "helm-values/${env}.yaml" > "${rendered}"; then
      echo "FAILED: helm template ${svc} / ${env}"
      fail=1
      continue
    fi

    echo "==> kubectl apply --dry-run=client (${svc} / ${env})"
    if ! kubectl apply --dry-run=client -f "${rendered}" > /dev/null; then
      echo "FAILED: kubectl dry-run ${svc} / ${env}"
      fail=1
    fi
    rm -f "${rendered}"
  done
done

if [[ "${fail}" -eq 1 ]]; then
  echo ""
  echo "Validation FAILED — see errors above."
  exit 1
fi

echo ""
echo "All ${#SERVICES[@]} services x ${#ENVIRONMENTS[@]} environments rendered and validated successfully."
