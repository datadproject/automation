locals {
  datadog_target_task_key      = var.dd_task_definition_key
  datadog_target_container_key = var.dd_container_definition_key

  # Every non-target task passes through unchanged. Only the selected task gets
  # the Agent, optional log router, and application Datadog settings.
  ecs_task_definition_effective = {
    for task_key, task in var.ecs_task_definition :
    task_key => task_key != local.datadog_target_task_key ? task : merge(task, {
      container_definitions = merge(
        {
          for container_key, cdef in task.container_definitions :
          container_key => merge(
            cdef,
            container_key == local.datadog_target_container_key ? {
              environment = merge(
                try(cdef.environment, {}),
                module.datadog_backend.app_environment,
              )
            } : {},
            container_key == local.datadog_target_container_key && module.datadog_backend.app_log_configuration != null ? {
              log_configuration = module.datadog_backend.app_log_configuration
            } : {},
            container_key == local.datadog_target_container_key && length(module.datadog_backend.app_depends_on) > 0 ? {
              container_depends_on = module.datadog_backend.app_depends_on
            } : {},
          )
        },
        module.datadog_backend.sidecar_container_definitions,
      )
    })
  }
}

