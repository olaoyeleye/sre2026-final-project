data "aws_availability_zones" "available" {
  filter {
    name   = "opt-in-status"
    values = ["opt-in-not-required"]
  }
}

locals {
  azs = slice(data.aws_availability_zones.available.names, 0, 3)

  # Labels/taints the Kubernetes manifests rely on (nodeSelector "workload")
  node_group_k8s = {
    system = { labels = { workload = "system" }, taints = null }
    apps   = { labels = { workload = "apps" }, taints = null }
    data = {
      labels = { workload = "data" }
      taints = {
        dedicated = { key = "dedicated", value = "data", effect = "NO_SCHEDULE" }
      }
    }
  }
}

# =====================================================================
# VPC - 3 AZs, private subnets for nodes, public subnets for the NLB
# =====================================================================
module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "~> 6.7"

  name = "${var.cluster_name}-vpc"
  cidr = var.vpc_cidr
  azs  = local.azs

  private_subnets = [for i, _ in local.azs : cidrsubnet(var.vpc_cidr, 4, i)]      # /20 each - room for pod IPs
  public_subnets  = [for i, _ in local.azs : cidrsubnet(var.vpc_cidr, 8, i + 48)] # /24 each

  enable_nat_gateway     = true
  single_nat_gateway     = var.single_nat_gateway
  one_nat_gateway_per_az = !var.single_nat_gateway

  enable_dns_hostnames = true
  enable_dns_support   = true

  # Lets the AWS Load Balancer Controller find the right subnets
  public_subnet_tags = {
    "kubernetes.io/role/elb" = 1
  }
  private_subnet_tags = {
    "kubernetes.io/role/internal-elb" = 1
  }
}

# =====================================================================
# EKS cluster with three managed node groups
# =====================================================================
module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "~> 21.29"

  name               = var.cluster_name
  kubernetes_version = var.kubernetes_version

  vpc_id     = module.vpc.vpc_id
  subnet_ids = module.vpc.private_subnets

  endpoint_public_access       = true
  endpoint_public_access_cidrs = var.endpoint_public_access_cidrs

  # Whoever runs terraform apply becomes cluster admin (access entry)
  enable_cluster_creator_admin_permissions = true

  enabled_log_types = ["api", "audit", "authenticator"]

  addons = {
    vpc-cni = {
      before_compute = true
      configuration_values = jsonencode({
        enableNetworkPolicy = tostring(var.enable_network_policy)
      })
    }
    eks-pod-identity-agent = {
      before_compute = true
    }
    kube-proxy = {}
    coredns    = {}
    aws-ebs-csi-driver = {
      pod_identity_association = [{
        role_arn        = module.ebs_csi_pod_identity.iam_role_arn
        service_account = "ebs-csi-controller-sa"
      }]
    }
    metrics-server = {} # needed by the HorizontalPodAutoscalers
  }

  eks_managed_node_groups = {
    for name, ng in var.node_groups : name => {
      name           = "${var.cluster_name}-${name}"
      ami_type       = "AL2023_x86_64_STANDARD"
      instance_types = ng.instance_types
      capacity_type  = ng.capacity_type

      min_size     = ng.min_size
      max_size     = ng.max_size
      desired_size = ng.desired_size

      subnet_ids = module.vpc.private_subnets # spread across all 3 AZs

      labels = local.node_group_k8s[name].labels
      taints = local.node_group_k8s[name].taints

      block_device_mappings = {
        root = {
          device_name = "/dev/xvda"
          ebs = {
            volume_size           = ng.disk_size_gb
            volume_type           = "gp3"
            encrypted             = true
            delete_on_termination = true
          }
        }
      }

      update_config = {
        max_unavailable = 1
      }

      # IMDSv2 only; hop limit 1 stops pods reading the node's IAM credentials
      metadata_options = {
        http_endpoint               = "enabled"
        http_tokens                 = "required"
        http_put_response_hop_limit = 1
      }

      # Lets you open a shell on a node with SSM Session Manager (no SSH keys)
      iam_role_additional_policies = {
        ssm = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
      }
    }
  }
}
