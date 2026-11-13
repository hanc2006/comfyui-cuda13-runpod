# comfyui-cuda13-runpod

A clean ComfyUI image for RunPod: Debian 13 slim, Python 3.13, PyTorch for CUDA 13.0,
File Browser, Node.js 24 and npm (for front ends such as Mix Studio), nano, tmux and SSH.
Nothing app-specific is baked in —
node packs, models and outputs live on the network volume, so the image stays small and
generic and the data survives pod restarts.

There is also a separate `comfyui-cuda13-kokon` image with the headless
[Kokon](https://github.com/GabrieleLozupone/kokon) browser application. The original image
does not include or start Kokon.

`llama-server` and its `LLAMA_*` settings have been removed from both images. Existing
model files on the volume are not deleted.

## What lives where

| Path | Where | Contents |
|---|---|---|
| `/opt/ComfyUI` | image | ComfyUI code |
| `/usr/local/bin/filebrowser` | image | File Browser |
| `/workspace/models` | volume | **models only** (`checkpoints`, `loras`, `vae`, `diffusion_models`, `text_encoders`, …) |
| `/workspace/ComfyUI` | volume | `custom_nodes`, `input`, `output`, `user` |
| `/workspace/.python` | volume | Python packages of the node packs in `custom_nodes` |
| `/workspace/.ce` | volume | isolated Python envs that some node packs build with comfy-env (e.g. ComfyUI-SAM3) |
| `/workspace/.filebrowser` | volume | File Browser settings, users and log |
| `/workspace/kokon` | volume | Kokon data, configuration and saved images (Kokon image only) |

On every start the entrypoint creates any missing standard model folders (existing files are
never touched) and installs the node packs' `requirements.txt` into `/workspace/.python`
**only when they changed** — the
first start after adding packs is slow, later starts are fast. Install log:
`/workspace/.python/node-deps.log`. Before installing it waits for the pod's DNS
(up to `NET_WAIT` seconds), retries failed packs once, and marks the install done only when
every pack installed, so a pack that failed (no network, say) is tried again on the next start.
Packs built on comfy-env (e.g. ComfyUI-SAM3) also get their isolated env built in `/workspace/.ce`
by running their `install.py` — once, and again only when their `comfy-env*.toml` changes. Log:
`/workspace/.ce/install-<pack>.log`.

## Environment variables

| Variable | Default | Purpose |
|---|---|---|
| `COMFY_MODELS` | `/workspace/models` | models folder |
| `COMFY_BASE` | `/workspace/ComfyUI` | custom_nodes / input / output / user |
| `COMFY_ARGS` | – | extra ComfyUI flags, e.g. `--highvram` |
| `SKIP_NODE_DEPS` | `0` | `1` = skip the node-pack requirements check |
| `NET_WAIT` | `120` | seconds to wait for DNS (pypi.org, github.com) before installing node-pack requirements |
| `FILEBROWSER_ENABLED` | `true` | `false` = don't start File Browser |
| `FILEBROWSER_PASSWORD` | – | password for user `admin` (12+ characters). Unset: generated on first start and saved in `/workspace/.filebrowser/admin-password.txt` |
| `KOKON_ENABLED` | `true` in Kokon image | `false` = don't start Kokon |
| `PUBLIC_KEY` | set by RunPod | SSH key for `root` (password login is disabled) |

## Kokon image

Use `<dockerhub-user>/comfyui-cuda13-kokon:latest` and expose `39152/http` in addition
to the usual RunPod ports. Kokon starts alongside ComfyUI and shares the GPU; running
both may exhaust GPU memory. Kokon downloads its own engine and model during setup
(allow at least 15 GB on the `/workspace` volume); it does not automatically use
ComfyUI's models.

RunPod supplies the NVIDIA driver and GPU devices from the host via the NVIDIA container
runtime; the image does not install a driver. `nvidia-smi` in the pod should show the GPU.
Kokon's setup downloads its CUDA 12.8 engine and CUDA runtime libraries separately; the
CUDA 13-capable host driver is backward-compatible with them.

Set a browser password from a pod shell (at least 8 characters):

```bash
runuser -u kokon -- kokon-service --set-password
```

Open the RunPod HTTP proxy URL for port `39152`, sign in, and complete Kokon's setup.
The password is required before remote access is enabled and persists in
`/workspace/kokon/data`. Settings are in `/workspace/kokon/config`, saved images in
`/workspace/kokon/gallery`, and startup output in `/workspace/kokon/data/kokon-service.log`.
The service runs as UID 1000; these folders must be writable by that user. The local
token API on port `39151` must not be exposed. Kokon itself serves plain HTTP, so use
RunPod's HTTPS proxy or another secure connection rather than exposing it directly to
the internet. See [Kokon's Docker guide](https://github.com/GabrieleLozupone/kokon/blob/master/docs/docker.md).

## Starting and stopping ComfyUI

ComfyUI runs as a child process of the container's startup script, so stopping or
crashing it does **not** stop the container: SSH, File Browser and Kokon (if enabled) keep
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
- **Ports:** `8188/http` (ComfyUI), `8080/http` (File Browser), `22/tcp` (SSH). For Kokon use the
  `comfyui-cuda13-kokon` image and add `39152/http`.
- **Volume:** network volume mounted at `/workspace`
- **GPU filter:** CUDA 13.x drivers. PyTorch is built for CUDA 13.0.

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

Both `<namespace>/<IMAGE_NAME>` and `<namespace>/<IMAGE_NAME>-kokon` are pushed with
`latest` and short commit SHA tags. The workflow can also be started by hand
(**Actions → Build and push image → Run workflow**) with an optional torch version pin and
ComfyUI ref.

Local build:

```bash
docker buildx build --platform linux/amd64 --target runtime -t <dockerhub-user>/comfyui-cuda13:latest --push .
docker buildx build --platform linux/amd64 --target kokon -t <dockerhub-user>/comfyui-cuda13-kokon:latest --push .
```

### Build arguments

| Arg | Default | Purpose |
|---|---|---|
| `TORCH_INDEX` | `https://download.pytorch.org/whl/cu130` | PyTorch wheel index |
| `TORCH_VERSION` | empty (newest) | pin torch + torchaudio, e.g. `2.11.0` |
| `COMFY_REF` | `master` | ComfyUI branch or tag |
| `FILEBROWSER_VERSION` | `v2.63.23` | File Browser release |
| `KOKON_IMAGE` | `ghcr.io/gabrielelozupone/kokon:0.12.1` | published Kokon image supplying `kokon-service`; pin with `@sha256:<digest>` |
