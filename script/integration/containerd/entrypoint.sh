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

# NOTE: The entire contents of containerd/stargz-snapshotter are located in
# the testing container so utils.sh is visible from this script during runtime.
# TODO: Refactor the code dependencies and pack them in the container without
#       expecting and relying on volumes.
source "/utils.sh"

PLUGIN=stargz
REGISTRY_HOST=registry-integration
REGISTRY_ALT_HOST=registry-alt
DUMMYUSER=dummyuser
DUMMYPASS=dummypass

USR_ORG=$(mktemp -d)
USR_MIRROR=$(mktemp -d)
USR_REFRESH=$(mktemp -d)
USR_NOMALSN_UNSTARGZ=$(mktemp -d)
USR_NOMALSN_STARGZ=$(mktemp -d)
USR_STARGZSN_UNSTARGZ=$(mktemp -d)
USR_STARGZSN_STARGZ=$(mktemp -d)
USR_NORMALSN_PLAIN_STARGZ=$(mktemp -d)
USR_STARGZSN_PLAIN_STARGZ=$(mktemp -d)
LOG_FILE=$(mktemp)
function cleanup {
    ORG_EXIT_CODE="${1}"
    rm -rf "${USR_ORG}" || true
    rm -rf "${USR_MIRROR}" || true
    rm -rf "${USR_REFRESH}" || true
    rm -rf "${USR_NOMALSN_UNSTARGZ}" || true
    rm -rf "${USR_NOMALSN_STARGZ}" || true
    rm -rf "${USR_STARGZSN_UNSTARGZ}" || true
    rm -rf "${USR_STARGZSN_STARGZ}" || true
    rm -rf "${USR_NORMALSN_PLAIN_STARGZ}" || true
    rm -rf "${USR_STARGZSN_PLAIN_STARGZ}" || true
    rm "${LOG_FILE}"
    exit "${ORG_EXIT_CODE}"
}
trap 'cleanup "$?"' EXIT SIGHUP SIGINT SIGQUIT SIGTERM

RETRYNUM=100
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
CONTAINERD_STATUS=/run/containerd/
REMOTE_SNAPSHOTTER_SOCKET=/run/containerd-stargz-grpc/containerd-stargz-grpc.sock
REMOTE_SNAPSHOTTER_ROOT=/var/lib/containerd-stargz-grpc/
function reboot_containerd {
    local CONFIG="${1:-}"

    kill_all "containerd"
    kill_all "containerd-stargz-grpc"
    rm -rf "${CONTAINERD_STATUS}"*
    rm -rf "${CONTAINERD_ROOT}"*
    if [ -f "${REMOTE_SNAPSHOTTER_SOCKET}" ] ; then
        rm "${REMOTE_SNAPSHOTTER_SOCKET}"
    fi
    if [ -d "${REMOTE_SNAPSHOTTER_ROOT}snapshotter/snapshots/" ] ; then 
        find "${REMOTE_SNAPSHOTTER_ROOT}snapshotter/snapshots/" \
             -maxdepth 1 -mindepth 1 -type d -exec umount "{}/fs" \;
    fi
    rm -rf "${REMOTE_SNAPSHOTTER_ROOT}"*
    if [ "${CONFIG}" == "" ] ; then
        containerd-stargz-grpc --log-level=debug \
                           --address="${REMOTE_SNAPSHOTTER_SOCKET}" \
                           2>&1 | tee -a "${LOG_FILE}" & # Dump all log
    else
        containerd-stargz-grpc --log-level=debug \
                           --address="${REMOTE_SNAPSHOTTER_SOCKET}" \
                           --config="${CONFIG}" \
                           2>&1 | tee -a "${LOG_FILE}" &
    fi
    retry ls "${REMOTE_SNAPSHOTTER_SOCKET}"
    containerd --log-level debug --config=/etc/containerd/config.toml &

    # Makes sure containerd and containerd-stargz-grpc are up-and-running.
    UNIQUE_SUFFIX=$(date +%s%N | shasum | base64 | fold -w 10 | head -1)
    retry ctr snapshots --snapshotter="${PLUGIN}" prepare "connectiontest-dummy-${UNIQUE_SUFFIX}" ""
}

print_versions_info

echo "Logging into the registry..."
cp /auth/certs/domain.crt /usr/local/share/ca-certificates
update-ca-certificates
retry docker login "${REGISTRY_HOST}:5000" -u "${DUMMYUSER}" -p "${DUMMYPASS}"

reboot_containerd
OK=$(ctr-remote plugins ls \
         | grep io.containerd.snapshotter \
         | sed -E 's/ +/ /g' \
         | cut -d ' ' -f 2,4 \
         | grep "${PLUGIN}" \
         | cut -d ' ' -f 2)
if [ "${OK}" != "ok" ] ; then
    echo "Plugin ${PLUGIN} not found" 1>&2
    exit 1
fi

function optimize {
    local SRC="${1}"
    local DST="${2}"
    local PUSHOPTS=${@:3}
    ctr-remote image pull -u "${DUMMYUSER}:${DUMMYPASS}" "${SRC}"
    ctr-remote image optimize --oci "${SRC}" "${DST}"
    ctr-remote image push ${PUSHOPTS} -u "${DUMMYUSER}:${DUMMYPASS}" "${DST}"
}

echo "Preparing images..."
crane copy ubuntu:18.04 "${REGISTRY_HOST}:5000/ubuntu:18.04"
crane copy alpine:3.10.2 "${REGISTRY_HOST}:5000/alpine:3.10.2"
stargzify "${REGISTRY_HOST}:5000/ubuntu:18.04" "${REGISTRY_HOST}:5000/ubuntu:sgz"
optimize "${REGISTRY_HOST}:5000/ubuntu:18.04" "${REGISTRY_HOST}:5000/ubuntu:esgz"
optimize "${REGISTRY_HOST}:5000/alpine:3.10.2" "${REGISTRY_HOST}:5000/alpine:esgz"
optimize "${REGISTRY_HOST}:5000/alpine:3.10.2" "${REGISTRY_ALT_HOST}:5000/alpine:esgz" --plain-http

############
# Tests for refreshing and mirror
echo "Testing refreshing and mirror..."

reboot_containerd
echo "Getting image with normal snapshotter..."
ctr-remote images pull --user "${DUMMYUSER}:${DUMMYPASS}" "${REGISTRY_HOST}:5000/alpine:esgz"
ctr-remote run --rm "${REGISTRY_HOST}:5000/alpine:esgz" test tar -c /usr | tar -xC "${USR_ORG}"

echo "Getting image with stargz snapshotter..."
echo -n "" > "${LOG_FILE}"
ctr-remote images rpull --user "${DUMMYUSER}:${DUMMYPASS}" "${REGISTRY_HOST}:5000/alpine:esgz"
check_remote_snapshots "${LOG_FILE}"

REGISTRY_HOST_IP=$(getent hosts "${REGISTRY_HOST}" | awk '{ print $1 }')
REGISTRY_ALT_HOST_IP=$(getent hosts "${REGISTRY_ALT_HOST}" | awk '{ print $1 }')

echo "Disabling source registry and check if mirroring is working for stargz snapshotter..."
iptables -A OUTPUT -d "${REGISTRY_HOST_IP}" -j DROP
iptables -L
ctr-remote run --rm --snapshotter=stargz "${REGISTRY_HOST}:5000/alpine:esgz" test tar -c /usr \
    | tar -xC "${USR_MIRROR}"
iptables -D OUTPUT -d "${REGISTRY_HOST_IP}" -j DROP

echo "Disabling mirror registry and check if refreshing works for stargz snapshotter..."
iptables -A OUTPUT -d "${REGISTRY_ALT_HOST_IP}" -j DROP
iptables -L
ctr-remote run --rm --snapshotter=stargz "${REGISTRY_HOST}:5000/alpine:esgz" test tar -c /usr \
    | tar -xC "${USR_REFRESH}"
iptables -D OUTPUT -d "${REGISTRY_ALT_HOST_IP}" -j DROP

echo "Disabling all registries and running container should fail"
iptables -A OUTPUT -d "${REGISTRY_HOST_IP}","${REGISTRY_ALT_HOST_IP}" -j DROP
iptables -L
if ctr-remote run --rm --snapshotter=stargz "${REGISTRY_HOST}:5000/alpine:esgz" test tar -c /usr > /usr_dummy_fail.tar ; then
    echo "All registries are disabled so this must be failed"
    exit 1
else
    echo "Failed to run the container as expected"
fi
iptables -D OUTPUT -d "${REGISTRY_HOST_IP}","${REGISTRY_ALT_HOST_IP}" -j DROP

echo "Diffing root filesystems for mirroring"
diff --no-dereference -qr "${USR_ORG}/" "${USR_MIRROR}/"

echo "Diffing root filesystems for refreshing"
diff --no-dereference -qr "${USR_ORG}/" "${USR_REFRESH}/"

############
# Tests for stargz filesystem
echo "Testing stargz filesystem..."

reboot_containerd
echo "Getting normal image with normal snapshotter..."
ctr-remote images pull --user "${DUMMYUSER}:${DUMMYPASS}" "${REGISTRY_HOST}:5000/ubuntu:18.04"
ctr-remote run --rm "${REGISTRY_HOST}:5000/ubuntu:18.04" test tar -c /usr \
    | tar -xC "${USR_NOMALSN_UNSTARGZ}"

reboot_containerd
echo "Getting normal image with stargz snapshotter..."
ctr-remote images rpull --user "${DUMMYUSER}:${DUMMYPASS}" "${REGISTRY_HOST}:5000/ubuntu:18.04"
ctr-remote run --rm --snapshotter=stargz "${REGISTRY_HOST}:5000/ubuntu:18.04" test tar -c /usr \
    | tar -xC "${USR_STARGZSN_UNSTARGZ}"

reboot_containerd
echo "Getting eStargz image with normal snapshotter..."
ctr-remote images pull --user "${DUMMYUSER}:${DUMMYPASS}" "${REGISTRY_HOST}:5000/ubuntu:esgz"
ctr-remote run --rm "${REGISTRY_HOST}:5000/ubuntu:esgz" test tar -c /usr \
    | tar -xC "${USR_NOMALSN_STARGZ}"

reboot_containerd
echo "Getting eStargz image with stargz snapshotter..."
echo -n "" > "${LOG_FILE}"
ctr-remote images rpull --user "${DUMMYUSER}:${DUMMYPASS}" "${REGISTRY_HOST}:5000/ubuntu:esgz"
check_remote_snapshots "${LOG_FILE}"
ctr-remote run --rm --snapshotter=stargz "${REGISTRY_HOST}:5000/ubuntu:esgz" test tar -c /usr \
    | tar -xC "${USR_STARGZSN_STARGZ}"

echo "Diffing bitween two root filesystems(normal vs stargz snapshotter, normal rootfs)"
diff --no-dereference -qr "${USR_NOMALSN_UNSTARGZ}/" "${USR_STARGZSN_UNSTARGZ}/"

echo "Diffing bitween two root filesystems(normal vs stargz snapshotter, eStargz rootfs)"
diff --no-dereference -qr "${USR_NOMALSN_STARGZ}/" "${USR_STARGZSN_STARGZ}/"

############
# Checking compatibility with plain stargz

reboot_containerd
echo "Getting (legacy) stargz image with normal snapshotter..."
ctr-remote images pull --user "${DUMMYUSER}:${DUMMYPASS}" "${REGISTRY_HOST}:5000/ubuntu:sgz"
ctr-remote run --rm "${REGISTRY_HOST}:5000/ubuntu:sgz" test tar -c /usr \
    | tar -xC "${USR_NORMALSN_PLAIN_STARGZ}"

echo "Getting (legacy) stargz image with stargz snapshotter..."
echo "disable_verification = true" > /tmp/config.noverify.toml
cat /etc/containerd-stargz-grpc/config.toml >> /tmp/config.noverify.toml
reboot_containerd /tmp/config.noverify.toml
echo -n "" > "${LOG_FILE}"
ctr-remote images rpull --user "${DUMMYUSER}:${DUMMYPASS}" "${REGISTRY_HOST}:5000/ubuntu:sgz"
check_remote_snapshots "${LOG_FILE}"
ctr-remote run --rm --snapshotter=stargz "${REGISTRY_HOST}:5000/ubuntu:sgz" test tar -c /usr \
    | tar -xC "${USR_STARGZSN_PLAIN_STARGZ}"

echo "Diffing bitween two root filesystems(normal vs stargz snapshotter, plain stargz rootfs)"
diff --no-dereference -qr "${USR_NORMALSN_PLAIN_STARGZ}/" "${USR_STARGZSN_PLAIN_STARGZ}/"

############
# Try to pull this image from different namespace.
ctr-remote --namespace=dummy images rpull --user "${DUMMYUSER}:${DUMMYPASS}" \
           "${REGISTRY_HOST}:5000/ubuntu:esgz"

############
# Test for starting when no configuration file.
mv /etc/containerd-stargz-grpc/config.toml /etc/containerd-stargz-grpc/config.toml_rm
reboot_containerd
mv /etc/containerd-stargz-grpc/config.toml_rm /etc/containerd-stargz-grpc/config.toml

exit 0
