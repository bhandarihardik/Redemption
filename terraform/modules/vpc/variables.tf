variable "name" {
  description = "Name prefix for all VPC resources"
  type        = string
}

variable "vpc_cidr" {
  description = "CIDR block for the VPC"
  type        = string
  default     = "10.0.0.0/16"
}

variable "azs" {
  description = "Availability zones to span. Must be >= 3 for production resilience."
  type        = list(string)

  validation {
    condition     = length(var.azs) >= 3
    error_message = "At least 3 AZs are required for zero-downtime AZ-failure tolerance."
  }
}

variable "tags" {
  description = "Common tags applied to all resources"
  type        = map(string)
  default     = {}
}
