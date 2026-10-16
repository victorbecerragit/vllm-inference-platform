#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

COMPOSE_FILE="$ROOT_DIR/docker-compose.yml"
ENV_FILE="$ROOT_DIR/.env"

log() {
  printf "[preflight] %s\n" "$1"
}

fail() {
  printf "[preflight] ERROR: %s\n" "$1" >&2
  exit 1
}

require_cmd() {
  local cmd="$1"
  if ! command -v "$cmd" >/dev/null 2>&1; then
    fail "Missing required command: $cmd"
  fi
}

docker_compose() {
  docker compose -f "$COMPOSE_FILE" "$@"
}

run_check() {
  log "Running Docker and Compose checks"
  require_cmd docker

  docker --version >/dev/null
  docker compose version >/dev/null

  if [[ ! -f "$ENV_FILE" ]]; then
    log "No .env file found. Copying from .env.example"
    cp "$ROOT_DIR/.env.example" "$ENV_FILE"
  fi

  docker_compose config -q
  log "Compose configuration is valid"
}

run_test() {
  log "Running lightweight compose tests"

  local services
  services="$(docker_compose config --services)"

  for required in vllm kong prometheus otel-collector; do
    if ! grep -q "^${required}$" <<<"$services"; then
      fail "Required service '${required}' not found in compose definition"
    fi
  done

  local config_dump
  config_dump="$(docker_compose config)"

  for endpoint in "localhost:8000/health" "kong health"; do
    if ! grep -q "$endpoint" <<<"$config_dump"; then
      fail "Expected healthcheck endpoint '${endpoint}' not present in rendered compose config"
    fi
  done

  log "Compose structure and health checks look good"
}

run_build() {
  log "Building local benchmark image"
  docker build -t vllm-benchmark:local "$ROOT_DIR/apps/benchmark"

  log "Pulling runtime images for faster startup"
  docker_compose pull

  log "Build stage completed"
}

usage() {
  cat <<'EOF'
Usage: scripts/docker-preflight.sh [check|test|build|all]

Stages:
  check  Validate Docker/Compose availability and compose syntax
  test   Verify expected services and healthcheck wiring
  build  Build benchmark image and pull runtime images
  all    Run check, test, and build in order (default)
EOF
}

main() {
  local stage="${1:-all}"

  case "$stage" in
    check)
      run_check
      ;;
    test)
      run_check
      run_test
      ;;
    build)
      run_check
      run_build
      ;;
    all)
      run_check
      run_test
      run_build
      ;;
    -h|--help|help)
      usage
      ;;
    *)
      fail "Unknown stage '$stage'. Use --help to see available stages."
      ;;
  esac
}

main "$@"
