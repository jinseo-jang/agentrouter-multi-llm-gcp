#!/usr/bin/env bash
set -euo pipefail

GW="${GATEWAY_URL:-http://$(kubectl get gateway envoy-ai-gateway -n routing -o jsonpath='{.status.addresses[0].value}' 2>/dev/null || echo 35.198.228.226):8080}"
PH=partner.agent-router.internal

echo "=== Generating GCIP Token for alice (department: platform) ==="
GT=$(./scripts/gcip-token.sh alice platform)

echo "=== Generating SA Token via impersonation ==="
PROJECT="${GCP_PROJECT:-$(gcloud config get-value project 2>/dev/null || echo '<YOUR_PROJECT_ID>')}"
SA="${SA_EMAIL:-$(gcloud iam service-accounts list --project="${PROJECT}" --filter="name:firebase-adminsdk" --format="value(email)" 2>/dev/null | head -n1)}"
ST=$(gcloud auth print-identity-token \
  --impersonate-service-account="${SA}" \
  --audiences=https://agent-router.internal --include-email)

echo "=== Getting Partner API Key (acme-corp) ==="
AK=$(kubectl get secret partner-api-keys -n routing -o jsonpath='{.data.acme-corp}' | base64 -d)

B_GEMMA='{"model":"gemma-rr","max_tokens":8,"messages":[{"role":"user","content":"hi"}]}'
B_CLAUDE='{"model":"claude-sonnet-5","max_tokens":8,"messages":[{"role":"user","content":"hi"}]}'

echo "--- E1: Anonymous (No Token) ---"
E1_RESP=$(curl -sS -i -X POST "$GW/v1/chat/completions" -H 'Content-Type: application/json' -d "$B_GEMMA")
echo "$E1_RESP"

echo "--- E4: Forged Token ---"
E4_RESP=$(curl -sS -i -X POST "$GW/v1/chat/completions" -H 'Authorization: Bearer not-a-token' -H 'Content-Type: application/json' -d "$B_GEMMA")
echo "$E4_RESP"

echo "--- E2: Employee GCIP Token ---"
E2_RESP=$(curl -sS -i -X POST "$GW/v1/chat/completions" -H "Authorization: Bearer $GT" -H 'Content-Type: application/json' -d "$B_CLAUDE")
echo "$E2_RESP"

echo "--- E3: Internal Workload (Metadata ID Token via in-cluster pod) ---"
E3_OUT=$(kubectl run e3-probe --namespace=vllm --rm -i --restart=Never \
  --image=curlimages/curl:8.10.1 \
  --overrides='{"spec":{"serviceAccountName":"envoy-ai-ksa"}}' -- sh -c '
T=$(curl -s -H "Metadata-Flavor: Google" "http://metadata.google.internal/computeMetadata/v1/instance/service-accounts/default/identity?audience=https://agent-router.internal")
curl -sS -i -X POST \
  http://envoy-routing-envoy-ai-gateway-add85b85.envoy-gateway-system.svc.cluster.local:8080/v1/chat/completions \
  -H "Authorization: Bearer $T" -H "Content-Type: application/json" \
  -d "{\"model\":\"gemma-rr\",\"max_tokens\":8,\"messages\":[{\"role\":\"user\",\"content\":\"hi\"}]}"
')
echo "$E3_OUT"

echo "--- E5: Employee GCIP Token with Spoofed Header (x-tenant-id: admin) ---"
# Ensure echo server is available to inspect received headers
kubectl apply -f manifests/05-routing/echo-route.yaml
kubectl rollout status deploy/echo-server -n routing --timeout=120s

echo "Echo server response with spoof attempt:"
E5_ECHO=$(curl -sS "$GW/authtest" -H "Authorization: Bearer $GT" -H "x-tenant-id: admin")
echo "$E5_ECHO"

echo "Echo server response with SA token:"
E3_ECHO=$(curl -sS "$GW/authtest" -H "Authorization: Bearer $ST" -H "x-tenant-id: admin")
echo "$E3_ECHO"

echo "--- E6: Partner (X-API-Key + Host: partner.agent-router.internal) ---"
E6_RESP=$(curl -sS -i -X POST "$GW/v1/chat/completions" \
  -H "Host: $PH" -H "X-API-Key: $AK" -H 'Content-Type: application/json' \
  -d '{"model":"gemma-rr","max_tokens":16,"messages":[{"role":"user","content":"Say OK"}]}')
echo "$E6_RESP"

echo "--- E7: Partner with Model outside allowlist (claude-sonnet-5) ---"
E7_RESP=$(curl -sS -i -X POST "$GW/v1/chat/completions" \
  -H "Host: $PH" -H "X-API-Key: $AK" -H 'Content-Type: application/json' \
  -d '{"model":"claude-sonnet-5","max_tokens":8,"messages":[{"role":"user","content":"hi"}]}')
echo "$E7_RESP"
