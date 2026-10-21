#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

KONG_URL="${KONG_URL:-http://localhost:8000/v1/chat/completions}"
API_KEY="${API_KEY:-secret-api-key}"
REQUEST_BODY='{"model":"Qwen/Qwen2.5-0.5B-Instruct","messages":[{"role":"user","content":"Return one sentence about failover routing."}],"max_tokens":32}'

PRIMARY_SERVICE="${PRIMARY_SERVICE:-vllm}"

echo "[1/5] Starting fallback stack components (vllm, litellm, fallback-mock, kong)..."
docker compose up -d vllm litellm fallback-mock kong >/dev/null

echo "[2/5] Waiting for kong and fallback-mock to report healthy..."
docker compose ps

for svc in kong fallback-mock; do
  echo "  - waiting for $svc"
  for _ in $(seq 1 60); do
    status="$(docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}unknown{{end}}' "$(docker compose ps -q "$svc")" 2>/dev/null || true)"
    if [[ "$status" == "healthy" ]]; then
      break
    fi
    sleep 2
  done
  if [[ "$status" != "healthy" ]]; then
    echo "ERROR: $svc did not become healthy"
    exit 1
  fi
done

echo "[3/5] Forcing primary failure by stopping $PRIMARY_SERVICE..."
docker compose stop "$PRIMARY_SERVICE" >/dev/null

echo "[4/5] Sending request via Kong and capturing response..."
TMP_BODY="$(mktemp)"
HTTP_CODE=""
for _ in $(seq 1 12); do
  HTTP_CODE="$(curl -sS -o "$TMP_BODY" -w '%{http_code}' \
    -H "apikey: $API_KEY" \
    -H "Authorization: Bearer $API_KEY" \
    -H 'Content-Type: application/json' \
    -X POST "$KONG_URL" \
    --data "$REQUEST_BODY")"

  # Allow Kong active/passive health checks to converge after primary failure.
  if [[ ! "$HTTP_CODE" =~ ^5 ]]; then
    break
  fi
  sleep 2
done

echo "HTTP code: $HTTP_CODE"
echo "Response body:"
cat "$TMP_BODY"
echo

echo "[5/5] Validating fallback behavior..."
if [[ "$HTTP_CODE" =~ ^5 ]]; then
  echo "ERROR: expected non-5xx response during fallback, got $HTTP_CODE"
  rm -f "$TMP_BODY"
  exit 1
fi

if ! grep -q "Fallback response from mock endpoint" "$TMP_BODY"; then
  echo "ERROR: response does not appear to come from fallback mock"
  rm -f "$TMP_BODY"
  exit 1
fi

rm -f "$TMP_BODY"
echo "PASS: fallback routing worked and avoided 5xx client errors."
