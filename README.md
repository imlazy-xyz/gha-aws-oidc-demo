# GitHub Actions → AWS OIDC, validated with `tf-policy-validator`

A setup guide for authenticating GitHub Actions to AWS with OIDC (no long-lived access keys),
running Terraform from CI, and gating every IAM policy involved with
[`awslabs/terraform-iam-policy-validator`](https://github.com/awslabs/terraform-iam-policy-validator).

Every step here was built and verified against a real AWS account and a real GitHub repo — see
[BUILD_LOG.md](BUILD_LOG.md) for the unabridged debugging journal, including everything that broke
along the way. This document is the clean version: what to do, why, and what you should see.

**What you'll end up with:**
- An IAM OIDC provider trusting `token.actions.githubusercontent.com`
- An IAM role GitHub Actions assumes via OIDC, scoped to one repo and one GitHub *environment*
- A small, free-tier Terraform workload (S3, SQS, SNS, DynamoDB, CloudWatch Logs, an app IAM role)
- A CI workflow that plans, validates, applies, verifies, and destroys that workload on every run
- Four `tf-policy-validator` checks gating the plan before anything is applied

## Contents

1. [Prerequisites](#1-prerequisites)
2. [Repo layout](#2-repo-layout)
3. [Confirm the validator works with your Terraform version](#3-confirm-the-validator-works-with-your-terraform-version)
4. [Create the GitHub repository](#4-create-the-github-repository)
5. [Create the OIDC provider and CI role](#5-create-the-oidc-provider-and-ci-role)
6. [Deploy the workload and scope CI permissions](#6-deploy-the-workload-and-scope-ci-permissions)
7. [Wire up the policy validator](#7-wire-up-the-policy-validator)
8. [The GitHub Actions workflow](#8-the-github-actions-workflow)
9. [Run it](#9-run-it)
10. [Clean up](#10-clean-up)
11. [Troubleshooting](#11-troubleshooting)
12. [References](#12-references)

## 1. Prerequisites

- `aws` CLI, authenticated, pointed at the target account
- `gh` CLI, authenticated, with the `workflow` scope (`gh auth refresh -h github.com -s workflow` if
  you're not sure — see [§11](#11-troubleshooting))
- Terraform ≥ 1.11 (for `use_lockfile` — see [§6](#6-deploy-the-workload-and-scope-ci-permissions))
- `jq`

Built and verified against Terraform 1.16.0, AWS provider 6.62.0, `tf-policy-validator` 0.0.9,
aws-cli 2.27.35, gh 2.99.0. The PyPI package is **`tf-policy-validator`**, not
`terraform-iam-policy-validator` — the latter is only the GitHub repo name and 404s on PyPI.

```bash
python3 -m venv .venv
.venv/bin/pip install tf-policy-validator
```

## 2. Repo layout

```
bootstrap/                   # OIDC provider, CI role, state bucket — applied once, locally
infra/                       # the disposable workload — applied by CI
policy-validator/
  config.yaml                # arnServiceMap for tf-policy-validator (from the tool's own repo)
  reference-policy.json       # approved baseline for check-no-new-access
.github/workflows/terraform.yml
```

`bootstrap/` and `infra/` are separate Terraform configurations with separate state, applied by
different identities (you, and CI, respectively) — that split is deliberate and matters for the
permissions model in [§6](#6-deploy-the-workload-and-scope-ci-permissions).

## 3. Confirm the validator works with your Terraform version

Do this before building anything else. `tf-policy-validator` 0.0.9 has a known issue
([#42](https://github.com/awslabs/terraform-iam-policy-validator/issues/42)) parsing plan JSON from
Terraform 1.12+: newer plans include `identity`/`identity_schema_version` fields on each resource
that the tool's parser doesn't recognize and rejects with an uncaught `ValueError`.

Get the tool's own `arnServiceMap` config — don't hand-write one:

```bash
curl -fsSL https://raw.githubusercontent.com/awslabs/terraform-iam-policy-validator/main/iam_check/config/default.yaml \
  -o policy-validator/config.yaml
```

Take any Terraform config with an IAM policy in it, plan it, and try validating:

```bash
terraform plan -out tf.plan
terraform show -json -no-color tf.plan > tf.json
tf-policy-validator validate --config policy-validator/config.yaml --template-path tf.json --region us-east-1
```

If you're on Terraform 1.12+ you'll likely hit:
```
ValueError: TerraformResource: Invalid parameter: identity_schema_version
```

**Fix**: strip those fields from the plan JSON before handing it to the validator. This becomes a
permanent step in the pipeline, not a one-off workaround:

```bash
jq 'del(.. | .identity?, .identity_schema_version?)' tf.json > tf.clean.json
tf-policy-validator validate --config policy-validator/config.yaml --template-path tf.clean.json --region us-east-1
```

Confirm the validator is actually working (not just failing to crash) by checking it catches
something real — e.g. plan a policy with a deliberately misspelled action like `s3:GetObjectt` and
confirm you get back a blocking `INVALID_ACTION` finding with exit code 2. Delete the throwaway
config once confirmed.

## 4. Create the GitHub repository

```bash
git init
git add .
git commit -m "Initial commit"
gh repo create <owner>/<repo> --public --source=. --remote=origin --push
```

If the push fails with a workflow-scope error once you add `.github/workflows/`, see
[§11](#11-troubleshooting).

## 5. Create the OIDC provider and CI role

`bootstrap/main.tf` is applied **once, locally**, with your own AWS credentials. It creates the OIDC
provider, the CI role GitHub Actions will assume, and the S3 bucket that `infra/`'s Terraform state
will live in. Because it creates that bucket, `bootstrap/` itself must use **local state** — gitignore
`bootstrap/terraform.tfstate`.

### OIDC provider — no thumbprint needed

```hcl
resource "aws_iam_openid_connect_provider" "github" {
  url             = "https://token.actions.githubusercontent.com"
  client_id_list  = ["sts.amazonaws.com"]
  thumbprint_list = []
}
```

Older tutorials hardcode a thumbprint. That's no longer necessary: AWS validates the GitHub OIDC
JWKS endpoint's TLS certificate against its own library of trusted root CAs, and only falls back to
a configured thumbprint if the certificate isn't signed by a trusted CA. ([AWS docs][thumbprint-docs] ·
[Terraform provider docs][tf-oidc-docs])

> Note: even with `thumbprint_list = []`, AWS may auto-populate a thumbprint on creation anyway
> (it's harmless and unused for verification — see [§11](#11-troubleshooting) if `terraform plan`
> shows drift here).

### CI role trust policy — find your exact `sub` claim first

**Don't guess the `sub` format.** GitHub repositories created after **2026-07-15** issue OIDC tokens
with an **immutable-ID** `sub` claim (`repo:OWNER@OWNER-ID/REPO@REPO-ID:...`) instead of the older
`repo:OWNER/REPO:...` form most examples online still show. A trust policy written against the wrong
format will simply never match, with no useful error — `AssumeRoleWithWebIdentity` just fails.

To find your repo's actual `sub`, create a GitHub **environment** first (this also lets you scope
the trust policy to that environment rather than to any branch):

```bash
gh api -X PUT repos/<owner>/<repo>/environments/<env-name>
```

Then run a throwaway workflow step that requests a real token and decodes its JWT payload:

```yaml
permissions:
  id-token: write
jobs:
  debug:
    runs-on: ubuntu-latest
    environment: <env-name>
    steps:
      - run: |
          TOKEN=$(curl -sH "Authorization: bearer $ACTIONS_ID_TOKEN_REQUEST_TOKEN" \
            "$ACTIONS_ID_TOKEN_REQUEST_URL&audience=sts.amazonaws.com" | jq -r .value)
          echo "$TOKEN" | cut -d. -f2 | base64 -d 2>/dev/null | jq '{sub, aud}'
```

This prints the exact `sub` string for your repo — copy it into the trust policy below, then delete
the debug workflow.

```hcl
resource "aws_iam_role" "ci" {
  name                 = "ci-role"
  path                 = "/demo/"
  permissions_boundary = aws_iam_policy.ci_boundary.arn

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Federated = aws_iam_openid_connect_provider.github.arn }
      Action    = "sts:AssumeRoleWithWebIdentity"
      Condition = {
        StringEquals = {
          "token.actions.githubusercontent.com:aud" = "sts.amazonaws.com"
          "token.actions.githubusercontent.com:sub" = "repo:<owner>@<owner-id>/<repo>@<repo-id>:environment:<env-name>"
        }
      }
    }]
  })
}
```

Use `StringEquals` on the exact `sub`, not `StringLike` with a wildcard — a wildcard like
`repo:owner/repo:*` trusts every branch, tag, PR, and environment in the repo, which is broader than
almost any pipeline needs.

Apply, then verify the role actually works before moving on — add
`aws-actions/configure-aws-credentials@v6` and `aws sts get-caller-identity` to the same debug
workflow and confirm you get back an `assumed-role/ci-role/...` ARN.

### Permissions boundary — and why it also applies to the CI role itself

If your CI workload provisions its own IAM role (an "app role" the deployed service assumes), the CI
role needs `iam:CreateRole`/`iam:PutRolePolicy`. Granting that unconditionally would let CI create a
role with *more* privilege than CI itself has — so scope it two ways:

- **Path constraint**: CI's `iam:*` grant only covers `role/demo/*`, not all roles.
- **Permissions boundary**: attach a boundary policy to every role CI creates, capping it to the
  workload's actual services.

**The important, easy-to-miss part**: if you attach that same boundary policy to the **CI role
itself** (`aws_iam_role.ci`'s own `permissions_boundary`, as shown above) — which you should, so CI
can't escalate its own privileges either — then the boundary caps what CI can do *directly*, not just
what it can grant to roles it creates. Any action CI needs (including read-only ones like
`iam:ListPolicies`, or `access-analyzer:ValidatePolicy` for the validator itself) must be granted in
**both** the CI role's identity policy *and* its permissions boundary. Granting it in only one place
produces an `AccessDenied` naming the other as the blocker — read the error message carefully; AWS
tells you which one is missing.

```hcl
resource "aws_iam_policy" "ci_boundary" {
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      { Sid = "WorkloadServices", Effect = "Allow",
        Action = ["s3:*", "sqs:*", "sns:*", "dynamodb:*", "logs:*"], Resource = "*" },
      { Sid = "AccessAnalyzer", Effect = "Allow",
        Action = ["access-analyzer:ValidatePolicy", "access-analyzer:CheckNoNewAccess",
                  "access-analyzer:CheckAccessNotGranted", "access-analyzer:CheckNoPublicAccess"],
        Resource = "*" },
      { Sid = "IamListForLookups", Effect = "Allow", Action = ["iam:ListPolicies"], Resource = "*" },
      { Sid = "IamManageUnderPath", Effect = "Allow",
        Action = ["iam:GetPolicy", "iam:GetPolicyVersion", "iam:GetRole", "iam:CreateRole",
                  "iam:DeleteRole", "iam:UpdateRole", "iam:PutRolePolicy", "iam:GetRolePolicy",
                  "iam:DeleteRolePolicy", "iam:TagRole", "iam:UntagRole", "iam:ListRolePolicies",
                  "iam:ListAttachedRolePolicies", "iam:ListInstanceProfilesForRole"],
        Resource = ["arn:aws:iam::*:role/demo/*", "arn:aws:iam::*:policy/ci-boundary"] }
    ]
  })
}
```

`iam:ListPolicies` needs `Resource: "*"` — it's a list-type action IAM doesn't support scoping to
one ARN.

### State bucket

```hcl
resource "aws_s3_bucket" "tf_state" { bucket = "tfstate-${data.aws_caller_identity.current.account_id}" }
resource "aws_s3_bucket_versioning" "tf_state" { ... status = "Enabled" }
resource "aws_s3_bucket_public_access_block" "tf_state" { ... all four flags true }
resource "aws_s3_bucket_server_side_encryption_configuration" "tf_state" { ... AES256 }
```

Apply `bootstrap/` and note the outputs (`ci_role_arn`, `oidc_provider_arn`, `state_bucket`) — you'll
need them in the workflow and `infra/backend.tf`.

## 6. Deploy the workload and scope CI permissions

`infra/` is the disposable, CI-applied workload. It uses an **S3 backend with `use_lockfile = true`**
— S3-native locking (GA since Terraform 1.11), so no separate DynamoDB lock table is needed:

```hcl
backend "s3" {
  bucket       = "<state-bucket-from-bootstrap>"
  key          = "infra/terraform.tfstate"
  region       = "us-east-1"
  use_lockfile = true
  encrypt      = true
}
```

A workload with real IAM breadth at $0 cost:

| Resource | Why |
|---|---|
| `aws_s3_bucket` + policy | Resource policy — target for `check-no-public-access` |
| `aws_sqs_queue` + policy | Second resource-policy type |
| `aws_sns_topic` + policy | Third resource-policy type |
| `aws_dynamodb_table` (`PAY_PER_REQUEST`) | Identity-policy breadth, $0 at zero traffic |
| `aws_cloudwatch_log_group` (`retention_in_days = 1`) | Identity-policy breadth, $0 at zero ingest |
| `aws_iam_role` + `aws_iam_role_policy` (app role) | Both an identity policy and a trust policy for the validator to analyse |

Look up the boundary policy created in `bootstrap/` by name (separate state, so a data source, not a
reference):

```hcl
data "aws_iam_policy" "ci_boundary" {
  name = "ci-boundary"
}

resource "aws_iam_role" "app" {
  name                 = "app-role"
  path                 = "/demo/"
  permissions_boundary = data.aws_iam_policy.ci_boundary.arn
  assume_role_policy    = jsonencode({ ... Principal = { Service = "lambda.amazonaws.com" } ... })
}
```

### Testing CI's permissions locally before pushing to CI

Round-tripping permission fixes through GitHub Actions is slow (minutes per attempt). Test locally
instead by temporarily assuming the CI role with your own credentials:

```bash
# temporarily add your own user as a second trusted principal on the CI role, then:
CREDS=$(aws sts assume-role --role-arn <ci-role-arn> --role-session-name local-test)
export AWS_ACCESS_KEY_ID=...   # from $CREDS
export AWS_SECRET_ACCESS_KEY=...
export AWS_SESSION_TOKEN=...
cd infra && terraform apply
```

If a permission is missing, Terraform's `AccessDenied` error names the exact action and — per the
boundary note in [§5](#5-create-the-oidc-provider-and-ci-role) — tells you whether the identity
policy or the boundary is the blocker. Add it to the right place, re-apply, repeat. On this workload,
closing every gap took three rounds: `iam:ListPolicies` (for the boundary lookup, needed in *both*
places), then `iam:ListRolePolicies` (a Terraform drift-detection read on the new role) — both now
included in the boundary shown in §5. **Never** resolve a denial by widening to `Action: "*"` or
`Resource: "*"` — the error always names the specific action; grant exactly that.

Remove the temporary trust entry once done — re-applying `bootstrap/` (whose tracked config never
included it) does this automatically.

## 7. Wire up the policy validator

Four subcommands, two different flags for "what counts as blocking" (easy to mix up):

| Subcommand | Blocking-severity flag | Purpose |
|---|---|---|
| `validate` | `--treat-finding-type-as-blocking` | General IAM Access Analyzer policy checks |
| `check-no-new-access` | `--treat-findings-as-non-blocking` (opt *out*) | Diff against an approved baseline policy |
| `check-access-not-granted` | `--treat-findings-as-non-blocking` | Assert specific actions/resources are never granted |
| `check-no-public-access` | `--treat-findings-as-non-blocking` | Assert no resource policy is public |

`--config` and `--region` are required on every subcommand. The config file is an **`arnServiceMap`**
(how to synthesize a fake ARN per resource type for the underlying Access Analyzer calls) — not a
list of actions, despite what the name might suggest.

```bash
tf-policy-validator validate --config policy-validator/config.yaml \
  --template-path infra/tf.clean.json --region us-east-1

tf-policy-validator check-no-new-access --config policy-validator/config.yaml \
  --template-path infra/tf.clean.json --region us-east-1 \
  --reference-policy policy-validator/reference-policy.json --reference-policy-type identity

tf-policy-validator check-access-not-granted --config policy-validator/config.yaml \
  --template-path infra/tf.clean.json --region us-east-1 \
  --actions "iam:CreateUser,iam:PassRole,s3:DeleteBucket"

tf-policy-validator check-no-public-access --config policy-validator/config.yaml \
  --template-path infra/tf.clean.json --region us-east-1
```

`reference-policy.json` should be the app role's identity policy exactly as you intend it — the
approved baseline `check-no-new-access` diffs future plans against.

### If you hit a `KeyError` on `aws_sqs_queue_policy` (or several other resource types)

The `arnServiceMap` config shipped with the tool has a real bug affecting several entries, including
`aws_sqs_queue_policy: fakeQueueUrl`. An entry is only treated as "read this attribute, with a static
fallback" when it contains a `?` (`key?default`); without one, the whole string is read as a literal
attribute name — and `fakeQueueUrl` isn't a real attribute on that resource type, so the lookup
throws an uncaught `KeyError`. Fix locally:

```diff
- aws_sqs_queue_policy: fakeQueueUrl
+ aws_sqs_queue_policy: ?fakeQueueUrl
```

(`aws_codebuild_resource_policy`, `aws_ecr_registry_policy`, `aws_glue_resource_policy`, the four
`aws_kms_*` entries, and `aws_vpc_endpoint` have the same missing `?` — patch them the same way if
your workload touches them.)

### Try it yourself: trigger a real finding

To confirm the gate actually blocks something (not just passes everything), try either of these
against your own workload, then revert:

- Widen an identity-policy statement from scoped actions/resources to `Action = ["s3:*"]`,
  `Resource = "*"` and re-run `check-no-new-access` — expect a blocking `SECURITY_WARNING` with exit
  code 2, naming the specific statement.
- Add a resource-policy statement with `Principal = "*"` and re-run `check-no-public-access` —
  same result, naming the statement that made it public.

## 8. The GitHub Actions workflow

```yaml
name: Terraform (OIDC + policy validator)

on:
  workflow_dispatch:   # applies real resources then destroys them in the same run

permissions:
  id-token: write
  contents: read

jobs:
  terraform:
    runs-on: ubuntu-latest
    environment: <env-name>
    defaults:
      run:
        working-directory: infra

    steps:
      - uses: actions/checkout@v4
      - uses: hashicorp/setup-terraform@v3
        with: { terraform_version: "1.16.0" }

      - uses: aws-actions/configure-aws-credentials@v6
        with:
          role-to-assume: <ci-role-arn>
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

      - run: |
          tf-policy-validator validate --config ../policy-validator/config.yaml \
            --template-path tf.clean.json --region us-east-1 \
            --treat-finding-type-as-blocking ERROR,SECURITY_WARNING
      - run: |
          tf-policy-validator check-no-new-access --config ../policy-validator/config.yaml \
            --template-path tf.clean.json --region us-east-1 \
            --reference-policy ../policy-validator/reference-policy.json --reference-policy-type identity
      - run: |
          tf-policy-validator check-access-not-granted --config ../policy-validator/config.yaml \
            --template-path tf.clean.json --region us-east-1 \
            --actions "iam:CreateUser,iam:PassRole,s3:DeleteBucket"
      - run: |
          tf-policy-validator check-no-public-access --config ../policy-validator/config.yaml \
            --template-path tf.clean.json --region us-east-1

      - run: terraform apply -auto-approve tf.plan

      - name: Verify resources exist
        run: |
          aws s3api head-bucket --bucket "$(terraform output -raw bucket_name)" --no-cli-pager
          aws dynamodb describe-table --table-name "$(terraform output -raw table_name)" \
            --query 'Table.TableStatus' --no-cli-pager

      - run: terraform destroy -auto-approve
        if: always()

      - name: Verify teardown
        if: always()
        run: |
          BUCKET_OUT=$(aws s3api head-bucket --bucket "<app-bucket-name>" --no-cli-pager 2>&1) || true
          echo "$BUCKET_OUT" | grep -q "Not Found" && echo "bucket gone: OK" \
            || { echo "teardown not confirmed: $BUCKET_OUT"; exit 1; }
```

A few choices worth calling out:

- **`workflow_dispatch`, not a push trigger.** This workflow applies real resources and destroys
  them in the same run — appropriate for a manually-triggered demo pipeline, not something you'd
  want firing on every commit.
- **`if: always()` on destroy and teardown-verification** so a failure mid-pipeline (e.g. a
  validator gate blocking) doesn't leave orphaned resources — though if a gate blocks, `apply` never
  ran, so there's nothing to destroy yet either.
- **Capture-then-grep, not pipe-then-grep, for the teardown check.** GitHub Actions runs `bash`
  steps with `-eo pipefail` by default. `aws ... | grep -q "Not Found" && echo ok` fails the whole
  step if the `aws` command itself errors — even when `grep` finds its match — because `pipefail`
  reports the last non-zero exit among *all* pipeline stages, not just the final command. Capture
  output into a variable first, then grep the variable.

Before committing, check every validator flag against `tf-policy-validator <subcommand> --help`
rather than trusting memory — the two flag names (`--treat-finding-type-as-blocking` vs.
`--treat-findings-as-non-blocking`) are easy to transpose.

## 9. Run it

```bash
gh workflow run terraform.yml --repo <owner>/<repo>
gh run watch <run-id> --repo <owner>/<repo> --exit-status
```

You should see every step green: OIDC auth → `terraform plan` → four validator gates → `apply` →
resource verification → `destroy` → teardown verification. A real example run, confirmed working end
to end:
[imlazy-xyz/gha-aws-oidc-demo run 33614042453](https://github.com/imlazy-xyz/gha-aws-oidc-demo/actions/runs/33614042453) —
`Apply complete! Resources: 12 added` followed by `Destroy complete! Resources: 12 destroyed`.

Verify independently afterward, don't just trust the workflow's own report:

```bash
aws sts get-caller-identity   # from inside the job, confirms an assumed-role ARN, not a user
aws s3 ls | grep <workload-prefix>            # -> only your state bucket, nothing from infra/
aws dynamodb list-tables --query 'TableNames' # -> []
aws iam list-roles --path-prefix /demo/ --query 'Roles[].RoleName'  # -> only the CI role
```

## 10. Clean up

`infra/` is destroyed by every workflow run already. What's left is `bootstrap/`:

```bash
cd bootstrap
terraform destroy -auto-approve
```

The state bucket will refuse to delete if it's versioned (it should be) — you must purge every
object version and delete marker first, not just the current objects:

```bash
aws s3api list-object-versions --bucket <state-bucket> --output json > versions.json
jq '{Objects: ([.Versions[]? | {Key, VersionId}] + [.DeleteMarkers[]? | {Key, VersionId}])}' versions.json > purge.json
aws s3api delete-objects --bucket <state-bucket> --delete file://purge.json
terraform destroy -auto-approve
```

Final check, across the whole account, not just what Terraform reports:

```bash
aws iam list-open-id-connect-providers
aws iam list-roles --path-prefix /demo/ --query 'Roles[].RoleName'
aws s3 ls | grep <workload-prefix>
```

All should be empty.

## 11. Troubleshooting

**`gh repo create --push` fails with `Permission denied (publickey)`.** It defaults to the SSH
remote. If your `gh`-authenticated account doesn't have a working SSH key configured for
`github.com`, switch the remote to HTTPS and let `gh`'s own credential helper handle auth:
`git remote set-url origin https://github.com/<owner>/<repo>.git`.

**Push rejected: `refusing to allow an OAuth App to create or update workflow ... without 'workflow'
scope`.** `gh`'s default token doesn't include it. Fix once: `gh auth refresh -h github.com -s
workflow` (interactive device-code flow).

**`aws` CLI commands hang with no output and no error, in a non-interactive shell.** Check
`~/.aws/config` for `output = yaml` (or `table`) — the CLI invokes a pager for those formats, which
waits forever for a keypress with nothing piped to it. Pass `--no-cli-pager` or set `CLI_PAGER=""`.

**A GitHub environment must exist before the first workflow run that references it.** A job with
`environment: <name>` fails to even start — and issues no OIDC token — if that environment hasn't
been created yet (`gh api -X PUT repos/<owner>/<repo>/environments/<name>`).

**`terraform plan`/`apply` fails with `Error acquiring the state lock` /
`PreconditionFailed`.** `use_lockfile` locking (S3-native, no DynamoDB table) doesn't auto-release if
the process holding it is killed (e.g. a CI timeout). Force-unlock: `terraform force-unlock -force
<lock-id>` (from the error message).

**An `aws_s3_bucket_policy`/`aws_sqs_queue_policy`/`aws_sns_topic_policy` shows an IAM principal
that's a raw unique ID (`AROA...`) instead of an ARN, or the provider fails to even *read* the
resource with "invalid principals".** This happens if the IAM role referenced in that policy was ever
destroyed and recreated. AWS resource policies store a referenced IAM principal as its **internal
unique ID**, resolved once at write time — not the ARN text — so deleting and recreating the role
orphans that ID even though the ARN string is unchanged. S3/SQS will show it as plan drift (fixable
with a normal `terraform apply`); SNS's own read can fail outright, blocking the plan before it shows
a diff — in that case, fix the live policy directly with `aws sns set-topic-attributes` first. Prefer
`create_before_destroy` on IAM roles referenced by other resources' policies to avoid this.

**A permissions-boundary error names an action your CI role's identity policy already grants.** See
[§5](#5-create-the-oidc-provider-and-ci-role) — if the boundary is attached to the CI role itself
(not just to roles it creates), the boundary also gates the CI role's own actions. Grant it in both
places.

## 12. References

- [awslabs/terraform-iam-policy-validator](https://github.com/awslabs/terraform-iam-policy-validator) — [issue #42](https://github.com/awslabs/terraform-iam-policy-validator/issues/42) (plan-JSON identity fields)
- [tf-policy-validator on PyPI](https://pypi.org/project/tf-policy-validator/)
- [GitHub: Configuring OpenID Connect in AWS](https://docs.github.com/en/actions/how-tos/secure-your-work/security-harden-deployments/oidc-in-aws)
- [GitHub: OIDC reference](https://docs.github.com/en/actions/reference/security/oidc) (sub claim formats, immutable IDs)
- [AWS: OIDC thumbprint verification][thumbprint-docs]
- [Terraform: `aws_iam_openid_connect_provider`][tf-oidc-docs]
- [aws-actions/configure-aws-credentials](https://github.com/aws-actions/configure-aws-credentials)
- [Terraform: S3 backend, `use_lockfile`](https://developer.hashicorp.com/terraform/language/backend/s3)

[thumbprint-docs]: https://docs.aws.amazon.com/IAM/latest/UserGuide/id_roles_providers_create_oidc_verify-thumbprint.html
[tf-oidc-docs]: https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_openid_connect_provider

---

Built and verified end-to-end against a real AWS account and
[imlazy-xyz/gha-aws-oidc-demo](https://github.com/imlazy-xyz/gha-aws-oidc-demo). The full
debugging journal — every failed attempt, every iteration — is in [BUILD_LOG.md](BUILD_LOG.md).
