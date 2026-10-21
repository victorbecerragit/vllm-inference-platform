#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

NAMESPACE="${NAMESPACE:-vllm-inference-platform}"
PRIMARY_DEPLOYMENT="${PRIMARY_DEPLOYMENT:-vllm}"
PRIMARY_LABEL_SELECTOR="${PRIMARY_LABEL_SELECTOR:-app=vllm}"
KONG_SERVICE_HOST="${KONG_SERVICE_HOST:-kong}"
KONG_SERVICE_PORT="${KONG_SERVICE_PORT:-8000}"
KONG_CHAT_PATH="${KONG_CHAT_PATH:-/v1/chat/completions}"
API_KEY="${API_KEY:-secret-api-key}"
MODEL_NAME="${MODEL_NAME:-Qwen/Qwen2.5-0.5B-Instruct}"
KUBECTL_REQUEST_TIMEOUT="${KUBECTL_REQUEST_TIMEOUT:-15s}"
ROLLOUT_TIMEOUT="${ROLLOUT_TIMEOUT:-600s}"
SUPPORT_ROLLOUT_TIMEOUT="${SUPPORT_ROLLOUT_TIMEOUT:-300s}"

REQUEST_BODY="{\"model\":\"${MODEL_NAME}\",\"messages\":[{\"role\":\"user\",\"content\":\"Return one sentence proving fallback routing still works.\"}],\"max_tokens\":32}"

for cmd in kubectl awk sed; do
  if ! command -v "$cmd" >/dev/null 2>&1; then
    echo "ERROR: required command not found: $cmd"
    exit 1
  fi
done

k() {
  kubectl --request-timeout="$KUBECTL_REQUEST_TIMEOUT" "$@"
}

if ! k get ns "$NAMESPACE" >/dev/null 2>&1; then
  echo "ERROR: namespace '$NAMESPACE' does not exist"
  exit 1
fi

echo "[1/7] Verifying required deployments exist in namespace '$NAMESPACE'..."
k -n "$NAMESPACE" get deploy "$PRIMARY_DEPLOYMENT" >/dev/null
k -n "$NAMESPACE" get deploy kong >/dev/null
k -n "$NAMESPACE" get deploy fallback-mock >/dev/null

ORIGINAL_REPLICAS="$(k -n "$NAMESPACE" get deploy "$PRIMARY_DEPLOYMENT" -o jsonpath='{.spec.replicas}')"
ORIGINAL_REPLICAS="${ORIGINAL_REPLICAS:-1}"
RESTORE_NEEDED=0

cleanup() {
  if [[ "$RESTORE_NEEDED" -eq 1 ]]; then
    echo "[cleanup] Restoring $PRIMARY_DEPLOYMENT replicas to $ORIGINAL_REPLICAS..."
    k -n "$NAMESPACE" scale deploy "$PRIMARY_DEPLOYMENT" --replicas="$ORIGINAL_REPLICAS" >/dev/null || true
    k -n "$NAMESPACE" rollout status deploy "$PRIMARY_DEPLOYMENT" --timeout="$ROLLOUT_TIMEOUT" >/dev/null || true
  fi
}
trap cleanup EXIT

echo "[2/7] Ensuring Kong and fallback-mock are rolled out..."
k -n "$NAMESPACE" rollout status deploy kong --timeout="$SUPPORT_ROLLOUT_TIMEOUT" >/dev/null
k -n "$NAMESPACE" rollout status deploy fallback-mock --timeout="$SUPPORT_ROLLOUT_TIMEOUT" >/dev/null

echo "[3/7] Scaling primary deployment '$PRIMARY_DEPLOYMENT' to 0 to force failover..."
k -n "$NAMESPACE" scale deploy "$PRIMARY_DEPLOYMENT" --replicas=0 >/dev/null
RESTORE_NEEDED=1

k -n "$NAMESPACE" wait --for=delete pod -l "$PRIMARY_LABEL_SELECTOR" --timeout=180s >/dev/null 2>&1 || true

echo "[4/7] Running in-cluster request through Kong service..."
SMOKE_POD="fallback-smoke-$(date +%s)"
SMOKE_OUTPUT="$(mktemp)"

k -n "$NAMESPACE" run "$SMOKE_POD" \
  --restart=Never \
  --image=curlimages/curl:8.10.1 \
  --labels=app=fallback-smoke \
  --env="API_KEY=$API_KEY" \
  --env="REQUEST_BODY=$REQUEST_BODY" \
  --command -- sh -c '
set -eu
URL="http://'"$KONG_SERVICE_HOST"':'"$KONG_SERVICE_PORT"''"$KONG_CHAT_PATH"'"
http_code=""
body=""
for _ in $(seq 1 12); do
  response="$(curl -sS -w "\\n%{http_code}" -H "apikey: ${API_KEY}" -H "Authorization: Bearer ${API_KEY}" -H "Content-Type: application/json" -X POST "$URL" --data "$REQUEST_BODY")"
  body="$(printf "%s" "$response" | sed "$ d")"
  http_code="$(printf "%s" "$response" | tail -n1)"
  if ! printf "%s" "$http_code" | grep -Eq "^5"; then
    break
  fi
  sleep 2
done
printf "__HTTP_CODE__:%s\n" "$http_code"
printf "__BODY_BEGIN__\n%s\n__BODY_END__\n" "$body"
' >/dev/null

k -n "$NAMESPACE" wait --for=jsonpath='{.status.phase}'=Succeeded "pod/$SMOKE_POD" --timeout=240s >/dev/null
k -n "$NAMESPACE" logs "$SMOKE_POD" > "$SMOKE_OUTPUT"
k -n "$NAMESPACE" delete pod "$SMOKE_POD" --ignore-not-found >/dev/null

echo "[5/7] Restoring primary deployment replicas..."
k -n "$NAMESPACE" scale deploy "$PRIMARY_DEPLOYMENT" --replicas="$ORIGINAL_REPLICAS" >/dev/null
k -n "$NAMESPACE" rollout status deploy "$PRIMARY_DEPLOYMENT" --timeout="$ROLLOUT_TIMEOUT" >/dev/null
RESTORE_NEEDED=0

echo "[6/8] Verifying failback (traffic returns to primary)..."
POST_RESTORE_POD="failback-smoke-$(date +%s)"
POST_RESTORE_OUTPUT="$(mktemp)"

k -n "$NAMESPACE" run "$POST_RESTORE_POD" \
  --restart=Never \
  --image=curlimages/curl:8.10.1 \
  --labels=app=failback-smoke \
  --env="API_KEY=$API_KEY" \
  --env="REQUEST_BODY=$REQUEST_BODY" \
  --command -- sh -c '
set -eu
URL="http://'"$KONG_SERVICE_HOST"':'"$KONG_SERVICE_PORT"''"$KONG_CHAT_PATH"'"
response="$(curl -sS -w "\\n%{http_code}" -H "apikey: ${API_KEY}" -H "Authorization: Bearer ${API_KEY}" -H "Content-Type: application/json" -X POST "$URL" --data "$REQUEST_BODY")"
body="$(printf "%s" "$response" | sed "$ d")"
http_code="$(printf "%s" "$response" | tail -n1)"
printf "__HTTP_CODE__:%s\n" "$http_code"
printf "__BODY_BEGIN__\n%s\n__BODY_END__\n" "$body"
' >/dev/null

k -n "$NAMESPACE" wait --for=jsonpath='{.status.phase}'=Succeeded "pod/$POST_RESTORE_POD" --timeout=240s >/dev/null
k -n "$NAMESPACE" logs "$POST_RESTORE_POD" > "$POST_RESTORE_OUTPUT"
k -n "$NAMESPACE" delete pod "$POST_RESTORE_POD" --ignore-not-found >/dev/null

HTTP_CODE="$(awk -F: '/^__HTTP_CODE__:/ {print $2}' "$SMOKE_OUTPUT" | tail -n1)"
BODY="$(awk '/^__BODY_BEGIN__$/,/^__BODY_END__$/ { if ($0 !~ /^__BODY_(BEGIN|END)__$/) print }' "$SMOKE_OUTPUT")"
POST_RESTORE_HTTP_CODE="$(awk -F: '/^__HTTP_CODE__:/ {print $2}' "$POST_RESTORE_OUTPUT" | tail -n1)"
POST_RESTORE_BODY="$(awk '/^__BODY_BEGIN__$/,/^__BODY_END__$/ { if ($0 !~ /^__BODY_(BEGIN|END)__$/) print }' "$POST_RESTORE_OUTPUT")"

echo "[7/8] Response summary"
echo "HTTP code: ${HTTP_CODE:-unknown}"
echo "Body:"
echo "$BODY"
echo ""
echo "Post-restore HTTP code: ${POST_RESTORE_HTTP_CODE:-unknown}"
echo "Post-restore body:"
echo "$POST_RESTORE_BODY"

rm -f "$SMOKE_OUTPUT"
rm -f "$POST_RESTORE_OUTPUT"

echo "[8/8] Validating fallback and failback responses..."
if [[ -z "$HTTP_CODE" ]]; then
  echo "ERROR: did not capture HTTP code from smoke request"
  exit 1
fi

if [[ "$HTTP_CODE" =~ ^5 ]]; then
  echo "ERROR: expected non-5xx response during fallback, got $HTTP_CODE"
  exit 1
fi

if [[ "$BODY" != *"Fallback response from Kubernetes mock backend."* ]] && [[ "$BODY" != *'"fallback": true'* ]] && [[ "$BODY" != *'"fallback":true'* ]]; then
  echo "ERROR: response does not appear to come from fallback backend"
  exit 1
fi

if [[ -z "$POST_RESTORE_HTTP_CODE" ]]; then
  echo "ERROR: did not capture post-restore HTTP code"
  exit 1
fi

if [[ "$POST_RESTORE_HTTP_CODE" =~ ^5 ]]; then
  echo "ERROR: post-restore request returned 5xx ($POST_RESTORE_HTTP_CODE)"
  exit 1
fi

if [[ "$POST_RESTORE_BODY" == *"Fallback response from Kubernetes mock backend."* ]] || [[ "$POST_RESTORE_BODY" == *'"fallback": true'* ]] || [[ "$POST_RESTORE_BODY" == *'"fallback":true'* ]]; then
  echo "ERROR: post-restore response still appears to come from fallback backend"
  exit 1
fi

echo "PASS: Kong served fallback responses during primary outage and returned to primary after rollout restored."
