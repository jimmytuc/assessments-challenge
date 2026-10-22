#!/usr/bin/env bash
# CodeDeploy BeforeInstall: pull the new image while the old container keeps
# serving. If the pull fails, the deployment fails and the live container
# stays up untouched.
set -euo pipefail

IMAGE_TAG="$(aws ssm get-parameter --name /backend/image_tag \
  --with-decryption --query 'Parameter.Value' --output text --region "${AWS_REGION:-ap-southeast-1}")"
IMAGE="$(aws ssm get-parameter --name /backend/ecr_registry \
  --with-decryption --query 'Parameter.Value' --output text --region "${AWS_REGION:-ap-southeast-1}")/backend:$IMAGE_TAG"

docker pull "$IMAGE"
