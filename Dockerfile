# syntax=docker/dockerfile:1.7
# Clean ComfyUI base image for RunPod — multi-stage, Debian 13 slim, Python 3.13, CUDA 13.
# CUDA comes from PyTorch's own libs and the llama.cpp image's libs; the base has none.
#  - Image (/opt): PyTorch, ComfyUI, llama-server, File Browser, SSH.
#  - Volume: /workspace/models = models only (--models-directory);
#    /workspace/ComfyUI = custom_nodes, input, output, user (--base-directory).
#    Node-pack Python deps go to /workspace/.python (pip --user), so they survive
#    restarts. File Browser (:8080, login required) manages /workspace.
#
# Build: docker build --platform linux/amd64 -t <you>/comfyui-cuda13:1 .
# Pod:   network volume at /workspace; expose 8188/http, 8080/http, 22/tcp (+ 8089/http for llama).
#        Host driver must be CUDA 13.x (nvidia-smi). PyTorch is cu130; llama-server's
#        libs are 13.4 and rely on CUDA 13 minor-version compatibility on 13.0-13.3 drivers.
#        llama-server (port 8089) is off by default: LLAMA_ENABLED=true + LLAMA_ARG_MODEL.

# Official llama.cpp server image built for CUDA 13 (13.4.1 per llama.cpp's
# .github/workflows/docker.yml). Its binaries + the CUDA libs they link to are copied
# into the Debian runtime, so no compile and no CUDA install is needed here.
# Pin it for reproducible builds: ghcr.io/ggml-org/llama.cpp:server-cuda13@sha256:<digest>
ARG LLAMA_IMAGE=ghcr.io/ggml-org/llama.cpp:server-cuda13
# PyTorch for CUDA 13.0. TORCH_VERSION empty = newest on the index; set e.g. 2.11.0 to pin
# torch + torchaudio (torchvision follows torch automatically).
ARG TORCH_INDEX=https://download.pytorch.org/whl/cu130
ARG TORCH_VERSION=
ARG COMFY_REF=master
ARG FILEBROWSER_VERSION=v2.63.23

########## Stage 1: llama-server from the official CUDA 13 image ##########
FROM ${LLAMA_IMAGE} AS llama
SHELL ["/bin/bash", "-o", "pipefail", "-c"]
# The image lays llama-server and its ggml/llama *.so out flat under /app; that folder is
# copied as-is below. A Debian base has no CUDA libs, so also collect the NVIDIA runtime
# libs /app links to (cudart, cuBLAS, NCCL, ...), wherever this image keeps them.
# libcuda.so.1 is the host driver (RunPod provides it) and is not copied.
RUN mkdir -p /nvlibs \
 && LD_LIBRARY_PATH=/app ldd /app/llama-server /app/*.so* \
      | grep -oE '=> /[^ ]+' | cut -c4- | grep -v stubs \
      | grep -E '/lib(cudart|cublas|cublasLt|cufft|curand|cusolver|cusparse|nvrtc|nvJitLink|nvjitlink|nccl)[^/]*\.so[^/]*$' \
      | sort -u | xargs -r -I{} cp -L {} /nvlibs/ \
 && ls /nvlibs

########## Stage 2: build Python packages + ComfyUI (same Debian/Python as runtime) ##########
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

RUN git clone --depth 1 --branch "${COMFY_REF}" https://github.com/comfyanonymous/ComfyUI /opt/ComfyUI \
 && grep -viE '^(torch|torchvision|torchaudio)([<>=~! ]|$)' /opt/ComfyUI/requirements.txt > /tmp/req.txt \
 && python3 -m pip install -r /tmp/req.txt \
 && find /usr/local/lib/python3* /opt -name '__pycache__' -prune -exec rm -rf {} +

########## Stage 3: runtime ##########
FROM debian:13-slim
ARG FILEBROWSER_VERSION
ENV DEBIAN_FRONTEND=noninteractive PYTHONUNBUFFERED=1 PYTHONUTF8=1 \
    PIP_NO_CACHE_DIR=1 PIP_DISABLE_PIP_VERSION_CHECK=1 PIP_ROOT_USER_ACTION=ignore \
    PIP_CONSTRAINT=/opt/torch-constraints.txt \
    PYTHONUSERBASE=/workspace/.python \
    COMFY_BASE=/workspace/ComfyUI \
    NVIDIA_VISIBLE_DEVICES=all NVIDIA_DRIVER_CAPABILITIES=compute,utility \
    PATH=/opt/llama:$PATH
SHELL ["/bin/bash", "-o", "pipefail", "-c"]

# python3-dev + build-essential stay: node packs on the volume can compile wheels at boot.
# git: node packs | ffmpeg: video nodes | libgl1/libglib: OpenCV | libgomp1: llama
RUN apt-get update && apt-get install -y --no-install-recommends \
      ca-certificates curl git python3 python3-pip python3-dev build-essential \
      ffmpeg libgl1 libglib2.0-0 libgomp1 openssh-server procps tmux tini \
 && rm -rf /var/lib/apt/lists/* \
 && rm -f /usr/lib/python3*/EXTERNALLY-MANAGED \
 && ln -sf /usr/bin/python3 /usr/local/bin/python \
 && rm -f /etc/ssh/ssh_host_* \
 && sed -i 's/^#\?PasswordAuthentication .*/PasswordAuthentication no/; s/^#\?PermitRootLogin .*/PermitRootLogin prohibit-password/' /etc/ssh/sshd_config

# File Browser: single static binary from its GitHub release
RUN curl -fsSL "https://github.com/filebrowser/filebrowser/releases/download/${FILEBROWSER_VERSION}/linux-amd64-filebrowser.tar.gz" \
      | tar -xz -C /usr/local/bin filebrowser \
 && filebrowser version

# pip installs as root land in /usr/local on Debian — copy exactly that over
COPY --from=builder /usr/local/lib /usr/local/lib
COPY --from=builder /usr/local/bin /usr/local/bin
COPY --from=builder /opt /opt
# llama-server: the official image's /app as-is (binary + ggml/llama libs, flat), plus the
# NVIDIA libs collected in stage 1. LD_LIBRARY_PATH=/opt/llama is set only for the
# llama-server process (entrypoint.sh), so these libs never shadow PyTorch's own CUDA libs.
COPY --from=llama /app/ /opt/llama/
COPY --from=llama /nvlibs/ /opt/llama/
# Report (don't fail on) any library llama-server still can't resolve; libcuda.so.1 is
# expected to be missing at build time - the host driver provides it on the pod.
RUN python3 --version \
 && { LD_LIBRARY_PATH=/opt/llama ldd /opt/llama/llama-server /opt/llama/*.so* 2>/dev/null | grep 'not found' | grep -v 'libcuda\.so' | sort -u \
      | sed 's/^/WARNING llama-server missing: /' || true; }
COPY --chmod=755 entrypoint.sh /entrypoint.sh
# Helper commands for the supervised ComfyUI process (see entrypoint.sh).
# The pattern is anchored so it only matches ComfyUI itself, never a shell that mentions it.
RUN printf '%s\n' '#!/bin/sh' 'touch /tmp/comfyui.restart' 'pkill -f "^python3 main.py --listen" || rm -f /tmp/comfyui.stop /tmp/comfyui.restart' 'echo "ComfyUI restarting"' > /usr/local/bin/comfyui-restart \
 && printf '%s\n' '#!/bin/sh' 'touch /tmp/comfyui.stop' 'rm -f /tmp/comfyui.restart' 'pkill -f "^python3 main.py --listen"' 'echo "ComfyUI stopped (comfyui-start to start it again)"' > /usr/local/bin/comfyui-stop \
 && printf '%s\n' '#!/bin/sh' 'rm -f /tmp/comfyui.stop' 'echo "ComfyUI starting"' > /usr/local/bin/comfyui-start \
 && chmod 755 /usr/local/bin/comfyui-restart /usr/local/bin/comfyui-stop /usr/local/bin/comfyui-start

WORKDIR /opt/ComfyUI
EXPOSE 22 8080 8188 8089
# tini as PID 1: forwards stop signals and reaps exited child processes
ENTRYPOINT ["/usr/bin/tini", "-g", "--", "/entrypoint.sh"]
