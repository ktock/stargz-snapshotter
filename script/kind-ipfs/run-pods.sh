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

set -eu -o pipefail

KIND_CLUSTER_NAME="${1}"
KIND_KUBECONFIG="${2}"

CONTEXT="$( cd "$( dirname "${BASH_SOURCE[0]}" )" >/dev/null 2>&1 && pwd )/"
REPO="${CONTEXT}../../"
TESTIMAGE="ghcr.io/stargz-containers/tomcat:10.0.0-jdk15-openjdk-buster-esgz"
REMOTE_SNAPSHOT_LABEL="containerd.io/snapshot/remote"

function is_all_running() {
    local KIND_KUBECONFIG="${1}"
    local SELECTOR="${2}"

    FOUND=false
    for s in $(KUBECONFIG="${KIND_KUBECONFIG}" kubectl get pods -l ${SELECTOR} -ojsonpath='{.items.*.status.phase}') ; do
        FOUND=true
        if [ "${s}" != "Running" ] ; then
            return 1
        fi
    done
    if [ "${FOUND}" != "true" ] ; then
        echo "no pod match ${SELECTOR}"
        return 1
    fi
    return 0
}

function wait_for_running() {
    local KIND_KUBECONFIG="${1}"
    local SELECTOR="${2}"

    local TRY=0
    local MAXTRY=100
    local SUCCESS=false
    while [ ${TRY} -lt ${MAXTRY} ] ; do
        echo "checking pods are running..."
        if is_all_running "${KIND_KUBECONFIG}" "${SELECTOR}" ; then
            SUCCESS=true
            return 0
        fi
        (( TRY += 1 ))
        sleep 5
    done
    echo "failed to run some containers"
    KUBECONFIG="${KIND_KUBECONFIG}" kubectl get all
    return 1
}

"${REPO}"/script/nerdctl-ipfs-registry-kubernetes/bootstrap.yaml.sh | KUBECONFIG="${KIND_KUBECONFIG}" kubectl apply -f -
KUBECONFIG="${KIND_KUBECONFIG}" kubectl apply -f "${REPO}"/script/nerdctl-ipfs-registry-kubernetes/nerdctl-ipfs-registry.yaml
wait_for_running "${KIND_KUBECONFIG}" "app=ipfs"
KUBECONFIG="${KIND_KUBECONFIG}" kubectl get all

KIND_NODENAME=$(kind get nodes --name "${KIND_CLUSTER_NAME}" | grep -v control-plane | sed -n 1p)
docker exec "${KIND_NODENAME}" /bin/bash -c "mkdir -p /tmp/ipfsapi ; echo -n /ip4/127.0.0.1/tcp/5001 >  /tmp/ipfsapi/api"
docker exec "${KIND_NODENAME}" ctr-remote i pull "${TESTIMAGE}"
CID=$(docker exec "${KIND_NODENAME}" /bin/bash -c "IPFS_PATH=/tmp/ipfsapi ctr-remote i ipfs-push --estargz=true ${TESTIMAGE}")
docker exec "${KIND_NODENAME}" ctr-remote i rm --sync "${TESTIMAGE}"

CONTAINER_NAME=tomcat
cat <<EOF | KUBECONFIG="${KIND_KUBECONFIG}" kubectl apply -f -
apiVersion: apps/v1
kind: DaemonSet
metadata:
  name: ${CONTAINER_NAME}
spec:
  selector:
    matchLabels:
      app: ${CONTAINER_NAME}
  template:
    metadata:
      labels:
        app: ${CONTAINER_NAME}
    spec:
      containers:
      - name: ${CONTAINER_NAME}
        image: localhost:5050/ipfs/${CID}
EOF

wait_for_running "${KIND_KUBECONFIG}" "app=${CONTAINER_NAME}"

for N in $(kind get nodes --name "${KIND_CLUSTER_NAME}" | grep -v "control-plane") ; do
    echo "========== Node ${N}: Checking snapshots =========="
    TARGET_CONTAINER=
    for (( RETRY=1; RETRY<=50; RETRY++ )) ; do
        echo "[${RETRY}]Trying to get container id..."
        TARGET_CONTAINER=$(docker exec -i "${N}" ctr-remote --namespace="k8s.io" c ls -q labels."io.kubernetes.container.name"=="${CONTAINER_NAME}" | sed -n 1p)
        if [ "${TARGET_CONTAINER}" != "" ] ; then
            break
        fi
        sleep 3
    done
    if [ "${TARGET_CONTAINER}" == "" ] ; then
        echo "no container created"
        docker exec -i "${N}" ctr-remote --namespace="k8s.io" c ls
        exit 1
    else
        echo "container ${TARGET_CONTAINER} created"
    fi
    # We don't check this *active* snapshot
    LAYER=$(docker exec -i "${N}" ctr-remote --namespace="k8s.io" c info "${TARGET_CONTAINER}" | jq -r '.SnapshotKey')

    echo "Checking all layers being remote snapshots..."
    LAYERSNUM=0
    for (( ; ; )) ; do
        LAYER=$(docker exec -i "${N}" ctr-remote --namespace="k8s.io" snapshot --snapshotter=stargz info "${LAYER}" | jq -r '.Parent')
        if [ "${LAYER}" == "null" ] ; then
            break
        elif [ ${LAYERSNUM} -gt 100 ] ; then
            echo "testing image contains too many layes > 100"
            exit 1
        fi
        ((LAYERSNUM+=1))
        LABEL=$(docker exec -i "${N}" ctr-remote --namespace="k8s.io" snapshots --snapshotter=stargz info "${LAYER}" \
                    | jq -r ".Labels.\"${REMOTE_SNAPSHOT_LABEL}\"")
        echo "Checking layer ${LAYER} : ${LABEL}"
        if [ "${LABEL}" == "null" ] ; then
            echo "layer ${LAYER} isn't remote snapshot"
            exit 1
        fi
    done

    if [ ${LAYERSNUM} -eq 0 ] ; then
        echo "cannot get layers"
        exit 1
    fi
done
