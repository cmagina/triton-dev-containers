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
ARG UBI_VERSION=9

FROM registry.access.redhat.com/ubi${UBI_VERSION}/${UBI_IMAGE} AS base

ARG UBI_VERSION
ARG PYTHON_VERSION=3.12
ARG WORKSPACE=/workspace

ARG INSTALL_JUPYTER=true
ARG INSTALL_LLVM=skip
ARG INSTALL_TORCH=skip
ARG INSTALL_TRITON=skip
ARG INSTALL_VLLM=skip

USER 0

ARG EPEL_REPO=https://dl.fedoraproject.org/pub/epel/epel-release-latest-${UBI_VERSION}.noarch.rpm
RUN rpm -ivh $EPEL_REPO && \
    rpm -ql epel-release && \
    /usr/bin/crb enable && \
    dnf -y install ccache && \
    dnf clean all && rm -rf /var/cache/dnf

RUN dnf update -y && \
    dnf -y install clang cmake git lld llvm llvm-libs libomp libomp-devel \
    ninja-build openblas openblas-devel python${PYTHON_VERSION}-devel \
    python${PYTHON_VERSION}-pip && \
    dnf clean all && rm -rf /var/cache/dnf

COPY --from=quay.io/triton-dev-containers/gosu /usr/local/bin/gosu /usr/local/bin/gosu

# Create the /workspace directory and set permissions
WORKDIR $WORKSPACE
RUN python${PYTHON_VERSION} -m pip install uv && \
    uv venv --python 3.12 --seed $WORKSPACE && \
    echo "unset BASH_ENV PROMPT_COMMAND ENV" >> ${WORKSPACE}/bin/activate && \
    chmod -R 777 $WORKSPACE

ENV BASH_ENV=${WORKSPACE}/bin/activate \
    CCACHE_DIR=${WORKSPACE}/.cache/ccache \
    ENV=${WORKSPACE}/bin/activate \
    PROMPT_COMMAND=". ${WORKSPACE}/bin/activate" \
    PYTHON_VERSION=$PYTHON_VERSION \
    PATH=${WORKSPACE}/bin:$PATH \
    PYTHONUNBUFFERED=1 \
    PIP_PREFIX=$WORKSPACE \
    PYTHONPATH=${WORKSPACE}/lib/python${PYTHON_VERSION}/site-packages \
    XDG_CACHE_HOME=$WORKSPACE \
    TRITON_BUILD_WITH_CCACHE=true \
    TRITON_CACHE_DIR=${WORKSPACE}/.triton/cache \
    TRITON_HOME=$WORKSPACE \
    INSTALL_JUPYTER=$INSTALL_JUPYTER \
    INSTALL_LLVM=$INSTALL_LLVM \
    INSTALL_TORCH=$INSTALL_TORCH \
    INSTALL_TRITON=$INSTALL_TRITON \
    INSTALL_VLLM=$INSTALL_VLLM \
    UBI_VERSION=$UBI_VERSION \
    WORKSPACE=$WORKSPACE

RUN tee -a "${HOME}/.bashrc" <<EOF
export LD_LIBRARY_PATH=/usr/lib64:$LD_LIBRARY_PATH
EOF

COPY scripts/ldpretend.sh ${WORKSPACE}/ldpretend.sh
COPY scripts/install_software.sh ${WORKSPACE}/install_software.sh
COPY scripts/setup*.sh ${WORKSPACE}/

COPY hack/triton-gpu-check.py triton-gpu-check.py
