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

set -euox pipefail

function wait_for_crio() {
    CRIO_SOCK=unix:///run/crio/crio.sock
    CONNECTED=
    for i in $(seq 100) ; do
        if /go/bin/crictl --runtime-endpoint=${CRIO_SOCK} stats ; then
            CONNECTED=true
            break
        fi
        echo "Fail(${i}). Retrying..."
        sleep 1
    done
    if [ "${CONNECTED}" != "true" ] ; then
        echo "Failed to connect to CRI-O"
        return 1
    fi
    return 0
}

# Check if image store isn't damaged
crio check

# Initialize state marker
mkdir -p /tmp/layerstate/
crio check --repair --check-layer-state --state-marker="lazy:enable" --state-file=/tmp/layerstate/state

# start CRI-O
systemctl restart stargz-store
systemctl restart crio
wait_for_crio

# Lazy pull an image
/go/bin/crictl pull ghcr.io/stargz-containers/ubuntu:20.04-esgz

# stop CRI-O
systemctl stop stargz-store
systemctl stop crio

# Disable Additional Layer Store
cat <<EOF > /etc/containers/storage.conf
[storage]
driver = "overlay"
graphroot = "/var/lib/containers/storage"
runroot = "/run/containers/storage"
EOF

# # Update state marker (disable lazy pulling) and repair the storage
# crio check --repair --check-layer-state --state-marker="" --state-file=/tmp/layerstate/state

# Restart CRI-O
systemctl restart crio
wait_for_crio

# Check if image store isn't damaged
crio check
