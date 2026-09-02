#!/usr/bin/env bash
#
# GOVCLOUD IMAGE MIRROR -- run this BEFORE the first apply.
#
# public.ecr.aws and gcr.io are not reachable from GovCloud regions. Without
# this step the tasks fail to pull and you get CannotPullContainerError.
#
# Run from a COMMERCIAL-side host that can reach both public.ecr.aws and your
# GovCloud ECR, or pull to a laptop and push from there. Two sets of AWS
# credentials are needed.

set -euo pipefail

# ------------------------------------------------------------------
GOV_ACCOUNT_ID="123456789012"
GOV_REGION="us-gov-west-1"

AGENT_VERSION="7.66.1"
FLUENTBIT_VERSION="2.32.5"     # pin; do not mirror :stable
# ------------------------------------------------------------------

GOV_REGISTRY="${GOV_ACCOUNT_ID}.dkr.ecr.${GOV_REGION}.amazonaws.com"

echo ">> Pulling from public registries (commercial-side network)"
docker pull "public.ecr.aws/datadog/agent:${AGENT_VERSION}"
docker pull "public.ecr.aws/aws-observability/aws-for-fluent-bit:${FLUENTBIT_VERSION}"

echo ">> Creating GovCloud ECR repos if absent"
for REPO in datadog/agent datadog/aws-for-fluent-bit; do
  aws ecr describe-repositories --repository-names "${REPO}" \
      --region "${GOV_REGION}" >/dev/null 2>&1 \
    || aws ecr create-repository \
         --repository-name "${REPO}" \
         --image-tag-mutability IMMUTABLE \
         --image-scanning-configuration scanOnPush=true \
         --region "${GOV_REGION}"
done

echo ">> Logging into GovCloud ECR"
aws ecr get-login-password --region "${GOV_REGION}" \
  | docker login --username AWS --password-stdin "${GOV_REGISTRY}"

echo ">> Tag and push"
docker tag "public.ecr.aws/datadog/agent:${AGENT_VERSION}" \
           "${GOV_REGISTRY}/datadog/agent:${AGENT_VERSION}"
docker push "${GOV_REGISTRY}/datadog/agent:${AGENT_VERSION}"

docker tag "public.ecr.aws/aws-observability/aws-for-fluent-bit:${FLUENTBIT_VERSION}" \
           "${GOV_REGISTRY}/datadog/aws-for-fluent-bit:${FLUENTBIT_VERSION}"
docker push "${GOV_REGISTRY}/datadog/aws-for-fluent-bit:${FLUENTBIT_VERSION}"

echo
echo ">> Digests to paste into ecs.tfvars (pin by digest, not tag):"
for REPO in datadog/agent datadog/aws-for-fluent-bit; do
  DIGEST=$(aws ecr describe-images --repository-name "${REPO}" \
    --region "${GOV_REGION}" \
    --query 'sort_by(imageDetails,&imagePushedAt)[-1].imageDigest' --output text)
  echo "   ${GOV_REGISTRY}/${REPO}@${DIGEST}"
done
