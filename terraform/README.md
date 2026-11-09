# Terraform roots

Each subfolder is an independent Terraform root module with its own state,
lock file, and `terraform.tfvars`.

| Folder | Purpose | Cloud |
| --- | --- | --- |
| `gke/` | GKE cluster, VPC, CPU node pool, HAMI GPU node pool | GCP |
| `eks/` | EKS cluster, VPC, CPU node group, GPU (L4/Spot) node group | AWS |
| `incluster/` | Cluster-side add-ons (KEDA, optional `ScaledObject`) | Any |

## Usage

```bash
# GKE
cp terraform/gke/terraform.tfvars.example terraform/gke/terraform.tfvars
terraform -chdir=terraform/gke init
terraform -chdir=terraform/gke apply --var-file=terraform.tfvars

# EKS
cp terraform/eks/terraform.tfvars.example terraform/eks/terraform.tfvars
terraform -chdir=terraform/eks init
terraform -chdir=terraform/eks apply --var-file=terraform.tfvars

# In-cluster add-ons (run after a cluster exists and kubectl is configured)
cp terraform/incluster/terraform.tfvars.example terraform/incluster/terraform.tfvars
terraform -chdir=terraform/incluster init
terraform -chdir=terraform/incluster apply --var-file=terraform.tfvars
```

Provider-specific setup notes live next to each root:

- `gke/setup.txt` — gcloud auth, API enablement, cluster credentials
- `eks/setup.txt` — AWS CLI config, GPU Spot quota increase, kubeconfig

## Notes

- State files and `.terraform/` caches are git-ignored per root.
- `incluster/` is provider-agnostic; it targets whatever cluster your current
  kubeconfig points at.
