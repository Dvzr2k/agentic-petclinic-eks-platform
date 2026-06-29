#!/usr/bin/env bash
# PETPLAT-29: Install AWS Load Balancer Controller on EKS
# Creates the IRSA role and installs the controller via Helm.
#
# Run from petclinic-platform/ after terraform apply has provisioned EKS.
# Re-running is safe — create commands fall back to existing resources.
set -euo pipefail

# Application version tag (used for CRD URL on GitHub).
# IMPORTANT: use the application version (v2.x.x), NOT the Helm chart version (1.x.x).
# They use different numbering schemes — the wrong tag returns a 404.
APP_VERSION="v2.8.2"
CHART_VERSION="1.8.2"

CLUSTER_NAME="petclinic-dev"
REGION="eu-central-1"
ROLE_NAME="petclinic-dev-lb-controller-role"
POLICY_NAME="petclinic-dev-lb-controller-policy"
SA_NAME="aws-load-balancer-controller"
SA_NAMESPACE="kube-system"

ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)

echo "==> Configuring kubectl for cluster ${CLUSTER_NAME}"
aws eks update-kubeconfig --name "${CLUSTER_NAME}" --region "${REGION}"

# ---------------------------------------------------------------------------
# IAM Policy
# ---------------------------------------------------------------------------
echo "==> Downloading IAM policy (app version ${APP_VERSION})"
curl -sSfL \
  "https://raw.githubusercontent.com/kubernetes-sigs/aws-load-balancer-controller/${APP_VERSION}/docs/install/iam_policy.json" \
  -o /tmp/lb_controller_policy.json

echo "==> Creating IAM policy ${POLICY_NAME}"
POLICY_ARN=$(aws iam create-policy \
  --policy-name "${POLICY_NAME}" \
  --policy-document file:///tmp/lb_controller_policy.json \
  --query Policy.Arn \
  --output text 2>/dev/null) || \
POLICY_ARN=$(aws iam list-policies \
  --scope Local \
  --query "Policies[?PolicyName=='${POLICY_NAME}'].Arn | [0]" \
  --output text)

echo "    Policy ARN: ${POLICY_ARN}"

# ---------------------------------------------------------------------------
# IRSA Role
# ---------------------------------------------------------------------------
echo "==> Fetching OIDC provider"
OIDC_URL=$(aws eks describe-cluster \
  --name "${CLUSTER_NAME}" \
  --region "${REGION}" \
  --query "cluster.identity.oidc.issuer" \
  --output text | sed 's|https://||')

OIDC_ARN="arn:aws:iam::${ACCOUNT_ID}:oidc-provider/${OIDC_URL}"

cat > /tmp/lb_trust_policy.json <<EOF
{
  "Version": "2012-10-17",
  "Statement": [{
    "Effect": "Allow",
    "Principal": {
      "Federated": "${OIDC_ARN}"
    },
    "Action": "sts:AssumeRoleWithWebIdentity",
    "Condition": {
      "StringEquals": {
        "${OIDC_URL}:sub": "system:serviceaccount:${SA_NAMESPACE}:${SA_NAME}",
        "${OIDC_URL}:aud": "sts.amazonaws.com"
      }
    }
  }]
}
EOF

echo "==> Creating IRSA role ${ROLE_NAME}"
ROLE_ARN=$(aws iam create-role \
  --role-name "${ROLE_NAME}" \
  --assume-role-policy-document file:///tmp/lb_trust_policy.json \
  --query Role.Arn \
  --output text 2>/dev/null) || \
ROLE_ARN=$(aws iam get-role \
  --role-name "${ROLE_NAME}" \
  --query Role.Arn \
  --output text)

echo "    Role ARN: ${ROLE_ARN}"

echo "==> Attaching policy to role"
aws iam attach-role-policy \
  --role-name "${ROLE_NAME}" \
  --policy-arn "${POLICY_ARN}" 2>/dev/null || true

# ---------------------------------------------------------------------------
# CRDs — use APP_VERSION tag, not chart version
# ---------------------------------------------------------------------------
echo "==> Installing CRDs (app ${APP_VERSION})"
kubectl apply -f \
  "https://raw.githubusercontent.com/kubernetes-sigs/aws-load-balancer-controller/${APP_VERSION}/helm/aws-load-balancer-controller/crds/crds.yaml"

# ---------------------------------------------------------------------------
# Helm install
# ---------------------------------------------------------------------------
echo "==> Adding EKS Helm repo"
helm repo add eks https://aws.github.io/eks-charts
helm repo update eks

VPC_ID=$(aws ec2 describe-vpcs \
  --region "${REGION}" \
  --filters "Name=tag:Name,Values=petclinic-dev-vpc" \
  --query "Vpcs[0].VpcId" \
  --output text)

echo "==> Installing aws-load-balancer-controller chart ${CHART_VERSION}"
helm upgrade --install aws-load-balancer-controller eks/aws-load-balancer-controller \
  --namespace "${SA_NAMESPACE}" \
  --version "${CHART_VERSION}" \
  --set clusterName="${CLUSTER_NAME}" \
  --set serviceAccount.create=true \
  --set serviceAccount.name="${SA_NAME}" \
  --set "serviceAccount.annotations.eks\.amazonaws\.com/role-arn=${ROLE_ARN}" \
  --set region="${REGION}" \
  --set vpcId="${VPC_ID}" \
  --wait

# ---------------------------------------------------------------------------
# Verify
# ---------------------------------------------------------------------------
echo ""
echo "==> Controller pods:"
kubectl get pods -n "${SA_NAMESPACE}" -l app.kubernetes.io/name=aws-load-balancer-controller

echo ""
echo "==> IngressClass:"
kubectl get ingressclass alb

echo ""
echo "Done. LB Controller ${APP_VERSION} is running."
echo ""
echo "Next steps:"
echo "  1. Fill in k8s/base/ingress/ingress.yaml placeholders:"
echo "       cd terraform/environments/dev"
echo "       terraform output -raw certificate_arn   # → REPLACE_WITH_ACM_CERTIFICATE_ARN"
echo "       terraform output -raw alb_sg_id         # → REPLACE_WITH_ALB_SG_ID"
echo "  2. kubectl apply -f k8s/base/ingress/ingress.yaml"
echo "  3. Wait ~3 min for ALB to provision, then:"
echo "       terraform apply -var=\"create_alb_dns_record=true\""
