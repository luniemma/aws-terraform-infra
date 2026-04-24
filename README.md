# terraform-aws-ec2

Opinionated Terraform stack that provisions a production-shaped AWS footprint: a VPC with public and private subnets, one or more EC2 instances (Amazon Linux 2023 by default, SSM + CloudWatch agent pre-installed), and an optional EKS cluster with a managed node group. State is kept locally for quick experiments and can be migrated to a locked S3 backend for real environments.

```
          ┌─────────────────────── VPC (10.0.0.0/16) ──────────────────────┐
          │                                                                 │
IGW ◄─────┤  public subnets (10.0.1.0/24, 10.0.2.0/24)                     │
          │     │                                                           │
          │     ├── EC2 instances (optional EIP)                            │
          │     │                                                           │
          │     └── NAT Gateway ────► private subnets (10.0.11/12.0/24)    │
          │                                 │                               │
          │                                 └── EKS nodes (optional)        │
          └─────────────────────────────────────────────────────────────────┘
```

---

## Table of contents

1. [What you get](#what-you-get)
2. [Repository layout](#repository-layout)
3. [Prerequisites](#prerequisites)
4. [Quick start (local state)](#quick-start-local-state)
5. [Step-by-step walkthrough](#step-by-step-walkthrough)
6. [Remote state on S3 + DynamoDB](#remote-state-on-s3--dynamodb)
7. [Enabling EKS](#enabling-eks)
8. [Variables reference](#variables-reference)
9. [Outputs reference](#outputs-reference)
10. [GitHub Actions deployment](#github-actions-deployment)
11. [Connecting to instances](#connecting-to-instances)
12. [Cost notes](#cost-notes)
13. [Destroying the stack](#destroying-the-stack)
14. [Troubleshooting](#troubleshooting)

---

## What you get

| Component | Details |
|---|---|
| **VPC** | `/16` with configurable public/private `/24` subnets across 2 AZs, IGW, optional NAT GW |
| **EC2** | Launch-template-backed instances, IMDSv2-only, configurable count/type/storage, optional EIP |
| **IAM** | EC2 instance profile with `AmazonSSMManagedInstanceCore` + CloudWatch Agent policy |
| **Observability** | CloudWatch agent for memory/disk metrics + `/var/log/messages` & `cloud-init` log shipping, CPU alarm |
| **Security Group** | Port 22 open only to `allowed_ssh_cidrs` (leave empty to disable SSH and use SSM) |
| **EKS (optional)** | Managed control plane + managed node group in private subnets, OIDC provider for IRSA |
| **Bootstrap module** | Separate stack to create a versioned/encrypted S3 state bucket + DynamoDB lock table |

---

## Repository layout

```
terraform-aws-ec2/
├── main.tf                  # Root module — wires VPC / EC2 / EKS together
├── variables.tf             # Root-level inputs
├── outputs.tf               # Root-level outputs
├── userdata.sh              # EC2 bootstrap: SSM, CloudWatch agent, hostname
├── terraform.tfvars.example # Copy → terraform.tfvars for local runs
├── environments/            # Per-env variable files consumed by CI
│   ├── dev.tfvars
│   ├── staging.tfvars
│   └── prod.tfvars
├── backend/
│   └── main.tf              # One-time bootstrap for S3 + DynamoDB backend
├── modules/
│   ├── vpc/                 # VPC, subnets, IGW, NAT, route tables
│   ├── ec2/                 # Launch template, instances, SG, IAM, alarms
│   └── eks/                 # EKS cluster + managed node group + OIDC
└── .github/
    ├── actions/terraform-deploy/  # Reusable composite action
    └── workflows/terraform.yml    # validate → scan → plan → apply pipeline
```

---

## Prerequisites

- **Terraform** `>= 1.5.0` ([install](https://developer.hashicorp.com/terraform/install))
- **AWS CLI v2** configured (`aws configure` or `aws sso login`)
- An **AWS account** with permission to create VPC, EC2, IAM, CloudWatch, and (optionally) EKS resources
- An **SSH public key** if you plan to SSH in (not needed when using SSM Session Manager)
- **kubectl** and **aws-iam-authenticator** only if you enable EKS

Confirm you're authenticated:

```bash
aws sts get-caller-identity
```

---

## Quick start (local state)

```bash
# 1. Clone and enter the repo
git clone <your-fork-url> terraform-aws-ec2
cd terraform-aws-ec2

# 2. Create your variables file
cp terraform.tfvars.example terraform.tfvars
$EDITOR terraform.tfvars          # set project_name, allowed_ssh_cidrs, etc.

# 3. Init, plan, apply
terraform init
terraform plan  -out=tfplan
terraform apply tfplan

# 4. Inspect outputs
terraform output
```

That's the minimum. Everything below is either a richer explanation of these four commands or an optional hardening step (remote state, EKS, CI/CD).

---

## Step-by-step walkthrough

### Step 1 — Configure AWS credentials

Pick one:

```bash
# Static keys (quickest, least secure)
aws configure

# SSO (recommended for teams)
aws configure sso
aws sso login --profile my-sso-profile
export AWS_PROFILE=my-sso-profile
```

Verify:

```bash
aws sts get-caller-identity
```

### Step 2 — Copy the example tfvars

```bash
cp terraform.tfvars.example terraform.tfvars
```

Edit [terraform.tfvars](terraform.tfvars). At minimum:

- `project_name` — prefix for every resource name
- `environment` — must be `dev`, `staging`, or `prod`
- `allowed_ssh_cidrs` — `["<your-public-ip>/32"]` or `[]` to disable SSH
- `public_key_path` — path to the SSH public key to import, or `""` to skip

> `terraform.tfvars` is git-ignored ([.gitignore:11](.gitignore#L11)). Never commit it.

### Step 3 — Initialize

```bash
terraform init
```

This downloads the `hashicorp/aws` and `hashicorp/tls` providers and wires up the child modules under [modules/](modules/).

### Step 4 — Plan

```bash
terraform plan -out=tfplan
```

Review the plan. For the default settings you should see ~20–30 resources: VPC, 2 public subnets, 2 private subnets, route tables, IGW, SG, launch template, 1 EC2 instance, IAM role + profile, CloudWatch alarm + log group, optional key pair.

### Step 5 — Apply

```bash
terraform apply tfplan
```

Typical wall-clock time:

- VPC + EC2 only: **1–3 minutes**
- With EKS: **10–15 minutes** (control plane is slow)

### Step 6 — Read the outputs

```bash
terraform output
terraform output -raw ssh_commands     # prints ready-to-run SSH lines
terraform output instance_public_ips
```

---

## Remote state on S3 + DynamoDB

Local state is fine for one person; for teams use the bundled bootstrap to create a locked, versioned, encrypted backend.

### Step A — Bootstrap the backend resources

```bash
cd backend
terraform init
terraform apply \
  -var "aws_region=us-east-1" \
  -var "project_name=myapp" \
  -var "environment=dev"
```

Take note of the outputs:

```
s3_bucket_name      = "myapp-dev-tfstate-123456789012"
dynamodb_table_name = "myapp-dev-tflock"
```

The bucket is created with `prevent_destroy = true` ([backend/main.tf:50](backend/main.tf#L50)) so you can't accidentally `terraform destroy` it.

### Step B — Uncomment the root backend block

In [main.tf:10-16](main.tf#L10-L16) uncomment:

```hcl
backend "s3" {
  bucket         = "myapp-dev-tfstate-123456789012"
  key            = "terraform.tfstate"
  region         = "us-east-1"
  dynamodb_table = "myapp-dev-tflock"
  encrypt        = true
}
```

### Step C — Migrate existing state

```bash
cd ..                          # back to repo root
terraform init -migrate-state  # prompts yes to copy local → S3
```

Delete the now-empty local state files:

```bash
rm terraform.tfstate terraform.tfstate.backup
```

From this point on, `plan` and `apply` read and write state through S3 with DynamoDB locking.

---

## Enabling EKS

EKS is off by default (`enable_eks = false`). To turn it on, add to [terraform.tfvars](terraform.tfvars):

```hcl
enable_eks              = true
enable_nat_gateway      = true     # forced on when enable_eks=true, but be explicit
eks_cluster_version     = "1.31"
eks_node_instance_types = ["t3.medium"]
eks_node_desired_size   = 2
eks_node_min_size       = 1
eks_node_max_size       = 4
```

Apply, then hook up `kubectl`:

```bash
terraform apply
eval "$(terraform output -raw eks_kubeconfig_command)"
kubectl get nodes
```

> NAT Gateway + EKS control plane + 2× `t3.medium` nodes runs around **USD $100–150 / month**. Don't leave it on.

---

## Variables reference

Full list lives in [variables.tf](variables.tf). Highlights:

### General

| Name | Default | Notes |
|---|---|---|
| `aws_region` | `us-east-1` | Any region supported by the AWS provider |
| `project_name` | `web` | Prefixed onto every resource name |
| `environment` | `dev` | Must be `dev`, `staging`, or `prod` |

### Network

| Name | Default | Notes |
|---|---|---|
| `vpc_cidr` | `10.0.0.0/16` | |
| `public_subnet_cidrs` | `["10.0.1.0/24","10.0.2.0/24"]` | One per AZ |
| `private_subnet_cidrs` | `["10.0.11.0/24","10.0.12.0/24"]` | One per AZ |
| `enable_nat_gateway` | `false` | Forced `true` when `enable_eks = true` |

### EC2

| Name | Default | Notes |
|---|---|---|
| `instance_type` | `t3.micro` | |
| `ami_id` | `""` | Empty → latest Amazon Linux 2023 |
| `instance_count` | `1` | 1–10 |
| `ec2_in_public_subnet` | `true` | `false` routes via NAT |
| `assign_eip` | `false` | Stable public IP |
| `allowed_ssh_cidrs` | `[]` | Empty disables SSH (use SSM instead) |
| `public_key_path` | `""` | Empty skips key pair creation |

### Storage / Monitoring

| Name | Default | Notes |
|---|---|---|
| `root_volume_size` | `30` | GB |
| `root_volume_type` | `gp3` | |
| `additional_ebs_volumes` | `[]` | List of `{device_name, volume_size, volume_type}` |
| `enable_detailed_monitoring` | `false` | 1-minute CloudWatch (extra cost) |
| `cpu_alarm_threshold` | `80` | CPU% that triggers the alarm |
| `alarm_sns_topic_arn` | `""` | Optional SNS target for the alarm |

### EKS (only when `enable_eks = true`)

| Name | Default |
|---|---|
| `eks_cluster_version` | `1.31` |
| `eks_cluster_endpoint_private_access` | `true` |
| `eks_cluster_endpoint_public_access` | `true` |
| `eks_cluster_log_types` | `["api","audit","authenticator"]` |
| `eks_node_instance_types` | `["t3.medium"]` |
| `eks_node_capacity_type` | `ON_DEMAND` |
| `eks_node_disk_size` | `50` |
| `eks_node_desired_size` / `min_size` / `max_size` | `2` / `1` / `4` |

---

## Outputs reference

Defined in [outputs.tf](outputs.tf). The ones you'll reach for most:

| Output | What it is |
|---|---|
| `instance_public_ips` / `instance_private_ips` | IPs of each EC2 instance |
| `instance_public_dns` | Public DNS names |
| `elastic_ips` | EIPs when `assign_eip = true` |
| `ssh_commands` | Ready-to-paste `ssh ec2-user@…` lines |
| `ec2_iam_role_arn` | Attach extra policies here |
| `vpc_id`, `public_subnet_ids`, `private_subnet_ids` | For wiring in other stacks |
| `eks_cluster_name`, `eks_cluster_endpoint`, `eks_kubeconfig_command` | Only populated when EKS is enabled |

Usage examples:

```bash
terraform output -raw ssh_commands
terraform output -json instance_public_ips | jq -r '.[]'
```

---

## GitHub Actions deployment

This repo ships with a reusable composite action at [.github/actions/terraform-deploy/action.yml](.github/actions/terraform-deploy/action.yml) and a pipeline workflow at [.github/workflows/terraform.yml](.github/workflows/terraform.yml).

### Pipeline shape

```
   config ──► validate ──┐
            └► scan      ├─► plan ──► apply (only on push or manual apply)
                         │              ▲
                         │              └── consumes the plan artifact — never re-plans
                         │
   PR comment (upsert) ◄─┘
```

**Triggers**

| Event | Environment | Stages that run |
|---|---|---|
| PR to `main` | `dev` | validate, scan, plan (comments on PR) |
| Push to `main` | `dev` | validate, scan, plan, apply |
| `workflow_dispatch` | `dev` / `staging` / `prod` (pick) | validate, scan, plan, apply (if selected) |

### Best-practice features baked in

- **OIDC, no long-lived keys** — role assumed via `aws-actions/configure-aws-credentials`; session name includes `run_id` for CloudTrail tracing.
- **Deny-by-default `permissions: {}`** at workflow scope; each job re-requests exactly what it needs.
- **Per-environment concurrency group** — two applies to the same env queue instead of racing the state lock. PR plans cancel in progress on new pushes.
- **Plan → apply artifact hand-off** — apply runs `terraform apply tfplan.binary`, never re-plans. Zero drift between preview and deploy.
- **Per-environment state key** — `key=<env>/terraform.tfstate` so one bucket holds all envs safely.
- **GitHub Environments as the approval gate** — attach required reviewers to `prod` and apply blocks on approval automatically.
- **Workspaces match environments** — `dev`, `staging`, `prod` mapped 1:1; `environments/<env>.tfvars` is auto-selected.
- **tfsec security scan** uploaded as SARIF (non-blocking by default).
- **Upsert PR comment** — replaces the previous bot comment on each push so PRs don't fill up.
- **`TF_IN_AUTOMATION=1`, `TF_INPUT=0`, `TF_CLI_ARGS=-no-color`** at workflow scope — no interactive prompts, no ANSI noise.
- **Provider + module cache** keyed by `.terraform.lock.hcl` for faster init.
- **No script-injection sinks** — user-controlled inputs flow through `env:` blocks, never inline into `run:` scripts.
- **`persist-credentials: false`** on every checkout so the `GITHUB_TOKEN` isn't left on disk.

### Setup checklist

1. **Finish the [remote state section](#remote-state-on-s3--dynamodb)** — CI can't share local state.
2. **Create an OIDC-trusted IAM role.** Trust policy (replace `OWNER/REPO` and account ID):

   ```json
   {
     "Version": "2012-10-17",
     "Statement": [{
       "Effect": "Allow",
       "Principal": { "Federated": "arn:aws:iam::<ACCOUNT_ID>:oidc-provider/token.actions.githubusercontent.com" },
       "Action": "sts:AssumeRoleWithWebIdentity",
       "Condition": {
         "StringEquals": { "token.actions.githubusercontent.com:aud": "sts.amazonaws.com" },
         "StringLike":   { "token.actions.githubusercontent.com:sub": "repo:OWNER/REPO:*" }
       }
     }]
   }
   ```

   Attach whatever policy lets Terraform manage VPC/EC2/IAM/EKS. Start from AWS-managed policies (`AmazonEC2FullAccess`, `AmazonVPCFullAccess`, `IAMFullAccess`) for experimentation, then tighten.

3. **Create three GitHub Environments** — `dev`, `staging`, `prod` (Settings → Environments).
   - On `prod` (and optionally `staging`), add **required reviewers** so apply pauses for manual approval.
   - Per-Environment variables override repo-level variables, so each env can have its own role / bucket / region.

4. **Set these Variables** at repo scope or per-Environment (Settings → Secrets and variables → Actions → Variables):

   | Name | Example | Required | Scope |
   |---|---|---|---|
   | `AWS_REGION` | `us-east-1` | ✅ | repo or env |
   | `AWS_ROLE_ARN` | `arn:aws:iam::123456789012:role/github-actions-terraform` | ✅ | **env** (one role per env) |
   | `TF_STATE_BUCKET` | `myapp-tfstate-123456789012` | ✅ | repo |
   | `TF_LOCK_TABLE` | `myapp-tflock` | ✅ | repo |
   | `TERRAFORM_VERSION` | `1.9.8` | optional | repo (override default) |
   | `RUNNER_IMAGE` | `ubuntu-latest` | optional | repo (e.g. self-hosted label) |

5. **Keep `environments/<env>.tfvars` in sync** with what you actually want deployed — the workflow selects the file matching the target environment.

6. **Harden the action pins.** The composite action pins third-party actions to major-version tags for readability. For production, swap each `@v4`/`@v3` for a full commit SHA — see [GitHub's hardening guide](https://docs.github.com/en/actions/security-guides/security-hardening-for-github-actions#using-third-party-actions).

7. **Push a PR.** The workflow will plan against `dev` and upsert a comment.

### Consuming the composite action from another repo

```yaml
- uses: OWNER/REPO/.github/actions/terraform-deploy@<sha>
  with:
    working-directory: infra/
    aws-region: us-east-1
    aws-role-to-assume: arn:aws:iam::123456789012:role/github-actions-terraform
    action: apply
    var-file: environments/dev.tfvars
    workspace: dev
    backend-config: |
      bucket=myapp-tfstate-123456789012
      key=dev/terraform.tfstate
      region=us-east-1
      dynamodb_table=myapp-tflock
      encrypt=true
```

### Action inputs

Full schema in [.github/actions/terraform-deploy/action.yml](.github/actions/terraform-deploy/action.yml). Most-used inputs:

| Input | Required | Notes |
|---|---|---|
| `aws-region` | ✅ | |
| `aws-role-to-assume` | ✅ | OIDC role ARN |
| `working-directory` | | Defaults to `.` |
| `terraform-version` | | Exact version, defaults to `1.9.8` |
| `action` | | `plan` (default) or `apply` |
| `var-file` | | Path relative to `working-directory` |
| `backend-config` | | Multiline `key=value`, one per line |
| `workspace` | | Selected or created on init |
| `download-plan-artifact` | | When `action=apply`, download this artifact instead of re-planning |
| `plan-artifact-name` | | Name used when uploading on plan runs |
| `fail-on-format` | | `"false"` to warn instead of fail on fmt diffs |

---

## Connecting to instances

### Option 1 — SSM Session Manager (recommended)

No SSH keys, no open ports. The instance profile already attaches `AmazonSSMManagedInstanceCore`, and the SSM agent is enabled in [userdata.sh:19-20](userdata.sh#L19-L20).

```bash
aws ssm start-session --target "$(terraform output -raw instance_ids | jq -r '.[0]')"
```

### Option 2 — SSH

Requires `public_key_path` set, `allowed_ssh_cidrs` populated, and (usually) `ec2_in_public_subnet = true`.

```bash
terraform output -raw ssh_commands
# then paste the printed command
```

---

## Cost notes

Rough USD / month in `us-east-1`, on-demand pricing:

| Config | Estimate |
|---|---|
| 1× `t3.micro` + VPC, no NAT | **free-tier-eligible**; otherwise ~$8 |
| 1× `t3.micro` + NAT Gateway | ~$40 (NAT is $0.045/h + data) |
| EKS control plane | **$73** flat |
| 2× `t3.medium` nodes | **$60** |
| S3 state bucket + DynamoDB | **<$1** |

The NAT Gateway and the EKS control plane are the line items that hurt. Turn them off when you're done experimenting.

---

## Destroying the stack

```bash
terraform destroy
```

If you bootstrapped the S3 backend and want to remove it too, you must first:

1. Run `terraform destroy` in the root to empty the state.
2. Migrate state back to local: comment out the backend block in [main.tf](main.tf) and run `terraform init -migrate-state`.
3. Temporarily remove `prevent_destroy = true` from [backend/main.tf:50](backend/main.tf#L50).
4. Empty the bucket (versioned objects included):
   ```bash
   aws s3api delete-objects --bucket <bucket> \
     --delete "$(aws s3api list-object-versions --bucket <bucket> --output json \
                 | jq '{Objects: [.Versions[], .DeleteMarkers[]] | map({Key, VersionId})}')"
   ```
5. `cd backend && terraform destroy`.

---

## Troubleshooting

**`Error: InvalidKeyPair.Duplicate`** — you're re-applying with the same `project_name`/`environment` but the key pair already exists. Either import it (`terraform import module.ec2.aws_key_pair.this ...`) or change the name.

**`Error: Unsupported argument "public_key_path"`** in the EC2 module — make sure you pulled the latest [modules/ec2/](modules/ec2/); older copies used a different name.

**`terraform plan` shows "Backend reinitialization required"** — run `terraform init -reconfigure` after changing the backend block.

**EKS nodes stuck in `NotReady`** — almost always missing NAT egress. Check that `enable_nat_gateway = true` (it's forced when `enable_eks = true` via [main.tf:54](main.tf#L54) but verify the NAT actually provisioned).

**GitHub Actions: `Error: Could not assume role with OIDC`** — the role's trust policy `sub` condition doesn't match the repo/branch. Check the exact string GitHub sends by looking at the failed run's "Configure AWS credentials" step; it prints the token subject.

**CloudWatch alarm stays in `INSUFFICIENT_DATA`** — metrics take ~5 minutes to appear on a fresh instance, and `mem_used_percent` / `disk_used_percent` require the CloudWatch agent, which runs as part of user-data. Check `/var/log/cloud-init-output.log` on the instance.

---

## License

Use, fork, modify — no attribution required.
