variable "project" { type = string }
variable "environment" { type = string }

variable "workload_name" {
  description = "Workload identifier."
  type        = string
  default     = "heartbeat-api"
}

variable "vpc_id" {
  description = "VPC ID."
  type        = string
}

variable "private_app_subnet_ids" {
  description = "Map of private workload subnet IDs."
  type        = map(string)
}

variable "s3_prefix_list_id" {
  description = "Managed prefix list ID for S3 — used in egress rule."
  type        = string
}

variable "kms_key_arn" {
  description = "ARN of the platform CMK for EBS and S3 encryption."
  type        = string
}

variable "instance_profile_name" {
  description = "IAM instance profile name to attach to the Launch Template."
  type        = string
}

variable "workload_role_arn" {
  description = "ARN of the workload IAM role — used in diagnostics bucket policy."
  type        = string
}

variable "golden_ami_parameter_name" {
  description = "SSM Parameter name holding the current Golden AMI ID. Resolved at plan time."
  type        = string
  default     = ""
}

# ami_id removed — use golden_ami_parameter_name instead.
# Kept as optional escape hatch for local testing only.
variable "ami_id_override" {
  description = "Direct AMI ID override for local testing. Leave empty in all other cases."
  type        = string
  default     = ""
}

variable "instance_type" {
  description = "EC2 instance type."
  type        = string
  default     = "t4g.micro"
}

variable "root_volume_size_gb" {
  description = "Root EBS volume size in GB."
  type        = number
  default     = 30
}
