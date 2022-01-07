#!/bin/bash

set -eux -o pipefail

REGISTRY_HOST="${1}"
CONTAINERD_VERSION=1.5.8
PAUSE_MIRROR=ghcr.io/ktock/pause:3.6

sudo apt-get update -y
sudo apt-get install -y iperf3

rm -rf usr/ etc/ opt/ cri-containerd*
wget --quiet https://github.com/containerd/containerd/releases/download/v${CONTAINERD_VERSION}/cri-containerd-cni-${CONTAINERD_VERSION}-linux-amd64.tar.gz
tar zxvf cri-containerd-cni-${CONTAINERD_VERSION}-linux-amd64.tar.gz

sudo systemctl stop kubelet || true
( sudo crictl ps | grep Runnin | awk '{print $1}' | xargs sudo crictl rm -f ) || true

if ! cat /etc/containerd/config.toml | grep sandbox_image ; then
    sudo cat /etc/containerd/config.toml > /tmp/config.toml
    sed -i '/\[plugins\.cri\]/a \ \ sandbox_image = "'"${PAUSE_MIRROR}"'"' /tmp/config.toml
    sudo mv /tmp/config.toml /etc/containerd/config.toml
    sudo chown root:root /etc/containerd/config.toml
    sudo chmod 644 /etc/containerd/config.toml
fi

if ! cat /etc/containerd/config.toml | grep "${REGISTRY_HOST}" ; then
    cat /etc/containerd/config.toml > /tmp/config.toml
    cat <<EOF >> /tmp/config.toml
[plugins.cri.registry.mirrors."${REGISTRY_HOST}:5000"]
  endpoint = ["http://${REGISTRY_HOST}:5000"]
EOF
    sudo mv /tmp/config.toml /etc/containerd/config.toml
    sudo chown root:root /etc/containerd/config.toml
    sudo chmod 644 /etc/containerd/config.toml
fi

sudo systemctl stop containerd || true
sleep 10
sudo ps auxww | grep containerd | grep -v "${0}" | awk '{print $2}' | xargs -I{} sudo kill -9 {} || true
sudo cp usr/local/bin/* /usr/bin
sudo rm -rf /opt/cni && sudo cp -R opt/cni /opt/

sudo systemctl start containerd
sleep 10
sudo systemctl start kubelet
