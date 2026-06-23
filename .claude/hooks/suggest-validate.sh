#!/usr/bin/env bash
# Hook: suggest-validate.sh (PostToolUse on Write|Edit)
# Purpose: After editing infrastructure files, suggests running validation.
# Why: Terraform and K8s YAML files can have subtle errors that only validation catches.
#      Running validate after every edit catches errors early, before plan/apply/deploy.
# How: Checks the edited file path and suggests the appropriate validation command.
#      This is purely informational — exit 0 always (never blocks).

set -euo pipefail

INPUT=$(cat)

# Extract the file path from the tool input
# For Write tool: .tool_input.file_path
# For Edit tool: .tool_input.file_path
FILE_PATH=$(echo "$INPUT" | jq -r '.tool_input.file_path // empty')

if [ -z "$FILE_PATH" ]; then
  exit 0
fi

# Check if the file is a Terraform file
if echo "$FILE_PATH" | grep -qE '\.tf$'; then
  TF_DIR=$(dirname "$FILE_PATH")
  echo "Tip: You edited a Terraform file. Run 'terraform validate' in ${TF_DIR}/ to check for errors."
  echo "     Also run 'terraform fmt -check' to verify formatting."
fi

# Check if the file is a Kubernetes YAML file
if echo "$FILE_PATH" | grep -qE 'k8s/.*\.(yaml|yml)$'; then
  echo "Tip: You edited a K8s manifest. Run 'kubectl apply --dry-run=client -f ${FILE_PATH}' to validate."
fi

# Check if the file is a Helm chart template or values file
if echo "$FILE_PATH" | grep -qE '(helm/|helm-values/).*\.(yaml|yml|tpl)$'; then
  echo "Tip: You edited a Helm file. Validate with:"
  echo "     helm template petclinic helm/petclinic-service/ -f helm-values/{service}.yaml -f helm-values/{env}.yaml"
  echo "     helm lint helm/petclinic-service/ -f helm-values/{service}.yaml -f helm-values/{env}.yaml"
fi

# Check if the file is a GitHub Actions workflow file
if echo "$FILE_PATH" | grep -qE '\.github/workflows/.*\.(yaml|yml)$'; then
  echo "Tip: You edited a GitHub Actions workflow. Review with the pipeline-reviewer agent before committing."
  echo "     Validate locally with: act --dryrun (if installed) or push to a feature branch to test."
fi

# Always exit 0 — this hook is informational only, never blocks
exit 0
