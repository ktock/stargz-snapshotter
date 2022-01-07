#!/bin/bash

set -eux -o pipefail

SOURCEREG="${1}"
IMAGE="${2}"

YQ_VERSION=v4.16.1

function kill_all {
    if [ "${1}" != "" ] ; then
        ps auxww | grep "${1}" | grep -v grep | sed -E 's/ +/ /g' | cut -f 2 -d ' ' | xargs -I{} kill -9 {} || true
    fi
}

kill_all " ipfs"
rm -rf ~/.ipfs

# basic dependencies
sudo apt-get update -y
sudo apt-get install -y iperf3
sudo modprobe ifb
if ! yq --help ; then
    wget https://github.com/mikefarah/yq/releases/download/${YQ_VERSION}/yq_linux_amd64.tar.gz -O - | tar xz
    sudo mv yq_linux_amd64 /usr/bin/yq
fi

# install containerd and nerdctl
if ! sudo nerdctl version ; then
    wget https://github.com/containerd/nerdctl/releases/download/v0.15.0/nerdctl-full-0.15.0-linux-amd64.tar.gz
    sudo tar -C /usr/local/ -zxvf nerdctl-full-0.15.0-linux-amd64.tar.gz
    sudo systemctl enable --now containerd
fi

# (re)start registry
if sudo nerdctl ps -a | grep registry ; then
    sudo nerdctl kill registry
    sudo nerdctl rm registry
fi
sudo nerdctl run -d -p 5000:5000 --name registry registry:2

sudo nerdctl pull ${SOURCEREG}/${IMAGE}
sudo nerdctl tag ${SOURCEREG}/${IMAGE} localhost:5000/${IMAGE}
sudo nerdctl push localhost:5000/${IMAGE}
