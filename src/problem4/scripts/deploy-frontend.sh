#!/usr/bin/env bash
# Frontend deployment to S3 + CloudFront.
#
# Usage:
#   deploy-frontend.sh <bucket> <dist-dir> <tag> [--rollback]
#
# Required environment variables:
#   CLOUDFRONT_DISTRIBUTION   CloudFront distribution ID
#   KVS_ARN                   CloudFront KeyValueStore ARN (keys: current/previous)
#   CDN_ENDPOINT              (optional) CDN hostname to smoke-test
#   VERSION_MARKER            (optional) string that must appear in index.html
#
# Release layout (per bucket):
#   releases/<tag>/...     immutable release artifacts
#   KVS "current"          tag of the live release (read by the origin-request
#                          CloudFront Function, scripts/cloudfront-function.js)
#   KVS "previous"         tag of the release before the last switch
#
# Rollback rewrites KVS "current" back to "previous" and invalidates the CDN.
set -euo pipefail

BUCKET="${1:?bucket}"
DIST_DIR="${2:?dist dir}"
TAG="${3:?release tag}"
ROLLBACK="${4:-}"
CLOUDFRONT_DISTRIBUTION="${CLOUDFRONT_DISTRIBUTION:?CLOUDFRONT_DISTRIBUTION env var required}"
KVS_ARN="${KVS_ARN:?KVS_ARN env var required}"
CDN_ENDPOINT="${CDN_ENDPOINT:-}"
VERSION_MARKER="${VERSION_MARKER:-}"

fail() { echo "ERROR: $*" >&2; exit 1; }

kvs_get() {
  aws cloudfront-keyvaluestore get-key --kvs-arn "$KVS_ARN" --key "$1" \
    --query 'Value' --output text 2>/dev/null || echo ""
}

kvs_put() {
  local key="$1" value="$2" etag=""
  for _ in 1 2 3; do
    etag="$(aws cloudfront-keyvaluestore describe-key-value-store \
      --kvs-arn "$KVS_ARN" --query 'ETag' --output text)"
    if aws cloudfront-keyvaluestore put-key --kvs-arn "$KVS_ARN" \
        --key "$key" --value "$value" --if-match "$etag" 2>/dev/null; then
      return 0
    fi
    sleep 2
  done
  fail "could not update KVS key '$key' after 3 attempts"
}

kvs_put_new() {
  local key="$1" value="$2"
  if ! aws cloudfront-keyvaluestore put-key --kvs-arn "$KVS_ARN" \
      --key "$key" --value "$value" 2>/dev/null; then
    kvs_put "$key" "$value"
  fi
}

invalidate_and_wait() {
  echo "==> Invalidating CloudFront distribution $CLOUDFRONT_DISTRIBUTION"
  local id
  id="$(aws cloudfront create-invalidation \
    --distribution-id "$CLOUDFRONT_DISTRIBUTION" \
    --paths "/*" --query 'Invalidation.Id' --output text)"
  echo "Invalidation $id — waiting for completion"
  aws cloudfront wait invalidation-completed \
    --distribution-id "$CLOUDFRONT_DISTRIBUTION" --id "$id"
}

smoke_test() {
  [[ -z "$CDN_ENDPOINT" ]] && return 0
  echo "Smoke test: https://$CDN_ENDPOINT/index.html"
  curl -fsS --retry 10 --retry-delay 10 --retry-all-errors \
    --max-time 5 "https://$CDN_ENDPOINT/index.html" > /tmp/frontend-index.html
  if [[ -n "$VERSION_MARKER" ]]; then
    grep -qF "$VERSION_MARKER" /tmp/frontend-index.html || {
      echo "served index.html does not contain marker '$VERSION_MARKER'" >&2
      return 1
    }
  fi
}

rollback() {
  local reason="${1:-failure}"
  echo "==> Rolling back ($reason)"
  local prev
  prev="$(kvs_get previous)"
  [[ -z "$prev" ]] && fail "no previous release recorded — nothing to roll back to"
  echo "Switching KVS current -> $prev"
  kvs_put current "$prev"
  invalidate_and_wait
  smoke_test || fail "rollback applied but smoke test failed"
  echo "Rollback complete — $prev is live"
}

if [[ "$ROLLBACK" == "--rollback" ]]; then
  rollback "manual"
  exit 0
fi

echo "==> Uploading build to s3://$BUCKET/releases/$TAG/"
aws s3 sync --delete "$DIST_DIR" "s3://$BUCKET/releases/$TAG/"

echo "==> Switching release pointer (current -> previous -> $TAG)"
current="$(kvs_get current)"
if [[ -n "$current" ]]; then
  kvs_put previous "$current"
fi
kvs_put_new current "$TAG"

invalidate_and_wait

if smoke_test; then
  echo "Deployment complete — $TAG is live"
else
  rollback "smoke test failed"
  exit 1
fi
