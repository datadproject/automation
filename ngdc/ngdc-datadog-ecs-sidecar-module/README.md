# NGDC Datadog ECS Sidecar Module

Emits the Datadog agent + FireLens sidecars for **Fargate** tasks, plus the
fragments you merge into your own app container. Sits alongside
`ngdc-ecs-cluster-module`; it does not replace it.

## Getting started

```hcl
module "datadog" {
  source  = "gitlab.example.com/ngdc/datadog-ecs-sidecar/aws"
  version = "1.0.0"

  aws_region             = var.aws_region
  app_container_name     = var.service_name
  sidecar_log_group      = aws_cloudwatch_log_group.datadog_sidecars.name
  dd_api_key_secret_name = "platform/datadog/api-key"

  dd_env     = var.environment
  dd_service = var.service_name
  dd_version = var.image_tag
  log_source = "java"
}
```

Then in your task definition:

```hcl
locals {
  app_container = {
    name             = var.service_name
    image            = "${var.ecr_repo}:${var.image_tag}"
    essential        = true
    environment      = concat(local.app_env, module.datadog.app_environment)
    logConfiguration = module.datadog.app_log_configuration
    dependsOn        = module.datadog.app_depends_on
    dockerLabels     = merge(local.app_labels, module.datadog.app_docker_labels)
    # ...
  }
}

resource "aws_ecs_task_definition" "this" {
  network_mode = "awsvpc"                                   # mandatory on Fargate
  cpu          = var.app_cpu    + module.datadog.additional_cpu
  memory       = var.app_memory + module.datadog.additional_memory

  container_definitions = jsonencode(concat(
    [local.app_container],
    module.datadog.container_definitions,
  ))
}

resource "aws_iam_role_policy" "execution_datadog" {
  role   = aws_iam_role.execution.id
  policy = module.datadog.execution_role_policy_json
}
```

## Why this module creates no IAM resources

It returns `execution_role_policy_json`, a document, and nothing else. If the
module created an `aws_iam_role`, then two services in one account both
wanting `<name>-execution` collide with `EntityAlreadyExists`, and any role
that both the cluster module and this module attach to develops perpetual
diffs. Exactly one module should own each role. That module is yours.

## Why there is no provider block

`provider.tf` here declares `required_providers` only. A configured
`provider "aws" {}` inside a reusable module blocks `count`/`for_each` on the
module call, prevents the caller passing an aliased provider, and hardcodes
region and assume-role behaviour. Worth auditing
`ngdc-ecs-cluster-module/provider.tf` for the same issue.

## Container layout after this module

| Container | Purpose |
|---|---|
| *your app* | traces → `127.0.0.1:8126`, custom metrics → `127.0.0.1:8125`, logs → FireLens |
| `datadog-agent` | metrics, trace agent, DogStatsD, autodiscovery |
| `log_router` | fluent-bit → Datadog log intake |

## Secrets

`dd_api_key_secret_name` is resolved to an ARN by data source, then referenced
twice: `secrets.DD_API_KEY` on the agent and `secretOptions.apikey` on the
app's FireLens config. ECS resolves both at task start using the **execution
role**. The key is never in the task definition, tfstate, or CI variables.

Same `platform/datadog/api-key` secret as the EKS clusters — one secret, one
rotation, three consumers.

## Gotchas

**Execution role, not task role.** `secrets` and `secretOptions` are resolved
before your containers exist. The wrong role gives you a
`ResourceInitializationError` that reads like a networking failure.

**Fargate cpu/memory pairs are an allowlist.** 512 + 192 = 704 is not a legal
task size. Round up to the next valid combination (1024) or Fargate rejects
the task definition at registration time.

**FireLens replaces awslogs on the app container.** App logs stop arriving in
CloudWatch. If retention/audit requires them there, either set
`enable_logs = false` and keep awslogs, or add a second fluent-bit output via
a custom config. Decide before rollout.

**`DD_APM_NON_LOCAL_TRAFFIC=true`** is set for you and is required even though
awsvpc shares loopback. Removing it produces silent trace loss.

## Image pinning

Defaults point at public ECR with a floating `stable` tag on fluent-bit.
Before prod, mirror both into your ECR and pin by digest:

```bash
REG=<acct>.dkr.ecr.<region>.amazonaws.com
crane copy public.ecr.aws/datadog/agent:7.66.1 $REG/datadog/agent:7.66.1
crane copy public.ecr.aws/aws-observability/aws-for-fluent-bit:stable \
  $REG/datadog/aws-for-fluent-bit:2.32.5
```

Then set `agent_image` / `fluentbit_image` to `...@sha256:...` in `ecs.tfvars`.

## Cost

~192 CPU units and 640 MiB per task, on every task, permanently. That is the
structural cost of sidecars versus the DaemonSet you run on EKS. Multiply by
task count before fleet-wide rollout and take the number to whoever owns the
budget.

## Releasing

Tag `vX.Y.Z` on `main`. CI publishes to the GitLab Terraform Module Registry.
Consumers pin `version = "1.0.0"` — never a branch.
