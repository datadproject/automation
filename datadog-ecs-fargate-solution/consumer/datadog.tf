module "datadog_backend" {
  source = "git::<DATADOG_MODULE_GIT_URL>?ref=<PINNED_COMMIT>"

  aws_region                    = var.region
  dd_api_key_secret_name        = var.dd_api_key_secret_name
  dd_api_key_secret_json_key    = var.dd_api_key_secret_json_key
  dd_site                       = var.dd_site
  dd_env                        = var.dd_env
  dd_service                    = var.dd_service
  dd_version                    = var.dd_version
  log_source                    = var.dd_log_source
  agent_image                   = var.dd_agent_image
  fluentbit_image               = var.dd_fluentbit_image
  enable_apm                    = true
  enable_dogstatsd              = false
  enable_logs                   = var.dd_enable_logs
  agent_essential               = false
  app_wait_for_agent            = false
  app_depends_on_log_router     = true
  agent_proxy_https             = var.dd_agent_proxy_https
  agent_proxy_http              = var.dd_agent_proxy_http
  agent_proxy_no_proxy          = var.dd_agent_proxy_no_proxy
  fluentbit_proxy               = var.dd_fluentbit_proxy
  kms_key_arn                   = var.dd_api_key_kms_key_arn
}

# This manages only a new inline policy on the existing execution role.
# It does not create, replace, or import the role.
resource "aws_iam_role_policy" "datadog_secret_access" {
  name   = "FATW-Datadog-API-Key-Access"
  role   = var.ecs_execution_role_name
  policy = module.datadog_backend.execution_role_policy_json
}

