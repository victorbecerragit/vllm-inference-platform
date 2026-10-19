# Installation and Setup

This guide contains local installation and usage steps with Docker Compose.

## Prerequisites

- Docker + Docker Compose
- GNU Make
- curl + jq
- Optional for Kubernetes: kubectl, kustomize, helm, kind, terraform

## Local Installation (Docker Compose)

### 1) Prepare environment

```bash
cp .env.example .env
```

### 2) Run preflight and start services

```bash
# Validate Docker setup and images
make preflight

# Start vLLM, Kong, Prometheus, OTel, and Gradio
make up
```

### 3) Verify health

```bash
docker compose ps
curl -s -H "apikey: secret-api-key" http://localhost:8000/v1/models | jq .
curl -s -o /dev/null -w "gradio_http=%{http_code}\n" http://localhost:7860/
```

On first startup, vLLM downloads model weights. Track progress with:

```bash
docker compose logs -f vllm
```

## Local Benchmark

Run the benchmark from your host:

```bash
python3 -m venv .venv
source .venv/bin/activate
pip install -r apps/benchmark/requirements.txt
python apps/benchmark/main.py --requests 10 --concurrency 2
```

Or run with Docker:

```bash
docker build -t vllm-benchmark apps/benchmark
docker run --net=host vllm-benchmark --requests 10 --concurrency 2
```

## Kubernetes and Autoscaling

Use [docs/kubernetes.md](kubernetes.md) for kind, Kustomize, KEDA, and Terraform steps.

## Useful Commands

```bash
# Follow logs
docker compose logs -f vllm
docker compose logs -f kong
docker compose logs -f gradio-gui

# Shutdown
docker compose down

# Shutdown and remove volumes
docker compose down -v
```