#!/bin/bash

CONTEXT="$( cd "$( dirname "${BASH_SOURCE[0]}" )" >/dev/null 2>&1 && pwd )/"
REPO="${CONTEXT}../../"

TMPDIR=$(mktemp -d)

cat <<EOF > "${TMPDIR}/docker-compose.yaml"
version: "3.7"
services:
  containerd_ctr_bench:
    image: golang:1.13-buster
    container_name: containerd_ctr_bench
    privileged: true
    working_dir: /go/src/github.com/containerd/stargz-snapshotter
    entrypoint: ./script/optimize-bench/run.sh
    environment:
    - NO_PROXY=127.0.0.1,localhost,registry2:5000
    - HTTP_PROXY=${HTTP_PROXY}
    - HTTPS_PROXY=${HTTPS_PROXY}
    - http_proxy=${http_proxy}
    - https_proxy=${https_proxy}
    - GOPATH=/go
    tmpfs:
    - /tmp:exec,mode=777
    volumes:
    - /dev/fuse:/dev/fuse
    - "${REPO}:/go/src/github.com/containerd/stargz-snapshotter:ro"
  registry-ctr2:
    image: registry:2
    container_name: registry-ctr2
    environment:
    - HTTP_PROXY=${HTTP_PROXY}
    - HTTPS_PROXY=${HTTPS_PROXY}
    - http_proxy=${http_proxy}
    - https_proxy=${https_proxy}
EOF


cd "${TMPDIR}"
docker-compose -f "${TMPDIR}/docker-compose.yaml" up --abort-on-container-exit
