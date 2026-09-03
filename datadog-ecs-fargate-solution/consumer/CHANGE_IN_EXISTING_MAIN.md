# One required change in the existing consumer `main.tf`

Find the existing call to the shared ECS cluster module. Change only the
`ecs_task_definition` argument:

```hcl
module "ecs_cluster" {
  # existing source and inputs remain unchanged

  ecs_task_definition = local.ecs_task_definition_effective
  ecs_service         = var.ecs_service
}
```

If the module block has a different label, keep its current label. The essential
change is:

```diff
- ecs_task_definition = var.ecs_task_definition
+ ecs_task_definition = local.ecs_task_definition_effective
```

Do not add a second ECS module call and do not create a separate Datadog ECS
service for Fargate.

