# Step-by-step

Dev first. Do not touch test/stage/prod until dev is verified.

## Step 0 — Three answers

1. **Datadog org**: commercial or `ddog-gov.com`? Determines whether you need
   a new API key secret.
2. **Egress**: do the Fargate subnets have NAT, or proxy-only?
3. **Agent image**: is it already mirrored into a GovCloud ECR repo you can
   pull from? If not, that is a prerequisite ticket.

## Step 1 — Module patch MR (separate, first)

`generic-ecs-module-patch/PATCH.md`, **Tier A only**. One attribute, one merge.

Run the no-op proof in that file for dev/test/stage/prod and at least one
other team's consumer. `terraform plan` must say "No changes" everywhere.

Tag a minor version. Consumers move when they choose.

## Step 2 — Sidecar module

Copy `ngdc-datadog-ecs-sidecar-module/` into the repo as a sibling of
`consumer-fatw-ecs/`. Seven files, no edits.

## Step 3 — dev/datadog.tf

Copy in as-is. Check the `source` path resolves from `dev/`:

```
source = "../../ngdc-datadog-ecs-sidecar-module"
```

Adjust if your layout differs.

## Step 4 — Paste three snippets into dev/

| From | Into | Note |
|---|---|---|
| `locals.tf.datadog-additions` | `dev/locals.tf` | create the file if absent |
| `variables.tf.datadog-additions` | `dev/variable.tf` | **singular** in your repo |
| `ecs.tfvars.datadog-additions` | `dev/ecs.tfvars` | three separate places — see below |

Then delete the `.datadog-additions` files.

`ecs.tfvars` is not a straight append:

1. **In `ecs_service.backend_service`** (~line 288) add:
   ```hcl
   datadog_enabled = true
   dd_log_source   = "php"
   dd_enable_logs  = false     # Tier A
   ```
2. **In `ecs_task_definition`** — change nothing. Confirm Backend is still
   `cpu = 1024`, `memory = 2048`.
3. **At the end of the file** (after `trackingid_tag`, ~line 323) append the
   `dd_*` block, replacing every `<<<REPLACE>>>`.

## Step 5 — The one line in dev/main.tf.tmpl

```hcl
ecs_task_definition = local.ecs_task_definition_effective
```

No `$${...}` escaping — the expression contains a dot, so envsubst skips it.

## Step 6 — Check the ecs_service type

If `dev/variable.tf` declares `ecs_service` as `type = any`, nothing to do.

If it mirrors the module's typed object, add the optional `dd_*` attributes
listed at the bottom of `variables.tf.datadog-additions`. If the *module's*
type then rejects them, strip them in the module call — the strip expression
is in the same file.

## Step 7 — Plan

```bash
cd consumer-fatw-ecs/dev
terraform init
terraform plan -var-file=ecs.tfvars -out=tfplan
```

Pass criteria:

| Check | Expected |
|---|---|
| Frontend, DB-Import, Scraper, Importer, Exporter TDs | **no diff** |
| FATW-Dev-Backend-TD | replaced, `datadog-agent` added |
| Backend `cpu` / `memory` | **absent from the diff** |
| backend container image / secrets / mount_points / port_mappings | unchanged |
| new resource | `aws_iam_role_policy.datadog_execution_secret["backend_service"]` |
| GovCloud | no `arn:aws:` in the plan |

```bash
terraform show -no-color tfplan | grep -i "arn:aws:" && echo "PARTITION BUG"
```

Any diff on the other five task definitions means the composition is leaking.
Stop.

Deliberate plan-time errors you may hit:

- *"enable_logs = true requires fluentbit_image"* → you left logs on; set
  `dd_enable_logs = false` for Tier A
- *"agent_proxy_https is set but fluentbit_proxy is not"* → set both
- *"aws-us-gov partition but dd_site is not ddog-gov.com"* → fix `dd_site`

## Step 8 — Apply dev, verify in order

Each check rules out one specific failure.

1. **Task reaches RUNNING.** `ResourceInitializationError` → the execution
   role cannot read the secret; the IAM attachment did not land or the role
   name derivation is wrong.
2. **Two containers:**
   ```bash
   aws ecs describe-tasks --cluster NGDC-FATW-ECS-CLUSTER --tasks <id> \
     --region us-gov-west-1 \
     --query 'tasks[0].containers[].{name:name,status:lastStatus,health:healthStatus}'
   ```
   Expect `backend` and `datadog-agent`.
3. **Agent HEALTHY** within ~60s (`startPeriod`).
4. **Metrics** — Datadog → Infrastructure → Containers. Both containers
   visible. Their presence confirms no `DD_CONTAINER_EXCLUDE`.
5. **Backend still serving.** ALB target group healthy, Drupal responding.
   This is the one that matters.
6. **APM** — expect **nothing** unless the app already runs `dd-trace-php`.
   That is correct, not a failure.

Soak 24h. With `agent_essential = false` and `app_wait_for_agent = false`, an
Agent crash should show as missing data, not a task restart.

## Step 9 — test → stage → prod

Same Tier A everywhere. `datadog.tf`, `locals.tf.datadog-additions` and
`variables.tf.datadog-additions` are identical across all four — verified with
`diff`. Only `ecs.tfvars` differs: task-definition key names, and proxy
values, which must be **re-verified per VPC**.

Prod last, after stage runs a full business cycle.

## Step 10 — Tier B (logs), later

Only after Tier A is stable everywhere, and after confirming nothing in
GovCloud audit or retention expects backend logs to stay in CloudWatch.
FireLens removes them from `/ecs/NGDC-FATW-ECS-CLUSTER`.

Then: merge Tier B of the module patch, set `dd_fluentbit_image`, set
`dd_enable_logs = true`, and if proxied set `dd_fluentbit_proxy`. Dev first
again.

## Backing out

| Tier | Action | Speed |
|---|---|---|
| 1 | `datadog_enabled = false` on backend_service | one apply |
| 2 | `dd_enable_logs = false` (logs broken only) | one apply |
| 3 | `aws ecs update-service --task-definition FATW-Dev-Backend-TD:<prev>` | one deploy, no pipeline |
| 4 | `git revert` the MR | per env |

Tier 3 works because task-definition revisions are immutable and the previous
one still exists. Follow with Tier 1 so state matches reality.

Nothing in any tier touches the other five task definitions, the execution
role, or the Secrets Manager secret.
