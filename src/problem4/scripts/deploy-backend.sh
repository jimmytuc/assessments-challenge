#!/usr/bin/env bash
# Backend deployment via AWS CodeDeploy.
#
# Usage:
#   deploy-backend.sh <app-name> <deployment-group> <region> [--rollback]
#
# Required environment variables:
#   IMAGE_TAG          git SHA of the image to deploy (deploy mode only)
#   S3_DEPLOY_BUCKET   S3 bucket holding the deployment archives
#   ALB_ENDPOINT       (optional) ALB hostname to smoke-test; skipped when empty
#
# State (SSM parameters, the instance hooks read these at deploy time):
#   /backend/image_tag         tag the hooks pull
#   /backend/image_tag_prev    tag that was live before the last deploy attempt
#   /backend/last_good_deployment   CodeDeployment ID of the last known-good deploy
#
# Flow (deploy):
#   1. Record current tag as prev; publish the new tag to /backend/image_tag.
#   2. Upload this repo (appspec + hooks) as a revision archive to S3.
#   3. Create a CodeDeploy deployment and poll it to completion.
#   4. Smoke-test the ALB; on any failure roll back.
#   5. On success, record the deployment as last good.
#
# Rollback restores /backend/image_tag from image_tag_prev and replays the
# last good deployment's revision (whose hooks pull the restored tag).
set -euo pipefail

APP_NAME="${1:?app name}"
DEPLOYMENT_GROUP="${2:?deployment group}"
AWS_REGION="${3:?region}"
ROLLBACK="${4:-}"
S3_BUCKET="${S3_DEPLOY_BUCKET:?S3_DEPLOY_BUCKET env var required}"
ALB_ENDPOINT="${ALB_ENDPOINT:-}"
WAIT_TIMEOUT="${DEPLOY_WAIT_TIMEOUT:-600}"

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

SSM_TAG="/backend/image_tag"
SSM_TAG_PREV="/backend/image_tag_prev"
SSM_LAST_GOOD="/backend/last_good_deployment"

fail() { echo "ERROR: $*" >&2; exit 1; }

ssm_get() {
  aws ssm get-parameter --name "$1" --with-decryption \
    --query 'Parameter.Value' --output text --region "$AWS_REGION" 2>/dev/null || echo "none"
}

ssm_put() {
  aws ssm put-parameter --name "$1" --type String --value "$2" \
    --overwrite --region "$AWS_REGION"
}

poll_deployment() {
  local deployment_id="$1"
  local deadline=$((SECONDS + WAIT_TIMEOUT))
  local status=""
  while (( SECONDS < deadline )); do
    status="$(aws deploy get-deployment --deployment-id "$deployment_id" \
      --region "$AWS_REGION" --query 'deploymentInfo.status' --output text)"
    case "$status" in
      Succeeded) return 0 ;;
      Failed|Stopped)
        aws deploy get-deployment --deployment-id "$deployment_id" \
          --region "$AWS_REGION" --query 'deploymentInfo.errorInformation' \
          --output json >&2
        return 1 ;;
    esac
    sleep 15
  done
  fail "deployment $deployment_id did not finish within ${WAIT_TIMEOUT}s (last status: $status)"
}

smoke_test() {
  [[ -z "$ALB_ENDPOINT" ]] && return 0
  echo "Smoke test: https://$ALB_ENDPOINT/health"
  curl -fsS --retry 10 --retry-delay 10 --retry-all-errors \
    --max-time 5 "https://$ALB_ENDPOINT/health" > /dev/null
}

rollback() {
  local reason="${1:-failure}"
  echo "==> Rolling back ($reason)"
  local prev_tag
  prev_tag="$(ssm_get "$SSM_TAG_PREV")"
  if [[ "$prev_tag" == "none" ]]; then
    fail "no previous image tag recorded — nothing to roll back to"
  fi
  ssm_put "$SSM_TAG" "$prev_tag"

  local last_good
  last_good="$(ssm_get "$SSM_LAST_GOOD")"
  if [[ "$last_good" == "none" ]]; then
    fail "no last-good deployment recorded — image tag restored to $prev_tag, deploy manually"
  fi

  local revision
  revision="$(aws deploy get-deployment --deployment-id "$last_good" \
    --region "$AWS_REGION" --query 'deploymentInfo.revision' --output json)"
  local rollback_id
  rollback_id="$(aws deploy create-deployment \
    --application-name "$APP_NAME" \
    --deployment-group-name "$DEPLOYMENT_GROUP" \
    --region "$AWS_REGION" \
    --ignore-application-stop-failures \
    --revision "$revision" \
    --query 'deploymentId' --output text)"
  echo "Rollback deployment ID: $rollback_id"
  if poll_deployment "$rollback_id" && smoke_test; then
    ssm_put "$SSM_LAST_GOOD" "$rollback_id"
    echo "Rollback complete — $prev_tag is live"
  else
    fail "rollback deployment failed; image tag is restored to $prev_tag, investigate manually"
  fi
}

if [[ "$ROLLBACK" == "--rollback" ]]; then
  rollback "manual"
  exit 0
fi

IMAGE_TAG="${IMAGE_TAG:?IMAGE_TAG env var required}"

echo "==> Recording previous image tag and publishing $IMAGE_TAG"
ssm_put "$SSM_TAG_PREV" "$(ssm_get "$SSM_TAG")"
ssm_put "$SSM_TAG" "$IMAGE_TAG"

REVISION_KEY="backend/$IMAGE_TAG.zip"
echo "==> Uploading deployment archive to s3://$S3_BUCKET/$REVISION_KEY"
(cd "$REPO_ROOT" && aws deploy push \
  --application-name "$APP_NAME" \
  --s3-location "s3://$S3_BUCKET/$REVISION_KEY" \
  --source . \
  --region "$AWS_REGION")

echo "==> Creating deployment"
DEPLOYMENT_ID="$(aws deploy create-deployment \
  --application-name "$APP_NAME" \
  --deployment-group-name "$DEPLOYMENT_GROUP" \
  --region "$AWS_REGION" \
  --s3-location "bucket=$S3_BUCKET,key=$REVISION_KEY,bundleType=zip" \
  --query 'deploymentId' --output text)"
echo "Deployment ID: $DEPLOYMENT_ID"

if poll_deployment "$DEPLOYMENT_ID"; then
  echo "==> Deployment succeeded; smoke testing"
  if smoke_test; then
    ssm_put "$SSM_LAST_GOOD" "$DEPLOYMENT_ID"
    echo "Deployment complete — $IMAGE_TAG is live"
  else
    rollback "smoke test failed"
    exit 1
  fi
else
  rollback "deployment failed"
  exit 1
fi
