#!/bin/bash

set -eux -o pipefail

BOOTSTRAP_YAML="${1}"
BOOTSTRAP_SVC_IP="${2}"
SOURCEREG="${3}"
IMAGE="${4}"

IPFS_SWARM_KEY=$(cat ${BOOTSTRAP_YAML} | yq eval '.data.ipfs-swarm-key' - | grep -v null | grep -v -- '--' | base64 -d)
IPFS_BOOTSTRAP_PEER_ID=$(wget -O - ${BOOTSTRAP_SVC_IP}:8000/id)

function kill_all {
    if [ "${1}" != "" ] ; then
        ps auxww | grep "${1}" | grep -v grep | sed -E 's/ +/ /g' | cut -f 2 -d ' ' | xargs -I{} kill -9 {} || true
    fi
}

kill_all " ipfs"
rm -rf ~/.ipfs

export LIBP2P_FORCE_PNET=1
ipfs init --profile=badgerds,server
ipfs bootstrap rm --all
ipfs bootstrap add /dns4/${BOOTSTRAP_SVC_IP}/tcp/4001/ipfs/${IPFS_BOOTSTRAP_PEER_ID}
ipfs config Addresses.NoAnnounce --json '[]'
ipfs config Swarm.AddrFilters --json '[]'
ipfs config Datastore.StorageMax 10GB
echo -n "${IPFS_SWARM_KEY}" > ~/.ipfs/swarm.key
nohup ipfs daemon >>~/ipfs.log 2>&1 &

OK=false
for i in {0..100} ; do
    echo "checking ipfs is ready..."
    if ! [ -f .ipfs/repo.lock ] ; then
	echo "daemon hasn't been started"
	sleep 5
	continue
    fi
    PEERS="$(ipfs swarm peers || true)"
    if [ "${PEERS}" == "" ] ; then
	echo "ipfs not ready (${PEERS})"
	sleep 5
	continue
    fi
    OK=true
    echo "${PEERS}"
    break
done
if [ "${OK}" != "true" ] ; then
    echo "FAIL: ipfs is not ready"
    exit 1
fi

if ! [ -f /home/$(whoami)/ipfs-api/api ] ; then
    mkdir -p /home/$(whoami)/ipfs-api ; echo -n "/ip4/127.0.0.1/tcp/5001" >  /home/$(whoami)/ipfs-api/api
fi

sudo nerdctl pull ${SOURCEREG}/${IMAGE}
sudo IPFS_PATH=/home/$(whoami)/ipfs-api nerdctl push ipfs://${SOURCEREG}/${IMAGE}
sudo nerdctl rmi ${SOURCEREG}/${IMAGE}
