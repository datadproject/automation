# ngdc-ecs-cluster-module — the minimum change, in two tiers

This module is deployed to prod and shared with non-Datadog consumers, so the
patch is deliberately as small as it can be and **provably no-op** for every
existing workload.

Ship Tier A first. It is one attribute and one merge.

---

## TIER A — metrics + APM (1 attribute, 1 merge)

Everything except log collection works with this alone. Use with
`dd_enable_logs = false`.

### `variables.tf` — inside the `container_definitions` object (~line 73)

```hcl
      # Standard ECS healthCheck. Optional, so nothing existing changes.
      health_check = optional(object({
        command     = list(string)
        interval    = optional(number, 30)
        timeout     = optional(number, 5)
        retries     = optional(number, 3)
        startPeriod = optional(number)
      }))
```

### `main.tf` — add one conditional merge inside the container `merge(...)`

```hcl
      try(cdef.health_check, null) != null ? {
        healthCheck = cdef.health_check
      } : {},
```

Put it alongside the existing `secrets` / `port_mappings` / `mount_points`
conditionals. Order does not matter for this one.

**Blast radius:** none. No existing container in any tfvars sets
`health_check`, so `try(...)` returns null and the merge contributes `{}`.

---

## TIER B — add Datadog log collection (3 more attributes, 3 more merges)

Only needed when `dd_enable_logs = true`.

### `variables.tf` — three more

```hcl
      # Standard ECS dependsOn. Named container_depends_on to match the
      # module's existing container_* convention.
      container_depends_on = optional(list(object({
        containerName = string
        condition     = string   # START | COMPLETE | SUCCESS | HEALTHY
      })), [])

      # Standard ECS firelensConfiguration. Needed by ANY log-router sidecar
      # (fluentbit or fluentd) -- FireLens is an AWS feature, not a vendor one.
      firelens_configuration = optional(object({
        type    = string
        options = optional(map(string), {})
      }))

      # PER-CONTAINER logConfiguration override.
      #
      # THIS IS THE BLOCKER. main.tf currently hardcodes awslogs from
      # task-level variables for every container, so no container can use
      # awsfirelens, splunk, fluentd, or any other driver.
      #
      # `any` because the shape varies by driver (secretOptions only applies
      # to some). null keeps today's behaviour exactly.
      log_configuration = optional(any)
```

### `main.tf` — three more merges

```hcl
      length(try(cdef.container_depends_on, [])) > 0 ? {
        dependsOn = cdef.container_depends_on
      } : {},

      try(cdef.firelens_configuration, null) != null ? {
        firelensConfiguration = cdef.firelens_configuration
      } : {},

      # MUST BE LAST in the merge() argument list. merge() is last-wins, so
      # this overrides the awslogs default above when set, and contributes
      # nothing when null.
      try(cdef.log_configuration, null) != null ? {
        logConfiguration = cdef.log_configuration
      } : {},
```

**Blast radius:** none. No existing container sets any of the three.

---

## NOT in this patch, deliberately

Earlier drafts also needed `container_cpu`, `container_memory`, `user` and
`docker_labels`. All four have been designed out of the sidecar module:

| | How it was removed |
|---|---|
| `container_cpu` / `container_memory` | default `null` in the sidecar module → key omitted. Your whole estate already runs with these commented out, so the sidecars match. |
| `docker_labels` | `emit_docker_labels = false` by default. UST still works via `DD_ENV` / `DD_SERVICE` / `DD_VERSION`, which is what the Agent reads on Fargate. |
| `user` | dropped. `aws-for-fluent-bit` already runs as root. |

If you later want container-level reservations, they are a separate,
independently useful change — uncomment lines 78-79 in `variables.tf` and
49-50 in `main.tf`.

---

## Proving it is no-op before you merge

The module is in prod for four environments and other teams' workloads. Prove
it, don't assert it:

```bash
# 1. Render container_definitions from the CURRENT module
cd consumer-fatw-ecs/dev
terraform init && terraform plan -out=before.tfplan
terraform show -json before.tfplan \
  | jq -S '.planned_values.root_module.child_modules[].resources[]
           | select(.type=="aws_ecs_task_definition")
           | {family: .values.family, cd: .values.container_definitions}' \
  > /tmp/before.json

# 2. Point at the patched module, WITHOUT adding datadog.tf yet
#    (change the module source/version only)
terraform init -upgrade && terraform plan -out=after.tfplan
terraform show -json after.tfplan \
  | jq -S '.planned_values.root_module.child_modules[].resources[]
           | select(.type=="aws_ecs_task_definition")
           | {family: .values.family, cd: .values.container_definitions}' \
  > /tmp/after.json

# 3. Must be empty
diff /tmp/before.json /tmp/after.json && echo "PROVEN NO-OP"
```

`terraform plan` should also say **"No changes"** outright. Repeat for
test/stage/prod, and for at least one other team's consumer repo before the
MR merges.

---

## Reusability

Every field added is a standard AWS ECS container-definition key:
`healthCheck`, `dependsOn`, `firelensConfiguration`, `logConfiguration`. All
documented by AWS, all useful to workloads that have never heard of Datadog:

- `health_check` — any container with a readiness probe
- `container_depends_on` — any multi-container task with an init or migration step
- `firelens_configuration` + `log_configuration` — Splunk, Fluentd, Kinesis, any log destination that is not CloudWatch

Nothing here mentions Datadog. There is no `datadog_secrets`, no
`datadog_health_check`, no `datadog_firelens`. A consumer that sets none of
these gets byte-identical JSON.

## Versioning

Tag the module `vX.Y.0` (minor — additive). Consumers move on their own
schedule. `fatw-ecs/dev` goes first; the other three environments and other
teams stay on the current version until they choose to move.
