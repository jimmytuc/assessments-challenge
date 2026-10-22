# Problem 4: Ship It Twice

Production-ready GitHub Actions CI/CD for a two-app web product:

- **backend** — Node.js HTTP API, deployed to EC2 (ASG + ALB) via CodeDeploy
- **frontend** — static SPA, deployed to S3 + CloudFront


## What "production ready" means here

1. **No long-lived credentials.** GitHub's OIDC provider → short-lived AWS
   credentials (`id-token: write` + role assumption). Nothing to rotate, nothing
   to leak from the repo.
2. **Immutable artifacts.** Backend images are tagged with the git SHA and
   never overwritten; frontend releases live under `releases/<sha>/` with a
   pointer object (`current.txt`) as the switch.
3. **Human gate for prod.** Deploys to `production` run in a protected GitHub
   environment with required reviewers; staging deploys automatically from
   `main`.
4. **Every deploy is verified and reversible.** CodeDeploy polls to success +
   ALB smoke test (backend); CDN smoke test after invalidation (frontend).
   Failure in any step triggers an automatic rollback to the last good
   revision/release.
5. **Shift-left safety.** Unit tests and lint in every PR; Trivy fails the
   build on HIGH/CRITICAL vulnerabilities.
6. **Hygiene.** Actions pinned by commit SHA, concurrency groups prevent
   racing deploys, minimal workflow permissions.

## Assumptions (and why)

| Assumption | Why |
|---|---|
| Backend lives in `backend/` (Node 20, `package-lock.json`, `Dockerfile`, `npm test`, `/health` endpoint) | Standard monorepo layout; the workflows need concrete paths to be real. The `/health` contract is what CodeDeploy and the ALB target group use — same pattern as Problem 3. |
| Frontend lives in `frontend/` (builds to `frontend/dist`) | Same reasoning. |
| Backend runs as a Docker container on EC2 instances inside an ASG behind an ALB, managed by CodeDeploy | Matches the problem statement (EC2), and a container gives immutable, roll-forward-friendly deploys even on plain EC2. |
| Image registry is ECR | Managed, IAM-integrated, no extra credentials. |
| AWS region `ap-southeast-1` | Consistent with the Problem 1 plan. |
| The deployment archive is the repo itself (appspec + hook scripts) pushed to S3 via `aws deploy push` | CodeDeploy needs a revision source; S3 is the standard one and keeps GitHub from being a deploy dependency. |
| The instance hooks read the image tag from SSM (`/backend/image_tag`) | Decouples "what changed" from the AppSpec; the same revision can be re-deployed, and rollback restores the tag and replays the last known-good deployment |

## How the pipelines work

### Backend (`backend.yml`)

```
PR ──> lint + unit tests                          (no deploy, no creds)
push main ──> tests ──> build ──> Trivy ──> ECR ──> deploy staging
tag v*    ──> tests ──> build ──> Trivy ──> ECR ──> deploy production (approval env)
manual dispatch ──> build ──> deploy staging      (same as a main push)
```

- Build uses `--cache-from` against the last pushed image; push is git-SHA
  tagged plus a moving `latest` (cache only, never deployed).
- `deploy-backend.sh` (deploy mode): records the current tag as
  `/backend/image_tag_prev`, publishes the new tag to `/backend/image_tag`,
  pushes the revision archive, creates the deployment, polls it to
  Success/Failed, then smoke-tests `https://<ALB>/health`. Only after the
  smoke test passes does it record the deployment as
  `/backend/last_good_deployment`.
- **Rollback is internal to the script** and runs on any post-creation
  failure (deployment failed *or* smoke test failed): it restores
  `/backend/image_tag` from `image_tag_prev` and replays the last good
  deployment's revision — whose hooks now pull the restored tag. It then
  exits non-zero so the workflow is red even though the rollback succeeded.
  Instance-side, `ValidateService` failing the deployment is a second,
  CodeDeploy-native safety net.

### Frontend (`frontend.yml`)

```
PR ──> tests ──> build (artifact uploaded)
push main ──> tests/build ──> S3 staging (releases/<sha>/ + KVS switch) ──> invalidate + wait ──> smoke
tag v*    ──> tests/build ──> S3 production ──> invalidate + wait ──> smoke   (approval env)
```

- Releases are immutable under `releases/<tag>/`. The live release is a
  CloudFront KeyValueStore key (`current`, with `previous` as the undo
  record) that the origin-request CloudFront Function
  (`scripts/cloudfront-function.js`) rewrites every request path against —
  so the switch is a single KVS write, and rollback is the same write in
  reverse. Bucket root is never served directly.
- `deploy-frontend.sh` waits for the CloudFront invalidation to complete
  before smoke-testing, and greps the served `index.html` for
  `VERSION_MARKER` (the git SHA, which the build embeds via
  `BUILD_GIT_SHA`) so a green smoke test proves the *new* release is being
  served, not a stale cache.
- S3 versioning on the bucket is the deeper safety net (recommended in
  setup).

## Deliberately left out (and why)

| Item | Why |
|---|---|
| Blue/green or canary deploys | CodeDeploy in-place rolling + ASG health checks cover this stage; blue/green adds ALB/target-group orchestration better done when traffic warrants |
| ECS/EKS migration for the backend | The problem pins EC2; containerized deploys make a later lift-and-shift trivial |
| Multi-region deploys | Not required; the pipelines are region-parameterized so it's a config change |
| Slack/Teams notification steps | Secrets-dependent; documented as the obvious extension |
| Performance/load testing in the pipeline | Separately scheduled job (e.g. k6 on staging) — kept out of the deploy path |
| Dependabot/Renovate config | Repo-level setting, not a workflow |

## What the AWS/repo side needs (setup checklist)

1. **GitHub:** OIDC provider in the AWS account (thumbprint + audience
   `sts.amazonaws.com`); environments `staging`/`production` with required
   reviewers on `production`; branch protection on `main`.
2. **Secrets/vars:** `AWS_ROLE_ARN` (secret, per environment), vars:
   `ECR_REGISTRY`, `BACKEND_DEPLOY_BUCKET`, `BACKEND_ALB_ENDPOINT`,
   `FRONTEND_S3_BUCKET_*`, `CLOUDFRONT_DISTRIBUTION_*`, `FRONTEND_KVS_ARN_*`,
   `CDN_ENDPOINT_*`.
3. **IAM role (least privilege):** `sts:AssumeRoleWithWebIdentity` for the
   repo ref; ECR push; S3 read/write on the deploy bucket and frontend
   buckets; CloudFront invalidation + KVS `get/put/describe` on the
   frontend KVS stores; CodeDeploy create/get/list; SSM
   `put-parameter`/`get-parameter` on `/backend/*`. Prod role additionally
   scoped to prod resources.
4. **EC2:** ASG + ALB target group with `/health` checks; CodeDeploy agent on
   the AMI (or SSM install in user-data); instance profile with ECR pull +
   SSM read; `docker` installed.
5. **S3/CloudFront:** frontend buckets with versioning; a CloudFront
   KeyValueStore with keys `current`/`previous`; the origin-request
   CloudFront Function (`scripts/cloudfront-function.js`) associated with
   the S3-origin behavior and published (attach via Console/API once).
6. **Frontend build contract:** the build must embed the git SHA
   (`BUILD_GIT_SHA` env) into `index.html` (e.g. a meta tag) so the smoke
   test can assert the served version.

## Verification performed here

- `actionlint`: clean on both workflows.
- `yamllint` (relaxed, 140 cols): clean.
- `bash -n` + `shellcheck`: clean on all scripts.
- No AWS account was available, so the deploy steps are implemented
  faithfully but not executed; every AWS call is standard CLI that runs
  as-is once the checklist above exists.
