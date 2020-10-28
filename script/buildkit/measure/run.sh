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

REPO=$GOPATH/src/github.com/containerd/stargz-snapshotter
CONTAINERD_ROOT=/var/lib/containerd/
CONTAINERD_CONFIG_DIR=/etc/containerd/
CONTAINERD_SOCKET=/run/containerd/containerd.sock
REMOTE_SNAPSHOTTER_ROOT=/var/lib/containerd-stargz-grpc/
REMOTE_SNAPSHOTTER_CONFIG_DIR=/etc/containerd-stargz-grpc/
REMOTE_SNAPSHOTTER_SOCKET=/run/containerd-stargz-grpc/containerd-stargz-grpc.sock
BUILDKITD_ROOT=/var/lib/buildkit/
BUILDKITD_CONFIG_DIR=/etc/buildkit/
BUILDKITD_SOCKET=/run/buildkit/buildkitd.sock

RETRYNUM=30
RETRYINTERVAL=1
TIMEOUTSEC=180
function retry {
    SUCCESS=false
    for i in $(seq ${RETRYNUM}) ; do
        if eval "timeout ${TIMEOUTSEC} ${@}" ; then
            SUCCESS=true
            break
        fi
        echo "Fail(${i}). Retrying..."
        sleep ${RETRYINTERVAL}
    done
    if [ "${SUCCESS}" == "true" ] ; then
        return 0
    else
        return 1
    fi
}

function kill_all {
    if [ "${1}" != "" ] ; then
        ps aux | grep "${1}" \
            | grep -v grep \
            | grep -v "run.sh" \
            | grep -v "measure.sh" \
            | sed -E 's/ +/ /g' | cut -f 2 -d ' ' | xargs -I{} kill -9 {} || true
    fi
}

function cleanup {
    # containerd
    if [ -f "${CONTAINERD_SOCKET}" ] ; then
        rm "${CONTAINERD_SOCKET}"
    fi
    rm -rf "${CONTAINERD_ROOT}"*

    # snapshotter
    if [ -f "${REMOTE_SNAPSHOTTER_SOCKET}" ] ; then
        rm "${REMOTE_SNAPSHOTTER_SOCKET}"
    fi
    if [ -d "${REMOTE_SNAPSHOTTER_ROOT}snapshotter/snapshots/" ] ; then 
        find "${REMOTE_SNAPSHOTTER_ROOT}snapshotter/snapshots/" \
             -maxdepth 1 -mindepth 1 -type d -exec umount "{}/fs" \;
    fi
    rm -rf "${REMOTE_SNAPSHOTTER_ROOT}"*

    # buildkit
    if [ -d "${BUILDKITD_ROOT}runc-stargz/snapshots/snapshotter/snapshots/" ] ; then 
        find "${BUILDKITD_ROOT}runc-stargz/snapshots/snapshotter/snapshots/" \
             -maxdepth 1 -mindepth 1 -type d -exec umount "{}/fs" \;
    fi
    rm -rf "${BUILDKITD_ROOT}"*
    rm -rf "${BUILDKITD_SOCKET}"
}

echo "cleaning up the environment..."
kill_all "containerd"
kill_all "containerd-stargz-grpc"
kill_all "buildkitd"
cleanup

if [ "${LOG_FILE:-}" == "" ] ; then
    LOG_FILE=/dev/null
fi

if [ "${NO_STARGZ_SNAPSHOTTER:-}" == "true" ] ; then
    echo "DO NOT RUN remote snapshotter"
else
    echo "running remote snaphsotter..."
    containerd-stargz-grpc --log-level=debug \
                           --address="${REMOTE_SNAPSHOTTER_SOCKET}" \
                           --config="${REMOTE_SNAPSHOTTER_CONFIG_DIR}config.toml" \
                           2>&1 | tee -a "${LOG_FILE}" & # Dump all log
    retry ls "${REMOTE_SNAPSHOTTER_SOCKET}"
fi

echo "running containerd..."
if [ "${NO_CONTAINERD:-}" == "true" ] ; then
    echo "DO NOT RUN containerd"
else
    containerd --config="${CONTAINERD_CONFIG_DIR}config.toml" &
    retry ctr version
fi

echo "running buildkitd..."
buildkitd --debug $@ 2>&1 | tee -a "${LOG_FILE}" & # Dump all log
retry buildctl du
