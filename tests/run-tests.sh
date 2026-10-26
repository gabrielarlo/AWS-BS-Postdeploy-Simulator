#!/usr/bin/env bash
set -euo pipefail

SCRIPT="/workspace/scripts/postdeploy-phpredis.sh"
LOG_DIR="/workspace/logs"
mkdir -p "$LOG_DIR"

if [[ ! -f "$SCRIPT" ]]; then
  echo "ERROR: $SCRIPT not found."
  exit 2
fi

echo "Target metadata:"
echo "  platform=${TEST_PLATFORM:-eb-php84-al2023-4.13.13}"
echo "  PHP=${TEST_PHP_VERSION:-8.4}"
echo "  redis_loaded=${TEST_REDIS_LOADED:-false}"
echo
echo "NOTE: This harness does not execute the installer."

bash -n "$SCRIPT"
echo "PASS: Bash syntax"

if grep -q 'redis_so_is_loadable' "$SCRIPT"; then
  echo "REVIEW: redis_so_is_loadable checks file existence, not runtime loadability."
fi
if grep -q 'sudo ln -sf' "$SCRIPT"; then
  echo "REVIEW: Verify symbolic-link failures propagate as errors."
fi
if grep -q 'php8.4-pecl-redis6' "$SCRIPT"; then
  echo "INFO: Script contains a PHP 8.4 package name; verify it exists in the EB repositories."
fi

{
  echo "phpredis postdeploy harness report"
  date -u '+UTC timestamp: %Y-%m-%dT%H:%M:%SZ'
  echo "TEST_PLATFORM=${TEST_PLATFORM:-eb-php84-al2023-4.13.13}"
  echo "TEST_PHP_VERSION=${TEST_PHP_VERSION:-8.4}"
  echo "TEST_REDIS_LOADED=${TEST_REDIS_LOADED:-false}"
  echo "Result: syntax passed; installer not executed."
} | tee "$LOG_DIR/test-report.txt"

echo "PASS: safe harness checks completed."
