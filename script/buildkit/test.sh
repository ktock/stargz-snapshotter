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

BUILDKIT_REPO="https://github.com/moby/buildkit"
BUILDKIT_VERSION="08e901325b526c1a7fcc43f71a19a273053b6f2c"
BUILDKIT_BASE_IMAGE_NAME="buildkit-image-base"
BUILDKIT_TEST_IMAGE_NAME="buildkit-image-test"

if [ "${BUILDKIT_NO_RECREATE:-}" != "true" ] ; then
    echo "Preparing node image..."

    docker build -t "${BUILDKIT_BASE_IMAGE_NAME}" \
           --target snapshotter-base \
            ${DOCKER_BUILD_ARGS:-} \
           "${REPO}"
fi

DOCKER_COMPOSE_YAML=$(mktemp)
SS_ROOT_DIR=$(mktemp -d)
TMP_CONTEXT=$(mktemp -d)
function cleanup {
    local ORG_EXIT_CODE="${1}"
    rm "${DOCKER_COMPOSE_YAML}" || true
    rm -rf "${SS_ROOT_DIR}" || true
    rm -rf "${TMP_CONTEXT}" || true
    exit "${ORG_EXIT_CODE}"
}
trap 'cleanup "$?"' EXIT SIGHUP SIGINT SIGQUIT SIGTERM

cp -R "${CONTEXT}/config" "${TMP_CONTEXT}"
cat <<EOF > "${TMP_CONTEXT}/Dockerfile"
FROM ${BUILDKIT_BASE_IMAGE_NAME}

RUN apt-get update -y && \
    apt-get --no-install-recommends install -y iptables jq time && \
    git clone ${BUILDKIT_REPO} \$GOPATH/src/github.com/moby/buildkit && \
    cd \$GOPATH/src/github.com/moby/buildkit && \
    git checkout ${BUILDKIT_VERSION} && \
    go build -o /usr/local/bin/buildctl ./cmd/buildctl && \
    go build -ldflags "-w -extldflags -static" -tags "osusergo netgo static_build seccomp" \
         -o /usr/local/bin/buildkitd ./cmd/buildkitd

COPY ./config/config.containerd.toml /etc/containerd/config.toml
COPY ./config/config.stargz.toml /etc/containerd-stargz-grpc/config.toml
COPY ./config/config.buildkit.toml /etc/buildkit/buildkitd.toml

ENV CONTAINERD_SNAPSHOTTER=""

ENTRYPOINT [ "sleep", "infinity" ]
EOF
docker build -t "${BUILDKIT_TEST_IMAGE_NAME}" ${DOCKER_BUILD_ARGS:-} "${TMP_CONTEXT}"

BENCHMARKING_NODE="buildkit_integration_service"
CONTAINER_NAME="bulidkit_integration_node"
echo "Preparing docker-compose.yml..."
cat <<EOF > "${DOCKER_COMPOSE_YAML}"
version: "3.7"
services:
  ${BENCHMARKING_NODE}:
    image: ${BUILDKIT_TEST_IMAGE_NAME}
    container_name: ${CONTAINER_NAME}
    privileged: true
    init: true
    working_dir: /go/src/github.com/containerd/stargz-snapshotter
    environment:
    - NO_PROXY=127.0.0.1,localhost
    - HTTP_PROXY=${HTTP_PROXY:-}
    - HTTPS_PROXY=${HTTPS_PROXY:-}
    - http_proxy=${http_proxy:-}
    - https_proxy=${https_proxy:-}
    tmpfs:
    - /tmp:exec,mode=777
    volumes:
    - "${REPO}:/go/src/github.com/containerd/stargz-snapshotter:ro"
    - /dev/fuse:/dev/fuse
    - buildkit-buildkit-data:/var/lib/buildkit
    - containerd-buildkit-data:/var/lib/containerd
    - snapshotter-buildkit-data:/var/lib/containerd-stargz-grpc
volumes:
  buildkit-buildkit-data:
  containerd-buildkit-data:
  snapshotter-buildkit-data:
EOF

echo "Preparing for benchmark..."
OUTPUTDIR="${BENCHMARK_RESULT_DIR:-}"
if [ "${OUTPUTDIR}" == "" ] ; then
    OUTPUTDIR=$(mktemp -d)
fi
echo "See output for >>> ${OUTPUTDIR}"
LOG_DIR="${BENCHMARK_LOG_DIR:-}"
if [ "${LOG_DIR}" == "" ] ; then
    LOG_DIR=$(mktemp -d)
fi
RESULT_JSON_LOG_OCI="${LOG_DIR}/buildkit-benchmark-oci-$(date '+%Y%m%d%H%M%S')"
touch "${RESULT_JSON_LOG_OCI}"
echo "Logging to >>> ${RESULT_JSON_LOG_OCI} (will stored =>${OUTPUTDIR})"

# Benchmarking. Currently buildkitd + oci-worker(builtin stargz snapshotter) configuration is enabled.
echo "Benchmarking..."
FAIL=
if ! ( cd "${CONTEXT}" && \
           docker-compose -f "${DOCKER_COMPOSE_YAML}" build ${DOCKER_BUILD_ARGS:-} \
                          "${BENCHMARKING_NODE}" && \
           docker-compose -f "${DOCKER_COMPOSE_YAML}" up -d --force-recreate && \
           docker exec -i \
                  -e BENCHMARK_TARGET_IMAGES \
                  -e BENCHMARK_SAMPLES_NUM \
                  -e WITH_WORKER="oci" \
                  "${CONTAINER_NAME}" script/buildkit/measure/measure.sh 2>&1 \
           | tee "${RESULT_JSON_LOG_OCI}" ) ; then
    echo "Failed to run benchmark."
    FAIL=true
fi

echo "Harvesting log ${RESULT_JSON_LOG_OCI} -> ${OUTPUTDIR} ..."
mv "${RESULT_JSON_LOG_OCI}" "${OUTPUTDIR}/result_oci.log"
if [ "${FAIL}" != "true" ] ; then
    if ! ( cat "${OUTPUTDIR}/result_oci.log" | "${CONTEXT}/tools/format.sh" > "${OUTPUTDIR}/result_oci.json" && \
               cat "${OUTPUTDIR}/result_oci.json" | "${CONTEXT}/tools/plot.sh" "${OUTPUTDIR}" "oci" && \
               cat "${OUTPUTDIR}/result_oci.json" | "${CONTEXT}/tools/percentiles.sh" "${OUTPUTDIR}/oci_percentiles" ) ; then
        echo "Failed to formatting output (but you can try it manually from ${OUTPUTDIR})"
        FAIL=true
    fi
fi

echo "Cleaning up environment..."
docker-compose -f "${DOCKER_COMPOSE_YAML}" down -v
if [ "${FAIL}" == "true" ] ; then
    exit 1
fi

exit 0
