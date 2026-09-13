#!/usr/bin/env bash
set -euo pipefail

GW="${GATEWAY_URL:-http://$(kubectl get gateway envoy-ai-gateway -n routing -o jsonpath='{.status.addresses[0].value}' 2>/dev/null || echo 35.198.228.226):8080}"
TOKEN=$(./scripts/gcip-token.sh alice platform)

echo "=== 1. Testing Gemma 3-Arm Routing via Gateway ==="
for M in gemma-rr gemma-epp gemma-epp-noprefix; do
  CODE=$(curl -sS -o /dev/null -w "%{http_code}" -X POST "$GW/v1/chat/completions" \
    -H "Authorization: Bearer $TOKEN" -H 'Content-Type: application/json' \
    -d "{\"model\":\"$M\",\"max_tokens\":16,\"messages\":[{\"role\":\"user\",\"content\":\"hi from $M\"}]}")
  echo "$M HTTP=$CODE"
done

echo "=== 2. EPP logs for llm-d-router (prefix scorer pool) ==="
kubectl logs -n vllm -l app=llm-d-router --tail=20 --prefix

echo "=== 3. EPP logs for llm-d-router-noprefix (generic pool) ==="
kubectl logs -n vllm -l app=llm-d-router-noprefix --tail=20 --prefix
