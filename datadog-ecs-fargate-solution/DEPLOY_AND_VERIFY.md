# Deploy and verify

## Phase 1: Agent sidecar only

1. Set `dd_enable_logs = false`.
2. Run `terraform init -upgrade` so the pinned Datadog module revision is fetched.
3. Run `terraform validate`.
4. Run `terraform plan`.
5. Inspect the plan. Only the selected backend task definition should receive a
   new revision, the backend service should update to it, and one new inline
   execution-role policy should be created.
6. Apply.

Expected containers in the backend task:

- `backend`
- `datadog-agent`

The frontend, scraper, importer, exporter, and DB-import task definitions should
remain unchanged.

## AWS checks

```bash
aws ecs describe-services \
  --cluster NGDC-FATW-ECS-CLUSTER \
  --services backend-service \
  --region us-gov-west-1
```

```bash
aws ecs describe-task-definition \
  --task-definition toolkit-dev-backend \
  --region us-gov-west-1 \
  --query 'taskDefinition.containerDefinitions[].{name:name,image:image,essential:essential,secrets:secrets,ports:portMappings}'
```

Confirm that the Agent has `DD_API_KEY` as a secret reference rather than a
plaintext environment value.

## Datadog checks

1. In Infrastructure > Containers, filter by `env:dev` and
   `service:backend-service`.
2. Confirm that the Fargate task and both containers appear.
3. Check the Agent container's CloudWatch log stream for authentication, DNS,
   TLS, or proxy errors if it does not appear.

## Phase 2: Direct logs with FireLens

1. Set the Fluent Bit image.
2. Set `dd_enable_logs = true`.
3. If required, set both the Agent proxy and Fluent Bit proxy values.
4. Plan and apply again.

Expected containers:

- `backend`
- `datadog-agent`
- `log_router`

The backend log driver becomes `awsfirelens`. Search Datadog Logs for:

```text
env:dev service:backend-service
```

## APM interpretation

The task definition exposes the Agent receiver and supplies `DD_AGENT_HOST`,
`DD_ENV`, `DD_SERVICE`, and `DD_VERSION` to the application. If metrics and logs
work but APM has no services, the infrastructure path is working and the
application image does not contain an active Datadog tracer.

