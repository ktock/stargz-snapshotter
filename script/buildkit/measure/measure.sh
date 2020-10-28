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
REPO="${CONTEXT}../../../"

RUN_SCRIPT="${CONTEXT}run.sh"
SAMPLE_DIR="${CONTEXT}sample/"
DOCKERFILE_SUFFIX_PH='{{ IMAGE_MODE_SUFFIX }}'
BENCHMARKOUT_MARK_OUTPUT="BENCHMARK_OUTPUT: "
LEGACY_MODE="legacy"
STARGZ_MODE="stargz"
ESTARGZ_MODE="estargz"

# NOTE: The entire contents of containerd/stargz-snapshotter are located in
# the testing container so utils.sh is visible from this script during runtime.
# TODO: Refactor the code dependencies and pack them in the container without
#       expecting and relying on volumes.
source "${REPO}/script/util/utils.sh"

NUM_OF_SAMPLES="${BENCHMARK_SAMPLES_NUM:-1}"

BUILDKIT_WORKER="${WITH_WORKER:-}"
if [ "${BUILDKIT_WORKER}" == "" ] ; then
    BUILDKIT_WORKER="oci"
fi

TARGET_IMAGES="${BENCHMARK_TARGET_IMAGES:-}"
if [ "${TARGET_IMAGES}" == "" ] ; then
    TARGET_IMAGES=$(ls -1 "${SAMPLE_DIR}" | xargs echo)
fi

TMP_LOG_FILE=$(mktemp)
WORKLOADS_LIST=$(mktemp)
function cleanup {
    local ORG_EXIT_CODE="${1}"
    rm "${TMP_LOG_FILE}" || true
    rm "${WORKLOADS_LIST}"
    exit "${ORG_EXIT_CODE}"
}
trap 'cleanup "$?"' EXIT SIGHUP SIGINT SIGQUIT SIGTERM

function output {
    echo "${BENCHMARKOUT_MARK_OUTPUT}${1}"
}

REMOTE_SNAPSHOTTER_CONFIG=/etc/containerd-stargz-grpc/config.toml
BUILDKITD_CONFIG=/etc/buildkit/buildkitd.toml
function set_noprefetch {
    local NOPREFETCH="${1}"
    sed -i 's/noprefetch = .*/noprefetch = '"${NOPREFETCH}"'/g' "${REMOTE_SNAPSHOTTER_CONFIG}"
    sed -i 's/noprefetch = .*/noprefetch = '"${NOPREFETCH}"'/g' "${BUILDKITD_CONFIG}"
}
function set_disable_verification {
    local DISABLE_V="${1}"
    sed -i 's/disable_verification = .*/disable_verification = '"${DISABLE_V}"'/g' "${REMOTE_SNAPSHOTTER_CONFIG}"
    sed -i 's/disable_verification = .*/disable_verification = '"${DISABLE_V}"'/g' "${BUILDKITD_CONFIG}"
}

function build {
    local TARGET_CONTEXT="${1}"
    local TARGET_DOCKERFILE="${2}"
    local RESULT=$(mktemp)
    /usr/bin/time --output="${RESULT}" -f '%e' buildctl build --progress=plain \
         --frontend=dockerfile.v0 \
         --local context="${TARGET_CONTEXT}" \
         --local dockerfile="${TARGET_DOCKERFILE}"
    local ELAPSED=$(cat "${RESULT}")
    rm "${RESULT}"
    echo -n "${ELAPSED}"
}

function measure {
    local IMAGE="${1}"
    local MODE="${2}"
    local SNAPSHOTTER_NAME="${3}"
    local IMAGE_SUFFIX="${4}"

    # Construct options for buildkitd
    BUILDKITD_OPTS=
    NO_CONTAINERD=
    NO_STARGZ_SNAPSHOTTER="${NO_STARGZ_SNAPSHOTTER:-}"
    if [ "${BUILDKIT_WORKER}" == "oci" ] ; then
        # uses oci worker
        # containerd and stargz snapshotter won't be spawned.
        NO_CONTAINERD="true"
        NO_STARGZ_SNAPSHOTTER="true"
        BUILDKITD_OPTS="--oci-worker-snapshotter=${SNAPSHOTTER_NAME}"
    elif [ "${BUILDKIT_WORKER}" == "containerd" ] ; then
        # uses containerd worker
        BUILDKITD_OPTS="--containerd-worker-snapshotter=${SNAPSHOTTER_NAME} --oci-worker=false --containerd-worker=true"
    else
        echo "Unknown mode (for buildkit option): ${BUILDKIT_WORKER}"
        exit 1
    fi
    echo "suffix: ${IMAGE_SUFFIX}, options for buildkitd: ${BUILDKITD_OPTS}"

    # Prepare the contenxt
    SAMPLE_CONTEXT="${SAMPLE_DIR}/${IMAGE}/"
    DOCKERFILE_DIR=$(mktemp -d)
    cat "${SAMPLE_CONTEXT}Dockerfile" \
        | sed 's/'"${DOCKERFILE_SUFFIX_PH}"'/'"${IMAGE_SUFFIX}"'/g' > "${DOCKERFILE_DIR}/Dockerfile"

    # Run buildkitd + dependencies
    NO_CONTAINERD="${NO_CONTAINERD}" NO_STARGZ_SNAPSHOTTER="${NO_STARGZ_SNAPSHOTTER}" "${RUN_SCRIPT}" ${BUILDKITD_OPTS}

    # Build the sample image
    ELAPSED=$(build "${SAMPLE_CONTEXT}" "${DOCKERFILE_DIR}")
    output '{ "image" : "'"${IMAGE}"'", "mode" : "'"${MODE}"'", "elapsed": '"${ELAPSED}"' },'
}

echo "========="
echo "SPEC LIST"
echo "========="
uname -r
cat /etc/os-release
cat /proc/cpuinfo
cat /proc/meminfo
mount
df

output "["

for SAMPLE_NO in $(seq ${NUM_OF_SAMPLES}) ; do
    echo -n "" > "${WORKLOADS_LIST}"
    # Randomize workloads
    for IMAGE in ${TARGET_IMAGES} ; do
        for MODE in ${LEGACY_MODE} ${STARGZ_MODE} ${ESTARGZ_MODE} ; do
            echo "${IMAGE},${MODE}" >> "${WORKLOADS_LIST}"
        done
    done
    sort -R -o "${WORKLOADS_LIST}" "${WORKLOADS_LIST}"
    echo "Workloads of iteration [${SAMPLE_NO}]"
    cat "${WORKLOADS_LIST}"

    # Run the workloads
    for THEWL in $(cat "${WORKLOADS_LIST}") ; do
        echo "The workload is ${THEWL}"

        IMAGE=$(echo "${THEWL}" | cut -d ',' -f 1)
        MODE=$(echo "${THEWL}" | cut -d ',' -f 2)

        echo "===== Measuring [${SAMPLE_NO}] ${IMAGE} (${MODE}) ====="

        if [ "${MODE}" == "${LEGACY_MODE}" ] ; then
            NO_STARGZ_SNAPSHOTTER="true" measure "${IMAGE}" "${MODE}" "overlayfs" "org"
        fi

        if [ "${MODE}" == "${STARGZ_MODE}" ] ; then
            echo -n "" > "${TMP_LOG_FILE}"
            set_noprefetch "true"           # disable prefetch
            set_disable_verification "true" # disable verification
            LOG_FILE="${TMP_LOG_FILE}" measure "${IMAGE}" "${MODE}" "stargz" "sgz"
            check_remote_snapshots "${TMP_LOG_FILE}"
        fi

        if [ "${MODE}" == "${ESTARGZ_MODE}" ] ; then
            echo -n "" > "${TMP_LOG_FILE}"
            set_noprefetch "false"           # enable prefetch
            set_disable_verification "false" # enable verification
            LOG_FILE="${TMP_LOG_FILE}" measure "${IMAGE}" "${MODE}" "stargz" "esgz"
            check_remote_snapshots "${TMP_LOG_FILE}"
        fi
    done
done

output "]"
