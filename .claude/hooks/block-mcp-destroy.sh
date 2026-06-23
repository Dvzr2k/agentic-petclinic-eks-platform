#!/usr/bin/env bash
# Hook: block-mcp-destroy.sh (PreToolUse on MCP Terraform/Terragrunt tools)
# Purpose: Blocks 'destroy' command via MCP ExecuteTerraformCommand/ExecuteTerragruntCommand.
# Why: The block-destroy.sh hook catches 'terraform destroy' in Bash commands,
#      but the MCP Terraform server has its own destroy command that bypasses Bash.
#      This hook closes that gap by checking the MCP tool's command parameter.
# How: Reads the tool input JSON from stdin, checks the 'command' field for 'destroy'.

set -euo pipefail

INPUT=$(cat)

# Extract the command field from the MCP tool input
# MCP tool calls use: .tool_input.command
COMMAND=$(echo "$INPUT" | jq -r '.tool_input.command // empty')

if [ -z "$COMMAND" ]; then
  exit 0
fi

# Block destroy command
if [ "$COMMAND" = "destroy" ]; then
  echo "BLOCKED: 'destroy' via MCP Terraform tool is not allowed."
  echo ""
  echo "Destroying infrastructure must be done manually with explicit human oversight."
  echo "Run 'terraform destroy' directly in your terminal (not via Claude Code)."
  exit 2
fi

exit 0
