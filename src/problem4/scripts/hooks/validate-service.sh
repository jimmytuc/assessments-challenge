#!/usr/bin/env bash
# CodeDeploy ValidateService: the instance's own health check. CodeDeploy
# treats a non-zero exit as a failed deployment and rolls the ASG back.
set -euo pipefail

curl -fsS --retry 10 --retry-delay 5 --max-time 5 http://localhost:3000/health > /dev/null
