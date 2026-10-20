# Kubernetes and Autoscaling

This guide covers the local Kubernetes workflow for the project, including the kind cluster, base Kustomize deployment, and the KEDA autoscaling overlay.

## Prerequisites

- kubectl
- kustomize (or kubectl kustomize)
- helm
- kind
- Optional: terraform

## 1) Create a local kind cluster

The repo includes a `kind` target that creates a cluster with the expected externally exposed ports for Kong and the Gradio UI:

```bash
make kind-up
```

This creates a cluster named `vllm-inference-platform` and applies the base manifests from `k8s/` in one step. The default exposed ports are:

- Kong proxy: `localhost:18000`
- Kong admin: `localhost:18001`
- Gradio: `localhost:18080`

Check cluster health:

```bash
kubectl get pods -n vllm-inference-platform
kubectl get svc -n vllm-inference-platform
```

If you want the gateway on standard ports `8000` and `8001`, stop Docker Compose first and rerun the cluster target with the port overrides:

```bash
make kind-up KIND_KONG_PROXY_PORT=8000 KIND_KONG_ADMIN_PORT=8001 KIND_GRADIO_PORT=18080
```

Then validate the gateway once the vLLM pod is ready:

```bash
curl -s -H "apikey: secret-api-key" http://localhost:8000/v1/models | jq .
```

> The Kong service is configured with a `key-auth` plugin and requires the `apikey` header or a matching query parameter.

## 2) Apply the base deployment

The base Kustomize stack is defined in `k8s/base` and includes the namespace, vLLM deployment, Kong gateway, and Prometheus. Apply it directly with:

```bash
kubectl apply -k k8s/
```

This creates the namespace:

```bash
kubectl get ns vllm-inference-platform
```

## 3) Install KEDA and enable autoscaling

Install the KEDA chart:

```bash
helm repo add kedacore https://kedacore.github.io/charts
helm repo update
helm install keda kedacore/keda --namespace keda --create-namespace
```

Then apply the autoscaling overlay:

```bash
kubectl apply -k k8s/overlays/autoscaling
```

The autoscaling object is defined in `k8s/overlays/autoscaling/scaledobject.yaml` and uses Prometheus metrics from the vLLM endpoint:

- Metric: `vllm:num_requests_waiting`
- Query: `sum(vllm:num_requests_waiting)`
- Threshold: `2`

This matches the project goal of scaling based on the vLLM wait queue instead of raw CPU usage.

## 4) Validate the stack

After all pods are ready:

```bash
kubectl get pods -n vllm-inference-platform -w
kubectl get scaledobject -n vllm-inference-platform
kubectl get svc -n vllm-inference-platform
```

Check the inference endpoint through Kong:

```bash
curl -s -H "apikey: secret-api-key" http://localhost:8000/v1/models | jq .
```

Inspect the KEDA trigger and pod logs if scaling is not happening:

```bash
kubectl describe scaledobject -n vllm-inference-platform
kubectl logs -n vllm-inference-platform deployment/vllm --tail=200
kubectl logs -n vllm-inference-platform deployment/kong --tail=200
```

## 5) Terraform split (infra vs in-cluster)

The repo separates:

- `terraform/`: cluster and infrastructure bootstrap
- `terraform/incluster/`: cluster-side dependencies such as KEDA and optional `ScaledObject`

Typical flow:

```bash
terraform -chdir=terraform init
terraform -chdir=terraform apply --var-file=terraform.tfvars

cp terraform/incluster/terraform.tfvars.example terraform/incluster/terraform.tfvars
terraform -chdir=terraform/incluster init
terraform -chdir=terraform/incluster apply --var-file=terraform.tfvars
```

The `Makefile` guards against applying the autoscaling overlay if Terraform appears to own the `ScaledObject`. This prevents duplicate ownership of the same scaling resource.

## Useful Commands

```bash
kubectl get pods -n vllm-inference-platform
kubectl get svc -n vllm-inference-platform
kubectl get deployment -n vllm-inference-platform
kubectl describe scaledobject -n vllm-inference-platform
kubectl logs -n vllm-inference-platform deployment/vllm --tail=200
```

## Notes

- The base vLLM container runs in CPU mode with `Qwen/Qwen2.5-0.5B-Instruct`.
- Kong is in DB-less declarative mode and serves as the front door for OpenAI-compatible API traffic.
- Prometheus scrapes both Kong and vLLM for metrics used by KEDA and observability.
- The project requires a valid API key for protected routes; the default test key configured in the repo is `secret-api-key`.
