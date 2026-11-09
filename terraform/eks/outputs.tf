output "kubernetes_cluster_name" {
  description = "EKS cluster name"
  value       = module.eks.cluster_name
}

output "kubernetes_cluster_endpoint" {
  description = "EKS API server endpoint"
  value       = module.eks.cluster_endpoint
}

output "aws_region" {
  description = "AWS region where the cluster is deployed"
  value       = var.aws_region
}

output "eks_update_kubeconfig_command" {
  description = "Command to configure kubectl authentication"
  value       = "aws eks update-kubeconfig --name ${module.eks.cluster_name} --region ${var.aws_region}"
}

output "hami_gpu_nodegroup_name" {
  description = "Managed node group name for HAMI GPU workloads"
  value       = module.eks.eks_managed_node_groups["hami_gpu"].node_group_name
}

output "hami_gpu_label_command" {
  description = "Optional command to enforce gpu=on node label"
  value       = format("kubectl label node -l eks.amazonaws.com/nodegroup=%s gpu=on --overwrite", module.eks.eks_managed_node_groups["hami_gpu"].node_group_name)
}
