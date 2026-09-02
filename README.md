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

*(Tutorial continues below as later phases are implemented and verified.)*
