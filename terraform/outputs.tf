output "cluster_name" {
  value = module.eks.cluster_name
}

output "region" {
  value = var.region
}

output "vpc_id" {
  description = "Put this in argocd/apps/00-aws-load-balancer-controller.yml (vpcId)"
  value       = module.vpc.vpc_id
}

output "configure_kubectl" {
  description = "Run this to point kubectl at the new cluster"
  value       = "aws eks update-kubeconfig --region ${var.region} --name ${module.eks.cluster_name}"
}

output "node_groups" {
  value = { for k, v in module.eks.eks_managed_node_groups : k => v.node_group_id }
}
