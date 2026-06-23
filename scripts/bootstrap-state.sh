#!/usr/bin/env bash
set -euo pipefail

REGION="eu-central-1"

usage() {
  echo "Usage: $0 [--region <aws-region>]"
  echo "  --region   AWS region (default: eu-central-1)"
  exit 1
}

while [[ $# -gt 0 ]]; do
  case $1 in
    --region)
      REGION="$2"
      shift 2
      ;;
    -h|--help)
      usage
      ;;
    *)
      echo "Unknown argument: $1" >&2
      usage
      ;;
  esac
done

ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
BUCKET_NAME="petclinic-terraform-state-${ACCOUNT_ID}"
DYNAMODB_TABLE="petclinic-terraform-locks"

echo "=== Terraform State Bootstrap ==="
echo "  Region:   ${REGION}"
echo "  Account:  ${ACCOUNT_ID}"
echo "  Bucket:   ${BUCKET_NAME}"
echo "  DynamoDB: ${DYNAMODB_TABLE}"
echo ""

# --- S3 bucket ---

if aws s3api head-bucket --bucket "${BUCKET_NAME}" --region "${REGION}" 2>/dev/null; then
  echo "[skip] S3 bucket already exists: ${BUCKET_NAME}"
else
  echo "[create] S3 bucket: ${BUCKET_NAME}"
  if [ "${REGION}" = "us-east-1" ]; then
    aws s3api create-bucket \
      --bucket "${BUCKET_NAME}" \
      --region "${REGION}"
  else
    aws s3api create-bucket \
      --bucket "${BUCKET_NAME}" \
      --region "${REGION}" \
      --create-bucket-configuration LocationConstraint="${REGION}"
  fi
fi

echo "[apply] S3 versioning..."
aws s3api put-bucket-versioning \
  --bucket "${BUCKET_NAME}" \
  --versioning-configuration Status=Enabled

echo "[apply] S3 encryption (AES256)..."
aws s3api put-bucket-encryption \
  --bucket "${BUCKET_NAME}" \
  --server-side-encryption-configuration '{
    "Rules": [{
      "ApplyServerSideEncryptionByDefault": {"SSEAlgorithm": "AES256"},
      "BucketKeyEnabled": true
    }]
  }'

echo "[apply] S3 block public access..."
aws s3api put-public-access-block \
  --bucket "${BUCKET_NAME}" \
  --public-access-block-configuration \
    BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true

echo "[apply] S3 tags..."
aws s3api put-bucket-tagging \
  --bucket "${BUCKET_NAME}" \
  --tagging 'TagSet=[
    {Key=Project,Value=petclinic},
    {Key=ManagedBy,Value=terraform},
    {Key=Purpose,Value=terraform-state}
  ]'

# --- DynamoDB table ---

if aws dynamodb describe-table \
    --table-name "${DYNAMODB_TABLE}" \
    --region "${REGION}" \
    --output text 2>/dev/null | grep -q ACTIVE; then
  echo "[skip] DynamoDB table already exists: ${DYNAMODB_TABLE}"
else
  echo "[create] DynamoDB table: ${DYNAMODB_TABLE}"
  aws dynamodb create-table \
    --table-name "${DYNAMODB_TABLE}" \
    --attribute-definitions AttributeName=LockID,AttributeType=S \
    --key-schema AttributeName=LockID,KeyType=HASH \
    --billing-mode PAY_PER_REQUEST \
    --region "${REGION}" \
    --tags \
      Key=Project,Value=petclinic \
      Key=ManagedBy,Value=terraform \
      Key=Purpose,Value=terraform-state-lock

  echo "[wait] DynamoDB table becoming active..."
  aws dynamodb wait table-exists \
    --table-name "${DYNAMODB_TABLE}" \
    --region "${REGION}"
fi

echo ""
echo "=== Bootstrap complete ==="
echo ""
echo "Next steps:"
echo "  1. Update backend.tf in both environments — replace ACCOUNT_ID:"
echo "     bucket = \"${BUCKET_NAME}\""
echo ""
echo "  2. Run terraform init in each environment:"
echo "     cd terraform/environments/dev && terraform init"
echo "     cd terraform/environments/prod && terraform init"
