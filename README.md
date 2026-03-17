# Datadog API Key Rotation — Automated Pipeline

Automated rotation of Datadog GovCloud API keys across 30+ EKS clusters in separate AWS accounts, orchestrated via self-hosted GitLab CI.

## Architecture

```
GitLab CI (scheduled every 60 days)
  │
  ├── Stage 1: rotate_key.sh
  │     → Create new DD API key via Datadog GovCloud API
  │     → Update GitLab CI/CD masked variable
  │
  ├── Stage 2: generate_matrix.sh
  │     → Read clusters.yml inventory
  │     → Generate child pipeline YAML (1 job per cluster)
  │
  ├── Stage 3: child-pipeline.yml (parallel, 1 job per cluster)
  │     → Assume cross-account IAM role
  │     → Update kubeconfig
  │     → Patch K8s secret
  │     → Rollout restart Datadog agents
  │     → Health check
  │
  ├── Stage 4: verify.sh
  │     → Poll Datadog API to confirm all clusters reporting
  │
  ├── Stage 5: revoke_old_key.sh
  │     → Delete old API key (only if verification passed)
  │
  └── Stage 6: notify (Slack/Teams webhook)
```

## Prerequisites

### 1. GitLab CI/CD Variables

Set these as **protected, masked** variables in your project settings:

| Variable | Description | Masked | Protected |
|---|---|---|---|
| `DD_API_KEY` | Current Datadog API key | Yes | Yes |
| `DD_APP_KEY` | Datadog Application key (`api_keys_write` + `api_keys_read` scope) | Yes | Yes |
| `GITLAB_TOKEN` | Project Access Token with `api` scope (to update variables) | Yes | Yes |
| `SLACK_WEBHOOK_URL` | (Optional) Slack incoming webhook for notifications | Yes | No |

### 2. Datadog Application Key Permissions (GovCloud)

The `DD_APP_KEY` needs these scopes in Datadog GovCloud (`app.ddog-gov.com`):
- `api_keys_write` — create and delete API keys
- `api_keys_read` — list API keys

### 3. AWS IAM Setup

**Per workload account** — Deploy the CloudFormation stack:

```bash
# Via StackSets (recommended for 30+ accounts):
aws cloudformation create-stack-set \
  --stack-set-name dd-key-rotation-role \
  --template-body file://iam/cross-account-role.yml \
  --parameters \
    ParameterKey=ManagementAccountId,ParameterValue=<MGMT_ACCOUNT_ID> \
    ParameterKey=EksClusterName,ParameterValue=<CLUSTER_NAME> \
  --permission-model SERVICE_MANAGED \
  --auto-deployment Enabled=true,RetainStacksOnAccountRemoval=false
```

The GitLab runner's IAM identity needs `sts:AssumeRole` on every workload account's `GitLabDDKeyRotationRole`.

### 4. Kubernetes RBAC

Apply in each EKS cluster:

```bash
kubectl apply -f kubernetes/rbac.yml
```

Then add the IAM role mapping. **EKS Access Entry (preferred, 1.28+):**

```bash
aws eks create-access-entry \
  --cluster-name <CLUSTER_NAME> \
  --principal-arn arn:aws:iam::<ACCOUNT_ID>:role/GitLabDDKeyRotationRole \
  --kubernetes-groups dd-key-rotation-group \
  --type STANDARD
```

Or use the `aws-auth` ConfigMap (see `kubernetes/aws-auth-patch-example.yml`).

### 5. Runner Image

Build and push the Docker image to your internal registry:

```bash
docker build -t <CI_REGISTRY>/infra/dd-rotation-runner:latest .
docker push <CI_REGISTRY>/infra/dd-rotation-runner:latest
```

## Configuration

### Cluster Inventory

Edit `config/clusters.yml` to list all your EKS clusters:

```yaml
defaults:
  namespace: datadog
  secret_name: datadog-credentials
  secret_key: api-key

clusters:
  - name: prod-us-east-1-app
    aws_account_id: "111111111111"
    aws_region: us-east-1
    cluster_name: prod-app-cluster
    role_arn: arn:aws:iam::111111111111:role/GitLabDDKeyRotationRole
  # ... repeat for all 30+ clusters
```

### Schedule

Create a pipeline schedule in **GitLab > CI/CD > Schedules**:
- Interval: `0 6 1 */2 *` (1st of every 2nd month at 06:00 UTC — rotates every ~60 days, well within the 90-day requirement)
- Target branch: `main` (must be protected)

## Manual Trigger

Run from GitLab UI: **CI/CD > Pipelines > Run pipeline**, or set `FORCE_ROTATION=true`.

## Failure Handling

| Failure point | Behavior |
|---|---|
| Key creation fails | Pipeline stops. No changes made. |
| GitLab variable update fails | Pipeline stops. New key exists in DD but isn't deployed. Delete it manually. |
| Rollout fails on some clusters | Old key still valid. Fix the cluster, re-run pipeline. Both keys work. |
| Verification times out | Old key is NOT revoked. Both keys remain active. Alert fires. |
| Revocation fails | Both keys active. Manual cleanup needed. Alert fires. |

## File Structure

```
datadog-key-rotation/
├── .gitlab-ci.yml              # Main pipeline definition
├── Dockerfile                  # Runner image
├── config/
│   └── clusters.yml            # Cluster inventory
├── scripts/
│   ├── helpers.sh              # Shared functions (logging, IAM, kubectl)
│   ├── rotate_key.sh           # Stage 1: Create new key, update GitLab var
│   ├── generate_matrix.sh      # Stage 2: Build child pipeline
│   ├── rollout.sh              # Stage 3: Update one cluster
│   ├── verify.sh               # Stage 4: Confirm all clusters reporting
│   └── revoke_old_key.sh       # Stage 5: Revoke old key
├── kubernetes/
│   ├── rbac.yml                # ClusterRole + Binding for rotation
│   └── aws-auth-patch-example.yml
└── iam/
    └── cross-account-role.yml  # CloudFormation for workload account IAM role
```
