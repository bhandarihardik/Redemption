variable "aws_region" {
  type    = string
  default = "us-east-1"
}

variable "azs" {
  type    = list(string)
  default = ["us-east-1a", "us-east-1b", "us-east-1c"]
}

variable "cluster_name" {
  type    = string
  default = "redemption-prod"
}

variable "db_instance_class" {
  description = "RDS instance class. Sized for steady-state; read replica absorbs read-heavy flash-sale traffic."
  type        = string
  default     = "db.r6g.large"
}

variable "db_engine_version" {
  type    = string
  default = "16.4"
}

variable "redis_node_type" {
  type    = string
  default = "cache.r6g.large"
}
