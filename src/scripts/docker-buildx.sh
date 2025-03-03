#!/bin/bash
ORB_EVAL_REGION=$(eval echo "${ORB_EVAL_REGION}")
ORB_EVAL_REPO=$(eval echo "${ORB_EVAL_REPO}")
ORB_EVAL_TAG=$(eval echo "${ORB_EVAL_TAG}")
ORB_EVAL_PATH=$(eval echo "${ORB_EVAL_PATH}")
ORB_EVAL_DOCKERFILE_PATH=$(eval echo "${ORB_EVAL_DOCKERFILE_PATH}")
ORB_VAL_ACCOUNT_URL="${!ORB_ENV_REGISTRY_ID}.dkr.ecr.${ORB_EVAL_REGION}.amazonaws.com"
ORB_EVAL_PUBLIC_REGISTRY_ALIAS=$(eval echo "${ORB_EVAL_PUBLIC_REGISTRY_ALIAS}")
ECR_COMMAND="ecr"
number_of_tags_in_ecr=0
docker_tag_args=""

dockerfile_path=$ORB_EVAL_PATH
if [ "${ORB_EVAL_DOCKERFILE_PATH}" != "." ]; then
  dockerfile_path=$ORB_EVAL_DOCKERFILE_PATH
fi

IFS="," read -ra PLATFORMS <<<"${ORB_VAL_PLATFORM}"
arch_count=${#PLATFORMS[@]}

if [ "${ORB_VAL_PUBLIC_REGISTRY}" == "1" ]; then
  if [ "$arch_count" -gt 1 ]; then
    echo "AWS ECR does not support multiple platforms for public registries. Please specify only one platform and try again"
    exit 1
  fi

  ECR_COMMAND="ecr-public"
  ORB_VAL_ACCOUNT_URL="public.ecr.aws/${ORB_EVAL_PUBLIC_REGISTRY_ALIAS}"
fi

IFS="," read -ra DOCKER_TAGS <<<"${ORB_EVAL_TAG}"
for tag in "${DOCKER_TAGS[@]}"; do
  if [ "${ORB_VAL_SKIP_WHEN_TAGS_EXIST}" = "1" ] || [ "${ORB_VAL_SKIP_WHEN_TAGS_EXIST}" = "true" ]; then
    docker_tag_exists_in_ecr=$(aws "${ECR_COMMAND}" describe-images --profile "${ORB_VAL_PROFILE_NAME}" --registry-id "${!ORB_ENV_REGISTRY_ID}" --region "${ORB_EVAL_REGION}" --repository-name "${ORB_EVAL_REPO}" --query "contains(imageDetails[].imageTags[], '${tag}')")
    if [ "${docker_tag_exists_in_ecr}" = "true" ]; then
      docker pull "${ORB_VAL_ACCOUNT_URL}/${ORB_EVAL_REPO}:${tag}"
      number_of_tags_in_ecr=$((number_of_tags_in_ecr += 1))
    fi
  fi
  docker_tag_args="${docker_tag_args} -t ${ORB_VAL_ACCOUNT_URL}/${ORB_EVAL_REPO}:${tag}"
done

if [ "${ORB_VAL_SKIP_WHEN_TAGS_EXIST}" = "0" ] || [[ "${ORB_VAL_SKIP_WHEN_TAGS_EXIST}" = "1" && ${number_of_tags_in_ecr} -lt ${#DOCKER_TAGS[@]} ]]; then
  if [ "${ORB_VAL_PUSH_IMAGE}" == "1" ]; then
    set -- "$@" --push

    if [ -n "${ORB_VAL_LIFECYCLE_POLICY_PATH}" ]; then
      aws ecr put-lifecycle-policy \
        --repository-name "${ORB_EVAL_REPO}" \
        --lifecycle-policy-text "file://${ORB_VAL_LIFECYCLE_POLICY_PATH}"
    fi

  else
    set -- "$@" --load
  fi

  if [ -n "$ORB_VAL_EXTRA_BUILD_ARGS" ]; then
    ORB_VAL_EXTRA_BUILD_ARGS=$(eval echo "${ORB_VAL_EXTRA_BUILD_ARGS}")
    set -- "$@" ${ORB_VAL_EXTRA_BUILD_ARGS}
  fi

  if [ "${ORB_VAL_PUBLIC_REGISTRY}" == "1" ]; then
    docker buildx build \
      -f "${dockerfile_path}"/"${ORB_VAL_DOCKERFILE}" \
      ${docker_tag_args} \
      --platform "${ORB_VAL_PLATFORM}" \
      --progress plain \
      "$@" \
      "${ORB_EVAL_PATH}"
  else

    if ! docker context ls | grep builder; then
      # We need to skip the creation of the builder context if it's already present
      # otherwise the command will fail when called more than once in the same job.

      docker context create builder
      docker run --privileged --rm tonistiigi/binfmt --install all
      docker --context builder buildx create --use
    fi

    docker --context builder buildx build \
      -f "${dockerfile_path}"/"${ORB_VAL_DOCKERFILE}" \
      ${docker_tag_args} \
      --platform "${ORB_VAL_PLATFORM}" \
      --progress plain \
      "$@" \
      "${ORB_EVAL_PATH}"
  fi
fi
