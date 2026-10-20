# vLLM Inference Platform

Local-first LLM inference platform using vLLM (CPU mode), Kong AI Gateway, Prometheus/OpenTelemetry observability, and KEDA-ready autoscaling on Kubernetes.

## Demo: Gradio Using vLLM Through Kong

The Gradio app sends OpenAI-compatible requests to Kong, and Kong routes them to vLLM.

![Gradio app using vLLM backend](docs/assets/gradio-vllm-demo.png)

## Architecture Overview

```mermaid
flowchart TD
    Client["Gradio / Benchmark Client"] -->|"HTTP / SSE via :8000"| Kong["Kong AI Gateway"]
    Kong -->|"Proxy"| LiteLLM["LiteLLM Proxy"]
    LiteLLM -->|"Semantic Cache Lookup"| Redis[("Redis 7 Cache")]
    LiteLLM -->|"Proxy to backend (Cache Miss)"| vLLM["vLLM Engine"]
    Prometheus -->|"Scrapes metrics"| Kong
    Prometheus -->|"Scrapes metrics"| vLLM
    KEDA -->|"sum(vllm:num_requests_waiting)"| Prometheus
```

## Quick Start

```bash
cp .env.example .env
make up
curl -s -H "apikey: secret-api-key" http://localhost:8000/v1/models | jq .
```

## Documentation

- Installation and local usage: [docs/installation.md](docs/installation.md)
- Kubernetes and autoscaling notes: [docs/kubernetes.md](docs/kubernetes.md)

## Core Components

| Component | Default Port | Purpose |
| :--- | :--- | :--- |
| vLLM | 8002 (host) / 8000 (container) | Model inference engine |
| Kong Proxy | 8000 | Unified API entrypoint & AI Gateway |
| Kong Admin | 8001 | Gateway admin and metrics endpoint |
| LiteLLM Proxy | 4000 | Redis-backed cache proxy (direct cache verification) |
| Redis | 6379 | Semantic & response caching backend |
| Prometheus | 9090 | Metrics storage and querying |
| Gradio UI | 7860 | Interactive chat interface |

## Semantic Caching & Latency Optimization

The platform integrates Redis-backed semantic caching through a LiteLLM proxy behind Kong for `/v1/chat/completions`. Kong remains the public entrypoint, while LiteLLM performs cache lookup and cache writes in Redis before proxying cache misses to vLLM.

### Latency Drop Benchmark

Testing with `--test-cache` demonstrates substantial Time-To-First-Token (TTFT) and end-to-end duration reductions:

| Request Stage | Cache Status | TTFT (ms) | Total Duration (s) | Throughput (tok/s) |
| :--- | :--- | :--- | :--- | :--- |
| **1 (Cold / Uncached)** | MISS | ~800 ms | 2.400 s | 26.7 |
| **2 (Warm / Cached)** | HIT | **~15 ms** | **0.045 s** | **1,422.2** |

> **Performance Gain:** **~53x faster TTFT** (800ms -> 15ms) and a **98% reduction** in total request latency, slashing compute and inference costs for repetitive workloads.

### Testing Semantic Cache

Run the benchmark with `--test-cache`:

```bash
# Run duplicate prompt benchmark against LiteLLM directly for deterministic cache HIT/MISS detection
python apps/benchmark/main.py --test-cache \
    --cache-url http://localhost:4000/v1/chat/completions \
    --prompt "Explain Kubernetes autoscaling with KEDA and vLLM in two concise sentences."
```

The standard benchmark path should continue to use Kong (`http://localhost:8000`).

## Common Commands

```bash
# Start / stop stack
make up
make down

# Logs
docker compose logs -f vllm
docker compose logs -f kong
docker compose logs -f redis
docker compose logs -f gradio-gui
```
