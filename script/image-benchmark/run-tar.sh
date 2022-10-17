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

RES_DIR=${1}
IMAGE=${2}
SOURCE_REGISTRY=${3}
WORKING_REGISTRY=${4}

CHUNK_SIZES="0 1000 10000 25000 50000"

for MIN_CHUNK_SIZE in ${CHUNK_SIZES} ; do
    echo "Measuring min-chunk-size: ${MIN_CHUNK_SIZE} ============================================="
    METADATA_STORE="${METADATA_STORE:-memory}" ./script/image-benchmark/prepare.sh
    sleep 3
    ctr-remote i pull ${SOURCE_REGISTRY}/${IMAGE}
    ctr-remote i convert --oci --estargz --estargz-min-chunk-size=${MIN_CHUNK_SIZE} ${SOURCE_REGISTRY}/${IMAGE} ${WORKING_REGISTRY}/${IMAGE}-${MIN_CHUNK_SIZE}
    ctr-remote i push --plain-http ${WORKING_REGISTRY}/${IMAGE}-${MIN_CHUNK_SIZE}
    for i in $(seq 0 2) ; do
        echo "Iteration $i"
        METADATA_STORE="${METADATA_STORE:-memory}" ./script/image-benchmark/prepare.sh
        sleep 3
        ctr-remote i rpull --plain-http ${WORKING_REGISTRY}/${IMAGE}-${MIN_CHUNK_SIZE}
        mount | grep "stargz on"
        ( ctr-remote run --snapshotter=stargz --rm ${WORKING_REGISTRY}/${IMAGE}-${MIN_CHUNK_SIZE} foo /bin/bash -c 'time ( tar --exclude=/sys --exclude=/proc --exclude=/dev -cf - / | cat > /dev/null )' ) 2>&1 | grep "real" | tee -a ${RES_DIR}/${MIN_CHUNK_SIZE}
    done
done
