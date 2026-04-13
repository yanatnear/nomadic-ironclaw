#!/bin/bash
# Deploy IronClaw shards with optional mock LLM.
#
# Usage:
#   ./deploy.sh                          # Deploy shards (current image, current LLM)
#   ./deploy.sh --image TAG              # Deploy shards pinned to image TAG
#   ./deploy.sh --mock                   # Save real LLM config, switch to mock
#   ./deploy.sh --real                   # Restore real LLM config from saved backup
#   ./deploy.sh --status                 # Show LLM mode and currently-deployed image
#
# --image can combine with any subcommand:
#   ./deploy.sh --image us-central1-docker.pkg.dev/.../ironclaw:abc1234 --mock
#
# Image TAG defaults to the value baked into ironclaw.nomad.hcl (`:latest`)
# when --image is not passed. Internally this exports NOMAD_VAR_ironclaw_image,
# which Nomad's HCL2 loader reads to override the job's `var.ironclaw_image`.

set -euo pipefail
cd "$(dirname "$0")"

BACKUP_FILE="/tmp/ironclaw-real-llm-vars.json"

# Parse --image TAG (can appear anywhere; everything else falls through to the
# subcommand case statement below).
ARGS=()
while [ $# -gt 0 ]; do
  case "$1" in
    --image)
      [ -z "${2:-}" ] && { echo "Error: --image requires a TAG argument" >&2; exit 1; }
      export NOMAD_VAR_ironclaw_image="$2"
      shift 2
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
  nomad job run ironclaw.nomad.hcl
}

case "${1:-}" in
  --mock)
    save_real_vars
    echo "==> Starting mock LLM..."
    nomad job run mockllm.nomad.hcl

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
    echo "==> Mock LLM active on localhost:4010"
    ;;

  --real)
    echo "==> Stopping mock LLM..."
    nomad job stop -purge mockllm 2>/dev/null || true

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
    nomad job run ironclaw.nomad.hcl
    ;;

  *)
    echo "Usage: $0 [--image TAG] [--mock|--real|--status]" >&2
    exit 1
    ;;
esac
