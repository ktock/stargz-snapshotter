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
FIO_TEST_NODE_NAME="fio-simple-node"
FIO_TEST_SERVICE="fio_simple_service"

RESULT_DIR="${BENCHMARK_RESULT_DIR:-}"
if [ "${RESULT_DIR}" == "" ] ; then
    echo "Specify BENCHMARK_RESULT_DIR"
    exit 1
fi

DOCKER_COMPOSE_YAML=$(mktemp)
FIO_CONF=$(mktemp)
function cleanup {
    ORG_EXIT_CODE="${1}"
    rm "${DOCKER_COMPOSE_YAML}" || true
    rm "${FIO_CONF}" || true
    exit "${ORG_EXIT_CODE}"
}
trap 'cleanup "$?"' EXIT SIGHUP SIGINT SIGQUIT SIGTERM

cat <<EOF > "${DOCKER_COMPOSE_YAML}"
version: "3.4"
services:
  ${FIO_TEST_SERVICE}:
    build:
      context: "${CONTEXT}containerd"
      dockerfile: Dockerfile
    container_name: ${FIO_TEST_NODE_NAME}
    privileged: true
    working_dir: /go/src/github.com/containerd/stargz-snapshotter
    entrypoint: ./script/fio-simple/containerd/entrypoint.sh
    tmpfs:
    - /tmp:exec,mode=777
    volumes:
    - /dev/fuse:/dev/fuse
    - "${RESULT_DIR}:/output"
    - "${REPO}:/go/src/github.com/containerd/stargz-snapshotter:ro"
    - type: volume
      source: fio-simple-containerd-data
      target: /var/lib/containerd
      volume:
        nosuid: false
    - type: volume
      source: fio-simple-containerd-stargz-grpc-data
      target: /var/lib/containerd-stargz-grpc
      volume:
        nosuid: false
    - type: volume
      source: fio-simple-containerd-stargz-grpc-status
      target: /run/containerd-stargz-grpc
      volume:
        nosuid: false
volumes:
  fio-simple-containerd-data:
  fio-simple-containerd-stargz-grpc-data:
  fio-simple-containerd-stargz-grpc-status:
EOF

echo "Testing..."
FAIL=
if ! ( cd "${CONTEXT}" && \
           docker-compose -f "${DOCKER_COMPOSE_YAML}" build ${DOCKER_BUILD_ARGS:-} \
                          "${FIO_TEST_SERVICE}" && \
           docker-compose -f "${DOCKER_COMPOSE_YAML}" up --abort-on-container-exit ) ; then
    FAIL=true
fi
docker-compose -f "${DOCKER_COMPOSE_YAML}" down -v
if [ "${FAIL}" == "true" ] ; then
    exit 1
fi

exit 0
