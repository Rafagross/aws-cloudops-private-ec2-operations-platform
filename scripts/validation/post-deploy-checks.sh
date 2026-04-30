#!/usr/bin/env bash
# post-deploy-checks.sh
# Smoke tests run after terraform apply to verify the platform is healthy.
# Prerequisites: AWS CLI v2, Session Manager plugin, jq
# Usage: ./scripts/validation/post-deploy-checks.sh <instance-id> <aws-region>

set -euo pipefail

INSTANCE_ID="${1:-}"
REGION="${2:-us-east-1}"
PASS=0
FAIL=0

if [[ -z "$INSTANCE_ID" ]]; then
  echo "Usage: $0 <instance-id> [aws-region]"
  exit 1
fi

log() { echo "[$(date '+%Y-%m-%dT%H:%M:%S')] $*"; }
pass() { log "PASS: $*"; ((PASS++)) || true; }
fail() { log "FAIL: $*"; ((FAIL++)) || true; }

# 1. SSM reachability
log "Checking SSM reachability for $INSTANCE_ID..."
STATUS=$(aws ssm describe-instance-information \
  --filters "Key=InstanceIds,Values=$INSTANCE_ID" \
  --region "$REGION" \
  --query 'InstanceInformationList[0].PingStatus' \
  --output text 2>/dev/null || echo "UNKNOWN")

if [[ "$STATUS" == "Online" ]]; then
  pass "SSM Agent is Online"
else
  fail "SSM Agent status: $STATUS (expected: Online)"
fi

# 2. CloudWatch Agent running (via Run Command)
log "Checking CloudWatch Agent status via SSM Run Command..."
COMMAND_ID=$(aws ssm send-command \
  --instance-ids "$INSTANCE_ID" \
  --document-name "AWS-RunShellScript" \
  --parameters 'commands=["systemctl is-active amazon-cloudwatch-agent"]' \
  --region "$REGION" \
  --query 'Command.CommandId' \
  --output text)

sleep 5
CWA_STATUS=$(aws ssm get-command-invocation \
  --command-id "$COMMAND_ID" \
  --instance-id "$INSTANCE_ID" \
  --region "$REGION" \
  --query 'StandardOutputContent' \
  --output text 2>/dev/null | tr -d '\n')

if [[ "$CWA_STATUS" == "active" ]]; then
  pass "CloudWatch Agent is active"
else
  fail "CloudWatch Agent status: '$CWA_STATUS' (expected: active)"
fi

# 3. heartbeat-api /health via port forwarding (non-blocking check)
log "Checking heartbeat-api /health via SSM Run Command..."
COMMAND_ID=$(aws ssm send-command \
  --instance-ids "$INSTANCE_ID" \
  --document-name "AWS-RunShellScript" \
  --parameters 'commands=["curl -sf http://127.0.0.1:8080/health"]' \
  --region "$REGION" \
  --query 'Command.CommandId' \
  --output text)

sleep 5
HEALTH_OUTPUT=$(aws ssm get-command-invocation \
  --command-id "$COMMAND_ID" \
  --instance-id "$INSTANCE_ID" \
  --region "$REGION" \
  --query 'StatusDetails' \
  --output text 2>/dev/null)

if [[ "$HEALTH_OUTPUT" == "Success" ]]; then
  pass "heartbeat-api /health returned 200"
else
  fail "heartbeat-api /health check status: $HEALTH_OUTPUT"
fi

# 4. IMDSv2 enforcement
log "Checking IMDSv2 enforcement..."
COMMAND_ID=$(aws ssm send-command \
  --instance-ids "$INSTANCE_ID" \
  --document-name "AWS-RunShellScript" \
  --parameters 'commands=["curl -s -o /dev/null -w \"%{http_code}\" http://169.254.169.254/latest/meta-data/ --max-time 2 || true"]' \
  --region "$REGION" \
  --query 'Command.CommandId' \
  --output text)

sleep 5
IMDS_CODE=$(aws ssm get-command-invocation \
  --command-id "$COMMAND_ID" \
  --instance-id "$INSTANCE_ID" \
  --region "$REGION" \
  --query 'StandardOutputContent' \
  --output text 2>/dev/null | tr -d '\n')

if [[ "$IMDS_CODE" == "401" ]]; then
  pass "IMDSv2 enforced (HTTP 401 without token)"
else
  fail "IMDSv2 check: got HTTP $IMDS_CODE (expected: 401)"
fi

# Summary
echo ""
log "=== POST-DEPLOY CHECK SUMMARY ==="
log "PASSED: $PASS"
log "FAILED: $FAIL"

if [[ $FAIL -gt 0 ]]; then
  log "STATUS: UNHEALTHY — review failures above"
  exit 1
else
  log "STATUS: HEALTHY"
  exit 0
fi
