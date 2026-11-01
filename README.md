# comfyui-cuda13-runpod

A clean ComfyUI image for RunPod: Debian 13 slim, Python 3.13, PyTorch for CUDA 13.0,
File Browser, an optional `llama-server` (llama.cpp, CUDA 13, off by default), Node.js 24
and npm (for front ends such as Mix Studio), nano, tmux and SSH.
Nothing app-specific is baked in —
node packs, models and outputs live on the network volume, so the image stays small and
generic and the data survives pod restarts.

## What lives where

| Path | Where | Contents |
|---|---|---|
| `/opt/ComfyUI` | image | ComfyUI code |
| `/opt/llama` | image | `llama-server` with its libs (the official `server-cuda13` image's `/app`) + the NVIDIA libs it links to |
| `/usr/local/bin/filebrowser` | image | File Browser |
| `/workspace/models` | volume | **models only** (`checkpoints`, `loras`, `vae`, `diffusion_models`, `text_encoders`, …) |
| `/workspace/ComfyUI` | volume | `custom_nodes`, `input`, `output`, `user` |
| `/workspace/.python` | volume | Python packages of the node packs in `custom_nodes` |
| `/workspace/.filebrowser` | volume | File Browser settings, users and log |

On every start the entrypoint creates any missing standard model folders (existing files are
never touched) and installs the node packs' `requirements.txt` into `/workspace/.python`
**only when they changed** — the
first start after adding packs is slow, later starts are fast. Install log:
`/workspace/.python/node-deps.log`.

## Environment variables

| Variable | Default | Purpose |
|---|---|---|
| `COMFY_MODELS` | `/workspace/models` | models folder |
| `COMFY_BASE` | `/workspace/ComfyUI` | custom_nodes / input / output / user |
| `COMFY_ARGS` | – | extra ComfyUI flags, e.g. `--highvram` |
| `SKIP_NODE_DEPS` | `0` | `1` = skip the node-pack requirements check |
| `FILEBROWSER_ENABLED` | `true` | `false` = don't start File Browser |
| `FILEBROWSER_PASSWORD` | – | password for user `admin` (12+ characters). Unset: generated on first start and saved in `/workspace/.filebrowser/admin-password.txt` |
| `LLAMA_ENABLED` | `false` | `true` = start `llama-server` on port 8089 (not started by default) |
| `LLAMA_ARG_MODEL` | – | `.gguf` to load, e.g. `/workspace/models/llm/model.gguf` (required when enabled) |
| `LLAMA_ARG_*` | – | any llama-server option, e.g. `LLAMA_ARG_CTX_SIZE=8192` |
| `LLAMA_ARGS` | – | extra flags, e.g. `--mmproj /workspace/models/llm/mmproj.gguf --api-key <secret>` |
| `PUBLIC_KEY` | set by RunPod | SSH key for `root` (password login is disabled) |

## Starting and stopping ComfyUI

ComfyUI runs as a child process of the container's startup script, so stopping or
crashing it does **not** stop the container: SSH, File Browser and llama-server keep
running. It is **not** restarted automatically — after it exits it stays stopped until you
start it again from a pod shell:

| Command | Effect |
|---|---|
| `comfyui-start` | start ComfyUI (after it was stopped or crashed) |
| `comfyui-restart` | stop it and start it again right away (e.g. after adding node packs) |
| `comfyui-stop` | stop it, e.g. to run `python3 /opt/ComfyUI/main.py` by hand |
| `comfyui-args` | show the flags ComfyUI runs with |

### Extra startup flags

`comfyui-start` and `comfyui-restart` accept ComfyUI flags. They are checked with ComfyUI's
own option parser first, so a mistyped or unknown flag prints an error and nothing is
restarted. The flags are kept for later restarts until you change them, and last until the
pod restarts. For flags on every start, set `COMFY_ARGS` on the pod or template instead.

```bash
comfyui-restart --use-split-cross-attention     # restart with these extra flags
comfyui-restart --novram --reserve-vram 2       # replace them with others
comfyui-restart                                 # restart, same extra flags as before
comfyui-restart --defaults                      # restart without extra flags
comfyui-restart --help                          # list all flags (restarts nothing)
```

Some useful ones: `--novram`, `--highvram`, `--cpu`, `--reserve-vram GB`,
`--use-split-cross-attention`, `--use-quad-cross-attention`, `--use-pytorch-cross-attention`,
`--use-sage-attention`, `--use-flash-attention`, `--disable-dynamic-vram`, `--cache-none`.
`--medvram` and `--normalvram` are Automatic1111 flags and don't exist in ComfyUI.
`--lowvram` exists but does nothing while Dynamic VRAM is on (add `--disable-dynamic-vram`).

## File Browser

A web file manager for the whole volume (`/workspace`) on port 8080, for uploading models,
downloading outputs and editing files. Log in as `admin`. The password comes from
`FILEBROWSER_PASSWORD`, or is generated on the first start — read it from a pod shell with
`cat /workspace/.filebrowser/admin-password.txt`. Setting `FILEBROWSER_PASSWORD` later
replaces the current password on the next start.

## RunPod template

- **Image:** `<dockerhub-user>/comfyui-cuda13:latest`
- **Ports:** `8188/http` (ComfyUI), `8080/http` (File Browser), `22/tcp` (SSH), plus
  `8089/http` only if llama-server must be reachable from outside
- **Volume:** network volume mounted at `/workspace`
- **GPU filter:** CUDA 13.x drivers. PyTorch is built for CUDA 13.0; llama.cpp's CUDA 13
  image uses 13.4 libraries and relies on CUDA 13 minor-version compatibility on older 13.x
  drivers — if `llama-server` fails with a CUDA error, pick hosts with CUDA ≥ 13.4.

## Moving an existing install to this layout

If models are currently in `/workspace/ComfyUI/models`, move them once (from a pod shell):

```bash
mkdir -p /workspace/models
cp -rn /workspace/ComfyUI/models/. /workspace/models/ && rm -rf /workspace/ComfyUI/models
```

## Build

Pushing to `main` builds and pushes the image with GitHub Actions
(`.github/workflows/docker.yml`). In **Settings → Secrets and variables → Actions** set:

- Secret `DOCKERHUB_USERNAME` – login name (Docker ID or email)
- Secret `DOCKERHUB_TOKEN` – a Docker Hub access token with Read & Write access
- Variable (or secret) `DOCKERHUB_NAMESPACE` – your Docker ID (lowercase, no `@`); the image is pushed as
  `<DOCKERHUB_NAMESPACE>/comfyui-cuda13`. Required if the login name is an email.
- Variable `IMAGE_NAME` – optional, default `comfyui-cuda13`

Tags pushed: `latest` and the short commit SHA. The workflow can also be started by hand
(**Actions → Build and push image → Run workflow**) with an optional torch version pin and
ComfyUI ref.

Local build:

```bash
docker buildx build --platform linux/amd64 -t <dockerhub-user>/comfyui-cuda13:latest --push .
```

### Build arguments

| Arg | Default | Purpose |
|---|---|---|
| `LLAMA_IMAGE` | `ghcr.io/ggml-org/llama.cpp:server-cuda13` | source of `llama-server`; pin with `@sha256:<digest>` |
| `TORCH_INDEX` | `https://download.pytorch.org/whl/cu130` | PyTorch wheel index |
| `TORCH_VERSION` | empty (newest) | pin torch + torchaudio, e.g. `2.11.0` |
| `COMFY_REF` | `master` | ComfyUI branch or tag |
| `FILEBROWSER_VERSION` | `v2.63.23` | File Browser release |
