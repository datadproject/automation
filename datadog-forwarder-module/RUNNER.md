# Runner setup and validation

Use `datadog-forwarder-module/examples/forwarder-multi-env` as the Terraform
root. It directly calls Datadog's official module, pinned at 2.0.4. That version
was confirmed published and downloaded from the Terraform Registry.

## Runner connectivity

The Lambda's `dd_http_proxy_url` does not configure Terraform or GitLab.
On the corporate runner, configure the Terraform process separately:

```sh
export HTTP_PROXY=http://10.111.225.254:8080
export HTTPS_PROXY=http://10.111.225.254:8080
export http_proxy="$HTTP_PROXY"
export https_proxy="$HTTPS_PROXY"
```

Preserve approved NO_PROXY entries for internal endpoints and credential
services. Do not bypass the proxy for public Registry hosts that require it.
Install the corporate CA in the runner trust store if TLS inspection is used;
do not disable TLS verification.

The runner requires HTTPS access to `registry.terraform.io`, `github.com` and
module download redirect hosts, and `releases.hashicorp.com`. During plan the
official module also reads:

`https://datadog-opensource-asset-versions.s3.us-east-1.amazonaws.com/forwarder/versions.json`

AWS credentials and resources require their appropriate GovCloud API endpoints.
A provider mirror alone does not mirror modules or that version-metadata JSON.
If public access is prohibited, use the organization's approved distribution
process. A version change cannot fix a blocked endpoint. Capture the complete
initialization error, including its URL, to distinguish connectivity, proxy
authentication, certificate and module-resolution failures.

## Checks without deployment

Tested with Terraform 1.13.3. The lockfile records AWS 6.66.0 and HTTP 3.6.2.

```sh
terraform init -backend=false -input=false
terraform fmt -check
terraform validate
terraform test
```

The four Forwarder tests plan the actual official module with mocked AWS APIs
and overridden HTTP metadata. They check all-event subscriptions, proxy-only
egress and rejection of recursive/duplicate groups and absent private subnets.
They do not prove real account permissions, network reachability or delivery.

Separately run init, validate and test from
`ngdc/ngdc-datadog-ecs-sidecar-module`. Its test verifies default APM, only the
Agent sidecar, no log_router dependency and no app log-driver override.
NGDC consumers use a literal local module source, supported by Terraform 1.13.
When copying the snippets into another repository, use its actual literal path
or a pinned Git URL; `source = var.dd_module_source` is not supported there.

## Deployment

Supply real values from the target account using `terraform.tfvars.example`:
existing secret name, VPC, private subnets and existing FE/BE log-group names.
The secret must contain the raw API key; the Forwarder does not use the
sidecar's optional JSON-key selector. No secret value is fetched into state.

Configure an approved remote backend and credentials, initialize again, and
review a real plan. Keep one shared state per account/region, separate from
per-service ECS deployments. The existing ECS consumer files are snippets that
still depend on the ECS variables/task definitions described in ngdc/INSTRUCTIONS.md.

Verify private-subnet routing and proxy access to Datadog and Secrets Manager:
the Lambda SG only allows TCP 8080 to the proxy, not direct 443 endpoint access.
Also verify secret/KMS permissions, Lambda-layer availability and subscription
capacity. The retained upstream proxy setting skips Datadog TLS validation;
set `dd_skip_ssl_validation = false` when certificate trust permits it.

If the previous wrapper was applied, migrate state addresses before using this
direct-call layout; do not accept destruction/recreation caused only by address
changes. No automated state migration or infrastructure apply is included here.

After an approved DEV deployment, emit known FE/BE events and verify them in
CloudWatch and Datadog, then confirm existing APM traces still arrive. This live
check is required to establish end-to-end delivery in the target environment.
