variable "vpc_id" {
  type = string
}

variable "vpc_cidr" {
  type = string
}

variable "name" {
  type = string
}

variable "tags" {
  type    = map(string)
  default = {}
}
