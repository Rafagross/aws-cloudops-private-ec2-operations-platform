##############################################################################
# Module: image-builder
# Purpose: EC2 Image Builder pipeline for Golden AMI (AL2023, arm64).
#          Monthly schedule + on-demand.
#          See docs/architecture.md Section 9
##############################################################################

data "aws_caller_identity" "current" {}
data "aws_region" "current" {}
data "aws_partition" "current" {}

locals {
  account_id  = data.aws_caller_identity.current.account_id
  region      = data.aws_region.current.name
  name_prefix = "${var.project}-${var.environment}"
}

data "aws_ssm_parameter" "al2023_arm64" {
  name = "/aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-arm64"
}

# IAM role for build instances
resource "aws_iam_role" "image_builder" {
  name = "${local.name_prefix}-role-image-builder"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "ec2.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
  tags = { Name = "${local.name_prefix}-role-image-builder" }
}

resource "aws_iam_role_policy_attachment" "ib_ec2_instance_profile" {
  role       = aws_iam_role.image_builder.name
  policy_arn = "arn:aws:iam::aws:policy/EC2InstanceProfileForImageBuilder"
}

resource "aws_iam_role_policy_attachment" "ib_ssm_core" {
  role       = aws_iam_role.image_builder.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_role_policy" "ib_ssm_param_write" {
  name = "${local.name_prefix}-policy-ib-param-write"
  role = aws_iam_role.image_builder.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = ["ssm:PutParameter", "ssm:GetParameter"]
        Resource = [
          "arn:aws:ssm:${local.region}:${local.account_id}:parameter/${var.project}/${var.environment}/golden-ami/*",
        ]
      },
      {
        # Read the heartbeat-api artifact from the diagnostics bucket
        Effect   = "Allow"
        Action   = ["s3:GetObject"]
        Resource = "arn:aws:s3:::${var.project}-${var.environment}-s3-diagnostics-${local.account_id}/artifacts/heartbeat-api/*"
      },
    ]
  })
}

resource "aws_iam_instance_profile" "image_builder" {
  name = "${local.name_prefix}-iprofile-image-builder"
  role = aws_iam_role.image_builder.name
  tags = { Name = "${local.name_prefix}-iprofile-image-builder" }
}

# Infrastructure configuration
resource "aws_imagebuilder_infrastructure_configuration" "default" {
  name                          = "${local.name_prefix}-ibinfra-default"
  description                   = "Build infrastructure for Golden AMI pipeline"
  instance_types                = ["t4g.medium"]
  instance_profile_name         = aws_iam_instance_profile.image_builder.name
  terminate_instance_on_failure = true

  logging {
    s3_logs {
      s3_bucket_name = var.image_builder_logs_bucket
      s3_key_prefix  = "image-builder-logs/"
    }
  }

  tags = { Name = "${local.name_prefix}-ibinfra-default" }
}

# Custom components
resource "aws_imagebuilder_component" "cis_baseline" {
  name     = "${local.name_prefix}-ibcomp-cis-baseline"
  platform = "Linux"
  version  = "1.0.0"
  data = yamlencode({
    name          = "CIS Baseline Hardening"
    schemaVersion = "1.0"
    phases = [
      {
        name = "build"
        steps = [
          {
            name   = "SysctlHardening"
            action = "ExecuteBash"
            inputs = {
              commands = [
                "echo 'net.ipv4.conf.all.rp_filter = 1' >> /etc/sysctl.d/99-cloudops-hardening.conf",
                "echo 'kernel.randomize_va_space = 2' >> /etc/sysctl.d/99-cloudops-hardening.conf",
                "sysctl -p /etc/sysctl.d/99-cloudops-hardening.conf",
              ]
            }
          },
          {
            name   = "AuditdEnable"
            action = "ExecuteBash"
            inputs = { commands = ["systemctl enable auditd", "systemctl start auditd"] }
          },
          {
            name   = "SSHHardening"
            action = "ExecuteBash"
            inputs = {
              commands = [
                "sed -i 's/^#*PermitRootLogin.*/PermitRootLogin no/' /etc/ssh/sshd_config",
                "sed -i 's/^#*PasswordAuthentication.*/PasswordAuthentication no/' /etc/ssh/sshd_config",
              ]
            }
          },
        ]
      },
      {
        name = "validate"
        steps = [
          {
            name   = "ValidateAuditd"
            action = "ExecuteBash"
            inputs = { commands = ["systemctl is-active auditd || exit 1"] }
          },
          {
            name   = "ValidateSSH"
            action = "ExecuteBash"
            inputs = { commands = ["grep -q 'PermitRootLogin no' /etc/ssh/sshd_config || exit 1"] }
          },
        ]
      },
    ]
  })
  tags = { Name = "${local.name_prefix}-ibcomp-cis-baseline" }
}

resource "aws_imagebuilder_component" "cwagent_install" {
  name     = "${local.name_prefix}-ibcomp-cwagent-install"
  platform = "Linux"
  version  = "1.0.0"
  data = yamlencode({
    name          = "CloudWatch Agent Install"
    schemaVersion = "1.0"
    phases = [
      {
        name = "build"
        steps = [{
          name   = "InstallCWA"
          action = "ExecuteBash"
          inputs = { commands = ["dnf install -y amazon-cloudwatch-agent", "systemctl enable amazon-cloudwatch-agent"] }
        }]
      },
      {
        name = "validate"
        steps = [{
          name   = "ValidateCWA"
          action = "ExecuteBash"
          inputs = { commands = ["amazon-cloudwatch-agent-ctl -a status | grep -q 'stopped\\|running' || exit 1"] }
        }]
      },
    ]
  })
  tags = { Name = "${local.name_prefix}-ibcomp-cwagent-install" }
}

resource "aws_imagebuilder_component" "heartbeat_api_install" {
  name     = "${local.name_prefix}-ibcomp-heartbeat-api-install"
  platform = "Linux"
  version  = "1.0.0"
  data = yamlencode({
    name          = "heartbeat-api Install"
    schemaVersion = "1.0"
    phases = [
      {
        name = "build"
        steps = [
          {
            name   = "CreateDirs"
            action = "ExecuteBash"
            inputs = { commands = ["mkdir -p /usr/local/bin /etc/heartbeat /var/log/heartbeat"] }
          },
          {
            # Fetch the arm64 binary from the diagnostics S3 bucket.
            # Upload before triggering the pipeline:
            #   aws s3 cp app/heartbeat-api/dist/heartbeat-api \
            #     s3://<diagnostics-bucket>/artifacts/heartbeat-api/heartbeat-api
            name   = "FetchBinary"
            action = "ExecuteBash"
            inputs = {
              commands = [
                "aws s3 cp s3://${var.project}-${var.environment}-s3-diagnostics-$(curl -sf -H 'X-aws-ec2-metadata-token: $(curl -sf -X PUT http://169.254.169.254/latest/api/token -H Ttl:21600)' http://169.254.169.254/latest/dynamic/instance-identity/document | python3 -c 'import sys,json;print(json.load(sys.stdin)[\"accountId\"])')/artifacts/heartbeat-api/heartbeat-api /usr/local/bin/heartbeat-api",
                "chmod 0755 /usr/local/bin/heartbeat-api",
                "/usr/local/bin/heartbeat-api --version 2>/dev/null || /usr/local/bin/heartbeat-api &",
                "sleep 2",
                "kill %1 2>/dev/null || true",
              ]
            }
          },
          {
            name   = "InstallService"
            action = "ExecuteBash"
            inputs = {
              commands = [
                "printf '[Unit]\\nDescription=heartbeat-api\\nAfter=network.target\\n[Service]\\nType=simple\\nUser=nobody\\nEnvironment=PORT=8080\\nExecStart=/usr/local/bin/heartbeat-api\\nRestart=on-failure\\nRestartSec=5\\n[Install]\\nWantedBy=multi-user.target\\n' > /etc/systemd/system/heartbeat-api.service",
                "systemctl daemon-reload",
                "systemctl enable heartbeat-api.service",
              ]
            }
          },
        ]
      },
      {
        name = "validate"
        steps = [
          {
            name   = "ValidateBinaryExists"
            action = "ExecuteBash"
            inputs = { commands = ["test -x /usr/local/bin/heartbeat-api || exit 1"] }
          },
          {
            name   = "ValidateServiceEnabled"
            action = "ExecuteBash"
            inputs = { commands = ["systemctl is-enabled heartbeat-api.service || exit 1"] }
          },
          {
            name   = "ValidateIMDSv2"
            action = "ExecuteBash"
            inputs = {
              commands = [
                "HTTP=$(curl -s -o /dev/null -w '%{http_code}' http://169.254.169.254/latest/meta-data/ --max-time 2 || echo 000)",
                "[ \"$HTTP\" = '401' ] || exit 1",
              ]
            }
          },
        ]
      },
    ]
  })
  tags = { Name = "${local.name_prefix}-ibcomp-heartbeat-api-install" }
}

resource "aws_imagebuilder_component" "publish_ami_to_ssm" {
  name     = "${local.name_prefix}-ibcomp-publish-ami-ssm"
  platform = "Linux"
  version  = "1.0.0"
  data = yamlencode({
    name          = "Publish AMI ID to SSM Parameter"
    schemaVersion = "1.0"
    phases = [{
      name = "build"
      steps = [{
        name   = "WriteSSMParameter"
        action = "ExecuteBash"
        inputs = {
          commands = [
            # IMAGE_ID is injected by Image Builder as an environment variable
            # during the distribution phase. We publish it here so Terraform
            # reads it on the next apply via data.aws_ssm_parameter.
            "REGION=$(curl -sf -H \"X-aws-ec2-metadata-token: $(curl -sf -X PUT http://169.254.169.254/latest/api/token -H 'X-aws-ec2-metadata-token-ttl-seconds:21600')\" http://169.254.169.254/latest/meta-data/placement/region)",
            "ACCOUNT=$(curl -sf -H \"X-aws-ec2-metadata-token: $(curl -sf -X PUT http://169.254.169.254/latest/api/token -H 'X-aws-ec2-metadata-token-ttl-seconds:21600')\" http://169.254.169.254/latest/dynamic/instance-identity/document | python3 -c 'import sys,json;print(json.load(sys.stdin)[\"accountId\"])')",
            "AMI_ID=$(aws ec2 describe-images --owners self --filters 'Name=tag:GoldenAMI,Values=true' --query 'sort_by(Images, &CreationDate)[-1].ImageId' --output text --region $REGION)",
            "aws ssm put-parameter --name '/${var.project}/${var.environment}/golden-ami/al2023-arm64/latest' --value $AMI_ID --type String --overwrite --region $REGION",
            "echo \"Published AMI $AMI_ID to SSM\"",
          ]
        }
      }]
    }]
  })
  tags = { Name = "${local.name_prefix}-ibcomp-publish-ami-ssm" }
}

resource "aws_imagebuilder_component" "cleanup" {
  name     = "${local.name_prefix}-ibcomp-cleanup"
  platform = "Linux"
  version  = "1.0.0"
  data = yamlencode({
    name          = "Cleanup"
    schemaVersion = "1.0"
    phases = [{
      name = "build"
      steps = [{
        name   = "CleanCaches"
        action = "ExecuteBash"
        inputs = { commands = ["dnf clean all", "rm -rf /tmp/* /var/tmp/*"] }
      }]
    }]
  })
  tags = { Name = "${local.name_prefix}-ibcomp-cleanup" }
}

# Image recipe
resource "aws_imagebuilder_image_recipe" "golden_al2023_arm64" {
  name         = "${local.name_prefix}-ibrecipe-golden-al2023-arm64"
  parent_image = data.aws_ssm_parameter.al2023_arm64.value
  version      = "1.0.0"

  block_device_mapping {
    device_name = "/dev/xvda"
    ebs {
      delete_on_termination = true
      encrypted             = true
      kms_key_id            = var.kms_key_arn
      volume_size           = 30
      volume_type           = "gp3"
    }
  }

  component {
    component_arn = "arn:${data.aws_partition.current.partition}:imagebuilder:${local.region}:aws:component/update-linux/x.x.x"
  }
  component { component_arn = aws_imagebuilder_component.cis_baseline.arn }
  component { component_arn = aws_imagebuilder_component.cwagent_install.arn }
  component { component_arn = aws_imagebuilder_component.heartbeat_api_install.arn }
  component { component_arn = aws_imagebuilder_component.publish_ami_to_ssm.arn }
  component { component_arn = aws_imagebuilder_component.cleanup.arn }

  tags = { Name = "${local.name_prefix}-ibrecipe-golden-al2023-arm64" }
}

# Distribution configuration
resource "aws_imagebuilder_distribution_configuration" "golden" {
  name = "${local.name_prefix}-ibdist-us-east-1"

  distribution {
    region = local.region
    ami_distribution_configuration {
      name = "${local.name_prefix}-ami-golden-al2023-arm64-{{ imagebuilder:buildDate }}"
      ami_tags = {
        Project     = "${var.project}-platform"
        Environment = var.environment
        ManagedBy   = "image-builder"
        GoldenAMI   = "true"
      }
      launch_permission {
        user_ids = [local.account_id]
      }
    }
    launch_template_configuration {
      launch_template_id = var.launch_template_id
      default            = true
    }
  }

  tags = { Name = "${local.name_prefix}-ibdist-us-east-1" }
}

# Pipeline
resource "aws_imagebuilder_image_pipeline" "golden_al2023_arm64" {
  name                             = "${local.name_prefix}-ibpipe-golden-al2023-arm64"
  status                           = "ENABLED"
  image_recipe_arn                 = aws_imagebuilder_image_recipe.golden_al2023_arm64.arn
  infrastructure_configuration_arn = aws_imagebuilder_infrastructure_configuration.default.arn
  distribution_configuration_arn   = aws_imagebuilder_distribution_configuration.golden.arn

  schedule {
    schedule_expression                = "cron(0 6 ? * SUN#1 *)"
    pipeline_execution_start_condition = "EXPRESSION_MATCH_ONLY"
  }

  image_tests_configuration {
    image_tests_enabled = true
    timeout_minutes     = 60
  }

  tags = { Name = "${local.name_prefix}-ibpipe-golden-al2023-arm64" }
}
