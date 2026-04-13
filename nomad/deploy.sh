#!/bin/bash
# Deploy IronClaw shards with optional mock LLM.
#
# Usage:
#   ./deploy.sh                              # Deploy shards (current image, current LLM)
#   ./deploy.sh --image TAG                  # Deploy shards pinned to image TAG
#   ./deploy.sh --mock=stacklok              # Switch to StacklokLabs/mockllm (simple canned responses)
#   ./deploy.sh --mock=llmock                # Switch to CopilotKit/llmock (fixture-driven, SSE, chaos)
#   ./deploy.sh --real                       # Restore real LLM config from saved backup
#   ./deploy.sh --status                     # Show LLM mode, active mock backend, and image
#
# --image can combine with any subcommand:
#   ./deploy.sh --image us-central1-docker.pkg.dev/.../ironclaw:abc1234 --mock=llmock
#
# The two mock backends are mutually exclusive (both bind port 4010 on host
# networking). Switching between them via --mock=NAME purges the other first.
# `--real` purges either. Shards need no config change — they always point
# at http://localhost:4010 when in mock mode.

set -euo pipefail
# cd to repo root so `nomad job run` paths are consistent and any relative
# file() references inside the HCL resolve against the same CWD whether
# the script is invoked from the repo root or elsewhere.
cd "$(dirname "$0")/.."

BACKUP_FILE="/tmp/ironclaw-real-llm-vars.json"
MOCK_BACKEND=""

# Parse --image TAG and --mock=NAME (can appear anywhere in args; other tokens
# fall through to the subcommand case statement below).
ARGS=()
while [ $# -gt 0 ]; do
  case "$1" in
    --image)
      [ -z "${2:-}" ] && { echo "Error: --image requires a TAG argument" >&2; exit 1; }
      export NOMAD_VAR_ironclaw_image="$2"
      shift 2
      ;;
    --mock=*)
      MOCK_BACKEND="${1#--mock=}"
      case "$MOCK_BACKEND" in
        stacklok|llmock) ;;
        *) echo "Error: --mock=$MOCK_BACKEND: unknown backend (expected stacklok or llmock)" >&2; exit 1 ;;
      esac
      ARGS+=("--mock")
      shift
      ;;
    --mock)
      echo "Error: --mock requires a backend name. Use --mock=stacklok or --mock=llmock" >&2
      exit 1
      ;;
    *)
      ARGS+=("$1")
      shift
      ;;
  esac
done
set -- "${ARGS[@]+"${ARGS[@]}"}"

get_var() {
  nomad var get nomad/jobs/ironclaw-shards 2>/dev/null | python3 -c "
import json, sys
data = json.load(sys.stdin)
print(data.get('Items', {}).get('$1', ''))
"
}

save_real_vars() {
  echo "  Saving current LLM config to $BACKUP_FILE..."
  nomad var get nomad/jobs/ironclaw-shards 2>/dev/null | python3 -c "
import json, sys
data = json.load(sys.stdin)
items = data.get('Items', {})
backup = {k: items[k] for k in ['NEARAI_API_KEY', 'NEARAI_BASE_URL', 'NEARAI_MODEL'] if k in items}
json.dump(backup, sys.stdout)
" > "$BACKUP_FILE"
}

restore_real_vars() {
  if [ ! -f "$BACKUP_FILE" ]; then
    echo "Error: No saved config at $BACKUP_FILE. Set variables manually:"
    echo "  nomad var put -force nomad/jobs/ironclaw-shards NEARAI_BASE_URL=... NEARAI_API_KEY=... NEARAI_MODEL=..."
    exit 1
  fi

  echo "  Restoring real LLM config from $BACKUP_FILE..."
  eval "$(python3 -c "
import json
with open('$BACKUP_FILE') as f:
    d = json.load(f)
for k, v in d.items():
    print(f'export SAVED_{k}=\"{v}\"')
")"

  nomad var put -force nomad/jobs/ironclaw-shards \
    "NEARAI_API_KEY=$SAVED_NEARAI_API_KEY" \
    "NEARAI_BASE_URL=$SAVED_NEARAI_BASE_URL" \
    "NEARAI_MODEL=$SAVED_NEARAI_MODEL" \
    "DATABASE_URL=$(get_var DATABASE_URL)" \
    "SECRETS_MASTER_KEY=$(get_var SECRETS_MASTER_KEY)" \
    "GATEWAY_ADMIN_TOKEN=$(get_var GATEWAY_ADMIN_TOKEN)" \
    "HTTP_WEBHOOK_SECRET=$(get_var HTTP_WEBHOOK_SECRET)" \
    > /dev/null
}

redeploy_shards() {
  echo "  Redeploying shards..."
  nomad job stop ironclaw-shards 2>/dev/null || true
  sleep 3
  nomad job run nomad/ironclaw.nomad.hcl
}

# Map backend name -> Nomad job name + .nomad.hcl file + human label.
mock_job_name() {
  case "$1" in
    stacklok) echo "mockllm" ;;
    llmock)   echo "llmock" ;;
    *)        echo "" ;;
  esac
}

mock_job_file() {
  case "$1" in
    stacklok) echo "nomad/mockllm.nomad.hcl" ;;
    llmock)   echo "nomad/llmock.nomad.hcl" ;;
    *)        echo "" ;;
  esac
}

# Print which mock backend has a running Nomad job, or empty string if none.
active_mock_backend() {
  for be in stacklok llmock; do
    job=$(mock_job_name "$be")
    if nomad job status "$job" >/dev/null 2>&1; then
      echo "$be"
      return
    fi
  done
  echo ""
}

# Purge any running mock backend. Safe to call when none is running.
purge_all_mocks() {
  for be in stacklok llmock; do
    job=$(mock_job_name "$be")
    nomad job stop -purge "$job" >/dev/null 2>&1 || true
  done
}

case "${1:-}" in
  --mock)
    JOB_NAME=$(mock_job_name "$MOCK_BACKEND")
    JOB_FILE=$(mock_job_file "$MOCK_BACKEND")

    save_real_vars

    echo "==> Stopping any running mock backend (XOR on port 4010)..."
    purge_all_mocks

    echo "==> Starting mock LLM backend: $MOCK_BACKEND ($JOB_NAME)..."
    nomad job run "$JOB_FILE"

    echo "==> Switching shards to mock LLM..."
    nomad var put -force nomad/jobs/ironclaw-shards \
      NEARAI_API_KEY=mock-key \
      NEARAI_BASE_URL=http://localhost:4010 \
      NEARAI_MODEL=mock-model \
      "DATABASE_URL=$(get_var DATABASE_URL)" \
      "SECRETS_MASTER_KEY=$(get_var SECRETS_MASTER_KEY)" \
      "GATEWAY_ADMIN_TOKEN=$(get_var GATEWAY_ADMIN_TOKEN)" \
      "HTTP_WEBHOOK_SECRET=$(get_var HTTP_WEBHOOK_SECRET)" \
      > /dev/null

    redeploy_shards
    echo "==> Mock LLM active: $MOCK_BACKEND on localhost:4010"
    ;;

  --real)
    echo "==> Purging any running mock backend..."
    purge_all_mocks

    echo "==> Restoring real LLM config..."
    restore_real_vars

    redeploy_shards
    echo "==> Real LLM restored."
    ;;

  --status)
    BASE_URL=$(get_var NEARAI_BASE_URL)
    MODEL=$(get_var NEARAI_MODEL)
    if echo "$BASE_URL" | grep -q "localhost:4010"; then
      echo "Mode: MOCK LLM"
    else
      echo "Mode: REAL LLM"
    fi
    echo "  NEARAI_BASE_URL = $BASE_URL"
    echo "  NEARAI_MODEL    = $MODEL"
    BE=$(active_mock_backend)
    echo "  Mock backend    = ${BE:-none}"
    IMAGE=$(nomad job inspect ironclaw-shards 2>/dev/null | python3 -c "
import json, sys
try:
    d = json.load(sys.stdin)
    print(d['Job']['TaskGroups'][0]['Tasks'][0]['Config']['image'])
except Exception:
    print('(not deployed)')
" 2>/dev/null || echo "(not deployed)")
    echo "  Image           = $IMAGE"
    [ -f "$BACKUP_FILE" ] && echo "  (real config backed up at $BACKUP_FILE)"
    ;;

  "")
    echo "==> Deploying IronClaw shards..."
    nomad job run nomad/ironclaw.nomad.hcl
    ;;

  *)
    echo "Usage: $0 [--image TAG] [--mock=stacklok|--mock=llmock|--real|--status]" >&2
    exit 1
    ;;
esac
