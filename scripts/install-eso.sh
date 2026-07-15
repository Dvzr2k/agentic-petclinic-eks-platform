#!/usr/bin/env bash
# PETPLAT-34: Install External Secrets Operator (ESO) on EKS
# Renders the official Helm chart to plain manifests (CRDs + controller) and
# applies them with kubectl — matches the "kubectl apply" installation method
# in docs/technical-spec.md#external-secrets-operator-eso, not `helm install`.
#
# Run from petclinic-platform/ after terraform apply has provisioned EKS
# and the eso_role_arn output (PETPLAT-37) is available.
#
# Usage: ./scripts/install-eso.sh <dev|prod>
set -euo pipefail

if [[ $# -ne 1 || ( "$1" != "dev" && "$1" != "prod" ) ]]; then
  echo "Usage: $0 <dev|prod>"
  exit 1
fi
ENVIRONMENT="$1"

CLUSTER_NAME="petclinic-${ENVIRONMENT}"
REGION="eu-central-1"
NAMESPACE="external-secrets"
SA_NAME="external-secrets-sa"
CHART_VERSION="0.10.4"

echo "==> Configuring kubectl for cluster ${CLUSTER_NAME}"
aws eks update-kubeconfig --name "${CLUSTER_NAME}" --region "${REGION}"

echo "==> Fetching ESO IRSA role ARN (terraform output: eso_role_arn)"
ROLE_ARN=$(terraform -chdir="terraform/environments/${ENVIRONMENT}" output -raw eso_role_arn)
echo "    Role ARN: ${ROLE_ARN}"

echo "==> Creating namespace ${NAMESPACE}"
kubectl create namespace "${NAMESPACE}" --dry-run=client -o yaml | kubectl apply -f -

# ---------------------------------------------------------------------------
# Render CRDs + controller manifests via helm template, then kubectl apply.
# The chart creates the ServiceAccount named ${SA_NAME} with the IRSA
# annotation baked in — this is the identity the ClusterSecretStore in
# k8s/base/external-secrets/cluster-secret-store.yaml authenticates as.
# ---------------------------------------------------------------------------
echo "==> Adding external-secrets Helm repo"
helm repo add external-secrets https://charts.external-secrets.io
helm repo update external-secrets

echo "==> Rendering manifests (chart ${CHART_VERSION}, CRDs included)"
helm template external-secrets external-secrets/external-secrets \
  --namespace "${NAMESPACE}" \
  --version "${CHART_VERSION}" \
  --include-crds \
  --set installCRDs=true \
  --set serviceAccount.name="${SA_NAME}" \
  --set "serviceAccount.annotations.eks\.amazonaws\.com/role-arn=${ROLE_ARN}" \
  > /tmp/external-secrets-manifests.yaml

echo "==> Applying manifests"
kubectl apply -n "${NAMESPACE}" -f /tmp/external-secrets-manifests.yaml

echo "==> Waiting for ESO controller to become ready"
kubectl rollout status deployment/external-secrets -n "${NAMESPACE}" --timeout=180s

# ---------------------------------------------------------------------------
# Wire up the ClusterSecretStore + ExternalSecrets
# ---------------------------------------------------------------------------
echo "==> Applying ClusterSecretStore and ExternalSecret CRs"
kubectl apply -f k8s/base/external-secrets/cluster-secret-store.yaml
# [Bug fix] These moved to per-env subdirectories (dev/prod ExternalSecret
# split) - was still pointing at the old flat paths, which no longer exist.
kubectl apply -f "k8s/base/external-secrets/${ENVIRONMENT}/rds-credentials.yaml"
kubectl apply -f "k8s/base/external-secrets/${ENVIRONMENT}/openai-api-key.yaml"

echo ""
echo "==> Verifying: synced K8s Secrets"
kubectl get externalsecret -n "petclinic-${ENVIRONMENT}"
kubectl get secret rds-credentials openai-api-key -n "petclinic-${ENVIRONMENT}"

echo ""
echo "Done. ESO ${CHART_VERSION} is running in namespace ${NAMESPACE}."
echo ""
echo "To add a new secret:"
echo "  1. Add an aws_secretsmanager_secret + secret_version to terraform/modules/secrets/main.tf"
echo "     (or the rds module, if it's a database credential)."
echo "  2. terraform apply in terraform/environments/{env}/ to create it in AWS Secrets Manager."
echo "  3. Add a new ExternalSecret manifest under k8s/base/external-secrets/ pointing"
echo "     secretStoreRef at aws-secrets-manager (ClusterSecretStore) and remoteRef.key"
echo "     at the new secret's name (petclinic/{env}/{secret-name})."
echo "  4. kubectl apply -f k8s/base/external-secrets/{new-file}.yaml"
echo "  5. Reference the resulting K8s Secret from the consuming Deployment via envFrom/secretKeyRef."
