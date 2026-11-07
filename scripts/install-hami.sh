#!/usr/bin/env bash
#
# Install (or upgrade) the HAMI scheduler + vGPU device plugin.
#
# HAMI provides GPU memory and compute-core slicing so multiple vLLM
# deployments can share a single physical GPU. This script is idempotent:
# re-running it performs a `helm upgrade --install`.
#
# Usage:
#   ./scripts/install-hami.sh
#   HAMI_NAMESPACE=hami-system ./scripts/install-hami.sh
#
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

HAMI_NAMESPACE="${HAMI_NAMESPACE:-hami-system}"
HAMI_RELEASE="${HAMI_RELEASE:-hami}"
HAMI_CHART_VERSION="${HAMI_CHART_VERSION:-}"
HAMI_HELM_REPO_URL="${HAMI_HELM_REPO_URL:-https://project-hami.github.io/HAMi/}"
HAMI_VALUES_FILE="${HAMI_VALUES_FILE:-k8s/overlays/hami-gpu/hami-values.yaml}"

require() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "ERROR: required command '$1' not found in PATH" >&2
    exit 1
  fi
}

require helm
require kubectl

if [[ ! -f "$HAMI_VALUES_FILE" ]]; then
  echo "ERROR: HAMI values file not found: $HAMI_VALUES_FILE" >&2
  exit 1
fi

echo "[1/5] Adding HAMI Helm repository..."
helm repo add hami-charts "$HAMI_HELM_REPO_URL" >/dev/null 2>&1 || true
helm repo update hami-charts >/dev/null

echo "[2/5] Checking GPU node labels..."
# The chart's device plugin DaemonSet only targets nodes labelled gpu=on
# (devicePlugin.nvidiaNodeSelector in hami-values.yaml).
labelled_nodes="$(kubectl get nodes -l gpu=on -o name 2>/dev/null || true)"
if [[ -z "$labelled_nodes" ]]; then
  echo "WARNING: no node carries the 'gpu=on' label; the HAMI device plugin will not schedule." >&2
  echo "         Label a GPU node first: kubectl label node <gpu-node> gpu=on" >&2
else
  echo "  - labelled nodes: $(echo "$labelled_nodes" | tr '\n' ' ')"
fi
HAS_GPU_NODE=0
if [[ -n "$labelled_nodes" ]]; then
  HAS_GPU_NODE=1
fi

echo "[3/5] Installing/upgrading HAMI release '$HAMI_RELEASE' in namespace '$HAMI_NAMESPACE'..."
helm_args=(
  upgrade --install "$HAMI_RELEASE" hami-charts/hami
  --namespace "$HAMI_NAMESPACE"
  --create-namespace
  --values "$HAMI_VALUES_FILE"
  --wait
  --timeout 10m
)

if [[ -n "$HAMI_CHART_VERSION" ]]; then
  helm_args+=(--version "$HAMI_CHART_VERSION")
fi

helm "${helm_args[@]}"

echo "[4/5] Waiting for HAMI scheduler and device plugin to become ready..."
# Resource names follow <release>-<chart> unless the release name already
# contains the chart name, so release "hami" yields hami-scheduler /
# hami-device-plugin.
kubectl rollout status "deployment/${HAMI_RELEASE}-scheduler" -n "$HAMI_NAMESPACE" --timeout=300s
if [[ "$HAS_GPU_NODE" -eq 1 ]]; then
  kubectl rollout status "daemonset/${HAMI_RELEASE}-device-plugin" -n "$HAMI_NAMESPACE" --timeout=300s
else
  echo "  - Skipping device-plugin rollout check because no 'gpu=on' node is present in this cluster."
fi

echo "[5/5] HAMI components:"
kubectl get pods -n "$HAMI_NAMESPACE" -o wide

echo
echo "PASS: HAMI scheduler and vGPU device plugin are installed."
echo "Next: kubectl apply -k k8s/overlays/hami-gpu"
