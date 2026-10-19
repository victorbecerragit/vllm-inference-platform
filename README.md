# vLLM Inference Platform

A production-grade, local-first LLM inference platform using CPU mode (zero cloud cost), fronted by Kong AI Gateway with declarative routing and rate-limiting, instrumented with Prometheus & OpenTelemetry, and designed for Kubernetes autoscaling with KEDA.

---

## Architecture Overview

```mermaid
flowchart TD
    Client["Client / Benchmark CLI<br/>(apps/benchmark)"] -->|"HTTP / SSE (:8000)"| Kong["Kong AI Gateway (:8000)<br/>• DB-less Declarative<br/>• CORS & Rate Limiting<br/>• Key-Auth Validation"]
    Kong -->|"Reverse Proxy (:8000)"| vLLM["vLLM Engine (:8000)<br/>• CPU Mode (--device cpu)<br/>• Qwen2.5-0.5B-Instruct<br/>• /metrics & /health"]
    
    subgraph Observability
        Prometheus["Prometheus (:9090)"] -->|"Scrape 5s"| vLLM
        Prometheus -->|"Scrape 5s"| Kong
        OTel["OTel Collector (:4317/:4318)"]
    end
    
    subgraph Kubernetes Autoscaling
        KEDA["KEDA Autoscaler"] -->|"Query: sum(vllm:num_requests_waiting) > 2"| Prometheus
        KEDA -->|"Scale Replicas (1 to 4)"| HPA["Kubernetes HPA / vLLM Deployment"]
    end
```

### Key Architectural Highlights
- **Zero-Cloud-Cost CPU Inference**: Runs lightweight quantized/small-parameter models (such as `Qwen/Qwen2.5-0.5B-Instruct` or `meta-llama/Llama-3.2-1B-Instruct`) entirely on CPU with PyTorch optimizations (`--device cpu`, `--enforce-eager`, `--dtype float32`).
- **AI Gateway Ingress**: Kong Gateway 3.6 runs in DB-less mode, providing rate limiting, API key authentication, CORS handling, and Prometheus telemetry.
- **Queue-Aware Autoscaling (KEDA)**: Scales Kubernetes pods dynamically by tracking `vllm:num_requests_waiting` rather than traditional CPU/memory metrics, ensuring rapid scale-up when inference queues build up.
- **Bootstrap-Friendly GKE Capacity**: The managed node pool starts at 1 node and can grow up to 4 nodes, so the stack can bootstrap cheaply and add capacity only when additional vLLM replicas are scheduled.
- **Async Streaming Benchmarking**: Custom Python client testing streaming token delivery via Server-Sent Events (SSE), measuring Time-To-First-Token (TTFT), Inter-Token Latency (ITL), and token throughput.

---

## Directory Structure

```
vllm-inference-platform/
├── .github/
│   └── copilot-instructions.md    # Architecture and agent coding invariants
├── docker-compose.yml              # Local orchestration (vLLM + Kong + Prometheus + OTel)
├── .env.example                    # Environment variable configuration template
├── .gitignore                      # Git ignore rules for caches, models, and environments
├── README.md                       # Platform documentation and quickstart
├── config/
│   ├── kong/
│   │   └── kong.yml                # Declarative Kong services, routes, and plugins
│   ├── prometheus/
│   │   └── prometheus.yml          # Prometheus scrape configs for vLLM and Kong
│   └── otel/
│       └── otel-collector-config.yml # OpenTelemetry Collector pipeline definition
├── k8s/
│   ├── base/
│   │   ├── deployment-vllm.yaml    # vLLM Kubernetes Deployment manifest
│   │   ├── service-vllm.yaml       # ClusterIP Service for vLLM
│   └── overlays/
│       └── autoscaling/
│           ├── kustomization.yaml # KEDA-enabled overlay
│           └── scaledobject.yaml  # KEDA ScaledObject with Prometheus query trigger
│   └── kustomization.yaml          # Root Kustomize manifest
└── apps/
    └── benchmark/
        ├── requirements.txt        # Benchmark client dependencies
        ├── main.py                 # Async streaming benchmark CLI tool
        └── Dockerfile              # Containerized benchmark client
```

---

## 3-Step Quickstart

### Step 1: Start the Platform Locally
Initialize environment variables and launch the Docker Compose stack:

```bash
# 1. Prepare configuration
cp .env.example .env

# 2. Run Docker preflight (check + test + build)
make preflight

# 3. Launch vLLM, Kong Gateway, Prometheus, and OpenTelemetry Collector
make up
```

Check the health status of the services:
```bash
docker compose ps
```

> **Note**: On the first start, vLLM will download model weights for `Qwen/Qwen2.5-0.5B-Instruct` (~1GB). Watch container logs using `docker compose logs -f vllm`. Once ready, Kong will report `healthy`.

### Docker Preflight Commands
The bootstrap now includes a pre-start Docker preflight workflow:

```bash
# Validate docker + compose + syntax
make docker-check

# Validate expected services and healthcheck wiring
make docker-test

# Build local benchmark image and pull runtime images
make docker-build

# Run all stages (check -> test -> build)
make preflight
```

`make up` always runs `make preflight` first. If you need to bypass it temporarily:

```bash
make up-no-preflight
```

### Step 2: Run the Latency & Throughput Benchmark
Run the async streaming benchmark to measure TTFT, ITL, and tokens/second:

```bash
# Optional: create a local virtualenv
python3 -m venv .venv
source .venv/bin/activate
pip install -r apps/benchmark/requirements.txt

# Execute benchmark with 10 requests at concurrency 2
python apps/benchmark/main.py --requests 10 --concurrency 2
```

Alternatively, run the benchmark tool directly with Docker:
```bash
docker build -t vllm-benchmark apps/benchmark
docker run --net=host vllm-benchmark --requests 10 --concurrency 2
```

### Step 3: Inspect Metrics & Gateway Routes

#### 1. Inspect Kong Routes & Health
Verify Kong AI Gateway proxy routes:
```bash
# Check model listing via Kong proxy (Port 8000)
curl -s http://localhost:8000/v1/models | jq .

# Send a sample chat completion request with API key
curl -X POST http://localhost:8000/v1/chat/completions \
  -H "Content-Type: application/json" \
  -H "apikey: secret-api-key" \
  -d '{
    "model": "Qwen/Qwen2.5-0.5B-Instruct",
    "messages": [{"role": "user", "content": "What is Kubernetes?"}],
    "max_tokens": 64
  }' | jq .
```

#### 2. Query Prometheus Metrics
Open [http://localhost:9090](http://localhost:9090) in your browser or run instant queries:

```bash
# Query vLLM waiting requests
curl -s 'http://localhost:9090/api/v1/query?query=vllm:num_requests_waiting' | jq .

# Query Kong request counts
curl -s 'http://localhost:9090/api/v1/query?query=kong_http_requests_total' | jq .
```

### Kubernetes on kind

Spin up the same lab inside a local kind cluster when you want to validate the Kubernetes manifests and Kong exposure path:

```bash
# Create the local cluster and deploy vLLM, Kong, and Prometheus
make kind-up

# Inspect the deployed workloads
kubectl get pods -n vllm-inference-platform

# Hit Kong through the default kind port mapping
curl -s http://localhost:18000/v1/models | jq .
```

The kind bootstrap uses host ports `18000` and `18001` by default so it can coexist with the Docker Compose stack on `8000` and `8001`. If you want to reuse the Compose ports instead, stop the Compose stack first and run:

```bash
make kind-up KIND_KONG_PROXY_PORT=8000 KIND_KONG_ADMIN_PORT=8001
```

`make kind-up` deploys the core lab resources on a vanilla cluster without requiring KEDA CRDs up front. If you want autoscaling in kind too, install KEDA separately and then run:

```bash
make kind-deploy-full
```

The same split now applies to any cluster: `kubectl apply -k k8s/` deploys the platform, while `kubectl apply -k k8s/overlays/autoscaling` adds the KEDA `ScaledObject` after the operator is available.

---

## Benchmark Metrics Explained

The benchmark client captures three critical low-latency inference metrics:

| Metric | Definition | Importance |
| :--- | :--- | :--- |
| **TTFT** (Time-To-First-Token) | Milliseconds elapsed from HTTP request dispatch until the first SSE chunk is received. | Primary indicator of perceived interactivity and prefill prompt processing speed. |
| **ITL** (Inter-Token Latency) | Delay in milliseconds between consecutive token chunks in the SSE stream. | Determines conversational smoothness and reading experience fluidity. |
| **Throughput (Tokens/sec)** | Number of generated completion tokens divided by total generation duration. | Overall serving capacity metric across concurrent requests. |

---

## Kubernetes Production Deployment & KEDA Autoscaling

### Deploying with Kustomize
Deploy the core vLLM inference platform to your Kubernetes cluster:

```bash
# Preview manifests
kustomize build k8s/

# Apply to cluster
kubectl apply -k k8s/
```

This default bundle intentionally excludes the KEDA `ScaledObject`. That resource depends on the KEDA CRDs and operator already being installed in the cluster.

### Installing KEDA and Enabling Autoscaling
This repository now enforces separation with two Terraform roots:

- `terraform/` -> infra only (GKE, VPC, node pool autoscaling)
- `terraform/incluster/` -> in-cluster resources only (KEDA + optional ScaledObject)

Recommended sequence:

1. Provision cluster infra:

```bash
terraform -chdir=terraform init
terraform -chdir=terraform apply --var-file=terraform.tfvars
```

2. Install in-cluster dependencies (KEDA), ScaledObject off by default:

```bash
cp terraform/incluster/terraform.tfvars.example terraform/incluster/terraform.tfvars
terraform -chdir=terraform/incluster init
terraform -chdir=terraform/incluster apply --var-file=terraform.tfvars
```

3. Deploy application manifests:

```bash
kubectl apply -k k8s/
```

4. Optional: if Terraform should own autoscaling policy too, set `install_scaledobject = true` in `terraform/incluster/terraform.tfvars` and run Terraform in `terraform/incluster/` again.

After `terraform apply`, only deploy the application manifests:

```bash
kubectl apply -k k8s/
```

If your cluster was provisioned outside Terraform (or you disable `install_scaledobject`), install KEDA first and then apply the autoscaling overlay:

```bash
# Install KEDA
helm repo add kedacore https://kedacore.github.io/charts
helm repo update
helm install keda kedacore/keda --namespace keda --create-namespace

# Apply the vLLM autoscaling resources
kubectl apply -k k8s/overlays/autoscaling
```

### IaC vs Application Deployment Separation (Decision Table)

Use this table as the source of truth to avoid dual ownership and drift:

| Mode | Terraform Root | Terraform `install_scaledobject` | App deploy command | Autoscaling overlay command | Recommended for |
| :--- | :---: | :---: | :--- | :--- | :--- |
| Terraform-owned autoscaling | `terraform/incluster` | `true` | `kubectl apply -k k8s/` | Do **not** run | Platform teams managing autoscaling policy as IaC |
| App/GitOps-owned autoscaling | `terraform/incluster` | `false` | `kubectl apply -k k8s/` | `kubectl apply -k k8s/overlays/autoscaling` | Teams that keep scaling policy with app manifests |
| External cluster + manual KEDA | `false` or external | `false` | `kubectl apply -k k8s/` | `kubectl apply -k k8s/overlays/autoscaling` after KEDA install | Non-Terraform clusters |

Important: never let Terraform and `kubectl apply -k k8s/overlays/autoscaling` manage the same `ScaledObject` at the same time.

The Makefile includes a guardrail on `make autoscaling-deploy` and `make kind-deploy-full`:
- It blocks overlay apply when `install_scaledobject=true` is detected in `terraform/incluster/terraform.tfvars` (or legacy `terraform/terraform.tfvars`).
- To override intentionally (for migration/testing only), run:

```bash
make autoscaling-deploy ALLOW_SCALEDOBJECT_OVERLAY=1
```

### How KEDA Autoscaling Works
The Terraform-managed ScaledObject (or `k8s/overlays/autoscaling/scaledobject.yaml` in non-Terraform flows) defines autoscaling rules triggered by queue congestion:

```yaml
triggers:
  - type: prometheus
    metadata:
      serverAddress: http://prometheus:9090
      metricName: vllm_num_requests_waiting
      query: sum(vllm:num_requests_waiting)
      threshold: "2"
```

- **Trigger Metric**: `sum(vllm:num_requests_waiting)`
- **Scale-Up Threshold**: When more than 2 inference requests are queued waiting for compute, KEDA triggers horizontal pod scaling.
- **Replica Range**: Scales dynamically between **1** (baseline) and **4** replicas.
- **Fast Scaling**: Instant scale-up (stabilization window: 0s), with gradual scale-down (120s stabilization window) to avoid flapping.

For GKE, the Terraform node pool also autoscales from **1** to **4** nodes. That allows the initial deployment to succeed on a single node, while a second node is added automatically once additional vLLM replicas become unschedulable because of CPU or anti-affinity constraints.

---

## Observability & Key Metrics Reference

| Component | Port | Target Endpoint | Key PromQL Metric |
| :--- | :--- | :--- | :--- |
| **Kong Proxy** | `8000` | `http://localhost:8000` | `kong_http_requests_total` |
| **Kong Admin** | `8001` | `http://localhost:8001/metrics` | `kong_latency_ms_bucket` |
| **vLLM Engine** | `8002` (direct) / `8000` (internal) | `http://vllm:8000/metrics` | `vllm:num_requests_waiting`<br/>`vllm:gpu_cache_usage_perc` |
| **Prometheus** | `9090` | `http://localhost:9090` | `sum(rate(vllm:request_success_total[1m]))` |
| **OTel Collector** | `4317` (gRPC) / `4318` (HTTP) | `http://localhost:4318` | Traces & OTLP export |

---

## Useful Commands

```bash
# View container logs
docker compose logs -f vllm
docker compose logs -f kong

# Inspect Kong declarative configuration state
curl -s http://localhost:8001/config | jq .

# Stop the platform
docker compose down

# Stop and clean up model cache and Prometheus volumes
docker compose down -v
```
