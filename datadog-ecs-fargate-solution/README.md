# Datadog sidecar for an existing ECS Fargate service

This package matches the three-layer structure shown in the screenshots:

1. `consumer/` - the FATW ECS repository.
2. `shared-ecs-module/` - the module that owns `aws_ecs_task_definition`.
3. `datadog-fragment-module/` - emits container-definition fragments only.

The Datadog module does **not** create an ECS cluster, service, task definition,
IAM role, or log group. The existing ECS module remains the only resource owner.

## Important Fargate behavior

An Agent cannot be installed once on a Fargate cluster. Add the Agent sidecar to
each application task definition that must be monitored. Updating the service to
the new task-definition revision starts one Agent alongside every application
task.

## Recommended rollout

1. Merge and publish the `shared-ecs-module` changes.
2. Merge and publish the `datadog-fragment-module` files. Do not put a configured
   `provider "aws"` block in that child module.
3. In the consumer, pin both module sources to commits containing the changes.
4. Start with `dd_enable_logs = false`. This adds the Agent while preserving the
   application's current `awslogs` configuration.
5. Apply and confirm that the task has `backend` and `datadog-agent` containers.
6. After the Agent is healthy, set `dd_enable_logs = true` to add FireLens and
   route the backend container's stdout/stderr directly to Datadog.

## Logs and APM

- Metrics and container health come from the Agent sidecar.
- APM port `8126` and the application environment are configured, but traces only
  appear if the application image already contains a Datadog tracer.
- Direct log collection uses FireLens, so enabling it changes the application
  container from `awslogs` to `awsfirelens`. The Agent and log-router containers
  still use the task's existing `awslogs` defaults.

## Required substitutions

Replace only these placeholders in `consumer/datadog.tf`:

- `<DATADOG_MODULE_GIT_URL>`
- `<PINNED_COMMIT>`

Set the real image URIs and network values in the consumer tfvars. Image creation
or mirroring is intentionally outside this package.

The consumer files are replacement/reference blocks for the Datadog sections
already added in the screenshots. Do not append duplicate variable declarations;
replace the current Datadog block with the supplied block.

## CI version label

Do not put a CI expression in a Terraform variable default. Declare `dd_version`
once, with a normal default such as `"unknown"`, and pass the runtime value from
GitLab:

```yaml
variables:
  TF_VAR_dd_version: "$CI_COMMIT_SHORT_SHA"
```

## What to remove from the current attempt

- Remove the duplicate `image_tag` variable.
- Remove the text `Wire from CI: ...` from any Terraform `default` expression.
- Remove the configured AWS provider from the Datadog child module.
- Do not use the old Datadog module ref that produced `Unsupported argument`.
- For the first deployment, do not add FireLens; keep `dd_enable_logs = false`.
