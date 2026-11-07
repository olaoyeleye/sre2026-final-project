# =====================================================================
# IAM for in-cluster controllers, via EKS Pod Identity (no node-wide
# permissions, no OIDC/IRSA setup needed)
# =====================================================================

# EBS CSI driver - creates the gp3 volumes for Postgres and Kafka
module "ebs_csi_pod_identity" {
  source  = "terraform-aws-modules/eks-pod-identity/aws"
  version = "~> 2.10"

  name                      = "${var.cluster_name}-ebs-csi"
  attach_aws_ebs_csi_policy = true
}

# AWS Load Balancer Controller - creates the NLB for the Istio gateway.
# The controller itself is installed by Argo CD (argocd/apps/00-...).
module "aws_lb_controller_pod_identity" {
  source  = "terraform-aws-modules/eks-pod-identity/aws"
  version = "~> 2.10"

  name                            = "${var.cluster_name}-aws-lbc"
  attach_aws_lb_controller_policy = true

  associations = {
    this = {
      cluster_name    = module.eks.cluster_name
      namespace       = "kube-system"
      service_account = "aws-load-balancer-controller"
    }
  }
}
