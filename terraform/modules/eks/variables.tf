variable "name" {
  description = "EKS cluster name"
  type        = string
}

variable "kubernetes_version" {
  description = "EKS control plane version"
  type        = string
  default     = "1.31"
}

variable "vpc_id" {
  type = string
}

variable "app_subnet_ids" {
  description = "Private subnets where worker nodes and pods run"
  type        = list(string)
}

variable "public_subnet_ids" {
  description = "Public subnets, needed for the public-facing ALB created by the AWS Load Balancer Controller"
  type        = list(string)
}

variable "baseline_instance_types" {
  description = "Instance types for the always-on baseline node group"
  type        = list(string)
  default     = ["m6i.large"]
}

variable "baseline_min_size" {
  type    = number
  default = 3 # one per AZ, floor capacity that is never scaled below
}

variable "baseline_max_size" {
  type    = number
  default = 6
}

variable "tags" {
  type    = map(string)
  default = {}
}
