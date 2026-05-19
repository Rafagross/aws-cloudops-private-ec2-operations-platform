# Deployment Guide

End-to-end walkthrough: from `terraform init` to a running, observable
platform. Every command has been run against a real AWS account.

---

## 0. Prerequisites check

Before you start, verify the prerequisites in [docs/prerequisites.md](prerequisites.md).

```bash
# CloudTrail logging
aws cloudtrail get-trail-status --name <your-trail> --query IsLogging

# State backend
aws s3api head-bucket --bucket <tfstate-bucket>
aws dynamodb describe-table --table-name <lock-table> --query Table.TableStatus
```

---

## 1. Clone and configure

```bash
git clone https://github.com/Rafagross/aws-cloudops-private-ec2-operations-platform.git
cd aws-cloudops-private-ec2-operations-platform

cd terraform/envs/dev
cp terraform.tfvars.example terraform.tfvars
# Edit terraform.tfvars: set alert_email (ami_id is no longer needed)
```

---

## 2. Init, plan, apply

```bash
terraform init
terraform plan -out=tfplan
# Review: ~60-70 resources. Main cost drivers: 5 VPC Interface Endpoints.

terraform apply tfplan
# Typical apply time: 8-12 minutes.
```

**Confirm SNS email subscription** — check your inbox and click the link.

---

## 3. Upload heartbeat-api binary and run Image Builder

```bash
# Build arm64 binary
cd ../../../app/heartbeat-api && make build

# Upload to diagnostics bucket (created by Terraform)
ACCOUNT=$(aws sts get-caller-identity --query Account --output text)
aws s3 cp dist/heartbeat-api \
  s3://cloudops-dev-s3-diagnostics-${ACCOUNT}/artifacts/heartbeat-api/heartbeat-api

# Return to dev env
cd ../../terraform/envs/dev

# Trigger the Image Builder pipeline
PIPELINE_ARN=$(aws imagebuilder list-image-pipelines \
  --query "imagePipelineList[?name=='cloudops-dev-ibpipe-golden-al2023-arm64'].arn" \
  --output text)
aws imagebuilder start-image-pipeline-execution --image-pipeline-arn $PIPELINE_ARN

# Monitor (takes 15-20 min)
aws imagebuilder list-image-pipeline-images --image-pipeline-arn $PIPELINE_ARN \
  --query 'imageSummaryList[0].{Status:state.status,AMI:outputResources.amis[0].image}'
```

After the pipeline completes, the Golden AMI ID is written to SSM:

```bash
aws ssm get-parameter \
  --name /cloudops/dev/golden-ami/al2023-arm64/latest \
  --query Parameter.Value
```

Re-apply to refresh the ASG launch template:

```bash
terraform apply -auto-approve
```

---

## 4. Start an SSM Session (no bastion, no SSH)

```bash
# Get instance ID from ASG
INSTANCE_ID=$(aws autoscaling describe-auto-scaling-groups \
  --auto-scaling-group-names cloudops-dev-asg-workload \
  --query 'AutoScalingGroups[0].Instances[0].InstanceId' \
  --output text)

# Start session
aws ssm start-session --target $INSTANCE_ID
```

---

## 5. Validate the workload

```bash
# Inside the SSM session:
systemctl status heartbeat-api
curl -sf http://127.0.0.1:8080/health
curl -sf http://127.0.0.1:8080/metrics
curl -sf 'http://127.0.0.1:8080/work?ms=500'

# Verify CloudWatch Agent is shipping metrics
amazon-cloudwatch-agent-ctl -a status
```

---

## 6. Run a command via SSM Run Command

```bash
# Run a command without an interactive session
aws ssm send-command \
  --document-name "AWS-RunShellScript" \
  --instance-ids $INSTANCE_ID \
  --parameters 'commands=["curl -sf http://127.0.0.1:8080/health"]' \
  --query 'Command.CommandId' \
  --output text

# Get output
aws ssm get-command-invocation \
  --command-id <command-id> \
  --instance-id $INSTANCE_ID \
  --query '{Status:Status,Output:StandardOutputContent}'
```

---

## 7. Trigger a CloudWatch alarm (CPU)

```bash
# Inside SSM session — drive CPU above the alarm threshold
curl -sf 'http://127.0.0.1:8080/work?ms=30000' &
curl -sf 'http://127.0.0.1:8080/work?ms=30000' &
curl -sf 'http://127.0.0.1:8080/work?ms=30000' &
wait

# Watch alarm state from your terminal
aws cloudwatch describe-alarms \
  --alarm-names "cloudops-dev-alarm-cpu-high" \
  --query 'MetricAlarms[0].{State:StateValue,Updated:StateUpdatedTimestamp}'
```

---

## 8. Test break-glass role assumption

```bash
# Assume the break-glass role (MFA required)
aws sts assume-role \
  --role-arn arn:aws:iam::<account-id>:role/cloudops-dev-role-break-glass \
  --role-session-name break-glass-test \
  --serial-number arn:aws:iam::<account-id>:mfa/<username> \
  --token-code <mfa-code>

# An SNS email should arrive within ~1 minute if CloudTrail is delivering
# events to CloudWatch Logs (see docs/prerequisites.md #1).
```

---

## 9. Restore from backup

See the dedicated runbook: [runbooks/03-restore-from-backup.md](../runbooks/03-restore-from-backup.md)

Quick path:

```bash
# List recovery points
VAULT=$(aws backup list-backup-vaults --query 'BackupVaultList[?contains(BackupVaultName, `cloudops-dev`)].BackupVaultName' --output text)
aws backup list-recovery-points-by-backup-vault \
  --backup-vault-name $VAULT \
  --query 'RecoveryPoints[*].{Status:Status,Created:CreationDate,ARN:RecoveryPointArn}'
```

---

## 10. Destroy (cost kill switch)

```bash
# Step 1: Scale ASG to 0 to detach volumes before destroy
aws autoscaling update-auto-scaling-group \
  --auto-scaling-group-name cloudops-dev-asg-workload \
  --min-size 0 --max-size 0 --desired-capacity 0

# Wait for instance to terminate
aws autoscaling describe-auto-scaling-groups \
  --auto-scaling-group-names cloudops-dev-asg-workload \
  --query 'AutoScalingGroups[0].Instances'

# Step 2: Empty S3 diagnostics bucket (Terraform can't delete non-empty buckets)
ACCOUNT=$(aws sts get-caller-identity --query Account --output text)
aws s3 rm s3://cloudops-dev-s3-diagnostics-${ACCOUNT} --recursive

# Step 3: Destroy
terraform destroy
```

> Estimated monthly cost while running: ~$53–58 (VPC endpoints are the
> dominant driver). See [docs/cost-model.md](cost-model.md) for the full breakdown.
