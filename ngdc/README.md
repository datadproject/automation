# Datadog on FATW ECS — additive, prod-safe

Two constraints shaped everything here:

1. **It is deployed to prod.** Nothing currently running may change.
2. **`ngdc-ecs-cluster-module` is shared** with workloads that will never use
   Datadog.

Both point the same way: the module patch is tiny and provably no-op.

```
ngdc/
├── ngdc-datadog-ecs-sidecar-module/     fragment module, creates NO resources
├── generic-ecs-module-patch/PATCH.md    the minimum change, in two tiers
└── consumer-fatw-ecs/{dev,test,stage,prod}/
        datadog.tf                       the only new FILE, identical in all four
        locals.tf.datadog-additions      the composition
        variables.tf.datadog-additions
        ecs.tfvars.datadog-additions     real values from your dev tfvars
        main.tf.tmpl.datadog-change      the one line
```

---

## What actually changes in your running estate

| Task definition | Change |
|---|---|
| FATW-Dev-Frontend-TD | **none** — byte-identical |
| FATW-Dev-DB-Import-TD | **none** |
| FATW-Dev-Scraper-TD | **none** |
| FATW-Dev-Importer-TD | **none** |
| FATW-Dev-Exporter-TD | **none** |
| **FATW-Dev-Backend-TD** | new revision: `datadog-agent` added to `container_definitions`, `DD_*` merged into the `backend` container's `environment` |

Backend's `cpu = 1024` / `memory = 2048` are **not touched**. Nor its image,
`secrets` (HASH_SALT), `mount_points` (drupal-files), `port_mappings` (8080),
`efs_volume`, roles, or `awslogs_*`.

Backend gets a rolling replacement, which is the point. Everything else stays
on its current revision.

---

## The blocker, and how it is minimised

`ngdc-ecs-cluster-module/main.tf` hardcodes `logConfiguration` to `awslogs`
for every container from task-level variables. There is no per-container
override, so **`awsfirelens` is unreachable without a module change**.

So the rollout is two tiers:

### Tier A — metrics + APM. Module change = 1 attribute, 1 merge.

Add `health_check` to the container object; add one conditional merge. Set
`dd_enable_logs = false`. You get the Agent sidecar, APM, DogStatsD, ECS and
container metrics, container health, Unified Service Tagging.

### Tier B — add Datadog logs. Module change = 3 more attributes, 3 more merges.

`container_depends_on`, `firelens_configuration`, `log_configuration`.

Four fields I previously needed were designed out so they are not in the
patch at all: `container_cpu`, `container_memory` (default null → key
omitted, matching your estate where they are commented out everywhere),
`docker_labels` (`emit_docker_labels = false`; UST works via `DD_ENV` /
`DD_SERVICE` / `DD_VERSION`), and `user` (fluent-bit already runs as root).

Every field added is a standard AWS ECS key — `healthCheck`, `dependsOn`,
`firelensConfiguration`, `logConfiguration` — all useful to non-Datadog
workloads. No `datadog_*` inputs anywhere.

**`generic-ecs-module-patch/PATCH.md` includes a `jq`-based procedure that
proves the rendered `container_definitions` JSON is unchanged before you
merge.** Run it for all four environments and at least one other team's repo.

---

## The consumer change

One new file (`datadog.tf`), three pasted snippets, and one line:

```hcl
ecs_task_definition = local.ecs_task_definition_effective
```

`local.ecs_task_definition_effective` returns `var.ecs_task_definition`
unchanged for every task definition whose service did not set
`datadog_enabled = true`. Only `backend_service` sets it.

Note on `main.tf.tmpl`: `local.ecs_task_definition_effective` contains a dot,
so GNU envsubst leaves it alone. No `$${...}` escaping.

---

## Settle these before planning

**Which Datadog org?** GovCloud (`ddog-gov.com`) is a physically separate
instance with its own API keys. If your EKS clusters report to
`datadoghq.com`, this needs a **different secret**. Everything else is wasted
work if this is wrong.

**NAT or proxy?** Do subnets `subnet-006a34b1ad999f94a` /
`subnet-0224b8225a9a90a3e` egress via NAT, or only via the corporate proxy? A
wrong answer gives healthy tasks and zero telemetry with no error anywhere.
If proxied you must set **both** `dd_agent_proxy_https` and
`dd_fluentbit_proxy` — the module fails the plan if you set only the first,
because Fluent Bit does not read `DD_PROXY_HTTPS`.

**Agent image in GovCloud ECR?** `public.ecr.aws` and `gcr.io` are
unreachable from `us-gov-west-1`. Mirror to
`093737011827.dkr.ecr.us-gov-west-1.amazonaws.com/...` or wherever your
policy allows, and pin.

---

## Order

1. Answer the three questions above.
2. Raise the Tier A module patch as its own MR. Run the no-op proof. Tag a
   minor version.
3. `fatw-ecs/dev` only: add `datadog.tf`, paste the three snippets, change the
   one line, set `dd_enable_logs = false`.
4. Plan. **Five task definitions show no diff; only Backend changes; cpu and
   memory do not appear.**
5. Apply dev. Verify backend appears in Datadog with `env:dev`.
6. Soak, then test → stage → prod on the same Tier A.
7. Tier B for logs, dev-first again, only after checking whether anything in
   GovCloud audit expects backend logs to stay in CloudWatch.

## Backing out

`datadog_enabled = false` on `backend_service`. Next apply registers a task
definition identical to today's. The inline IAM policy is removed; the
execution role is untouched because this repo never owned it. Nothing else in
the estate was ever modified.

Full detail: `INSTRUCTIONS.md`.

## Two pre-existing issues, unrelated

- `ecs.tfvars:279-280` — `frontend_service.autoscaling` sets `min_capacity`
  twice (1, then 2). The second is almost certainly meant to be
  `max_capacity`. HCL takes the last value, so you have min 2 and no max.
- `FATW-Dev-Importer-CD` image is pinned to `:latest`
  (`fatoolkit-data-refresh-importer-dev:latest`) while every other container
  uses a SHA tag.
