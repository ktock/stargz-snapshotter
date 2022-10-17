#!/bin/bash

#   Copyright The containerd Authors.

#   Licensed under the Apache License, Version 2.0 (the "License");
#   you may not use this file except in compliance with the License.
#   You may obtain a copy of the License at

#       http://www.apache.org/licenses/LICENSE-2.0

#   Unless required by applicable law or agreed to in writing, software
#   distributed under the License is distributed on an "AS IS" BASIS,
#   WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
#   See the License for the specific language governing permissions and
#   limitations under the License.

set -euo pipefail

CONTEXT="$( cd "$( dirname "${BASH_SOURCE[0]}" )" >/dev/null 2>&1 && pwd )/"
REPO="${CONTEXT}../../"

TARGET_IMAGE="${1}"
SOURCE_REGISTRY="${2}"
RES="${3}"

BENCH_METADATA_STORE="${METADATA_STORE:-memory}"

SCRIPTS_DIR="./script/image-benchmark/"
CONTAINER_NAME="benchenv"
WORKING_REGISTRY="registry2-bench"

DOCKER_COMPOSE_YAML=$(mktemp)
function cleanup {
    local ORG_EXIT_CODE="${1}"
    rm "${DOCKER_COMPOSE_YAML}" || true
    exit "${ORG_EXIT_CODE}"
}
trap 'cleanup "$?"' EXIT SIGHUP SIGINT SIGQUIT SIGTERM

cat <<EOF > "${DOCKER_COMPOSE_YAML}"
version: "3.4"
services:
  ${CONTAINER_NAME}:
    build:
      context: "${REPO}"
      target: demo
    container_name: ${CONTAINER_NAME}
    privileged: true
    working_dir: /go/src/github.com/containerd/stargz-snapshotter
    init: true
    entrypoint: ["sleep", "infinity"]
    volumes:
    - /dev/fuse:/dev/fuse
    - "${REPO}:/go/src/github.com/containerd/stargz-snapshotter:ro"
    - "bench-containerd-data:/var/lib/containerd"
    - "bench-containerd-stargz-grpc-data:/var/lib/containerd-stargz-grpc"
  registry2_bench:
    image: registry:2
    container_name: ${WORKING_REGISTRY}
volumes:
  bench-containerd-data:
  bench-containerd-stargz-grpc-data:
EOF

echo "Running ${MODE:-} ..."
FAIL=
if [ "${MODE:-}" == "1" ] ; then
    if ! ( docker-compose -f "${DOCKER_COMPOSE_YAML}" up -d && \
               docker exec "${CONTAINER_NAME}" /bin/bash ./script/image-benchmark/init.sh && \
               docker exec "${CONTAINER_NAME}" /bin/bash -c "mkdir -p /res" && \
               docker exec "${CONTAINER_NAME}" /bin/bash -c "METADATA_STORE=${BENCH_METADATA_STORE} ${SCRIPTS_DIR}/prepare.sh && sleep 2 && ctr-remote i pull ${SOURCE_REGISTRY}/${TARGET_IMAGE}" && \
               docker exec "${CONTAINER_NAME}" /bin/bash -c "go run ${SCRIPTS_DIR}/run.go ${SOURCE_REGISTRY}/${TARGET_IMAGE} | tee -a /res/res" && \
               docker exec "${CONTAINER_NAME}" /bin/bash -c "ls /res" && \
               docker exec "${CONTAINER_NAME}" /bin/bash -c "tar -c /res"  | tar -C "${RES}" -xvf -
         ) ; then
        FAIL=true
    fi
else
    if ! ( docker-compose -f "${DOCKER_COMPOSE_YAML}" up -d && \
               docker exec "${CONTAINER_NAME}" /bin/bash ./script/image-benchmark/init.sh && \
               docker exec "${CONTAINER_NAME}" /bin/bash -c "mkdir -p /res" && \
               docker exec "${CONTAINER_NAME}" /bin/bash -c "METADATA_STORE=${BENCH_METADATA_STORE} ${SCRIPTS_DIR}/run-tar.sh /res/ $TARGET_IMAGE $SOURCE_REGISTRY ${WORKING_REGISTRY}:5000" && \
               docker exec "${CONTAINER_NAME}" /bin/bash -c "ls /res" && \
               docker exec "${CONTAINER_NAME}" /bin/bash -c "tar -c /res"  | tar -C "${RES}" -xvf -
         ) ; then
        FAIL=true
    fi
fi
docker-compose -f "${DOCKER_COMPOSE_YAML}" down -v
if [ "${FAIL}" == "true" ] ; then
    exit 1
fi
exit 0
