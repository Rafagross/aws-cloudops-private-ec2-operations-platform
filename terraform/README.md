# Terraform

This directory contains the Terraform code for the `aws-cloudops-private-ec2-operations-platform`.

> **Status:** Work in progress — Phase 4 of the project.

---

## Structure

```
terraform/
├── envs/
│   └── dev/                    # Dev environment root module
│       ├── main.tf             # Module composition
│       ├── variables.tf
│       ├── outputs.tf
│       ├── backend.tf          # S3 + DynamoDB remote state
│       └── terraform.tfvars.example
└── modules/
    ├── vpc/                    # VPC, subnets, route tables
    ├── vpc-endpoints/          # Interface endpoints + S3 Gateway
    ├── kms/                    # Customer-managed CMK
    ├── iam-roles/              # All platform IAM roles
    ├── ec2-workload/           # Launch Template + ASG
    ├── image-builder/          # EC2 Image Builder pipeline
    ├── observability/          # CloudWatch Agent, alarms, dashboard, EventBridge, SNS
    └── backup/                 # AWS Backup vault + plan
```

---

## Prerequisites

- Terraform >= 1.6
- AWS provider >= 5.x
- AWS CLI v2 configured with credentials for a role that can assume `cloudops-dev-role-deploy`
- An S3 bucket and DynamoDB table for remote state (see `envs/dev/backend.tf.example` when available)

---

## Usage

```bash
# Initialize
cd terraform/envs/dev
terraform init

# Plan
terraform plan -out=tfplan

# Apply
terraform apply tfplan

# Destroy (when done with the lab — endpoints accrue cost 24/7)
terraform destroy
```

---

## Cost reminder

VPC Interface Endpoints are the largest cost driver (~$36.50/month base). Always destroy the environment when not in use. AWS Budgets alerts are provisioned as part of the deploy to catch forgotten environments.

See [`docs/cost-model.md`](../docs/cost-model.md) for the full breakdown.

---

## Naming convention

All resources follow `cloudops-<env>-<resource-type>-<purpose>`. See [`docs/naming-conventions.md`](../docs/naming-conventions.md).

## Tagging

Required tags applied via `default_tags` in the AWS provider. See [`docs/tagging-strategy.md`](../docs/tagging-strategy.md).
