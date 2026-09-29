# Reusable Datadog Forwarder Wrapper

Compatibility wrapper from the first integration. The recommended
[shared deployment](../../examples/forwarder-multi-env/main.tf) now calls the
official Datadog module directly and does not use this wrapper.

Reusable wrapper around Datadog's official AWS Log Lambda Forwarder Terraform module.

## Design

- Keep ECS application containers on `awslogs` so logs remain in CloudWatch.
- Use one Datadog Forwarder per AWS account/region unless isolation requires more.
- Create one CloudWatch Logs subscription per log group.
- An empty `filter_pattern` forwards all events from the log group, including FE and BE streams in the same group.
- The ECS Datadog sidecar remains responsible for APM/metrics; the Forwarder handles CloudWatch Logs -> Datadog Logs.

## Requirements

- Terraform >= 1.9
- AWS provider >= 6.21
- Existing Datadog API key in AWS Secrets Manager as plaintext
- Private subnets that can reach your corporate proxy
- The proxy must reach both Datadog and the regional Secrets Manager HTTPS API.
  Direct VPC endpoint access on TCP 443 is not allowed by the proxy-only security
  group. Verify proxy routing, DNS and AWS SDK certificate trust before deployment.

## Example

See `../../examples/forwarder-multi-env`. The provider defaults to `us-gov-west-1`
and the wrapper derives its region from that provider. Use one shared state per
account/region; combine DEV, QA, UAT and PROD groups when they share an account.
Use separate states and providers for environments in different accounts.

The default dedicated security group has no inbound rules and only TCP 8080
egress to `10.111.225.254/32`. Supply private subnets with a route to that proxy.
If overriding the proxy URL, CIDR or port, keep all three consistent.
Each unique log group gets a subscription with literal `filter_pattern = ""`.
ARNs with or without a trailing `:*` are supported. Groups must belong to the
same GovCloud account/region. The Forwarder's own group is rejected to prevent
recursive forwarding. Check existing subscription quotas before deployment.

## Package review

Adapted from `datadog-forwarder-module.zip`. Fixed its `coalesce("", "")`
failure by setting the subscription filter directly to the required empty string.
The security group is always created and no additional groups are attached.
The secret value is never fetched into Terraform state; only its ARN is passed.

The package's `dd_skip_ssl_validation = true` default is retained to match the
upstream proxy guidance. This disables Datadog endpoint certificate validation;
set it to false when proxy and certificate trust configuration support it.

Upstream version 2.0.4 creates its own IAM and invocation permissions, including
broad S3 read/KMS decrypt defaults and account-wide CloudWatch invocation access.
The wrapper's per-group permissions do not narrow those upstream permissions.
The Terraform module pin does not independently pin the Lambda layer version.
Inspect these resources in the deployment plan against account requirements.

The Forwarder package does not own ECS resources. The repository's ECS consumer
examples keep the Agent for APM and disable their legacy FireLens option so FE/BE
logs continue through `awslogs`. Do not add FireLens or `log_router`.

Before applying in your deployment environment, initialize and validate the
example, supply actual IDs using `terraform.tfvars.example`, configure an
approved remote backend and review the plan. Verify secret/KMS access, available
Lambda layer, proxy connectivity and end-to-end log delivery in DEV first.
