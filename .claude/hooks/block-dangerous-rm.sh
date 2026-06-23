#!/usr/bin/env bash
# Hook: block-dangerous-rm.sh (PreToolUse on Bash)
# Purpose: Blocks 'rm -rf' on critical infrastructure directories.
# Why: Accidentally deleting terraform/, k8s/, or .github/ means
#      losing all infrastructure code. Git can recover it, but the blast radius
#      of an accidental 'rm -rf terraform/' is too high to leave unguarded.
# How: Checks if the command contains 'rm' with force/recursive flags targeting
#      protected directories. Exits 2 to deny execution.

set -euo pipefail

INPUT=$(cat)
COMMAND=$(echo "$INPUT" | jq -r '.tool_input.command // empty')

if [ -z "$COMMAND" ]; then
  exit 0
fi

# Protected directories — these contain all our infrastructure code
PROTECTED_DIRS="terraform k8s helm helm-values .github docs scripts .claude"

# Check for rm with force/recursive flags (-rf, -fr, -r -f, --recursive, etc.)
if echo "$COMMAND" | grep -qE 'rm\s+(-[a-zA-Z]*[rf][a-zA-Z]*\s+|--recursive|--force)'; then
  for dir in $PROTECTED_DIRS; do
    # Check if the rm command targets a protected directory
    # Match: rm -rf terraform, rm -rf ./terraform, rm -rf terraform/, etc.
    if echo "$COMMAND" | grep -qE "rm\s+.*(\s|/|^)\.?/?${dir}(/|\s|$)"; then
      echo "BLOCKED: Cannot 'rm -rf' the '${dir}/' directory."
      echo ""
      echo "This directory contains critical infrastructure code."
      echo "If you need to remove specific files, delete them individually."
      echo "If you need to reset the directory, use 'git checkout -- ${dir}/'."
      exit 2
    fi
  done
fi

# Allow all other commands
exit 0
