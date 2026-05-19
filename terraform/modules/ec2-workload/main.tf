##############################################################################
# Module: ec2-workload
# Purpose: Security group (no inbound, S3 egress only here),
#          S3 diagnostics bucket, Launch Template, ASG.
#          The egress rule to the vpce SG is added from envs/dev/main.tf
#          via aws_security_group_rule to break the circular dependency
#          between ec2-workload and vpc-endpoints.
##############################################################################

data "aws_caller_identity" "current" {}
data "aws_region" "current" {}

locals {
  account_id  = data.aws_caller_identity.current.account_id
  region      = data.aws_region.current.name
  name_prefix = "${var.project}-${var.environment}"
}

# Resolve Golden AMI from SSM Parameter (seeded by Terraform, updated by Image Builder)
data "aws_ssm_parameter" "golden_ami" {
  count = var.golden_ami_parameter_name != "" ? 1 : 0
  name  = var.golden_ami_parameter_name
}

locals {
  resolved_ami_id = (
    var.ami_id_override != ""
    ? var.ami_id_override
    : data.aws_ssm_parameter.golden_ami[0].value
  )
}

resource "aws_security_group" "workload" {
  name        = "${local.name_prefix}-sg-workload"
  description = "Workload instances: no inbound, egress to S3 and VPC endpoints (rule added externally)."
  vpc_id      = var.vpc_id

  egress {
    description     = "HTTPS to S3 via gateway endpoint"
    from_port       = 443
    to_port         = 443
    protocol        = "tcp"
    prefix_list_ids = [var.s3_prefix_list_id]
  }

  tags = { Name = "${local.name_prefix}-sg-workload" }
}

resource "aws_s3_bucket" "diagnostics" {
  bucket = "${local.name_prefix}-s3-diagnostics-${local.account_id}"
  tags   = { Name = "${local.name_prefix}-s3-diagnostics" }
}

resource "aws_s3_bucket_versioning" "diagnostics" {
  bucket = aws_s3_bucket.diagnostics.id
  versioning_configuration { status = "Enabled" }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "diagnostics" {
  bucket = aws_s3_bucket.diagnostics.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm     = "aws:kms"
      kms_master_key_id = var.kms_key_arn
    }
    bucket_key_enabled = true
  }
}

resource "aws_s3_bucket_public_access_block" "diagnostics" {
  bucket                  = aws_s3_bucket.diagnostics.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_lifecycle_configuration" "diagnostics" {
  bucket = aws_s3_bucket.diagnostics.id
  rule {
    id     = "auto-delete-30-days"
    status = "Enabled"
    expiration { days = 30 }
    noncurrent_version_expiration { noncurrent_days = 7 }
  }
}

resource "aws_s3_bucket_policy" "diagnostics" {
  bucket = aws_s3_bucket.diagnostics.id
  policy = data.aws_iam_policy_document.diagnostics_bucket.json
}

data "aws_iam_policy_document" "diagnostics_bucket" {
  # Deny any request not using TLS
  statement {
    sid    = "DenyNonTLS"
    effect = "Deny"
    principals {
      type        = "AWS"
      identifiers = ["*"]
    }
    actions   = ["s3:*"]
    resources = [aws_s3_bucket.diagnostics.arn, "${aws_s3_bucket.diagnostics.arn}/*"]
    condition {
      test     = "Bool"
      variable = "aws:SecureTransport"
      values   = ["false"]
    }
  }

  # Restrict PutObject to the workload role only
  statement {
    sid    = "RestrictPutObjectToWorkloadRole"
    effect = "Deny"
    principals {
      type        = "AWS"
      identifiers = ["*"]
    }
    actions   = ["s3:PutObject"]
    resources = ["${aws_s3_bucket.diagnostics.arn}/*"]
    condition {
      test     = "StringNotLike"
      variable = "aws:PrincipalArn"
      values   = [var.workload_role_arn]
    }
  }
}

locals {
  user_data = base64encode(templatefile("${path.module}/templates/user_data.sh.tpl", {
    project       = var.project
    environment   = var.environment
    workload_name = var.workload_name
    region        = local.region
  }))
}

resource "aws_launch_template" "workload" {
  name        = "${local.name_prefix}-lt-workload"
  description = "Golden AMI-based launch template for ${var.workload_name}"

  image_id      = local.resolved_ami_id
  instance_type = var.instance_type
  key_name      = null

  iam_instance_profile {
    name = var.instance_profile_name
  }

  vpc_security_group_ids = [aws_security_group.workload.id]

  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required"
    http_put_response_hop_limit = 1
    instance_metadata_tags      = "enabled"
  }

  block_device_mappings {
    device_name = "/dev/xvda"
    ebs {
      volume_type           = "gp3"
      volume_size           = var.root_volume_size_gb
      encrypted             = true
      kms_key_id            = var.kms_key_arn
      delete_on_termination = true
    }
  }

  user_data = local.user_data

  monitoring { enabled = true }

  tag_specifications {
    resource_type = "instance"
    tags = {
      Name     = "${local.name_prefix}-ec2-${var.workload_name}"
      Backup   = "daily"
      Patch    = "auto"
      Workload = var.workload_name
    }
  }

  tag_specifications {
    resource_type = "volume"
    tags = {
      Name     = "${local.name_prefix}-ebs-${var.workload_name}-root"
      Backup   = "daily"
      Workload = var.workload_name
    }
  }

  lifecycle {
    create_before_destroy = true
  }

  tags = { Name = "${local.name_prefix}-lt-workload" }
}

resource "aws_autoscaling_group" "workload" {
  name                      = "${local.name_prefix}-asg-workload"
  min_size                  = 1
  max_size                  = 1
  desired_capacity          = 1
  vpc_zone_identifier       = values(var.private_app_subnet_ids)
  health_check_type         = "EC2"
  health_check_grace_period = 300

  launch_template {
    id      = aws_launch_template.workload.id
    version = "$Latest"
  }

  instance_refresh {
    strategy = "Rolling"
    preferences {
      min_healthy_percentage = 0
      instance_warmup        = 300
    }
  }

  dynamic "tag" {
    for_each = {
      Name        = "${local.name_prefix}-asg-workload"
      Project     = "cloudops-platform"
      Environment = var.environment
      Workload    = var.workload_name
      Backup      = "daily"
      Patch       = "auto"
      ManagedBy   = "terraform"
    }
    content {
      key                 = tag.key
      value               = tag.value
      propagate_at_launch = true
    }
  }

  lifecycle {
    ignore_changes = [desired_capacity]
  }
}
