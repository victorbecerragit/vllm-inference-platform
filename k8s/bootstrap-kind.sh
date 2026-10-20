#! /usr/bin/env bash
set -eou pipefail

USER=victorbecerra  # non-root user to move kubeconfig file into their home dir
USER_HOME="/home/$USER" # path to non-root home folder
CURRENT_DIR="$(dirname $(readlink -f $0))"

CLUSTER_NAME=vllm-inference-platform

APP_MOUNT_FOLDERS=(
  tmp
)

NODE_MOUNT_FOLDERS=(
  "/var/lib/kind/images/control-plane-1"
  "/var/lib/kind/images/worker-1"
  "/var/lib/kind/images/worker-2"
)

create_node_folders() {
  for node_folder in "${NODE_MOUNT_FOLDERS[@]}"; do
    if [ ! -d "$node_folder" ]; then
      echo "Creating node folder $node_folder ..."
      sudo mkdir -p "$node_folder"
      sudo chown root:root "$node_folder"
      sudo chmod 0755 "$node_folder"
    else
      echo "Keeping existing node folder $node_folder (preserving contents)"
    fi
    for app_folder in "${APP_MOUNT_FOLDERS[@]}"; do
      echo "Creating folder ${node_folder}/${app_folder} ..."
      sudo mkdir -p "${node_folder}/${app_folder}"
      sudo chown root:root "${node_folder}/${app_folder}" || true
    done
  done
}

generate_config() {
  # Ensure sensible defaults so kind receives integers not empty strings
  KIND_KONG_PROXY_PORT="${KIND_KONG_PROXY_PORT:-30080}"
  KIND_KONG_ADMIN_PORT="${KIND_KONG_ADMIN_PORT:-30081}"
  KIND_GRADIO_PORT="${KIND_GRADIO_PORT:-30082}"

  echo "Generating kind config with ports: proxy=$KIND_KONG_PROXY_PORT admin=$KIND_KONG_ADMIN_PORT gradio=$KIND_GRADIO_PORT"

  # Write generated config to a fixed path for reproducibility and easy inspection
  GENERATED_CONFIG="$CURRENT_DIR/cluster-config.generated.yaml"
  # Truncate/create the generated file so subsequent writes overwrite it
  : > "$GENERATED_CONFIG"

  if command -v envsubst >/dev/null 2>&1; then
    envsubst '${KIND_KONG_PROXY_PORT} ${KIND_KONG_ADMIN_PORT} ${KIND_GRADIO_PORT}' < "$CURRENT_DIR/cluster-config.yaml" > "$GENERATED_CONFIG"
  else
    sed -e "s/\${KIND_KONG_PROXY_PORT}/${KIND_KONG_PROXY_PORT}/g" \
        -e "s/\${KIND_KONG_ADMIN_PORT}/${KIND_KONG_ADMIN_PORT}/g" \
        -e "s/\${KIND_GRADIO_PORT}/${KIND_GRADIO_PORT}/g" \
        "$CURRENT_DIR/cluster-config.yaml" > "$GENERATED_CONFIG"
  fi

  echo "Wrote generated config: $GENERATED_CONFIG"
}

if [ -z "$(kind get clusters -q)" ]
then
  echo "Creating cluster..."
  create_node_folders
  generate_config
  kind create cluster --name "$CLUSTER_NAME" --config="$GENERATED_CONFIG"
  kind get kubeconfig --name "$CLUSTER_NAME" -q > kubeconfig
  chown "$USER" kubeconfig
  mv kubeconfig "$USER_HOME/.kube/config"
else
  echo "Cluster already there. Skipping creation."
fi
