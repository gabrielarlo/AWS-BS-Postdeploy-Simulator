#!/usr/bin/env bash
set -euo pipefail

SCRIPT="/workspace/scripts/postdeploy-phpredis.sh"

if [[ ! -f "$SCRIPT" ]]; then
  echo "ERROR: $SCRIPT not found."
  echo "Copy your full postdeploy script to scripts/postdeploy-phpredis.sh first."
  exit 2
fi

echo "Checking Bash syntax..."
bash -n "$SCRIPT"
echo "PASS: bash -n"

if command -v shellcheck >/dev/null 2>&1; then
  echo "Running ShellCheck..."
  shellcheck "$SCRIPT"
  echo "PASS: ShellCheck"
else
  echo "SKIP: ShellCheck is not installed."
fi
