# Datadog on ECS Fargate — backend services only, GovCloud

```
ngdc-datadog-ecs-sidecar-module/       # publish as its own repo
scripts/mirror-images-govcloud.sh      # RUN THIS FIRST
consumer-fatw-ecs/
  .gitlab-ci.yml                       # your file, 5 marked changes
  dev/
    datadog.tf                         # NEW -- drop in as-is
    .terraformrc.tmpl                  # marked-up version of yours
    ecs.tfvars.datadog-additions       # what to add to your tfvars
    variables.tf.datadog-additions     # what to add to your variables.tf
    task-definitions-PATCH.md          # the merge into your existing TD code
```

Additions-only files rather than whole-file replacements, because your `dev/`
already has working content I can't see.

---

## GovCloud changes four things

That `arn:aws-us-gov:elasticloadbalancing:us-gov-...` in your tfvars is the
most important detail in the screenshots. Every one of these fails silently or
confusingly rather than with a clear error.

**1. `dd_site` must be `ddog-gov.com`.** Datadog for Government is a
physically separate instance with its own org and its own API keys. If your
EKS clusters report to `datadoghq.com`, **the same secret will not work** — a
commercial key authenticates against nothing on the gov site. Symptom: agent
healthy, zero data. You likely need a second secret,
`platform/datadog/gov-api-key`. Confirm which Datadog org this ECS estate
belongs to before anything else.

There's a `validation` block that fails the plan if the region is `us-gov-*`
and `dd_site` isn't `ddog-gov.com`.

**2. `public.ecr.aws` is not reachable from GovCloud.** Neither is `gcr.io`.
Mirroring is now mandatory, not a hardening step —
`scripts/mirror-images-govcloud.sh` handles it. Variable validations reject
any image starting `public.ecr.aws` or `gcr.io` at plan time rather than
letting you discover it as `CannotPullContainerError`.

**3. IAM policy ARNs use the `aws-us-gov` partition.**
`arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy` does
not exist there. `datadog.tf` declares `data "aws_partition" "current"`; the
patch file shows the substitution. **Grep the whole repo for `arn:aws:`** —
anything hardcoded is a latent bug across all four env directories.

**4. Log intake host** becomes `http-intake.logs.ddog-gov.com`. Derived from
`dd_site` automatically, no action needed.

---

## Backend-only, cleanly

`datadog.tf` filters your existing `ecs_service` map:

```hcl
locals {
  dd_services = {
    for name, svc in var.ecs_service : name => svc
    if try(svc.datadog_enabled, false)
  }
}

module "datadog" {
  for_each = local.dd_services
  ...
}
```

`frontend_service` has no `datadog_enabled` key, so `try()` returns false and
it's excluded. **The plan diff for frontend should be empty.** If it isn't,
the conditional is leaking — that's your review gate.

`for_each` on a module only works because the module declares no configured
provider block. That constraint from earlier is now load-bearing rather than
theoretical, and it's another reason to audit
`ngdc-ecs-cluster-module/provider.tf`.

Two sanity outputs:

```
terraform output datadog_enabled_services   # expect ["backend_service"]
terraform output datadog_task_sizing        # expect legal Fargate pairs
```

---

## A bug in your current tfvars

`frontend_service.autoscaling` (screenshot lines 279–280) declares
`min_capacity` **twice** — `1` then `2`. The second is almost certainly meant
to be `max_capacity`. HCL takes the last value, so you have `min_capacity = 2`
and no maximum at all. Unrelated to this work but worth the same MR.

---

## The four env directories

`dev/ prod/ stage/ test/` each get their own copy of `datadog.tf`. Roll
`dev` → `test` → `stage` → `prod`, and only after backend telemetry is
confirmed arriving at each stage.

That duplication is the real smell here — four near-identical copies of the
same root config drifting independently is exactly how `stage` ends up with a
`Revert "added data.tf..."` commit. Worth a follow-up ticket to collapse them
into one root with per-env tfvars, but not in this change.

---

## Sizing

Sidecars add **192 CPU / 640 MiB** to backend tasks only. Fargate accepts a
fixed allowlist of pairs:

```
832  + 192 = 1024   OK
1408 + 640 = 2048   OK
```

`terraform output datadog_task_sizing` confirms before apply.

---

## Order of operations

1. **Confirm the Datadog org.** Commercial or GovCloud? This determines
   whether you need a new API key secret. Everything else is wasted work if
   this is wrong.
2. Run `scripts/mirror-images-govcloud.sh`; paste the digests into
   `ecs.tfvars`.
3. Publish the module, tag `v1.0.0`.
4. Grep for `arn:aws:` across all four env dirs; fix with
   `data.aws_partition`.
5. Add `datadog.tf` + tfvars/variables additions to `dev/` only.
6. MR → `plan`. Verify: frontend diff empty, backend gains two containers,
   backend task size 1024/2048.
7. Manual `deploy`. Confirm in Datadog that `backend-service` appears under
   APM with `env:dev`.

## Still outstanding from earlier

- The `terraform workspace` / http-backend question — with four env
  directories *and* workspaces, it's now worth confirming what state file each
  environment actually writes to.
- `plan -out=tfplan` / `apply tfplan` so the manual gate approves the plan
  that actually runs.
- FireLens removes backend app logs from CloudWatch. In a GovCloud estate
  there is a decent chance something in your compliance posture expects them
  there. `dd_enable_logs = false` keeps awslogs if so.
