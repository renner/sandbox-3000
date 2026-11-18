#!/usr/bin/env bash
# Create (or update) the podman secret oc_env_<VAR> that oc() injects into the
# sandbox as the environment variable <VAR>.
#
#   ./set-podman-secret.sh PROVIDER_API_KEY
#
# Prompts for the value without echoing it. For automation, pipe it in:
#
#   printf '%s' "$PROVIDER_API_KEY" | ./set-podman-secret.sh PROVIDER_API_KEY

set -euo pipefail

usage() {
  printf 'usage: %s VAR_NAME\n' "${0##*/}" >&2
  printf 'example: %s PROVIDER_API_KEY\n' "${0##*/}" >&2
  exit 2
}

[ $# -eq 1 ] || usage
var=$1

[[ $var =~ ^[A-Z_][A-Z0-9_]*$ ]] || {
  printf 'error: %s is not an environment variable name (try PROVIDER_API_KEY)\n' "$var" >&2
  exit 2
}

command -v podman >/dev/null 2>&1 || {
  echo 'error: podman not found in PATH' >&2
  exit 1
}

secret="oc_env_$var"

if [ -t 0 ]; then
  read -rsp "$var: " key
  printf '\n' >&2
else
  IFS= read -r key || true
fi

[ -n "$key" ] || { echo 'error: empty value; nothing stored' >&2; exit 1; }

printf '%s' "$key" | podman secret create --replace "$secret" - >/dev/null
unset key

printf 'stored %s; opencode can read it as {env:%s}\n' "$secret" "$var"

podman secret ls --format '{{.ID}}  {{.Name}}  {{.Driver}}  {{.UpdatedAt}}' |
  awk -v name="$secret" '$2 == name'
