# Kubernetes and Autoscaling

This guide contains Kubernetes setup and scaling steps for this project.

## Prerequisites

- kubectl
- kustomize
- helm
- Optional: kind, terraform

## kind Installation

```bash
make kind-up
kubectl get pods -n vllm-inference-platform
curl -s http://localhost:18000/v1/models | jq .
```

If you want kind to use ports 8000/8001, stop Docker Compose first and run:

```bash
make kind-up KIND_KONG_PROXY_PORT=8000 KIND_KONG_ADMIN_PORT=8001
```

## Kubernetes Installation (Kustomize + KEDA)

Apply core resources:

```bash
kubectl apply -k k8s/
```

Install KEDA, then apply autoscaling resources:

```bash
helm repo add kedacore https://kedacore.github.io/charts
helm repo update
helm install keda kedacore/keda --namespace keda --create-namespace
kubectl apply -k k8s/overlays/autoscaling
```

## Terraform split (infra vs in-cluster)

- terraform/: cluster and infrastructure
- terraform/incluster/: in-cluster dependencies like KEDA and optional ScaledObject

Typical flow:

```bash
terraform -chdir=terraform init
terraform -chdir=terraform apply --var-file=terraform.tfvars

cp terraform/incluster/terraform.tfvars.example terraform/incluster/terraform.tfvars
terraform -chdir=terraform/incluster init
terraform -chdir=terraform/incluster apply --var-file=terraform.tfvars

kubectl apply -k k8s/
```

## Useful Kubernetes Commands

```bash
kubectl get pods -n vllm-inference-platform
kubectl get svc -n vllm-inference-platform
kubectl logs -n vllm-inference-platform deployment/vllm --tail=200
kubectl describe scaledobject -n vllm-inference-platform
```
