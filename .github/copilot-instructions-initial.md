# Project Context: vllm-inference-platform

## Objective
Build a low-latency, cost-effective LLM serving platform on Kubernetes and Docker Compose, integrated with Kong AI Gateway for token routing, rate limiting, and observability, and KEDA for custom metric autoscaling based on vLLM internal queue dynamics.

## Primary Tech Stack
- **Engine**: vLLM (CPU mode optimized for local development and cloud zero-cost compute) / Triton Inference Server
- **Gateway**: Kong Gateway (v3.x in DB-less declarative mode with AI Gateway plugins / LiteLLM Proxy)
- **Autoscaler**: KEDA (Kubernetes Event-driven Autoscaling) via Prometheus metric triggers
- **Observability**: Prometheus, OpenTelemetry Collector & OpenInference standard
- **Benchmarking & Clients**: Python 3.11+ (FastAPI, httpx, asyncio, pydantic v2)
- **Deployment**: Docker Compose (local orchestration) and Kubernetes manifests (Kustomize/Helm)

## Core Architectural Principles & Invariants
1. **CPU-First Local Inference**:
   - vLLM MUST run in CPU mode locally using `--device cpu` with small parameter models (e.g. `Qwen/Qwen2.5-0.5B-Instruct` or `meta-llama/Llama-3.2-1B-Instruct`) to enable zero-cloud-cost local testing and development.
   - Use `--enforce-eager` and `--dtype float32` (or bfloat16 where AVX-512 is supported) for CPU execution stability.
2. **Gateway-Fronted Traffic**:
   - All client traffic routes through Kong AI Gateway on port `8000`.
   - vLLM backend is abstracted and accessible through declarative routing (`/v1/chat/completions`, `/v1/models`).
   - Implement plugins for CORS, rate-limiting, key-auth, and Prometheus metrics export.
3. **Queue-Aware Autoscaling**:
   - Scale Kubernetes pods based on vLLM internal workload rather than raw CPU/memory.
   - Primary metric: `vllm:num_requests_waiting` (triggers scale-up when waiting queue exceeds target threshold, e.g. `> 2`).
   - Secondary metric: `vllm:gpu_cache_usage_perc` (or CPU KV cache memory saturation).
4. **Streaming Metric Extraction**:
   - Streaming token endpoints (Server-Sent Events) are first-class citizens.
   - Performance benchmarks must measure:
     - **TTFT (Time-To-First-Token)**: Latency from HTTP dispatch to first SSE token chunk.
     - **ITL (Inter-Token Latency)**: Average and p95 delta between consecutive token chunks.
     - **Throughput**: Tokens generated per second per request and aggregate throughput.

## Code Style & Conventions
- **Kubernetes**: Modular manifests organized with Kustomize (`k8s/base/` and `k8s/kustomization.yaml`). Strict resource limits, readiness/liveness probes (`/health`), and shared memory mounts (`/dev/shm`).
- **Python**: Python 3.11+ code strictly typed with `pydantic` v2, formatted with `black`, asynchronous I/O with `asyncio` and `httpx`.
- **Docker Compose**: Deterministic port mappings, health checks on all dependent services (`vllm`, `kong`, `prometheus`, `otel-collector`), and named volumes for model caching.
- **Git & Repo Hygiene**: Keep manifests declarative, self-documenting, and avoid committing model checkpoints or private credentials.
