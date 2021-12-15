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
KIND_CLUSTER_NAME="kind-ipfs-stargz-snapshotter"
NODE_BASE_IMAGE_NAME="stargz-snapshotter-node-base:1"

if [ "${KIND_IPFS_NO_RECREATE:-}" != "true" ] ; then
    echo "Preparing node image..."

    TARGET_STAGE=
    if [ "${BUILTIN_SNAPSHOTTER:-}" == "true" ] ; then
        TARGET_STAGE="--target kind-builtin-snapshotter"
    fi

    docker build ${DOCKER_BUILD_ARGS:-} -t "${NODE_BASE_IMAGE_NAME}" ${TARGET_STAGE} "${REPO}"
fi

KIND_CONFIG=$(mktemp)
KIND_KUBECONFIG=$(mktemp)
function cleanup {
    local ORG_EXIT_CODE="${1}"
    rm "${KIND_CONFIG}" || true
    rm "${KIND_KUBECONFIG}" || true
    exit "${ORG_EXIT_CODE}"
}
trap 'cleanup "$?"' EXIT SIGHUP SIGINT SIGQUIT SIGTERM

cat <<EOF > "${KIND_CONFIG}"
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
nodes:
- role: control-plane
- role: worker
- role: worker
EOF

kind create cluster --name "${KIND_CLUSTER_NAME}" --image="${NODE_BASE_IMAGE_NAME}" --config="${KIND_CONFIG}" --kubeconfig "${KIND_KUBECONFIG}"

echo "Testing in kind cluster (kubeconfig: ${KIND_KUBECONFIG})..."
FAIL=
if ! "${CONTEXT}"/run-pods.sh "${KIND_CLUSTER_NAME}" "${KIND_KUBECONFIG}" ; then
    FAIL=true
fi

kind delete cluster --name "${KIND_CLUSTER_NAME}"
if [ "${FAIL}" == "true" ] ; then
    exit 1
fi

exit 0
