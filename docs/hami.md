# HAMI vGPU Slicing

This guide adds [HAMI](https://github.com/Project-HAMI/HAMI) (Heterogeneous AI
Computing Virtualization Middleware) to the platform so a single physical GPU
can be partitioned into multiple isolated vGPU slices. Each slice gets a hard
VRAM limit and a hard compute-core limit, which lets several vLLM deployments
co-exist on one GPU without one model starving another.

## Why HAMI

The base stack runs vLLM in CPU mode. The `k8s/overlays/gpu` overlay requests a
whole GPU (`nvidia.com/gpu: 1`), so only one vLLM pod can run per GPU. HAMI adds
two extended resources:

| Resource | Unit | Meaning |
| :--- | :--- | :--- |
| `hami.io/gpu-mem` | MiB | Hard VRAM limit for the slice |
| `hami.io/gpu-core` | percent | Hard SM (compute core) limit for the slice |

Pods that request these resources must use `schedulerName: hami-scheduler` so
the HAMI scheduler extension can bind them to a node with enough free slice
capacity.

## 1) Install HAMI

The install is scripted and idempotent (`helm upgrade --install`):

```bash
./scripts/install-hami.sh
```

The script reads `k8s/overlays/hami-gpu/hami-values.yaml`, which pins:

- `devicePlugin.service.type=ClusterIP`
- `scheduler.kubeScheduler.image.tag=v1.30.0`
- `devices.nvidia.resourceMemoryName=hami.io/gpu-mem`
- `devices.nvidia.resourceCoreName=hami.io/gpu-core`

> The chart rejects the legacy top-level `resourceName` / `resourceCoreName`
> keys; resource names must be set under `devices.nvidia.*`.

The device plugin DaemonSet only schedules onto nodes labelled `gpu=on`
(`devicePlugin.nvidiaNodeSelector`). Label your GPU node first:

```bash
kubectl label node <gpu-node-name> gpu=on
```

Override the namespace or release name if needed:

```bash
HAMI_NAMESPACE=hami-system HAMI_RELEASE=hami ./scripts/install-hami.sh
```

Verify the control plane:

```bash
kubectl get pods -n hami-system
kubectl get ds -n hami-system hami-device-plugin
kubectl get deploy -n hami-system hami-scheduler
```

## 2) Apply the HAMI overlay

```bash
kubectl apply -k k8s/overlays/hami-gpu
```

The overlay:

- Deletes the base CPU-mode `vllm` Deployment and Service.
- Adds two GPU-sliced deployments and matching Services:

| Deployment | Model | `hami.io/gpu-mem` | `hami.io/gpu-core` |
| :--- | :--- | :--- | :--- |
| `vllm-qwen25` | `Qwen/Qwen2.5-1.5B-Instruct` | 6144 MiB | 40 |
| `vllm-llama32` | `meta-llama/Llama-3.2-1B-Instruct` | 4096 MiB | 30 |

- Replaces the Kong declarative config with a header-routed, multi-model config.
- Replaces the Prometheus config to scrape both slices plus the HAMI exporter.
- Adds a `prometheus` ServiceAccount and ClusterRole for pod-based discovery.

> **Note:** `meta-llama/Llama-3.2-1B-Instruct` is a gated model. Provide a
> Hugging Face token (for example via a `hf-token` Secret mounted as
> `HF_TOKEN`) before the Llama slice can download weights.

## 3) Kong routing

Clients select a slice with the `x-model-target` header:

```bash
curl -i -X POST http://localhost:8000/v1/chat/completions \
  -H "Content-Type: application/json" \
  -H "apikey: secret-api-key" \
  -H "x-model-target: qwen2.5" \
  -d '{
    "model": "Qwen/Qwen2.5-1.5B-Instruct",
    "messages": [{"role": "user", "content": "Explain HAMI vGPU slicing."}],
    "stream": true
  }'
```

```bash
curl -i -X POST http://localhost:8000/v1/chat/completions \
  -H "Content-Type: application/json" \
  -H "apikey: secret-api-key" \
  -H "x-model-target: llama3.2" \
  -d '{
    "model": "meta-llama/Llama-3.2-1B-Instruct",
    "messages": [{"role": "user", "content": "Explain HAMI vGPU slicing."}],
    "stream": true
  }'
```

Requests without `x-model-target` fall through to the default route, which
targets the Qwen slice.

## 4) Telemetry

The overlay's Prometheus config scrapes:

- `vllm-qwen25:8000/metrics` and `vllm-llama32:8000/metrics` (labelled
  `mode="hami-vgpu"` and `model="qwen2.5"` / `model="llama3.2"`).
- The HAMI device plugin in `hami-system` via pod-based service discovery.

### HAMI virtual GPU metrics

| Metric | Meaning |
| :--- | :--- |
| `hami_vgpu_memory_used_bytes` | VRAM used by the container slice |
| `hami_vgpu_memory_limit_bytes` | Assigned hard limit (`hami.io/gpu-mem`) |
| `hami_container_device_utilization_ratio` | Compute utilization ratio for the slice (`hami.io/gpu-core`) |

> Older HAMI releases exposed `hami_container_gpu_memory_usage_bytes`,
> `hami_container_gpu_memory_limit_bytes`, and `hami_container_gpu_utilization`.
> Those names are gone in current charts; `hami_container_device_memory_bytes`
> is deprecated in v2.11.0 and removed in v2.12.0.

### DCGM physical GPU metrics

The `k8s/overlays/gpu` overlay ships DCGM Exporter. When both overlays are in
use, keep the distinction clear:

| Layer | Metric | Meaning |
| :--- | :--- | :--- |
| Physical | `DCGM_FI_DEV_GPU_UTIL` | Whole-GPU SM utilization |
| Physical | `DCGM_FI_DEV_FB_USED` | Whole-GPU framebuffer allocated |
| Physical | `DCGM_FI_DEV_XID_ERRORS` | Hardware CUDA fault codes |
| Virtual | `hami_container_device_utilization_ratio` | Per-slice compute usage |
| Virtual | `hami_vgpu_memory_used_bytes` | Per-slice VRAM usage |

`DCGM_FI_DEV_FB_USED` reflects the sum of all slices plus driver overhead; it
will not match a single slice's `hami_vgpu_memory_used_bytes`.

## 5) Verification

```bash
./scripts/verify-hami.sh
```

The script checks the HAMI control plane, confirms both vLLM pods were bound by
`hami-scheduler`, prints the node's allocated vGPU resources, and exercises both
Kong routes.

Manual checks:

```bash
kubectl get pods -n vllm-inference-platform -o wide
kubectl describe node <gpu-node-name> | grep -A 12 "Allocated resources:"
kubectl logs -n vllm-inference-platform deploy/vllm-qwen25 --tail=100
```

## Troubleshooting

| Symptom | Likely cause |
| :--- | :--- |
| Pods stay `Pending` with `Insufficient hami.io/gpu-mem` | Slice requests exceed free capacity on the node |
| Pods stay `Pending` with no events | `schedulerName` is not `hami-scheduler` |
| `hami.io/gpu-mem` not advertised on the node | Device plugin not running or node lacks the NVIDIA device plugin prerequisites |
| Kong returns 404 for `x-model-target` | Header value does not match `qwen2.5` or `llama3.2` exactly |
| Prometheus target `hami-vgpu-exporter` is down | RBAC missing, or the vGPU monitor port is not `9394` |

Check node-advertised resources:

```bash
kubectl get node <gpu-node-name> -o jsonpath='{.status.capacity}' | jq .
```
