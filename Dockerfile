# syntax=docker/dockerfile:1.7
# Clean ComfyUI base image for RunPod — multi-stage, Debian 13 slim, Python 3.13, CUDA 13.
# CUDA comes from PyTorch's own libs; the base has none.
#  - Image (/opt): PyTorch, ComfyUI, File Browser, SSH.
#  - Volume: /workspace/models = models only (--models-directory);
#    /workspace/ComfyUI = custom_nodes, input, output, user (--base-directory).
#    Node-pack Python deps go to /workspace/.python (pip --user), so they survive
#    restarts. File Browser (:8080, login required) manages /workspace.
#
# Build: docker build --platform linux/amd64 -t <you>/comfyui-cuda13:1 .
# Pod:   network volume at /workspace; expose 8188/http, 8080/http, 22/tcp.
#        Host driver must be CUDA 13.x (nvidia-smi). PyTorch is cu130.

# PyTorch for CUDA 13.0. TORCH_VERSION empty = newest on the index; set e.g. 2.11.0 to pin
# torch + torchaudio (torchvision follows torch automatically).
ARG TORCH_INDEX=https://download.pytorch.org/whl/cu130
ARG TORCH_VERSION=
ARG COMFY_REF=master
ARG FILEBROWSER_VERSION=v2.63.23
ARG KOKON_IMAGE=ghcr.io/gabrielelozupone/kokon:0.12.1

########## Build Python packages + ComfyUI (same Debian/Python as runtime) ##########
FROM debian:13-slim AS builder
ARG TORCH_INDEX
ARG TORCH_VERSION
ARG COMFY_REF
ENV DEBIAN_FRONTEND=noninteractive PIP_NO_CACHE_DIR=1 PIP_DISABLE_PIP_VERSION_CHECK=1 PIP_ROOT_USER_ACTION=ignore
SHELL ["/bin/bash", "-o", "pipefail", "-c"]

RUN apt-get update && apt-get install -y --no-install-recommends \
      ca-certificates git python3 python3-pip python3-dev build-essential \
 && rm -rf /var/lib/apt/lists/* \
 # single-purpose container: let pip own the system Python (3.13 on Debian 13)
 && rm -f /usr/lib/python3*/EXTERNALLY-MANAGED

RUN if [ -n "${TORCH_VERSION}" ]; then PKGS=("torch==${TORCH_VERSION}" torchvision "torchaudio==${TORCH_VERSION}"); \
     else PKGS=(torch torchvision torchaudio); fi \
 && python3 -m pip install "${PKGS[@]}" --index-url "${TORCH_INDEX}" \
 && python3 -m pip freeze | grep -iE '^(torch|torchvision|torchaudio)==' > /opt/torch-constraints.txt \
 && cat /opt/torch-constraints.txt
ENV PIP_CONSTRAINT=/opt/torch-constraints.txt

# SageAttention 1 uses the Triton already installed with CUDA PyTorch, without nvcc.
RUN python3 -m pip install --no-deps sageattention==1.0.6 \
 && python3 -c 'from sageattention import sageattn; assert callable(sageattn)'

RUN git clone --depth 1 --branch "${COMFY_REF}" https://github.com/comfyanonymous/ComfyUI /opt/ComfyUI \
 && grep -viE '^(torch|torchvision|torchaudio)([<>=~! ]|$)' /opt/ComfyUI/requirements.txt > /tmp/req.txt \
 && python3 -m pip install -r /tmp/req.txt \
 && find /usr/local/lib/python3* /opt -name '__pycache__' -prune -exec rm -rf {} +

########## Runtime ##########
FROM debian:13-slim AS runtime
ARG FILEBROWSER_VERSION
ENV DEBIAN_FRONTEND=noninteractive PYTHONUNBUFFERED=1 PYTHONUTF8=1 \
    PIP_NO_CACHE_DIR=1 PIP_DISABLE_PIP_VERSION_CHECK=1 PIP_ROOT_USER_ACTION=ignore \
    PIP_CONSTRAINT=/opt/torch-constraints.txt \
    PYTHONUSERBASE=/workspace/.python \
    COMFY_ENV_ROOT=/workspace/.ce \
    COMFY_BASE=/workspace/ComfyUI \
    NVIDIA_VISIBLE_DEVICES=all NVIDIA_DRIVER_CAPABILITIES=compute,utility \
    PATH=$PATH:/workspace/.python/bin
# /workspace/.python/bin (last, so system tools win): commands that node packs' pip
# installs bring, e.g. `uv`, which comfy-env runs to install CUDA wheels into its envs.
SHELL ["/bin/bash", "-o", "pipefail", "-c"]

# python3-dev + build-essential stay: node packs on the volume can compile wheels at boot.
# git: node packs | ffmpeg: video nodes | libgl1/libglib: OpenCV | nano: editor
RUN apt-get update && apt-get install -y --no-install-recommends \
      ca-certificates curl git python3 python3-pip python3-dev build-essential \
      ffmpeg libgl1 libglib2.0-0 libgomp1 nano openssh-server procps tmux tini \
 && rm -rf /var/lib/apt/lists/* \
 && rm -f /usr/lib/python3*/EXTERNALLY-MANAGED \
 && ln -sf /usr/bin/python3 /usr/local/bin/python \
 && rm -f /etc/ssh/ssh_host_* \
 && sed -i 's/^#\?PasswordAuthentication .*/PasswordAuthentication no/; s/^#\?PermitRootLogin .*/PermitRootLogin prohibit-password/' /etc/ssh/sshd_config

# Node.js 24 from NodeSource (for ComfyUI front ends such as Mix Studio)
RUN curl -fsSL https://deb.nodesource.com/setup_24.x | bash - \
 && apt-get install -y --no-install-recommends nodejs \
 && rm -rf /var/lib/apt/lists/* \
 && node --version && npm --version

# File Browser: single static binary from its GitHub release
RUN curl -fsSL "https://github.com/filebrowser/filebrowser/releases/download/${FILEBROWSER_VERSION}/linux-amd64-filebrowser.tar.gz" \
      | tar -xz -C /usr/local/bin filebrowser \
 && filebrowser version

# pip installs as root land in /usr/local on Debian — copy exactly that over
COPY --from=builder /usr/local/lib /usr/local/lib
COPY --from=builder /usr/local/bin /usr/local/bin
COPY --from=builder /opt /opt
RUN python3 --version
COPY --chmod=755 entrypoint.sh /entrypoint.sh
# Helper commands for the supervised ComfyUI process (see entrypoint.sh).
# The pattern is anchored so it only matches ComfyUI itself, never a shell that mentions it.
COPY --chmod=755 comfyui-ctl.sh /usr/local/bin/comfyui-ctl
RUN for c in start restart stop args; do ln -s comfyui-ctl "/usr/local/bin/comfyui-$c"; done

WORKDIR /opt/ComfyUI
EXPOSE 22 8080 8188
# tini forwards stop signals and reaps exited child processes. -s (subreaper) keeps
# reaping working when the platform starts tini as a child instead of PID 1 (RunPod does).
ENTRYPOINT ["/usr/bin/tini", "-s", "-g", "--", "/entrypoint.sh"]

########## Optional image: add Kokon's published headless service ##########
FROM ${KOKON_IMAGE} AS kokon-source

FROM runtime AS kokon
RUN apt-get update && apt-get install -y --no-install-recommends libssl3t64 libvulkan1 \
 && rm -rf /var/lib/apt/lists/* \
 && useradd --create-home --uid 1000 kokon
COPY --from=kokon-source /usr/local/bin/kokon-service /usr/local/bin/kokon-service
ENV KOKON_ENABLED=true KOKON_CONTAINER=1 \
    QLS_DATA_DIR=/workspace/kokon/data \
    QLS_CONFIG_DIR=/workspace/kokon/config \
    QLS_OUTPUT_DIR=/workspace/kokon/gallery
EXPOSE 39152

# Default to the ComfyUI image for builds that do not specify --target.
FROM runtime AS final
