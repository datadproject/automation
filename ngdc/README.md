# Datadog on ECS Fargate — backend services, GovCloud, four environments

## What changed in this revision

You made two corrections and both were right.

### 1. File layout now matches your convention

Module, mirroring `ngdc-ecs-cluster-module`:

```
provider.tf   required_providers only, no provider block
variables.tf  inputs
data.tf       lookups only (partition, secret, policy document)
locals.tf     all computation (container definitions)
main.tf       resources only (log group, IAM inline policy)
outputs.tf
```

Consumer, per env directory:

```
datadog.tf                     the module call, and nothing else
locals.tf.datadog-additions    dd_services filter + helper maps
data.tf.datadog-additions      aws_partition
outputs.tf.datadog-additions   the pre-apply review gate
variables.tf.datadog-additions
ecs.tfvars.datadog-additions   the only per-env file
```

The previous `datadog.tf` bundled locals, data sources, resources and the
module call into one file. That was my convenience, not your standard.

### 2. The log group and IAM policy moved into the module

My earlier reasoning was sloppy. The rule I stated was "the module must not
create IAM." The actual rule is narrower: **the module must not create the
role.**

Creating an *inline policy on a role it was handed* is safe — inline policies
are namespaced per role, so there's no `EntityAlreadyExists` class of
collision and no ambiguity about ownership. I over-applied the constraint and
pushed work onto every consumer that belonged in the module.

So now:

| | Owner | Why |
|---|---|---|
| Execution **role** | consumer | one owner per role, always |
| Secret-read inline **policy** | module | it's the module's own requirement |
| Sidecar log group | module | exists only because sidecars need it |
| Task definition | consumer | it's your app |

The policy name is service-scoped (`datadog-secret-read-<service>`) so two
module instances attaching to a shared execution role can't overwrite each
other. Both are escapable: `execution_role_name = null` returns the policy
JSON for you to attach, and `sidecar_log_group = "..."` reuses an existing
group if a central team owns log-group creation.

Net effect on the consumer: `datadog.tf` is now a single `module` block. No
resources at all.

---

## The rest of the design

`datadog.tf` is byte-identical across dev/test/stage/prod — verified. Every
environment difference is in `ecs.tfvars`, so `diff dev/datadog.tf
prod/datadog.tf` stays empty forever and catches hand-edits.

**Backend only.** `local.dd_services` filters your `ecs_service` map on
`datadog_enabled`. `frontend_service` has no such key, so `try()` returns
false and it's excluded — no module instance, no sidecars, no plan diff. That
empty frontend diff is your review gate.

**GovCloud.** `dd_site = "ddog-gov.com"` (separate Datadog org, separate API
key — a commercial key authenticates against nothing). Private ECR images
only. `data.aws_partition.current` for ARNs; grep every env dir and the
cluster module for hardcoded `arn:aws:`.

**Sizing.** Sidecars add 192 CPU / 640 MiB to backend tasks only. Fargate
takes a fixed allowlist of pairs, so `terraform output datadog_task_sizing`
before every apply.

---

## Order of operations

1. **State files.** Your `TF_ADDRESS` has no env component and the http
   backend doesn't support workspaces — confirm dev/test/stage/prod aren't
   sharing one state file. This blocks everything else.
2. **Datadog org.** Commercial or `ddog-gov.com`? Determines whether you need
   a new API key secret.
3. Resolve your private image tags to sha256 digests. Same digests in all
   four envs.
4. Publish the module, tag `v1.0.0`.
5. Grep for `arn:aws:` across all env dirs and the cluster module.
6. Apply `task-definitions-PATCH.md` — the merge into whatever renders
   `container_definitions`. Check `grep -rl aws_ecs_task_definition` first;
   if it's in the cluster module, that needs an additive optional input.
7. `dev` only. Plan → frontend diff empty, backend gains two containers,
   task size 1024/2048.
8. Deploy dev, confirm `backend-service` in Datadog APM with `env:dev`, soak,
   then test → stage → prod one at a time.

## Still open

- **FireLens removes backend app logs from CloudWatch.** In prod GovCloud
  that's where a retention or audit requirement is most likely to bite.
  `dd_enable_logs = false` keeps awslogs; metrics and APM unaffected.
- **APM needs the app team** — the sidecar receives traces but can't create
  them. Metrics and logs need nothing from them, so shipping those first is
  the lower-friction path.
- `plan -out=tfplan` / `apply tfplan`, so the manual gate approves the plan
  that actually runs.
