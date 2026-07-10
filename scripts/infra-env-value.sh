#!/usr/bin/env bash
# Prints a single value from the VM-local compose-infra credentials file
# (/opt/case-poc/infra.env). Exists because `multipass exec ... -c "..."`
# on Windows loses argument quoting — host scripts call this instead:
#
#   multipass exec case-poc-cp -- sudo bash /repo/scripts/infra-env-value.sh GITLAB_API_TOKEN
set -eu
KEY="${1:?usage: infra-env-value.sh KEY}"
ENV_FILE="${ENV_FILE:-/opt/case-poc/infra.env}"
# shellcheck disable=SC1090
. "$ENV_FILE"
eval "printf '%s\n' \"\${$KEY:?$KEY not set in $ENV_FILE}\""
