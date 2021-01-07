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

JSON="$(mktemp)"
cat > "${JSON}"

CONTEXT="$( cd "$( dirname "${BASH_SOURCE[0]}" )" >/dev/null 2>&1 && pwd )/"
source "${CONTEXT}/util.sh"

if [ "${1}" == "" ] ; then
    echo "Specify directory for output"
    exit 1
fi

if [ "${2}" == "" ] ; then
    echo "Specify worker"
    exit 1
fi

DATADIR="${1}/"
echo "output into: ${DATADIR}"
BUILDKIT_WORKER="${2}"

MODES=( ${TARGET_MODES:-} )
if [ ${#MODES[@]} -eq 0 ] ; then
    MODES=("legacy" "estargz-noopt" "estargz")
fi

IMAGES=( ${TARGET_IMAGES:-} )
if [ ${#IMAGES[@]} -eq 0 ] ; then
    IMAGES=( $(cat "${JSON}" | jq -r '[ .[] | select(.mode=="'${MODES[0]}'").image ] | unique[]') )
fi

# Ensure we use the exact same number of samples among benchmarks
MINSAMPLES=
for IMGNAME in "${IMAGES[@]}" ; do
    for MODE in "${MODES[@]}"; do
        THEMIN=$(samples_num "${JSON}" "${IMGNAME}" "${MODE}")
        if [ "${MINSAMPLES}" == "" ] ; then
            MINSAMPLES="${THEMIN}"
        fi
        MINSAMPLES=$(echo "${MINSAMPLES} ${THEMIN}" | tr ' ' '\n' | sort -n | head -1)
    done
done

PLTFILE_ALL="${DATADIR}result_${BUILDKIT_WORKER}.plt"
GRAPHFILE_ALL="${DATADIR}result_${BUILDKIT_WORKER}.png"

cat <<EOF > "${PLTFILE_ALL}"
set output '${GRAPHFILE_ALL}'
set title "Time to take for building containers with ${BUILDKIT_WORKER}(${PERCENTILE} pctl., ${MINSAMPLES} samples)"
set terminal png size 1000, 750
set style data histogram
set style histogram rowstack gap 1
set style fill solid 1.0 border -1
set key autotitle columnheader
set xtics rotate by -45
set ylabel 'time[sec]'
set lmargin 10
set rmargin 5
set tmargin 5
set bmargin 5
plot \\
EOF

NOTITLE=
INDEX=1
for IMGNAME in "${IMAGES[@]}" ; do
    echo "[${INDEX}]Processing: ${IMGNAME}"
    IMAGE=$(echo "${IMGNAME}" | sed 's|[/:]|-|g')
    DATAFILE="${DATADIR}${IMAGE}.dat"
    SUFFIX=', \'
    if [ ${INDEX} -eq ${#IMAGES[@]} ] ; then
        SUFFIX=''
    fi
    
    echo "mode build" > "${DATAFILE}"
    for MODE in "${MODES[@]}"; do
        BUILDTIME=$(percentile "${JSON}" "${MINSAMPLES}" "${IMGNAME}" "${MODE}")
        echo "${MODE} ${BUILDTIME}" >> "${DATAFILE}"
    done

    echo 'newhistogram "'"${IMAGE}"'", "'"${DATAFILE}"'" u 2:xtic(1) fs pattern 1 lt -1 '"${NOTITLE}""${SUFFIX}" \
         >> "${PLTFILE_ALL}"
    NOTITLE=notitle
    ((INDEX+=1))
done

gnuplot "${PLTFILE_ALL}"
