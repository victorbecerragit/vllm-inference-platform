# Project Context & Roadmap: vllm-inference-platform

## Objective
Build a production-grade, local-first zero-cost LLM inference platform stack on Kubernetes and Docker Compose. Fronted by Kong AI Gateway, autoscaled via KEDA, monitored via OpenTelemetry/Prometheus/Jaeger/Grafana, and validated via async Python benchmarking.

---

## Key Tech Stack & Environment
- **LLM Inference Engine**: vLLM (CPU mode locally with lightweight models like `Qwen/Qwen2.5-0.5B-Instruct`, optional GPU overlay via Kustomize).
- **API Gateway**: Kong Gateway v3.x (DB-less mode with AI Gateway plugins: `ai-proxy`, `ai-cache`, `ai-rate-limiting-advanced`).
- **Autoscaling**: KEDA (Kubernetes Event-driven Autoscaling) driven by Prometheus metric `vllm:num_requests_waiting`.
- **Observability**: OpenTelemetry, OpenInference (`openinference-instrumentation-vllm`), Jaeger, Prometheus, Grafana, NVIDIA DCGM Exporter.
- **CI/CD & IaC**: GitHub Actions, Terraform (ephemeral GKE), Kustomize (`k8s/base/` and `k8s/overlays/gpu/`).
- **Benchmarking**: Async Python 3.11 client using `httpx` and `pydantic` v2.

---

## Active Implementation Backlog & Tasks

### Phase 1: Semantic Caching Optimization
- [ ] **SSE Streaming Preservation**: Verify that cached responses maintain Server-Sent Events (`text/event-stream`) streaming headers and yield frames properly without buffering.
- [ ] **Benchmark Cache Verification Flag**: Update `apps/benchmark/main.py` with a `--test-cache` CLI flag that executes dual passes to explicitly measure and report **Uncached $TTFT$** (e.g., $\sim 450\text{ ms}$) vs. **Cached $TTFT$** (e.g., $\sim 15\text{ ms}$).
- [ ] **TTL & Invalidation Policy**: Document and enforce cache invalidation rules in `config/kong/kong.yml` and Redis for non-deterministic inference requests ($temperature > 0$).

### Phase 2: Model Fallback & SRE Resilience
- [ ] **Active/Passive Upstream Health Probes**: Configure `healthchecks.active` and `healthchecks.passive` settings in `config/kong/kong.yml` for the primary vLLM upstream target.
- [ ] **Circuit Breaker & Fallback Triggers**: Route requests to the secondary fallback service automatically on HTTP 503, connection timeouts, or when queue depth exceeds threshold ($vllm:num\_requests\_waiting > 10$).
- [ ] **External Secondary Provider Setup**: Configure secondary upstream target to route either to a lightweight secondary local service or external provider endpoint.
- [ ] **Automated Chaos Testing**: Create `scripts/test-fallback.sh` to simulate pod failure or request flooding, validating fallback execution without throwing 500 errors to clients.

### Phase 3: OpenTelemetry & Deep Observability Enhancements
- [ ] **OpenInference Token Spans**: Integrate `openinference-instrumentation-vllm` into the inference path to capture token-level trace spans:
  - `llm.token_count.prompt`
  - `llm.token_count.completion`
  - `llm.time_to_first_token` ($TTFT$)
  - `llm.inter_token_latency` ($ITL$)
- [ ] **Prometheus Exemplars**: Wire trace ID headers to correlate Prometheus $TTFT$ histogram buckets directly to Jaeger Trace IDs.
- [ ] **Grafana SRE Golden Signals Dashboard**: Structure Grafana panel layouts into three distinct operational domains:
  1. *Inference Engine Health*: `vllm:num_requests_waiting`, `vllm:gpu_cache_usage_perc` (KV Cache saturation), `vllm:num_requests_running`.
  2. *Latency SLOs*: $TTFT$ ($P_{50}$, $P_{90}$, $P_{99}$), $ITL$ ($P_{50}$, $P_{99}$), and overall throughput ($\text{tokens/sec}$).
  3. *Edge Ingress*: Gateway rate-limit throttles, Cache Hit Ratio %, Circuit Breaker status.

### Phase 4: CI/CD Performance Budget SLO Gates
- [ ] **SLO Gate Assertions**: Update `.github/workflows/benchmark-ci.yml` to evaluate `apps/benchmark/results.json` and fail the build if:
  - $P_{95}\ TTFT > 2000\text{ ms}$
  - $\text{error\_rate} > 0$
- [ ] **GitHub Step Summaries**: Use `$GITHUB_STEP_SUMMARY` to format and display tabular benchmark results directly in PR summaries.
- [ ] **Hugging Face Model Cache**: Add workflow caching step for `~/.cache/huggingface` to avoid re-downloading quantized model weights on CI triggers.

### Phase 5: Production GPU Overlay & DCGM Metric Rules
- [ ] **Kustomize GPU Overlay**: Finalize `k8s/overlays/gpu/` with `deployment-gpu-patch.yaml` requesting `nvidia.com/gpu: 1` and tuning `VLLM_GPU_MEMORY_UTILIZATION`.
- [ ] **KV Cache vs. VRAM Disambiguation**: Update documentation and Grafana legends to distinguish between **DCGM VRAM hardware allocation** (pre-allocated at startup) and **`vllm:gpu_cache_usage_perc`** (actual active KV block utilization).
- [ ] **Prometheus Hardware Alerts**: Create `k8s/overlays/gpu/alerts-gpu.yaml` with alerts for:
  - Critical XID Errors (`DCGM_FI_DEV_XID_ERRORS`)
  - Thermal Throttling (`DCGM_FI_DEV_THERMAL_THROTTLE`)
- [ ] **KEDA Metric Alignment**: Ensure `k8s/base/keda-scaledobject.yaml` scales pods using `vllm:num_requests_waiting` or `vllm:gpu_cache_usage_perc` rather than raw GPU SM utilization.

---

## Coding Standards & Architectural Guidelines
- **Idempotent Manifests**: Maintain clean, modular Kubernetes manifests using Helm/Kustomize.
- **Python Formatting**: Strictly typed Python code using `pydantic` v2 and formatted using standard async practices (`httpx`, `asyncio`).
- **Cost Awareness**: Default all local development setups to CPU mode ($0 cloud cost) and keep ephemeral GKE Terraform deployments minimal.