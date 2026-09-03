# Pipeline errors — what each one is and who broke it

Five distinct failures in that job. Two are my bugs, three are wiring.

---

## 1. `Invalid precondition expression` — MY BUG

```
on .terraform/modules/datadog/main.tf line 41, in resource "terraform_data" "validate_proxy_pairing":
  41:  condition = false
```

Terraform rejects a precondition whose condition is a constant. It must refer
to at least one object from elsewhere, or its result would be fixed.

I used the pattern `count = <bad case> ? 1 : 0` plus `condition = false`, which
looks clever and does not plan. It never worked. I should have caught it.

**Fixed** in the new `main.tf`: one `terraform_data "validations"` resource, no
`count`, and each condition written as a real expression over the variables:

```hcl
condition = !(var.enable_logs && var.agent_proxy_https != null && var.fluentbit_proxy == null)
```

## 2. `Variables not allowed` / `Unsuitable value type` — MY BUG

```
on variables.tf line 193, in variable "image_tag":
 198:   Wire from CI: export TF_VAR_image_tag="${CI_COMMIT_SHORT_SHA}"
Variables may not be used here.
```

I wrote `${CI_COMMIT_SHORT_SHA}` inside a heredoc `description`. Terraform
interpolates `${...}` inside heredocs, so it tried to resolve
`CI_COMMIT_SHORT_SHA` as a Terraform reference.

**Fixed**: the braces are gone —

```
Wire from CI: export TF_VAR_image_tag="$CI_COMMIT_SHORT_SHA"
```

(`$${CI_COMMIT_SHORT_SHA}` would also work; dropping the braces is clearer.)

I checked every other `.tf` file for the same pattern — the remaining `${...}`
occurrences are all intentional Terraform references.

---

## 3. `Module is incompatible with count, for_each, and depends_on`

```
The module at module.datadog is a legacy module which contains its own
local provider configurations
git::https://...@ngdc-gitlab-nonprod.fsa.mrd/ngdc/modules/logging/datadog-ecs.git?ref=sunday.ebosele-main-patch-ecaf
```

The module you published has a `provider "aws" {}` block. Almost certainly
copied over from `ngdc-ecs-cluster-module/provider.tf`, which does have one.

**Fix**: in `ngdc/modules/logging/datadog-ecs`, delete the provider block.
Keep `terraform { required_providers { ... } }` and nothing else. The new
`provider.tf` in this zip has a comment block explaining exactly this, so it
does not get re-added.

This is precisely the constraint I flagged earlier about auditing
`ngdc-ecs-cluster-module/provider.tf` — it has now bitten in the other
direction.

## 4. `Unsupported argument` × 7 — wrong content in `datadog.tf`

```
on datadog.tf line 56: dd_site                = "ddog-gov.com"
on datadog.tf line 64: dd_api_key_secret_name = "fatw_datadog_api_key"
on datadog.tf line 76: dd_agent_image         = "093737011827.dkr.ecr..."
on datadog.tf line 91: dd_agent_proxy_https   = null
```

These are **literal values with `dd_`-prefixed names**. That is the content of
`ecs.tfvars.datadog-additions`, and it has ended up inside the
`module "datadog"` block in `datadog.tf`.

Two different naming layers got merged:

| Layer | Names | Belongs in |
|---|---|---|
| tfvars | `dd_agent_image`, `dd_agent_proxy_https`, `dd_log_source` | `ecs.tfvars` |
| module args | `agent_image`, `agent_proxy_https`, `log_source` | `datadog.tf` |

The module call passes `agent_image = var.dd_agent_image`. Consumer variable
names carry the `dd_` prefix; module argument names do not.

My "paste into" instructions were ambiguous about which file each block went
to. Corrected `datadog.tf` is in this zip — copy it whole rather than editing
what is there.

## 5. Module source is a git repo, not a relative path

The error shows the source resolving to
`ngdc/modules/logging/datadog-ecs.git?ref=sunday.ebosele-main-patch-ecaf`,
not the `../../ngdc-datadog-ecs-sidecar-module` my `datadog.tf` assumed. You
published it separately, which is fine and arguably better.

`datadog.tf` now takes the source from a variable so the path is not
hardcoded, and `ecs.tfvars` sets it. **Move off the branch ref before prod** —
`?ref=sunday.ebosele-main-patch-ecaf` means a push to that branch changes
every consumer's next apply. Tag it.

---

## Order to fix

1. Delete the `provider "aws"` block from the published `datadog-ecs` module.
2. Push the corrected module files from this zip to that repo (`main.tf` and
   `variables.tf` are the ones that changed).
3. Replace `fatw-ecs/dev/datadog.tf` with the one from this zip.
4. Move the `dd_*` literals out of `datadog.tf` and into `dev/ecs.tfvars`.
5. Re-run `validate`.

Expect the next run to surface any remaining `Unsupported argument` errors
one layer down — those would be genuine mismatches between the published
module's `variables.tf` and the call. Send them and I will reconcile.
