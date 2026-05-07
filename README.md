# aws-terraform-infra

Terraform stack that provisions a single shared **EKS cluster** (`codeplex-eks`) inside its own VPC. App environments (`dev`, `qa`, `staging`, `prod`) live as Kubernetes namespaces inside this one cluster — there are no per-env AWS stacks.

```
              ┌────────────────── VPC (10.10.0.0/16) ──────────────────┐
              │                                                         │
   IGW ◄──────┤  public subnets (10.10.1.0/24, 10.10.2.0/24)            │
              │     │                                                   │
              │     └── NAT Gateway ──► private subnets (10.10.11/12.0/24)
              │                                  │                      │
              │                                  ├── EKS control plane  │
              │                                  └── EKS managed nodes  │
              └─────────────────────────────────────────────────────────┘
```

After a successful `apply`, the workflow fires a `repository_dispatch` at the app repo so the app deploys automatically into the `codeplex-dev` namespace — see [Triggering app deploy after cluster apply](#triggering-app-deploy-after-cluster-apply).

---

## Table of contents

1. [What you get](#what-you-get)
2. [Repository layout](#repository-layout)
3. [Prerequisites](#prerequisites)
4. [Quick start](#quick-start)
5. [Remote state on S3 + DynamoDB](#remote-state-on-s3--dynamodb)
6. [Variables reference](#variables-reference)
7. [Outputs reference](#outputs-reference)
8. [GitHub Actions deployment](#github-actions-deployment)
   - [Triggering app deploy after cluster apply](#triggering-app-deploy-after-cluster-apply)
9. [Cost notes](#cost-notes)
10. [Destroying the stack](#destroying-the-stack)
11. [Troubleshooting](#troubleshooting)

---

## What you get

| Component | Details |
|---|---|
| **VPC** | `/16` with public and private `/24` subnets across 2 AZs, IGW, NAT GW. Subnets pre-tagged for ELB discovery (`kubernetes.io/role/elb`, `kubernetes.io/cluster/<name>: shared`). |
| **EKS cluster** | `codeplex-eks` — managed control plane, configurable Kubernetes version, control-plane logs to CloudWatch (`api`, `audit`, `authenticator`). Auth mode `API_AND_CONFIG_MAP`. |
| **Managed node group** | Worker nodes in private subnets; configurable instance types, capacity type (ON_DEMAND or SPOT), disk size, autoscaling bounds. |
| **OIDC provider** | For IAM Roles for Service Accounts (IRSA) — pods can assume IAM roles without static credentials. |
| **App-deploy IAM role** | `codeplex-app-deploy` — assumed by the app repo's deploy workflow via OIDC. Inline policy grants `eks:DescribeCluster`; cluster authority via EKS access entry mapped to `AmazonEKSClusterAdminPolicy`. |
| **Cluster admin access entries** | Driver-side `cluster_admin_principals` list — IAM users/roles get cluster-admin via EKS access entry. Survives destroy/apply, no manual `aws-cli` step. |
| **nginx-ingress controller** | Installed as a `helm_release` (chart `4.11.3`). Single LoadBalancer-backed ingress controller; per-env `Ingress` objects share its NLB. |
| **Trigger app deploy** | Post-apply, `terraform.yml` POSTs `repository_dispatch: deploy-app` at the app repo (when `APP_REPO` + `APP_REPO_TOKEN` are set). |
| **Bootstrap module** | Separate stack to create a versioned/encrypted S3 state bucket + DynamoDB lock table. |

App envs (`dev`, `qa`, `staging`, `prod`) are k8s namespaces deployed by the [app repo](https://github.com/luniemma/codeplex-application-ai-systhem) — not separate AWS stacks.

---

## Repository layout

```
aws-terraform-infra/
├── main.tf                  # Root — wires VPC + EKS, app-deploy role + access
│                            #   entries, nginx-ingress helm_release, k8s/helm
│                            #   providers (auth via `aws eks get-token` exec)
├── variables.tf             # Root-level inputs (incl. cluster_admin_principals,
│                            #   app_repo)
├── outputs.tf               # Root outputs (incl. app_deploy_role_arn for the
│                            #   app repo's AWS_DEPLOY_ROLE_ARN secret)
├── environments/
│   └── platform.tfvars      # The only stack — provisions the shared EKS cluster
├── backend/
│   └── main.tf              # One-time bootstrap for S3 + DynamoDB backend
├── modules/
│   ├── vpc/                 # VPC, subnets, IGW, NAT, route tables.
│   │                        #   Subnets tagged for ELB discovery.
│   └── eks/                 # EKS cluster + managed node group + OIDC provider
└── .github/
    ├── actions/terraform-deploy/  # Reusable composite action
    └── workflows/terraform.yml    # validate → scan → plan → apply →
                                   # trigger_app_deploy → app repo dispatch
```

---

## Prerequisites

- **Terraform** `>= 1.5.0` ([install](https://developer.hashicorp.com/terraform/install))
- **AWS CLI v2** configured (`aws configure` or `aws sso login`)
- An **AWS account** with permission to create VPC, EKS, and IAM resources
- **kubectl** for talking to the cluster after it's up

```bash
aws sts get-caller-identity
```

---

## Quick start

```bash
git clone <your-fork-url> aws-terraform-infra
cd aws-terraform-infra

# Use the bundled platform tfvars (or copy + edit)
terraform init
terraform workspace select platform || terraform workspace new platform
terraform plan  -var-file=environments/platform.tfvars -out=tfplan
terraform apply tfplan

# Hook up kubectl
eval "$(terraform output -raw eks_kubeconfig_command)"
kubectl get nodes
```

Cluster creation takes ~10–15 minutes (the EKS control plane is the slow part).

---

## Remote state on S3 + DynamoDB

State for the `platform` workspace lives at `s3://<bucket>/platform/terraform.tfstate`, locked by a DynamoDB table. The bootstrap stack is in [backend/](backend/).

```bash
cd backend
terraform init && terraform apply
# note the bucket name + table name from outputs

cd ..
terraform init \
  -backend-config="bucket=<state-bucket>" \
  -backend-config="key=platform/terraform.tfstate" \
  -backend-config="region=us-east-1" \
  -backend-config="dynamodb_table=<lock-table>" \
  -backend-config="encrypt=true"
```

In CI the same values come from repo Variables `TF_STATE_BUCKET` and `TF_LOCK_TABLE` (see [GitHub Actions deployment](#github-actions-deployment)).

---

## Variables reference

Full list in [variables.tf](variables.tf). All defaults are tuned for the `platform` stack — override per cluster in [environments/platform.tfvars](environments/platform.tfvars).

### General

| Name | Default | Notes |
|---|---|---|
| `aws_region` | `us-east-1` | |
| `project_name` | `codeplex` | Prefixed onto every resource name; the cluster becomes `${project_name}-eks` |
| `environment` | `platform` | Validation only allows `platform` (the single workspace) |

### Network

| Name | Default | Notes |
|---|---|---|
| `vpc_cidr` | `10.10.0.0/16` | |
| `public_subnet_cidrs` | `["10.10.1.0/24","10.10.2.0/24"]` | One per AZ |
| `private_subnet_cidrs` | `["10.10.11.0/24","10.10.12.0/24"]` | EKS nodes live here |

NAT Gateway is always on — EKS nodes in private subnets need outbound for ECR pulls and node registration.

### EKS

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

### Access + cross-repo

| Name | Default | Notes |
|---|---|---|
| `app_repo` | `luniemma/codeplex-application-ai-systhem` | OIDC trust subject for `codeplex-app-deploy` role |
| `cluster_admin_principals` | `["arn:aws:iam::724772096574:user/terra-project"]` | List of IAM principal ARNs that get `AmazonEKSClusterAdminPolicy` via EKS access entry. Add team members here to give them `kubectl` access without manual CLI steps. |

---

## Outputs reference

Defined in [outputs.tf](outputs.tf):

| Output | What it is |
|---|---|
| `vpc_id`, `vpc_cidr` | VPC identifiers |
| `public_subnet_ids`, `private_subnet_ids` | For wiring in other stacks |
| `nat_gateway_id`, `nat_gateway_public_ip` | NAT Gateway info |
| `eks_cluster_name` | Cluster name (`codeplex-eks`) |
| `eks_cluster_endpoint` | API server URL |
| `eks_cluster_version` | Kubernetes version |
| `eks_oidc_provider_arn` | For IRSA trust policies |
| `eks_kubeconfig_command` | Ready-to-paste `aws eks update-kubeconfig …` |
| `app_deploy_role_arn` | IAM role for the app repo's deploy workflow. Set on the app repo as the `AWS_DEPLOY_ROLE_ARN` secret. |

```bash
terraform output -raw eks_kubeconfig_command
terraform output -raw eks_cluster_endpoint
```

---

## GitHub Actions deployment

Pipeline lives at [.github/workflows/terraform.yml](.github/workflows/terraform.yml) and uses the reusable composite action at [.github/actions/terraform-deploy/action.yml](.github/actions/terraform-deploy/action.yml).

### Pipeline shape

```
   config ──► validate ──┐
            └► scan      ├─► plan ──► apply (workflow_dispatch only)
                         │              ▲
                         │              └── consumes the plan artifact — never re-plans
                         │
   PR comment (upsert) ◄─┘
```

### Triggers

| Event | Action |
|---|---|
| PR to `main` / `master` | validate, scan, plan against `platform` (comments on PR) |
| Push to `main` / `master` | validate, scan, **plan only** — no auto-apply on the cluster stack |
| Schedule (06:00 UTC daily) | validate, scan, plan — drift detection |
| `workflow_dispatch` | action = `plan` / `apply` / `destroy`. Apply + destroy require typed confirmation for destroy and pass through the `platform` GitHub Environment's required reviewers. |

There's only one workspace, so push events deliberately don't auto-apply — cluster changes always go through manual dispatch.

### Best-practice features baked in

- **OIDC, no long-lived AWS keys** — role assumed via `aws-actions/configure-aws-credentials`
- **Deny-by-default `permissions: {}`** at workflow scope
- **Concurrency group** `tf-platform-<action>` so two applies queue instead of racing the state lock
- **Plan → apply artifact hand-off** — apply runs `terraform apply tfplan.binary`, never re-plans
- **GitHub Environments approval gate** — required reviewers on `platform` block apply automatically
- **tfsec scan** uploaded as SARIF (non-blocking by default; pin with `TFSEC_VERSION`)
- **Destroy with typed confirmation** — `workflow_dispatch` only; must type `destroy platform` exactly
- **`terraform init -reconfigure`** — never migrates state, always reinitialises against current backend
- **No script-injection sinks** — user input flows through `env:` blocks

### Setup checklist

1. **Bootstrap remote state** — see [backend/](backend/).

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

   Attach a policy that lets Terraform manage VPC, EKS, and IAM. Start from AWS-managed (`AmazonVPCFullAccess`, `AmazonEKSClusterPolicy`, `IAMFullAccess`) for experimentation, then tighten.

3. **Create one GitHub Environment** — `platform` (Settings → Environments). Add **required reviewers** so apply pauses for manual approval.

4. **Set repo Variables** (Settings → Secrets and variables → Actions → Variables):

   | Name | Example | Required |
   |---|---|---|
   | `AWS_REGION` | `us-east-1` | ✅ |
   | `AWS_ROLE_ARN` | `arn:aws:iam::123456789012:role/github-actions-terraform` | ✅ |
   | `TF_STATE_BUCKET` | `myapp-tfstate-123456789012` | ✅ |
   | `TF_LOCK_TABLE` | `myapp-tflock` | ✅ |
   | `TERRAFORM_VERSION` | `1.9.8` | optional |
   | `RUNNER_IMAGE` | `ubuntu-latest` | optional |
   | `TFSEC_VERSION` | `latest` | optional |
   | `APP_REPO` | `luniemma/codeplex-application-ai-systhem` | optional (enables auto app deploy) |

   And **one secret**:

   | Name | Example | Required |
   |---|---|---|
   | `APP_REPO_TOKEN` | fine-grained PAT with `contents: write` on `APP_REPO` only | optional (paired with `APP_REPO`) |

5. **Trigger the first apply.** Push a PR to verify plan, then `gh workflow run terraform.yml -f action=apply` (or use the Actions UI).

### Triggering app deploy after cluster apply

After a successful `apply` on the `platform` stack, the `trigger_app_deploy` job POSTs `repository_dispatch` (`event-type: deploy-app`, `client_payload.environment: dev`) at `APP_REPO`. The app repo's `deploy.yml` listens for that event and runs a Helm deploy into the `codeplex-dev` namespace on the freshly-built cluster.

If `APP_REPO` or `APP_REPO_TOKEN` are unset, the dispatch step no-ops with a notice — the apply itself still succeeds.

`qa`, `staging`, and `prod` deploys do **not** auto-trigger from this path — the app repo's `dispatch_validate` job rejects anything but `dev`. Promotions go through the app repo's own `workflow_dispatch` with required-reviewer gates on the matching GitHub Environments.

---

## Cost notes

Approximate monthly running cost in `us-east-1`:

| Item | Approx |
|---|---|
| EKS control plane | **$73** flat |
| NAT Gateway (1×) | **$32** + data |
| 2× `t3.medium` ON_DEMAND nodes | **$60** |
| **Total** | **~$165/month** |

Switch `eks_node_capacity_type = "SPOT"` and `eks_node_instance_types = ["t3.medium","t3a.medium","t3.large"]` to drop the node bill ~70% at the cost of preemption tolerance. The control plane is the line item that hurts most — destroy the stack when you're done experimenting.

---

## Destroying the stack

The workflow supports a `destroy` action via manual dispatch:

```bash
gh workflow run terraform.yml \
  -f action=destroy \
  -f confirmation="destroy platform"
```

The plan step runs `terraform plan -destroy` so reviewers see exactly what will be removed before any resource is touched. If `platform` has required reviewers on its GitHub Environment, the destroy apply step pauses for approval. Decline to abort.

Local equivalent:

```bash
terraform destroy -var-file=environments/platform.tfvars
```

Tearing the cluster down also tears down the VPC and NAT Gateway, so this is a clean teardown — nothing to clean up by hand afterwards.

---

## Troubleshooting

**EKS nodes stuck in `NotReady`** — almost always missing NAT egress. NAT Gateway is forced on by [main.tf](main.tf), but verify it actually provisioned and that the private subnets' route tables point `0.0.0.0/0` at it.

**`Error: error creating EKS Cluster: ResourceInUseException`** — a cluster with the same name (`codeplex-eks`) already exists in the region. Either import it, destroy the existing one, or change `project_name`.

**`Error: Backend configuration changed`** during `terraform init` on a new run — happens when a module cache from a previous init gets restored and holds the old backend init fingerprint. The composite action passes `-reconfigure` and scopes the cache key, so this shouldn't recur. If you see it, confirm you have the latest [.github/actions/terraform-deploy/action.yml](.github/actions/terraform-deploy/action.yml).

**`could not find any suitable subnets for creating the ELB`** — the public subnets aren't tagged for ELB discovery. The VPC module sets `kubernetes.io/role/elb: "1"` and `kubernetes.io/cluster/${project_name}-eks: shared`. If the cluster name and tag drift apart (e.g. after renaming `project_name`), the cloud provider can't find subnets. Re-apply, or `aws ec2 create-tags` against the public subnets to match.

**`OperationNotPermitted: This AWS account currently does not support creating load balancers`** — account-level restriction common on new AWS accounts. Open a Support ticket asking to enable Elastic Load Balancer creation. Until then, the nginx-ingress controller's Service stays `Pending` for `EXTERNAL-IP` and the app repo's deploy summary falls back to `kubectl port-forward` commands.

**`Error: creating IAM Role: EntityAlreadyExists`** when re-applying after a destroy — IAM role names linger briefly after deletion (eventual consistency). Wait 30–60s and re-run apply; the names will be free.

**helm provider hangs on destroy** — if you destroy the cluster while `helm_release.ingress_nginx` is still in state, terraform tries to talk to a dead API server. Workaround: `terraform state rm helm_release.ingress_nginx` before destroy, or destroy via `gh workflow run … -f action=destroy` (the workflow handles it).

**Local kubectl returns `the server has asked for the client to provide credentials`** — your IAM principal isn't in the cluster's access entries. Add it to `cluster_admin_principals` in [variables.tf](variables.tf) (or [environments/platform.tfvars](environments/platform.tfvars)) and re-apply, or temporarily `aws eks create-access-entry` + `aws eks associate-access-policy` via CLI (will drift terraform state).

**`UnauthorizedOperation` from `aws-actions/configure-aws-credentials`** — OIDC trust policy doesn't match the workflow's repo/branch. Check `token.actions.githubusercontent.com:sub` in the role trust policy against `repo:<owner>/<repo>:*`.

**Apply succeeds but `kubectl` can't reach the cluster** — `eks_cluster_endpoint_public_access` may be `false`. Either run `kubectl` from inside the VPC (or via VPN), or set `eks_cluster_endpoint_public_access = true` in [environments/platform.tfvars](environments/platform.tfvars) and re-apply.
