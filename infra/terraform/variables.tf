variable "resource_prefix" {
  description = "Dedicated P1 resource name prefix."
  type        = string
  default     = "p01-self-healing"

  validation {
    condition     = var.resource_prefix == "p01-self-healing"
    error_message = "resource_prefix is fixed to p01-self-healing for account isolation."
  }
}

variable "aws_profile" {
  description = "Explicit AWS CLI profile independently verified as the personal P1 account before apply."
  type        = string

  validation {
    condition     = length(trimspace(var.aws_profile)) > 0
    error_message = "aws_profile must be explicit."
  }
}

variable "expected_account_id" {
  description = "Expected personal AWS account ID; supplied securely and never committed."
  type        = string
  sensitive   = true

  validation {
    condition     = can(regex("^[0-9]{12}$", var.expected_account_id))
    error_message = "expected_account_id must be a 12-digit AWS account ID."
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

variable "enable_web_asg" {
  description = "Create the ALB and two-instance ASG used by the AWS host-loss experiment."
  type        = bool
  default     = false
}

variable "web_instance_type" {
  description = "EC2 instance type for the stateless web ASG experiment."
  type        = string
  default     = "t3.micro"
}

variable "web_ingress_cidrs" {
  description = "IPv4 CIDRs allowed to send HTTP probes to the public ALB. Narrow this for an actual experiment."
  type        = list(string)
  default     = []

  validation {
    condition     = !var.enable_web_asg || (length(var.web_ingress_cidrs) > 0 && alltrue([for cidr in var.web_ingress_cidrs : can(cidrnetmask(cidr))]))
    error_message = "When enable_web_asg is true, web_ingress_cidrs must contain at least one valid IPv4 CIDR."
  }
}
