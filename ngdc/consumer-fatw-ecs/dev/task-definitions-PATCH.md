# =============================================================================
# dev/task-definitions-PATCH.md  (reference, not a .tf file)
#
# I can't see your ecs_task_definition wiring -- the screenshots show
# ecs_service but the task definitions are referenced by name
# ("FATW-Dev-Backend-TD"), so the resource that builds them lives elsewhere.
#
# Below is the shape of the change. Apply it to whichever resource currently
# renders container_definitions.
# =============================================================================

## If your task definitions are a `for_each` over a map

```hcl
resource "aws_ecs_task_definition" "this" {
  for_each = var.ecs_task_definition

  family                   = each.value.family
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"

  # BEFORE
  # cpu    = each.value.cpu
  # memory = each.value.memory

  # AFTER -- lookup by SERVICE key, defaulting to 0 for frontend.
  cpu    = each.value.cpu    + lookup(local.dd_extra_cpu,    each.key, 0)
  memory = each.value.memory + lookup(local.dd_extra_memory, each.key, 0)

  execution_role_arn = aws_iam_role.execution[each.key].arn
  task_role_arn      = aws_iam_role.task[each.key].arn

  # BEFORE
  # container_definitions = jsonencode([local.app_containers[each.key]])

  # AFTER -- concat with an empty list for non-Datadog services.
  container_definitions = jsonencode(concat(
    [local.app_containers[each.key]],
    lookup(local.dd_sidecars, each.key, []),
  ))
}
```

## The app container itself

Only for services in `local.dd_services`. Use a conditional so frontend is
byte-for-byte unchanged and shows no diff in the plan:

```hcl
locals {
  app_containers = {
    for name, svc in var.ecs_service : name => merge(
      {
        name      = svc.load_balancer.container_name
        image     = "${svc.image_repo}:${var.image_tag}"
        essential = true
        cpu       = svc.cpu
        memory    = svc.memory
        portMappings = [{
          containerPort = svc.load_balancer.container_port
          protocol      = "tcp"
        }]
        environment      = [for k, v in try(svc.environment, {}) : { name = k, value = v }]
        logConfiguration = local.default_log_config[name]
      },
      # Datadog additions, empty map for frontend.
      try(svc.datadog_enabled, false) ? {
        environment = concat(
          [for k, v in try(svc.environment, {}) : { name = k, value = v }],
          module.datadog[name].app_environment,
        )
        logConfiguration = module.datadog[name].app_log_configuration
        dependsOn        = module.datadog[name].app_depends_on
        dockerLabels     = module.datadog[name].app_docker_labels
      } : {},
    )
  }
}
```

## Execution role — GovCloud partition

Your existing role attachment almost certainly hardcodes `arn:aws:`. In
GovCloud that policy does not exist and the attach fails:

```hcl
# BEFORE -- breaks in GovCloud
# policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"

# AFTER
policy_arn = "arn:${data.aws_partition.current.partition}:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
```

`data "aws_partition" "current"` is declared in `datadog.tf`. Grep the whole
repo for `arn:aws:` — anything hardcoded is a latent GovCloud bug.

## Verifying before apply

```
terraform output datadog_enabled_services   # expect: ["backend_service"]
terraform output datadog_task_sizing        # expect legal Fargate pairs
```

The plan diff should show **zero** changes to `frontend_service`. If it shows
any, the conditional above is leaking into services that opted out.
