variable "project_name" {
  description = "Name prefix used for resources and tags."
  type        = string
  default     = "01-aws-self-healing"

  validation {
    condition     = can(regex("^[a-z0-9-]+$", var.project_name))
    error_message = "project_name must contain only lowercase letters, digits, and hyphens."
  }
}

variable "region" {
  description = "AWS region used for a future lab deployment."
  type        = string
  default     = "ap-northeast-2"
}

variable "vpc_cidr" {
  description = "CIDR for the resilience lab VPC."
  type        = string
  default     = "10.40.0.0/16"

  validation {
    condition     = can(cidrnetmask(var.vpc_cidr))
    error_message = "vpc_cidr must be a valid IPv4 CIDR."
  }
}

variable "nat_mode" {
  description = "Egress mode: none, instance_ha for the recovery lab, or gateway_per_az for the production reference."
  type        = string
  default     = "none"

  validation {
    condition     = contains(["none", "instance_ha", "gateway_per_az"], var.nat_mode)
    error_message = "nat_mode must be none, instance_ha, or gateway_per_az."
  }
}

variable "nat_instance_type" {
  description = "EC2 size used only by the low-cost instance_ha experiment."
  type        = string
  default     = "t3.micro"
}
