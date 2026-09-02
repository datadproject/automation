# Task definition patch — applies to all four environments

The same edit in each env directory (or once in `ngdc-ecs-cluster-module`, if
that's where `aws_ecs_task_definition` lives — check with
`grep -rl aws_ecs_task_definition`).

## 1. Merge the sidecars

```hcl
resource "aws_ecs_task_definition" "this" {
  for_each = var.ecs_task_definition

  # BEFORE
  # cpu    = each.value.cpu
  # memory = each.value.memory

  # AFTER — 0 for services that opted out, so frontend is unchanged.
  cpu    = each.value.cpu    + lookup(local.dd_extra_cpu,    each.key, 0)
  memory = each.value.memory + lookup(local.dd_extra_memory, each.key, 0)

  container_definitions = jsonencode(concat(
    [local.app_containers[each.key]],
    lookup(local.dd_sidecars, each.key, []),
  ))
}
```

## 2. App container additions, backend only

```hcl
locals {
  app_containers = {
    for name, svc in var.ecs_service : name => merge(
      local.base_container[name],
      try(svc.datadog_enabled, false) ? {
        environment = concat(
          local.base_container[name].environment,
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

## 3. GovCloud partition

```hcl
# BEFORE — this policy does not exist in aws-us-gov
# policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"

# AFTER
policy_arn = "arn:${data.aws_partition.current.partition}:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
```

`data "aws_partition" "current"` is declared in `datadog.tf`.

**Grep every env directory and the cluster module for `arn:aws:`.** Each one
is a latent GovCloud bug.

## 4. Execution role

You still **create** the execution role — the module never does, because two
modules creating the same role is the `EntityAlreadyExists` / perpetual-diff
failure mode.

But the module now **attaches** its own inline policy to whatever role you
hand it, via `execution_role_name`. Inline policies are namespaced per role,
so this cannot collide, and the policy name is service-scoped
(`datadog-secret-read-<service>`) so two module instances sharing one role
don't overwrite each other.

`datadog.tf` currently passes `aws_iam_role.execution[each.key].name`. If your
ECS module creates the execution role instead, expose its **name** as an
output and pass that:

```hcl
execution_role_name = module.ecs_cluster.execution_role_names[each.key]
```

To opt out entirely, set `execution_role_name = null` and attach
`module.datadog[name].execution_role_policy_json` yourself.

## Verify before apply, every env

```
terraform output datadog_enabled_services   # ["backend_service"]
terraform output datadog_task_sizing        # legal Fargate pairs
```

The plan diff for `frontend_service` must be **empty**.
