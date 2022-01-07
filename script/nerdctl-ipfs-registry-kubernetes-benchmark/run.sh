#!/bin/bash

set -euo pipefail

###############################################
#
# Mandatory configuration envvars
#
PROJECT="${PROJECT}"
ZONE="${ZONE}"
REGISTRY_NODE="${REGISTRY_NODE}"
REGISTRY_NODE_IP="${REGISTRY_NODE_IP}"
RESULT_DIR="${RESULT_DIR}"
###############################################

PROJECT_DOMAIN="${ZONE}.c.${PROJECT}.internal"

# Benchmark configuration
PULLS="1 5 10 15 20"
BANDWIDTH_MBITS="500 1000 4000 16000"
NODE_RESTRICT_VCPUS="${NODE_RESTRICT_VCPUS:-1}"
TARGET_REPO=ghcr.io/stargz-containers
TARGET_IMAGE=jenkins:2.60.3-org
TARGET_IMAGE_CID=bafkreife3j4tgtx23jcautprornrdp2p4g3j3ndnidzdlrpd7unbpnwkce
IPFS_BOOTSTRAP_LB=ipfs-bootstrap-llb
IPFS_YAML_REPO=https://github.com/ktock/stargz-snapshotter
IPFS_YAML_REPO_COMMIT=nerdctl-ipfs-registry-kubernetes
IPFS_YAML_PATH=script/nerdctl-ipfs-registry-kubernetes

# Script dependencies
CONTEXT="$( cd "$( dirname "${BASH_SOURCE[0]}" )" >/dev/null 2>&1 && pwd )/"
SETUP_NODE_SCRIPT=${CONTEXT}/setup-node.sh
SETUP_REGISTRY_SCRIPT=${CONTEXT}/setup-registry.sh
SETUP_IPFS_SCRIPT=${CONTEXT}/setup-ipfs.sh
BOOTSTRAP_SERVICE_YAML=${CONTEXT}/bootstrap-service.yaml
TMPREPO=$(mktemp -d)
echo "Cloning ipfs yaml repo to $TMPREPO"
git clone "${IPFS_YAML_REPO}" "${TMPREPO}"
(
    cd "${TMPREPO}"
    git checkout "${IPFS_YAML_REPO_COMMIT}"
)
mkdir -p ${RESULT_DIR}
IPFS_YAML="${RESULT_DIR}/ipfskube"
mkdir -p "${IPFS_YAML}"
"${TMPREPO}/${IPFS_YAML_PATH}"/bootstrap.yaml.sh > "${IPFS_YAML}/bootstrap.yaml"
cp "${TMPREPO}/${IPFS_YAML_PATH}"/nerdctl-ipfs-registry.yaml "${IPFS_YAML}/"
rm -rf "${TMPREPO}"

###############################################
# Utilities
###############################################

function wait_jobs() {
    echo "waiting jobs to finish..."
    local FAIL=0
    for job in $(jobs -p) ; do
	echo "waiting job $job ..."
	wait $job || let "FAIL+=1"
    done
    if [ "$FAIL" != "0" ]; then
	echo "FAIL: fails:$FAIL, pulls: $P"
	return 1
    fi
    return 0
}

function wait_until_no_pod() {
    echo "waiting until all pods are removed..."
    for i in {0..100} ; do
	if [ "$(kubectl get pods -o name)" == "" ] ; then
	    return 0
	fi
	echo "some pods are running"
	kubectl get pods
	sleep 5
    done
    echo "FAIL: pods are deleting too long"
    return 1
}

function wait_all_pods_running() {
    echo "waiting for all pods are running..."
    for i in {0..100} ; do
        PENDING=0
        for s in $(kubectl get pods -ojsonpath='{.items.*.status.phase}') ; do
            if [ "${s}" != "Running" ] ; then
                (( PENDING += 1 ))
            fi
        done
        if [ "${PENDING}" == "0" ] ; then
            return 0
	fi
        echo "${PENDING} pods are pending"
	kubectl get pods
        sleep 5
    done
    echo "FAIL: pods are pending too long"
    return 1
}

function wait_ingress_ip() {
    echo "waiting for ingress ip is assigned..."
    for i in {0..100} ; do
	GOT_IP=$(kubectl get svc "${IPFS_BOOTSTRAP_LB}" -ojsonpath='{.status.loadBalancer.ingress[0].ip}')
	if [ "${GOT_IP}" != "" ] ; then
	    echo "got ${GOT_IP}"
	    return 0
	fi
	echo "no ip is assigned ($i)"
        sleep 5
    done
    echo "FAIL: ip is pending too long"
    return 1
}

function delete_all_images() {
    echo "deleting all images on nodes"
    for n in $(kubectl get node -o custom-columns='DATA:metadata.name' | grep gke); do
	ssh -n ${n}.${PROJECT_DOMAIN} "sudo ctr -n k8s.io image ls | sed -E 's/ +/ /g' | cut -f 1 -d ' ' | grep -v REF | xargs sudo ctr -n k8s.io i rm" >>${RESULT_DIR}/${n}.log 2>&1 &
	sleep 0.2
    done
    wait_jobs
}

function configure_all() {
    echo "configuring all nodes"
    scp ${SETUP_REGISTRY_SCRIPT} ${REGISTRY_NODE}.${PROJECT_DOMAIN}:~/
    scp ${SETUP_IPFS_SCRIPT} ${REGISTRY_NODE}.${PROJECT_DOMAIN}:~/
    scp "${IPFS_YAML}/bootstrap.yaml" ${REGISTRY_NODE}.${PROJECT_DOMAIN}:~/

    ssh ${REGISTRY_NODE}.${PROJECT_DOMAIN} /bin/bash $(basename ${SETUP_REGISTRY_SCRIPT}) ${TARGET_REPO} ${TARGET_IMAGE}
    for n in $(kubectl get node -o custom-columns='DATA:metadata.name' | grep gke); do
    	echo "UPGRADING: ${n}"
    	scp ${SETUP_NODE_SCRIPT} ${n}.${PROJECT_DOMAIN}:~/
    	if ! ssh -n ${n}.${PROJECT_DOMAIN} /bin/bash $(basename ${SETUP_NODE_SCRIPT}) ${REGISTRY_NODE_IP} >${RESULT_DIR}/${n}.log 2>&1 ; then
            echo "FAIL: ${n}"
    	    exit 1
    	fi &
    	sleep 0.2
    done
    wait_jobs

    kubectl apply -f ${BOOTSTRAP_SERVICE_YAML}
    wait_ingress_ip
}

function parse_k8s_time() {
    local RAWTIME="${1}"
    local UNIT=$(echo "${RAWTIME}" | sed -E 's/^[0-9\.]+([muns\.]+.*)/\1/')
    local TIME=$(echo "${RAWTIME}" | sed -E 's/^([0-9\.]+)[muns\.]+.*/\1/')
    case $UNIT in
        ms)
            echo "$TIME"
            ;;
        s)
            echo $(echo "${TIME}"' * 1000' | bc)
            ;;
        *)
	    if [ "${UNIT::1}" == "m" ] ; then
		SUBTIME=$(parse_k8s_time ${UNIT:1})
		echo $(echo "${TIME}"' * 60000 + '"${SUBTIME}" | bc)
		return
	    fi
            # TODO
            echo "unsupported unit $UNIT"
            return 1
            ;;
    esac
}

function deploy() {
    local RESULT="${1}"
    local IMAGE="${2}"
    local REPLICAS="${3}"

    NAME=sample-$(date +%s%N | shasum | base64 | fold -w 10 | head -1 | tr '[:upper:]' '[:lower:]')
    TMPYAML=$(mktemp)
    cat <<EOF > "${TMPYAML}"
apiVersion: apps/v1
kind: Deployment
metadata:
  name: ${NAME}
spec:
  replicas: ${REPLICAS}
  selector:
    matchLabels:
      app: ${NAME}
  template:
    metadata:
      labels:
        app: ${NAME}
    spec:
      containers:
      - name: ${NAME}
        image: ${IMAGE}
        command: ["sleep", "infinity"]
        resources:
          requests:
            cpu: ${VCPUS:-1}
EOF
    echo "Applying ${TMPYAML}..."
    cat "${TMPYAML}"
    kubectl apply -f "${TMPYAML}"
    for i in {0..100} ; do
        echo "checking ${REPLICAS} pods are running..."
        RUNNING=0
        for s in $(kubectl get pods -l app=${NAME} -ojsonpath='{.items.*.status.phase}') ; do
            if [ "${s}" == "Running" ] ; then
                (( RUNNING += 1 ))
            fi
        done
        if ! [ "${RUNNING}" -ge "${REPLICAS}" ] ; then
            echo "running(${RUNNING}) != wants(${REPLICAS})"
            sleep 5
	    continue
	fi
        MAX=0
        PULLED_IMAGES=0
        kubectl describe pods -l app=${NAME} | grep "Successfully pulled"
        for RAWV in $(kubectl describe pods -l app=${NAME} | grep "Successfully pulled" | sed -E 's/.*in ([0-9muns\.]+)/\1/'); do
            v=$(parse_k8s_time "${RAWV}")
            echo "Pulled in $v millisec"
            MAX=$(echo "if($v>$MAX) $v else $MAX" | bc)
            (( PULLED_IMAGES += 1 ))
        done
        if [ "${PULLED_IMAGES}" -lt "$(( REPLICAS - 1 ))" ] ; then
            echo "some image haven't been pulled"
            return 1
        fi
	NODES=$(kubectl describe pods -l app=${NAME} | grep "Node:" | sort | uniq -c)
	echo "${NODES}"
	NODESNUM=$(echo "${NODES}" | wc -l)
	if [ "${NODESNUM}" -lt "${REPLICAS}" ] ; then
	    echo "duplicated deploy: ${NODESNUM}(nodes) != ${REPLICAS}(replicas)"
	    return 1
	fi
        echo -n "${MAX}," >> "${RESULT}"
        kubectl delete -f "${TMPYAML}"
        rm "${TMPYAML}"
        return 0
    done
    echo "timeout: failed to deploy some pods"
    return 1
}

function measure_registry() {
    local NAME="${NAME}"
    local PULL_REPLICAS="${PULL_REPLICAS}"

    echo "measuring with registry (name: $NAME, replicas: $PULL_REPLICAS)"
    wait_until_no_pod
    delete_all_images
    VCPUS=$NODE_RESTRICT_VCPUS deploy ${RESULT_DIR}/result-registry-$NAME-$PULL_REPLICAS ${REGISTRY_NODE_IP}:5000/${TARGET_IMAGE} $PULL_REPLICAS
}

function measure_ipfs() {
    local NAME="${NAME}"
    local PULL_REPLICAS="${PULL_REPLICAS}"
    local BOOTSTRAP_SERVICE_IP=$(kubectl get svc "${IPFS_BOOTSTRAP_LB}" -ojsonpath='{.status.loadBalancer.ingress[0].ip}')
    if [ "${BOOTSTRAP_SERVICE_IP}" == "" ] ; then
	echo "failed to get bootstrap"
	return 1
    fi

    echo "measuring with ipfs (name: $NAME, replicas: $PULL_REPLICAS)"
    kubectl delete -f "${IPFS_YAML}" || true
    wait_until_no_pod
    for n in $(kubectl get node -o custom-columns='DATA:metadata.name' | grep gke); do
        (
	    # cleanup ipfs repo
	    ssh -n ${n}.${PROJECT_DOMAIN} sudo rm -rf /var/ipfs
	    ssh -n ${n}.${PROJECT_DOMAIN} sudo ls /var/
        ) &
    	sleep 0.5
    done
    wait_jobs
    kubectl apply -f "${IPFS_YAML}"
    sleep 3
    wait_all_pods_running
    ssh -n ${REGISTRY_NODE}.${PROJECT_DOMAIN} /bin/bash $(basename ${SETUP_IPFS_SCRIPT}) bootstrap.yaml ${BOOTSTRAP_SERVICE_IP} ${TARGET_REPO} ${TARGET_IMAGE}
    delete_all_images
    VCPUS=$NODE_RESTRICT_VCPUS deploy ${RESULT_DIR}/result-ipfs-$NAME-$PULL_REPLICAS localhost:5050/ipfs/$TARGET_IMAGE_CID $PULL_REPLICAS
    kubectl delete -f "${IPFS_YAML}"
    for n in $(kubectl get node -o custom-columns='DATA:metadata.name' | grep gke); do
        (
	    # cleanup ipfs repo
	    ssh -n ${n}.${PROJECT_DOMAIN} sudo rm -rf /var/ipfs
	    ssh -n ${n}.${PROJECT_DOMAIN} sudo ls /var/
        ) &
    	sleep 0.5
    done
    ssh ${REGISTRY_NODE}.${PROJECT_DOMAIN} ps auxww | grep ipfs | grep -v grep | sed -E 's/ +/ /g' | cut -f 2 -d ' ' | xargs -I{} ssh ${REGISTRY_NODE}.${PROJECT_DOMAIN} kill -9 {} || true
}

function measure_iperf() {
    local SERVER="${1}"
    local CLIENT="${2}"

    echo "Measuring iperf (SERVER=${SERVER}, CLIENT=${CLIENT})..."
    TMPRES=$(mktemp)
    ssh "${SERVER}" iperf3 -s &
    SV=$!
    sleep 3
    ssh "${CLIENT}" iperf3 -c "${SERVER}" >${TMPRES} 2>&1
    cat "${TMPRES}"
    kill $SV || true
    ssh "${SERVER}" ps auxww | grep iperf3 | grep -v grep | sed -E 's/ +/ /g' | cut -f 2 -d ' ' | xargs -I{} ssh "${SERVER}" kill -9 {} || true
    rm "${TMPRES}"
}

function measure() {
    local FIRST_NODE=$(kubectl get node -o custom-columns='DATA:metadata.name' | grep gke | head -n 1)
    if [[ "${FIRST_NODE}" == "" ]] ; then
	echo "cannot get the first node"
	return 1
    fi
    for B in $BANDWIDTH_MBITS ; do
	echo "===== measuring with bandwidth = $B Mbit/s ====="
	ssh ${REGISTRY_NODE}.${PROJECT_DOMAIN} sudo tc qdisc delete dev ens4 root || true
	ssh ${REGISTRY_NODE}.${PROJECT_DOMAIN} sudo tc qdisc delete dev ens4 ingress || true
	ssh ${REGISTRY_NODE}.${PROJECT_DOMAIN} sudo tc qdisc delete dev ifb0 root || true

	ssh ${REGISTRY_NODE}.${PROJECT_DOMAIN} sudo ip link set dev ifb0 up
        ssh ${REGISTRY_NODE}.${PROJECT_DOMAIN} sudo tc qdisc add dev ens4 ingress
        ssh ${REGISTRY_NODE}.${PROJECT_DOMAIN} sudo tc filter add dev ens4 parent ffff: protocol ip u32 match u32 0 0 action mirred egress redirect dev ifb0
        ssh ${REGISTRY_NODE}.${PROJECT_DOMAIN} sudo tc qdisc add dev ifb0 root netem rate ${B}Mbit
        ssh ${REGISTRY_NODE}.${PROJECT_DOMAIN} sudo tc qdisc add dev ens4 root netem rate ${B}Mbit

	measure_iperf ${FIRST_NODE}.${PROJECT_DOMAIN} ${REGISTRY_NODE}.${PROJECT_DOMAIN}
	measure_iperf ${REGISTRY_NODE}.${PROJECT_DOMAIN} ${FIRST_NODE}.${PROJECT_DOMAIN}

	for P in $PULLS ; do
	    echo "===== Measuring with registry (PULLS=$P) ======"
	    NAME=${B}mbit PULL_REPLICAS=${P} measure_registry
	    echo "===== Measuring with ipfs (PULLS=$P) ======"
	    NAME=${B}mbit PULL_REPLICAS=${P} measure_ipfs
	done
    done
}

###############################################
# Measure
###############################################

echo "===== Configuring cluster ====="
configure_all

echo "===== Cluster info ====="
kubectl cluster-info
kubectl version
kubectl get nodes -owide

echo "===== Measuring ====="
measure

echo "Done"
