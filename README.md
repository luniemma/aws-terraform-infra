# aws-terraform-infra

Opinionated Terraform stack that provisions a production-shaped AWS footprint: a VPC with public and private subnets, one or more EC2 instances (Amazon Linux 2023 by default, SSM + CloudWatch agent pre-installed), and a **single shared EKS cluster** (provisioned by the dedicated `platform` stack) that hosts every app environment as a separate Kubernetes namespace. State is kept locally for quick experiments and can be migrated to a locked S3 backend for real environments.

> **Topology:** one cluster, namespace per env. `environments/platform.tfvars` owns the cluster (`codeplex-eks`); `dev.tfvars`, `staging.tfvars`, `prod.tfvars` provision per-env VPC + EC2 only (`enable_eks=false`). App workloads land in `codeplex-dev`, `codeplex-qa`, `codeplex-staging`, `codeplex-prod` namespaces inside the shared cluster. After a successful `apply` on the `platform` stack, the workflow fires a `repository_dispatch` at the app repo so the app deploys automatically into the `dev` namespace — see [Triggering app deploy after cluster apply](#triggering-app-deploy-after-cluster-apply).

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
7. [The platform stack (shared EKS cluster)](#the-platform-stack-shared-eks-cluster)
   - [Triggering app deploy after cluster apply](#triggering-app-deploy-after-cluster-apply)
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
| **EKS (shared cluster)** | One `codeplex-eks` cluster owned by the `platform` stack; managed control plane + managed node group in private subnets, OIDC provider for IRSA. App envs are k8s namespaces inside this cluster — `codeplex-dev`, `codeplex-qa`, `codeplex-staging`, `codeplex-prod`. |
| **Bootstrap module** | Separate stack to create a versioned/encrypted S3 state bucket + DynamoDB lock table |

---

## Repository layout

```
aws-terraform-infra/
├── main.tf                  # Root module — wires VPC / EC2 / EKS together
├── variables.tf             # Root-level inputs
├── outputs.tf               # Root-level outputs
├── userdata.sh              # EC2 bootstrap: SSM, CloudWatch agent, hostname
├── terraform.tfvars.example # Copy → terraform.tfvars for local runs
├── environments/            # Per-env variable files consumed by CI
│   ├── platform.tfvars      # Owns the SHARED EKS cluster (enable_eks=true here only)
│   ├── dev.tfvars           # VPC + EC2 only; enable_eks=false
│   ├── staging.tfvars       # VPC + EC2 only; enable_eks=false
│   └── prod.tfvars          # VPC + EC2 only; enable_eks=false
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
git clone <your-fork-url> aws-terraform-infra
cd aws-terraform-infra

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

## The platform stack (shared EKS cluster)

EKS lives in a dedicated stack — [environments/platform.tfvars](environments/platform.tfvars) — so a single `codeplex-eks` cluster is shared across every app environment. Per-env stacks (`dev`, `staging`, `prod`) only manage VPC + EC2 and keep `enable_eks = false`.

Why split it out:

- **One control plane to pay for.** The cluster is the most expensive line item; running one shared cluster instead of three saves ~$150/month versus a per-env cluster topology.
- **Independent lifecycle.** You can rebuild a per-env VPC without touching the cluster, and upgrade the cluster's Kubernetes version without rolling any per-env state.
- **Soft isolation via namespaces.** App envs land in `codeplex-dev`, `codeplex-qa`, `codeplex-staging`, `codeplex-prod` — same cluster, different namespaces. Layer on `ResourceQuotas`, dedicated node groups for prod (taints + tolerations), and `NetworkPolicies` if non-prod noisy-neighbour risk to prod is a concern.

### Provisioning the cluster

Locally:

```bash
terraform init
terraform workspace select platform || terraform workspace new platform
terraform apply -var-file=environments/platform.tfvars
eval "$(terraform output -raw eks_kubeconfig_command)"
kubectl get nodes
```

Or via CI: trigger [terraform.yml](.github/workflows/terraform.yml) with `workflow_dispatch` and pick `environment: platform`, `action: apply`.

### Triggering app deploy after cluster apply

After a successful `apply` on the `platform` env, a follow-up job in the workflow (`trigger_app_deploy`) fires a `repository_dispatch` at the app repo with `event-type: deploy-app` and `client_payload.environment: dev`. The app repo's `deploy.yml` accepts that dispatch and runs a Helm deploy into the `codeplex-dev` namespace on the shared cluster — so a fresh cluster comes up with the app already running.

To enable that dispatch, add **two** values to this repo's settings (Settings → Secrets and variables → Actions):

| Kind | Name | Example | Purpose |
|---|---|---|---|
| Variable | `APP_REPO` | `luniemma/codeplex-application-ai-systhem` | `owner/name` of the app repo |
| Secret | `APP_REPO_TOKEN` | `<fine-grained PAT>` | PAT scoped to `APP_REPO` with `contents: write` (only used to call `POST /repos/.../dispatches`) |

If either is unset, the dispatch step no-ops with a clear notice — the cluster apply still succeeds, you'd just have to deploy the app manually.

Higher environments (`qa`, `staging`, `prod`) intentionally do **not** auto-deploy — the app repo's `dispatch_validate` job rejects anything but `dev`, so promotions must go through the app repo's own `workflow_dispatch` with required-reviewer gates on the `qa` / `staging` / `prod` GitHub Environments.

> NAT Gateway + EKS control plane + 2× `t3.medium` nodes runs around **USD $100–150 / month**. The platform stack is the one to destroy first when you're done experimenting.

---

## Variables reference

Full list lives in [variables.tf](variables.tf). Highlights:

### General

| Name | Default | Notes |
|---|---|---|
| `aws_region` | `us-east-1` | Any region supported by the AWS provider |
| `project_name` | `web` | Prefixed onto every resource name |
| `environment` | `dev` | Must be `dev`, `staging`, `prod`, or `platform` (the shared-cluster stack) |

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

### EKS (only used by the `platform` stack — `enable_eks = true`)

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
| PR to `main` / `master` | `dev` | validate, scan, plan (comments on PR) |
| Push to `main` / `master` | `dev` | validate, scan, plan, apply |
| `workflow_dispatch` | `dev` / `staging` / `prod` / `platform` (pick) | validate, scan, plan, apply/destroy (if selected) |
| `workflow_dispatch` → `platform` apply | `platform` | + `trigger_app_deploy` job dispatches `deploy-app` to `APP_REPO` (no-op if `APP_REPO`/`APP_REPO_TOKEN` are unset) |

### Best-practice features baked in

- **OIDC, no long-lived keys** — role assumed via `aws-actions/configure-aws-credentials`; session name includes `run_id` for CloudTrail tracing.
- **Deny-by-default `permissions: {}`** at workflow scope; each job re-requests exactly what it needs.
- **Per-environment concurrency group** — two applies to the same env queue instead of racing the state lock. PR plans cancel in progress on new pushes.
- **Plan → apply artifact hand-off** — apply runs `terraform apply tfplan.binary`, never re-plans. Zero drift between preview and deploy.
- **Per-environment state key** — `key=<env>/terraform.tfstate` so one bucket holds all envs safely.
- **GitHub Environments as the approval gate** — attach required reviewers to `prod` and apply blocks on approval automatically.
- **Workspaces match environments** — `dev`, `staging`, `prod` mapped 1:1; `environments/<env>.tfvars` is auto-selected.
- **tfsec security scan** installed directly from GitHub releases (no third-party action tag drift); uploaded as SARIF (non-blocking by default). Pin with optional repo variable `TFSEC_VERSION`.
- **Destroy action with typed confirmation** — `workflow_dispatch` only; requires typing `destroy <env>` to match the selected environment. Same plan→artifact→apply flow as a regular deploy, so reviewers see exactly what will be removed before apply runs.
- **Upsert PR comment** — replaces the previous bot comment on each push so PRs don't fill up.
- **`TF_IN_AUTOMATION=1`, `TF_INPUT=0`, `TF_CLI_ARGS=-no-color`** at workflow scope — no interactive prompts, no ANSI noise.
- **Per-workspace provider + module cache** keyed on `terraform-version + workspace + hash(.terraform.lock.hcl, **/*.tf)`. Scoping by workspace prevents `.terraform/` from a `dev` run contaminating a `staging` init.
- **`terraform init -reconfigure`** — CI never migrates state; it always reinitialises fresh against the backend-config for the current run. Defends against any stale backend init fingerprint in the cache.
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

3. **Create four GitHub Environments** — `dev`, `staging`, `prod`, `platform` (Settings → Environments).
   - On `prod` and `platform` (and optionally `staging`), add **required reviewers** so apply pauses for manual approval. `platform` provisions the shared cluster, so treat it like prod.
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
   | `TFSEC_VERSION` | `latest` | optional | repo (e.g. `v1.28.6` to pin) |
   | `APP_REPO` | `luniemma/codeplex-application-ai-systhem` | optional | repo (enables app auto-deploy after `platform` apply) |

   And **one secret**:

   | Name | Example | Required | Scope |
   |---|---|---|---|
   | `APP_REPO_TOKEN` | fine-grained PAT, `contents: write` on `APP_REPO` only | optional | repo (paired with `APP_REPO`) |

5. **Keep `environments/<env>.tfvars` in sync** with what you actually want deployed — the workflow selects the file matching the target environment.

6. **Harden the action pins.** The composite action pins third-party actions to major-version tags for readability. For production, swap each `@v4`/`@v3` for a full commit SHA — see [GitHub's hardening guide](https://docs.github.com/en/actions/security-guides/security-hardening-for-github-actions#using-third-party-actions).

7. **Push a PR.** The workflow will plan against `dev` and upsert a comment.

### Bootstrap with `gh` and `aws` CLIs

End-to-end commands for the OIDC trust, IAM role, GitHub Environments, and variables described in the [Setup checklist](#setup-checklist). With OIDC there are **no AWS access keys** stored in GitHub — only an IAM role ARN, which lives in `gh variable` (not `gh secret`).

#### 0. Prereqs and shell variables

```bash
gh auth login                                    # authenticate the GitHub CLI (needs `repo` + `workflow` scopes)
gh auth status                                   # confirm scopes
aws sts get-caller-identity                      # confirm AWS creds with IAM permissions

export AWS_ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
export AWS_REGION=us-east-1
export GH_REPO=OWNER/REPO                        # e.g. luniemma/aws-terraform-infra
export PROJECT=myapp
export ROLE_NAME=github-actions-terraform
```

#### 1. Create the GitHub OIDC provider in AWS (once per AWS account)

GitHub mints OIDC ID tokens for each workflow run; AWS STS exchanges them for temporary credentials. The provider is the trust anchor for that exchange. Skip this if `aws iam list-open-id-connect-providers` already shows `token.actions.githubusercontent.com`.

```bash
aws iam create-open-id-connect-provider \
  --url https://token.actions.githubusercontent.com \
  --client-id-list sts.amazonaws.com \
  --thumbprint-list 6938fd4d98bab03faadb97b34396831e3780aea1
```

> AWS now verifies the full TLS chain, so the thumbprint is essentially advisory — the value above is GitHub's published root. `EntityAlreadyExists` is fine: you only need one per account.

#### 2. Create the IAM role Terraform will assume

The `sub` condition restricts the role to *this* repo. To narrow further (e.g., one role usable only from the `prod` environment), change the pattern — see [GitHub's OIDC token docs](https://docs.github.com/en/actions/deployment/security-hardening-your-deployments/about-security-hardening-with-openid-connect#understanding-the-oidc-token).

```bash
cat > /tmp/trust.json <<EOF
{
  "Version": "2012-10-17",
  "Statement": [{
    "Effect": "Allow",
    "Principal": { "Federated": "arn:aws:iam::${AWS_ACCOUNT_ID}:oidc-provider/token.actions.githubusercontent.com" },
    "Action": "sts:AssumeRoleWithWebIdentity",
    "Condition": {
      "StringEquals": { "token.actions.githubusercontent.com:aud": "sts.amazonaws.com" },
      "StringLike":   { "token.actions.githubusercontent.com:sub": "repo:${GH_REPO}:*" }
    }
  }]
}
EOF

aws iam create-role \
  --role-name "${ROLE_NAME}" \
  --assume-role-policy-document file:///tmp/trust.json
```

Attach a permission policy. The bundled [gha-terraform-policy.json](gha-terraform-policy.json) covers the VPC/EC2/IAM/CloudWatch + state-bucket actions Terraform calls in this repo:

```bash
aws iam put-role-policy \
  --role-name "${ROLE_NAME}" \
  --policy-name terraform-deploy \
  --policy-document file://gha-terraform-policy.json

export AWS_ROLE_ARN=$(aws iam get-role --role-name "${ROLE_NAME}" --query Role.Arn --output text)
echo "$AWS_ROLE_ARN"
```

For quick experimentation, the AWS-managed broad policies work too:

```bash
for p in AmazonEC2FullAccess AmazonVPCFullAccess IAMFullAccess; do
  aws iam attach-role-policy --role-name "${ROLE_NAME}" \
    --policy-arn "arn:aws:iam::aws:policy/${p}"
done
```

For real environments, create one role per env (`github-actions-terraform-dev`, `…-staging`, `…-prod`) and tighten the trust policy's `sub` condition per env, e.g. `repo:${GH_REPO}:environment:prod`.

#### 3. Create the three GitHub Environments

There's no first-class `gh environment` subcommand, so we drive the REST API:

```bash
for env in dev staging prod; do
  gh api -X PUT "repos/${GH_REPO}/environments/${env}"
done
```

Add required reviewers on `prod` so apply pauses for human approval. Get the reviewer's numeric ID first (`gh api users/<login> --jq .id`), then:

```bash
cat <<EOF | gh api -X PUT "repos/${GH_REPO}/environments/prod" --input -
{
  "wait_timer": 0,
  "prevent_self_review": true,
  "reviewers": [
    { "type": "User", "id": <USER_ID> }
  ]
}
EOF
```

Use `"type": "Team"` and the team ID instead to gate by team.

#### 4. Set repo-level variables (shared across envs)

```bash
gh variable set AWS_REGION        --repo "${GH_REPO}" --body "${AWS_REGION}"
gh variable set TF_STATE_BUCKET   --repo "${GH_REPO}" --body "${PROJECT}-tfstate-${AWS_ACCOUNT_ID}"
gh variable set TF_LOCK_TABLE     --repo "${GH_REPO}" --body "${PROJECT}-tflock"
gh variable set TERRAFORM_VERSION --repo "${GH_REPO}" --body "1.9.8"   # optional override
```

Confirm: `gh variable list --repo "${GH_REPO}"`.

#### 5. Set per-environment variables (one role ARN per env)

Per-env values override repo-level ones, so each env can also pin its own region or state bucket if envs live in separate AWS accounts.

```bash
gh variable set AWS_ROLE_ARN --repo "${GH_REPO}" --env dev     --body "<dev-role-arn>"
gh variable set AWS_ROLE_ARN --repo "${GH_REPO}" --env staging --body "<staging-role-arn>"
gh variable set AWS_ROLE_ARN --repo "${GH_REPO}" --env prod    --body "<prod-role-arn>"
```

Confirm per-env: `gh variable list --repo "${GH_REPO}" --env dev`.

#### 6. Why no `gh secret` calls

The role ARN is a public-by-design identifier, not a credential — variables are correct. The only credential AWS issues here is the short-lived STS session minted at run time from the OIDC ID token, and that never touches GitHub. If you ever fall back to static keys (please don't), they'd go in `gh secret` and be scoped per env:

```bash
gh secret set AWS_ACCESS_KEY_ID     --repo "${GH_REPO}" --env dev
gh secret set AWS_SECRET_ACCESS_KEY --repo "${GH_REPO}" --env dev
```

#### 7. Verify the wiring with a dry-run

```bash
gh workflow run terraform.yml --repo "${GH_REPO}" --ref master \
  -f environment=dev -f action=plan
gh run watch --repo "${GH_REPO}"
```

A successful plan run confirms OIDC trust, role permissions, state-bucket access, and the variable wiring all work end-to-end.

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
| `action` | | `plan` (generate + upload artifact) or `apply` (download + apply artifact). Drives which CI phase the action runs. |
| `destroy` | | `"true"` to produce a `terraform plan -destroy`. Only meaningful in the plan phase; the apply phase applies whatever the plan file contains. |
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

### Via the GitHub Actions pipeline (recommended)

The workflow supports a `destroy` action via manual dispatch. It's identical to the apply flow — same plan→apply artifact hand-off, same GitHub Environment approval gate — except the plan step runs `terraform plan -destroy`. Reviewers see exactly what will be removed on the PR-less step summary before any resource is touched.

Two layers of protection:

1. **Only `workflow_dispatch` can trigger destroy.** Pushes and PRs cannot. The `action` input is a typed choice locked to `plan` / `apply` / `destroy`.
2. **Typed confirmation.** The dispatch form has a `confirmation` input. You must type `destroy <environment>` exactly (e.g. `destroy prod`). The config job fails the run with a clear error otherwise. Prevents fat-finger destroys and drive-by "just click apply" accidents.

Via the GitHub UI:

1. Actions → **Terraform** workflow → **Run workflow**
2. Environment: `dev` / `staging` / `prod`
3. Action: `destroy`
4. Confirmation: type exactly `destroy dev` (or `destroy staging`, `destroy prod`)
5. Run

Via `gh` CLI:

```bash
gh workflow run terraform.yml --ref master \
  -f environment=dev \
  -f action=destroy \
  -f confirmation="destroy dev"
```

If `prod` has required reviewers on its GitHub Environment, the destroy apply step will pause for approval. Decline to abort.

### Local destroy

```bash
terraform init \
  -backend-config="bucket=myapp-shared-tfstate-724772096574" \
  -backend-config="key=dev/terraform.tfstate" \
  -backend-config="region=us-east-1" \
  -backend-config="dynamodb_table=myapp-shared-tflock"
terraform workspace select dev
terraform destroy -var-file=environments/dev.tfvars
```

### Tearing down the backend itself

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

**GitHub Actions: `Error: Backend configuration changed`** during `terraform init` on a new environment — happens when a provider/module cache from a previous env gets restored and holds the old backend init fingerprint. The composite action now passes `-reconfigure` and scopes the cache key by `workspace`, so this shouldn't recur. If you see it, confirm you pulled the latest [.github/actions/terraform-deploy/action.yml](.github/actions/terraform-deploy/action.yml).

**GitHub Actions: `Unable to resolve action 'aquasecurity/tfsec-action@v1'`** — the upstream action stopped publishing a `v1` rolling tag. The scan job installs `tfsec` directly from GitHub releases now; pin a specific version with the repo variable `TFSEC_VERSION` (e.g. `v1.28.6`) if you want reproducibility.

**GitHub Actions: plan step fails with exit code 2 but the log shows the plan succeeded** — `terraform plan -detailed-exitcode` returns `2` when there are changes. GitHub Actions runs bash steps with `-e` and `-o pipefail`, so the `2` through a `| tee` used to trip errexit before the step could handle it. Fixed in the composite action by explicitly `set +e; set -u`.

**Apply fails with `iam:TagInstanceProfile` (or similar) AccessDenied** — the CI role's permission policy is missing a tagging action the AWS provider now calls. Add it to the role's inline policy. The bootstrapped policy in [gha-terraform-policy.json](gha-terraform-policy.json) covers the common set (`TagRole`/`UntagRole`/`TagInstanceProfile`/…); add more as AWS expands the provider.

**Apply fails with `InvalidBlockDeviceMapping: Volume of size NGB is smaller than snapshot`** — the EC2 launch template requests a root volume smaller than the AMI's default snapshot. Amazon Linux 2023 wants `>= 30` GB. Bump `root_volume_size` in the affected `environments/<env>.tfvars`.

---

## License

Use, fork, modify — no attribution required.
