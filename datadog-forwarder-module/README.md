# Shared Datadog Forwarder

CloudWatch Logs -> Datadog Forwarder -> `http://10.111.225.254:8080` ->
`ddog-gov.com`, in AWS GovCloud `us-gov-west-1`.

This package is separate from both ECS fragment modules. FE/BE containers keep
`awslogs`; the Datadog Agent sidecar stays enabled for APM. The ECS consumer
examples now explicitly disable their legacy FireLens option. Do not enable
`dd_enable_logs` or add a `log_router` for this architecture.

- [Reusable wrapper](modules/datadog-forwarder/README.md), using official
  `DataDog/log-lambda-forwarder-datadog/aws` version `2.0.4`.
- [Shared environment example](examples/forwarder-multi-env/main.tf).

Deploy one instance per AWS account/region from shared infrastructure state,
not one instance per ECS service. Pass all relevant DEV/QA/UAT/PROD log groups
in the example's `ecs_log_groups` map. Keys can identify separate FE/BE groups
as well as environments. The existing `ngdc` examples call QA/UAT `test/stage`;
use the actual log-group names rather than renaming deployed environments.

Supply the existing plaintext Secrets Manager API-key secret name, VPC and
private subnet IDs. The dedicated security group has no ingress and only TCP
8080 egress to `10.111.225.254/32`. Every subscription uses `filter_pattern = ""`.

The proxy must reach both Datadog and Secrets Manager. See the wrapper README
for proxy/TLS and upstream IAM considerations. Configure an approved backend
and review a real deployment plan before applying. No infrastructure has been
deployed by this integration.

This architecture supersedes the older FireLens/Tier B rollout instructions
elsewhere in the repository. Existing fragment-module capabilities are retained
for compatibility, but the supplied consumers do not activate them.
