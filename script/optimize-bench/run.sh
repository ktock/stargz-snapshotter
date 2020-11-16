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

apt-get update && apt-get install -y fuse

echo "===== master ===="
rm -rf $HOME/master/ || true
git clone -b master --depth 1 \
    https://github.com/containerd/stargz-snapshotter $HOME/master/
cd $HOME/master/
make ctr-remote
for i in 1 2 3 ; do
    echo "Iteration $i"
    time ./out/ctr-remote i optimize --args='[ "echo", "hello" ]' \
         --plain-http ghcr.io/stargz-containers/fedora:30-org \
         http://registry-ctr2:5000/fedora:30-esgz
done

echo "===== PR ===="
rm -rf $HOME/pr/ || true
git clone -b sgzdivide --depth 1 \
    https://github.com/ktock/stargz-snapshotter $HOME/pr/
cd $HOME/pr/
make ctr-remote
for i in 1 2 3 ; do
    echo "Iteration $i"
    time ./out/ctr-remote i optimize --args='[ "echo", "hello" ]' \
         --plain-http ghcr.io/stargz-containers/fedora:30-org \
         http://registry-ctr2:5000/fedora:30-esgz
done

exit 0
