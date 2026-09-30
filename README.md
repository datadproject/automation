# Datadog Lambda Forwarder

Files:
- `datadog-forwarder.tf`
- `variables-forwarder.tf`
- `ecs.tfvars.forwarder.example`

Existing `datadog.tf`:
- Keep the Datadog Agent for APM/metrics.
- Keep the application container on `awslogs`.
- Do not enable direct Datadog application log collection at the same time, or logs can be duplicated.
- Log path: ECS -> CloudWatch Logs -> Datadog Forwarder Lambda -> Datadog.

Before apply:
- Replace the placeholder CloudWatch log group, subnet IDs, and security group IDs.
- Ensure the Forwarder subnets can reach the corporate proxy.
- Ensure the Forwarder can reach Secrets Manager.
