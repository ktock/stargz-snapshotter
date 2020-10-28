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

FROM ghcr.io/stargz-containers/gcc:10.2.0-{{ IMAGE_MODE_SUFFIX }} AS dev
COPY ./main.c /root/
RUN cd /root && gcc -static -o hello ./main.c

FROM ghcr.io/stargz-containers/alpine:3.10.2-{{ IMAGE_MODE_SUFFIX }}
COPY --from=dev /root/hello /hello
ENTRYPOINT [ "/hello" ]
