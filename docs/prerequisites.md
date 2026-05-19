# Prerequisites

This document lists the AWS-account-level resources and settings that must
exist **before** running `terraform apply` for the first time. None of these
are created by this Terraform codebase (they are account-level concerns that
should survive workspace teardown).

---

## 1. CloudTrail — management events (required for alarms)

Two CloudWatch alarms depend on CloudTrail delivering management events to
a CloudWatch Logs log group:

- **KMS key deletion scheduled** — triggers on `ScheduleKeyDeletion` API call
- **Break-glass role assumed** — triggers on `AssumeRole` for the break-glass role

Without CloudTrail, these alarms will never fire. Validate with:

```bash
# Check that at least one trail exists and is logging
aws cloudtrail describe-trails --include-shadow-trails false \
  --query 'trailList[*].{Name:Name,S3:S3BucketName,CWLogs:CloudWatchLogsLogGroupArn}'

# Confirm it is active
aws cloudtrail get-trail-status --name <trail-name> \
  --query '{IsLogging:IsLogging,LatestDelivery:LatestDeliveryTime}'
```

### Quick single-region trail (if none exists)

```bash
# Create an S3 bucket for CloudTrail logs
aws s3api create-bucket --bucket cloudops-dev-cloudtrail-logs-$(aws sts get-caller-identity --query Account --output text) \
  --region us-east-1

# Attach bucket policy (CloudTrail requires specific permissions)
# See: https://docs.aws.amazon.com/awscloudtrail/latest/userguide/create-s3-bucket-policy-for-cloudtrail.html

# Create trail
aws cloudtrail create-trail \
  --name cloudops-dev-trail \
  --s3-bucket-name cloudops-dev-cloudtrail-logs-<account-id> \
  --is-multi-region-trail \
  --enable-log-file-validation

aws cloudtrail start-logging --name cloudops-dev-trail
```

> **Portfolio note:** A future `modules/cloudtrail-baseline` module is on the
> roadmap (see README Phase 2). For now, the trail is a manual prerequisite
> to avoid incurring CloudTrail costs on every `terraform apply / destroy` cycle.

---

## 2. SNS email subscription confirmation

The observability module creates an SNS topic and subscribes `var.alert_email`.
AWS sends a confirmation email before the subscription becomes active.

After `terraform apply`:

1. Check your inbox for "AWS Notification - Subscription Confirmation"
2. Click the confirmation link
3. Verify: `aws sns list-subscriptions-by-topic --topic-arn <arn>`

---

## 3. Terraform state backend (S3 + DynamoDB)

`terraform/envs/dev/backend.tf` references an S3 bucket and DynamoDB table
that must exist before `terraform init`.

```bash
# Validate they exist
aws s3api head-bucket --bucket <backend-bucket>
aws dynamodb describe-table --table-name <lock-table>
```

If they don't exist, create them first:

```bash
BUCKET=cloudops-tfstate-$(aws sts get-caller-identity --query Account --output text)
TABLE=cloudops-tfstate-lock
REGION=us-east-1

aws s3api create-bucket --bucket $BUCKET --region $REGION
aws s3api put-bucket-versioning --bucket $BUCKET \
  --versioning-configuration Status=Enabled
aws s3api put-bucket-encryption --bucket $BUCKET \
  --server-side-encryption-configuration '{"Rules":[{"ApplyServerSideEncryptionByDefault":{"SSEAlgorithm":"AES256"}}]}'

aws dynamodb create-table \
  --table-name $TABLE \
  --attribute-definitions AttributeName=LockID,AttributeType=S \
  --key-schema AttributeName=LockID,KeyType=HASH \
  --billing-mode PAY_PER_REQUEST \
  --region $REGION
```

---

## 4. heartbeat-api binary upload

The Image Builder pipeline fetches the `heartbeat-api` binary from the
diagnostics S3 bucket. The binary must be uploaded before running the pipeline
(not before `terraform apply` — the bucket is created by Terraform).

```bash
# Build arm64 binary
cd app/heartbeat-api && make build

# Upload (run after terraform apply creates the bucket)
ACCOUNT=$(aws sts get-caller-identity --query Account --output text)
aws s3 cp dist/heartbeat-api \
  s3://cloudops-dev-s3-diagnostics-${ACCOUNT}/artifacts/heartbeat-api/heartbeat-api
```

---

## 5. IAM permissions for the deploying identity

The identity running `terraform apply` needs:

- `IAMFullAccess` (or equivalent) — to create roles, policies, instance profiles
- `AmazonVPCFullAccess` — VPC, subnets, security groups, endpoints
- `AmazonEC2FullAccess` — launch templates, ASG, image builder
- `AmazonS3FullAccess` — diagnostics bucket
- `CloudWatchFullAccess` — alarms, dashboards, log groups
- `AWSKeyManagementServicePowerUser` — KMS key creation
- `AWSBackupFullAccess` — backup plan, vault
- `AmazonSSMFullAccess` — parameter store, session manager
- `AWSImageBuilderFullAccess` — pipeline, recipe, components

For least privilege, scope each to the specific resource ARNs used by this
platform (`cloudops-dev-*`).
