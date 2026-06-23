#!/usr/bin/env bash
# Hook: warn-apply-without-plan.sh (PreToolUse on Bash)
# Purpose: Warns when running 'terraform apply' without a saved plan file.
# Why: Running 'terraform apply' without a plan can make unexpected changes.
#      The safe workflow is: plan -out plan.out → review → apply plan.out.
#      This hook doesn't block — it escalates to ask the user for confirmation.
# How: Checks if 'terraform apply' or 'terragrunt apply' is run without
#      a .out plan file argument. Exits 1 to ask for user confirmation.

set -euo pipefail

INPUT=$(cat)
COMMAND=$(echo "$INPUT" | jq -r '.tool_input.command // empty')

if [ -z "$COMMAND" ]; then
  exit 0
fi

# Check for terraform/terragrunt apply
if echo "$COMMAND" | grep -qE '(terraform|terragrunt)\s+apply'; then
  # Check if a plan file is provided (*.out or *.tfplan)
  if echo "$COMMAND" | grep -qE 'apply\s+.*\.(out|tfplan)'; then
    # Plan file provided — this is the safe workflow, allow it
    exit 0
  fi

  # Check for -auto-approve flag (extra dangerous without a plan)
  if echo "$COMMAND" | grep -qE '\-auto-approve'; then
    echo "WARNING: 'terraform apply -auto-approve' without a saved plan is risky."
    echo ""
    echo "Recommended safe workflow:"
    echo "  1. terraform plan -out plan.out"
    echo "  2. Review the plan output"
    echo "  3. terraform apply plan.out"
    echo ""
    echo "Using -auto-approve skips the confirmation prompt AND uses no saved plan."
    exit 1
  fi

  # No plan file — warn and ask for confirmation
  echo "WARNING: Running 'terraform apply' without a saved plan file."
  echo ""
  echo "Recommended workflow:"
  echo "  1. terraform plan -out plan.out"
  echo "  2. Review the plan"
  echo "  3. terraform apply plan.out"
  echo ""
  echo "Proceeding without a plan means Terraform will re-plan at apply time,"
  echo "and the changes may differ from what you reviewed."
  exit 1
fi

exit 0
