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

TMP_DIR=$(mktemp -d)
LOG_FILE=$(mktemp)
function cleanup {
    ORG_EXIT_CODE="${1}"
    rm -rf "${TMP_DIR}" || true
    rm "${LOG_FILE}"
    exit "${ORG_EXIT_CODE}"
}
trap 'cleanup "$?"' EXIT SIGHUP SIGINT SIGQUIT SIGTERM

RETRYNUM=30
RETRYINTERVAL=1
TIMEOUTSEC=180
function retry {
    local SUCCESS=false
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
        ps aux | grep "${1}" | grep -v grep | grep -v $(basename ${0}) | sed -E 's/ +/ /g' | cut -f 2 -d ' ' | xargs -I{} kill -9 {} || true
    fi
}

CONTAINERD_ROOT=/var/lib/containerd/
REMOTE_SNAPSHOTTER_SOCKET=/run/containerd-stargz-grpc/containerd-stargz-grpc.sock
REMOTE_SNAPSHOTTER_ROOT=/var/lib/containerd-stargz-grpc/
function reboot_containerd {
    kill_all "containerd"
    kill_all "containerd-stargz-grpc"
    rm -rf "${CONTAINERD_ROOT}"*
    if [ -f "${REMOTE_SNAPSHOTTER_SOCKET}" ] ; then
        rm "${REMOTE_SNAPSHOTTER_SOCKET}"
    fi
    if [ -d "${REMOTE_SNAPSHOTTER_ROOT}snapshotter/snapshots/" ] ; then 
        find "${REMOTE_SNAPSHOTTER_ROOT}snapshotter/snapshots/" \
             -maxdepth 1 -mindepth 1 -type d -exec umount "{}/fs" \;
    fi
    rm -rf "${REMOTE_SNAPSHOTTER_ROOT}"*
    containerd-stargz-grpc --log-level=debug \
                           --address="${REMOTE_SNAPSHOTTER_SOCKET}" \
                           --config=/etc/containerd-stargz-grpc/config.toml \
                           2>&1 | tee -a "${LOG_FILE}" & # Dump all log
    retry ls "${REMOTE_SNAPSHOTTER_SOCKET}"
    containerd --log-level debug --config=/etc/containerd/config.toml &
    retry ctr version
}

echo "preparing commands..."
PREFIX="${TMP_DIR}/" make clean
PREFIX="${TMP_DIR}/" make containerd-stargz-grpc
PREFIX="${TMP_DIR}/" make ctr-remote
PREFIX="${TMP_DIR}/" make install
mkdir -p /etc/containerd /etc/containerd-stargz-grpc \
      /output/org /output/sgz /output/esgz
cp ./script/fio-simple/containerd/config.containerd.toml /etc/containerd/config.toml
cp ./script/fio-simple/containerd/config.stargz.toml /etc/containerd-stargz-grpc/config.toml
cp ./script/fio-simple/containerd/fio.conf /fio.conf

reboot_containerd
ctr-remote image rpull docker.io/stargz/fio:256m-4t-org
ctr-remote run --rm --snapshotter=stargz \
  --mount type=bind,src=/output/org,dst=/output,options=rbind:rw \
  --mount type=bind,src=/fio.conf,dst=/fio.conf,options=rbind:ro \
  docker.io/stargz/fio:256m-4t-org foo \
  fio /fio.conf --output /output/summary.txt

reboot_containerd
ctr-remote image rpull docker.io/stargz/fio:256m-4t-sgz
ctr-remote run --rm --snapshotter=stargz \
  --mount type=bind,src=/output/sgz,dst=/output,options=rbind:rw \
  --mount type=bind,src=/fio.conf,dst=/fio.conf,options=rbind:ro \
  docker.io/stargz/fio:256m-4t-sgz foo \
  fio /fio.conf --output /output/summary.txt

reboot_containerd
ctr-remote image rpull docker.io/stargz/fio:256m-4t-esgz
ctr-remote run --rm --snapshotter=stargz \
  --mount type=bind,src=/output/esgz,dst=/output,options=rbind:rw \
  --mount type=bind,src=/fio.conf,dst=/fio.conf,options=rbind:ro \
  docker.io/stargz/fio:256m-4t-esgz foo \
  fio /fio.conf --output /output/summary.txt
