# Copyright (C) 2024-2025 Red Hat, Inc.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
# http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
#
# SPDX-License-Identifier: Apache-2.0

ARG UBI_IMAGE=ubi
ARG UBI_VERSION=10

FROM registry.access.redhat.com/ubi${UBI_VERSION}/${UBI_IMAGE} AS base

ARG UBI_VERSION
ARG PYTHON_VERSION=3.12
ARG WORKSPACE=/workspace

USER 0

ARG GOSU_IMAGE_NAME=gosu
ARG GOSU_IMAGE_TAG=${UBI_IMAGE}${UBI_VERSION}
COPY --from=quay.io/triton-dev-containers/${GOSU_IMAGE_NAME}:${GOSU_IMAGE_TAG} /usr/local/bin/gosu /usr/local/bin/gosu

RUN dnf -y update && \
    dnf -y install clang cmake git glibc-langpack-en libxml2-devel \
    lld llvm llvm-libs libomp libomp-devel ninja-build openblas openblas-devel \
    python${PYTHON_VERSION}-devel python${PYTHON_VERSION}-pip zlib-devel && \
    dnf clean all && rm -rf /var/cache/dnf

# Create the /workspace directory and set permissions
WORKDIR $WORKSPACE
RUN python${PYTHON_VERSION} -m pip install uv && \
    uv venv --python ${PYTHON_VERSION} --seed $WORKSPACE && \
    echo "unset BASH_ENV PROMPT_COMMAND ENV" >> ${WORKSPACE}/bin/activate && \
    chmod -R 777 $WORKSPACE

ENV BASH_ENV=${WORKSPACE}/bin/activate \
    ENV=${WORKSPACE}/bin/activate \
    LANG=en_US.UTF-8 \
    LC_ALL=C.UTF-8 \
    PATH=${WORKSPACE}/bin:$PATH \
    PIP_PREFIX=$WORKSPACE \
    PROMPT_COMMAND=". ${WORKSPACE}/bin/activate" \
    PYTHON_VERSION=$PYTHON_VERSION \
    PYTHONUNBUFFERED=1 \
    PYTHONPATH=${WORKSPACE}/lib/python${PYTHON_VERSION}/site-packages \
    TRITON_HOME=$WORKSPACE \
    UBI_VERSION=$UBI_VERSION \
    UV_HTTP_TIMEOUT=60 \
    WORKSPACE=$WORKSPACE \
    XDG_CACHE_HOME=$WORKSPACE

COPY scripts/ldpretend.sh ${WORKSPACE}/ldpretend.sh
COPY scripts/install_software.sh ${WORKSPACE}/install_software.sh
COPY scripts/setup*.sh ${WORKSPACE}/

COPY hack/triton-gpu-check.py triton-gpu-check.py
