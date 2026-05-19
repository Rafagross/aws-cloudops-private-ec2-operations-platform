##############################################################################
# main.tf — Dev environment module composition
# Module dependency order: kms > vpc > iam-roles > ec2-workload >
#                          vpc-endpoints > sg-rule-wiring >
#                          backup > observability > image-builder
##############################################################################

data "aws_caller_identity" "current" {}

data "aws_ec2_managed_prefix_list" "s3" {
  name = "com.amazonaws.${var.region}.s3"
}

locals {
  diagnostics_bucket_name = "${var.project}-${var.environment}-s3-diagnostics-${data.aws_caller_identity.current.account_id}"
}

# Bootstrap: seed the golden AMI parameter from AWS-managed AL2023 on first
# apply.  After Image Builder runs its first build it will overwrite this
# value; lifecycle ignore_changes prevents Terraform from fighting back.
data "aws_ssm_parameter" "al2023_seed" {
  name = "/aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-arm64"
}

resource "aws_ssm_parameter" "golden_ami" {
  name        = "/${var.project}/${var.environment}/golden-ami/al2023-arm64/latest"
  type        = "String"
  value       = data.aws_ssm_parameter.al2023_seed.value
  description = "Latest Golden AMI ID. Seeded by Terraform; updated by Image Builder pipeline."
  overwrite   = true

  tags = { Name = "${var.project}-${var.environment}-param-golden-ami" }

  lifecycle {
    ignore_changes = [value] # Image Builder owns the value after first build
  }
}

# 1. KMS
module "kms" {
  source      = "../../modules/kms"
  project     = var.project
  environment = var.environment
}

# 2. VPC
module "vpc" {
  source      = "../../modules/vpc"
  project     = var.project
  environment = var.environment
  kms_key_arn = module.kms.key_arn
}

# 3. IAM roles
module "iam_roles" {
  source                  = "../../modules/iam-roles"
  project                 = var.project
  environment             = var.environment
  workload_name           = var.workload_name
  kms_key_arn             = module.kms.key_arn
  diagnostics_bucket_name = local.diagnostics_bucket_name
}

# 4. EC2 workload — creates workload SG (S3 egress only; vpce egress added below)
module "ec2_workload" {
  source        = "../../modules/ec2-workload"
  project       = var.project
  environment   = var.environment
  workload_name = var.workload_name

  vpc_id                 = module.vpc.vpc_id
  private_app_subnet_ids = module.vpc.private_app_subnet_ids
  s3_prefix_list_id      = data.aws_ec2_managed_prefix_list.s3.id
  kms_key_arn            = module.kms.key_arn
  instance_profile_name  = module.iam_roles.workload_instance_profile_name
  workload_role_arn      = module.iam_roles.workload_role_arn

  # AMI resolved from SSM — no manual input required
  golden_ami_parameter_name = aws_ssm_parameter.golden_ami.name

  depends_on = [aws_ssm_parameter.golden_ami]
}

# 5. VPC endpoints — needs workload SG
module "vpc_endpoints" {
  source      = "../../modules/vpc-endpoints"
  project     = var.project
  environment = var.environment

  vpc_id                     = module.vpc.vpc_id
  private_vpce_subnet_ids    = module.vpc.private_vpce_subnet_ids
  private_app_route_table_id = module.vpc.private_app_route_table_id
  workload_sg_id             = module.ec2_workload.workload_sg_id
}

# 5b. Wire vpce egress rule onto the workload SG — breaks circular dependency
# ec2-workload creates its SG without this rule; we add it here once both SGs exist.
resource "aws_security_group_rule" "workload_to_vpce" {
  type                     = "egress"
  description              = "HTTPS to VPC interface endpoints"
  from_port                = 443
  to_port                  = 443
  protocol                 = "tcp"
  security_group_id        = module.ec2_workload.workload_sg_id
  source_security_group_id = module.vpc_endpoints.vpce_sg_id
}

# 6. Backup
module "backup" {
  source          = "../../modules/backup"
  project         = var.project
  environment     = var.environment
  kms_key_arn     = module.kms.key_arn
  backup_role_arn = module.iam_roles.aws_backup_role_arn
}

# 7. Observability
module "observability" {
  source        = "../../modules/observability"
  project       = var.project
  environment   = var.environment
  workload_name = var.workload_name

  kms_key_arn          = module.kms.key_arn
  kms_key_id           = module.kms.key_id
  asg_name             = module.ec2_workload.asg_name
  alert_email          = var.alert_email
  break_glass_role_arn = module.iam_roles.break_glass_role_arn
}

# 8. Image Builder
module "image_builder" {
  source      = "../../modules/image-builder"
  project     = var.project
  environment = var.environment

  kms_key_arn               = module.kms.key_arn
  launch_template_id        = module.ec2_workload.launch_template_id
  image_builder_logs_bucket = var.image_builder_logs_bucket != "" ? var.image_builder_logs_bucket : module.ec2_workload.diagnostics_bucket_name
}
