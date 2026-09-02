# GitHub Actions → AWS OIDC, validated with `tf-policy-validator`

A hands-on, verified walkthrough of authenticating GitHub Actions to AWS via OIDC (no long-lived
access keys), running Terraform from CI, and gating the IAM policies involved with
[`awslabs/terraform-iam-policy-validator`](https://github.com/awslabs/terraform-iam-policy-validator).

Every command below was actually run against a real AWS account and a real GitHub repo. Where
something failed, the failure and the fix are recorded rather than smoothed over.

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

*(Tutorial continues below as later phases are implemented and verified.)*
