variable "region" {
  description = "AWS region."
  type        = string
  default     = "us-east-1"
}

variable "environment" {
  description = "Deployment environment."
  type        = string
  default     = "dev"
  validation {
    condition     = contains(["dev", "staging", "prod"], var.environment)
    error_message = "environment must be one of: dev, staging, prod."
  }
}

variable "project" {
  description = "Project identifier prefix."
  type        = string
  default     = "cloudops"
  validation {
    condition     = var.project == "cloudops"
    error_message = "project must be 'cloudops'."
  }
}

variable "owner" {
  description = "GitHub handle or team name — applied as Owner tag on all resources."
  type        = string
  default     = "Rafagross"
}

variable "cost_center" {
  description = "Cost allocation identifier."
  type        = string
  default     = "portfolio"
}

variable "alert_email" {
  description = "Email address for CloudWatch alarms, EventBridge alerts, and AWS Budgets."
  type        = string
  default     = "rafagross15@gmail.com"
}

# ami_id removed — AMI is now resolved automatically from SSM Parameter
# /${var.project}/${var.environment}/golden-ami/al2023-arm64/latest
# Seeded on first apply from the AWS-managed AL2023 parameter.
# Image Builder overwrites the value after each successful pipeline run.

variable "image_builder_logs_bucket" {
  description = "S3 bucket for Image Builder logs. Leave empty to reuse diagnostics bucket."
  type        = string
  default     = ""
}

variable "workload_name" {
  description = "Workload identifier used in resource names, tags, and SSM paths."
  type        = string
  default     = "heartbeat-api"
}
