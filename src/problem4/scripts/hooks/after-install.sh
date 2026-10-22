#!/usr/bin/env bash
# CodeDeploy AfterInstall: switch the container to the already-pulled image.
set -euo pipefail

IMAGE_TAG="$(aws ssm get-parameter --name /backend/image_tag \
  --with-decryption --query 'Parameter.Value' --output text --region "${AWS_REGION:-ap-southeast-1}")"
IMAGE="$(aws ssm get-parameter --name /backend/ecr_registry \
  --with-decryption --query 'Parameter.Value' --output text --region "${AWS_REGION:-ap-southeast-1}")/backend:$IMAGE_TAG"

docker stop backend 2>/dev/null || true
docker rm backend 2>/dev/null || true
docker run -d \
  --name backend \
  --restart unless-stopped \
  -p 3000:3000 \
  "$IMAGE"
