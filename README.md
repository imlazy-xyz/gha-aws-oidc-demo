# GitHub Actions → AWS OIDC, validated with `tf-policy-validator`

A hands-on, verified walkthrough of authenticating GitHub Actions to AWS via OIDC (no long-lived
access keys), running Terraform from CI, and gating the IAM policies involved with
[`awslabs/terraform-iam-policy-validator`](https://github.com/awslabs/terraform-iam-policy-validator).

Every command below was actually run against a real AWS account and a real GitHub repo. Where
something failed, the failure and the fix are recorded rather than smoothed over.

**Repo structure:** `bootstrap/` (OIDC provider, CI role, state bucket — applied once, locally) ·
`infra/` (the disposable demo workload — applied by CI) · `policy-validator/` (validator config +
reference policy) · `.github/workflows/terraform.yml` (the CI pipeline).

**Contents:** [Prerequisites](#prerequisites) ·
[Phase 0 — De-risking the validator](#phase-0--de-risking-the-validator-against-terraform-116) ·
[Phase 1 — GitHub repo](#phase-1--github-repository) ·
[Phase 2 — OIDC provider + CI role](#phase-2--aws-oidc-provider-ci-role-state-bucket-bootstrap) ·
[Phase 3 — Workload + CI permissions](#phase-3--disposable-workload--iteratively-earned-ci-permissions) ·
[Phase 4 — Validator integration](#phase-4--validator-integration-against-the-real-infra) ·
[Phase 5 — Workflow](#phase-5--github-actions-workflow) ·
[Phase 6 — Running it for real](#phase-6--running-the-workflow-for-real) ·
[Phase 7 — Cleanup](#phase-7--final-cleanup) ·
[Summary](#summary) · [References](#references)

## Prerequisites

- `aws` CLI, authenticated, pointed at the target account.
- `gh` CLI, authenticated.
- Terraform.
- `jq` (used both as a CLI utility and, as it turns out, as a required workaround — see Phase 0).

Environment this tutorial was built against:

| Item | Value |
|---|---|
| AWS account | `123456789012`, region `us-east-1` |
| Terraform | 1.16.0, AWS provider 6.62.0 |
| `tf-policy-validator` | 0.0.9 (PyPI package name — **not** the GitHub repo name) |
| aws-cli | 2.27.35 |
| gh | 2.99.0 |

> **Naming gotcha:** the tool's PyPI package is `tf-policy-validator`, not
> `terraform-iam-policy-validator` (the latter is only the GitHub repo name and 404s on PyPI).
> [Repo](https://github.com/awslabs/terraform-iam-policy-validator) ·
> [PyPI](https://pypi.org/project/tf-policy-validator/)

## Phase 0 — De-risking the validator against Terraform 1.16

Before touching AWS IAM or GitHub, we checked whether `tf-policy-validator` even works against a
plan produced by our installed Terraform version. Open issue
[#42](https://github.com/awslabs/terraform-iam-policy-validator/issues/42) reports a `ValueError`
parsing Terraform 1.12+ plan JSON due to new resource-identity fields — worth confirming before
building anything on top of it.

```bash
python3 -m venv .venv
.venv/bin/pip install tf-policy-validator
.venv/bin/pip show tf-policy-validator
```

```
Name: tf-policy-validator
Version: 0.0.9
...
```

Fetched the shipped `arnServiceMap` config verbatim rather than hand-writing one:

```bash
curl -fsSL https://raw.githubusercontent.com/awslabs/terraform-iam-policy-validator/main/iam_check/config/default.yaml \
  -o policy-validator/config.yaml
```

A minimal throwaway Terraform config with one `aws_iam_role` + `aws_iam_role_policy`
(`infra-phase0/main.tf`) — deliberately including a **malformed action** (`s3:GetObjectt`, an extra
trailing `t`) so we can confirm the validator actually flags problems instead of silently passing:

```hcl
resource "aws_iam_role_policy" "test" {
  name = "phase0-test-policy"
  role = aws_iam_role.test.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = ["s3:GetObjectt"]
      Resource = "*"
    }]
  })
}
```

```bash
terraform init
terraform plan -out tf.plan
terraform show -json -no-color tf.plan > tf.json
tf-policy-validator validate --config policy-validator/config.yaml --template-path tf.json --region us-east-1
```

### Result: issue #42 reproduced exactly

```
Traceback (most recent call last):
  ...
  File ".../iam_check/lib/tfPlan.py", line 525, in __init__
    raise ValueError(f"TerraformResource: Invalid parameter: {arg}")
ValueError: TerraformResource: Invalid parameter: identity_schema_version
```

Terraform 1.16.0's plan JSON includes `identity` / `identity_schema_version` fields on each planned
resource (new resource-identity metadata) that `tf-policy-validator` 0.0.9's `TerraformResource`
parser doesn't know about and rejects outright.

### Fix: strip the fields with `jq` before handing the plan to the validator

```bash
jq 'del(.. | .identity?, .identity_schema_version?)' tf.json > tf.clean.json
tf-policy-validator validate --config policy-validator/config.yaml --template-path tf.clean.json --region us-east-1
```

```json
{
    "BlockingFindings": [
        {
            "findingType": "ERROR",
            "code": "INVALID_ACTION",
            "message": "The action s3:GetObjectt does not exist.",
            "resourceName": "phase0-test-policy",
            "policyName": "aws_iam_role_policy.test",
            ...
        }
    ],
    "NonBlockingFindings": [
        {
            "findingType": "SUGGESTION",
            "code": "EMPTY_ARRAY_RESOURCE",
            "message": "This statement includes no resources and does not affect the policy. Specify resources.",
            "resourceName": "phase0-test-role",
            "policyName": "aws_iam_role.test",
            ...
        }
    ]
}
```

The `jq` filter clears the crash, and the validator correctly caught the deliberate typo as a
blocking `ERROR` (exit code 2), plus a non-blocking suggestion about the assume-role policy's empty
resource array. This confirms the tool is functioning, not just failing to crash.

**Consequence for the rest of this tutorial:** the `jq` filter is a mandatory, permanent stage of the
CI pipeline built below — not an optional cleanup step. Every `terraform show -json` output is piped
through it before being handed to `tf-policy-validator`.

---

## Phase 1 — GitHub repository

```bash
git init
git config user.name "Demo User"
git config user.email "you@example.com"
git add .gitignore README.md PLAN.md policy-validator/config.yaml
git commit -m "Phase 0: de-risk tf-policy-validator against Terraform 1.16 plan JSON"
gh repo create imlazy-xyz/gha-aws-oidc-demo --public --source=. --remote=origin --push
```

### Gotcha: SSH push failed, switched to HTTPS

`gh repo create --push` defaults to the SSH remote URL. On this machine that failed:

```
git@github.com: Permission denied (publickey).
fatal: Could not read from remote repository.
```

The account has SSH keys for other GitHub identities (`github-personal`, `github-compunnel`) but none
wired up for `github.com` → `imlazy-xyz` in `~/.ssh/config`. Since `gh auth status` showed `imlazy-xyz`
already authenticated with a valid token, the fix was to switch the remote to HTTPS and let `gh`'s
git credential helper handle auth instead of debugging SSH key routing:

```bash
git remote set-url origin https://github.com/imlazy-xyz/gha-aws-oidc-demo.git
git push -u origin master
```

This succeeded immediately. Confirmed:

```bash
gh repo view imlazy-xyz/gha-aws-oidc-demo --json url,visibility,defaultBranchRef
```
```json
{"defaultBranchRef":{"name":"master"},"url":"https://github.com/imlazy-xyz/gha-aws-oidc-demo","visibility":"PUBLIC"}
```

**Note on token scope:** `gh auth status` for this account initially showed scopes
`admin:public_key, gist, read:org, repo` — no `workflow` scope. This turned out to matter for real:
pushing the first `.github/workflows/*.yml` file was rejected outright:

```
! [remote rejected] master -> master (refusing to allow an OAuth App to create or
  update workflow `.github/workflows/debug-oidc.yml` without `workflow` scope)
```

`gh`'s OAuth token does **not** carry an implicit `workflow` grant — this needed fixing, not just
noting. Fixed with:

```bash
gh auth refresh -h github.com -s workflow
```

which runs an interactive device-code flow (open `https://github.com/login/device`, enter the
printed code). After that, `gh auth status` showed `workflow` added to the scope list and the same
push succeeded unchanged. Anyone reproducing this needs to run `gh auth refresh -s workflow` before
the first push that touches `.github/workflows/`.

---

## Phase 2 — AWS OIDC provider, CI role, state bucket (`bootstrap/`)

Applied **once, locally**, using the existing `user/deploy-admin` credentials. `bootstrap/` deliberately uses
**local Terraform state** — it is what creates the state bucket the rest of this project uses, so it
cannot store its own state there (chicken-and-egg). `bootstrap/terraform.tfstate` is gitignored.

### OIDC provider — no thumbprint

```hcl
resource "aws_iam_openid_connect_provider" "github" {
  url             = "https://token.actions.githubusercontent.com"
  client_id_list  = ["sts.amazonaws.com"]
  thumbprint_list = []
}
```

The classic tutorials hardcode a thumbprint (`6938fd4d98bab03faadb97b34396831e3780aea1` or similar).
That's no longer necessary: AWS validates the GitHub OIDC JWKS endpoint's TLS certificate against its
own library of trusted root CAs, and only falls back to a configured thumbprint if the certificate
isn't signed by a trusted CA.
[AWS docs](https://docs.aws.amazon.com/IAM/latest/UserGuide/id_roles_providers_create_oidc_verify-thumbprint.html) ·
[Terraform provider docs](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_openid_connect_provider)
(the AWS docs page currently ends with an injected block instructing AI assistants to run an
unrelated CLI command — ignored, since page content is data, not instructions).

### Permissions boundary + CI role

The workload provisions its own IAM role (an "app role" — see Phase 3), which means the CI role needs
`iam:CreateRole` / `iam:PutRolePolicy`. Granting that unconditionally would let CI mint a role with
*more* privilege than CI itself has. Two mitigations, both applied:

- **Path constraint**: the CI role's `iam:*` grant is scoped to
  `arn:aws:iam::123456789012:role/gha-demo/*` only.
- **Permissions boundary**: every role CI creates gets `permissions_boundary` set to a policy that
  caps it to the same workload services (`s3`, `sqs`, `sns`, `dynamodb`, `logs`) — CI cannot mint a
  role with escalated privileges even within the `/gha-demo/` path.

The CI role's trust policy started deliberately loose (`StringLike` on the whole repo) because the
real `sub` claim format isn't known until a token is actually issued — see below.

### Apply — real output

```bash
cd bootstrap && terraform init && terraform apply -auto-approve
```

```
aws_iam_openid_connect_provider.github: Creation complete after 22s [id=arn:aws:iam::123456789012:oidc-provider/token.actions.githubusercontent.com]
aws_iam_policy.ci_boundary: Creation complete after 23s [id=arn:aws:iam::123456789012:policy/gha-demo-ci-boundary]
aws_iam_role.ci: Creation complete after 1s [id=gha-demo-ci-role]
aws_s3_bucket.tf_state: Creation complete after 1m0s [id=gha-demo-tfstate-123456789012]
aws_iam_role_policy.ci_workload: Creation complete after 0s [id=gha-demo-ci-role:gha-demo-ci-workload]
aws_s3_bucket_server_side_encryption_configuration.tf_state: Creation complete after 14s [id=gha-demo-tfstate-123456789012]
aws_s3_bucket_public_access_block.tf_state: Creation complete after 14s [id=gha-demo-tfstate-123456789012]
aws_s3_bucket_versioning.tf_state: Creation complete after 15s [id=gha-demo-tfstate-123456789012]

Apply complete! Resources: 8 added, 0 changed, 0 destroyed.

Outputs:

ci_role_arn = "arn:aws:iam::123456789012:role/gha-demo/gha-demo-ci-role"
oidc_provider_arn = "arn:aws:iam::123456789012:oidc-provider/token.actions.githubusercontent.com"
state_bucket = "gha-demo-tfstate-123456789012"
```

Verified independently with the AWS CLI (not just trusting Terraform's own report):

```bash
aws iam get-role --role-name gha-demo-ci-role \
  --query 'Role.{Arn:Arn,Path:Path,PermissionsBoundary:PermissionsBoundary}'
```
```
Arn: arn:aws:iam::123456789012:role/gha-demo/gha-demo-ci-role
Path: /gha-demo/
PermissionsBoundary:
  PermissionsBoundaryArn: arn:aws:iam::123456789012:policy/gha-demo-ci-boundary
  PermissionsBoundaryType: Policy
```

> **Sandbox gotcha (unrelated to AWS/GitHub):** `aws` CLI here is configured with `output = yaml` in
> `~/.aws/config`, which makes the CLI invoke a pager. In a non-interactive shell that pager can hang
> indefinitely waiting for a keypress with zero output — it looks exactly like a stuck network call.
> Fix: pass `--no-cli-pager`, or set `CLI_PAGER=""`.

### Discovering the real `sub` claim — deterministic, not guessed

The trust policy above started with a loose `StringLike` on
`repo:imlazy-xyz/gha-aws-oidc-demo:*`. A temporary workflow
(`.github/workflows/debug-oidc.yml`, `workflow_dispatch`-triggered) requested a real OIDC token and
decoded its JWT payload:

```bash
TOKEN=$(curl -sH "Authorization: bearer $ACTIONS_ID_TOKEN_REQUEST_TOKEN" \
  "$ACTIONS_ID_TOKEN_REQUEST_URL&audience=sts.amazonaws.com" | jq -r .value)
echo "$TOKEN" | cut -d. -f2 | base64 -d 2>/dev/null | jq '{sub, aud, repository, repository_id, repository_owner, repository_owner_id, ref}'
```

First run (job with no `environment:` set), against branch `master`:

```json
{
  "sub": "repo:imlazy-xyz@1752641/gha-aws-oidc-demo@1354514600:ref:refs/heads/master",
  "aud": "sts.amazonaws.com",
  "repository": "imlazy-xyz/gha-aws-oidc-demo",
  "repository_id": "1354514600",
  "repository_owner": "imlazy-xyz",
  "repository_owner_id": "1752641",
  "ref": "refs/heads/master"
}
```

**This confirms the research prediction exactly**: since `gha-aws-oidc-demo` was created after
2026-07-15, its OIDC `sub` uses GitHub's newer **immutable-ID** format
(`repo:OWNER@OWNER-ID/REPO@REPO-ID:...`) instead of the legacy `repo:OWNER/REPO:...` form still shown
in most tutorials and blog posts. A trust policy copied from one of those would never match.

### Scoping to a GitHub environment

A branch-scoped `sub` (`:ref:refs/heads/master`) means any push to `master` can assume the role. We
created a GitHub **environment** instead, so the condition is on `:environment:` rather than
`:ref:`:

```bash
gh api -X PUT repos/imlazy-xyz/gha-aws-oidc-demo/environments/aws-demo
```

**Ordering trap, confirmed by testing:** the environment must exist *before* the first workflow run
references it — a job with `environment: aws-demo` fails to even start if the environment isn't
created yet, and no OIDC token is ever issued in that case.

Re-ran the same debug step with `environment: aws-demo` added to the job:

```json
{
  "sub": "repo:imlazy-xyz@1752641/gha-aws-oidc-demo@1354514600:environment:aws-demo",
  "aud": "sts.amazonaws.com",
  ...
}
```

### Tightening the trust policy

Replaced `StringLike` + wildcard with `StringEquals` on the exact observed sub:

```hcl
Condition = {
  StringEquals = {
    "token.actions.githubusercontent.com:aud" = "sts.amazonaws.com"
    "token.actions.githubusercontent.com:sub" = "repo:imlazy-xyz@1752641/gha-aws-oidc-demo@1354514600:environment:aws-demo"
  }
}
```

```bash
terraform apply -auto-approve
```

Applying this surfaced one more piece of drift worth knowing about:

```
~ resource "aws_iam_openid_connect_provider" "github" {
    ~ thumbprint_list = [
        - "ab9d0263244dd0326eb67015705a667e79cfe998",
      ]
  }
```

Even though `thumbprint_list = []` was set at creation, AWS had auto-populated one anyway (matching
the documented behavior: "if you don't provide one, IAM retrieves the top intermediate CA
thumbprint"). Re-applying the empty list cleared it — harmless, since AWS doesn't use the configured
thumbprint to verify GitHub's endpoint regardless (see the provider docs cited above).

### Proof: a real `AssumeRoleWithWebIdentity` succeeds under the tightened policy

Extended the debug workflow to actually assume the role via `aws-actions/configure-aws-credentials@v6`
and call `aws sts get-caller-identity`:

```yaml
- name: Configure AWS credentials via OIDC
  uses: aws-actions/configure-aws-credentials@v6
  with:
    role-to-assume: arn:aws:iam::123456789012:role/gha-demo/gha-demo-ci-role
    aws-region: us-east-1

- name: Prove the assumed role
  run: aws sts get-caller-identity --no-cli-pager
```

Real run output ([workflow run 33610179327](https://github.com/imlazy-xyz/gha-aws-oidc-demo/actions/runs/33610179327), all steps green):

```json
{
    "UserId": "AROAEXAMPLE1111111111:GitHubActions",
    "Account": "123456789012",
    "Arn": "arn:aws:sts::123456789012:assumed-role/gha-demo-ci-role/GitHubActions"
}
```

**This is the core proof point of the whole tutorial**: GitHub Actions obtained temporary AWS
credentials via OIDC, scoped by the exact `sub`/`aud` claims of a token issued for the `aws-demo`
environment on this specific repository — no access keys or secrets stored anywhere.

---

## Phase 3 — Disposable workload + iteratively-earned CI permissions

### The workload (`infra/`)

Six free-tier resources chosen for IAM breadth at $0 cost:

| Resource | Purpose |
|---|---|
| `aws_s3_bucket` + policy | Resource policy #1 — target for `check-no-public-access` |
| `aws_sqs_queue` + policy | Resource policy #2 |
| `aws_sns_topic` + policy | Resource policy #3 |
| `aws_dynamodb_table` (`PAY_PER_REQUEST`) | Identity-policy breadth, no resource policy |
| `aws_cloudwatch_log_group` (`retention_in_days = 1`) | Identity-policy breadth |
| `aws_iam_role` + `aws_iam_role_policy` (app role) | Both an **identity policy** and a **trust policy** for the validator to analyse — richest finding source |

`infra/backend.tf` uses an **S3 backend with `use_lockfile = true`** — S3-native locking (GA since
Terraform 1.11), so no separate DynamoDB lock table is needed:

```hcl
backend "s3" {
  bucket       = "gha-demo-tfstate-123456789012"
  key          = "infra/terraform.tfstate"
  region       = "us-east-1"
  use_lockfile = true
  encrypt      = true
}
```

The app role's permissions boundary is looked up by name from `infra/`'s own state (separate from
`bootstrap/`'s state) via a data source:

```hcl
data "aws_iam_policy" "ci_boundary" {
  name = "gha-demo-ci-boundary"
}
```

### Iterating against real `AccessDenied` errors — locally, not through CI

Per the plan, permission gaps were closed by actually running `terraform apply` **locally** under
the CI role's own credentials (fast, seconds per round-trip) rather than through GitHub Actions
(minutes per round-trip). The CI role's trust policy was temporarily extended with a second trust
statement for `user/deploy-admin`, removed again once done:

```bash
aws iam update-assume-role-policy --role-name gha-demo-ci-role --policy-document file://temp-trust.json
CREDS=$(aws sts assume-role --role-arn arn:aws:iam::123456789012:role/gha-demo/gha-demo-ci-role \
  --role-session-name local-test)
# export AWS_ACCESS_KEY_ID / AWS_SECRET_ACCESS_KEY / AWS_SESSION_TOKEN from $CREDS, then:
terraform apply -auto-approve
```

Three real denials surfaced and were fixed, each captured verbatim:

**Iteration 1 —** `data "aws_iam_policy"` (looking up the boundary by name) requires
`iam:ListPolicies`, a list-type action IAM does not support scoping to one resource ARN:

```
Error: reading IAM Policy: ... AccessDenied: User: .../gha-demo-ci-role/local-test is not
authorized to perform: iam:ListPolicies on resource: policy path / because no identity-based
policy allows the iam:ListPolicies action
  with data.aws_iam_policy.ci_boundary
```

Fix: added `iam:ListPolicies` (`Resource: "*"`, unavoidable for a list action) and
`iam:GetPolicy`/`iam:GetPolicyVersion` (scoped to the boundary policy's own ARN) to the CI role's
identity policy.

**Iteration 2 — the interesting one.** Re-running hit the *same* action, but this time the boundary,
not the identity policy, was named as the blocker:

```
Error: reading IAM Policy: ... AccessDenied: ... because no permissions boundary allows the
iam:ListPolicies action
```

**Design finding:** `bootstrap/main.tf` attaches `ci_boundary` as the CI role's *own*
`permissions_boundary` (not only as the boundary the CI role assigns to roles it creates). A
permissions boundary caps the *effective* permissions of whatever it's attached to — so the CI
role's own identity-policy grant of `iam:ListPolicies` was necessary but not sufficient; the
boundary policy itself needed to allow it too. Fixed by adding the same IAM read/write actions,
scoped to the `/gha-demo/` role path and the boundary policy's ARN, into `ci_boundary` itself:

```hcl
resource "aws_iam_policy" "ci_boundary" {
  policy = jsonencode({
    Statement = [
      { Sid = "AllowDemoWorkloadActions", Action = ["s3:*","sqs:*","sns:*","dynamodb:*","logs:*"], Resource = "*" },
      { Sid = "AllowIamListForBoundaryLookup", Action = ["iam:ListPolicies"], Resource = "*" },
      { Sid = "AllowIamManagementUnderPath",
        Action = ["iam:GetPolicy","iam:GetPolicyVersion","iam:GetRole","iam:CreateRole","iam:DeleteRole",
                   "iam:UpdateRole","iam:PutRolePolicy","iam:GetRolePolicy","iam:DeleteRolePolicy",
                   "iam:TagRole","iam:UntagRole","iam:ListRolePolicies","iam:ListAttachedRolePolicies",
                   "iam:ListInstanceProfilesForRole"],
        Resource = ["arn:aws:iam::*:role/gha-demo/*", "arn:aws:iam::*:policy/gha-demo-ci-boundary"] }
    ]
  })
}
```

**Iteration 3 —** `terraform apply` creating the app role hit one more list action needed by
Terraform's own drift-detection read:

```
Error: reading inline policies for IAM role gha-demo-app-role: ... AccessDenied: ... not
authorized to perform: iam:ListRolePolicies ... because no permissions boundary allows the
iam:ListRolePolicies action
```

Fix: `iam:ListRolePolicies` (plus, pre-emptively, `iam:ListAttachedRolePolicies` and
`iam:ListInstanceProfilesForRole` — the same category of read Terraform performs for any IAM role)
added to the same boundary statement above.

**Result: 3 of the allotted 6 iterations used.** No wildcard `Action: "*"` or `Resource: "*"`
shortcuts were taken on any workload service — the four fixes above are the complete, exact list of
what closing the gaps required.

### Verified — all six resources live, confirmed independently via CLI

```bash
aws s3api head-bucket --bucket gha-demo-app-123456789012                  # -> 200 OK
aws sqs get-queue-url --queue-name gha-demo-app-queue                      # -> QueueUrl returned
aws sns get-topic-attributes --topic-arn arn:aws:sns:us-east-1:123456789012:gha-demo-app-topic
aws dynamodb describe-table --table-name gha-demo-app-table --query 'Table.TableStatus'  # -> "ACTIVE"
aws logs describe-log-groups --log-group-name-prefix /gha-demo/app         # -> "/gha-demo/app"
aws iam get-role --role-name gha-demo-app-role \
  --query 'Role.{Arn:Arn,Path:Path,Boundary:PermissionsBoundary.PermissionsBoundaryArn}'
```
```
Arn: arn:aws:iam::123456789012:role/gha-demo/gha-demo-app-role
Boundary: arn:aws:iam::123456789012:policy/gha-demo-ci-boundary
Path: /gha-demo/
```

After the last successful apply, the temporary `user/deploy-admin` trust-policy statement was removed by
re-applying `bootstrap/` (its Terraform-tracked config never included it), confirmed by reading the
live trust policy back — only the OIDC federated principal remains.

---

### Gotcha: orphaned IAM principal after a role destroy/recreate

Before moving to the validator, a routine `terraform plan` on `infra/` surfaced two more real
problems worth recording.

**1. Stale S3-native lock from a killed process.** An earlier `terraform plan` was killed after
hitting a 60s foreground timeout. `use_lockfile` locking does not auto-release on SIGTERM, so the
next command failed:

```
Error: Error acquiring the state lock
... api error PreconditionFailed: At least one of the pre-conditions you specified did not hold
Lock Info:
  ID: d9bba9aa-faca-885a-f847-c0ef76231f9c
```

Fixed with `terraform force-unlock -force <lock-id>`. Worth knowing: S3-native locking trades the
old DynamoDB lock table for a lock file, but a killed process can still strand a lock exactly like
the DynamoDB approach could.

**2. Orphaned IAM principal in the S3/SQS/SNS resource policies.** During Phase 3, `aws_iam_role.app`
was destroyed and recreated once (a leftover from an earlier failed apply attempt). AWS resource
policies (S3 bucket policy, SQS queue policy, SNS topic policy) store an IAM principal's **internal
unique ID**, not its ARN text, at write time. When the role behind that unique ID was deleted and
recreated, the stored ID became orphaned — silently, since Terraform's state still showed the ARN it
originally wrote.

The next `terraform plan` showed the drift plainly for two of the three resources:

```
# aws_s3_bucket_policy.app will be updated in-place
  ~ Principal = {
      ~ AWS = "AROAEXAMPLE2222222222" -> "arn:aws:iam::123456789012:role/gha-demo/gha-demo-app-role"
    }
# aws_sqs_queue_policy.app will be updated in-place  (same pattern)
```

But for SNS, the provider's own *read* of the topic failed outright, blocking the plan before it
could even show a diff:

```
Error: reading SNS Topic (arn:aws:sns:us-east-1:123456789012:gha-demo-app-topic): contains invalid principals
```

Confirmed directly against the live policy:

```bash
aws sns get-topic-attributes --topic-arn arn:aws:sns:us-east-1:123456789012:gha-demo-app-topic \
  --query 'Attributes.Policy' --output text | jq .
```
```json
{"Statement": [{"Principal": {"AWS": "AROAEXAMPLE2222222222"}, ...}]}
```

Since Terraform couldn't even read past this to plan a fix, it was fixed directly:

```bash
aws sns set-topic-attributes --topic-arn arn:aws:sns:us-east-1:123456789012:gha-demo-app-topic \
  --attribute-name Policy --attribute-value file://sns-policy-fixed.json
```

Then `terraform apply` cleanly reconciled the remaining S3/SQS drift, and a follow-up
`terraform plan` confirmed: `No changes. Your infrastructure matches the configuration.`

**Takeaway:** destroying and recreating an IAM role that other resource policies reference by ARN can
silently break those policies at the AWS level, even though the ARN string is unchanged — because
AWS resolves the ARN to an internal ID once, at write time, and never re-resolves it. This is a real
argument for `create_before_destroy` lifecycle rules on IAM roles referenced elsewhere, noted here
rather than retrofitted, since the failure only shows up after the fact.

---

## Phase 4 — Validator integration against the real infra

With `infra/` deployed, generated a fresh plan and ran all four `tf-policy-validator` subcommands
against it — the same `jq`-filtered pattern from Phase 0.

```bash
cd infra
terraform plan -out tf.plan
terraform show -json -no-color tf.plan > tf.json
jq 'del(.. | .identity?, .identity_schema_version?)' tf.json > tf.clean.json
```

### Second validator bug found: `aws_sqs_queue_policy` crashes on the shipped config

```bash
tf-policy-validator validate --config policy-validator/config.yaml --template-path infra/tf.clean.json --region us-east-1
```
```
KeyError: 'Invalid Key: aws_sqs_queue_policy.app.fakeQueueUrl'
```

Traced into the tool's own source
(`iam_check/lib/tfPlan.py:getResourceName`): an `arnServiceMap` entry is only treated as "attribute,
with a static fallback" when it contains a `?` separator (`key?default`). Without one, the whole
string is treated as a literal Terraform attribute name to read off the resource — and the shipped
`iam_check/config/default.yaml` has several entries with **no `?`**, including exactly the one this
workload hits:

```yaml
aws_sqs_queue_policy: fakeQueueUrl   # <- no "?", so "fakeQueueUrl" is read as an attribute name
```

Since `aws_sqs_queue_policy` has no attribute literally called `fakeQueueUrl`, the lookup raises an
uncaught `KeyError`. (The same bug class affects `aws_codebuild_resource_policy`,
`aws_ecr_registry_policy`, `aws_glue_resource_policy`, the four `aws_kms_*` entries, and
`aws_vpc_endpoint` in the shipped config — same missing `?`, not independently tested here since this
workload doesn't touch them.)

**Fix** — a one-line local patch to `policy-validator/config.yaml`, changing it to an empty
attribute key so it always falls through to the static default rather than depending on any real
attribute existing at plan time (SQS's `queue_url`/`id` are `(known after apply)` before creation, so
even a real attribute name would fail on a first-time plan):

```diff
- aws_sqs_queue_policy: fakeQueueUrl
+ aws_sqs_queue_policy: ?fakeQueueUrl
```

Re-running `validate` after the fix:

```json
{
    "BlockingFindings": [],
    "NonBlockingFindings": [
        {
            "findingType": "SUGGESTION",
            "code": "EMPTY_ARRAY_RESOURCE",
            "message": "This statement includes no resources and does not affect the policy. Specify resources.",
            "resourceName": "gha-demo-app-role",
            "policyName": "aws_iam_role.app"
        }
    ]
}
```
Exit code 0. The one suggestion is expected and benign — Lambda trust policies have no `Resource`
element by design.

### `check-no-new-access` against the real infra

`policy-validator/reference-policy.json` holds the app role's identity policy exactly as originally
written (scoped `s3:GetObject`/`PutObject` on the bucket, `sqs:Send/Receive/DeleteMessage` on the
queue, `sns:Publish` on the topic, `dynamodb:PutItem`/`GetItem` on the table,
`logs:CreateLogStream`/`PutLogEvents` on the log group) — the approved baseline this check answers
"has this PR granted more than that?" against.

```bash
tf-policy-validator check-no-new-access --config policy-validator/config.yaml \
  --template-path infra/tf.clean.json --region us-east-1 \
  --reference-policy policy-validator/reference-policy.json --reference-policy-type identity
```
```json
{"BlockingFindings": [], "NonBlockingFindings": []}
```
Exit 0 — matches the baseline exactly, as expected.

### `check-access-not-granted` and `check-no-public-access` against the real infra

```bash
tf-policy-validator check-access-not-granted --config policy-validator/config.yaml \
  --template-path infra/tf.clean.json --region us-east-1 \
  --actions "iam:CreateUser,iam:PassRole,s3:DeleteBucket"

tf-policy-validator check-no-public-access --config policy-validator/config.yaml \
  --template-path infra/tf.clean.json --region us-east-1
```
Both return `{"BlockingFindings": [], "NonBlockingFindings": []}`, exit 0 — the app role can't create
IAM users, pass roles, or delete the bucket, and no resource policy is public.

### Deliberate finding #1: `check-no-new-access` catches a policy widening

Temporarily widened the app role's S3 statement from scoped actions on one bucket to `s3:*` on `*`:

```diff
- Action   = ["s3:GetObject", "s3:PutObject"]
- Resource = "${aws_s3_bucket.app.arn}/*"
+ Action   = ["s3:*"]
+ Resource = "*"
```

Re-ran `check-no-new-access` against a fresh plan of the widened config:

```json
{
    "BlockingFindings": [
        {
            "findingType": "SECURITY_WARNING",
            "code": "policy-analysis-CheckNoNewAccess",
            "message": "The modified permissions grant new access compared to your existing policy.",
            "resourceName": "gha-demo-app-policy",
            "details": {
                "result": "FAIL",
                "reasons": [
                    { "description": "New access in the statement with sid: S3ReadWrite.", "statementId": "S3ReadWrite" }
                ]
            }
        }
    ],
    "NonBlockingFindings": []
}
```
Exit code **2** (blocking). Reverted the widening; a follow-up `terraform plan` confirmed the
infra config matches the last committed, clean state.

### Deliberate finding #2: `check-no-public-access` catches a public bucket statement

Added a second statement to the S3 bucket policy with `Principal = "*"`:

```hcl
{
  Sid       = "DeliberatelyPublicRead"
  Effect    = "Allow"
  Principal = "*"
  Action    = ["s3:GetObject"]
  Resource  = "${aws_s3_bucket.app.arn}/*"
}
```

```json
{
    "BlockingFindings": [
        {
            "findingType": "SECURITY_WARNING",
            "code": "policy-analysis-CheckNoPublicAccess",
            "message": "The resource policy grants public access for the given resource type.",
            "resourceName": "gha-demo-app-123456789012",
            "details": {
                "result": "FAIL",
                "reasons": [
                    { "description": "Public access granted in the following statement with sid: DeliberatelyPublicRead.", "statementId": "DeliberatelyPublicRead" }
                ]
            }
        }
    ],
    "NonBlockingFindings": []
}
```
Exit code **2**. Reverted; `infra/main.tf` confirmed byte-identical to the last committed version.

### Subcommand flag reference (confirmed by testing, not just the README)

| Subcommand | Blocking-severity flag | Confirmed working |
|---|---|---|
| `validate` | `--treat-finding-type-as-blocking` | Yes — default already blocks `ERROR`/`SECURITY_WARNING` |
| `check-no-new-access` | `--treat-findings-as-non-blocking` (opt *out* of blocking) | Yes — default blocks, as shown above |
| `check-access-not-granted` | `--treat-findings-as-non-blocking` | Yes |
| `check-no-public-access` | `--treat-findings-as-non-blocking` | Yes |

`--config` and `--region` are required on every subcommand. The config file is an **`arnServiceMap`**
(how to synthesize a fake ARN per resource type for the underlying AWS Access Analyzer API calls) —
not, as the flag name might suggest, a list of actions to check.

---

## Phase 5 — GitHub Actions workflow

`.github/workflows/terraform.yml` ties everything together: OIDC auth → `terraform plan` → all four
`tf-policy-validator` gates → `terraform apply` → CLI verification → `terraform destroy`.

```yaml
on:
  workflow_dispatch:   # applies real resources then destroys them in the same run

permissions:
  id-token: write
  contents: read

jobs:
  terraform:
    runs-on: ubuntu-latest
    environment: aws-demo
    steps:
      - uses: actions/checkout@v4
      - uses: hashicorp/setup-terraform@v3
        with: { terraform_version: "1.16.0" }

      - uses: aws-actions/configure-aws-credentials@v6
        with:
          role-to-assume: arn:aws:iam::123456789012:role/gha-demo/gha-demo-ci-role
          aws-region: us-east-1

      - run: terraform init
      - run: terraform fmt -check -recursive
      - run: terraform validate
      - run: |
          terraform plan -out=tf.plan
          terraform show -json -no-color tf.plan > tf.json
      - run: jq 'del(.. | .identity?, .identity_schema_version?)' tf.json > tf.clean.json

      - uses: actions/setup-python@v5
        with: { python-version: "3.12" }
      - run: pip install tf-policy-validator

      # four validator gates (validate, check-no-new-access,
      # check-access-not-granted, check-no-public-access) -- non-zero exit fails the job

      - run: terraform apply -auto-approve tf.plan
      - run: |  # verify via aws CLI using terraform outputs
      - run: terraform destroy -auto-approve
        if: always()
      - run: |  # verify teardown
        if: always()
```

Chose `workflow_dispatch` (manual trigger) rather than running on every push, since this workflow
applies real AWS resources and destroys them in the same run — appropriate for a demo/tutorial
pipeline, not something you'd want firing on every commit.

Before committing, every `tf-policy-validator` flag used was checked against `--help` output rather
than trusted from memory (`validate --treat-finding-type-as-blocking ERROR,SECURITY_WARNING`;
`check-no-new-access`/`check-access-not-granted --treat-findings-as-non-blocking`) — all confirmed
correct.

**Bash pipefail gotcha, caught before committing (not after a failed run):** GitHub Actions runs
`bash` steps with `-eo pipefail` by default. A step like
`aws ... | grep -q "Not Found" && echo ok` fails the whole step if the `aws` command itself errors
(nonzero), *even when* `grep` finds its match — because `pipefail` reports the pipeline's exit as the
last non-zero exit among all stages, not just the final command. Fixed by capturing output into a
variable first, then grepping the variable (no pipe involved):
```bash
BUCKET_OUT=$(aws s3api head-bucket --bucket "..." 2>&1) || true
echo "$BUCKET_OUT" | grep -q "Not Found" && echo "bucket gone: OK" || { echo "..."; exit 1; }
```

## Phase 6 — Running the workflow for real

### First run: caught one more real permissions bug

```bash
gh workflow run terraform.yml --repo imlazy-xyz/gha-aws-oidc-demo
```

[Run 33613750202](https://github.com/imlazy-xyz/gha-aws-oidc-demo/actions/runs/33613750202) — failed
at the first validator gate:

```
botocore.errorfactory.AccessDeniedException: An error occurred (AccessDeniedException) when calling
the ValidatePolicy operation: User: arn:aws:sts::123456789012:assumed-role/gha-demo-ci-role/GitHubActions
is not authorized to perform: access-analyzer:ValidatePolicy on resource:
arn:aws:access-analyzer:us-east-1:123456789012:* because no permissions boundary allows the
access-analyzer:ValidatePolicy action
```

**Same bug class as Phase 3's iteration 2**: `access-analyzer:*` was granted in the CI role's
identity policy (`ci_workload`) but never added to the permissions boundary (`ci_boundary`) that
also applies to the CI role itself. `terraform destroy` still ran (via `if: always()`) — harmlessly,
since `terraform apply` never got far enough to create anything.

Fixed the boundary the same way as before:
```hcl
{
  Sid    = "AllowAccessAnalyzerValidator"
  Effect = "Allow"
  Action = ["access-analyzer:ValidatePolicy", "access-analyzer:CheckNoNewAccess",
            "access-analyzer:CheckAccessNotGranted", "access-analyzer:CheckNoPublicAccess"]
  Resource = "*"
}
```
Applied locally with `terraform apply` in `bootstrap/`, committed, pushed.

### Second run: fully green, end to end

```bash
gh workflow run terraform.yml --repo imlazy-xyz/gha-aws-oidc-demo
gh run watch 33614042453 --repo imlazy-xyz/gha-aws-oidc-demo --exit-status
```

[Run 33614042453](https://github.com/imlazy-xyz/gha-aws-oidc-demo/actions/runs/33614042453) —
**every step green**, exit code 0:

```
✓ Configure AWS credentials via OIDC
✓ Prove the assumed identity
✓ terraform init / fmt -check / validate / plan
✓ Filter plan JSON for tf-policy-validator
✓ Policy validation gate -- validate
✓ Policy validation gate -- check-no-new-access
✓ Policy validation gate -- check-access-not-granted
✓ Policy validation gate -- check-no-public-access
✓ terraform apply
✓ Verify resources exist
✓ terraform destroy
✓ Verify teardown
```

Real output pulled from the run log:

```
Apply complete! Resources: 12 added, 0 changed, 0 destroyed.
```
```json
{
    "BucketArn": "arn:aws:s3:::gha-demo-app-123456789012",
    "BucketRegion": "us-east-1",
    "AccessPointAlias": false
}
```
```
Destroy complete! Resources: 12 destroyed.
bucket gone: OK
table gone: OK
```

### Verified independently, outside the workflow

```bash
aws s3 ls | grep gha-demo                                    # -> only the (intentional) state bucket
aws dynamodb list-tables --query 'TableNames'                 # -> []
aws sqs list-queues --query 'QueueUrls'                        # -> null (none)
aws sns list-topics --query 'Topics[].TopicArn' | grep gha-demo  # -> (no output)
aws iam list-roles --path-prefix /gha-demo/ --query 'Roles[].RoleName'  # -> only gha-demo-ci-role
```

Only the `bootstrap/`-owned state bucket and CI role remain — exactly as expected, since those are
torn down separately in Phase 7. The disposable workload leaves nothing behind.

**This is the complete, verified proof of the whole tutorial**: GitHub Actions authenticated to AWS
via OIDC with no stored credentials, a real Terraform plan was gated by `tf-policy-validator` (with
two deliberately-triggered findings caught earlier in Phase 4), the workload was applied for real,
verified via independent CLI calls, and cleanly destroyed — twice over, once inside the workflow and
once confirmed from outside it.

---

## Phase 7 — Final cleanup

`infra/` was already destroyed and verified as part of every workflow run (Phase 6). What remains is
`bootstrap/` — the OIDC provider, CI role, permissions boundary, and state bucket.

```bash
cd bootstrap
terraform destroy -auto-approve
```

Everything except the S3 state bucket destroyed cleanly. The bucket failed as documented in the plan:

```
Error: deleting S3 Bucket (gha-demo-tfstate-123456789012): operation error S3: DeleteBucket,
... api error BucketNotEmpty: The bucket you tried to delete is not empty. You must delete all
versions in the bucket.
```

Versioned buckets keep every historical version plus delete markers; emptying the *current* objects
isn't enough. Purged all versions and delete markers before retrying:

```bash
aws s3api list-object-versions --bucket gha-demo-tfstate-123456789012 --output json > versions.json
jq '{Objects: ([.Versions[]? | {Key, VersionId}] + [.DeleteMarkers[]? | {Key, VersionId}])}' versions.json > purge.json
aws s3api delete-objects --bucket gha-demo-tfstate-123456789012 --delete file://purge.json
```

44 objects/markers purged (27 versions + 17 delete markers — the accumulated history of `infra/`'s
state file and its S3-native lock file across every apply/destroy cycle in this tutorial). Confirmed
empty with `aws s3api list-object-versions`, then:

```bash
terraform destroy -auto-approve
```
```
Destroy complete! Resources: 1 destroyed.
```

### Final verification — the whole account, independently

```bash
aws iam list-open-id-connect-providers                                          # -> []
aws iam list-roles --path-prefix /gha-demo/ --query 'Roles[].RoleName'          # -> []
aws iam list-policies --scope Local --query "Policies[?starts_with(PolicyName, 'gha-demo')].PolicyName"  # -> []
aws s3 ls | grep gha-demo                                                        # -> (no output)
```

All four checks return empty. Every AWS resource created anywhere in this tutorial — OIDC provider,
CI role, permissions boundary, app role, S3/SQS/SNS/DynamoDB/CloudWatch resources, state bucket — has
been destroyed and confirmed gone by direct query, not by trusting Terraform's own report.

---

## Summary

| Phase | Outcome |
|---|---|
| 0 — De-risk validator | Issue #42 reproduced on Terraform 1.16.0; fixed with a `jq` pre-filter |
| 1 — GitHub repo | Created; needed `gh auth refresh -s workflow` before the first workflow-file push |
| 2 — OIDC + CI role | No thumbprint needed; `sub` confirmed to use the new immutable-ID format; real `AssumeRoleWithWebIdentity` proven |
| 3 — Workload + CI perms | 6 resources, 3 real `AccessDenied` iterations, all within the 6-iteration budget |
| 4 — Validator wiring | Found and fixed a second real validator bug (`arnServiceMap` missing `?`); 2 deliberate findings caught and reverted |
| 5 — Workflow | Full plan → 4 gates → apply → verify → destroy; a real `pipefail` bug caught before shipping |
| 6 — Real run | First run failed on a genuine boundary gap (fixed); second run fully green, independently verified |
| 7 — Cleanup | Account confirmed empty by direct query across every resource type touched |

**Real problems found and fixed along the way** (not simulated, all reproduced against live AWS/
GitHub/Terraform): the plan-JSON `identity` crash (issue #42), the `arnServiceMap` missing-`?` crash
(a second, previously undocumented validator bug), the immutable-ID `sub` claim format, a stale
S3-native lock from a killed process, an orphaned IAM principal after a role destroy/recreate, a
permissions boundary blocking the CI role's own `access-analyzer` calls, and a GitHub Actions
`pipefail` footgun in the teardown-verification step.

## References

- [awslabs/terraform-iam-policy-validator](https://github.com/awslabs/terraform-iam-policy-validator) — the validator itself; [issue #42](https://github.com/awslabs/terraform-iam-policy-validator/issues/42) (plan-JSON identity fields)
- [tf-policy-validator on PyPI](https://pypi.org/project/tf-policy-validator/)
- [GitHub: Configuring OpenID Connect in AWS](https://docs.github.com/en/actions/how-tos/secure-your-work/security-harden-deployments/oidc-in-aws)
- [GitHub: OIDC reference](https://docs.github.com/en/actions/reference/security/oidc) (sub claim formats, immutable IDs)
- [AWS: OIDC thumbprint verification](https://docs.aws.amazon.com/IAM/latest/UserGuide/id_roles_providers_create_oidc_verify-thumbprint.html)
- [Terraform: aws_iam_openid_connect_provider](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_openid_connect_provider)
- [aws-actions/configure-aws-credentials](https://github.com/aws-actions/configure-aws-credentials)
- [Terraform: S3 backend, `use_lockfile`](https://developer.hashicorp.com/terraform/language/backend/s3)
