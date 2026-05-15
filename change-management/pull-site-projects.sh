#!/bin/bash
#set -eo pipefail

# Load env vars (API keys etc.)
#[ -f .env ] && set -a && source .env && set +a
export NODE_TLS_REJECT_UNAUTHORIZED=0

DEPLOYMENT=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --deployment) DEPLOYMENT="$2"; shift 2 ;;
    *) echo "Unknown option: $1"; exit 1 ;;
  esac
done

log() { echo "[pull] $*"; }

trap 'log "Script exited unexpectedly at line $LINENO (exit code $?)"' ERR

# ── Check openfn CLI version ─────────────────────────────────────────────────
_required_version="1.31.0"
if ! command -v openfn &>/dev/null; then
  echo "Error: openfn CLI is not installed."
  echo "Install with: npm i -g @openfn/cli   or   pnpm i -g @openfn/cli"
  exit 1
fi
_actual_version=$(openfn version 2>&1 | awk '/▸.*cli/ { print $NF }')
if [ -z "$_actual_version" ]; then
  echo "Error: could not determine openfn CLI version."
  echo "Try reinstalling: npm i -g @openfn/cli   or   pnpm i -g @openfn/cli"
  exit 1
fi
if ! printf '%s\n%s\n' "$_required_version" "$_actual_version" | sort -V -C; then
  echo "Error: openfn CLI $_actual_version is installed but >= $_required_version is required."
  echo "Upgrade with: npm i -g @openfn/cli   or   pnpm i -g @openfn/cli"
  exit 1
fi
unset _required_version _actual_version

for project_config in ${DEPLOYMENT:-*}/*-config.json; do

  (
    spec_path=$(grep '"specPath"' "$project_config" | sed 's/.*"specPath"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/')
    endpoint=$(grep '"endpoint"' "$project_config" | sed 's/.*"endpoint"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/')
    dest_dir=$(dirname "$spec_path")
    base=$(basename "$spec_path")
    facility="${base%-project.yaml}"
    project_name="${facility}-et-emr"

    api_key_var="$(echo "$dest_dir" | tr '[:lower:]' '[:upper:]')_API_KEY"

    project_id=$(curl -sk \
      -H "Authorization: Bearer ${!api_key_var}" \
      "${endpoint}/api/projects" \
      | awk -v target="$project_name" '
          BEGIN { RS="\"type\":\"projects\"" }
          index($0, "\"name\":\"" target "\"") {
            match($0, /"id":"[^"]*"/)
            print substr($0, RSTART+6, RLENGTH-7)
            exit
          }
        ')

    if [ -z "$project_id" ]; then
      log "Project '${project_name}' not found on '${endpoint}', skipping."
      exit 0
    fi

    log "Pulling '${project_name}' (id: ${project_id})..."
    if OPENFN_API_KEY="${!api_key_var}" openfn pull "$project_id" -c "$project_config" --no-confirm; then
      log "  Pulled."
    else
      log "  Pull failed for '${project_name}'."
    fi
  ) || log "  Unexpected error processing '$project_config', continuing."
done

log ""
log "Pull complete."
