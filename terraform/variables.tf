variable "region" {
  description = "AWS region"
  type        = string
  default     = "eu-west-1"
}

variable "cluster_name" {
  description = "EKS cluster name"
  type        = string
  default     = "banking-eks"
}

variable "kubernetes_version" {
  description = "EKS Kubernetes version"
  type        = string
  default     = "1.34"
}

variable "vpc_cidr" {
  description = "CIDR for the new VPC"
  type        = string
  default     = "10.0.0.0/16"
}

variable "single_nat_gateway" {
  description = "true = one NAT gateway (cheaper, single-AZ egress). false = one per AZ (highly available)"
  type        = bool
  default     = false
}

variable "endpoint_public_access_cidrs" {
  description = "CIDRs allowed to reach the public Kubernetes API endpoint. Restrict to your EC2 box / office IPs, e.g. [\"x.x.x.x/32\"]"
  type        = list(string)
  default     = ["0.0.0.0/0"]
}

variable "enable_network_policy" {
  description = "Enforce Kubernetes NetworkPolicies with the VPC CNI (protects Postgres, Kafka and Redis)"
  type        = bool
  default     = true
}

# ---------------------------------------------------------------------
# The three node groups
#   system - platform add-ons: Istio, cert-manager, LB controller, Argo CD
#   apps   - stateless services: frontend, keycloak, user/transaction/
#            activity/finance-agent
#   data   - stateful: Postgres x2, Kafka x3, Redis (tainted, so only
#            pods that tolerate it land here)
# ---------------------------------------------------------------------
variable "node_groups" {
  description = "Sizing for the three managed node groups"
  type = map(object({
    instance_types = list(string)
    min_size       = number
    max_size       = number
    desired_size   = number
    disk_size_gb   = number
    capacity_type  = string
  }))
  default = {
    system = {
      instance_types = ["m6i.large"]   # 2 vCPU / 8 GiB
      min_size       = 2
      max_size       = 3
      desired_size   = 2
      disk_size_gb   = 50
      capacity_type  = "ON_DEMAND"
    }
    apps = {
      instance_types = ["m6i.xlarge"]  # 4 vCPU / 16 GiB
      min_size       = 2
      max_size       = 6
      desired_size   = 3
      disk_size_gb   = 50
      capacity_type  = "ON_DEMAND"
    }
    data = {
      instance_types = ["r6i.large"]   # 2 vCPU / 16 GiB (memory-optimised for Kafka/Postgres)
      min_size       = 3               # one per AZ, matching Kafka's 3 brokers
      max_size       = 4
      desired_size   = 3
      disk_size_gb   = 50
      capacity_type  = "ON_DEMAND"
    }
  }
}
