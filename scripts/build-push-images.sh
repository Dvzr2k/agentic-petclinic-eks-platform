#!/usr/bin/env bash
set -euo pipefail

ENV="${1:-dev}"
TAG="${2:-v1.0.0}"
REGION="${3:-eu-central-1}"
APP_REPO="${4:-$(dirname "$(cd "$(dirname "$0")" && pwd)")/../spring-petclinic-microservices}"

ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
REGISTRY="${ACCOUNT_ID}.dkr.ecr.${REGION}.amazonaws.com"

SERVICES=(
  config-server
  discovery-server
  api-gateway
  customers-service
  visits-service
  vets-service
  genai-service
  admin-server
)

SERVICE_PORTS=(
  8888
  8761
  8080
  8081
  8082
  8083
  8084
  9090
)

echo "============================================"
echo "  Petclinic Docker Build & Push"
echo "  Environment: ${ENV}"
echo "  Tag: ${TAG}"
echo "  Registry: ${REGISTRY}"
echo "  App repo: ${APP_REPO}"
echo "  Platform: linux/arm64 (Graviton)"
echo "============================================"

if [ ! -d "${APP_REPO}" ]; then
  echo "ERROR: Application repo not found at ${APP_REPO}"
  echo "Clone it: git clone https://github.com/spring-petclinic/spring-petclinic-microservices.git"
  exit 1
fi

echo ""
echo "--- Step 1: ECR Login ---"
aws ecr get-login-password --region "${REGION}" \
  | docker login --username AWS --password-stdin "${REGISTRY}"

echo ""
echo "--- Step 2: Build JARs with Maven ---"
cd "${APP_REPO}"
./mvnw clean install -DskipTests -pl \
  spring-petclinic-config-server,\
spring-petclinic-discovery-server,\
spring-petclinic-api-gateway,\
spring-petclinic-customers-service,\
spring-petclinic-visits-service,\
spring-petclinic-vets-service,\
spring-petclinic-genai-service,\
spring-petclinic-admin-server \
  -am

echo ""
echo "--- Step 3: Set up Docker Buildx ---"
docker buildx create --name petclinic-builder --use 2>/dev/null || docker buildx use petclinic-builder
docker buildx inspect --bootstrap

echo ""
echo "--- Step 4: Build and push ARM64 images ---"
for i in "${!SERVICES[@]}"; do
  SERVICE="${SERVICES[$i]}"
  PORT="${SERVICE_PORTS[$i]}"
  MAVEN_MODULE="spring-petclinic-${SERVICE}"
  JAR_PATH="${APP_REPO}/${MAVEN_MODULE}/target/${MAVEN_MODULE}-*.jar"
  IMAGE="${REGISTRY}/petclinic-${ENV}/${SERVICE}:${TAG}"

  JAR_FILE=$(ls ${JAR_PATH} 2>/dev/null | grep -v sources | head -1)
  if [ -z "${JAR_FILE}" ]; then
    echo "ERROR: JAR not found for ${SERVICE} at ${JAR_PATH}"
    exit 1
  fi

  echo ""
  echo "Building ${SERVICE} → ${IMAGE}"

  ARTIFACT_NAME=$(basename "${JAR_FILE}" .jar)

  docker buildx build \
    --platform linux/arm64 \
    --build-arg ARTIFACT_NAME="${ARTIFACT_NAME}" \
    --build-arg EXPOSED_PORT="${PORT}" \
    -f "${APP_REPO}/docker/Dockerfile" \
    -t "${IMAGE}" \
    --push \
    "$(dirname "${JAR_FILE}")"

  echo "Pushed: ${IMAGE}"
done

echo ""
echo "============================================"
echo "  All 8 images built and pushed!"
echo "  Environment: ${ENV}"
echo "  Tag: ${TAG}"
echo "  Platform: linux/arm64"
echo "============================================"
echo ""
echo "Verify with:"
echo "  aws ecr describe-images --repository-name petclinic-${ENV}/api-gateway --region ${REGION}"
