#!/usr/bin/env bash
set -euo pipefail

WS="${WORKSTATION_NAME:-vibe-workstation}"
PROJECT="${GCP_PROJECT:-$(gcloud config get-value project 2>/dev/null || echo '<YOUR_PROJECT_ID>')}"
REGION="${WORKSTATION_REGION:-asia-northeast3}"
CLUSTER="${WORKSTATION_CLUSTER:-workstation-cluster}"
CONFIG="${WORKSTATION_CONFIG:-workstation-config}"

echo "=== 1. Generating fresh GCIP token for alice platform ==="
TOK=$(./scripts/gcip-token.sh alice platform)

echo "=== 2. Fetching current settings.json from workstation ==="
gcloud workstations ssh "$WS" --project="$PROJECT" \
  --region="$REGION" --cluster="$CLUSTER" \
  --config="$CONFIG" --command="cat ~/.claude/settings.json" > /tmp/ws_settings.json

echo "=== 3. Transforming settings.json locally ==="
python3 scripts/prepare_ws_settings.py /tmp/ws_settings.json "$TOK"

echo "=== 4. Backing up and updating settings.json on workstation ==="
B64=$(base64 -w0 /tmp/ws_settings.json.new)

gcloud workstations ssh "$WS" --project="$PROJECT" \
  --region="$REGION" --cluster="$CLUSTER" \
  --config="$CONFIG" --command="bash -s" <<REMOTE_SCRIPT
set -euo pipefail
BACKUP=~/.claude/settings.json.bak.\$(date +%s)
cp ~/.claude/settings.json "\$BACKUP"
echo "Backup created at \$BACKUP"
echo "$B64" | base64 -d > ~/.claude/settings.json
echo "Updated ~/.claude/settings.json"
REMOTE_SCRIPT

echo "=== 5. Running claude -p 'say OK' on workstation ==="
gcloud workstations ssh "$WS" --project="$PROJECT" \
  --region="$REGION" --cluster="$CLUSTER" \
  --config="$CONFIG" --command="claude -p 'say OK'"

echo "=== 6. Checking Envoy access logs for /anthropic/v1/messages ==="
POD=$(kubectl get pod -n envoy-gateway-system \
  -l gateway.envoyproxy.io/owning-gateway-name=envoy-ai-gateway \
  -o jsonpath='{.items[0].metadata.name}')
kubectl logs -n envoy-gateway-system "$POD" -c envoy --tail=40 | grep -E "messages|anthropic" || true
