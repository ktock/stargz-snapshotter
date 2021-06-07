#!/bin/bash

set -euo pipefail

CONTEXT="$( cd "$( dirname "${BASH_SOURCE[0]}" )" >/dev/null 2>&1 && pwd )/"

K3S_CLUSTER_NAME="k3s-demo-cluster"
K3S_NODE_REPO=ghcr.io/stargz-containers
K3S_NODE_IMAGE_NAME=k3s
K3S_NODE_TAG=esgz
K3S_NODE_IMAGE="${K3S_NODE_REPO}/${K3S_NODE_IMAGE_NAME}:${K3S_NODE_TAG}"
RESULT_DIR=${DEMO_RESULT_DIR:-}
if [ "${RESULT_DIR}" == "" ] ; then
    RESULT_DIR=$(mktemp -d)
fi
mkdir -p "${RESULT_DIR}"
echo "Result: ${RESULT_DIR}"

TMP_GOYAML=$(mktemp)
TMP_ARGOYAML=$(mktemp)
TMP_K3S_KUBECONFIG=$(mktemp)
TMP_GOLANGCI=$(mktemp)
TMP_K3S_REPO=$(mktemp -d)
function cleanup {
    local ORG_EXIT_CODE="${1}"
    rm "${TMP_GOYAML}"
    rm "${TMP_ARGOYAML}"
    rm "${TMP_K3S_KUBECONFIG}"
    rm "${TMP_GOLANGCI}"
    rm -rf "${TMP_K3S_REPO}"
    k3d cluster delete "${K3S_CLUSTER_NAME}"
    exit "${ORG_EXIT_CODE}"
}
trap 'cleanup "$?"' EXIT SIGHUP SIGINT SIGQUIT SIGTERM

# Download argo yaml
wget -O "${TMP_ARGOYAML}" https://raw.githubusercontent.com/argoproj/argo-workflows/stable/manifests/quick-start-postgres.yaml
sed -i 's|containerRuntimeExecutor: docker|containerRuntimeExecutor: pns|g' "${TMP_ARGOYAML}"
sed -i 's|argoproj/argoexec:v3.0.7|ghcr.io/ktock/argoproj-argoexec:v3.0.7-esgz|g' "${TMP_ARGOYAML}"

# Create k3d node image
git clone --depth 1 -b stargz-snapshotter https://github.com/ktock/k3s "${TMP_K3S_REPO}"
( cd "${TMP_K3S_REPO}" && \
      git config user.email "dummy@example.com" && \
      git config user.name "dummy" && \
      cat ./.golangci.json | jq '.run.deadline|="10m"' > "${TMP_GOLANGCI}" && \
      cp "${TMP_GOLANGCI}" ./.golangci.json &&  \
      git add . && \
      git commit -m tmp && \
      REPO="${K3S_NODE_REPO}" IMAGE_NAME="${K3S_NODE_IMAGE_NAME}" TAG="${K3S_NODE_TAG}" make
)

# Run the workflow
function run() {
    local IMAGE_TYPE="${1}"
    local SNAPSHOTTER="${2}"

    k3d cluster create "${K3S_CLUSTER_NAME}" --image="${K3S_NODE_IMAGE}" \
        --k3s-server-arg=--snapshotter="${SNAPSHOTTER}" --k3s-agent-arg=--snapshotter="${SNAPSHOTTER}"
    k3d kubeconfig get "${K3S_CLUSTER_NAME}" > "${TMP_K3S_KUBECONFIG}"
    KUBECONFIG="${TMP_K3S_KUBECONFIG}" kubectl create ns argo
    KUBECONFIG="${TMP_K3S_KUBECONFIG}" kubectl apply -n argo -f "${TMP_ARGOYAML}"
    RETRYNUM=30
    RETRYINTERVAL=1
    TIMEOUTSEC=180
    for i in $(seq ${RETRYNUM}) ; do
        if [ $(KUBECONFIG="${TMP_K3S_KUBECONFIG}" kubectl get -n argo pods -o json |
                   jq '.items[] | select(.status.phase != "Running" and .status.phase != "Succeeded")' | wc -l) -eq 0 ]
        then
            echo "argo is ready"
            break
        fi
        echo "Waiting for argo is ready..."
        sleep ${RETRYINTERVAL}
    done

    cat "${CONTEXT}/go.yaml.template" | sed 's/{{ .IMAGE_TYPE }}/'"${IMAGE_TYPE}"'/g' > "${TMP_GOYAML}"
    argo submit -n argo --watch "${TMP_GOYAML}"

    START=$(argo list -n argo --completed -o json | jq -r '.[0].status.startedAt')
    FINISH=$(argo list -n argo --completed -o json | jq -r '.[0].status.finishedAt')
    expr $(date --date "${FINISH}" +%s) - $(date --date "${START}" +%s) >> "${RESULT_DIR}/${IMAGE_TYPE}"

    k3d cluster delete "${K3S_CLUSTER_NAME}"
}

#1
run "org" "overlayfs"
run "esgz" "stargz"

#2
run "org" "overlayfs"
run "esgz" "stargz"

#3
run "org" "overlayfs"
run "esgz" "stargz"
