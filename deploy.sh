#!/bin/bash
# Deploy IronClaw shards with optional mock LLM.
#
# Usage:
#   ./deploy.sh              # Deploy shards (current config)
#   ./deploy.sh --mock       # Save real LLM config, switch to mock
#   ./deploy.sh --real       # Restore real LLM config from saved backup
#   ./deploy.sh --status     # Show which LLM mode is active

set -euo pipefail
cd "$(dirname "$0")"

BACKUP_FILE="/tmp/ironclaw-real-llm-vars.json"

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
    [ -f "$BACKUP_FILE" ] && echo "  (real config backed up at $BACKUP_FILE)"
    ;;

  "")
    echo "==> Deploying IronClaw shards..."
    nomad job run ironclaw.nomad.hcl
    ;;

  *)
    echo "Usage: $0 [--mock|--real|--status]"
    exit 1
    ;;
esac
