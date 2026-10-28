#!/usr/bin/env bash
# Skaffold custom builder: regenerate copied EE inputs before every image build.
set -euo pipefail

repo=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)
cd -- "$repo"
: "${IMAGE:?Skaffold must provide IMAGE}"
: "${PUSH_IMAGE:?Skaffold must provide PUSH_IMAGE}"

# A fresh context also drops deleted collection/vendor files. Keep it outside
# the watched sources so generation cannot cause a watch/rebuild loop.
context=$(mktemp -d "${TMPDIR:-/tmp}/osac-aap-ee.XXXXXX")
trap 'rm -rf -- "$context"' EXIT
uv tool run --from "ansible-builder~=3.0" ansible-builder create \
    -f osac-aap/execution-environment/execution-environment.yaml \
    --context "$context"

platform_args=()
if [[ -n "${PLATFORMS:-}" ]]; then
    platform_args+=(--platform "$PLATFORMS")
fi
docker build --tag "$IMAGE" "${platform_args[@]}" "$context"
if [[ "$PUSH_IMAGE" == true ]]; then
    docker push "$IMAGE"
fi
