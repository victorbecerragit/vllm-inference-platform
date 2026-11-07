#!/usr/bin/env bash
#
# Verify the HAMI vGPU slicing overlay end to end:
#   1. HAMI scheduler + device plugin are running
#   2. Both vLLM slices are scheduled by hami-scheduler and Ready
#   3. The node reports allocated hami.io/gpu-mem / hami.io/gpu-core
#   4. Kong routes x-model-target requests to the correct slice
#
# Usage:
#   ./scripts/verify-hami.sh
#   NAMESPACE=vllm-inference-platform ./scripts/verify-hami.sh
#
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

NAMESPACE="${NAMESPACE:-vllm-inference-platform}"
HAMI_NAMESPACE="${HAMI_NAMESPACE:-hami-system}"
KONG_URL="${KONG_URL:-http://localhost:8000/v1/chat/completions}"
API_KEY="${API_KEY:-secret-api-key}"
KUBECTL_REQUEST_TIMEOUT="${KUBECTL_REQUEST_TIMEOUT:-15s}"

for cmd in kubectl curl; do
  if ! command -v "$cmd" >/dev/null 2>&1; then
    echo "ERROR: required command not found: $cmd" >&2
    exit 1
  fi
done

k() {
  kubectl --request-timeout="$KUBECTL_REQUEST_TIMEOUT" "$@"
}

echo "[1/5] Checking HAMI control plane in '$HAMI_NAMESPACE'..."
k -n "$HAMI_NAMESPACE" get pods -l app.kubernetes.io/component=hami-scheduler
k -n "$HAMI_NAMESPACE" get pods -l app.kubernetes.io/component=hami-device-plugin

echo "[2/5] Checking vLLM vGPU slices in '$NAMESPACE'..."
k -n "$NAMESPACE" get deploy vllm-qwen25 vllm-llama32
k -n "$NAMESPACE" get pods -l 'app in (vllm-qwen25,vllm-llama32)' -o wide

echo "[3/5] Verifying pods were bound by hami-scheduler..."
for app in vllm-qwen25 vllm-llama32; do
  scheduler="$(k -n "$NAMESPACE" get pods -l "app=$app" \
    -o jsonpath='{.items[0].spec.schedulerName}' 2>/dev/null || true)"
  if [[ "$scheduler" != "hami-scheduler" ]]; then
    echo "ERROR: pod for $app has schedulerName='${scheduler:-<none>}', expected 'hami-scheduler'" >&2
    exit 1
  fi
  echo "  - $app -> schedulerName=$scheduler"
done

echo "[4/5] Checking node vGPU allocations..."
NODE_NAME="$(k -n "$NAMESPACE" get pods -l 'app in (vllm-qwen25,vllm-llama32)' \
  -o jsonpath='{.items[0].spec.nodeName}')"
if [[ -z "$NODE_NAME" ]]; then
  echo "ERROR: could not determine GPU node for vLLM slices" >&2
  exit 1
fi
k describe node "$NODE_NAME" | grep -A 12 "Allocated resources:" || true

echo "  - node-advertised vGPU capacity:"
k get node "$NODE_NAME" -o jsonpath='{.status.capacity}' \
  | tr ',' '\n' | grep -E 'hami\.io/(gpu-mem|gpu-core)' || {
    echo "ERROR: node does not advertise hami.io/gpu-mem or hami.io/gpu-core" >&2
    echo "       Check that the HAMI device plugin is running on this node." >&2
    exit 1
  }

echo "[5/5] Testing header-based routing through Kong..."
# x-model-target -> served model name (see --served-model-name in the
# overlay deployments).
for pair in "qwen2.5:Qwen/Qwen2.5-1.5B-Instruct" "llama3.2:meta-llama/Llama-3.2-1B-Instruct"; do
  target="${pair%%:*}"
  model="${pair#*:}"
  echo "  - x-model-target: $target (model: $model)"
  code="$(curl -sS -o /dev/null -w '%{http_code}' \
    -X POST "$KONG_URL" \
    -H "Content-Type: application/json" \
    -H "apikey: $API_KEY" \
    -H "x-model-target: $target" \
    -d '{"model":"'"$model"'","messages":[{"role":"user","content":"Explain HAMI vGPU slicing."}],"max_tokens":16,"stream":false}' \
    || true)"
  echo "    HTTP $code"
  if [[ ! "$code" =~ ^2 ]]; then
    echo "ERROR: expected 2xx from Kong for x-model-target=$target, got $code" >&2
    exit 1
  fi
done

echo
echo "PASS: HAMI vGPU slicing is active and Kong routes per x-model-target header."
